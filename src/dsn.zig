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
    secret_key: ?[]const u8,
    host: []const u8,
    port: ?u16,
    path: []const u8,
    project_id: []const u8,

    /// Parse a Sentry DSN string.
    /// Format: {PROTOCOL}://{PUBLIC_KEY}@{HOST}/{PATH}{PROJECT_ID}
    pub fn parse(dsn_string: []const u8) DsnError!Dsn {
        const uri = std.Uri.parse(dsn_string) catch return DsnError.InvalidDsn;
        if (uri.scheme.len == 0) return DsnError.InvalidDsn;

        const user = uri.user orelse return DsnError.MissingPublicKey;
        const public_key = componentSlice(user);
        if (public_key.len == 0) return DsnError.MissingPublicKey;

        const host_component = uri.host orelse return DsnError.MissingHost;
        const host = componentSlice(host_component);
        if (host.len == 0) return DsnError.MissingHost;

        var raw_path = componentSlice(uri.path);
        if (raw_path.len == 0 or mem.eql(u8, raw_path, "/")) return DsnError.MissingProjectId;
        if (raw_path[0] == '/') {
            raw_path = raw_path[1..];
        }
        if (raw_path.len == 0) return DsnError.MissingProjectId;

        var path: []const u8 = "";
        var project_id: []const u8 = raw_path;

        if (mem.lastIndexOfScalar(u8, raw_path, '/')) |last_slash| {
            path = raw_path[0 .. last_slash + 1];
            project_id = raw_path[last_slash + 1 ..];
        }
        if (project_id.len == 0) return DsnError.MissingProjectId;

        const secret_key = if (uri.password) |pwd| componentSlice(pwd) else null;

        return Dsn{
            .scheme = uri.scheme,
            .public_key = public_key,
            .secret_key = secret_key,
            .host = host,
            .port = uri.port,
            .path = path,
            .project_id = project_id,
        };
    }

    /// Generate the envelope endpoint URL.
    /// Format: {scheme}://{host}[:{port}]/{path}api/{project_id}/envelope/
    pub fn getEnvelopeUrl(self: Dsn, allocator: Allocator) Allocator.Error![]u8 {
        const ipv6 = isIpv6Host(self.host);
        if (self.port) |p| {
            if (ipv6) {
                return std.fmt.allocPrint(allocator, "{s}://[{s}]:{d}/{s}api/{s}/envelope/", .{
                    self.scheme, self.host, p, self.path, self.project_id,
                });
            }

            return std.fmt.allocPrint(allocator, "{s}://{s}:{d}/{s}api/{s}/envelope/", .{
                self.scheme, self.host, p, self.path, self.project_id,
            });
        } else {
            if (ipv6) {
                return std.fmt.allocPrint(allocator, "{s}://[{s}]/{s}api/{s}/envelope/", .{
                    self.scheme, self.host, self.path, self.project_id,
                });
            }

            return std.fmt.allocPrint(allocator, "{s}://{s}/{s}api/{s}/envelope/", .{
                self.scheme, self.host, self.path, self.project_id,
            });
        }
    }

    /// Reconstruct the original DSN string.
    pub fn writeDsn(self: Dsn, writer: anytype) !void {
        try writer.print("{s}://{s}", .{ self.scheme, self.public_key });
        if (self.secret_key) |secret| {
            try writer.print(":{s}", .{secret});
        }
        try writer.writeByte('@');

        if (isIpv6Host(self.host)) {
            try writer.print("[{s}]", .{self.host});
        } else {
            try writer.writeAll(self.host);
        }

        if (self.port) |p| {
            try writer.print(":{d}", .{p});
        }
        try writer.print("/{s}{s}", .{ self.path, self.project_id });
    }
};

fn componentSlice(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw => |s| s,
        .percent_encoded => |s| s,
    };
}

fn isIpv6Host(host: []const u8) bool {
    return mem.indexOfScalar(u8, host, ':') != null;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "parse standard DSN" {
    const dsn = try Dsn.parse("https://examplePublicKey@o0.ingest.sentry.io/1234567");
    try testing.expectEqualStrings("https", dsn.scheme);
    try testing.expectEqualStrings("examplePublicKey", dsn.public_key);
    try testing.expect(dsn.secret_key == null);
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

test "parse DSN with secret key" {
    const dsn = try Dsn.parse("https://public:secret@sentry.example.com/42");
    try testing.expectEqualStrings("public", dsn.public_key);
    try testing.expectEqualStrings("secret", dsn.secret_key.?);
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

test "writeDsn roundtrip with secret key" {
    const original = "https://public:secret@sentry.example.com/42";
    const dsn = try Dsn.parse(original);
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try dsn.writeDsn(stream.writer());
    const written = stream.getWritten();
    try testing.expectEqualStrings(original, written);
}
