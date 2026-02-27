const std = @import("std");
const testing = std.testing;

const Client = @import("../client.zig").Client;
const Hub = @import("../hub.zig").Hub;
const Span = @import("../transaction.zig").Span;
const Transaction = @import("../transaction.zig").Transaction;
const TransactionOpts = @import("../transaction.zig").TransactionOpts;
const PropagationHeader = @import("../propagation.zig").PropagationHeader;

pub const TraceParentContext = struct {
    trace_id: [32]u8,
    parent_span_id: [16]u8,
    sampled: ?bool = null,
};

fn parseHexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn parseHexByte(chars: []const u8) ?u8 {
    if (chars.len != 2) return null;
    const hi = parseHexNibble(chars[0]) orelse return null;
    const lo = parseHexNibble(chars[1]) orelse return null;
    return (hi << 4) | lo;
}

fn isAllZeros(value: []const u8) bool {
    for (value) |c| {
        if (c != '0') return false;
    }
    return true;
}

/// Parse W3C `traceparent` header.
pub fn parseTraceParent(traceparent: []const u8) ?TraceParentContext {
    const trimmed = std.mem.trim(u8, traceparent, " \t");
    var it = std.mem.splitScalar(u8, trimmed, '-');

    const version = it.next() orelse return null;
    const trace_id_text = it.next() orelse return null;
    const span_id_text = it.next() orelse return null;
    const flags_text = it.next() orelse return null;

    if (version.len != 2 or trace_id_text.len != 32 or span_id_text.len != 16 or flags_text.len != 2) return null;
    _ = parseHexNibble(version[0]) orelse return null;
    _ = parseHexNibble(version[1]) orelse return null;
    if (std.ascii.eqlIgnoreCase(version, "ff")) return null;
    if (std.mem.eql(u8, version, "00") and it.next() != null) return null;
    if (isAllZeros(trace_id_text) or isAllZeros(span_id_text)) return null;

    var trace_id: [32]u8 = undefined;
    for (trace_id_text, 0..) |c, i| {
        _ = parseHexNibble(c) orelse return null;
        trace_id[i] = std.ascii.toLower(c);
    }

    var parent_span_id: [16]u8 = undefined;
    for (span_id_text, 0..) |c, i| {
        _ = parseHexNibble(c) orelse return null;
        parent_span_id[i] = std.ascii.toLower(c);
    }

    const flags = parseHexByte(flags_text) orelse return null;
    return .{
        .trace_id = trace_id,
        .parent_span_id = parent_span_id,
        .sampled = (flags & 1) != 0,
    };
}

/// Find and parse `traceparent` from raw header list.
pub fn parseTraceParentFromHeaders(headers: []const PropagationHeader) ?TraceParentContext {
    for (headers) |header| {
        const name = std.mem.trim(u8, header.name, " \t");
        if (std.ascii.eqlIgnoreCase(name, "traceparent")) {
            return parseTraceParent(header.value);
        }
    }
    return null;
}

/// Build W3C `traceparent` header from transaction context.
pub fn traceParentFromTransactionAlloc(allocator: std.mem.Allocator, txn: *const Transaction) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "00-{s}-{s}-{s}",
        .{
            txn.trace_id[0..],
            txn.span_id[0..],
            if (txn.sampled) "01" else "00",
        },
    );
}

/// Build W3C `traceparent` header from span context.
pub fn traceParentFromSpanAlloc(allocator: std.mem.Allocator, span: *const Span) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "00-{s}-{s}-{s}",
        .{
            span.trace_id[0..],
            span.span_id[0..],
            if (span.sampled) "01" else "00",
        },
    );
}

/// Start transaction from explicit W3C `traceparent` header.
pub fn startTransactionFromTraceParent(
    client: *Client,
    opts: TransactionOpts,
    traceparent: []const u8,
) !Transaction {
    const parsed = parseTraceParent(traceparent) orelse return error.InvalidTraceParent;
    var actual = opts;
    actual.parent_trace_id = parsed.trace_id;
    actual.parent_span_id = parsed.parent_span_id;
    actual.parent_sampled = parsed.sampled;
    return client.startTransaction(actual);
}

/// Start transaction from current Hub using W3C `traceparent`.
pub fn startCurrentHubTransactionFromTraceParent(
    opts: TransactionOpts,
    traceparent: []const u8,
) !Transaction {
    const hub = Hub.current() orelse return error.NoCurrentHub;
    const parsed = parseTraceParent(traceparent) orelse return error.InvalidTraceParent;
    var actual = opts;
    actual.parent_trace_id = parsed.trace_id;
    actual.parent_span_id = parsed.parent_span_id;
    actual.parent_sampled = parsed.sampled;
    return hub.startTransaction(actual);
}

test "parseTraceParent parses valid header" {
    const parsed = parseTraceParent("00-0123456789abcdef0123456789abcdef-89abcdef01234567-01").?;
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef", parsed.trace_id[0..]);
    try testing.expectEqualStrings("89abcdef01234567", parsed.parent_span_id[0..]);
    try testing.expectEqual(@as(?bool, true), parsed.sampled);
}

test "parseTraceParent rejects malformed input" {
    try testing.expect(parseTraceParent("invalid") == null);
    try testing.expect(parseTraceParent("00-00000000000000000000000000000000-89abcdef01234567-01") == null);
    try testing.expect(parseTraceParent("00-0123456789abcdef0123456789abcdef-0000000000000000-01") == null);
    try testing.expect(parseTraceParent("ff-0123456789abcdef0123456789abcdef-89abcdef01234567-01") == null);
    try testing.expect(parseTraceParent("zz-0123456789abcdef0123456789abcdef-89abcdef01234567-01") == null);
}

test "parseTraceParent accepts future versions with trailing data" {
    const parsed = parseTraceParent("01-0123456789abcdef0123456789abcdef-89abcdef01234567-01-extra").?;
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef", parsed.trace_id[0..]);
    try testing.expectEqualStrings("89abcdef01234567", parsed.parent_span_id[0..]);
    try testing.expectEqual(@as(?bool, true), parsed.sampled);
}

test "parseTraceParent normalizes uppercase identifiers to lowercase" {
    const parsed = parseTraceParent("00-0123456789ABCDEF0123456789ABCDEF-89ABCDEF01234567-01").?;
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef", parsed.trace_id[0..]);
    try testing.expectEqualStrings("89abcdef01234567", parsed.parent_span_id[0..]);
}

test "parseTraceParentFromHeaders is case-insensitive" {
    const headers = [_]PropagationHeader{
        .{
            .name = "TrAcEpArEnT",
            .value = "00-0123456789abcdef0123456789abcdef-89abcdef01234567-01",
        },
    };
    const parsed = parseTraceParentFromHeaders(&headers).?;
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef", parsed.trace_id[0..]);
}

test "startTransactionFromTraceParent continues trace ids" {
    const client = try Client.init(testing.allocator, .{
        .dsn = "https://examplePublicKey@o0.ingest.sentry.io/1234567",
        .traces_sample_rate = 1.0,
        .install_signal_handlers = false,
    });
    defer client.deinit();

    var txn = try startTransactionFromTraceParent(
        client,
        .{
            .name = "GET /otel",
            .op = "http.server",
        },
        "00-0123456789abcdef0123456789abcdef-89abcdef01234567-01",
    );
    defer txn.deinit();

    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef", txn.trace_id[0..]);
    try testing.expectEqualStrings("89abcdef01234567", txn.parent_span_id.?[0..]);
    try testing.expectEqual(@as(?bool, true), txn.parent_sampled);
}

test "traceParentFromTransactionAlloc encodes transaction context" {
    const client = try Client.init(testing.allocator, .{
        .dsn = "https://examplePublicKey@o0.ingest.sentry.io/1234567",
        .traces_sample_rate = 1.0,
        .install_signal_handlers = false,
    });
    defer client.deinit();

    var txn = client.startTransaction(.{
        .name = "GET /otel-out",
        .op = "http.server",
    });
    defer txn.deinit();

    const traceparent = try traceParentFromTransactionAlloc(testing.allocator, &txn);
    defer testing.allocator.free(traceparent);

    try testing.expect(std.mem.startsWith(u8, traceparent, "00-"));
    try testing.expect(std.mem.indexOf(u8, traceparent, txn.trace_id[0..]) != null);
    try testing.expect(std.mem.indexOf(u8, traceparent, txn.span_id[0..]) != null);
}
