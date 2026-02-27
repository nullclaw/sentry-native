//! Built-in transport backend helpers for composing delivery strategies.

pub const file = @import("transport_backends/file.zig");
pub const fanout = @import("transport_backends/fanout.zig");

