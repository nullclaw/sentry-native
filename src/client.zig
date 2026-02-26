const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const json = std.json;
const Writer = std.io.Writer;

const Dsn = @import("dsn.zig").Dsn;
const event_mod = @import("event.zig");
const Event = event_mod.Event;
const Level = event_mod.Level;
const User = event_mod.User;
const Breadcrumb = event_mod.Breadcrumb;
const ExceptionValue = event_mod.ExceptionValue;
const ExceptionInterface = event_mod.ExceptionInterface;
const Message = event_mod.Message;
const scope_mod = @import("scope.zig");
const Scope = scope_mod.Scope;
const Session = @import("session.zig").Session;
const SessionStatus = @import("session.zig").SessionStatus;
const Transport = @import("transport.zig").Transport;
const SendResult = @import("transport.zig").SendResult;
const Worker = @import("worker.zig").Worker;
const signal_handler = @import("signal_handler.zig");
const envelope = @import("envelope.zig");
const txn_mod = @import("transaction.zig");
const Transaction = txn_mod.Transaction;
const TransactionOpts = txn_mod.TransactionOpts;

/// Configuration options for the Sentry client.
pub const Options = struct {
    dsn: []const u8,
    release: ?[]const u8 = null,
    environment: ?[]const u8 = null,
    server_name: ?[]const u8 = null,
    sample_rate: f64 = 1.0,
    traces_sample_rate: f64 = 0.0,
    max_breadcrumbs: u32 = 100,
    before_send: ?*const fn (*Event) ?*Event = null, // return null to drop
    cache_dir: []const u8 = "/tmp/sentry-zig",
    install_signal_handlers: bool = true,
    auto_session_tracking: bool = false,
    shutdown_timeout_ms: u64 = 2000,
};

/// The Sentry client, tying together DSN, Scope, Transport, Worker, and Session.
/// Heap-allocated via `init` to avoid self-referential pointer issues.
pub const Client = struct {
    allocator: Allocator,
    dsn: Dsn,
    options: Options,
    scope: Scope,
    transport: Transport,
    worker: Worker,
    session: ?Session = null,
    mutex: std.Thread.Mutex = .{},

    /// Initialize a new Client. Heap-allocates the Client struct so that
    /// internal pointers (e.g., the Worker's send_ctx) remain stable.
    pub fn init(allocator: Allocator, options: Options) !*Client {
        if (!isValidSampleRate(options.sample_rate)) return error.InvalidSampleRate;
        if (!isValidSampleRate(options.traces_sample_rate)) return error.InvalidTracesSampleRate;

        const self = try allocator.create(Client);
        errdefer allocator.destroy(self);

        const dsn = Dsn.parse(options.dsn) catch return error.InvalidDsn;

        var transport = try Transport.init(allocator, dsn);
        errdefer transport.deinit();

        var scope = try Scope.init(allocator, options.max_breadcrumbs);
        errdefer scope.deinit();

        self.* = Client{
            .allocator = allocator,
            .dsn = dsn,
            .options = options,
            .scope = scope,
            .transport = transport,
            .worker = Worker.init(allocator, transportSendCallback, @ptrCast(self)),
            .session = null,
        };

        try self.worker.start();

        std.fs.cwd().makePath(options.cache_dir) catch {};

        // Install signal handlers if requested
        if (options.install_signal_handlers) {
            signal_handler.install(options.cache_dir);
        }

        // Check for pending crash from previous run
        if (signal_handler.checkPendingCrash(allocator, options.cache_dir)) |signal_num| {
            self.captureCrashEvent(signal_num);
        }

        if (options.auto_session_tracking) {
            self.startSession();
        }

        return self;
    }

    /// Shut down the client, flushing pending events and freeing resources.
    pub fn deinit(self: *Client) void {
        self.endSession(.exited);

        // Flush remaining events
        _ = self.worker.flush(self.options.shutdown_timeout_ms);

        // Shutdown worker thread
        self.worker.shutdown();
        self.worker.deinit();

        // Uninstall signal handlers
        if (self.options.install_signal_handlers) {
            signal_handler.uninstall();
        }

        self.transport.deinit();
        self.scope.deinit();

        const allocator = self.allocator;
        allocator.destroy(self);
    }

    // ─── Capture Methods ─────────────────────────────────────────────────

    /// Capture a simple message event at the given level.
    pub fn captureMessage(self: *Client, message: []const u8, level: Level) void {
        var event = Event.initMessage(message, level);
        self.captureEvent(&event);
    }

    /// Capture an exception event.
    pub fn captureException(self: *Client, exception_type: []const u8, value: []const u8) void {
        const values = [_]ExceptionValue{.{
            .type = exception_type,
            .value = value,
        }};
        var event = Event.initException(&values);
        self.captureEvent(&event);
    }

    /// Core method: apply defaults, sample, apply scope, run before_send,
    /// serialize to envelope, and submit to the worker queue.
    pub fn captureEvent(self: *Client, event: *Event) void {
        // Apply defaults from options
        if (self.options.release) |release| {
            if (event.release == null) event.release = release;
        }
        if (self.options.environment) |env| {
            if (event.environment == null) event.environment = env;
        }
        if (self.options.server_name) |sn| {
            if (event.server_name == null) event.server_name = sn;
        }

        // Apply scope to event
        const applied = self.scope.applyToEvent(self.allocator, event) catch return;
        defer scope_mod.cleanupAppliedToEvent(self.allocator, event, applied);

        var prepared_event = event;

        // Run before_send callback
        if (self.options.before_send) |before_send| {
            if (before_send(prepared_event)) |processed_event| {
                prepared_event = processed_event;
            } else {
                return;
            }
        }

        // Update session based on the prepared event before applying sampling.
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.session) |*s| {
                if (prepared_event.level) |level| {
                    if (level == .err or level == .fatal) {
                        s.markErrored();
                    }
                }
                if (s.dirty) {
                    _ = self.sendSessionUpdate(s);
                }
            }
        }

        // Sample rate check
        if (self.options.sample_rate < 1.0) {
            const rand_val = std.crypto.random.float(f64);
            if (rand_val >= self.options.sample_rate) return;
        }

        // Serialize event to envelope
        const data = self.serializeEventEnvelope(prepared_event) catch return;

        // Submit to worker queue (worker takes ownership of data)
        self.worker.submit(data) catch {
            self.allocator.free(data);
        };
    }

    // ─── Scope Delegation ────────────────────────────────────────────────

    /// Set the user context.
    pub fn setUser(self: *Client, user: User) void {
        self.scope.setUser(user);
    }

    /// Remove the user context.
    pub fn removeUser(self: *Client) void {
        self.scope.setUser(null);
    }

    /// Set a tag.
    pub fn setTag(self: *Client, key: []const u8, value: []const u8) void {
        self.scope.setTag(key, value) catch {};
    }

    /// Remove a tag.
    pub fn removeTag(self: *Client, key: []const u8) void {
        self.scope.removeTag(key);
    }

    /// Set an extra value.
    pub fn setExtra(self: *Client, key: []const u8, value: json.Value) void {
        self.scope.setExtra(key, value) catch {};
    }

    /// Set a context value.
    pub fn setContext(self: *Client, key: []const u8, value: json.Value) void {
        self.scope.setContext(key, value) catch {};
    }

    /// Add a breadcrumb.
    pub fn addBreadcrumb(self: *Client, crumb: Breadcrumb) void {
        self.scope.addBreadcrumb(crumb);
    }

    // ─── Transaction Methods ─────────────────────────────────────────────

    /// Start a new transaction, applying release/environment from options.
    pub fn startTransaction(self: *Client, opts: TransactionOpts) Transaction {
        var real_opts = opts;

        // Apply defaults from client options
        if (real_opts.release == null) real_opts.release = self.options.release;
        if (real_opts.environment == null) real_opts.environment = self.options.environment;

        // Apply traces sample rate
        if (real_opts.sample_rate == 1.0) {
            real_opts.sample_rate = self.options.traces_sample_rate;
        }

        if (real_opts.sampled and real_opts.sample_rate < 1.0) {
            const rand_val = std.crypto.random.float(f64);
            real_opts.sampled = rand_val < real_opts.sample_rate;
        }

        return Transaction.init(self.allocator, real_opts);
    }

    /// Finish a transaction, serialize it, and submit the envelope to the worker.
    pub fn finishTransaction(self: *Client, txn: *Transaction) void {
        txn.finish();

        if (!txn.sampled) return;

        // Serialize transaction to JSON
        const txn_json = txn.toJson(self.allocator) catch return;
        defer self.allocator.free(txn_json);

        // Create transaction envelope
        const data = self.serializeTransactionEnvelope(txn, txn_json) catch return;

        self.worker.submit(data) catch {
            self.allocator.free(data);
        };
    }

    // ─── Session Methods ─────────────────────────────────────────────────

    /// Start a new session.
    pub fn startSession(self: *Client) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // End any existing session first
        if (self.session) |*s| {
            s.end(.exited);
            _ = self.sendSessionUpdate(s);
        }

        const release = self.options.release orelse "unknown";
        const environment = self.options.environment orelse "production";
        self.session = Session.start(release, environment);
    }

    /// End the current session with the given status.
    pub fn endSession(self: *Client, status: SessionStatus) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.session) |*s| {
            s.end(status);
            _ = self.sendSessionUpdate(s);
            self.session = null;
        }
    }

    // ─── Flush ───────────────────────────────────────────────────────────

    /// Flush the event queue, waiting up to timeout_ms.
    /// Returns true if the queue was fully drained.
    pub fn flush(self: *Client, timeout_ms: u64) bool {
        return self.worker.flush(timeout_ms);
    }

    // ─── Internal Helpers ────────────────────────────────────────────────

    fn transportSendCallback(data: []const u8, ctx: ?*anyopaque) void {
        if (ctx) |ptr| {
            const client: *Client = @ptrCast(@alignCast(ptr));
            _ = client.transport.send(data) catch {};
        }
    }

    fn captureCrashEvent(self: *Client, signal_num: u32) void {
        var event = Event.init();
        event.level = .fatal;

        var msg_buf: [64]u8 = undefined;
        const sig_name: []const u8 = switch (signal_num) {
            11 => "SIGSEGV",
            6 => "SIGABRT",
            7 => "SIGBUS",
            4 => "SIGILL",
            8 => "SIGFPE",
            else => "Unknown",
        };
        const msg = std.fmt.bufPrint(&msg_buf, "Crash: {s} (signal {d})", .{ sig_name, signal_num }) catch "Crash detected from previous run";

        // Use exception interface with stack-local values — safe because captureEvent
        // serializes synchronously before returning
        const values = [_]ExceptionValue{.{
            .type = "NativeCrash",
            .value = msg,
        }};
        event.exception = .{ .values = &values };
        self.captureEvent(&event);
    }

    fn serializeEventEnvelope(self: *Client, event: *const Event) ![]u8 {
        var aw: Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();
        try envelope.serializeEventEnvelope(self.allocator, event.*, self.dsn, &aw.writer);
        return try aw.toOwnedSlice();
    }

    fn serializeTransactionEnvelope(self: *Client, txn: *const Transaction, txn_json: []const u8) ![]u8 {
        var aw: Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();
        const w = &aw.writer;

        // Envelope header
        try w.writeAll("{\"event_id\":\"");
        try w.writeAll(&txn.event_id);
        try w.writeAll("\",\"dsn\":\"");
        try self.dsn.writeDsn(w);
        try w.writeAll("\",\"sent_at\":\"");
        const ts = @import("timestamp.zig");
        const rfc3339 = ts.nowRfc3339();
        try w.writeAll(&rfc3339);
        try w.writeAll("\",\"sdk\":{\"name\":\"");
        try w.writeAll(envelope.SDK_NAME);
        try w.writeAll("\",\"version\":\"");
        try w.writeAll(envelope.SDK_VERSION);
        try w.writeAll("\"}}");
        try w.writeByte('\n');

        // Item header
        try w.writeAll("{\"type\":\"transaction\",\"length\":");
        try w.print("{d}", .{txn_json.len});
        try w.writeByte('}');
        try w.writeByte('\n');

        // Payload
        try w.writeAll(txn_json);

        return try aw.toOwnedSlice();
    }

    fn sendSessionUpdate(self: *Client, session: *Session) bool {
        const session_json = session.toJson(self.allocator) catch return false;
        defer self.allocator.free(session_json);

        var aw: Writer.Allocating = .init(self.allocator);

        envelope.serializeSessionEnvelope(self.dsn, session_json, &aw.writer) catch {
            aw.deinit();
            return false;
        };

        const data = aw.toOwnedSlice() catch {
            aw.deinit();
            return false;
        };

        self.worker.submit(data) catch {
            self.allocator.free(data);
            return false;
        };

        session.markSent();
        return true;
    }

    fn isValidSampleRate(rate: f64) bool {
        if (!std.math.isFinite(rate)) return false;
        return rate >= 0.0 and rate <= 1.0;
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

test "Options struct has correct defaults" {
    const opts = Options{
        .dsn = "https://key@sentry.io/1",
    };
    try testing.expectEqual(@as(f64, 1.0), opts.sample_rate);
    try testing.expectEqual(@as(f64, 0.0), opts.traces_sample_rate);
    try testing.expectEqual(@as(u32, 100), opts.max_breadcrumbs);
    try testing.expect(opts.release == null);
    try testing.expect(opts.environment == null);
    try testing.expect(opts.server_name == null);
    try testing.expect(opts.before_send == null);
    try testing.expect(opts.install_signal_handlers);
    try testing.expect(!opts.auto_session_tracking);
    try testing.expectEqual(@as(u64, 2000), opts.shutdown_timeout_ms);
    try testing.expectEqualStrings("/tmp/sentry-zig", opts.cache_dir);
}

test "Client struct size is non-zero" {
    try testing.expect(@sizeOf(Client) > 0);
}

test "Options struct size is non-zero" {
    try testing.expect(@sizeOf(Options) > 0);
}
