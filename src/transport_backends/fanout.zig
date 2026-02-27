const std = @import("std");
const testing = std.testing;

const TransportConfig = @import("../client.zig").TransportConfig;
const TransportSendFn = @import("../client.zig").TransportSendFn;
const SendOutcome = @import("../worker.zig").SendOutcome;
const RateLimitUpdate = @import("../ratelimit.zig").Update;

pub const Target = struct {
    send_fn: TransportSendFn,
    ctx: ?*anyopaque = null,
};

/// Fanout transport backend.
///
/// For each envelope, all targets are invoked. Returned rate-limit updates are
/// merged so upstream worker logic can apply conservative backpressure.
pub const Backend = struct {
    allocator: std.mem.Allocator,
    targets: []Target,

    pub fn init(allocator: std.mem.Allocator, targets: []const Target) !Backend {
        if (targets.len == 0) return error.NoTargets;
        const copied = try allocator.alloc(Target, targets.len);
        @memcpy(copied, targets);
        return .{
            .allocator = allocator,
            .targets = copied,
        };
    }

    pub fn deinit(self: *Backend) void {
        self.allocator.free(self.targets);
        self.* = undefined;
    }

    pub fn transportConfig(self: *Backend) TransportConfig {
        return .{
            .send_fn = sendFn,
            .ctx = self,
        };
    }

    fn sendFn(data: []const u8, ctx: ?*anyopaque) SendOutcome {
        const self: *Backend = @ptrCast(@alignCast(ctx.?));

        var merged: RateLimitUpdate = .{};
        for (self.targets) |target| {
            const outcome = target.send_fn(data, target.ctx);
            merged.merge(outcome.rate_limits);
        }
        return .{
            .rate_limits = merged,
        };
    }
};

const CounterState = struct {
    count: usize = 0,
};

fn countSendFn(_: []const u8, ctx: ?*anyopaque) SendOutcome {
    const state: *CounterState = @ptrCast(@alignCast(ctx.?));
    state.count += 1;
    return .{};
}

fn rateLimitSendFn(_: []const u8, _: ?*anyopaque) SendOutcome {
    var update: RateLimitUpdate = .{};
    update.setMax(.any, 7);
    return .{ .rate_limits = update };
}

test "fanout backend dispatches envelopes to all targets and merges rate limits" {
    var first = CounterState{};
    var second = CounterState{};

    var backend = try Backend.init(testing.allocator, &.{
        .{
            .send_fn = countSendFn,
            .ctx = &first,
        },
        .{
            .send_fn = countSendFn,
            .ctx = &second,
        },
        .{
            .send_fn = rateLimitSendFn,
        },
    });
    defer backend.deinit();

    const transport = backend.transportConfig();
    const outcome = transport.send_fn("fanout-envelope", transport.ctx);

    try testing.expectEqual(@as(usize, 1), first.count);
    try testing.expectEqual(@as(usize, 1), second.count);
    try testing.expectEqual(@as(?u64, 7), outcome.rate_limits.any);
}

test "fanout backend requires at least one target" {
    try testing.expectError(error.NoTargets, Backend.init(testing.allocator, &.{}));
}

