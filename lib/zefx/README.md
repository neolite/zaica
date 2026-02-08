# zefx

Reactive state management for Zig, inspired by [Effector](https://effector.dev).

**Event → Store → sample → Effect** — declarative data flow graphs with comptime type safety.

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

## JS-like facade

Use `Runtime` for the shortest setup and an Effector-style API:

```zig
const std = @import("std");
const zefx = @import("zefx");

var rt: zefx.Runtime = undefined;
rt.init();
defer rt.deinit();
const fx = rt.fx();

const inc = fx.createEvent(i32);
const dec = fx.createEvent(i32);

const count = fx.createStore(i32, 0);
_ = count.on(inc, &struct { fn plus(s: i32, x: i32) ?i32 { return s + x; } }.plus);
_ = count.on(dec, &struct { fn minus(s: i32, x: i32) ?i32 { return s - x; } }.minus);

const doubled = fx.createStore(i32, 0);
_ = fx.sample(.{
    .clock = inc,
    .source = count,
    .fn_ = &struct { fn f(v: i32) i32 { return v * 2; } }.f,
    .target = doubled,
});

const bigOnly = fx.createStore(i32, 0);
_ = fx.guard(.{
    .clock = inc,
    .source = count,
    .filter = &struct { fn f(v: i32) bool { return v >= 10; } }.f,
    .target = bigOnly,
});

const lastInc = fx.restore(inc, 0);

const sub = count.subscribe(&struct {
    fn w(v: i32) void {
        std.debug.print("$count = {d}\n", .{v});
    }
}.w);

inc.emit(5); // count=5, doubled=10, guard blocked
inc.emit(6); // count=11, doubled=22, guard passed (11)
dec.emit(3); // count=8

count.unsubscribe(sub);
std.debug.print("doubled={d}, bigOnly={d}, lastInc={d}\n", .{
    doubled.getState(), bigOnly.getState(), lastInc.getState(),
});
```

Store and event aliases available:
- `store.getState()` / `store.setState(v)`
- `store.subscribe(cb)` / `store.unsubscribe(sub)`
- `event.subscribe(cb)` / `event.unsubscribe(sub)`

`Runtime` already gives a bound facade (`fx`) so you do not pass `&domain` around:

```zig
var rt: zefx.Runtime = undefined;
rt.init();
defer rt.deinit();

const fx = rt.fx();
const inc = fx.createEvent(i32);
const count = fx.createStore(i32, 0);
_ = count.on(inc, &struct { fn r(s: i32, x: i32) ?i32 { return s + x; } }.r);
```

Counter example with runtime:

```zig
var rt: zefx.Runtime = undefined;
rt.init();
defer rt.deinit();
const fx = rt.fx();

const inc = fx.createEvent(i32);
const dec = fx.createEvent(i32);
const count = fx.createStore(i32, 0);
_ = count.on(inc, &struct { fn r(s: i32, p: i32) ?i32 { return s + p; } }.r);
_ = count.on(dec, &struct { fn r(s: i32, p: i32) ?i32 { return s - p; } }.r);

inc.emit(10);
dec.emit(3);
// count.getState() == 7
```

## Effector-style todo model example

```zig
const std = @import("std");
const zefx = @import("zefx");

const Todo = struct { id: u32, done: bool };
const Todos = struct {
    items: [64]Todo = undefined,
    len: usize = 0,
};

var rt: zefx.Runtime = undefined;
rt.init();
defer rt.deinit();
const fx = rt.fx();

const addTodo = fx.createEvent(u32);
const toggleTodo = fx.createEvent(u32);
const removeTodo = fx.createEvent(u32);

const $todos = fx.createStore(Todos, .{});
const $total = fx.createStore(usize, 0);
const $completed = fx.createStore(usize, 0);

_ = $todos.on(addTodo, &struct {
    fn r(state: Todos, id: u32) ?Todos {
        if (state.len >= state.items.len) return state;
        var next = state;
        next.items[next.len] = .{ .id = id, .done = false };
        next.len += 1;
        return next;
    }
}.r);
_ = $todos.on(toggleTodo, &struct {
    fn r(state: Todos, id: u32) ?Todos {
        var next = state;
        var i: usize = 0;
        while (i < next.len) : (i += 1) {
            if (next.items[i].id == id) {
                next.items[i].done = !next.items[i].done;
                break;
            }
        }
        return next;
    }
}.r);
_ = $todos.on(removeTodo, &struct {
    fn r(state: Todos, id: u32) ?Todos {
        var next = state;
        var i: usize = 0;
        while (i < next.len) : (i += 1) {
            if (next.items[i].id == id) {
                var j = i;
                while (j + 1 < next.len) : (j += 1) {
                    next.items[j] = next.items[j + 1];
                }
                next.len -= 1;
                break;
            }
        }
        return next;
    }
}.r);

_ = fx.sample(.{
    .source = $todos,
    .fn_ = &struct { fn f(s: Todos) usize { return s.len; } }.f,
    .target = $total,
});
_ = fx.sample(.{
    .source = $todos,
    .fn_ = &struct {
        fn f(s: Todos) usize {
            var done: usize = 0;
            var i: usize = 0;
            while (i < s.len) : (i += 1) if (s.items[i].done) done += 1;
            return done;
        }
    }.f,
    .target = $completed,
});

addTodo.emit(1);
addTodo.emit(2);
toggleTodo.emit(1);
removeTodo.emit(2);

std.debug.print("total={d}, completed={d}\n", .{
    $total.getState(), $completed.getState(),
});
```

## API

### Core primitives

| Primitive | Description |
|-----------|-------------|
| `Runtime` | Owns allocator + domain lifecycle. Use `rt.init()` / `rt.deinit()` |
| `Engine` | Owns the reactive graph. Two-phase flush: pure reducers → effect watchers |
| `Event(T)` | A signal carrying payload `T`. Emit to trigger the graph |
| `Store(T)` | Holds state `T`. Updated by `.on(event, reducer)` or `.set(value)` |

### Operators

#### `sample` — connect clock, source, transform, target

When `clock` fires, snapshot `source`, apply `fn_`, push result to `target`.

```zig
// setup once
var rt: zefx.Runtime = undefined;
rt.init();
defer rt.deinit();
const fx = rt.fx();

const clicked = fx.createEvent(i32);
const count = fx.createStore(i32, 0);
const doubled_ev = fx.createEvent(i32);

// clock fires -> read count -> double it -> push to doubled_ev
_ = fx.sample(.{
    .clock  = clicked,
    .source = count,
    .fn_    = &struct {
        fn f(src: i32) i32 { return src * 2; }
    }.f,
    .target = doubled_ev,
});
```

Target can be an `Event` or a `Store`. If omitted, `sample` auto-creates and returns a new `*Event(R)`:

```zig
const squared = fx.sample(.{
    .clock  = clicked,
    .source = count,
    .fn_    = &struct {
        fn f(src: i32) i32 { return src * src; }
    }.f,
});
_ = squared.watch(&struct {
    fn log(v: i32) void { _ = v; }
}.log);
```

#### `guard` — conditional pass-through

Like `sample`, but with a `filter` instead of `fn_`. Only passes values where filter returns `true`:

```zig
const big_values_ev = fx.createEvent(i32);
_ = fx.guard(.{
    .clock  = clicked,
    .source = count,
    .filter = &struct {
        fn f(v: i32) bool { return v > 5; }
    }.f,
    .target = big_values_ev,
});
```

#### `sample` with shape source

Combine multiple stores into a single snapshot:

```zig
const other = fx.createStore(i32, 10);
const sum_ev = fx.createEvent(i32);
_ = fx.sample(.{
    .clock  = clicked,
    .source = .{ .a = count, .b = other },
    .fn_    = &struct {
        fn f(snap: zefx.shape.SnapshotTypeOf(
            struct { a: *zefx.Store(i32), b: *zefx.Store(i32) }
        )) i32 {
            return snap.a + snap.b;
        }
    }.f,
    .target = sum_ev,
});
```

#### `forward` — pipe one unit to another

```zig
const source_event = fx.createEvent(i32);
const target_event = fx.createEvent(i32);
_ = fx.forward(source_event, target_event);
```

#### `restore` — create a store from an event

```zig
const $last = fx.restore(clicked, 0);
// $last always holds the most recent value emitted by `clicked`
```

### Factory constructors

Runtime/domain-managed allocation (auto-freed on `rt.deinit()`):

```zig
const ev = fx.createEvent(i32);
const st = fx.createStore(i32, 0);
```

## Execution model

1. `event.emit(payload)` schedules reducer thunks (pure) and watcher thunks (effects)
2. Engine flushes in two phases:
   - **Phase 1**: all pure reducers run, stores update, derived samples fire
   - **Phase 2**: all effect watchers run
3. If no flush is in progress, `emit` auto-flushes immediately

This guarantees consistent state snapshots — watchers always see the final state of the current tick.

## Run the demo

```sh
git clone https://github.com/neolite/zefx.git
cd zefx
zig build run
```

## License

MIT
