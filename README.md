# zaica

**Zig AI Coding Assistant** — multi-provider LLM agent CLI with tool calling.

A lightweight coding assistant that runs in your terminal, calls tools autonomously, and streams responses in real-time. Built from scratch in Zig 0.15 with zero runtime dependencies beyond the standard library.

## Features

- **Multi-provider**: GLM, OpenAI, Anthropic, DeepSeek, Ollama (OpenAI-compatible API)
- **Agentic tool calling**: LLM autonomously reads files, runs commands, searches code
- **SSE streaming**: Real-time token streaming with reasoning display
- **Interactive REPL**: Line editing, history, UTF-8/Cyrillic support
- **3-tier permissions**: `[y]es all` / `[s]afe only` / `[n]o` — ask-once per session
- **Tool risk levels**: Safe (read), Write, Dangerous (bash) — color-coded

## Tools

| Tool | Risk | Description |
|------|------|-------------|
| `read_file` | safe | Read file contents |
| `list_files` | safe | List directory entries |
| `search_files` | safe | Grep pattern search |
| `write_file` | write | Create/overwrite files |
| `execute_bash` | dangerous | Run bash commands (10s timeout) |

## Quick Start

```bash
# Build
zig build

# Single-shot mode
export GLM_API_KEY="your-key"
./zig-out/bin/zc "explain this codebase"

# Interactive REPL
./zig-out/bin/zc
```

## REPL Commands

```
/help   — show commands and permission keys
/tools  — list available tools with risk levels
/exit   — quit (also /quit, /q, Cyrillic variants)
```

## Configuration

Layered config system: defaults -> presets -> `~/.config/zaica/config.json` -> project `zaica.json` -> env vars -> CLI flags.

```bash
# Initialize config
zc --init

# Use different provider
zc --provider openai --model gpt-4o

# CLI flags
zc --provider anthropic --model claude-sonnet-4-20250514 --temperature 0.7
```

### Environment Variables

```bash
GLM_API_KEY=...           # GLM (default provider)
OPENAI_API_KEY=...        # OpenAI
ANTHROPIC_API_KEY=...     # Anthropic
DEEPSEEK_API_KEY=...      # DeepSeek
ZAICA_PROVIDER=openai     # Override provider
ZAICA_MODEL=gpt-4o        # Override model
```

### Config File (`~/.config/zaica/config.json`)

```json
{
  "provider": "glm",
  "model": "glm-4.7-flash",
  "max_tokens": 8192,
  "temperature": 0.0,
  "system_prompt": "You are a coding assistant..."
}
```

## Architecture

```
src/
  main.zig           — entry point
  repl.zig           — REPL with line editing + agentic loop
  tools.zig          — 5 tools, executor, risk levels, permissions
  io.zig             — I/O helpers (terminal-safe \r\n translation)
  config/            — layered JSON config system
  client/
    mod.zig          — chat API (single-shot + multi-turn with tools)
    http.zig         — HTTP streaming + tool call accumulation
    sse.zig          — SSE parser (content, reasoning, tool_call_delta)
    message.zig      — ChatMessage union, request body builder
```

### Key Design Decisions

- **ChatMessage as tagged union**: `.text`, `.tool_use`, `.tool_result` — type-safe message history
- **Error-as-string pattern**: Tool errors returned as strings so the LLM can handle them
- **Comptime JSON schemas**: Tool parameter schemas are comptime string literals (zero allocation)
- **Terminal resilience**: Forces cooked mode on startup, `\n` -> `\r\n` translation regardless of OPOST

## Requirements

- Zig 0.15.2+
- macOS (kqueue) or Linux (epoll/io_uring)

## License

MIT
