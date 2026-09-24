//! The save store (Stage 11): one SQLite file holds many campaigns. Every
//! table carries a campaign id; `campaign` is the registry. Saving rewrites
//! a campaign's rows inside one transaction; loading rebuilds a GameState
//! from them; deleting a campaign removes it and starts nothing else.
//!
//! The sim core never touches SQL — this module maps GameState ↔ rows.
//! docs/schema.sql remains the design document; this DDL is the executable
//! truth and stays close to it.
//! MekHQ counterpart: the campaign save and load (XML there, SQLite here)
//! (docs/mekhq-map.md).

const std = @import("std");
const rng_mod = @import("../sim/rng.zig");
const sqlite = @import("sqlite.zig");
const types = @import("../domain/types.zig");
const state_mod = @import("../sim/state.zig");
const GameState = state_mod.GameState;
const person_mod = @import("../domain/person.zig");
const unit_mod = @import("../domain/unit.zig");
const force_mod = @import("../domain/force.zig");
const after_action_mod = @import("../sim/after_action.zig");
const autoresolve_mod = @import("../sim/autoresolve.zig");
const hq_mod = @import("../domain/hq.zig");
const contract_mod = @import("../domain/contract.zig");
const commander_mod = @import("../domain/commander.zig");
const finance_mod = @import("../econ/finance.zig");
const market_mod = @import("../econ/market.zig");
const events_mod = @import("../sim/events.zig");
const contract_events = @import("../sim/contract_events.zig");
const network = @import("../sim/network.zig");
const clock_mod = @import("../sim/clock.zig");

pub const schema_version = 34;

const ddl =
    \\CREATE TABLE IF NOT EXISTS player (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, created_seq INTEGER NOT NULL);
    \\CREATE TABLE IF NOT EXISTS setting (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
    \\CREATE TABLE IF NOT EXISTS campaign (id INTEGER PRIMARY KEY, name TEXT NOT NULL, commander TEXT, day INTEGER NOT NULL, date TEXT NOT NULL, schema_version INTEGER NOT NULL, save_seq INTEGER NOT NULL, player_id INTEGER NOT NULL DEFAULT 0);
    \\CREATE TABLE IF NOT EXISTS meta (cid INTEGER NOT NULL, key TEXT NOT NULL, value INTEGER NOT NULL, PRIMARY KEY (cid, key));
    \\CREATE TABLE IF NOT EXISTS meta_text (cid INTEGER NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (cid, key));
    \\CREATE TABLE IF NOT EXISTS rng (cid INTEGER PRIMARY KEY, state BLOB NOT NULL);
    \\CREATE TABLE IF NOT EXISTS rng_stream (cid INTEGER NOT NULL, stream TEXT NOT NULL, format INTEGER NOT NULL, state BLOB NOT NULL, UNIQUE (cid, stream));
    \\CREATE TABLE IF NOT EXISTS commander (cid INTEGER PRIMARY KEY, name TEXT NOT NULL, origin TEXT NOT NULL, profession TEXT NOT NULL);
    \\CREATE TABLE IF NOT EXISTS person (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, first TEXT, last TEXT, callsign TEXT, role TEXT, xp INTEGER, status TEXT, fatigue INTEGER, morale INTEGER, recruited_day INTEGER, salary_override INTEGER, assigned_force INTEGER, posted_hq INTEGER, weekly_hours INTEGER, medbay_priority INTEGER, leave_until INTEGER, wound_heal_day INTEGER, training_skill TEXT, training_done INTEGER, admitted INTEGER NOT NULL DEFAULT 0, rank TEXT NOT NULL DEFAULT 'private', rank_pinned INTEGER NOT NULL DEFAULT 0, kills INTEGER NOT NULL DEFAULT 0, kill_bv INTEGER NOT NULL DEFAULT 0, battles INTEGER NOT NULL DEFAULT 0, tours INTEGER NOT NULL DEFAULT 0, outstanding_tours INTEGER NOT NULL DEFAULT 0, edge_spent INTEGER NOT NULL DEFAULT 0, faction TEXT NOT NULL DEFAULT '', shares INTEGER NOT NULL DEFAULT 0, born_day INTEGER, last_raise_day INTEGER, last_award_day INTEGER, departed_day INTEGER, PRIMARY KEY (cid, id));
    \\CREATE TABLE IF NOT EXISTS award (cid INTEGER NOT NULL, person_id INTEGER NOT NULL, key TEXT NOT NULL);
    \\CREATE TABLE IF NOT EXISTS ability (cid INTEGER NOT NULL, person_id INTEGER NOT NULL, key TEXT NOT NULL);
    \\CREATE TABLE IF NOT EXISTS person_skill (cid INTEGER NOT NULL, person_id INTEGER NOT NULL, skill TEXT NOT NULL, level INTEGER NOT NULL);
    \\CREATE TABLE IF NOT EXISTS injury (cid INTEGER NOT NULL, person_id INTEGER NOT NULL, ord INTEGER NOT NULL, location TEXT NOT NULL, severity INTEGER NOT NULL, incurred INTEGER NOT NULL, heal_done INTEGER, doctor INTEGER NOT NULL DEFAULT 0, permanent INTEGER NOT NULL DEFAULT 0, healed INTEGER NOT NULL DEFAULT 0);
    \\CREATE TABLE IF NOT EXISTS unit (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, chassis_key TEXT, name TEXT, kind TEXT, force INTEGER, pilot INTEGER, tech INTEGER, armor_pct INTEGER, quality TEXT, status TEXT, last_maint INTEGER, acquired_day INTEGER, price INTEGER, reactivation_done INTEGER, berth_hq INTEGER NOT NULL DEFAULT 0, wreck TEXT NOT NULL DEFAULT 'none', held_by TEXT NOT NULL DEFAULT '', held_day INTEGER NOT NULL DEFAULT 0, held_battle INTEGER NOT NULL DEFAULT 0, held_force INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (cid, id));
    \\CREATE TABLE IF NOT EXISTS unit_slot (cid INTEGER NOT NULL, unit_id INTEGER NOT NULL, ord INTEGER NOT NULL, slot_key TEXT, part_key TEXT, class TEXT, condition TEXT);
    \\CREATE TABLE IF NOT EXISTS force (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, parent INTEGER, name TEXT, emblem BLOB, local_funds INTEGER, echelon TEXT, commander INTEGER, supplying_hq INTEGER, role TEXT, support_kind TEXT, last_rotation INTEGER, contracts_since_rotation INTEGER, location_planet TEXT, return_eta INTEGER, shortage_days INTEGER, roe TEXT NOT NULL DEFAULT 'standard', PRIMARY KEY (cid, id));
    \\CREATE TABLE IF NOT EXISTS force_unit (cid INTEGER NOT NULL, force_id INTEGER NOT NULL, ord INTEGER NOT NULL, unit_id INTEGER NOT NULL);
    \\CREATE TABLE IF NOT EXISTS force_child (cid INTEGER NOT NULL, force_id INTEGER NOT NULL, ord INTEGER NOT NULL, child_id INTEGER NOT NULL);
    \\CREATE TABLE IF NOT EXISTS stock (cid INTEGER NOT NULL, owner_kind TEXT NOT NULL, owner_id INTEGER NOT NULL, ord INTEGER NOT NULL, key TEXT NOT NULL, qty INTEGER NOT NULL);
    \\CREATE TABLE IF NOT EXISTS hq (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, name TEXT, tier TEXT, planet TEXT, staff_assigned INTEGER, upkeep INTEGER, funds INTEGER, PRIMARY KEY (cid, id));
    \\CREATE TABLE IF NOT EXISTS hq_facility (cid INTEGER NOT NULL, hq_id INTEGER NOT NULL, ord INTEGER NOT NULL, kind TEXT, level INTEGER);
    \\CREATE TABLE IF NOT EXISTS hq_project (cid INTEGER NOT NULL, hq_id INTEGER NOT NULL, ord INTEGER NOT NULL, kind TEXT, facility TEXT, target_level INTEGER, started INTEGER, paperwork_done INTEGER, construction_done INTEGER, cost INTEGER);
    \\CREATE TABLE IF NOT EXISTS contract (cid INTEGER NOT NULL, is_offer INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER, kind TEXT, employer TEXT, enemy TEXT, planet TEXT, status TEXT, company INTEGER, start_day INTEGER, score INTEGER, dist_ly INTEGER, beachhead INTEGER, transit_days INTEGER, arrive_day INTEGER, end_day INTEGER, monthly_net INTEGER, next_battle INTEGER, battles INTEGER, casualties INTEGER, objective TEXT, committed_bv INTEGER, pool INTEGER, pool_remaining INTEGER, vp INTEGER, ineffective_since INTEGER, breach_day INTEGER, length_months INTEGER, base_pay INTEGER, advance_pct INTEGER, signing_bonus INTEGER, transport_pct INTEGER, overhead_pct INTEGER, battle_loss_pct INTEGER, salvage_pct INTEGER, salvage_exchange INTEGER, command_rights TEXT, negotiated INTEGER NOT NULL DEFAULT 0, enemy_lances INTEGER NOT NULL DEFAULT 0, enemy_quality TEXT NOT NULL DEFAULT 'regular', enemy_lance_bv INTEGER NOT NULL DEFAULT 0, enemy_lance_tons INTEGER NOT NULL DEFAULT 0, offer_hq INTEGER NOT NULL DEFAULT 0, orders_day INTEGER);
    \\CREATE TABLE IF NOT EXISTS txn (cid INTEGER NOT NULL, ord INTEGER NOT NULL, day INTEGER, amount INTEGER, category TEXT, company INTEGER, hq INTEGER, contract INTEGER, note TEXT);
    \\CREATE TABLE IF NOT EXISTS loan (cid INTEGER NOT NULL, ord INTEGER NOT NULL, principal INTEGER, balance INTEGER, rate_bp INTEGER, term INTEGER, next_pay INTEGER, payment INTEGER);
    \\CREATE TABLE IF NOT EXISTS courier (cid INTEGER NOT NULL, ord INTEGER NOT NULL, to_kind TEXT, to_id INTEGER, amount INTEGER, sent INTEGER, eta INTEGER);
    \\CREATE TABLE IF NOT EXISTS policy (cid INTEGER NOT NULL, ord INTEGER NOT NULL, entity_kind TEXT, entity_id INTEGER, floor INTEGER, cap INTEGER, sent INTEGER NOT NULL DEFAULT 0);
    \\CREATE TABLE IF NOT EXISTS supply_policy (cid INTEGER NOT NULL, ord INTEGER NOT NULL, company INTEGER, min_days INTEGER, tons INTEGER, ammo_battles INTEGER NOT NULL DEFAULT 0);
    \\CREATE TABLE IF NOT EXISTS stock_policy (cid INTEGER NOT NULL, ord INTEGER NOT NULL, hq INTEGER, part_key TEXT, min_qty INTEGER, target INTEGER);
    \\CREATE TABLE IF NOT EXISTS bay_job (cid INTEGER NOT NULL, ord INTEGER NOT NULL, hq INTEGER, kind TEXT, unit INTEGER, item_key TEXT, duration INTEGER, queued INTEGER, started INTEGER, done INTEGER, cost INTEGER);
    \\CREATE TABLE IF NOT EXISTS candidate (cid INTEGER NOT NULL, ord INTEGER NOT NULL, hq INTEGER, first TEXT, last TEXT, callsign TEXT, role TEXT, experience TEXT, primary_skill INTEGER, secondary_skill INTEGER, bonus INTEGER, listed INTEGER, expires INTEGER, age INTEGER NOT NULL DEFAULT 30);
    \\CREATE TABLE IF NOT EXISTS hq_link (cid INTEGER NOT NULL, ord INTEGER NOT NULL, a INTEGER, b INTEGER, level INTEGER, tons INTEGER, established INTEGER);
    \\CREATE TABLE IF NOT EXISTS unit_transfer (cid INTEGER NOT NULL, ord INTEGER NOT NULL, unit INTEGER, to_company INTEGER, eta INTEGER);
    \\CREATE TABLE IF NOT EXISTS faction_cooling (cid INTEGER NOT NULL, ord INTEGER NOT NULL, faction TEXT, until_day INTEGER);
    \\CREATE TABLE IF NOT EXISTS faction_standing (cid INTEGER NOT NULL, faction TEXT NOT NULL, value INTEGER NOT NULL);
    \\CREATE TABLE IF NOT EXISTS event_memory (cid INTEGER NOT NULL, kind TEXT NOT NULL, last_day INTEGER NOT NULL, last_choice INTEGER NOT NULL, streak INTEGER NOT NULL);
    \\CREATE TABLE IF NOT EXISTS rating_snapshot (cid INTEGER NOT NULL, year INTEGER NOT NULL, score INTEGER NOT NULL);
    \\CREATE TABLE IF NOT EXISTS listing (cid INTEGER NOT NULL, ord INTEGER NOT NULL, kind TEXT, item_key TEXT, rarity TEXT, price INTEGER, qty INTEGER, staple INTEGER, listed INTEGER, expires INTEGER, hq INTEGER, c_armor INTEGER, c_quality TEXT, c_damaged INTEGER, c_destroyed INTEGER, c_missing INTEGER, black INTEGER NOT NULL DEFAULT 0, company INTEGER NOT NULL DEFAULT 0);
    \\CREATE TABLE IF NOT EXISTS part_order (cid INTEGER NOT NULL, ord INTEGER NOT NULL, part_key TEXT, qty INTEGER, dest_kind TEXT, dest_id INTEGER, ordered INTEGER, eta INTEGER, cost INTEGER, status TEXT);
    \\CREATE TABLE IF NOT EXISTS event_log (cid INTEGER NOT NULL, ord INTEGER NOT NULL, day INTEGER, category TEXT, company INTEGER, hq INTEGER, contract INTEGER, text TEXT);
    \\CREATE TABLE IF NOT EXISTS pending_event (cid INTEGER NOT NULL, ord INTEGER NOT NULL, kind TEXT, day INTEGER, contract INTEGER, company INTEGER, default_choice INTEGER, deadline INTEGER, chosen INTEGER, person INTEGER NOT NULL DEFAULT 0, id INTEGER NOT NULL DEFAULT 0, battle INTEGER NOT NULL DEFAULT 0);
    \\CREATE TABLE IF NOT EXISTS refit_plan (cid INTEGER NOT NULL, ord INTEGER NOT NULL, unit INTEGER, committed INTEGER);
    \\CREATE TABLE IF NOT EXISTS refit_op (cid INTEGER NOT NULL, plan_ord INTEGER NOT NULL, ord INTEGER NOT NULL, kind TEXT, slot_key TEXT, location TEXT, part_key TEXT);
    \\CREATE TABLE IF NOT EXISTS battle_report (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER, day INTEGER, contract INTEGER, company INTEGER, kind TEXT, enemy_key TEXT, scenario TEXT, terrain TEXT, weather TEXT, outcome TEXT, held_field INTEGER, withdrew INTEGER, roe TEXT, roe_overridden INTEGER, player_power INTEGER, enemy_power INTEGER, conditions_mod INTEGER, close_terrain INTEGER, air_grounded INTEGER, convoy_hit INTEGER, edge_spent_by TEXT, recon_quality INTEGER, avg_fatigue INTEGER, avg_morale INTEGER, hits_taken INTEGER, destroyed INTEGER, wounded INTEGER, kia INTEGER, lost_hulls INTEGER, missing INTEGER, enemy_destroyed_bv INTEGER, kills_credited INTEGER, prisoners INTEGER, battle_loss_comp INTEGER, score_after INTEGER, score_delta INTEGER, morale_delta INTEGER, fatigue_add INTEGER, battle_loss_pct INTEGER, salvage_pct INTEGER, command_rights TEXT, silenced_mounts INTEGER, armor_left INTEGER, salvage_claimed INTEGER, salvage_haulable INTEGER, salvage_cut INTEGER, salvage_cash INTEGER, salvage_items TEXT, conceded INTEGER, acknowledged INTEGER NOT NULL DEFAULT 1, salvage_unclaimed INTEGER NOT NULL DEFAULT 0);
    \\CREATE TABLE IF NOT EXISTS battle_report_hit (cid INTEGER NOT NULL, report_ord INTEGER NOT NULL, ord INTEGER NOT NULL, unit INTEGER, chassis_key TEXT, chassis_name TEXT, armor_before INTEGER, armor_after INTEGER, slot TEXT, slot_part TEXT, slot_result TEXT, destroyed INTEGER, cause TEXT, pilot INTEGER, crew_name TEXT, wound_severity INTEGER, wound_location TEXT, wound_permanent INTEGER, fate TEXT, recovery_roll INTEGER, recovery_target INTEGER, lost INTEGER);
    \\CREATE TABLE IF NOT EXISTS battle_report_ammo (cid INTEGER NOT NULL, report_ord INTEGER NOT NULL, ord INTEGER NOT NULL, family TEXT, burned INTEGER, reserve INTEGER);
    \\CREATE TABLE IF NOT EXISTS battle_report_salvage (cid INTEGER NOT NULL, report_ord INTEGER NOT NULL, ord INTEGER NOT NULL, key TEXT, name TEXT, bv INTEGER, armor_pct INTEGER, quality TEXT, damaged INTEGER, destroyed INTEGER, missing INTEGER);
;

const tables = [_][]const u8{
    "meta",          "meta_text",    "rng",             "commander",        "person",            "person_skill",       "injury",                "award",       "ability",
    "unit",          "unit_slot",    "force",           "force_unit",       "force_child",       "stock",              "hq",                    "hq_facility", "hq_project",
    "contract",      "txn",          "loan",            "courier",          "policy",            "bay_job",            "candidate",             "hq_link",     "unit_transfer",
    "supply_policy", "stock_policy", "faction_cooling", "faction_standing", "event_memory",      "listing",            "part_order",            "event_log",   "pending_event",
    "refit_plan",    "refit_op",     "rating_snapshot", "battle_report",    "battle_report_hit", "battle_report_ammo", "battle_report_salvage", "rng_stream",
};

/// The stream order of the single `rng` blob that saves before schema v32
/// hold: the generator states, one after another, in this order.
const legacy_rng_order = [_]rng_mod.Stream{ .generation, .market, .maintenance, .acquisition, .battle, .events, .medical, .travel };

pub const Store = struct {
    db: sqlite.Db,
    /// The player new campaigns are filed under; 0 = none.
    player_id: i64 = 0,

    /// One schema step: the version it brings the store to, and the column
    /// it adds. `CREATE TABLE IF NOT EXISTS` in `ddl` covers
    /// new tables; columns on existing tables are the only thing SQLite
    /// makes us migrate by hand. Steps are idempotent (column-guarded) so a
    /// store that predates the version key still upgrades cleanly.
    pub const Migration = struct { version: u32, table: []const u8, column: []const u8, sql: [*:0]const u8 };
    pub const migrations = [_]Migration{
        .{ .version = 2, .table = "campaign", .column = "player_id", .sql = "ALTER TABLE campaign ADD COLUMN player_id INTEGER NOT NULL DEFAULT 0" },
        .{ .version = 3, .table = "person", .column = "admitted", .sql = "ALTER TABLE person ADD COLUMN admitted INTEGER NOT NULL DEFAULT 0" },
        .{ .version = 4, .table = "policy", .column = "sent", .sql = "ALTER TABLE policy ADD COLUMN sent INTEGER NOT NULL DEFAULT 0" },
        .{ .version = 5, .table = "supply_policy", .column = "ammo_battles", .sql = "ALTER TABLE supply_policy ADD COLUMN ammo_battles INTEGER NOT NULL DEFAULT 0" },
        .{ .version = 6, .table = "unit", .column = "berth_hq", .sql = "ALTER TABLE unit ADD COLUMN berth_hq INTEGER NOT NULL DEFAULT 0" },
        // v29: a hull the enemy holds rides in the `unit` table with
        // its own slots, distinguished only by a non-empty `held_by`.
        .{ .version = 29, .table = "unit", .column = "held_by", .sql = "ALTER TABLE unit ADD COLUMN held_by TEXT NOT NULL DEFAULT ''" },
        .{ .version = 29, .table = "unit", .column = "held_day", .sql = "ALTER TABLE unit ADD COLUMN held_day INTEGER NOT NULL DEFAULT 0" },
        .{ .version = 29, .table = "unit", .column = "held_battle", .sql = "ALTER TABLE unit ADD COLUMN held_battle INTEGER NOT NULL DEFAULT 0" },
        // v30: a battle decision names the engagement it answers,
        // and a hull won back goes home to the lance it was taken from.
        .{ .version = 30, .table = "pending_event", .column = "battle", .sql = "ALTER TABLE pending_event ADD COLUMN battle INTEGER NOT NULL DEFAULT 0" },
        .{ .version = 30, .table = "unit", .column = "held_force", .sql = "ALTER TABLE unit ADD COLUMN held_force INTEGER NOT NULL DEFAULT 0" },
        // v31: the part of a haul still to be divided. Older saves
        // have no undivided hauls — their salvage was taken at claim time.
        .{ .version = 31, .table = "battle_report", .column = "salvage_unclaimed", .sql = "ALTER TABLE battle_report ADD COLUMN salvage_unclaimed INTEGER NOT NULL DEFAULT 0" },
        .{ .version = 33, .table = "contract", .column = "orders_day", .sql = "ALTER TABLE contract ADD COLUMN orders_day INTEGER" },
        // v34: a hall candidate keeps the age it was generated with.
        .{ .version = 34, .table = "candidate", .column = "age", .sql = "ALTER TABLE candidate ADD COLUMN age INTEGER NOT NULL DEFAULT 30" },
        // v7: the `injury` table (created by ddl); campaign data is
        // upgraded on load (`upgradeCampaign`). v8: `faction_standing`
        // (created by ddl; absent rows read as 0).
        .{ .version = 9, .table = "pending_event", .column = "person", .sql = "ALTER TABLE pending_event ADD COLUMN person INTEGER NOT NULL DEFAULT 0" },
        .{ .version = 10, .table = "contract", .column = "negotiated", .sql = "ALTER TABLE contract ADD COLUMN negotiated INTEGER NOT NULL DEFAULT 0" },
        .{ .version = 11, .table = "person", .column = "rank", .sql = "ALTER TABLE person ADD COLUMN rank TEXT NOT NULL DEFAULT 'private'" },
        .{ .version = 11, .table = "person", .column = "rank_pinned", .sql = "ALTER TABLE person ADD COLUMN rank_pinned INTEGER NOT NULL DEFAULT 0" },
        .{ .version = 12, .table = "person", .column = "kills", .sql = "ALTER TABLE person ADD COLUMN kills INTEGER NOT NULL DEFAULT 0" },
        .{ .version = 12, .table = "person", .column = "kill_bv", .sql = "ALTER TABLE person ADD COLUMN kill_bv INTEGER NOT NULL DEFAULT 0" },
        .{ .version = 12, .table = "person", .column = "battles", .sql = "ALTER TABLE person ADD COLUMN battles INTEGER NOT NULL DEFAULT 0" },
        .{ .version = 12, .table = "person", .column = "tours", .sql = "ALTER TABLE person ADD COLUMN tours INTEGER NOT NULL DEFAULT 0" },
        .{ .version = 12, .table = "person", .column = "outstanding_tours", .sql = "ALTER TABLE person ADD COLUMN outstanding_tours INTEGER NOT NULL DEFAULT 0" },
        // v12 also adds the `award` table (created by ddl).
        .{ .version = 13, .table = "person", .column = "edge_spent", .sql = "ALTER TABLE person ADD COLUMN edge_spent INTEGER NOT NULL DEFAULT 0" },
        // v13 also adds the `ability` table (created by ddl).
        .{ .version = 14, .table = "person", .column = "faction", .sql = "ALTER TABLE person ADD COLUMN faction TEXT NOT NULL DEFAULT ''" },
        .{ .version = 15, .table = "person", .column = "shares", .sql = "ALTER TABLE person ADD COLUMN shares INTEGER NOT NULL DEFAULT 0" },
        .{ .version = 16, .table = "person", .column = "born_day", .sql = "ALTER TABLE person ADD COLUMN born_day INTEGER" },
        .{ .version = 17, .table = "person", .column = "last_raise_day", .sql = "ALTER TABLE person ADD COLUMN last_raise_day INTEGER" },
        .{ .version = 17, .table = "person", .column = "last_award_day", .sql = "ALTER TABLE person ADD COLUMN last_award_day INTEGER" },
        // v18 adds the `rating_snapshot` table (created by ddl) and the stats meta ints.
        .{ .version = 19, .table = "listing", .column = "black", .sql = "ALTER TABLE listing ADD COLUMN black INTEGER NOT NULL DEFAULT 0" },
        .{ .version = 20, .table = "unit", .column = "wreck", .sql = "ALTER TABLE unit ADD COLUMN wreck TEXT NOT NULL DEFAULT 'none'" },
        .{ .version = 21, .table = "force", .column = "roe", .sql = "ALTER TABLE force ADD COLUMN roe TEXT NOT NULL DEFAULT 'standard'" },
        .{ .version = 22, .table = "contract", .column = "enemy_lances", .sql = "ALTER TABLE contract ADD COLUMN enemy_lances INTEGER NOT NULL DEFAULT 0" },
        .{ .version = 22, .table = "contract", .column = "enemy_quality", .sql = "ALTER TABLE contract ADD COLUMN enemy_quality TEXT NOT NULL DEFAULT 'regular'" },
        .{ .version = 22, .table = "contract", .column = "enemy_lance_bv", .sql = "ALTER TABLE contract ADD COLUMN enemy_lance_bv INTEGER NOT NULL DEFAULT 0" },
        .{ .version = 23, .table = "listing", .column = "company", .sql = "ALTER TABLE listing ADD COLUMN company INTEGER NOT NULL DEFAULT 0" },
        .{ .version = 24, .table = "contract", .column = "enemy_lance_tons", .sql = "ALTER TABLE contract ADD COLUMN enemy_lance_tons INTEGER NOT NULL DEFAULT 0" },
        .{ .version = 25, .table = "person", .column = "departed_day", .sql = "ALTER TABLE person ADD COLUMN departed_day INTEGER" },
        .{ .version = 24, .table = "contract", .column = "offer_hq", .sql = "ALTER TABLE contract ADD COLUMN offer_hq INTEGER NOT NULL DEFAULT 0" },
        // v28: reports already in a save count as read (default 1), so an
        // upgrade does not hold the turn on battles long since fought.
        .{ .version = 28, .table = "battle_report", .column = "acknowledged", .sql = "ALTER TABLE battle_report ADD COLUMN acknowledged INTEGER NOT NULL DEFAULT 1" },
        // v26: the inbox is answered by event id, not by row; `load` stamps
        // ids on rows that default to 0.
        .{ .version = 26, .table = "pending_event", .column = "id", .sql = "ALTER TABLE pending_event ADD COLUMN id INTEGER NOT NULL DEFAULT 0" },
    };

    pub fn open(path: [*:0]const u8) !Store {
        return fromDb(try sqlite.Db.open(path));
    }

    /// Adopt an open database: create what's missing, migrate what's old.
    pub fn fromDb(db: sqlite.Db) !Store {
        try db.exec(ddl);
        const store: Store = .{ .db = db };
        const stored = try fit(u32, @max(1, store.getSetting("schema_version", 1)));
        if (stored > schema_version) return error.StoreNewerThanGame;
        try db.exec("BEGIN");
        // best-effort: rolling back a failed transaction; the original error propagates.
        errdefer db.exec("ROLLBACK") catch {};
        for (migrations) |m| {
            if (m.version <= stored) continue;
            if (!try hasColumnRt(db, m.table, m.column)) try db.exec(m.sql);
        }
        try store.setSetting("schema_version", schema_version);
        try db.exec("COMMIT");
        return store;
    }

    fn hasColumnRt(db: sqlite.Db, table: []const u8, column: []const u8) !bool {
        var sql_buf: [96]u8 = undefined;
        const sql = try std.fmt.bufPrint(&sql_buf, "PRAGMA table_info({s})", .{table});
        var buf: [64]u8 = undefined;
        const st = try db.prepare(sql);
        defer st.finalize();
        while (try st.next()) {
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            const name = st.text(1, fba.allocator()) catch continue;
            if (std.mem.eql(u8, name, column)) return true;
        }
        return false;
    }

    fn hasColumn(db: sqlite.Db, comptime table: []const u8, column: []const u8) !bool {
        var buf: [64]u8 = undefined;
        const st = try db.prepare("PRAGMA table_info(" ++ table ++ ")");
        defer st.finalize();
        while (try st.next()) {
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            const name = st.text(1, fba.allocator()) catch continue;
            if (std.mem.eql(u8, name, column)) return true;
        }
        return false;
    }

    pub fn close(self: Store) void {
        self.db.close();
    }

    pub const CampaignInfo = struct {
        id: i64,
        name: @import("../sim/table.zig").Raw,
        commander: @import("../sim/table.zig").Raw,
        day: i64,
        date: []const u8,
        /// Monotonic save counter across the store (the sim core keeps no
        /// wall clock); higher = saved more recently.
        save_seq: i64,
        player_id: i64 = 0,
    };

    pub const PlayerInfo = struct {
        id: i64,
        name: @import("../sim/table.zig").Raw,
        campaigns: i64,
    };

    /// Every playthrough in the store, most recently saved first. Strings
    /// owned by `alloc`. `player` = 0 lists everyone's.
    pub fn listCampaigns(self: Store, alloc: std.mem.Allocator) ![]CampaignInfo {
        return self.listCampaignsOf(alloc, 0);
    }

    pub fn listCampaignsOf(self: Store, alloc: std.mem.Allocator, player: i64) ![]CampaignInfo {
        var out: std.ArrayListUnmanaged(CampaignInfo) = .empty;
        const st = try self.db.prepare("SELECT id, name, commander, day, date, save_seq, player_id FROM campaign WHERE (?1 = 0 OR player_id = ?1) ORDER BY save_seq DESC, id DESC");
        defer st.finalize();
        try st.bindAll(.{player});
        while (try st.next()) {
            try out.append(alloc, .{
                .id = st.int(0),
                .name = .{ .raw = try st.text(1, alloc) },
                .commander = .{ .raw = try st.text(2, alloc) },
                .day = st.int(3),
                .date = try st.text(4, alloc),
                .save_seq = st.int(5),
                .player_id = st.int(6),
            });
        }
        return out.toOwnedSlice(alloc);
    }

    // -------------------------------------------------------------- settings

    /// Client settings (music on/off, volume …) live in the store so they
    /// follow the save file, not the terminal.
    pub fn getSetting(self: Store, key: []const u8, default: i64) i64 {
        const st = self.db.prepare("SELECT value FROM setting WHERE key = ?1") catch return default;
        defer st.finalize();
        st.bindAll(.{key}) catch return default;
        const has = st.next() catch return default;
        return if (has) st.int(0) else default;
    }

    pub fn setSetting(self: Store, key: []const u8, value: i64) !void {
        const st = try self.db.prepare("INSERT INTO setting (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value");
        defer st.finalize();
        try st.bindAll(.{ key, value });
        try st.run();
    }

    // --------------------------------------------------------------- players

    pub fn listPlayers(self: Store, alloc: std.mem.Allocator) ![]PlayerInfo {
        var out: std.ArrayListUnmanaged(PlayerInfo) = .empty;
        const st = try self.db.prepare("SELECT p.id, p.name, (SELECT COUNT(*) FROM campaign c WHERE c.player_id = p.id) FROM player p ORDER BY p.created_seq, p.id");
        defer st.finalize();
        while (try st.next()) {
            try out.append(alloc, .{ .id = st.int(0), .name = .{ .raw = try st.text(1, alloc) }, .campaigns = st.int(2) });
        }
        return out.toOwnedSlice(alloc);
    }

    pub fn createPlayer(self: Store, name: []const u8) !i64 {
        const ins = try self.db.prepare("INSERT INTO player (name, created_seq) VALUES (?1, (SELECT COALESCE(MAX(created_seq), 0) + 1 FROM player))");
        defer ins.finalize();
        try ins.bindAll(.{name});
        try ins.run();
        const q = try self.db.prepare("SELECT last_insert_rowid()");
        defer q.finalize();
        _ = try q.next();
        return q.int(0);
    }

    /// Delete a player and every campaign filed under them.
    pub fn deletePlayer(self: Store, player: i64) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const owned = try self.listCampaignsOf(arena.allocator(), player);
        for (owned) |c| try self.deleteCampaign(c.id);
        const st = try self.db.prepare("DELETE FROM player WHERE id = ?1");
        defer st.finalize();
        try st.bindAll(.{player});
        try st.run();
    }

    /// Remove a campaign and every row that belonged to it.
    pub fn deleteCampaign(self: Store, cid: i64) !void {
        try self.db.exec("BEGIN");
        // best-effort: rolling back a failed transaction; the original error propagates.
        errdefer self.db.exec("ROLLBACK") catch {};
        try self.clearRows(cid);
        const st = try self.db.prepare("DELETE FROM campaign WHERE id = ?1");
        defer st.finalize();
        try st.bindAll(.{cid});
        try st.run();
        try self.db.exec("COMMIT");
    }

    fn clearRows(self: Store, cid: i64) !void {
        inline for (tables) |t| {
            const st = try self.db.prepare("DELETE FROM " ++ t ++ " WHERE cid = ?1");
            defer st.finalize();
            try st.bindAll(.{cid});
            try st.run();
        }
    }

    // ------------------------------------------------------------------ save

    /// Save the campaign in one transaction. A first save registers it and
    /// sets `gs.campaign_id` only once the transaction commits, so a failed
    /// save leaves both the store and the state as they were. Saving over a
    /// campaign whose row is gone returns `error.NoSuchCampaign`.
    pub fn save(self: Store, gs: *GameState) !void {
        try self.db.exec("BEGIN");
        // best-effort: rolling back a failed transaction; the original error propagates.
        errdefer self.db.exec("ROLLBACK") catch {};

        const cid = try self.saveCampaignRow(gs);
        try self.clearRows(cid);

        try self.saveMeta(gs, cid);
        try self.saveRngStream(gs, cid);
        try self.saveCommander(gs, cid);
        try self.savePerson(gs, cid);
        try self.saveUnit(gs, cid);
        try self.saveForce(gs, cid);
        try self.saveStock(cid, "outfit", 0, &gs.spare_parts);
        try self.saveHq(gs, cid);
        try self.saveContracts(gs, cid);
        try self.saveTxn(gs, cid);
        try self.saveLoan(gs, cid);
        try self.saveCourier(gs, cid);
        try self.savePolicy(gs, cid);
        try self.saveSupplyPolicy(gs, cid);
        try self.saveStockPolicy(gs, cid);
        try self.saveBayJob(gs, cid);
        try self.saveCandidate(gs, cid);
        try self.saveHqLink(gs, cid);
        try self.saveUnitTransfer(gs, cid);
        try self.saveFactionCooling(gs, cid);
        try self.saveFactionStanding(gs, cid);
        try self.saveEventMemory(gs, cid);
        try self.saveRatingSnapshot(gs, cid);
        try self.saveListing(gs, cid);
        try self.savePartOrder(gs, cid);
        try self.saveEventLog(gs, cid);
        try self.savePendingEvent(gs, cid);
        try self.saveBattleReport(gs, cid);
        try self.saveRefitPlan(gs, cid);

        try self.db.exec("COMMIT");
        gs.campaign_id = cid;
    }

    // ---- the per-table encoders `save` runs, in its order ----

    /// Insert or update the campaign registry row; returns its id.
    /// `NoSuchCampaign` when an id already set has no row.
    fn saveCampaignRow(self: Store, gs: *GameState) !i64 {
        var date_buf: [10]u8 = undefined;
        const date = gs.clock.date.text(&date_buf);
        const cmdr_name: []const u8 = if (gs.commander) |c| c.name else "";

        var cid = gs.campaign_id;
        if (cid == 0) {
            const ins = try self.db.prepare("INSERT INTO campaign (name, commander, day, date, schema_version, save_seq, player_id) VALUES (?1, ?2, ?3, ?4, ?5, (SELECT COALESCE(MAX(save_seq), 0) + 1 FROM campaign), ?6)");
            defer ins.finalize();
            try ins.bindAll(.{ gs.outfit_name, cmdr_name, @as(i64, gs.clock.day_index), date, @as(i64, schema_version), self.player_id });
            try ins.run();
            const q = try self.db.prepare("SELECT last_insert_rowid()");
            defer q.finalize();
            _ = try q.next();
            cid = q.int(0);
        } else {
            const up = try self.db.prepare("UPDATE campaign SET name = ?1, commander = ?2, day = ?3, date = ?4, schema_version = ?5, save_seq = (SELECT COALESCE(MAX(save_seq), 0) + 1 FROM campaign) WHERE id = ?6");
            defer up.finalize();
            try up.bindAll(.{ gs.outfit_name, cmdr_name, @as(i64, gs.clock.day_index), date, @as(i64, schema_version), cid });
            try up.run();
            if (self.db.changes() == 0) return error.NoSuchCampaign;
        }
        return cid;
    }

    // Scalars.
    fn saveMeta(self: Store, gs: *GameState, cid: i64) !void {
        const difficulty_int: i64 = @intFromEnum(gs.difficulty);
        const st = try self.db.prepare("INSERT INTO meta VALUES (?1, ?2, ?3)");
        defer st.finalize();
        const ints = [_]struct { []const u8, i64 }{
            .{ "day_index", gs.clock.day_index },                                  .{ "year", gs.clock.date.year },
            .{ "month", gs.clock.date.month },                                     .{ "day", gs.clock.date.day },
            .{ "funds", gs.funds },                                                .{ "reputation", gs.reputation },
            .{ "bankrupt", @as(i64, @intFromBool(gs.bankrupt)) },                  .{ "auto_admit", @as(i64, @intFromBool(gs.auto_admit)) },
            .{ "difficulty", difficulty_int },                                     .{ "share_profit_bp", @as(i64, gs.share_profit_bp) },
            .{ "stat_battles_won", gs.stats.battles_won },                         .{ "stat_battles_drawn", gs.stats.battles_drawn },
            .{ "stat_battles_lost", gs.stats.battles_lost },                       .{ "stat_hulls_lost", gs.stats.hulls_lost },
            .{ "stat_hulls_salvaged", gs.stats.hulls_salvaged },                   .{ "stat_people_kia", gs.stats.people_kia },
            .{ "stat_enemy_bv", @as(i64, @intCast(gs.stats.enemy_bv_destroyed)) }, .{ "next_person_id", gs.next_person_id },
            .{ "next_unit_id", gs.next_unit_id },                                  .{ "next_force_id", gs.next_force_id },
            .{ "next_hq_id", gs.next_hq_id },                                      .{ "next_contract_id", gs.next_contract_id },
            .{ "next_battle_id", gs.next_battle_id },                              .{ "rng_seed", @as(i64, @bitCast(gs.rng.seed)) },
            .{ "next_event_id", gs.event_queue.next_id },
        };
        for (ints) |kv| {
            try st.bindAll(.{ cid, kv[0], kv[1] });
            try st.run();
        }
        const tx = try self.db.prepare("INSERT INTO meta_text VALUES (?1, ?2, ?3)");
        defer tx.finalize();
        try tx.bindAll(.{ cid, "outfit_name", gs.outfit_name });
        try tx.run();
    }

    fn saveRngStream(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO rng_stream VALUES (?1, ?2, ?3, ?4)");
        defer st.finalize();
        for (std.enums.values(rng_mod.Stream)) |stream| {
            const bytes = gs.rng.encode(stream);
            try st.bindAll(.{ cid, @tagName(stream), rng_mod.Rng.state_format });
            try st.bindBlob(4, &bytes);
            try st.run();
        }
    }

    fn saveCommander(self: Store, gs: *GameState, cid: i64) !void {
        if (gs.commander) |c| {
            const st = try self.db.prepare("INSERT INTO commander VALUES (?1, ?2, ?3, ?4)");
            defer st.finalize();
            try st.bindAll(.{ cid, c.name, c.origin, c.profession });
            try st.run();
        }
    }

    // People.
    fn savePerson(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO person VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26,?27,?28,?29,?30,?31,?32,?33,?34,?35,?36)");
        const aw = try self.db.prepare("INSERT INTO award VALUES (?1,?2,?3)");
        defer aw.finalize();
        const ab = try self.db.prepare("INSERT INTO ability VALUES (?1,?2,?3)");
        defer ab.finalize();
        defer st.finalize();
        const sk = try self.db.prepare("INSERT INTO person_skill VALUES (?1, ?2, ?3, ?4)");
        defer sk.finalize();
        const inj = try self.db.prepare("INSERT INTO injury VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)");
        defer inj.finalize();
        var it = gs.people.iterator();
        var ord: i64 = 0;
        while (it.next()) |entry| : (ord += 1) {
            const p = entry.value_ptr;
            try st.bindAll(.{
                cid,                                       ord,                                                               @intFromEnum(p.id),
                p.first_name,                              p.last_name,                                                       p.callsign,
                p.role,                                    @as(i64, p.xp),                                                    p.status,
                @as(i64, p.fatigue),                       @as(i64, p.morale),                                                @as(i64, p.recruited_day),
                p.salary_override,                         @intFromEnum(p.assigned_force),                                    @intFromEnum(p.posted_hq),
                @as(i64, p.weekly_hours),                  @as(i64, p.medbay_priority),                                       p.leave_until_day,
                p.wound_heal_day,                          if (p.training) |t| @as(?[]const u8, @tagName(t.skill)) else null, if (p.training) |t| @as(?u32, t.done_day) else null,
                @as(i64, @intFromBool(p.medbay_admitted)), p.rank,                                                            @as(i64, @intFromBool(p.rank_pinned)),
                @as(i64, p.kills),                         @as(i64, p.kill_bv),                                               @as(i64, p.battles),
                @as(i64, p.tours),                         @as(i64, p.outstanding_tours),                                     @as(i64, @intFromBool(p.edge_spent)),
                p.faction,                                 @as(i64, p.shares),                                                p.born_day,
                p.last_raise_day,                          p.last_award_day,                                                  p.departed_day,
            });
            for (p.awards.items) |key| {
                try aw.bindAll(.{ cid, @intFromEnum(p.id), key });
                try aw.run();
            }
            for (p.abilities.items) |key| {
                try ab.bindAll(.{ cid, @intFromEnum(p.id), key });
                try ab.run();
            }
            try st.run();
            var skit = p.skills.iterator();
            while (skit.next()) |s| {
                try sk.bindAll(.{ cid, @intFromEnum(p.id), s.key_ptr.*, @as(i64, s.value_ptr.*) });
                try sk.run();
            }
            for (p.injuries.items, 0..) |i, n| {
                try inj.bindAll(.{ cid, @intFromEnum(p.id), @as(i64, @intCast(n)), i.location, @as(i64, i.severity), @as(i64, i.incurred_day), i.heal_done_day, @intFromEnum(i.doctor), @as(i64, @intFromBool(i.permanent)), @as(i64, @intFromBool(i.healed)) });
                try inj.run();
            }
        }
    }

    // Units and slots.
    fn saveUnit(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO unit VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22)");
        defer st.finalize();
        const sl = try self.db.prepare("INSERT INTO unit_slot VALUES (?1,?2,?3,?4,?5,?6,?7)");
        defer sl.finalize();
        var ord: i64 = 0;
        const Writer = struct {
            // One writer for both, so an owned hull and a held one can
            // never be saved by two loops that drift apart.
            fn put(unit_st: anytype, slot_st: anytype, c: i64, o: i64, u: *const unit_mod.Unit, held: unit_mod.HeldHull.Mark) !void {
                try unit_st.bindAll(.{
                    c,                                   o,                                       @intFromEnum(u.id),    u.chassis_key,
                    u.name,                              u.kind,                                  @intFromEnum(u.force), @intFromEnum(u.pilot),
                    @intFromEnum(u.tech),                @as(i64, u.armor_pct),                   u.quality,             u.status,
                    u.last_maintenance_day,              @as(i64, u.acquired_day),                u.purchase_price,      u.reactivation_done_day,
                    @intFromEnum(u.berth_hq),            u.wreck,                                 held.by,               @as(i64, held.day),
                    @as(i64, @intFromEnum(held.battle)), @as(i64, @intFromEnum(held.from_force)),
                });
                try unit_st.run();
                for (u.slots.items, 0..) |s, i| {
                    try slot_st.bindAll(.{ c, @intFromEnum(u.id), @as(i64, @intCast(i)), s.slot_key, s.part_key, s.class, s.condition });
                    try slot_st.run();
                }
            }
        };
        var it = gs.units.iterator();
        while (it.next()) |entry| : (ord += 1) try Writer.put(st, sl, cid, ord, entry.value_ptr, .{});
        for (gs.held_hulls.items) |*h| {
            try Writer.put(st, sl, cid, ord, &h.unit, h.mark());
            ord += 1;
        }
    }

    // Forces, their unit and child orderings, and field stores.
    fn saveForce(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO force VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18)");
        defer st.finalize();
        const fu = try self.db.prepare("INSERT INTO force_unit VALUES (?1,?2,?3,?4)");
        defer fu.finalize();
        const fc = try self.db.prepare("INSERT INTO force_child VALUES (?1,?2,?3,?4)");
        defer fc.finalize();
        var it = gs.forces.iterator();
        var ord: i64 = 0;
        while (it.next()) |entry| : (ord += 1) {
            const f = entry.value_ptr;
            try st.bind(1, cid);
            try st.bind(2, ord);
            try st.bind(3, @intFromEnum(f.id));
            try st.bind(4, @intFromEnum(f.parent));
            try st.bind(5, f.name);
            if (f.emblem) |e| try st.bindBlob(6, e) else try st.bind(6, null);
            try st.bind(7, f.local_funds);
            try st.bind(8, f.echelon);
            try st.bind(9, @intFromEnum(f.commander));
            try st.bind(10, @intFromEnum(f.supplying_hq));
            try st.bind(11, f.role);
            try st.bind(12, f.support_kind);
            try st.bind(13, f.last_rotation_day);
            try st.bind(14, @as(i64, f.contracts_since_rotation));
            try st.bind(15, f.location_planet);
            try st.bind(16, f.return_eta_day);
            try st.bind(17, @as(i64, f.supply_shortage_days));
            try st.bind(18, f.roe);
            try st.run();
            for (f.units.items, 0..) |uid, i| {
                try fu.bindAll(.{ cid, @intFromEnum(f.id), @as(i64, @intCast(i)), @intFromEnum(uid) });
                try fu.run();
            }
            for (f.children.items, 0..) |child, i| {
                try fc.bindAll(.{ cid, @intFromEnum(f.id), @as(i64, @intCast(i)), @intFromEnum(child) });
                try fc.run();
            }
            try self.saveStock(cid, "company", @intFromEnum(f.id), &f.stock);
        }
    }

    // HQs, facilities, projects, warehouse stock.
    fn saveHq(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO hq VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)");
        defer st.finalize();
        const fa = try self.db.prepare("INSERT INTO hq_facility VALUES (?1,?2,?3,?4,?5)");
        defer fa.finalize();
        const pr = try self.db.prepare("INSERT INTO hq_project VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)");
        defer pr.finalize();
        var it = gs.hqs.iterator();
        var ord: i64 = 0;
        while (it.next()) |entry| : (ord += 1) {
            const h = entry.value_ptr;
            try st.bindAll(.{ cid, ord, @intFromEnum(h.id), h.name, h.tier, h.planet_key, @as(i64, h.staff_assigned), h.monthly_upkeep, h.funds });
            try st.run();
            for (h.facilities.items, 0..) |f, i| {
                try fa.bindAll(.{ cid, @intFromEnum(h.id), @as(i64, @intCast(i)), f.kind, @as(i64, f.level) });
                try fa.run();
            }
            for (h.projects.items, 0..) |p, i| {
                try pr.bindAll(.{ cid, @intFromEnum(h.id), @as(i64, @intCast(i)), p.kind, p.facility, @as(i64, p.target_level), @as(i64, p.started_day), @as(i64, p.paperwork_done_day), @as(i64, p.construction_done_day), p.cost });
                try pr.run();
            }
            try self.saveStock(cid, "hq", @intFromEnum(h.id), &h.stock);
        }
    }

    // Contracts and offers.
    fn saveContracts(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO contract VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26,?27,?28,?29,?30,?31,?32,?33,?34,?35,?36,?37,?38,?39,?40,?41,?42,?43,?44,?45)");
        defer st.finalize();
        var ord: i64 = 0;
        var it = gs.contracts.iterator();
        while (it.next()) |entry| : (ord += 1) try saveContract(st, cid, false, ord, entry.value_ptr);
        for (gs.contract_offers.items, 0..) |*o, i| try saveContract(st, cid, true, @intCast(i), o);
    }

    // Ledger and the rest of the lists.
    fn saveTxn(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO txn VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)");
        defer st.finalize();
        for (gs.ledger.transactions.items, 0..) |t, i| {
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), @as(i64, t.day), t.amount, t.category, @intFromEnum(t.company), @intFromEnum(t.hq), @intFromEnum(t.contract), t.note });
            try st.run();
        }
    }

    fn saveLoan(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO loan VALUES (?1,?2,?3,?4,?5,?6,?7,?8)");
        defer st.finalize();
        for (gs.loans.items, 0..) |l, i| {
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), l.principal, l.balance, l.rate_bp, @as(i64, l.term_months), @as(i64, l.next_pay_day), l.payment });
            try st.run();
        }
    }

    fn saveCourier(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO courier VALUES (?1,?2,?3,?4,?5,?6,?7)");
        defer st.finalize();
        for (gs.fund_couriers.items, 0..) |c, i| {
            const t = treasuryCols(c.to);
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), t.kind, t.id, c.amount, @as(i64, c.sent_day), @as(i64, c.eta_day) });
            try st.run();
        }
    }

    fn savePolicy(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO policy VALUES (?1,?2,?3,?4,?5,?6,?7)");
        defer st.finalize();
        for (gs.policies.items, 0..) |p, i| {
            const t = treasuryCols(p.entity);
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), t.kind, t.id, p.floor, p.monthly_cap, p.sent_this_month });
            try st.run();
        }
    }

    fn saveSupplyPolicy(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO supply_policy VALUES (?1,?2,?3,?4,?5,?6)");
        defer st.finalize();
        for (gs.supply_policies.items, 0..) |p, i| {
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), @intFromEnum(p.company), @as(i64, p.min_days), @as(i64, p.tons), @as(i64, p.ammo_battles) });
            try st.run();
        }
    }

    fn saveStockPolicy(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO stock_policy VALUES (?1,?2,?3,?4,?5,?6)");
        defer st.finalize();
        for (gs.stock_policies.items, 0..) |p, i| {
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), @intFromEnum(p.hq), p.part_key, @as(i64, p.min), @as(i64, p.target) });
            try st.run();
        }
    }

    fn saveBayJob(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO bay_job VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)");
        defer st.finalize();
        for (gs.bay_jobs.items, 0..) |j, i| {
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), @intFromEnum(j.hq), j.kind, @intFromEnum(j.unit), j.item_key, @as(i64, j.duration_days), @as(i64, j.queued_day), j.started_day, j.done_day, j.cost });
            try st.run();
        }
    }

    fn saveCandidate(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO candidate VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)");
        defer st.finalize();
        for (gs.candidates.items, 0..) |c, i| {
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), @intFromEnum(c.hq), c.spec.first, c.spec.last, c.spec.callsign, c.spec.role, c.spec.experience, @as(i64, c.spec.primary_skill), @as(i64, c.spec.secondary_skill), c.asking_bonus, @as(i64, c.listed_day), @as(i64, c.expires_day), @as(i64, c.spec.age) });
            try st.run();
        }
    }

    fn saveHqLink(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO hq_link VALUES (?1,?2,?3,?4,?5,?6,?7)");
        defer st.finalize();
        for (gs.hq_links.items, 0..) |l, i| {
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), @intFromEnum(l.a), @intFromEnum(l.b), @as(i64, l.level), @as(i64, l.tons_this_week), @as(i64, l.established_day) });
            try st.run();
        }
    }

    fn saveUnitTransfer(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO unit_transfer VALUES (?1,?2,?3,?4,?5)");
        defer st.finalize();
        for (gs.unit_transfers.items, 0..) |t, i| {
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), @intFromEnum(t.unit), @intFromEnum(t.to_company), @as(i64, t.eta_day) });
            try st.run();
        }
    }

    fn saveFactionCooling(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO faction_cooling VALUES (?1,?2,?3,?4)");
        defer st.finalize();
        for (gs.faction_cooling.items, 0..) |f, i| {
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), f.faction, @as(i64, f.until_day) });
            try st.run();
        }
    }

    fn saveFactionStanding(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO faction_standing VALUES (?1,?2,?3)");
        defer st.finalize();
        var it = gs.faction_standing.iterator();
        while (it.next()) |e| {
            try st.bindAll(.{ cid, e.key_ptr.*, @as(i64, e.value_ptr.*) });
            try st.run();
        }
    }

    fn saveEventMemory(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO event_memory VALUES (?1,?2,?3,?4,?5)");
        defer st.finalize();
        var it = gs.event_memory.iterator();
        while (it.next()) |e| {
            try st.bindAll(.{ cid, e.key_ptr.*, @as(i64, e.value_ptr.last_day), @as(i64, e.value_ptr.last_choice), @as(i64, e.value_ptr.streak) });
            try st.run();
        }
    }

    fn saveRatingSnapshot(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO rating_snapshot VALUES (?1,?2,?3)");
        defer st.finalize();
        for (gs.rating_history.items) |snap| {
            try st.bindAll(.{ cid, @as(i64, snap.year), @as(i64, snap.score) });
            try st.run();
        }
    }

    fn saveListing(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO listing VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18)");
        defer st.finalize();
        for (gs.market_listings.items, 0..) |l, i| {
            try st.bindAll(.{
                cid,                                                                  @as(i64, @intCast(i)),                                     l.kind,                                                      l.item_key,
                l.rarity,                                                             l.price,                                                   @as(i64, l.quantity),                                        l.staple,
                @as(i64, l.listed_day),                                               @as(i64, l.expires_day),                                   @intFromEnum(l.hq),                                          if (l.condition) |c| @as(?i64, c.armor_pct) else null,
                if (l.condition) |c| @as(?[]const u8, @tagName(c.quality)) else null, if (l.condition) |c| @as(?i64, c.damaged_slots) else null, if (l.condition) |c| @as(?i64, c.destroyed_slots) else null, if (l.condition) |c| @as(?i64, c.missing_components) else null,
                @as(i64, @intFromBool(l.black_market)),                               @intFromEnum(l.company),
            });
            try st.run();
        }
    }

    fn savePartOrder(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO part_order VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)");
        defer st.finalize();
        for (gs.part_orders.items, 0..) |o, i| {
            const dest_cols = siteCols(o.dest);
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), o.part_key, @as(i64, o.quantity), dest_cols.kind, dest_cols.id, @as(i64, o.ordered_day), o.eta_day, o.cost, o.status });
            try st.run();
        }
    }

    fn saveEventLog(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO event_log VALUES (?1,?2,?3,?4,?5,?6,?7,?8)");
        defer st.finalize();
        for (gs.event_log.items, 0..) |e, i| {
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), @as(i64, e.day), e.category, @intFromEnum(e.company), @intFromEnum(e.hq), @intFromEnum(e.contract), e.text });
            try st.run();
        }
    }

    fn savePendingEvent(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO pending_event VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)");
        defer st.finalize();
        for (gs.event_queue.pending.items, 0..) |e, i| {
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), e.kind, @as(i64, e.day), @intFromEnum(e.contract), @intFromEnum(e.company), @as(i64, @intCast(e.default_choice)), @as(i64, e.deadline_day), if (e.chosen) |c| @as(?i64, @intCast(c)) else null, @intFromEnum(e.person), @intFromEnum(e.id), @intFromEnum(e.battle) });
            try st.run();
        }
    }

    fn saveBattleReport(self: Store, gs: *GameState, cid: i64) !void {
        // Battle reports: the record a screen reads. Hits and ammunition
        // are child rows; the ammunition family is stored by name, not
        // by position, because `part.munition_keys` can grow and a
        // positional encoding would silently re-label saved rows.
        const br = try self.db.prepare("INSERT INTO battle_report VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26,?27,?28,?29,?30,?31,?32,?33,?34,?35,?36,?37,?38,?39,?40,?41,?42,?43,?44,?45,?46,?47,?48,?49,?50,?51,?52,?53)");
        defer br.finalize();
        const bh = try self.db.prepare("INSERT INTO battle_report_hit VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22)");
        defer bh.finalize();
        const ba = try self.db.prepare("INSERT INTO battle_report_ammo VALUES (?1,?2,?3,?4,?5,?6)");
        defer ba.finalize();
        const bs = try self.db.prepare("INSERT INTO battle_report_salvage VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)");
        defer bs.finalize();
        for (gs.battle_reports.kept.items, 0..) |r, i| {
            const ord: i64 = @intCast(i);
            try br.bindAll(.{
                cid,                                    ord,                                  @intFromEnum(r.id),                 @as(i64, r.day),
                @intFromEnum(r.contract),               @intFromEnum(r.company),              r.kind,                             r.enemy_key,
                r.scenario,                             r.terrain,                            r.weather,                          @tagName(r.outcome),
                @as(i64, @intFromBool(r.held_field)),   @as(i64, @intFromBool(r.withdrew)),   @tagName(r.roe),                    @as(i64, @intFromBool(r.roe_overridden)),
                r.player_power,                         r.enemy_power,                        @as(i64, r.conditions_mod),         @as(i64, @intFromBool(r.close_terrain)),
                @as(i64, @intFromBool(r.air_grounded)), @as(i64, @intFromBool(r.convoy_hit)), r.edge_spent_by,                    @as(i64, r.recon_quality),
                @as(i64, r.avg_fatigue),                @as(i64, r.avg_morale),               @as(i64, r.hits_taken),             @as(i64, r.destroyed),
                @as(i64, r.wounded),                    @as(i64, r.kia),                      @as(i64, r.lost_hulls),             @as(i64, r.missing),
                r.enemy_destroyed_bv,                   @as(i64, r.kills_credited),           @as(i64, r.prisoners),              r.battle_loss_comp,
                @as(i64, r.score_after),                @as(i64, r.score_delta),              @as(i64, r.morale_delta),           @as(i64, r.fatigue_add),
                @as(i64, r.battle_loss_pct),            @as(i64, r.salvage_pct),              r.command_rights,                   @as(i64, r.silenced_mounts),
                @as(i64, r.armor_left),                 r.salvage.claimed_bv,                 r.salvage.haulable_bv,              r.salvage.liaison_cut,
                r.salvage.exchange_cash,                r.salvage.items,                      @as(i64, @intFromBool(r.conceded)), @as(i64, @intFromBool(r.acknowledged)),
                r.salvage.unclaimed_bv,
            });
            try br.run();
            for (r.hulls, 0..) |h, hi| {
                // Each value in its own local: a mixed if/else inside
                // the tuple lets peer resolution pick a type the
                // binder then reads as the wrong kind of column.
                const slot_key: []const u8 = h.slot orelse "";
                const wound_severity: ?i64 = if (h.crew.wound) |w| @intCast(w.severity) else null;
                const wound_location: []const u8 = if (h.crew.wound) |w| @tagName(w.location) else "";
                const wound_permanent: i64 = if (h.crew.wound) |w| @intFromBool(w.permanent) else 0;
                const recovery_roll: ?i64 = if (h.recovery) |rec| @intCast(rec.roll) else null;
                const recovery_target: ?i64 = if (h.recovery) |rec| @intCast(rec.target) else null;
                try bh.bindAll(.{
                    cid,               ord,                             @as(i64, @intCast(hi)),   @as(i64, @intFromEnum(h.unit)),
                    h.chassis_key,     h.chassis_name,                  @as(i64, h.armor_before), @as(i64, h.armor_after),
                    slot_key,          h.slot_part,                     @tagName(h.slot_result),  @as(i64, @intFromBool(h.destroyed)),
                    @tagName(h.cause), @as(i64, @intFromEnum(h.pilot)), h.crew_name,              wound_severity,
                    wound_location,    wound_permanent,                 @tagName(h.crew.fate),    recovery_roll,
                    recovery_target,   @as(i64, @intFromBool(h.lost)),
                });
                try bh.run();
            }
            for (r.ammo, 0..) |a, ai| {
                try ba.bindAll(.{ cid, ord, @as(i64, @intCast(ai)), a.key, @as(i64, a.burned), @as(i64, a.left) });
                try ba.run();
            }
            // The wrecks on offer. Rolled once when the fight ended, so a reload must offer the same ones — rolling
            // again would hand the player a different battlefield.
            for (r.salvage.candidates, 0..) |sc, si| {
                try bs.bindAll(.{
                    cid,                        ord,                          @as(i64, @intCast(si)),          sc.key,
                    sc.name,                    sc.bv,                        @as(i64, sc.armor_pct),          @tagName(sc.quality),
                    @as(i64, sc.damaged_slots), @as(i64, sc.destroyed_slots), @as(i64, sc.missing_components),
                });
                try bs.run();
            }
        }
    }

    fn saveRefitPlan(self: Store, gs: *GameState, cid: i64) !void {
        const pl = try self.db.prepare("INSERT INTO refit_plan VALUES (?1,?2,?3,?4)");
        defer pl.finalize();
        const op = try self.db.prepare("INSERT INTO refit_op VALUES (?1,?2,?3,?4,?5,?6,?7)");
        defer op.finalize();
        for (gs.refit_plans.items, 0..) |p, i| {
            try pl.bindAll(.{ cid, @as(i64, @intCast(i)), @intFromEnum(p.unit), p.committed });
            try pl.run();
            for (p.ops.items, 0..) |o, j| {
                switch (o) {
                    .remove => |slot_key| try op.bindAll(.{ cid, @as(i64, @intCast(i)), @as(i64, @intCast(j)), "remove", slot_key, @as(?[]const u8, null), @as(?[]const u8, null) }),
                    .install => |it| try op.bindAll(.{ cid, @as(i64, @intCast(i)), @as(i64, @intCast(j)), "install", @as(?[]const u8, null), it.location, it.part_key }),
                }
                try op.run();
            }
        }
    }

    fn saveStock(self: Store, cid: i64, kind: []const u8, owner: i64, stock: *const std.StringArrayHashMapUnmanaged(u32)) !void {
        const st = try self.db.prepare("INSERT INTO stock VALUES (?1,?2,?3,?4,?5,?6)");
        defer st.finalize();
        var it = stock.iterator();
        var i: i64 = 0;
        while (it.next()) |entry| : (i += 1) {
            try st.bindAll(.{ cid, kind, owner, i, entry.key_ptr.*, @as(i64, entry.value_ptr.*) });
            try st.run();
        }
    }

    fn saveContract(st: sqlite.Stmt, cid: i64, is_offer: bool, ord: i64, c: *const contract_mod.Contract) !void {
        try st.bindAll(.{
            cid,                             is_offer,                         ord,                               @intFromEnum(c.id),
            c.kind,                          c.employer_key,                   c.enemy_key,                       c.planet_key,
            c.status,                        @intFromEnum(c.assigned_company), c.start_day,                       @as(i64, c.score),
            @as(i64, c.dist_ly),             c.beachhead,                      @as(i64, c.transit_days),          c.arrive_day,
            c.end_day,                       c.monthly_net,                    c.next_battle_day,                 @as(i64, c.battles_fought),
            @as(i64, c.casualties),          c.objective,                      c.committed_bv,                    c.enemy_pool_bv,
            c.enemy_pool_remaining,          @as(i64, c.victory_points),       c.ineffective_since,               c.breach_day,
            @as(i64, c.terms.length_months), c.terms.base_pay_month,           @as(i64, c.terms.advance_pct),     c.terms.signing_bonus,
            @as(i64, c.terms.transport_pct), @as(i64, c.terms.overhead_pct),   @as(i64, c.terms.battle_loss_pct), @as(i64, c.terms.salvage_pct),
            c.terms.salvage_exchange,        c.terms.command_rights,           c.negotiated,                      @as(i64, c.enemy_lances),
            c.enemy_quality,                 c.enemy_lance_bv,                 @as(i64, c.enemy_lance_tons),      @intFromEnum(c.offer_hq),
            c.orders_day,
        });
        try st.run();
    }

    // ------------------------------------------------------------------ load

    /// Restore every RNG stream. A row names its stream; a stream with no
    /// row starts fresh from the campaign seed. A malformed row, an unknown
    /// stream, or stream rows without a seed are `error.CorruptSave`.
    ///
    /// Saves before schema v32 hold one `rng` blob of native-endian
    /// generator states in `legacy_rng_order` and no seed. Their seed, used
    /// only for streams added since, is a hash of that blob, so it differs
    /// per campaign. A save with no RNG state at all is corrupt.
    fn loadRng(self: Store, gs: *GameState, cid: i64, has_seed: bool) !void {
        const alloc = gs.allocator();
        var loaded = std.EnumSet(rng_mod.Stream).initEmpty();
        {
            const st = try self.db.prepare("SELECT stream, format, state FROM rng_stream WHERE cid = ?1");
            defer st.finalize();
            try st.bindAll(.{cid});
            while (try st.next()) {
                const stream = st.enumValue(rng_mod.Stream, 0) orelse return error.CorruptSave;
                if (!gs.rng.decode(stream, st.int(1), try st.blob(2, alloc))) return error.CorruptSave;
                loaded.insert(stream);
            }
        }
        if (loaded.count() > 0 and !has_seed) return error.CorruptSave;
        if (loaded.count() == 0) {
            const st = try self.db.prepare("SELECT state FROM rng WHERE cid = ?1");
            defer st.finalize();
            try st.bindAll(.{cid});
            if (!try st.next()) return error.CorruptSave;
            const bytes = try st.blob(0, alloc);
            const size = @sizeOf(std.Random.DefaultPrng);
            if (bytes.len != legacy_rng_order.len * size) return error.CorruptSave;
            for (legacy_rng_order, 0..) |stream, i| {
                gs.rng.prngs[@intFromEnum(stream)] = std.mem.bytesToValue(std.Random.DefaultPrng, bytes[i * size ..][0..size]);
                loaded.insert(stream);
            }
            if (!has_seed) gs.rng.seed = std.hash.Wyhash.hash(0, bytes);
        }
        for (std.enums.values(rng_mod.Stream)) |stream| {
            if (!loaded.contains(stream)) gs.rng.prngs[@intFromEnum(stream)] = rng_mod.Rng.fresh(gs.rng.seed, stream);
        }
    }

    /// Rebuild a campaign from the store. `gpa` backs the new GameState.
    pub fn load(self: Store, gpa: std.mem.Allocator, cid: i64) !GameState {
        var gs = GameState.init(gpa, .{});
        errdefer gs.deinit();
        gs.campaign_id = cid;
        const saved_version = try self.loadVersion(cid);
        if (saved_version > schema_version) return error.SaveNewerThanGame;

        const has_seed = try self.loadMeta(&gs, cid);
        try self.loadRng(&gs, cid, has_seed);
        try self.loadCommander(&gs, cid);
        try self.loadPerson(&gs, cid);
        try self.loadUnit(&gs, cid);
        try self.loadForce(&gs, cid);
        try self.loadHq(&gs, cid);
        try self.loadStock(&gs, cid);
        try self.loadContract(&gs, cid);
        try self.loadTxn(&gs, cid);
        try self.loadLoan(&gs, cid);
        try self.loadCourier(&gs, cid);
        try self.loadPolicy(&gs, cid);
        try self.loadSupplyPolicy(&gs, cid);
        try self.loadStockPolicy(&gs, cid);
        try self.loadBayJob(&gs, cid);
        try self.loadCandidate(&gs, cid);
        try self.loadHqLink(&gs, cid);
        try self.loadUnitTransfer(&gs, cid);
        try self.loadFactionCooling(&gs, cid);
        try self.loadFactionStanding(&gs, cid);
        try self.loadEventMemory(&gs, cid);
        try self.loadRatingSnapshot(&gs, cid);
        try self.loadListing(&gs, cid);
        try self.loadPartOrder(&gs, cid);
        try self.loadEventLog(&gs, cid);
        try self.loadPendingEvent(&gs, cid);
        try self.loadBattleReport(&gs, cid);
        try self.loadRefitPlan(&gs, cid);

        gs.refreshHqStaffing();
        try upgradeCampaign(&gs, saved_version);
        // Saves before schema v18 have no stats counters: if the book is
        // empty but the log has battles, count them up.
        if (gs.stats.isEmpty()) recoverStatsFromLog(&gs);
        // Saves without a `next_battle_id` row still hold reports, held hulls
        // and decisions that name battles; numbering resumes past all of them.
        gs.resumeBattleIds();
        try validateStoredStrings(&gs);
        return gs;
    }

    // ---- the per-table decoders `load` runs, in its order ----

    /// The schema version a campaign was saved at; `NoSuchCampaign` when the id is unknown.
    fn loadVersion(self: Store, cid: i64) !u32 {
        const st = try self.db.prepare("SELECT schema_version FROM campaign WHERE id = ?1");
        defer st.finalize();
        try st.bindAll(.{cid});
        if (!try st.next()) return error.NoSuchCampaign;
        return try fit(u32, @max(1, st.int(0)));
    }

    /// The campaign scalars; true when the save holds its RNG seed.
    fn loadMeta(self: Store, gs: *GameState, cid: i64) !bool {
        const alloc = gs.allocator();
        var has_seed = false;
        const st = try self.db.prepare("SELECT key, value FROM meta WHERE cid = ?1");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const key = try st.text(0, alloc);
            const v = st.int(1);
            if (std.mem.eql(u8, key, "day_index")) gs.clock.day_index = try fit(@TypeOf(gs.clock.day_index), v);
            if (std.mem.eql(u8, key, "year")) gs.clock.date.year = try fit(@TypeOf(gs.clock.date.year), v);
            if (std.mem.eql(u8, key, "month")) gs.clock.date.month = try fit(@TypeOf(gs.clock.date.month), v);
            if (std.mem.eql(u8, key, "day")) gs.clock.date.day = try fit(@TypeOf(gs.clock.date.day), v);
            if (std.mem.eql(u8, key, "funds")) gs.funds = v;
            if (std.mem.eql(u8, key, "reputation")) gs.reputation = try fit(@TypeOf(gs.reputation), v);
            if (std.mem.eql(u8, key, "bankrupt")) gs.bankrupt = v != 0;
            if (std.mem.eql(u8, key, "auto_admit")) gs.auto_admit = v != 0;
            if (std.mem.eql(u8, key, "difficulty")) gs.difficulty = std.enums.fromInt(@TypeOf(gs.difficulty), v) orelse return error.CorruptSave;
            if (std.mem.eql(u8, key, "share_profit_bp")) gs.share_profit_bp = try fit(@TypeOf(gs.share_profit_bp), v);
            if (std.mem.eql(u8, key, "stat_battles_won")) gs.stats.battles_won = try fit(@TypeOf(gs.stats.battles_won), v);
            if (std.mem.eql(u8, key, "stat_battles_drawn")) gs.stats.battles_drawn = try fit(@TypeOf(gs.stats.battles_drawn), v);
            if (std.mem.eql(u8, key, "stat_battles_lost")) gs.stats.battles_lost = try fit(@TypeOf(gs.stats.battles_lost), v);
            if (std.mem.eql(u8, key, "stat_hulls_lost")) gs.stats.hulls_lost = try fit(@TypeOf(gs.stats.hulls_lost), v);
            if (std.mem.eql(u8, key, "stat_hulls_salvaged")) gs.stats.hulls_salvaged = try fit(@TypeOf(gs.stats.hulls_salvaged), v);
            if (std.mem.eql(u8, key, "stat_people_kia")) gs.stats.people_kia = try fit(@TypeOf(gs.stats.people_kia), v);
            if (std.mem.eql(u8, key, "stat_enemy_bv")) gs.stats.enemy_bv_destroyed = try fit(@TypeOf(gs.stats.enemy_bv_destroyed), v);
            if (std.mem.eql(u8, key, "next_person_id")) gs.next_person_id = try fit(@TypeOf(gs.next_person_id), v);
            if (std.mem.eql(u8, key, "next_unit_id")) gs.next_unit_id = try fit(@TypeOf(gs.next_unit_id), v);
            if (std.mem.eql(u8, key, "next_force_id")) gs.next_force_id = try fit(@TypeOf(gs.next_force_id), v);
            if (std.mem.eql(u8, key, "next_hq_id")) gs.next_hq_id = try fit(@TypeOf(gs.next_hq_id), v);
            if (std.mem.eql(u8, key, "next_contract_id")) gs.next_contract_id = try fit(@TypeOf(gs.next_contract_id), v);
            if (std.mem.eql(u8, key, "next_battle_id")) gs.next_battle_id = try fit(@TypeOf(gs.next_battle_id), v);
            if (std.mem.eql(u8, key, "next_event_id")) gs.event_queue.next_id = try fit(@TypeOf(gs.event_queue.next_id), v);
            if (std.mem.eql(u8, key, "rng_seed")) {
                gs.rng.seed = @bitCast(v);
                has_seed = true;
            }
        }
        const tx = try self.db.prepare("SELECT key, value FROM meta_text WHERE cid = ?1");
        defer tx.finalize();
        try tx.bindAll(.{cid});
        while (try tx.next()) {
            const key = try tx.text(0, alloc);
            if (std.mem.eql(u8, key, "outfit_name")) gs.outfit_name = try tx.text(1, alloc);
        }
        return has_seed;
    }

    fn loadCommander(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT name, origin, profession FROM commander WHERE cid = ?1");
        defer st.finalize();
        try st.bindAll(.{cid});
        if (try st.next()) {
            gs.commander = .{
                .name = try st.text(0, alloc),
                .origin = st.enumValue(commander_mod.Faction, 1) orelse return error.CorruptSave,
                .profession = st.enumValue(commander_mod.Profession, 2) orelse return error.CorruptSave,
            };
        }
    }

    // People.
    fn loadPerson(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT id, first, last, callsign, role, xp, status, fatigue, morale, recruited_day, salary_override, assigned_force, posted_hq, weekly_hours, medbay_priority, leave_until, wound_heal_day, training_skill, training_done, admitted, rank, rank_pinned, kills, kill_bv, battles, tours, outstanding_tours, edge_spent, faction, shares, born_day, last_raise_day, last_award_day, departed_day FROM person WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            var p: person_mod.Person = .{
                .id = try toId(types.PersonId, st.int(0)),
                .first_name = try st.text(1, alloc),
                .last_name = try st.text(2, alloc),
                .callsign = try st.optText(3, alloc),
                .role = st.enumValue(person_mod.Role, 4) orelse return error.CorruptSave,
                .xp = try st.intAs(u32, 5),
                .status = st.enumValue(person_mod.Status, 6) orelse return error.CorruptSave,
                .fatigue = try st.intAs(u8, 7),
                .morale = try st.intAs(u8, 8),
                .recruited_day = try st.intAs(u32, 9),
                .salary_override = st.optInt(10),
                .assigned_force = try toId(types.ForceId, st.int(11)),
                .posted_hq = try toId(types.HqId, st.int(12)),
                .weekly_hours = try st.intAs(u16, 13),
                .medbay_priority = try st.intAs(u8, 14),
                .leave_until_day = try optU32(st.optInt(15)),
                .wound_heal_day = try optU32(st.optInt(16)),
                .medbay_admitted = st.int(19) != 0,
                .rank = st.enumValue(@import("../domain/rank.zig").Rank, 20) orelse return error.CorruptSave,
                .rank_pinned = st.int(21) != 0,
                .kills = try st.intAs(u32, 22),
                .kill_bv = try st.intAs(u32, 23),
                .battles = try st.intAs(u32, 24),
                .tours = try st.intAs(u32, 25),
                .outstanding_tours = try st.intAs(u32, 26),
                .edge_spent = st.int(27) != 0,
                .faction = try st.text(28, alloc),
                .shares = try st.intAs(u8, 29),
                .born_day = if (st.optInt(30)) |b| try fit(i32, b) else null,
                .last_raise_day = try optU32(st.optInt(31)),
                .last_award_day = try optU32(st.optInt(32)),
                .departed_day = try optU32(st.optInt(33)),
            };
            if (st.enumValue(types.SkillType, 17)) |skill| {
                if (st.optInt(18)) |done| p.training = .{ .skill = skill, .done_day = try fit(u32, done) };
            }
            try gs.people.put(alloc, p.id, p);
        }
        const sk = try self.db.prepare("SELECT person_id, skill, level FROM person_skill WHERE cid = ?1");
        defer sk.finalize();
        try sk.bindAll(.{cid});
        while (try sk.next()) {
            const p = gs.people.getPtr(try toId(types.PersonId, sk.int(0))) orelse return error.CorruptSave;
            const skill = sk.enumValue(types.SkillType, 1) orelse return error.CorruptSave;
            try p.skills.put(alloc, skill, try sk.intAs(u8, 2));
        }
        const aw = try self.db.prepare("SELECT person_id, key FROM award WHERE cid = ?1");
        defer aw.finalize();
        try aw.bindAll(.{cid});
        while (try aw.next()) {
            const p = gs.people.getPtr(try toId(types.PersonId, aw.int(0))) orelse return error.CorruptSave;
            try p.awards.append(alloc, try aw.text(1, alloc));
        }
        const ab = try self.db.prepare("SELECT person_id, key FROM ability WHERE cid = ?1");
        defer ab.finalize();
        try ab.bindAll(.{cid});
        while (try ab.next()) {
            const p = gs.people.getPtr(try toId(types.PersonId, ab.int(0))) orelse return error.CorruptSave;
            try p.abilities.append(alloc, try ab.text(1, alloc));
        }
        const inj = try self.db.prepare("SELECT person_id, location, severity, incurred, heal_done, doctor, permanent, healed FROM injury WHERE cid = ?1 ORDER BY person_id, ord");
        defer inj.finalize();
        try inj.bindAll(.{cid});
        while (try inj.next()) {
            const p = gs.people.getPtr(try toId(types.PersonId, inj.int(0))) orelse return error.CorruptSave;
            const location = inj.enumValue(person_mod.InjuryLocation, 1) orelse return error.CorruptSave;
            try p.injuries.append(alloc, .{
                .location = location,
                .severity = try inj.intAs(u8, 2),
                .incurred_day = try inj.intAs(u32, 3),
                .heal_done_day = try optU32(inj.optInt(4)),
                .doctor = try toId(types.PersonId, inj.int(5)),
                .permanent = inj.int(6) != 0,
                .healed = inj.int(7) != 0,
            });
        }
    }

    // Units.
    fn loadUnit(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT id, chassis_key, name, kind, force, pilot, tech, armor_pct, quality, status, last_maint, acquired_day, price, reactivation_done, berth_hq, wreck, held_by, held_day, held_battle, held_force FROM unit WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const u: unit_mod.Unit = .{
                .id = try toId(types.UnitId, st.int(0)),
                .chassis_key = try st.text(1, alloc),
                .name = try st.optText(2, alloc),
                .kind = st.enumValue(unit_mod.UnitKind, 3) orelse return error.CorruptSave,
                .force = try toId(types.ForceId, st.int(4)),
                .pilot = try toId(types.PersonId, st.int(5)),
                .tech = try toId(types.PersonId, st.int(6)),
                .armor_pct = try st.intAs(u8, 7),
                .quality = st.enumValue(types.Quality, 8) orelse return error.CorruptSave,
                .status = st.enumValue(unit_mod.UnitStatus, 9) orelse return error.CorruptSave,
                .last_maintenance_day = try optU32(st.optInt(10)),
                .acquired_day = try st.intAs(u32, 11),
                .purchase_price = st.int(12),
                .reactivation_done_day = try optU32(st.optInt(13)),
                .berth_hq = try toId(types.HqId, st.int(14)),
                .wreck = st.enumValue(unit_mod.WreckCause, 15) orelse return error.CorruptSave,
            };
            // A non-empty `held_by` is what tells the two apart: the
            // enemy's hulls go to the limbo list, ours to the books.
            const held_by = try st.text(16, alloc);
            if (held_by.len == 0) {
                try gs.units.put(alloc, u.id, u);
            } else {
                try gs.held_hulls.append(alloc, .{
                    .unit = u,
                    .by = held_by,
                    .day = try st.intAs(u32, 17),
                    .battle = try toId(types.BattleId, st.int(18)),
                    .from_force = try toId(types.ForceId, st.int(19)),
                });
            }
        }
        const sl = try self.db.prepare("SELECT unit_id, slot_key, part_key, class, condition FROM unit_slot WHERE cid = ?1 ORDER BY unit_id, ord");
        defer sl.finalize();
        try sl.bindAll(.{cid});
        while (try sl.next()) {
            const uid = try toId(types.UnitId, sl.int(0));
            const u = gs.units.getPtr(uid) orelse held: {
                for (gs.held_hulls.items) |*h| if (h.unit.id == uid) break :held &h.unit;
                continue;
            };
            try u.slots.append(alloc, .{
                .slot_key = try sl.text(1, alloc),
                .part_key = try sl.text(2, alloc),
                .class = sl.enumValue(unit_mod.SlotClass, 3) orelse return error.CorruptSave,
                .condition = sl.enumValue(unit_mod.PartCondition, 4) orelse return error.CorruptSave,
            });
        }
    }

    // Forces.
    fn loadForce(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT id, parent, name, emblem, local_funds, echelon, commander, supplying_hq, role, support_kind, last_rotation, contracts_since_rotation, location_planet, return_eta, shortage_days, roe FROM force WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const f: force_mod.Force = .{
                .id = try toId(types.ForceId, st.int(0)),
                .parent = try toId(types.ForceId, st.int(1)),
                .name = try st.text(2, alloc),
                .emblem = if (st.isNull(3)) null else try st.blob(3, alloc),
                .local_funds = st.int(4),
                .echelon = st.enumValue(force_mod.Echelon, 5) orelse return error.CorruptSave,
                .commander = try toId(types.PersonId, st.int(6)),
                .supplying_hq = try toId(types.HqId, st.int(7)),
                .role = st.enumValue(force_mod.LanceRole, 8) orelse return error.CorruptSave,
                .support_kind = st.enumValue(force_mod.SupportLanceKind, 9),
                .last_rotation_day = try optU32(st.optInt(10)),
                .contracts_since_rotation = try st.intAs(u16, 11),
                .location_planet = try st.optText(12, alloc),
                .return_eta_day = try optU32(st.optInt(13)),
                .supply_shortage_days = try st.intAs(u16, 14),
                .roe = st.enumValue(force_mod.Roe, 15) orelse return error.CorruptSave,
            };
            try gs.forces.put(alloc, f.id, f);
        }
        const fu = try self.db.prepare("SELECT force_id, unit_id FROM force_unit WHERE cid = ?1 ORDER BY force_id, ord");
        defer fu.finalize();
        try fu.bindAll(.{cid});
        while (try fu.next()) {
            const f = gs.forces.getPtr(try toId(types.ForceId, fu.int(0))) orelse return error.CorruptSave;
            try f.units.append(alloc, try toId(types.UnitId, fu.int(1)));
        }
        const fc = try self.db.prepare("SELECT force_id, child_id FROM force_child WHERE cid = ?1 ORDER BY force_id, ord");
        defer fc.finalize();
        try fc.bindAll(.{cid});
        while (try fc.next()) {
            const f = gs.forces.getPtr(try toId(types.ForceId, fc.int(0))) orelse return error.CorruptSave;
            try f.children.append(alloc, try toId(types.ForceId, fc.int(1)));
        }
    }

    // HQs.
    fn loadHq(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT id, name, tier, planet, staff_assigned, upkeep, funds FROM hq WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const h: hq_mod.Hq = .{
                .id = try toId(types.HqId, st.int(0)),
                .name = try st.text(1, alloc),
                .tier = st.enumValue(hq_mod.HqTier, 2) orelse return error.CorruptSave,
                .planet_key = try st.text(3, alloc),
                .staff_assigned = 0, // derived: refreshHqStaffing recomputes it after the load
                .monthly_upkeep = st.int(5),
                .funds = st.int(6),
            };
            try gs.hqs.put(alloc, h.id, h);
        }
        const fa = try self.db.prepare("SELECT hq_id, kind, level FROM hq_facility WHERE cid = ?1 ORDER BY hq_id, ord");
        defer fa.finalize();
        try fa.bindAll(.{cid});
        while (try fa.next()) {
            const h = gs.hqs.getPtr(try toId(types.HqId, fa.int(0))) orelse return error.CorruptSave;
            try h.facilities.append(alloc, .{ .kind = fa.enumValue(hq_mod.FacilityKind, 1) orelse return error.CorruptSave, .level = try fa.intAs(u8, 2) });
        }
        const pr = try self.db.prepare("SELECT hq_id, kind, facility, target_level, started, paperwork_done, construction_done, cost FROM hq_project WHERE cid = ?1 ORDER BY hq_id, ord");
        defer pr.finalize();
        try pr.bindAll(.{cid});
        while (try pr.next()) {
            const h = gs.hqs.getPtr(try toId(types.HqId, pr.int(0))) orelse return error.CorruptSave;
            try h.projects.append(alloc, .{
                .kind = pr.enumValue(hq_mod.ProjectKind, 1) orelse return error.CorruptSave,
                .facility = pr.enumValue(hq_mod.FacilityKind, 2),
                .target_level = try pr.intAs(u8, 3),
                .started_day = try pr.intAs(u32, 4),
                .paperwork_done_day = try pr.intAs(u32, 5),
                .construction_done_day = try pr.intAs(u32, 6),
                .cost = pr.int(7),
            });
        }
    }

    // Stock at every site.
    fn loadStock(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT owner_kind, owner_id, key, qty FROM stock WHERE cid = ?1 ORDER BY owner_kind, owner_id, ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const kind = try st.text(0, alloc);
            const site = try siteFromCols(kind, st.int(1));
            try gs.addStock(site, try st.text(2, alloc), try st.intAs(u32, 3));
        }
    }

    // Contracts & offers.
    fn loadContract(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT is_offer, id, kind, employer, enemy, planet, status, company, start_day, score, dist_ly, beachhead, transit_days, arrive_day, end_day, monthly_net, next_battle, battles, casualties, objective, committed_bv, pool, pool_remaining, vp, ineffective_since, breach_day, length_months, base_pay, advance_pct, signing_bonus, transport_pct, overhead_pct, battle_loss_pct, salvage_pct, salvage_exchange, command_rights, negotiated, enemy_lances, enemy_quality, enemy_lance_bv, enemy_lance_tons, offer_hq, orders_day FROM contract WHERE cid = ?1 ORDER BY is_offer, ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const c: contract_mod.Contract = .{
                .id = try toId(types.ContractId, st.int(1)),
                .kind = st.enumValue(contract_mod.ContractKind, 2) orelse return error.CorruptSave,
                .employer_key = try st.text(3, alloc),
                .enemy_key = try st.text(4, alloc),
                .planet_key = try st.text(5, alloc),
                .status = st.enumValue(contract_mod.ContractStatus, 6) orelse return error.CorruptSave,
                .assigned_company = try toId(types.ForceId, st.int(7)),
                .start_day = try optU32(st.optInt(8)),
                .score = try st.intAs(i32, 9),
                .dist_ly = try st.intAs(u32, 10),
                .beachhead = st.int(11) != 0,
                .transit_days = try st.intAs(u32, 12),
                .arrive_day = try optU32(st.optInt(13)),
                .end_day = try optU32(st.optInt(14)),
                .monthly_net = st.int(15),
                .next_battle_day = try optU32(st.optInt(16)),
                .battles_fought = try st.intAs(u8, 17),
                .casualties = try st.intAs(u8, 18),
                .objective = st.enumValue(contract_mod.ObjectiveKind, 19) orelse return error.CorruptSave,
                .committed_bv = st.int(20),
                .enemy_pool_bv = st.int(21),
                .enemy_pool_remaining = st.int(22),
                .victory_points = try st.intAs(i32, 23),
                .ineffective_since = try optU32(st.optInt(24)),
                .breach_day = try optU32(st.optInt(25)),
                .negotiated = st.int(36) != 0,
                .enemy_lances = try st.intAs(u8, 37),
                .enemy_quality = st.enumValue(types.ExperienceLevel, 38) orelse return error.CorruptSave,
                .enemy_lance_bv = st.int(39),
                .enemy_lance_tons = try st.intAs(u32, 40),
                .offer_hq = try toId(types.HqId, st.int(41)),
                .orders_day = try optU32(st.optInt(42)),
                .terms = .{
                    .length_months = try st.intAs(u8, 26),
                    .base_pay_month = st.int(27),
                    .advance_pct = try st.intAs(u8, 28),
                    .signing_bonus = st.int(29),
                    .transport_pct = try st.intAs(u8, 30),
                    .overhead_pct = try st.intAs(u8, 31),
                    .battle_loss_pct = try st.intAs(u8, 32),
                    .salvage_pct = try st.intAs(u8, 33),
                    .salvage_exchange = st.int(34) != 0,
                    .command_rights = st.enumValue(contract_mod.CommandRights, 35) orelse return error.CorruptSave,
                },
            };
            if (st.int(0) != 0) try gs.contract_offers.append(alloc, c) else try gs.contracts.put(alloc, c.id, c);
        }
    }

    // Lists.
    fn loadTxn(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT day, amount, category, company, hq, contract, note FROM txn WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.ledger.transactions.append(alloc, .{
                .day = try st.intAs(u32, 0),
                .amount = st.int(1),
                .category = st.enumValue(finance_mod.Category, 2) orelse return error.CorruptSave,
                .company = try toId(types.ForceId, st.int(3)),
                .hq = try toId(types.HqId, st.int(4)),
                .contract = try toId(types.ContractId, st.int(5)),
                .note = try st.text(6, alloc),
            });
        }
    }

    fn loadLoan(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT principal, balance, rate_bp, term, next_pay, payment FROM loan WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.loans.append(alloc, .{ .principal = st.int(0), .balance = st.int(1), .rate_bp = st.int(2), .term_months = try st.intAs(u16, 3), .next_pay_day = try st.intAs(u32, 4), .payment = st.int(5) });
        }
    }

    fn loadCourier(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT to_kind, to_id, amount, sent, eta FROM courier WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.fund_couriers.append(alloc, .{ .to = try treasuryFromCols(try st.text(0, alloc), st.int(1)), .amount = st.int(2), .sent_day = try st.intAs(u32, 3), .eta_day = try st.intAs(u32, 4) });
        }
    }

    fn loadPolicy(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT entity_kind, entity_id, floor, cap, sent FROM policy WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.policies.append(alloc, .{ .entity = try treasuryFromCols(try st.text(0, alloc), st.int(1)), .floor = st.int(2), .monthly_cap = st.int(3), .sent_this_month = st.int(4) });
        }
    }

    fn loadSupplyPolicy(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT company, min_days, tons, ammo_battles FROM supply_policy WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.supply_policies.append(alloc, .{ .company = try toId(types.ForceId, st.int(0)), .min_days = try st.intAs(u16, 1), .tons = try st.intAs(u32, 2), .ammo_battles = try st.intAs(u8, 3) });
        }
    }

    fn loadStockPolicy(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT hq, part_key, min_qty, target FROM stock_policy WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.stock_policies.append(alloc, .{ .hq = try toId(types.HqId, st.int(0)), .part_key = try st.text(1, alloc), .min = try st.intAs(u32, 2), .target = try st.intAs(u32, 3) });
        }
    }

    fn loadBayJob(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT hq, kind, unit, item_key, duration, queued, started, done, cost FROM bay_job WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.bay_jobs.append(alloc, .{
                .hq = try toId(types.HqId, st.int(0)),
                .kind = st.enumValue(state_mod.BayJobKind, 1) orelse return error.CorruptSave,
                .unit = try toId(types.UnitId, st.int(2)),
                .item_key = try st.text(3, alloc),
                .duration_days = try st.intAs(u32, 4),
                .queued_day = try st.intAs(u32, 5),
                .started_day = try optU32(st.optInt(6)),
                .done_day = try optU32(st.optInt(7)),
                .cost = st.int(8),
            });
        }
    }

    fn loadCandidate(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT hq, first, last, callsign, role, experience, primary_skill, secondary_skill, bonus, listed, expires, age FROM candidate WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.candidates.append(alloc, .{
                .hq = try toId(types.HqId, st.int(0)),
                .spec = .{
                    .first = try st.text(1, alloc),
                    .last = try st.text(2, alloc),
                    .callsign = try st.optText(3, alloc),
                    .role = st.enumValue(person_mod.Role, 4) orelse return error.CorruptSave,
                    .experience = st.enumValue(types.ExperienceLevel, 5) orelse return error.CorruptSave,
                    .primary_skill = try st.intAs(u8, 6),
                    .secondary_skill = try st.intAs(u8, 7),
                    .age = try st.intAs(u8, 11),
                },
                .asking_bonus = st.int(8),
                .listed_day = try st.intAs(u32, 9),
                .expires_day = try st.intAs(u32, 10),
            });
        }
    }

    fn loadHqLink(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT a, b, level, tons, established FROM hq_link WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.hq_links.append(alloc, .{ .a = try toId(types.HqId, st.int(0)), .b = try toId(types.HqId, st.int(1)), .level = try st.intAs(u8, 2), .tons_this_week = try st.intAs(u32, 3), .established_day = try st.intAs(u32, 4) });
        }
    }

    fn loadUnitTransfer(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT unit, to_company, eta FROM unit_transfer WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.unit_transfers.append(alloc, .{ .unit = try toId(types.UnitId, st.int(0)), .to_company = try toId(types.ForceId, st.int(1)), .eta_day = try st.intAs(u32, 2) });
        }
    }

    fn loadFactionCooling(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT faction, until_day FROM faction_cooling WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.faction_cooling.append(alloc, .{ .faction = try st.text(0, alloc), .until_day = try st.intAs(u32, 1) });
        }
    }

    fn loadFactionStanding(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT faction, value FROM faction_standing WHERE cid = ?1");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.faction_standing.put(alloc, try st.text(0, alloc), try st.intAs(i32, 1));
        }
    }

    fn loadEventMemory(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT kind, last_day, last_choice, streak FROM event_memory WHERE cid = ?1");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const kind = st.enumValue(events_mod.EventKind, 0) orelse return error.CorruptSave;
            try gs.event_memory.put(alloc, kind, .{ .last_day = try st.intAs(u32, 1), .last_choice = try st.intAs(u8, 2), .streak = try st.intAs(u8, 3) });
        }
    }

    fn loadRatingSnapshot(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT year, score FROM rating_snapshot WHERE cid = ?1 ORDER BY year");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.rating_history.append(alloc, .{ .year = try st.intAs(i32, 0), .score = try st.intAs(i32, 1) });
        }
    }

    fn loadListing(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT kind, item_key, rarity, price, qty, staple, listed, expires, hq, c_armor, c_quality, c_damaged, c_destroyed, c_missing, black, company FROM listing WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            var l: market_mod.Listing = .{
                .kind = if (std.mem.eql(u8, try st.text(0, alloc), "unit")) .unit else .part,
                .item_key = try st.text(1, alloc),
                .rarity = st.enumValue(types.Rarity, 2) orelse return error.CorruptSave,
                .price = st.int(3),
                .quantity = try st.intAs(u32, 4),
                .staple = st.int(5) != 0,
                .listed_day = try st.intAs(u32, 6),
                .expires_day = try st.intAs(u32, 7),
                .hq = try toId(types.HqId, st.int(8)),
                .black_market = st.int(14) != 0,
                .company = try toId(types.ForceId, st.int(15)),
            };
            if (st.optInt(9)) |armor| {
                l.condition = .{
                    .armor_pct = try fit(u8, armor),
                    .quality = st.enumValue(types.Quality, 10) orelse return error.CorruptSave,
                    .damaged_slots = try st.intAs(u8, 11),
                    .destroyed_slots = try st.intAs(u8, 12),
                    .missing_components = try st.intAs(u8, 13),
                };
            }
            try gs.market_listings.append(alloc, l);
        }
    }

    fn loadPartOrder(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT part_key, qty, dest_kind, dest_id, ordered, eta, cost, status FROM part_order WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.part_orders.append(alloc, .{
                .part_key = try st.text(0, alloc),
                .quantity = try st.intAs(u32, 1),
                .dest = try siteFromCols(try st.text(2, alloc), st.int(3)),
                .ordered_day = try st.intAs(u32, 4),
                .eta_day = try optU32(st.optInt(5)),
                .cost = st.int(6),
                .status = st.enumValue(@import("../domain/part.zig").OrderStatus, 7) orelse return error.CorruptSave,
            });
        }
    }

    fn loadEventLog(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT day, category, company, hq, contract, text FROM event_log WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.event_log.append(alloc, .{
                .day = try st.intAs(u32, 0),
                .category = st.enumValue(state_mod.LogCategory, 1) orelse return error.CorruptSave,
                .company = try toId(types.ForceId, st.int(2)),
                .hq = try toId(types.HqId, st.int(3)),
                .contract = try toId(types.ContractId, st.int(4)),
                .text = try st.text(5, alloc),
            });
        }
    }

    fn loadPendingEvent(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT kind, day, contract, company, default_choice, deadline, chosen, person, id, battle FROM pending_event WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const kind = st.enumValue(events_mod.EventKind, 0) orelse return error.CorruptSave;
            const entry = contract_events.entryForKind(kind) orelse return error.CorruptSave;
            try gs.event_queue.pending.append(alloc, .{
                .day = try st.intAs(u32, 1),
                .kind = kind,
                .contract = try toId(types.ContractId, st.int(2)),
                .company = try toId(types.ForceId, st.int(3)),
                .options = entry.options,
                .default_choice = try st.intAs(usize, 4),
                .deadline_day = try st.intAs(u32, 5),
                .chosen = if (st.optInt(6)) |c| try fit(usize, c) else null,
                .person = try toId(types.PersonId, st.int(7)),
                .id = try toId(types.EventId, st.int(8)),
                .battle = try toId(types.BattleId, st.int(9)),
            });
        }
        // A save before schema v26 has every id defaulted to 0; stamp them
        // in load order so the inbox is addressable, then resume past the
        // highest (the queue owns the numbering, `events.EventQueue`).
        for (gs.event_queue.pending.items, 0..) |*ev, i| {
            if (ev.id == .none) ev.id = @enumFromInt(i + 1);
        }
        gs.event_queue.resumeIds();
    }

    fn loadBattleReport(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        // Battle reports. Child rows are read per report; an outcome or
        // ROE that does not parse is `error.CorruptSave`.
        const br = try self.db.prepare("SELECT ord, id, day, contract, company, kind, enemy_key, scenario, terrain, weather, outcome, held_field, withdrew, roe, roe_overridden, player_power, enemy_power, conditions_mod, close_terrain, air_grounded, convoy_hit, edge_spent_by, recon_quality, avg_fatigue, avg_morale, hits_taken, destroyed, wounded, kia, lost_hulls, missing, enemy_destroyed_bv, kills_credited, prisoners, battle_loss_comp, score_after, score_delta, morale_delta, fatigue_add, battle_loss_pct, salvage_pct, command_rights, silenced_mounts, armor_left, salvage_claimed, salvage_haulable, salvage_cut, salvage_cash, salvage_items, conceded, acknowledged, salvage_unclaimed FROM battle_report WHERE cid = ?1 ORDER BY ord");
        defer br.finalize();
        try br.bindAll(.{cid});
        while (try br.next()) {
            const ord = br.int(0);
            const outcome = br.enumValue(autoresolve_mod.Outcome, 10) orelse return error.CorruptSave;
            const roe = br.enumValue(force_mod.Roe, 13) orelse return error.CorruptSave;

            const hulls = try self.loadReportHits(alloc, cid, ord);
            const ammo = try self.loadReportAmmo(alloc, cid, ord);
            const candidates = try self.loadReportSalvage(alloc, cid, ord);
            try gs.battle_reports.kept.append(alloc, .{
                .id = try toId(types.BattleId, br.int(1)),
                .day = try br.intAs(u32, 2),
                .contract = try toId(types.ContractId, br.int(3)),
                .company = try toId(types.ForceId, br.int(4)),
                .kind = try br.text(5, alloc),
                .enemy_key = try br.text(6, alloc),
                .scenario = try br.text(7, alloc),
                .terrain = try br.text(8, alloc),
                .weather = try br.text(9, alloc),
                .outcome = outcome,
                .held_field = br.int(11) != 0,
                .withdrew = br.int(12) != 0,
                .roe = roe,
                .roe_overridden = br.int(14) != 0,
                .player_power = br.int(15),
                .enemy_power = br.int(16),
                .conditions_mod = try br.intAs(i32, 17),
                .close_terrain = br.int(18) != 0,
                .air_grounded = br.int(19) != 0,
                .convoy_hit = br.int(20) != 0,
                .edge_spent_by = try br.text(21, alloc),
                .recon_quality = try br.intAs(u8, 22),
                .avg_fatigue = try br.intAs(u8, 23),
                .avg_morale = try br.intAs(u8, 24),
                .hits_taken = try br.intAs(u32, 25),
                .destroyed = try br.intAs(u8, 26),
                .wounded = try br.intAs(u8, 27),
                .kia = try br.intAs(u8, 28),
                .lost_hulls = try br.intAs(u32, 29),
                .missing = try br.intAs(u32, 30),
                .enemy_destroyed_bv = br.int(31),
                .kills_credited = try br.intAs(u32, 32),
                .prisoners = try br.intAs(u32, 33),
                .battle_loss_comp = br.int(34),
                .score_after = try br.intAs(i32, 35),
                .score_delta = try br.intAs(i32, 36),
                .morale_delta = try br.intAs(i32, 37),
                .fatigue_add = try br.intAs(u8, 38),
                .battle_loss_pct = try br.intAs(u8, 39),
                .salvage_pct = try br.intAs(u8, 40),
                .command_rights = try br.text(41, alloc),
                .hulls = hulls,
                .ammo = ammo,
                .silenced_mounts = try br.intAs(u32, 42),
                .armor_left = try br.intAs(u32, 43),
                .salvage = .{
                    .claimed_bv = br.int(44),
                    .haulable_bv = br.int(45),
                    .liaison_cut = br.int(46),
                    .exchange_cash = br.int(47),
                    .items = try br.text(48, alloc),
                    .candidates = candidates,
                    .unclaimed_bv = br.int(51),
                },
                .conceded = br.int(49) != 0,
                .acknowledged = br.int(50) != 0,
            });
        }
    }

    /// The hulls a report's hit rows name, in order.
    fn loadReportHits(self: Store, alloc: std.mem.Allocator, cid: i64, ord: i64) ![]after_action_mod.HullHit {
        var hulls: std.ArrayListUnmanaged(after_action_mod.HullHit) = .empty;
        const bh = try self.db.prepare("SELECT unit, chassis_key, chassis_name, armor_before, armor_after, slot, slot_part, slot_result, destroyed, cause, pilot, crew_name, wound_severity, wound_location, wound_permanent, fate, recovery_roll, recovery_target, lost FROM battle_report_hit WHERE cid = ?1 AND report_ord = ?2 ORDER BY ord");
        defer bh.finalize();
        try bh.bindAll(.{ cid, ord });
        while (try bh.next()) {
            const slot_text = try bh.text(5, alloc);
            try hulls.append(alloc, .{
                .unit = try toId(types.UnitId, bh.int(0)),
                .chassis_key = try bh.text(1, alloc),
                .chassis_name = try bh.text(2, alloc),
                .armor_before = try bh.intAs(u8, 3),
                .armor_after = try bh.intAs(u8, 4),
                .slot = if (slot_text.len > 0) slot_text else null,
                .slot_part = try bh.text(6, alloc),
                .slot_result = bh.enumValue(after_action_mod.SlotResult, 7) orelse return error.CorruptSave,
                .destroyed = bh.int(8) != 0,
                .cause = bh.enumValue(unit_mod.WreckCause, 9) orelse return error.CorruptSave,
                .pilot = try toId(types.PersonId, bh.int(10)),
                .crew_name = try bh.text(11, alloc),
                .crew = .{
                    .wound = if (bh.optInt(12)) |sev| .{
                        .severity = try fit(u8, sev),
                        .location = bh.enumValue(person_mod.InjuryLocation, 13) orelse return error.CorruptSave,
                        .permanent = bh.int(14) != 0,
                    } else null,
                    .fate = bh.enumValue(after_action_mod.CrewOutcome.Fate, 15) orelse return error.CorruptSave,
                },
                .recovery = if (bh.optInt(16)) |roll| .{ .roll = try fit(i32, roll), .target = try bh.intAs(i32, 17) } else null,
                .lost = bh.int(18) != 0,
            });
        }
        return hulls.items;
    }

    /// A report's ammunition lines, in order.
    fn loadReportAmmo(self: Store, alloc: std.mem.Allocator, cid: i64, ord: i64) ![]after_action_mod.AmmoLine {
        var ammo: std.ArrayListUnmanaged(after_action_mod.AmmoLine) = .empty;
        const ba = try self.db.prepare("SELECT family, burned, reserve FROM battle_report_ammo WHERE cid = ?1 AND report_ord = ?2 ORDER BY ord");
        defer ba.finalize();
        try ba.bindAll(.{ cid, ord });
        while (try ba.next()) try ammo.append(alloc, .{
            .key = try ba.text(0, alloc),
            .burned = try ba.intAs(u32, 1),
            .left = try ba.intAs(u32, 2),
        });
        return ammo.items;
    }

    /// The wrecks a report's salvage claim was divided over, in order.
    fn loadReportSalvage(self: Store, alloc: std.mem.Allocator, cid: i64, ord: i64) ![]after_action_mod.SalvageCandidate {
        var candidates: std.ArrayListUnmanaged(after_action_mod.SalvageCandidate) = .empty;
        const bs = try self.db.prepare("SELECT key, name, bv, armor_pct, quality, damaged, destroyed, missing FROM battle_report_salvage WHERE cid = ?1 AND report_ord = ?2 ORDER BY ord");
        defer bs.finalize();
        try bs.bindAll(.{ cid, ord });
        while (try bs.next()) try candidates.append(alloc, .{
            .key = try bs.text(0, alloc),
            .name = try bs.text(1, alloc),
            .bv = bs.int(2),
            .armor_pct = try bs.intAs(u8, 3),
            .quality = bs.enumValue(types.Quality, 4) orelse return error.CorruptSave,
            .damaged_slots = try bs.intAs(u8, 5),
            .destroyed_slots = try bs.intAs(u8, 6),
            .missing_components = try bs.intAs(u8, 7),
        });
        return candidates.items;
    }

    fn loadRefitPlan(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const pl = try self.db.prepare("SELECT ord, unit, committed FROM refit_plan WHERE cid = ?1 ORDER BY ord");
        defer pl.finalize();
        try pl.bindAll(.{cid});
        while (try pl.next()) {
            try gs.refit_plans.append(alloc, .{ .unit = try toId(types.UnitId, pl.int(1)), .committed = pl.int(2) != 0 });
        }
        const op = try self.db.prepare("SELECT plan_ord, kind, slot_key, location, part_key FROM refit_op WHERE cid = ?1 ORDER BY plan_ord, ord");
        defer op.finalize();
        try op.bindAll(.{cid});
        while (try op.next()) {
            const idx: usize = try op.intAs(usize, 0);
            if (idx >= gs.refit_plans.items.len) continue;
            const kind = try op.text(1, alloc);
            if (std.mem.eql(u8, kind, "remove")) {
                try gs.refit_plans.items[idx].ops.append(alloc, .{ .remove = try op.text(2, alloc) });
            } else {
                try gs.refit_plans.items[idx].ops.append(alloc, .{ .install = .{
                    .location = op.enumValue(@import("../domain/meklab.zig").Location, 3) orelse return error.CorruptSave,
                    .part_key = try op.text(4, alloc),
                } });
            }
        }
    }

    /// Data-level upgrades for campaigns saved under an older schema.
    /// Draws from the `generation` stream only when a step needs a roll.
    pub fn upgradeCampaign(gs: *GameState, from_version: u32) !void {
        // Saves before v16 have no birthdays; each person rolls an age by
        // role and experience.
        if (from_version < 16) {
            const person_gen = @import("../gen/person_gen.zig");
            var it = gs.people.iterator();
            while (it.next()) |e| {
                const p = e.value_ptr;
                if (p.born_day != null) continue;
                const age = person_gen.rollAge(&gs.rng, .generation, p.role, p.experience());
                p.setBirthdayFromAge(p.recruited_day, age);
            }
        }
        // Saves before v7 hold wounds with no located injury; triage
        // (medical.runDailyHealing) gives such a person a stand-in record,
        // so nothing is upgraded here.
    }
};

/// Save-file recovery, not a rule: a campaign saved before schema v18 has
/// no stats counters, so its log holds battles and its book holds zeros.
/// This reads the log's AAR lines once, at load. Campaigns with counters
/// count at the source (battle.zig) and never come through here.
pub fn recoverStatsFromLog(gs: *GameState) void {
    var st: state_mod.Stats = .{};
    for (gs.event_log.items) |e| {
        // Lines carry a date prefix: "3025-02-15 [AAR] …".
        if (e.category != .battle or std.mem.indexOf(u8, e.text, "[AAR]") == null) continue;
        if (std.mem.indexOf(u8, e.text, " — power ") != null) {
            // "[AAR] kind vs enemy …: outcome — power a vs b"
            const head = e.text[0..std.mem.indexOf(u8, e.text, " — power ").?];
            const colon = std.mem.lastIndexOfScalar(u8, head, ':') orelse continue;
            const outcome = std.mem.trim(u8, head[colon + 1 ..], " ");
            if (std.mem.eql(u8, outcome, "decisive_victory") or std.mem.eql(u8, outcome, "victory")) st.battles_won += 1 //
            else if (std.mem.eql(u8, outcome, "draw")) st.battles_drawn += 1 //
            else if (std.mem.eql(u8, outcome, "defeat") or std.mem.eql(u8, outcome, "rout")) st.battles_lost += 1;
            continue;
        }
        if (std.mem.indexOf(u8, e.text, "losses: ")) |i| {
            // "losses: H hit / D destroyed, W wounded, K KIA | enemy losses B BV"
            var it = std.mem.tokenizeAny(u8, e.text[i + "losses: ".len ..], " /,|");
            var nums: [8]u64 = @splat(0);
            var n: usize = 0;
            while (it.next()) |tok| {
                if (n >= nums.len) break;
                if (std.fmt.parseInt(u64, tok, 10)) |v| {
                    nums[n] = v;
                    n += 1;
                } else |_| {}
            }
            // order: hit, destroyed, wounded, KIA, enemy BV
            if (n >= 5) {
                st.hulls_lost += @intCast(nums[1]);
                st.people_kia += @intCast(nums[3]);
                st.enemy_bv_destroyed += nums[4];
            }
            continue;
        }
        if (std.mem.indexOf(u8, e.text, "salvage: ") != null) {
            var rest = e.text;
            while (std.mem.indexOf(u8, rest, "wreck #")) |k| {
                st.hulls_salvaged += 1;
                rest = rest[k + "wreck #".len ..];
            }
        }
    }
    gs.stats = st;
}

test "counters rebuild from the AAR lines of an older save" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1288 });
    defer gs.deinit();
    try gs.log(.battle, .{}, "[AAR] garrison_duty vs DC: victory — power 900 vs 700 (recon 0, fatigue 4, morale 50)", .{});
    try gs.log(.battle, .{}, "[AAR]   losses: 2 hit / 1 destroyed, 1 wounded, 1 KIA | enemy losses 1200 BV ≈ 1 kill credited | salvage 300 BV claimed | comp 0 | score 1", .{});
    try gs.log(.battle, .{}, "[AAR]   salvage: wreck #40 SHD-2H Shadow Hawk (armor 30%) → home depot in 5 days; wreck #41 LCT-1V Locust → home depot in 5 days; ", .{});
    try gs.log(.battle, .{}, "[AAR] raid vs CC — ambush on heavy woods, night action: rout — power 500 vs 900 (recon 0, fatigue 9, morale 40)", .{});
    try gs.log(.battle, .{}, "[AAR]   losses: 4 hit / 2 destroyed, 2 wounded, 0 KIA | enemy losses 100 BV ≈ 0 kills credited | salvage 0 BV claimed | comp 0 | score -2", .{});
    try gs.log(.battle, .{}, "[AAR]   salvage: none — the field was not held", .{});
    recoverStatsFromLog(&gs);
    try std.testing.expectEqual(@as(u32, 1), gs.stats.battles_won);
    try std.testing.expectEqual(@as(u32, 1), gs.stats.battles_lost);
    try std.testing.expectEqual(@as(u32, 3), gs.stats.hulls_lost);
    try std.testing.expectEqual(@as(u32, 1), gs.stats.people_kia);
    try std.testing.expectEqual(@as(u32, 2), gs.stats.hulls_salvaged);
    try std.testing.expectEqual(@as(u64, 1300), gs.stats.enemy_bv_destroyed);
}

/// Every stored key names something in the catalogues, and every display
/// copy a save keeps is markup-safe; `error.CorruptSave` otherwise. The
/// screens then show these strings as they are. Free text a player chose
/// (names, log lines, crew names) is not checked here: the queries escape
/// it on the way to a screen.
fn validateStoredStrings(gs: *GameState) error{CorruptSave}!void {
    const chassis = @import("../domain/chassis.zig");
    const part = @import("../domain/part.zig");
    const planet = @import("../domain/planet.zig");
    const faction = @import("../domain/faction.zig");
    const table = @import("../sim/table.zig");
    const Check = struct {
        fn hull(key: []const u8) error{CorruptSave}!void {
            if (chassis.find(key) == null) return error.CorruptSave;
        }
        fn item(key: []const u8) error{CorruptSave}!void {
            if (!part.isKnownKey(key)) return error.CorruptSave;
        }
        fn world(key: []const u8) error{CorruptSave}!void {
            if (planet.find(key) == null) return error.CorruptSave;
        }
        fn house(key: []const u8) error{CorruptSave}!void {
            if (faction.find(key) == null) return error.CorruptSave;
        }
        fn shown(text: []const u8) error{CorruptSave}!void {
            if (!table.markupSafe(text)) return error.CorruptSave;
        }
        fn slots(u: *const @import("../domain/unit.zig").Unit) error{CorruptSave}!void {
            try hull(u.chassis_key);
            for (u.slots.items) |s| {
                try item(s.part_key);
                try shown(s.slot_key);
            }
        }
        fn stock(map: *const std.StringArrayHashMapUnmanaged(u32)) error{CorruptSave}!void {
            for (map.keys()) |k| try item(k);
        }
    };
    var uit = gs.units.iterator();
    while (uit.next()) |e| try Check.slots(e.value_ptr);
    for (gs.held_hulls.items) |*h| try Check.slots(&h.unit);
    try Check.stock(&gs.spare_parts);
    var hit = gs.hqs.iterator();
    while (hit.next()) |e| {
        try Check.world(e.value_ptr.planet_key);
        try Check.stock(&e.value_ptr.stock);
    }
    var force_it = gs.forces.iterator();
    while (force_it.next()) |e| {
        try Check.stock(&e.value_ptr.stock);
        if (e.value_ptr.location_planet) |p| try Check.world(p);
    }
    for ([_][]const @import("../domain/contract.zig").Contract{ gs.contracts.values(), gs.contract_offers.items }) |list| for (list) |c| {
        try Check.world(c.planet_key);
        try Check.house(c.employer_key);
        try Check.house(c.enemy_key);
    };
    var pit = gs.people.iterator();
    while (pit.next()) |e| if (e.value_ptr.faction.len > 0) try Check.house(e.value_ptr.faction);
    for (gs.faction_standing.keys()) |k| try Check.house(k);
    for (gs.faction_cooling.items) |f| try Check.house(f.faction);
    for (gs.market_listings.items) |l| switch (l.kind) {
        .unit => try Check.hull(l.item_key),
        .part => try Check.item(l.item_key),
    };
    for (gs.part_orders.items) |o| try Check.item(o.part_key);
    for (gs.stock_policies.items) |sp| try Check.item(sp.part_key);
    for (gs.bay_jobs.items) |j| if (j.item_key.len > 0) try Check.item(j.item_key);
    for (gs.refit_plans.items) |plan| for (plan.ops.items) |op| switch (op) {
        .install => |it| try Check.item(it.part_key),
        .remove => |slot_key| try Check.shown(slot_key),
    };
    for (gs.battle_reports.kept.items) |r| {
        inline for (.{ r.kind, r.enemy_key, r.scenario, r.terrain, r.weather, r.command_rights, r.salvage.items }) |text| try Check.shown(text);
        for (r.hulls) |h| {
            try Check.hull(h.chassis_key);
            try Check.shown(h.chassis_name);
            try Check.shown(h.slot_part);
            if (h.slot) |s| try Check.shown(s);
        }
        for (r.ammo) |a| try Check.item(a.key);
        for (r.salvage.candidates) |c| {
            try Check.hull(c.key);
            try Check.shown(c.name);
        }
    }
}

/// A stored integer as `T`; `error.CorruptSave` when it does not fit.
fn fit(comptime T: type, v: i64) error{CorruptSave}!T {
    return std.math.cast(T, v) orelse error.CorruptSave;
}

/// A typed id from a stored integer; `error.CorruptSave` outside `u32`.
fn toId(comptime T: type, v: i64) error{CorruptSave}!T {
    return @enumFromInt(std.math.cast(u32, v) orelse return error.CorruptSave);
}

fn optU32(v: ?i64) error{CorruptSave}!?u32 {
    return if (v) |x| try fit(u32, x) else null;
}

const Cols = struct { kind: []const u8, id: i64 };

fn treasuryCols(t: state_mod.Treasury) Cols {
    return switch (t) {
        .outfit => .{ .kind = "outfit", .id = 0 },
        .hq => |id| .{ .kind = "hq", .id = @intFromEnum(id) },
        .company => |id| .{ .kind = "company", .id = @intFromEnum(id) },
    };
}

fn treasuryFromCols(kind: []const u8, id: i64) error{CorruptSave}!state_mod.Treasury {
    if (std.mem.eql(u8, kind, "hq")) return .{ .hq = try toId(types.HqId, id) };
    if (std.mem.eql(u8, kind, "company")) return .{ .company = try toId(types.ForceId, id) };
    if (std.mem.eql(u8, kind, "outfit")) return .outfit;
    return error.CorruptSave;
}

fn siteCols(s: types.Site) Cols {
    return switch (s) {
        .outfit => .{ .kind = "outfit", .id = 0 },
        .hq => |id| .{ .kind = "hq", .id = @intFromEnum(id) },
        .company => |id| .{ .kind = "company", .id = @intFromEnum(id) },
    };
}

fn siteFromCols(kind: []const u8, id: i64) error{CorruptSave}!types.Site {
    if (std.mem.eql(u8, kind, "hq")) return .{ .hq = try toId(types.HqId, id) };
    if (std.mem.eql(u8, kind, "company")) return .{ .company = try toId(types.ForceId, id) };
    if (std.mem.eql(u8, kind, "outfit")) return .outfit;
    return error.CorruptSave;
}

test "save → load → identical hash, and the loaded campaign keeps playing" {
    const commands = @import("../sim/commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1101 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "Erik Kalmar", .origin = .CC, .profession = .quartermaster } });
    _ = try commands.execute(&gs, .{ .rename_outfit = "Kalmar's Free Legion" });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    _ = try commands.execute(&gs, .{ .accept_contract = .{ .offer_index = 0, .company = co } });
    _ = try commands.execute(&gs, .{ .set_policy = .{ .entity = .{ .company = co }, .floor = 200_000, .monthly_cap = 300_000 } });
    _ = try commands.execute(&gs, .{ .set_supply_policy = .{ .company = co, .min_days = 14, .tons = 20 } });
    _ = try commands.execute(&gs, .{ .set_supply_policy = .{ .company = co, .min_days = 30, .tons = 60 } }); // re-setting replaces
    _ = try commands.execute(&gs, .{ .set_stock_policy = .{ .hq = gs.hqs.keys()[0], .part_key = "ammo_lrm", .min = 10, .target = 30 } });
    _ = try commands.execute(&gs, .{ .set_auto_admit = true });
    _ = try commands.execute(&gs, .{ .set_shares_pct = 45 }); // profit shares
    gs.people.getPtr(gs.people.keys()[2]).?.shares = 4;
    gs.people.getPtr(gs.people.keys()[2]).?.last_raise_day = 3; // raise cooldown
    gs.stats.battles_won = 7; // campaign stats
    try gs.rating_history.append(gs.allocator(), .{ .year = 3025, .score = 40 });
    _ = try commands.execute(&gs, .{ .advance_days = 40 }); // battles, events, deliveries, couriers
    _ = try gs.adjustStanding("LC", 12); // faction standing rides along
    // A permanent injury on someone's record rides along.
    const scarred = gs.people.keys()[3];
    try gs.people.getPtr(scarred).?.injuries.append(gs.allocator(), .{ .location = .head, .severity = 3, .incurred_day = 5, .heal_done_day = 40, .permanent = true, .healed = true });
    // A dropship holding a berth rides along.
    const ship = try gs.addUnit("LEOPARD");
    gs.unit(ship).?.berth_hq = gs.hqs.keys()[0];
    // A company's rules of engagement ride along.
    gs.forces.getPtr(gs.forces.keys()[0]).?.roe = .cautious;
    // A wreck remembers how it died.
    const wreck = try gs.addUnit("GRF-1N");
    gs.unit(wreck).?.markWreckedBy(.engine);
    const before = gs.hash();

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try std.testing.expect(gs.campaign_id > 0);

    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", gs.firstHashDifference(&loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(before, loaded.hash());
    try std.testing.expectEqual(gs.hqs.keys()[0], loaded.unit(ship).?.berth_hq);
    try std.testing.expectEqual(@import("../domain/unit.zig").WreckCause.engine, loaded.unit(wreck).?.wreck);
    try std.testing.expectEqual(@import("../domain/force.zig").Roe.cautious, loaded.forces.getPtr(gs.forces.keys()[0]).?.roe);
    // Offers keep their opposition.
    if (gs.contract_offers.items.len > 0) {
        try std.testing.expectEqual(gs.contract_offers.items[0].enemy_lances, loaded.contract_offers.items[0].enemy_lances);
        try std.testing.expectEqual(gs.contract_offers.items[0].enemy_quality, loaded.contract_offers.items[0].enemy_quality);
        try std.testing.expectEqual(gs.contract_offers.items[0].enemy_lance_bv, loaded.contract_offers.items[0].enemy_lance_bv);
        try std.testing.expectEqual(gs.contract_offers.items[0].enemy_lance_tons, loaded.contract_offers.items[0].enemy_lance_tons);
        try std.testing.expectEqual(gs.contract_offers.items[0].offer_hq, loaded.contract_offers.items[0].offer_hq);
    }
    try std.testing.expectEqual(@as(i32, 12), loaded.standing("LC"));
    try std.testing.expectEqual(@as(usize, 1), loaded.person(scarred).?.injuries.items.len);
    try std.testing.expect(loaded.person(scarred).?.injuries.items[0].permanent);
    try std.testing.expectEqual(person_mod.InjuryLocation.head, loaded.person(scarred).?.injuries.items[0].location);
    try std.testing.expectEqualStrings("Kalmar's Free Legion", loaded.outfit_name);
    try std.testing.expectEqual(gs.people.count(), loaded.people.count());
    try std.testing.expectEqual(gs.event_log.items.len, loaded.event_log.items.len);
    try std.testing.expectEqual(gs.event_queue.pending.items.len, loaded.event_queue.pending.items.len);
    // An event is answered by id, so the ids must survive the save —
    // a length check would pass with every one of them zeroed.
    for (gs.event_queue.pending.items, loaded.event_queue.pending.items) |saved_ev, loaded_ev| {
        try std.testing.expectEqual(saved_ev.id, loaded_ev.id);
        try std.testing.expect(loaded_ev.id != .none);
        // An event's options are rebuilt from its kind on load, and
        // a kind with no `entryForKind` entry comes back unanswerable —
        // which a length check or an id check would never notice.
        try std.testing.expectEqual(saved_ev.kind, loaded_ev.kind);
        try std.testing.expectEqual(saved_ev.options.len, loaded_ev.options.len);
        try std.testing.expectEqual(saved_ev.default_choice, loaded_ev.default_choice);
        try std.testing.expectEqual(saved_ev.needsDecision(), loaded_ev.needsDecision());
        try std.testing.expectEqual(saved_ev.holdsTurn(), loaded_ev.holdsTurn());
        // A battle decision that forgets which fight it answers
        // comes back applying to nothing.
        try std.testing.expectEqual(saved_ev.battle, loaded_ev.battle);
    }
    // And the counter resumes past them, so the next event cannot collide
    // with one already in the inbox.
    for (loaded.event_queue.pending.items) |ev| {
        try std.testing.expect(@intFromEnum(ev.id) < loaded.event_queue.next_id);
    }
    // Policies survive the round trip with their current numbers (the
    // starter HQ's default top-up and provisions line ride along).
    try std.testing.expectEqual(@as(usize, 2), loaded.policies.items.len);
    try std.testing.expectEqual(gs.policies.items[1].sent_this_month, loaded.policies.items[1].sent_this_month);
    try std.testing.expectEqual(@as(usize, 1), loaded.supply_policies.items.len);
    try std.testing.expectEqual(@as(u16, 30), loaded.supply_policies.items[0].min_days);
    try std.testing.expectEqual(@as(u32, 60), loaded.supply_policies.items[0].tons);
    try std.testing.expectEqual(@as(usize, 2), loaded.stock_policies.items.len);
    try std.testing.expectEqualStrings("ammo_lrm", loaded.stock_policies.items[1].part_key);
    try std.testing.expectEqual(@as(u32, 30), loaded.stock_policies.items[1].target);
    try std.testing.expect(loaded.auto_admit);
    try std.testing.expectEqual(@as(types.Bp, 4_500), loaded.share_profit_bp);
    try std.testing.expectEqual(gs.people.getPtr(gs.people.keys()[2]).?.shares, loaded.people.getPtr(gs.people.keys()[2]).?.shares);
    try std.testing.expectEqual(@as(?u32, 3), loaded.people.getPtr(gs.people.keys()[2]).?.last_raise_day);
    try std.testing.expectEqual(gs.stats.battles_won, loaded.stats.battles_won);
    try std.testing.expect(loaded.stats.battles_won >= 7);
    try std.testing.expectEqual(@as(usize, 1), loaded.rating_history.items.len);
    try std.testing.expectEqual(@as(i32, 40), loaded.rating_history.items[0].score);

    // Determinism survives the round trip: both worlds evolve identically.
    _ = try commands.execute(&gs, .{ .advance_days = 30 });
    _ = try commands.execute(&loaded, .{ .advance_days = 30 });
    try std.testing.expectEqual(gs.hash(), loaded.hash());
}

test "players own campaigns; deleting a player cascades" {
    const commands = @import("../sim/commands.zig");
    var store = try Store.open(":memory:");
    defer store.close();
    const john = try store.createPlayer("John");
    const guest = try store.createPlayer("Guest");
    try std.testing.expect(john != guest);

    var a = GameState.init(std.testing.allocator, .{ .seed = 1 });
    defer a.deinit();
    _ = try commands.execute(&a, .{ .create_commander = .{ .name = "A", .origin = .LC, .profession = .paymaster } });
    store.player_id = john;
    try store.save(&a);
    var b = GameState.init(std.testing.allocator, .{ .seed = 2 });
    defer b.deinit();
    _ = try commands.execute(&b, .{ .create_commander = .{ .name = "B", .origin = .DC, .profession = .line_officer } });
    store.player_id = guest;
    try store.save(&b);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    try std.testing.expectEqual(@as(usize, 1), (try store.listCampaignsOf(al, john)).len);
    try std.testing.expectEqual(@as(usize, 2), (try store.listCampaigns(al)).len);
    const players = try store.listPlayers(al);
    try std.testing.expectEqual(@as(usize, 2), players.len);
    try std.testing.expectEqual(@as(i64, 1), players[0].campaigns);

    try store.deletePlayer(john);
    try std.testing.expectEqual(@as(usize, 1), (try store.listPlayers(al)).len);
    try std.testing.expectEqual(@as(usize, 1), (try store.listCampaigns(al)).len);
    try std.testing.expectEqual(guest, (try store.listCampaigns(al))[0].player_id);
}

test "one store, many playthroughs: list, overwrite, delete" {
    const commands = @import("../sim/commands.zig");
    const store = try Store.open(":memory:");
    defer store.close();

    var a = GameState.init(std.testing.allocator, .{ .seed = 1 });
    defer a.deinit();
    _ = try commands.execute(&a, .{ .create_commander = .{ .name = "A", .origin = .LC, .profession = .paymaster } });
    _ = try commands.execute(&a, .{ .rename_outfit = "Alpha Outfit" });
    try store.save(&a);

    var b = GameState.init(std.testing.allocator, .{ .seed = 2 });
    defer b.deinit();
    _ = try commands.execute(&b, .{ .create_commander = .{ .name = "B", .origin = .DC, .profession = .line_officer } });
    _ = try commands.execute(&b, .{ .rename_outfit = "Bravo Outfit" });
    try store.save(&b);
    try std.testing.expect(a.campaign_id != b.campaign_id);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const list = try store.listCampaigns(arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), list.len);

    // Saving again overwrites in place (same id, no duplicate).
    _ = try commands.execute(&a, .{ .advance_days = 10 });
    try store.save(&a);
    try std.testing.expectEqual(@as(usize, 2), (try store.listCampaigns(arena.allocator())).len);
    var reloaded = try store.load(std.testing.allocator, a.campaign_id);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(u32, 10), reloaded.clock.day_index);

    // Delete one; the other is untouched.
    try store.deleteCampaign(a.campaign_id);
    const after = try store.listCampaigns(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectEqualStrings("Bravo Outfit", after[0].name.raw);
    var still = try store.load(std.testing.allocator, b.campaign_id);
    defer still.deinit();
    try std.testing.expectEqual(b.hash(), still.hash());
}

test "a v5 store upgrades in place — columns added, version stamped, wounds left to triage" {
    // A store as the game wrote it at schema 5: no berth_hq on unit, no
    // injury table, no schema_version setting. Only the tables the fixture
    // touches are created by hand; `fromDb` creates the rest.
    const raw = try sqlite.Db.open(":memory:");
    try raw.exec(
        \\CREATE TABLE setting (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        \\CREATE TABLE campaign (id INTEGER PRIMARY KEY, name TEXT NOT NULL, commander TEXT, day INTEGER NOT NULL, date TEXT NOT NULL, schema_version INTEGER NOT NULL, save_seq INTEGER NOT NULL, player_id INTEGER NOT NULL DEFAULT 0);
        \\CREATE TABLE unit (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, chassis_key TEXT, name TEXT, kind TEXT, force INTEGER, pilot INTEGER, tech INTEGER, armor_pct INTEGER, quality TEXT, status TEXT, last_maint INTEGER, acquired_day INTEGER, price INTEGER, reactivation_done INTEGER, PRIMARY KEY (cid, id));
        \\CREATE TABLE person (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, first TEXT, last TEXT, callsign TEXT, role TEXT, xp INTEGER, status TEXT, fatigue INTEGER, morale INTEGER, recruited_day INTEGER, salary_override INTEGER, assigned_force INTEGER, posted_hq INTEGER, weekly_hours INTEGER, medbay_priority INTEGER, leave_until INTEGER, wound_heal_day INTEGER, training_skill TEXT, training_done INTEGER, admitted INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (cid, id));
        \\CREATE TABLE meta (cid INTEGER NOT NULL, key TEXT NOT NULL, value INTEGER NOT NULL);
        \\CREATE TABLE rng (cid INTEGER PRIMARY KEY, state BLOB NOT NULL);
        \\INSERT INTO rng VALUES (1, x'000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff');
        \\INSERT INTO campaign VALUES (1, 'Old Outfit', 'K', 12, '3025-01-13', 5, 1, 0);
        \\INSERT INTO meta VALUES (1, 'day_index', 12);
        \\INSERT INTO unit VALUES (1, 0, 1, 'LCT-1V', NULL, 'mek', 0, 0, 0, 100, 'c', 'ready', NULL, 0, 1500000, NULL);
        \\INSERT INTO person VALUES (1, 0, 1, 'Lori', 'Kalmar', NULL, 'mekwarrior', 0, 'wounded', 0, 50, 0, NULL, 0, 0, 40, 0, NULL, 30, NULL, NULL, 1);
    );

    const store = try Store.fromDb(raw);
    defer store.close();
    try std.testing.expect(try Store.hasColumnRt(store.db, "unit", "berth_hq"));
    try std.testing.expect(try Store.hasColumnRt(store.db, "injury", "location"));
    try std.testing.expectEqual(@as(i64, schema_version), store.getSetting("schema_version", 0));

    var gs = try store.load(std.testing.allocator, 1);
    defer gs.deinit();
    try std.testing.expectEqual(@as(u32, 12), gs.clock.day_index);
    const lori = gs.person(@enumFromInt(1)).?;
    try std.testing.expectEqual(person_mod.Status.wounded, lori.status);
    // The store does not invent a wound record; triage does, the first
    // day the medbay looks at her (the sim's rule, not the loader's).
    try std.testing.expectEqual(@as(usize, 0), lori.injuries.items.len);
    try std.testing.expectEqual(@as(?u32, 30), lori.wound_heal_day);
    try std.testing.expectEqual(types.HqId.none, gs.unit(@enumFromInt(1)).?.berth_hq);

    // A save from a newer game is refused rather than misread.
    try store.db.exec("UPDATE campaign SET schema_version = 99 WHERE id = 1");
    try std.testing.expectError(error.SaveNewerThanGame, store.load(std.testing.allocator, 1));
}

test "a battle report round-trips as fields, not as a row count" {
    const battle = @import("../sim/battle.zig");
    const part_mod = @import("../domain/part.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 90210 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    const co = try @import("../sim/starter_company.zig").generateInto(&gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "PER",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000, .salvage_pct = 30, .battle_loss_pct = 30 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    const site: types.Site = .{ .company = co };
    try gs.addStock(site, "armor", 60);
    for (part_mod.munition_keys) |key| try gs.addStock(site, key, 40);
    // Enough engagements that some hull takes a slot hit and some crew is
    // hurt — an all-clean fixture would not exercise the child rows.
    for (0..8) |_| {
        try battle.resolveEngagement(&gs, c);
        try @import("../sim/maintenance.zig").runWeeklyRepairs(&gs);
    }

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    // The fixture must actually have fought, or every assertion below is
    // vacuous — the failure mode this whole test exists to catch.
    try std.testing.expect(gs.battle_reports.kept.items.len >= 8);
    var hulls_seen: usize = 0;
    for (gs.battle_reports.kept.items) |r| hulls_seen += r.hulls.len;
    try std.testing.expect(hulls_seen > 0);
    // A battle report round-trips as fields, child rows included.
    // Asserting only the count would pass with every hull and every
    // munition family dropped on the floor.
    try std.testing.expectEqual(gs.battle_reports.kept.items.len, loaded.battle_reports.kept.items.len);
    for (gs.battle_reports.kept.items, loaded.battle_reports.kept.items) |saved_r, loaded_r| {
        try std.testing.expectEqual(saved_r.id, loaded_r.id);
        try std.testing.expectEqual(saved_r.outcome, loaded_r.outcome);
        try std.testing.expectEqual(saved_r.held_field, loaded_r.held_field);
        try std.testing.expectEqual(saved_r.player_power, loaded_r.player_power);
        try std.testing.expectEqual(saved_r.morale_delta, loaded_r.morale_delta);
        try std.testing.expectEqualStrings(saved_r.enemy_key, loaded_r.enemy_key);
        try std.testing.expectEqual(saved_r.hulls.len, loaded_r.hulls.len);
        try std.testing.expectEqual(saved_r.ammo.len, loaded_r.ammo.len);
        for (saved_r.hulls, loaded_r.hulls) |saved_h, loaded_h| {
            try std.testing.expectEqual(saved_h.unit, loaded_h.unit);
            try std.testing.expectEqual(saved_h.armor_before, loaded_h.armor_before);
            try std.testing.expectEqual(saved_h.armor_after, loaded_h.armor_after);
            try std.testing.expectEqual(saved_h.destroyed, loaded_h.destroyed);
            try std.testing.expectEqual(saved_h.cause, loaded_h.cause);
            try std.testing.expectEqual(saved_h.crew.fate, loaded_h.crew.fate);
            try std.testing.expectEqual(saved_h.crew.wound == null, loaded_h.crew.wound == null);
            if (saved_h.crew.wound) |w| {
                try std.testing.expectEqual(w.severity, loaded_h.crew.wound.?.severity);
                try std.testing.expectEqual(w.location, loaded_h.crew.wound.?.location);
            }
            try std.testing.expectEqual(saved_h.recovery == null, loaded_h.recovery == null);
            try std.testing.expectEqualStrings(saved_h.chassis_key, loaded_h.chassis_key);
        }
        for (saved_r.ammo, loaded_r.ammo) |saved_a, loaded_a| {
            try std.testing.expectEqualStrings(saved_a.key, loaded_a.key);
            try std.testing.expectEqual(saved_a.burned, loaded_a.burned);
            try std.testing.expectEqual(saved_a.left, loaded_a.left);
        }
        // The AAR a reloaded report renders is the AAR it always rendered.
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const before_lines = try after_action_mod.render(arena.allocator(), &saved_r);
        const after_lines = try after_action_mod.render(arena.allocator(), &loaded_r);
        try std.testing.expectEqual(before_lines.len, after_lines.len);
        for (before_lines, after_lines) |bl, al2| try std.testing.expectEqualStrings(bl, al2);
    }
}

test "a hull the enemy holds round-trips, slots and all — off the books, not struck off" {
    const battle = @import("../sim/battle.zig");
    const part_mod = @import("../domain/part.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12007 });
    defer gs.deinit();
    gs.difficulty = .elite; // a lost field is the point of the fixture
    _ = try gs.createCommander("T", .LC, .line_officer);
    const co = try @import("../sim/starter_company.zig").generateInto(&gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .planetary_assault,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000, .battle_loss_pct = 30 },
        .status = .active,
        .assigned_company = co,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    const site: types.Site = .{ .company = co };
    try gs.addStock(site, "armor", 60);
    for (part_mod.munition_keys) |key| try gs.addStock(site, key, 40);
    // A starving, exhausted company with no armour left: routs are the norm
    // and hulls stay on the field.
    for (0..10) |_| {
        var pit = gs.people.iterator();
        while (pit.next()) |e| {
            e.value_ptr.morale = 0;
            e.value_ptr.fatigue = 60;
        }
        var uit = gs.units.iterator();
        while (uit.next()) |e| if (e.value_ptr.status != .destroyed) {
            e.value_ptr.armor_pct = 0;
        };
        try battle.resolveEngagement(&gs, c);
    }

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    // Vacuous otherwise: if nothing was ever held, everything below passes
    // while the feature is broken.
    try std.testing.expect(gs.held_hulls.items.len > 0);
    try std.testing.expectEqual(gs.held_hulls.items.len, loaded.held_hulls.items.len);
    // Held hulls are off the books on both sides of the save, and the
    // owned count is not quietly inflated by them.
    try std.testing.expectEqual(gs.units.count(), loaded.units.count());
    var slots_seen: usize = 0;
    for (gs.held_hulls.items, loaded.held_hulls.items) |saved, got| {
        try std.testing.expectEqual(saved.unit.id, got.unit.id);
        try std.testing.expectEqualStrings(saved.unit.chassis_key, got.unit.chassis_key);
        try std.testing.expectEqual(saved.unit.status, got.unit.status);
        try std.testing.expectEqual(saved.unit.armor_pct, got.unit.armor_pct);
        try std.testing.expectEqualStrings(saved.by, got.by);
        try std.testing.expectEqual(saved.day, got.day);
        try std.testing.expectEqual(saved.battle, got.battle);
        try std.testing.expectEqual(saved.unit.slots.items.len, got.unit.slots.items.len);
        slots_seen += got.unit.slots.items.len;
        try std.testing.expect(loaded.units.get(got.unit.id) == null);
        try std.testing.expect(loaded.heldHull(got.unit.id) != null);
    }
    // The slot rows really came back — the drop this test exists to catch.
    try std.testing.expect(slots_seen > 0);
}

fn countCampaignRows(store: Store) !i64 {
    const st = try store.db.prepare("SELECT COUNT(*) FROM campaign");
    defer st.finalize();
    _ = try st.next();
    return st.int(0);
}

test "loading a campaign id with no campaign row is refused" {
    const store = try Store.open(":memory:");
    defer store.close();
    try std.testing.expectError(error.NoSuchCampaign, store.load(std.testing.allocator, 999));
}

test "a first save that fails leaves the campaign unsaved, and a retry registers it" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 4004 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    const store = try Store.open(":memory:");
    defer store.close();
    // A missing child table makes the save fail after the campaign INSERT.
    try store.db.exec("DROP TABLE unit");
    try std.testing.expect(std.meta.isError(store.save(&gs)));
    try std.testing.expectEqual(@as(i64, 0), gs.campaign_id);
    try std.testing.expectEqual(@as(i64, 0), try countCampaignRows(store));

    try store.db.exec(ddl);
    try store.save(&gs);
    try std.testing.expect(gs.campaign_id != 0);
    try std.testing.expectEqual(@as(i64, 1), try countCampaignRows(store));
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
}

test "saving over a campaign row that no longer exists is refused" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 4005 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try store.db.exec("DELETE FROM campaign");
    try std.testing.expectError(error.NoSuchCampaign, store.save(&gs));
    try std.testing.expectEqual(@as(i64, 0), try countCampaignRows(store));
}

/// Save a generated campaign, corrupt one column with `sql`, and load it
/// back.
fn loadAfterTampering(sql: [*:0]const u8) !void {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 5005 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    _ = try @import("../sim/starter_company.zig").generateInto(&gs, "Alpha");
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try store.db.exec(sql);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    loaded.deinit();
}

test "an integer column out of its field's range rejects the load as corrupt" {
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE person SET fatigue = 100000"));
}

test "a negative id rejects the load as corrupt" {
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE unit SET force = -5"));
}

test "a child row whose parent is missing rejects the load as corrupt" {
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE person_skill SET person_id = 99999"));
}

test "an unknown enum value rejects the load as corrupt" {
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE commander SET origin = 'XX'"));
}

test "a stored key that names nothing in the catalogues rejects the load as corrupt" {
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE hq SET planet = '{c}nowhere'"));
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE unit SET chassis_key = 'NOPE-1'"));
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE unit_slot SET part_key = 'nope' WHERE ord = 0"));
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE stock SET key = '{g}x' WHERE ord = 0"));
}

test "a battle report's display copies must be markup-safe to load" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 8101 });
    defer gs.deinit();
    try foughtCampaignForTest(&gs, 1);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try store.db.exec("UPDATE battle_report SET scenario = '{c}ambush'");
    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
}

test "confirmed battle orders survive a save" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 8301 });
    defer gs.deinit();
    const f = try contract_events.damagedCompanyForTest(&gs, 0);
    f.c.next_battle_day = gs.clock.day_index + 2;
    f.c.orders_day = f.c.next_battle_day;
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    try std.testing.expectEqual(f.c.orders_day, loaded.contracts.getPtr(f.c.id).?.orders_day);
}

test "a malformed RNG stream row rejects the load as corrupt" {
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE rng_stream SET state = x'00' WHERE stream = 'battle'"));
}

test "an RNG row naming no known stream rejects the load as corrupt" {
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE rng_stream SET stream = 'weather' WHERE stream = 'travel'"));
}

test "a malformed legacy RNG blob rejects the load as corrupt" {
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("DELETE FROM rng_stream; INSERT INTO rng VALUES (1, x'00')"));
}

/// Draw from every stream so none sits at its starting state.
fn stirRng(gs: *GameState) void {
    for (std.enums.values(rng_mod.Stream), 0..) |stream, i| {
        for (0..i + 3) |_| _ = gs.rng.roll2d6(stream);
    }
}

test "every RNG stream and the seed survive a save and load" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 6006 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    stirRng(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    try std.testing.expectEqual(gs.rng.seed, loaded.rng.seed);
    for (std.enums.values(rng_mod.Stream)) |stream| {
        try std.testing.expectEqual(gs.rng.encode(stream), loaded.rng.encode(stream));
    }
}

test "a stream the save lacks starts fresh from the seed, and the others keep their state" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 6007 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    stirRng(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    // A stream added to the game after this campaign was saved has no row.
    try store.db.exec("DELETE FROM rng_stream WHERE stream = 'travel'");
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    var fresh = rng_mod.Rng.init(gs.rng.seed);
    for (std.enums.values(rng_mod.Stream)) |stream| {
        const want = if (stream == .travel) fresh.encode(stream) else gs.rng.encode(stream);
        try std.testing.expectEqual(want, loaded.rng.encode(stream));
    }
}

test "a save from before per-stream rows loads every stream from its legacy blob" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 6008 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    stirRng(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    // Rewrite the save the way schema v31 held it: one blob, no seed.
    try store.db.exec("DELETE FROM rng_stream; DELETE FROM meta WHERE key = 'rng_seed'");
    var blob: [legacy_rng_order.len * @sizeOf(std.Random.DefaultPrng)]u8 = undefined;
    for (legacy_rng_order, 0..) |stream, i| {
        @memcpy(blob[i * @sizeOf(std.Random.DefaultPrng) ..][0..@sizeOf(std.Random.DefaultPrng)], std.mem.asBytes(&gs.rng.prngs[@intFromEnum(stream)]));
    }
    const ins = try store.db.prepare("INSERT INTO rng VALUES (?1, ?2)");
    defer ins.finalize();
    try ins.bind(1, gs.campaign_id);
    try ins.bindBlob(2, &blob);
    try ins.run();
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    for (std.enums.values(rng_mod.Stream)) |stream| {
        try std.testing.expectEqual(gs.rng.encode(stream), loaded.rng.encode(stream));
    }
    try std.testing.expectEqual(std.hash.Wyhash.hash(0, &blob), loaded.rng.seed);
}

/// A campaign that has fought `fights` engagements, every battle decision
/// answered with its default and every report read.
fn foughtCampaignForTest(gs: *GameState, fights: u32) !void {
    _ = try gs.createCommander("T", .LC, .line_officer);
    const co = try @import("../sim/starter_company.zig").generateInto(gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "PER",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000 },
        .status = .active,
        .assigned_company = co,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    for (@import("../domain/part.zig").munition_keys) |key| try gs.addStock(.{ .company = co }, key, 40);
    for (0..fights) |_| {
        try @import("../sim/battle.zig").resolveEngagement(gs, c);
        while (gs.event_queue.blocking()) |ev| try contract_events.resolveChoice(gs, ev.id, ev.default_choice);
        while (gs.battle_reports.unread()) |r| _ = gs.battle_reports.markRead(r.id);
    }
}

test "battle report IDs stay unique after a save and load" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3003 });
    defer gs.deinit();
    try foughtCampaignForTest(&gs, 3);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    try std.testing.expectEqual(gs.next_battle_id, loaded.next_battle_id);
    const fresh = loaded.nextBattleId();
    for (loaded.battle_reports.kept.items) |r| try std.testing.expect(r.id != fresh);
}

test "a save without the battle counter resumes numbering past every battle it references" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3004 });
    defer gs.deinit();
    try foughtCampaignForTest(&gs, 3);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    // Saves before the counter was stored carry no `next_battle_id` row.
    try store.db.exec("DELETE FROM meta WHERE key = 'next_battle_id'");
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    var max: u32 = 0;
    for (loaded.battle_reports.kept.items) |r| max = @max(max, @intFromEnum(r.id));
    for (loaded.held_hulls.items) |h| max = @max(max, @intFromEnum(h.battle));
    for (loaded.event_queue.pending.items) |ev| max = @max(max, @intFromEnum(ev.battle));
    try std.testing.expect(max > 0);
    try std.testing.expect(loaded.next_battle_id > max);
}

test "a battle decision round-trips answerable, and still holds the turn" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12006 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    const co = try @import("../sim/starter_company.zig").generateInto(&gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "PER",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000 },
        .status = .active,
        .assigned_company = co,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    try @import("../sim/contract_events.zig").queuePress(&gs, c);
    try std.testing.expect(gs.event_queue.blocking() != null);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    // The store rebuilds an event's options from its kind. Without an
    // `entryForKind` entry the decision comes back optionless — answered
    // by nobody, holding nothing, and silently gone.
    const ev = loaded.event_queue.blocking() orelse return error.DecisionLostOnLoad;
    try std.testing.expectEqual(@import("../sim/events.zig").EventKind.press_or_consolidate, ev.kind);
    try std.testing.expectEqual(@as(usize, 2), ev.options.len);
    try std.testing.expectEqual(gs.event_queue.blocking().?.id, ev.id);
    try std.testing.expectEqual(@as(usize, 1), ev.default_choice);
    try std.testing.expect(ev.holdsTurn());
}

test "a field repair decision comes back from a save with its three orders" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12069 });
    defer gs.deinit();
    const f = try contract_events.damagedCompanyForTest(&gs, 2);
    try contract_events.queueFieldRepair(&gs, f.c, .none);
    try std.testing.expect(gs.event_queue.blocking() != null);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    const ev = loaded.event_queue.blocking() orelse return error.DecisionLostOnLoad;
    try std.testing.expectEqual(@import("../sim/events.zig").EventKind.field_repair, ev.kind);
    try std.testing.expectEqual(@as(usize, 3), ev.options.len);
    try std.testing.expect(ev.holdsTurn());
    // The damage is state, not part of the event: the reloaded plan matches.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const maintenance = @import("../sim/maintenance.zig");
    const before = try maintenance.planFor(&gs, arena.allocator(), f.c.assigned_company, .worst_first);
    const after = try maintenance.planFor(&loaded, arena.allocator(), f.c.assigned_company, .worst_first);
    try std.testing.expectEqual(before.hulls.len, after.hulls.len);
    for (before.hulls, after.hulls) |x, y| try std.testing.expectEqual(x.armor_after, y.armor_after);
}

test "a recovery decision remembers its battle, and a held hull its lance" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12066 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    const co = try @import("../sim/starter_company.zig").generateInto(&gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .planetary_assault,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000 },
        .status = .active,
        .assigned_company = co,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    const taken = blk: {
        var it = gs.units.iterator();
        while (it.next()) |e| if (e.value_ptr.kind == .mek and e.value_ptr.force != .none) break :blk e.value_ptr.id;
        unreachable;
    };
    const lance = gs.unit(taken).?.force;
    try gs.holdUnit(taken, "DC", @enumFromInt(4));
    try @import("../sim/contract_events.zig").queueRecoveryPush(&gs, c, @enumFromInt(4));

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    const ev = loaded.event_queue.blocking() orelse return error.DecisionLostOnLoad;
    try std.testing.expectEqual(@import("../sim/events.zig").EventKind.recovery_push, ev.kind);
    // The two pointers this decision needs to do anything at all.
    try std.testing.expectEqual(@as(types.BattleId, @enumFromInt(4)), ev.battle);
    try std.testing.expectEqual(lance, loaded.heldHull(taken).?.from_force);
    // And a hull won back after a reload still goes home to that lance.
    try std.testing.expect(try loaded.releaseHull(taken));
    try std.testing.expectEqual(lance, loaded.unit(taken).?.force);
}

test "the wrecks on offer survive a save — the same battlefield after a reload" {
    const battle = @import("../sim/battle.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12060 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    const co = try @import("../sim/starter_company.zig").generateInto(&gs, "Alpha");
    // A report with a haul still to be divided, built by hand so the test
    // does not depend on a campaign happening to throw one up.
    const candidates = [_]after_action_mod.SalvageCandidate{
        .{ .key = "DRG-1N", .name = "Dragon", .bv = 1_144, .armor_pct = 30, .quality = .c, .damaged_slots = 1, .destroyed_slots = 2, .missing_components = 1 },
        .{ .key = "LCT-1V", .name = "Locust", .bv = 432, .armor_pct = 24, .quality = .d, .damaged_slots = 1, .destroyed_slots = 1, .missing_components = 1 },
        .{ .key = "STG-3R", .name = "Stinger", .bv = 192, .armor_pct = 18, .quality = .c, .damaged_slots = 1, .destroyed_slots = 1, .missing_components = 1 },
    };
    try gs.battle_reports.record(gs.allocator(), .{
        .id = gs.nextBattleId(),
        .day = 12,
        .contract = @enumFromInt(1),
        .company = co,
        .kind = "recon_raid",
        .enemy_key = "DC",
        .scenario = "breakthrough",
        .terrain = "badlands",
        .weather = "clear skies",
        .outcome = .victory,
        .held_field = true,
        .acknowledged = true,
        .salvage = .{ .claimed_bv = 1_500, .candidates = &candidates, .unclaimed_bv = 1_500 },
    });
    const battle_id = gs.battle_reports.kept.items[0].id;

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    const r = loaded.battle_reports.find(battle_id) orelse return error.ReportLostOnLoad;
    try std.testing.expectEqual(@as(i64, 1_500), r.salvage.unclaimed_bv);
    try std.testing.expectEqual(candidates.len, r.salvage.candidates.len);
    for (candidates, r.salvage.candidates) |saved, got| {
        try std.testing.expectEqualStrings(saved.key, got.key);
        try std.testing.expectEqualStrings(saved.name, got.name);
        try std.testing.expectEqual(saved.bv, got.bv);
        try std.testing.expectEqual(saved.armor_pct, got.armor_pct);
        try std.testing.expectEqual(saved.quality, got.quality);
        try std.testing.expectEqual(saved.destroyed_slots, got.destroyed_slots);
        try std.testing.expectEqual(saved.missing_components, got.missing_components);
    }
    // And the plan the reloaded record offers is the plan the original
    // offered — the whole reason the rolls are kept rather than re-rolled.
    const before = battle.salvagePlan(&candidates, 1_500, .heaviest);
    const after = battle.salvagePlan(r.salvage.candidates, 1_500, .heaviest);
    try std.testing.expectEqual(before.hulls, after.hulls);
    try std.testing.expectEqualStrings("Dragon", r.salvage.candidates[after.take[0]].name);
}

/// A played year for the golden master: a commander, the starter company,
/// every contract offer taken as the last one ends, every decision answered
/// with its default and every after-action read.
fn playedYearForTest(gs: *GameState) !void {
    const commands = @import("../sim/commands.zig");
    const checklist = @import("../sim/checklist.zig");
    _ = try commands.execute(gs, .{ .create_commander = .{ .name = "Kalmar", .origin = .LC, .profession = .line_officer } });
    const co = (try commands.execute(gs, .{ .new_company = "Alpha" })).created_force;
    var day: u32 = 0;
    while (day < 365) {
        while (checklist.turnHold(gs)) |h| switch (h) {
            .unread_after_action => _ = try commands.execute(gs, .{ .read_report = gs.battle_reports.unread().?.id }),
            .battle_decision => {
                const ev = gs.event_queue.blocking().?;
                _ = try commands.execute(gs, .{ .resolve_decision = .{ .event = ev.id, .choice = ev.default_choice } });
            },
        };
        if (!gs.isCompanyDeployed(co) and gs.contract_offers.items.len > 0) {
            _ = commands.execute(gs, .{ .accept_contract = .{ .offer_index = 0, .company = co } }) catch {};
        }
        const r = try commands.execute(gs, .{ .advance_days = 7 });
        if (r.days_advanced == 0) return error.TestUnexpectedResult;
        day += @intCast(r.days_advanced);
    }
}

test "golden master: a played year hashes to its pinned value, and a save of it plays on identically" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 20_260_924 });
    defer gs.deinit();
    try playedYearForTest(&gs);
    try std.testing.expect(gs.battle_reports.kept.items.len > 0); // the year saw fighting
    // Any change to a simulated or saved result moves this; re-pin it only
    // when the change is meant.
    try std.testing.expectEqual(@as(u64, 12374000996448995992), gs.hash());

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", gs.firstHashDifference(&loaded, &buf) orelse "");
    const commands = @import("../sim/commands.zig");
    for ([_]*GameState{ &gs, &loaded }) |g| _ = try commands.execute(g, .{ .advance_days = 60 });
    try std.testing.expectEqualStrings("", gs.firstHashDifference(&loaded, &buf) orelse "");
}

test "the table registry matches the tables the executable schema creates" {
    // Campaign clear, delete and overwrite walk `tables`: a table the DDL
    // creates but the registry misses would keep a deleted campaign's rows.
    const store_wide = [_][]const u8{ "campaign", "player", "setting" };
    var created: std.ArrayListUnmanaged([]const u8) = .empty;
    defer created.deinit(std.testing.allocator);
    var rest: []const u8 = ddl;
    const marker = "CREATE TABLE IF NOT EXISTS ";
    while (std.mem.indexOf(u8, rest, marker)) |i| {
        rest = rest[i + marker.len ..];
        const end = std.mem.indexOfAny(u8, rest, " (") orelse rest.len;
        const name = rest[0..end];
        const shared = for (store_wide) |w| {
            if (std.mem.eql(u8, w, name)) break true;
        } else false;
        if (!shared) try created.append(std.testing.allocator, name);
    }
    try std.testing.expectEqual(tables.len, created.items.len);
    for (tables, 0..) |t, i| {
        for (tables[i + 1 ..]) |u| try std.testing.expect(!std.mem.eql(u8, t, u));
        const in_ddl = for (created.items) |c| {
            if (std.mem.eql(u8, c, t)) break true;
        } else false;
        if (!in_ddl) std.debug.print("registry table {s} is not in the DDL\n", .{t});
        try std.testing.expect(in_ddl);
    }
}
