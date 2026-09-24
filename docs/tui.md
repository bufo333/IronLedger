# TUI architecture

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
status strip   <date> day N · outfit <funds> · rep · inbox N · checklist N · urgent N                   ▒▒ (8×3)
screen body    2–4 panes; the focused pane has the bright border
command line   `:` prompt (opens on `:`), hints on the right
```

- **Tabs** are screens; **panes** are the composable windows inside a
  screen. Tab / Shift-Tab cycles pane focus; each pane owns a cursor.
- **Modals** (end-turn checklist, decision, confirmations, order/transfer
  forms) draw over the current screen and take all input until closed.
  The **after-action sheet** (Desk `b`, then Enter) is the one that carves
  its own layout: the fight, the field, the spoils and the trucks in four
  panes, falling back to the wrapped AAR text below
  `layout.modal.after_action_stack_cols`. A conceded engagement's sheet
  says the objective was given up with nothing to field.
- **Size.** The client measures the terminal at startup and on SIGWINCH
  and lays every screen out from the width and height it has: panes split
  the body by ratio, side panes drop below 120 columns (`narrow()`), the
  Desk emblem needs 160, and every table sizes its columns to content and
  scrolls sideways when the pane is narrower. Below 80 × 24
  the client shows what it needs instead of fragments. There are no fixed
  tiers; a bigger terminal simply shows more rows and wider panes.
  `docs/tui-mockup.html` shows the layout at 200 × 50.

## Keyboard model

Keys map to actions through binding tables (`src/tui/keys.zig`): one
table for the keys every screen shares, one per screen. The screen's
handler switches on the action, so a key works only if it is listed, and
the footer, pane titles, help modal and the reference under **Keys** below
are all generated from the same tables. Screen keys are shortcuts for
commands the command line can also run.

The command line and the REPL share one parser, `src/sim/cli.zig`
(`game.cli.parseCommand`, `verbs`, `usage`, `errorText`): every command
verb (`accept`, `order`, `transfer`, `assign`, `refit`, `found`, `link`,
`raise`, `sellstock`, `roe`, `role`, `rush`, `confirm`, …) works in both,
with tab completion over verbs and entity ids here. Frontend-only verbs
(`day`, `save`, `quit`, `help`, `settings`, `emblem`, `manning`,
`readiness`, `summary`, `music`) stay in `app.zig`; the REPL's
`briefing <contract id>` prints what the battle-orders box shows. Results
land in the Desk log pane.

Parsing is strict, for the client's own verbs too (`day`, `save`,
`manning`, …: `cli.parseClientVerb`; `:day junk` moves no time). Every
word must be used: anything left over after a
complete command is refused, and a verb that takes a name (`raise`,
`rename`, …) takes the rest of the line as that name. A choice word
outside its list (`xfer`, `office`, `promote`, `cycledifficulty`) is
refused, never read as the default; bare `autoadmit` toggles, and
`autoadmit on|off` sets it. A parse error shows the verb's usage line.

A command the sim refuses shows as `refused: <sentence>` in the status
line (the REPL prints the same line), the sentence coming from
`cli.errorText`, which words every command and parse error and says "an
unexpected failure" for anything else; no error name reaches the screen.
A screen may word an expected refusal its own way (the part a repair
lacks, the role nobody fills) through `execResultWith`. Screen keys do
not pre-check what the command decides: the Forces `+` asks for the new
company's name, aims at an HQ with a free combat-company slot (else the
selected one), and `raise_company` refuses after the name when there is
no room.

## Screens

| Tab | Screen | Panes |
|---|---|---|
| F1 | Desk | Emblem · Checklist · Inbox · Companies · Log · HQs |
| F2 | Map | Star map · World |
| F3 | Forces | TO&E tree · Hull/Person detail · Unassigned pool |
| F4 | Contracts | Board · Active · History (closed contracts: outcome, world, days served, VP, pay received) · Contract log |
| F5 | Ledger | Treasuries · P&L · Ledger |
| F6 | Supply | Sites · Demand · Order form · Shop |
| F7 | HQ | Facilities/projects · Bays · Back office · Hiring hall |
| F8 | Lab | Budget/crits · Mounts · Plan & rules |
| F9 | People | Personnel (pinned header, role filter) · Record · Open seats |
| F10 | Market | Boards · Order catalog · Demand |

## Keys

Every key the client answers, from the binding tables that dispatch them
(`src/tui/keys.zig`, each screen's `bindings`). The footer, the pane
titles and the help modal come from the same tables.

<!-- keys: generated from the binding tables by `game --keys-markdown`; a test compares this block -->

### Every screen

| Key | Does |
|---|---|
| `F1-F10 / 1-0` | switch screens: Desk, Map, Forces, Contracts, Ledger, Supply, HQ, Lab, People, Market |
| `F12` | settings |
| `Tab` | next pane (Shift-Tab: previous) |
| `j/k ↑/↓` | move the cursor (PgUp/PgDn ten rows) |
| `← →` | scroll a wide table's columns (◀ 2 · 3 ▶ = hidden); pan the star map |
| `:` | the command line: every CLI verb works (day, transfer, order, accept, …) |
| `n` | end the turn (the checklist opens first) |
| `N` | end 7 turns (the checklist opens first) |
| `M` | music on/off |
| `?` | help |
| `q` | back to the welcome screen (save / discard / stay) |

### F1 Desk

| Key | Pane | Does |
|---|---|---|
| `Enter` | checklist | go where the warning points (a contact warning opens its battle orders) |
| `Enter` | inbox | open the decision under the cursor |
| `Enter` | log | read the whole log entry under the cursor |
| `b` | any | the engagements still on record: pick one to read |
| `e` | any | choose the outfit's emblem |

### F2 Map

| Key | Pane | Does |
|---|---|---|
| `h l` | any | pan the map west / east (j k and the arrows pan too) |
| `+ -` | any | zoom in / out (names show at zoom ×2) |
| `c` | any | colour the map by faction, industry, standing or activity |
| `f` | any | found an HQ on the world under the cursor (fills the command line) |
| `o` | any | open the contract board |

### F3 Forces

| Key | Pane | Does |
|---|---|---|
| `[ ]` | any | previous / next TO&E view: all forces, each company, unassigned hulls, the hangar |
| `r` | any | cycle the side pane: readiness, manning, damage |
| `Enter` | TO&E | assign people to the hull under the cursor (narrow: its detail) |
| `a` | any | seat a pilot, crew or tech on the hull under the cursor |
| `u` | any | clear a seat or the tech on the hull under the cursor |
| `l` | any | move the hull under the cursor into a lance |
| `x` | any | send the hull under the cursor to another company |
| `c` | any | hire from the halls to fill the company's manning table |
| `A` | any | auto-assign the company's people to its hulls |
| `t / T` | any | train one person (the command line); T enrolls the whole company |
| `o` | any | cycle a lance's role, or a company's rules of engagement |
| `d` | any | queue the hull under the cursor for depot repair |
| `R` | any | on a hull: order spares for its broken gear; on a company: recall it home |
| `m` | any | mothball or reactivate the hull under the cursor |
| `w` | any | raise an air wing for the company under the cursor |
| `+` | any | raise a new combat company |
| `$` | any | sell the hull under the cursor |
| `X` | any | disband the company under the cursor |
| `b` | any | fabricate the structural parts the company's home HQ lacks |

### F4 Contracts

| Key | Pane | Does |
|---|---|---|
| `[ ]` | any | previous / next HQ's board |
| `Enter` | board | accept the offer under the cursor (you pick the company) |
| `b` | board | negotiate the offer under the cursor (one round per offer) |
| `Enter` | active | the active contract's whole log, full screen |
| `c` | active | close out the contract under the cursor |
| `R` | active | recall the company (under contract: a breach, confirmed first) |
| `Enter` | history | the closed contract's whole log, full screen |

### F5 Ledger

| Key | Pane | Does |
|---|---|---|
| `Enter` | any | open the command line with a transfer from the outfit treasury started |
| `L` | any | take a loan (simple interest) |
| `R` | any | repay the oldest loan |
| `t` | any | send cash from the outfit to the HQ or company row selected |
| `T` | any | pull cash back from the selected HQ or company to the outfit |
| `p` | any | set the selected row's cash top-up policy (floor and monthly cap) |
| `x` | any | clear the selected row's standing cash or resupply policy |

### F6 Supply

| Key | Pane | Does |
|---|---|---|
| `o` | any | order a part delivered to the site under the cursor |
| `s` | any | ship parts from the home shelf (to the company under the cursor) |
| `R` | any | return a company's stock over its field plan to the home HQ |
| `H` | any | send every structural component in a company's field stores home |
| `K` | any | keep a part stocked at the HQ under the cursor |
| `t` | any | send outfit cash to the company or HQ under the cursor |
| `T` | any | transfer the site's cash back to the outfit |
| `p` | any | keep a company or HQ topped up from the outfit treasury |
| `P` | any | set a company's automatic resupply policy |
| `$` | any | sell stock |

### F7 HQ

| Key | Pane | Does |
|---|---|---|
| `[ ]` | any | previous / next HQ |
| `u` | any | upgrade the facility under the cursor (elsewhere: pick one) |
| `T` | any | raise a field HQ to regional |
| `S` | any | staff the back office to requirement |
| `h` | any | hiring hall |
| `f` | any | hall filter forward (F: back) |
| `Enter` | hiring hall | hire the candidate under the cursor |
| `b` | any | fabricate a component at this HQ's bay |
| `$` | any | sell HQ |

### F8 Lab

| Key | Pane | Does |
|---|---|---|
| `[ ]` | any | previous / next mek in the hangar |
| `+` | any | stage installing a part from the home HQ's stock |
| `-` | any | stage removing the mount under the cursor |
| `c` | any | clear the staged refit plan |
| `Enter` | any | commit the plan as a bay job at the home HQ |
| `R` | any | order a replacement for the damaged or destroyed mount under the cursor |
| `D` | any | queue the hull for depot repair |

### F9 People

| Key | Pane | Does |
|---|---|---|
| `/ ,` | any | next / previous roster filter |
| `a` | any | assign the person under the cursor to an open seat |
| `x` | any | transfer to another company |
| `P` | any | post to an HQ |
| `t` | any | train the person's primary skill |
| `L` | any | send on leave for some days |
| `T` | any | set medical triage priority (higher heals first) |
| `m` | any | admit to the medbay |
| `r` | any | open the full service record |
| `D` | any | dismiss the person (asks first) |

### F10 Market

| Key | Pane | Does |
|---|---|---|
| `[ ]` | any | previous / next HQ's board and treasury |
| `/ ,` | any | next / previous market filter |
| `Enter` | board | buy the board listing under the cursor |
| `Enter` | catalog | order the catalogue part under the cursor |
| `Enter` | demand | order (or fabricate) what a damaged slot is short |
| `Enter` | keep stocked | edit the keep-stocked line under the cursor |
| `b` | catalog | fabricate the structural component under the cursor at this HQ's bay |
| `K` | catalog | keep the catalogue part under the cursor stocked at this HQ |
| `x` | keep stocked | remove the keep-stocked line under the cursor |

### Welcome

| Key | Does |
|---|---|
| `Tab` | players / campaigns |
| `j/k` | choose |
| `Enter` | campaigns |
| `Enter` | continue |
| `n` | new campaign |
| `d` | delete campaign |
| `p` | new player |
| `D` | delete player |
| `s` | settings |
| `M` | music on/off |
| `?` | help |
| `q` | quit |

### New campaign · commander

| Key | Does |
|---|---|
| `Tab` | next field |
| `j/k` | choose |
| `type` | type the name |
| `Backspace` | erase |
| `Enter` | next step |
| `Esc` | back to welcome |

### New campaign · outfit and emblem

| Key | Does |
|---|---|
| `Tab` | next field |
| `h` | presets |
| `l` | import a picture |
| `j/k` | choose |
| `type` | type the outfit's name |
| `type` | type the company's name |
| `Backspace` | erase |
| `Enter` | next step |
| `Esc` | back |

### New campaign · company and back office

| Key | Does |
|---|---|
| `r` | reroll (new seed) |
| `Tab` | company / back office |
| `j/k` | row |
| `-/+` | adjust headcount |
| `Enter` | next step |
| `Esc` | back |

### New campaign · review

| Key | Does |
|---|---|
| `Enter` | begin campaign |
| `1-3` | back to a step |
| `Esc` | discard |

### Lists (pick a company, a part, a seat, …)

| Key | Does |
|---|---|
| `j/k ↑/↓` | row |
| `PgUp/PgDn` | page |
| `Home` | top |
| `End` | end |
| `←/→` | columns |
| `Enter` | choose |
| `Esc` | cancel |

### Sheets (hull, record, help, summary, …)

| Key | Does |
|---|---|
| `←/→` | columns |
| `Esc` | close |
| `type` | any other key closes |

### Raise a company · hulls

| Key | Does |
|---|---|
| `[ ]` | lance |
| `b` | take the hull under the cursor (Enter does the same) |
| `p` | pass on a board listing |
| `n` | support train |

### Raise a company · support train

| Key | Does |
|---|---|
| `b` | buy a support hull (Enter does the same) |
| `n` | crews |

### Raise a company · crews

| Key | Does |
|---|---|
| `a` | crew from the halls |

### Soundtrack

| Key | Does |
|---|---|
| `m` | music on/off |
| `< >` | previous / next track |
| `+ -` | louder / quieter |
| `q` | close |

### Decision

| Key | Does |
|---|---|
| `1-9` | choose |

### Contract log

| Key | Does |
|---|---|
| `g` | start |
| `G` | end |
| `q` | close |

### After-action report

| Key | Does |
|---|---|
| `←/→` | columns |
| `Esc` | read |

### Emblem editor

| Key | Does |
|---|---|
| `arrows` | move |
| `Backspace` | erase |
| `u` | undo |
| `type` | paint the cell with the character typed |
| `Enter` | save as the outfit's crest |
| `Esc` | cancel |

### Number form

| Key | Does |
|---|---|
| `Tab j/k` | field |
| `+ -` | step |
| `0-9` | type |
| `Backspace` | erase |
| `Enter` | finish |
| `Esc` | cancel |

### Battle orders and settings

| Key | Does |
|---|---|
| `j/k` | row |
| `← →` | change |
| `Enter` | act |
| `Esc` | close |

### Settings shortcuts

| Key | Does |
|---|---|
| `m` | music |
| `+ -` | volume |
| `< >` | track |
| `t` | soundtracks |
| `d` | difficulty |
| `a` | auto-admit |

### End turn

| Key | Does |
|---|---|
| `n` | end the turn anyway |
| `N` | end 7 turns |
| `1-9` | go to that warning |
| `Esc` | not yet |

### Leave the campaign

| Key | Does |
|---|---|
| `s` | save and return |
| `r` | return without saving |
| `Esc` | stay in the campaign |

### Game over

| Key | Does |
|---|---|
| `Enter` | return to the welcome screen |

### Confirm (fire, sell, disband, recall)

| Key | Does |
|---|---|
| `y` | confirm |
| `s` | the second choice |
| `Esc` | keep |

### Text prompts and the command line

| Key | Does |
|---|---|
| `type` | type |
| `Backspace` | erase |
| `Tab` | complete a verb or an id (the command line) |
| `Enter` | confirm |
| `Esc` | cancel |

<!-- /keys -->

Money keys: Ledger `L` → `take_loan`, `R` → `repay_loan`; Forces `$` →
`sell_unit`, `X` → `disband_company`; HQ `$` → `sell_hq`. Turn rules the
client surfaces: urgent checklist items (untreated wounded, hungry or dry
companies, overdrawn treasuries, understaffed HQs, a contract running
combat-ineffective, decisions near deadline) are marked red but advisory —
the turn ends anyway; an **unread after-action** refuses with
`ReportUnread` and a multi-day advance stops on the day the battle lands,
dropping the player into its sheet; it also stops once on the day an
engagement's contact window opens, dropping the player into its battle
orders, and the next advance goes ahead; `advance` refuses with
`Insolvent` until a loan or sale covers it, and `Bankrupt` (game over
modal, campaign saved as it ended) once nothing could.

Modals: **End turn** (the checklist rows that prompt, with jump targets;
`n` ends the advance asked for — a day, a week from `N`, or `:day n` —
and `N` a week; it opens for every advance while a row prompts, and
`:day n force` skips it; Desk notes such as a hull waiting on a pilot in
the medbay stay on the Desk) ·
**Decision** (options with effects, default marked) ·
**Battle orders** (the situation and odds; ←/→ step the ROE and each
lance's role with the odds recomputed, Enter buys the emergency resupply,
recalls behind a confirm, or confirms the orders, which clears the
contact warning; `Esc` closes it with the current settings standing) ·
**Amount forms** (order, ship, sell, transfer, loan, policies: one to
three numbers held to their ranges; Enter builds a command line for the
shared parser, and a refusal shows as its sentence, never an error code).

## Queries the core exposes

Every screen reads a **query** in `src/sim/queries.zig`, shared by the REPL
and the TUI:

- `desk` (checklist warnings from `checklist.turnWarnings`; inbox;
  company postures; HQ summaries; log tail with filter)
- `map` (worlds with ring/beachhead/dark classification per HQ, offers per
  world, HQ and company markers)
- `toe` (tree with slot states), `hull`, `person`, `unassignedPool`
- `contracts` (board + active with objective/pool/VP/clock/exposure)
- `treasuries`, `pnl(entity, period)` (from `finance.summarize`),
  `ledger(entity, n)`
- `supplies` (sites with tons/capacity/burn/days, inbound), `demand`
- `hq` (facilities built/effective, projects, capacity/ceilings, bays,
  staff vs requirement, candidates)
- `lab(unit)` (from `meklab.validate` + `state.labItems`)

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
- **Widgets**: `Pane` (title, border, focus), `Table`
  (`sim/table.zig` holds the column names and rows of markup cells, the
  query never pads; `screen.table` sizes every column to its widest cell,
  pins the first, scrolls the rest with ←/→ and hints how many columns are
  hidden either side), `Tree` (the TO&E: lines, with hull rows padded to
  widths shared across the tree), `Bar` (tonnage/pool bars), `Form`,
  `Modal`, `Log`. Each widget draws from a view model struct, never from
  `GameState`. A pane too narrow for a table clips the column at its edge
  rather than dropping it, so nothing is silently missing.
- **Markup**: `table.Tokenizer` (`src/sim/table.zig`) is the one reader
  of `{x}…{/}` tags for drawing, measuring and wrapping; `{{` is a literal
  brace. Free text — names, callsigns, log lines, filenames — enters
  markup escaped (`MarkupBuilder.appendPlain`), and controls and invalid
  UTF-8 draw as `?` and U+FFFD.
- **Colors** are semantic only — amber (attention/active), green (ok),
  red (critical), cyan (cursor/focus), dim (chrome) — on the terminal's own
  background, so the client holds on any theme.

## Boundary rules

The TUI's boundary with the core is a contract rule, not a TUI one:
[`docs/coding-contract.md`](coding-contract.md) sections 1, 4 and 5 state
what a screen may call, how screens and widgets are structured, and the
greps a reviewer runs. Two notes that are specific to this client and
not rules:

- The CLI remains the scripting/debug interface; both frontends run the
  same golden-master scripts.
- **Glyph set** is ASCII plus box-drawing and block elements only; `--ascii`
  swaps those for `+ - |` and `# .` on terminals that render them
  double-width. Emblem art is plain ASCII by construction.

## Smoke tests

`python3 docs/tui_smoke.py zig-out/bin/game /tmp/smoke.db` drives the
binary through a pty (create player → wizard → begin → every screen → end
turn → `:day 3` → save & return), asserts on landmarks, and runs a second
pass at 80 × 24 with `--ascii`. The REPL has its own:
`docs/repl_smoke.sh zig-out/bin/game /tmp/repl.db`. Both run after any
change under `src/tui/`, `cli.zig`, `queries.zig` or `src/main.zig`,
alongside `zig build test`.
