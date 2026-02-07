const std = @import("std");
const types = @import("types.zig");

pub const ParseError = error{
    MissingValue,
    InvalidNumber,
    UnknownFlag,
    OutOfMemory,
};

/// Parse command-line arguments into CliArgs.
pub fn parse(allocator: std.mem.Allocator) !types.CliArgs {
    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();

    // Skip program name
    _ = args_iter.next();

    return parseFromIterator(allocator, &args_iter);
}

/// Parse arguments from an iterator (testable).
pub fn parseFromIterator(allocator: std.mem.Allocator, args_iter: anytype) !types.CliArgs {
    var result = types.CliArgs{};
    var prompt_parts = std.ArrayList([]const u8).init(allocator);
    defer prompt_parts.deinit();

    while (args_iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--provider")) {
                result.provider = args_iter.next() orelse {
                    printFlagError("--provider", "requires a value");
                    return error.MissingValue;
                };
            } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--model")) {
                result.model = args_iter.next() orelse {
                    printFlagError("--model", "requires a value");
                    return error.MissingValue;
                };
            } else if (std.mem.eql(u8, arg, "-T") or std.mem.eql(u8, arg, "--temperature")) {
                const val = args_iter.next() orelse {
                    printFlagError("--temperature", "requires a value");
                    return error.MissingValue;
                };
                result.temperature = std.fmt.parseFloat(f64, val) catch {
                    printFlagError("--temperature", "must be a number");
                    return error.InvalidNumber;
                };
            } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--max-tokens")) {
                const val = args_iter.next() orelse {
                    printFlagError("--max-tokens", "requires a value");
                    return error.MissingValue;
                };
                result.max_tokens = std.fmt.parseInt(u32, val, 10) catch {
                    printFlagError("--max-tokens", "must be a positive integer");
                    return error.InvalidNumber;
                };
            } else if (std.mem.eql(u8, arg, "--api-key")) {
                result.api_key = args_iter.next() orelse {
                    printFlagError("--api-key", "requires a value");
                    return error.MissingValue;
                };
            } else if (std.mem.eql(u8, arg, "--config")) {
                result.config_path = args_iter.next() orelse {
                    printFlagError("--config", "requires a value");
                    return error.MissingValue;
                };
            } else if (std.mem.eql(u8, arg, "--dump-config")) {
                result.dump_config = true;
            } else if (std.mem.eql(u8, arg, "--init")) {
                result.do_init = true;
            } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                result.show_help = true;
            } else {
                const stderr = std.io.getStdErr().writer();
                stderr.print("Unknown flag: {s}\nTry 'zc --help' for more information.\n", .{arg}) catch {};
                return error.UnknownFlag;
            }
        } else {
            // Positional argument — part of the prompt
            try prompt_parts.append(arg);
        }
    }

    // Join positional args into prompt
    if (prompt_parts.items.len > 0) {
        result.prompt = try std.mem.join(allocator, " ", prompt_parts.items);
    }

    return result;
}

fn printFlagError(flag: []const u8, msg: []const u8) void {
    const stderr = std.io.getStdErr().writer();
    stderr.print("Error: {s} {s}\n", .{ flag, msg }) catch {};
}

/// Print help text to stdout.
pub fn printHelp() void {
    const stdout = std.io.getStdOut().writer();
    stdout.writeAll(help_text) catch {};
}

const help_text =
    \\zc — Zig AI Coding Assistant
    \\
    \\USAGE:
    \\  zc [OPTIONS] <prompt...>
    \\
    \\OPTIONS:
    \\  -p, --provider <name>      LLM provider (glm, openai, anthropic, deepseek, ollama)
    \\  -m, --model <name>         Model name or alias
    \\  -T, --temperature <float>  Sampling temperature (0.0 - 2.0)
    \\  -t, --max-tokens <int>     Maximum output tokens
    \\  --api-key <key>            API key (overrides all other key sources)
    \\  --config <path>            Path to config file
    \\  --dump-config              Print resolved configuration and exit
    \\  --init                     Create default config files in ~/.config/zc/
    \\  -h, --help                 Show this help
    \\
    \\EXAMPLES:
    \\  zc "explain this code"
    \\  zc --provider glm --model glm-4.7-flash "hello"
    \\  zc --init
    \\  zc --dump-config
    \\
    \\CONFIG FILES:
    \\  ~/.config/zc/config.json   Global configuration
    \\  ~/.config/zc/auth.json     API keys (chmod 600)
    \\  .zc.json                   Project-level overrides
    \\
    \\ENVIRONMENT:
    \\  ZAICA_PROVIDER       Override provider
    \\  ZAICA_MODEL          Override model
    \\  ZAICA_API_KEY        API key (any provider)
    \\  GLM_API_KEY           GLM-specific API key
    \\  OPENAI_API_KEY        OpenAI-specific API key
    \\  ANTHROPIC_API_KEY     Anthropic-specific API key
    \\  DEEPSEEK_API_KEY      DeepSeek-specific API key
    \\
;

test "parseFromIterator: empty args" {
    const allocator = std.testing.allocator;
    var args = [_][]const u8{};
    var iter = SliceIterator.init(&args);
    const result = try parseFromIterator(allocator, &iter);
    try std.testing.expect(result.provider == null);
    try std.testing.expect(result.prompt == null);
    try std.testing.expect(!result.dump_config);
}

test "parseFromIterator: prompt only" {
    const allocator = std.testing.allocator;
    var args = [_][]const u8{ "hello", "world" };
    var iter = SliceIterator.init(&args);
    const result = try parseFromIterator(allocator, &iter);
    defer allocator.free(result.prompt.?);
    try std.testing.expectEqualStrings("hello world", result.prompt.?);
}

test "parseFromIterator: flags and prompt" {
    const allocator = std.testing.allocator;
    var args = [_][]const u8{ "--provider", "glm", "-m", "glm-4.7", "tell me a joke" };
    var iter = SliceIterator.init(&args);
    const result = try parseFromIterator(allocator, &iter);
    defer allocator.free(result.prompt.?);
    try std.testing.expectEqualStrings("glm", result.provider.?);
    try std.testing.expectEqualStrings("glm-4.7", result.model.?);
    try std.testing.expectEqualStrings("tell me a joke", result.prompt.?);
}

test "parseFromIterator: dump-config flag" {
    var args = [_][]const u8{"--dump-config"};
    var iter = SliceIterator.init(&args);
    const result = try parseFromIterator(std.testing.allocator, &iter);
    try std.testing.expect(result.dump_config);
}

test "parseFromIterator: help flag" {
    var args = [_][]const u8{"--help"};
    var iter = SliceIterator.init(&args);
    const result = try parseFromIterator(std.testing.allocator, &iter);
    try std.testing.expect(result.show_help);
}

/// Simple slice-based iterator for testing (matches ArgIterator interface).
const SliceIterator = struct {
    args: []const []const u8,
    index: usize,

    pub fn init(args: []const []const u8) SliceIterator {
        return .{ .args = args, .index = 0 };
    }

    pub fn next(self: *SliceIterator) ?[]const u8 {
        if (self.index >= self.args.len) return null;
        const arg = self.args[self.index];
        self.index += 1;
        return arg;
    }
};
