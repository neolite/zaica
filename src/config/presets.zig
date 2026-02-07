const std = @import("std");
const types = @import("types.zig");
const ProviderPreset = types.ProviderPreset;

/// All built-in provider presets.
pub const all = [_]ProviderPreset{
    glm,
    anthropic,
    openai,
    deepseek,
    ollama,
};

pub const glm = ProviderPreset{
    .name = "glm",
    .base_url = "https://api.z.ai/api/paas/v4",
    .key_env_var = "GLM_API_KEY",
    .default_model = "glm-4.7-flash",
    .chat_completions_path = "/chat/completions",
    .requires_key = true,
};

pub const anthropic = ProviderPreset{
    .name = "anthropic",
    .base_url = "https://api.anthropic.com/v1",
    .key_env_var = "ANTHROPIC_API_KEY",
    .default_model = "claude-sonnet-4-5-20250929",
    .chat_completions_path = "/messages",
    .requires_key = true,
};

pub const openai = ProviderPreset{
    .name = "openai",
    .base_url = "https://api.openai.com/v1",
    .key_env_var = "OPENAI_API_KEY",
    .default_model = "gpt-4o",
    .chat_completions_path = "/chat/completions",
    .requires_key = true,
};

pub const deepseek = ProviderPreset{
    .name = "deepseek",
    .base_url = "https://api.deepseek.com/v1",
    .key_env_var = "DEEPSEEK_API_KEY",
    .default_model = "deepseek-chat",
    .chat_completions_path = "/chat/completions",
    .requires_key = true,
};

pub const ollama = ProviderPreset{
    .name = "ollama",
    .base_url = "http://localhost:11434/v1",
    .key_env_var = null,
    .default_model = "llama3",
    .chat_completions_path = "/chat/completions",
    .requires_key = false,
};

/// Look up a provider preset by name.
pub fn findByName(name: []const u8) ?ProviderPreset {
    for (all) |preset| {
        if (std.mem.eql(u8, preset.name, name)) {
            return preset;
        }
    }
    return null;
}

/// Return a comma-separated list of available provider names.
pub fn availableNames() []const u8 {
    return "glm, anthropic, openai, deepseek, ollama";
}

test "findByName: known providers" {
    try std.testing.expect(findByName("glm") != null);
    try std.testing.expect(findByName("anthropic") != null);
    try std.testing.expect(findByName("openai") != null);
    try std.testing.expect(findByName("deepseek") != null);
    try std.testing.expect(findByName("ollama") != null);
}

test "findByName: unknown provider" {
    try std.testing.expect(findByName("unknown") == null);
}

test "glm preset values" {
    const p = findByName("glm").?;
    try std.testing.expectEqualStrings("https://api.z.ai/api/paas/v4", p.base_url);
    try std.testing.expectEqualStrings("GLM_API_KEY", p.key_env_var.?);
    try std.testing.expectEqualStrings("glm-4.7-flash", p.default_model);
    try std.testing.expect(p.requires_key);
}
