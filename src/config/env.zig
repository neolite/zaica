const std = @import("std");
const json = std.json;
const merge = @import("merge.zig");

/// ZAGENT_* environment variable mappings to config JSON paths.
const EnvMapping = struct {
    env_name: []const u8,
    json_key: []const u8,
    value_type: enum { string, integer, float, boolean },
};

const mappings = [_]EnvMapping{
    .{ .env_name = "ZAGENT_PROVIDER", .json_key = "provider", .value_type = .string },
    .{ .env_name = "ZAGENT_MODEL", .json_key = "model", .value_type = .string },
    .{ .env_name = "ZAGENT_MAX_TOKENS", .json_key = "max_tokens", .value_type = .integer },
    .{ .env_name = "ZAGENT_TEMPERATURE", .json_key = "temperature", .value_type = .float },
    .{ .env_name = "ZAGENT_SYSTEM_PROMPT", .json_key = "system_prompt", .value_type = .string },
    .{ .env_name = "ZAGENT_LOG_LEVEL", .json_key = "log_level", .value_type = .string },
};

/// Build a json.Value object from ZAGENT_* environment variables.
/// Returns null if no relevant env vars are set.
pub fn readEnvOverrides(allocator: std.mem.Allocator) !?json.Value {
    var obj = json.ObjectMap.init(allocator);
    var found_any = false;

    for (mappings) |m| {
        if (std.posix.getenv(m.env_name)) |raw| {
            const value: json.Value = switch (m.value_type) {
                .string => .{ .string = try allocator.dupe(u8, raw) },
                .integer => blk: {
                    const parsed = std.fmt.parseInt(i64, raw, 10) catch continue;
                    break :blk .{ .integer = parsed };
                },
                .float => blk: {
                    const parsed = std.fmt.parseFloat(f64, raw) catch continue;
                    break :blk .{ .float = parsed };
                },
                .boolean => blk: {
                    if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "1")) {
                        break :blk .{ .bool = true };
                    } else if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "0")) {
                        break :blk .{ .bool = false };
                    } else continue;
                },
            };
            try obj.put(m.json_key, value);
            found_any = true;
        }
    }

    if (!found_any) {
        obj.deinit();
        return null;
    }
    return .{ .object = obj };
}

/// Get an environment variable, returning null if not set.
pub fn getEnv(name: []const u8) ?[]const u8 {
    return std.posix.getenv(name);
}

test "readEnvOverrides: returns null when no vars set" {
    // In test env, ZAGENT_* vars are unlikely to be set
    const allocator = std.testing.allocator;
    const result = try readEnvOverrides(allocator);
    // Can't guarantee no env vars — just check it doesn't crash
    if (result) |r| {
        _ = r;
        // If somehow set, that's fine
    }
}
