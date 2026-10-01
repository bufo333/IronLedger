# MekLab location-layout design note

Status: design spitball — not yet scheduled. Candidate feature for P3d
(construction editor and variant lifecycle). Not a committed deliverable.

## Problem

The current MekLab (`src/tui/screens/lab.zig`) shows a budget summary, a
crits-remaining table, and a mounts list. A player cannot see *where* things
are, which slots are occupied by fixed structure, or how the mech's physical
shape constrains the build. Two very different chassis (a Catapult and a
Marauder) look identical in the current view.

## Goal

Replace or supplement the crits table with a per-location slot layout that
renders the chassis's actual structure: fixed occupants, installed weapons,
and free slots — arranged spatially so the chassis reads as a machine, not a
spreadsheet.

## Design

The layout would be data-driven from `chassis.zon`, but requires two
additions not present today: per-location critical slot counts (currently
`meklab.zig` applies uniform standard-rules values via `freeCrits`) and
per-chassis actuator and fixed-occupant configuration (cockpit, engine,
gyro, actuators). No per-chassis artwork is needed; the structural
differences render themselves once that data exists.

### Location arrangement (7 locations, classic BT)

```
              ┌─── HEAD ────┐
              └─────────────┘
   ┌──── LT ─────┐┌──── CT ─────┐┌──── RT ─────┐
   └─────────────┘└─────────────┘└─────────────┘
   ┌──── LA ──┐                  ┌──── RA ──┐
   └──────────┘                  └──────────┘
   ┌──── LL ──┐                  ┌──── RL ──┐
   └──────────┘                  └──────────┘
```

Arm boxes are narrower than torso boxes (fewer slots). Locations with no
lower arm / hand actuators show an annotation and have visibly fewer rows.

### Slot representation (one row per critical slot)

Each slot shows:

| Marker | Meaning           | TUI colour  |
|--------|-------------------|-------------|
| `■`    | Fixed/structural  | dim grey    |
| `M`    | Missile weapon    | cyan        |
| `E`    | Energy weapon     | amber       |
| `B`    | Ballistic weapon  | red         |
| `Q`    | Equipment         | green       |
| `·`    | Free slot         | dim         |

Multi-slot items (e.g. LRM-20 takes 5 slots) are shown as one named group
with a part counter (`LRM-20 1/5 … 5/5`) so removing the item frees all
slots at once.

The existing `src/domain/meklab.zig` enforces a jump-jet location rule
(torsos and legs only). P3d would add CASE (side torso only) and AMS
(head/torso only) placement rules to match the same owner pattern. The
layout would visualise these constraints: attempting to place CASE in a
leg shows the refusal inline with the violated rule named.

### Catapult CPLT-C1 example (approximate — driven by chassis.zon)

```
CATAPULT CPLT-C1  65t  ▓▓▓▓▓▓▓▓▓▓▓▓░░ armor

Slot key:  ■ fixed  M missile  E energy  B ballistic  Q equip  · free

              ┌─── HEAD ────┐
              │ ■ cockpit   │
              │ ■ sensors   │
              │ ■ life spt  │
              │ ■ life spt  │
              │ · ──────────│
              │ · ──────────│
              └─────────────┘
   ┌──── LT ─────┐┌──── CT ─────┐┌──── RT ─────┐
   │ M LRM-20 1/5││ ■ engine    ││ M LRM-20 1/5│
   │ M LRM-20 2/5││ ■ engine    ││ M LRM-20 2/5│
   │ M LRM-20 3/5││ ■ engine    ││ M LRM-20 3/5│
   │ M LRM-20 4/5││ ■ gyro      ││ M LRM-20 4/5│
   │ M LRM-20 5/5││ ■ gyro      ││ M LRM-20 5/5│
   │ M ammo LRM  ││ ■ gyro      ││ M ammo LRM  │
   │ M ammo LRM  ││ ■ gyro      ││ M ammo LRM  │
   │ Q CASE      ││ ■ engine    ││ Q CASE      │
   │ · ──────────││ ■ engine    ││ · ──────────│
   │ · ──────────││ ■ engine    ││ · ──────────│
   │ · ──────────││ · ──────────││ · ──────────│
   │ · ──────────││ · ──────────││ · ──────────│
   └─────────────┘└─────────────┘└─────────────┘
   ┌──── LA ──┐                  ┌──── RA ──┐
   │ ■ shldr  │                  │ ■ shldr  │
   │ ■ u.arm  │                  │ ■ u.arm  │
   │ E med.las│                  │ E med.las│
   │ E med.las│                  │ E med.las│
   │ · ───────│  no lower arm /  │ · ───────│
   │ · ───────│   no hand act.   │ · ───────│
   └──────────┘                  └──────────┘
   ┌──── LL ──┐                  ┌──── RL ──┐
   │ ■ hip    │                  │ ■ hip    │
   │ ■ u.leg  │                  │ ■ u.leg  │
   │ ■ l.leg  │                  │ ■ l.leg  │
   │ ■ foot   │                  │ ■ foot   │
   │ · ───────│                  │ · ───────│
   │ · ───────│                  │ · ───────│
   └──────────┘                  └──────────┘

Budget: 65.0t  used 64.5t  free 0.5t
Refit class: C   Bay ceiling: regional (≥ 2)   Verdict: LEGAL
```

The Catapult's character reads immediately: arm boxes are small and mostly
fixed, the torsos are packed with missile slots. An Atlas or Marauder would
have full 12-slot arm boxes with all four actuators and room for large
weapons.

### What the layout communicates that the current view does not

- **Chassis identity** — short arms vs. full arms; dense CT vs. sparse CT.
- **CASE placement** — visible beside the ammo it protects; rules block it
  elsewhere and name the violated rule.
- **Multi-slot weapon grouping** — remove one item, all N slots free at once.
- **Location rules** — JJ slots greyed out if legs are full; AMS only legal
  in head/torso shown by context.

### Interaction model (P3d scope)

Cursor navigates location-by-location. Enter on a free slot opens the parts
picker filtered to what fits (weight remaining, crits remaining, location
rules). The picker shows the slot-type colour of each candidate so the player
can see at a glance what a choice adds. Conflict with a location rule is
refused inline with the rule name, not a silent no-op.

## Dependency on P3a–P3c

The read-only layout (showing the current loadout in location boxes) can ship
earlier as a pure TUI improvement, but needs new `chassis.zon` fields
(fixed-occupant layout and per-chassis actuator configuration) before it can
render chassis-specific slot arrangements. The interactive, editable version
(P3d) depends on P3a (editable construction parts with verified mass/crit
data from TechManual), P3b (full A–F refit class support), and P3c (persisted
campaign-owned custom chassis), because interactive variant editing requires
variant persistence.

The layout question is essentially P3d's entire UX question; this note is
the design input for that deliverable.

## Classic BT vs. hardpoints note

This game uses classic BattleTech rules (CamOps): any weapon may go in any
location within crit/tonnage limits. The Catapult's arms feel restricted
because fixed actuators consume most of the available slots, not because
of a hardpoint type gate. The layout makes that structural reality visible
without inventing a hardpoint rule that doesn't exist in the source.
