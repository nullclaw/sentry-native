const std = @import("std");
const testing = std.testing;

const Client = @import("../client.zig").Client;
const Hub = @import("../hub.zig").Hub;
const SendOutcome = @import("../worker.zig").SendOutcome;

/// Detached Hub container for worker threads and async-style task boundaries.
///
/// It clones the current top scope (`fromCurrent`) or an explicit source Hub
/// (`fromTop`) and can temporarily bind that clone as current TLS Hub via `run`.
pub const DetachedHub = struct {
    allocator: std.mem.Allocator,
    hub: *Hub,
    active: bool = true,

    /// Clone from current TLS Hub top scope when available, otherwise initialize
    /// from explicit `client`.
    pub fn fromCurrent(allocator: std.mem.Allocator, client: ?*Client) !DetachedHub {
        const hub_ptr = try allocator.create(Hub);
        errdefer allocator.destroy(hub_ptr);

        if (Hub.current()) |current| {
            hub_ptr.* = try Hub.initFromTop(allocator, current, client);
        } else {
            const base_client = client orelse return error.NoCurrentHubOrClient;
            hub_ptr.* = try Hub.init(allocator, base_client);
        }
        errdefer hub_ptr.deinit();

        return .{
            .allocator = allocator,
            .hub = hub_ptr,
        };
    }

    /// Clone from an explicit source hub.
    pub fn fromTop(allocator: std.mem.Allocator, source: *Hub, client: ?*Client) !DetachedHub {
        const hub_ptr = try allocator.create(Hub);
        errdefer allocator.destroy(hub_ptr);

        hub_ptr.* = try Hub.initFromTop(allocator, source, client);
        errdefer hub_ptr.deinit();

        return .{
            .allocator = allocator,
            .hub = hub_ptr,
        };
    }

    pub fn hubPtr(self: *DetachedHub) *Hub {
        return self.hub;
    }

    /// Run callback with this detached hub installed as current TLS Hub, then
    /// restore the previous TLS Hub.
    pub fn run(self: *DetachedHub, callback: anytype, args: anytype) @TypeOf(@call(.auto, callback, args)) {
        const previous = Hub.setCurrent(self.hub);
        defer {
            _ = Hub.clearCurrent();
            if (previous) |previous_hub| {
                _ = Hub.setCurrent(previous_hub);
            }
        }
        return @call(.auto, callback, args);
    }

    pub fn deinit(self: *DetachedHub) void {
        if (!self.active) return;
        self.active = false;

        if (Hub.current()) |current| {
            if (current == self.hub) {
                _ = Hub.clearCurrent();
            }
        }

        self.hub.deinit();
        self.allocator.destroy(self.hub);
    }
};

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

const ObserveCurrent = struct {
    expected: *Hub,
    saw_expected: bool = false,
};

fn observeCurrent(state: *ObserveCurrent) void {
    if (Hub.current()) |current| {
        state.saw_expected = current == state.expected;
    }
}

fn captureWorkerEvent(worker_hub: *DetachedHub) void {
    worker_hub.hubPtr().setTag("worker", "email-delivery");
    _ = worker_hub.hubPtr().captureMessageId("worker start", .info);
}

const DemoError = error{
    DemoFailure,
};

fn runDemo(value: usize) DemoError!usize {
    if (value == 0) return error.DemoFailure;
    return value + 1;
}

test "DetachedHub run swaps current hub and restores previous" {
    const client = try Client.init(testing.allocator, .{
        .dsn = "https://examplePublicKey@o0.ingest.sentry.io/1234567",
        .install_signal_handlers = false,
    });
    defer client.deinit();

    var primary = try Hub.init(testing.allocator, client);
    defer primary.deinit();

    _ = Hub.setCurrent(&primary);
    defer _ = Hub.clearCurrent();

    var detached = try DetachedHub.fromCurrent(testing.allocator, client);
    defer detached.deinit();

    var observation = ObserveCurrent{
        .expected = detached.hubPtr(),
    };
    detached.run(observeCurrent, .{&observation});

    try testing.expect(observation.saw_expected);
    try testing.expect(Hub.current().? == &primary);
}

test "DetachedHub fromCurrent clones top scope and isolates worker scope changes" {
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

    var primary = try Hub.init(testing.allocator, client);
    defer primary.deinit();

    _ = Hub.setCurrent(&primary);
    defer _ = Hub.clearCurrent();

    primary.setTag("tenant", "acme");

    var detached = try DetachedHub.fromCurrent(testing.allocator, client);
    defer detached.deinit();

    detached.run(captureWorkerEvent, .{&detached});

    try testing.expect(primary.currentScope().tags.get("worker") == null);
    try testing.expectEqualStrings("acme", primary.currentScope().tags.get("tenant").?);

    try testing.expect(client.flush(1000));
    try testing.expect(payload_state.payloads.items.len >= 1);
    try testing.expect(std.mem.indexOf(u8, payload_state.payloads.items[0], "\"tenant\":\"acme\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload_state.payloads.items[0], "\"worker\":\"email-delivery\"") != null);
}

test "DetachedHub run preserves callback return type including errors" {
    const client = try Client.init(testing.allocator, .{
        .dsn = "https://examplePublicKey@o0.ingest.sentry.io/1234567",
        .install_signal_handlers = false,
    });
    defer client.deinit();

    var detached = try DetachedHub.fromCurrent(testing.allocator, client);
    defer detached.deinit();

    try testing.expectError(error.DemoFailure, detached.run(runDemo, .{0}));
    const value = try detached.run(runDemo, .{41});
    try testing.expectEqual(@as(usize, 42), value);
}

test "DetachedHub fromCurrent requires current hub or explicit client" {
    _ = Hub.clearCurrent();
    try testing.expect(Hub.current() == null);
    try testing.expectError(error.NoCurrentHubOrClient, DetachedHub.fromCurrent(testing.allocator, null));
}
