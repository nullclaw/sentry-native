//! Sentry-Zig: Pure Zig Sentry SDK

const std = @import("std");
const builtin = @import("builtin");

comptime {
    const minimum = std.SemanticVersion{
        .major = 0,
        .minor = 15,
        .patch = 2,
    };
    if (builtin.zig_version.order(minimum) == .lt) {
        @compileError("sentry-zig requires Zig >= 0.15.2");
    }
}

pub const Client = @import("client.zig").Client;
pub const Options = @import("client.zig").Options;
pub const SessionMode = @import("client.zig").SessionMode;
pub const TracesSamplingContext = @import("client.zig").TracesSamplingContext;
pub const TracesSampler = @import("client.zig").TracesSampler;
pub const Event = @import("event.zig").Event;
pub const Level = @import("event.zig").Level;
pub const User = @import("event.zig").User;
pub const Breadcrumb = @import("event.zig").Breadcrumb;
pub const Frame = @import("event.zig").Frame;
pub const Stacktrace = @import("event.zig").Stacktrace;
pub const ExceptionValue = @import("event.zig").ExceptionValue;
pub const Message = @import("event.zig").Message;
pub const Attachment = @import("attachment.zig").Attachment;
pub const Transaction = @import("transaction.zig").Transaction;
pub const TransactionOpts = @import("transaction.zig").TransactionOpts;
pub const ChildSpanOpts = @import("transaction.zig").ChildSpanOpts;
pub const Span = @import("transaction.zig").Span;
pub const SpanStatus = @import("transaction.zig").SpanStatus;
pub const Session = @import("session.zig").Session;
pub const SessionStatus = @import("session.zig").SessionStatus;
pub const MonitorCheckIn = @import("monitor.zig").MonitorCheckIn;
pub const MonitorCheckInStatus = @import("monitor.zig").MonitorCheckInStatus;
pub const Dsn = @import("dsn.zig").Dsn;
pub const Scope = @import("scope.zig").Scope;
pub const EventProcessor = @import("scope.zig").EventProcessor;
pub const cleanupAppliedToEvent = @import("scope.zig").cleanupAppliedToEvent;
pub const Transport = @import("transport.zig").Transport;
pub const MockTransport = @import("transport.zig").MockTransport;
pub const envelope = @import("envelope.zig");
pub const Uuid = @import("uuid.zig").Uuid;
pub const timestamp = @import("timestamp.zig");
pub const Worker = @import("worker.zig").Worker;
pub const RateLimitCategory = @import("ratelimit.zig").Category;
pub const RateLimitUpdate = @import("ratelimit.zig").Update;
pub const RateLimitState = @import("ratelimit.zig").State;
pub const signal_handler = @import("signal_handler.zig");

/// Initialize a new Sentry client with the given options.
pub fn init(allocator: std.mem.Allocator, options: Options) !*Client {
    return Client.init(allocator, options);
}

test {
    std.testing.refAllDecls(@This());
}
