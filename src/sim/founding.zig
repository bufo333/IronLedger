//! Founding: commander creation and HQ setup (ARCH §4).
//! MekHQ counterpart: `Campaign.java` initial setup; our version separates
//! founding from the state it operates on.

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const person_mod = @import("../domain/person.zig");
const commander_mod = @import("../domain/commander.zig");
const planet_mod = @import("../domain/planet.zig");
const hq_mod = @import("../domain/hq.zig");
const part_mod = @import("../domain/part.zig");
const person_gen = @import("../gen/person_gen.zig");
const GameState = @import("state.zig").GameState;
const hq_ops = @import("hq_ops.zig");
const contract_market = @import("contract_market.zig");
const commands = @import("commands.zig");

pub const CreateCommanderError = error{ CommanderExists, NoHomeWorld, UnknownSite } || std.mem.Allocator.Error;

/// A generous fixed bound on the starter HQ's staff plan (rule 11-13:
/// every founding allocation is pre-sized before anything commits). Derived
/// from the tuning constants for a regional HQ at level-1 facilities; a
/// future tuning change that raises the requirement past this trips the
/// assertion below rather than silently overrunning a stack array.
const max_founding_staff = 32;

/// Character creation: the commander's origin picks the starter world
/// (weighted-random in their faction's space) and stands up the starter
/// regional HQ there with modest level-1 facilities.
///
/// Failure-atomic (rules 11-13): every RNG draw and allocation happens in
/// a prepare phase that never touches `gs`; nothing commits until every
/// destination has reserved capacity, so an OOM anywhere in preparation
/// leaves `gs` — including `gs.rng` — exactly as it was.
pub fn createCommander(
    gs: *GameState,
    name: []const u8,
    origin: commander_mod.Faction,
    profession: commander_mod.Profession,
) CreateCommanderError!types.HqId {
    // ---- validate ----
    if (gs.commander != null) return error.CommanderExists;

    // ---- prepare: RNG draws and allocations; no gs.* mutation ----
    var rng_copy = gs.rng;
    const world = planet_mod.weightedPickByFaction(&rng_copy, .generation, origin.key()) orelse return error.NoHomeWorld;

    const owned_name = try gs.allocator().dupe(u8, name);

    var hq: hq_mod.Hq = .{
        .id = .none,
        .name = try std.fmt.allocPrint(gs.allocator(), "{s} Regional HQ", .{world.name}),
        .tier = .regional,
        .planet_key = world.key,
        .monthly_upkeep = hq_mod.HqTier.regional.monthlyUpkeep(),
    };
    const starter_facilities = [_]hq_mod.FacilityKind{ .mek_bay, .warehouse, .hospital, .mess, .comms, .spaceport, .hiring_hall, .training_ground };
    for (starter_facilities) |kind| {
        try hq.facilities.append(gs.allocator(), .{ .kind = kind, .level = 1 });
    }

    // The back office is people: the starter HQ's staff plan, to requirement.
    const req = hq.staffRequired();
    const staff_plan = req.hiringPlan();
    var total_staff: u32 = 0;
    for (staff_plan) |entry| total_staff += entry.need;
    std.debug.assert(total_staff <= max_founding_staff);

    // Draw every founding recruit's spec from the RNG copy. `recruitBonus`
    // (personnel.zig) is role-agnostic: it awards +1 to every recruit once
    // an HQ's assigned admin_hr count reaches `tuning.person.recruit_hr_admins`,
    // regardless of the role being recruited. A local counter tracks that
    // count as each admin_hr recruit is drawn; the bonus it unlocks then
    // applies to every recruit that follows, admin_hr or not.
    var specs: [max_founding_staff]person_gen.GeneratedPerson = undefined;
    var staff_count: usize = 0;
    var admin_hr_count: u32 = 0;
    for (staff_plan) |entry| {
        for (0..entry.need) |_| {
            const bonus: i32 = if (admin_hr_count >= tuning.person.recruit_hr_admins) 1 else 0;
            specs[staff_count] = person_gen.generateWithBonus(&rng_copy, .generation, entry.role, bonus);
            staff_count += 1;
            if (entry.role == .admin_hr) admin_hr_count += 1;
        }
    }

    // Pre-build every Person struct: allocations only, no more RNG.
    var built: [max_founding_staff]person_mod.Person = undefined;
    for (specs[0..staff_count], 0..) |spec, i| {
        var p: person_mod.Person = .{
            .id = .none,
            .first_name = try gs.allocator().dupe(u8, spec.first),
            .last_name = try gs.allocator().dupe(u8, spec.last),
            .role = spec.role,
            .recruited_day = gs.clock.day_index,
        };
        if (spec.callsign) |c| p.callsign = try gs.allocator().dupe(u8, c);
        try p.skills.put(gs.allocator(), .admin, spec.primary_skill);
        p.setBirthdayFromAge(gs.clock.day_index, spec.age);
        built[i] = p;
    }

    // A modestly stocked warehouse to start, on the local HQ (not yet on
    // the books).
    const g = tuning.generation;
    {
        const entry = try hq.stock.getOrPut(gs.allocator(), "provisions");
        entry.value_ptr.* = g.starter_provisions;
    }
    {
        const entry = try hq.stock.getOrPut(gs.allocator(), "medical_supplies");
        entry.value_ptr.* = g.starter_medical;
    }
    {
        const entry = try hq.stock.getOrPut(gs.allocator(), "armor");
        entry.value_ptr.* = g.starter_armor;
    }
    for (part_mod.component_keys) |key| {
        const entry = try hq.stock.getOrPut(gs.allocator(), key);
        entry.value_ptr.* = g.starter_components_each;
    }
    for (part_mod.munition_keys) |key| {
        const entry = try hq.stock.getOrPut(gs.allocator(), key);
        entry.value_ptr.* = g.starter_munitions_each;
    }

    // Reserve capacity in every GameState destination: nothing past this
    // point can fail.
    try gs.hqs.ensureUnusedCapacity(gs.allocator(), 1);
    try gs.people.ensureUnusedCapacity(gs.allocator(), total_staff);
    try gs.policies.ensureUnusedCapacity(gs.allocator(), 1);
    try gs.stock_policies.ensureUnusedCapacity(gs.allocator(), 1);
    const founding_funds = tuning.hq.founding_funds;
    const can_fund = gs.funds >= founding_funds;
    if (can_fund) try gs.reserveLedger(2); // debit + credit

    // ---- commit: no fallible operation past this point ----
    gs.commander = .{
        .name = owned_name,
        .origin = origin,
        .profession = profession,
    };

    const id = gs.commitHq(hq);

    for (built[0..staff_count]) |person| {
        var p = person;
        const pid: types.PersonId = @enumFromInt(gs.next_person_id);
        gs.next_person_id += 1;
        p.id = pid;
        p.posted_hq = id;
        gs.people.putAssumeCapacity(pid, p);
    }
    hq_ops.refreshHqStaffing(gs);

    // Founding capital: the HQ opens with its own operating treasury,
    // handed over on-site (no courier). An outfit that cannot cover it
    // opens the HQ with an empty treasury — matching `treasury.transferFunds`'s
    // `InsufficientTreasury` refusal, done here without a fallible call.
    if (can_fund) {
        gs.ledger.transactions.appendAssumeCapacity(.{
            .day = gs.clock.day_index,
            .amount = -founding_funds,
            .category = .fund_transfer,
            .note = "funds dispatched",
        });
        gs.funds -= founding_funds;
        gs.ledger.transactions.appendAssumeCapacity(.{
            .day = gs.clock.day_index,
            .amount = founding_funds,
            .category = .fund_transfer,
            .hq = id,
            .note = "funds received",
        });
        gs.hqs.getPtr(id).?.funds += founding_funds;
    }

    // Standing defaults the player can clear, so a hands-off outfit keeps
    // its HQ solvent and fed: the outfit tops the HQ up on payday, and
    // the warehouse keeps provisions stocked.
    gs.policies.appendAssumeCapacity(.{ .entity = .{ .hq = id }, .floor = tuning.finance.hq_policy_floor, .monthly_cap = tuning.finance.hq_policy_cap });
    gs.stock_policies.appendAssumeCapacity(.{ .hq = id, .part_key = "provisions", .min = g.provisions_keep_min, .target = g.provisions_keep_target });

    // Commit the RNG state last: everything above is now on the books.
    gs.rng = rng_copy;
    return id;
}

// ------------------------------------- the HQ network

pub const FoundError = error{ UnknownPlanet, NotReachable } || std.mem.Allocator.Error;

/// Stand up an HQ on a world. Field HQs open with a bay, a warehouse
/// and a mess; regional ones add comms, a spaceport, a hospital and a
/// hiring hall. Staffing is the player's problem from day one.
pub fn foundHq(gs: *GameState, name: []const u8, tier: hq_mod.HqTier, planet_key: []const u8) FoundError!types.HqId {
    const hq = try prepareHq(gs, name, tier, planet_key);
    try gs.hqs.ensureUnusedCapacity(gs.allocator(), 1);
    return gs.commitHq(hq);
}

/// A new HQ with every allocation done but no id and nothing on the
/// books; `commitHq` registers it.
pub fn prepareHq(gs: *GameState, name: []const u8, tier: hq_mod.HqTier, planet_key: []const u8) FoundError!hq_mod.Hq {
    const world = planet_mod.find(planet_key) orelse return error.UnknownPlanet;
    var hq: hq_mod.Hq = .{
        .id = .none,
        .name = try gs.allocator().dupe(u8, name),
        .tier = tier,
        .planet_key = world.key,
        .monthly_upkeep = tier.monthlyUpkeep(),
    };
    const base = [_]hq_mod.FacilityKind{ .mek_bay, .warehouse, .mess };
    for (base) |kind| try hq.facilities.append(gs.allocator(), .{ .kind = kind, .level = 1 });
    if (tier != .field) {
        const more = [_]hq_mod.FacilityKind{ .comms, .spaceport, .hospital, .hiring_hall, .training_ground };
        for (more) |kind| try hq.facilities.append(gs.allocator(), .{ .kind = kind, .level = 1 });
    }
    return hq;
}

// ---- C4b handler (moved from commands.zig) ----
const Error = commands.Error;
const Result = commands.Result;
const Command = commands.Command;

pub fn execCreateCommander(gs: *GameState, c: @FieldType(Command, "create_commander")) Error!Result {
    if (c.start_year < 3000 or c.start_year > 3060) return Error.BadYear;
    _ = try createCommander(gs, c.name, c.origin, c.profession);
    gs.clock.date.year = c.start_year;
    // Until renamed, the outfit carries the commander's name — it
    // reads far better in the campaign registry.
    if (std.mem.eql(u8, gs.outfit_name, "Provisional Mercenary Command")) {
        gs.outfit_name = try std.fmt.allocPrint(gs.allocator(), "{s}'s Command", .{c.name});
    }
    // The boards open the day the shingle goes up.
    try contract_market.refresh(gs);
    try contract_market.refreshListings(gs);
    try contract_market.refreshCandidates(gs);
    return .{};
}

test "foundHq produces an HQ with exactly the facilities from prepareHq" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 8101 });
    defer gs.deinit();
    _ = try createCommander(&gs, "T", .LC, .line_officer);

    const prepared_field = try prepareHq(&gs, "Frontier", .field, "alkaid");
    const field_id = try foundHq(&gs, "Frontier", .field, "alkaid");
    const actual_field = gs.hqs.getPtr(field_id).?;
    try std.testing.expectEqual(prepared_field.facilities.items.len, actual_field.facilities.items.len);
    for (prepared_field.facilities.items, actual_field.facilities.items) |exp, got| {
        try std.testing.expectEqual(exp.kind, got.kind);
        try std.testing.expectEqual(exp.level, got.level);
    }

    const prepared_regional = try prepareHq(&gs, "Second", .regional, "skye");
    const regional_id = try foundHq(&gs, "Second", .regional, "skye");
    const actual_regional = gs.hqs.getPtr(regional_id).?;
    try std.testing.expectEqual(prepared_regional.facilities.items.len, actual_regional.facilities.items.len);
    for (prepared_regional.facilities.items, actual_regional.facilities.items) |exp, got| {
        try std.testing.expectEqual(exp.kind, got.kind);
        try std.testing.expectEqual(exp.level, got.level);
    }
}

test "createCommander yields the same commander, HQ, staff and stock regardless of clock year" {
    // execCreateCommander sets the start year after createCommander succeeds;
    // this test verifies that the founding output is independent of the
    // clock's year value so the two paths always agree.
    var gs1 = GameState.init(std.testing.allocator, .{ .seed = 8102 });
    defer gs1.deinit();
    var gs2 = GameState.init(std.testing.allocator, .{ .seed = 8102 });
    defer gs2.deinit();

    _ = try createCommander(&gs1, "T", .LC, .quartermaster);

    // Set the year first to prove createCommander is clock-independent.
    gs2.clock.date.year = 3025;
    _ = try createCommander(&gs2, "T", .LC, .quartermaster);

    // Commander fields must match.
    try std.testing.expect(gs1.commander != null);
    try std.testing.expect(gs2.commander != null);
    try std.testing.expectEqualStrings(gs1.commander.?.name, gs2.commander.?.name);
    try std.testing.expectEqual(gs1.commander.?.origin, gs2.commander.?.origin);
    try std.testing.expectEqual(gs1.commander.?.profession, gs2.commander.?.profession);

    // Each state has exactly one HQ; it must land on the same planet.
    try std.testing.expectEqual(@as(usize, 1), gs1.hqs.count());
    try std.testing.expectEqual(@as(usize, 1), gs2.hqs.count());
    const hq1 = gs1.hqs.values()[0];
    const hq2 = gs2.hqs.values()[0];
    try std.testing.expectEqualStrings(hq1.planet_key, hq2.planet_key);
    try std.testing.expectEqual(hq1.tier, hq2.tier);
    try std.testing.expectEqual(hq1.facilities.items.len, hq2.facilities.items.len);

    // Recruited staff count must match.
    try std.testing.expectEqual(gs1.people.count(), gs2.people.count());

    // Starter stock must match for every part family.
    const site1: types.Site = .{ .hq = gs1.seat() };
    const site2: types.Site = .{ .hq = gs2.seat() };
    for (part_mod.component_keys) |key| {
        try std.testing.expectEqual(gs1.stockCount(site1, key), gs2.stockCount(site2, key));
    }
    for (part_mod.munition_keys) |key| {
        try std.testing.expectEqual(gs1.stockCount(site1, key), gs2.stockCount(site2, key));
    }
}

test "a failed commander creation leaves the clock year untouched" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    var gs = GameState.init(failing.allocator(), .{ .seed = 8103 });
    defer gs.deinit();
    const initial_year = gs.clock.date.year;

    try std.testing.expectError(error.OutOfMemory, commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster, .start_year = 3040 } }));
    try std.testing.expectEqual(initial_year, gs.clock.date.year);
}

test "a failed createCommander leaves state and RNG unchanged" {
    const digest = @import("digest.zig");

    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 8104 });

    const before = digest.stateHash(&gs);

    // Block every allocation. createCommander's first allocation (the
    // commander name dupe) must fail before anything commits.
    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;

    try std.testing.expectError(error.OutOfMemory, createCommander(&gs, "T", .LC, .line_officer));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
}

test "the start year sets the calendar and gates the catalogue" {
    const chassis_mod = @import("../domain/chassis.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1216 });
    defer gs.deinit();
    try std.testing.expectError(commands.Error.BadYear, commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster, .start_year = 2800 } }));
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster, .start_year = 3010 } });
    try std.testing.expectEqual(@as(u16, 3010), gs.clock.date.year);
    _ = try commands.execute(&gs, .{ .new_company = "Alpha" });
    var it = gs.units.iterator();
    while (it.next()) |e| {
        const c = chassis_mod.find(e.value_ptr.chassis_key).?;
        try std.testing.expect(c.intro_year <= 3010);
    }
    for (gs.market_listings.items) |l| if (l.kind == .unit) {
        try std.testing.expect(chassis_mod.find(l.item_key).?.intro_year <= 3010);
    };
}
