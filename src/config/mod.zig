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
    const resolved = loader.loadConfig(arena.allocator(), &cli_args) catch {
        return error.ConfigError;
    };

    // Validate
    if (validate.validate(&resolved)) |err_msg| {
        const stderr = std.io.getStdErr().writer();
        stderr.print("Config error: {s}\n", .{err_msg}) catch {};
        return error.ConfigError;
    }

    // Check for missing API key (separate from validate for detailed error)
    if (validate.needsApiKey(&resolved)) {
        const stderr = std.io.getStdErr().writer();
        auth.formatKeyError(
            stderr,
            resolved.config.provider,
            resolved.active_provider.key_env_var,
        ) catch {};
        // For --dump-config, allow proceeding without key
        if (!cli_args.dump_config) {
            return error.ConfigError;
        }
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
        .arena = arena,
    };
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
