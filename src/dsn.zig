const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const DsnError = error{
    InvalidDsn,
    MissingPublicKey,
    MissingProjectId,
    MissingHost,
};

pub const Dsn = struct {
    scheme: []const u8,
    public_key: []const u8,
    host: []const u8,
    port: ?u16,
    path: []const u8,
    project_id: []const u8,

    /// Parse a Sentry DSN string.
    /// Format: {PROTOCOL}://{PUBLIC_KEY}@{HOST}/{PATH}{PROJECT_ID}
    pub fn parse(dsn_string: []const u8) DsnError!Dsn {
        // Find scheme separator "://"
        const scheme_end = mem.indexOf(u8, dsn_string, "://") orelse return DsnError.InvalidDsn;
        const scheme = dsn_string[0..scheme_end];
        if (scheme.len == 0) return DsnError.InvalidDsn;

        const after_scheme = dsn_string[scheme_end + 3 ..];

        // Find '@' to separate public_key from host
        const at_pos = mem.indexOf(u8, after_scheme, "@") orelse return DsnError.MissingPublicKey;
        const public_key = after_scheme[0..at_pos];
        if (public_key.len == 0) return DsnError.MissingPublicKey;

        const after_at = after_scheme[at_pos + 1 ..];
        if (after_at.len == 0) return DsnError.MissingHost;

        // Find the first '/' after host (and optional port)
        const slash_pos = mem.indexOf(u8, after_at, "/") orelse return DsnError.MissingProjectId;
        const host_port = after_at[0..slash_pos];
        if (host_port.len == 0) return DsnError.MissingHost;

        const after_host_slash = after_at[slash_pos + 1 ..];

        // Parse host and optional port
        var host: []const u8 = undefined;
        var port: ?u16 = null;
        if (mem.indexOf(u8, host_port, ":")) |colon_pos| {
            host = host_port[0..colon_pos];
            const port_str = host_port[colon_pos + 1 ..];
            port = std.fmt.parseInt(u16, port_str, 10) catch return DsnError.InvalidDsn;
        } else {
            host = host_port;
        }
        if (host.len == 0) return DsnError.MissingHost;

        // The rest is path + project_id. The project_id is the last path segment.
        // e.g., "my/path/42" => path="my/path/", project_id="42"
        // e.g., "42" => path="", project_id="42"
        if (after_host_slash.len == 0) return DsnError.MissingProjectId;

        var path: []const u8 = "";
        var project_id: []const u8 = after_host_slash;

        if (mem.lastIndexOf(u8, after_host_slash, "/")) |last_slash| {
            path = after_host_slash[0 .. last_slash + 1];
            project_id = after_host_slash[last_slash + 1 ..];
        }

        if (project_id.len == 0) return DsnError.MissingProjectId;

        return Dsn{
            .scheme = scheme,
            .public_key = public_key,
            .host = host,
            .port = port,
            .path = path,
            .project_id = project_id,
        };
    }

    /// Generate the envelope endpoint URL.
    /// Format: {scheme}://{host}[:{port}]/{path}api/{project_id}/envelope/
    pub fn getEnvelopeUrl(self: Dsn, allocator: Allocator) Allocator.Error![]u8 {
        if (self.port) |p| {
            return std.fmt.allocPrint(allocator, "{s}://{s}:{d}/{s}api/{s}/envelope/", .{
                self.scheme, self.host, p, self.path, self.project_id,
            });
        } else {
            return std.fmt.allocPrint(allocator, "{s}://{s}/{s}api/{s}/envelope/", .{
                self.scheme, self.host, self.path, self.project_id,
            });
        }
    }

    /// Reconstruct the original DSN string.
    pub fn writeDsn(self: Dsn, writer: anytype) !void {
        try writer.print("{s}://{s}@{s}", .{ self.scheme, self.public_key, self.host });
        if (self.port) |p| {
            try writer.print(":{d}", .{p});
        }
        try writer.print("/{s}{s}", .{ self.path, self.project_id });
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

test "parse standard DSN" {
    const dsn = try Dsn.parse("https://examplePublicKey@o0.ingest.sentry.io/1234567");
    try testing.expectEqualStrings("https", dsn.scheme);
    try testing.expectEqualStrings("examplePublicKey", dsn.public_key);
    try testing.expectEqualStrings("o0.ingest.sentry.io", dsn.host);
    try testing.expect(dsn.port == null);
    try testing.expectEqualStrings("", dsn.path);
    try testing.expectEqualStrings("1234567", dsn.project_id);
}

test "parse DSN with port" {
    const dsn = try Dsn.parse("https://key@sentry.example.com:9000/42");
    try testing.expectEqualStrings("https", dsn.scheme);
    try testing.expectEqualStrings("key", dsn.public_key);
    try testing.expectEqualStrings("sentry.example.com", dsn.host);
    try testing.expectEqual(@as(u16, 9000), dsn.port.?);
    try testing.expectEqualStrings("", dsn.path);
    try testing.expectEqualStrings("42", dsn.project_id);
}

test "parse DSN with path" {
    const dsn = try Dsn.parse("https://key@sentry.example.com/my/path/42");
    try testing.expectEqualStrings("https", dsn.scheme);
    try testing.expectEqualStrings("key", dsn.public_key);
    try testing.expectEqualStrings("sentry.example.com", dsn.host);
    try testing.expect(dsn.port == null);
    try testing.expectEqualStrings("my/path/", dsn.path);
    try testing.expectEqualStrings("42", dsn.project_id);
}

test "envelope URL generation" {
    const dsn = try Dsn.parse("https://examplePublicKey@o0.ingest.sentry.io/1234567");
    const url = try dsn.getEnvelopeUrl(testing.allocator);
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("https://o0.ingest.sentry.io/api/1234567/envelope/", url);
}

test "envelope URL with port" {
    const dsn = try Dsn.parse("https://key@sentry.example.com:9000/42");
    const url = try dsn.getEnvelopeUrl(testing.allocator);
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("https://sentry.example.com:9000/api/42/envelope/", url);
}

test "envelope URL with path" {
    const dsn = try Dsn.parse("https://key@sentry.example.com/my/path/42");
    const url = try dsn.getEnvelopeUrl(testing.allocator);
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("https://sentry.example.com/my/path/api/42/envelope/", url);
}

test "invalid DSN - missing scheme" {
    const result = Dsn.parse("no-scheme-here");
    try testing.expectError(DsnError.InvalidDsn, result);
}

test "invalid DSN - empty scheme" {
    const result = Dsn.parse("://key@host/1");
    try testing.expectError(DsnError.InvalidDsn, result);
}

test "invalid DSN - missing public key" {
    const result = Dsn.parse("https://@host/1");
    try testing.expectError(DsnError.MissingPublicKey, result);
}

test "invalid DSN - no @ sign" {
    const result = Dsn.parse("https://host/1");
    try testing.expectError(DsnError.MissingPublicKey, result);
}

test "invalid DSN - missing project id" {
    const result = Dsn.parse("https://key@host/");
    try testing.expectError(DsnError.MissingProjectId, result);
}

test "invalid DSN - missing host" {
    const result = Dsn.parse("https://key@/1");
    try testing.expectError(DsnError.MissingHost, result);
}

test "writeDsn roundtrip" {
    const original = "https://examplePublicKey@o0.ingest.sentry.io/1234567";
    const dsn = try Dsn.parse(original);
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try dsn.writeDsn(stream.writer());
    const written = stream.getWritten();
    try testing.expectEqualStrings(original, written);
}

test "writeDsn roundtrip with port" {
    const original = "https://key@sentry.example.com:9000/42";
    const dsn = try Dsn.parse(original);
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try dsn.writeDsn(stream.writer());
    const written = stream.getWritten();
    try testing.expectEqualStrings(original, written);
}
