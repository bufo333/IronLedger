//! Soundtrack (Stage 12, reworked on play feedback): every audio file
//! under `data/music/` — loose files form the "default" soundtrack, each
//! sub-directory (`data/music/lyran/`, `data/music/pirates/` …) is a
//! soundtrack of its own — played through the system's command-line
//! player as a child process (`afplay` on macOS, `ffplay`/`mpv`/`aplay`
//! elsewhere), so the client needs no audio library. The playlist is
//! every selected soundtrack mixed together and shuffled, reshuffled each
//! run so the first track differs; one soundtrack can be chosen instead
//! of the mix. The app polls once per frame; when a track ends the next
//! one starts. Settings (on/off, volume, soundtrack) persist in the store.

const std = @import("std");

const extensions = [_][]const u8{ ".aac", ".m4a", ".mp3", ".wav", ".flac", ".ogg" };

pub const Track = struct {
    path: []const u8,
    /// File name without directory and extension.
    name: []const u8,
    /// Index into `sets`.
    set: usize,
};

pub const Player = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    tracks: []const Track = &.{},
    /// Soundtrack names: "default" for loose files, else the sub-directory.
    sets: []const []const u8 = &.{},
    /// null = every soundtrack mixed; else one of `sets`.
    selected_set: ?usize = null,
    /// The shuffled playlist (indexes into `tracks`) and the next slot to play.
    order: []usize = &.{},
    pos: usize = 0,
    enabled: bool = true,
    /// 0–100
    volume: u8 = 60,
    current: ?usize = null,
    child: ?std.process.Child = null,
    player_cmd: ?[]const u8 = null,
    arena: std.heap.ArenaAllocator,
    rng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0),

    pub fn init(io: std.Io, gpa: std.mem.Allocator, dir_path: []const u8) Player {
        var p: Player = .{ .io = io, .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
        // The client may roll dice: a fresh order every launch.
        var seed: u64 = @intCast(@as(u32, @bitCast(std.c.getpid())));
        const now = std.Io.Clock.now(.real, io);
        seed ^= @as(u64, @truncate(@as(u96, @bitCast(now.nanoseconds))));
        p.rng = std.Random.DefaultPrng.init(seed);
        p.scan(dir_path) catch {};
        p.player_cmd = detectPlayer();
        p.rebuild();
        return p;
    }

    pub fn deinit(self: *Player) void {
        self.stop();
        self.arena.deinit();
    }

    fn isAudio(name: []const u8) bool {
        for (extensions) |ext| if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
        return false;
    }

    fn baseName(path: []const u8) []const u8 {
        const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |k| path[k + 1 ..] else path;
        return if (std.mem.lastIndexOfScalar(u8, base, '.')) |k| base[0..k] else base;
    }

    /// Loose files → "default"; each sub-directory → a soundtrack.
    fn scan(self: *Player, dir_path: []const u8) !void {
        const al = self.arena.allocator();
        var tracks: std.ArrayListUnmanaged(Track) = .empty;
        var sets: std.ArrayListUnmanaged([]const u8) = .empty;
        var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var it = dir.iterate();
        var subdirs: std.ArrayListUnmanaged([]const u8) = .empty;
        var loose: usize = 0;
        while (try it.next(self.io)) |e| {
            if (e.kind == .directory) {
                try subdirs.append(al, try al.dupe(u8, e.name));
                continue;
            }
            if (e.kind != .file or !isAudio(e.name)) continue;
            if (loose == 0) try sets.append(al, "default");
            const path = try std.fmt.allocPrint(al, "{s}/{s}", .{ dir_path, e.name });
            try tracks.append(al, .{ .path = path, .name = baseName(path), .set = 0 });
            loose += 1;
        }
        std.mem.sort([]const u8, subdirs.items, {}, lessThan);
        for (subdirs.items) |sub| {
            const sub_path = try std.fmt.allocPrint(al, "{s}/{s}", .{ dir_path, sub });
            var sd = std.Io.Dir.cwd().openDir(self.io, sub_path, .{ .iterate = true }) catch continue;
            defer sd.close(self.io);
            var names: std.ArrayListUnmanaged([]const u8) = .empty;
            var sit = sd.iterate();
            while (try sit.next(self.io)) |e| {
                if (e.kind != .file or !isAudio(e.name)) continue;
                try names.append(al, try std.fmt.allocPrint(al, "{s}/{s}", .{ sub_path, e.name }));
            }
            if (names.items.len == 0) continue;
            std.mem.sort([]const u8, names.items, {}, lessThan);
            const set_index = sets.items.len;
            try sets.append(al, sub);
            for (names.items) |path| try tracks.append(al, .{ .path = path, .name = baseName(path), .set = set_index });
        }
        self.tracks = try tracks.toOwnedSlice(al);
        self.sets = try sets.toOwnedSlice(al);
    }

    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    /// The first command-line player on PATH.
    fn detectPlayer() ?[]const u8 {
        const path = std.mem.span(std.c.getenv("PATH") orelse return null);
        for ([_][]const u8{ "afplay", "mpv", "ffplay", "aplay" }) |cmd| {
            var it = std.mem.tokenizeScalar(u8, path, ':');
            while (it.next()) |dir| {
                var buf: [512]u8 = undefined;
                const full = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, cmd }) catch continue;
                if (std.c.access(full, 1) == 0) return cmd; // X_OK
            }
        }
        return null;
    }

    pub fn available(self: *const Player) bool {
        return self.tracks.len > 0 and self.player_cmd != null;
    }

    /// Rebuild the playlist from the selection and shuffle it (Fisher–Yates).
    pub fn rebuild(self: *Player) void {
        const al = self.arena.allocator();
        var order: std.ArrayListUnmanaged(usize) = .empty;
        for (self.tracks, 0..) |t, i| {
            if (self.selected_set) |s| if (t.set != s) continue;
            order.append(al, i) catch return;
        }
        const r = self.rng.random();
        var i = order.items.len;
        while (i > 1) : (i -= 1) {
            const j = r.uintLessThan(usize, i);
            std.mem.swap(usize, &order.items[i - 1], &order.items[j]);
        }
        self.order = order.toOwnedSlice(al) catch &.{};
        self.pos = 0;
    }

    /// Choose one soundtrack (or null for the mix); the playlist restarts.
    pub fn selectSet(self: *Player, set: ?usize) void {
        if (set) |s| if (s >= self.sets.len) return;
        self.selected_set = set;
        self.rebuild();
        self.stop();
        if (self.enabled) self.startNext();
    }

    pub fn setName(self: *const Player, set: ?usize) []const u8 {
        const s = set orelse return "all soundtracks, mixed";
        return if (s < self.sets.len) self.sets[s] else "?";
    }

    /// Tracks in a soundtrack.
    pub fn setCount(self: *const Player, set: usize) usize {
        var n: usize = 0;
        for (self.tracks) |t| if (t.set == set) {
            n += 1;
        };
        return n;
    }

    pub fn nowPlaying(self: *const Player) ?[]const u8 {
        const i = self.current orelse return null;
        if (self.child == null) return null;
        return self.tracks[i].name;
    }

    pub fn nowPlayingSet(self: *const Player) ?[]const u8 {
        const i = self.current orelse return null;
        if (self.child == null) return null;
        return self.sets[self.tracks[i].set];
    }

    /// Call once per frame: reap a finished track and start the next.
    pub fn poll(self: *Player) void {
        if (!self.enabled or !self.available()) return;
        if (self.child) |*c| {
            const pid = c.id orelse {
                self.child = null;
                return;
            };
            var status: c_int = 0;
            const rc = std.c.waitpid(pid, &status, std.c.W.NOHANG);
            if (rc == 0) return; // still playing
            self.child = null;
        }
        self.startNext();
    }

    fn startNext(self: *Player) void {
        if (self.order.len == 0) return;
        if (self.pos >= self.order.len) {
            self.rebuild(); // a fresh shuffle every time round
        }
        const next = self.order[self.pos];
        self.pos += 1;
        self.current = next;
        self.spawn(self.tracks[next].path) catch {
            self.child = null;
        };
    }

    /// Play one track now; the playlist continues after it.
    pub fn play(self: *Player, track: usize) void {
        if (track >= self.tracks.len) return;
        self.stop();
        self.enabled = true;
        for (self.order, 0..) |t, i| if (t == track) {
            self.pos = i + 1;
        };
        self.current = track;
        self.spawn(self.tracks[track].path) catch {
            self.child = null;
        };
    }

    fn spawn(self: *Player, path: []const u8) !void {
        const cmd = self.player_cmd orelse return error.NoPlayer;
        var vol_buf: [16]u8 = undefined;
        const vol = if (std.mem.eql(u8, cmd, "afplay"))
            try std.fmt.bufPrint(&vol_buf, "{d}.{d:0>2}", .{ self.volume / 100, self.volume % 100 })
        else
            try std.fmt.bufPrint(&vol_buf, "{d}", .{self.volume});
        const argv: []const []const u8 = if (std.mem.eql(u8, cmd, "afplay"))
            &.{ "afplay", "-v", vol, path }
        else if (std.mem.eql(u8, cmd, "mpv"))
            &.{ "mpv", "--no-video", "--really-quiet", try std.fmt.bufPrint(&vol_buf, "--volume={d}", .{self.volume}), path }
        else if (std.mem.eql(u8, cmd, "ffplay"))
            &.{ "ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet", "-volume", vol, path }
        else
            &.{ "aplay", "-q", path };
        self.child = try std.process.spawn(self.io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    }

    pub fn stop(self: *Player) void {
        if (self.child) |*c| {
            if (c.id) |pid| {
                std.posix.kill(pid, .TERM) catch {};
                var status: c_int = 0;
                _ = std.c.waitpid(pid, &status, 0);
            }
            self.child = null;
        }
    }

    pub fn skip(self: *Player) void {
        self.stop();
        if (self.enabled) self.startNext();
    }

    /// Back one track in the playlist.
    pub fn back(self: *Player) void {
        self.stop();
        if (self.order.len == 0) return;
        // pos points past the current track; step back two to land on the previous one.
        self.pos = if (self.pos >= 2) self.pos - 2 else self.order.len - (2 - self.pos);
        if (self.enabled) self.startNext();
    }

    pub fn setEnabled(self: *Player, on: bool) void {
        self.enabled = on;
        if (!on) self.stop();
    }

    /// Volume changes apply from the next track (the player's process
    /// takes its level at launch).
    pub fn setVolume(self: *Player, v: u8) void {
        self.volume = @min(100, v);
    }
};

test "the scan makes a soundtrack of each sub-directory and a default of the loose files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "Amber Warning.aac", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "not audio" });
    try tmp.dir.createDirPath(io, "lyran");
    try tmp.dir.writeFile(io, .{ .sub_path = "lyran/March.mp3", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lyran/Anthem.aac", .data = "x" });
    try tmp.dir.createDirPath(io, "empty");
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    var p: Player = .{ .io = io, .gpa = std.testing.allocator, .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer p.arena.deinit();
    try p.scan(root);
    try std.testing.expectEqual(@as(usize, 3), p.tracks.len);
    try std.testing.expectEqual(@as(usize, 2), p.sets.len); // default + lyran; "empty" has no audio
    try std.testing.expectEqualStrings("default", p.sets[0]);
    try std.testing.expectEqualStrings("lyran", p.sets[1]);
    try std.testing.expectEqualStrings("Amber Warning", p.tracks[0].name);
    try std.testing.expectEqual(@as(usize, 2), p.setCount(1));
    p.rebuild();
    try std.testing.expectEqual(@as(usize, 3), p.order.len);
}

test "the playlist mixes every soundtrack once, shuffled, and a selection filters it" {
    var p: Player = .{ .io = undefined, .gpa = std.testing.allocator, .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .rng = std.Random.DefaultPrng.init(7) };
    defer p.arena.deinit();
    const sets = [_][]const u8{ "default", "lyran", "pirates" };
    const tracks = [_]Track{
        .{ .path = "data/music/Amber Warning.aac", .name = "Amber Warning", .set = 0 },
        .{ .path = "data/music/lyran/March.aac", .name = "March", .set = 1 },
        .{ .path = "data/music/lyran/Anthem.aac", .name = "Anthem", .set = 1 },
        .{ .path = "data/music/pirates/Raid.aac", .name = "Raid", .set = 2 },
    };
    p.sets = &sets;
    p.tracks = &tracks;
    p.rebuild();
    try std.testing.expectEqual(@as(usize, 4), p.order.len);
    var seen = [_]bool{false} ** 4;
    for (p.order) |i| seen[i] = true;
    for (seen) |s| try std.testing.expect(s);
    p.selected_set = 1;
    p.rebuild();
    try std.testing.expectEqual(@as(usize, 2), p.order.len);
    for (p.order) |i| try std.testing.expectEqual(@as(usize, 1), tracks[i].set);
    try std.testing.expectEqualStrings("lyran", p.setName(1));
    try std.testing.expectEqualStrings("all soundtracks, mixed", p.setName(null));
    try std.testing.expectEqual(@as(usize, 2), p.setCount(1));
    // The name helper through a stub child.
    p.current = 3;
    p.child = .{ .id = null, .thread_handle = {}, .stdin = null, .stdout = null, .stderr = null, .request_resource_usage_statistics = false };
    try std.testing.expectEqualStrings("Raid", p.nowPlaying().?);
    try std.testing.expectEqualStrings("pirates", p.nowPlayingSet().?);
}
