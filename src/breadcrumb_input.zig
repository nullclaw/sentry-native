const Breadcrumb = @import("event.zig").Breadcrumb;
const testing = @import("std").testing;

/// Visit breadcrumb input in any supported form and invoke callback for each breadcrumb.
///
/// Supported forms:
/// - Breadcrumb struct literal/value
/// - ?Breadcrumb
/// - []const Breadcrumb / [N]Breadcrumb
/// - function or function pointer returning any supported form
pub fn forEach(input: anytype, context: anytype, comptime callback: anytype) !void {
    comptime validateCallbackContract(@TypeOf(context), @TypeOf(callback));
    try forEachImpl(input, context, callback);
}

fn forEachImpl(input: anytype, context: anytype, comptime callback: anytype) !void {
    const T = @TypeOf(input);
    switch (@typeInfo(T)) {
        .optional => {
            if (input) |value| {
                try forEachImpl(value, context, callback);
            }
            return;
        },
        .@"struct" => {
            const crumb = breadcrumbFromStruct(input);
            try invokeCallback(context, crumb, callback);
            return;
        },
        .array => {
            for (input) |value| {
                try forEachImpl(value, context, callback);
            }
            return;
        },
        .pointer => |ptr| {
            if (ptr.size == .slice) {
                for (input) |value| {
                    try forEachImpl(value, context, callback);
                }
                return;
            }
            if (ptr.size == .one) {
                switch (@typeInfo(ptr.child)) {
                    .@"fn" => {
                        const produced = input();
                        try forEachImpl(produced, context, callback);
                        return;
                    },
                    .array => {
                        for (input.*) |value| {
                            try forEachImpl(value, context, callback);
                        }
                        return;
                    },
                    else => {
                        const crumb = breadcrumbFromStruct(input.*);
                        try invokeCallback(context, crumb, callback);
                        return;
                    },
                }
            }
        },
        .@"fn" => {
            const produced = input();
            try forEachImpl(produced, context, callback);
            return;
        },
        else => {},
    }

    @compileError("Unsupported breadcrumb input type.");
}

fn invokeCallback(context: anytype, crumb: Breadcrumb, comptime callback: anytype) !void {
    const result = callback(context, crumb);
    switch (@typeInfo(@TypeOf(result))) {
        .void => return,
        .error_union => try result,
        else => @compileError("Breadcrumb callback must return void or !void."),
    }
}

fn validateCallbackContract(comptime Context: type, comptime Callback: type) void {
    const callback_fn = switch (@typeInfo(Callback)) {
        .@"fn" => |fn_info| fn_info,
        .pointer => |ptr| switch (@typeInfo(ptr.child)) {
            .@"fn" => |fn_info| fn_info,
            else => @compileError("Breadcrumb callback pointer must target a function."),
        },
        else => @compileError("Breadcrumb callback must be a function."),
    };

    if (callback_fn.params.len != 2) {
        @compileError("Breadcrumb callback must accept exactly two parameters: context, breadcrumb.");
    }

    const context_param = callback_fn.params[0].type orelse
        @compileError("Breadcrumb callback context parameter must be typed.");
    if (context_param != Context) {
        @compileError("Breadcrumb callback context parameter type does not match provided context.");
    }

    const breadcrumb_param = callback_fn.params[1].type orelse
        @compileError("Breadcrumb callback breadcrumb parameter must be typed.");
    if (breadcrumb_param != Breadcrumb) {
        @compileError("Breadcrumb callback second parameter must be Breadcrumb.");
    }

    const return_type = callback_fn.return_type orelse
        @compileError("Breadcrumb callback return type must be explicit.");
    switch (@typeInfo(return_type)) {
        .void => {},
        .error_union => |err| {
            if (err.payload != void) {
                @compileError("Breadcrumb callback error union payload must be void.");
            }
        },
        else => @compileError("Breadcrumb callback must return void or !void."),
    }
}

fn breadcrumbFromStruct(value: anytype) Breadcrumb {
    const T = @TypeOf(value);
    const struct_info = switch (@typeInfo(T)) {
        .@"struct" => |info| info,
        else => @compileError("Breadcrumb struct conversion requires a struct input."),
    };

    var crumb = Breadcrumb{};
    inline for (struct_info.fields) |field| {
        if (!@hasField(Breadcrumb, field.name)) {
            @compileError("Unsupported breadcrumb field.");
        }
        @field(crumb, field.name) = @field(value, field.name);
    }
    return crumb;
}

const TestCollect = struct {
    items: [8]Breadcrumb = undefined,
    len: usize = 0,
};

fn collectBreadcrumb(ctx: *TestCollect, crumb: Breadcrumb) !void {
    ctx.items[ctx.len] = crumb;
    ctx.len += 1;
}

fn collectBreadcrumbNoError(ctx: *TestCollect, crumb: Breadcrumb) void {
    ctx.items[ctx.len] = crumb;
    ctx.len += 1;
}

fn breadcrumbFactorySingle() Breadcrumb {
    return .{ .message = "factory-single" };
}

const breadcrumb_factory_batch = [_]Breadcrumb{
    .{ .message = "factory-batch-1" },
    .{ .message = "factory-batch-2" },
};

fn breadcrumbFactoryBatch() []const Breadcrumb {
    return breadcrumb_factory_batch[0..];
}

fn breadcrumbFactoryNone() ?Breadcrumb {
    return null;
}

test "forEach traverses mixed breadcrumb inputs preserving order" {
    var collected = TestCollect{};

    try forEach(.{ .message = "inline" }, &collected, collectBreadcrumb);
    const optional: ?Breadcrumb = .{ .message = "optional" };
    try forEach(optional, &collected, collectBreadcrumb);
    try forEach(breadcrumbFactorySingle, &collected, collectBreadcrumb);
    try forEach(([_]Breadcrumb{
        .{ .message = "slice-1" },
        .{ .message = "slice-2" },
    })[0..], &collected, collectBreadcrumb);
    try forEach(breadcrumbFactoryBatch, &collected, collectBreadcrumb);
    try forEach(breadcrumbFactoryNone, &collected, collectBreadcrumb);
    try forEach(@as(?Breadcrumb, null), &collected, collectBreadcrumb);

    try testing.expectEqual(@as(usize, 7), collected.len);
    try testing.expectEqualStrings("inline", collected.items[0].message.?);
    try testing.expectEqualStrings("optional", collected.items[1].message.?);
    try testing.expectEqualStrings("factory-single", collected.items[2].message.?);
    try testing.expectEqualStrings("slice-1", collected.items[3].message.?);
    try testing.expectEqualStrings("slice-2", collected.items[4].message.?);
    try testing.expectEqualStrings("factory-batch-1", collected.items[5].message.?);
    try testing.expectEqualStrings("factory-batch-2", collected.items[6].message.?);
}

test "forEach accepts callback returning void" {
    var collected = TestCollect{};
    try forEach(.{ .message = "inline" }, &collected, collectBreadcrumbNoError);
    try testing.expectEqual(@as(usize, 1), collected.len);
    try testing.expectEqualStrings("inline", collected.items[0].message.?);
}
