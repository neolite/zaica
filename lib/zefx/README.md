# zefx

Reactive state management for Zig, inspired by [Effector](https://effector.dev).

**Event → Store → sample → Effect** — declarative data flow graphs with comptime type safety.

## Why

Zig projects — game engines, TUI tools, embedded firmware, HTTP servers — end up with the same problem: state scattered across structs, manual callback wiring, flags that track "did X happen yet". zefx replaces that with a declarative graph where you describe **what depends on what**, and the engine handles the rest.

- Zero heap allocs at runtime (arena per tick, freed automatically)
- Comptime type-checked wiring — wrong payload type = compile error, not runtime crash
- Two-phase flush (pure reducers → effects) — watchers always see consistent state
- No event loop dependency — works in game loops, TUI poll loops, embedded `while(true)`, or with external I/O (libxev, epoll)

## Install

```sh
zig fetch --save https://github.com/neolite/zefx/archive/refs/tags/v0.1.0.tar.gz
```

Then in your `build.zig`:

```zig
const zefx_dep = b.dependency("zefx", .{});
exe.root_module.addImport("zefx", zefx_dep.module("zefx"));
```

## Quick start

```zig
const std = @import("std");
const zefx = @import("zefx");

pub fn main() !void {
    var rt: zefx.Runtime = undefined;
    rt.init();
    defer rt.deinit();
    const fx = rt.fx();

    const inc = fx.createEvent(i32);
    const count = fx.createStore(i32, 0);

    _ = count.on(inc, &struct { fn r(s: i32, p: i32) ?i32 { return s + p; } }.r);

    _ = count.subscribe(&struct {
        fn w(v: i32) void {
            std.debug.print("count = {d}\n", .{v});
        }
    }.w);

    inc.emit(5); // count = 5
    inc.emit(3); // count = 8
}
```

## Examples

### Game HUD — raylib-zig

Managing HUD state in a game loop. Instead of `if (health != prev_health) redraw()` scattered everywhere, declare the graph once:

```zig
const zefx = @import("zefx");
const rl = @import("raylib");

// ── graph ──────────────────────────────────────
var rt: zefx.Runtime = undefined;
rt.init();
defer rt.deinit();
const fx = rt.fx();

const damageTaken = fx.createEvent(i32);
const healReceived = fx.createEvent(i32);

const $hp = fx.createStore(i32, 100);
_ = $hp.on(damageTaken, &struct {
    fn r(hp: i32, dmg: i32) ?i32 { return @max(0, hp - dmg); }
}.r);
_ = $hp.on(healReceived, &struct {
    fn r(hp: i32, heal: i32) ?i32 { return @min(100, hp + heal); }
}.r);

const $alive = fx.createStore(bool, true);
_ = fx.sample(.{
    .clock  = damageTaken,
    .source = $hp,
    .fn_    = &struct { fn f(hp: i32) bool { return hp > 0; } }.f,
    .target = $alive,
});

// only fires when hp drops below 20
const lowHpWarning = fx.createEvent(i32);
_ = fx.guard(.{
    .clock  = damageTaken,
    .source = $hp,
    .filter = &struct { fn f(hp: i32) bool { return hp > 0 and hp < 20; } }.f,
    .target = lowHpWarning,
});

// ── game loop ──────────────────────────────────
while (!rl.windowShouldClose()) {
    if (rl.isKeyPressed(.key_space)) damageTaken.emit(15);
    if (rl.isKeyPressed(.key_h)) healReceived.emit(10);

    rl.beginDrawing();
    // $hp.get(), $alive.get() — always consistent, no stale state
    drawHealthBar($hp.get(), $alive.get());
    rl.endDrawing();
}
```

No manual dirty flags. The graph guarantees `$alive` and `$hp` are consistent after every emit.

### TUI file browser — libvaxis

Managing filter/sort state in a terminal UI. Instead of re-sorting in the render loop, the graph updates `$visible` only when inputs change:

```zig
const zefx = @import("zefx");
const vaxis = @import("vaxis");

var rt: zefx.Runtime = undefined;
rt.init();
defer rt.deinit();
const fx = rt.fx();

const Entry = struct { name: [256]u8 = undefined, name_len: u8 = 0, size: u64 = 0, is_dir: bool = false };
const Entries = struct { items: [512]Entry = undefined, len: usize = 0 };

const queryChanged = fx.createEvent([256]u8);
const sortToggled = fx.createEvent(void);
const dirOpened = fx.createEvent([256]u8);

const $query = fx.restore(queryChanged, [_]u8{0} ** 256);
const $sort_by_size = fx.createStore(bool, false);
_ = $sort_by_size.on(sortToggled, &struct {
    fn r(s: bool, _: void) ?bool { return !s; }
}.r);

const $entries = fx.createStore(Entries, .{});
const $visible = fx.createStore(Entries, .{});

// When query or entries change → recompute visible list
_ = fx.sample(.{
    .source = .{ .entries = $entries, .query = $query },
    .fn_ = &struct {
        fn filter(snap: zefx.shape.SnapshotTypeOf(
            struct { entries: *zefx.Store(Entries), query: *zefx.Store([256]u8) }
        )) Entries {
            var result: Entries = .{};
            for (snap.entries.items[0..snap.entries.len]) |entry| {
                if (matchesQuery(entry, snap.query)) {
                    result.items[result.len] = entry;
                    result.len += 1;
                }
            }
            return result;
        }
    }.filter,
    .target = $visible,
});

// readdir effect
const FsErr = error{AccessDenied};
const readdirFx = fx.createEffect([256]u8, Entries, FsErr, &readDirectory);
_ = $entries.on(readdirFx.done, &struct {
    fn r(_: Entries, d: zefx.Effect([256]u8, Entries, FsErr).DoneData) ?Entries {
        return d.result;
    }
}.r);

// dirOpened → trigger readdir
_ = fx.forward(dirOpened, readdirFx); // assumes matching types

// ── vaxis event loop ───────────────────────────
while (true) {
    const event = tty.nextEvent();
    switch (event) {
        .key_press => |key| switch (key) {
            '/' => queryChanged.emit(input_buf),
            's' => sortToggled.emit({}),
            '\r' => dirOpened.emit(selected_path),
            'q' => break,
            else => {},
        },
        else => {},
    }
    renderFileList($visible.get()); // always filtered + sorted
}
```

### HTTP server metrics — httpz (http.zig)

Track request metrics without polluting handler logic. The graph accumulates stats; handlers just emit facts:

```zig
const zefx = @import("zefx");
const httpz = @import("httpz");

var rt: zefx.Runtime = undefined;
rt.init();
defer rt.deinit();
const fx = rt.fx();

const ReqInfo = struct { method: u8, path_len: u16, status: u16, latency_us: u64 };

const requestCompleted = fx.createEvent(ReqInfo);

const $total_requests = fx.createStore(u64, 0);
_ = $total_requests.on(requestCompleted, &struct {
    fn r(n: u64, _: ReqInfo) ?u64 { return n + 1; }
}.r);

const $error_count = fx.createStore(u64, 0);
_ = fx.sample(.{
    .clock = requestCompleted,
    .source = $error_count,
    .fn_ = &struct {
        // sample fn receives (source_value, clock_payload) when both provided
        fn f(count: u64) u64 { return count; }
    }.f,
    .target = $error_count,
});
// simpler: count errors via guard + store
const errorOccurred = fx.createEvent(ReqInfo);
_ = fx.guard(.{
    .clock  = requestCompleted,
    .filter = &struct { fn f(r: ReqInfo) bool { return r.status >= 500; } }.f,
    .target = errorOccurred,
});
_ = $error_count.on(errorOccurred, &struct {
    fn r(n: u64, _: ReqInfo) ?u64 { return n + 1; }
}.r);

// Log slow requests (>100ms) as a side effect
const slowRequest = fx.createEvent(ReqInfo);
_ = fx.guard(.{
    .clock  = requestCompleted,
    .filter = &struct { fn f(r: ReqInfo) bool { return r.latency_us > 100_000; } }.f,
    .target = slowRequest,
});
_ = slowRequest.watch(&logSlowRequest);

// ── in your httpz handler ──────────────────────
fn handleRequest(req: *httpz.Request, res: *httpz.Response) void {
    const start = std.time.microTimestamp();
    // ... handle ...
    res.status = 200;
    requestCompleted.emit(.{
        .method = req.method,
        .path_len = @intCast(req.path.len),
        .status = res.status,
        .latency_us = @intCast(std.time.microTimestamp() - start),
    });
}

// GET /metrics
fn handleMetrics(_: *httpz.Request, res: *httpz.Response) void {
    res.json(.{
        .total = $total_requests.get(),
        .errors = $error_count.get(),
    });
}
```

### Sensor pipeline — MicroZig / embedded

Embedded sensor → threshold → actuator. Replace hand-rolled state machines with a declarative graph:

```zig
const zefx = @import("zefx");

var rt: zefx.Runtime = undefined;
rt.init();
defer rt.deinit();
const fx = rt.fx();

const SensorReading = struct { temp_c: i16, humidity: u8 };

const sensorTick = fx.createEvent(SensorReading);

const $temperature = fx.createStore(i16, 0);
_ = $temperature.on(sensorTick, &struct {
    fn r(_: i16, s: SensorReading) ?i16 { return s.temp_c; }
}.r);

const $humidity = fx.createStore(u8, 0);
_ = $humidity.on(sensorTick, &struct {
    fn r(_: u8, s: SensorReading) ?u8 { return s.humidity; }
}.r);

// Overheat alarm — only fires when crossing threshold
const overheatDetected = fx.createEvent(i16);
_ = fx.guard(.{
    .clock  = sensorTick,
    .source = $temperature,
    .filter = &struct { fn f(t: i16) bool { return t > 80; } }.f,
    .target = overheatDetected,
});

// Fan control: on when temp > 60, off when <= 60
const $fan_on = fx.createStore(bool, false);
_ = fx.sample(.{
    .clock  = sensorTick,
    .source = $temperature,
    .fn_    = &struct { fn f(t: i16) bool { return t > 60; } }.f,
    .target = $fan_on,
});

// Wire to hardware via watchers
_ = $fan_on.watch(&setFanGpio);
_ = overheatDetected.watch(&triggerBuzzer);

// ── main loop (bare metal / RTOS) ─────────────
while (true) {
    const reading = readSensorI2C();
    sensorTick.emit(reading);
    // fan GPIO and buzzer are updated automatically by the graph
    busyWait(100_000); // 100ms
}
```

No `if (temp > 80 and !alarm_active)` scattered across the codebase. The graph handles all derived state.

### Event loop integration — libxev

zefx is synchronous — it doesn't own an event loop. When using libxev (or epoll/kqueue directly), the pattern is: I/O completes → emit event → graph reacts:

```zig
const zefx = @import("zefx");
const xev = @import("xev");

var rt: zefx.Runtime = undefined;
rt.init();
defer rt.deinit();
const fx = rt.fx();

const ConnEvent = struct { fd: i32, bytes: usize };

const dataReceived = fx.createEvent(ConnEvent);
const connectionClosed = fx.createEvent(i32);

const $active_conns = fx.createStore(u32, 0);
_ = $active_conns.on(dataReceived, &struct {
    fn r(n: u32, _: ConnEvent) ?u32 { return n; } // no-op, just tracking
}.r);
_ = $active_conns.on(connectionClosed, &struct {
    fn r(n: u32, _: i32) ?u32 { return if (n > 0) n - 1 else 0; }
}.r);

const $bytes_total = fx.createStore(u64, 0);
_ = $bytes_total.on(dataReceived, &struct {
    fn r(total: u64, ev: ConnEvent) ?u64 { return total + ev.bytes; }
}.r);

// ── libxev callback ────────────────────────────
fn onRead(userdata: ?*anyopaque, result: xev.ReadError!usize) void {
    _ = userdata;
    const n = result catch {
        connectionClosed.emit(fd);
        return;
    };
    dataReceived.emit(.{ .fd = fd, .bytes = n });
    // $bytes_total, $active_conns updated synchronously — no race conditions
}

// Run libxev event loop
var loop = try xev.Loop.init(.{});
defer loop.deinit();
loop.run();
```

zefx runs inside the callback — fully synchronous, no thread safety issues, no async/await.

## API

### Core primitives

| Primitive | Description |
|-----------|-------------|
| `Runtime` | Owns allocator + domain lifecycle. `rt.init()` / `rt.deinit()` |
| `Event(T)` | Signal carrying payload `T`. `.emit(value)` triggers the graph |
| `Store(T)` | Holds state `T`. `.on(event, reducer)` or `.set(value)` |
| `Effect(P,R,E)` | Wraps `fn(P) E!R`. Derived: `.done`, `.fail`, `.finally_`, `.pending` |

### Operators

| Operator | Description |
|----------|-------------|
| `sample(.{clock, source, fn_, target})` | When clock fires → snapshot source → transform → push to target |
| `guard(.{clock, source, filter, target})` | Like sample, but only passes when filter returns `true` |
| `forward(from, to)` | Pipe one unit to another (sugar over sample) |
| `restore(event, initial)` | Create a store that holds the last value from an event |

### createEffect

```zig
const FxErr = error{Timeout};
const fetchFx = fx.createEffect(Request, Response, FxErr, &handler);

fetchFx.run(params);         // schedule handler in effects phase
fetchFx.done                 // *Event(DoneData) — emitted on success
fetchFx.fail                 // *Event(FailData) — emitted on error
fetchFx.finally_             // *Event(FinallyData) — emitted always
fetchFx.pending              // *Store(bool) — true while running
```

### Factory constructors

All units are heap-allocated and auto-freed on `rt.deinit()`:

```zig
const ev = fx.createEvent(i32);
const st = fx.createStore(i32, 0);
const ef = fx.createEffect(i32, i32, error{Fail}, &handler);
```

## Execution model

1. `event.emit(payload)` schedules reducer thunks (pure) and watcher thunks (effects)
2. Engine flushes in two phases:
   - **Phase 1 (pure)**: reducers run, stores update, derived samples fire
   - **Phase 2 (effects)**: watchers run, effects execute — may emit new events
3. If effects emit events, the loop repeats until stable
4. If no flush is in progress, `emit` auto-flushes immediately

Watchers always see the final consistent state of the current tick.

## Run the demo

```sh
git clone https://github.com/neolite/zefx.git
cd zefx
zig build run
```

## License

MIT
