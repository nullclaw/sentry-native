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
            try callback(context, crumb);
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
                        try callback(context, crumb);
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
