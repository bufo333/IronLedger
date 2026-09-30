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

    /// Delete a player and all their campaigns.  If `live` is non-null
    /// and the live session's campaign belonged to the deleted player,
    /// its `campaign_id` is reset to 0 (as `deleteCampaign` does).
    pub fn deletePlayer(self: Lobby, player: i64, live: ?*Session) !void {
        // Snapshot whether the live session's campaign belongs to this player
        // before the deletion so we can reset it afterwards.
        const session_cid: i64 = if (live) |s| s.gs.campaign_id else 0;
        var session_owned = false;
        if (session_cid != 0) {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            if (self.store.listCampaignsOf(arena.allocator(), player)) |list| {
                for (list) |c| if (c.id == session_cid) {
                    session_owned = true;
                    break;
                };
            } else |_| {}
        }
        try self.store.deletePlayer(player);
        if (session_owned) live.?.gs.campaign_id = 0;
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
    /// `player_id` is restored to its prior value if the save fails so
    /// a failed first-save does not latch the wrong player (rule 49).
    pub fn save(self: *Lobby, session: *Session, player: i64) !void {
        const prior_id = self.store.player_id;
        self.store.player_id = player;
        errdefer self.store.player_id = prior_id;
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

    /// The new-campaign wizard spec (rule 9 — builder lives in the application
    /// layer, not the frontend).
    pub const WizardSpec = struct {
        commander_name: []const u8,
        origin: @import("../domain/commander.zig").Faction,
        profession: @import("../domain/commander.zig").Profession,
        start_year: u16,
        outfit_name: []const u8,
        company_name: []const u8,
        /// If non-null, `set_emblem` is called on the created company.
        emblem_image: ?[]const u8 = null,
    };

    /// Build a fresh campaign from the wizard spec: creates commander, renames
    /// outfit, creates the first company, optionally sets the emblem. On any
    /// error the session is closed before returning (rule 9 — no half-built
    /// campaigns). The caller must close the returned session on their own error
    /// paths.
    pub fn freshCampaign(gpa: std.mem.Allocator, seed: u64, spec: WizardSpec) !Session {
        const commands = @import("../sim/commands.zig");
        var session = try Session.fresh(gpa, seed);
        errdefer session.close();
        const gs = session.gs;
        _ = try commands.execute(gs, .{ .create_commander = .{ .name = spec.commander_name, .origin = spec.origin, .profession = spec.profession, .start_year = spec.start_year } });
        _ = try commands.execute(gs, .{ .rename_outfit = spec.outfit_name });
        const res = try commands.execute(gs, .{ .new_company = spec.company_name });
        if (spec.emblem_image) |img| {
            _ = try commands.execute(gs, .{ .set_emblem = .{ .force = res.created_force, .image = img } });
        }
        return session;
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

test "deletePlayer resets the live session's campaign_id when it was owned by the deleted player" {
    const sqlite = @import("sqlite.zig");
    const commands = @import("../sim/commands.zig");
    var lobby = Lobby.wrap(try store_mod.Store.fromDb(try sqlite.Db.open(":memory:")));
    defer lobby.close();
    const pid = try lobby.createPlayer("Ada");
    const other = try lobby.createPlayer("Other");

    var session = try Session.fresh(std.testing.allocator, 9);
    defer session.close();
    _ = try commands.execute(session.state(), .{ .create_commander = .{ .name = "C", .origin = .FS, .profession = .paymaster } });
    try lobby.save(&session, pid);
    try std.testing.expect(session.state().campaign_id != 0);

    // Deleting the owning player resets the live session's campaign_id.
    try lobby.deletePlayer(pid, &session);
    try std.testing.expectEqual(@as(i64, 0), session.state().campaign_id);

    // Deleting a different player leaves the session untouched.
    session.state().campaign_id = 42; // arbitrary non-zero
    try lobby.deletePlayer(other, &session);
    try std.testing.expectEqual(@as(i64, 42), session.state().campaign_id);
    session.state().campaign_id = 0; // clean up before close
}

test "save failure does not latch player_id" {
    const sqlite = @import("sqlite.zig");
    const commands = @import("../sim/commands.zig");
    var lobby = Lobby.wrap(try store_mod.Store.fromDb(try sqlite.Db.open(":memory:")));
    defer lobby.close();
    const pid = try lobby.createPlayer("Ada");

    var session = try Session.fresh(std.testing.allocator, 11);
    defer session.close();
    _ = try commands.execute(session.state(), .{ .create_commander = .{ .name = "D", .origin = .FS, .profession = .paymaster } });
    // First save: succeeds, stamps campaign_id.
    try lobby.save(&session, pid);
    const cid = session.state().campaign_id;
    try std.testing.expect(cid != 0);

    // Point campaign_id at a non-existent row so the next save fails.
    session.state().campaign_id = 99999;
    const prior_player_id = lobby.store.player_id;
    lobby.store.player_id = 0; // reset to probe the errdefer path
    try std.testing.expectError(error.NoSuchCampaign, lobby.save(&session, pid));
    // player_id must be restored to what it was before the failed save.
    try std.testing.expectEqual(@as(i64, 0), lobby.store.player_id);
    session.state().campaign_id = cid; // restore for clean close
    _ = prior_player_id;
}

test "freshCampaign builds a saveable session with commander, outfit, company and emblem" {
    const sqlite = @import("sqlite.zig");
    const commander_mod = @import("../domain/commander.zig");
    var lobby = Lobby.wrap(try store_mod.Store.fromDb(try sqlite.Db.open(":memory:")));
    defer lobby.close();
    const pid = try lobby.createPlayer("Ada");
    var session = try Session.freshCampaign(std.testing.allocator, 7, .{
        .commander_name = "Kalmar",
        .origin = .FS,
        .profession = .paymaster,
        .start_year = 3050, // u16
        .outfit_name = "Iron Wolves",
        .company_name = "Alpha Company",
        .emblem_image = "WOLFHEAD",
    });
    defer session.close();
    const gs = session.state();
    try std.testing.expect(gs.commander != null);
    try std.testing.expectEqualStrings("Kalmar", gs.commander.?.name);
    try std.testing.expectEqualStrings("Iron Wolves", gs.outfit_name);
    try std.testing.expect(gs.forces.count() > 0);
    // Emblem was set on the company named "Alpha Company".
    var fit = gs.forces.iterator();
    var found_emblem = false;
    while (fit.next()) |e| {
        if (std.mem.eql(u8, e.value_ptr.name, "Alpha Company")) {
            found_emblem = e.value_ptr.emblem != null;
        }
    }
    try std.testing.expect(found_emblem);
    // Session is saveable.
    try lobby.save(&session, pid);
    try std.testing.expect(gs.campaign_id != 0);
    _ = commander_mod.Profession.paymaster; // ensures import is used
}
