/// Reactive session state powered by zefx (Effector-inspired).
///
/// Replaces the imperative StatusBar struct with a reactive graph:
///   Events → Stores → Watchers (side effects)
///
/// All .emit() calls happen on the main thread only.
/// Spinner thread reads atomics (io.status_static) set by watchers.
const std = @import("std");
const zefx = @import("zefx");
const io = @import("io.zig");
const tools = @import("tools.zig");

/// Token usage payload for the tokensReceived event.
pub const TokenUsage = struct {
    prompt_tokens: u64,
    completion_tokens: u64,
};

/// Terminal dimensions payload for the terminalResized event.
pub const TermSize = struct {
    rows: u16,
    cols: u16,
};

/// Current phase of the agentic loop.
pub const Phase = enum(u8) {
    idle,
    streaming,
    executing_tools,
    awaiting_permission,
};

/// Reactive session state — owns the zefx domain and all events/stores.
///
/// Domain is heap-allocated because zefx Events/Stores capture `*Engine`
/// (a pointer into Domain). If Domain were stored by value, returning
/// SessionState from init() would move it, invalidating those pointers.
pub const SessionState = struct {
    domain: *zefx.Domain,
    allocator: std.mem.Allocator,

    events: struct {
        tokens_received: *zefx.Event(TokenUsage),
        permission_granted: *zefx.Event(tools.PermissionLevel),
        terminal_resized: *zefx.Event(TermSize),
        phase_changed: *zefx.Event(Phase),
        cancel_requested: *zefx.Event(bool),
    },

    stores: struct {
        prompt_tokens: *zefx.Store(u64),
        completion_tokens: *zefx.Store(u64),
        total_tokens: *zefx.Store(u64),
        permission: *zefx.Store(tools.PermissionLevel),
        term_rows: *zefx.Store(u16),
        term_cols: *zefx.Store(u16),
        phase: *zefx.Store(Phase),
        cancelled: *zefx.Store(bool),
    },

    model_name: []const u8,
    context_limit: u32,
    start_time: i64,

    pub fn deinit(self: *SessionState) void {
        self.domain.deinit();
        self.allocator.destroy(self.domain);
    }
};

// ── File-level state for watchers ────────────────────────────────────
//
// zefx watchers are plain fn(*) void — no closures. We use a file-level
// pointer so watchers can read sibling stores. Safe because zefx is
// single-threaded and watchers run after all reducers settle.

var session_ptr: *SessionState = undefined;

/// Initialize a reactive session state graph.
pub fn init(
    allocator: std.mem.Allocator,
    model_name: []const u8,
    context_limit: u32,
    rows: u16,
    cols: u16,
) SessionState {
    // Heap-allocate Domain so its Engine address is stable.
    // Events/Stores capture *Engine — moving Domain would invalidate them.
    const domain = allocator.create(zefx.Domain) catch @panic("OOM: zefx Domain");
    domain.* = zefx.createDomain(allocator);

    // ── Events ───────────────────────────────────────────────────────
    const tokens_received = domain.createEvent(TokenUsage);
    const permission_granted = domain.createEvent(tools.PermissionLevel);
    const terminal_resized = domain.createEvent(TermSize);
    const phase_changed = domain.createEvent(Phase);
    const cancel_requested = domain.createEvent(bool);

    // ── Stores ───────────────────────────────────────────────────────

    // Accumulator: prompt_tokens += payload.prompt_tokens
    const prompt_tokens = domain.createStore(u64, 0);
    _ = prompt_tokens.on(tokens_received, &struct {
        fn reduce(s: u64, payload: TokenUsage) ?u64 {
            return s + payload.prompt_tokens;
        }
    }.reduce);

    // Accumulator: completion_tokens += payload.completion_tokens
    const completion_tokens = domain.createStore(u64, 0);
    _ = completion_tokens.on(tokens_received, &struct {
        fn reduce(s: u64, payload: TokenUsage) ?u64 {
            return s + payload.completion_tokens;
        }
    }.reduce);

    // Derived: total = prompt + completion (via sample)
    const total_tokens = domain.createStore(u64, 0);
    _ = domain.sample(.{
        .clock = tokens_received,
        .source = .{ .p = prompt_tokens, .c = completion_tokens },
        .fn_ = &struct {
            fn compute(snap: zefx.shape.SnapshotTypeOf(struct {
                p: *zefx.Store(u64),
                c: *zefx.Store(u64),
            })) u64 {
                return snap.p + snap.c;
            }
        }.compute,
        .target = total_tokens,
    });

    // Permission: last granted value
    const permission = domain.restore(permission_granted, tools.PermissionLevel.none);

    // Terminal dimensions
    const term_rows = domain.createStore(u16, rows);
    _ = term_rows.on(terminal_resized, &struct {
        fn reduce(_: u16, payload: TermSize) ?u16 {
            return payload.rows;
        }
    }.reduce);

    const term_cols = domain.createStore(u16, cols);
    _ = term_cols.on(terminal_resized, &struct {
        fn reduce(_: u16, payload: TermSize) ?u16 {
            return payload.cols;
        }
    }.reduce);

    // Phase: restore from phase_changed events
    const phase = domain.restore(phase_changed, Phase.idle);

    // Cancelled: set by cancel_requested, auto-reset to false when phase returns to idle
    const cancelled = domain.restore(cancel_requested, false);
    _ = cancelled.on(phase_changed, &struct {
        fn reduce(cur: bool, p: Phase) ?bool {
            return if (p == .idle) false else cur;
        }
    }.reduce);

    // ── Watchers (side effects) ──────────────────────────────────────
    // Register watchers now — they reference the file-level session_ptr,
    // which will be set by bind() after the caller has a stable address.
    _ = total_tokens.watch(&watchRenderStatus);
    _ = permission.watch(&watchRenderStatus_perm);
    _ = term_rows.watch(&watchResize);
    _ = cancelled.watch(&watchCancelled);
    _ = phase.watch(&watchPhase);

    return SessionState{
        .domain = domain,
        .allocator = allocator,
        .events = .{
            .tokens_received = tokens_received,
            .permission_granted = permission_granted,
            .terminal_resized = terminal_resized,
            .phase_changed = phase_changed,
            .cancel_requested = cancel_requested,
        },
        .stores = .{
            .prompt_tokens = prompt_tokens,
            .completion_tokens = completion_tokens,
            .total_tokens = total_tokens,
            .permission = permission,
            .term_rows = term_rows,
            .term_cols = term_cols,
            .phase = phase,
            .cancelled = cancelled,
        },
        .model_name = model_name,
        .context_limit = context_limit,
        .start_time = std.time.timestamp(),
    };
}

/// Bind the session to the file-level pointer and perform initial render.
/// MUST be called after init(), once the SessionState has a stable address.
pub fn bind(s: *SessionState) void {
    session_ptr = s;
    renderStatus(s);
}

/// Refresh the status bar atomics and re-render. Call before starting
/// the spinner thread to ensure it has fresh elapsed-time content.
pub fn syncStatus(s: *const SessionState) void {
    renderStatus(s);
}

// ── Watcher functions ────────────────────────────────────────────────

/// Re-render status bar when total tokens change.
fn watchRenderStatus(_: u64) void {
    renderStatus(session_ptr);
}

/// Re-render status bar when permission changes.
fn watchRenderStatus_perm(_: tools.PermissionLevel) void {
    renderStatus(session_ptr);
}

/// Update status bar when cancel state changes.
fn watchCancelled(is_cancelled: bool) void {
    if (is_cancelled) {
        io.setSpinnerLabel("Cancelling...");
    }
    renderStatus(session_ptr);
}

/// Update status bar when phase changes.
fn watchPhase(_: Phase) void {
    renderStatus(session_ptr);
}

/// Re-layout terminal when rows change.
fn watchResize(_: u16) void {
    const s = session_ptr;
    const r = s.stores.term_rows.get();
    const c = s.stores.term_cols.get();
    if (std.posix.isatty(std.fs.File.stdout().handle)) {
        io.setupScrollRegion(r);
        io.renderSeparator(r -| 3, c); // top separator
        io.renderSeparator(r -| 1, c); // bottom separator
        io.printOut("\x1b[{d};1H", .{r -| 4}) catch {}; // cursor back to scroll region
    }
    renderStatus(s);
}

// ── Status bar rendering ─────────────────────────────────────────────

/// Format and render the status bar, updating io atomics for the spinner thread.
/// Skips terminal I/O when stdout is not a TTY (e.g. during tests).
fn renderStatus(s: *const SessionState) void {
    var buf: [512]u8 = undefined;
    const len = formatStatic(s, &buf);
    io.setStatusStatic(buf[0..len]);
    io.setStatusRows(s.stores.term_rows.get());

    // Skip terminal rendering when not connected to a TTY
    if (!std.posix.isatty(std.fs.File.stdout().handle)) return;

    // Direct render (status bar on last row)
    var render_buf: [520]u8 = undefined;
    render_buf[0] = ' ';
    @memcpy(render_buf[1..][0..len], buf[0..len]);
    io.renderStatusBar(s.stores.term_rows.get(), render_buf[0 .. len + 1]);
}

/// Format the static portion of the status bar.
/// Layout: model │ tokens/limit (N%) │ perm │ H:MM:SS
fn formatStatic(s: *const SessionState, buf: []u8) usize {
    var pos: usize = 0;

    // Model name (truncate at 24 chars)
    const model = s.model_name;
    const model_len = @min(model.len, 24);
    if (pos + model_len < buf.len) {
        @memcpy(buf[pos..][0..model_len], model[0..model_len]);
        pos += model_len;
    }

    const sep = " \xe2\x94\x82 "; // " │ "
    if (pos + sep.len < buf.len) {
        @memcpy(buf[pos..][0..sep.len], sep);
        pos += sep.len;
    }

    // Tokens: "1.2k/128k (1%)"
    pos += formatTokens(buf[pos..], s.stores.total_tokens.get(), s.context_limit);

    if (pos + sep.len < buf.len) {
        @memcpy(buf[pos..][0..sep.len], sep);
        pos += sep.len;
    }

    // Permission level
    const perm_str = switch (s.stores.permission.get()) {
        .all => "all",
        .safe_only => "safe",
        .none => "ask",
    };
    if (pos + perm_str.len < buf.len) {
        @memcpy(buf[pos..][0..perm_str.len], perm_str);
        pos += perm_str.len;
    }

    // Cancel indicator
    if (s.stores.cancelled.get()) {
        const cancel_mark = " \xe2\x8a\x98"; // " ⊘"
        if (pos + cancel_mark.len < buf.len) {
            @memcpy(buf[pos..][0..cancel_mark.len], cancel_mark);
            pos += cancel_mark.len;
        }
    }

    if (pos + sep.len < buf.len) {
        @memcpy(buf[pos..][0..sep.len], sep);
        pos += sep.len;
    }

    // Elapsed time "H:MM:SS"
    pos += formatElapsed(buf[pos..], s.start_time);

    // Trailing space
    if (pos < buf.len) {
        buf[pos] = ' ';
        pos += 1;
    }

    return pos;
}

// ── Formatting helpers ───────────────────────────────────────────────

/// Format token count with K suffix: 0 → "0", 1234 → "1.2k", 128000 → "128k".
fn formatK(buf: []u8, value: u64) usize {
    if (value == 0) {
        buf[0] = '0';
        return 1;
    }
    if (value < 1000) {
        return (std.fmt.bufPrint(buf, "{d}", .{value}) catch return 0).len;
    }
    if (value < 10000) {
        const whole = value / 1000;
        const frac = (value % 1000) / 100;
        return (std.fmt.bufPrint(buf, "{d}.{d}k", .{ whole, frac }) catch return 0).len;
    }
    return (std.fmt.bufPrint(buf, "{d}k", .{value / 1000}) catch return 0).len;
}

/// Format "used/limit (N%)" token display.
fn formatTokens(buf: []u8, used: u64, limit: u32) usize {
    var pos: usize = 0;
    pos += formatK(buf[pos..], used);
    buf[pos] = '/';
    pos += 1;
    pos += formatK(buf[pos..], @as(u64, limit));

    const pct: u64 = if (limit > 0) (used * 100) / @as(u64, limit) else 0;
    const pct_str = std.fmt.bufPrint(buf[pos..], " ({d}%)", .{pct}) catch return pos;
    pos += pct_str.len;
    return pos;
}

/// Format elapsed time as "H:MM:SS" from a start timestamp.
fn formatElapsed(buf: []u8, start_time: i64) usize {
    const now = std.time.timestamp();
    const elapsed: u64 = if (now > start_time) @intCast(now - start_time) else 0;
    const hours = elapsed / 3600;
    const mins = (elapsed % 3600) / 60;
    const secs = elapsed % 60;
    const result = std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ hours, mins, secs }) catch return 0;
    return result.len;
}

// ── Tests ────────────────────────────────────────────────────────────

test "tokensReceived accumulates into prompt and completion stores" {
    const allocator = std.testing.allocator;
    var session = init(allocator, "test-model", 128000, 24, 80);
    bind(&session);
    defer session.deinit();

    session.events.tokens_received.emit(.{ .prompt_tokens = 100, .completion_tokens = 50 });
    try std.testing.expectEqual(@as(u64, 100), session.stores.prompt_tokens.get());
    try std.testing.expectEqual(@as(u64, 50), session.stores.completion_tokens.get());
    try std.testing.expectEqual(@as(u64, 150), session.stores.total_tokens.get());

    session.events.tokens_received.emit(.{ .prompt_tokens = 200, .completion_tokens = 30 });
    try std.testing.expectEqual(@as(u64, 300), session.stores.prompt_tokens.get());
    try std.testing.expectEqual(@as(u64, 80), session.stores.completion_tokens.get());
    try std.testing.expectEqual(@as(u64, 380), session.stores.total_tokens.get());
}

test "permissionGranted updates permission store" {
    const allocator = std.testing.allocator;
    var session = init(allocator, "test-model", 128000, 24, 80);
    bind(&session);
    defer session.deinit();

    try std.testing.expectEqual(tools.PermissionLevel.none, session.stores.permission.get());

    session.events.permission_granted.emit(.all);
    try std.testing.expectEqual(tools.PermissionLevel.all, session.stores.permission.get());

    session.events.permission_granted.emit(.safe_only);
    try std.testing.expectEqual(tools.PermissionLevel.safe_only, session.stores.permission.get());
}

test "terminalResized updates rows and cols stores" {
    const allocator = std.testing.allocator;
    var session = init(allocator, "test-model", 128000, 24, 80);
    bind(&session);
    defer session.deinit();

    try std.testing.expectEqual(@as(u16, 24), session.stores.term_rows.get());
    try std.testing.expectEqual(@as(u16, 80), session.stores.term_cols.get());

    session.events.terminal_resized.emit(.{ .rows = 40, .cols = 120 });
    try std.testing.expectEqual(@as(u16, 40), session.stores.term_rows.get());
    try std.testing.expectEqual(@as(u16, 120), session.stores.term_cols.get());
}

test "formatK: formats token counts with K suffix" {
    var buf: [32]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 1), formatK(&buf, 0));
    try std.testing.expectEqualStrings("0", buf[0..1]);

    const len2 = formatK(&buf, 500);
    try std.testing.expectEqualStrings("500", buf[0..len2]);

    const len3 = formatK(&buf, 1234);
    try std.testing.expectEqualStrings("1.2k", buf[0..len3]);

    const len4 = formatK(&buf, 128000);
    try std.testing.expectEqualStrings("128k", buf[0..len4]);
}

test "formatTokens: formats used/limit with percentage" {
    var buf: [64]u8 = undefined;
    const len = formatTokens(&buf, 1500, 128000);
    try std.testing.expectEqualStrings("1.5k/128k (1%)", buf[0..len]);
}

test "formatTokens: zero usage" {
    var buf: [64]u8 = undefined;
    const len = formatTokens(&buf, 0, 128000);
    try std.testing.expectEqualStrings("0/128k (0%)", buf[0..len]);
}
