//! Personnel bookkeeping that spans people and forces (Stage 12B.4):
//! recruiting and posting people, and ranks, shares, awards and the
//! manning table. Adaptation of MekHQ `personnel/ranks`, the AtB
//! "commander/lance leader" designations and the AtB personnel
//! generation: ranks follow seats and experience unless pinned.

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const person_mod = @import("../domain/person.zig");
const rank_mod = @import("../domain/rank.zig");
const award_mod = @import("../domain/award.zig");
const chassis_mod = @import("../domain/chassis.zig");
const GameState = @import("state.zig").GameState;
const founding = @import("founding.zig");
const hq_ops = @import("hq_ops.zig");
const company_gen = @import("../gen/company_gen.zig");
const person_gen = @import("../gen/person_gen.zig");
const rng_mod = @import("rng.zig");
const maintenance = @import("maintenance.zig");
const toe = @import("toe.zig");
const posture = @import("posture.zig");
const sites = @import("sites.zig");
const commands = @import("commands.zig");

/// Recruit a randomly generated person (AtB-style: experience on 2d6,
/// skills from the band, names from the tables). No signing bonus: that
/// belongs to hiring-hall candidates.
pub fn recruitGenerated(gs: *GameState, role: person_mod.Role, hq_id: types.HqId, stream: rng_mod.Stream) !types.PersonId {
    const spec = person_gen.generateWithBonus(&gs.rng, stream, role, recruitBonus(gs, hq_id));
    return hireFromSpec(gs, spec);
}

/// Put a generated person on the books (recruiting, or hiring a hall
/// candidate).
pub fn hireFromSpec(gs: *GameState, spec: person_gen.GeneratedPerson) !types.PersonId {
    const role = spec.role;
    const alloc = gs.allocator();
    var p: person_mod.Person = .{
        .id = @enumFromInt(0), // overwritten by commitPerson
        .first_name = try alloc.dupe(u8, spec.first),
        .last_name = try alloc.dupe(u8, spec.last),
        .role = role,
        .recruited_day = gs.clock.day_index,
    };
    if (spec.callsign) |c| p.callsign = try alloc.dupe(u8, c);
    p.setBirthdayFromAge(gs.clock.day_index, spec.age);

    // Set the generated experience band.
    switch (role) {
        .mekwarrior => {
            try p.skills.put(alloc, .gunnery_mek, spec.primary_skill);
            try p.skills.put(alloc, .piloting_mek, spec.secondary_skill);
        },
        .vehicle_crew => {
            try p.skills.put(alloc, .gunnery_vee, spec.primary_skill);
            try p.skills.put(alloc, .driving_vee, spec.secondary_skill);
        },
        .aero_pilot => {
            try p.skills.put(alloc, .gunnery_aero, spec.primary_skill);
            try p.skills.put(alloc, .piloting_aero, spec.secondary_skill);
        },
        .ba_trooper, .infantry => try p.skills.put(alloc, .small_arms, spec.primary_skill),
        .tech_mek, .tech_ba => try p.skills.put(alloc, .tech_mek, spec.primary_skill),
        .tech_mechanic => try p.skills.put(alloc, .tech_mechanic, spec.primary_skill),
        .tech_aero => try p.skills.put(alloc, .tech_aero, spec.primary_skill),
        .astech => try p.skills.put(alloc, .astech, spec.primary_skill),
        .doctor => try p.skills.put(alloc, .doctor, spec.primary_skill),
        .medic => try p.skills.put(alloc, .medtech, spec.primary_skill),
        .admin_command, .admin_logistics, .admin_transport, .admin_hr, .admin_finance => try p.skills.put(alloc, .admin, spec.primary_skill),
        .dropship_crew, .jumpship_crew => {},
    }
    return gs.commitPerson(p);
}

/// Why posting a person to an HQ is blocked (rule 21: one named predicate for
/// "may this person be posted here"; `postToHq` and any view eligibility call
/// it before acting).
pub const PostBlock = enum { unknown_person, unknown_hq };

pub fn canPostToHq(gs: *GameState, person_id: types.PersonId, hq_id: types.HqId) ?PostBlock {
    if (gs.person(person_id) == null) return .unknown_person;
    if (gs.hqs.getPtr(hq_id) == null) return .unknown_hq;
    return null;
}

/// Post a person to an HQ's staff (off any force). Vacates any pilot/tech
/// seat they hold so no unit is left with a dangling assignment (rule 20).
pub fn postToHq(gs: *GameState, person_id: types.PersonId, hq_id: types.HqId) !void {
    if (canPostToHq(gs, person_id, hq_id)) |why| return switch (why) {
        .unknown_person => error.UnknownPerson,
        .unknown_hq => error.UnknownHq,
    };
    const p = gs.person(person_id).?;
    vacateSeats(gs, person_id);
    p.posted_hq = hq_id;
    p.assigned_force = .none;
    hq_ops.refreshHqStaffing(gs);
}

/// Recruit-quality bonus on the 2d6 experience roll at one HQ: its hiring
/// hall and a staffed HR office find better people.
pub fn recruitBonus(gs: *GameState, hq_id: types.HqId) i32 {
    const hq = gs.hqs.getPtr(hq_id) orelse return 0;
    var bonus: i32 = hq.effectiveFacilityLevel(.hiring_hall);
    if (hq_ops.hqStaff(gs, hq.id, .admin_hr).count >= tuning.person.recruit_hr_admins) bonus += 1;
    // A famous outfit draws a better class of walk-in.
    if ((@import("rating.zig").currentIndex(gs) catch 0) >= tuning.rating.recruit_bonus_index) bonus += 1; // best-effort: OOM skips recruit quality bonus
    return @min(bonus, 4);
}

/// Morale across the whole outfit: a contract's ending is felt
/// by everyone on the payroll, not only the company that fought it.
pub fn adjustMoraleAll(gs: *GameState, delta: i32) u32 {
    var touched: u32 = 0;
    var it = gs.people.iterator();
    while (it.next()) |e| {
        const p = e.value_ptr;
        if (!p.isOnBooks()) continue;
        p.addMorale(delta);
        touched += 1;
    }
    return touched;
}

/// Payday: everyone's stake brought up to date. Returns how many
/// people gained shares.
pub fn refreshShares(gs: *GameState) u32 {
    var gained: u32 = 0;
    var it = gs.people.iterator();
    while (it.next()) |e| {
        const p = e.value_ptr;
        const due = p.sharesDue(gs.clock.day_index);
        if (due > p.shares) gained += 1;
        p.shares = due;
    }
    return gained;
}

/// Contract completed: `gs.share_profit_bp` of what the contract
/// brought in, split pro rata across every shareholder on the books and
/// paid as payroll "profit shares". Returns the pool paid.
pub fn payShares(gs: *GameState, contract_id: types.ContractId, company: types.ForceId) !types.CBills {
    var income: types.CBills = 0;
    for (gs.ledger.transactions.items) |t| if (t.contract == contract_id) {
        income += t.amount;
    };
    if (income <= 0 or gs.share_profit_bp == 0) return 0;
    var total_shares: u32 = 0;
    var it = gs.people.iterator();
    while (it.next()) |e| {
        const p = e.value_ptr;
        if (!p.isOnBooks()) continue;
        total_shares += p.shares;
    }
    if (total_shares == 0) return 0;
    const pool = types.applyBp(income, gs.share_profit_bp);
    const per_share = @divTrunc(pool, @as(types.CBills, total_shares));
    if (per_share <= 0) return 0;
    var paid: types.CBills = 0;
    var holders: u32 = 0;
    var it2 = gs.people.iterator();
    while (it2.next()) |e| {
        const p = e.value_ptr;
        if (!p.isOnBooks() or p.shares == 0) continue;
        paid += per_share * p.shares;
        holders += 1;
        p.addMorale(3);
    }
    try gs.postTransaction(.{ .day = gs.clock.day_index, .amount = -paid, .category = .payroll, .company = company, .contract = contract_id, .note = "profit shares" });
    try gs.log(.contract, .{ .company = company, .contract = contract_id }, "[shares] {d} c-bills of {d} contract income ({d}%) paid to {d} shareholders — {d} shares at {d} each (morale +3)", .{
        paid, income, types.bpPercent(gs.share_profit_bp), holders, total_shares, per_share,
    });
    return paid;
}

/// Clear every pilot/tech slot that points at this person (rule 20: one owner
/// for seat-vacating; called by `depart`, `transferPerson` and `postToHq`).
fn vacateSeats(gs: *GameState, person_id: types.PersonId) void {
    var uit = gs.units.iterator();
    while (uit.next()) |ue| {
        if (ue.value_ptr.pilot == person_id) ue.value_ptr.pilot = .none;
        if (ue.value_ptr.tech == person_id) ue.value_ptr.tech = .none;
    }
}

/// Someone leaves the outfit: status set, every seat vacated, and
/// the departure payout posted to the outfit as payroll ("severance") —
/// `share_bp` of the full amount (a firing pays half, a notice or a
/// retirement all of it). Returns what was paid.
pub fn depart(gs: *GameState, person_id: types.PersonId, status: person_mod.Status, share_bp: types.Bp, note: []const u8) !types.CBills {
    const p = gs.person(person_id) orelse return 0;
    p.status = status;
    p.departed_day = gs.clock.day_index;
    vacateSeats(gs, person_id);
    // The posting stays on the record (who walked from which desk); the
    // staffing count is derived from active people, refreshed here so no
    // caller has to remember.
    hq_ops.refreshHqStaffing(gs);
    const owed = severanceOwed(gs, person_id, share_bp);
    if (owed > 0) try gs.postTransaction(.{ .day = gs.clock.day_index, .amount = -owed, .category = .payroll, .company = gs.companyOf(p.assigned_force), .note = note });
    return owed;
}

/// How far from ready a company is for an offer: the points the
/// candidates table sorts by. Lower is readier.
pub fn readinessPenalty(crew: CrewStats, depot_hulls: u32, transit_days: u32) i32 {
    const t = tuning.person;
    return @as(i32, @intCast(depot_hulls)) * t.readiness_depot_weight +
        @as(i32, @intCast(crew.spent)) * t.readiness_spent_weight +
        @as(i32, @intCast(crew.wounded)) * t.readiness_wounded_weight +
        @as(i32, @intCast(crew.avg_fatigue / t.readiness_fatigue_divisor)) +
        @as(i32, @intCast(transit_days / t.readiness_transit_divisor)) -
        @as(i32, @intCast(crew.avg_morale / t.readiness_morale_divisor));
}

/// What letting someone go costs at a share of the full payout:
/// `depart` pays it and the desk quotes it from the same function.
pub fn severanceOwed(gs: *GameState, person_id: types.PersonId, share_bp: types.Bp) types.CBills {
    const p = gs.person(person_id) orelse return 0;
    return types.applyBp(p.severance(gs.clock.day_index), share_bp);
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
/// transit to it: `company_gen.staffNeeds` is the table, this counts the
/// hulls it is read for.
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
    var out: [14]Need = undefined;
    for (company_gen.staffNeeds(.{ .meks = meks, .vehicles = vehicles, .platoons = platoons, .fighters = fighters, .mash = mash }), 0..) |n, i| {
        out[i] = .{ .role = n.role, .need = n.need, .why = n.why };
    }
    return out;
}

/// One row of the manning table: the need, who fills it, and the gap.
pub const ManningLine = struct { role: person_mod.Role, have: u32, need: u32, open: u32, why: []const u8 };

/// The manning table: every need against who is on the payroll.
/// The checklist warns from it, the raise wizard and the Forces pane
/// print it.
pub fn manningLines(gs: *GameState, company: types.ForceId) [14]ManningLine {
    var out: [14]ManningLine = undefined;
    for (manningNeeds(gs, company), 0..) |n, i| {
        const have = manningHave(gs, company, n.role);
        out[i] = .{ .role = n.role, .have = have, .need = n.need, .open = n.need -| have, .why = n.why };
    }
    return out;
}

/// A company's people in one pass: who is on the books under it, how
/// tired and how happy on average, and the counts the readiness board
/// prints. The battle's company modifiers, the rotation reset, the
/// Forces board and the readiness board all read this one census.
pub const CrewStats = struct {
    heads: u32 = 0,
    avg_fatigue: u8 = 0,
    avg_morale: u8 = 50,
    tired: u32 = 0,
    spent: u32 = 0,
    wounded: u32 = 0,
    permanent: u32 = 0,
    training: u32 = 0,
    banked_xp: u32 = 0,
};

pub fn companyCrewStats(gs: *GameState, company: types.ForceId) CrewStats {
    var st: CrewStats = .{};
    var fat: u64 = 0;
    var mor: u64 = 0;
    var pit = gs.people.iterator();
    while (pit.next()) |e| {
        const p = e.value_ptr;
        if (!p.isOnBooks() or !toe.personInCompany(gs, p, company)) continue;
        st.heads += 1;
        fat += p.fatigue;
        mor += p.morale;
        if (p.fatigueBand() != .fresh) st.tired += 1;
        if (p.isUnfit()) st.spent += 1;
        if (p.status == .wounded) st.wounded += 1;
        if (p.permanentPenalty() > 0) st.permanent += 1;
        if (p.training != null) st.training += 1;
        if (p.role.isCombat()) st.banked_xp += p.xp;
    }
    if (st.heads > 0) {
        st.avg_fatigue = @intCast(fat / st.heads);
        st.avg_morale = @intCast(mor / st.heads);
    }
    return st;
}

/// Tech hours: what a company's hulls want per week against
/// what its techs, at their skill and with their astech teams, can give.
pub const TechHours = struct { needed: u32, have: u32 };

pub fn techHours(gs: *GameState, company: types.ForceId) TechHours {
    var needed: u32 = 0;
    var have: u32 = 0;
    var uit = gs.units.iterator();
    while (uit.next()) |e| {
        const u = e.value_ptr;
        if (u.isParked() or u.kind == .infantry or gs.companyOf(u.force) != company) continue;
        needed += if (gs.person(u.tech)) |t| maintenance.techHoursFor(gs, t, u) else maintenance.hullHours(gs, u);
    }
    var pit = gs.people.iterator();
    while (pit.next()) |e| {
        const p = e.value_ptr;
        if (!p.role.isTech() or !p.isAvailable(gs.clock.day_index) or gs.companyOf(p.assigned_force) != company) continue;
        have += maintenance.techHoursAvailable(gs, p);
    }
    return .{ .needed = needed, .have = have };
}

/// People of `role` on a company's books (active or wounded).
pub fn manningHave(gs: *GameState, company: types.ForceId, role: person_mod.Role) u32 {
    var have: u32 = 0;
    var pit = gs.people.iterator();
    while (pit.next()) |e| {
        const p = e.value_ptr;
        if (p.role != role or !p.isOnBooks()) continue;
        if (gs.companyOf(p.assigned_force) == company) have += 1;
    }
    return have;
}

/// Kill credits: the enemy BV destroyed in an engagement becomes
/// whole kills (one per ~1000 BV, the average 3025 mek), each handed to
/// an engaged pilot at random weighted by their hull's BV and gunnery; the
/// BV itself is split by the same weights. Every engaged pilot logs a
/// battle. Returns kills credited.
pub fn creditKills(gs: *GameState, engaged: []const types.UnitId, destroyed_bv: i64) !u32 {
    var weights: std.ArrayListUnmanaged(u32) = .empty;
    defer weights.deinit(gs.scratch());
    var pilots: std.ArrayListUnmanaged(types.PersonId) = .empty;
    defer pilots.deinit(gs.scratch());
    var total_w: u64 = 0;
    for (engaged) |uid| {
        const u = gs.unit(uid) orelse continue;
        const p = gs.person(u.pilot) orelse continue;
        if (!p.isOnBooks()) continue;
        p.battles += 1;
        const bv: u32 = if (chassis_mod.find(u.chassis_key)) |c| c.bv else 500;
        const gunnery: u32 = p.skill(p.role.primarySkill()) orelse 4;
        const w: u32 = @max(1, bv * (9 - @min(8, gunnery)) / 100);
        try weights.append(gs.scratch(), w);
        try pilots.append(gs.scratch(), p.id);
        total_w += w;
    }
    if (pilots.items.len == 0 or destroyed_bv <= 0) return 0;
    // BV shares.
    for (pilots.items, weights.items) |pid, w| {
        if (gs.person(pid)) |p| p.kill_bv += @intCast(@divTrunc(destroyed_bv * @as(i64, w), @as(i64, @intCast(total_w))));
    }
    // Whole kills, weighted draws.
    const kills: u32 = @import("battle.zig").estimatedKills(destroyed_bv);
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

/// Hand out every award whose threshold a person has crossed.
/// Returns how many were pinned on.
pub fn checkAwards(gs: *GameState, person_id: types.PersonId) !u32 {
    const p = gs.person(person_id) orelse return 0;
    if (!p.isOnBooks()) return 0;
    var n: u32 = 0;
    for (award_mod.table) |a| {
        if (p.hasAward(a.key)) continue;
        if (p.counter(a.kind, gs.clock.day_index) < a.threshold) continue;
        try p.awards.append(gs.allocator(), a.key);
        p.last_award_day = gs.clock.day_index; // a recent award is a loyalty modifier
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
    defer ids.deinit(gs.scratch());
    var it = gs.people.iterator();
    while (it.next()) |e| try ids.append(gs.scratch(), e.value_ptr.id);
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
            if (!lance.isCombatLance()) continue;
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

// ---- C4b personnel command handlers moved from commands.zig ----

pub fn hire(gs: *GameState, first: []const u8, last: []const u8, role: person_mod.Role) !types.PersonId {
    return gs.hirePerson(first, last, role);
}

pub fn recruit(gs: *GameState, role: person_mod.Role) !types.PersonId {
    return recruitGenerated(gs, role, gs.homeHqFor(.none), .market);
}

pub fn fire(gs: *GameState, id: types.PersonId) !void {
    const p = gs.person(id) orelse return error.UnknownPerson;
    const paid = try depart(gs, id, .resigned, tuning.person.fire_severance_bp, "severance (fired)");
    if (paid > 0) try gs.log(.rotation, .{ .company = gs.companyOf(p.assigned_force) }, "[personnel] {s} fired — {d} c-bills severance", .{ try p.fullName(gs.allocator()), paid });
}

pub fn setOfficeStaff(gs: *GameState, hq: types.HqId, role: person_mod.Role, delta: i8) !types.PersonId {
    if (gs.hqs.getPtr(hq) == null) return error.UnknownHq;
    if (delta > 0) {
        const id = try recruitGenerated(gs, role, hq, .market);
        try postToHq(gs, id, hq);
        return id;
    }
    var last: types.PersonId = .none;
    var it = gs.people.iterator();
    while (it.next()) |e| {
        const p = e.value_ptr;
        if (p.status == .active and p.role == role and p.posted_hq == hq) last = p.id;
    }
    if (last == .none) return error.UnknownPerson;
    try fire(gs, last);
    return .none;
}

pub fn transferPerson(gs: *GameState, person_id: types.PersonId, to_force: types.ForceId) !void {
    const p = gs.person(person_id) orelse return error.UnknownPerson;
    const dest = gs.force(to_force) orelse return error.UnknownForce;
    if (gs.companyOf(p.assigned_force) == gs.companyOf(dest.id) and p.assigned_force == dest.id) return error.SameForce;
    if (posture.isCompanyDeployed(gs, gs.companyOf(p.assigned_force))) return error.PersonDeployed;
    // Vacate any seat/tech slot they hold in the old company.
    vacateSeats(gs, person_id);
    const days = sites.travelDays(gs, gs.companyOf(p.assigned_force), gs.companyOf(dest.id));
    p.assigned_force = dest.id;
    p.posted_hq = .none;
    hq_ops.refreshHqStaffing(gs);
    if (days > 0) p.leave_until_day = gs.clock.day_index + days; // in transit
}

pub fn promote(gs: *GameState, person_id: types.PersonId, rank: rank_mod.Rank, pin: bool) !void {
    const p = gs.person(person_id) orelse return error.UnknownPerson;
    const was = p.rank;
    p.rank = rank;
    p.rank_pinned = pin;
    if (!pin) _ = try refreshRanks(gs);
    try gs.log(.rotation, .{ .company = gs.companyOf(p.assigned_force), .hq = p.posted_hq }, "[rank] {s}: {s} → {s}{s} · {d} c-bills/mo", .{ try p.fullName(gs.allocator()), was.name(), p.rank.name(), if (pin) " (pinned)" else "", p.monthlySalary() });
}

// ---- C4b exec wrappers ----
const Error = commands.Error;
const Result = commands.Result;
const Command = commands.Command;

pub fn execHire(gs: *GameState, h: @FieldType(Command, "hire")) Error!Result {
    const id = hire(gs, h.first, h.last, h.role) catch |err| return @errorCast(err);
    return .{ .hired = id };
}

pub fn execRecruit(gs: *GameState, role: @FieldType(Command, "recruit")) Error!Result {
    const id = recruit(gs, role) catch |err| return @errorCast(err);
    return .{ .hired = id };
}

pub fn execFire(gs: *GameState, id: @FieldType(Command, "fire")) Error!Result {
    fire(gs, id) catch |err| return @errorCast(err);
    return .{};
}

pub fn execPromote(gs: *GameState, pr: @FieldType(Command, "promote")) Error!Result {
    promote(gs, pr.person, pr.rank, pr.pin) catch |err| return @errorCast(err);
    return .{};
}

pub fn execTransferPerson(gs: *GameState, t: @FieldType(Command, "transfer_person")) Error!Result {
    transferPerson(gs, t.person, t.to_force) catch |err| return @errorCast(err);
    return .{};
}

pub fn execPostPerson(gs: *GameState, pp: @FieldType(Command, "post_person")) Error!Result {
    postToHq(gs, pp.person, pp.hq) catch |err| return @errorCast(err);
    return .{};
}

pub fn execSetOfficeStaff(gs: *GameState, o: @FieldType(Command, "set_office_staff")) Error!Result {
    const hired = setOfficeStaff(gs, o.hq, o.role, o.delta) catch |err| return @errorCast(err);
    return .{ .hired = hired };
}

test "the recruiting bonus is the recruiting HQ's hiring hall, not the first HQ's" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7701 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .paymaster);
    const seat = gs.seat();
    const second = try founding.foundHq(&gs, "Second", .regional, "alkaid");
    for ([_]types.HqId{ seat, second }) |id| gs.hqs.getPtr(id).?.staff_assigned = 999;
    for (gs.hqs.getPtr(seat).?.facilities.items) |*f| {
        if (f.kind == .hiring_hall) f.level = 3;
    }
    for (gs.hqs.getPtr(second).?.facilities.items) |*f| {
        if (f.kind == .hiring_hall) f.level = 0;
    }
    try std.testing.expect(recruitBonus(&gs, seat) > recruitBonus(&gs, second));
}

test "ranks follow seats: a lance leader is a lieutenant, the company commander a captain, the rest by experience" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1234 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .paymaster);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
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

test "kills are credited to engaged pilots and awards follow the counters" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1235 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .paymaster);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
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

test "severance is a month per year served, capped; a firing pays half; under a year nothing" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 122 });
    defer gs.deinit();
    const t = tuning.person;
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

test "shares are paid pro rata from contract income at the configured share" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 123 });
    defer gs.deinit();
    const a = try gs.hirePerson("Two", "Shares", .mekwarrior);
    const b = try gs.hirePerson("One", "Share", .tech_mek);
    _ = try gs.hirePerson("No", "Stake", .admin_hr);
    gs.person(a).?.shares = 2;
    gs.person(b).?.shares = 1;
    const cid: types.ContractId = @enumFromInt(7);
    try gs.postTransaction(.{ .day = 0, .amount = 1_000_000, .category = .contract_payment, .contract = cid });
    try gs.postTransaction(.{ .day = 0, .amount = -100_000, .category = .breach_clawback, .contract = cid });
    gs.share_profit_bp = 3_000; // 30% of 900_000 = 270_000 → 90_000 a share
    const funds = gs.funds;
    const paid = try payShares(&gs, cid, .none);
    try std.testing.expectEqual(@as(types.CBills, 270_000), paid);
    try std.testing.expectEqual(funds - 270_000, gs.funds);
    // Nothing owed with the share at zero or no shareholders.
    gs.share_profit_bp = 0;
    try std.testing.expectEqual(@as(types.CBills, 0), try payShares(&gs, cid, .none));
}

test "a raised company is an empty skeleton; hulls bought for it land in a lance or ship with the map transit; halls crew it" {
    const unit_mod = @import("../domain/unit.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const hq = gs.seat();
    gs.hqs.getPtr(hq).?.funds = 50_000_000;
    const co = (try commands.execute(&gs, .{ .raise_company = .{ .name = "Bravo", .hq = hq } })).created_force;
    // The slot is taken: a second one is refused.
    try std.testing.expectError(commands.Error.CapacityFull, commands.execute(&gs, .{ .raise_company = .{ .name = "Charlie", .hq = hq } }));
    var line: u32 = 0;
    var support: u32 = 0;
    var fit = gs.forces.iterator();
    while (fit.next()) |e| {
        const f = e.value_ptr;
        if (gs.companyOf(f.id) != co) continue;
        try std.testing.expectEqual(@as(usize, 0), f.units.items.len);
        if (f.echelon == .lance) line += 1;
        if (f.echelon == .support_lance) support += 1;
    }
    try std.testing.expectEqual(gs.hqs.getPtr(hq).?.capacity().lances_per_company, @as(u8, @intCast(line)));
    try std.testing.expectEqual(@as(u32, 4), support);
    try std.testing.expectEqual(hq, gs.force(co).?.supplying_hq);

    // A mek on the home board: bought straight into the first lance.
    var first_lance: types.ForceId = .none;
    for (gs.force(co).?.children.items) |cid| if (gs.force(cid).?.echelon == .lance and first_lance == .none) {
        first_lance = cid;
    };
    var mek_listing: ?usize = null;
    for (gs.market_listings.items, 0..) |l, i| if (l.kind == .unit and l.hq == hq and !l.staple and chassis_mod.find(l.item_key) != null and chassis_mod.find(l.item_key).?.kind == .mek) {
        mek_listing = i;
        break;
    };
    if (mek_listing == null) {
        try gs.market_listings.append(gs.allocator(), .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1_500_000, .hq = hq, .listed_day = 0, .expires_day = 400 });
        mek_listing = gs.market_listings.items.len - 1;
    }
    const r = try commands.execute(&gs, .{ .buy_hull_for = .{ .listing = mek_listing.?, .company = co, .lance = first_lance } });
    try std.testing.expectEqual(@as(u32, 0), r.eta_days);
    try std.testing.expectEqual(first_lance, gs.unit(r.unit).?.force);

    // The same hull on a distant HQ's board ships with the map transit.
    _ = try commands.execute(&gs, .{ .found_hq = .{ .name = "Far", .planet_key = "zebebelgenubi" } });
    const far = gs.hqs.keys()[1];
    gs.hqs.getPtr(far).?.funds = 5_000_000;
    try gs.market_listings.append(gs.allocator(), .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1_500_000, .hq = far, .listed_day = 0, .expires_day = 400 });
    const r2 = try commands.execute(&gs, .{ .buy_hull_for = .{ .listing = gs.market_listings.items.len - 1, .company = co, .lance = first_lance } });
    try std.testing.expect(r2.eta_days > 0);
    try std.testing.expectEqual(unit_mod.UnitStatus.in_transit, gs.unit(r2.unit).?.status);
    try std.testing.expectEqual(@as(usize, 1), gs.unit_transfers.items.len);

    // Crews come from the halls: seed one of each role (and only those) and fill the seats.
    gs.candidates.clearRetainingCapacity();
    try gs.candidates.append(gs.allocator(), .{ .id = @enumFromInt(gs.next_candidate_id), .hq = hq, .spec = person_gen.generate(&gs.rng, .market, .mekwarrior), .asking_bonus = 0, .listed_day = 0, .expires_day = 400 });
    gs.next_candidate_id += 1;
    try gs.candidates.append(gs.allocator(), .{ .id = @enumFromInt(gs.next_candidate_id), .hq = hq, .spec = person_gen.generate(&gs.rng, .market, .tech_mek), .asking_bonus = 0, .listed_day = 0, .expires_day = 400 });
    gs.next_candidate_id += 1;
    const c = try commands.execute(&gs, .{ .crew_company = co });
    try std.testing.expect(gs.unit(r.unit).?.pilot != .none);
    try std.testing.expect(gs.unit(r.unit).?.tech != .none);
    // Astechs and medics come to complement without a market;
    // the doctor, mechanics and office nobody offered stay open.
    for (manningNeeds(&gs, co)) |n| {
        const have = manningHave(&gs, co, n.role);
        // Two meks (one in transit) want two pilots and two techs; the hall
        // offered one of each, so those lines stay half open.
        if (isPooledRole(n.role)) try std.testing.expectEqual(n.need, have);
        if (n.role == .mekwarrior or n.role == .tech_mek) try std.testing.expectEqual(@as(u32, 1), have);
    }
    try std.testing.expect(c.hired_count > 2);
    try std.testing.expect(c.still_open > 0);
    for (gs.candidates.items) |cand| try std.testing.expect(cand.spec.role != .mekwarrior and cand.spec.role != .tech_mek);
}

test "posting a pilot clears their unit seat; an ineligible post changes nothing" {
    const crew_m = @import("crew.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 42 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const hq = gs.seat();

    // Assign a pilot to a unit, then post them to HQ: no dangling assignment.
    const uid = try gs.addUnit("LCT-1V");
    const pilot_id = try gs.hirePerson("Jo", "Doe", .mekwarrior);
    try crew_m.assignSlot(&gs, uid, .pilot, pilot_id);
    try std.testing.expectEqual(pilot_id, gs.unit(uid).?.pilot);
    try postToHq(&gs, pilot_id, hq);
    try std.testing.expectEqual(types.PersonId.none, gs.unit(uid).?.pilot);

    // An ineligible post (unknown person) returns an error and changes nothing
    // (rule 13: a refused command mutates nothing).
    const hq_funds_before = gs.hqs.getPtr(hq).?.funds;
    const people_before = gs.people.count();
    const bad_pid: types.PersonId = @enumFromInt(9999);
    try std.testing.expectError(error.UnknownPerson, postToHq(&gs, bad_pid, hq));
    try std.testing.expectEqual(hq_funds_before, gs.hqs.getPtr(hq).?.funds);
    try std.testing.expectEqual(people_before, gs.people.count());
}
