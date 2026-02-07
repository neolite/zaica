const std = @import("std");
const types = @import("types.zig");
const presets = @import("presets.zig");

pub const ValidationError = error{
    UnknownProvider,
    EmptyModel,
    TemperatureOutOfRange,
    InvalidMaxTokens,
    MissingApiKey,
};

/// Validate a resolved config. Returns a descriptive error message on failure.
pub fn validate(resolved: *const types.ResolvedConfig) ?[]const u8 {
    // Provider must be known
    if (presets.findByName(resolved.config.provider) == null) {
        return "Unknown provider. Available: glm, anthropic, openai, deepseek, ollama";
    }

    // Model must not be empty
    if (resolved.resolved_model.len == 0) {
        return "Model name cannot be empty.";
    }

    // Temperature must be in [0, 2]
    if (resolved.config.temperature < 0.0 or resolved.config.temperature > 2.0) {
        return "Temperature must be between 0.0 and 2.0.";
    }

    // max_tokens must be > 0
    if (resolved.config.max_tokens == 0) {
        return "max_tokens must be greater than 0.";
    }

    // API key required for non-ollama providers
    if (resolved.active_provider.requires_key and resolved.auth.api_key == null) {
        return null; // Handled separately with detailed message
    }

    return null;
}

/// Check if API key is missing for a provider that requires one.
pub fn needsApiKey(resolved: *const types.ResolvedConfig) bool {
    return resolved.active_provider.requires_key and resolved.auth.api_key == null;
}

test "validate: valid config passes" {
    const resolved = types.ResolvedConfig{
        .config = .{},
        .active_provider = presets.glm,
        .auth = .{ .api_key = "test-key", .key_source = .cli_flag },
        .resolved_model = "glm-4.7-flash",
        .completions_url = "https://api.z.ai/api/paas/v4/chat/completions",
    };
    try std.testing.expect(validate(&resolved) == null);
}

test "validate: bad temperature" {
    const resolved = types.ResolvedConfig{
        .config = .{ .temperature = 3.0 },
        .active_provider = presets.glm,
        .auth = .{ .api_key = "test-key", .key_source = .cli_flag },
        .resolved_model = "glm-4.7-flash",
        .completions_url = "https://api.z.ai/api/paas/v4/chat/completions",
    };
    try std.testing.expect(validate(&resolved) != null);
}

test "validate: empty model" {
    const resolved = types.ResolvedConfig{
        .config = .{},
        .active_provider = presets.glm,
        .auth = .{ .api_key = "test-key", .key_source = .cli_flag },
        .resolved_model = "",
        .completions_url = "https://api.z.ai/api/paas/v4/chat/completions",
    };
    try std.testing.expect(validate(&resolved) != null);
}

test "needsApiKey: ollama doesn't need key" {
    const resolved = types.ResolvedConfig{
        .config = .{ .provider = "ollama" },
        .active_provider = presets.ollama,
        .auth = .{},
        .resolved_model = "llama3",
        .completions_url = "http://localhost:11434/v1/chat/completions",
    };
    try std.testing.expect(!needsApiKey(&resolved));
}

test "needsApiKey: glm needs key" {
    const resolved = types.ResolvedConfig{
        .config = .{},
        .active_provider = presets.glm,
        .auth = .{},
        .resolved_model = "glm-4.7-flash",
        .completions_url = "https://api.z.ai/api/paas/v4/chat/completions",
    };
    try std.testing.expect(needsApiKey(&resolved));
}
