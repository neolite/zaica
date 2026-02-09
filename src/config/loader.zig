const std = @import("std");
const json = std.json;
const types = @import("types.zig");
const merge = @import("merge.zig");
const io = @import("../io.zig");
const presets = @import("presets.zig");
const env_mod = @import("env.zig");
const auth_mod = @import("auth.zig");
const validate_mod = @import("validate.zig");

/// Load and merge all config layers, returning a fully resolved config.
pub fn loadConfig(
    arena: std.mem.Allocator,
    cli: *const types.CliArgs,
) !types.ResolvedConfig {
    // Start with empty object — Config struct defaults handle missing fields
    var merged: json.Value = .{ .object = json.ObjectMap.init(arena) };

    // Layer 2: Global config file (~/.config/zaica/config.json or --config)
    if (cli.config_path) |path| {
        if (try readJsonFile(arena, path)) |val| {
            merged = try merge.deepMerge(arena, merged, val);
        }
    } else {
        if (try readGlobalConfig(arena)) |val| {
            merged = try merge.deepMerge(arena, merged, val);
        }
    }

    // Layer 3: Project config (.zaica.json in cwd)
    if (try readProjectConfig(arena)) |val| {
        merged = try merge.deepMerge(arena, merged, val);
    }

    // Layer 4: Environment variables (ZAICA_*)
    if (try env_mod.readEnvOverrides(arena)) |val| {
        merged = try merge.deepMerge(arena, merged, val);
    }

    // Layer 5: CLI overrides
    const cli_json = try cliToJson(arena, cli);
    if (cli_json) |val| {
        merged = try merge.deepMerge(arena, merged, val);
    }

    // Parse merged JSON into typed Config (struct defaults fill gaps)
    const config = try json.parseFromValue(types.Config, arena, merged, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });

    // Resolve provider preset
    const provider = presets.findByName(config.value.provider) orelse {
        io.printErr("Error: Unknown provider '{s}'. Available: {s}\n", .{
            config.value.provider,
            presets.availableNames(),
        });
        return error.UnknownProvider;
    };

    // Resolve model: CLI > config > preset default
    const resolved_model = if (config.value.model.len > 0)
        config.value.model
    else
        provider.default_model;

    // Build completions URL
    const completions_url = try std.fmt.allocPrint(
        arena,
        "{s}{s}",
        .{ provider.base_url, provider.chat_completions_path },
    );

    // Resolve API key
    const resolved_auth = try auth_mod.resolveApiKey(
        arena,
        config.value.provider,
        provider.key_env_var,
        cli.api_key,
    );

    // Build layered system prompt (or use explicit override)
    var final_config = config.value;
    final_config.system_prompt = try buildSystemPrompt(arena, config.value, provider);

    return .{
        .config = final_config,
        .active_provider = provider,
        .auth = resolved_auth,
        .resolved_model = resolved_model,
        .completions_url = completions_url,
    };
}

/// Build the system prompt from layers, or return explicit override.
/// Layers: base → provider → global ZAICA.md → project ZAICA.md
fn buildSystemPrompt(
    arena: std.mem.Allocator,
    config: types.Config,
    provider: types.ProviderPreset,
) ![]const u8 {
    // Explicit override: non-empty system_prompt from config/CLI wins
    if (config.system_prompt.len > 0) return config.system_prompt;

    var parts: [4][]const u8 = undefined;
    var count: usize = 0;

    // Layer 1: Base prompt
    parts[count] = types.BASE_SYSTEM_PROMPT;
    count += 1;

    // Layer 2: Provider-specific prompt
    if (provider.provider_prompt) |pp| {
        parts[count] = pp;
        count += 1;
    }

    // Layer 3: Global user prompt (~/.config/zaica/ZAICA.md)
    if (try readGlobalZaicaMd(arena)) |content| {
        parts[count] = content;
        count += 1;
    }

    // Layer 4: Project prompt (./ZAICA.md in cwd)
    if (try readProjectZaicaMd(arena)) |content| {
        parts[count] = content;
        count += 1;
    }

    // Join with double newline
    if (count == 1) return parts[0];
    return try std.mem.join(arena, "\n\n", parts[0..count]);
}

/// Read ~/.config/zaica/ZAICA.md if it exists.
fn readGlobalZaicaMd(allocator: std.mem.Allocator) !?[]const u8 {
    const home = env_mod.getEnv("HOME") orelse return null;
    const path = try std.fmt.allocPrint(allocator, "{s}/.config/zaica/ZAICA.md", .{home});
    defer allocator.free(path);
    return readTextFileAbsolute(allocator, path);
}

/// Read ./ZAICA.md from cwd if it exists.
fn readProjectZaicaMd(allocator: std.mem.Allocator) !?[]const u8 {
    const cwd = std.fs.cwd();
    const file = cwd.openFile("ZAICA.md", .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return null,
    };
    defer file.close();
    return file.readToEndAlloc(allocator, 1 * 1024 * 1024) catch null;
}

/// Read a text file by absolute path, returning null if not found.
fn readTextFileAbsolute(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return null,
    };
    defer file.close();
    return file.readToEndAlloc(allocator, 1 * 1024 * 1024) catch null;
}

/// Read and parse a JSON file, returning null if not found.
fn readJsonFile(allocator: std.mem.Allocator, path: []const u8) !?json.Value {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            io.printErr("Warning: Could not open config file '{s}': {}\n", .{ path, err });
            return null;
        },
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return null;
    defer allocator.free(content);

    const parsed = json.parseFromSlice(json.Value, allocator, content, .{}) catch |err| {
        io.printErr("Warning: Invalid JSON in '{s}': {}\n", .{ path, err });
        return null;
    };
    // Clone to arena so parsed can be freed
    const cloned = try merge.cloneValue(allocator, parsed.value);
    parsed.deinit();
    return cloned;
}

/// Read the relative-path .zaica.json, returning null if not found.
fn readProjectConfig(allocator: std.mem.Allocator) !?json.Value {
    const cwd = std.fs.cwd();
    const file = cwd.openFile(".zaica.json", .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return null,
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return null;
    defer allocator.free(content);

    const parsed = json.parseFromSlice(json.Value, allocator, content, .{}) catch |err| {
        io.printErr("Warning: Invalid JSON in '.zaica.json': {}\n", .{err});
        return null;
    };
    const cloned = try merge.cloneValue(allocator, parsed.value);
    parsed.deinit();
    return cloned;
}

/// Read global config from ~/.config/zaica/config.json.
fn readGlobalConfig(allocator: std.mem.Allocator) !?json.Value {
    const home = env_mod.getEnv("HOME") orelse return null;
    const path = try std.fmt.allocPrint(allocator, "{s}/.config/zaica/config.json", .{home});
    defer allocator.free(path);
    return readJsonFile(allocator, path);
}

/// Convert CLI overrides to json.Value for merging.
fn cliToJson(allocator: std.mem.Allocator, cli: *const types.CliArgs) !?json.Value {
    var obj = json.ObjectMap.init(allocator);
    var any = false;

    if (cli.provider) |v| {
        try obj.put("provider", .{ .string = v });
        any = true;
    }
    if (cli.model) |v| {
        try obj.put("model", .{ .string = v });
        any = true;
    }
    if (cli.temperature) |v| {
        try obj.put("temperature", .{ .float = v });
        any = true;
    }
    if (cli.max_tokens) |v| {
        try obj.put("max_tokens", .{ .integer = @intCast(v) });
        any = true;
    }

    if (!any) {
        obj.deinit();
        return null;
    }
    return .{ .object = obj };
}

/// Create default config files (--init command).
pub fn initConfigFiles() !void {
    const home = env_mod.getEnv("HOME") orelse {
        io.writeErr("Error: HOME environment variable not set.\n");
        return error.NoHome;
    };

    // Create config directory
    var buf: [1024]u8 = undefined;
    const config_dir = try std.fmt.bufPrint(&buf, "{s}/.config/zaica", .{home});
    std.fs.makeDirAbsolute(std.fs.path.dirname(config_dir).?) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            io.printErr("Error creating directory: {}\n", .{err});
            return err;
        },
    };
    std.fs.makeDirAbsolute(config_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            io.printErr("Error creating directory: {}\n", .{err});
            return err;
        },
    };

    // Write config.json
    var config_path_buf: [1024]u8 = undefined;
    const config_path = try std.fmt.bufPrint(&config_path_buf, "{s}/config.json", .{config_dir});
    {
        const exists = blk: {
            std.fs.accessAbsolute(config_path, .{}) catch break :blk false;
            break :blk true;
        };
        if (exists) {
            try io.printOut("  exists: {s}\n", .{config_path});
        } else {
            const file = try std.fs.createFileAbsolute(config_path, .{});
            defer file.close();
            try file.writeAll(default_config_json);
            try io.printOut("  created: {s}\n", .{config_path});
        }
    }

    // Write auth.json
    var auth_path_buf: [1024]u8 = undefined;
    const auth_path = try std.fmt.bufPrint(&auth_path_buf, "{s}/auth.json", .{config_dir});
    {
        const exists = blk: {
            std.fs.accessAbsolute(auth_path, .{}) catch break :blk false;
            break :blk true;
        };
        if (exists) {
            try io.printOut("  exists: {s}\n", .{auth_path});
        } else {
            const file = try std.fs.createFileAbsolute(auth_path, .{});
            defer file.close();
            try file.writeAll(default_auth_json);
            // Set restrictive permissions (chmod 600)
            const f = std.fs.openFileAbsolute(auth_path, .{}) catch {
                try io.printOut("  created: {s} (could not set permissions)\n", .{auth_path});
                return;
            };
            defer f.close();
            f.chmod(0o600) catch {};
            try io.printOut("  created: {s} (chmod 600)\n", .{auth_path});
        }
    }

    try io.writeOut(
        \\
        \\Setup complete! Next steps:
        \\  1. Add your API key to ~/.config/zaica/auth.json
        \\     OR set GLM_API_KEY environment variable
        \\  2. Run: zc "hello"
        \\
    );
}

const default_config_json =
    \\{
    \\  "provider": "glm",
    \\  "model": "glm-4.7-flash",
    \\  "max_tokens": 8192,
    \\  "temperature": 0.0
    \\}
;

const default_auth_json =
    \\{
    \\  "keys": {
    \\    "glm": "YOUR_GLM_API_KEY_HERE",
    \\    "openai": "",
    \\    "anthropic": "",
    \\    "deepseek": ""
    \\  }
    \\}
;
