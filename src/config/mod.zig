/// Config module — loads, merges, and validates zaica configuration.
///
/// Priority (lowest to highest):
///   1. Comptime defaults (Config struct defaults)
///   2. Provider presets (built-in for GLM, OpenAI, etc.)
///   3. ~/.config/zaica/config.json (global)
///   4. .zaica.json (project-level)
///   5. Environment variables (ZAICA_*)
///   6. CLI flags (--provider, --model, ...)
pub const types = @import("types.zig");
pub const presets = @import("presets.zig");
pub const cli = @import("cli.zig");
pub const loader = @import("loader.zig");
pub const auth = @import("auth.zig");
pub const validate = @import("validate.zig");
pub const merge = @import("merge.zig");
pub const env = @import("env.zig");

const std = @import("std");
const io = @import("../io.zig");

/// Load the fully resolved configuration.
/// Handles --help and --init commands (returns error.HelpRequested / error.InitCompleted).
/// On validation failure, prints errors to stderr and returns an error.
pub fn load(parent_allocator: std.mem.Allocator) !types.LoadResult {
    // Parse CLI args
    const cli_args = cli.parse(parent_allocator) catch {
        return error.ConfigError;
    };

    // Handle --help
    if (cli_args.show_help) {
        cli.printHelp();
        return error.HelpRequested;
    }

    // Handle --init
    if (cli_args.do_init) {
        loader.initConfigFiles() catch {
            return error.ConfigError;
        };
        return error.InitCompleted;
    }

    // Create arena for all config allocations
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    errdefer arena.deinit();

    // Load and merge all config layers
    var resolved = loader.loadConfig(arena.allocator(), &cli_args) catch {
        return error.ConfigError;
    };

    // Validate
    if (validate.validate(&resolved)) |err_msg| {
        io.printErr("Config error: {s}\n", .{err_msg});
        return error.ConfigError;
    }

    // Check for missing API key (separate from validate for detailed error)
    if (validate.needsApiKey(&resolved)) {
        // For --dump-config, allow proceeding without key
        if (cli_args.dump_config) {} else {
            // If no explicit provider was set via CLI/config, offer selection
            if (cli_args.provider == null) {
                if (auth.promptProviderSelection()) |idx| {
                    const selected = presets.all[idx];
                    // Update resolved config with new provider
                    resolved.config.provider = selected.name;
                    resolved.config.model = selected.default_model;
                    resolved.active_provider = selected;
                    resolved.resolved_model = selected.default_model;
                    resolved.completions_url = try std.fmt.allocPrint(
                        arena.allocator(),
                        "{s}{s}",
                        .{ selected.base_url, selected.chat_completions_path },
                    );

                    // Save provider choice to global config
                    saveProviderToConfig(arena.allocator(), selected.name) catch {};

                    // If new provider doesn't need a key (e.g. ollama), skip key prompt
                    if (!selected.requires_key) {
                        resolved.auth = .{ .api_key = null, .key_source = .none };
                    } else {
                        // Re-resolve key for new provider
                        resolved.auth = try auth.resolveApiKey(
                            arena.allocator(),
                            selected.name,
                            selected.key_env_var,
                            cli_args.api_key,
                        );
                    }
                } else {
                    return error.ConfigError;
                }
            }

            // Still no key? Prompt for it
            if (resolved.active_provider.requires_key and resolved.auth.api_key == null) {
                auth.printKeyError(
                    resolved.config.provider,
                    resolved.active_provider.key_env_var,
                );
                if (auth.promptApiKey(arena.allocator())) |key| {
                    auth.saveApiKey(arena.allocator(), resolved.config.provider, key) catch {
                        io.writeErr("Failed to save API key.\n");
                        return error.ConfigError;
                    };
                    io.writeErr("API key saved to ~/.config/zaica/auth.json\n\n");
                    resolved.auth = .{ .api_key = key, .key_source = .auth_file };
                } else {
                    return error.ConfigError;
                }
            }
        }
    }

    // Apply --infinity overrides (iteration limits only — timeouts stay)
    if (cli_args.infinity) {
        resolved.config.max_iterations = std.math.maxInt(u32);
        resolved.config.max_sub_agent_iterations = std.math.maxInt(u32);
    }

    // Apply --max-iterations CLI override (takes precedence over --infinity)
    if (cli_args.max_iterations) |n| {
        resolved.config.max_iterations = n;
    }

    // Dupe prompt into arena so it's freed with everything else
    const prompt: ?[]const u8 = if (cli_args.prompt) |p|
        try arena.allocator().dupe(u8, p)
    else
        null;

    // Free the original prompt allocated by cli.parse with parent_allocator
    if (cli_args.prompt) |p| parent_allocator.free(p);

    return .{
        .resolved = resolved,
        .dump_config = cli_args.dump_config,
        .prompt = prompt,
        .continue_last = cli_args.continue_last,
        .session_id = if (cli_args.session_id) |s| try arena.allocator().dupe(u8, s) else null,
        .chain_path = if (cli_args.chain_path) |p| try arena.allocator().dupe(u8, p) else null,
        .dry_run = cli_args.dry_run,
        .yolo = cli_args.yolo,
        .infinity = cli_args.infinity,
        .arena = arena,
    };
}

/// Save the chosen provider to ~/.config/zaica/config.json.
fn saveProviderToConfig(allocator: std.mem.Allocator, provider_name: []const u8) !void {
    const home = env.getEnv("HOME") orelse return;
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/.config/zaica", .{home});
    defer allocator.free(dir_path);
    const path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{dir_path});
    defer allocator.free(path);

    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const file = std.fs.createFileAbsolute(path, .{}) catch return error.FileError;
    defer file.close();

    var buf: [256]u8 = undefined;
    const content = std.fmt.bufPrint(&buf, "{{\n  \"provider\": \"{s}\"\n}}\n", .{provider_name}) catch return;
    file.writeAll(content) catch {};
}

test {
    // Pull in all sub-module tests
    _ = @import("types.zig");
    _ = @import("merge.zig");
    _ = @import("presets.zig");
    _ = @import("env.zig");
    _ = @import("auth.zig");
    _ = @import("validate.zig");
    _ = @import("cli.zig");
}
