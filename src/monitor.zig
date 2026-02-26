const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const json = std.json;
const Writer = std.io.Writer;

const Uuid = @import("uuid.zig").Uuid;

pub const MonitorCheckInStatus = enum {
    ok,
    @"error",
    in_progress,

    pub fn toString(self: MonitorCheckInStatus) []const u8 {
        return switch (self) {
            .ok => "ok",
            .@"error" => "error",
            .in_progress => "in_progress",
        };
    }

    pub fn jsonStringify(self: MonitorCheckInStatus, jw: anytype) !void {
        try jw.write(self.toString());
    }
};

pub const MonitorCheckIn = struct {
    check_in_id: [32]u8,
    monitor_slug: []const u8,
    status: MonitorCheckInStatus,
    environment: ?[]const u8 = null,
    duration: ?f64 = null,

    pub fn init(monitor_slug: []const u8, status: MonitorCheckInStatus) MonitorCheckIn {
        const id = Uuid.v4();
        return .{
            .check_in_id = id.toHex(),
            .monitor_slug = monitor_slug,
            .status = status,
        };
    }

    pub fn toJson(self: *const MonitorCheckIn, allocator: Allocator) ![]u8 {
        var aw: Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        const w = &aw.writer;

        try w.writeAll("{\"check_in_id\":\"");
        try w.writeAll(&self.check_in_id);
        try w.writeAll("\",\"monitor_slug\":");
        try json.Stringify.value(self.monitor_slug, .{}, w);
        try w.writeAll(",\"status\":\"");
        try w.writeAll(self.status.toString());
        try w.writeByte('"');

        if (self.environment) |environment| {
            try w.writeAll(",\"environment\":");
            try json.Stringify.value(environment, .{}, w);
        }
        if (self.duration) |duration| {
            try w.print(",\"duration\":{d:.3}", .{duration});
        }
        try w.writeByte('}');

        return try aw.toOwnedSlice();
    }
};

test "MonitorCheckIn.init generates valid check-in id" {
    const check_in = MonitorCheckIn.init("nightly-job", .ok);

    try testing.expectEqual(@as(usize, 32), check_in.check_in_id.len);
    for (check_in.check_in_id) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
    try testing.expectEqualStrings("nightly-job", check_in.monitor_slug);
    try testing.expectEqual(MonitorCheckInStatus.ok, check_in.status);
}

test "MonitorCheckIn.toJson includes expected fields" {
    var check_in = MonitorCheckIn.init("db-cleanup", .in_progress);
    check_in.environment = "production";
    check_in.duration = 12.345;

    const payload = try check_in.toJson(testing.allocator);
    defer testing.allocator.free(payload);

    try testing.expect(std.mem.indexOf(u8, payload, "\"check_in_id\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"monitor_slug\":\"db-cleanup\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"status\":\"in_progress\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"environment\":\"production\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"duration\":12.345") != null);
}
