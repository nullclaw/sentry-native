const std = @import("std");
const testing = std.testing;

const Event = @import("../event.zig").Event;
const ExceptionValue = @import("../event.zig").ExceptionValue;
const Frame = @import("../event.zig").Frame;
const Stacktrace = @import("../event.zig").Stacktrace;
const Hub = @import("../hub.zig").Hub;
const Client = @import("../client.zig").Client;
const SendOutcome = @import("../worker.zig").SendOutcome;

pub const Config = struct {
    exception_type: []const u8 = "Panic",
    flush_timeout_ms: u64 = 2000,
    capture_backtrace: bool = true,
    max_backtrace_frames: u8 = 32,
    capture_return_address_frame: bool = true,
};

var config_mutex: std.Thread.Mutex = .{};
var config: Config = .{};
threadlocal var in_panic_capture: bool = false;

pub fn install(new_config: Config) void {
    config_mutex.lock();
    defer config_mutex.unlock();
    config = new_config;
}

pub fn reset() void {
    install(.{});
}

pub fn currentConfig() Config {
    config_mutex.lock();
    defer config_mutex.unlock();
    return config;
}

pub fn setup(_: *Client, ctx: ?*anyopaque) void {
    if (ctx) |ptr| {
        const cfg: *const Config = @ptrCast(@alignCast(ptr));
        install(cfg.*);
    } else {
        install(.{});
    }
}

/// Capture panic text and then forward to Zig's default panic printer/abort path.
///
/// Usage:
///
/// ```zig
/// pub const panic = std.debug.FullPanic(sentry.integrations.panic.captureAndForward);
/// ```
pub fn captureAndForward(msg: []const u8, return_address: ?usize) noreturn {
    capture(msg, return_address);
    std.debug.defaultPanic(msg, return_address);
}

fn capture(msg: []const u8, return_address: ?usize) void {
    if (in_panic_capture) return;
    in_panic_capture = true;
    defer in_panic_capture = false;

    const cfg = currentConfig();
    if (Hub.current()) |hub| {
        var attempted_enriched_capture = false;
        if (return_address) |address| {
            if (cfg.capture_backtrace) {
                attempted_enriched_capture = true;
                _ = captureWithBacktrace(
                    hub,
                    cfg.exception_type,
                    msg,
                    address,
                    cfg.max_backtrace_frames,
                    cfg.capture_return_address_frame,
                );
            } else if (cfg.capture_return_address_frame) {
                attempted_enriched_capture = true;
                _ = captureWithReturnAddressFrame(hub, cfg.exception_type, msg, address);
            }
        }
        if (!attempted_enriched_capture) {
            _ = hub.captureExceptionId(cfg.exception_type, msg);
        }
        _ = hub.flush(cfg.flush_timeout_ms);
    }
}

fn captureWithBacktrace(
    hub: *Hub,
    exception_type: []const u8,
    value: []const u8,
    return_address: usize,
    max_frames: u8,
    allow_return_address_fallback: bool,
) ?[32]u8 {
    const frame_limit = @min(@as(usize, max_frames), 32);
    if (frame_limit == 0) {
        if (allow_return_address_fallback) {
            return captureWithReturnAddressFrame(hub, exception_type, value, return_address);
        }
        return hub.captureExceptionId(exception_type, value);
    }

    var iterator = std.debug.StackIterator.init(return_address, null);
    defer iterator.deinit();

    var address_buffers: [32][2 + (@sizeOf(usize) * 2)]u8 = undefined;
    var frames: [32]Frame = undefined;
    var frame_count: usize = 0;
    while (frame_count < frame_limit) {
        const address = iterator.next() orelse break;
        const address_text = std.fmt.bufPrint(&address_buffers[frame_count], "0x{x}", .{address}) catch break;
        frames[frame_count] = .{
            .instruction_addr = address_text,
        };
        frame_count += 1;
    }

    if (frame_count == 0) {
        if (allow_return_address_fallback) {
            return captureWithReturnAddressFrame(hub, exception_type, value, return_address);
        }
        return hub.captureExceptionId(exception_type, value);
    }

    const values = [_]ExceptionValue{.{
        .type = exception_type,
        .value = value,
        .stacktrace = Stacktrace{
            .frames = frames[0..frame_count],
        },
    }};
    var event = Event.initException(&values);
    event.level = .fatal;
    return hub.captureEventId(&event);
}

fn captureWithReturnAddressFrame(
    hub: *Hub,
    exception_type: []const u8,
    value: []const u8,
    return_address: usize,
) ?[32]u8 {
    var address_buf: [2 + (@sizeOf(usize) * 2)]u8 = undefined;
    const address = std.fmt.bufPrint(&address_buf, "0x{x}", .{return_address}) catch null;

    const frames = [_]Frame{.{
        .instruction_addr = address,
    }};
    const values = [_]ExceptionValue{.{
        .type = exception_type,
        .value = value,
        .stacktrace = Stacktrace{
            .frames = &frames,
        },
    }};
    var event = Event.initException(&values);
    event.level = .fatal;
    return hub.captureEventId(&event);
}

const PayloadState = struct {
    allocator: std.mem.Allocator,
    payloads: std.ArrayListUnmanaged([]u8) = .{},

    fn deinit(self: *PayloadState) void {
        for (self.payloads.items) |payload| self.allocator.free(payload);
        self.payloads.deinit(self.allocator);
        self.* = undefined;
    }
};

fn payloadSendFn(data: []const u8, ctx: ?*anyopaque) SendOutcome {
    const state: *PayloadState = @ptrCast(@alignCast(ctx.?));
    const copied = state.allocator.dupe(u8, data) catch return .{};
    state.payloads.append(state.allocator, copied) catch state.allocator.free(copied);
    return .{};
}

test "panic integration captures panic message through current hub" {
    var payload_state = PayloadState{ .allocator = testing.allocator };
    defer payload_state.deinit();

    const client = try Client.init(testing.allocator, .{
        .dsn = "https://examplePublicKey@o0.ingest.sentry.io/1234567",
        .transport = .{
            .send_fn = payloadSendFn,
            .ctx = &payload_state,
        },
        .install_signal_handlers = false,
    });
    defer client.deinit();

    var hub = try Hub.init(testing.allocator, client);
    defer hub.deinit();
    defer _ = Hub.clearCurrent();
    _ = Hub.setCurrent(&hub);

    install(.{
        .exception_type = "ZigPanic",
        .flush_timeout_ms = 1000,
    });
    defer reset();

    capture("panic parity test", null);

    try testing.expect(payload_state.payloads.items.len >= 1);
    try testing.expect(std.mem.indexOf(u8, payload_state.payloads.items[0], "\"type\":\"event\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload_state.payloads.items[0], "\"ZigPanic\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload_state.payloads.items[0], "panic parity test") != null);
}

test "panic integration can attach return-address frame as stacktrace" {
    var payload_state = PayloadState{ .allocator = testing.allocator };
    defer payload_state.deinit();

    const client = try Client.init(testing.allocator, .{
        .dsn = "https://examplePublicKey@o0.ingest.sentry.io/1234567",
        .transport = .{
            .send_fn = payloadSendFn,
            .ctx = &payload_state,
        },
        .install_signal_handlers = false,
    });
    defer client.deinit();

    var hub = try Hub.init(testing.allocator, client);
    defer hub.deinit();
    defer _ = Hub.clearCurrent();
    _ = Hub.setCurrent(&hub);

    install(.{
        .exception_type = "ZigPanic",
        .flush_timeout_ms = 1000,
        .capture_return_address_frame = true,
    });
    defer reset();

    capture("panic backtrace parity test", 0x1234abcd);

    try testing.expect(payload_state.payloads.items.len >= 1);
    try testing.expect(std.mem.indexOf(u8, payload_state.payloads.items[0], "\"stacktrace\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload_state.payloads.items[0], "\"instruction_addr\":\"0x1234abcd\"") != null);
}

test "panic integration can capture multi-frame backtrace" {
    var payload_state = PayloadState{ .allocator = testing.allocator };
    defer payload_state.deinit();

    const client = try Client.init(testing.allocator, .{
        .dsn = "https://examplePublicKey@o0.ingest.sentry.io/1234567",
        .transport = .{
            .send_fn = payloadSendFn,
            .ctx = &payload_state,
        },
        .install_signal_handlers = false,
    });
    defer client.deinit();

    var hub = try Hub.init(testing.allocator, client);
    defer hub.deinit();
    defer _ = Hub.clearCurrent();
    _ = Hub.setCurrent(&hub);

    install(.{
        .exception_type = "ZigPanic",
        .flush_timeout_ms = 1000,
        .capture_backtrace = true,
        .max_backtrace_frames = 8,
    });
    defer reset();

    capture("panic backtrace iterator test", @returnAddress());

    try testing.expect(payload_state.payloads.items.len >= 1);
    try testing.expect(std.mem.indexOf(u8, payload_state.payloads.items[0], "\"stacktrace\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload_state.payloads.items[0], "\"instruction_addr\":\"0x") != null);
}
