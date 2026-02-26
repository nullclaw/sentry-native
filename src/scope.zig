const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const json = std.json;

const event_mod = @import("event.zig");
const Event = event_mod.Event;
const User = event_mod.User;
const Breadcrumb = event_mod.Breadcrumb;
const Level = event_mod.Level;

pub const MAX_BREADCRUMBS = 200;

/// Fixed-size ring buffer for breadcrumbs.
pub const BreadcrumbBuffer = struct {
    buffer: []Breadcrumb,
    capacity: usize,
    head: usize = 0,
    count: usize = 0,
    allocator: Allocator,

    pub fn init(allocator: Allocator, capacity: usize) !BreadcrumbBuffer {
        const cap = if (capacity > MAX_BREADCRUMBS) MAX_BREADCRUMBS else capacity;
        const buf = try allocator.alloc(Breadcrumb, cap);
        return BreadcrumbBuffer{
            .buffer = buf,
            .capacity = cap,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BreadcrumbBuffer) void {
        self.allocator.free(self.buffer);
        self.* = undefined;
    }

    /// O(1) push. Overwrites oldest breadcrumb when full.
    pub fn push(self: *BreadcrumbBuffer, crumb: Breadcrumb) void {
        self.buffer[self.head] = crumb;
        self.head = (self.head + 1) % self.capacity;
        if (self.count < self.capacity) {
            self.count += 1;
        }
    }

    /// Return breadcrumbs in insertion order.
    pub fn toSlice(self: *const BreadcrumbBuffer, allocator: Allocator) ![]Breadcrumb {
        const result = try allocator.alloc(Breadcrumb, self.count);
        if (self.count < self.capacity) {
            // Buffer has not wrapped around yet
            @memcpy(result, self.buffer[0..self.count]);
        } else {
            // Buffer has wrapped; oldest is at head
            const first_part_len = self.capacity - self.head;
            @memcpy(result[0..first_part_len], self.buffer[self.head..self.capacity]);
            @memcpy(result[first_part_len..], self.buffer[0..self.head]);
        }
        return result;
    }

    pub fn clear(self: *BreadcrumbBuffer) void {
        self.head = 0;
        self.count = 0;
    }
};

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
        self.tags.deinit();
        self.extra.deinit();
        self.contexts.deinit();
        self.breadcrumbs.deinit();
        self.* = undefined;
    }

    /// Set the user context (thread-safe).
    pub fn setUser(self: *Scope, user: ?User) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.user = user;
    }

    /// Set a tag (thread-safe).
    pub fn setTag(self: *Scope, key: []const u8, value: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.tags.put(key, value);
    }

    /// Remove a tag.
    pub fn removeTag(self: *Scope, key: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.tags.remove(key);
    }

    /// Set an extra value (thread-safe).
    pub fn setExtra(self: *Scope, key: []const u8, value: json.Value) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.extra.put(key, value);
    }

    /// Set a context (thread-safe).
    pub fn setContext(self: *Scope, key: []const u8, value: json.Value) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.contexts.put(key, value);
    }

    /// Add a breadcrumb (thread-safe).
    pub fn addBreadcrumb(self: *Scope, crumb: Breadcrumb) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.breadcrumbs.push(crumb);
    }

    /// Apply scope data to an event before sending.
    pub fn applyToEvent(self: *Scope, allocator: Allocator, event: *Event) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Apply user
        if (self.user) |u| {
            event.user = u;
        }

        // Apply tags as json.Value object
        if (self.tags.count() > 0) {
            var obj = json.ObjectMap.init(allocator);
            var it = self.tags.iterator();
            while (it.next()) |entry| {
                try obj.put(entry.key_ptr.*, .{ .string = entry.value_ptr.* });
            }
            event.tags = .{ .object = obj };
        }

        // Apply extra as json.Value object
        if (self.extra.count() > 0) {
            var obj = json.ObjectMap.init(allocator);
            var it = self.extra.iterator();
            while (it.next()) |entry| {
                try obj.put(entry.key_ptr.*, entry.value_ptr.*);
            }
            event.extra = .{ .object = obj };
        }

        // Apply contexts as json.Value object
        if (self.contexts.count() > 0) {
            var obj = json.ObjectMap.init(allocator);
            var it = self.contexts.iterator();
            while (it.next()) |entry| {
                try obj.put(entry.key_ptr.*, entry.value_ptr.*);
            }
            event.contexts = .{ .object = obj };
        }

        // Apply breadcrumbs
        if (self.breadcrumbs.count > 0) {
            const crumbs = try self.breadcrumbs.toSlice(allocator);
            event.breadcrumbs = crumbs;
        }
    }

    /// Reset all fields.
    pub fn clear(self: *Scope) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.user = null;
        self.tags.clearRetainingCapacity();
        self.extra.clearRetainingCapacity();
        self.contexts.clearRetainingCapacity();
        self.breadcrumbs.clear();
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

test "BreadcrumbBuffer push and read" {
    var buf = try BreadcrumbBuffer.init(testing.allocator, 10);
    defer buf.deinit();

    buf.push(.{ .message = "crumb1", .category = "test" });
    buf.push(.{ .message = "crumb2", .category = "test" });

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

    buf.push(.{ .message = "first" });
    buf.push(.{ .message = "second" });
    buf.push(.{ .message = "third" }); // overwrites "first"

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
    try scope.applyToEvent(testing.allocator, &event);

    // Free allocated resources after test
    defer {
        if (event.tags) |t| {
            var tags_obj = t.object;
            tags_obj.deinit();
        }
        if (event.breadcrumbs) |b| {
            testing.allocator.free(b);
        }
    }

    // Verify user applied
    try testing.expectEqualStrings("user-42", event.user.?.id.?);

    // Verify tags applied
    try testing.expect(event.tags != null);

    // Verify breadcrumbs applied
    try testing.expect(event.breadcrumbs != null);
    try testing.expectEqual(@as(usize, 1), event.breadcrumbs.?.len);
    try testing.expectEqualStrings("navigation", event.breadcrumbs.?[0].message.?);
}

test "Scope clear resets all fields" {
    var scope = try Scope.init(testing.allocator, 10);
    defer scope.deinit();

    scope.setUser(.{ .id = "user-1" });
    try scope.setTag("key", "value");
    scope.addBreadcrumb(.{ .message = "crumb" });

    scope.clear();

    try testing.expect(scope.user == null);
    try testing.expectEqual(@as(u32, 0), scope.tags.count());
    try testing.expectEqual(@as(usize, 0), scope.breadcrumbs.count);
}
