//! Sentry-Zig: Pure Zig Sentry SDK

const std = @import("std");

pub const Client = @import("client.zig").Client;
pub const Options = @import("client.zig").Options;
pub const Event = @import("event.zig").Event;
pub const Level = @import("event.zig").Level;
pub const User = @import("event.zig").User;
pub const Breadcrumb = @import("event.zig").Breadcrumb;
pub const Frame = @import("event.zig").Frame;
pub const Stacktrace = @import("event.zig").Stacktrace;
pub const ExceptionValue = @import("event.zig").ExceptionValue;
pub const Message = @import("event.zig").Message;
pub const Transaction = @import("transaction.zig").Transaction;
pub const TransactionOpts = @import("transaction.zig").TransactionOpts;
pub const ChildSpanOpts = @import("transaction.zig").ChildSpanOpts;
pub const Span = @import("transaction.zig").Span;
pub const SpanStatus = @import("transaction.zig").SpanStatus;
pub const Session = @import("session.zig").Session;
pub const SessionStatus = @import("session.zig").SessionStatus;
pub const Dsn = @import("dsn.zig").Dsn;
pub const Scope = @import("scope.zig").Scope;
pub const cleanupAppliedToEvent = @import("scope.zig").cleanupAppliedToEvent;
pub const Transport = @import("transport.zig").Transport;
pub const MockTransport = @import("transport.zig").MockTransport;
pub const envelope = @import("envelope.zig");
pub const Uuid = @import("uuid.zig").Uuid;
pub const timestamp = @import("timestamp.zig");
pub const Worker = @import("worker.zig").Worker;
pub const signal_handler = @import("signal_handler.zig");

/// Initialize a new Sentry client with the given options.
pub fn init(allocator: std.mem.Allocator, options: Options) !*Client {
    return Client.init(allocator, options);
}

test {
    std.testing.refAllDecls(@This());
}
