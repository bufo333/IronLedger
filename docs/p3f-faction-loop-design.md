# P3f Faction Economic Loop — Implementation Design

**Date:** 2026-10-06
**Status:** delivered (P3f.1-P3f.5); follow-up NPC economy work is in `TODO.md`
**Prerequisite:** P3e (entity model, rivals, insolvency predicate — merged)
**Scope:** mechs only; one coherent stage delivered as ordered increments P3f.1–P3f.5

---

## §1  Scope, Owner Decisions, and Ordered-Increment Delivery Model

P3f closes the faction economic loop opened by P3e.  Five interdependent
sub-features are specified here and dispatched one branch per increment, each
reaching local `main` before the next begins (CLAUDE.md one-branch-in-flight
rule).  Every increment is independently correct and green on the rule-72 gate
before the next is dispatched.

**Ordered increments:**

| Increment | Name                                  | Schema |
|-----------|---------------------------------------|--------|
| P3f.1     | Data foundation + black-market schema | v57    |
| P3f.2     | Lost-field wreck dispersal            | —      |
| P3f.3     | NPC competition + pirate replenishment| —      |
| P3f.4     | Merc lifecycle (death + replacement)  | v58                |
| P3f.5     | Campaign-wizard logo picker           | —                  |

P3f.1 shipped schema v57 and P3f.4 shipped schema v58. P3f.2, P3f.3, and
P3f.5 required no additional schema version.

### Owner Decisions for Confirmation at Approval

These seven decisions are architectural/product choices, not inventions.  Each
is presented with rationale and the alternative rejected.  The owner must
confirm or redirect at approval; an implementation increment executes the
confirmed choice.

**D1 — Black-market gating representation (P3f.1)**
Recommend: `black_market: bool = false` on `domain/planet.Planet` (static
catalog, not persisted), extending the existing 12C.17 system rather than
adding a parallel tier or flag table.  The set of worlds (§2 below) is drawn
from `data/planets.zon` — well-known mercenary hubs and periphery-adjacent
worlds.  Alternative: a numeric `black_market_tier: u8` with a threshold
predicate; rejected because the 3025 model has no fine-grained tier
distinction in available sourcebook data, and a bool covers the needed
gameplay distinction (present/absent).

**D2 — Dispersed listing placement (P3f.1)**
Recommend: add `planet_key: []const u8 = ""` and `available_after: u32 = 0`
to `market.Listing`.  A dispersed black-market listing has `black_market=true`,
`hq=.none`, `planet_key` set to a randomly selected black-market world,
`available_after` set to a future `day_index`, and `hull_instance_id` set to
the real wreck.  Rule 1 (no partial truth): a listing is visible and buyable
if and only if `available_after <= current_day_index` AND the buyer can reach
`planet_key`; before that condition is met the listing is absent from every
board — it is never shown in a half-state.  Alternative: store "hidden" flag;
rejected because hidden is an additional state bit that would require a
visibility query to filter — the `available_after` field IS the visibility
contract, and `available_after=0` means "already available" on migrated rows.

**D3 — Buyer-eligibility single owner (P3f.1)**
Recommend: a single function `black_market.buyerEligible(gs, listing, buyer)`
in new `src/sim/black_market.zig` decides "can buyer X take listing Y", where
buyer ∈ {player, pirate band, rival merc company}.  The listing carries only
`planet_key` and `available_after`; access is derived at query time, not
stored redundantly (rule 3, rule 20).  Alternative: per-listing access flag;
rejected because it duplicates the derivation and creates a second truth.

**D4 — Hull disposition on dispersal (P3f.2)**
Recommend: reuse `.market` `OwnerType` for dispersed wrecks, not add a new
`.black_market` `OwnerType` or `HullStatus`.  `.market` ownership already
means "a physical hull a buy transfers to the taker"; the `Listing.black_market
= true` + `available_after` fields carry the black-market semantics without
widening the owner/status enums and their persistence/migration.  Alternative:
add `.black_market` to `OwnerType`; rejected because the dispatch floated it
but the enum extension requires new migrations plus new branches in every
`switch` on `OwnerType` across `battle.zig`, `state.zig`, `rivals.zig`,
`store.zig` — all for a distinction that the listing already carries.
**Owner: confirm the reuse of `.market` ownership.**

**D5 — Enemy-recovery capacity on a lost field (P3f.2)**
Recommend: on a lost field, the enemy faction recovers up to a tunable capacity
(`market.enemy_recovery_capacity` // TUNE, in `tuning.zon`) of the drawn destroyed
hulls back into `faction_rosters[enemy_key]` via `transferHullOwnership`;
the remainder disperse to black-market listings.  Capacity is a ceiling on
hull count, not tonnage, for simplicity in 3025 (BV-weighted variant is a
future refinement).  Alternative: recover all; rejected because it leaves
nothing to disperse, defeating P3f's purpose.

**D6 — RNG stream assignment (P3f.1–P3f.3)**
Dispersal draws inside battle resolution reuse stream `.battle` (consistent
with surrounding salvage rolls).  Monthly NPC/formation flow reuses `.market`
(economic) and `.rosters`/`.rivals` (identity/pool), matching the existing
`faction_surplus`/`seedMercCompanies` patterns.  No new `Stream` value is
added unless the doc justifies one; if it is needed it must have a pinned,
save-meaning salt persisted in `rng_stream` and the draw ORDER is documented
(rule 6/57).

**D7 — Logo-picker auto-fill target (P3f.5)**
Recommend: the logo picker auto-fills the OUTFIT name field (`w_outfit`) in
`app.zig`.  Logos represent whole mercenary companies and the player's outfit
is the company being founded.  Alternative: auto-fill `w_company` (first
lance/company name); rejected because the logo filenames correspond to outfit
identities, not sub-unit names.  **Owner: confirm auto-fill of `w_outfit`.**
Seeded NPC merc companies store a `logo_key` so names and logos are drawn
deterministically from the remaining pool, excluding the player's pick.

---

## §2  Data Foundation — P3f.1

### 2.1  `planet.black_market` attribute

**File:** `src/domain/planet.zig`
**Change:** add `black_market: bool = false` field to the `Planet` struct.

**File:** `data/planets.zon`
**Change:** set `black_market = true` on the following worlds (sourced fresh
from `data/planets.zon` at base commit — all keys verified present):

| Key             | Name            | Faction | Rationale                                           |
|-----------------|-----------------|---------|-----------------------------------------------------|
| `galatea`       | Galatea         | LC      | Mercenary's Star; permissive hiring-and-trade world |
| `solaris7`      | Solaris VII     | LC      | Game world; active underground mech economy         |
| `outreach`      | Outreach        | FWL     | Wolf's Dragoons HQ; major merc hub                  |
| `antallos`      | Antallos        | PER     | Port Krin; pirate trade hub                         |
| `tortuga_prime` | Tortuga Prime   | PER     | Pirate capital; clandestine mech trade              |
| `herotitus`     | Herotitus       | PER     | Periphery hub with grey-market activity             |
| `star_s_end`    | Star's End      | PER     | Oberon-adjacent; pirate supply depot                |
| `canopus4`      | Canopus IV      | MOC     | Magistracy capital; permissive arms laws            |

**Owner: confirm this world set at implementation.**  If the owner selects
additional worlds at implementation, they must be present in `data/planets.zon`
— no world name or key is invented.  The `black_market` flag is a static
catalog attribute, not persisted; it never appears in `store.zig`.

### 2.2  `Listing.planet_key` and `Listing.available_after`

**File:** `src/econ/market.zig` — `Listing` struct
**Change:** add two fields after the existing `hull_instance_id` field:

```zig
/// Dispersed black-market listing: the world where this hull surfaces.
/// Empty string for HQ-board and contract-world listings (hq != .none or
/// company != .none). Non-empty only when black_market=true and hq=.none.
planet_key: []const u8 = "",

/// Dispersed black-market listing: day_index from which this listing is
/// visible and buyable. Zero means immediately available (including
/// migrated rows from pre-v57 saves — fail-closed default, rule 49).
/// A listing with available_after > current_day_index is absent from
/// every board query (rule 1: no partial truth).
available_after: u32 = 0,
```

**Visibility contract (rule 1):**  A listing L is shown and buyable iff:
`L.available_after <= gs.clock.day_index AND black_market.buyerEligible(gs, L, buyer)`

No listing is ever shown in a "pending" or "hidden" state — it is simply absent
from the board until the condition is met.

### 2.3  `src/sim/black_market.zig` — new module

New file: `src/sim/black_market.zig`
This module is the single owner of all dispersed-black-market rules (rule 3,
rule 20).  Nothing outside this module evaluates buyer eligibility or generates
dispersed listings.

**Delivered interfaces:**

```zig
/// The canonical "can this buyer take this listing?" predicate (rule 20/3).
/// buyer is player, pirate, or merc company.
/// Returns false if listing.available_after > current_day.
/// Returns false if buyer cannot reach listing.planet_key.
/// Reach rules (shipped P3f.3 per owner decision): pirate→PER worlds only;
/// merc_company→non-PER worlds only; player→HQ worlds or active-contract
/// deployed worlds; empty/unknown planet_key unreachable by any buyer.
pub fn buyerEligible(
    gs: *const state.GameState,
    listing: market.Listing,
    buyer: BuyerKind,
    current_day: u32,
) bool

/// Generate a dispersed black-market listing for a wreck hull_instance_id.
/// The caller owns world selection and delay draws; this pure constructor sets
/// available_after = battle_day + delay_days.
pub fn makeDispersedListing(
    gs: *const state.GameState,
    hull_instance_id: types.HullInstanceId,
    listing_id: types.ListingId,
    planet_key: []const u8,
    battle_day: u32,
    delay_days: u32,
) market.Listing

/// BuyerKind: the three classes that can access the black market.
pub const BuyerKind = enum {
    player,
    pirate,
    merc_company,
};
```

**Import rule (rule 5):** `black_market.zig` is under `src/sim/`; it imports
`src/domain/` and `src/econ/` but nothing from `src/tui/` or `src/gen/`.
`src/sim/queries.zig` remains a leaf — it may call `buyerEligible` but
`black_market.zig` does not import `queries.zig`.

### 2.4  Schema v57

**File:** `src/persist/store.zig`
**Schema version bump:** `schema_version = 56` → `57`

**Migrations to add** (in the ordered `migrations` slice, after the last v56
migration):

```
Migration{ .from = 56, .to = 57, .table = "listing", .column = "planet_key",
    .sql = "ALTER TABLE listing ADD COLUMN planet_key TEXT NOT NULL DEFAULT ''" }
Migration{ .from = 56, .to = 57, .table = "listing", .column = "available_after",
    .sql = "ALTER TABLE listing ADD COLUMN available_after INTEGER NOT NULL DEFAULT 0" }
```

Both ADD COLUMN NOT NULL DEFAULT migrations follow the existing pattern (no
table rebuild required).  Pre-v57 rows backfill to `planet_key = ""` (no
dispersal world) and `available_after = 0` (already available — fail-closed
default per rule 49: a migrated black-market listing is not suppressed).

**`saveListing` update:**  add `planet_key` and `available_after` to the INSERT
parameter list (currently `?1..?20`; the two new columns become `?21` and
`?22`, or the INSERT is rewritten with named parameters for readability).

**`loadListing` update:**  add `planet_key` and `available_after` to the
SELECT column list and assignment.

**`docs/schema.sql` mirror:**  add the two columns to the `listing` table
definition.  The schema mirror must be updated in the same P3f.1 commit.

### 2.5  Digest coverage

`src/sim/digest.zig` `stateHash` reflectively hashes every field of hashed
`GameState` collections.  `market_listings` is in the hashed set.  The two new
`Listing` fields are auto-covered once `saveListing`/`loadListing` are wired —
no digest code change is needed.  The P3f.1 implementer must confirm that
`stateHash` still produces the same hash for a save loaded before and after the
migration (the round-trip test covers this).

### 2.6  Dispersal tunables (P3f.1)

Delivered constants in `data/tables/tuning.zon` and corresponding fields in
`src/domain/tuning.zig`, all labelled `// TUNE`:

```
market.black_market_delay_days_min       // TUNE: minimum days before a dispersed listing surfaces
market.black_market_delay_days_max       // TUNE: maximum days before a dispersed listing surfaces
market.enemy_recovery_capacity           // TUNE: dispersed listings the enemy may recover on a lost field
market.npc_black_market_draws_per_month  // TUNE: monthly draws per eligible NPC buyer
generation.pirate_replenishment_hulls_per_year // TUNE: base PER hull trickle per year
generation.merc_replacement_cbill_floor  // TUNE: merc-company replacement capital floor
```

---

## §3  Lost-Field Wreck Flow — P3f.2

### 3.1  Current gap (verified at base)

In `src/sim/battle.zig`, the lost-field path contains:

```zig
if (salvage_bv <= 0) break :blk "";
```

`takeSalvage` never runs.  The drawn destroyed enemy hulls are pool-removed,
still `.active`, still enemy-owned, and left with no terminal disposition.
P3f.2 closes this gap.

### 3.2  New lost-field disposition

**File:** `src/sim/battle.zig` — lost-field path in `spoils` block

After `if (salvage_bv <= 0)`, instead of breaking early, collect the drawn
destroyed enemy hulls and call the new owner `disperseEnemyWrecks`:

```zig
// P3f.2: drawn destroyed enemy hulls need a terminal disposition on the
// lost field. Enemy recovers up to capacity; remainder disperses.
try battle.disperseEnemyWrecks(gs, alloc, drawn_destroyed_enemy_hulls.items,
    gs.clock.day_index, contract.planet_key, &rng_copy);
break :blk "";
```

`drawn_destroyed_enemy_hulls` is the slice of `HullInstanceId` values that were
removed from the pool on the lost-field path (the implementer traces the exact
slice from the existing pool-path logic at the time of P3f.2).

### 3.3  `disperseEnemyWrecks` owner

**File:** `src/sim/black_market.zig` (preferred, to keep battle.zig thin per
rule 76/77) or `src/sim/battle.zig` if the battle module already owns the pool
logic and splitting creates an awkward import.  Decision: **the implementer
chooses the cleaner boundary and documents the choice in the commit message.**

```zig
/// Terminal disposition for drawn destroyed enemy hulls on a lost field.
/// Up to market.enemy_recovery_capacity hulls are returned to
/// faction_rosters[enemy_faction_key] (owner transfer to .faction).
/// The remainder are transferred to .market ownership and listed as
/// dispersed black-market listings via makeDispersedListing.
/// Failure-atomic: prepare all ownership transfers and listing appends,
/// then commit infallibly. rng draws on stream .battle.
/// Player-hull and held-field handling are UNCHANGED.
pub fn disperseEnemyWrecks(
    gs: *state.GameState,
    alloc: std.mem.Allocator,
    wrecks: []const types.HullInstanceId,
    enemy_faction_key: []const u8,
    battle_day: u32,
    battle_planet_key: []const u8,
    rng: *rng_mod.Rng,
) !void
```

**Failure-atomicity (rule 7/11):**  Prepare every ownership row, listing
append, and roster entry into a scratch buffer.  If any allocation fails, the
scratch buffer is discarded — `stateHash` is unchanged.  Only after all
allocations succeed are the changes committed to `gs` infallibly.  The
injected-failure atomicity test (§7 P3f.2) exercises this.

**Invariant:** every drawn destroyed enemy hull reaches a terminal state after
this call — either re-rostered to the enemy faction or listed as a dispersed
black-market hull with `owner = .market`.  No hull is left `.active` and
enemy-owned after a lost field.

---

## §4  NPC Black-Market Competition + Pirate Replenishment — P3f.3

### 4.1  Monthly NPC draw

**Tick hook:** `src/sim/tick.zig` `runMarkets`, ordered AFTER
`faction_surplus.runMonthly` and BEFORE the player's market board is surfaced.
This ensures NPC buyers see the same freshly-generated listings the player
would, and consume some before the player's turn.

**Owner:** `src/sim/black_market.zig` — `runNpcBlackMarketDraw`

```zig
/// Monthly NPC consumption of dispersed black-market listings (shipped P3f.3).
/// Called from tick.zig runMarkets on gs.clock.date.day == 1, after
/// faction_surplus.runMonthly and before the player board is surfaced.
/// Each NPC buyer is evaluated with its own BuyerKind so per-buyer reach
/// gating applies: pirates consume only PER-faction-world listings; merc
/// companies consume only non-PER listings (buyerEligible reach rules).
/// Draw order: pirate band first, then each merc company in MercCompanyId
/// insertion order; within a buyer, up to npc_black_market_draws_per_month
/// draws on stream .market from that buyer's eligible set. A consumed-marker
/// array prevents two buyers from taking the same hull (rule 1).
/// Asset safety: only NPC/pirate rosters are modified; no player funds,
/// forces, or units are touched (rule 67 P3f.3 §7).
pub fn runNpcBlackMarketDraw(gs: *state.GameState) !void
```

### 4.2  Pirate replenishment trickle

Pirates (`PER` faction, verified present in `data/tables/factions.zon` at
base) receive a base hull trickle independent of the black market, modelling
recruitment from untracked periphery raiders.

```zig
/// Monthly pirate hull trickle (independent of market listings).
/// Mints up to tuning.generation.pirate_replenishment_hulls_per_year/12
/// new HullInstances drawn from PER's RAT (reuse faction_surplus draw
/// pattern on stream .market), adds them to faction_rosters["PER"].
/// Called from tick.zig runMarkets on gs.clock.date.day == 1, after
/// faction_surplus.runMonthly and after runNpcBlackMarketDraw.
pub fn runPirateReplenishment(
    gs: *state.GameState,
    alloc: std.mem.Allocator,
) !void
```

The RAT used is the existing PER faction's configured table (drawn by the
existing `faction_surplus` RAT draw path — the implementer sources the exact
RAT key from `data/tables/factions.zon` at implementation time, not from this
doc).

### 4.3  Ordering guarantee (rule 6/57)

The draw order inside `runMarkets` is fixed:

1. `faction_surplus.runMonthly` (existing) — generates new faction/market listings
2. `runNpcBlackMarketDraw` — NPC buyers consume eligible dispersed listings
3. `runPirateReplenishment` — mint pirate trickle hulls
4. Existing market-refresh / player-board generation (unchanged)

This order is documented here so any reordering is caught by the determinism
tests.

---

## §5  Merc-Company Death and Replacement — P3f.4 (delivered)

### 5.1  Insolvency and bankruptcy detection

**Owners:** `src/sim/rivals.zig` `mercCompanyInsolvent` (BV-based, delivered
P3e.7) and the `cbills < 0` (bankrupt) check in `runMercLifecycle`.
`mercCompanyEligibleAsOpFor` (delivered P3f.4) is the single owner of the
"may this company be an OpFor" rule: active (dissolved_day==0), solvent, and
at full strength (roster.len >= merc_company_hulls_each).

**Tick hook:** `src/sim/merc_lifecycle.zig` `runMercLifecycle`, called from
`tick.zig runMarkets` after `runPirateReplenishment` (lifecycle sees the
month's fresh listings and pirate trickle).

```zig
/// Monthly merc lifecycle pass (docs/p3f-faction-loop-design.md §5).
/// Iterates the initial company set only; replacements appended this pass
/// are processed next month.
pub fn runMercLifecycle(gs: *GameState) !void
```

### 5.2  Liquidation

```zig
/// Single owner of merc-company liquidation (rule 20/76). No RNG.
/// Transfers every hull in the company's roster to .market ownership and
/// appends a regular market listing (black_market=false, planet_key="", hq=.none)
/// at factory-fresh pricing (avg-weapon + hullPrice, fixed roll 10_000,
/// expires after faction_surplus_listing_days). Sets dissolved_day=day.
/// Failure-atomic (rules 7, 11-13): reserve phase is entirely fallible;
/// commit phase is infallible.
pub fn liquidateMercCompany(
    gs: *GameState,
    alloc: std.mem.Allocator,
    company_id: types.MercCompanyId,
    day: u32,
) !void
```

The listing pattern reuses `faction_surplus.runMonthly`'s surplus-listing path
(owner-transfer to `.market` + listing append; `hullPrice` cited from
docs/p3f-faction-loop-design.md §3.4 // TUNE). Dissolved companies are never
removed from state (D-A): `dissolved_day != 0` is the permanent record.

### 5.3  Replacement spawn and hull buy

```zig
/// Single owner of "buy eligible hulls toward full strength" (rule 20/76).
/// Shared by spawnReplacementCompany and the monthly tick.
/// Does NOT write gs.rng — the caller commits.
pub fn buyHullsForCompany(
    gs: *GameState,
    alloc: std.mem.Allocator,
    company_id: types.MercCompanyId,
    day: u32,
    rng: *rng_mod.Rng,
) !void

/// Single owner of replacement spawn (rule 20/76).
/// Strength target: tuning.generation.merc_company_hulls_each (market listings only,
/// no RAT mint — D-B). Starting cbills: tuning.generation.merc_replacement_cbill_floor.
/// Does NOT write gs.rng — the caller commits.
pub fn spawnReplacementCompany(
    gs: *GameState,
    alloc: std.mem.Allocator,
    day: u32,
    rng: *rng_mod.Rng,
) !void
```

### 5.4  New `MercCompany` fields (schema v58, P3f.4)

Four new fields appended to `MercCompany` after `doctrine` (field order fixes
digest and column order):
- `cbills: types.CBills = 0` — C-bills held; seeded to `merc_replacement_cbill_floor`
- `founded_day: u32 = 0` — day_index founded (0 = pre-campaign seed)
- `dissolved_day: u32 = 0` — 0 = active; nonzero = day_index dissolved (D-A)
- `logo_key: []const u8 = ""` — logo basename from data/logos/ catalog; '' = legacy

Migration v57→v58: four `ALTER TABLE merc_company ADD COLUMN …` rows
(fail-closed defaults 0/'').  `saveMercCompanies` INSERT uses 14 columns;
`loadMercCompanies` SELECT reads indices 8-11.

### 5.5  Determinism

Liquidation is RNG-free. Spawn and buy draw on `.rivals` (identity) and
`.market` (hull selection) streams; `runMercLifecycle` commits `gs.rng`
once per company-action (bounded non-atomicity on OOM, matching
`faction_surplus.runMonthly`). Golden-master tests re-pinned at P3f.4.

---

## §6  Campaign-Wizard Logo Picker — P3f.5

### 6.1  Picker in `app.zig`

**File:** `src/tui/app.zig`

The outfit step already has `loadLogoList`, `self.logos`, `w_logo`, `w_preview`,
`setEmblemSource`, `emblemMove`, and `loadPreview` (verified at base).  Today
the picker sets only the emblem; it does not auto-fill a name field.

**P3f.5 change:** when the player confirms a logo (existing confirm key in the
outfit step), call `titleCaseLogoKey` (§6.2) on the selected logo filename stem
and write the result into `w_outfit` (the outfit name field).  The player may
then edit the auto-filled name before proceeding — no value is forced.

**Key binding:** the existing confirm/select key in the outfit step; no new key
is added.  If a new binding is introduced, it is added to `src/tui/keys.zig`
with a descriptive comment.

**Smoke scripts:** P3f.5 touches `src/tui/app.zig`, so both smoke scripts
(`docs/tui_smoke.py` and `docs/repl_smoke.sh`) must run and pass as part of
the P3f.5 gate (rule 72).

### 6.2  Title-case helper (delivered P3f.4)

**File:** `src/gen/logo_name.zig` (new, pure, no I/O — satisfies rule 2)

```zig
/// Convert a logo filename stem to a display name.
/// Algorithm: strip a directory prefix (last '/') and ".png" suffix,
/// replace '_' with space, upper-case the first ASCII byte of each word.
/// Non-ASCII bytes passed through unchanged. No allocation.
/// Output length == stripped input length; buf of key.len bytes always suffices.
/// Examples (verified):
///   "vipers_due"                    → "Vipers Due"
///   "red_bull_company"              → "Red Bull Company"
///   "ironledger_mercenary_company"  → "Ironledger Mercenary Company"
/// Note: apostrophes absent from filenames are NOT recovered.
pub fn titleCaseLogoKey(key: []const u8, buf: []u8) []u8
```

This function is pure, allocation-free, and tested in isolation.

### 6.3  Logo catalog — build-time generation (delivered P3f.4)

The logo catalog is generated at build time, not hand-maintained:

- `build.zig` scans `data/logos/` at configure time, collects every `*.png`
  basename with `.png` stripped, sorts ascending by byte order, formats a ZON
  array literal, writes it to a generated artifact `logos.zon` via
  `b.addWriteFiles()`, and exposes it as `mod.addAnonymousImport("logos_zon", …)`.
- `src/domain/logo.zig` is a checked-in pure shim:
  `pub const all_keys: []const []const u8 = &@import("logos_zon");`
  All consumers reference `logo.all_keys`; no hand-maintained key list exists.
- A comptime guard in `roster_seed.zig` fails the build if
  `merc_company_count > logo.all_keys.len`.
- Adding a new `data/logos/<name>.png` and running `zig build test` surfaces
  `<name>` in `logo.all_keys` with no `.zig` edit.

### 6.4  Committing `data/logos/` (brought forward to P3f.4)

Owner decision: `data/logos/` was brought forward from P3f.5 to P3f.4 so the
build-time scan produces a reproducible catalog on every machine (tracked PNGs
are identical everywhere). The 35 PNGs are committed in this branch.

P3f.5 delivered the campaign-wizard logo picker, which uses
`titleCaseLogoKey` to auto-fill the outfit name, and the runtime logo install.

The 35 files committed (sorted, from `git ls-files data/logos/`):

```
ashfall_lancers.png            balance_point_mercenaries.png
blackstar_company.png          broken_sky_company.png
cerberus_contracting.png       dawnbreak_mercenaries.png
dead_reckoning.png             deep_reach_company.png
dust_dogs_mercenaries.png      emberguard_mercenary_company.png
frontier_bound_mercenaries.png ghostline_mercenaries.png
glacial_reach_mercenaries.png  hammerfall_mercenaries.png
iron_vultures.png              ironbear_company.png
ironledger_mercenary_company.png  jade_fang_company.png
last_argument_mercenaries.png  nightwarden_mercenaries.png
northwind_mercenaries.png      orbital_scar_mercenaries.png
praetor_company.png            ravenstrike_mercenaries.png
red_bull_company.png           redline_mercenaries.png
sable_claw_mercenaries.png     scorched_earth_company.png
shadow_blade_company.png       stonewolf_mercenaries.png
stormforge_company.png         three_spears_company.png
vipers_due.png                 voidbreakers_mercenaries.png
windsong_company.png
```

**`build.zig.zon` and packaging:** `data/logos/` is in the package paths, and
`build.zig` installs its PNGs to `share/iron-ledger/logos` in every release
tree. `src/tui/paths.zig` locates that runtime directory.

---

## §7  Per-Sub-Increment Delivery Table

Each row asserts the increment is independently correct and green on the
rule-72 gate before the next increment is dispatched.

### P3f.1 — Data Foundation ✅

| Area        | Deliverable                                                                                      |
|-------------|--------------------------------------------------------------------------------------------------|
| Domain      | `planet.Planet.black_market: bool = false`; `data/planets.zon` worlds flagged                  |
| Listing     | `market.Listing.planet_key`, `market.Listing.available_after` fields                            |
| Schema      | v57; two ADD COLUMN migrations; `saveListing`/`loadListing` wiring; `docs/schema.sql` updated   |
| New module  | `src/sim/black_market.zig`: `BuyerKind`, `buyerEligible`, `makeDispersedListing`                |
| Tuning      | Six constants in `tuning.zon` / `tuning.zig` (all `// TUNE`)                                    |
| Tests (r67) | `buyerEligible` table test: buyer kinds × available/unavailable × planet reachable/unreachable  |
| Tests (r68) | Save/load round-trip: `planet_key`/`available_after` survive; digest equality before/after load  |
| Tests (r68) | Pre-v57 migration fixture: absent columns backfill to `""`/`0` without error                    |
| Gate        | `zig fmt`, `zig build test`, `verify-contract.sh`; NO smoke (no tui/cli/queries/main.zig change)|

### P3f.2 — Lost-Field Wreck Dispersal ✅

| Area        | Deliverable                                                                                      |
|-------------|--------------------------------------------------------------------------------------------------|
| Sim         | `battle.zig` lost-field path: calls `disperseEnemyWrecks` instead of early break                |
| New fn      | `disperseEnemyWrecks` in `black_market.zig` (or `battle.zig` — implementer decision)            |
| Invariant   | Every drawn destroyed enemy hull has a terminal disposition after a lost field                   |
| Tests (r67) | Fixed-seed lost-field test: enemy recovery up to capacity + remainder on black-market worlds    |
| Tests (r67) | Regression: previously-leaked enemy wrecks now reach terminal disposition                        |
| Tests (r69) | Injected-failure atomicity: failing allocator leaves `stateHash` unchanged                      |
| Gate        | `zig fmt`, `zig build test`, `verify-contract.sh`; NO smoke (no tui/cli/queries/main change)    |

### P3f.3 — NPC Competition + Pirate Replenishment ✅

| Area        | Deliverable                                                                                      |
|-------------|--------------------------------------------------------------------------------------------------|
| Tick hook   | `tick.zig runMarkets`: `runNpcBlackMarketDraw` then `runPirateReplenishment` inserted            |
| New fns     | `runNpcBlackMarketDraw`, `runPirateReplenishment` in `black_market.zig`                          |
| Tests (r67) | Deterministic NPC draw: NPC buyers consume eligible listings before player turn                  |
| Tests (r67) | Pirate trickle: independent of market, count within expected range under fixed seed              |
| Tests (r67) | Asset-safety: no player funds, forces, or units modified by non-buy NPC paths                   |
| Gate        | `zig fmt`, `zig build test`, `verify-contract.sh`; NO smoke                                     |

### P3f.4 — Merc Lifecycle ✅

| Area        | Deliverable                                                                                      |
|-------------|--------------------------------------------------------------------------------------------------|
| Domain      | `MercCompany.logo_key: []const u8 = ""`                                                          |
| Schema      | v58; ADD COLUMN `merc_company.logo_key`; `saveMercCompany`/`loadMercCompany`                    |
| Tick hook   | `runMercLifecycle` in `tick.zig` or new `merc_lifecycle.zig`                                     |
| New fns     | `liquidateMercCompany`, `spawnReplacementCompany`                                                |
| Tests (r67) | Insolvency → liquidation → replacement: count held at 12; C-bill injection floor exercised       |
| Tests (r67) | Determinism: same seed produces same company sequence                                            |
| Tests (r68) | Save/load of `MercCompany.logo_key`; round-trip digest equality                                  |
| Gate        | `zig fmt`, `zig build test`, `verify-contract.sh`; NO smoke                                     |

### P3f.5 — Campaign-Wizard Logo Picker ✅

| Area        | Deliverable                                                                                      |
|-------------|--------------------------------------------------------------------------------------------------|
| TUI         | `src/tui/app.zig`: confirm auto-fills `w_outfit` with `titleCaseLogoKey(selected_stem)`         |
| New fn      | `src/gen/logo_name.zig`: `titleCaseLogoKey` (pure)                                              |
| Seed        | `roster_seed.zig`: rivals draw from logo pool excluding player's pick                            |
| Assets      | `data/logos/` (35 PNG files) committed to the repository                                        |
| Tests (r67) | Pure unit test of `titleCaseLogoKey` over worked examples and odd filenames                     |
| Tests (r67) | TUI picker: row identity and key-dispatch test                                                   |
| Gate        | `zig fmt`, `zig build test`, `verify-contract.sh`; **BOTH smoke scripts required** (tui change) |

**Durable-doc updates required in each increment's commit (design-docs-in-sync rule):**
ARCHITECTURE.md (economy/black-market section), GAMEPLAY.md, `docs/tui.md` (P3f.5 picker),
`docs/schema.sql` (schema bumps), `docs/mekhq-map.md` (AtB black-market / retirement rows),
ROADMAP.md P3f tick, TODO.md re-file into P3f.2–P3f.5 items (owner action after P3f.1 lands).

---

## §8  Invariants and Contract Mapping

**Rule 1 (no partial truth):** A dispersed listing is either absent from the
board (available_after > day_index) or fully visible and buyable.  No listing
is ever shown in a "pending" or "hidden" state.  A campaign loads whole or is
rejected (migration: backfilled rows with available_after=0 are immediately
available — not suppressed).

**Rule 7/11 (command boundary, failure-atomic):** Buying from the black market
goes through the existing `commands.zig` → `contract_market.buyFromListing`
boundary, unchanged by P3f.  NPC "buys" inside `runNpcBlackMarketDraw` are
simulation-internal state mutations (not player commands); they use the same
ownership-transfer functions as the command path and are failure-atomic.
`disperseEnemyWrecks` and `liquidateMercCompany` are failure-atomic (prepare/commit
pattern).

**Rule 20/3 (one owner, one result):** `black_market.buyerEligible` is the
single owner of the "can X buy Y" decision.  `makeDispersedListing` is the
single owner of dispersed listing generation.  `liquidateMercCompany` is the single
owner of hull liquidation.  `spawnReplacementCompany` is the single owner of
replacement formation.  No caller re-implements any of these.

**Rule 55 (typed IDs, never inferred):** All hull references use
`types.HullInstanceId`, company references use `types.MercCompanyId`, listing
references use `types.ListingId`.  No ID is cast, inferred, or constructed
outside its mint point.

**Rule 56 (integer C-bills, basis points):** The C-bill injection floor
(`tuning.generation.merc_replacement_cbill_floor`) is an integer C-bill value.
All pricing calculations use the existing `types.CBills` + `types.Bp` pattern.

**Rule 6/57 (named RNG streams, pinned salts, documented draw order):** All
new draws use existing named streams (`.battle`, `.market`, `.rivals`,
`.rosters`).  No new `Stream` value is introduced without a pinned salt
persisted in `rng_stream`.  Draw order within each tick hook is fixed and
documented in this doc (§4.3 ordering guarantee).

**Rules 45–51 (persistence):** Every new field has an explicit field class
(transient/static/persisted).  `planet.black_market` is static (not persisted).
`Listing.planet_key` and `Listing.available_after` are persisted (explicit
migration).  `MercCompany.logo_key` is persisted (explicit migration).  All
migrations are ADD COLUMN NOT NULL DEFAULT (fail-closed defaults per rule 49).
All new saves are through the existing atomic save path in `store.zig`.

**Rules 67–69 (tests):**

- Rule 67: every new rule module (`black_market.zig`, `merc_lifecycle.zig` if
  separate, `logo_name.zig`) has focused tests asserting that the rule owner and
  every consumer agree.  See §7 for the required test descriptions per increment.
- Rule 68: every persisted field has a save/load round-trip test proving digest
  equality and migration-backfill correctness.
- Rule 69: every failure-atomic function has an injected-failure atomicity test
  proving `stateHash` is unchanged on allocator error.

**Rules 76/77 (new behavior in owning modules, not piled onto `battle.zig` /
`GameState`):**  Lost-field disposition logic is owned by `black_market.zig`
(called from `battle.zig`, not inline).  NPC draw and pirate replenishment are
owned by `black_market.zig` (called from `tick.zig`, not inline).  Merc
lifecycle is owned by `merc_lifecycle.zig` or `rivals.zig` (not piled onto
`GameState`).  `titleCaseLogoKey` is owned by `src/gen/logo_name.zig` (pure,
not inlined into `app.zig`).

---

## §9  Residual Risk, Open TUNE Values, and MekHQ/AtB Provenance

### Open TUNE values

Every new constant introduced by this design is labelled `// TUNE` because no
sourced value from a canonical rulebook or the existing codebase has been
verified at plan time.  They land in `data/tables/tuning.zon` and
`src/domain/tuning.zig`:

```
market.black_market_delay_days_min         // TUNE
market.black_market_delay_days_max         // TUNE
market.enemy_recovery_capacity             // TUNE
market.npc_black_market_draws_per_month    // TUNE
generation.pirate_replenishment_hulls_per_year // TUNE
generation.merc_replacement_cbill_floor    // TUNE (C-bill injection floor for P3f.4)
```

No chassis name, RAT composition, or C-bill value is stated in this doc.  The
implementer sources those from `data/tables/` at implementation time or labels
them `// TUNE`.

### MekHQ/AtB provenance

The dispersed black market design is consistent with AtB's black-market contact
event (the existing 12C.17 event in `contract_events.zig`), extended to cover
hull listings from battle salvage.  `docs/mekhq-map.md` maps the existing AtB
rows; the P3f implementer adds the rows for hull black-market, NPC competition,
and company retirement/replacement.

The merc-company death-and-replacement cycle maps to AtB's retirement/creation
flow (`PersonnelMarket`, `UnitMarket`). The replacement company draws its
identity from the person-name and rival-archetype generators, then separately
selects an unused logo. The campaign-wizard alone derives the player's outfit
name from a chosen logo key (§6.2).

### Risk register

| Risk                                | Mitigation                                                          |
|-------------------------------------|---------------------------------------------------------------------|
| D4 rejected (new OwnerType wanted)  | §2.3 describes the fallback; implementer adds enum value + migrations |
| D7 rejected (auto-fill w_company)   | One-line change in app.zig; no architectural rework needed           |
| Schema-version drift                | P3f.1 shipped v57 and P3f.4 shipped v58                              |
| `available_after=0` semantics       | Explicit in §2.2: zero means "already available" (fail-closed)      |
| Determinism from new RNG draws      | Draw ORDER documented in §4.3; digest/golden tests catch reordering  |
| Asset fan-out (hulls + C-bills)     | Existing command boundary for player buys; NPC paths use same transfer functions + asset-safety tests |
| Scope creep into P4 narrative       | §10 Delivered Scope Limits excludes P4 integration                  |

---

## §10  Delivered Scope Limits

- P3f delivers the documented mech-only economy. The planned P2 vehicle and
  aerospace foundation owns conventional combat hulls; it is not retrofitted
  into this delivered design.
- A new pirate faction key (pirates are the existing `PER` faction, verified
  present in `data/tables/factions.zon`).
- A parallel market, command, event, battle, or report path (all extensions
  go through existing owners).
- P4 narrative integration, world-state progression, or faction political events.
