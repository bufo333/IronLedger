//! The save store (Stage 11): one SQLite file holds many campaigns. Every
//! table carries a campaign id; `campaign` is the registry. Saving rewrites
//! a campaign's rows inside one transaction; loading rebuilds a GameState
//! from them; deleting a campaign removes it and starts nothing else.
//!
//! The sim core never touches SQL — this module maps GameState ↔ rows.
//! docs/schema.sql remains the design document; this DDL is the executable
//! truth and stays close to it.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const types = @import("../domain/types.zig");
const state_mod = @import("../sim/state.zig");
const GameState = state_mod.GameState;
const person_mod = @import("../domain/person.zig");
const unit_mod = @import("../domain/unit.zig");
const force_mod = @import("../domain/force.zig");
const hq_mod = @import("../domain/hq.zig");
const contract_mod = @import("../domain/contract.zig");
const commander_mod = @import("../domain/commander.zig");
const finance_mod = @import("../econ/finance.zig");
const market_mod = @import("../econ/market.zig");
const events_mod = @import("../sim/events.zig");
const contract_events = @import("../sim/contract_events.zig");
const network = @import("../sim/network.zig");
const clock_mod = @import("../sim/clock.zig");

pub const schema_version = 4;

const ddl =
    \\CREATE TABLE IF NOT EXISTS player (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, created_seq INTEGER NOT NULL);
    \\CREATE TABLE IF NOT EXISTS setting (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
    \\CREATE TABLE IF NOT EXISTS campaign (id INTEGER PRIMARY KEY, name TEXT NOT NULL, commander TEXT, day INTEGER NOT NULL, date TEXT NOT NULL, schema_version INTEGER NOT NULL, save_seq INTEGER NOT NULL, player_id INTEGER NOT NULL DEFAULT 0);
    \\CREATE TABLE IF NOT EXISTS meta (cid INTEGER NOT NULL, key TEXT NOT NULL, value INTEGER NOT NULL, PRIMARY KEY (cid, key));
    \\CREATE TABLE IF NOT EXISTS meta_text (cid INTEGER NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (cid, key));
    \\CREATE TABLE IF NOT EXISTS rng (cid INTEGER PRIMARY KEY, state BLOB NOT NULL);
    \\CREATE TABLE IF NOT EXISTS commander (cid INTEGER PRIMARY KEY, name TEXT NOT NULL, origin TEXT NOT NULL, profession TEXT NOT NULL);
    \\CREATE TABLE IF NOT EXISTS person (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, first TEXT, last TEXT, callsign TEXT, role TEXT, xp INTEGER, status TEXT, fatigue INTEGER, morale INTEGER, recruited_day INTEGER, salary_override INTEGER, assigned_force INTEGER, posted_hq INTEGER, weekly_hours INTEGER, medbay_priority INTEGER, leave_until INTEGER, wound_heal_day INTEGER, training_skill TEXT, training_done INTEGER, admitted INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (cid, id));
    \\CREATE TABLE IF NOT EXISTS person_skill (cid INTEGER NOT NULL, person_id INTEGER NOT NULL, skill TEXT NOT NULL, level INTEGER NOT NULL);
    \\CREATE TABLE IF NOT EXISTS unit (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, chassis_key TEXT, name TEXT, kind TEXT, force INTEGER, pilot INTEGER, tech INTEGER, armor_pct INTEGER, quality TEXT, status TEXT, last_maint INTEGER, acquired_day INTEGER, price INTEGER, reactivation_done INTEGER, PRIMARY KEY (cid, id));
    \\CREATE TABLE IF NOT EXISTS unit_slot (cid INTEGER NOT NULL, unit_id INTEGER NOT NULL, ord INTEGER NOT NULL, slot_key TEXT, part_key TEXT, class TEXT, condition TEXT);
    \\CREATE TABLE IF NOT EXISTS force (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, parent INTEGER, name TEXT, emblem BLOB, local_funds INTEGER, echelon TEXT, commander INTEGER, supplying_hq INTEGER, role TEXT, support_kind TEXT, last_rotation INTEGER, contracts_since_rotation INTEGER, location_planet TEXT, return_eta INTEGER, shortage_days INTEGER, PRIMARY KEY (cid, id));
    \\CREATE TABLE IF NOT EXISTS force_unit (cid INTEGER NOT NULL, force_id INTEGER NOT NULL, ord INTEGER NOT NULL, unit_id INTEGER NOT NULL);
    \\CREATE TABLE IF NOT EXISTS force_child (cid INTEGER NOT NULL, force_id INTEGER NOT NULL, ord INTEGER NOT NULL, child_id INTEGER NOT NULL);
    \\CREATE TABLE IF NOT EXISTS stock (cid INTEGER NOT NULL, owner_kind TEXT NOT NULL, owner_id INTEGER NOT NULL, ord INTEGER NOT NULL, key TEXT NOT NULL, qty INTEGER NOT NULL);
    \\CREATE TABLE IF NOT EXISTS hq (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, name TEXT, tier TEXT, planet TEXT, staff_assigned INTEGER, upkeep INTEGER, funds INTEGER, PRIMARY KEY (cid, id));
    \\CREATE TABLE IF NOT EXISTS hq_facility (cid INTEGER NOT NULL, hq_id INTEGER NOT NULL, ord INTEGER NOT NULL, kind TEXT, level INTEGER);
    \\CREATE TABLE IF NOT EXISTS hq_project (cid INTEGER NOT NULL, hq_id INTEGER NOT NULL, ord INTEGER NOT NULL, kind TEXT, facility TEXT, target_level INTEGER, started INTEGER, paperwork_done INTEGER, construction_done INTEGER, cost INTEGER);
    \\CREATE TABLE IF NOT EXISTS contract (cid INTEGER NOT NULL, is_offer INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER, kind TEXT, employer TEXT, enemy TEXT, planet TEXT, status TEXT, company INTEGER, start_day INTEGER, score INTEGER, dist_ly INTEGER, beachhead INTEGER, transit_days INTEGER, arrive_day INTEGER, end_day INTEGER, monthly_net INTEGER, next_battle INTEGER, battles INTEGER, casualties INTEGER, objective TEXT, committed_bv INTEGER, pool INTEGER, pool_remaining INTEGER, vp INTEGER, ineffective_since INTEGER, breach_day INTEGER, length_months INTEGER, base_pay INTEGER, advance_pct INTEGER, signing_bonus INTEGER, transport_pct INTEGER, overhead_pct INTEGER, battle_loss_pct INTEGER, salvage_pct INTEGER, salvage_exchange INTEGER, command_rights TEXT);
    \\CREATE TABLE IF NOT EXISTS txn (cid INTEGER NOT NULL, ord INTEGER NOT NULL, day INTEGER, amount INTEGER, category TEXT, company INTEGER, hq INTEGER, contract INTEGER, note TEXT);
    \\CREATE TABLE IF NOT EXISTS loan (cid INTEGER NOT NULL, ord INTEGER NOT NULL, principal INTEGER, balance INTEGER, rate_bp INTEGER, term INTEGER, next_pay INTEGER, payment INTEGER);
    \\CREATE TABLE IF NOT EXISTS courier (cid INTEGER NOT NULL, ord INTEGER NOT NULL, to_kind TEXT, to_id INTEGER, amount INTEGER, sent INTEGER, eta INTEGER);
    \\CREATE TABLE IF NOT EXISTS policy (cid INTEGER NOT NULL, ord INTEGER NOT NULL, entity_kind TEXT, entity_id INTEGER, floor INTEGER, cap INTEGER, sent INTEGER NOT NULL DEFAULT 0);
    \\CREATE TABLE IF NOT EXISTS supply_policy (cid INTEGER NOT NULL, ord INTEGER NOT NULL, company INTEGER, min_days INTEGER, tons INTEGER);
    \\CREATE TABLE IF NOT EXISTS bay_job (cid INTEGER NOT NULL, ord INTEGER NOT NULL, hq INTEGER, kind TEXT, unit INTEGER, item_key TEXT, duration INTEGER, queued INTEGER, started INTEGER, done INTEGER, cost INTEGER);
    \\CREATE TABLE IF NOT EXISTS candidate (cid INTEGER NOT NULL, ord INTEGER NOT NULL, hq INTEGER, first TEXT, last TEXT, callsign TEXT, role TEXT, experience TEXT, primary_skill INTEGER, secondary_skill INTEGER, bonus INTEGER, listed INTEGER, expires INTEGER);
    \\CREATE TABLE IF NOT EXISTS hq_link (cid INTEGER NOT NULL, ord INTEGER NOT NULL, a INTEGER, b INTEGER, level INTEGER, tons INTEGER, established INTEGER);
    \\CREATE TABLE IF NOT EXISTS unit_transfer (cid INTEGER NOT NULL, ord INTEGER NOT NULL, unit INTEGER, to_company INTEGER, eta INTEGER);
    \\CREATE TABLE IF NOT EXISTS faction_cooling (cid INTEGER NOT NULL, ord INTEGER NOT NULL, faction TEXT, until_day INTEGER);
    \\CREATE TABLE IF NOT EXISTS listing (cid INTEGER NOT NULL, ord INTEGER NOT NULL, kind TEXT, item_key TEXT, rarity TEXT, price INTEGER, qty INTEGER, staple INTEGER, listed INTEGER, expires INTEGER, hq INTEGER, c_armor INTEGER, c_quality TEXT, c_damaged INTEGER, c_destroyed INTEGER, c_missing INTEGER);
    \\CREATE TABLE IF NOT EXISTS part_order (cid INTEGER NOT NULL, ord INTEGER NOT NULL, part_key TEXT, qty INTEGER, dest_kind TEXT, dest_id INTEGER, ordered INTEGER, eta INTEGER, cost INTEGER, status TEXT);
    \\CREATE TABLE IF NOT EXISTS event_log (cid INTEGER NOT NULL, ord INTEGER NOT NULL, day INTEGER, category TEXT, company INTEGER, hq INTEGER, contract INTEGER, text TEXT);
    \\CREATE TABLE IF NOT EXISTS pending_event (cid INTEGER NOT NULL, ord INTEGER NOT NULL, kind TEXT, day INTEGER, contract INTEGER, company INTEGER, default_choice INTEGER, deadline INTEGER, chosen INTEGER);
    \\CREATE TABLE IF NOT EXISTS refit_plan (cid INTEGER NOT NULL, ord INTEGER NOT NULL, unit INTEGER, committed INTEGER);
    \\CREATE TABLE IF NOT EXISTS refit_op (cid INTEGER NOT NULL, plan_ord INTEGER NOT NULL, ord INTEGER NOT NULL, kind TEXT, slot_key TEXT, location TEXT, part_key TEXT);
;

const tables = [_][]const u8{
    "meta",       "meta_text",   "rng",          "commander",       "person",       "person_skill",
    "unit",       "unit_slot",   "force",        "force_unit",      "force_child",  "stock",
    "hq",         "hq_facility", "hq_project",   "contract",        "txn",          "loan",
    "courier",    "policy",      "bay_job",      "candidate",       "hq_link",      "unit_transfer",
    "supply_policy",
    "faction_cooling", "listing", "part_order",  "event_log",       "pending_event", "refit_plan",
    "refit_op",
};

pub const Store = struct {
    db: sqlite.Db,
    /// The player new campaigns are filed under (Stage 12 lobby); 0 = none.
    player_id: i64 = 0,

    pub fn open(path: [*:0]const u8) !Store {
        const db = try sqlite.Db.open(path);
        try db.exec(ddl);
        // Schema v1 → v2: campaigns gained an owning player.
        if (!try hasColumn(db, "campaign", "player_id")) {
            try db.exec("ALTER TABLE campaign ADD COLUMN player_id INTEGER NOT NULL DEFAULT 0");
        }
        // Schema v3 → v4: policies track what they sent this month.
        if (!try hasColumn(db, "policy", "sent")) {
            try db.exec("ALTER TABLE policy ADD COLUMN sent INTEGER NOT NULL DEFAULT 0");
        }
        // Schema v2 → v3: medbay admission is the player's call.
        if (!try hasColumn(db, "person", "admitted")) {
            try db.exec("ALTER TABLE person ADD COLUMN admitted INTEGER NOT NULL DEFAULT 0");
        }
        return .{ .db = db };
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
        name: []const u8,
        commander: []const u8,
        day: i64,
        date: []const u8,
        /// Monotonic save counter across the store (the sim core keeps no
        /// wall clock); higher = saved more recently.
        save_seq: i64,
        player_id: i64 = 0,
    };

    pub const PlayerInfo = struct {
        id: i64,
        name: []const u8,
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
                .name = try st.text(1, alloc),
                .commander = try st.text(2, alloc),
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
            try out.append(alloc, .{ .id = st.int(0), .name = try st.text(1, alloc), .campaigns = st.int(2) });
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

    /// Save the campaign; a first save registers it (gs.campaign_id set).
    pub fn save(self: Store, gs: *GameState) !void {
        try self.db.exec("BEGIN");
        errdefer self.db.exec("ROLLBACK") catch {};

        var date_buf: [16]u8 = undefined;
        const d = gs.clock.date;
        const date = try std.fmt.bufPrint(&date_buf, "{d}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day });
        const cmdr_name: []const u8 = if (gs.commander) |c| c.name else "";

        if (gs.campaign_id == 0) {
            const ins = try self.db.prepare("INSERT INTO campaign (name, commander, day, date, schema_version, save_seq, player_id) VALUES (?1, ?2, ?3, ?4, ?5, (SELECT COALESCE(MAX(save_seq), 0) + 1 FROM campaign), ?6)");
            defer ins.finalize();
            try ins.bindAll(.{ gs.outfit_name, cmdr_name, @as(i64, gs.clock.day_index), date, @as(i64, schema_version), self.player_id });
            try ins.run();
            const q = try self.db.prepare("SELECT last_insert_rowid()");
            defer q.finalize();
            _ = try q.next();
            gs.campaign_id = q.int(0);
        } else {
            const up = try self.db.prepare("UPDATE campaign SET name = ?1, commander = ?2, day = ?3, date = ?4, schema_version = ?5, save_seq = (SELECT COALESCE(MAX(save_seq), 0) + 1 FROM campaign) WHERE id = ?6");
            defer up.finalize();
            try up.bindAll(.{ gs.outfit_name, cmdr_name, @as(i64, gs.clock.day_index), date, @as(i64, schema_version), gs.campaign_id });
            try up.run();
        }
        const cid = gs.campaign_id;
        try self.clearRows(cid);

        // Scalars.
        {
            const st = try self.db.prepare("INSERT INTO meta VALUES (?1, ?2, ?3)");
            defer st.finalize();
            const ints = [_]struct { []const u8, i64 }{
                .{ "day_index", gs.clock.day_index },      .{ "year", gs.clock.date.year },
                .{ "month", gs.clock.date.month },         .{ "day", gs.clock.date.day },
                .{ "funds", gs.funds },                    .{ "reputation", gs.reputation },
                .{ "bankrupt", @as(i64, @intFromBool(gs.bankrupt)) },
                .{ "next_person_id", gs.next_person_id },  .{ "next_unit_id", gs.next_unit_id },
                .{ "next_force_id", gs.next_force_id },    .{ "next_hq_id", gs.next_hq_id },
                .{ "next_contract_id", gs.next_contract_id },
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
        {
            const st = try self.db.prepare("INSERT INTO rng VALUES (?1, ?2)");
            defer st.finalize();
            try st.bind(1, cid);
            try st.bindBlob(2, std.mem.asBytes(&gs.rng.prngs));
            try st.run();
        }
        if (gs.commander) |c| {
            const st = try self.db.prepare("INSERT INTO commander VALUES (?1, ?2, ?3, ?4)");
            defer st.finalize();
            try st.bindAll(.{ cid, c.name, c.origin, c.profession });
            try st.run();
        }

        // People.
        {
            const st = try self.db.prepare("INSERT INTO person VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22)");
            defer st.finalize();
            const sk = try self.db.prepare("INSERT INTO person_skill VALUES (?1, ?2, ?3, ?4)");
            defer sk.finalize();
            var it = gs.people.iterator();
            var ord: i64 = 0;
            while (it.next()) |entry| : (ord += 1) {
                const p = entry.value_ptr;
                try st.bindAll(.{
                    cid,                            ord,                            @intFromEnum(p.id),
                    p.first_name,                   p.last_name,                    p.callsign,
                    p.role,                         @as(i64, p.xp),                 p.status,
                    @as(i64, p.fatigue),            @as(i64, p.morale),             @as(i64, p.recruited_day),
                    p.salary_override,              @intFromEnum(p.assigned_force), @intFromEnum(p.posted_hq),
                    @as(i64, p.weekly_hours),       @as(i64, p.medbay_priority),    p.leave_until_day,
                    p.wound_heal_day,               if (p.training) |t| @as(?[]const u8, @tagName(t.skill)) else null,
                    if (p.training) |t| @as(?u32, t.done_day) else null,
                    @as(i64, @intFromBool(p.medbay_admitted)),
                });
                try st.run();
                var skit = p.skills.iterator();
                while (skit.next()) |s| {
                    try sk.bindAll(.{ cid, @intFromEnum(p.id), s.key_ptr.*, @as(i64, s.value_ptr.*) });
                    try sk.run();
                }
            }
        }

        // Units and slots.
        {
            const st = try self.db.prepare("INSERT INTO unit VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)");
            defer st.finalize();
            const sl = try self.db.prepare("INSERT INTO unit_slot VALUES (?1,?2,?3,?4,?5,?6,?7)");
            defer sl.finalize();
            var it = gs.units.iterator();
            var ord: i64 = 0;
            while (it.next()) |entry| : (ord += 1) {
                const u = entry.value_ptr;
                try st.bindAll(.{
                    cid,                     ord,                      @intFromEnum(u.id),        u.chassis_key,
                    u.name,                  u.kind,                   @intFromEnum(u.force),     @intFromEnum(u.pilot),
                    @intFromEnum(u.tech),    @as(i64, u.armor_pct),    u.quality,                 u.status,
                    u.last_maintenance_day,  @as(i64, u.acquired_day), u.purchase_price,          u.reactivation_done_day,
                });
                try st.run();
                for (u.slots.items, 0..) |s, i| {
                    try sl.bindAll(.{ cid, @intFromEnum(u.id), @as(i64, @intCast(i)), s.slot_key, s.part_key, s.class, s.condition });
                    try sl.run();
                }
            }
        }

        // Forces, their unit and child orderings, and field stores.
        {
            const st = try self.db.prepare("INSERT INTO force VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)");
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
        try self.saveStock(cid, "outfit", 0, &gs.spare_parts);

        // HQs, facilities, projects, warehouse stock.
        {
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
        {
            const st = try self.db.prepare("INSERT INTO contract VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26,?27,?28,?29,?30,?31,?32,?33,?34,?35,?36,?37,?38)");
            defer st.finalize();
            var ord: i64 = 0;
            var it = gs.contracts.iterator();
            while (it.next()) |entry| : (ord += 1) try saveContract(st, cid, false, ord, entry.value_ptr);
            for (gs.contract_offers.items, 0..) |*o, i| try saveContract(st, cid, true, @intCast(i), o);
        }

        // Ledger and the rest of the lists.
        {
            const st = try self.db.prepare("INSERT INTO txn VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)");
            defer st.finalize();
            for (gs.ledger.transactions.items, 0..) |t, i| {
                try st.bindAll(.{ cid, @as(i64, @intCast(i)), @as(i64, t.day), t.amount, t.category, @intFromEnum(t.company), @intFromEnum(t.hq), @intFromEnum(t.contract), t.note });
                try st.run();
            }
        }
        {
            const st = try self.db.prepare("INSERT INTO loan VALUES (?1,?2,?3,?4,?5,?6,?7,?8)");
            defer st.finalize();
            for (gs.loans.items, 0..) |l, i| {
                try st.bindAll(.{ cid, @as(i64, @intCast(i)), l.principal, l.balance, l.rate_bp, @as(i64, l.term_months), @as(i64, l.next_pay_day), l.payment });
                try st.run();
            }
        }
        {
            const st = try self.db.prepare("INSERT INTO courier VALUES (?1,?2,?3,?4,?5,?6,?7)");
            defer st.finalize();
            for (gs.fund_couriers.items, 0..) |c, i| {
                const t = treasuryCols(c.to);
                try st.bindAll(.{ cid, @as(i64, @intCast(i)), t.kind, t.id, c.amount, @as(i64, c.sent_day), @as(i64, c.eta_day) });
                try st.run();
            }
        }
        {
            const st = try self.db.prepare("INSERT INTO policy VALUES (?1,?2,?3,?4,?5,?6,?7)");
            defer st.finalize();
            for (gs.policies.items, 0..) |p, i| {
                const t = treasuryCols(p.entity);
                try st.bindAll(.{ cid, @as(i64, @intCast(i)), t.kind, t.id, p.floor, p.monthly_cap, p.sent_this_month });
                try st.run();
            }
        }
        {
            const st = try self.db.prepare("INSERT INTO supply_policy VALUES (?1,?2,?3,?4,?5)");
            defer st.finalize();
            for (gs.supply_policies.items, 0..) |p, i| {
                try st.bindAll(.{ cid, @as(i64, @intCast(i)), @intFromEnum(p.company), @as(i64, p.min_days), @as(i64, p.tons) });
                try st.run();
            }
        }
        {
            const st = try self.db.prepare("INSERT INTO bay_job VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)");
            defer st.finalize();
            for (gs.bay_jobs.items, 0..) |j, i| {
                try st.bindAll(.{ cid, @as(i64, @intCast(i)), @intFromEnum(j.hq), j.kind, @intFromEnum(j.unit), j.item_key, @as(i64, j.duration_days), @as(i64, j.queued_day), j.started_day, j.done_day, j.cost });
                try st.run();
            }
        }
        {
            const st = try self.db.prepare("INSERT INTO candidate VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)");
            defer st.finalize();
            for (gs.candidates.items, 0..) |c, i| {
                try st.bindAll(.{ cid, @as(i64, @intCast(i)), @intFromEnum(c.hq), c.spec.first, c.spec.last, c.spec.callsign, c.spec.role, c.spec.experience, @as(i64, c.spec.primary_skill), @as(i64, c.spec.secondary_skill), c.asking_bonus, @as(i64, c.listed_day), @as(i64, c.expires_day) });
                try st.run();
            }
        }
        {
            const st = try self.db.prepare("INSERT INTO hq_link VALUES (?1,?2,?3,?4,?5,?6,?7)");
            defer st.finalize();
            for (gs.hq_links.items, 0..) |l, i| {
                try st.bindAll(.{ cid, @as(i64, @intCast(i)), @intFromEnum(l.a), @intFromEnum(l.b), @as(i64, l.level), @as(i64, l.tons_this_week), @as(i64, l.established_day) });
                try st.run();
            }
        }
        {
            const st = try self.db.prepare("INSERT INTO unit_transfer VALUES (?1,?2,?3,?4,?5)");
            defer st.finalize();
            for (gs.unit_transfers.items, 0..) |t, i| {
                try st.bindAll(.{ cid, @as(i64, @intCast(i)), @intFromEnum(t.unit), @intFromEnum(t.to_company), @as(i64, t.eta_day) });
                try st.run();
            }
        }
        {
            const st = try self.db.prepare("INSERT INTO faction_cooling VALUES (?1,?2,?3,?4)");
            defer st.finalize();
            for (gs.faction_cooling.items, 0..) |f, i| {
                try st.bindAll(.{ cid, @as(i64, @intCast(i)), f.faction, @as(i64, f.until_day) });
                try st.run();
            }
        }
        {
            const st = try self.db.prepare("INSERT INTO listing VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)");
            defer st.finalize();
            for (gs.market_listings.items, 0..) |l, i| {
                try st.bindAll(.{
                    cid,                     @as(i64, @intCast(i)),       l.kind,                 l.item_key,
                    l.rarity,                l.price,                     @as(i64, l.quantity),   l.staple,
                    @as(i64, l.listed_day),  @as(i64, l.expires_day),     @intFromEnum(l.hq),
                    if (l.condition) |c| @as(?i64, c.armor_pct) else null,
                    if (l.condition) |c| @as(?[]const u8, @tagName(c.quality)) else null,
                    if (l.condition) |c| @as(?i64, c.damaged_slots) else null,
                    if (l.condition) |c| @as(?i64, c.destroyed_slots) else null,
                    if (l.condition) |c| @as(?i64, c.missing_components) else null,
                });
                try st.run();
            }
        }
        {
            const st = try self.db.prepare("INSERT INTO part_order VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)");
            defer st.finalize();
            for (gs.part_orders.items, 0..) |o, i| {
                const dest_cols = siteCols(o.dest);
                try st.bindAll(.{ cid, @as(i64, @intCast(i)), o.part_key, @as(i64, o.quantity), dest_cols.kind, dest_cols.id, @as(i64, o.ordered_day), o.eta_day, o.cost, o.status });
                try st.run();
            }
        }
        {
            const st = try self.db.prepare("INSERT INTO event_log VALUES (?1,?2,?3,?4,?5,?6,?7,?8)");
            defer st.finalize();
            for (gs.event_log.items, 0..) |e, i| {
                try st.bindAll(.{ cid, @as(i64, @intCast(i)), @as(i64, e.day), e.category, @intFromEnum(e.company), @intFromEnum(e.hq), @intFromEnum(e.contract), e.text });
                try st.run();
            }
        }
        {
            const st = try self.db.prepare("INSERT INTO pending_event VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)");
            defer st.finalize();
            for (gs.event_queue.pending.items, 0..) |e, i| {
                try st.bindAll(.{ cid, @as(i64, @intCast(i)), e.kind, @as(i64, e.day), @intFromEnum(e.contract), @intFromEnum(e.company), @as(i64, @intCast(e.default_choice)), @as(i64, e.deadline_day), if (e.chosen) |c| @as(?i64, @intCast(c)) else null });
                try st.run();
            }
        }

        {
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

        try self.db.exec("COMMIT");
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
            cid,                          is_offer,                       ord,                          @intFromEnum(c.id),
            c.kind,                       c.employer_key,                 c.enemy_key,                  c.planet_key,
            c.status,                     @intFromEnum(c.assigned_company), c.start_day,               @as(i64, c.score),
            @as(i64, c.dist_ly),          c.beachhead,                    @as(i64, c.transit_days),     c.arrive_day,
            c.end_day,                    c.monthly_net,                  c.next_battle_day,            @as(i64, c.battles_fought),
            @as(i64, c.casualties),       c.objective,                    c.committed_bv,               c.enemy_pool_bv,
            c.enemy_pool_remaining,       @as(i64, c.victory_points),     c.ineffective_since,          c.breach_day,
            @as(i64, c.terms.length_months), c.terms.base_pay_month,      @as(i64, c.terms.advance_pct), c.terms.signing_bonus,
            @as(i64, c.terms.transport_pct), @as(i64, c.terms.overhead_pct), @as(i64, c.terms.battle_loss_pct), @as(i64, c.terms.salvage_pct),
            c.terms.salvage_exchange,     c.terms.command_rights,
        });
        try st.run();
    }

    // ------------------------------------------------------------------ load

    /// Rebuild a campaign from the store. `gpa` backs the new GameState.
    pub fn load(self: Store, gpa: std.mem.Allocator, cid: i64) !GameState {
        var gs = GameState.init(gpa, .{});
        errdefer gs.deinit();
        const alloc = gs.allocator();
        gs.campaign_id = cid;

        {
            const st = try self.db.prepare("SELECT key, value FROM meta WHERE cid = ?1");
            defer st.finalize();
            try st.bindAll(.{cid});
            while (try st.next()) {
                const key = try st.text(0, alloc);
                const v = st.int(1);
                if (std.mem.eql(u8, key, "day_index")) gs.clock.day_index = @intCast(v);
                if (std.mem.eql(u8, key, "year")) gs.clock.date.year = @intCast(v);
                if (std.mem.eql(u8, key, "month")) gs.clock.date.month = @intCast(v);
                if (std.mem.eql(u8, key, "day")) gs.clock.date.day = @intCast(v);
                if (std.mem.eql(u8, key, "funds")) gs.funds = v;
                if (std.mem.eql(u8, key, "reputation")) gs.reputation = @intCast(v);
                if (std.mem.eql(u8, key, "bankrupt")) gs.bankrupt = v != 0;
                if (std.mem.eql(u8, key, "next_person_id")) gs.next_person_id = @intCast(v);
                if (std.mem.eql(u8, key, "next_unit_id")) gs.next_unit_id = @intCast(v);
                if (std.mem.eql(u8, key, "next_force_id")) gs.next_force_id = @intCast(v);
                if (std.mem.eql(u8, key, "next_hq_id")) gs.next_hq_id = @intCast(v);
                if (std.mem.eql(u8, key, "next_contract_id")) gs.next_contract_id = @intCast(v);
            }
            const tx = try self.db.prepare("SELECT key, value FROM meta_text WHERE cid = ?1");
            defer tx.finalize();
            try tx.bindAll(.{cid});
            while (try tx.next()) {
                const key = try tx.text(0, alloc);
                if (std.mem.eql(u8, key, "outfit_name")) gs.outfit_name = try tx.text(1, alloc);
            }
        }
        {
            const st = try self.db.prepare("SELECT state FROM rng WHERE cid = ?1");
            defer st.finalize();
            try st.bindAll(.{cid});
            if (try st.next()) {
                const bytes = try st.blob(0, alloc);
                if (bytes.len == @sizeOf(@TypeOf(gs.rng.prngs))) @memcpy(std.mem.asBytes(&gs.rng.prngs), bytes);
            }
        }
        {
            const st = try self.db.prepare("SELECT name, origin, profession FROM commander WHERE cid = ?1");
            defer st.finalize();
            try st.bindAll(.{cid});
            if (try st.next()) {
                gs.commander = .{
                    .name = try st.text(0, alloc),
                    .origin = st.enumValue(commander_mod.Faction, 1) orelse .LC,
                    .profession = st.enumValue(commander_mod.Profession, 2) orelse .quartermaster,
                };
            }
        }

        // People.
        {
            const st = try self.db.prepare("SELECT id, first, last, callsign, role, xp, status, fatigue, morale, recruited_day, salary_override, assigned_force, posted_hq, weekly_hours, medbay_priority, leave_until, wound_heal_day, training_skill, training_done, admitted FROM person WHERE cid = ?1 ORDER BY ord");
            defer st.finalize();
            try st.bindAll(.{cid});
            while (try st.next()) {
                var p: person_mod.Person = .{
                    .id = toId(types.PersonId, st.int(0)),
                    .first_name = try st.text(1, alloc),
                    .last_name = try st.text(2, alloc),
                    .callsign = try st.optText(3, alloc),
                    .role = st.enumValue(person_mod.Role, 4) orelse .astech,
                    .xp = @intCast(st.int(5)),
                    .status = st.enumValue(person_mod.Status, 6) orelse .active,
                    .fatigue = @intCast(st.int(7)),
                    .morale = @intCast(st.int(8)),
                    .recruited_day = @intCast(st.int(9)),
                    .salary_override = st.optInt(10),
                    .assigned_force = toId(types.ForceId, st.int(11)),
                    .posted_hq = toId(types.HqId, st.int(12)),
                    .weekly_hours = @intCast(st.int(13)),
                    .medbay_priority = @intCast(st.int(14)),
                    .leave_until_day = optU32(st.optInt(15)),
                    .wound_heal_day = optU32(st.optInt(16)),
                    .medbay_admitted = st.int(19) != 0,
                };
                if (st.enumValue(types.SkillType, 17)) |skill| {
                    if (st.optInt(18)) |done| p.training = .{ .skill = skill, .done_day = @intCast(done) };
                }
                try gs.people.put(alloc, p.id, p);
            }
            const sk = try self.db.prepare("SELECT person_id, skill, level FROM person_skill WHERE cid = ?1");
            defer sk.finalize();
            try sk.bindAll(.{cid});
            while (try sk.next()) {
                const p = gs.people.getPtr(toId(types.PersonId, sk.int(0))) orelse continue;
                const skill = sk.enumValue(types.SkillType, 1) orelse continue;
                try p.skills.put(alloc, skill, @intCast(sk.int(2)));
            }
        }

        // Units.
        {
            const st = try self.db.prepare("SELECT id, chassis_key, name, kind, force, pilot, tech, armor_pct, quality, status, last_maint, acquired_day, price, reactivation_done FROM unit WHERE cid = ?1 ORDER BY ord");
            defer st.finalize();
            try st.bindAll(.{cid});
            while (try st.next()) {
                const u: unit_mod.Unit = .{
                    .id = toId(types.UnitId, st.int(0)),
                    .chassis_key = try st.text(1, alloc),
                    .name = try st.optText(2, alloc),
                    .kind = st.enumValue(unit_mod.UnitKind, 3) orelse .mek,
                    .force = toId(types.ForceId, st.int(4)),
                    .pilot = toId(types.PersonId, st.int(5)),
                    .tech = toId(types.PersonId, st.int(6)),
                    .armor_pct = @intCast(st.int(7)),
                    .quality = st.enumValue(types.Quality, 8) orelse .c,
                    .status = st.enumValue(unit_mod.UnitStatus, 9) orelse .ready,
                    .last_maintenance_day = optU32(st.optInt(10)),
                    .acquired_day = @intCast(st.int(11)),
                    .purchase_price = st.int(12),
                    .reactivation_done_day = optU32(st.optInt(13)),
                };
                try gs.units.put(alloc, u.id, u);
            }
            const sl = try self.db.prepare("SELECT unit_id, slot_key, part_key, class, condition FROM unit_slot WHERE cid = ?1 ORDER BY unit_id, ord");
            defer sl.finalize();
            try sl.bindAll(.{cid});
            while (try sl.next()) {
                const u = gs.units.getPtr(toId(types.UnitId, sl.int(0))) orelse continue;
                try u.slots.append(alloc, .{
                    .slot_key = try sl.text(1, alloc),
                    .part_key = try sl.text(2, alloc),
                    .class = sl.enumValue(unit_mod.SlotClass, 3) orelse .equipment,
                    .condition = sl.enumValue(unit_mod.PartCondition, 4) orelse .ok,
                });
            }
        }

        // Forces.
        {
            const st = try self.db.prepare("SELECT id, parent, name, emblem, local_funds, echelon, commander, supplying_hq, role, support_kind, last_rotation, contracts_since_rotation, location_planet, return_eta, shortage_days FROM force WHERE cid = ?1 ORDER BY ord");
            defer st.finalize();
            try st.bindAll(.{cid});
            while (try st.next()) {
                const f: force_mod.Force = .{
                    .id = toId(types.ForceId, st.int(0)),
                    .parent = toId(types.ForceId, st.int(1)),
                    .name = try st.text(2, alloc),
                    .emblem = if (st.isNull(3)) null else try st.blob(3, alloc),
                    .local_funds = st.int(4),
                    .echelon = st.enumValue(force_mod.Echelon, 5) orelse .company,
                    .commander = toId(types.PersonId, st.int(6)),
                    .supplying_hq = toId(types.HqId, st.int(7)),
                    .role = st.enumValue(force_mod.LanceRole, 8) orelse .unassigned,
                    .support_kind = st.enumValue(force_mod.SupportLanceKind, 9),
                    .last_rotation_day = optU32(st.optInt(10)),
                    .contracts_since_rotation = @intCast(st.int(11)),
                    .location_planet = try st.optText(12, alloc),
                    .return_eta_day = optU32(st.optInt(13)),
                    .supply_shortage_days = @intCast(st.int(14)),
                };
                try gs.forces.put(alloc, f.id, f);
            }
            const fu = try self.db.prepare("SELECT force_id, unit_id FROM force_unit WHERE cid = ?1 ORDER BY force_id, ord");
            defer fu.finalize();
            try fu.bindAll(.{cid});
            while (try fu.next()) {
                const f = gs.forces.getPtr(toId(types.ForceId, fu.int(0))) orelse continue;
                try f.units.append(alloc, toId(types.UnitId, fu.int(1)));
            }
            const fc = try self.db.prepare("SELECT force_id, child_id FROM force_child WHERE cid = ?1 ORDER BY force_id, ord");
            defer fc.finalize();
            try fc.bindAll(.{cid});
            while (try fc.next()) {
                const f = gs.forces.getPtr(toId(types.ForceId, fc.int(0))) orelse continue;
                try f.children.append(alloc, toId(types.ForceId, fc.int(1)));
            }
        }

        // HQs.
        {
            const st = try self.db.prepare("SELECT id, name, tier, planet, staff_assigned, upkeep, funds FROM hq WHERE cid = ?1 ORDER BY ord");
            defer st.finalize();
            try st.bindAll(.{cid});
            while (try st.next()) {
                const h: hq_mod.Hq = .{
                    .id = toId(types.HqId, st.int(0)),
                    .name = try st.text(1, alloc),
                    .tier = st.enumValue(hq_mod.HqTier, 2) orelse .regional,
                    .planet_key = try st.text(3, alloc),
                    .staff_assigned = @intCast(st.int(4)),
                    .monthly_upkeep = st.int(5),
                    .funds = st.int(6),
                };
                try gs.hqs.put(alloc, h.id, h);
            }
            const fa = try self.db.prepare("SELECT hq_id, kind, level FROM hq_facility WHERE cid = ?1 ORDER BY hq_id, ord");
            defer fa.finalize();
            try fa.bindAll(.{cid});
            while (try fa.next()) {
                const h = gs.hqs.getPtr(toId(types.HqId, fa.int(0))) orelse continue;
                try h.facilities.append(alloc, .{ .kind = fa.enumValue(hq_mod.FacilityKind, 1) orelse continue, .level = @intCast(fa.int(2)) });
            }
            const pr = try self.db.prepare("SELECT hq_id, kind, facility, target_level, started, paperwork_done, construction_done, cost FROM hq_project WHERE cid = ?1 ORDER BY hq_id, ord");
            defer pr.finalize();
            try pr.bindAll(.{cid});
            while (try pr.next()) {
                const h = gs.hqs.getPtr(toId(types.HqId, pr.int(0))) orelse continue;
                try h.projects.append(alloc, .{
                    .kind = pr.enumValue(hq_mod.ProjectKind, 1) orelse .facility_upgrade,
                    .facility = pr.enumValue(hq_mod.FacilityKind, 2),
                    .target_level = @intCast(pr.int(3)),
                    .started_day = @intCast(pr.int(4)),
                    .paperwork_done_day = @intCast(pr.int(5)),
                    .construction_done_day = @intCast(pr.int(6)),
                    .cost = pr.int(7),
                });
            }
        }

        // Stock at every site.
        {
            const st = try self.db.prepare("SELECT owner_kind, owner_id, key, qty FROM stock WHERE cid = ?1 ORDER BY owner_kind, owner_id, ord");
            defer st.finalize();
            try st.bindAll(.{cid});
            while (try st.next()) {
                const kind = try st.text(0, alloc);
                const site = siteFromCols(kind, st.int(1));
                try gs.addStock(site, try st.text(2, alloc), @intCast(st.int(3)));
            }
        }

        // Contracts & offers.
        {
            const st = try self.db.prepare("SELECT is_offer, id, kind, employer, enemy, planet, status, company, start_day, score, dist_ly, beachhead, transit_days, arrive_day, end_day, monthly_net, next_battle, battles, casualties, objective, committed_bv, pool, pool_remaining, vp, ineffective_since, breach_day, length_months, base_pay, advance_pct, signing_bonus, transport_pct, overhead_pct, battle_loss_pct, salvage_pct, salvage_exchange, command_rights FROM contract WHERE cid = ?1 ORDER BY is_offer, ord");
            defer st.finalize();
            try st.bindAll(.{cid});
            while (try st.next()) {
                const c: contract_mod.Contract = .{
                    .id = toId(types.ContractId, st.int(1)),
                    .kind = st.enumValue(contract_mod.ContractKind, 2) orelse .garrison_duty,
                    .employer_key = try st.text(3, alloc),
                    .enemy_key = try st.text(4, alloc),
                    .planet_key = try st.text(5, alloc),
                    .status = st.enumValue(contract_mod.ContractStatus, 6) orelse .offer,
                    .assigned_company = toId(types.ForceId, st.int(7)),
                    .start_day = optU32(st.optInt(8)),
                    .score = @intCast(st.int(9)),
                    .dist_ly = @intCast(st.int(10)),
                    .beachhead = st.int(11) != 0,
                    .transit_days = @intCast(st.int(12)),
                    .arrive_day = optU32(st.optInt(13)),
                    .end_day = optU32(st.optInt(14)),
                    .monthly_net = st.int(15),
                    .next_battle_day = optU32(st.optInt(16)),
                    .battles_fought = @intCast(st.int(17)),
                    .casualties = @intCast(st.int(18)),
                    .objective = st.enumValue(contract_mod.ObjectiveKind, 19) orelse .duration,
                    .committed_bv = st.int(20),
                    .enemy_pool_bv = st.int(21),
                    .enemy_pool_remaining = st.int(22),
                    .victory_points = @intCast(st.int(23)),
                    .ineffective_since = optU32(st.optInt(24)),
                    .breach_day = optU32(st.optInt(25)),
                    .terms = .{
                        .length_months = @intCast(st.int(26)),
                        .base_pay_month = st.int(27),
                        .advance_pct = @intCast(st.int(28)),
                        .signing_bonus = st.int(29),
                        .transport_pct = @intCast(st.int(30)),
                        .overhead_pct = @intCast(st.int(31)),
                        .battle_loss_pct = @intCast(st.int(32)),
                        .salvage_pct = @intCast(st.int(33)),
                        .salvage_exchange = st.int(34) != 0,
                        .command_rights = st.enumValue(contract_mod.CommandRights, 35) orelse .independent,
                    },
                };
                if (st.int(0) != 0) try gs.contract_offers.append(alloc, c) else try gs.contracts.put(alloc, c.id, c);
            }
        }

        // Lists.
        {
            const st = try self.db.prepare("SELECT day, amount, category, company, hq, contract, note FROM txn WHERE cid = ?1 ORDER BY ord");
            defer st.finalize();
            try st.bindAll(.{cid});
            while (try st.next()) {
                try gs.ledger.transactions.append(alloc, .{
                    .day = @intCast(st.int(0)),
                    .amount = st.int(1),
                    .category = st.enumValue(finance_mod.Category, 2) orelse .misc,
                    .company = toId(types.ForceId, st.int(3)),
                    .hq = toId(types.HqId, st.int(4)),
                    .contract = toId(types.ContractId, st.int(5)),
                    .note = try st.text(6, alloc),
                });
            }
        }
        {
            const st = try self.db.prepare("SELECT principal, balance, rate_bp, term, next_pay, payment FROM loan WHERE cid = ?1 ORDER BY ord");
            defer st.finalize();
            try st.bindAll(.{cid});
            while (try st.next()) {
                try gs.loans.append(alloc, .{ .principal = st.int(0), .balance = st.int(1), .rate_bp = st.int(2), .term_months = @intCast(st.int(3)), .next_pay_day = @intCast(st.int(4)), .payment = st.int(5) });
            }
        }
        {
            const st = try self.db.prepare("SELECT to_kind, to_id, amount, sent, eta FROM courier WHERE cid = ?1 ORDER BY ord");
            defer st.finalize();
            try st.bindAll(.{cid});
            while (try st.next()) {
                try gs.fund_couriers.append(alloc, .{ .to = treasuryFromCols(try st.text(0, alloc), st.int(1)), .amount = st.int(2), .sent_day = @intCast(st.int(3)), .eta_day = @intCast(st.int(4)) });
            }
        }
        {
            const st = try self.db.prepare("SELECT entity_kind, entity_id, floor, cap, sent FROM policy WHERE cid = ?1 ORDER BY ord");
            defer st.finalize();
            try st.bindAll(.{cid});
            while (try st.next()) {
                try gs.policies.append(alloc, .{ .entity = treasuryFromCols(try st.text(0, alloc), st.int(1)), .floor = st.int(2), .monthly_cap = st.int(3), .sent_this_month = st.int(4) });
            }
        }
        {
            const st = try self.db.prepare("SELECT company, min_days, tons FROM supply_policy WHERE cid = ?1 ORDER BY ord");
            defer st.finalize();
            try st.bindAll(.{cid});
            while (try st.next()) {
                try gs.supply_policies.append(alloc, .{ .company = toId(types.ForceId, st.int(0)), .min_days = @intCast(st.int(1)), .tons = @intCast(st.int(2)) });
            }
        }
        {
            const st = try self.db.prepare("SELECT hq, kind, unit, item_key, duration, queued, started, done, cost FROM bay_job WHERE cid = ?1 ORDER BY ord");
            defer st.finalize();
            try st.bindAll(.{cid});
            while (try st.next()) {
                try gs.bay_jobs.append(alloc, .{
                    .hq = toId(types.HqId, st.int(0)),
                    .kind = st.enumValue(state_mod.BayJobKind, 1) orelse .fabrication,
                    .unit = toId(types.UnitId, st.int(2)),
                    .item_key = try st.text(3, alloc),
                    .duration_days = @intCast(st.int(4)),
                    .queued_day = @intCast(st.int(5)),
                    .started_day = optU32(st.optInt(6)),
                    .done_day = optU32(st.optInt(7)),
                    .cost = st.int(8),
                });
            }
        }
        {
            const st = try self.db.prepare("SELECT hq, first, last, callsign, role, experience, primary_skill, secondary_skill, bonus, listed, expires FROM candidate WHERE cid = ?1 ORDER BY ord");
            defer st.finalize();
            try st.bindAll(.{cid});
            while (try st.next()) {
                try gs.candidates.append(alloc, .{
                    .hq = toId(types.HqId, st.int(0)),
                    .spec = .{
                        .first = try st.text(1, alloc),
                        .last = try st.text(2, alloc),
                        .callsign = try st.optText(3, alloc),
                        .role = st.enumValue(person_mod.Role, 4) orelse .astech,
                        .experience = st.enumValue(types.ExperienceLevel, 5) orelse .regular,
                        .primary_skill = @intCast(st.int(6)),
                        .secondary_skill = @intCast(st.int(7)),
                    },
                    .asking_bonus = st.int(8),
                    .listed_day = @intCast(st.int(9)),
                    .expires_day = @intCast(st.int(10)),
                });
            }
        }
        {
            const st = try self.db.prepare("SELECT a, b, level, tons, established FROM hq_link WHERE cid = ?1 ORDER BY ord");
            defer st.finalize();
            try st.bindAll(.{cid});
            while (try st.next()) {
                try gs.hq_links.append(alloc, .{ .a = toId(types.HqId, st.int(0)), .b = toId(types.HqId, st.int(1)), .level = @intCast(st.int(2)), .tons_this_week = @intCast(st.int(3)), .established_day = @intCast(st.int(4)) });
            }
        }
        {
            const st = try self.db.prepare("SELECT unit, to_company, eta FROM unit_transfer WHERE cid = ?1 ORDER BY ord");
            defer st.finalize();
            try st.bindAll(.{cid});
            while (try st.next()) {
                try gs.unit_transfers.append(alloc, .{ .unit = toId(types.UnitId, st.int(0)), .to_company = toId(types.ForceId, st.int(1)), .eta_day = @intCast(st.int(2)) });
            }
        }
        {
            const st = try self.db.prepare("SELECT faction, until_day FROM faction_cooling WHERE cid = ?1 ORDER BY ord");
            defer st.finalize();
            try st.bindAll(.{cid});
            while (try st.next()) {
                try gs.faction_cooling.append(alloc, .{ .faction = try st.text(0, alloc), .until_day = @intCast(st.int(1)) });
            }
        }
        {
            const st = try self.db.prepare("SELECT kind, item_key, rarity, price, qty, staple, listed, expires, hq, c_armor, c_quality, c_damaged, c_destroyed, c_missing FROM listing WHERE cid = ?1 ORDER BY ord");
            defer st.finalize();
            try st.bindAll(.{cid});
            while (try st.next()) {
                var l: market_mod.Listing = .{
                    .kind = if (std.mem.eql(u8, try st.text(0, alloc), "unit")) .unit else .part,
                    .item_key = try st.text(1, alloc),
                    .rarity = st.enumValue(types.Rarity, 2) orelse .common,
                    .price = st.int(3),
                    .quantity = @intCast(st.int(4)),
                    .staple = st.int(5) != 0,
                    .listed_day = @intCast(st.int(6)),
                    .expires_day = @intCast(st.int(7)),
                    .hq = toId(types.HqId, st.int(8)),
                };
                if (st.optInt(9)) |armor| {
                    l.condition = .{
                        .armor_pct = @intCast(armor),
                        .quality = st.enumValue(types.Quality, 10) orelse .c,
                        .damaged_slots = @intCast(st.int(11)),
                        .destroyed_slots = @intCast(st.int(12)),
                        .missing_components = @intCast(st.int(13)),
                    };
                }
                try gs.market_listings.append(alloc, l);
            }
        }
        {
            const st = try self.db.prepare("SELECT part_key, qty, dest_kind, dest_id, ordered, eta, cost, status FROM part_order WHERE cid = ?1 ORDER BY ord");
            defer st.finalize();
            try st.bindAll(.{cid});
            while (try st.next()) {
                try gs.part_orders.append(alloc, .{
                    .part_key = try st.text(0, alloc),
                    .quantity = @intCast(st.int(1)),
                    .dest = siteFromCols(try st.text(2, alloc), st.int(3)),
                    .ordered_day = @intCast(st.int(4)),
                    .eta_day = optU32(st.optInt(5)),
                    .cost = st.int(6),
                    .status = st.enumValue(@import("../domain/part.zig").OrderStatus, 7) orelse .delivered,
                });
            }
        }
        {
            const st = try self.db.prepare("SELECT day, category, company, hq, contract, text FROM event_log WHERE cid = ?1 ORDER BY ord");
            defer st.finalize();
            try st.bindAll(.{cid});
            while (try st.next()) {
                try gs.event_log.append(alloc, .{
                    .day = @intCast(st.int(0)),
                    .category = st.enumValue(state_mod.LogCategory, 1) orelse .misc,
                    .company = toId(types.ForceId, st.int(2)),
                    .hq = toId(types.HqId, st.int(3)),
                    .contract = toId(types.ContractId, st.int(4)),
                    .text = try st.text(5, alloc),
                });
            }
        }
        {
            const st = try self.db.prepare("SELECT kind, day, contract, company, default_choice, deadline, chosen FROM pending_event WHERE cid = ?1 ORDER BY ord");
            defer st.finalize();
            try st.bindAll(.{cid});
            while (try st.next()) {
                const kind = st.enumValue(events_mod.EventKind, 0) orelse continue;
                const entry = contract_events.entryForKind(kind) orelse continue;
                try gs.event_queue.pending.append(alloc, .{
                    .day = @intCast(st.int(1)),
                    .kind = kind,
                    .contract = toId(types.ContractId, st.int(2)),
                    .company = toId(types.ForceId, st.int(3)),
                    .options = entry.options,
                    .default_choice = @intCast(st.int(4)),
                    .deadline_day = @intCast(st.int(5)),
                    .chosen = if (st.optInt(6)) |c| @as(?usize, @intCast(c)) else null,
                });
            }
        }

        {
            const pl = try self.db.prepare("SELECT ord, unit, committed FROM refit_plan WHERE cid = ?1 ORDER BY ord");
            defer pl.finalize();
            try pl.bindAll(.{cid});
            while (try pl.next()) {
                try gs.refit_plans.append(alloc, .{ .unit = toId(types.UnitId, pl.int(1)), .committed = pl.int(2) != 0 });
            }
            const op = try self.db.prepare("SELECT plan_ord, kind, slot_key, location, part_key FROM refit_op WHERE cid = ?1 ORDER BY plan_ord, ord");
            defer op.finalize();
            try op.bindAll(.{cid});
            while (try op.next()) {
                const idx: usize = @intCast(op.int(0));
                if (idx >= gs.refit_plans.items.len) continue;
                const kind = try op.text(1, alloc);
                if (std.mem.eql(u8, kind, "remove")) {
                    try gs.refit_plans.items[idx].ops.append(alloc, .{ .remove = try op.text(2, alloc) });
                } else {
                    try gs.refit_plans.items[idx].ops.append(alloc, .{ .install = .{
                        .location = op.enumValue(@import("../domain/meklab.zig").Location, 3) orelse .ct,
                        .part_key = try op.text(4, alloc),
                    } });
                }
            }
        }

        gs.refreshHqStaffing();
        return gs;
    }
};

fn toId(comptime T: type, v: i64) T {
    return @enumFromInt(@as(u32, @intCast(v)));
}

fn optU32(v: ?i64) ?u32 {
    return if (v) |x| @as(u32, @intCast(x)) else null;
}

const Cols = struct { kind: []const u8, id: i64 };

fn treasuryCols(t: state_mod.Treasury) Cols {
    return switch (t) {
        .outfit => .{ .kind = "outfit", .id = 0 },
        .hq => |id| .{ .kind = "hq", .id = @intFromEnum(id) },
        .company => |id| .{ .kind = "company", .id = @intFromEnum(id) },
    };
}

fn treasuryFromCols(kind: []const u8, id: i64) state_mod.Treasury {
    if (std.mem.eql(u8, kind, "hq")) return .{ .hq = toId(types.HqId, id) };
    if (std.mem.eql(u8, kind, "company")) return .{ .company = toId(types.ForceId, id) };
    return .outfit;
}

fn siteCols(s: types.Site) Cols {
    return switch (s) {
        .outfit => .{ .kind = "outfit", .id = 0 },
        .hq => |id| .{ .kind = "hq", .id = @intFromEnum(id) },
        .company => |id| .{ .kind = "company", .id = @intFromEnum(id) },
    };
}

fn siteFromCols(kind: []const u8, id: i64) types.Site {
    if (std.mem.eql(u8, kind, "hq")) return .{ .hq = toId(types.HqId, id) };
    if (std.mem.eql(u8, kind, "company")) return .{ .company = toId(types.ForceId, id) };
    return .outfit;
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
    _ = try commands.execute(&gs, .{ .advance_days = 40 }); // battles, events, deliveries, couriers
    const before = gs.hash();

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try std.testing.expect(gs.campaign_id > 0);

    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    try std.testing.expectEqual(before, loaded.hash());
    try std.testing.expectEqualStrings("Kalmar's Free Legion", loaded.outfit_name);
    try std.testing.expectEqual(gs.people.count(), loaded.people.count());
    try std.testing.expectEqual(gs.event_log.items.len, loaded.event_log.items.len);
    try std.testing.expectEqual(gs.event_queue.pending.items.len, loaded.event_queue.pending.items.len);
    // Policies survive the round trip with their current numbers.
    try std.testing.expectEqual(@as(usize, 1), loaded.policies.items.len);
    try std.testing.expectEqual(gs.policies.items[0].sent_this_month, loaded.policies.items[0].sent_this_month);
    try std.testing.expectEqual(@as(usize, 1), loaded.supply_policies.items.len);
    try std.testing.expectEqual(@as(u16, 30), loaded.supply_policies.items[0].min_days);
    try std.testing.expectEqual(@as(u32, 60), loaded.supply_policies.items[0].tons);

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
    try std.testing.expectEqualStrings("Bravo Outfit", after[0].name);
    var still = try store.load(std.testing.allocator, b.campaign_id);
    defer still.deinit();
    try std.testing.expectEqual(b.hash(), still.hash());
}
