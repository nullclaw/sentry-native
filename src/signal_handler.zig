const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const is_posix = switch (builtin.os.tag) {
    .windows => false,
    else => true,
};

const CRASH_FILE = ".sentry-zig-crash";

// Global state (necessary for signal handlers which cannot capture context)
var crash_file_path: [std.fs.max_path_bytes]u8 = undefined;
var crash_file_path_len: usize = 0;
var handlers_installed: bool = false;
var install_ref_count: usize = 0;
var install_mutex: std.Thread.Mutex = .{};

const NUM_SIGNALS = 5;

// Platform-specific signal definitions
const SIG = if (is_posix) std.posix.SIG else struct {};

const crash_signals = if (is_posix) [NUM_SIGNALS]u8{
    SIG.SEGV,
    SIG.ABRT,
    SIG.BUS,
    SIG.ILL,
    SIG.FPE,
} else [NUM_SIGNALS]u8{ 0, 0, 0, 0, 0 };

var previous_handlers: if (is_posix) [NUM_SIGNALS]std.posix.Sigaction else [NUM_SIGNALS]u8 = undefined;

/// Signal handler function. Must be async-signal-safe.
/// Writes "signal:N\n" to crash file, then re-raises with default handler.
fn signalHandler(sig: i32) callconv(.c) void {
    if (crash_file_path_len == 0) return;

    // Open the crash file using openZ with null-terminated path (async-signal-safe)
    const path_z: [*:0]const u8 = @ptrCast(crash_file_path[0..crash_file_path_len :0]);
    const fd = std.posix.openZ(
        path_z,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    ) catch return;
    defer std.posix.close(fd);

    // Write "signal:" prefix
    _ = std.posix.write(fd, "signal:") catch return;

    // Convert signal number to string (async-signal-safe, no allocator)
    var num_buf: [10]u8 = undefined;
    var num_len: usize = 0;
    var n: u32 = if (sig >= 0) @intCast(sig) else 0;
    if (n == 0) {
        num_buf[0] = '0';
        num_len = 1;
    } else {
        // Write digits in reverse
        while (n > 0) {
            num_buf[num_len] = @intCast('0' + (n % 10));
            num_len += 1;
            n /= 10;
        }
        // Reverse the digits
        var i: usize = 0;
        var j: usize = num_len - 1;
        while (i < j) {
            const tmp = num_buf[i];
            num_buf[i] = num_buf[j];
            num_buf[j] = tmp;
            i += 1;
            j -= 1;
        }
    }
    _ = std.posix.write(fd, num_buf[0..num_len]) catch return;
    _ = std.posix.write(fd, "\n") catch return;

    // Re-raise with default handler
    if (sig < 0 or sig >= 64) return;
    const usig: u8 = @intCast(sig);
    const default_action = std.posix.Sigaction{
        .handler = .{ .handler = SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(usig, &default_action, null);
    std.posix.raise(usig) catch {};
}

/// Install signal handlers for crash reporting.
/// cache_dir is the directory where the crash file will be written.
pub fn install(cache_dir: []const u8) void {
    if (!is_posix) return;

    install_mutex.lock();
    defer install_mutex.unlock();

    if (handlers_installed) {
        install_ref_count += 1;
        return;
    }

    // Build the crash file path: cache_dir/CRASH_FILE
    if (cache_dir.len + 1 + CRASH_FILE.len + 1 > crash_file_path.len) return;

    var pos: usize = 0;
    @memcpy(crash_file_path[pos .. pos + cache_dir.len], cache_dir);
    pos += cache_dir.len;
    crash_file_path[pos] = '/';
    pos += 1;
    @memcpy(crash_file_path[pos .. pos + CRASH_FILE.len], CRASH_FILE);
    pos += CRASH_FILE.len;
    crash_file_path[pos] = 0; // null-terminate for posix openZ
    crash_file_path_len = pos;

    // Install handlers for each crash signal
    for (crash_signals, 0..) |sig, i| {
        const action = std.posix.Sigaction{
            .handler = .{ .handler = @ptrCast(&signalHandler) },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(sig, &action, &previous_handlers[i]);
    }

    handlers_installed = true;
    install_ref_count = 1;
}

/// Uninstall signal handlers, restoring previous handlers.
pub fn uninstall() void {
    if (!is_posix) return;

    install_mutex.lock();
    defer install_mutex.unlock();

    if (!handlers_installed) return;

    if (install_ref_count > 1) {
        install_ref_count -= 1;
        return;
    }

    for (crash_signals, 0..) |sig, i| {
        std.posix.sigaction(sig, &previous_handlers[i], null);
    }

    install_ref_count = 0;
    handlers_installed = false;
    crash_file_path_len = 0;
}

/// Check for a pending crash from a previous run.
/// Returns the signal number if a crash file exists, null otherwise.
/// Deletes the crash file after reading.
pub fn checkPendingCrash(allocator: Allocator, cache_dir: []const u8) ?u32 {
    // Build the crash file path
    const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_dir, CRASH_FILE }) catch return null;
    defer allocator.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    var buf: [64]u8 = undefined;
    const bytes_read = file.read(&buf) catch return null;
    const content = buf[0..bytes_read];

    // Parse "signal:N\n"
    const signal_num = parseSignalLine(content);

    // Delete the crash file
    std.fs.cwd().deleteFile(path) catch {};

    return signal_num;
}

fn parseSignalLine(content: []const u8) ?u32 {
    const prefix = "signal:";
    if (!std.mem.startsWith(u8, content, prefix)) return null;

    const after_prefix = content[prefix.len..];
    // Find newline or end
    const end = std.mem.indexOf(u8, after_prefix, "\n") orelse after_prefix.len;
    const num_str = after_prefix[0..end];

    return std.fmt.parseInt(u32, num_str, 10) catch null;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "checkPendingCrash returns null when no crash file exists" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(dir_path);

    const result = checkPendingCrash(testing.allocator, dir_path);
    try testing.expect(result == null);
}

test "checkPendingCrash reads and deletes crash file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const test_dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(test_dir);
    const crash_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ test_dir, CRASH_FILE });
    defer testing.allocator.free(crash_path);

    // Write a fake crash file
    {
        const file = try std.fs.cwd().createFile(crash_path, .{});
        defer file.close();
        try file.writeAll("signal:11\n");
    }

    // Check pending crash
    const result = checkPendingCrash(testing.allocator, test_dir);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u32, 11), result.?);

    // File should be deleted
    const result2 = checkPendingCrash(testing.allocator, test_dir);
    try testing.expect(result2 == null);
}

test "install and uninstall is idempotent" {
    if (!is_posix) return;

    while (install_ref_count > 0) uninstall();

    install("/tmp/sentry-zig-test-signals");
    try testing.expect(handlers_installed);
    try testing.expectEqual(@as(usize, 1), install_ref_count);

    // Install again increments reference count.
    install("/tmp/sentry-zig-test-signals");
    try testing.expect(handlers_installed);
    try testing.expectEqual(@as(usize, 2), install_ref_count);

    // First uninstall decrements refcount and keeps handlers installed.
    uninstall();
    try testing.expect(handlers_installed);
    try testing.expectEqual(@as(usize, 1), install_ref_count);

    // Final uninstall removes handlers.
    uninstall();
    try testing.expect(!handlers_installed);
    try testing.expectEqual(@as(usize, 0), install_ref_count);

    // Uninstall again should be no-op
    uninstall();
    try testing.expect(!handlers_installed);
    try testing.expectEqual(@as(usize, 0), install_ref_count);
}

test "parseSignalLine parses valid signal" {
    try testing.expectEqual(@as(?u32, 11), parseSignalLine("signal:11\n"));
    try testing.expectEqual(@as(?u32, 6), parseSignalLine("signal:6\n"));
    try testing.expectEqual(@as(?u32, 0), parseSignalLine("signal:0\n"));
    try testing.expectEqual(@as(?u32, 11), parseSignalLine("signal:11"));
}

test "parseSignalLine rejects invalid input" {
    try testing.expect(parseSignalLine("garbage") == null);
    try testing.expect(parseSignalLine("") == null);
    try testing.expect(parseSignalLine("signal:") == null);
    try testing.expect(parseSignalLine("signal:abc") == null);
}
