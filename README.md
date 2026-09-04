# BattleTech Mercenary Command (working title)

A mercenary *organization* simulator in the BattleTech universe, written in
Zig. You are the commander of the whole outfit: build companies, win contracts,
and shape battle outcomes through logistics, HR, maintenance, training, and an
HQ network — never by piloting a mek. Battles resolve automatically and hand
you an after-action report.

Heavily inspired by [MekHQ](https://github.com/MegaMek/mekhq), minus the
tabletop; extended with multi-company operations and a simulated supply chain.

- **[ARCHITECTURE.md](ARCHITECTURE.md)** — design pillars, domain model,
  simulation loop, battle autoresolution, logistics network.
- **[ROADMAP.md](ROADMAP.md)** — the staged build plan (currently: Stage 0 done).
- **[docs/schema.sql](docs/schema.sql)** — SQLite save-file schema (Stage 11).
- **[docs/mekhq-map.md](docs/mekhq-map.md)** — MekHQ feature/class → module map.

## Build & run

Requires Zig 0.16.

```sh
zig build test   # unit tests
zig build run    # scaffold demo
```

## Status

Stage 0 (scaffolding): module skeleton with working primitives — money/date/
RNG streams, CamOps salary math, contract payment math, quality grades, the
autoresolve power model — each with tests.
