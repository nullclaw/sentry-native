const std = @import("std");

pub const Uuid = struct {
    bytes: [16]u8 = .{0} ** 16,
};
