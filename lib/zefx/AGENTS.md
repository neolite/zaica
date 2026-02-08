# Repository Guidelines

## Project Structure & Module Organization
`zefx` is a Zig library with a small demo executable.

- `src/root.zig`: public API surface exported as module `zefx`.
- `src/engine.zig`, `src/event.zig`, `src/store.zig`, `src/sample.zig`, `src/shape.zig`: core reactive graph primitives and operators.
- `src/main.zig`: runnable demo wired by the build system.
- `build.zig`: build graph, run step, and test step definitions.
- `build.zig.zon`: package metadata (`minimum_zig_version = 0.15.2`).
- Generated artifacts: `.zig-cache/` and `zig-out/` (do not edit manually).

## Build, Test, and Development Commands
- `zig build`: compile and install the demo artifact.
- `zig build run`: run the demo in `src/main.zig`.
- `zig build test`: run module + executable test targets (currently mostly compile/behavior checks; add `test` blocks as features grow).
- `zig build -Doptimize=ReleaseFast`: build with release optimization.
- `zig fmt src/*.zig build.zig`: format code before committing.

## Coding Style & Naming Conventions
- Use `zig fmt` as the source of truth (4-space indentation, consistent wrapping).
- Keep filenames lowercase snake-style (`engine.zig`, `sample.zig`).
- Use `PascalCase` for types (`Engine`, `Event`, `Store`) and `camelCase` for functions (`createEvent`, `createStore`, `trackGraphAlloc`).
- Keep public API in `src/root.zig`; keep implementation details in focused modules.
- Prefer explicit, typed helpers over broad `anytype` unless API flexibility requires it.

## Testing Guidelines
- Use Zig built-in tests with `test "..." { ... }` blocks, colocated in the relevant module file.
- Test names should describe behavior, e.g. `test "sample updates target store on clock"`.
- Run `zig build test` locally before opening a PR.
- Cover reducer ordering, watcher phase behavior, and edge cases in `sample`/`guard` flows.

## Commit & Pull Request Guidelines
- Follow concise, imperative commit subjects, as seen in history:
  - `Add README with API docs and usage examples`
  - `Initial release: zefx v0.1.0`
- Keep subject lines focused; add a body when changing API or execution semantics.
- PRs should include: problem statement, design/behavior summary, test evidence (`zig build test` output), and updated docs/examples when public API changes.
