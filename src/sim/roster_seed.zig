//! Campaign-start hull-pool seeding: faction pools (P3e.4) and world merc
//! company pools (P3e.5a), docs/p3c-economy-design.md §2/§3/§4/§8.D.
//! Single owner of "a manufactured hull enters a faction or merc-company pool"
//! (rule 20/3): owner tag, hull_instances entry, hull_ownership_history
//! interval, and roster membership are written together in one infallible
//! commit per function.
//! No MekHQ counterpart: campaign-start roster seeding is specific to this
//! implementation (docs/mekhq-map.md).

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const faction = @import("../domain/faction.zig");
const chassis_mod = @import("../domain/chassis.zig");
const hull_mod = @import("../domain/hull_instance.zig");
const rival_mod = @import("../domain/rival.zig");
const merc_company_mod = @import("../domain/merc_company.zig");
const merc_band = @import("../domain/merc_band.zig");
const roster_gen = @import("../gen/roster_gen.zig");
const logo = @import("../domain/logo.zig");
const merc_lifecycle = @import("merc_lifecycle.zig");
const merc_identity = @import("merc_identity.zig");
const npc_base = @import("npc_base.zig");
const GameState = @import("state.zig").GameState;

/// Maximum entries in faction.table; used for fixed stack arrays.
const max_factions = 32;

/// Upper bound for merc-company stack arrays; `merc_band.seedTotal()` must not
/// exceed this (the comptime sanity check below enforces it).
const max_merc_companies: usize = 256;
comptime {
    if (merc_band.seedTotal() > max_merc_companies)
        @compileError("data/tables/merc_bands.zon: seed_companies sum exceeds max_merc_companies; raise the constant");
}

/// Seed every manufacturing faction's hull pool at campaign creation.
/// Failure-atomic (rules 7, 11–13):
///   Prepare  — count needed capacity; no gs.* mutation.
///   Reserve  — ensureUnusedCapacity on all three collections, pre-build
///              per-faction roster ID lists, and construct every HullInstance
///              value (including its loadout) into a flat arena slice; all
///              fallible; on any error gs.* entries are unchanged.
///   Commit   — insert pre-built records into gs.* (infallible); gs.rng and
///              gs.next_hull_instance_id updated last.
///
/// Factions with replenishment_hulls_per_year == 0 are skipped (rule 4,
/// docs/p3c-economy-design.md §4 "empty manufacturing = no roster").
pub fn seedFactionRosters(gs: *GameState) !void {
    const alloc = gs.allocator();
    const tg = tuning.generation;

    // ---- Prepare ----
    // Count capacity needed; no gs.* mutation.
    var total_hulls: u32 = 0;
    var num_seeded: usize = 0;
    // Indices into faction.table for manufacturing factions, stack-local.
    var seeded_idx: [max_factions]usize = undefined;
    var seeded_counts: [max_factions]u32 = undefined;
    for (faction.table, 0..) |*f, i| {
        if (f.replenishment_hulls_per_year == 0) continue;
        const count: u32 = @as(u32, f.replenishment_hulls_per_year) *
            @as(u32, tg.faction_roster_seed_years);
        seeded_idx[num_seeded] = i;
        seeded_counts[num_seeded] = count;
        num_seeded += 1;
        total_hulls += count;
    }
    if (num_seeded == 0) return; // nothing to do

    // ---- Reserve ----
    // All fallible touches happen here, before any gs.* entry is written.
    // A failure here leaves gs.hull_instances, gs.hull_ownership_history,
    // gs.faction_rosters, gs.rng, and gs.next_hull_instance_id unchanged.
    try gs.hull_instances.ensureUnusedCapacity(alloc, total_hulls);
    try gs.hull_ownership_history.ensureUnusedCapacity(alloc, total_hulls);
    try gs.faction_rosters.ensureUnusedCapacity(alloc, num_seeded);

    // Pre-build per-faction roster ID lists; capacity reserved above.
    // On failure, partially-reserved lists are orphaned arena memory —
    // harmless (arena lifetime = campaign lifetime).
    var roster_lists: [max_factions]std.ArrayListUnmanaged(types.HullInstanceId) =
        .{std.ArrayListUnmanaged(types.HullInstanceId).empty} ** max_factions;
    for (0..num_seeded) |ri| {
        try roster_lists[ri].ensureTotalCapacity(alloc, seeded_counts[ri]);
    }

    // Draw from a rng copy so gs.rng is only updated on success.
    var rng_copy = gs.rng;
    var next_id = gs.next_hull_instance_id;
    const year = gs.clock.date.year;

    // Pre-build every HullInstance value — including its loadout — before
    // touching gs.*.  Loadout append is fallible; placing it here (Reserve)
    // ensures a failure leaves gs.* untouched (rules 7, 11–13, 1).
    const built_hulls = try alloc.alloc(hull_mod.HullInstance, total_hulls);
    var hull_idx: usize = 0;
    for (0..num_seeded) |ri| {
        const f = &faction.table[seeded_idx[ri]];
        const count = seeded_counts[ri];
        for (0..count) |_| {
            const hid: types.HullInstanceId = @enumFromInt(next_id);
            next_id += 1;

            const ch = roster_gen.rollFactionPoolOne(&rng_copy, .rosters, f.key, year);
            var inst: hull_mod.HullInstance = .{
                .id = hid,
                .base_key = ch.key, // static catalogue memory
                .status = .active,
                .intro_year = ch.intro_year,
                .pre_campaign = true,
                .owner = .{ .faction = f.key }, // static catalogue key
            };
            // Copy design loadout (docs/p3c-economy-design.md §2).
            // f.key is static catalogue memory — no dupe needed.
            for (ch.loadout) |slot| {
                try inst.loadout.append(alloc, .{ .part_key = slot.part });
            }
            roster_lists[ri].appendAssumeCapacity(hid);
            built_hulls[hull_idx] = inst;
            hull_idx += 1;
        }
    }

    // ---- Commit ----
    // All operations here are infallible; gs.* is only mutated in this phase.
    hull_idx = 0;
    for (0..num_seeded) |ri| {
        const f = &faction.table[seeded_idx[ri]];
        for (roster_lists[ri].items) |hid| {
            gs.hull_instances.putAssumeCapacity(hid, built_hulls[hull_idx]);
            hull_idx += 1;

            // Open one .initial ownership interval (rule 1 — owner without
            // interval is partial truth).
            gs.hull_ownership_history.appendAssumeCapacity(.{
                .hull_instance_id = hid,
                .from_day = 0,
                .to_day = null,
                .acquisition_type = .initial,
                .prior_owner_key = f.key, // static catalogue memory
            });
        }

        // Insert the roster list under the faction's stable key.
        gs.faction_rosters.putAssumeCapacity(f.key, roster_lists[ri]);
    }

    // Update counters last (infallible).
    gs.next_hull_instance_id = next_id;
    gs.rng = rng_copy;
}

/// Seed world merc companies and their hull pools at campaign creation (P3e.5a,
/// docs/p3c-economy-design.md §8.D).
/// Failure-atomic (rules 7, 11–13):
///   Prepare  — count needed capacity; draw identities and hull pools from
///              rng_copy; allocate unit_names and pre-build every HullInstance
///              (including loadout) into a flat arena slice; pre-build roster
///              ID lists. No gs.* mutation.
///   Reserve  — ensureUnusedCapacity on all four affected collections, then
///              prepare the founding log lines; all fallible; on any error
///              gs.* entries are unchanged.
///   Commit   — insert pre-built records and the log lines into gs.*
///              (infallible); gs.rng, gs.next_merc_company_id, and
///              gs.next_hull_instance_id updated last.
///
/// Seeds `merc_band.seedTotal()` companies in the band table's fixed mix
/// (docs/p5d-conflict-world-design.md §L8, D23–D25): each company's band is
/// drawn without replacement from the multiset of every row's
/// `seed_companies` slots, and the company is founded with that band's
/// `capital_cbills` and `merc_band.lineTarget` active mek hulls.
///
/// Draw order: per-company, archetype (.rivals), hiring faction (.rivals),
/// identity (.rivals), logo (.rivals), band (.rivals), then pool hulls
/// (.rosters stream). Within a company, identity/logo/band draws precede all
/// pool draws, so the stream-consumption order is fixed for any given seed:
/// company 0 identity, company 0 logo, company 0 band, company 0 pool hull
/// 0..N-1, company 1 identity, … After every company, a second pass draws
/// each company's base in company-id order (`npc_base.drawBase`, .rivals;
/// docs/p5d-conflict-world-design.md §L1), so identities, bands and pools do
/// not depend on it. Every seeded company's `ready_day` is 0. The eligible
/// logo pool is the sorted catalog minus gs.player_logo_key (if any).
/// Each unit_name is `merc_identity.unitName` over the names seeded before it,
/// so seeded names are distinct (ignoring ASCII case) without an extra draw.
/// This order is documented here so any change to it requires a deliberate
/// re-pin of the golden digest (and the stream-isolation test will catch it).
///
/// Every seeded company gets a roster entry (state.zig). Each company's
/// founding line is logged in company-id order (`merc_lifecycle.foundingLine`).
pub fn seedMercCompanies(gs: *GameState) !void {
    const alloc = gs.allocator();
    const count = merc_band.seedTotal();
    if (count == 0) return;

    // ---- Prepare ----
    // Collect hiring factions (static catalog, stack-local).
    var hiring_faction_idx: [max_factions]usize = undefined;
    var num_hiring: usize = 0;
    for (faction.table, 0..) |*f, i| {
        if (f.hires) {
            hiring_faction_idx[num_hiring] = i;
            num_hiring += 1;
        }
    }
    if (num_hiring == 0) return;

    // One slot per seeded company, `seed_companies` slots per band; the hull
    // total is fixed by the mix whatever order the draw assigns it in.
    var band_slots: [max_merc_companies]*const merc_band.Band = undefined;
    var slots_len: usize = 0;
    var total_hulls: usize = 0;
    for (merc_band.table.bands) |*band| {
        for (0..band.seed_companies) |_| {
            band_slots[slots_len] = band;
            slots_len += 1;
        }
        total_hulls += @as(usize, band.seed_companies) * merc_band.lineTarget(band);
    }

    // Draw from a rng copy so gs.rng is only updated on success.
    var rng_copy = gs.rng;
    var next_mid = gs.next_merc_company_id;
    var next_hid = gs.next_hull_instance_id;
    const year = gs.clock.date.year;

    // Build eligible logo pool: sorted catalog minus the player's reserved key.
    var pool: [logo.all_keys.len][]const u8 = undefined;
    var pool_len: usize = 0;
    for (logo.all_keys) |k| {
        if (gs.player_logo_key.len > 0 and std.mem.eql(u8, k, gs.player_logo_key)) continue;
        pool[pool_len] = k; // static catalog memory
        pool_len += 1;
    }

    // Pre-build per-company data into stack-local arrays.
    // Draw order: per-company, identity (on .rivals) then pool (on .rosters).
    var built_companies: [max_merc_companies]merc_company_mod.MercCompany = undefined;
    var seeded_names: [max_merc_companies][]const u8 = undefined;
    var roster_lists: [max_merc_companies]std.ArrayListUnmanaged(types.HullInstanceId) =
        .{std.ArrayListUnmanaged(types.HullInstanceId).empty} ** max_merc_companies;
    const built_hulls = try alloc.alloc(hull_mod.HullInstance, total_hulls);
    var hull_idx: usize = 0;

    for (0..count) |ci| {
        const mid: types.MercCompanyId = @enumFromInt(next_mid);
        next_mid += 1;

        // Choose archetype deterministically on .rivals stream.
        const archetype_idx = rng_copy.random(.rivals).uintLessThan(usize, rival_mod.table.archetypes.len);
        const archetype = &rival_mod.table.archetypes[archetype_idx];

        // Choose hiring faction deterministically on .rivals stream.
        const fi = hiring_faction_idx[rng_copy.random(.rivals).uintLessThan(usize, num_hiring)];
        const f = &faction.table[fi];

        // Draw identity (pure, no allocation, on .rivals stream).
        const identity = roster_gen.rollMercCompanyIdentity(&rng_copy, .rivals, archetype, f.key);

        // Draw logo without replacement from the eligible pool (on .rivals stream).
        const logo_j = rng_copy.random(.rivals).uintLessThan(usize, pool_len);
        const chosen_logo = pool[logo_j];
        pool[logo_j] = pool[pool_len - 1];
        pool_len -= 1;

        // Draw the band without replacement from the remaining slots (on .rivals stream).
        const band_j = rng_copy.random(.rivals).uintLessThan(usize, slots_len);
        const band = band_slots[band_j];
        band_slots[band_j] = band_slots[slots_len - 1];
        slots_len -= 1;

        // Allocate unit_name (fallible, arena lifetime = campaign lifetime),
        // distinct from every name seeded before it (merc_identity.unitName).
        const unit_name = try merc_identity.unitName(alloc, seeded_names[0..ci], identity.last, archetype.unit_noun);
        seeded_names[ci] = unit_name;

        built_companies[ci] = .{
            .id = mid,
            .archetype_key = archetype.key, // static catalog memory
            .commander_first = identity.first, // static names table memory
            .commander_last = identity.last, // static names table memory
            .unit_name = unit_name,
            .faction_key = f.key, // static catalog memory
            .side = identity.side,
            .doctrine = identity.doctrine,
            .cbills = band.capital_cbills,
            .founded_day = 0,
            .dissolved_day = 0,
            .logo_key = chosen_logo,
            .band_key = band.key, // static table memory
        };

        // Roll this company's hull pool on .rosters stream.
        const hulls_each = merc_band.lineTarget(band);
        try roster_lists[ci].ensureTotalCapacity(alloc, hulls_each);
        for (0..hulls_each) |_| {
            const hid: types.HullInstanceId = @enumFromInt(next_hid);
            next_hid += 1;

            const ch = roster_gen.rollFactionPoolOne(&rng_copy, .rosters, f.key, year);
            var inst: hull_mod.HullInstance = .{
                .id = hid,
                .base_key = ch.key, // static catalog memory
                .status = .active,
                .intro_year = ch.intro_year,
                .pre_campaign = true,
                .owner = .{ .merc_company = mid },
            };
            // Copy design loadout (docs/p3c-economy-design.md §2).
            for (ch.loadout) |slot| {
                try inst.loadout.append(alloc, .{ .part_key = slot.part });
            }
            roster_lists[ci].appendAssumeCapacity(hid);
            built_hulls[hull_idx] = inst;
            hull_idx += 1;
        }
    }

    // Bases (.rivals), in company-id order, after every company's identity,
    // logo, band and pool draws (docs/p5d-conflict-world-design.md §L1).
    for (built_companies[0..count]) |*mc| {
        const base = npc_base.drawBase(&rng_copy, mc.faction_key) orelse return error.CorruptSave;
        mc.home_planet_key = base.key; // static catalog memory
    }

    // ---- Reserve ----
    // All gs.* capacity reservations happen here, before any gs.* count changes.
    // A failure here leaves gs.merc_companies, gs.merc_company_rosters,
    // gs.hull_instances, gs.hull_ownership_history, gs.event_log, gs.rng,
    // gs.next_merc_company_id, and gs.next_hull_instance_id unchanged.
    try gs.merc_companies.ensureUnusedCapacity(alloc, count);
    try gs.merc_company_rosters.ensureUnusedCapacity(alloc, count);
    try gs.hull_instances.ensureUnusedCapacity(alloc, total_hulls);
    try gs.hull_ownership_history.ensureUnusedCapacity(alloc, total_hulls);
    var line_arena = std.heap.ArenaAllocator.init(gs.scratch());
    defer line_arena.deinit();
    var founding_lines: [max_merc_companies][]const u8 = undefined;
    for (built_companies[0..count], founding_lines[0..count]) |company, *line| {
        line.* = try merc_lifecycle.foundingLine(line_arena.allocator(), company);
    }
    const log = try gs.prepareLogBatch(.market, .{}, founding_lines[0..count]);

    // ---- Commit ----
    // All operations here are infallible; gs.* is only mutated in this phase.
    hull_idx = 0;
    for (0..count) |ci| {
        const mc = &built_companies[ci];
        gs.merc_companies.putAssumeCapacity(mc.id, mc.*);

        // Every merc company has a roster entry, empty or not (state.zig).
        gs.merc_company_rosters.putAssumeCapacity(mc.id, roster_lists[ci]);

        for (roster_lists[ci].items) |hid| {
            gs.hull_instances.putAssumeCapacity(hid, built_hulls[hull_idx]);
            hull_idx += 1;

            // Open one .initial ownership interval per hull (rule 1).
            gs.hull_ownership_history.appendAssumeCapacity(.{
                .hull_instance_id = hid,
                .from_day = 0,
                .to_day = null,
                .acquisition_type = .initial,
                .prior_owner_key = mc.faction_key, // static catalog memory
            });
        }
    }

    gs.commitLogBatch(log);

    // Update counters last (infallible).
    gs.next_merc_company_id = next_mid;
    gs.next_hull_instance_id = next_hid;
    gs.rng = rng_copy;
}

// ---- Tests ----

const digest = @import("digest.zig");
const planet_mod = @import("../domain/planet.zig");

test "seedFactionRosters: each manufacturing faction gets the expected roster size" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7001 });
    defer gs.deinit();
    _ = try @import("founding.zig").createCommander(&gs, "T", .LC, .line_officer);
    gs.clock.date.year = 3025;
    try seedFactionRosters(&gs);

    const tg = tuning.generation;
    for (faction.table) |*f| {
        if (f.replenishment_hulls_per_year == 0) {
            try std.testing.expect(gs.faction_rosters.get(f.key) == null);
            continue;
        }
        const expected: usize = @as(usize, f.replenishment_hulls_per_year) *
            @as(usize, tg.faction_roster_seed_years);
        const roster = gs.faction_rosters.get(f.key) orelse {
            std.debug.print("seedFactionRosters: no roster for {s}\n", .{f.key});
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqual(expected, roster.items.len);

        // Every member id resolves in hull_instances with correct fields.
        for (roster.items) |hid| {
            const inst = gs.hull_instances.getPtr(hid) orelse {
                std.debug.print("seedFactionRosters: hull {d} not in hull_instances\n", .{@intFromEnum(hid)});
                return error.TestUnexpectedResult;
            };
            try std.testing.expectEqualStrings(f.key, switch (inst.owner) {
                .faction => |k| k,
                else => return error.TestUnexpectedResult,
            });
            try std.testing.expect(inst.pre_campaign);
            try std.testing.expectEqual(hull_mod.HullStatus.active, inst.status);
            // Exactly one open .initial interval.
            var found: usize = 0;
            for (gs.hull_ownership_history.items) |h| {
                if (h.hull_instance_id != hid) continue;
                found += 1;
                try std.testing.expectEqual(hull_mod.AcquisitionType.initial, h.acquisition_type);
                try std.testing.expectEqual(@as(u32, 0), h.from_day);
                try std.testing.expectEqual(@as(?u32, null), h.to_day);
                try std.testing.expectEqualStrings(f.key, h.prior_owner_key);
            }
            try std.testing.expectEqual(@as(usize, 1), found);
        }
    }
    // next_hull_instance_id is past all seeded ids.
    var max_id: u32 = 0;
    var hit = gs.hull_instances.iterator();
    while (hit.next()) |e| {
        const raw: u32 = @intFromEnum(e.key_ptr.*);
        if (raw > max_id) max_id = raw;
    }
    try std.testing.expect(gs.next_hull_instance_id > max_id);
}

test "seedFactionRosters: determinism and stream isolation" {
    // Two same-seed campaigns produce identical stateHash after seeding.
    var gs1 = GameState.init(std.testing.allocator, .{ .seed = 7002 });
    defer gs1.deinit();
    var gs2 = GameState.init(std.testing.allocator, .{ .seed = 7002 });
    defer gs2.deinit();

    _ = try @import("founding.zig").createCommander(&gs1, "T", .LC, .line_officer);
    _ = try @import("founding.zig").createCommander(&gs2, "T", .LC, .line_officer);
    gs1.clock.date.year = 3025;
    gs2.clock.date.year = 3025;

    // Sample the .generation stream on both before seeding.
    const gen_before_1 = gs1.rng.random(.generation).int(u64);
    const gen_before_2 = gs2.rng.random(.generation).int(u64);
    try std.testing.expectEqual(gen_before_1, gen_before_2);

    // Resync: reset both prngs to same state for generation stream
    // (the sample above advanced both identically, so they remain equal).

    try seedFactionRosters(&gs1);
    try seedFactionRosters(&gs2);

    try std.testing.expectEqual(digest.stateHash(&gs1), digest.stateHash(&gs2));

    // Stream isolation: seeding must not perturb .generation draws.
    // Sample .generation draws after seeding on both (should still match).
    for (0..10) |_| {
        try std.testing.expectEqual(
            gs1.rng.random(.generation).int(u64),
            gs2.rng.random(.generation).int(u64),
        );
    }
}

test "seedFactionRosters: atomicity — reserve-phase failure leaves stateHash unchanged" {
    // Outer arena owns all pages; inner arena nulled after test so outer.deinit()
    // cleans up without leaks — the standard atomicity-test pattern (contract_market.zig).
    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 7003 });
    _ = try @import("founding.zig").createCommander(&gs, "T", .LC, .line_officer);
    gs.clock.date.year = 3025;

    const before = digest.stateHash(&gs);

    // Block all further allocations (the reserve phase fires first).
    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;

    try std.testing.expectError(error.OutOfMemory, seedFactionRosters(&gs));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
}

test "seedFactionRosters: atomicity — any allocation failure leaves stateHash unchanged" {
    // Iterate fail_index from 0 upward, covering reserve-phase capacity
    // reservations AND prepare-phase loadout copies.  Every OOM must leave
    // gs.* bit-identical to the pre-call state; success must change it.
    // Pattern from src/sim/field_supply.zig.
    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 7005 });
    _ = try @import("founding.zig").createCommander(&gs, "T", .LC, .line_officer);
    gs.clock.date.year = 3025;

    const before = digest.stateHash(&gs);

    var i: usize = 0;
    while (true) : (i += 1) {
        gs.arena.state.used_list = null;
        gs.arena.state.free_list = null;
        var failing = std.testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = i });
        gs.arena.child_allocator = failing.allocator();

        if (seedFactionRosters(&gs)) |_| {
            // All allocations succeeded; state must have changed.
            try std.testing.expect(digest.stateHash(&gs) != before);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(before, digest.stateHash(&gs));
        }
    }
}

/// The row index of the band named `key` in `merc_band.table`.
fn bandIndex(key: []const u8) !usize {
    for (merc_band.table.bands, 0..) |band, i| {
        if (std.mem.eql(u8, band.key, key)) return i;
    }
    return error.TestUnexpectedResult;
}

/// Each seeded company's band row index, in company-id order.
fn seededBandIndices(gs: *GameState, out: []usize) !void {
    for (gs.merc_companies.values(), out) |mc, *index| index.* = try bandIndex(mc.band_key);
}

test "seedMercCompanies: each band seeds its companies, line and capital, and the seed draws the assignment" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7010 });
    defer gs.deinit();
    _ = try @import("founding.zig").createCommander(&gs, "T", .LC, .line_officer);
    gs.clock.date.year = 3025;
    try seedMercCompanies(&gs);

    try std.testing.expectEqual(@as(usize, 12), gs.merc_companies.count());

    var per_band = [_]usize{0} ** merc_band.table.bands.len;
    var it = gs.merc_companies.iterator();
    while (it.next()) |entry| {
        const mc = entry.value_ptr;
        const band = merc_band.find(mc.band_key) orelse return error.TestUnexpectedResult;
        per_band[try bandIndex(band.key)] += 1;
        try std.testing.expectEqual(band.capital_cbills, mc.cbills);

        const roster = gs.merc_company_rosters.get(mc.id) orelse {
            std.debug.print("seedMercCompanies: no roster for merc company {d}\n", .{@intFromEnum(mc.id)});
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqual(@as(usize, 16), roster.items.len);
        try std.testing.expectEqual(merc_band.lineTarget(band), roster.items.len);

        // Campaign-start NPC pools are mek-only at the band's line target.
        for (roster.items) |hid| {
            const inst = gs.hull_instances.getPtr(hid) orelse {
                std.debug.print("seedMercCompanies: hull {d} not in hull_instances\n", .{@intFromEnum(hid)});
                return error.TestUnexpectedResult;
            };
            try std.testing.expectEqual(mc.id, switch (inst.owner) {
                .merc_company => |id| id,
                else => return error.TestUnexpectedResult,
            });
            try std.testing.expect(inst.pre_campaign);
            try std.testing.expectEqual(hull_mod.HullStatus.active, inst.status);
            try std.testing.expectEqual(@import("../domain/unit.zig").UnitKind.mek, chassis_mod.find(inst.base_key).?.kind);

            // Exactly one open .initial interval per hull.
            var found: usize = 0;
            for (gs.hull_ownership_history.items) |h| {
                if (h.hull_instance_id != hid) continue;
                found += 1;
                try std.testing.expectEqual(hull_mod.AcquisitionType.initial, h.acquisition_type);
                try std.testing.expectEqual(@as(u32, 0), h.from_day);
                try std.testing.expectEqual(@as(?u32, null), h.to_day);
                try std.testing.expectEqualStrings(mc.faction_key, h.prior_owner_key);
            }
            try std.testing.expectEqual(@as(usize, 1), found);
        }
    }
    // The table's mix, band by band.
    for (merc_band.table.bands, per_band) |band, seeded| {
        try std.testing.expectEqual(@as(usize, band.seed_companies), seeded);
    }

    // Another seed draws a different band-to-company assignment from the same mix.
    var other = GameState.init(std.testing.allocator, .{ .seed = 7016 });
    defer other.deinit();
    _ = try @import("founding.zig").createCommander(&other, "T", .LC, .line_officer);
    other.clock.date.year = 3025;
    try seedMercCompanies(&other);
    var first: [12]usize = undefined;
    var second: [12]usize = undefined;
    try seededBandIndices(&gs, &first);
    try seededBandIndices(&other, &second);
    try std.testing.expect(!std.mem.eql(usize, &first, &second));
    var sorted_first = first;
    var sorted_second = second;
    std.mem.sort(usize, &sorted_first, {}, std.sort.asc(usize));
    std.mem.sort(usize, &sorted_second, {}, std.sort.asc(usize));
    try std.testing.expectEqualSlices(usize, &sorted_first, &sorted_second);
    // next_merc_company_id is past all seeded ids.
    var max_mid: u32 = 0;
    var mit = gs.merc_companies.iterator();
    while (mit.next()) |e| {
        const raw: u32 = @intFromEnum(e.key_ptr.*);
        if (raw > max_mid) max_mid = raw;
    }
    try std.testing.expect(gs.next_merc_company_id > max_mid);
    // next_hull_instance_id is past all seeded hull ids.
    var max_hid: u32 = 0;
    var hit = gs.hull_instances.iterator();
    while (hit.next()) |e| {
        const raw: u32 = @intFromEnum(e.key_ptr.*);
        if (raw > max_hid) max_hid = raw;
    }
    try std.testing.expect(gs.next_hull_instance_id > max_hid);
}

test "seedMercCompanies bases every company on a world of its own faction, Periphery included, fixed by the seed" {
    // docs/p5d-conflict-world-design.md §L1, decision M3. The base pass runs
    // after every identity, band and pool draw, so seeded names stay as the
    // seed gave them (the seed-26 names pinned in store.zig's tests).
    const Bases = [12][]const u8;
    const S = struct {
        fn seeded(seed: u64, periphery: *bool) !Bases {
            var gs = GameState.init(std.testing.allocator, .{ .seed = seed });
            defer gs.deinit();
            _ = try @import("founding.zig").createCommander(&gs, "T", .LC, .line_officer);
            gs.clock.date.year = 3025;
            try seedMercCompanies(&gs);
            var out: Bases = undefined;
            for (gs.merc_companies.values(), &out) |company, *key| {
                const world = planet_mod.find(company.home_planet_key) orelse return error.TestUnexpectedResult;
                try std.testing.expectEqualStrings(company.faction_key, world.faction);
                try std.testing.expectEqual(@as(u32, 0), company.ready_day);
                if (std.mem.eql(u8, company.faction_key, "PER")) periphery.* = true;
                key.* = world.key; // static catalog memory
            }
            return out;
        }
    };
    var periphery = false;
    const first = try S.seeded(7020, &periphery);
    const again = try S.seeded(7020, &periphery);
    for (first, again) |a, b| try std.testing.expectEqualStrings(a, b);
    const other = try S.seeded(7021, &periphery);
    const differs = for (first, other) |a, b| {
        if (!std.mem.eql(u8, a, b)) break true;
    } else false;
    try std.testing.expect(differs);
    // Some seed founds a Periphery company; it too is based on a Periphery world.
    var seed: u64 = 7022;
    while (!periphery and seed < 7100) : (seed += 1) _ = try S.seeded(seed, &periphery);
    try std.testing.expect(periphery);
}

test "seedMercCompanies logs one founding line per company in company-id order" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7015 });
    defer gs.deinit();
    _ = try @import("founding.zig").createCommander(&gs, "T", .LC, .line_officer);
    gs.clock.date.year = 3025;
    const log_before = gs.event_log.items.len;
    try seedMercCompanies(&gs);

    const lines = gs.event_log.items[log_before..];
    try std.testing.expectEqual(merc_band.seedTotal(), lines.len);
    // The log follows the map, and the map is in ascending company id.
    for (lines, gs.merc_companies.values()) |entry, company| {
        const expected = try merc_lifecycle.foundingLine(std.testing.allocator, company);
        defer std.testing.allocator.free(expected);
        try std.testing.expect(std.mem.endsWith(u8, entry.text, expected));
        try std.testing.expect(std.mem.startsWith(u8, entry.text, "3025-"));
        try std.testing.expect(std.mem.indexOf(u8, entry.text, company.unit_name) != null);
        try std.testing.expectEqual(@import("state.zig").LogCategory.market, entry.category);
        try std.testing.expectEqual(@as(u32, 0), entry.day);
    }
    for (gs.merc_companies.keys()[1..], gs.merc_companies.keys()[0 .. gs.merc_companies.count() - 1]) |id, prior| {
        try std.testing.expect(@intFromEnum(id) > @intFromEnum(prior));
    }
}

test "seedMercCompanies: determinism and stream isolation" {
    var gs1 = GameState.init(std.testing.allocator, .{ .seed = 7011 });
    defer gs1.deinit();
    var gs2 = GameState.init(std.testing.allocator, .{ .seed = 7011 });
    defer gs2.deinit();

    _ = try @import("founding.zig").createCommander(&gs1, "T", .LC, .line_officer);
    _ = try @import("founding.zig").createCommander(&gs2, "T", .LC, .line_officer);
    gs1.clock.date.year = 3025;
    gs2.clock.date.year = 3025;

    // Sample .generation and .battle streams before seeding on both.
    const gen_before_1 = gs1.rng.random(.generation).int(u64);
    const gen_before_2 = gs2.rng.random(.generation).int(u64);
    try std.testing.expectEqual(gen_before_1, gen_before_2);
    const battle_before_1 = gs1.rng.random(.battle).int(u64);
    const battle_before_2 = gs2.rng.random(.battle).int(u64);
    try std.testing.expectEqual(battle_before_1, battle_before_2);

    try seedMercCompanies(&gs1);
    try seedMercCompanies(&gs2);

    try std.testing.expectEqual(digest.stateHash(&gs1), digest.stateHash(&gs2));

    // Stream isolation: seeding on .rivals and .rosters must not perturb
    // .generation or .battle draws.
    for (0..10) |_| {
        try std.testing.expectEqual(
            gs1.rng.random(.generation).int(u64),
            gs2.rng.random(.generation).int(u64),
        );
        try std.testing.expectEqual(
            gs1.rng.random(.battle).int(u64),
            gs2.rng.random(.battle).int(u64),
        );
    }
}

test "seedMercCompanies: atomicity — any allocation failure leaves stateHash unchanged" {
    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 7012 });
    _ = try @import("founding.zig").createCommander(&gs, "T", .LC, .line_officer);
    gs.clock.date.year = 3025;

    const before = digest.stateHash(&gs);

    var i: usize = 0;
    while (true) : (i += 1) {
        gs.arena.state.used_list = null;
        gs.arena.state.free_list = null;
        var failing = std.testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = i });
        gs.arena.child_allocator = failing.allocator();

        if (seedMercCompanies(&gs)) |_| {
            // All allocations succeeded; state must have changed.
            try std.testing.expect(digest.stateHash(&gs) != before);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(before, digest.stateHash(&gs));
        }
    }
}

test "seedMercCompanies: reserves the player's logo and assigns distinct catalog logos" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7013 });
    defer gs.deinit();
    _ = try @import("founding.zig").createCommander(&gs, "T", .LC, .line_officer);
    gs.clock.date.year = 3025;
    gs.player_logo_key = logo.all_keys[0]; // reserve first key
    try seedMercCompanies(&gs);

    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer seen.deinit();
    var it = gs.merc_companies.iterator();
    while (it.next()) |entry| {
        const mc = entry.value_ptr;
        // Must be a catalog key.
        var in_catalog = false;
        for (logo.all_keys) |k| {
            if (std.mem.eql(u8, mc.logo_key, k)) {
                in_catalog = true;
                break;
            }
        }
        try std.testing.expect(in_catalog);
        // Must not be the reserved player key.
        try std.testing.expect(!std.mem.eql(u8, mc.logo_key, logo.all_keys[0]));
        // Must be distinct across all seeded companies.
        try std.testing.expect(!seen.contains(mc.logo_key));
        try seen.put(mc.logo_key, {});
    }
}

test "seedMercCompanies: empty player_logo_key draws from the full catalog" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7014 });
    defer gs.deinit();
    _ = try @import("founding.zig").createCommander(&gs, "T", .LC, .line_officer);
    gs.clock.date.year = 3025;
    // player_logo_key defaults to "" — full pool
    try seedMercCompanies(&gs);

    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer seen.deinit();
    var it = gs.merc_companies.iterator();
    while (it.next()) |entry| {
        const mc = entry.value_ptr;
        // Must be a catalog key.
        var in_catalog = false;
        for (logo.all_keys) |k| {
            if (std.mem.eql(u8, mc.logo_key, k)) {
                in_catalog = true;
                break;
            }
        }
        try std.testing.expect(in_catalog);
        // Must be distinct across all seeded companies.
        try std.testing.expect(!seen.contains(mc.logo_key));
        try seen.put(mc.logo_key, {});
    }
}

test "a campaign whose seeded base names collide founds every company under a distinct name" {
    // Seed 26 draws "Quintana Assault" for companies 6 and 11.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 26 });
    defer gs.deinit();
    _ = try @import("commands.zig").execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer } });
    const companies = gs.merc_companies.values();
    try std.testing.expectEqual(merc_band.seedTotal(), companies.len);

    // Every identity field except the name, and every pool hull, is the
    // seeding draw's; only the name avoids earlier names.
    var fingerprint = std.hash.Wyhash.init(0);
    for (companies) |company| {
        for ([_][]const u8{ company.archetype_key, company.commander_first, company.commander_last, company.faction_key, company.logo_key, company.band_key, @tagName(company.side), @tagName(company.doctrine) }) |field| {
            fingerprint.update(field);
            fingerprint.update("\x00");
        }
        for (gs.merc_company_rosters.get(company.id).?.items) |hull_id| fingerprint.update(gs.hull_instances.get(hull_id).?.base_key);
    }
    try std.testing.expectEqual(@as(u64, 9167329222349959627), fingerprint.final());

    for (companies, 0..) |company, i| {
        for (companies[0..i]) |earlier| try std.testing.expect(!std.ascii.eqlIgnoreCase(company.unit_name, earlier.unit_name));
    }
    try std.testing.expectEqualStrings("Quintana Assault", gs.merc_companies.get(@enumFromInt(6)).?.unit_name);
    try std.testing.expectEqualStrings("Quintana Assault II", gs.merc_companies.get(@enumFromInt(11)).?.unit_name);
}

/// Seed the Periphery/pirates (PER) faction hull pool at campaign creation
/// (P3e.5b-1, docs/p3c-economy-design.md §8.C; owner decision 3).
/// Failure-atomic (rules 7, 11–13):
///   Prepare  — locate PER in faction.table; if absent, return without error.
///              If pirate_pool_hulls == 0, return without seeding.
///   Reserve  — ensureUnusedCapacity on hull_instances, hull_ownership_history,
///              and faction_rosters; pre-build roster ID list; construct every
///              HullInstance (including loadout) into a flat arena slice.
///              All fallible; on any error gs.* entries are unchanged.
///   Commit   — insert pre-built records into gs.* (infallible); gs.rng and
///              gs.next_hull_instance_id updated last.
///
/// Draws on the .rosters stream only; does not touch .rivals, .generation,
/// or .battle. Appended after seedMercCompanies to minimise golden-hash churn
/// (stream-consumption order is fixed: faction seeding, merc seeding, PER seeding).
pub fn seedPirateRoster(gs: *GameState) !void {
    const alloc = gs.allocator();
    const total: u32 = @as(u32, tuning.generation.pirate_pool_hulls);
    if (total == 0) return;

    // ---- Prepare ----
    // Locate PER in the static faction table.  If a mod removed PER, return
    // without seeding — fail-closed, matching seedFactionRosters' omit behaviour.
    const per_key: []const u8 = blk: {
        for (faction.table) |*f| {
            if (std.mem.eql(u8, f.key, "PER")) break :blk f.key;
        }
        return; // PER absent — no seeding, no error
    };

    // ---- Reserve ----
    // All fallible touches happen here, before any gs.* entry is written.
    try gs.hull_instances.ensureUnusedCapacity(alloc, total);
    try gs.hull_ownership_history.ensureUnusedCapacity(alloc, total);
    try gs.faction_rosters.ensureUnusedCapacity(alloc, 1);

    var roster_list = std.ArrayListUnmanaged(types.HullInstanceId).empty;
    try roster_list.ensureTotalCapacity(alloc, total);

    // Draw from rng_copy so gs.rng is updated only on success.
    var rng_copy = gs.rng;
    var next_id = gs.next_hull_instance_id;
    const year = gs.clock.date.year;

    // Pre-build every HullInstance — loadout append is fallible, placed here.
    const built_hulls = try alloc.alloc(hull_mod.HullInstance, total);
    var hull_idx: usize = 0;
    for (0..total) |_| {
        const hid: types.HullInstanceId = @enumFromInt(next_id);
        next_id += 1;

        const ch = roster_gen.rollFactionPoolOne(&rng_copy, .rosters, per_key, year);
        var inst: hull_mod.HullInstance = .{
            .id = hid,
            .base_key = ch.key, // static catalogue memory
            .status = .active,
            .intro_year = ch.intro_year,
            .pre_campaign = true,
            .owner = .{ .faction = per_key }, // static catalogue key
        };
        // Copy design loadout (docs/p3c-economy-design.md §2).
        for (ch.loadout) |slot| {
            try inst.loadout.append(alloc, .{ .part_key = slot.part });
        }
        roster_list.appendAssumeCapacity(hid);
        built_hulls[hull_idx] = inst;
        hull_idx += 1;
    }

    // ---- Commit ----
    // All operations here are infallible; gs.* is only mutated in this phase.
    hull_idx = 0;
    for (roster_list.items) |hid| {
        gs.hull_instances.putAssumeCapacity(hid, built_hulls[hull_idx]);
        hull_idx += 1;

        // Open one .initial ownership interval per hull (rule 1 — owner without
        // interval is partial truth).
        gs.hull_ownership_history.appendAssumeCapacity(.{
            .hull_instance_id = hid,
            .from_day = 0,
            .to_day = null,
            .acquisition_type = .initial,
            .prior_owner_key = per_key, // static catalogue memory
        });
    }

    // Insert the roster list under PER's stable key.
    gs.faction_rosters.putAssumeCapacity(per_key, roster_list);

    // Update counters last (infallible).
    gs.next_hull_instance_id = next_id;
    gs.rng = rng_copy;
}

test "seedPirateRoster: PER gets the flat pool, owner .faction PER, one open .initial interval each" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7020 });
    defer gs.deinit();
    _ = try @import("founding.zig").createCommander(&gs, "T", .LC, .line_officer);
    gs.clock.date.year = 3025;
    try seedPirateRoster(&gs);

    const tg = tuning.generation;
    const roster = gs.faction_rosters.get("PER") orelse {
        std.debug.print("seedPirateRoster: no roster for PER\n", .{});
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(@as(usize, tg.pirate_pool_hulls), roster.items.len);

    for (roster.items) |hid| {
        const inst = gs.hull_instances.getPtr(hid) orelse {
            std.debug.print("seedPirateRoster: hull {d} not in hull_instances\n", .{@intFromEnum(hid)});
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqualStrings("PER", switch (inst.owner) {
            .faction => |k| k,
            else => return error.TestUnexpectedResult,
        });
        try std.testing.expect(inst.pre_campaign);
        try std.testing.expectEqual(hull_mod.HullStatus.active, inst.status);
        // Exactly one open .initial ownership interval.
        var found: usize = 0;
        for (gs.hull_ownership_history.items) |h| {
            if (h.hull_instance_id != hid) continue;
            found += 1;
            try std.testing.expectEqual(hull_mod.AcquisitionType.initial, h.acquisition_type);
            try std.testing.expectEqual(@as(u32, 0), h.from_day);
            try std.testing.expectEqual(@as(?u32, null), h.to_day);
            try std.testing.expectEqualStrings("PER", h.prior_owner_key);
        }
        try std.testing.expectEqual(@as(usize, 1), found);
    }
    // next_hull_instance_id is past all seeded ids.
    var max_id: u32 = 0;
    var hit = gs.hull_instances.iterator();
    while (hit.next()) |e| {
        const raw: u32 = @intFromEnum(e.key_ptr.*);
        if (raw > max_id) max_id = raw;
    }
    try std.testing.expect(gs.next_hull_instance_id > max_id);
}

test "seedPirateRoster: determinism and stream isolation" {
    var gs1 = GameState.init(std.testing.allocator, .{ .seed = 7021 });
    defer gs1.deinit();
    var gs2 = GameState.init(std.testing.allocator, .{ .seed = 7021 });
    defer gs2.deinit();

    _ = try @import("founding.zig").createCommander(&gs1, "T", .LC, .line_officer);
    _ = try @import("founding.zig").createCommander(&gs2, "T", .LC, .line_officer);
    gs1.clock.date.year = 3025;
    gs2.clock.date.year = 3025;

    // Sample .generation and .battle streams before seeding on both.
    const gen_before_1 = gs1.rng.random(.generation).int(u64);
    const gen_before_2 = gs2.rng.random(.generation).int(u64);
    try std.testing.expectEqual(gen_before_1, gen_before_2);
    const battle_before_1 = gs1.rng.random(.battle).int(u64);
    const battle_before_2 = gs2.rng.random(.battle).int(u64);
    try std.testing.expectEqual(battle_before_1, battle_before_2);

    try seedPirateRoster(&gs1);
    try seedPirateRoster(&gs2);

    try std.testing.expectEqual(digest.stateHash(&gs1), digest.stateHash(&gs2));

    // Stream isolation: seeding on .rosters must not perturb .generation or .battle.
    for (0..10) |_| {
        try std.testing.expectEqual(
            gs1.rng.random(.generation).int(u64),
            gs2.rng.random(.generation).int(u64),
        );
        try std.testing.expectEqual(
            gs1.rng.random(.battle).int(u64),
            gs2.rng.random(.battle).int(u64),
        );
    }
}

test "seedPirateRoster: atomicity — any allocation failure leaves stateHash unchanged" {
    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 7022 });
    _ = try @import("founding.zig").createCommander(&gs, "T", .LC, .line_officer);
    gs.clock.date.year = 3025;

    const before = digest.stateHash(&gs);

    var i: usize = 0;
    while (true) : (i += 1) {
        gs.arena.state.used_list = null;
        gs.arena.state.free_list = null;
        var failing = std.testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = i });
        gs.arena.child_allocator = failing.allocator();

        if (seedPirateRoster(&gs)) |_| {
            // All allocations succeeded; state must have changed.
            try std.testing.expect(digest.stateHash(&gs) != before);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(before, digest.stateHash(&gs));
        }
    }
}

// Round-trip test lives in src/persist/store.zig (rule 5: sim does not import
// persist; the test is "seeded campaign round-trips with identical stateHash").
