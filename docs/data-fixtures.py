#!/usr/bin/env python3
"""Invalid-overlay fixtures (docs/coding-contract.md rule 58): each case
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
    ("a catalogue mek with an illegal loadout", lambda: {"chassis.zon": mutate("chassis.zon", r'("LCT-1V".*?)\.slot = "la\.mg\.1", \.part = "mg"', r'\1.slot = "la.ac10.1", .part = "ac10"', re.S)}, True),
    ("skull bands out of order", lambda: {"tables/skulls.zon": mutate("tables/skulls.zon", r"\.min_ratio_bp = 13_750", ".min_ratio_bp = 16_000")}, True),
    ("an empty skull table", lambda: {"tables/skulls.zon": mutate("tables/skulls.zon", r"\.bands = \.\{.*?\n    \},", ".bands = .{},", re.S)}, True),
    ("hull-condition rolls out of order", lambda: {"tables/tuning.zon": mutate("tables/tuning.zon", r"\.cond_used_roll = 7,", ".cond_used_roll = 11,")}, True),
    ("a percentage over 100", lambda: {"tables/tuning.zon": mutate("tables/tuning.zon", r"\.advance_pct = 25,", ".advance_pct = 120,")}, True),
    ("an arc with an unknown contract kind", lambda: {"tables/arcs.zon": mutate("tables/arcs.zon", r'"garrison_duty"', '"__bad_kind__"')}, True),
    ("an operation template with an unknown arc key", lambda: {"tables/operations.zon": mutate("tables/operations.zon", r'\.arc_key = "fracturing_garrison"', '.arc_key = "__bad_arc__"')}, True),
    ("a min_clock==0 finale marked ends_contract=true is rejected (P4h invariant)", lambda: {"tables/arcs.zon": mutate("tables/arcs.zon", r'\.key = "held",\n\s+\.name = "Garrison Holds",\n\s+\.min_clock = 0,\s*// unconditional fallback\n\s+\.ends_contract = false,', '.key = "held",\n            .name = "Garrison Holds",\n            .min_clock = 0, // unconditional fallback\n            .ends_contract = true,', re.S)}, True),
    ("an actor archetype referencing an unknown arc key (P4i)", lambda: {"tables/actor_archetypes.zon": mutate("tables/actor_archetypes.zon", r'"fracturing_garrison"', '"__no_such_arc__"')}, True),
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
