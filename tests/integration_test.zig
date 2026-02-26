//! Integration tests for the Sentry-Zig SDK.
//!
//! These tests exercise the PUBLIC API exported by `sentry-zig` and verify
//! end-to-end flows without any network access.

const std = @import("std");
const testing = std.testing;
const sentry = @import("sentry-zig");

// ─── 1. DSN Parsing and Envelope URL ────────────────────────────────────────

test "DSN parsing and envelope URL" {
    const dsn = try sentry.Dsn.parse("https://abc123@o0.ingest.sentry.io/5678");

    try testing.expectEqualStrings("https", dsn.scheme);
    try testing.expectEqualStrings("abc123", dsn.public_key);
    try testing.expectEqualStrings("o0.ingest.sentry.io", dsn.host);
    try testing.expect(dsn.port == null);
    try testing.expectEqualStrings("5678", dsn.project_id);

    const url = try dsn.getEnvelopeUrl(testing.allocator);
    defer testing.allocator.free(url);

    try testing.expectEqualStrings("https://o0.ingest.sentry.io/api/5678/envelope/", url);

    // Verify the URL starts with the DSN scheme and host
    try testing.expect(std.mem.startsWith(u8, url, "https://o0.ingest.sentry.io/"));
    // Verify it ends with /envelope/
    try testing.expect(std.mem.endsWith(u8, url, "/envelope/"));
}

test "DSN parsing with port" {
    const dsn = try sentry.Dsn.parse("https://mykey@sentry.example.com:9000/42");

    try testing.expectEqualStrings("mykey", dsn.public_key);
    try testing.expectEqualStrings("sentry.example.com", dsn.host);
    try testing.expectEqual(@as(u16, 9000), dsn.port.?);
    try testing.expectEqualStrings("42", dsn.project_id);

    const url = try dsn.getEnvelopeUrl(testing.allocator);
    defer testing.allocator.free(url);

    try testing.expectEqualStrings("https://sentry.example.com:9000/api/42/envelope/", url);
}

// ─── 2. Event Creation and JSON Serialization ───────────────────────────────

test "Event creation and JSON serialization" {
    const event = sentry.Event.initMessage("integration test message", .warning);

    // Verify the event has a valid 32-char hex event_id
    try testing.expectEqual(@as(usize, 32), event.event_id.len);
    for (event.event_id) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }

    // Verify the level is set
    try testing.expectEqual(sentry.Level.warning, event.level.?);

    // Verify the message is set
    try testing.expectEqualStrings("integration test message", event.message.?.formatted.?);

    // Verify platform defaults to "zig"
    try testing.expectEqualStrings("zig", event.platform);

    // Serialize to JSON
    const json_str = try std.json.Stringify.valueAlloc(
        testing.allocator,
        event,
        .{ .emit_null_optional_fields = false },
    );
    defer testing.allocator.free(json_str);

    // Verify JSON contains expected fields
    try testing.expect(std.mem.indexOf(u8, json_str, "\"event_id\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"integration test message\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"warning\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"zig\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"timestamp\"") != null);
}

test "Exception event creation and serialization" {
    const values = [_]sentry.ExceptionValue{.{
        .@"type" = "RuntimeError",
        .value = "something went wrong",
    }};
    const event = sentry.Event.initException(&values);

    try testing.expectEqual(sentry.Level.err, event.level.?);
    try testing.expect(event.exception != null);
    try testing.expectEqual(@as(usize, 1), event.exception.?.values.len);

    const json_str = try std.json.Stringify.valueAlloc(
        testing.allocator,
        event,
        .{ .emit_null_optional_fields = false },
    );
    defer testing.allocator.free(json_str);

    try testing.expect(std.mem.indexOf(u8, json_str, "\"RuntimeError\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"something went wrong\"") != null);
}

// ─── 3. Scope Enriches Events ───────────────────────────────────────────────

test "Scope enriches events with user, tags, and breadcrumbs" {
    var scope = try sentry.Scope.init(testing.allocator, 50);
    defer scope.deinit();

    // Set user
    scope.setUser(.{
        .id = "user-42",
        .email = "test@example.com",
        .username = "testuser",
    });

    // Set tags
    try scope.setTag("environment", "test");
    try scope.setTag("release", "1.0.0");

    // Add breadcrumbs
    scope.addBreadcrumb(.{
        .message = "User clicked button",
        .category = "ui.click",
        .level = .info,
    });
    scope.addBreadcrumb(.{
        .message = "API call made",
        .category = "http",
        .level = .debug,
    });

    // Create an event and apply scope
    var event = sentry.Event.init();
    try scope.applyToEvent(testing.allocator, &event);

    // Cleanup allocated resources
    defer {
        if (event.tags) |t| {
            var tags_obj = t.object;
            tags_obj.deinit();
        }
        if (event.breadcrumbs) |b| {
            testing.allocator.free(b);
        }
    }

    // Verify user was applied
    try testing.expect(event.user != null);
    try testing.expectEqualStrings("user-42", event.user.?.id.?);
    try testing.expectEqualStrings("test@example.com", event.user.?.email.?);
    try testing.expectEqualStrings("testuser", event.user.?.username.?);

    // Verify tags were applied
    try testing.expect(event.tags != null);

    // Verify breadcrumbs were applied
    try testing.expect(event.breadcrumbs != null);
    try testing.expectEqual(@as(usize, 2), event.breadcrumbs.?.len);
    try testing.expectEqualStrings("User clicked button", event.breadcrumbs.?[0].message.?);
    try testing.expectEqualStrings("API call made", event.breadcrumbs.?[1].message.?);
}

// ─── 4. UUID v4 Format ─────────────────────────────────────────────────────

test "UUID v4 format and roundtrip" {
    const uuid = sentry.Uuid.v4();

    // Verify hex format: 32 lowercase hex characters
    const hex = uuid.toHex();
    try testing.expectEqual(@as(usize, 32), hex.len);
    for (hex) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }

    // Verify version bits (byte 6, high nibble = 4)
    try testing.expectEqual(@as(u8, 0x40), uuid.bytes[6] & 0xF0);

    // Verify variant bits (byte 8, high 2 bits = 10)
    try testing.expectEqual(@as(u8, 0x80), uuid.bytes[8] & 0xC0);

    // Verify roundtrip: toHex -> fromHex -> toHex
    const parsed = try sentry.Uuid.fromHex(&hex);
    const hex2 = parsed.toHex();
    try testing.expectEqualSlices(u8, &hex, &hex2);

    // Verify dashed format: 8-4-4-4-12
    const dashed = uuid.toDashedHex();
    try testing.expectEqual(@as(usize, 36), dashed.len);
    try testing.expectEqual(@as(u8, '-'), dashed[8]);
    try testing.expectEqual(@as(u8, '-'), dashed[13]);
    try testing.expectEqual(@as(u8, '-'), dashed[18]);
    try testing.expectEqual(@as(u8, '-'), dashed[23]);
}

test "UUID uniqueness" {
    const uuid1 = sentry.Uuid.v4();
    const uuid2 = sentry.Uuid.v4();

    // Two UUIDs should be different
    try testing.expect(!std.mem.eql(u8, &uuid1.bytes, &uuid2.bytes));
}

// ─── 5. Transaction with Child Spans ────────────────────────────────────────

test "Transaction with child spans" {
    var txn = sentry.Transaction.init(testing.allocator, .{
        .name = "GET /api/users",
        .op = "http.server",
        .release = "my-service@2.0.0",
        .environment = "staging",
    });
    defer txn.deinit();

    // Verify transaction has valid trace_id and span_id
    try testing.expectEqual(@as(usize, 32), txn.trace_id.len);
    try testing.expectEqual(@as(usize, 16), txn.span_id.len);
    try testing.expect(txn.start_timestamp > 1704067200.0);

    // Start a child span
    const child = try txn.startChild(.{
        .op = "db.query",
        .description = "SELECT * FROM users WHERE active = true",
    });

    // Verify child inherits trace_id and has parent_span_id
    try testing.expectEqualSlices(u8, &txn.trace_id, &child.trace_id);
    try testing.expect(child.parent_span_id != null);
    try testing.expectEqualSlices(u8, &txn.span_id, &child.parent_span_id.?);

    // Finish child span
    child.finish();
    try testing.expect(child.timestamp != null);
    try testing.expectEqual(sentry.SpanStatus.ok, child.status.?);

    // Finish transaction
    txn.finish();
    try testing.expect(txn.timestamp != null);
    try testing.expectEqual(sentry.SpanStatus.ok, txn.status.?);

    // Serialize to JSON
    const json_str = try txn.toJson(testing.allocator);
    defer testing.allocator.free(json_str);

    // Verify JSON fields
    try testing.expect(std.mem.indexOf(u8, json_str, "\"transaction\":\"GET /api/users\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"type\":\"transaction\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"op\":\"http.server\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"op\":\"db.query\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"spans\":[") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"release\":\"my-service@2.0.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"environment\":\"staging\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"status\":\"ok\"") != null);
}

// ─── 6. Session Lifecycle ───────────────────────────────────────────────────

test "Session lifecycle: start, error, end" {
    var session = sentry.Session.start("my-app@1.0.0", "production");

    // Verify initial state
    try testing.expectEqual(sentry.SessionStatus.ok, session.status);
    try testing.expectEqual(@as(u32, 0), session.errors);
    try testing.expect(session.init_flag);
    try testing.expect(session.started > 1704067200.0);

    // Mark as errored
    session.markErrored();
    try testing.expectEqual(sentry.SessionStatus.errored, session.status);
    try testing.expectEqual(@as(u32, 1), session.errors);

    // End the session
    session.end(.exited);
    try testing.expectEqual(sentry.SessionStatus.exited, session.status);
    try testing.expect(session.duration != null);
    try testing.expect(session.duration.? >= 0.0);

    // Serialize to JSON
    const json_str = try session.toJson(testing.allocator);
    defer testing.allocator.free(json_str);

    // Verify JSON fields
    try testing.expect(std.mem.indexOf(u8, json_str, "\"sid\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"init\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"started\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"timestamp\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"status\":\"exited\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"errors\":1") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"release\":\"my-app@1.0.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"environment\":\"production\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"duration\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"attrs\"") != null);
}

// ─── 7. Envelope Serialization ──────────────────────────────────────────────

test "Envelope serialization produces 3-line format" {
    const dsn = try sentry.Dsn.parse("https://testkey@o0.ingest.sentry.io/99999");
    const event = sentry.Event.initMessage("envelope integration test", .info);

    var aw: std.io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try sentry.envelope.serializeEventEnvelope(testing.allocator, event, dsn, &aw.writer);
    const output = aw.written();

    // Split by newlines
    var lines = std.mem.splitScalar(u8, output, '\n');
    const line1 = lines.next().?; // envelope header
    const line2 = lines.next().?; // item header
    const line3 = lines.rest(); // payload

    // Line 1: envelope header with event_id, dsn, sent_at, sdk
    try testing.expect(std.mem.indexOf(u8, line1, "\"event_id\"") != null);
    try testing.expect(std.mem.indexOf(u8, line1, "\"dsn\"") != null);
    try testing.expect(std.mem.indexOf(u8, line1, "\"sent_at\"") != null);
    try testing.expect(std.mem.indexOf(u8, line1, "\"sentry-zig\"") != null);
    try testing.expect(std.mem.indexOf(u8, line1, "testkey") != null);

    // Line 2: item header with type "event" and length
    try testing.expect(std.mem.indexOf(u8, line2, "\"type\":\"event\"") != null);
    try testing.expect(std.mem.indexOf(u8, line2, "\"length\":") != null);

    // Line 3: non-empty payload
    try testing.expect(line3.len > 0);

    // Verify payload length matches declared length
    const length_prefix = "\"length\":";
    const length_start = std.mem.indexOf(u8, line2, length_prefix).? + length_prefix.len;
    const length_end = std.mem.indexOf(u8, line2[length_start..], "}").? + length_start;
    const declared_length = try std.fmt.parseInt(usize, line2[length_start..length_end], 10);
    try testing.expectEqual(declared_length, line3.len);
}

// ─── 8. Timestamp Formatting ────────────────────────────────────────────────

test "Timestamp: now() is reasonable" {
    const t = sentry.timestamp.now();

    // Should be after 2024-01-01T00:00:00Z (1704067200)
    try testing.expect(t > 1704067200.0);

    // Should be before 2100-01-01T00:00:00Z (4102444800)
    try testing.expect(t < 4102444800.0);
}

test "Timestamp: RFC 3339 format" {
    const rfc3339 = sentry.timestamp.nowRfc3339();

    // Length should be exactly 24 characters: YYYY-MM-DDTHH:MM:SS.mmmZ
    try testing.expectEqual(@as(usize, 24), rfc3339.len);

    // Should start with "20" (21st century)
    try testing.expectEqualStrings("20", rfc3339[0..2]);

    // Verify structural characters
    try testing.expectEqual(@as(u8, '-'), rfc3339[4]);
    try testing.expectEqual(@as(u8, '-'), rfc3339[7]);
    try testing.expectEqual(@as(u8, 'T'), rfc3339[10]);
    try testing.expectEqual(@as(u8, ':'), rfc3339[13]);
    try testing.expectEqual(@as(u8, ':'), rfc3339[16]);
    try testing.expectEqual(@as(u8, '.'), rfc3339[19]);
    try testing.expectEqual(@as(u8, 'Z'), rfc3339[23]);
}

test "Timestamp: known epoch formatting" {
    // 2025-02-25T12:00:00.000Z
    const result = sentry.timestamp.formatRfc3339(1740484800000);
    try testing.expectEqualStrings("2025-02-25T12:00:00.000Z", &result);
}
