const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const json = std.json;

const event_mod = @import("event.zig");
const Event = event_mod.Event;
const User = event_mod.User;
const Breadcrumb = event_mod.Breadcrumb;
const ts = @import("timestamp.zig");

pub const MAX_BREADCRUMBS = 200;

pub const ApplyResult = struct {
    user_allocated: bool = false,
    tags_allocated: bool = false,
    extra_allocated: bool = false,
    contexts_allocated: bool = false,
    breadcrumbs_allocated: bool = false,
};

fn cloneOptionalString(allocator: Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |v| return try allocator.dupe(u8, v);
    return null;
}

fn deinitOptionalString(allocator: Allocator, value: *?[]const u8) void {
    if (value.*) |v| {
        allocator.free(@constCast(v));
        value.* = null;
    }
}

fn cloneUser(allocator: Allocator, user: User) !User {
    var copy: User = .{};
    copy.id = try cloneOptionalString(allocator, user.id);
    errdefer deinitUserDeep(allocator, &copy);

    copy.email = try cloneOptionalString(allocator, user.email);
    copy.username = try cloneOptionalString(allocator, user.username);
    copy.ip_address = try cloneOptionalString(allocator, user.ip_address);
    copy.segment = try cloneOptionalString(allocator, user.segment);
    return copy;
}

pub fn deinitUserDeep(allocator: Allocator, user: *User) void {
    deinitOptionalString(allocator, &user.id);
    deinitOptionalString(allocator, &user.email);
    deinitOptionalString(allocator, &user.username);
    deinitOptionalString(allocator, &user.ip_address);
    deinitOptionalString(allocator, &user.segment);
}

pub fn deinitJsonValueDeep(allocator: Allocator, value: *json.Value) void {
    switch (value.*) {
        .number_string => |s| allocator.free(@constCast(s)),
        .string => |s| allocator.free(@constCast(s)),
        .array => |*arr| {
            for (arr.items) |*item| {
                deinitJsonValueDeep(allocator, item);
            }
            arr.deinit();
        },
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(@constCast(entry.key_ptr.*));
                deinitJsonValueDeep(allocator, entry.value_ptr);
            }
            obj.deinit();
        },
        else => {},
    }
    value.* = .null;
}

fn deinitJsonObjectDeep(allocator: Allocator, obj: *json.ObjectMap) void {
    var it = obj.iterator();
    while (it.next()) |entry| {
        allocator.free(@constCast(entry.key_ptr.*));
        deinitJsonValueDeep(allocator, entry.value_ptr);
    }
    obj.deinit();
}

fn cloneJsonValue(allocator: Allocator, value: json.Value) !json.Value {
    return switch (value) {
        .null => .null,
        .bool => |v| .{ .bool = v },
        .integer => |v| .{ .integer = v },
        .float => |v| .{ .float = v },
        .number_string => |v| .{ .number_string = try allocator.dupe(u8, v) },
        .string => |v| .{ .string = try allocator.dupe(u8, v) },
        .array => |arr| blk: {
            var copy = json.Array.init(allocator);
            errdefer {
                for (copy.items) |*item| {
                    deinitJsonValueDeep(allocator, item);
                }
                copy.deinit();
            }

            for (arr.items) |item| {
                try copy.append(try cloneJsonValue(allocator, item));
            }
            break :blk .{ .array = copy };
        },
        .object => |obj| blk: {
            var copy = json.ObjectMap.init(allocator);
            errdefer deinitJsonObjectDeep(allocator, &copy);

            var it = obj.iterator();
            while (it.next()) |entry| {
                const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key_copy);

                var value_copy = try cloneJsonValue(allocator, entry.value_ptr.*);
                errdefer deinitJsonValueDeep(allocator, &value_copy);

                try copy.put(key_copy, value_copy);
            }
            break :blk .{ .object = copy };
        },
    };
}

fn cloneBreadcrumb(allocator: Allocator, crumb: Breadcrumb) !Breadcrumb {
    var copy: Breadcrumb = .{
        .timestamp = crumb.timestamp,
        .level = crumb.level,
    };
    copy.type = try cloneOptionalString(allocator, crumb.type);
    errdefer deinitBreadcrumbDeep(allocator, &copy);

    copy.category = try cloneOptionalString(allocator, crumb.category);
    copy.message = try cloneOptionalString(allocator, crumb.message);
    copy.data = if (crumb.data) |value| try cloneJsonValue(allocator, value) else null;
    return copy;
}

pub fn deinitBreadcrumbDeep(allocator: Allocator, crumb: *Breadcrumb) void {
    deinitOptionalString(allocator, &crumb.type);
    deinitOptionalString(allocator, &crumb.category);
    deinitOptionalString(allocator, &crumb.message);
    if (crumb.data) |*value| {
        deinitJsonValueDeep(allocator, value);
    }
    crumb.data = null;
}

/// Fixed-size ring buffer for breadcrumbs.
pub const BreadcrumbBuffer = struct {
    buffer: []Breadcrumb,
    capacity: usize,
    head: usize = 0,
    count: usize = 0,
    allocator: Allocator,

    pub fn init(allocator: Allocator, capacity: usize) !BreadcrumbBuffer {
        const clamped = if (capacity > MAX_BREADCRUMBS) MAX_BREADCRUMBS else capacity;
        const cap = if (clamped == 0) 1 else clamped; // at least 1 to avoid division by zero
        const buf = try allocator.alloc(Breadcrumb, cap);
        return BreadcrumbBuffer{
            .buffer = buf,
            .capacity = cap,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BreadcrumbBuffer) void {
        self.clear();
        self.allocator.free(self.buffer);
        self.* = undefined;
    }

    /// O(1) push. Overwrites oldest breadcrumb when full.
    pub fn push(self: *BreadcrumbBuffer, crumb: Breadcrumb) void {
        if (self.count == self.capacity) {
            deinitBreadcrumbDeep(self.allocator, &self.buffer[self.head]);
        } else {
            self.count += 1;
        }

        self.buffer[self.head] = crumb;
        self.head = (self.head + 1) % self.capacity;
    }

    /// Return breadcrumbs in insertion order.
    pub fn toSlice(self: *const BreadcrumbBuffer, allocator: Allocator) ![]Breadcrumb {
        const result = try allocator.alloc(Breadcrumb, self.count);
        if (self.count < self.capacity) {
            // Buffer has not wrapped around yet.
            @memcpy(result, self.buffer[0..self.count]);
        } else {
            // Buffer has wrapped; oldest is at head.
            const first_part_len = self.capacity - self.head;
            @memcpy(result[0..first_part_len], self.buffer[self.head..self.capacity]);
            @memcpy(result[first_part_len..], self.buffer[0..self.head]);
        }
        return result;
    }

    pub fn clear(self: *BreadcrumbBuffer) void {
        if (self.count == 0) {
            self.head = 0;
            return;
        }

        if (self.count < self.capacity) {
            for (self.buffer[0..self.count]) |*crumb| {
                deinitBreadcrumbDeep(self.allocator, crumb);
            }
        } else {
            for (self.buffer) |*crumb| {
                deinitBreadcrumbDeep(self.allocator, crumb);
            }
        }

        self.head = 0;
        self.count = 0;
    }
};

fn clearTagMapOwned(allocator: Allocator, map: *std.StringHashMap([]const u8)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(@constCast(entry.key_ptr.*));
        allocator.free(@constCast(entry.value_ptr.*));
    }
    map.clearRetainingCapacity();
}

fn deinitTagMapOwned(allocator: Allocator, map: *std.StringHashMap([]const u8)) void {
    clearTagMapOwned(allocator, map);
    map.deinit();
}

fn clearJsonMapOwned(allocator: Allocator, map: *std.StringHashMap(json.Value)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(@constCast(entry.key_ptr.*));
        deinitJsonValueDeep(allocator, entry.value_ptr);
    }
    map.clearRetainingCapacity();
}

fn deinitJsonMapOwned(allocator: Allocator, map: *std.StringHashMap(json.Value)) void {
    clearJsonMapOwned(allocator, map);
    map.deinit();
}

/// The Scope holds mutable state applied to every event.
pub const Scope = struct {
    allocator: Allocator,
    user: ?User = null,
    tags: std.StringHashMap([]const u8),
    extra: std.StringHashMap(json.Value),
    contexts: std.StringHashMap(json.Value),
    breadcrumbs: BreadcrumbBuffer,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: Allocator, max_breadcrumbs: usize) !Scope {
        return Scope{
            .allocator = allocator,
            .tags = std.StringHashMap([]const u8).init(allocator),
            .extra = std.StringHashMap(json.Value).init(allocator),
            .contexts = std.StringHashMap(json.Value).init(allocator),
            .breadcrumbs = try BreadcrumbBuffer.init(allocator, max_breadcrumbs),
        };
    }

    pub fn deinit(self: *Scope) void {
        if (self.user) |*u| {
            deinitUserDeep(self.allocator, u);
            self.user = null;
        }

        deinitTagMapOwned(self.allocator, &self.tags);
        deinitJsonMapOwned(self.allocator, &self.extra);
        deinitJsonMapOwned(self.allocator, &self.contexts);
        self.breadcrumbs.deinit();
        self.* = undefined;
    }

    /// Set the user context (thread-safe).
    pub fn setUser(self: *Scope, user: ?User) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.user) |*existing| {
            deinitUserDeep(self.allocator, existing);
            self.user = null;
        }

        if (user) |u| {
            self.user = cloneUser(self.allocator, u) catch null;
        }
    }

    /// Set a tag (thread-safe).
    pub fn setTag(self: *Scope, key: []const u8, value: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.tags.fetchRemove(key)) |kv| {
            self.allocator.free(@constCast(kv.key));
            self.allocator.free(@constCast(kv.value));
        }

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);

        try self.tags.put(key_copy, value_copy);
    }

    /// Remove a tag.
    pub fn removeTag(self: *Scope, key: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.tags.fetchRemove(key)) |kv| {
            self.allocator.free(@constCast(kv.key));
            self.allocator.free(@constCast(kv.value));
        }
    }

    /// Set an extra value (thread-safe).
    pub fn setExtra(self: *Scope, key: []const u8, value: json.Value) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.extra.fetchRemove(key)) |kv| {
            self.allocator.free(@constCast(kv.key));
            var old_value = kv.value;
            deinitJsonValueDeep(self.allocator, &old_value);
        }

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        var value_copy = try cloneJsonValue(self.allocator, value);
        errdefer deinitJsonValueDeep(self.allocator, &value_copy);

        try self.extra.put(key_copy, value_copy);
    }

    /// Set a context (thread-safe).
    pub fn setContext(self: *Scope, key: []const u8, value: json.Value) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.contexts.fetchRemove(key)) |kv| {
            self.allocator.free(@constCast(kv.key));
            var old_value = kv.value;
            deinitJsonValueDeep(self.allocator, &old_value);
        }

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        var value_copy = try cloneJsonValue(self.allocator, value);
        errdefer deinitJsonValueDeep(self.allocator, &value_copy);

        try self.contexts.put(key_copy, value_copy);
    }

    /// Add a breadcrumb (thread-safe).
    pub fn addBreadcrumb(self: *Scope, crumb: Breadcrumb) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var owned = cloneBreadcrumb(self.allocator, crumb) catch return;
        if (owned.timestamp == null) {
            owned.timestamp = ts.now();
        }
        self.breadcrumbs.push(owned);
    }

    /// Apply scope data to an event before sending.
    pub fn applyToEvent(self: *Scope, allocator: Allocator, event: *Event) !ApplyResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result: ApplyResult = .{};

        // Apply user.
        if (self.user) |u| {
            event.user = try cloneUser(allocator, u);
            result.user_allocated = true;
        }

        // Apply tags as json.Value object.
        if (self.tags.count() > 0) {
            var obj = json.ObjectMap.init(allocator);
            errdefer deinitJsonObjectDeep(allocator, &obj);

            var it = self.tags.iterator();
            while (it.next()) |entry| {
                const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key_copy);

                const value_copy = try allocator.dupe(u8, entry.value_ptr.*);
                errdefer allocator.free(value_copy);

                try obj.put(key_copy, .{ .string = value_copy });
            }

            event.tags = .{ .object = obj };
            result.tags_allocated = true;
        }

        // Apply extra as json.Value object.
        if (self.extra.count() > 0) {
            var obj = json.ObjectMap.init(allocator);
            errdefer deinitJsonObjectDeep(allocator, &obj);

            var it = self.extra.iterator();
            while (it.next()) |entry| {
                const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key_copy);

                var value_copy = try cloneJsonValue(allocator, entry.value_ptr.*);
                errdefer deinitJsonValueDeep(allocator, &value_copy);

                try obj.put(key_copy, value_copy);
            }

            event.extra = .{ .object = obj };
            result.extra_allocated = true;
        }

        // Apply contexts as json.Value object.
        if (self.contexts.count() > 0) {
            var obj = json.ObjectMap.init(allocator);
            errdefer deinitJsonObjectDeep(allocator, &obj);

            var it = self.contexts.iterator();
            while (it.next()) |entry| {
                const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key_copy);

                var value_copy = try cloneJsonValue(allocator, entry.value_ptr.*);
                errdefer deinitJsonValueDeep(allocator, &value_copy);

                try obj.put(key_copy, value_copy);
            }

            event.contexts = .{ .object = obj };
            result.contexts_allocated = true;
        }

        // Apply breadcrumbs.
        if (self.breadcrumbs.count > 0) {
            const ordered = try self.breadcrumbs.toSlice(allocator);
            defer allocator.free(ordered);

            const crumbs = try allocator.alloc(Breadcrumb, ordered.len);
            var initialized: usize = 0;
            errdefer {
                for (crumbs[0..initialized]) |*crumb| {
                    deinitBreadcrumbDeep(allocator, crumb);
                }
                allocator.free(crumbs);
            }

            var i: usize = 0;
            while (i < ordered.len) : (i += 1) {
                crumbs[i] = try cloneBreadcrumb(allocator, ordered[i]);
                initialized += 1;
            }

            event.breadcrumbs = crumbs;
            result.breadcrumbs_allocated = true;
        }

        return result;
    }

    /// Reset all fields.
    pub fn clear(self: *Scope) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.user) |*u| {
            deinitUserDeep(self.allocator, u);
            self.user = null;
        }

        clearTagMapOwned(self.allocator, &self.tags);
        clearJsonMapOwned(self.allocator, &self.extra);
        clearJsonMapOwned(self.allocator, &self.contexts);
        self.breadcrumbs.clear();
    }
};

pub fn cleanupAppliedToEvent(allocator: Allocator, event: *Event, result: ApplyResult) void {
    if (result.user_allocated) {
        if (event.user) |*u| {
            deinitUserDeep(allocator, u);
            event.user = null;
        }
    }

    if (result.tags_allocated) {
        if (event.tags) |*tags| {
            deinitJsonValueDeep(allocator, tags);
            event.tags = null;
        }
    }

    if (result.extra_allocated) {
        if (event.extra) |*extra| {
            deinitJsonValueDeep(allocator, extra);
            event.extra = null;
        }
    }

    if (result.contexts_allocated) {
        if (event.contexts) |*contexts| {
            deinitJsonValueDeep(allocator, contexts);
            event.contexts = null;
        }
    }

    if (result.breadcrumbs_allocated) {
        if (event.breadcrumbs) |crumbs| {
            const mutable = @constCast(crumbs);
            for (mutable) |*crumb| {
                deinitBreadcrumbDeep(allocator, crumb);
            }
            allocator.free(mutable);
            event.breadcrumbs = null;
        }
    }
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "BreadcrumbBuffer push and read" {
    var buf = try BreadcrumbBuffer.init(testing.allocator, 10);
    defer buf.deinit();

    buf.push(.{ .message = try testing.allocator.dupe(u8, "crumb1"), .category = try testing.allocator.dupe(u8, "test") });
    buf.push(.{ .message = try testing.allocator.dupe(u8, "crumb2"), .category = try testing.allocator.dupe(u8, "test") });

    try testing.expectEqual(@as(usize, 2), buf.count);

    const slice = try buf.toSlice(testing.allocator);
    defer testing.allocator.free(slice);

    try testing.expectEqual(@as(usize, 2), slice.len);
    try testing.expectEqualStrings("crumb1", slice[0].message.?);
    try testing.expectEqualStrings("crumb2", slice[1].message.?);
}

test "BreadcrumbBuffer wraps around" {
    var buf = try BreadcrumbBuffer.init(testing.allocator, 2);
    defer buf.deinit();

    buf.push(.{ .message = try testing.allocator.dupe(u8, "first") });
    buf.push(.{ .message = try testing.allocator.dupe(u8, "second") });
    buf.push(.{ .message = try testing.allocator.dupe(u8, "third") }); // overwrites "first"

    try testing.expectEqual(@as(usize, 2), buf.count);

    const slice = try buf.toSlice(testing.allocator);
    defer testing.allocator.free(slice);

    try testing.expectEqual(@as(usize, 2), slice.len);
    // Should be in order: second, third (oldest first)
    try testing.expectEqualStrings("second", slice[0].message.?);
    try testing.expectEqualStrings("third", slice[1].message.?);
}

test "Scope setTag and setUser" {
    var scope = try Scope.init(testing.allocator, 10);
    defer scope.deinit();

    scope.setUser(.{ .id = "user-123", .email = "test@example.com" });
    try scope.setTag("environment", "production");
    try scope.setTag("release", "1.0.0");

    try testing.expectEqualStrings("user-123", scope.user.?.id.?);
    try testing.expectEqualStrings("test@example.com", scope.user.?.email.?);
    try testing.expectEqualStrings("production", scope.tags.get("environment").?);
    try testing.expectEqualStrings("1.0.0", scope.tags.get("release").?);
}

test "Scope applyToEvent" {
    var scope = try Scope.init(testing.allocator, 10);
    defer scope.deinit();

    scope.setUser(.{ .id = "user-42" });
    try scope.setTag("env", "test");
    scope.addBreadcrumb(.{ .message = "navigation", .category = "ui" });

    var event = Event.init();
    const applied = try scope.applyToEvent(testing.allocator, &event);
    defer cleanupAppliedToEvent(testing.allocator, &event, applied);

    // Verify user applied
    try testing.expectEqualStrings("user-42", event.user.?.id.?);

    // Verify tags applied
    try testing.expect(event.tags != null);

    // Verify breadcrumbs applied
    try testing.expect(event.breadcrumbs != null);
    try testing.expectEqual(@as(usize, 1), event.breadcrumbs.?.len);
    try testing.expectEqualStrings("navigation", event.breadcrumbs.?[0].message.?);
}

test "Scope stores owned tag strings" {
    var scope = try Scope.init(testing.allocator, 10);
    defer scope.deinit();

    var key_buf = [_]u8{ 'k', 'e', 'y' };
    var value_buf = [_]u8{ 'o', 'n', 'e' };

    try scope.setTag(key_buf[0..], value_buf[0..]);

    key_buf[0] = 'x';
    value_buf[0] = 'z';

    try testing.expectEqualStrings("one", scope.tags.get("key").?);
}

test "Scope clear resets all fields" {
    var scope = try Scope.init(testing.allocator, 10);
    defer scope.deinit();

    scope.setUser(.{ .id = "user-1" });
    try scope.setTag("key", "value");
    scope.addBreadcrumb(.{ .message = "crumb" });

    scope.clear();

    try testing.expect(scope.user == null);
    try testing.expectEqual(@as(usize, 0), scope.tags.count());
    try testing.expectEqual(@as(usize, 0), scope.breadcrumbs.count);
}
