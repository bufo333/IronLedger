# TUI architecture (Stage 12)

Companion to `docs/tui-mockup.html` (rendered mockups of every screen).
The terminal client is a **view over the existing command/query boundary**
— it issues the same `commands.Command` values the CLI does and reads state
through query functions; it never mutates `GameState` directly.

## The lobby

The client starts in a lobby, outside any campaign. It is the only place
that talks to the campaign registry directly (`persist/store.zig`):

| Screen | Panes | Keys → store calls |
|---|---|---|
| Welcome | Players · Campaigns (emblem mark + outfit + commander + day) · Emblem of the selected campaign · Snapshot | `Enter` load · `n` new campaign · `d` delete campaign (typed-name confirm) · `p` new player · `D` delete player · `q` quit |
| New campaign 1 · Commander | Form (name, callsign, faction of origin, profession) · What this means | `create_commander` staged, not yet executed |
| New campaign 2 · Outfit & emblem | Outfit form + emblem source (presets / draw / import) · Preview | `rename_outfit`, `set_emblem` staged |
| New campaign 3 · Company & back office | Generated company (reroll = new seed) · Back office headcount per admin role with payroll and effect | `new_company` + `hire`/`post_person` staged |
| New campaign 4 · Review | Everything staged, with the emblem | `Enter` executes the staged commands against a fresh `GameState`, saves, opens the Desk on day 0 |

Inside a campaign, `q` opens **Return to welcome?** (save and return · return
without saving · stay). Saving writes under the current player.

**Players.** The registry gains a `player` table (`id, name, created_seq`)
and `campaign.player_id`; `listCampaigns` takes a player filter, and
`deletePlayer` cascades to that player's campaigns. This is the one schema
change Stage 12 needs (schema_version 3 → 4).

**Emblems.** An emblem is multi-line text stored on the outfit (`set_emblem`
already takes a string; it becomes newline-separated rows, each cell an ASCII
char with an optional colour hint). Three sources in the wizard:

- *presets* — a handful of 7×3 marks shipped in `data/emblems.zon`;
- *draw* — a cell editor using the same character ramp;
- *import* — any PNG dropped into `~/.merc/logos/` (or `--logos <dir>`).
  The client needs a PNG decoder (`std.compress.zlib` + the five PNG
  filters, 8-bit RGB/RGBA non-interlaced); JPEG is out of scope for now.

The decoded picture is stored with the campaign (`outfit_emblem` blob) and
**displayed by the best method the terminal supports**, probed once at
startup (`tui/emblem.zig`):

1. **Graphics protocol** — kitty protocol (kitty, Ghostty, WezTerm, Konsole;
   probe with an `APC G …` query and a short response wait) or iTerm2
   inline images (`OSC 1337 File=`, gated on `TERM_PROGRAM=iTerm.app`). The
   PNG bytes are transmitted once and placed over a cell rectangle; the
   cells underneath are kept blank in the buffer so redraws don't erase it.
2. **Half-block colour** — every cell is `▀` with a foreground (top pixel)
   and background (bottom pixel) colour: two pixels per cell, so an 18×9
   pane is an 18×18 image and the wizard preview at 38×19 is 38×38.
   Truecolour SGR (`38;2;r;g;b`) where `COLORTERM=truecolor`, else the
   nearest of the 256-colour cube (Terminal.app). `docs/ascii_logo.py
   pixels()` is the reference sampler and produced the mockups.
3. **ASCII ramp** — luminance to ` .:-=+*#%@`, auto-levelled, only when the
   terminal reports no colour. Recognisable as a shape, not as the crest.

Placement is the same in all three: 24×12 on the Welcome, 18×9 on the Desk
and the wizard review, a 6×3 mark in the top-right corner of every in-game
frame, and 38×19 in the emblem studio preview.

## The frame

One persistent frame, three fixed rows plus the screen body:

```
tab bar        F1 Desk  F2 Map  F3 Forces  F4 Contracts  F5 Ledger  F6 Supply  F7 HQ  F8 Lab   <outfit>  ▒▒ emblem
status strip   <date> day N · outfit <funds> · rep · inbox N · checklist N · turn ready: YES/NO          ▒▒ (8×3)
screen body    2–4 panes; the focused pane has the bright border
command line   `:` prompt (opens on `:`), hints on the right
```

- **Tabs** are screens; **panes** are the composable windows inside a
  screen. Tab / Shift-Tab cycles pane focus; each pane owns a cursor.
- **Modals** (end-turn checklist, decision, confirmations, order/transfer
  forms) draw over the current screen and take all input until closed.
- **Size tiers.** The client measures the terminal at startup and on
  SIGWINCH and picks the largest tier that fits:

  | tier | cells | fits | what changes |
  |---|---|---|---|
  | full | 200 × 50 | maximised at 14–16 px on 1080p | three-column screens, 14-row log, emblem 40×20 on the Desk, star map at 1.75 LY/column |
  | wide | 160 × 45 | large window at 16 px | same layouts, side panes narrower |
  | compact | 118 × 36 | half-screen window | two columns, 5-row log, emblem 18×9 |
  | minimum | 80 × 24 | any terminal | one column, side panes hidden, no emblem |

  `docs/tui-mockup.html` shows the full tier; layouts are expressed as
  pane rectangles per tier in `tui/layout.zig`, not computed ad hoc.

## Keyboard model

Global: `F1–F8` / `1–8` tabs · `Tab`/`S-Tab` panes · `j k h l` / arrows
cursor · `Enter` act on cursor row · `Esc` close/back · `:` command line ·
`n` end turn (runs the checklist modal first; `N` = 7 turns) · `?` help ·
`q` return to welcome (save / discard / stay). Screen-local keys are listed per screen below;
they are shortcuts for commands the command line can also run.

The command line accepts every REPL verb (`accept`, `order`, `transfer`,
`assign`, `refit`, `found`, `link`, …) with tab completion over verbs and
entity ids. Results land in the Desk log pane.

## Screens

| Tab | Screen | Panes | Local keys → commands |
|---|---|---|---|
| F1 | Desk | Emblem · Checklist · Inbox · Companies · Log · HQs | Enter on inbox → `resolve_decision`; Enter on checklist → jump to fixing screen |
| F2 | Map | Star map · World | `h j k l` move by world (view follows) · `+`/`-` zoom ×1–×8 centred on the cursor · `o` offers here · `f` → `found_hq` |
| F3 | Forces | TO&E tree · Hull/Person detail · Unassigned pool | `a` → `assign`, `u` → `unassign`, `A` → `auto_assign`, `t` → `train`, `x` → `transfer_unit`/`transfer_person`, `m` medbay modal (`triage`, `leave`) |
| F4 | Contracts | Board · Active · History (closed contracts: outcome, world, days served, VP, pay received) · Contract log | Enter → `accept_contract` (company picker), `c` → `complete_contract`, `R` → `recall_company`; Tab to History, the log follows the cursor |
| F5 | Ledger | Treasuries · P&L · Ledger | `t` → `transfer`, `p` → `set_policy`, `x` clears the row's cash or resupply policy, `L` → `take_loan`, `[ ]` period |
| F6 | Supply | Sites · Demand · Order form · Shop | `o` → `order_part`, `s` → `ship_stock`, `b` → `buy_listing`, Enter on demand → order shortfall, `P` → `set_supply_policy`, `K` → `set_stock_policy` (keep an HQ line stocked), `$` on an HQ row → `sell_stock` |
| F7 | HQ | Facilities/projects · Bays · Back office · Hiring hall | `u` → `upgrade_facility`, `T` → `upgrade_tier`, `f` → `fabricate`, `P` → `post_person`, `h` → `hire_candidate`, `[ ]` switch HQ |
| F8 | Lab | Budget/crits · Mounts · Plan & rules | `-` → `refit_remove`, `+` → `refit_install`, `c` → `refit_clear`, Enter → `refit_commit`, `[ ]` switch hull |
| F9 | People | Personnel (pinned header, role filter) · Record · Open seats | `m` → `admit`, `t` → `train`, `a`/Enter seat picker → `assign`, `P` → `post_person`, `x` → `transfer_person`, `L` → `leave`, `D` → `fire`, `r` record |
| F10 | Market | Boards · Order catalog · Demand | Enter → `buy_listing` / `order_part` / order the shortfall, `b` → `fabricate`, `K` → `set_stock_policy` on a catalogue row, KEEP STOCKED pane (Enter edits, `x` removes), `[ ]` buyer HQ |

Money keys: Ledger `L` → `take_loan`, `R` → `repay_loan`; Forces `$` →
`sell_unit`, `X` → `disband_company`; HQ `$` → `sell_hq`. Turn rules the
client surfaces: untreated wounded and a negative outfit treasury are
blocking checklist items; `advance` refuses with `Insolvent` until a loan
or sale covers it, and `Bankrupt` (game over modal, campaign saved as it
ended) once nothing could.

Modals: **End turn** (checklist rows with jump targets, `n` proceed) ·
**Decision** (options with effects, default marked) · **Order / Transfer /
Assign / Upgrade forms** (field-by-field, validated before the command is
issued so refusals show as inline text, not error codes).

## Queries the core must expose

Most screen data already exists as `print*` functions in `src/main.zig`.
Stage 12 lifts each into a **query** returning structured data (no
formatting) in a new `src/sim/queries.zig`, shared by CLI and TUI:

- `desk` (checklist warnings — exists: `checklist.turnWarnings`; inbox;
  company postures; HQ summaries; log tail with filter)
- `map` (worlds with ring/beachhead/dark classification per HQ, offers per
  world, HQ and company markers)
- `toe` (tree with slot states), `hull`, `person`, `unassignedPool`
- `contracts` (board + active with objective/pool/VP/clock/exposure)
- `treasuries`, `pnl(entity, period)` (exists: `finance.summarize`),
  `ledger(entity, n)`
- `supplies` (sites with tons/capacity/burn/days, inbound), `demand`
- `hq` (facilities built/effective, projects, capacity/ceilings, bays,
  staff vs requirement, candidates)
- `lab(unit)` (exists: `meklab.validate` + `state.labItems`)

Every query is pure and allocator-parameterized so the TUI can rebuild its
view model each frame from an arena.

## Rendering

- **Terminal layer**: a small hand-rolled ANSI layer (raw mode via termios,
  alternate screen, cursor addressing, 16-color SGR, key decoding for
  arrows/F-keys/Esc sequences, resize via SIGWINCH). Evaluated libvaxis and
  found it the better long-term choice *if* it tracks Zig 0.16; given the
  0.15→0.16 std churn (Io, File, process), the hand-rolled layer (~400
  lines) keeps the build dependency-free now and can be swapped later
  behind the same `Screen`/`Cell` interface.
- **Cell buffer**: the frame renders into a `[]Cell` (char + fg + attrs)
  double buffer; only changed cells are flushed. No per-frame allocation
  beyond the arena the queries fill.
- **Widgets**: `Pane` (title, border, focus), `Table` (columns, cursor,
  scroll), `Tree`, `Bar` (tonnage/pool bars), `Form`, `Modal`, `Log`. Each
  widget draws from a view model struct, never from `GameState`.
- **Colors** are semantic only — amber (attention/active), green (ok),
  red (critical), cyan (cursor/focus), dim (chrome) — on the terminal's own
  background, so the client holds on any theme.

## Boundary rules

1. The TUI imports `commands`, `checklist`, `queries`, and read-only domain
   types — nothing under `sim/` that mutates.
2. All mutation goes through `commands.execute`; the TUI never touches
   `GameState` fields.
3. Every refusal (`Error.*`) is rendered as a sentence next to the control
   that caused it, using one table mapping error → text.
4. The CLI remains the scripting/debug interface; both frontends run the
   same golden-master scripts.

- **Glyph set** is ASCII plus box-drawing and block elements only; `--ascii`
  swaps those for `+ - |` and `# .` on terminals that render them
  double-width. Emblem art is plain ASCII by construction.

## Build order (status in ROADMAP.md Stage 12)

1. ✅ `sim/queries.zig` — display-ready views (status, desk, contracts,
   ledger, toe/hull/unassigned, supply, hqDetail) with `{a}…{/}` markup;
   the CLI printers remain for now and migrate onto queries as screens land.
2. ✅ `tui/term.zig` (raw mode, alt screen, keys, SIGWINCH, size) and
   `tui/screen.zig` (cell grid, markup text, panes, list panes, full-frame
   flush). Widgets are functions on `Screen`, not objects.
3. ✅ Lobby in `tui/app.zig`: `player` table (schema v2, migrated in
   `Store.open`), Welcome, four-step wizard, typed-name delete, quit modal.
4. ✅ Desk, Contracts, Ledger; end-turn and decision modals; `:` command
   line with the CLI verbs parsed into `commands.Command`.
5. ✅ first cut: Forces, Supply, HQ. ⬜ Map, Lab.
6. ✅ Emblem (`tui/png.zig`, `tui/emblem.zig`): PNG decode (8-bit,
   non-interlaced), wizard import from the logo directories, half-block
   colour cells in the grid (`Screen.blit`, `Cell.px`), kitty protocol
   probe at startup (`Term.probe`), transmit once per campaign, delete-all
   + place every frame, placements hidden while a modal is open.
   ⬜ iTerm2 inline images, the cell editor, wizard back-office sizing.
7. ✅ Command-line Tab completion; size tiers as inline rules (`narrow()`
   = under 120 columns drops side panes, Enter opens hull/record modals;
   the status strip shortens); `--ascii`; wizard back-office sizing.
   The pty smoke test runs a second pass at 80×24 with `--ascii`.

Smoke test: `python3 docs/tui_smoke.py zig-out/bin/game /tmp/smoke.db`
drives the binary through a pty (create player → wizard → begin → every
screen → end turn → `:day 3` → save & return) and asserts on landmarks.
Run it after any change under `src/tui/`, alongside `zig build test`.
