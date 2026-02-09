const std = @import("std");

/// Log verbosity level.
pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,

    pub fn jsonStringify(self: LogLevel, jw: anytype) !void {
        try jw.write(@tagName(self));
    }
};

/// Tool permission settings.
pub const ToolsConfig = struct {
    allow_exec: bool = false,
    allow_file_write: bool = true,
    allow_net: bool = false,
};

/// User-facing config (serializable to/from JSON).
/// Fields with defaults serve as comptime layer-1 defaults.
pub const Config = struct {
    provider: []const u8 = "glm",
    model: []const u8 = "glm-4.7-flash",
    system_prompt: []const u8 =
        "You are a coding assistant with access to tools. " ++
        "Use tools when the user asks to read, write, or search files, run commands, or explore the codebase. " ++
        "Prefer read_file over execute_bash for reading files. " ++
        "Prefer list_files over execute_bash for listing directories. " ++
        "Prefer search_files over execute_bash for searching code. " ++
        "Do NOT use execute_bash for interactive or long-running commands (editors, servers, REPLs). " ++
        "Always explain what you're about to do before using tools. " ++
        "Answer in the same language as the user.",
    max_tokens: u32 = 8192,
    temperature: f64 = 0.0,
    max_context_tokens: u32 = 128000,
    tools: ToolsConfig = .{},
    log_level: LogLevel = .info,
};

/// Wire format for tool definitions and message serialization.
/// Each provider may expect different JSON structures for tool calls.
pub const ToolFormat = enum {
    /// OpenAI-compatible: tool_calls[{id, function: {name, arguments}}]
    /// Used by: OpenAI, GLM, DeepSeek, Ollama, most OpenAI-compatible APIs
    openai_compatible,
    /// Anthropic Messages API: tool_use content blocks with separate tool_result messages
    /// Used by: Anthropic (Claude)
    anthropic_native,
    /// Gemini native: functionCall / functionResponse parts
    /// Used by: Google Gemini
    gemini_native,
};

/// Built-in provider preset.
pub const ProviderPreset = struct {
    name: []const u8,
    base_url: []const u8,
    key_env_var: ?[]const u8,
    default_model: []const u8,
    /// Whether the completions endpoint is at base_url + "/chat/completions".
    chat_completions_path: []const u8 = "/chat/completions",
    /// Whether provider requires an API key (Ollama doesn't).
    requires_key: bool = true,
    /// Wire format for tool calls (Attractor unified-llm-spec aligned).
    tool_format: ToolFormat = .openai_compatible,
};

/// Resolved auth information.
pub const ResolvedAuth = struct {
    api_key: ?[]const u8 = null,
    key_source: KeySource = .none,

    pub const KeySource = enum {
        cli_flag,
        zaica_env,
        provider_env,
        auth_file,
        none,

        pub fn jsonStringify(self: KeySource, jw: anytype) !void {
            try jw.write(@tagName(self));
        }
    };
};

/// Fully resolved configuration ready for use.
pub const ResolvedConfig = struct {
    config: Config,
    active_provider: ProviderPreset,
    auth: ResolvedAuth,
    resolved_model: []const u8,
    completions_url: []const u8,
};

/// Parsed CLI arguments.
pub const CliArgs = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    temperature: ?f64 = null,
    max_tokens: ?u32 = null,
    api_key: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    dump_config: bool = false,
    do_init: bool = false,
    show_help: bool = false,
    continue_last: bool = false,
    session_id: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
};

/// Result returned by config.load().
pub const LoadResult = struct {
    resolved: ResolvedConfig,
    dump_config: bool,
    prompt: ?[]const u8,
    continue_last: bool,
    session_id: ?[]const u8,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *LoadResult) void {
        self.arena.deinit();
    }

    /// Write the resolved config as JSON to a writer.
    pub fn writeJson(self: *const LoadResult, writer: anytype) !void {
        const rc = &self.resolved;
        try writer.writeAll("{\n");
        try writer.print("  \"provider\": \"{s}\",\n", .{rc.config.provider});
        try writer.print("  \"model\": \"{s}\",\n", .{rc.resolved_model});
        try writer.print("  \"system_prompt\": \"{s}\",\n", .{rc.config.system_prompt});
        try writer.print("  \"max_tokens\": {d},\n", .{rc.config.max_tokens});
        try writer.print("  \"temperature\": {d},\n", .{rc.config.temperature});
        try writer.print("  \"max_context_tokens\": {d},\n", .{rc.config.max_context_tokens});
        try writer.writeAll("  \"tools\": {\n");
        try writer.print("    \"allow_exec\": {s},\n", .{if (rc.config.tools.allow_exec) "true" else "false"});
        try writer.print("    \"allow_file_write\": {s},\n", .{if (rc.config.tools.allow_file_write) "true" else "false"});
        try writer.print("    \"allow_net\": {s}\n", .{if (rc.config.tools.allow_net) "true" else "false"});
        try writer.writeAll("  },\n");
        try writer.print("  \"log_level\": \"{s}\",\n", .{@tagName(rc.config.log_level)});
        try writer.print("  \"completions_url\": \"{s}\",\n", .{rc.completions_url});
        try writer.print("  \"provider_base_url\": \"{s}\",\n", .{rc.active_provider.base_url});

        // Show key source but not the actual key
        try writer.print("  \"api_key_source\": \"{s}\",\n", .{@tagName(rc.auth.key_source)});
        if (rc.auth.api_key) |key| {
            if (key.len > 8) {
                try writer.print("  \"api_key\": \"{s}...{s}\"\n", .{ key[0..4], key[key.len - 4 ..] });
            } else {
                try writer.writeAll("  \"api_key\": \"****\"\n");
            }
        } else {
            try writer.writeAll("  \"api_key\": null\n");
        }
        try writer.writeAll("}");
    }
};

test "Config defaults" {
    const c = Config{};
    try std.testing.expectEqualStrings("glm", c.provider);
    try std.testing.expectEqualStrings("glm-4.7-flash", c.model);
    try std.testing.expectEqual(@as(u32, 8192), c.max_tokens);
    try std.testing.expectEqual(@as(f64, 0.0), c.temperature);
}

test "CliArgs defaults" {
    const args = CliArgs{};
    try std.testing.expect(args.provider == null);
    try std.testing.expect(args.model == null);
    try std.testing.expect(!args.dump_config);
    try std.testing.expect(!args.do_init);
}
