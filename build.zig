const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The sim core as the `game` module; src/root.zig is its public surface.
    const mod = b.addModule("game", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Static game data: .zon files imported at comptime by the sim core
    // (e.g. `@import("chassis_zon")` in src/domain/chassis.zig).
    //
    // Mods: `zig build -Ddata=<dir>` overlays any of these files from <dir>
    // (same relative path: <dir>/chassis.zon, <dir>/tables/tuning.zon …).
    // Missing files fall back to data/. The typed structs the tables import
    // into are the schema: a malformed mod fails the build, not the
    // campaign. See docs/modding.md.
    const data_dir = b.option([]const u8, "data", "Directory overlaying data/*.zon and data/tables/*.zon (mod support)");
    const DataFile = struct { import_name: []const u8, rel: []const u8 };
    const data_files = [_]DataFile{
        .{ .import_name = "chassis_zon", .rel = "chassis.zon" },
        .{ .import_name = "planets_zon", .rel = "planets.zon" },
        .{ .import_name = "parts_zon", .rel = "parts.zon" },
        // Tables: tuning knobs, MekLab construction tables, names …
        .{ .import_name = "tuning_zon", .rel = "tables/tuning.zon" },
        .{ .import_name = "meklab_zon", .rel = "tables/meklab.zon" },
        .{ .import_name = "names_zon", .rel = "tables/names.zon" },
        .{ .import_name = "ranks_zon", .rel = "tables/ranks.zon" },
        .{ .import_name = "awards_zon", .rel = "tables/awards.zon" },
        .{ .import_name = "abilities_zon", .rel = "tables/abilities.zon" },
        .{ .import_name = "rat_zon", .rel = "tables/rat.zon" },
        .{ .import_name = "factions_zon", .rel = "tables/factions.zon" },
        .{ .import_name = "scenarios_zon", .rel = "tables/scenarios.zon" },
        .{ .import_name = "terrain_zon", .rel = "tables/terrain.zon" },
        .{ .import_name = "difficulty_zon", .rel = "tables/difficulty.zon" },
        .{ .import_name = "opfor_zon", .rel = "tables/opfor.zon" },
        .{ .import_name = "skulls_zon", .rel = "tables/skulls.zon" },
    };
    // A mod directory that is missing, or that overlays nothing, is a
    // mistake, not a request for stock data: it fails here. A .zon file in
    // it that the build does not read (a misspelled name) is a warning.
    if (data_dir) |dir| {
        var root = (if (std.fs.path.isAbsolute(dir))
            std.Io.Dir.openDirAbsolute(b.graph.io, dir, .{ .iterate = true })
        else
            b.build_root.handle.openDir(b.graph.io, dir, .{ .iterate = true })) catch |err|
            std.process.fatal("-Ddata={s}: not a readable directory ({s}); see docs/modding.md", .{ dir, @errorName(err) });
        defer root.close(b.graph.io);
        for ([_][]const u8{ "", "tables" }) |sub| {
            var d = if (sub.len == 0) root else root.openDir(b.graph.io, sub, .{ .iterate = true }) catch continue;
            defer if (sub.len != 0) d.close(b.graph.io);
            var it = d.iterate();
            while (it.next(b.graph.io) catch null) |e| {
                if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".zon")) continue;
                const rel = if (sub.len == 0) e.name else b.fmt("{s}/{s}", .{ sub, e.name });
                const known = for (data_files) |f| {
                    if (std.mem.eql(u8, f.rel, rel)) break true;
                } else false;
                if (!known) std.log.warn("-Ddata={s}: {s} is not a data file the build reads; it is ignored", .{ dir, rel });
            }
        }
    }
    var overlaid = std.ArrayList([]const u8).empty;
    for (data_files) |f| {
        var path: std.Build.LazyPath = b.path(b.fmt("data/{s}", .{f.rel}));
        if (data_dir) |dir| {
            const candidate = b.pathJoin(&.{ dir, f.rel });
            const exists = if (std.fs.path.isAbsolute(candidate))
                std.Io.Dir.accessAbsolute(b.graph.io, candidate, .{})
            else
                b.build_root.handle.access(b.graph.io, candidate, .{});
            if (exists) |_| {
                path = if (std.fs.path.isAbsolute(candidate)) .{ .cwd_relative = candidate } else b.path(candidate);
                overlaid.append(b.allocator, f.rel) catch @panic("OOM");
            } else |_| {}
        }
        mod.addAnonymousImport(f.import_name, .{ .root_source_file = path });
    }
    if (data_dir) |dir| if (overlaid.items.len == 0)
        std.process.fatal("-Ddata={s}: overlays no data file (expected chassis.zon, parts.zon, planets.zon or tables/<name>.zon); see docs/modding.md", .{dir});
    // What the binary can say about its data (settings screen, REPL banner).
    const build_options = b.addOptions();
    build_options.addOption(?[]const u8, "data_dir", data_dir);
    build_options.addOption([]const []const u8, "data_overlays", overlaid.items);
    mod.addImport("build_options", build_options.createModule());

    // Persistence: the system SQLite library, bound by hand in
    // src/persist/sqlite.zig (no translate-c dependency).
    mod.link_libc = true;
    mod.linkSystemLibrary("sqlite3", .{});

    // The executable: src/main.zig (demo, REPL, `--tui` client) importing `game`.
    const exe = b.addExecutable(.{
        .name = "game",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "game", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    // Packaging: the loose runtime files the binary reads at run time (the
    // .zon tables above are compiled in, these are not). The installed
    // layout is what src/tui/paths.zig looks for second:
    //
    //   zig build -Doptimize=ReleaseFast -Dbundle-music --prefix dist
    //     dist/bin/game
    //     dist/share/iron-ledger/music/<soundtrack>/…
    //     dist/share/iron-ledger/logos/*.png
    //
    // The soundtrack is opt-in: it is a few hundred megabytes, so copying it
    // on every build would make the edit/build loop crawl. Ship it as a
    // separate archive that unpacks into share/iron-ledger/music, or pass
    // -Dbundle-music for a single self-contained tree.
    const bundle_music = b.option(bool, "bundle-music", "Copy data/music into the install prefix (large)") orelse false;
    if (bundle_music) b.installDirectory(.{
        .source_dir = b.path("data/music"),
        .install_dir = .prefix,
        .install_subdir = "share/iron-ledger/music",
    });
    b.installDirectory(.{
        .source_dir = b.path("docs/logos"),
        .install_dir = .prefix,
        .install_subdir = "share/iron-ledger/logos",
        .include_extensions = &.{".png"},
    });

    // `zig build run [-- args]` runs the installed binary.
    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Tests: the `game` module and the executable's root module each run
    // their own test blocks, in parallel.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Data validation: the tests named "data: …" check the tables against
    // each other (every RAT entry is a catalogue mek, every loadout part
    // exists, every string is markup-safe, every tuning knob is in range).
    // `zig build validate-data` runs them alone, and every install waits on
    // them, so broken data (a mod's or the stock tables) fails the build
    // instead of the first game.
    const data_tests = b.addTest(.{
        .root_module = mod,
        .filters = &.{"data: "},
    });
    const run_data_tests = b.addRunArtifact(data_tests);
    const validate_step = b.step("validate-data", "Check the data tables (and any -Ddata mod) against each other");
    validate_step.dependOn(&run_data_tests.step);
    b.getInstallStep().dependOn(&run_data_tests.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    // A green test run also means the client builds: the tests compile the
    // TUI only as tests, so installing the binary here keeps an exe-only
    // compile error from hiding behind a passing suite.
    test_step.dependOn(b.getInstallStep());
}
