# Releasing IRON LEDGER

## Version and tag

`build.zig.zon` is the product-version authority. A release tag must be exactly
`v` followed by that version. For version `1.0.0`, the tag is `v1.0.0` and the
release archives are:

- `iron-ledger-1.0.0-macos-arm64.zip`
- `iron-ledger-1.0.0-linux-x64.zip`
- `iron-ledger-1.0.0-windows-x64.zip`
- `iron-ledger-1.0.0-music.zip`

Campaign and SQLite store schema versions are independent persistence details,
not product release numbers.

## Core and music packages

Every core ZIP contains one native executable in `bin/`, all committed logo PNGs
in `share/iron-ledger/logos/`, and `LICENSE`, `ASSETS.md`, and
`THIRD-PARTY-NOTICES.md` at its root. It contains no music, source tree, build
cache, database, or symlink.

macOS and Linux builds link their host SQLite library. The Windows x64 package
contains `bin/sqlite3.dll` beside `game.exe`. SQLite 3.53.4 comes only from
<https://www.sqlite.org/2026/sqlite-dll-win-x64-3530400.zip>; packaging verifies
its SHA3-256 as
`deddee963c810d1eeac3ce5e15c7c41da21a1c54d7a39cf54fbf577d2f50de3a` before
extracting `sqlite3.dll` and `sqlite3.def`. The Windows import library is made
from that definition file by the native Visual Studio toolchain and is never
packaged. SQLite's deliverable code and documentation are public domain; see
<https://www.sqlite.org/copyright.html>.

Validate a downloaded archive using the `SHA256SUMS` release asset, for example:

```sh
shasum -a 256 -c SHA256SUMS
```

The platform-neutral music ZIP is an optional overlay. It contains only the
root `ASSETS.md` notice and the complete soundtrack below
`share/iron-ledger/music/`, retaining `OST/`, `OST Part 2/`, and
`Supplimental Music/`. Unpack it beside an unpacked core ZIP. It contains no
audio player, executable, SQLite component, source, save, or build cache. Music
playback uses an existing `afplay`, `mpv`, `ffplay`, or `aplay` command on
`PATH`; the game remains playable without music or a player.

The music archive is an approved redistribution under the project-only terms in
`ASSETS.md`. It preserves source track bytes, including watermark and metadata.
Core ZIPs remain music-free, and `data/music` remains excluded from
`build.zig.zon` and source-package construction. Developers with a full checkout
can instead build a local music-enabled tree:

```sh
zig build -Doptimize=ReleaseFast -Dbundle-music --prefix dist
```

## Local validation

On macOS or Linux, run the full local gate and make a native core archive:

```sh
zig fmt --check build.zig src
zig build test --summary all
./docs/verify-contract.sh
bash docs/clean-package.sh ReleaseFast
python3 docs/data-fixtures.py
python3 docs/tui_smoke.py zig-out/bin/game /tmp/iron-ledger-tui.db
bash docs/repl_smoke.sh zig-out/bin/game /tmp/iron-ledger-repl.db
zig build -Doptimize=ReleaseFast -Dcpu=baseline --prefix /tmp/iron-ledger-dist
python3 scripts/package_release.py package --prefix /tmp/iron-ledger-dist --version 1.0.0 --target macos-arm64 --output /tmp/iron-ledger-release --source-root .
python3 scripts/package_release.py validate --archive /tmp/iron-ledger-release/iron-ledger-1.0.0-macos-arm64.zip --version 1.0.0 --target macos-arm64 --source-root .
python3 scripts/package_release.py test-music --source-root .
python3 scripts/package_release.py package-music --version 1.0.0 --output /tmp/iron-ledger-release --source-root .
python3 scripts/package_release.py validate-music --archive /tmp/iron-ledger-release/iron-ledger-1.0.0-music.zip --version 1.0.0 --source-root .
```

Use `linux-x64` instead of `macos-arm64` on Linux. The macOS package is Apple Silicon (`aarch64-macos`) only. Windows CI performs its native
SQLite acquisition, import-library build, PowerShell smoke, and package
validation. It rejects a deliberately altered SQLite archive before extraction.

## GitHub Actions

`ci.yml` runs native read-only CI for pull requests and `main` on `macos-latest` (Apple Silicon),
`ubuntu-24.04`, and `windows-2022`. It installs Zig 0.16 from the official
metadata-verified download, runs the platform's gate and smoke harness, creates
a validated core ZIP, and retains it only as a CI artifact. Its separate Linux
music job builds and validates the platform-neutral music ZIP and checksum from
the version in `build.zig.zon`.

`release.yml` runs only for pushed `v*` tags. It verifies the tag/version match,
repeats the native release checks, builds the music archive independently, and
validates all four package artifacts and their checksums. It publishes the three
core ZIPs, the music ZIP, and one `SHA256SUMS` with the workflow token. A release
is serialized per tag without cancelling an in-progress publication.
