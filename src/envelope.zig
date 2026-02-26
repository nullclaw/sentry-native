const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const json = std.json;
const Writer = std.io.Writer;

const Dsn = @import("dsn.zig").Dsn;
const Event = @import("event.zig").Event;
const ts = @import("timestamp.zig");

pub const SDK_NAME = "sentry-zig";
pub const SDK_VERSION = "0.1.0";

/// Serialize a complete event envelope.
///
/// The Sentry envelope format is newline-delimited:
///   {envelope_header_json}\n
///   {item_header_json}\n
///   {item_payload}
pub fn serializeEventEnvelope(allocator: Allocator, event: Event, dsn: Dsn, writer: *Writer) !void {
    // First, serialize the event payload to get its byte length.
    const payload = try json.Stringify.valueAlloc(
        allocator,
        event,
        .{ .emit_null_optional_fields = false },
    );
    defer allocator.free(payload);

    // Envelope header line
    try writer.writeAll("{\"event_id\":\"");
    try writer.writeAll(&event.event_id);
    try writer.writeAll("\",\"dsn\":\"");
    try dsn.writeDsn(writer);
    try writer.writeAll("\",\"sent_at\":\"");
    const rfc3339 = ts.nowRfc3339();
    try writer.writeAll(&rfc3339);
    try writer.writeAll("\",\"sdk\":{\"name\":\"");
    try writer.writeAll(SDK_NAME);
    try writer.writeAll("\",\"version\":\"");
    try writer.writeAll(SDK_VERSION);
    try writer.writeAll("\"}}");
    try writer.writeByte('\n');

    // Item header line
    try writer.writeAll("{\"type\":\"event\",\"length\":");
    try writer.print("{d}", .{payload.len});
    try writer.writeByte('}');
    try writer.writeByte('\n');

    // Payload
    try writer.writeAll(payload);
}

/// Serialize a session envelope.
///
/// Session envelopes do not include event_id in the header.
pub fn serializeSessionEnvelope(dsn: Dsn, session_json: []const u8, writer: *Writer) !void {
    // Envelope header line (no event_id for sessions)
    try writer.writeAll("{\"dsn\":\"");
    try dsn.writeDsn(writer);
    try writer.writeAll("\",\"sent_at\":\"");
    const rfc3339 = ts.nowRfc3339();
    try writer.writeAll(&rfc3339);
    try writer.writeAll("\",\"sdk\":{\"name\":\"");
    try writer.writeAll(SDK_NAME);
    try writer.writeAll("\",\"version\":\"");
    try writer.writeAll(SDK_VERSION);
    try writer.writeAll("\"}}");
    try writer.writeByte('\n');

    // Item header line
    try writer.writeAll("{\"type\":\"session\",\"length\":");
    try writer.print("{d}", .{session_json.len});
    try writer.writeByte('}');
    try writer.writeByte('\n');

    // Payload
    try writer.writeAll(session_json);
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "serializeEventEnvelope produces 3-line format" {
    const allocator = testing.allocator;
    const dsn = try Dsn.parse("https://examplePublicKey@o0.ingest.sentry.io/1234567");
    const event = Event.initMessage("test envelope", .info);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try serializeEventEnvelope(allocator, event, dsn, &aw.writer);
    const output = aw.written();

    // Split by newlines — expect exactly 3 parts (header, item header, payload)
    var lines = std.mem.splitScalar(u8, output, '\n');
    const line1 = lines.next().?; // envelope header
    const line2 = lines.next().?; // item header
    const line3 = lines.rest(); // payload (may not have trailing newline)

    // Verify line 1 (envelope header) contains required fields
    try testing.expect(std.mem.indexOf(u8, line1, "\"event_id\"") != null);
    try testing.expect(std.mem.indexOf(u8, line1, "\"dsn\"") != null);
    try testing.expect(std.mem.indexOf(u8, line1, "\"sent_at\"") != null);
    try testing.expect(std.mem.indexOf(u8, line1, "\"sentry-zig\"") != null);

    // Verify line 2 (item header) has type and length
    try testing.expect(std.mem.indexOf(u8, line2, "\"type\":\"event\"") != null);
    try testing.expect(std.mem.indexOf(u8, line2, "\"length\":") != null);

    // Verify payload is non-empty
    try testing.expect(line3.len > 0);
}

test "serializeEventEnvelope payload length matches declared length" {
    const allocator = testing.allocator;
    const dsn = try Dsn.parse("https://examplePublicKey@o0.ingest.sentry.io/1234567");
    const event = Event.initMessage("length test", .warning);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try serializeEventEnvelope(allocator, event, dsn, &aw.writer);
    const output = aw.written();

    // Extract the item header line and payload
    var lines = std.mem.splitScalar(u8, output, '\n');
    _ = lines.next(); // skip envelope header
    const item_header = lines.next().?;
    const payload = lines.rest();

    // Parse the declared length from item header
    const length_prefix = "\"length\":";
    const length_start = std.mem.indexOf(u8, item_header, length_prefix).? + length_prefix.len;
    const length_end = std.mem.indexOf(u8, item_header[length_start..], "}").? + length_start;
    const declared_length = try std.fmt.parseInt(usize, item_header[length_start..length_end], 10);

    try testing.expectEqual(declared_length, payload.len);
}

test "serializeEventEnvelope envelope header contains dsn" {
    const allocator = testing.allocator;
    const dsn = try Dsn.parse("https://examplePublicKey@o0.ingest.sentry.io/1234567");
    const event = Event.init();

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try serializeEventEnvelope(allocator, event, dsn, &aw.writer);
    const output = aw.written();

    // The DSN string should appear in the envelope header
    try testing.expect(std.mem.indexOf(u8, output, "o0.ingest.sentry.io") != null);
    try testing.expect(std.mem.indexOf(u8, output, "examplePublicKey") != null);
}

test "serializeSessionEnvelope produces valid format" {
    const dsn = try Dsn.parse("https://key@sentry.example.com/42");
    const session_json = "{\"sid\":\"abc\",\"status\":\"ok\"}";

    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try serializeSessionEnvelope(dsn, session_json, &aw.writer);
    const output = aw.written();

    var lines = std.mem.splitScalar(u8, output, '\n');
    const line1 = lines.next().?;
    const line2 = lines.next().?;
    const line3 = lines.rest();

    // Session envelope should NOT have event_id
    try testing.expect(std.mem.indexOf(u8, line1, "\"event_id\"") == null);
    // Should have dsn and sdk
    try testing.expect(std.mem.indexOf(u8, line1, "\"dsn\"") != null);
    try testing.expect(std.mem.indexOf(u8, line1, "\"sentry-zig\"") != null);

    // Item header should be session type
    try testing.expect(std.mem.indexOf(u8, line2, "\"type\":\"session\"") != null);

    // Payload should match
    try testing.expectEqualStrings(session_json, line3);
}
