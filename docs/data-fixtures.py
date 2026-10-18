#!/usr/bin/env python3
"""Invalid-overlay fixtures (docs/engineering-contract.md rule 58): each case
builds `zig build validate-data -Ddata=<dir>` against a mod made from the
stock table with one deliberate defect, and must fail. A control overlay
(an unchanged stock table) must pass, so a failure is the data's, not the
machine's. The defects are made from the current stock files at run time,
so the fixtures cannot drift from the tables; a mutation that no longer
applies is itself a failure.

    python3 docs/data-fixtures.py [extra zig build arguments, e.g. -Dcpu=baseline]
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))


def mutate(rel, pattern, repl, flags=0):
    """The stock file `rel` with exactly one match of `pattern` replaced."""
    text = open(os.path.join(ROOT, "data", rel), encoding="utf-8").read()
    out, n = re.subn(pattern, repl, text, count=1, flags=flags)
    if n != 1 or out == text:
        raise SystemExit(f"fixture mutation no longer applies to data/{rel}: {pattern!r}")
    return out


def mutate_all(rel, pattern, repl):
    """The stock file `rel` with every match of `pattern` (at least one) replaced."""
    text = open(os.path.join(ROOT, "data", rel), encoding="utf-8").read()
    out, n = re.subn(pattern, repl, text)
    if n == 0 or out == text:
        raise SystemExit(f"fixture mutation no longer applies to data/{rel}: {pattern!r}")
    return out


def stock(rel):
    return open(os.path.join(ROOT, "data", rel), encoding="utf-8").read()


# (name, {relative path: contents} or None for a missing directory, must_fail)
CASES = [
    ("control: an unchanged stock table", lambda: {"tables/tuning.zon": stock("tables/tuning.zon")}, False),
    ("-Ddata names a missing directory", lambda: None, True),
    ("-Ddata overlays no data file", lambda: {}, True),
    ("rank ladder one row short", lambda: {"tables/ranks.zon": mutate("tables/ranks.zon", r'\n[^\n]*"colonel"[^\n]*', "")}, True),
    ("rank ladder out of enum order", lambda: {"tables/ranks.zon": mutate("tables/ranks.zon", r'\.key = "major"', '.key = "colonel_"').replace('.key = "colonel"', '.key = "major"').replace('.key = "colonel_"', '.key = "colonel"')}, True),
    ("an empty name pool", lambda: {"tables/names.zon": mutate("tables/names.zon", r"\.first = \.\{.*?\},", ".first = .{},", re.S)}, True),
    ("control: an unchanged name table", lambda: {"tables/names.zon": stock("tables/names.zon")}, False),
    ("a repeated first name, pool size unchanged", lambda: {"tables/names.zon": mutate("tables/names.zon", r'"Aiko"', '"Adam"')}, True),
    ("an empty last name, pool size unchanged", lambda: {"tables/names.zon": mutate("tables/names.zon", r'"Baxter"', '""')}, True),
    ("a catalogue mek with an illegal loadout", lambda: {"chassis.zon": mutate("chassis.zon", r'("LCT-1V".*?)\.slot = "la\.mg\.1", \.part = "mg"', r'\1.slot = "la.ac10.1", .part = "ac10"', re.S)}, True),
    ("skull bands out of order", lambda: {"tables/skulls.zon": mutate("tables/skulls.zon", r"\.min_ratio_bp = 13_750", ".min_ratio_bp = 16_000")}, True),
    ("an empty skull table", lambda: {"tables/skulls.zon": mutate("tables/skulls.zon", r"\.bands = \.\{.*?\n    \},", ".bands = .{},", re.S)}, True),
    ("hull-condition rolls out of order", lambda: {"tables/tuning.zon": mutate("tables/tuning.zon", r"\.cond_used_roll = 7,", ".cond_used_roll = 11,")}, True),
    ("a reserve commitment beyond the 2d6 span (decisive-roll overflow)", lambda: {"tables/tuning.zon": mutate("tables/tuning.zon", r"\.commit_roll = 2 \}", ".commit_roll = 2147483647 }")}, True),
    ("a percentage over 100", lambda: {"tables/tuning.zon": mutate("tables/tuning.zon", r"\.advance_pct = 25,", ".advance_pct = 120,")}, True),
    ("an arc with an unknown contract kind", lambda: {"tables/arcs.zon": mutate("tables/arcs.zon", r'"garrison_duty"', '"__bad_kind__"')}, True),
    ("an operation template with an unknown arc key", lambda: {"tables/operations.zon": mutate("tables/operations.zon", r'\.arc_key = "fracturing_garrison"', '.arc_key = "__bad_arc__"')}, True),
    ("a min_clock==0 finale marked ends_contract=true is rejected (P4h invariant)", lambda: {"tables/arcs.zon": mutate("tables/arcs.zon", r'\.key = "held",\n\s+\.name = "Garrison Holds",\n\s+\.min_clock = 0,\s*// unconditional fallback\n\s+\.ends_contract = false,', '.key = "held",\n            .name = "Garrison Holds",\n            .min_clock = 0, // unconditional fallback\n            .ends_contract = true,', re.S)}, True),
    ("an actor archetype referencing an unknown arc key (P4i)", lambda: {"tables/actor_archetypes.zon": mutate("tables/actor_archetypes.zon", r'"fracturing_garrison"', '"__no_such_arc__"')}, True),
    ("a situation option that costs nothing", lambda: {"tables/situations.zon": mutate("tables/situations.zon", r"\.costs = \.\{\.\{ \.morale = -2 \}\}", ".costs = .{.{ .morale = 2 }}")}, True),
    ("a situation cost outside the cost subset", lambda: {"tables/situations.zon": mutate("tables/situations.zon", r"\.\{ \.escalation = 3 \}", ".{ .xp_all = 3 }")}, True),
    ("a situation callback without its note", lambda: {"tables/situations.zon": mutate("tables/situations.zon", r'\n\s*\.callback_note = "[^"]*",', "")}, True),
    ("a situation option both buying from and informing on its owner", lambda: {"tables/situations.zon": mutate("tables/situations.zon", r"\.set_actor_flags = \.\{\.did_business\}", ".set_actor_flags = .{ .did_business, .informed_on }")}, True),
    ("a situation option leaving the black market both open and closed", lambda: {"tables/situations.zon": mutate("tables/situations.zon", r"\.set_world_flags = \.\{\.black_market_open\}", ".set_world_flags = .{ .black_market_open, .black_market_closed }")}, True),
    ("a situation leaving an unknown world flag", lambda: {"tables/situations.zon": mutate("tables/situations.zon", r"\.set_world_flags = \.\{\.militia_trained\}", ".set_world_flags = .{.__bad_flag__}")}, True),
    ("a situation owned by an archetype off its arc", lambda: {"tables/situations.zon": mutate("tables/situations.zon", r'\.owner = "militia_commander"', '.owner = "relief_liaison"')}, True),
    ("a situation from a beat its arc does not have", lambda: {"tables/situations.zon": mutate("tables/situations.zon", r'\.min_beat = "complication"', '.min_beat = "__no_such_beat__"')}, True),
    ("a finale gated on a world flag that is a collapse", lambda: {"tables/arcs.zon": mutate("tables/arcs.zon", r"\.requires_world_flag = \.militia_trained,", ".requires_world_flag = .militia_trained, .ends_contract = true,")}, True),
    ("a rival archetype referencing an unknown arc key (P4i)", lambda: {"tables/rival_archetypes.zon": mutate("tables/rival_archetypes.zon", r'"fracturing_garrison"', '"__no_such_arc__"')}, True),
    ("loc_rule bad tag on jump_jet (P3a)", lambda: {"parts.zon": mutate("parts.zon", r'\.loc_rule = \.torso_or_leg', ".loc_rule = .__bad_rule__")}, True),
    ("crit_slots out-of-range on LCT-1V (P3a)", lambda: {"chassis.zon": mutate("chassis.zon", r'(\.key = "LCT-1V".*?\.armor_half_tons = 8,)', r'\1 .crit_slots = .{ 1, 2, 12, 12, 8, 8, 2, 999 },', re.S)}, True),
    ("a manufacturing_chassis entry with an unknown chassis key (P3e.1)", lambda: {"tables/factions.zon": mutate("tables/factions.zon", r'"RFL-3N"', '"__bad_chassis__"')}, True),
    ("an invalid arm_actuators tag on CPLT-C1 (P3d)", lambda: {"chassis.zon": mutate("chassis.zon", r'\.left_arm_actuators = \.no_lower_arm', ".left_arm_actuators = .__bad_actuators__")}, True),
    ("a conventional chassis without source provenance", lambda: {"chassis.zon": mutate("chassis.zon", r'(\.key = "SCP-1N".*?\.source_path = )"[^"]+"', r'\1""', re.S)}, True),
    ("artillery construction with an unknown mounted item", lambda: {"artillery.zon": mutate("artillery.zon", r'\.key = "long_tom", \.count = 1', '.key = "__unknown__", .count = 1')}, True),
    ("artillery construction with a changed mount count", lambda: {"artillery.zon": mutate("artillery.zon", r'\.key = "long_tom_ammo", \.count = 4', '.key = "long_tom_ammo", .count = 3')}, True),
    ("artillery construction with a changed mount location", lambda: {"artillery.zon": mutate("artillery.zon", r'\.key = "machine_gun", \.count = 2, \.location = \.right', '.key = "machine_gun", .count = 2, .location = .rear')}, True),
    ("artillery construction with the wrong source path", lambda: {"artillery.zon": mutate("artillery.zon", r'(\.source_path = )"[^"]+"', r'\1"__wrong_path__"')}, True),
    ("artillery construction with the wrong source revision", lambda: {"artillery.zon": mutate("artillery.zon", r'(\.source_revision = )"[^"]+"', r'\1"__wrong_revision__"')}, True),
    ("a conventional chassis with the wrong source revision", lambda: {"chassis.zon": mutate("chassis.zon", r'(\.key = "SCP-1N".*?\.source_revision = )"[^"]+"', r'\1"__wrong_revision__"', re.S)}, True),
    ("an unaudited conventional chassis admitted to market", lambda: {"chassis.zon": mutate("chassis.zon", r'(\.key = "VDT".*?\.source_path = "[^"]+")', r'\1, .market_eligible = true', re.S)}, True),
    ("an approved conventional chassis quarantined from market", lambda: {"chassis.zon": mutate("chassis.zon", r'(\.key = "SCP-1N".*?\.market_eligible = )true', r'\1false', re.S)}, True),
    ("two merc bands with one key", lambda: {"tables/merc_bands.zon": mutate("tables/merc_bands.zon", r'\.key = "band_3"', '.key = "band_1_2"')}, True),
    ("an empty merc band table", lambda: {"tables/merc_bands.zon": mutate("tables/merc_bands.zon", r"\.bands = \.\{.*?\n    \},", ".bands = .{},", re.S)}, True),
    ("a merc band with no line lances", lambda: {"tables/merc_bands.zon": mutate("tables/merc_bands.zon", r"\.line_lances = \d+,", ".line_lances = 0,")}, True),
    ("a merc band founded with no capital", lambda: {"tables/merc_bands.zon": mutate("tables/merc_bands.zon", r"\.capital_cbills = [\d_]+,", ".capital_cbills = 0,")}, True),
    ("merc bands that seed no company", lambda: {"tables/merc_bands.zon": mutate_all("tables/merc_bands.zon", r"\.seed_companies = \d+,", ".seed_companies = 0,")}, True),
    ("control: an unchanged personage table", lambda: {"tables/personages.zon": stock("tables/personages.zon")}, False),
    ("two personages with one key", lambda: {"tables/personages.zon": mutate("tables/personages.zon", r'\.key = "katrina_steiner"', '.key = "hanse_davion"')}, True),
    ("a personage key that is a planet key", lambda: {"tables/personages.zon": mutate("tables/personages.zon", r'\.key = "melissa_steiner"', '.key = "tharkad"')}, True),
    ("a personage of an unknown faction", lambda: {"tables/personages.zon": mutate("tables/personages.zon", r'\.faction_key = "TC"', '.faction_key = "XX"')}, True),
    ("a personage on an unknown seat", lambda: {"tables/personages.zon": mutate("tables/personages.zon", r'\.seat_planet_key = "taurus"', '.seat_planet_key = "nowhere"')}, True),
    ("a personage of an unknown family", lambda: {"tables/personages.zon": mutate("tables/personages.zon", r'\.family_key = "steiner"', '.family_key = "nosuchfamily"')}, True),
    ("a ruler on another faction's world", lambda: {"tables/personages.zon": mutate("tables/personages.zon", r'(\.key = "candace_liao".*?\.seat_planet_key = )"st_ives"', r'\1"alkaid"')}, True),
    ("a leader off its faction's capital", lambda: {"tables/personages.zon": mutate("tables/personages.zon", r'(\.key = "hanse_davion".*?\.seat_planet_key = )"new_avalon"', r'\1"kathil"')}, True),
    ("two leaders of one faction in overlapping windows", lambda: {"tables/personages.zon": mutate("tables/personages.zon", r'(\.key = "brannoc_hale".*?)\.faction_key = "CIR", \.seat_planet_key = "circinus"', r'\1.faction_key = "FS", .seat_planet_key = "new_avalon"')}, True),
    ("a personage window not covering 3025", lambda: {"tables/personages.zon": mutate("tables/personages.zon", r"\.era_to_year = 3025", ".era_to_year = 3024")}, True),
    ("a personage with one motive", lambda: {"tables/personages.zon": mutate("tables/personages.zon", r"\.motives = \.\{ \.expansion, \.dynastic_security \}", ".motives = .{.expansion}")}, True),
    ("a personage ambition out of range", lambda: {"tables/personages.zon": mutate("tables/personages.zon", r"\.ambition = 85,", ".ambition = 101,")}, True),
    ("a personage with an empty title", lambda: {"tables/personages.zon": mutate("tables/personages.zon", r'\.title = "Duke of Summer"', '.title = ""')}, True),
    ("a personage name with markup", lambda: {"tables/personages.zon": mutate("tables/personages.zon", r'\.last_name = "Centrella"', '.last_name = "{c}Centrella"')}, True),
    ("a personage full name the name pools can draw", lambda: {"tables/personages.zon": mutate("tables/personages.zon", r'\.first_name = "Hanse"', '.first_name = "Adam"')}, True),
    ("control: an unchanged political event table", lambda: {"tables/political_events.zon": stock("tables/political_events.zon")}, False),
    ("two political events with one key", lambda: {"tables/political_events.zon": mutate("tables/political_events.zon", r'\.key = "industrial_seizure"', '.key = "border_grab"')}, True),
    ("a political event key that is not lowercase", lambda: {"tables/political_events.zon": mutate("tables/political_events.zon", r'\.key = "supply_raid"', '.key = "Supply_Raid"')}, True),
    ("a political event outside the opening family", lambda: {"tables/political_events.zon": mutate("tables/political_events.zon", r"\.family = \.opening", ".family = .beat")}, True),
    ("a political event with no instigator role", lambda: {"tables/political_events.zon": mutate("tables/political_events.zon", r"\.instigator_roles = \.\{\.planetary_ruler\}", ".instigator_roles = .{}")}, True),
    ("a political event with no motive", lambda: {"tables/political_events.zon": mutate("tables/political_events.zon", r"\.motives = \.\{\.profit\}", ".motives = .{}")}, True),
    ("a political event with an unknown motive", lambda: {"tables/political_events.zon": mutate("tables/political_events.zon", r"\.motives = \.\{\.profit\}", ".motives = .{.greed}")}, True),
    ("a political event with an unknown strike kind", lambda: {"tables/political_events.zon": mutate("tables/political_events.zon", r"\.strike_kind = \.recon_raid", ".strike_kind = .__bad_kind__")}, True),
    ("a political event with min_industry on a relation rule", lambda: {"tables/political_events.zon": mutate("tables/political_events.zon", r"(\.target = \.grudge_seat, )\.min_industry = 0", r"\1.min_industry = 3")}, True),
    ("a political event of zero weight", lambda: {"tables/political_events.zon": mutate("tables/political_events.zon", r"\.weight = 10,", ".weight = 0,")}, True),
    ("a political event with an empty name", lambda: {"tables/political_events.zon": mutate("tables/political_events.zon", r'\.name = "Supply raid"', '.name = ""')}, True),
    ("a political event name with markup", lambda: {"tables/political_events.zon": mutate("tables/political_events.zon", r'\.name = "Supply raid"', '.name = "{c}Supply raid"')}, True),
    ("a political event with an empty cause", lambda: {"tables/political_events.zon": mutate("tables/political_events.zon", r'\.cause = "\{instigator\} sends raiders to plunder \{world\}\."', '.cause = ""')}, True),
    ("a political event cause with markup", lambda: {"tables/political_events.zon": mutate("tables/political_events.zon", r"sends raiders", "sends {/}raiders")}, True),
    ("a political event cause with an unknown placeholder", lambda: {"tables/political_events.zon": mutate("tables/political_events.zon", r"plunder \{world\}", "plunder {planet}")}, True),
    ("an own_seat political event on the aggressor side", lambda: {"tables/political_events.zon": mutate("tables/political_events.zon", r"(\.target = \.own_seat, \.min_industry = 0, )\.instigator_side = \.defender", r"\1.instigator_side = .aggressor")}, True),
]


def run(files):
    base = tempfile.mkdtemp(prefix="iron-ledger-fixture-")
    try:
        mod = os.path.join(base, "mod")
        if files is not None:
            for rel, text in files.items():
                path = os.path.join(mod, rel)
                os.makedirs(os.path.dirname(path), exist_ok=True)
                open(path, "w", encoding="utf-8").write(text)
            os.makedirs(mod, exist_ok=True)
        proc = subprocess.run(
            ["zig", "build", "validate-data", f"-Ddata={mod}", *sys.argv[1:]],
            cwd=ROOT, capture_output=True, text=True, timeout=900,
        )
        return proc.returncode, proc.stderr
    finally:
        shutil.rmtree(base, ignore_errors=True)


def main():
    failed = 0
    for name, make, must_fail in CASES:
        code, err = run(make())
        ok = (code != 0) if must_fail else (code == 0)
        print(f"{'ok  ' if ok else 'FAIL'} {name}: build exit {code}")
        if not ok:
            failed += 1
            print(err[-2000:])
    if failed:
        print(f"{failed} data fixture(s) did not behave")
        return 1
    print("DATA FIXTURES OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
