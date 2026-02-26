const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const Attachment = struct {
    filename: []u8,
    data: []u8,
    content_type: ?[]u8 = null,
    attachment_type: ?[]u8 = null,

    pub fn initOwned(
        allocator: Allocator,
        filename: []const u8,
        data: []const u8,
        content_type: ?[]const u8,
        attachment_type: ?[]const u8,
    ) !Attachment {
        var attachment = Attachment{
            .filename = try allocator.dupe(u8, filename),
            .data = try allocator.dupe(u8, data),
        };
        errdefer attachment.deinit(allocator);

        if (content_type) |ct| {
            attachment.content_type = try allocator.dupe(u8, ct);
        }
        if (attachment_type) |at| {
            attachment.attachment_type = try allocator.dupe(u8, at);
        }
        return attachment;
    }

    pub fn fromPath(
        allocator: Allocator,
        path: []const u8,
        filename_override: ?[]const u8,
        content_type: ?[]const u8,
        attachment_type: ?[]const u8,
    ) !Attachment {
        const data = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
        defer allocator.free(data);

        const filename = filename_override orelse std.fs.path.basename(path);
        return try initOwned(allocator, filename, data, content_type, attachment_type);
    }

    pub fn clone(self: Attachment, allocator: Allocator) !Attachment {
        return try initOwned(
            allocator,
            self.filename,
            self.data,
            self.content_type,
            self.attachment_type,
        );
    }

    pub fn deinit(self: *Attachment, allocator: Allocator) void {
        allocator.free(self.filename);
        allocator.free(self.data);
        if (self.content_type) |ct| allocator.free(ct);
        if (self.attachment_type) |at| allocator.free(at);
        self.* = undefined;
    }
};

test "Attachment initOwned and clone produce independent owned copies" {
    var attachment = try Attachment.initOwned(
        testing.allocator,
        "payload.txt",
        "hello",
        "text/plain",
        "event.attachment",
    );
    defer attachment.deinit(testing.allocator);

    var cloned = try attachment.clone(testing.allocator);
    defer cloned.deinit(testing.allocator);

    try testing.expectEqualStrings("payload.txt", attachment.filename);
    try testing.expectEqualStrings("hello", attachment.data);
    try testing.expectEqualStrings("text/plain", attachment.content_type.?);
    try testing.expectEqualStrings("event.attachment", attachment.attachment_type.?);

    attachment.filename[0] = 'X';
    try testing.expectEqualStrings("payload.txt", cloned.filename);
}

test "Attachment fromPath reads data and defaults filename to basename" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(dir_path);

    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/data.bin", .{dir_path});
    defer testing.allocator.free(file_path);

    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();
    try file.writeAll("abc123");

    var attachment = try Attachment.fromPath(
        testing.allocator,
        file_path,
        null,
        "application/octet-stream",
        null,
    );
    defer attachment.deinit(testing.allocator);

    try testing.expectEqualStrings("data.bin", attachment.filename);
    try testing.expectEqualStrings("abc123", attachment.data);
    try testing.expectEqualStrings("application/octet-stream", attachment.content_type.?);
    try testing.expect(attachment.attachment_type == null);
}
