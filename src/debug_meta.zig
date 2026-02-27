const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Allocator = std.mem.Allocator;
const scope_mod = @import("scope.zig");

fn putOwnedJsonEntry(
    allocator: Allocator,
    object: *json.ObjectMap,
    key: []const u8,
    value: json.Value,
) !void {
    const key_copy = try allocator.dupe(u8, key);
    errdefer allocator.free(key_copy);
    try object.put(key_copy, value);
}

fn putOwnedString(
    allocator: Allocator,
    object: *json.ObjectMap,
    key: []const u8,
    value: []const u8,
) !void {
    const value_copy = try allocator.dupe(u8, value);
    errdefer allocator.free(value_copy);
    try putOwnedJsonEntry(allocator, object, key, .{ .string = value_copy });
}

pub fn imageType() []const u8 {
    return switch (builtin.object_format) {
        .coff => "pe",
        .elf => "elf",
        .macho => "macho",
        .wasm => "wasm",
        else => "other",
    };
}

pub fn detectCodeFileAlloc(allocator: Allocator) ?[]u8 {
    switch (builtin.os.tag) {
        .wasi, .freestanding => return null,
        else => {},
    }
    return std.fs.selfExePathAlloc(allocator) catch null;
}

pub fn buildDefault(allocator: Allocator, code_file: []const u8) !json.Value {
    var image_object = json.ObjectMap.init(allocator);
    var image_moved = false;
    errdefer if (!image_moved) {
        var value: json.Value = .{ .object = image_object };
        scope_mod.deinitJsonValueDeep(allocator, &value);
    };

    try putOwnedString(allocator, &image_object, "type", imageType());
    try putOwnedString(allocator, &image_object, "code_file", code_file);

    var images_array = json.Array.init(allocator);
    var images_moved = false;
    errdefer if (!images_moved) {
        var value: json.Value = .{ .array = images_array };
        scope_mod.deinitJsonValueDeep(allocator, &value);
    };

    try images_array.append(.{ .object = image_object });
    image_moved = true;

    var debug_meta_object = json.ObjectMap.init(allocator);
    errdefer {
        var value: json.Value = .{ .object = debug_meta_object };
        scope_mod.deinitJsonValueDeep(allocator, &value);
    }

    try putOwnedJsonEntry(allocator, &debug_meta_object, "images", .{ .array = images_array });
    images_moved = true;

    return .{ .object = debug_meta_object };
}
