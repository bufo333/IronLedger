# Project guide

BattleTech mercenary-company management sim in Zig 0.16. No external deps yet.
Read ARCHITECTURE.md before changing sim behavior; ROADMAP.md defines stage
order — implement stages in order unless told otherwise.

## Commands

- `zig build test --summary all` — run all tests (must stay green)
- `zig build run` — demo CLI; `zig build run -- --repl` command console;
  `zig build run -- --tui [--store path]` terminal client (Stage 12)
- TUI code lives in `src/tui/` (outside the pure `game` module); it may
  only call `game.commands.execute` and read through `game.queries`.

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
