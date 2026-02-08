const std = @import("std");
const store_mod = @import("store.zig");

/// Check if a type is a pointer to a Store(T).
pub fn isStorePtr(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    const child_info = @typeInfo(info.pointer.child);
    if (child_info != .@"struct") return false;
    return @hasDecl(info.pointer.child, "Value") and @hasDecl(info.pointer.child, "notifyIfDirty");
}

/// Check if a type is a struct/tuple where all fields are *Store(T).
pub fn isStoreShape(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    inline for (info.@"struct".fields) |f| {
        if (!isStorePtr(f.type)) return false;
    }
    return info.@"struct".fields.len > 0;
}

/// Given a shape type (struct of *Store), produce the snapshot type (struct of values).
pub fn SnapshotTypeOf(comptime Shape: type) type {
    if (!isStoreShape(Shape)) return void;
    const info = @typeInfo(Shape).@"struct";
    var fields: [info.fields.len]std.builtin.Type.StructField = undefined;
    inline for (info.fields, 0..) |f, i| {
        const StoreType = @typeInfo(f.type).pointer.child;
        fields[i] = .{
            .name = f.name,
            .type = StoreType.Value,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(StoreType.Value),
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = info.is_tuple,
    } });
}

/// Read current values from a shape (struct/tuple of *Store).
pub fn readSnapshot(shape: anytype) SnapshotTypeOf(@TypeOf(shape)) {
    const Shape = @TypeOf(shape);
    const info = @typeInfo(Shape).@"struct";
    var result: SnapshotTypeOf(Shape) = undefined;
    inline for (info.fields) |f| {
        @field(result, f.name) = @field(shape, f.name).get();
    }
    return result;
}
