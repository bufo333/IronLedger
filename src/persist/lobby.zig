//! The lobby facade (Stage 12, docs/coding-contract.md §1): everything a
//! frontend needs from persistence — players, campaigns, settings, save
//! and load — behind one type, so no screen reaches `store` directly.
//! A `GameState` is handed out as an opaque session handle: the frontend
//! passes it to `commands.execute` and `queries`, and gives it back to
//! `discard`. MekHQ counterpart: `CampaignFactory` + the launcher's
//! campaign list (loosely).

const std = @import("std");
const store_mod = @import("store.zig");
const state_mod = @import("../sim/state.zig");
const GameState = state_mod.GameState;

pub const schema_version = store_mod.schema_version;
pub const PlayerInfo = store_mod.Store.PlayerInfo;
pub const CampaignInfo = store_mod.Store.CampaignInfo;

/// "stock tables (data/)" or the mod overlay in use.
pub const dataProvenance = @import("../root.zig").dataProvenance;

pub const Lobby = struct {
    store: store_mod.Store,

    pub fn open(path: [*:0]const u8) !Lobby {
        return .{ .store = try store_mod.Store.open(path) };
    }

    /// Adopt an open store (tests, the REPL).
    pub fn wrap(store: store_mod.Store) Lobby {
        return .{ .store = store };
    }

    pub fn close(self: Lobby) void {
        self.store.close();
    }

    pub fn players(self: Lobby, alloc: std.mem.Allocator) ![]PlayerInfo {
        return self.store.listPlayers(alloc);
    }

    /// A player's campaigns, most recently saved first.
    pub fn campaigns(self: Lobby, alloc: std.mem.Allocator, player: i64) ![]CampaignInfo {
        return self.store.listCampaignsOf(alloc, player);
    }

    /// Every campaign in the store (the console's `campaigns`).
    pub fn allCampaigns(self: Lobby, alloc: std.mem.Allocator) ![]CampaignInfo {
        return self.store.listCampaigns(alloc);
    }

    pub fn createPlayer(self: Lobby, name: []const u8) !i64 {
        return self.store.createPlayer(name);
    }

    pub fn deletePlayer(self: Lobby, player: i64) !void {
        return self.store.deletePlayer(player);
    }

    /// Delete a saved campaign; a live session that was it becomes unsaved.
    pub fn deleteCampaign(self: Lobby, id: i64, live: ?*Session) !void {
        try self.store.deleteCampaign(id);
        if (live) |session| if (session.gs.campaign_id == id) {
            session.gs.campaign_id = 0;
        };
    }

    pub fn getSetting(self: Lobby, key: []const u8, default: i64) i64 {
        return self.store.getSetting(key, default);
    }

    pub fn setSetting(self: Lobby, key: []const u8, value: i64) !void {
        return self.store.setSetting(key, value);
    }

    /// Save a session under a player (a first save files a new campaign).
    pub fn save(self: *Lobby, session: *Session, player: i64) !void {
        self.store.player_id = player;
        return self.store.save(session.gs);
    }
};

/// One open campaign, owned here rather than by a frontend (rule 9). The
/// campaign lives on the heap for the session's whole life, so its address
/// never moves; frontends reach it only through `state`, to hand to
/// queries and commands, and never create, copy or free one themselves.
pub const Session = struct {
    gpa: std.mem.Allocator,
    gs: *GameState,

    /// A new campaign from a seed (the new-campaign wizard, the REPL's `new`).
    pub fn fresh(gpa: std.mem.Allocator, seed: u64) !Session {
        const gs = try gpa.create(GameState);
        gs.* = GameState.init(gpa, .{ .seed = seed });
        return .{ .gpa = gpa, .gs = gs };
    }

    /// A saved campaign, fully loaded or refused (`NoSuchCampaign`,
    /// `SaveNewerThanGame`, `CorruptSave`).
    pub fn load(lobby: Lobby, gpa: std.mem.Allocator, id: i64) !Session {
        const gs = try gpa.create(GameState);
        errdefer gpa.destroy(gs);
        gs.* = try lobby.store.load(gpa, id);
        return .{ .gpa = gpa, .gs = gs };
    }

    /// The campaign, for queries and commands.
    pub fn state(self: Session) *GameState {
        return self.gs;
    }

    pub fn close(self: *Session) void {
        self.gs.deinit();
        self.gpa.destroy(self.gs);
        self.* = undefined;
    }
};

test "lobby: a generated session saves and lists under its player" {
    const sqlite = @import("sqlite.zig");
    var lobby = Lobby.wrap(try store_mod.Store.fromDb(try sqlite.Db.open(":memory:")));
    defer lobby.close();
    const pid = try lobby.createPlayer("Ada");
    var session = try Session.fresh(std.testing.allocator, 7);
    defer session.close();
    _ = try @import("../sim/commands.zig").execute(session.state(), .{ .create_commander = .{ .name = "T", .origin = .FS, .profession = .paymaster } });
    try lobby.save(&session, pid);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const list = try lobby.campaigns(arena.allocator(), pid);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expect(session.state().campaign_id != 0);
    var again = try Session.load(lobby, std.testing.allocator, session.state().campaign_id);
    defer again.close();
    const digest = @import("../sim/digest.zig");
    try std.testing.expectEqual(digest.stateHash(session.state()), digest.stateHash(again.state()));
}
