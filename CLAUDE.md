# Project guide

**IRON LEDGER** — BattleTech mercenary-company management sim in Zig 0.16.
No external deps (SQLite via the system library; music via the system
command-line player as a child process).
Read ARCHITECTURE.md before changing sim behavior; ROADMAP.md defines stage
order — implement stages in order unless told otherwise.

## Commands

- `zig build test --summary all` — run all tests (must stay green)
- `zig build -Ddata=<dir>` — build with a mod directory overlaying any
  `data/*.zon` / `data/tables/*.zon` file (docs/modding.md)
- `zig build -Doptimize=ReleaseFast [-Dbundle-music] --prefix dist` — a
  shippable tree (`dist/bin/game` + `dist/share/iron-ledger/{music,logos}`);
  the loose runtime files are found through `src/tui/paths.zig`, never the
  working directory
- `zig build run` — demo CLI; `zig build run -- --repl` command console;
  `zig build run -- --tui [--store path] [--ascii] [--no-splash] [--no-music]`
  terminal client (Stage 12); `docs/tui_smoke.py zig-out/bin/game /tmp/x.db`
  drives it through a pty; `docs/repl_smoke.sh zig-out/bin/game /tmp/r.db`
  scripts the REPL
- TUI code lives in `src/tui/` (outside the pure `game` module); it may
  only call `game.commands.execute`, parse through `game.cli`, and read
  through `game.queries`. Command verbs are parsed once, in `src/sim/cli.zig`,
  for both the REPL and the TUI `:` line.

## Hard rules (from ARCHITECTURE.md)

- Sim core (`src/domain`, `src/sim`, `src/econ`, `src/gen`) is pure and
  deterministic: no I/O, no wall clock, no global mutable state.
- All money is integer C-bills (`types.CBills`); multipliers in basis points
  via `types.applyBp`. Never floats in financial or rules math.
- All randomness goes through `sim/rng.zig` named streams — never create a
  PRNG elsewhere; pick the stream matching the subsystem.
- Typed IDs (`types.PersonId` etc.) — never raw u32s across module borders.
- Timestamps are `day_index: u32` (days since campaign start); calendar
  rendering only at the edges.
- Skill convention follows MekHQ: lower level = better (gunnery 3 beats 4).
- Every new module: doc comment naming its MekHQ counterpart (if any, see
  docs/mekhq-map.md) + unit tests in-file.
- Static game data belongs in `data/*.zon`, not hardcoded — cite the
  sourcebook (CamOps chapter etc.) in a comment next to rule tables.
- Capacity/influence/penalty constants (hq.zig, logistics.zig, market.zig)
  are placeholder tuning values: mark them `// TUNE` and migrate them to
  `data/tables/*.zon` during Stages 4/9. GAMEPLAY.md describes the intended
  feel; keep formulas legible over clever.
