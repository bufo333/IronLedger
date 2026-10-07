#!/usr/bin/env python3
"""Build and validate deterministic IRON LEDGER release archives."""

import argparse
import hashlib
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import tempfile
import urllib.request
import zipfile


SQLITE_URL = "https://www.sqlite.org/2026/sqlite-dll-win-x64-3530400.zip"
SQLITE_SHA3_256 = "deddee963c810d1eeac3ce5e15c7c41da21a1c54d7a39cf54fbf577d2f50de3a"
SQLITE_MEMBERS = frozenset({"sqlite3.dll", "sqlite3.def"})
NOTICE_FILES = ("LICENSE", "ASSETS.md", "THIRD-PARTY-NOTICES.md")
MUSIC_SET_DIRECTORIES = frozenset({"OST", "OST Part 2", "Supplimental Music"})
MUSIC_SUFFIXES = frozenset({".aac", ".m4a"})
TARGETS = {
    "macos-x64": "game",
    "linux-x64": "game",
    "windows-x64": "game.exe",
}
ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)


def fail(message):
    raise SystemExit(f"package_release.py: {message}")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha3_256(path):
    digest = hashlib.sha3_256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_zip_member(name):
    path = PurePosixPath(name)
    if "\\" in name or path.is_absolute() or len(path.parts) != 1 or path.name in ("", ".", ".."):
        fail(f"unsafe SQLite archive member: {name!r}")


def verified_sqlite_members(archive):
    archive = Path(archive)
    if not archive.is_file():
        fail(f"SQLite archive is not a file: {archive}")
    if sha3_256(archive) != SQLITE_SHA3_256:
        fail("SQLite archive SHA3-256 mismatch")
    try:
        with zipfile.ZipFile(archive) as bundle:
            members = bundle.infolist()
            names = set()
            for member in members:
                safe_zip_member(member.filename)
                if stat.S_ISLNK(member.external_attr >> 16):
                    fail(f"SQLite archive contains a symlink: {member.filename}")
                if member.filename in names:
                    fail(f"SQLite archive contains a duplicate member: {member.filename}")
                names.add(member.filename)
            if names != SQLITE_MEMBERS:
                fail(f"unexpected SQLite archive members: {sorted(names)!r}")
            return {member.filename: bundle.read(member) for member in members}
    except zipfile.BadZipFile as error:
        fail(f"invalid SQLite archive: {error}")


def extract_verified_sqlite(archive, destination):
    members = verified_sqlite_members(archive)
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    for name, content in members.items():
        path = destination / name
        path.write_bytes(content)
    return destination


def prepare_windows_sqlite(archive, output, lib_exe):
    output = extract_verified_sqlite(archive, output)
    import_library = output / "sqlite3.lib"
    subprocess.run(
        [str(lib_exe), f"/def:{output / 'sqlite3.def'}", "/machine:x64", f"/out:{import_library}"],
        check=True,
    )
    if not import_library.is_file():
        fail("lib.exe did not produce sqlite3.lib")
    print(output)


def logo_names(source_root):
    logos = sorted((source_root / "data" / "logos").glob("*.png"))
    if not logos:
        fail("no committed logo files found")
    return logos


def regular_file(path, description):
    if not path.is_file() or path.is_symlink():
        fail(f"{description} must be a regular file: {path}")


def expected_entries(source_root, target):
    executable = TARGETS[target]
    entries = {f"bin/{executable}"}
    if target == "windows-x64":
        entries.add("bin/sqlite3.dll")
    entries.update(f"share/iron-ledger/logos/{logo.name}" for logo in logo_names(source_root))
    entries.update(NOTICE_FILES)
    return entries


def staged_entries(prefix, source_root, target):
    prefix = Path(prefix)
    source_root = Path(source_root)
    if not prefix.is_dir():
        fail(f"staged prefix is not a directory: {prefix}")
    entries = {}
    for path in prefix.rglob("*"):
        if path.is_symlink():
            fail(f"staged prefix contains a symlink: {path}")
        if path.is_file():
            entries[path.relative_to(prefix).as_posix()] = path
    for notice in NOTICE_FILES:
        source = source_root / notice
        regular_file(source, notice)
        entries[notice] = source
    return entries


def validate_entries(entries, source_root, target):
    expected = expected_entries(source_root, target)
    actual = set(entries)
    forbidden = [name for name in actual if (
        name.startswith("data/music/")
        or name.startswith("share/iron-ledger/music/")
        or name.startswith(".zig-cache/")
        or name.startswith("zig-cache/")
        or name.startswith("src/")
        or name.startswith("data/")
        or name == ".DS_Store"
        or name.endswith("/.DS_Store")
        or name.endswith(".db")
    )]
    if forbidden:
        fail(f"forbidden staged package entries: {sorted(forbidden)!r}")
    if actual != expected:
        missing = sorted(expected - actual)
        unexpected = sorted(actual - expected)
        fail(f"invalid staged package layout; missing={missing!r}, unexpected={unexpected!r}")
    for name, path in entries.items():
        regular_file(path, name)
    executable = TARGETS[target]
    bin_entries = [name for name in actual if name.startswith("bin/") and name.endswith((".exe", "game"))]
    if bin_entries != [f"bin/{executable}"]:
        fail(f"expected exactly bin/{executable}, found executables {bin_entries!r}")


def deterministic_zip(entries, archive):
    archive.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as bundle:
        for name in sorted(entries):
            info = zipfile.ZipInfo(name, ZIP_TIMESTAMP)
            info.create_system = 3
            info.external_attr = ((stat.S_IFREG | (0o755 if name.startswith("bin/") else 0o644)) << 16)
            bundle.writestr(info, entries[name].read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)


def expected_music_entries(source_root):
    source_root = Path(source_root)
    music_root = source_root / "data" / "music"
    if not music_root.is_dir():
        fail(f"soundtrack directory is not a directory: {music_root}")
    entries = {}
    for path in music_root.rglob("*"):
        if path.is_symlink():
            fail(f"soundtrack directory contains a symlink: {path}")
        if path.is_dir():
            continue
        if path.name == ".DS_Store":
            continue
        if not path.is_file() or path.suffix.lower() not in MUSIC_SUFFIXES:
            fail(f"unexpected soundtrack source file: {path}")
        relative = path.relative_to(music_root)
        if relative.parts[0] not in MUSIC_SET_DIRECTORIES:
            fail(f"soundtrack file is outside an approved set directory: {path}")
        entries[f"share/iron-ledger/music/{relative.as_posix()}"] = path
    if not entries:
        fail("no soundtrack files found")
    assets = source_root / "ASSETS.md"
    regular_file(assets, "ASSETS.md")
    entries["ASSETS.md"] = assets
    return entries


def validate_music_archive(archive, version, source_root):
    expected = expected_music_entries(source_root)
    try:
        with zipfile.ZipFile(archive) as bundle:
            entries = bundle.infolist()
            names = set()
            for entry in entries:
                path = PurePosixPath(entry.filename)
                if entry.is_dir() or path.is_absolute() or "\\" in entry.filename or ".." in path.parts:
                    fail(f"unsafe music archive member: {entry.filename!r}")
                if stat.S_ISLNK(entry.external_attr >> 16):
                    fail(f"music archive contains a symlink: {entry.filename}")
                if entry.filename in names:
                    fail(f"music archive contains a duplicate member: {entry.filename}")
                if entry.date_time != ZIP_TIMESTAMP or (entry.external_attr >> 16 & 0o777) != 0o644:
                    fail(f"music archive has non-deterministic metadata: {entry.filename}")
                names.add(entry.filename)
            if [entry.filename for entry in entries] != sorted(names):
                fail("music archive entries are not in lexical order")
            if names != set(expected):
                fail(f"invalid music archive layout; missing={sorted(set(expected) - names)!r}, unexpected={sorted(names - set(expected))!r}")
            for name, source in expected.items():
                if bundle.read(name) != source.read_bytes():
                    fail(f"music archive member does not match source: {name}")
    except zipfile.BadZipFile as error:
        fail(f"invalid music archive: {error}")
    expected_name = f"iron-ledger-{version}-music.zip"
    if Path(archive).name != expected_name:
        fail(f"archive name must be {expected_name}")


def package_music(version, output, source_root):
    entries = expected_music_entries(source_root)
    archive = Path(output) / f"iron-ledger-{version}-music.zip"
    deterministic_zip(entries, archive)
    validate_music_archive(archive, version, source_root)
    print(f"SHA256 {sha256(archive)}  {archive.name}")


def expect_music_validation_failure(action):
    try:
        action()
    except SystemExit:
        return
    fail("music validation unexpectedly accepted a malformed archive")


def test_music_package(source_root):
    expected_music_entries(source_root)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        fixture = root / "source"
        tracks = fixture / "data" / "music"
        for set_name, file_name in (("OST", "one.m4a"), ("OST Part 2", "two.m4a"), ("Supplimental Music", "three.aac")):
            directory = tracks / set_name
            directory.mkdir(parents=True, exist_ok=True)
            (directory / file_name).write_bytes(file_name.encode("ascii"))
        (tracks / ".DS_Store").write_bytes(b"metadata")
        (fixture / "ASSETS.md").write_text("asset notice\n", encoding="utf-8")
        archive = root / "iron-ledger-1.0.0-music.zip"
        package_music("1.0.0", root, fixture)
        validate_music_archive(archive, "1.0.0", fixture)

        altered_track = tracks / "OST" / "one.m4a"
        altered_track.write_bytes(b"altered")
        expect_music_validation_failure(lambda: validate_music_archive(archive, "1.0.0", fixture))
        altered_track.write_bytes(b"one.m4a")

        assets = fixture / "ASSETS.md"
        assets.write_text("changed notice\n", encoding="utf-8")
        expect_music_validation_failure(lambda: validate_music_archive(archive, "1.0.0", fixture))
        assets.write_text("asset notice\n", encoding="utf-8")

        entries = expected_music_entries(fixture)
        missing = root / "iron-ledger-1.0.0-music.zip"
        without_track = dict(entries)
        del without_track["share/iron-ledger/music/OST/one.m4a"]
        deterministic_zip(without_track, missing)
        expect_music_validation_failure(lambda: validate_music_archive(missing, "1.0.0", fixture))

        extra = root / "iron-ledger-1.0.0-music.zip"
        unexpected = root / "unexpected.aac"
        unexpected.write_bytes(b"unexpected")
        with_extra = dict(entries)
        with_extra["share/iron-ledger/music/OST/unexpected.aac"] = unexpected
        deterministic_zip(with_extra, extra)
        expect_music_validation_failure(lambda: validate_music_archive(extra, "1.0.0", fixture))

        unsafe = root / "iron-ledger-1.0.0-music.zip"
        deterministic_zip(entries, unsafe)
        with zipfile.ZipFile(unsafe, "a", compression=zipfile.ZIP_DEFLATED) as bundle:
            info = zipfile.ZipInfo("share/iron-ledger/music/OST/link.m4a", ZIP_TIMESTAMP)
            info.create_system = 3
            info.external_attr = ((stat.S_IFLNK | 0o777) << 16)
            bundle.writestr(info, b"target")
        expect_music_validation_failure(lambda: validate_music_archive(unsafe, "1.0.0", fixture))

        wrong_name = root / "wrong-name.zip"
        deterministic_zip(entries, wrong_name)
        expect_music_validation_failure(lambda: validate_music_archive(wrong_name, "1.0.0", fixture))
    print("music package tests OK")


def validate_archive(archive, version, target, source_root):
    expected = expected_entries(source_root, target)
    try:
        with zipfile.ZipFile(archive) as bundle:
            entries = bundle.infolist()
            names = set()
            for entry in entries:
                path = PurePosixPath(entry.filename)
                if entry.is_dir() or path.is_absolute() or "\\" in entry.filename or ".." in path.parts:
                    fail(f"unsafe release archive member: {entry.filename!r}")
                if stat.S_ISLNK(entry.external_attr >> 16):
                    fail(f"release archive contains a symlink: {entry.filename}")
                if entry.filename in names:
                    fail(f"release archive contains a duplicate member: {entry.filename}")
                expected_mode = 0o755 if entry.filename.startswith("bin/") else 0o644
                if entry.date_time != ZIP_TIMESTAMP or (entry.external_attr >> 16 & 0o777) != expected_mode:
                    fail(f"release archive has non-deterministic metadata: {entry.filename}")
                names.add(entry.filename)
            if [entry.filename for entry in entries] != sorted(names):
                fail("release archive entries are not in lexical order")
            if names != expected:
                fail(f"invalid release archive layout; missing={sorted(expected - names)!r}, unexpected={sorted(names - expected)!r}")
    except zipfile.BadZipFile as error:
        fail(f"invalid release archive: {error}")
    expected_name = f"iron-ledger-{version}-{target}.zip"
    if Path(archive).name != expected_name:
        fail(f"archive name must be {expected_name}")


def package(prefix, version, target, output, source_root, sqlite_archive):
    if target not in TARGETS:
        fail(f"unsupported target label: {target}")
    source_root = Path(source_root)
    sqlite_members = None
    if target == "windows-x64":
        if sqlite_archive is None:
            fail("Windows packaging requires --sqlite-archive")
        sqlite_members = verified_sqlite_members(sqlite_archive)
    elif sqlite_archive is not None:
        fail("only Windows packaging accepts --sqlite-archive")
    entries = staged_entries(prefix, source_root, target)
    validate_entries(entries, source_root, target)
    if sqlite_members is not None and entries["bin/sqlite3.dll"].read_bytes() != sqlite_members["sqlite3.dll"]:
        fail("staged sqlite3.dll does not match the verified SQLite archive")
    archive = Path(output) / f"iron-ledger-{version}-{target}.zip"
    deterministic_zip(entries, archive)
    validate_archive(archive, version, target, Path(source_root))
    print(f"SHA256 {sha256(archive)}  {archive.name}")


def download_sqlite(output):
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with urllib.request.urlopen(SQLITE_URL) as response, output.open("wb") as stream:
            shutil.copyfileobj(response, stream)
    except OSError as error:
        fail(f"SQLite download failed: {error}")
    verified_sqlite_members(output)


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)

    download = commands.add_parser("download-windows-sqlite")
    download.add_argument("--output", required=True)

    verify = commands.add_parser("verify-windows-sqlite")
    verify.add_argument("--sqlite-archive", required=True)

    prepare = commands.add_parser("prepare-windows-sqlite")
    prepare.add_argument("--sqlite-archive", required=True)
    prepare.add_argument("--output", required=True)
    prepare.add_argument("--lib-exe", required=True)

    pack = commands.add_parser("package")
    pack.add_argument("--prefix", required=True)
    pack.add_argument("--version", required=True)
    pack.add_argument("--target", required=True, choices=sorted(TARGETS))
    pack.add_argument("--output", required=True)
    pack.add_argument("--source-root", required=True)
    pack.add_argument("--sqlite-archive")

    validate = commands.add_parser("validate")
    validate.add_argument("--archive", required=True)
    validate.add_argument("--version", required=True)
    validate.add_argument("--target", required=True, choices=sorted(TARGETS))
    validate.add_argument("--source-root", required=True)

    package_music_parser = commands.add_parser("package-music")
    package_music_parser.add_argument("--version", required=True)
    package_music_parser.add_argument("--output", required=True)
    package_music_parser.add_argument("--source-root", required=True)

    validate_music = commands.add_parser("validate-music")
    validate_music.add_argument("--archive", required=True)
    validate_music.add_argument("--version", required=True)
    validate_music.add_argument("--source-root", required=True)

    test_music = commands.add_parser("test-music")
    test_music.add_argument("--source-root", required=True)

    args = parser.parse_args()
    if args.command == "download-windows-sqlite":
        download_sqlite(args.output)
    elif args.command == "verify-windows-sqlite":
        verified_sqlite_members(args.sqlite_archive)
    elif args.command == "prepare-windows-sqlite":
        prepare_windows_sqlite(args.sqlite_archive, args.output, args.lib_exe)
    elif args.command == "package":
        package(args.prefix, args.version, args.target, args.output, args.source_root, args.sqlite_archive)
    elif args.command == "validate":
        validate_archive(Path(args.archive), args.version, args.target, Path(args.source_root))
    elif args.command == "package-music":
        package_music(args.version, args.output, args.source_root)
    elif args.command == "validate-music":
        validate_music_archive(Path(args.archive), args.version, Path(args.source_root))
    else:
        test_music_package(args.source_root)


if __name__ == "__main__":
    main()
