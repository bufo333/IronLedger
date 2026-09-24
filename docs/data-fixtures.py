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
