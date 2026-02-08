const std = @import("std");
const json = std.json;
const posix = std.posix;
const io = @import("../io.zig");
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
        io.printErr("Warning: {s} has overly permissive permissions ({o}). Consider: chmod 600 {s}\n", .{ path, mode & 0o777, path });
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

/// Print a helpful error message when no API key is found.
pub fn printKeyError(provider_name: []const u8, provider_key_env: ?[]const u8) void {
    io.printErr("Error: No API key found for provider '{s}'.\n\n", .{provider_name});
    io.writeErr("Set it using one of these methods (highest priority first):\n");
    io.writeErr("  1. CLI flag:     zc --api-key <key> ...\n");
    io.writeErr("  2. Env var:      export ZAICA_API_KEY=<key>\n");
    if (provider_key_env) |env_name| {
        io.printErr("  3. Provider env: export {s}=<key>\n", .{env_name});
    }
    io.writeErr("  4. Auth file:    ~/.config/zaica/auth.json\n\n");
}

/// Prompt the user to enter an API key interactively (with echo suppressed).
/// Returns the trimmed key, or null if the user cancels (empty input / Ctrl-C).
pub fn promptApiKey(allocator: std.mem.Allocator) ?[]const u8 {
    // Open /dev/tty directly for terminal I/O
    const fd = posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0) catch return null;
    defer posix.close(fd);

    // Save terminal state and disable echo
    const orig = posix.tcgetattr(fd) catch return null;
    var noecho = orig;
    noecho.lflag.ECHO = false;
    posix.tcsetattr(fd, .FLUSH, noecho) catch return null;
    defer posix.tcsetattr(fd, .FLUSH, orig) catch {};

    io.writeErr("API key: ");
    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    while (pos < buf.len) {
        var byte_buf: [1]u8 = undefined;
        const n = posix.read(fd, &byte_buf) catch break;
        if (n == 0) break;
        if (byte_buf[0] == '\n' or byte_buf[0] == '\r') break;
        if (byte_buf[0] == 0x03) { // Ctrl-C
            io.writeErr("\n");
            return null;
        }
        buf[pos] = byte_buf[0];
        pos += 1;
    }
    io.writeErr("\n");

    const trimmed = std.mem.trim(u8, buf[0..pos], " \t");
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch null;
}

/// Save an API key to ~/.config/zaica/auth.json for the given provider.
pub fn saveApiKey(allocator: std.mem.Allocator, provider_name: []const u8, api_key: []const u8) !void {
    const path = try getAuthFilePath(allocator) orelse return error.NoHome;
    defer allocator.free(path);

    // Ensure config directory exists
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    // Read existing auth.json (or start with empty keys)
    var keys = json.ObjectMap.init(allocator);
    defer keys.deinit();

    if (std.fs.openFileAbsolute(path, .{})) |file| {
        defer file.close();
        const content = file.readToEndAlloc(allocator, 1024 * 1024) catch null;
        if (content) |c| {
            defer allocator.free(c);
            const parsed = json.parseFromSlice(json.Value, allocator, c, .{}) catch null;
            if (parsed) |p| {
                defer p.deinit();
                if (p.value.object.get("keys")) |k| {
                    if (k == .object) {
                        var iter = k.object.iterator();
                        while (iter.next()) |entry| {
                            const key_name = try allocator.dupe(u8, entry.key_ptr.*);
                            errdefer allocator.free(key_name);
                            const val = try allocator.dupe(u8, if (entry.value_ptr.* == .string) entry.value_ptr.string else "");
                            try keys.put(key_name, .{ .string = val });
                        }
                    }
                }
            }
        }
    } else |_| {}

    // Set/overwrite the provider key
    const prov_name = try allocator.dupe(u8, provider_name);
    const prov_key = try allocator.dupe(u8, api_key);
    try keys.put(prov_name, .{ .string = prov_key });

    // Write formatted JSON
    const file = std.fs.createFileAbsolute(path, .{}) catch return error.FileError;
    defer file.close();

    file.writeAll("{\n  \"keys\": {\n") catch return error.WriteError;
    var first = true;
    var write_iter = keys.iterator();
    while (write_iter.next()) |entry| {
        if (!first) file.writeAll(",\n") catch return error.WriteError;
        var line_buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "    \"{s}\": \"{s}\"", .{ entry.key_ptr.*, if (entry.value_ptr.* == .string) entry.value_ptr.string else "" }) catch continue;
        file.writeAll(line) catch return error.WriteError;
        first = false;
    }
    file.writeAll("\n  }\n}\n") catch return error.WriteError;

    // Set restrictive permissions
    const f = std.fs.openFileAbsolute(path, .{}) catch return;
    defer f.close();
    f.chmod(0o600) catch {};
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
