//! Where the client's loose runtime files live (Stage 12, packaging).
//! No MekHQ counterpart in the sim sense; MekHQ resolves its user directory
//! the same way (`MekHQ.getCampaignsDirectory`).
//!
//! Everything under `data/*.zon` is compiled into the binary, but the
//! soundtrack, the emblem pictures and the save store are read from disk at
//! run time — so an installed copy has to find them without depending on the
//! working directory. Asset roots are tried in order, first hit wins:
//!
//!   1. `--data <dir>` or `$IRON_LEDGER_DATA`     an explicit choice
//!   2. `<exe dir>/../share/iron-ledger`          an install prefix
//!   3. `<exe dir>/data`                          unpacked next to the binary
//!   4. `./data`                                  the source tree
//!
//! A root holds `music/` (one sub-directory per soundtrack) and `logos/`.
//! Nothing here is required: a missing root just means no soundtrack.

const std = @import("std");

const native_os = @import("builtin").os.tag;

/// Environment variable naming an asset root explicitly.
pub const env_var = "IRON_LEDGER_DATA";
/// The save store's file name, wherever it ends up living.
pub const store_name = "campaigns.db";

const music_sub = "music";
const logos_sub = "logos";

/// Pictures the source tree keeps outside `data/`; the wizard has always
/// offered them, so they stay in the list after the roots.
const source_logo_dirs = [_][]const u8{ ".", "logos", "docs/logos" };

pub const Roots = struct {
    /// Directory holding the soundtracks, null when no root had one.
    music: ?[]const u8 = null,
    /// Directories to scan for emblem pictures, nearest first.
    logos: []const []const u8 = &.{},
};

/// The asset roots to try, in order. `exe_dir` is null when the executable's
/// own path could not be read (the roots then reduce to the source tree).
fn rootCandidates(al: std.mem.Allocator, exe_dir: ?[]const u8, override: ?[]const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    if (override) |d| try out.append(al, try al.dupe(u8, d));
    if (exe_dir) |d| {
        try out.append(al, try std.fs.path.join(al, &.{ d, "..", "share", "iron-ledger" }));
        try out.append(al, try std.fs.path.join(al, &.{ d, "data" }));
    }
    try out.append(al, try al.dupe(u8, "data"));
    return out.toOwnedSlice(al);
}

fn isDir(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

/// Find the loose runtime files. Paths are owned by `al` (give it an arena
/// that outlives the app). Failures are not fatal: an empty `Roots` means the
/// client runs without a soundtrack or imported pictures.
pub fn resolve(io: std.Io, al: std.mem.Allocator, env: *const std.process.Environ.Map, override: ?[]const u8) Roots {
    return resolveFailing(io, al, env, override) catch .{};
}

fn resolveFailing(io: std.Io, al: std.mem.Allocator, env: *const std.process.Environ.Map, override: ?[]const u8) !Roots {
    const exe_dir: ?[]const u8 = std.process.executableDirPathAlloc(io, al) catch null;
    const chosen = if (override) |o| o else env.get(env_var);
    var music: ?[]const u8 = null;
    var logos: std.ArrayListUnmanaged([]const u8) = .empty;
    for (try rootCandidates(al, exe_dir, chosen)) |root| {
        const m = try std.fs.path.join(al, &.{ root, music_sub });
        if (music == null and isDir(io, m)) music = m;
        const l = try std.fs.path.join(al, &.{ root, logos_sub });
        if (isDir(io, l)) try logos.append(al, l);
    }
    for (source_logo_dirs) |d| if (isDir(io, d)) try logos.append(al, try al.dupe(u8, d));
    return .{ .music = music, .logos = try logos.toOwnedSlice(al) };
}

/// The platform's per-user data directory, or null when the environment does
/// not say where home is.
fn userDataDir(al: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]const u8 {
    return switch (native_os) {
        .macos => if (env.get("HOME")) |h|
            try std.fs.path.join(al, &.{ h, "Library", "Application Support", "IRON LEDGER" })
        else
            null,
        .windows => if (env.get("APPDATA")) |a|
            try std.fs.path.join(al, &.{ a, "IRON LEDGER" })
        else
            null,
        else => if (env.get("XDG_DATA_HOME")) |x|
            try std.fs.path.join(al, &.{ x, "iron-ledger" })
        else if (env.get("HOME")) |h|
            try std.fs.path.join(al, &.{ h, ".local", "share", "iron-ledger" })
        else
            null,
    };
}

/// Where campaigns are saved when `--store` was not given: a `campaigns.db`
/// in the working directory wins (the source tree, and a portable copy that
/// keeps its saves beside it), otherwise the per-user data directory.
pub fn defaultStore(io: std.Io, al: std.mem.Allocator, env: *const std.process.Environ.Map) ![:0]const u8 {
    if (std.Io.Dir.cwd().access(io, store_name, .{})) |_| return al.dupeZ(u8, store_name) else |_| {}
    const dir = (userDataDir(al, env) catch null) orelse return al.dupeZ(u8, store_name);
    std.Io.Dir.cwd().createDirPath(io, dir) catch return al.dupeZ(u8, store_name);
    return std.fs.path.joinZ(al, &.{ dir, store_name });
}

test "asset roots run explicit choice, install prefix, portable, source tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    const with_exe = try rootCandidates(al, "/opt/iron/bin", "/mods/mine");
    try std.testing.expectEqual(@as(usize, 4), with_exe.len);
    try std.testing.expectEqualStrings("/mods/mine", with_exe[0]);
    try std.testing.expectEqualStrings("/opt/iron/bin/../share/iron-ledger", with_exe[1]);
    try std.testing.expectEqualStrings("/opt/iron/bin/data", with_exe[2]);
    try std.testing.expectEqualStrings("data", with_exe[3]);

    // No executable path and no override: only the source tree is left.
    const bare = try rootCandidates(al, null, null);
    try std.testing.expectEqual(@as(usize, 1), bare.len);
    try std.testing.expectEqualStrings("data", bare[0]);
}

test "the user data directory follows the platform convention" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    var env = std.process.Environ.Map.init(al);
    defer env.deinit();

    const want = switch (native_os) {
        .macos => blk: {
            try env.put("HOME", "/Users/mercs");
            break :blk "/Users/mercs/Library/Application Support/IRON LEDGER";
        },
        .windows => blk: {
            try env.put("APPDATA", "C:\\Users\\mercs\\AppData\\Roaming");
            break :blk "C:\\Users\\mercs\\AppData\\Roaming\\IRON LEDGER";
        },
        else => blk: {
            try env.put("HOME", "/home/mercs");
            break :blk "/home/mercs/.local/share/iron-ledger";
        },
    };
    try std.testing.expectEqualStrings(want, (try userDataDir(al, &env)).?);

    var empty = std.process.Environ.Map.init(al);
    defer empty.deinit();
    try std.testing.expect((try userDataDir(al, &empty)) == null);
}

test "XDG_DATA_HOME wins over HOME where it applies" {
    if (native_os == .macos or native_os == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    var env = std.process.Environ.Map.init(al);
    defer env.deinit();
    try env.put("HOME", "/home/mercs");
    try env.put("XDG_DATA_HOME", "/home/mercs/.share");
    try std.testing.expectEqualStrings("/home/mercs/.share/iron-ledger", (try userDataDir(al, &env)).?);
}
