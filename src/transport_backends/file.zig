const std = @import("std");
const testing = std.testing;

const TransportConfig = @import("../client.zig").TransportConfig;
const SendOutcome = @import("../worker.zig").SendOutcome;

pub const Options = struct {
    directory: []const u8,
    prefix: []const u8 = "sentry-envelope",
    extension: []const u8 = "envelope",
};

/// File-based transport backend.
///
/// Each envelope is stored as a separate file. Useful for offline capture,
/// sidecar forwarding, or debugging transport payloads.
pub const Backend = struct {
    allocator: std.mem.Allocator,
    directory: []u8,
    prefix: []u8,
    extension: []u8,
    mutex: std.Thread.Mutex = .{},
    counter: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, options: Options) !Backend {
        try std.fs.cwd().makePath(options.directory);

        const directory = try allocator.dupe(u8, options.directory);
        errdefer allocator.free(directory);
        const prefix = try allocator.dupe(u8, options.prefix);
        errdefer allocator.free(prefix);
        const extension = try allocator.dupe(u8, options.extension);

        return .{
            .allocator = allocator,
            .directory = directory,
            .prefix = prefix,
            .extension = extension,
        };
    }

    pub fn deinit(self: *Backend) void {
        self.allocator.free(self.directory);
        self.allocator.free(self.prefix);
        self.allocator.free(self.extension);
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
        self.writeEnvelopeFile(data) catch {};
        return .{};
    }

    fn writeEnvelopeFile(self: *Backend, data: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now_ms = std.time.milliTimestamp();
        const index = self.counter;
        self.counter += 1;

        const file_name = try std.fmt.allocPrint(
            self.allocator,
            "{s}-{d}-{d}.{s}",
            .{ self.prefix, now_ms, index, self.extension },
        );
        defer self.allocator.free(file_name);

        const path = try std.fs.path.join(self.allocator, &.{ self.directory, file_name });
        defer self.allocator.free(path);

        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();

        try file.writeAll(data);
    }
};

test "file backend writes envelopes to configured directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache/tmp", tmp.sub_path });
    defer testing.allocator.free(dir_path);

    var backend = try Backend.init(testing.allocator, .{
        .directory = dir_path,
        .prefix = "sentry-outbox",
    });
    defer backend.deinit();

    const transport = backend.transportConfig();
    _ = transport.send_fn("envelope-one", transport.ctx);
    _ = transport.send_fn("envelope-two", transport.ctx);

    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    var file_count: usize = 0;
    var saw_first = false;
    var saw_second = false;
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        file_count += 1;

        const file_path = try std.fs.path.join(testing.allocator, &.{ dir_path, entry.name });
        defer testing.allocator.free(file_path);

        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const body = try file.readToEndAlloc(testing.allocator, 64 * 1024);
        defer testing.allocator.free(body);

        if (std.mem.eql(u8, body, "envelope-one")) saw_first = true;
        if (std.mem.eql(u8, body, "envelope-two")) saw_second = true;
    }

    try testing.expectEqual(@as(usize, 2), file_count);
    try testing.expect(saw_first);
    try testing.expect(saw_second);
}
