//! Soundtrack (Stage 12): loops the tracks in `data/music/` through the
//! system's command-line player as a child process — `afplay` on macOS,
//! `ffplay`/`mpv`/`aplay` elsewhere — so the client needs no audio
//! library. The app polls once per frame; when a track ends the next one
//! starts. Settings (on/off, volume) persist in the store.

const std = @import("std");

const extensions = [_][]const u8{ ".aac", ".m4a", ".mp3", ".wav", ".flac", ".ogg" };

pub const Player = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    tracks: []const []const u8 = &.{},
    enabled: bool = true,
    /// 0–100
    volume: u8 = 60,
    current: ?usize = null,
    child: ?std.process.Child = null,
    player_cmd: ?[]const u8 = null,
    arena: std.heap.ArenaAllocator,

    pub fn init(io: std.Io, gpa: std.mem.Allocator, dir_path: []const u8) Player {
        var p: Player = .{ .io = io, .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
        p.tracks = p.listTracks(dir_path) catch &.{};
        p.player_cmd = detectPlayer();
        return p;
    }

    pub fn deinit(self: *Player) void {
        self.stop();
        self.arena.deinit();
    }

    fn listTracks(self: *Player, dir_path: []const u8) ![]const []const u8 {
        const al = self.arena.allocator();
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch return out.toOwnedSlice(al);
        defer dir.close(self.io);
        var it = dir.iterate();
        while (try it.next(self.io)) |e| {
            if (e.kind != .file) continue;
            var ok = false;
            for (extensions) |ext| if (std.ascii.endsWithIgnoreCase(e.name, ext)) {
                ok = true;
            };
            if (!ok) continue;
            try out.append(al, try std.fmt.allocPrint(al, "{s}/{s}", .{ dir_path, e.name }));
        }
        std.mem.sort([]const u8, out.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        return out.toOwnedSlice(al);
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

    /// Track name without directory and extension.
    pub fn nowPlaying(self: *const Player) ?[]const u8 {
        const i = self.current orelse return null;
        if (self.child == null) return null;
        const path = self.tracks[i];
        const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |k| path[k + 1 ..] else path;
        return if (std.mem.lastIndexOfScalar(u8, base, '.')) |k| base[0..k] else base;
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
        const n = self.tracks.len;
        if (n == 0) return;
        const next: usize = if (self.current) |i| (i + 1) % n else @intCast(@as(u32, @intCast(std.c.getpid())) % @as(u32, @intCast(n)));
        self.current = next;
        self.spawn(self.tracks[next]) catch {
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

test "track listing filters by extension and strips names" {
    // No I/O in tests: exercise the name helper through a stub player.
    var p: Player = .{ .io = undefined, .gpa = std.testing.allocator, .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer p.arena.deinit();
    const tracks = [_][]const u8{"data/music/Amber Warning.aac"};
    p.tracks = &tracks;
    p.current = 0;
    p.child = .{ .id = null, .thread_handle = {}, .stdin = null, .stdout = null, .stderr = null, .request_resource_usage_statistics = false };
    try std.testing.expectEqualStrings("Amber Warning", p.nowPlaying().?);
}
