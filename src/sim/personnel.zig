//! Personnel bookkeeping that spans people and forces (Stage 12B.4).
//! Mirrors MekHQ `personnel/ranks` + the AtB "commander/lance leader"
//! designations: ranks follow seats and experience unless pinned.

const std = @import("std");
const types = @import("../domain/types.zig");
const person_mod = @import("../domain/person.zig");
const rank_mod = @import("../domain/rank.zig");
const award_mod = @import("../domain/award.zig");
const chassis_mod = @import("../domain/chassis.zig");
const GameState = @import("state.zig").GameState;
const company_gen = @import("../gen/company_gen.zig");

/// Someone leaves the outfit (12C.2): status set, every seat vacated, and
/// the departure payout posted to the outfit as payroll ("severance") —
/// `share_bp` of the full amount (a firing pays half, a notice or a
/// retirement all of it). Returns what was paid.
pub fn depart(gs: *GameState, person_id: types.PersonId, status: person_mod.Status, share_bp: types.Bp, note: []const u8) !types.CBills {
    const p = gs.person(person_id) orelse return 0;
    p.status = status;
    var uit = gs.units.iterator();
    while (uit.next()) |ue| {
        if (ue.value_ptr.pilot == person_id) ue.value_ptr.pilot = .none;
        if (ue.value_ptr.tech == person_id) ue.value_ptr.tech = .none;
    }
    const owed = types.applyBp(p.severance(gs.clock.day_index), share_bp);
    if (owed > 0) try gs.postTransaction(.{ .day = gs.clock.day_index, .amount = -owed, .category = .payroll, .company = gs.companyOf(p.assigned_force), .note = note });
    return owed;
}

/// One line of a company's manning table (MekHQ: the personnel-count
/// panel plus the astech/medic pool "full complement" numbers).
pub const Need = struct { role: person_mod.Role, need: u32, why: []const u8 };

/// Roles MekHQ treats as a pool rather than as individuals on a market:
/// astechs and medics are unskilled labour, hired to complement on demand.
pub fn isPooledRole(role: person_mod.Role) bool {
    return role == .astech or role == .medic;
}

/// What a company needs in every role, from its hulls on hand and in
/// transit to it; mirrors the starter generator's ratios
/// (`company_gen.supportStaffFor`).
pub fn manningNeeds(gs: *GameState, company: types.ForceId) [14]Need {
    var meks: u32 = 0;
    var vehicles: u32 = 0;
    var platoons: u32 = 0;
    var mash: u32 = 0;
    var fighters: u32 = 0;
    var uit = gs.units.iterator();
    while (uit.next()) |e| {
        const u = e.value_ptr;
        if (u.status == .destroyed) continue;
        var ours = gs.companyOf(u.force) == company;
        if (!ours) for (gs.unit_transfers.items) |t| if (t.unit == u.id and t.to_company == company) {
            ours = true;
        };
        if (!ours) continue;
        switch (u.kind) {
            .mek => meks += 1,
            .infantry => platoons += 1,
            .aerospace => fighters += 1,
            .dropship, .jumpship => {}, // crewed by ship crews at the berth, not the company
            .mash => {
                vehicles += 1;
                mash += 1;
            },
            else => vehicles += 1,
        }
    }
    const combat = meks + vehicles + platoons;
    const staff = company_gen.supportStaffFor(meks, combat);
    return .{
        .{ .role = .mekwarrior, .need = meks, .why = "one per mek" },
        .{ .role = .vehicle_crew, .need = vehicles, .why = "one per truck, rig or ambulance" },
        .{ .role = .infantry, .need = platoons, .why = "one per security platoon" },
        .{ .role = .aero_pilot, .need = fighters, .why = "one per fighter" },
        .{ .role = .tech_aero, .need = fighters, .why = "one per fighter" },
        .{ .role = .tech_mek, .need = staff.techs, .why = "one per mek" },
        .{ .role = .astech, .need = staff.astechs, .why = "six per mek tech (hours)" },
        .{ .role = .tech_mechanic, .need = vehicles / 2, .why = "one per two vehicles" },
        .{ .role = .doctor, .need = staff.doctors, .why = "one per 25 combat crew" },
        .{ .role = .medic, .need = staff.medics + (if (mash > 0) @as(u32, 4) else 0), .why = "each covers 5 patients and staffs a MASH bed; four per doctor, four more with the MASH lance" },
        .{ .role = .admin_command, .need = 1, .why = "company office" },
        .{ .role = .admin_logistics, .need = 1, .why = "company office" },
        .{ .role = .admin_transport, .need = 1, .why = "company office" },
        .{ .role = .admin_hr, .need = staff.admins -| 3, .why = "one per 10 combat crew beyond the office" },
    };
}

/// People of `role` on a company's books (active or wounded).
pub fn manningHave(gs: *GameState, company: types.ForceId, role: person_mod.Role) u32 {
    var have: u32 = 0;
    var pit = gs.people.iterator();
    while (pit.next()) |e| {
        const p = e.value_ptr;
        if (p.role != role or (p.status != .active and p.status != .wounded)) continue;
        if (gs.companyOf(p.assigned_force) == company) have += 1;
    }
    return have;
}


/// Kill credits (12B.5): the enemy BV destroyed in an engagement becomes
/// whole kills (one per ~1000 BV, the average 3025 mek), each handed to
/// an engaged pilot at random weighted by their hull's BV and gunnery; the
/// BV itself is split by the same weights. Every engaged pilot logs a
/// battle. Returns kills credited.
pub fn creditKills(gs: *GameState, engaged: []const types.UnitId, destroyed_bv: i64) !u32 {
    var weights: std.ArrayListUnmanaged(u32) = .empty;
    defer weights.deinit(gs.allocator());
    var pilots: std.ArrayListUnmanaged(types.PersonId) = .empty;
    defer pilots.deinit(gs.allocator());
    var total_w: u64 = 0;
    for (engaged) |uid| {
        const u = gs.unit(uid) orelse continue;
        const p = gs.person(u.pilot) orelse continue;
        if (p.status != .active and p.status != .wounded) continue;
        p.battles += 1;
        const bv: u32 = if (chassis_mod.find(u.chassis_key)) |c| c.bv else 500;
        const gunnery: u32 = p.skill(p.role.primarySkill()) orelse 4;
        const w: u32 = @max(1, bv * (9 - @min(8, gunnery)) / 100);
        try weights.append(gs.allocator(), w);
        try pilots.append(gs.allocator(), p.id);
        total_w += w;
    }
    if (pilots.items.len == 0 or destroyed_bv <= 0) return 0;
    // BV shares.
    for (pilots.items, weights.items) |pid, w| {
        if (gs.person(pid)) |p| p.kill_bv += @intCast(@divTrunc(destroyed_bv * @as(i64, w), @as(i64, @intCast(total_w))));
    }
    // Whole kills, weighted draws.
    const kills: u32 = @intCast(@divTrunc(destroyed_bv + 500, 1000));
    for (0..kills) |_| {
        var pick = gs.rng.random(.battle).uintLessThan(u64, total_w);
        for (pilots.items, weights.items) |pid, w| {
            if (pick < w) {
                if (gs.person(pid)) |p| p.kills += 1;
                break;
            }
            pick -= w;
        }
    }
    return kills;
}

/// Hand out every award whose threshold a person has crossed (12B.5).
/// Returns how many were pinned on.
pub fn checkAwards(gs: *GameState, person_id: types.PersonId) !u32 {
    const p = gs.person(person_id) orelse return 0;
    if (p.status != .active and p.status != .wounded) return 0;
    var n: u32 = 0;
    for (award_mod.table) |a| {
        if (p.hasAward(a.key)) continue;
        if (p.counter(a.kind, gs.clock.day_index) < a.threshold) continue;
        try p.awards.append(gs.allocator(), a.key);
        p.morale = @intCast(@min(100, @as(u32, p.morale) + a.morale));
        n += 1;
        try gs.log(.rotation, .{ .company = gs.companyOf(p.assigned_force), .hq = p.posted_hq }, "[award] {s} receives the {s} ({s} {d})", .{ try p.rankedName(gs.allocator()), a.name, @tagName(a.kind), p.counter(a.kind, gs.clock.day_index) });
    }
    return n;
}

/// Payday sweep: service awards for everyone.
pub fn checkAllAwards(gs: *GameState) !u32 {
    var n: u32 = 0;
    var ids: std.ArrayListUnmanaged(types.PersonId) = .empty;
    defer ids.deinit(gs.allocator());
    var it = gs.people.iterator();
    while (it.next()) |e| try ids.append(gs.allocator(), e.value_ptr.id);
    for (ids.items) |id| n += try checkAwards(gs, id);
    return n;
}

/// Recompute every unpinned rank: the best fit combat crew in a company is
/// its commander (Captain), the best in each line or air lance its leader
/// (Lieutenant), everyone else ranks by experience. Company and lance
/// `commander` fields follow. Returns promotions made.
pub fn refreshRanks(gs: *GameState) !u32 {
    var changed: u32 = 0;
    // Start everyone unpinned at their experience rank.
    var pit = gs.people.iterator();
    while (pit.next()) |e| {
        const p = e.value_ptr;
        if (p.status != .active or p.rank_pinned) continue;
        const r = rank_mod.Rank.forExperience(p.experience());
        if (p.rank != r) {
            if (@intFromEnum(r) > @intFromEnum(p.rank)) changed += 1;
            p.rank = r;
        }
    }
    // Seats: lance leaders, then company commanders (the best of the leaders).
    var fit = gs.forces.iterator();
    while (fit.next()) |fe| {
        const f = fe.value_ptr;
        if (f.echelon != .company) continue;
        var company_best: types.PersonId = .none;
        var company_best_skill: u8 = 99;
        for (f.children.items) |cid| {
            const lance = gs.force(cid) orelse continue;
            if (lance.echelon != .lance and lance.echelon != .air_lance) continue;
            var best: types.PersonId = .none;
            var best_skill: u8 = 99;
            for (lance.units.items) |uid| {
                const u = gs.unit(uid) orelse continue;
                const p = gs.person(u.pilot) orelse continue;
                if (p.status != .active) continue;
                const skill = p.skill(p.role.primarySkill()) orelse 7;
                if (skill < best_skill or (skill == best_skill and p.xp > (gs.person(best) orelse p).xp)) {
                    best = p.id;
                    best_skill = skill;
                }
            }
            lance.commander = best;
            if (gs.person(best)) |leader| {
                if (!leader.rank_pinned and @intFromEnum(leader.rank) < @intFromEnum(rank_mod.Rank.lieutenant)) {
                    leader.rank = .lieutenant;
                    changed += 1;
                }
                if (best_skill < company_best_skill) {
                    company_best = best;
                    company_best_skill = best_skill;
                }
            }
        }
        f.commander = company_best;
        if (gs.person(company_best)) |cmdr| if (!cmdr.rank_pinned and @intFromEnum(cmdr.rank) < @intFromEnum(rank_mod.Rank.captain)) {
            cmdr.rank = .captain;
            changed += 1;
        };
    }
    return changed;
}

test "ranks follow seats: a lance leader is a lieutenant, the company commander a captain, the rest by experience" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1234 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    const co = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha");
    _ = try refreshRanks(&gs);
    const cmdr = gs.force(co).?.commander;
    try std.testing.expect(cmdr != .none);
    try std.testing.expectEqual(rank_mod.Rank.captain, gs.person(cmdr).?.rank);
    var lieutenants: u32 = 0;
    var officers: u32 = 0;
    var pit = gs.people.iterator();
    while (pit.next()) |e| {
        if (e.value_ptr.rank == .lieutenant) lieutenants += 1;
        if (e.value_ptr.rank.isOfficer()) officers += 1;
    }
    try std.testing.expect(lieutenants >= 3);
    try std.testing.expectEqual(lieutenants + 1, officers);
    // A pinned rank survives the refresh; pay follows rank.
    const tech = blk: {
        var it = gs.people.iterator();
        while (it.next()) |e| if (e.value_ptr.role == .tech_mek) break :blk e.value_ptr;
        unreachable;
    };
    const before = tech.monthlySalary();
    tech.rank = .major;
    tech.rank_pinned = true;
    _ = try refreshRanks(&gs);
    try std.testing.expectEqual(rank_mod.Rank.major, tech.rank);
    try std.testing.expect(tech.monthlySalary() > before);
}

test "12B.5: kills are credited to engaged pilots and awards follow the counters" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1235 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    const co = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha");
    var engaged: std.ArrayListUnmanaged(types.UnitId) = .empty;
    defer engaged.deinit(gs.allocator());
    var uit = gs.units.iterator();
    while (uit.next()) |e| if (e.value_ptr.kind == .mek and gs.companyOf(e.value_ptr.force) == co) try engaged.append(gs.allocator(), e.value_ptr.id);
    const kills = try creditKills(&gs, engaged.items, 5_400);
    try std.testing.expectEqual(@as(u32, 5), kills);
    var total_kills: u32 = 0;
    var total_bv: u32 = 0;
    var battles: u32 = 0;
    var pit = gs.people.iterator();
    while (pit.next()) |e| {
        total_kills += e.value_ptr.kills;
        total_bv += e.value_ptr.kill_bv;
        if (e.value_ptr.battles == 1) battles += 1;
    }
    try std.testing.expectEqual(@as(u32, 5), total_kills);
    try std.testing.expect(total_bv > 5_000 and total_bv <= 5_400);
    try std.testing.expectEqual(@as(u32, @intCast(engaged.items.len)), battles);
    // Awards: whoever has a kill gets First Blood; five kills makes an Ace.
    var ace = gs.person(gs.unit(engaged.items[0]).?.pilot).?;
    ace.kills = 5;
    _ = try checkAwards(&gs, ace.id);
    try std.testing.expect(ace.hasAward("first_blood") and ace.hasAward("ace") and !ace.hasAward("double_ace"));
    const again = try checkAwards(&gs, ace.id);
    try std.testing.expectEqual(@as(u32, 0), again); // no duplicates
}

test "12C.2: severance is a month per year served, capped; a firing pays half; under a year nothing" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 122 });
    defer gs.deinit();
    const t = @import("../domain/tuning.zig").t.person;
    const rookie = try gs.hirePerson("New", "Hand", .astech);
    gs.clock.day_index = 200;
    try std.testing.expectEqual(@as(types.CBills, 0), gs.person(rookie).?.severance(200));
    const vet = try gs.hirePerson("Old", "Hand", .mekwarrior);
    gs.person(vet).?.recruited_day = 0;
    gs.clock.day_index = 3 * 365;
    const pay = gs.person(vet).?.monthlySalary();
    try std.testing.expectEqual(pay * 3 * t.severance_months_per_year, gs.person(vet).?.severance(gs.clock.day_index));
    gs.clock.day_index = 40 * 365;
    try std.testing.expectEqual(pay * t.severance_cap_months, gs.person(vet).?.severance(gs.clock.day_index));
    gs.clock.day_index = 2 * 365;
    const funds = gs.funds;
    const paid = try depart(&gs, vet, .resigned, t.fire_severance_bp, "severance (fired)");
    try std.testing.expectEqual(pay, paid); // half of two months
    try std.testing.expectEqual(funds - pay, gs.funds);
    try std.testing.expectEqual(person_mod.Status.resigned, gs.person(vet).?.status);
}
