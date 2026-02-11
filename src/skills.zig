/// Skills system — markdown-based knowledge injection for the LLM.
///
/// Skills are SKILL.md files with YAML-like JSON frontmatter that teach the LLM
/// specific domains. They live in `.zaica/skills/<name>/SKILL.md` (project-local)
/// or `~/.config/zaica/skills/<name>/SKILL.md` (user-global).
///
/// At startup, skills are scanned and their metadata extracted. "Always-on" skills
/// are injected directly into the system prompt. Other skills appear as an XML
/// summary that the LLM can load on demand via the `load_skill` tool.
const std = @import("std");

/// Where a skill was found.
pub const SkillSource = enum {
    project,
    global,
};

/// Metadata and content for a single skill.
pub const SkillInfo = struct {
    name: []const u8,
    description: []const u8,
    always: bool,
    available: bool,
    missing: []const u8, // comma-separated missing binaries/envs, empty if available
    source: SkillSource,
    path: []const u8,
    content: []const u8, // full file content (including frontmatter)
};

/// Scan for skills in project-local and global directories.
/// Project skills override global skills of the same name.
/// Returns a list of SkillInfo (all strings owned by allocator).
pub fn scan(allocator: std.mem.Allocator, project_dir: ?[]const u8) []SkillInfo {
    var skills: std.ArrayList(SkillInfo) = .empty;
    var seen_names = std.StringHashMap(void).init(allocator);
    defer seen_names.deinit();

    // 1. Project-local skills (higher priority)
    if (project_dir) |proj| {
        const proj_skills_path = std.fmt.allocPrint(allocator, "{s}/.zaica/skills", .{proj}) catch null;
        if (proj_skills_path) |p| {
            defer allocator.free(p);
            scanDir(allocator, p, .project, &skills, &seen_names);
        }
    }

    // 2. Global skills
    if (std.posix.getenv("HOME")) |home| {
        const global_skills_path = std.fmt.allocPrint(allocator, "{s}/.config/zaica/skills", .{home}) catch null;
        if (global_skills_path) |p| {
            defer allocator.free(p);
            scanDir(allocator, p, .global, &skills, &seen_names);
        }
    }

    return skills.toOwnedSlice(allocator) catch &.{};
}

/// Scan a single directory for skill subdirectories containing SKILL.md.
fn scanDir(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    source: SkillSource,
    skills: *std.ArrayList(SkillInfo),
    seen_names: *std.StringHashMap(void),
) void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;

        // Skip if already seen (project overrides global)
        if (seen_names.contains(entry.name)) continue;

        const skill_path = std.fmt.allocPrint(allocator, "{s}/{s}/SKILL.md", .{ dir_path, entry.name }) catch continue;

        const file = std.fs.openFileAbsolute(skill_path, .{}) catch {
            allocator.free(skill_path);
            continue;
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, 1 * 1024 * 1024) catch {
            allocator.free(skill_path);
            continue;
        };

        const name = allocator.dupe(u8, entry.name) catch {
            allocator.free(skill_path);
            allocator.free(content);
            continue;
        };

        // Parse frontmatter
        var description: []const u8 = "";
        var always = false;
        var missing_buf: std.ArrayList(u8) = .empty;

        if (parseFrontmatter(allocator, content)) |fm| {
            defer fm.deinit();
            if (fm.value == .object) {
                if (fm.value.object.get("description")) |v| {
                    if (v == .string)
                        description = allocator.dupe(u8, v.string) catch "";
                }
                if (fm.value.object.get("always")) |v| {
                    if (v == .bool) always = v.bool;
                }
                if (fm.value.object.get("requires")) |req| {
                    if (req == .object) {
                        if (req.object.get("bins")) |bins| {
                            if (bins == .array) {
                                for (bins.array.items) |bin| {
                                    if (bin == .string) {
                                        if (!checkBin(bin.string)) {
                                            if (missing_buf.items.len > 0)
                                                missing_buf.appendSlice(allocator, ", ") catch {};
                                            missing_buf.appendSlice(allocator, bin.string) catch {};
                                        }
                                    }
                                }
                            }
                        }
                        if (req.object.get("envs")) |envs| {
                            if (envs == .array) {
                                for (envs.array.items) |env| {
                                    if (env == .string) {
                                        if (!checkEnv(env.string)) {
                                            if (missing_buf.items.len > 0)
                                                missing_buf.appendSlice(allocator, ", ") catch {};
                                            missing_buf.appendSlice(allocator, env.string) catch {};
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        const missing = missing_buf.toOwnedSlice(allocator) catch "";
        const available = missing.len == 0;

        seen_names.put(name, {}) catch {};
        skills.append(allocator, .{
            .name = name,
            .description = description,
            .always = always,
            .available = available,
            .missing = missing,
            .source = source,
            .path = skill_path,
            .content = content,
        }) catch {
            allocator.free(name);
            allocator.free(skill_path);
            allocator.free(content);
            if (description.len > 0) allocator.free(description);
            allocator.free(missing);
        };
    }
}

/// Build the system prompt section for skills.
/// Returns full content for always:true skills + XML summary for the rest.
pub fn buildPromptSection(allocator: std.mem.Allocator, skill_list: []const SkillInfo) []const u8 {
    if (skill_list.len == 0) return "";

    var buf: std.ArrayList(u8) = .empty;
    const writer = buf.writer(allocator);

    // Always-on skills: inject full body
    for (skill_list) |s| {
        if (s.always and s.available) {
            const body = stripFrontmatter(s.content);
            writer.writeAll("\n\n") catch {};
            writer.writeAll(body) catch {};
        }
    }

    // Non-always skills: XML summary
    var has_loadable = false;
    for (skill_list) |s| {
        if (!s.always) {
            has_loadable = true;
            break;
        }
    }

    if (has_loadable) {
        writer.writeAll("\n\n<available-skills>\n") catch {};
        for (skill_list) |s| {
            if (s.always) continue;
            if (s.available) {
                writer.print("  <skill name=\"{s}\" available=\"true\">{s}</skill>\n", .{ s.name, s.description }) catch {};
            } else {
                writer.print("  <skill name=\"{s}\" available=\"false\" missing=\"{s}\">{s}</skill>\n", .{ s.name, s.missing, s.description }) catch {};
            }
        }
        writer.writeAll("</available-skills>\nUse the load_skill tool to load a skill's full instructions when you need specialized knowledge.\n") catch {};
    }

    return buf.toOwnedSlice(allocator) catch "";
}

/// Load a skill's full content (with frontmatter stripped) by name.
pub fn loadSkill(skill_list: []const SkillInfo, name: []const u8) ?[]const u8 {
    for (skill_list) |s| {
        if (std.mem.eql(u8, s.name, name)) {
            return stripFrontmatter(s.content);
        }
    }
    return null;
}

/// Parse the JSON frontmatter from a SKILL.md file.
/// Frontmatter is delimited by `---` lines at the start of the file.
pub fn parseFrontmatter(allocator: std.mem.Allocator, content: []const u8) ?std.json.Parsed(std.json.Value) {
    if (!std.mem.startsWith(u8, content, "---")) return null;
    const after_first = content[3..];
    // Find the closing ---
    const end_idx = std.mem.indexOf(u8, after_first, "\n---") orelse return null;
    const json_str = std.mem.trim(u8, after_first[0..end_idx], " \n\r\t");
    if (json_str.len == 0) return null;
    return std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch null;
}

/// Strip the frontmatter from SKILL.md content, returning just the body.
pub fn stripFrontmatter(content: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, content, "---")) return content;
    const after_first = content[3..];
    const end_idx = std.mem.indexOf(u8, after_first, "\n---") orelse return content;
    const body_start = end_idx + 4; // skip "\n---"
    if (body_start >= after_first.len) return "";
    // Skip past the closing --- line (find next newline)
    const rest = after_first[body_start..];
    const nl = std.mem.indexOf(u8, rest, "\n") orelse return std.mem.trim(u8, rest, " \n\r\t");
    return std.mem.trimLeft(u8, rest[nl + 1 ..], "\n");
}

/// Check if a binary is available on PATH.
pub fn checkBin(name: []const u8) bool {
    const result = std.process.Child.run(.{
        .argv = &.{ "/usr/bin/which", name },
        .allocator = std.heap.page_allocator,
        .max_output_bytes = 1024,
    }) catch return false;
    std.heap.page_allocator.free(result.stdout);
    std.heap.page_allocator.free(result.stderr);
    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

/// Check if an environment variable is set.
pub fn checkEnv(name: []const u8) bool {
    return std.posix.getenv(name) != null;
}

/// Free a list of SkillInfo and all owned strings.
pub fn freeSkills(allocator: std.mem.Allocator, skill_list: []SkillInfo) void {
    for (skill_list) |s| {
        if (s.name.len > 0) allocator.free(s.name);
        if (s.description.len > 0) allocator.free(s.description);
        if (s.missing.len > 0) allocator.free(s.missing);
        if (s.path.len > 0) allocator.free(s.path);
        if (s.content.len > 0) allocator.free(s.content);
    }
    allocator.free(skill_list);
}

/// Print a formatted list of skills to stdout.
pub fn printSkillList(skill_list: []const SkillInfo) void {
    const io = @import("io.zig");
    io.writeOut("\r\n\x1b[1mSkills:\x1b[0m\r\n") catch {};
    if (skill_list.len == 0) {
        io.writeOut("  \x1b[2m(none found)\x1b[0m\r\n") catch {};
    } else {
        for (skill_list) |s| {
            if (s.available) {
                io.writeOut("  \x1b[32m\xe2\x9c\x93\x1b[0m ") catch {}; // green ✓
            } else {
                io.writeOut("  \x1b[31m\xe2\x9c\x97\x1b[0m ") catch {}; // red ✗
            }
            io.writeOut(s.name) catch {};
            // Pad name to 12 chars
            var pad: usize = if (s.name.len < 12) 12 - s.name.len else 1;
            while (pad > 0) : (pad -= 1) {
                io.writeOut(" ") catch {};
            }
            io.writeOut("\x1b[2m\xe2\x80\x94 ") catch {}; // dim —
            io.writeOut(s.description) catch {};
            io.writeOut("\x1b[0m") catch {};
            // Source + always tag
            const source_label: []const u8 = switch (s.source) {
                .project => " (project",
                .global => " (global",
            };
            io.writeOut("\x1b[2m") catch {};
            io.writeOut(source_label) catch {};
            if (s.always) io.writeOut(", always") catch {};
            io.writeOut(")") catch {};
            if (!s.available) {
                io.writeOut(" \x1b[31m[missing: ") catch {};
                io.writeOut(s.missing) catch {};
                io.writeOut("]\x1b[0m") catch {};
            }
            io.writeOut("\x1b[0m\r\n") catch {};
        }
    }
    io.writeOut("\r\n") catch {};
}

// ── Tests ────────────────────────────────────────────────────────────

test "parseFrontmatter: valid JSON" {
    const allocator = std.testing.allocator;
    const content =
        \\---
        \\{"name":"test","description":"A test skill","always":false}
        \\---
        \\# Test Skill
        \\Some content here.
    ;
    const result = parseFrontmatter(allocator, content);
    try std.testing.expect(result != null);
    var fm = result.?;
    defer fm.deinit();
    try std.testing.expect(fm.value == .object);
    const name_val = fm.value.object.get("name").?;
    try std.testing.expectEqualStrings("test", name_val.string);
}

test "parseFrontmatter: no frontmatter" {
    const allocator = std.testing.allocator;
    try std.testing.expect(parseFrontmatter(allocator, "# Just markdown") == null);
}

test "stripFrontmatter: strips correctly" {
    const content =
        \\---
        \\{"name":"test"}
        \\---
        \\# Body
        \\Content here.
    ;
    const body = stripFrontmatter(content);
    try std.testing.expect(std.mem.startsWith(u8, body, "# Body"));
}

test "stripFrontmatter: no frontmatter returns original" {
    const content = "# Just content";
    try std.testing.expectEqual(content.ptr, stripFrontmatter(content).ptr);
}

test "checkEnv: HOME exists" {
    try std.testing.expect(checkEnv("HOME"));
}

test "checkEnv: nonexistent" {
    try std.testing.expect(!checkEnv("ZAICA_NONEXISTENT_TEST_VAR_12345"));
}

test "checkBin: sh exists" {
    try std.testing.expect(checkBin("sh"));
}

test "checkBin: nonexistent" {
    try std.testing.expect(!checkBin("zaica_nonexistent_binary_12345"));
}

test "buildPromptSection: empty list" {
    const allocator = std.testing.allocator;
    const result = buildPromptSection(allocator, &.{});
    try std.testing.expectEqualStrings("", result);
}

test "loadSkill: found" {
    const skills = [_]SkillInfo{.{
        .name = "test",
        .description = "test skill",
        .always = false,
        .available = true,
        .missing = "",
        .source = .global,
        .path = "/tmp/test",
        .content = "---\n{\"name\":\"test\"}\n---\n# Body content",
    }};
    const result = loadSkill(&skills, "test");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.startsWith(u8, result.?, "# Body"));
}

test "loadSkill: not found" {
    try std.testing.expect(loadSkill(&.{}, "nonexistent") == null);
}
