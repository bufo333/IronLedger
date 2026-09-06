# Learning Zig through IRON LEDGER

*Also available as a single-file HTML page: [iron-ledger-zig-guide.html](iron-ledger-zig-guide.html).*

A newcomer's guide to the Zig language, taught with the real code of a 29,000-line BattleTech mercenary-company simulator, and a tour of how that program is wired together from the build script to a keypress.

This document has two halves. Part I teaches Zig syntax from nothing, and every example is lifted from the project rather than invented, so you meet the language the way it is actually used. Part II walks through the program's design: how a pure simulation core, a data layer, a save system and a terminal client fit together, and why the boundaries sit where they do. You can read it straight through or jump around with the table of contents. Paths like `src/sim/rng.zig` are relative to the repository root.

> Zig version matters. This project is written for **Zig 0.16**, which changed the I/O model (see section 17). Older tutorials on the web often show `std.fs.cwd()` or `std.time.timestamp()`; those calls no longer exist in 0.16 and this guide shows the current forms.

## Contents

- [1. What Zig is and why this project uses it](#1-what-zig-is-and-why-this-project-uses-it)
- [2. The toolchain and build.zig](#2-the-toolchain-and-buildzig)
- [3. Files, imports, visibility](#3-files-imports-visibility)
- [4. Values, integers, casts](#4-values-integers-casts)
- [5. Structs and methods](#5-structs-and-methods)
- [6. Enums and typed IDs](#6-enums-and-typed-ids)
- [7. Tagged unions and switch](#7-tagged-unions-and-switch)
- [8. Optionals](#8-optionals)
- [9. Errors, try, catch, defer](#9-errors-try-catch-defer)
- [10. Arrays, slices, strings](#10-arrays-slices-strings)
- [11. Pointers](#11-pointers)
- [12. Loops and labeled blocks](#12-loops-and-labeled-blocks)
- [13. Memory: allocators and lists](#13-memory-allocators-and-lists)
- [14. comptime and reflection](#14-comptime-and-reflection)
- [15. Tests](#15-tests)
- [16. Talking to C](#16-talking-to-c)
- [17. Zig 0.16: std.Io](#17-zig-016-stdio)
- [18. The architecture in one picture](#18-the-architecture-in-one-picture)
- [19. Data: ZON files become typed tables](#19-data-zon-files-become-typed-tables)
- [20. GameState: one arena, one dice bag](#20-gamestate-one-arena-one-dice-bag)
- [21. Commands: the only way in](#21-commands-the-only-way-in)
- [22. The daily tick](#22-the-daily-tick)
- [23. Queries: the only way out](#23-queries-the-only-way-out)
- [24. Money without floats](#24-money-without-floats)
- [25. Battles and events](#25-battles-and-events)
- [26. Persistence: SQLite by hand](#26-persistence-sqlite-by-hand)
- [27. The terminal client](#27-the-terminal-client)
- [28. Determinism and the test suite](#28-determinism-and-the-test-suite)
- [29. One keypress, end to end](#29-one-keypress-end-to-end)
- [30. Where to go next](#30-where-to-go-next)

## 1. What Zig is and why this project uses it

Zig is a small systems language in the C tradition: manual memory management, no hidden control flow, no hidden allocations, and a compiler that can also build C. What makes it feel modern is that a lot of what other languages do with macros, generics or a runtime, Zig does with *compile-time code execution*: ordinary Zig functions that run while the program is being compiled.

IRON LEDGER leans on four Zig properties in particular:

- **No hidden allocation.** Every function that needs memory takes an allocator as a parameter. That makes it easy to keep the simulation core pure and to give the whole campaign one arena that is freed in a single call.

- **Compile-time data.** The game's tables (designs, planets, tuning knobs) are `.zon` files imported at compile time straight into typed structs. A wrong field is a build error, not a crash on turn 40.

- **Explicit errors.** A function that can fail says so in its type. You cannot forget to handle a failure; the compiler makes you either propagate it or deal with it.

- **C without bindings generators.** SQLite is called through eleven `extern fn` declarations written by hand. There is no dependency beyond the system library.

## 2. The toolchain and build.zig

There is one tool, `zig`. It compiles, tests, formats and runs. A project is described by `build.zig`, which is itself Zig code: a function that builds a graph of steps, which the build runner then executes. Here is the heart of this project's build script.

*build.zig (trimmed)*

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The simulation core as a module other code can import as "game".
    const mod = b.addModule("game", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Static game data: .zon files imported at comptime by the sim core.
    const data_dir = b.option([]const u8, "data", "Directory overlaying data/*.zon (mod support)");
    const DataFile = struct { import_name: []const u8, rel: []const u8 };
    const data_files = [_]DataFile{
        .{ .import_name = "chassis_zon", .rel = "chassis.zon" },
        .{ .import_name = "tuning_zon", .rel = "tables/tuning.zon" },
        // … eleven more
    };
    for (data_files) |f| {
        var path: std.Build.LazyPath = b.path(b.fmt("data/{s}", .{f.rel}));
        // (if -Ddata=<dir> names a file at the same relative path, use it instead)
        mod.addAnonymousImport(f.import_name, .{ .root_source_file = path });
    }

    mod.link_libc = true;
    mod.linkSystemLibrary("sqlite3", .{});

    const exe = b.addExecutable(.{
        .name = "game",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "game", .module = mod } },
        }),
    });
    b.installArtifact(exe);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
}
```

Read it top to bottom. A *module* is a tree of source files with one root. This project has two: the library module `game` rooted at `src/root.zig`, and the executable rooted at `src/main.zig` which imports `game`. The executable is the only place that does I/O; the library is pure. `addAnonymousImport` makes a file importable under a name, and because the files are `.zon` (Zig Object Notation, the language's data literal syntax), `@import("chassis_zon")` yields a value, not code. Section 19 comes back to this.

The commands you will use:

```zig
zig build                      # compile, install to zig-out/bin/game
zig build test --summary all   # run every test block in the module tree
zig build run -- --tui         # build and run with arguments after --
zig build -Ddata=mymod         # a build option declared with b.option
zig fmt src/                   # the one true formatter
```

> **Try it.** Run `zig build --help` in the repository. The `-Ddata` option you see listed is the one declared by `b.option` above; Zig generates the help text from the declaration.

## 3. Files, imports, visibility

Every Zig file is a struct. Its top-level declarations are the struct's fields and methods, and `@import("x.zig")` returns that struct as a value. So a module root is simply a struct that re-exports other structs:

*src/root.zig*

```zig
//! Module root for the simulation core. See ARCHITECTURE.md.
//! The core is pure and deterministic: no I/O, no wall clock, no globals.

const std = @import("std");

pub const types = @import("domain/types.zig");
pub const person = @import("domain/person.zig");
pub const state = @import("sim/state.zig");
pub const commands = @import("sim/commands.zig");
pub const queries = @import("sim/queries.zig");
// …
```

Three things to notice:

- `pub` makes a declaration visible to importers. Without it, a function is private to its file. This is the whole visibility system; there are no classes, packages or friends.

- `//!` is a doc comment for the file itself; `///` documents the next declaration; `//` is an ordinary comment. Every module in this project opens with a `//!` block naming its MekHQ counterpart, a house rule from `CLAUDE.md`.

- Imports are lazy and cyclic imports are allowed. `queries.zig` imports `commands.zig` in a test and `commands.zig` imports `queries.zig` for the rating; Zig only compiles what is referenced.

Inside the executable, the library is reached by the name given in `build.zig`:

*src/main.zig*

```zig
const game = @import("game");
// game.state.GameState, game.commands.execute, game.queries.people …
```

## 4. Values, integers, casts

`const` is a value that never changes; `var` can be reassigned. Types come after the name, and are usually inferred. Integers have explicit widths: `u8`, `u32`, `i64` and so on, plus `usize` for indexes and lengths. The project's money type is one of these:

*src/domain/types.zig*

```zig
/// Integer C-bills. Never floats in financial or rules math.
pub const CBills = i64;
/// Basis points: 10_000 = ×1.
pub const Bp = i64;

pub fn applyBp(amount: CBills, bp: Bp) CBills {
    return @divTrunc(amount * bp, 10_000);
}
```

Two Zig habits appear here. Underscores in number literals are allowed anywhere for readability. And integer division is not the `/` operator when the operands are signed: Zig makes you say which rounding you want, `@divTrunc` (toward zero) or `@divFloor`, because the two differ on negatives and a silent choice is a bug waiting to happen.

Functions whose names start with `@` are *builtins*, part of the language rather than the standard library. The ones you will see most:

| Builtin | What it does | In this project |
|---|---|---|
| `@intCast(x)` | Convert between integer widths; panics in debug if the value does not fit. The target type comes from context. | `const rows: u32 = @intCast(fat / row.heads);` |
| `@as(T, x)` | Give an expression an explicit type, often to satisfy inference. | `@as(u32, p.morale) + 3` |
| `@intFromEnum`, `@enumFromInt` | Enum ↔ integer. | Typed IDs, section 6. |
| `@intFromBool` | `true` → 1. | `4 + @as(u8, @intFromBool(mess >= 2))` |
| `@min`, `@max` | Clamp helpers that work on any numeric type. | `@min(100, p.fatigue + add)` |
| `@tagName(e)` | An enum value's name as a string. | Log lines: `@tagName(c.kind)` |
| `@import`, `@embedFile` | Bring in code or a file's bytes at compile time. | ZON tables; the test PNG. |

Arithmetic has three flavours. Plain `+` is checked in debug builds and undefined on overflow in release. `+%` wraps. `+|` saturates. The RNG seeds streams with wrapping multiplication because the product is meant to overflow:

```zig
prng.* = std.Random.DefaultPrng.init(seed ^ (0x9E3779B97F4A7C15 *% (i + 1)));
```

And saturating subtraction is everywhere a count must not go below zero:

```zig
const open = n.need -| have;   // 0 when have >= need, never negative
```

## 5. Structs and methods

A struct lists fields, optionally with defaults, and may contain functions. A function whose first parameter is the struct (by value or pointer) can be called with dot syntax. The campaign calendar is a small, complete example:

*src/sim/clock.zig*

```zig
pub const Date = struct {
    year: u16,
    month: u8, // 1–12
    day: u8, // 1–31

    pub const campaign_default: Date = .{ .year = 3025, .month = 1, .day = 1 };

    pub fn isLeapYear(year: u16) bool {
        return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
    }

    pub fn daysInMonth(year: u16, month: u8) u8 {
        return switch (month) {
            1, 3, 5, 7, 8, 10, 12 => 31,
            4, 6, 9, 11 => 30,
            2 => if (isLeapYear(year)) @as(u8, 29) else 28,
            else => unreachable,
        };
    }

    pub fn next(self: Date) Date {
        var d = self;
        d.day += 1;
        if (d.day > daysInMonth(d.year, d.month)) {
            d.day = 1;
            d.month += 1;
            if (d.month > 12) {
                d.month = 1;
                d.year += 1;
            }
        }
        return d;
    }

    pub fn isPayday(self: Date) bool {
        return self.day == 1;
    }
};
```

Points to absorb:

- `.{ .year = 3025, … }` is an *anonymous struct literal*. The type is inferred from where it is used. You will see `.{}` constantly: for struct values, for function-argument tuples in `print`, for default-initialised structs.

- `next(self: Date)` takes the struct by value, copies it into `d`, mutates the copy and returns it. Nothing is mutated in place; that is a choice, not a rule.

- A function without `self`, like `isLeapYear`, is just a function namespaced inside the struct. Call it as `Date.isLeapYear(3025)`.

- `switch` is an expression. Every case must be covered or you write `else`. `unreachable` tells the compiler and the reader that a month outside 1–12 cannot happen here.

Structs with pointer receivers mutate in place. `GameState` methods take `self: *GameState`:

*src/sim/state.zig*

```zig
pub const GameState = struct {
    arena: std.heap.ArenaAllocator,
    rng: rng_mod.Rng,
    stats: Stats = .{},
    next_person_id: u32 = 1,
    // … roughly forty more fields

    pub fn init(gpa: std.mem.Allocator, config: Config) GameState {
        return .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .rng = rng_mod.Rng.init(config.seed),
            .clock = .{ .date = config.start_date },
            .funds = config.start_funds,
        };
    }

    pub fn deinit(self: *GameState) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *GameState) std.mem.Allocator {
        return self.arena.allocator();
    }
};
```

Fields without a default (`arena`, `rng`) must be set by whoever constructs the value; fields with a default may be omitted. `init`/`deinit` pairs are a convention, not a language feature. Nothing runs automatically when a value goes out of scope.

## 6. Enums and typed IDs

An enum is a closed set of names. It can have methods, and it can carry an integer representation. The project's roles:

*src/domain/person.zig*

```zig
pub const Role = enum {
    mekwarrior, vehicle_crew, aero_pilot, ba_trooper, infantry,
    tech_mek, tech_mechanic, tech_aero, tech_ba, astech,
    doctor, medic,
    admin_command, admin_logistics, admin_transport, admin_hr, admin_finance,
    dropship_crew, jumpship_crew,

    /// CamOps base monthly salary in C-bills (MekHQ defaults).
    pub fn baseSalary(self: Role) types.CBills {
        return switch (self) {
            .mekwarrior, .aero_pilot => 1_500,
            .vehicle_crew => 900,
            .tech_mek, .tech_aero, .tech_ba => 800,
            .astech => 400,
            .doctor => 1_500,
            .medic => 400,
            .admin_command, .admin_logistics, .admin_transport, .admin_hr, .admin_finance => 500,
            .dropship_crew, .jumpship_crew => 750,
            // …
        };
    }
};
```

Enum values are written with a leading dot when the type is known from context: `.mekwarrior`. The switch above must name every variant; add a role and the compiler lists every switch you forgot. That is the main reason the project reaches for enums over strings.

The most important enum trick in the codebase is the **non-exhaustive enum**, used for every entity ID:

*src/domain/types.zig*

```zig
// Typed IDs: non-exhaustive enums over u32 — copyable, comparable, and
// impossible to pass a PersonId where a UnitId is expected.
pub const PersonId = enum(u32) { none = 0, _ };
pub const UnitId = enum(u32) { none = 0, _ };
pub const ForceId = enum(u32) { none = 0, _ };
pub const ContractId = enum(u32) { none = 0, _ };
```

The trailing `_` means "any other u32 is also a valid value". So a `PersonId` is a 32-bit integer at runtime, costs nothing, has one named value `.none` for "no one", and is a distinct type from `UnitId`. A function declared `fn fire(id: PersonId)` will not accept a unit's ID. Converting is explicit and rare: `@enumFromInt(7)` and `@intFromEnum(id)`, mostly at the edges where a user typed a number.

## 7. Tagged unions and switch

A tagged union is a value that is exactly one of several alternatives, each with its own payload, and always knows which. The whole game is driven by one:

*src/sim/commands.zig*

```zig
pub const Command = union(enum) {
    advance_day,
    advance_days: u32,
    hire: struct { first: []const u8, last: []const u8, role: person_mod.Role },
    recruit: person_mod.Role,
    fire: types.PersonId,
    new_company: []const u8,
    create_commander: struct {
        name: []const u8,
        origin: commander_mod.Faction,
        profession: commander_mod.Profession,
        start_year: u16 = 3025,
    },
    crew_company: types.ForceId,
    set_shares_pct: u8,
    // … about ninety variants
};
```

Variants can carry nothing (`advance_day`), a plain value (`fire: PersonId`), or an inline struct. A value is built with the same dot syntax as a struct literal: `.{ .fire = id }` or `.{ .hire = .{ .first = "Grayson", .last = "Carlyle", .role = .mekwarrior } }`. Consuming one is a `switch` that *captures* the payload between vertical bars:

```zig
pub fn execute(gs: *GameState, cmd: Command) Error!Result {
    switch (cmd) {
        .advance_day => return advance(gs, 1),
        .advance_days => |n| return advance(gs, n),
        .hire => |h| {
            const id = try gs.hirePerson(h.first, h.last, h.role);
            return .{ .hired = id };
        },
        .recruit => |role| {
            const id = try gs.recruitGenerated(role);
            return .{ .hired = id };
        },
        // …
    }
}
```

`|n|` binds the payload of `advance_days`; `|h|` binds the inline struct so `h.first` works. Add a variant to `Command` and this switch fails to compile until you handle it. The terminal's key type is the same idea at a smaller scale:

*src/tui/term.zig*

```zig
pub const Key = union(enum) {
    char: u21,
    enter, escape, tab, backtab, backspace, delete,
    up, down, left, right, home, end, pgup, pgdn,
    f: u8,    // F1..F12
    ctrl: u8, // 'a'..'z'
    none,
};
```

You will also see `switch` used on integers with ranges and lists, as in the byte-to-key decoder:

```zig
return switch (b) {
    0x1b => self.readEscape(),
    '\r', '\n' => .enter,
    '\t' => .tab,
    0x7f, 0x08 => .backspace,
    1...7, 11, 12, 14...26 => .{ .ctrl = 'a' + b - 1 },
    else => self.readUtf8(b),
};
```

## 8. Optionals

Zig has no null pointers by default. A value that may be absent has an optional type, written `?T`, and you must unwrap it before use. The three unwrapping forms, all from the project:

```zig
// 1. `orelse`: a fallback, or an early return.
const p = gs.person(id) orelse return Error.UnknownPerson;
const tonnage: u8 = if (chassis_mod.find(u.chassis_key)) |d| d.tonnage else 50;

// 2. `if (x) |v|`: run a block only when present.
if (p.born_day) |born| {
    const days = @as(i64, day) - @as(i64, born);
    // …
}

// 3. `.?`: assert it is present (panics in debug if not).
const u = gs.unit(seat).?;
```

Optional fields are how the domain expresses "not yet": `leave_until_day: ?u32 = null`, `wound_heal_day: ?u32 = null`, `born_day: ?i32 = null` for people hired by tests without a birthday. Lookups return optionals: `chassis.find(key)` returns `?*const Chassis`, a maybe-pointer to a catalog entry.

```zig
pub fn find(key: []const u8) ?*const Chassis {
    for (catalog) |*c| {
        if (std.mem.eql(u8, c.key, key)) return c;
    }
    return null;
}
```

A common pattern chains the two: `if (gs.person(u.pilot)) |pilot| if (pilot.isAvailable(day)) …`. Reading it, remember that `|x|` after an `if` or `while` always means "the unwrapped value".

## 9. Errors, try, catch, defer

An error is a value from an *error set*, which is an enum of failure names. A function that can fail returns `E!T`: either an error from set `E` or a `T`. Writing `!T` lets the compiler infer the set.

*src/sim/commands.zig*

```zig
pub const Error = error{
    UnknownPerson,
    UnknownForce,
    UnknownUnit,
    InsufficientTreasury,
    CompanyDeployed,
    NoBerth,
    BadPercent,
    BadYear,
    // … about sixty
} || std.mem.Allocator.Error;   // merged with OutOfMemory

pub fn execute(gs: *GameState, cmd: Command) Error!Result { // … }
```

The four verbs:

- `try f()` — if `f` fails, return that error from the current function immediately. Nine out of ten error sites use this.

- `f() catch value` — if it fails, use `value` instead. `catch |err| { … }` captures the error. `catch unreachable` asserts it cannot fail. `catch {}` swallows it (used deliberately, and rarely).

- `defer` — run a statement when the enclosing block exits, however it exits. Used for every cleanup.

- `errdefer` — like `defer`, but only when the block exits with an error.

The save store's opener shows all of them cooperating around a database transaction:

*src/persist/store.zig*

```zig
pub fn fromDb(db: sqlite.Db) !Store {
    try db.exec(ddl);
    const store: Store = .{ .db = db };
    const stored: u32 = @intCast(@max(1, store.getSetting("schema_version", 1)));
    if (stored > schema_version) return error.StoreNewerThanGame;
    try db.exec("BEGIN");
    errdefer db.exec("ROLLBACK") catch {};
    for (migrations) |m| {
        if (m.version <= stored) continue;
        if (!try hasColumnRt(db, m.table, m.column)) try db.exec(m.sql);
    }
    try store.setSetting("schema_version", schema_version);
    try db.exec("COMMIT");
    return store;
}
```

If any `try` after `BEGIN` fails, the `errdefer` rolls the transaction back on the way out; the `catch {}` on it says that if even the rollback fails there is nothing more to do. On success, `errdefer` does nothing and `COMMIT` stands. Compare this with a language that throws: here the failure path is visible in the text, line by line.

Errors travel up to the user interface, where a shared table turns them into sentences:

*src/sim/cli.zig*

```zig
pub fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.InsufficientTreasury => "not enough money in that treasury — transfer funds first",
        error.BadPercent => "a percentage between 0 and 100",
        error.BadYear => "the campaign starts between 3000 and 3060",
        error.MaxLevel => "already at the top: this HQ is regional (or the facility is maxed)",
        // …
        else => @errorName(err),
    };
}
```

## 10. Arrays, slices, strings

An array has a compile-time length: `[3]u8`. A *slice* is a pointer plus a runtime length: `[]u8`, or `[]const u8` when it must not be written through. Strings are just `[]const u8`; a literal like `"Alpha"` is a pointer to a constant array with a zero terminator, which coerces to a slice.

```zig
const lance_names = [_][]const u8{ "1st Lance", "2nd Lance", "3rd Lance" };   // [3][]const u8, length inferred by _
var buf: [96]u8 = undefined;                                            // stack scratch, uninitialised
const s = try std.fmt.bufPrint(&buf, "order {s} 1 hq:{d}", .{ key, id }); // a slice into buf
const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |k| path[k + 1 ..] else path;  // slicing: path[a..b]
```

There is no string type and no `==` on strings. Compare with `std.mem.eql(u8, a, b)`, search with `std.mem.indexOf`, split with `std.mem.tokenizeScalar`. The REPL parser is built from these:

*src/sim/cli.zig*

```zig
pub fn parseCommand(verb: []const u8, tokens: *std.mem.TokenIterator(u8, .scalar)) ParseError!?Command {
    const eq = std.mem.eql;
    if (eq(u8, verb, "admit")) return .{ .admit = @enumFromInt(try num(u32, tokens.next())) };
    if (eq(u8, verb, "shares")) return .{ .set_shares_pct = try num(u8, tokens.next()) };
    if (eq(u8, verb, "newlance")) {
        const site = try parseSite(try need(tokens.next()));
        var name = std.mem.trim(u8, tokens.rest(), " ");
        // …
    }
    return null; // not a verb we know
}
```

Note the return type `ParseError!?Command`: it can fail, and on success may still be "no command" (`null`). Nesting error and optional like this is common and reads inside-out: an optional command, wrapped in a possible error.

The C-string form `[*:0]const u8` (a many-item pointer with a zero sentinel) appears only where C needs it, such as `sqlite3_open(filename: [*:0]const u8, …)`. The `Z`-suffixed formatters like `bufPrintZ` produce them.

## 11. Pointers

`*T` is a pointer to one `T`; `*const T` cannot write through. `&x` takes an address; `p.*` dereferences. Field access through a pointer needs no arrow: `p.morale` works whether `p` is a struct or a pointer to one.

```zig
var gs = GameState.init(alloc, .{ .seed = 42 });
defer gs.deinit();                       // method on *GameState; & is implicit for method calls
_ = try execute(&gs, .{ .new_company = "Alpha" });   // explicit & when passing as an argument

for (&self.prngs, 0..) |*prng, i| {      // iterate an array by pointer so we can assign
    prng.* = std.Random.DefaultPrng.init(seed ^ (0x9E3779B97F4A7C15 *% (i + 1)));
}
```

Two gotchas the project ran into during development, worth knowing early:

- **Pointers into growable containers go stale.** If you hold `*Force` from a hash map and then insert into that map, the map may reallocate and your pointer now points at freed memory. The fix is to re-fetch after any insert. You will see `gs.force(id)` called again rather than a pointer kept across a `createForce`.

- **Shadowing is an error.** A local named `rows` inside a function that already has `rows` in scope does not compile. Zig forbids shadowing entirely, which is why locals in this codebase have slightly fussy names like `tpb` or `uit2`.

Leading-underscore assignment, `_ = try execute(…)`, discards a value on purpose. Zig refuses to compile an unused result or an unused local, so discarding is explicit.

## 12. Loops and labeled blocks

`for` iterates slices and arrays, optionally with an index from `0..`. `while` takes a condition and an optional continue expression after a colon.

```zig
for (p.awards.items, 0..) |key, i| { // value and index
    if (i > 0) try line.appendSlice(alloc, " · ");
    try line.appendSlice(alloc, key);
}

var i: usize = 0;
while (i < gs.bay_jobs.items.len) {  // index loop when the body removes items
    const job = &gs.bay_jobs.items[i];
    if (job.done_day == null or today < job.done_day.?) {
        i += 1;
        continue;
    }
    if (!try completeJob(gs, job)) { i += 1; continue; }
    _ = gs.bay_jobs.orderedRemove(i);    // no i += 1: the next item slid into slot i
}

var days: u32 = 0;
while (hasJobForUnit(&gs, uid) and days < 200) : (days += 1) {  // continue expression
    try runDaily(&gs);
    gs.clock.day_index += 1;
}
```

Hash maps are walked with an iterator and `while` capturing entries:

```zig
var it = gs.people.iterator();
while (it.next()) |entry| {
    const p = entry.value_ptr;            // a pointer, so changes stick
    if (p.status != .active) continue;
    p.xp += monthly_service_xp;
}
```

Blocks can be labeled and can yield a value with `break :label value`. The project uses this for "compute a value with several steps, inline":

```zig
const env: terrain_mod.Environment = blk: {
    const world = planet_mod.find(c.planet_key) orelse break :blk .{};
    const t = terrain_mod.terrainOf(world);
    break :blk .{ .terrain = t, .weather = terrain_mod.rollWeather(&gs.rng, .battle, t) };
};
```

A `while` can also be an expression with an `else` that runs when the condition ends the loop without a `break`. That is how "is this person in this company" walks up the force tree:

```zig
var f = p.assigned_force;
const in_company = while (f != .none) {
    if (f == company) break true;
    f = (gs.forces.getPtr(f) orelse break false).parent;
} else false;
```

## 13. Memory: allocators and lists

This is the part of Zig newcomers find strangest, so take it slowly. Nothing allocates unless you hand it an allocator. An allocator is a small interface value, `std.mem.Allocator`, passed as an ordinary parameter. Different allocators have different lifetimes and costs, and choosing one is a design decision.

IRON LEDGER uses three, each for a different lifetime:

| Allocator | Lifetime | Where |
|---|---|---|
| `init.gpa` (general purpose) | The process. Tracks leaks in debug. | Handed to `GameState.init` and the terminal app in `main`. |
| `ArenaAllocator` owned by `GameState` | The campaign. Individual frees are no-ops; `arena.deinit()` frees everything at once. | Every person, hull, log line and ledger row. `gs.allocator()` returns it. |
| A per-frame arena in the TUI, and per-call arenas in tests | One frame, or one function call. | Query results: rows of formatted text that are drawn once and forgotten. |

The arena is why the simulation core can be so relaxed about strings. A query builds hundreds of small strings with `allocPrint` and never frees one; the caller resets the arena after drawing. In a test, the pattern is always the same three lines:

```zig
var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
defer arena.deinit();
const a = arena.allocator();
const lines = try summary(a, &gs);
```

The standard growable list is `std.ArrayListUnmanaged(T)`. "Unmanaged" means it does not remember its allocator; you pass it to every call that might grow the list. That keeps the struct one pointer and one length, and makes the allocation visible at the call site:

```zig
var out: std.ArrayListUnmanaged([]const u8) = .empty;
try out.append(alloc, "{a}CONTRACTS{/}");
try out.append(alloc, try std.fmt.allocPrint(alloc, "  {s} c-bills earned", .{try money(alloc, earned)}));
return out.toOwnedSlice(alloc);    // hand the buffer to the caller as a plain slice
```

Formatting goes through `std.fmt`. `{s}` prints a string, `{d}` a number, `{d: >5}` right-aligns in five columns, `{s: <18}` left-aligns. Because `{` and `}` are format syntax, a literal brace is written doubled, which is why the TUI's colour markup appears as `{{a}}…{{/}}` inside format strings and as `{a}…{/}` in plain literals.

Hash maps: `std.AutoArrayHashMapUnmanaged(K, V)` keeps insertion order, which matters for determinism (iterating a map in a stable order is what makes two runs with the same seed identical). `StringArrayHashMapUnmanaged` is the string-keyed cousin used for stock and faction standing.

## 14. comptime and reflection

Any expression marked `comptime`, and any expression the compiler can evaluate before runtime, runs at compile time. Types are values at compile time, which is how Zig does generics: a function takes `comptime T: type` and returns something built from `T`. Three uses in this project, in rising order of cleverness.

#### ZON data as compile-time values

```zig
pub const catalog: []const Chassis = @import("chassis_zon");
pub const t: Tuning = @import("tuning_zon");
```

The `.zon` file is a struct literal. Importing it with a declared type makes the compiler type-check the literal against the struct: a missing field without a default, a misspelled field or a string where a number belongs is a build error with a line number. The 97 designs, 234 systems and every tuning knob are checked this way on every build.

#### anytype and inline for

The SQLite binding takes a tuple of mixed values and binds each by its type:

*src/persist/sqlite.zig*

```zig
pub fn bindAll(self: Stmt, args: anytype) Error!void {
    inline for (args, 1..) |arg, i| try self.bind(@intCast(i), arg);
}

pub fn bind(self: Stmt, idx: c_int, value: anytype) Error!void {
    const T = @TypeOf(value);
    const rc = switch (@typeInfo(T)) {
        .int, .comptime_int => sqlite3_bind_int64(self.h, idx, @intCast(value)),
        .bool => sqlite3_bind_int64(self.h, idx, @intFromBool(value)),
        .@"enum" => blk: {
            if (@typeInfo(T).@"enum".is_exhaustive) {
                const name = @tagName(value);
                break :blk sqlite3_bind_text(self.h, idx, name.ptr, @intCast(name.len), transient);
            }
            break :blk sqlite3_bind_int64(self.h, idx, @intCast(@intFromEnum(value)));
        },
        .optional => if (value) |v| return self.bind(idx, v) else sqlite3_bind_null(self.h, idx),
        .pointer => blk: {
            const s: []const u8 = value;
            break :blk sqlite3_bind_text(self.h, idx, s.ptr, @intCast(s.len), transient);
        },
        else => @compileError("unsupported bind type " ++ @typeName(T)),
    };
    // …
}
```

`anytype` means "whatever the caller passes; specialise this function per type". `inline for` unrolls the loop at compile time, so each element of the tuple gets its own `bind` call with its own concrete type. `@typeInfo` is reflection: it returns a description of the type as a tagged union, so the code can ask "is this an enum, and is it exhaustive?" Notice the enum rule this encodes: exhaustive enums (roles, statuses) are saved as their names, so a save file stays readable and survives reordering; non-exhaustive typed IDs are saved as integers.

#### Walking a struct's fields

The tuning sanity test walks every field of the `Tuning` struct, however deeply nested, and checks that unsigned integers are positive and basis-point fields are at most ten times unity. It is one recursive function that takes a type as a parameter:

*src/domain/tuning.zig*

```zig
fn checkPositive(comptime T: type, value: T, comptime name: []const u8) !void {
    switch (@typeInfo(T)) {
        .int => |info| {
            // Signed knobs (deltas, scores) may be zero or negative by design.
            if (info.signedness == .signed) return;
            if (value <= 0) {
                std.debug.print("tuning field {s} must be positive\n", .{name});
                return error.BadTuning;
            }
            if (std.mem.endsWith(u8, name, "_bp") and value > 100_000) {
                std.debug.print("tuning field {s} is over 100000 basis points\n", .{name});
                return error.BadTuning;
            }
        },
        .@"struct" => |info| inline for (info.fields) |f| try checkPositive(f.type, @field(value, f.name), name ++ "." ++ f.name),
        else => {},
    }
}

test "every tuning value is positive and every basis-point knob is sane" {
    try checkPositive(Tuning, t, "t");
}
```

Read the struct arm carefully: for each field it calls itself with the field's *type*, the field's *value* (read by name with `@field`) and a dotted path built with `++`, which concatenates strings at compile time. Because `T` and `name` are `comptime`, every level of recursion is resolved while compiling; at runtime only the integer checks remain. Add a knob to the tuning table and it is covered by this test with no change to the test.

Two smaller comptime devices you will meet: `@embedFile("testdata/rgb4x3.png")` bakes a file's bytes into the binary (the PNG decoder's test image), and `@typeInfo(Stream).@"enum".fields.len` sizes an array by the number of enum variants, so adding an RNG stream also grows the array of generators.

## 15. Tests

A test is a `test "name" { … }` block anywhere in a file. `zig build test` compiles every test in the module tree and runs them. Tests live next to the code they check; this project has 224 of them, and the rule in `CLAUDE.md` is that every module carries its own.

*src/sim/rng.zig*

```zig
test "streams are independent and deterministic" {
    var a = Rng.init(42);
    var b = Rng.init(42);
    // Draw heavily from one stream in `a` only; another stream must still
    // match the untouched twin exactly.
    for (0..1000) |_| _ = a.roll2d6(.maintenance);
    for (0..10) |_| {
        try std.testing.expectEqual(b.roll2d6(.battle), a.roll2d6(.battle));
    }
}
```

The assertions you need: `expect(bool)`, `expectEqual(expected, actual)`, `expectEqualStrings`, and `expectError(error.X, expr)` to assert a call fails a particular way:

```zig
try std.testing.expectError(Error.MaxLevel, execute(&gs, .{ .upgrade_tier = home }));
try std.testing.expectError(Error.InsufficientTreasury, execute(&gs, .{ .upgrade_tier = fb }));
```

Tests use `std.testing.allocator`, which fails the test if anything is leaked. That is why every test that creates a `GameState` writes `defer gs.deinit()` on the next line. The root file has one more test that forces every declaration to be compiled, which catches dead code that no longer type-checks:

```zig
test {
    std.testing.refAllDecls(@This());
}
```

Tests that need the filesystem get a scratch directory from `std.testing.tmpDir` and the test I/O instance `std.testing.io` (section 17). The soundtrack scanner's test writes a few files into one, scans it, and cleans up with `defer tmp.cleanup()`.

## 16. Talking to C

Zig can declare C functions directly. The SQLite layer is eleven declarations and two opaque handle types, no header translation involved:

*src/persist/sqlite.zig*

```zig
pub const Handle = opaque {};
pub const StmtHandle = opaque {};

extern fn sqlite3_open(filename: [*:0]const u8, db: *?*Handle) c_int;
extern fn sqlite3_close(db: *Handle) c_int;
extern fn sqlite3_prepare_v2(db: *Handle, sql: [*]const u8, nbyte: c_int, stmt: *?*StmtHandle, tail: ?*?[*]const u8) c_int;
extern fn sqlite3_step(stmt: *StmtHandle) c_int;
extern fn sqlite3_bind_int64(stmt: *StmtHandle, idx: c_int, v: i64) c_int;
extern fn sqlite3_bind_text(stmt: *StmtHandle, idx: c_int, text: [*]const u8, n: c_int, destructor: ?*const anyopaque) c_int;
// …
```

`opaque {}` is a type you can point to but never look inside, which is exactly what a C library's handle is. `c_int` is C's `int` on the target. `?*Handle` is a nullable pointer, the honest type for a C out-parameter. `anyopaque` is `void*`. The linker finds these symbols because `build.zig` said `linkSystemLibrary("sqlite3")`.

Above the raw functions sits a small Zig wrapper (`Db`, `Stmt`) that turns return codes into errors and pointers into slices, so the rest of the program never sees a `c_int`. The same pattern holds for the terminal: `std.posix.tcsetattr` for raw mode, `std.c.waitpid` to reap the music player process. The rule is to keep the C-shaped code in one file per foreign thing.

## 17. Zig 0.16: std.Io

Zig 0.16 introduced an explicit I/O interface, `std.Io`, passed as a value in the same spirit as allocators. Anything that touches the outside world takes an `io`. The program receives one in `main`:

*src/main.zig*

```zig
pub fn main(init: std.process.Init) !void {
    var gs = game.state.GameState.init(init.gpa, .{ .seed = 3025 });
    defer gs.deinit();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // exe name
    var tui = false;
    var store_path: [:0]const u8 = "campaigns.db";
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--tui")) tui = true;
        if (std.mem.eql(u8, arg, "--store")) store_path = args.next() orelse store_path;
    }
    if (tui) {
        try @import("tui/app.zig").run(init.io, init.gpa, store_path, .{ /* … */ });
    }
    // …
}
```

`init` carries the allocator, the I/O instance and the arguments. Old code that called `std.fs.cwd()` now writes `std.Io.Dir.cwd()` and passes `io` to each operation; the wall clock is `std.Io.Clock.now(.real, io)`; a child process is `std.process.spawn(io, …)`. Here is a directory walk from the soundtrack scanner in the current style:

*src/tui/music.zig*

```zig
var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch return;
defer dir.close(self.io);
var it = dir.iterate();
while (try it.next(self.io)) |e| {
    if (e.kind == .directory) { /* a soundtrack */ continue; }
    if (e.kind != .file or !isAudio(e.name)) continue;
    // …
}
```

The practical consequence for this project: the simulation core never receives an `io`, so it structurally cannot read a file or check the time. Purity is not a promise in a comment; it is a parameter that is not there.

---

## 18. The architecture in one picture

```zig
src/
├── domain/     entities and rule tables: person, unit, chassis, contract, hq, tuning …   (pure)
├── sim/        state, the daily tick, commands, queries, battle, medical, personnel …    (pure)
├── econ/       finance, markets, logistics                                               (pure)
├── gen/        company and person generators                                             (pure)
├── persist/    sqlite.zig (C binding) and store.zig (save/load, migrations)              (I/O)
├── tui/        term.zig, screen.zig, app.zig, emblem.zig, png.zig, music.zig, splash.zig  (I/O)
├── root.zig    the `game` module: re-exports everything above except tui/
└── main.zig    the executable: flags, the REPL, the demo, and the hand-off to tui/app.zig
data/
├── chassis.zon  planets.zon  parts.zon
└── tables/      tuning.zon meklab.zon names.zon ranks.zon awards.zon abilities.zon rat.zon factions.zon scenarios.zon terrain.zon
```

Everything reduces to one rule, stated in `ARCHITECTURE.md` and enforced by the module layout: **the simulation is a pure function of its inputs**. Given the same seed and the same sequence of commands, two processes produce byte-identical state. The consequences ripple outward:

- Randomness is a struct inside the state, not a global (section 20).

- Time is an integer day counter; the calendar is rendered only at the edges.

- Money is integers; there is not a single float in the rules.

- The two frontends, terminal and console, talk to the core through exactly two doors: `commands.execute` to change things and `queries.*` to read things (sections 21 and 23). A third door, `cli.parseCommand`, turns typed text into commands and is shared by both.

The payoff is the golden-master test in section 28, and the practical fact that any bug can be reproduced from a seed and a script.

## 19. Data: ZON files become typed tables

A ZON file is a Zig struct literal with nothing else in it. Here is the top of the tuning table:

*data/tables/tuning.zon*

```zig
// Tuning knobs. Typed against domain/tuning.zig `Tuning` at comptime.
.{
    .hq = .{
        .influence_ly = .{ .field = 15, .regional = 60, .brigade = 90 },
        .paperwork_base_days = 21,
        .upgrade_cost_per_level = .{ .mek_bay = 800_000, .warehouse = 400_000, /* … */ },
    },
    .person = .{
        .fatigue_tired = 30,
        .exhausted_fatigue = 70,
        .turnover_target = 3, // 2d6 < 3 + flags
        // …
    },
    // … market, medical, battle, rating, contract …
}
```

And the Zig side that gives it a shape:

*src/domain/tuning.zig*

```zig
pub const Tuning = struct {
    hq: struct {
        influence_ly: struct { field: u32, regional: u32, brigade: u32 },
        paperwork_base_days: u32,
        // …
    },
    person: struct {
        fatigue_tired: u8,
        exhausted_fatigue: u8,
        turnover_target: u8,
        // …
    },
    // …
};

/// The live table.
pub const t: Tuning = @import("tuning_zon");
```

Rules code reads `tuning.person.turnover_target` as a plain constant. The compiler has already checked the file matches the struct. Adding a knob is a three-line change: a field in the struct, a value in the file, a use in the formula. The same mechanism carries the design catalogue, where each row is a struct with defaults so a vehicle need not state mek-only fields:

*data/chassis.zon (one row)*

```zig
.{ .key = "SHD-2H", .name = "Shadow Hawk", .tonnage = 55, .bv = 1064, .cost = 4_701_800, .rarity = .common,
   .walk_mp = 5, .jump_mp = 3, .heat_sinks = 12, .armor_half_tons = 19, .loadout = .{
    .{ .slot = "lt.ac5.1", .part = "ac5", .class = .weapon },
    .{ .slot = "ct.mlas.1", .part = "mlas", .class = .weapon },
    // …
} },
```

What the type system cannot check, tests do: every loadout part key must exist in the parts catalogue, every RAT entry must name a real design of the right class, every mek must pass the MekLab's construction rules. Those tests run against the data, which is why the modding doc tells you to run `zig build test -Ddata=mymod`.

The mod overlay in `build.zig` (section 2) is the last piece: because the import is by name, swapping which file backs the name is a build-script decision, and the sim code does not know or care.

## 20. GameState: one arena, one dice bag

`GameState` is a large struct holding everything about a campaign: ordered hash maps of people, units, forces, HQs and contracts keyed by their typed IDs; lists for the ledger, the log, the event queue, orders, couriers and market listings; the clock; the treasury; and two special members.

The **arena** owns every allocation the campaign makes. Names, log text, lists, maps: all of it comes from `gs.allocator()` and all of it is released by `gs.deinit()`. There is no per-object destructor anywhere in the domain. This is a deliberate trade: memory grows monotonically over a campaign (a long game holds every log line it ever wrote), in exchange for never having a use-after-free and never forgetting a free.

The **RNG** is a bag of independent generators, one per subsystem:

*src/sim/rng.zig*

```zig
pub const Stream = enum(u8) { generation, market, maintenance, acquisition, battle, events, medical, travel };

pub const Rng = struct {
    prngs: [Stream.count]std.Random.DefaultPrng,

    pub fn roll2d6(self: *Rng, stream: Stream) u8 {
        const r = self.random(stream);
        return r.intRangeAtMost(u8, 1, 6) + r.intRangeAtMost(u8, 1, 6);
    }
};
```

Why streams? Suppose you add a weather roll to battles. If all randomness shared one generator, every market roll after the first battle would shift, and a saved game would replay differently after an update. With named streams, adding a draw to `.battle` leaves `.market` untouched. Sections of the code name the stream they draw from: `gs.rng.roll2d6(.medical)` in turnover, `.acquisition` in part orders. A house rule forbids creating a PRNG anywhere else.

Finally, `gs.hash()` folds the important state (day, funds, every person's fatigue and morale, every unit's condition, counts of everything) into a 64-bit number. It exists for one test, in section 28.

## 21. Commands: the only way in

Nothing outside the core mutates `GameState` except through `commands.execute(gs, cmd)`. The function is a single switch over the `Command` union, and every arm follows the same shape: validate, then mutate, then return a `Result`.

*src/sim/commands.zig (the tier-upgrade arm)*

```zig
.upgrade_tier => |hq_id| {
    // Check everything before a c-bill moves: a refused upgrade used
    // to keep the money.
    const h = gs.hqs.getPtr(hq_id) orelse return Error.UnknownHq;
    if (h.tier != .field) return Error.MaxLevel;
    for (h.projects.items) |p| if (p.kind == .tier_upgrade) return Error.ProjectInProgress;
    if (gs.treasuryBalance(.{ .hq = hq_id }) < hq_ops.tier_upgrade_cost) return Error.InsufficientTreasury;
    hq_ops.startTierUpgrade(gs, hq_id) catch |err| switch (err) {
        error.ProjectInProgress => return Error.ProjectInProgress,
        error.MaxLevel => return Error.MaxLevel,
        error.UnknownHq => return Error.UnknownHq,
        error.OutOfMemory => return Error.OutOfMemory,
    };
    try gs.postTreasury(.{ .hq = hq_id }, .{
        .day = gs.clock.day_index,
        .amount = -hq_ops.tier_upgrade_cost,
        .category = .hq_construction,
        .hq = hq_id,
        .note = "regional upgrade",
    });
    return .{};
},
```

The comment records a real bug: an earlier version debited first and checked second, so a refused upgrade kept the money. The shape "all checks, then all effects" is the discipline that prevents it. Notice also that `hq_ops.startTierUpgrade` has its own smaller error set, and the arm translates each case into the command layer's set explicitly; Zig's `switch` on an error is exhaustive too, so a new failure mode in `hq_ops` shows up here as a compile error.

The `Result` struct is all defaults, so most arms return `.{}` and only the ones with something to report fill a field:

```zig
pub const Result = struct {
    days_advanced: u32 = 0,
    hired: types.PersonId = .none,
    created_force: types.ForceId = .none,
    unit: types.UnitId = .none,
    eta_days: u32 = 0,
    hired_count: u32 = 0,
    still_open: u32 = 0,
    // …
};
```

Both frontends produce commands the same way. The console parses a typed line with `cli.parseCommand`; the terminal client's `:` line uses the same parser, and its keys build command values directly (`try self.exec(.{ .crew_company = co })`). That single parser is why a verb added for one frontend works in the other for free.

## 22. The daily tick

Ending a turn calls `tick.advanceDay` once per day. It is a fixed list of phases, each a function that takes the state and returns an error union:

*src/sim/tick.zig*

```zig
pub fn advanceDay(gs: *GameState) !void {
    gs.clock.advance();
    gs.refreshHqStaffing();
    if (gs.clock.day_index % 7 == 0) network.resetWeeklyThroughput(gs);
    try runTravel(gs);               // deliveries, couriers, transfers land
    try runPolicies(gs);             // standing cash top-ups and resupply
    try runStockPolicies(gs);        // warehouse reorder points
    try hq_ops.runDaily(gs);         // bays, fabrication, construction
    try runSupplyConsumption(gs);
    try medical.runDailyHealing(gs);
    try runMarkets(gs);
    if (gs.clock.day_index % 7 == 0 and gs.clock.day_index > 0) {
        try maintenance.runWeeklyMaintenance(gs);
        try maintenance.runWeeklyRepairs(gs);
    }
    try medical.runDailyTraining(gs);
    try runContracts(gs);
    try contract_control.runReturns(gs);
    if (gs.clock.date.day == 1) try contract_events.rollMonthly(gs);
    if (gs.clock.day_index % 7 == 3) try contract_events.rollWeekly(gs);
    try battle.runDaily(gs);         // due engagements resolve
    try contract_control.checkEffectiveness(gs);
    if (gs.clock.day_index % 7 == 0 and gs.clock.day_index > 0) {
        try medical.runWeeklyRest(gs);
        runTrainingLances(gs);
    }
    try runFinances(gs);             // payday on the 1st: payroll, ranks, shares, turnover
    try contract_events.expireDue(gs);
}
```

Order is meaning. Deliveries land before consumption so a convoy that arrives today feeds today. Maintenance runs before battles on the same day, so a hull that broke down this week does not fight. Finance runs last so the day's costs are on the books when payroll is counted. When you add a mechanic, the first question is which phase it belongs in and what must already have happened.

Each phase is small and testable on its own. `medical.runMonthlyTurnover` is called from `runFinances` on payday, but its tests call it directly on a hand-built state, set morale to zero, and count notices in the inbox. That is the general testing style: build the smallest state that exercises the rule, call the phase, assert on state.

## 23. Queries: the only way out

Frontends never walk `GameState` themselves to draw a screen. They call a query, which returns plain data: strings already formatted, plus the IDs a key handler will need. The People screen's query:

*src/sim/queries.zig*

```zig
pub const PersonRow = struct { id: types.PersonId, text: []const u8 };
pub const People = struct { header: []const u8, rows: []PersonRow, total: usize };

pub fn people(alloc: Alloc, gs: *GameState, filter: HallFilter) !People {
    var rows: std.ArrayListUnmanaged(PersonRow) = .empty;
    var total: usize = 0;
    var it = gs.people.iterator();
    while (it.next()) |e| {
        const p = e.value_ptr;
        if (p.status == .kia or p.status == .retired or p.status == .resigned or p.status == .released) continue;
        total += 1;
        if (!filter.matches(p.role)) continue;
        if (filter == .wounded and p.status != .wounded) continue;
        if (filter == .unassigned and !isUnassigned(gs, p)) continue;
        const name = try p.rankedName(alloc);
        try rows.append(alloc, .{ .id = p.id, .text = try std.fmt.allocPrint(alloc,
            "{d: <4} {s: <20} {s: <15} {s: <7} {s: <5} {d: >3} {s} {s} {s: <11} {d: >3} {d: >3} {s: >7}",
            .{ @intFromEnum(p.id), clip(name, 20), @tagName(p.role), /* … */ }) });
    }
    return .{ .header = "id   name                 role …", .rows = try rows.toOwnedSlice(alloc), .total = total };
}
```

Three design points. The query takes an allocator, and callers pass a per-frame arena, so the rows cost nothing to free. It returns the `id` beside the text so the screen can act on the highlighted row without re-deriving which person it was. And the text carries lightweight colour markup (`{g}active{/}`) that the console strips and the terminal renders, so one query serves both frontends.

This is also where a class of bugs lives. The HQ screen once mapped the cursor row to a facility by position, assuming the table started on row one; when the tier section above it grew, every row shifted. The fix was a query, `hqFacilityAtRow`, that reads the rendered rows back and says which facility each one is. Rule of thumb: if a key handler needs to know what a row means, ask a query, never count.

## 24. Money without floats

Every amount is `CBills = i64`, and every multiplier is basis points through `applyBp`. A 10 percent markup is `applyBp(cost, 11_000)`. A rating letter's pay multiplier, a periphery world's local-supply price, a profession's 2 percent edge: all basis points, all integer arithmetic, all reproducible to the C-bill on any machine.

Money moves in exactly one way. The ledger records a transaction and the named treasury's balance changes in the same call:

*src/econ/finance.zig · src/sim/state.zig*

```zig
pub const Transaction = struct {
    day: u32,
    amount: types.CBills, // signed: income +, expense −
    category: Category,
    company: types.ForceId = .none,
    hq: types.HqId = .none,
    contract: types.ContractId = .none,
    note: []const u8 = "",
};

/// The only way money moves: ledger entry + the named treasury's balance, in lockstep.
pub fn postTreasury(self: *GameState, treasury: Treasury, txn: Transaction) !void {
    try self.ledger.post(self.allocator(), txn);
    switch (treasury) {
        .outfit => self.funds += txn.amount,
        .hq => |id| if (self.hqs.getPtr(id)) |h| { h.funds += txn.amount; },
        .company => |id| if (self.forces.getPtr(id)) |f| { f.local_funds += txn.amount; },
    }
}
```

Because every transaction is tagged with a company, HQ and contract, the P&L per entity, the contract history's "pay received", the profit-share pool and the campaign summary are all sums over the same list with different filters. There is no second copy of the numbers to drift out of sync. `Treasury` is itself a small tagged union, so "which till" is a typed value rather than a convention.

## 25. Battles and events

A battle is resolved by one function, `battle.resolveEngagement`, that reads the campaign state and rolls dice. There is no map and no turns. The player's side is built by walking the company's lances, summing each hull's battle value adjusted for damage, ammunition on hand and the pilot's skill with fatigue and injury penalties; the campaign-level modifiers (supplies, morale, recon, air cover, support lances) scale it. The enemy is a fraction of that, set by contract kind, scenario and a variance roll. Then:

*src/sim/battle.zig (trimmed)*

```zig
const scenario = scenario_mod.roll(&gs.rng, .battle, c.kind);
const scenario_mod: i32 = @as(i32, scenario.roll_mod)
    + (if (player.mods.recon_quality > 0) @as(i32, scenario.scout_bonus) else 0)
    + env.rollMod();
const ratio_bonus: i32 = if (env.close()) @min(ratioBonus(player.power, enemy_power), 2) else ratioBonus(player.power, enemy_power);
var roll = @as(i32, gs.rng.roll2d6(.battle)) + ratio_bonus + scenario_mod;

const outcome: autoresolve.Outcome = if (roll >= 11) .decisive_victory
    else if (roll >= 8) .victory
    else if (roll >= 6) .draw
    else if (roll >= 4) .defeat
    else .rout;
```

Everything after that is bookkeeping driven by the outcome: how many hulls are hit and where, who is wounded or killed, what ammunition was spent, what salvage the trucks can haul, what the contract's score and the pilots' records gain, and a multi-line after-action report written to the log. The function is long because the report is detailed, but it is straight-line code with no state of its own.

Events use the same tagged-union idea as commands. An event deck entry has options, each a list of effects:

```zig
pub const Effect = union(enum) {
    cash: types.CBills,
    reputation: i16,
    morale: i8,
    fatigue: u8,
    score: i16,
    damage_random_units: u8,
    damage_convoy_units: u8,
    raise_pct: u8,
    retention_bonus_months: u8,
    let_go,
    replace_from_hall,
    // …
};
```

An inbox rule decides whether an event is a decision or a dice roll: if none of its effects touch money, stock or damage, the sim rolls the default and logs it; otherwise it waits in the inbox with a deadline. That rule is a function over the union tags, and a test asserts it for every deck.

## 26. Persistence: SQLite by hand

The save file is one SQLite database holding every player and campaign. Each campaign's state is spread over about forty tables keyed by campaign ID, one row per entity, with list-valued fields (skills, injuries, awards, force children) in child tables. Saving is a transaction that deletes the campaign's rows and inserts them afresh; loading rebuilds the maps in insertion order so the state hashes the same as before it was saved. A round-trip test checks exactly that.

Schema changes are a list of migrations, each guarded by "does the column exist yet":

*src/persist/store.zig*

```zig
pub const schema_version = 19;

pub const migrations = [_]Migration{
    .{ .version = 15, .table = "person", .column = "shares", .sql = "ALTER TABLE person ADD COLUMN shares INTEGER NOT NULL DEFAULT 0" },
    .{ .version = 16, .table = "person", .column = "born_day", .sql = "ALTER TABLE person ADD COLUMN born_day INTEGER" },
    .{ .version = 17, .table = "person", .column = "last_raise_day", .sql = "ALTER TABLE person ADD COLUMN last_raise_day INTEGER" },
    .{ .version = 19, .table = "listing", .column = "black", .sql = "ALTER TABLE listing ADD COLUMN black INTEGER NOT NULL DEFAULT 0" },
    // …
};
```

New tables need no migration because the DDL uses `CREATE TABLE IF NOT EXISTS`. Data fixes that need Zig logic (giving everyone in an old save a birthday, for instance) run in `upgradeCampaign(gs, from_version)` after load. A store newer than the game is refused with a clear error rather than misread.

One trap worth remembering from this project's history: the binding of a new column to the `INSERT` was once lost when the formatter reflowed a long argument list and an edit missed the new shape. The symptom was a value that saved as NULL. The round-trip test caught it. Persistence code is where "add a field" has four places to touch (struct, DDL, insert, select), and a test that checks the fourth is worth more than care at the first three.

## 27. The terminal client

The client is the one part of the program that is not pure, and it is layered so the impure parts stay small.

**`term.zig`** puts the terminal in raw mode with `tcsetattr`, restores it with a `defer`, reads bytes with a timeout, and decodes them into the `Key` union (section 7). Escape sequences are ambiguous, so a lone `ESC` is recognised by waiting a few milliseconds for nothing to follow. It also sends a graphics-protocol probe at startup and reads the reply, which is how the app learns whether pictures are possible.

**`screen.zig`** is a grid of cells, each a character, a semantic style (amber, good, crit, dim, selected, purple) and optionally two pixel colours for half-block pictures. Drawing writes into the grid; `flush` diffs nothing and simply emits the whole frame as ANSI, which is fast enough at terminal sizes. Panes, titled boxes, padded text and the `{a}…{/}` markup parser live here.

**`app.zig`** is the state machine: a mode (welcome, wizard, game), a tab, per-pane cursors, an optional modal, and the campaign. Its loop is four lines:

```zig
while (self.running) {
    try self.draw();                         // queries → cells → ANSI
    const key = self.term.readKey(500);      // half a second, then redraw anyway (music, resize)
    if (self.music) |*m| m.poll();
    if (key == .none) continue;
    self.handleKey(key) catch |err| self.say(.crit, "error: {s}", .{@errorName(err)});
}
```

`draw` resets the frame arena, then each screen's `drawX` calls queries and paints. `handleKey` dispatches by modal, then mode, then tab, down to a `switch` on the character. A key that changes the game builds a `Command` and calls `self.exec`, which runs `commands.execute` and turns any error into a status-line sentence via `cli.errorText`. The client never touches `GameState` fields to change them; the module boundary in `docs/tui.md` says it may only call `execute`, `parseCommand` and queries, and a reviewer can grep for violations.

The smaller modules do one foreign thing each: `png.zig` decodes 8-bit PNGs (inflate included, no library); `emblem.zig` speaks the kitty and iTerm2 image protocols; `music.zig` runs the system's audio player as a child process and reaps it with `waitpid`; `splash.zig` draws the title.

Because the client is driven by bytes on a file descriptor, it can be tested without a human. `docs/tui_smoke.py` forks it under a pseudo-terminal, sends keystrokes, and asserts on the text that comes back, twice: once at a large size and once at 80 by 24 with `--ascii`. Every screen and most modals are visited in about two minutes. When the market pane was retitled, that script failed on the old title within seconds, which is the point.

## 28. Determinism and the test suite

The whole architecture is summed up by one test:

*src/sim/commands.zig*

```zig
test "golden master: same seed + same script = same state hash" {
    const script = [_]Command{
        .{ .hire = .{ .first = "Grayson", .last = "Carlyle", .role = .mekwarrior } },
        .{ .hire = .{ .first = "Lori", .last = "Kalmar", .role = .mekwarrior } },
        .{ .hire = .{ .first = "Clay", .last = "Cluny", .role = .tech_mek } },
        .{ .advance_days = 45 },
        .{ .fire = @enumFromInt(2) },
        .{ .advance_days = 45 },
    };
    var hashes: [2]u64 = undefined;
    for (&hashes) |*out| {
        var gs = GameState.init(std.testing.allocator, .{ .seed = 42 });
        defer gs.deinit();
        for (script) |cmd| _ = try execute(&gs, cmd);
        out.* = gs.hash();
    }
    try std.testing.expectEqual(hashes[0], hashes[1]);
}
```

Two campaigns, same seed, same script, ninety days each, identical hash. If anyone introduces a wall-clock read, a global counter, an unordered map iteration or a stray PRNG, this test breaks. It is cheap, it runs on every build, and it guards the property everything else depends on.

The rest of the suite is organised by module. Domain tests check rule tables and formulas against known values (an Atlas wants ten maintenance hours, a 300-rated engine weighs 19 tons). Sim tests build a small state, run one phase or command, and assert. Persistence tests round-trip a campaign and load a hand-written old-schema fixture. Data tests cross-check the ZON files. The two smoke scripts cover the frontends. A change is done when `zig build test --summary all` is green and both smokes pass; that sequence appears in every commit of the project's history.

## 29. One keypress, end to end

Take the Forces screen with the cursor on a company, and press `c` to crew it from the hiring halls. Here is everything that happens, layer by layer.

1. **Bytes.** `term.readKey` reads `0x63`, not an escape, not a control byte, so it returns `.{ .char = 'c' }`.

2. **Dispatch.** `App.handleKey`: no modal, mode is `.game`, tab is `.forces`. The Forces branch switches on the character and finds `'c'`. It reads the highlighted row from the last query result to get a `ForceId`, resolves it to a company, and calls `game.commands.execute(g, .{ .crew_company = co })`.

3. **Validate.** The `.crew_company` arm looks up the force, refuses if it is not a company (`Error.NotACompany`) or is deployed (`Error.CompanyDeployed`).

4. **Mutate.** It asks `personnel.manningNeeds` for the company's table, fourteen rows of role, need and reason. For every row where `have < need`: astechs and medics are generated on the spot with `gs.hireFromSpec`; every other role is filled from the hall candidates with `hire_candidate`, which itself debits the signing bonus through `postTreasury`. Whatever the halls could not supply is counted in `still_open`. Then `gs.autoAssign` seats pilots and techs. A log line is written with `gs.log`.

5. **Report.** The arm returns `.{ .hired_count = hired, .still_open = still_open }`. The key handler formats one sentence from those two numbers into the status line with `self.say`.

6. **Redraw.** The loop comes round, `draw` resets the frame arena and calls `queries.toe` and `queries.manning` again. The manning pane's rows now show the new counts and the tech-hours line, because the query recomputes from state every frame. Nothing was cached.

7. **Persist.** Nothing yet. Saving is its own command; when it runs, the new people are rows in the `person` table like any other.

Every layer is visible in the text, and each one can be exercised alone: the command has a test with a seeded hall, the query has a test on a generated company, and the smoke script presses `c` and looks for "hired to fill the manning table" in the output.

## 30. Where to go next

Suggested exercises, in rising order of reach, each touching one layer you have now seen:

1. **A tuning knob.** Pick a constant in `data/tables/tuning.zon`, change it, and find the test that notices. Then make the change in a mod directory instead and build with `-Ddata`.

2. **A query.** Add a line to `queries.personRecord` (the People screen's `r` modal) showing something the record does not yet: the person's monthly salary in the outfit's payroll as a percentage, say. Only one file changes.

3. **A command.** Add `set_leave_days` or similar: a variant in `Command`, an arm in `execute`, a verb in `cli.parseCommand` and its `usage` row, an error text if it can refuse, a test. The compiler will list every switch you must extend.

4. **A tick phase.** Add a small weekly effect (a morale point for a company that has eaten well all week, perhaps). Decide its place in `advanceDay`, write it as a function that takes `*GameState`, test it on a hand-built state, and confirm the golden-master hash still matches itself.

5. **A field that persists.** Add a field to `Person` and carry it through the four places in `store.zig` plus a migration. The round-trip test is your safety net.

Reading order for the source if you want to go deeper: `ARCHITECTURE.md`, then `src/root.zig`, `src/domain/types.zig`, `src/sim/rng.zig`, `src/sim/clock.zig`, `src/sim/state.zig` (skim the fields, read the money and lookup helpers), `src/sim/commands.zig` (the union and a few arms), `src/sim/tick.zig`, one query in `src/sim/queries.zig`, `src/persist/sqlite.zig`, and finally `src/tui/app.zig`'s `run`, `draw` and `handleKey`. That path is a couple of hours and after it nothing in the repository will look unfamiliar.

Written from the project as it stood at commit d77f9de, Zig 0.16, 224 tests.
