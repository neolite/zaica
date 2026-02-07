const std = @import("std");
const json = std.json;
const types = @import("types.zig");
const env_mod = @import("env.zig");

/// Resolve the API key for a provider using the priority chain:
/// 1. CLI --api-key flag
/// 2. ZAICA_API_KEY env var
/// 3. {PROVIDER}_API_KEY env var (e.g. GLM_API_KEY)
/// 4. auth.json → keys.{provider}
/// Returns ResolvedAuth with key and source info.
pub fn resolveApiKey(
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    provider_key_env: ?[]const u8,
    cli_api_key: ?[]const u8,
) !types.ResolvedAuth {
    // 1. CLI flag
    if (cli_api_key) |key| {
        return .{
            .api_key = try allocator.dupe(u8, key),
            .key_source = .cli_flag,
        };
    }

    // 2. ZAICA_API_KEY
    if (env_mod.getEnv("ZAICA_API_KEY")) |key| {
        return .{
            .api_key = try allocator.dupe(u8, key),
            .key_source = .zaica_env,
        };
    }

    // 3. Provider-specific env var (e.g. GLM_API_KEY)
    if (provider_key_env) |env_name| {
        if (env_mod.getEnv(env_name)) |key| {
            return .{
                .api_key = try allocator.dupe(u8, key),
                .key_source = .provider_env,
            };
        }
    }

    // 4. auth.json
    if (try loadAuthFile(allocator, provider_name)) |key| {
        return .{
            .api_key = key,
            .key_source = .auth_file,
        };
    }

    return .{ .api_key = null, .key_source = .none };
}

/// Load API key from ~/.config/zaica/auth.json.
fn loadAuthFile(allocator: std.mem.Allocator, provider_name: []const u8) !?[]const u8 {
    const home = env_mod.getEnv("HOME") orelse return null;
    const path = try std.fmt.allocPrint(allocator, "{s}/.config/zaica/auth.json", .{home});
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return null, // Silently skip if can't open
    };
    defer file.close();

    // Check file permissions (warn if too permissive)
    const stat = file.stat() catch return null;
    const mode = stat.mode;
    // Check if group or others have read/write access
    const group_other_mask: u32 = 0o077;
    if (mode & group_other_mask != 0) {
        const stderr = std.io.getStdErr().writer();
        stderr.print("Warning: {s} has overly permissive permissions ({o}). Consider: chmod 600 {s}\n", .{ path, mode & 0o777, path }) catch {};
    }

    // Read and parse
    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch return null;
    defer allocator.free(content);

    const parsed = json.parseFromSlice(json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();

    // Navigate keys.{provider_name}
    const keys_obj = switch (parsed.value) {
        .object => |obj| obj.get("keys") orelse return null,
        else => return null,
    };

    const provider_key = switch (keys_obj) {
        .object => |obj| obj.get(provider_name) orelse return null,
        else => return null,
    };

    return switch (provider_key) {
        .string => |s| try allocator.dupe(u8, s),
        else => null,
    };
}

/// Build the auth.json path for init command.
pub fn getAuthFilePath(allocator: std.mem.Allocator) !?[]const u8 {
    const home = env_mod.getEnv("HOME") orelse return null;
    return try std.fmt.allocPrint(allocator, "{s}/.config/zaica/auth.json", .{home});
}

/// Get the config directory path.
pub fn getConfigDir(allocator: std.mem.Allocator) !?[]const u8 {
    const home = env_mod.getEnv("HOME") orelse return null;
    return try std.fmt.allocPrint(allocator, "{s}/.config/zaica", .{home});
}

/// Format a helpful error message when no API key is found.
pub fn formatKeyError(writer: anytype, provider_name: []const u8, provider_key_env: ?[]const u8) !void {
    try writer.print("Error: No API key found for provider '{s}'.\n\n", .{provider_name});
    try writer.writeAll("Set it using one of these methods (highest priority first):\n");
    try writer.writeAll("  1. CLI flag:     zc --api-key <key> ...\n");
    try writer.writeAll("  2. Env var:      export ZAICA_API_KEY=<key>\n");
    if (provider_key_env) |env_name| {
        try writer.print("  3. Provider env: export {s}=<key>\n", .{env_name});
    }
    try writer.writeAll("  4. Auth file:    ~/.config/zaica/auth.json\n\n");
    try writer.writeAll("To create a default auth file, run: zc --init\n");
}

test "resolveApiKey: returns none when nothing set" {
    const allocator = std.testing.allocator;
    const auth = try resolveApiKey(allocator, "test_provider_xyz", null, null);
    try std.testing.expect(auth.api_key == null);
    try std.testing.expect(auth.key_source == .none);
}

test "resolveApiKey: cli flag takes priority" {
    const allocator = std.testing.allocator;
    const auth = try resolveApiKey(allocator, "test_provider_xyz", null, "my-key");
    defer allocator.free(auth.api_key.?);
    try std.testing.expectEqualStrings("my-key", auth.api_key.?);
    try std.testing.expect(auth.key_source == .cli_flag);
}
