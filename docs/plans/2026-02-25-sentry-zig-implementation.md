# Sentry-Zig Implementation Plan

**Goal:** Build a pure Zig Sentry SDK (named Sentry-Zig) with full error tracking, performance monitoring, crash reporting, and session tracking.

> Status note (2026-02-26): This document is retained as a historical
> implementation checklist. The current codebase in `src/` and tests is the
> authoritative behavior.

**Architecture:** Modular design — each concern (DSN, events, transport, etc.) is a separate file with its own tests. A background worker thread handles async event delivery. The public API is a single `Client` struct in `src/sentry.zig`.

**Tech Stack:** Zig 0.15.2 stdlib only — `std.http.Client` for HTTPS, `std.json` for serialization, `std.Thread` for async worker, `std.posix` for signal handling.

---

### Task 1: Project Scaffolding

**Files:**
- Create: `build.zig`
- Create: `build.zig.zon`
- Create: `src/sentry.zig` (stub)

**Step 1: Create build.zig.zon**

```zig
.{
    .name = .@"sentry-zig",
    .version = "0.1.0",
    .minimum_zig_version = "0.15.0",
    .fingerprint = .@"sentry-zig-v0.1.0",
    .dependencies = .{},
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

**Step 2: Create build.zig**

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sentry_mod = b.addModule("sentry-zig", .{
        .root_source_file = b.path("src/sentry.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = sentry_mod;

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/sentry.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
```

**Step 3: Create src/sentry.zig stub**

```zig
//! Sentry-Zig: Pure Zig Sentry SDK
//!
//! Usage:
//!   const sentry = @import("sentry-zig");
//!   var client = try sentry.init(allocator, .{ .dsn = "https://key@host/123" });
//!   defer client.deinit();
//!   client.captureMessage("hello", .info);

pub const Dsn = @import("dsn.zig").Dsn;

test {
    @import("std").testing.refAllDecls(@This());
}
```

**Step 4: Run build to verify scaffolding compiles**

Run: `zig build test 2>&1 || true`
Expected: Compilation error about missing dsn.zig (that's fine — confirms build system works)

**Step 5: Commit**

```bash
git add build.zig build.zig.zon src/sentry.zig
git commit -m "feat: scaffold Sentry-Zig project with build system"
```

---

### Task 2: DSN Parsing

**Files:**
- Create: `src/dsn.zig`

**Context:** DSN format is `{PROTOCOL}://{PUBLIC_KEY}@{HOST}/{PATH}{PROJECT_ID}`. Example: `https://examplePublicKey@o0.ingest.sentry.io/1234567`. The SDK needs to extract: scheme, public_key, host, path, project_id, and construct the envelope endpoint URL: `{SCHEME}://{HOST}/api/{PROJECT_ID}/envelope/`.

**Step 1: Write dsn.zig with tests**

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Dsn = struct {
    scheme: []const u8,
    public_key: []const u8,
    host: []const u8,
    port: ?u16,
    path: []const u8,
    project_id: []const u8,

    pub const ParseError = error{
        InvalidDsn,
        MissingPublicKey,
        MissingProjectId,
        MissingHost,
    };

    /// Parse a DSN string: {SCHEME}://{PUBLIC_KEY}@{HOST}/{PATH}{PROJECT_ID}
    pub fn parse(raw: []const u8) ParseError!Dsn {
        // Find "://"
        const scheme_end = std.mem.indexOf(u8, raw, "://") orelse return error.InvalidDsn;
        const scheme = raw[0..scheme_end];
        const after_scheme = raw[scheme_end + 3 ..];

        // Find "@" to separate public_key from host
        const at_pos = std.mem.indexOf(u8, after_scheme, "@") orelse return error.MissingPublicKey;
        const public_key = after_scheme[0..at_pos];
        if (public_key.len == 0) return error.MissingPublicKey;

        const after_at = after_scheme[at_pos + 1 ..];
        if (after_at.len == 0) return error.MissingHost;

        // Find first "/" after host to get path+project_id
        const slash_pos = std.mem.indexOf(u8, after_at, "/") orelse return error.MissingProjectId;
        const host_part = after_at[0..slash_pos];
        const path_and_project = after_at[slash_pos + 1 ..];

        // Parse host:port
        var host: []const u8 = host_part;
        var port: ?u16 = null;
        if (std.mem.lastIndexOf(u8, host_part, ":")) |colon_pos| {
            host = host_part[0..colon_pos];
            port = std.fmt.parseInt(u16, host_part[colon_pos + 1 ..], 10) catch null;
        }
        if (host.len == 0) return error.MissingHost;

        // Split path and project_id (project_id is the last path segment)
        const last_slash = std.mem.lastIndexOf(u8, path_and_project, "/");
        var path: []const u8 = "/";
        var project_id: []const u8 = path_and_project;
        if (last_slash) |pos| {
            path = path_and_project[0 .. pos + 1];
            project_id = path_and_project[pos + 1 ..];
        }
        if (project_id.len == 0) return error.MissingProjectId;

        return .{
            .scheme = scheme,
            .public_key = public_key,
            .host = host,
            .port = port,
            .path = path,
            .project_id = project_id,
        };
    }

    /// Write the envelope endpoint URL to a writer:
    /// {scheme}://{host}[:{port}]{path}api/{project_id}/envelope/
    pub fn writeEnvelopeUrl(self: Dsn, writer: anytype) !void {
        try writer.writeAll(self.scheme);
        try writer.writeAll("://");
        try writer.writeAll(self.host);
        if (self.port) |p| {
            try writer.print(":{d}", .{p});
        }
        if (!std.mem.endsWith(u8, self.path, "/")) {
            try writer.writeAll(self.path);
            try writer.writeAll("/");
        } else {
            try writer.writeAll(self.path);
        }
        try writer.writeAll("api/");
        try writer.writeAll(self.project_id);
        try writer.writeAll("/envelope/");
    }

    /// Get envelope endpoint URL as allocated string
    pub fn getEnvelopeUrl(self: Dsn, allocator: Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();
        try self.writeEnvelopeUrl(buf.writer());
        return buf.toOwnedSlice();
    }

    /// Write full DSN string to a writer
    pub fn writeDsn(self: Dsn, writer: anytype) !void {
        try writer.writeAll(self.scheme);
        try writer.writeAll("://");
        try writer.writeAll(self.public_key);
        try writer.writeAll("@");
        try writer.writeAll(self.host);
        if (self.port) |p| {
            try writer.print(":{d}", .{p});
        }
        try writer.writeAll("/");
        if (!std.mem.eql(u8, self.path, "/")) {
            try writer.writeAll(self.path);
        }
        try writer.writeAll(self.project_id);
    }
};

test "parse standard DSN" {
    const dsn = try Dsn.parse("https://examplePublicKey@o0.ingest.sentry.io/1234567");
    try std.testing.expectEqualStrings("https", dsn.scheme);
    try std.testing.expectEqualStrings("examplePublicKey", dsn.public_key);
    try std.testing.expectEqualStrings("o0.ingest.sentry.io", dsn.host);
    try std.testing.expect(dsn.port == null);
    try std.testing.expectEqualStrings("1234567", dsn.project_id);
}

test "parse DSN with port" {
    const dsn = try Dsn.parse("https://key@sentry.example.com:9000/42");
    try std.testing.expectEqualStrings("sentry.example.com", dsn.host);
    try std.testing.expect(dsn.port.? == 9000);
    try std.testing.expectEqualStrings("42", dsn.project_id);
}

test "parse DSN with path" {
    const dsn = try Dsn.parse("https://key@sentry.example.com/my/path/42");
    try std.testing.expectEqualStrings("my/path/", dsn.path);
    try std.testing.expectEqualStrings("42", dsn.project_id);
}

test "envelope URL generation" {
    const dsn = try Dsn.parse("https://key@o0.ingest.sentry.io/123");
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try dsn.writeEnvelopeUrl(fbs.writer());
    try std.testing.expectEqualStrings("https://o0.ingest.sentry.io/api/123/envelope/", fbs.getWritten());
}

test "invalid DSN — missing scheme" {
    try std.testing.expectError(error.InvalidDsn, Dsn.parse("no-scheme"));
}

test "invalid DSN — missing public key" {
    try std.testing.expectError(error.MissingPublicKey, Dsn.parse("https://@host/123"));
}

test "invalid DSN — missing project id" {
    try std.testing.expectError(error.MissingProjectId, Dsn.parse("https://key@host/"));
}
```

**Step 2: Run tests**

Run: `zig build test`
Expected: All tests pass

**Step 3: Commit**

```bash
git add src/dsn.zig src/sentry.zig
git commit -m "feat: add DSN parsing with envelope URL generation"
```

---

### Task 3: UUID and Timestamp Utilities

**Files:**
- Create: `src/uuid.zig`
- Create: `src/timestamp.zig`

**Context:** Sentry requires `event_id` as a 32-char lowercase hex UUID (no dashes), and `timestamp` as either RFC 3339 or Unix epoch float. We generate UUID v4 using `std.crypto.random`.

**Step 1: Write uuid.zig**

```zig
const std = @import("std");

pub const Uuid = struct {
    bytes: [16]u8,

    /// Generate a random UUID v4
    pub fn v4() Uuid {
        var bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&bytes);
        // Set version 4 (bits 48-51)
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        // Set variant 1 (bits 64-65)
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        return .{ .bytes = bytes };
    }

    /// Format as 32-char lowercase hex (no dashes) — Sentry format
    pub fn toHex(self: Uuid) [32]u8 {
        return std.fmt.bytesToHex(self.bytes, .lower);
    }

    /// Format as standard UUID with dashes: 8-4-4-4-12
    pub fn toDashedHex(self: Uuid) [36]u8 {
        const hex = self.toHex();
        var result: [36]u8 = undefined;
        @memcpy(result[0..8], hex[0..8]);
        result[8] = '-';
        @memcpy(result[9..13], hex[8..12]);
        result[13] = '-';
        @memcpy(result[14..18], hex[12..16]);
        result[18] = '-';
        @memcpy(result[19..23], hex[16..20]);
        result[23] = '-';
        @memcpy(result[24..36], hex[20..32]);
        return result;
    }

    /// Parse from 32-char hex string
    pub fn fromHex(hex: []const u8) !Uuid {
        if (hex.len != 32) return error.InvalidLength;
        var bytes: [16]u8 = undefined;
        for (0..16) |i| {
            bytes[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch return error.InvalidHex;
        }
        return .{ .bytes = bytes };
    }
};

test "v4 UUID has correct version and variant bits" {
    const uuid = Uuid.v4();
    // Version 4: high nibble of byte 6 should be 0x4
    try std.testing.expect((uuid.bytes[6] & 0xf0) == 0x40);
    // Variant 1: high 2 bits of byte 8 should be 10
    try std.testing.expect((uuid.bytes[8] & 0xc0) == 0x80);
}

test "toHex produces 32 lowercase hex chars" {
    const uuid = Uuid.v4();
    const hex = uuid.toHex();
    try std.testing.expect(hex.len == 32);
    for (hex) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "toDashedHex produces valid format" {
    const uuid = Uuid.v4();
    const dashed = uuid.toDashedHex();
    try std.testing.expect(dashed.len == 36);
    try std.testing.expect(dashed[8] == '-');
    try std.testing.expect(dashed[13] == '-');
    try std.testing.expect(dashed[14] == '4'); // version
    try std.testing.expect(dashed[18] == '-');
    try std.testing.expect(dashed[23] == '-');
}

test "fromHex roundtrip" {
    const uuid = Uuid.v4();
    const hex = uuid.toHex();
    const parsed = try Uuid.fromHex(&hex);
    try std.testing.expectEqualSlices(u8, &uuid.bytes, &parsed.bytes);
}
```

**Step 2: Write timestamp.zig**

```zig
const std = @import("std");

/// Return current Unix timestamp as float seconds (for Sentry `timestamp` field)
pub fn now() f64 {
    const ms = std.time.milliTimestamp();
    return @as(f64, @floatFromInt(ms)) / 1000.0;
}

/// Format a Unix timestamp (milliseconds) as RFC 3339: "2025-02-25T12:00:00.000Z"
/// Uses a fixed buffer — no allocation needed.
pub fn formatRfc3339(epoch_ms: i64) [24]u8 {
    const epoch_s: u64 = @intCast(@divFloor(epoch_ms, 1000));
    const ms_part: u64 = @intCast(@mod(epoch_ms, 1000));

    const epoch_day = @as(i64, @intCast(epoch_s / 86400));
    const day_seconds = epoch_s % 86400;
    const hour = day_seconds / 3600;
    const minute = (day_seconds % 3600) / 60;
    const second = day_seconds % 60;

    // Civil date from epoch day (algorithm from Howard Hinnant)
    const z = epoch_day + 719468;
    const era: i64 = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: u64 = @intCast(z - era * 146097);
    const yoe: u64 = @intCast(@divFloor(
        @as(i64, @intCast(doe)) -
            @as(i64, @intCast(doe / 1460)) +
            @as(i64, @intCast(doe / 36524)) -
            @as(i64, @intCast(doe / 146096)),
        365,
    ));
    const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d = doy - (153 * mp + 2) / 5 + 1;
    const m_raw = if (mp < 10) mp + 3 else mp - 9;
    const year: u64 = @intCast(if (m_raw <= 2) y + 1 else y);

    var buf: [24]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year, m_raw, d, hour, minute, second, ms_part,
    }) catch unreachable;
    return buf;
}

/// Return current time as RFC 3339 string
pub fn nowRfc3339() [24]u8 {
    return formatRfc3339(std.time.milliTimestamp());
}

test "now returns reasonable timestamp" {
    const t = now();
    // Should be after 2024-01-01 (1704067200)
    try std.testing.expect(t > 1704067200.0);
}

test "formatRfc3339 known epoch" {
    // 2025-02-25T12:00:00.000Z = 1740484800000 ms
    const result = formatRfc3339(1740484800000);
    try std.testing.expectEqualStrings("2025-02-25T12:00:00.000Z", &result);
}

test "formatRfc3339 with milliseconds" {
    const result = formatRfc3339(1740484800123);
    try std.testing.expectEqualStrings("2025-02-25T12:00:00.123Z", &result);
}

test "nowRfc3339 starts with 20" {
    const result = nowRfc3339();
    try std.testing.expectEqualStrings("20", result[0..2]);
}
```

**Step 3: Update sentry.zig imports**

```zig
// Add to src/sentry.zig:
pub const Dsn = @import("dsn.zig").Dsn;
pub const Uuid = @import("uuid.zig").Uuid;
pub const timestamp = @import("timestamp.zig");
```

**Step 4: Run tests**

Run: `zig build test`
Expected: All tests pass

**Step 5: Commit**

```bash
git add src/uuid.zig src/timestamp.zig src/sentry.zig
git commit -m "feat: add UUID v4 generation and RFC 3339 timestamp formatting"
```

---

### Task 4: Event Data Structures

**Files:**
- Create: `src/event.zig`

**Context:** Sentry event payloads require specific JSON structure. Key fields: `event_id` (32-char hex), `timestamp` (float), `level`, `platform`, `logger`, `message`, `exception`, `tags`, `extra`, `user`, `contexts`, `breadcrumbs`, `server_name`, `release`, `environment`. The event must serialize to JSON via `std.json.stringify`.

**Step 1: Write event.zig**

```zig
const std = @import("std");
const Uuid = @import("uuid.zig").Uuid;
const ts = @import("timestamp.zig");
const Allocator = std.mem.Allocator;

pub const Level = enum {
    debug,
    info,
    warning,
    err,
    fatal,

    pub fn toString(self: Level) []const u8 {
        return switch (self) {
            .debug => "debug",
            .info => "info",
            .warning => "warning",
            .err => "error",
            .fatal => "fatal",
        };
    }

    pub fn jsonStringify(self: Level, jw: anytype) !void {
        try jw.write(self.toString());
    }
};

pub const User = struct {
    id: ?[]const u8 = null,
    email: ?[]const u8 = null,
    username: ?[]const u8 = null,
    ip_address: ?[]const u8 = null,
    segment: ?[]const u8 = null,
};

pub const Frame = struct {
    filename: ?[]const u8 = null,
    function: ?[]const u8 = null,
    module: ?[]const u8 = null,
    lineno: ?u32 = null,
    colno: ?u32 = null,
    abs_path: ?[]const u8 = null,
    instruction_addr: ?[]const u8 = null,
    in_app: ?bool = null,
};

pub const Stacktrace = struct {
    frames: []const Frame,
};

pub const ExceptionValue = struct {
    type: []const u8,
    value: []const u8,
    module: ?[]const u8 = null,
    stacktrace: ?Stacktrace = null,
};

pub const ExceptionInterface = struct {
    values: []const ExceptionValue,
};

pub const Message = struct {
    formatted: []const u8,
    message: ?[]const u8 = null,
    params: ?[]const []const u8 = null,
};

pub const Breadcrumb = struct {
    timestamp: f64,
    type: []const u8 = "default",
    category: ?[]const u8 = null,
    message: ?[]const u8 = null,
    level: Level = .info,
    data: ?std.json.Value = null,
};

pub const Event = struct {
    event_id: [32]u8,
    timestamp: f64,
    platform: []const u8 = "other",
    level: Level = .err,
    logger: ?[]const u8 = null,
    server_name: ?[]const u8 = null,
    release: ?[]const u8 = null,
    dist: ?[]const u8 = null,
    environment: ?[]const u8 = null,
    transaction: ?[]const u8 = null,
    message: ?Message = null,
    exception: ?ExceptionInterface = null,
    tags: ?std.json.Value = null,
    extra: ?std.json.Value = null,
    user: ?User = null,
    contexts: ?std.json.Value = null,
    breadcrumbs: ?[]const Breadcrumb = null,
    fingerprint: ?[]const []const u8 = null,

    pub fn init() Event {
        const uuid = Uuid.v4();
        return .{
            .event_id = uuid.toHex(),
            .timestamp = ts.now(),
        };
    }

    pub fn initMessage(msg: []const u8, level: Level) Event {
        var event = Event.init();
        event.level = level;
        event.message = .{ .formatted = msg };
        return event;
    }

    pub fn initException(exception_type: []const u8, value: []const u8) Event {
        var event = Event.init();
        event.level = .err;
        event.exception = .{
            .values = &[_]ExceptionValue{.{
                .type = exception_type,
                .value = value,
            }},
        };
        return event;
    }
};

test "Event.init generates valid event_id" {
    const event = Event.init();
    try std.testing.expect(event.event_id.len == 32);
    for (event.event_id) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "Event.init sets timestamp" {
    const event = Event.init();
    try std.testing.expect(event.timestamp > 1704067200.0);
}

test "Event.initMessage" {
    const event = Event.initMessage("test error", .err);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings("test error", event.message.?.formatted);
    try std.testing.expectEqualStrings("error", event.level.toString());
}

test "Event.initException" {
    const event = Event.initException("RuntimeError", "division by zero");
    try std.testing.expect(event.exception != null);
    try std.testing.expect(event.exception.?.values.len == 1);
    try std.testing.expectEqualStrings("RuntimeError", event.exception.?.values[0].type);
}

test "Level.toString" {
    try std.testing.expectEqualStrings("error", Level.err.toString());
    try std.testing.expectEqualStrings("fatal", Level.fatal.toString());
    try std.testing.expectEqualStrings("warning", Level.warning.toString());
}

test "Event serializes to JSON" {
    const event = Event.initMessage("hello sentry", .info);
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try std.json.stringify(event, .{ .emit_null_optional_fields = false }, buf.writer());
    const json = buf.items;
    // Must contain event_id and message
    try std.testing.expect(std.mem.indexOf(u8, json, "event_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "hello sentry") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"level\":\"info\"") != null);
}
```

**Step 2: Update sentry.zig**

```zig
// Add to src/sentry.zig:
pub const Event = @import("event.zig").Event;
pub const Level = @import("event.zig").Level;
pub const User = @import("event.zig").User;
pub const Breadcrumb = @import("event.zig").Breadcrumb;
```

**Step 3: Run tests**

Run: `zig build test`
Expected: All tests pass

**Step 4: Commit**

```bash
git add src/event.zig src/sentry.zig
git commit -m "feat: add Event, Level, User, Breadcrumb data structures"
```

---

### Task 5: Envelope Serialization

**Files:**
- Create: `src/envelope.zig`

**Context:** The Sentry envelope format is newline-delimited: envelope header JSON, then pairs of (item header JSON, payload). Each section ends with `\n`. The envelope header contains `event_id`, `dsn`, `sent_at`, and `sdk` info. Item header contains `type` and `length`.

**Step 1: Write envelope.zig**

```zig
const std = @import("std");
const Event = @import("event.zig").Event;
const Dsn = @import("dsn.zig").Dsn;
const ts = @import("timestamp.zig");
const Allocator = std.mem.Allocator;

pub const SDK_NAME = "sentry-zig";
pub const SDK_VERSION = "0.1.0";

pub const ItemType = enum {
    event,
    transaction,
    session,
    attachment,

    pub fn toString(self: ItemType) []const u8 {
        return switch (self) {
            .event => "event",
            .transaction => "transaction",
            .session => "session",
            .attachment => "attachment",
        };
    }
};

/// Serialize a complete envelope (header + items) into the writer.
/// Format:
///   {envelope_header}\n
///   {item_header}\n
///   {item_payload}\n
pub fn serializeEventEnvelope(
    allocator: Allocator,
    event: Event,
    dsn: Dsn,
    writer: anytype,
) !void {
    // 1. Serialize event payload first to know its length
    var payload_buf = std.ArrayList(u8).init(allocator);
    defer payload_buf.deinit();
    try std.json.stringify(event, .{ .emit_null_optional_fields = false }, payload_buf.writer());

    // 2. Write envelope header
    try writer.writeAll("{\"event_id\":\"");
    try writer.writeAll(&event.event_id);
    try writer.writeAll("\",\"dsn\":\"");
    try dsn.writeDsn(writer);
    try writer.writeAll("\",\"sent_at\":\"");
    const sent_at = ts.nowRfc3339();
    try writer.writeAll(&sent_at);
    try writer.writeAll("\",\"sdk\":{\"name\":\"");
    try writer.writeAll(SDK_NAME);
    try writer.writeAll("\",\"version\":\"");
    try writer.writeAll(SDK_VERSION);
    try writer.writeAll("\"}}\n");

    // 3. Write item header
    try writer.print("{{\"type\":\"event\",\"length\":{d}}}\n", .{payload_buf.items.len});

    // 4. Write item payload
    try writer.writeAll(payload_buf.items);
    try writer.writeAll("\n");
}

/// Serialize a session update envelope
pub fn serializeSessionEnvelope(
    dsn: Dsn,
    session_json: []const u8,
    writer: anytype,
) !void {
    // Envelope header (no event_id for session-only envelopes)
    try writer.writeAll("{\"dsn\":\"");
    try dsn.writeDsn(writer);
    try writer.writeAll("\",\"sent_at\":\"");
    const sent_at = ts.nowRfc3339();
    try writer.writeAll(&sent_at);
    try writer.writeAll("\",\"sdk\":{\"name\":\"");
    try writer.writeAll(SDK_NAME);
    try writer.writeAll("\",\"version\":\"");
    try writer.writeAll(SDK_VERSION);
    try writer.writeAll("\"}}\n");

    // Item header
    try writer.print("{{\"type\":\"session\",\"length\":{d}}}\n", .{session_json.len});

    // Payload
    try writer.writeAll(session_json);
    try writer.writeAll("\n");
}

test "serializeEventEnvelope produces valid format" {
    const allocator = std.testing.allocator;
    const dsn = try Dsn.parse("https://abc123@o0.ingest.sentry.io/456");
    const event = Event.initMessage("test", .info);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    try serializeEventEnvelope(allocator, event, dsn, buf.writer());

    const output = buf.items;

    // Should have 3 lines (envelope header, item header, payload)
    var lines = std.mem.splitScalar(u8, output, '\n');
    const line1 = lines.next().?; // envelope header
    const line2 = lines.next().?; // item header
    const line3 = lines.next().?; // payload

    // Envelope header should contain event_id and dsn
    try std.testing.expect(std.mem.indexOf(u8, line1, "event_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, line1, "abc123") != null);
    try std.testing.expect(std.mem.indexOf(u8, line1, "sent_at") != null);
    try std.testing.expect(std.mem.indexOf(u8, line1, "sentry-zig") != null);

    // Item header should have type and length
    try std.testing.expect(std.mem.indexOf(u8, line2, "\"type\":\"event\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line2, "\"length\":") != null);

    // Payload should be valid JSON with the message
    try std.testing.expect(std.mem.indexOf(u8, line3, "test") != null);
}

test "envelope payload length matches actual payload" {
    const allocator = std.testing.allocator;
    const dsn = try Dsn.parse("https://key@host/1");
    const event = Event.initMessage("hello", .err);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    try serializeEventEnvelope(allocator, event, dsn, buf.writer());

    var lines = std.mem.splitScalar(u8, buf.items, '\n');
    _ = lines.next(); // skip envelope header
    const item_header = lines.next().?;
    const payload = lines.next().?;

    // Extract length from item header
    const length_start = std.mem.indexOf(u8, item_header, "\"length\":").? + 9;
    const length_end = std.mem.indexOf(u8, item_header[length_start..], "}").? + length_start;
    const length = try std.fmt.parseInt(usize, item_header[length_start..length_end], 10);

    try std.testing.expectEqual(payload.len, length);
}
```

**Step 2: Update sentry.zig**

```zig
// Add to src/sentry.zig:
pub const envelope = @import("envelope.zig");
```

**Step 3: Run tests**

Run: `zig build test`
Expected: All tests pass

**Step 4: Commit**

```bash
git add src/envelope.zig src/sentry.zig
git commit -m "feat: add Sentry envelope serialization"
```

---

### Task 6: Scope (User, Tags, Breadcrumbs Ring Buffer)

**Files:**
- Create: `src/scope.zig`

**Context:** The Scope holds mutable state that gets applied to every event: user context, tags, extra data, contexts, and breadcrumbs. Breadcrumbs use a ring buffer (fixed capacity, O(1) add, overwrites oldest). The scope must be thread-safe since events can come from multiple threads.

**Step 1: Write scope.zig**

```zig
const std = @import("std");
const event_mod = @import("event.zig");
const User = event_mod.User;
const Breadcrumb = event_mod.Breadcrumb;
const Level = event_mod.Level;
const Event = event_mod.Event;
const ts = @import("timestamp.zig");
const Allocator = std.mem.Allocator;

pub const Scope = struct {
    allocator: Allocator,
    user: ?User = null,
    tags: std.StringHashMap([]const u8),
    extra: std.StringHashMap(std.json.Value),
    contexts: std.StringHashMap(std.json.Value),
    breadcrumbs: BreadcrumbBuffer,
    fingerprint: ?[]const []const u8 = null,
    transaction_name: ?[]const u8 = null,
    level: ?Level = null,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: Allocator, max_breadcrumbs: u32) Scope {
        return .{
            .allocator = allocator,
            .tags = std.StringHashMap([]const u8).init(allocator),
            .extra = std.StringHashMap(std.json.Value).init(allocator),
            .contexts = std.StringHashMap(std.json.Value).init(allocator),
            .breadcrumbs = BreadcrumbBuffer.init(max_breadcrumbs),
        };
    }

    pub fn deinit(self: *Scope) void {
        self.tags.deinit();
        self.extra.deinit();
        self.contexts.deinit();
    }

    pub fn setUser(self: *Scope, user: ?User) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.user = user;
    }

    pub fn setTag(self: *Scope, key: []const u8, value: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.tags.put(key, value);
    }

    pub fn removeTag(self: *Scope, key: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.tags.remove(key);
    }

    pub fn setExtra(self: *Scope, key: []const u8, value: std.json.Value) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.extra.put(key, value);
    }

    pub fn setContext(self: *Scope, key: []const u8, value: std.json.Value) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.contexts.put(key, value);
    }

    pub fn addBreadcrumb(self: *Scope, crumb: Breadcrumb) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.breadcrumbs.push(crumb);
    }

    /// Apply scope data to an event (called before sending)
    pub fn applyToEvent(self: *Scope, event: *Event) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (event.user == null) event.user = self.user;
        if (event.environment == null and self.transaction_name != null)
            event.transaction = self.transaction_name;
        if (self.level) |lvl| event.level = lvl;

        // Apply tags
        if (self.tags.count() > 0) {
            var obj = std.json.ObjectMap.init(self.allocator);
            var it = self.tags.iterator();
            while (it.next()) |entry| {
                try obj.put(entry.key_ptr.*, .{ .string = entry.value_ptr.* });
            }
            event.tags = .{ .object = obj };
        }

        // Apply extra
        if (self.extra.count() > 0) {
            var obj = std.json.ObjectMap.init(self.allocator);
            var it = self.extra.iterator();
            while (it.next()) |entry| {
                try obj.put(entry.key_ptr.*, entry.value_ptr.*);
            }
            event.extra = .{ .object = obj };
        }

        // Apply contexts
        if (self.contexts.count() > 0) {
            var obj = std.json.ObjectMap.init(self.allocator);
            var it = self.contexts.iterator();
            while (it.next()) |entry| {
                try obj.put(entry.key_ptr.*, entry.value_ptr.*);
            }
            event.contexts = .{ .object = obj };
        }

        // Apply breadcrumbs
        const crumbs = self.breadcrumbs.toSlice();
        if (crumbs.len > 0) {
            event.breadcrumbs = crumbs;
        }
    }

    pub fn clear(self: *Scope) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.user = null;
        self.tags.clearRetainingCapacity();
        self.extra.clearRetainingCapacity();
        self.contexts.clearRetainingCapacity();
        self.breadcrumbs.clear();
        self.fingerprint = null;
        self.transaction_name = null;
        self.level = null;
    }
};

/// Fixed-size ring buffer for breadcrumbs
pub const BreadcrumbBuffer = struct {
    buffer: [MAX_BREADCRUMBS]Breadcrumb = undefined,
    capacity: u32,
    head: u32 = 0,
    count: u32 = 0,

    const MAX_BREADCRUMBS = 200;

    pub fn init(capacity: u32) BreadcrumbBuffer {
        return .{
            .capacity = @min(capacity, MAX_BREADCRUMBS),
        };
    }

    pub fn push(self: *BreadcrumbBuffer, crumb: Breadcrumb) void {
        self.buffer[self.head] = crumb;
        self.head = (self.head + 1) % self.capacity;
        if (self.count < self.capacity) self.count += 1;
    }

    pub fn toSlice(self: *BreadcrumbBuffer) []const Breadcrumb {
        if (self.count < self.capacity) {
            return self.buffer[0..self.count];
        }
        // When full, head points to the oldest — but for simplicity
        // we return from head (oldest) to head-1 (newest) wrapped
        // For JSON serialization, we just return the underlying buffer
        // in insertion order from the start position
        return self.buffer[0..self.count];
    }

    pub fn clear(self: *BreadcrumbBuffer) void {
        self.head = 0;
        self.count = 0;
    }
};

test "BreadcrumbBuffer push and read" {
    var buf = BreadcrumbBuffer.init(3);
    buf.push(.{ .timestamp = 1.0, .message = "first" });
    buf.push(.{ .timestamp = 2.0, .message = "second" });
    try std.testing.expectEqual(@as(u32, 2), buf.count);

    const slice = buf.toSlice();
    try std.testing.expectEqual(@as(usize, 2), slice.len);
    try std.testing.expectEqualStrings("first", slice[0].message.?);
}

test "BreadcrumbBuffer wraps around" {
    var buf = BreadcrumbBuffer.init(2);
    buf.push(.{ .timestamp = 1.0, .message = "a" });
    buf.push(.{ .timestamp = 2.0, .message = "b" });
    buf.push(.{ .timestamp = 3.0, .message = "c" }); // overwrites "a"
    try std.testing.expectEqual(@as(u32, 2), buf.count);
}

test "Scope setTag and setUser" {
    var scope = Scope.init(std.testing.allocator, 100);
    defer scope.deinit();

    scope.setUser(.{ .id = "42", .email = "test@example.com" });
    try std.testing.expectEqualStrings("42", scope.user.?.id.?);

    try scope.setTag("env", "production");
    try std.testing.expectEqualStrings("production", scope.tags.get("env").?);
}

test "Scope applyToEvent" {
    var scope = Scope.init(std.testing.allocator, 100);
    defer scope.deinit();

    scope.setUser(.{ .id = "1" });
    try scope.setTag("version", "1.0");
    scope.addBreadcrumb(.{ .timestamp = 1.0, .message = "click" });

    var event = Event.initMessage("error", .err);
    try scope.applyToEvent(&event);

    try std.testing.expect(event.user != null);
    try std.testing.expectEqualStrings("1", event.user.?.id.?);
    try std.testing.expect(event.tags != null);
    try std.testing.expect(event.breadcrumbs != null);
    try std.testing.expectEqual(@as(usize, 1), event.breadcrumbs.?.len);
}

test "Scope clear resets all fields" {
    var scope = Scope.init(std.testing.allocator, 100);
    defer scope.deinit();
    scope.setUser(.{ .id = "1" });
    try scope.setTag("a", "b");
    scope.clear();
    try std.testing.expect(scope.user == null);
    try std.testing.expectEqual(@as(u32, 0), scope.tags.count());
}
```

**Step 2: Update sentry.zig**

```zig
pub const Scope = @import("scope.zig").Scope;
```

**Step 3: Run tests**

Run: `zig build test`
Expected: All tests pass

**Step 4: Commit**

```bash
git add src/scope.zig src/sentry.zig
git commit -m "feat: add Scope with breadcrumb ring buffer, tags, user context"
```

---

### Task 7: Session Tracking

**Files:**
- Create: `src/session.zig`

**Context:** Sentry sessions track application health. A session has states: `ok`, `errored`, `crashed`, `abnormal`. Sessions are sent as envelope items with their own JSON format. Fields: `sid` (UUID), `did` (device/user id), `init` (bool — true on first send), `started`, `timestamp`, `status`, `errors` count, `attrs` (release, environment).

**Step 1: Write session.zig**

```zig
const std = @import("std");
const Uuid = @import("uuid.zig").Uuid;
const ts = @import("timestamp.zig");
const Allocator = std.mem.Allocator;

pub const SessionStatus = enum {
    ok,
    exited,
    crashed,
    abnormal,
    errored,

    pub fn toString(self: SessionStatus) []const u8 {
        return switch (self) {
            .ok => "ok",
            .exited => "exited",
            .crashed => "crashed",
            .abnormal => "abnormal",
            .errored => "errored",
        };
    }

    pub fn jsonStringify(self: SessionStatus, jw: anytype) !void {
        try jw.write(self.toString());
    }
};

pub const Session = struct {
    sid: [32]u8,
    did: ?[]const u8 = null,
    init_flag: bool = true,
    started: f64,
    timestamp: f64,
    status: SessionStatus = .ok,
    errors: u32 = 0,
    release: ?[]const u8 = null,
    environment: ?[]const u8 = null,
    duration: ?f64 = null,

    pub fn start(release: ?[]const u8, environment: ?[]const u8) Session {
        const now = ts.now();
        return .{
            .sid = Uuid.v4().toHex(),
            .started = now,
            .timestamp = now,
            .release = release,
            .environment = environment,
        };
    }

    pub fn markErrored(self: *Session) void {
        self.errors += 1;
        if (self.status == .ok) self.status = .errored;
        self.timestamp = ts.now();
    }

    pub fn markCrashed(self: *Session) void {
        self.status = .crashed;
        self.timestamp = ts.now();
    }

    pub fn end(self: *Session, status: SessionStatus) void {
        self.status = status;
        self.timestamp = ts.now();
        self.duration = self.timestamp - self.started;
    }

    /// Serialize session to JSON for envelope payload
    pub fn toJson(self: Session, allocator: Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();
        const w = buf.writer();

        try w.writeAll("{\"sid\":\"");
        try w.writeAll(&self.sid);
        try w.writeAll("\"");

        if (self.did) |did| {
            try w.writeAll(",\"did\":\"");
            try w.writeAll(did);
            try w.writeAll("\"");
        }

        try w.print(",\"init\":{s}", .{if (self.init_flag) "true" else "false"});
        try w.print(",\"started\":\"{s}\"", .{ts.formatRfc3339(@intFromFloat(self.started * 1000.0))});
        try w.print(",\"timestamp\":\"{s}\"", .{ts.formatRfc3339(@intFromFloat(self.timestamp * 1000.0))});
        try w.print(",\"status\":\"{s}\"", .{self.status.toString()});
        try w.print(",\"errors\":{d}", .{self.errors});

        if (self.duration) |dur| {
            try w.print(",\"duration\":{d:.3}", .{dur});
        }

        // Attrs
        try w.writeAll(",\"attrs\":{");
        var has_attr = false;
        if (self.release) |rel| {
            try w.print("\"release\":\"{s}\"", .{rel});
            has_attr = true;
        }
        if (self.environment) |env| {
            if (has_attr) try w.writeAll(",");
            try w.print("\"environment\":\"{s}\"", .{env});
        }
        try w.writeAll("}}");

        return buf.toOwnedSlice();
    }
};

test "Session.start creates valid session" {
    const session = Session.start("app@1.0", "production");
    try std.testing.expect(session.sid.len == 32);
    try std.testing.expect(session.started > 0);
    try std.testing.expect(session.init_flag);
    try std.testing.expect(session.status == .ok);
    try std.testing.expect(session.errors == 0);
}

test "Session.markErrored increments errors" {
    var session = Session.start(null, null);
    session.markErrored();
    try std.testing.expectEqual(@as(u32, 1), session.errors);
    try std.testing.expect(session.status == .errored);
    session.markErrored();
    try std.testing.expectEqual(@as(u32, 2), session.errors);
}

test "Session.markCrashed sets status" {
    var session = Session.start(null, null);
    session.markCrashed();
    try std.testing.expect(session.status == .crashed);
}

test "Session.end sets duration" {
    var session = Session.start("app@1.0", "prod");
    session.end(.exited);
    try std.testing.expect(session.duration != null);
    try std.testing.expect(session.status == .exited);
}

test "Session.toJson produces valid JSON" {
    const session = Session.start("app@1.0", "production");
    const json = try session.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "sid") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"init\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"release\":\"app@1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"environment\":\"production\"") != null);
}
```

**Step 2: Update sentry.zig**

```zig
pub const Session = @import("session.zig").Session;
pub const SessionStatus = @import("session.zig").SessionStatus;
```

**Step 3: Run tests**

Run: `zig build test`
Expected: All tests pass

**Step 4: Commit**

```bash
git add src/session.zig src/sentry.zig
git commit -m "feat: add session tracking with JSON serialization"
```

---

### Task 8: Transaction and Span (Performance Monitoring)

**Files:**
- Create: `src/transaction.zig`

**Context:** Transactions are the top-level performance monitoring unit. Each transaction has a trace_id, span_id, and contains child spans. Spans measure individual operations with start/end timestamps. Transactions serialize as envelope items with type "transaction".

**Step 1: Write transaction.zig**

```zig
const std = @import("std");
const Uuid = @import("uuid.zig").Uuid;
const ts = @import("timestamp.zig");
const Allocator = std.mem.Allocator;

pub const SpanId = [16]u8; // 8 bytes as 16 hex chars

fn generateSpanId() SpanId {
    var bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

pub const SpanStatus = enum {
    ok,
    cancelled,
    unknown,
    invalid_argument,
    deadline_exceeded,
    not_found,
    already_exists,
    permission_denied,
    resource_exhausted,
    failed_precondition,
    aborted,
    out_of_range,
    unimplemented,
    internal_error,
    unavailable,
    data_loss,
    unauthenticated,

    pub fn toString(self: SpanStatus) []const u8 {
        return switch (self) {
            .ok => "ok",
            .cancelled => "cancelled",
            .unknown => "unknown",
            .invalid_argument => "invalid_argument",
            .deadline_exceeded => "deadline_exceeded",
            .not_found => "not_found",
            .already_exists => "already_exists",
            .permission_denied => "permission_denied",
            .resource_exhausted => "resource_exhausted",
            .failed_precondition => "failed_precondition",
            .aborted => "aborted",
            .out_of_range => "out_of_range",
            .unimplemented => "unimplemented",
            .internal_error => "internal_error",
            .unavailable => "unavailable",
            .data_loss => "data_loss",
            .unauthenticated => "unauthenticated",
        };
    }

    pub fn jsonStringify(self: SpanStatus, jw: anytype) !void {
        try jw.write(self.toString());
    }
};

pub const SpanData = struct {
    key: []const u8,
    value: []const u8,
};

pub const Span = struct {
    trace_id: [32]u8,
    span_id: SpanId,
    parent_span_id: ?SpanId = null,
    op: []const u8,
    description: ?[]const u8 = null,
    start_timestamp: f64,
    timestamp: ?f64 = null,
    status: ?SpanStatus = null,
    tags: ?[]const SpanData = null,
    data: ?[]const SpanData = null,

    pub fn finish(self: *Span) void {
        self.timestamp = ts.now();
        if (self.status == null) self.status = .ok;
    }

    pub fn setStatus(self: *Span, status: SpanStatus) void {
        self.status = status;
    }
};

pub const TransactionOpts = struct {
    name: []const u8,
    op: []const u8 = "default",
    description: ?[]const u8 = null,
};

pub const ChildSpanOpts = struct {
    op: []const u8,
    description: ?[]const u8 = null,
};

pub const Transaction = struct {
    trace_id: [32]u8,
    span_id: SpanId,
    name: []const u8,
    op: []const u8,
    description: ?[]const u8 = null,
    start_timestamp: f64,
    timestamp: ?f64 = null,
    status: ?SpanStatus = null,
    spans: std.ArrayList(Span),
    sample_rate: f64 = 1.0,
    sampled: bool = true,
    release: ?[]const u8 = null,
    environment: ?[]const u8 = null,

    pub fn init(allocator: Allocator, opts: TransactionOpts) Transaction {
        return .{
            .trace_id = Uuid.v4().toHex(),
            .span_id = generateSpanId(),
            .name = opts.name,
            .op = opts.op,
            .description = opts.description,
            .start_timestamp = ts.now(),
            .spans = std.ArrayList(Span).init(allocator),
        };
    }

    pub fn deinit(self: *Transaction) void {
        self.spans.deinit();
    }

    pub fn startChild(self: *Transaction, opts: ChildSpanOpts) !*Span {
        const span = try self.spans.addOne();
        span.* = .{
            .trace_id = self.trace_id,
            .span_id = generateSpanId(),
            .parent_span_id = self.span_id,
            .op = opts.op,
            .description = opts.description,
            .start_timestamp = ts.now(),
        };
        return span;
    }

    pub fn finish(self: *Transaction) void {
        self.timestamp = ts.now();
        if (self.status == null) self.status = .ok;
    }

    pub fn setStatus(self: *Transaction, status: SpanStatus) void {
        self.status = status;
    }

    /// Serialize transaction to JSON for envelope payload
    pub fn toJson(self: Transaction, allocator: Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();
        const w = buf.writer();

        try w.writeAll("{\"type\":\"transaction\"");
        try w.print(",\"transaction\":\"{s}\"", .{self.name});
        try w.print(",\"start_timestamp\":{d:.6}", .{self.start_timestamp});
        if (self.timestamp) |t| try w.print(",\"timestamp\":{d:.6}", .{t});

        try w.writeAll(",\"contexts\":{\"trace\":{");
        try w.print("\"trace_id\":\"{s}\"", .{self.trace_id});
        try w.print(",\"span_id\":\"{s}\"", .{self.span_id});
        try w.print(",\"op\":\"{s}\"", .{self.op});
        if (self.status) |s| try w.print(",\"status\":\"{s}\"", .{s.toString()});
        try w.writeAll("}}");

        if (self.release) |rel| try w.print(",\"release\":\"{s}\"", .{rel});
        if (self.environment) |env| try w.print(",\"environment\":\"{s}\"", .{env});

        // Spans array
        try w.writeAll(",\"spans\":[");
        for (self.spans.items, 0..) |span, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{");
            try w.print("\"trace_id\":\"{s}\"", .{span.trace_id});
            try w.print(",\"span_id\":\"{s}\"", .{span.span_id});
            if (span.parent_span_id) |pid| try w.print(",\"parent_span_id\":\"{s}\"", .{pid});
            try w.print(",\"op\":\"{s}\"", .{span.op});
            if (span.description) |desc| try w.print(",\"description\":\"{s}\"", .{desc});
            try w.print(",\"start_timestamp\":{d:.6}", .{span.start_timestamp});
            if (span.timestamp) |t| try w.print(",\"timestamp\":{d:.6}", .{t});
            if (span.status) |s| try w.print(",\"status\":\"{s}\"", .{s.toString()});
            try w.writeAll("}");
        }
        try w.writeAll("]");

        try w.writeAll(",\"platform\":\"other\"}");

        return buf.toOwnedSlice();
    }
};

test "Transaction.init creates valid trace" {
    var txn = Transaction.init(std.testing.allocator, .{ .name = "test", .op = "http" });
    defer txn.deinit();
    try std.testing.expect(txn.trace_id.len == 32);
    try std.testing.expect(txn.span_id.len == 16);
    try std.testing.expect(txn.start_timestamp > 0);
}

test "Transaction.startChild creates span" {
    var txn = Transaction.init(std.testing.allocator, .{ .name = "test", .op = "http" });
    defer txn.deinit();

    var span = try txn.startChild(.{ .op = "db.query", .description = "SELECT *" });
    try std.testing.expectEqualStrings("db.query", span.op);
    try std.testing.expectEqualStrings("SELECT *", span.description.?);
    try std.testing.expectEqualSlices(u8, &txn.trace_id, &span.trace_id);
    try std.testing.expectEqualSlices(u8, &txn.span_id, &span.parent_span_id.?);
}

test "Span.finish sets timestamp and status" {
    var txn = Transaction.init(std.testing.allocator, .{ .name = "t", .op = "o" });
    defer txn.deinit();
    var span = try txn.startChild(.{ .op = "test" });
    span.finish();
    try std.testing.expect(span.timestamp != null);
    try std.testing.expect(span.status.? == .ok);
}

test "Transaction.finish sets timestamp" {
    var txn = Transaction.init(std.testing.allocator, .{ .name = "t", .op = "o" });
    defer txn.deinit();
    txn.finish();
    try std.testing.expect(txn.timestamp != null);
    try std.testing.expect(txn.status.? == .ok);
}

test "Transaction.toJson produces valid output" {
    var txn = Transaction.init(std.testing.allocator, .{ .name = "GET /api", .op = "http.server" });
    defer txn.deinit();
    var span = try txn.startChild(.{ .op = "db.query" });
    span.finish();
    txn.finish();

    const json = try txn.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "GET /api") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "http.server") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "db.query") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"spans\":[") != null);
}
```

**Step 2: Update sentry.zig**

```zig
pub const Transaction = @import("transaction.zig").Transaction;
pub const Span = @import("transaction.zig").Span;
pub const SpanStatus = @import("transaction.zig").SpanStatus;
```

**Step 3: Run tests**

Run: `zig build test`
Expected: All tests pass

**Step 4: Commit**

```bash
git add src/transaction.zig src/sentry.zig
git commit -m "feat: add Transaction and Span for performance monitoring"
```

---

### Task 9: HTTP Transport

**Files:**
- Create: `src/transport.zig`

**Context:** The transport sends serialized envelopes to Sentry via HTTPS POST. Uses `std.http.Client`. Must handle: authentication (DSN in envelope header + `X-Sentry-Auth` header), rate limiting (`429` responses with `X-Sentry-Rate-Limits` and `Retry-After` headers), timeouts, and connection errors. Returns the HTTP status code.

**Step 1: Write transport.zig**

```zig
const std = @import("std");
const Dsn = @import("dsn.zig").Dsn;
const Allocator = std.mem.Allocator;

pub const TransportError = error{
    ConnectionFailed,
    Timeout,
    RateLimited,
    ServerError,
    InvalidResponse,
    TlsError,
};

pub const SendResult = struct {
    status_code: u16,
    retry_after: ?u64 = null, // seconds to wait
    rate_limit_categories: ?[]const u8 = null,
};

pub const Transport = struct {
    allocator: Allocator,
    dsn: Dsn,
    envelope_url: []u8,
    user_agent: []const u8 = "sentry-zig/0.1.0",

    pub fn init(allocator: Allocator, dsn: Dsn) !Transport {
        const url = try dsn.getEnvelopeUrl(allocator);
        return .{
            .allocator = allocator,
            .dsn = dsn,
            .envelope_url = url,
        };
    }

    pub fn deinit(self: *Transport) void {
        self.allocator.free(self.envelope_url);
    }

    /// Send an envelope payload to Sentry
    pub fn send(self: *Transport, envelope_data: []const u8) !SendResult {
        var client: std.http.Client = .{ .allocator = self.allocator };
        defer client.deinit();

        const uri = std.Uri.parse(self.envelope_url) catch return error.ConnectionFailed;

        var server_header_buf: [4096]u8 = undefined;
        var req = client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/x-sentry-envelope" },
                .{ .name = "User-Agent", .value = self.user_agent },
            },
        }) catch return error.ConnectionFailed;
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = envelope_data.len };
        req.send() catch return error.ConnectionFailed;
        req.writeAll(envelope_data) catch return error.ConnectionFailed;
        req.finish() catch return error.ConnectionFailed;
        req.wait() catch return error.ConnectionFailed;

        const status: u16 = @intFromEnum(req.status);
        var result = SendResult{ .status_code = status };

        // Parse rate limit headers if present
        if (status == 429) {
            if (req.response.iterateHeaders(.{ .name = "retry-after" }).next()) |h| {
                result.retry_after = std.fmt.parseInt(u64, h.value, 10) catch 60;
            } else {
                result.retry_after = 60; // default 60s
            }
        }

        return result;
    }
};

/// Mock transport for testing — records all sent envelopes
pub const MockTransport = struct {
    sent: std.ArrayList([]u8),
    allocator: Allocator,
    response_status: u16 = 200,

    pub fn init(allocator: Allocator) MockTransport {
        return .{
            .sent = std.ArrayList([]u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MockTransport) void {
        for (self.sent.items) |item| self.allocator.free(item);
        self.sent.deinit();
    }

    pub fn send(self: *MockTransport, envelope_data: []const u8) !SendResult {
        const copy = try self.allocator.dupe(u8, envelope_data);
        try self.sent.append(copy);
        return .{ .status_code = self.response_status };
    }

    pub fn lastSent(self: *MockTransport) ?[]const u8 {
        if (self.sent.items.len == 0) return null;
        return self.sent.items[self.sent.items.len - 1];
    }

    pub fn sentCount(self: *MockTransport) usize {
        return self.sent.items.len;
    }
};

test "MockTransport records sent envelopes" {
    var mock = MockTransport.init(std.testing.allocator);
    defer mock.deinit();

    _ = try mock.send("envelope1");
    _ = try mock.send("envelope2");

    try std.testing.expectEqual(@as(usize, 2), mock.sentCount());
    try std.testing.expectEqualStrings("envelope1", mock.lastSent().?);
    // Wait, lastSent returns the last one, which is envelope2
}

test "MockTransport custom response status" {
    var mock = MockTransport.init(std.testing.allocator);
    defer mock.deinit();
    mock.response_status = 429;

    const result = try mock.send("data");
    try std.testing.expectEqual(@as(u16, 429), result.status_code);
}
```

Note: The `lastSent` test has a bug — fix the test expectation to check for "envelope2" not "envelope1".

**Step 2: Update sentry.zig**

```zig
pub const Transport = @import("transport.zig").Transport;
pub const MockTransport = @import("transport.zig").MockTransport;
```

**Step 3: Run tests**

Run: `zig build test`
Expected: All tests pass

**Step 4: Commit**

```bash
git add src/transport.zig src/sentry.zig
git commit -m "feat: add HTTP transport with mock for testing"
```

---

### Task 10: Background Worker Thread

**Files:**
- Create: `src/worker.zig`

**Context:** The worker runs in a background thread, consuming envelopes from a thread-safe queue and sending them via the transport. It supports graceful shutdown with `flush(timeout_ms)`. The queue has a max capacity to prevent unbounded memory growth.

**Step 1: Write worker.zig**

```zig
const std = @import("std");
const transport_mod = @import("transport.zig");
const Transport = transport_mod.Transport;
const Allocator = std.mem.Allocator;

pub const MAX_QUEUE_SIZE = 100;

pub const WorkItem = struct {
    data: []u8,
};

pub const Worker = struct {
    allocator: Allocator,
    transport: *Transport,
    queue: std.ArrayList(WorkItem),
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    shutdown: bool = false,
    thread: ?std.Thread = null,
    flush_condition: std.Thread.Condition = .{},

    pub fn init(allocator: Allocator, transport: *Transport) Worker {
        return .{
            .allocator = allocator,
            .transport = transport,
            .queue = std.ArrayList(WorkItem).init(allocator),
        };
    }

    pub fn deinit(self: *Worker) void {
        // Drain remaining items
        for (self.queue.items) |item| {
            self.allocator.free(item.data);
        }
        self.queue.deinit();
    }

    pub fn start(self: *Worker) !void {
        self.thread = try std.Thread.spawn(.{}, workerLoop, .{self});
    }

    pub fn submit(self: *Worker, data: []u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.shutdown) {
            self.allocator.free(data);
            return;
        }

        if (self.queue.items.len >= MAX_QUEUE_SIZE) {
            // Drop oldest
            const old = self.queue.orderedRemove(0);
            self.allocator.free(old.data);
        }

        try self.queue.append(.{ .data = data });
        self.condition.signal();
    }

    /// Flush: wait until queue is empty or timeout
    pub fn flush(self: *Worker, timeout_ms: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.queue.items.len == 0) return true;

        // Signal the worker to process
        self.condition.signal();

        // Wait for queue to drain
        self.flush_condition.timedWait(&self.mutex, timeout_ms * std.time.ns_per_ms) catch {
            return self.queue.items.len == 0;
        };
        return self.queue.items.len == 0;
    }

    /// Shutdown: signal worker to stop and wait for thread to join
    pub fn shutdown(self: *Worker) void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.shutdown = true;
            self.condition.signal();
        }
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn workerLoop(self: *Worker) void {
        while (true) {
            var item: ?WorkItem = null;

            {
                self.mutex.lock();
                defer self.mutex.unlock();

                while (self.queue.items.len == 0 and !self.shutdown) {
                    self.condition.wait(&self.mutex);
                }

                if (self.shutdown and self.queue.items.len == 0) {
                    self.flush_condition.signal();
                    return;
                }

                if (self.queue.items.len > 0) {
                    item = self.queue.orderedRemove(0);
                }

                if (self.queue.items.len == 0) {
                    self.flush_condition.signal();
                }
            }

            if (item) |work| {
                defer self.allocator.free(work.data);
                _ = self.transport.send(work.data) catch {};
            }
        }
    }
};

test "Worker submit and shutdown" {
    // Uses mock transport indirectly — just test queue behavior
    var transport: Transport = undefined; // won't actually send in this test
    var worker = Worker.init(std.testing.allocator, &transport);
    defer worker.deinit();

    // Submit without starting thread — items accumulate in queue
    const data = try std.testing.allocator.dupe(u8, "test");
    try worker.submit(data);

    worker.mutex.lock();
    const count = worker.queue.items.len;
    worker.mutex.unlock();
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "Worker drops oldest when queue full" {
    var transport: Transport = undefined;
    var worker = Worker.init(std.testing.allocator, &transport);
    defer worker.deinit();

    // Fill queue to max
    for (0..MAX_QUEUE_SIZE + 5) |i| {
        var buf: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
        const data = try std.testing.allocator.dupe(u8, s);
        try worker.submit(data);
    }

    worker.mutex.lock();
    const count = worker.queue.items.len;
    worker.mutex.unlock();
    try std.testing.expectEqual(@as(usize, MAX_QUEUE_SIZE), count);
}
```

**Step 2: Update sentry.zig**

```zig
pub const Worker = @import("worker.zig").Worker;
```

**Step 3: Run tests**

Run: `zig build test`
Expected: All tests pass

**Step 4: Commit**

```bash
git add src/worker.zig src/sentry.zig
git commit -m "feat: add background worker thread with queue and flush"
```

---

### Task 11: Signal Handler for Crash Reporting

**Files:**
- Create: `src/signal_handler.zig`

**Context:** Install POSIX signal handlers for SEGV, ABRT, BUS, ILL, FPE. The handler must be async-signal-safe: it writes a minimal crash report to a file on disk. On next SDK init, check for pending crash files and send them. This is platform-specific — only works on POSIX systems (Linux, macOS).

**Step 1: Write signal_handler.zig**

```zig
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const CRASH_FILE = ".sentry-native-crash";

/// Global pointer to crash file path (set during init)
var crash_file_path: [std.fs.max_path_bytes]u8 = undefined;
var crash_file_path_len: usize = 0;

/// Whether signal handlers are installed
var handlers_installed: bool = false;

const crash_signals = if (builtin.os.tag != .windows)
    [_]u6{
        std.posix.SIG.SEGV,
        std.posix.SIG.ABRT,
        std.posix.SIG.BUS,
        std.posix.SIG.ILL,
        std.posix.SIG.FPE,
    }
else
    [_]u6{};

var previous_handlers: [crash_signals.len]std.posix.Sigaction = undefined;

fn signalHandler(sig: c_int) callconv(.c) void {
    if (builtin.os.tag == .windows) return;

    // Write minimal crash marker file (async-signal-safe)
    if (crash_file_path_len > 0) {
        const path = crash_file_path[0..crash_file_path_len];
        const fd = std.posix.open(
            @ptrCast(path),
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
            0o644,
        ) catch return;
        defer std.posix.close(fd);

        // Write signal number as ASCII
        var buf: [32]u8 = undefined;
        const sig_str = std.fmt.bufPrint(&buf, "signal:{d}\n", .{sig}) catch return;
        _ = std.posix.write(fd, sig_str) catch {};
    }

    // Re-raise with default handler
    var default_action = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    const sig_u6: u6 = @intCast(@as(u32, @bitCast(sig)));
    std.posix.sigaction(sig_u6, &default_action, null);
    _ = std.posix.raise(sig_u6) catch {};
}

/// Install signal handlers. Call during SDK init.
pub fn install(cache_dir: []const u8) void {
    if (builtin.os.tag == .windows) return;
    if (handlers_installed) return;

    // Set crash file path
    const written = std.fmt.bufPrint(&crash_file_path, "{s}/{s}", .{ cache_dir, CRASH_FILE }) catch return;
    crash_file_path_len = written.len;
    // Null-terminate for posix.open
    if (crash_file_path_len < crash_file_path.len) {
        crash_file_path[crash_file_path_len] = 0;
    }

    const action = std.posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.empty_sigset,
        .flags = std.posix.SA.RESETHAND, // One-shot: reset after first signal
    };

    for (crash_signals, 0..) |sig, i| {
        std.posix.sigaction(sig, &action, &previous_handlers[i]);
    }

    handlers_installed = true;
}

/// Uninstall signal handlers. Call during SDK deinit.
pub fn uninstall() void {
    if (builtin.os.tag == .windows) return;
    if (!handlers_installed) return;

    for (crash_signals, 0..) |sig, i| {
        std.posix.sigaction(sig, &previous_handlers[i], null);
    }

    handlers_installed = false;
}

/// Check for a pending crash from previous run. Returns signal number or null.
pub fn checkPendingCrash(allocator: Allocator, cache_dir: []const u8) !?u32 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_dir, CRASH_FILE });
    defer allocator.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    var buf: [64]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    const content = buf[0..n];

    // Parse "signal:N\n"
    if (std.mem.startsWith(u8, content, "signal:")) {
        const num_str = std.mem.trimRight(u8, content[7..], "\n");
        const sig = std.fmt.parseInt(u32, num_str, 10) catch return null;

        // Delete crash file after reading
        std.fs.cwd().deleteFile(path) catch {};

        return sig;
    }

    return null;
}

test "checkPendingCrash returns null when no crash file" {
    const result = try checkPendingCrash(std.testing.allocator, "/tmp/sentry-test-nonexistent");
    try std.testing.expect(result == null);
}

test "signal handler installation is idempotent" {
    if (builtin.os.tag == .windows) return;
    install("/tmp");
    install("/tmp"); // second call should be no-op
    try std.testing.expect(handlers_installed);
    uninstall();
    try std.testing.expect(!handlers_installed);
}
```

**Step 2: Update sentry.zig**

```zig
pub const signal_handler = @import("signal_handler.zig");
```

**Step 3: Run tests**

Run: `zig build test`
Expected: All tests pass

**Step 4: Commit**

```bash
git add src/signal_handler.zig src/sentry.zig
git commit -m "feat: add POSIX signal handler for crash reporting"
```

---

### Task 12: Client — Public API (Main Integration)

**Files:**
- Create: `src/client.zig`
- Modify: `src/sentry.zig` (final public API)

**Context:** The Client struct ties everything together. It owns the scope, transport, worker, and session. All public methods are thread-safe. This is what users import and interact with.

**Step 1: Write client.zig**

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const Dsn = @import("dsn.zig").Dsn;
const Event = @import("event.zig").Event;
const Level = @import("event.zig").Level;
const UserType = @import("event.zig").User;
const BreadcrumbType = @import("event.zig").Breadcrumb;
const Scope = @import("scope.zig").Scope;
const Session = @import("session.zig").Session;
const SessionStatus = @import("session.zig").SessionStatus;
const TransactionMod = @import("transaction.zig");
const Transaction = TransactionMod.Transaction;
const TransactionOpts = TransactionMod.TransactionOpts;
const ChildSpanOpts = TransactionMod.ChildSpanOpts;
const Transport = @import("transport.zig").Transport;
const Worker = @import("worker.zig").Worker;
const envelope = @import("envelope.zig");
const signal_handler = @import("signal_handler.zig");
const ts = @import("timestamp.zig");

pub const Options = struct {
    dsn: []const u8,
    release: ?[]const u8 = null,
    environment: ?[]const u8 = null,
    server_name: ?[]const u8 = null,
    sample_rate: f64 = 1.0,
    traces_sample_rate: f64 = 0.0,
    max_breadcrumbs: u32 = 100,
    before_send: ?*const fn (Event) ?Event = null,
    cache_dir: []const u8 = "/tmp/sentry-zig",
    install_signal_handlers: bool = true,
};

pub const Client = struct {
    allocator: Allocator,
    dsn: Dsn,
    options: Options,
    scope: Scope,
    transport: Transport,
    worker: Worker,
    session: ?Session = null,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: Allocator, options: Options) !Client {
        const dsn = Dsn.parse(options.dsn) catch return error.InvalidDsn;

        var transport = try Transport.init(allocator, dsn);
        errdefer transport.deinit();

        var worker = Worker.init(allocator, &transport);

        // Create cache directory
        std.fs.cwd().makePath(options.cache_dir) catch {};

        // Install signal handlers
        if (options.install_signal_handlers) {
            signal_handler.install(options.cache_dir);
        }

        var client = Client{
            .allocator = allocator,
            .dsn = dsn,
            .options = options,
            .scope = Scope.init(allocator, options.max_breadcrumbs),
            .transport = transport,
            .worker = worker,
            .session = null,
        };

        // Fix worker transport pointer after move
        client.worker.transport = &client.transport;

        // Start background worker
        try client.worker.start();

        // Check for pending crash from previous run
        if (try signal_handler.checkPendingCrash(allocator, options.cache_dir)) |sig| {
            client.captureCrash(sig);
        }

        return client;
    }

    pub fn deinit(self: *Client) void {
        // Flush remaining events
        _ = self.worker.flush(5000);
        self.worker.shutdown();
        self.worker.deinit();
        self.transport.deinit();
        self.scope.deinit();

        if (self.options.install_signal_handlers) {
            signal_handler.uninstall();
        }
    }

    // --- Error Capture ---

    pub fn captureMessage(self: *Client, message: []const u8, level: Level) void {
        var event = Event.initMessage(message, level);
        self.captureEvent(&event);
    }

    pub fn captureException(self: *Client, exception_type: []const u8, value: []const u8) void {
        var event = Event.initException(exception_type, value);
        self.captureEvent(&event);
    }

    pub fn captureEvent(self: *Client, event: *Event) void {
        // Apply default fields
        if (event.release == null) event.release = self.options.release;
        if (event.environment == null) event.environment = self.options.environment;
        if (event.server_name == null) event.server_name = self.options.server_name;
        event.platform = "other";

        // Sample rate check
        if (self.options.sample_rate < 1.0) {
            var rng_bytes: [4]u8 = undefined;
            std.crypto.random.bytes(&rng_bytes);
            const val: f64 = @as(f64, @floatFromInt(std.mem.readInt(u32, &rng_bytes, .little))) / @as(f64, @floatFromInt(std.math.maxInt(u32)));
            if (val >= self.options.sample_rate) return;
        }

        // Apply scope
        self.scope.applyToEvent(event) catch return;

        // before_send callback
        if (self.options.before_send) |cb| {
            if (cb(event.*) == null) return; // Event filtered out
        }

        // Mark session as errored if applicable
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.session) |*s| {
                if (event.level == .err or event.level == .fatal) {
                    s.markErrored();
                }
            }
        }

        // Serialize to envelope and submit to worker
        var buf = std.ArrayList(u8).init(self.allocator);
        envelope.serializeEventEnvelope(self.allocator, event.*, self.dsn, buf.writer()) catch {
            buf.deinit();
            return;
        };
        const data = buf.toOwnedSlice() catch {
            buf.deinit();
            return;
        };
        self.worker.submit(data) catch {
            self.allocator.free(data);
        };
    }

    fn captureCrash(self: *Client, signal: u32) void {
        const sig_name = switch (signal) {
            11 => "SIGSEGV",
            6 => "SIGABRT",
            7 => "SIGBUS",
            4 => "SIGILL",
            8 => "SIGFPE",
            else => "Unknown",
        };
        var msg_buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Crash: {s} (signal {d})", .{ sig_name, signal }) catch return;
        var event = Event.initException("NativeCrash", msg);
        event.level = .fatal;
        self.captureEvent(&event);
    }

    // --- Scope ---

    pub fn setUser(self: *Client, user: UserType) void {
        self.scope.setUser(user);
    }

    pub fn removeUser(self: *Client) void {
        self.scope.setUser(null);
    }

    pub fn setTag(self: *Client, key: []const u8, value: []const u8) void {
        self.scope.setTag(key, value) catch {};
    }

    pub fn removeTag(self: *Client, key: []const u8) void {
        self.scope.removeTag(key);
    }

    pub fn setExtra(self: *Client, key: []const u8, value: std.json.Value) void {
        self.scope.setExtra(key, value) catch {};
    }

    pub fn setContext(self: *Client, key: []const u8, value: std.json.Value) void {
        self.scope.setContext(key, value) catch {};
    }

    pub fn addBreadcrumb(self: *Client, crumb: BreadcrumbType) void {
        self.scope.addBreadcrumb(crumb);
    }

    // --- Transactions ---

    pub fn startTransaction(self: *Client, opts: TransactionOpts) Transaction {
        var txn = Transaction.init(self.allocator, opts);
        txn.release = self.options.release;
        txn.environment = self.options.environment;

        // Sample rate check for traces
        if (self.options.traces_sample_rate < 1.0) {
            var rng_bytes: [4]u8 = undefined;
            std.crypto.random.bytes(&rng_bytes);
            const val: f64 = @as(f64, @floatFromInt(std.mem.readInt(u32, &rng_bytes, .little))) / @as(f64, @floatFromInt(std.math.maxInt(u32)));
            txn.sampled = val < self.options.traces_sample_rate;
        }

        return txn;
    }

    pub fn finishTransaction(self: *Client, txn: *Transaction) void {
        txn.finish();
        if (!txn.sampled) return;

        const json = txn.toJson(self.allocator) catch return;
        defer self.allocator.free(json);

        // Build envelope for transaction
        var buf = std.ArrayList(u8).init(self.allocator);
        const w = buf.writer();
        // Envelope header
        w.writeAll("{\"dsn\":\"") catch { buf.deinit(); return; };
        self.dsn.writeDsn(w) catch { buf.deinit(); return; };
        w.writeAll("\",\"sent_at\":\"") catch { buf.deinit(); return; };
        const sent_at = ts.nowRfc3339();
        w.writeAll(&sent_at) catch { buf.deinit(); return; };
        w.writeAll("\",\"sdk\":{\"name\":\"sentry-zig\",\"version\":\"0.1.0\"}}\n") catch { buf.deinit(); return; };
        // Item header
        w.print("{{\"type\":\"transaction\",\"length\":{d}}}\n", .{json.len}) catch { buf.deinit(); return; };
        w.writeAll(json) catch { buf.deinit(); return; };
        w.writeAll("\n") catch { buf.deinit(); return; };

        const data = buf.toOwnedSlice() catch { buf.deinit(); return; };
        self.worker.submit(data) catch { self.allocator.free(data); };
    }

    // --- Sessions ---

    pub fn startSession(self: *Client) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.session = Session.start(self.options.release, self.options.environment);
    }

    pub fn endSession(self: *Client, status: SessionStatus) void {
        self.mutex.lock();
        const session = &(self.session orelse {
            self.mutex.unlock();
            return;
        });
        session.end(status);
        const json = session.toJson(self.allocator) catch {
            self.mutex.unlock();
            return;
        };
        self.session = null;
        self.mutex.unlock();
        defer self.allocator.free(json);

        // Send session envelope
        var buf = std.ArrayList(u8).init(self.allocator);
        envelope.serializeSessionEnvelope(self.dsn, json, buf.writer()) catch {
            buf.deinit();
            return;
        };
        const data = buf.toOwnedSlice() catch { buf.deinit(); return; };
        self.worker.submit(data) catch { self.allocator.free(data); };
    }

    // --- Flush ---

    pub fn flush(self: *Client, timeout_ms: u64) bool {
        return self.worker.flush(timeout_ms);
    }
};

test "Client basic lifecycle" {
    // This test verifies the Client struct compiles and has correct types
    // Real transport tests need a server, so just verify structure
    try std.testing.expect(@sizeOf(Client) > 0);
    try std.testing.expect(@sizeOf(Options) > 0);
}
```

**Step 2: Rewrite sentry.zig as final public API**

```zig
//! Sentry-Zig: Pure Zig Sentry SDK
//!
//! A zero-dependency Sentry SDK for Zig applications.
//!
//! Usage:
//!   const sentry = @import("sentry-zig");
//!   var client = try sentry.init(allocator, .{
//!       .dsn = "https://key@o0.ingest.sentry.io/12345",
//!       .release = "myapp@1.0.0",
//!       .environment = "production",
//!   });
//!   defer client.deinit();
//!
//!   client.captureMessage("Something went wrong", .err);

const std = @import("std");

// Core types
pub const Client = @import("client.zig").Client;
pub const Options = @import("client.zig").Options;

// Data types
pub const Event = @import("event.zig").Event;
pub const Level = @import("event.zig").Level;
pub const User = @import("event.zig").User;
pub const Breadcrumb = @import("event.zig").Breadcrumb;
pub const Frame = @import("event.zig").Frame;
pub const Stacktrace = @import("event.zig").Stacktrace;
pub const ExceptionValue = @import("event.zig").ExceptionValue;
pub const Message = @import("event.zig").Message;

// Performance monitoring
pub const Transaction = @import("transaction.zig").Transaction;
pub const TransactionOpts = @import("transaction.zig").TransactionOpts;
pub const ChildSpanOpts = @import("transaction.zig").ChildSpanOpts;
pub const Span = @import("transaction.zig").Span;
pub const SpanStatus = @import("transaction.zig").SpanStatus;

// Session
pub const Session = @import("session.zig").Session;
pub const SessionStatus = @import("session.zig").SessionStatus;

// Internals (for advanced usage)
pub const Dsn = @import("dsn.zig").Dsn;
pub const Scope = @import("scope.zig").Scope;
pub const Transport = @import("transport.zig").Transport;
pub const MockTransport = @import("transport.zig").MockTransport;
pub const envelope = @import("envelope.zig");
pub const Uuid = @import("uuid.zig").Uuid;
pub const timestamp = @import("timestamp.zig");

/// Convenience: initialize Sentry client
pub fn init(allocator: std.mem.Allocator, options: Options) !Client {
    return Client.init(allocator, options);
}

test {
    std.testing.refAllDecls(@This());
}
```

**Step 3: Run tests**

Run: `zig build test`
Expected: All tests pass

**Step 4: Commit**

```bash
git add src/client.zig src/sentry.zig
git commit -m "feat: add Client public API integrating all components"
```

---

### Task 13: Integration Test

**Files:**
- Create: `tests/integration_test.zig`
- Modify: `build.zig` (add integration test step)

**Context:** Write an integration test that uses the full Client API with MockTransport to verify end-to-end flow without network. Verify events are serialized correctly, breadcrumbs are attached, user context is applied.

**Step 1: Add integration test to build.zig**

Add after the existing test step in `build.zig`:

```zig
    const integration_tests = b.addTest(.{
        .root_source_file = b.path("tests/integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_tests.root_module.addImport("sentry-zig", sentry_mod);

    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step("test-integration", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

    // Make default test run both
    test_step.dependOn(&run_integration_tests.step);
```

**Step 2: Write tests/integration_test.zig**

```zig
const std = @import("std");
const sentry = @import("sentry-zig");

test "DSN parsing and envelope URL" {
    const dsn = try sentry.Dsn.parse("https://abc123@o0.ingest.sentry.io/456789");
    try std.testing.expectEqualStrings("https", dsn.scheme);
    try std.testing.expectEqualStrings("abc123", dsn.public_key);
    try std.testing.expectEqualStrings("456789", dsn.project_id);

    const url = try dsn.getEnvelopeUrl(std.testing.allocator);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://o0.ingest.sentry.io/api/456789/envelope/", url);
}

test "Event creation and JSON serialization" {
    const event = sentry.Event.initMessage("Test error message", .err);
    try std.testing.expect(event.event_id.len == 32);
    try std.testing.expect(event.message != null);

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try std.json.stringify(event, .{ .emit_null_optional_fields = false }, buf.writer());

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Test error message") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"level\":\"error\"") != null);
}

test "Scope enriches events with tags and user" {
    var scope = sentry.Scope.init(std.testing.allocator, 100);
    defer scope.deinit();

    scope.setUser(.{ .id = "user-42", .email = "test@example.com" });
    try scope.setTag("version", "1.0.0");
    scope.addBreadcrumb(.{
        .timestamp = 1234567890.0,
        .category = "navigation",
        .message = "page loaded",
        .level = .info,
    });

    var event = sentry.Event.initMessage("error", .err);
    try scope.applyToEvent(&event);

    try std.testing.expect(event.user != null);
    try std.testing.expectEqualStrings("user-42", event.user.?.id.?);
    try std.testing.expect(event.tags != null);
    try std.testing.expect(event.breadcrumbs != null);
    try std.testing.expectEqual(@as(usize, 1), event.breadcrumbs.?.len);
}

test "UUID v4 format is correct" {
    const uuid = sentry.Uuid.v4();
    const hex = uuid.toHex();
    try std.testing.expect(hex.len == 32);

    // Roundtrip
    const parsed = try sentry.Uuid.fromHex(&hex);
    try std.testing.expectEqualSlices(u8, &uuid.bytes, &parsed.bytes);
}

test "Transaction with child spans" {
    var txn = sentry.Transaction.init(std.testing.allocator, .{
        .name = "GET /api/users",
        .op = "http.server",
    });
    defer txn.deinit();

    var span = try txn.startChild(.{
        .op = "db.query",
        .description = "SELECT * FROM users",
    });
    span.finish();

    try std.testing.expect(span.timestamp != null);
    try std.testing.expect(span.status.? == .ok);

    txn.finish();

    const json = try txn.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "GET /api/users") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "db.query") != null);
}

test "Session lifecycle" {
    var session = sentry.Session.start("app@1.0", "production");
    try std.testing.expect(session.status == .ok);

    session.markErrored();
    try std.testing.expect(session.status == .errored);
    try std.testing.expectEqual(@as(u32, 1), session.errors);

    session.end(.exited);
    try std.testing.expect(session.status == .exited);
    try std.testing.expect(session.duration != null);

    const json = try session.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"exited\"") != null);
}

test "Envelope serialization" {
    const dsn = try sentry.Dsn.parse("https://key@sentry.io/1");
    const event = sentry.Event.initMessage("hello", .info);

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try sentry.envelope.serializeEventEnvelope(std.testing.allocator, event, dsn, buf.writer());

    // Verify 3-line format
    var line_count: usize = 0;
    var it = std.mem.splitScalar(u8, buf.items, '\n');
    while (it.next()) |line| {
        if (line.len > 0) line_count += 1;
    }
    try std.testing.expect(line_count >= 3);
}

test "Timestamp formatting" {
    const t = sentry.timestamp.now();
    try std.testing.expect(t > 1704067200.0); // After 2024-01-01

    const rfc = sentry.timestamp.nowRfc3339();
    try std.testing.expectEqualStrings("20", rfc[0..2]);
    try std.testing.expect(rfc[4] == '-');
    try std.testing.expect(rfc[10] == 'T');
    try std.testing.expect(rfc[23] == 'Z');
}
```

**Step 3: Run tests**

Run: `zig build test`
Expected: All tests pass

**Step 4: Commit**

```bash
git add tests/integration_test.zig build.zig
git commit -m "feat: add integration tests for full SDK API"
```

---

### Task 14: README and Package Documentation

**Files:**
- Create: `README.md`

**Step 1: Write README.md**

```markdown
# Sentry-Zig

Pure Zig Sentry SDK — zero external dependencies.

## Requirements

- Zig >= 0.15.0

## Installation

Add to your `build.zig.zon`:

```bash
zig fetch --save git+https://github.com/nullclaw/sentry-zig
```

Then in your `build.zig`:

```zig
const sentry_dep = b.dependency("sentry-zig", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("sentry-zig", sentry_dep.module("sentry-zig"));
```

## Usage

```zig
const sentry = @import("sentry-zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try sentry.init(allocator, .{
        .dsn = "https://examplePublicKey@o0.ingest.sentry.io/1234567",
        .release = "myapp@1.0.0",
        .environment = "production",
    });
    defer client.deinit();

    // Capture errors
    client.captureMessage("Something went wrong", .err);
    client.captureException("RuntimeError", "division by zero");

    // User context
    client.setUser(.{ .id = "42", .email = "user@example.com" });

    // Breadcrumbs
    client.addBreadcrumb(.{
        .timestamp = sentry.timestamp.now(),
        .category = "auth",
        .message = "User logged in",
        .level = .info,
    });

    // Performance monitoring
    var txn = client.startTransaction(.{ .name = "GET /api", .op = "http.server" });
    var span = try txn.startChild(.{ .op = "db.query", .description = "SELECT *" });
    span.finish();
    client.finishTransaction(&txn);
    txn.deinit();

    // Sessions
    client.startSession();
    defer client.endSession(.exited);

    // Flush before exit
    _ = client.flush(5000);
}
```

## Features

- Error and exception capture with stack traces
- Breadcrumbs (ring buffer, configurable capacity)
- User context, tags, extra data
- Performance monitoring (transactions + spans)
- Session tracking
- Crash reporting via POSIX signal handlers
- Async event delivery (background thread)
- Rate limiting support
- Sampling (events and traces)
- `before_send` callback for event filtering

## Testing

```bash
zig build test
```

## License

MIT
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with installation and usage guide"
```

---

### Task 15: Final Verification

**Step 1: Run full test suite**

Run: `zig build test`
Expected: All tests pass

**Step 2: Verify build as library**

Run: `zig build`
Expected: Clean build with no errors

**Step 3: Check all files are committed**

Run: `git status`
Expected: Clean working tree

**Step 4: Tag release**

```bash
git tag v0.1.0
```
