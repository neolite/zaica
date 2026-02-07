const std = @import("std");
const json = std.json;

/// Deep-merge `override` into `base`, returning the merged result.
/// For object keys present in both, recurse if both values are objects;
/// otherwise the override value wins.
/// Both inputs are consumed/modified — caller should not reuse them.
pub fn deepMerge(allocator: std.mem.Allocator, base: json.Value, override: json.Value) !json.Value {
    // If both are objects, merge key-by-key
    if (base == .object and override == .object) {
        var result = base.object;

        var it = override.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (result.getPtr(key)) |existing| {
                // Both have this key — recurse
                existing.* = try deepMerge(allocator, existing.*, entry.value_ptr.*);
            } else {
                // New key from override
                try result.put(key, entry.value_ptr.*);
            }
        }
        return .{ .object = result };
    }

    // Non-object: override wins entirely
    return override;
}

test "deepMerge: scalar override" {
    const allocator = std.testing.allocator;

    const base_str =
        \\{"provider":"glm","model":"glm-4.7-flash"}
    ;
    const override_str =
        \\{"model":"glm-4.7"}
    ;

    var base_parsed = try json.parseFromSlice(json.Value, allocator, base_str, .{});
    defer base_parsed.deinit();

    var override_parsed = try json.parseFromSlice(json.Value, allocator, override_str, .{});
    defer override_parsed.deinit();

    // We need to clone since deepMerge mutates in-place and parsed values share allocator
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var base_clone = try cloneValue(arena_alloc, base_parsed.value);
    const override_clone = try cloneValue(arena_alloc, override_parsed.value);

    const merged = try deepMerge(arena_alloc, base_clone, override_clone);

    // provider should remain "glm", model should be overridden to "glm-4.7"
    try std.testing.expectEqualStrings("glm", merged.object.get("provider").?.string);
    try std.testing.expectEqualStrings("glm-4.7", merged.object.get("model").?.string);
    _ = &base_clone;
}

test "deepMerge: nested object merge" {
    const allocator = std.testing.allocator;

    const base_str =
        \\{"tools":{"allow_exec":false,"allow_file_write":true}}
    ;
    const override_str =
        \\{"tools":{"allow_exec":true}}
    ;

    var base_parsed = try json.parseFromSlice(json.Value, allocator, base_str, .{});
    defer base_parsed.deinit();
    var override_parsed = try json.parseFromSlice(json.Value, allocator, override_str, .{});
    defer override_parsed.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var base_clone = try cloneValue(arena_alloc, base_parsed.value);
    const override_clone = try cloneValue(arena_alloc, override_parsed.value);

    const merged = try deepMerge(arena_alloc, base_clone, override_clone);

    const tools = merged.object.get("tools").?.object;
    try std.testing.expect(tools.get("allow_exec").?.bool == true);
    try std.testing.expect(tools.get("allow_file_write").?.bool == true);
    _ = &base_clone;
}

/// Clone a json.Value into the given allocator.
pub fn cloneValue(allocator: std.mem.Allocator, value: json.Value) !json.Value {
    return switch (value) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| {
            var new_arr = json.Array.initCapacity(allocator, arr.items.len) catch
                return error.OutOfMemory;
            for (arr.items) |item| {
                try new_arr.append(try cloneValue(allocator, item));
            }
            return .{ .array = new_arr };
        },
        .object => |obj| {
            var new_obj = json.ObjectMap.init(allocator);
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try cloneValue(allocator, entry.value_ptr.*);
                try new_obj.put(key, val);
            }
            return .{ .object = new_obj };
        },
    };
}
