# Codebase Audit

Date: 2026-09-23

Scope: structural, architectural, correctness, and best-practices review of the IRON LEDGER codebase. The review was conducted read-only: no source files were modified, no Git commands were issued, and tests were not run because other work was in progress.

## Critical Findings

### 1. Black-market fraud can move an unrelated hull

- `src/sim/commands.zig:861-870` returns success after fraud without creating a unit.
- `src/sim/commands.zig:1039-1053` assumes the purchased unit is always `next_unit_id - 1`.
- A fraudulent `buy_hull_for` can therefore move the previously created unit into the destination company.
- Return the created `UnitId` explicitly from the purchase operation, with a distinct fraud result.

### 2. Refits can duplicate parts

- `src/sim/commands.zig:1684-1691` validates each install against the same initial stock count and ignores `takeStock` failure.
- Two identical installs with one part in stock pass validation; both are subsequently installed.
- Aggregate demand by part before consuming inventory and make consumption failure fatal.

### 3. Battle report IDs are reused after loading

- `next_battle_id` is defined in `src/sim/state.zig:253` but is absent from the persisted counters in `src/persist/store.zig:346-363`.
- Existing reports are loaded at `src/persist/store.zig:1395-1503` without reconstructing the counter.
- New reports can collide with old IDs after save/load.
- Persist the counter and backfill older saves using `max(report.id) + 1`.

### 4. A failed first save corrupts the in-memory save identity

- `src/persist/store.zig:328-336` assigns `gs.campaign_id` before the transaction commits.
- A later failure rolls back SQLite but leaves the state pointing to a nonexistent campaign.
- Keep the inserted ID local and assign it only after successful commit.

### 5. Loading an unknown campaign returns a blank campaign

- `src/persist/store.zig:820-831` treats a missing registry row as a current-version campaign.
- The rest of the loader then constructs an effectively empty state.
- Require the campaign row and return a typed `NoSuchCampaign` error when absent.

## High Severity

### 6. Commands are not transactionally atomic

Representative cases:

- HQ founding: `src/sim/commands.zig:459-474`
- Facility upgrades: `src/sim/commands.zig:1365-1387`
- Fabrication: `src/sim/commands.zig:1346-1363`
- Unit transfers: `src/sim/commands.zig:1638-1655`
- Refit commitment: `src/sim/commands.zig:1684-1705`
- Event resolution: `src/sim/contract_events.zig:332-348`

Funds, inventory, offers, or assignments can be changed before a fallible append or allocation. This violates the contract that failed commands leave state consistent.

Adopt validate, preallocate, then commit; add failing-allocator tests.

### 7. Medical rules ignore physical location

- `src/sim/medical.zig:94-113` counts doctors, patients, and the best hospital across the entire outfit.
- `src/sim/medical.zig:138-141` gives every home patient the best hospital's capacity.
- `src/sim/medical.zig:213-215` treats every deployed patient as having MASH coverage.
- Facilities and personnel on another planet can therefore improve remote care.
- Compute medical capacity by concrete HQ/company site.

### 8. Equal-priority field patients can all be denied beds

- `src/sim/medical.zig:181-188` counts every peer with equal or higher priority for each patient.
- With five equal-priority patients and four beds, all five are delayed.
- Allocate beds in one ordered pass with a used-bed count per site.

### 9. Unit-type combat skills are ignored

- `src/sim/battle.zig:209-210` always uses `gunnery_mek` and `piloting_mek`.
- Vehicle and aerospace crews therefore fight using default MekWarrior ratings instead of their actual skills.
- Centralize combat-skill selection by unit kind.

### 10. Unavailable support assets still grant modifiers

- `src/sim/battle.zig:257-285` grants recon, MASH, mess, security, salvage, and transport benefits largely from nonempty lances.
- `src/sim/medical.zig:120-127` excludes only destroyed MASH units.
- Mothballed, uncrewed, repairing, or in-transit assets may still contribute.
- Introduce one readiness predicate used by battle, medical, and salvage systems.

### 11. Conceded engagements do not produce blocking AARs

- `src/sim/battle.zig:730-736` only adjusts score and logs when no units can fight.
- `src/sim/commands.zig:2239-2243` stops multi-day advancement only for unread reports.
- This allows advancement past an engagement that should block under the documented architecture.
- Emit a conceded `BattleReport` and normal engagement bookkeeping.

### 12. Freight throughput is both overprovisioned and consumed on failures

- `src/econ/logistics.zig:112-122` defines weekly capacity.
- `src/sim/network.zig:26-29` multiplies it by four while `src/sim/tick.zig:35` resets it weekly.
- `src/sim/commands.zig:1778-1783` reserves throughput before payment or sourcing succeeds.
- Failed orders can consume capacity, and successful links carry four times their documented amount.
- Separate quote from reservation and align the unit with the reset interval.

### 13. Persistence silently accepts corruption

- Missing or malformed RNG state defaults silently at `src/persist/store.zig:873-879`.
- Numerous database values use unchecked `@intCast`, beginning around `src/persist/store.zig:830-862`.
- Missing parent rows and invalid enum rows are often skipped later in the loader.
- Replace casts with checked readers and reject missing relationships as `CorruptSave`.

### 14. Runtime SQLite schema lacks integrity enforcement

- Runtime DDL begins at `src/persist/store.zig:32`.
- The design schema enables foreign keys at `docs/schema.sql:21`, but the runtime open path in `src/persist/sqlite.zig:42-70` does not.
- Manual table lists and cleanup are vulnerable to omissions.
- Enable foreign keys, cascades, uniqueness, and range constraints through migrations.

### 15. Terminal text is not safely escaped

- `src/tui/screen.zig:147-173` uses unchecked UTF-8 decoding and accepts terminal control characters.
- User names, mod strings, paths, and filenames can reach this renderer.
- Literal markup tokens can also alter styling.
- Sanitize controls and invalid UTF-8 at the renderer boundary and distinguish trusted markup from plain text.

### 16. Terminal and screen initialization have unsafe failure paths

- `src/tui/screen.zig:120-126` frees the current buffer before allocating its replacement, leaving a dangling pointer on allocation failure.
- `src/tui/term.zig:108-135` enters raw mode before fallible output without an `errdefer` restoring terminal state.
- Allocate before replacing the screen buffer and install restoration guards immediately after changing terminal settings.

### 17. The deterministic state hash is incomplete

- `src/sim/state.zig:1881-1985` hashes counts or aggregates for many structures while omitting detailed transactions, jobs, reports, RNG state, inventory distribution, assignments, and counters.
- Save/load tests can pass despite materially different state.
- Replace it with a canonical digest of every gameplay-relevant field and assert fixed known hashes.

### 18. Named RNG streams remain cross-coupled

- Market personnel generation uses generation streams in `src/econ/contract_market.zig:500-509`.
- Battle prisoner and salvage generation cross into generation/market streams in `src/sim/battle.zig:703-718` and `947-966`.
- `src/sim/rng.zig:7-28` also derives streams from enum ordinal, so inserting a stream changes later streams.
- Give each stream a stable explicit salt and pass subsystem-owned streams into helpers.

## Architecture And Structure

### 19. Dependency direction is already inverted

Domain modules import simulation RNG:

- `src/domain/planet.zig:6`
- `src/domain/scenario.zig:9`
- `src/domain/opfor.zig:14`
- `src/domain/rat.zig:8`

Economy and generation import simulation state/rules:

- `src/econ/market.zig:10`
- `src/econ/contract_market.zig:12`
- `src/gen/company_gen.zig:13-14`

This conflicts with the documented downward-only dependency model. Pass narrow random/data inputs downward and keep stateful orchestration in `sim`.

### 20. Central modules have become subsystem aggregators

- `src/sim/queries.zig`: about 5,600 lines.
- `src/sim/commands.zig`: about 4,300 lines; `execute` is over 1,000 lines.
- `src/tui/app.zig`: about 3,300 lines.
- `src/sim/state.zig`: about 2,000 lines.
- `src/persist/store.zig`: about 2,000 lines; `load` exceeds 700 lines.

The size is contributing to unreachable parser branches, cleanup omissions, duplicated calculations, and incomplete persistence. Preserve single facades, but delegate to subsystem command, query, persistence-codec, and UI modules.

### 21. HQ locality is repeatedly bypassed

- Training accepts any qualifying HQ: `src/sim/commands.zig:782-797`, `1445-1464`, `1843-1855`.
- Recovery and recruitment use the first or best HQ: `src/sim/medical.zig:321-332`, `src/sim/state.zig:641-650`.
- Offer intelligence uses global best comms: `src/sim/offer_rating.zig:22-45`.
- These shortcuts undermine the central network/location design.
- Create site-specific rule functions and asymmetric two-HQ tests.

### 22. Query and frontend boundaries have concrete violations

- TUI directly reads unread battle reports at `src/tui/app.zig:2214-2217`.
- `src/sim/queries.zig:1673-1692` recovers facility identity by parsing rendered text.
- Inbox selection reconstructs identity through rendered row counts at `src/tui/app.zig:1825-1840`.
- Several TUI handlers prevalidate command rules instead of executing commands and showing canonical refusals.
- Return typed row identities and next-action information from queries or command results.

### 23. CLI parser has unreachable and permissive branches

- Duplicate `shares` and `autoadmit` handling at `src/sim/cli.zig:148-158` and `392-398`.
- `shares +/-` and bare toggle behavior are unreachable.
- Several closed choices treat unknown tokens as a valid alternative, including `xfer` and office direction around `src/sim/cli.zig:339-367`.
- Use strict enum parsing, reject trailing tokens, and maintain one branch per verb.

## Build, Data, And Tests

### 24. Published package omits an unconditional build input

- `build.zig.zon:73-81` includes only `src`, `data`, and build files.
- `build.zig:167-172` unconditionally installs `docs/logos`.
- A clean package-manager checkout will not contain that directory.
- Move logos under packaged runtime data or include the directory. Include `LICENSE` as well.

### 25. Tuning validation skips signed economic fields

- `CBills` and `Bp` are signed aliases in `src/domain/types.zig:7-11`.
- `src/domain/tuning.zig:717-739` skips signed integers before applying its basis-point checks.
- Negative or nonsensical monetary and multiplier values can pass the named validation.
- Use semantic, field-aware validation rather than signedness reflection.

### 26. Mod semantic validation is not part of ordinary mod builds

- `zig build -Ddata=...` configures overlay imports in `build.zig:47-51`, but cross-file checks live primarily in tests.
- Runtime assumptions such as nonempty fallback tables can survive a normal mod build.
- Add a dedicated validation build step and make overlay builds depend on it.

### 27. Reviewer checks do not recursively inspect screens

- `docs/coding-contract.md:58-67` and `140-188` use `src/tui/*.zig`, excluding `src/tui/screens/*.zig`.
- Several actual boundary and command-feedback violations are therefore invisible to the documented checks.
- Move checks into an executable script using recursive searches and run it in CI.

### 28. TUI modules mostly lack focused tests

- `src/main.zig:6-26` compile-imports them, but `src/tui/app.zig` and the screen modules have no in-file behavioral tests.
- Cursor identity, resize focus, narrow layout, and command refusal behavior depend mainly on one PTY smoke test.
- Add pure screen-model and handler tests, especially for row identity and resize behavior.

## Positive Observations

- The documented architectural intent is unusually explicit and provides useful reviewable invariants.
- Core monetary math consistently uses integer C-bills and basis points.
- Simulation randomness is at least centralized behind named streams.
- TUI screen registration is centralized rather than repeated across parallel switches.
- ANSI literals are appropriately confined to terminal/emblem modules.
- Current TUI modules are all included in the compile-test import block.
- CI runs the unit gate and both smoke scripts.

## Recommended Order

1. Fix gameplay corruption: black-market hull identity, refit inventory, battle IDs.
2. Harden save/load identity, corruption handling, and first-save rollback.
3. Introduce atomic command preparation/commit patterns.
4. Correct medical locality, combat skill selection, support readiness, and freight accounting.
5. Secure terminal rendering and failure cleanup.
6. Replace the incomplete state hash and stabilize RNG stream ownership.
7. Restore layer boundaries while splitting the oversized command/query/store/TUI modules.
8. Repair package contents, data validation, reviewer checks, and focused tests.
