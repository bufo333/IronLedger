//! HQ operations (Stage 9C, ARCH §9.4): mek bays as occupied slots with
//! queues, construction/upgrade projects, and component fabrication. The
//! back office sets the pace: command admins shorten paperwork, and the
//! whole staff must be there for facilities to run at built level.

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const hq_mod = @import("../domain/hq.zig");
const part_mod = @import("../domain/part.zig");
const unit_mod = @import("../domain/unit.zig");
const person_mod = @import("../domain/person.zig");
const state_mod = @import("state.zig");
const GameState = state_mod.GameState;

/// Work slots a mek bay grants.
pub fn baySlots(gs: *GameState, hq_id: types.HqId) u32 {
    const hq = gs.hqs.getPtr(hq_id) orelse return 0;
    return @as(u32, hq.effectiveFacilityLevel(.mek_bay)) * tuning.hq_ops.slots_per_bay_level;
}

pub fn activeJobs(gs: *GameState, hq_id: types.HqId) u32 {
    var n: u32 = 0;
    for (gs.bay_jobs.items) |j| {
        if (j.hq == hq_id and j.started_day != null and j.done_day != null) n += 1;
    }
    return n;
}

pub fn hasJobForUnit(gs: *GameState, unit_id: types.UnitId) bool {
    for (gs.bay_jobs.items) |j| {
        if (j.unit == unit_id) return true;
    }
    return false;
}

/// Paperwork lead time at this HQ: command admins push permits through.
pub fn paperworkDaysFor(gs: *GameState, hq_id: types.HqId) u32 {
    const cmd = gs.hqStaff(hq_id, .admin_command);
    return hq_mod.paperworkDays(@min(cmd.count, 5));
}

pub const QueueError = error{ UnknownUnit, NoHq, NoBay, MissingComponents } || std.mem.Allocator.Error;

/// Queue a depot repair: takes the needed structural components from the
/// HQ's warehouse up front (false = something's missing; see `demand`).
pub fn queueDepotRepair(gs: *GameState, unit_id: types.UnitId) QueueError!bool {
    const u = gs.unit(unit_id) orelse return error.UnknownUnit;
    if (gs.hqs.count() == 0) return error.NoHq;
    const hq_id = gs.hqs.keys()[0];
    const hq = &gs.hqs.values()[0];
    if (!hq.supportsStructuralRepair()) return error.NoBay;
    if (hasJobForUnit(gs, unit_id)) return true;

    // Count what's needed; verify all present before consuming any.
    var needed: u32 = 0;
    for (u.slots.items) |s| {
        if (s.class != .structure or s.condition == .ok) continue;
        needed += 1;
        if (s.condition == .destroyed or s.condition == .missing) {
            if (gs.stockCount(.{ .hq = hq_id }, part_mod.componentForSlot(s.slot_key)) == 0) return false;
        }
    }
    if (needed == 0) return true;
    // Consume (each destroyed slot's component is distinct stock; re-check
    // per slot so two torsos don't share one assembly).
    for (u.slots.items) |s| {
        if (s.class != .structure or s.condition == .damaged or s.condition == .ok) continue;
        if (!gs.takeStock(.{ .hq = hq_id }, part_mod.componentForSlot(s.slot_key), 1)) return false;
    }

    try gs.bay_jobs.append(gs.allocator(), .{
        .hq = hq_id,
        .kind = .depot_repair,
        .unit = unit_id,
        .duration_days = tuning.hq_ops.depot_base_days + tuning.hq_ops.depot_days_per_component * needed,
        .queued_day = gs.clock.day_index,
        .cost = @divTrunc(u.purchase_price, 25) * needed,
    });
    return true;
}

pub fn queueReactivation(gs: *GameState, unit_id: types.UnitId) QueueError!void {
    const u = gs.unit(unit_id) orelse return error.UnknownUnit;
    if (gs.hqs.count() == 0) return error.NoHq;
    const hq_id = gs.hqs.keys()[0];
    if (baySlots(gs, hq_id) == 0) return error.NoBay;
    try gs.bay_jobs.append(gs.allocator(), .{
        .hq = hq_id,
        .kind = .reactivation,
        .unit = unit_id,
        .duration_days = unit_mod.reactivationDays(u.quality),
        .queued_day = gs.clock.day_index,
        .cost = @divTrunc(u.purchase_price, 100),
    });
}

/// Fabricate components in the bay: the §9.8 guarantee — always available,
/// at a premium, over bay time. Cost is paid by the caller up front.
pub fn queueFabrication(gs: *GameState, hq_id: types.HqId, key: []const u8, quantity: u32) QueueError!void {
    if (baySlots(gs, hq_id) == 0) return error.NoBay;
    for (0..quantity) |_| {
        try gs.bay_jobs.append(gs.allocator(), .{
            .hq = hq_id,
            .kind = .fabrication,
            .item_key = key,
            .duration_days = part_mod.fabricationDays(key),
            .queued_day = gs.clock.day_index,
        });
    }
}

/// Start (or level up) a facility as a construction project.
pub fn startUpgrade(gs: *GameState, hq_id: types.HqId, kind: hq_mod.FacilityKind) !void {
    const hq = gs.hqs.getPtr(hq_id) orelse return error.UnknownHq;
    for (hq.projects.items) |p| {
        if (p.facility == kind and p.phase(gs.clock.day_index) != .complete) return error.ProjectInProgress;
    }
    const to_level = hq.facilityLevel(kind) + 1;
    if (to_level > hq_mod.max_facility_level) return error.MaxLevel;
    const paperwork = paperworkDaysFor(gs, hq_id);
    const build_days: u32 = tuning.hq_ops.build_days_per_level * @as(u32, to_level);
    try hq.projects.append(gs.allocator(), .{
        .kind = .facility_upgrade,
        .facility = kind,
        .target_level = to_level,
        .started_day = gs.clock.day_index,
        .paperwork_done_day = gs.clock.day_index + paperwork,
        .construction_done_day = gs.clock.day_index + paperwork + build_days,
        .cost = hq_mod.upgradeCost(kind, to_level),
    });
    try gs.log(.construction, .{ .hq = hq_id }, "[construction] {s} → level {d}: {d} days paperwork, {d} days build", .{
        @tagName(kind), to_level, paperwork, build_days,
    });
}

/// Field → regional (Stage 9D): the beachhead becomes a ring. A project
/// with paperwork then a long build; on completion the HQ gains the
/// regional facility set and starts projecting influence.
pub const tier_upgrade_cost: types.CBills = tuning.hq_ops.tier_upgrade_cost;
pub const tier_upgrade_build_days: u32 = tuning.hq_ops.tier_upgrade_build_days;

pub fn startTierUpgrade(gs: *GameState, hq_id: types.HqId) !void {
    const hq = gs.hqs.getPtr(hq_id) orelse return error.UnknownHq;
    if (hq.tier != .field) return error.MaxLevel;
    for (hq.projects.items) |p| {
        if (p.kind == .tier_upgrade) return error.ProjectInProgress;
    }
    const paperwork = paperworkDaysFor(gs, hq_id);
    try hq.projects.append(gs.allocator(), .{
        .kind = .tier_upgrade,
        .started_day = gs.clock.day_index,
        .paperwork_done_day = gs.clock.day_index + paperwork,
        .construction_done_day = gs.clock.day_index + paperwork + tier_upgrade_build_days,
        .cost = tier_upgrade_cost,
    });
    try gs.log(.construction, .{ .hq = hq_id }, "[construction] {s} → regional HQ: {d} days paperwork, {d} days build", .{ hq.name, paperwork, tier_upgrade_build_days });
}

/// Daily: start queued jobs as slots free up, finish due jobs, and land
/// completed construction.
// ------------------------------------------------- repair outcomes (12C.12)

pub const RepairOdds = struct {
    skill: u8,
    target: i32,
    clean_pct: u8,
    fault_pct: u8,
    redo_pct: u8,
    tech: types.PersonId,
};

/// The best mek tech who could take the job: the hull's own tech, else
/// the sharpest available one on the books at home.
fn bestTechFor(gs: *GameState, hq_id: types.HqId, u: *const unit_mod.Unit) ?*person_mod.Person {
    if (gs.person(u.tech)) |t| if (t.isAvailable(gs.clock.day_index)) return t;
    const role: person_mod.Role = unit_mod.techRoleFor(u.kind) orelse .tech_mek;
    var best: ?*person_mod.Person = null;
    var it = gs.people.iterator();
    while (it.next()) |e| {
        const p = e.value_ptr;
        if (p.role != role or !p.isAvailable(gs.clock.day_index)) continue;
        const home = if (p.assigned_force != .none) gs.homeHqFor(p.assigned_force) else hq_id;
        if (home != hq_id) continue;
        const sk = p.skill(role.primarySkill()) orelse 7;
        if (best == null or sk < (best.?.skill(role.primarySkill()) orelse 7)) best = p;
    }
    return best;
}

/// What a depot repair or refit on this hull is likely to come to.
pub fn repairOdds(gs: *GameState, hq_id: types.HqId, unit_id: types.UnitId) RepairOdds {
    const t = tuning.hq_ops;
    const u = gs.unit(unit_id) orelse return .{ .skill = 7, .target = t.repair_target_base, .clean_pct = 0, .fault_pct = 0, .redo_pct = 100, .tech = .none };
    const tech = bestTechFor(gs, hq_id, u);
    const role: person_mod.Role = unit_mod.techRoleFor(u.kind) orelse .tech_mek;
    const skill: u8 = if (tech) |p| p.skill(role.primarySkill()) orelse 7 else 7;
    const target: i32 = t.repair_target_base + u.quality.maintenanceModifier();
    // 2d6 distribution, ways out of 36.
    const ways = [_]u8{ 1, 2, 3, 4, 5, 6, 5, 4, 3, 2, 1 };
    var clean: u32 = 0;
    var fault: u32 = 0;
    var redo: u32 = 0;
    for (ways, 0..) |w, i| {
        const raw: i32 = @intCast(i + 2);
        if (raw == 2) {
            redo += w; // botch counts against you too
            continue;
        }
        const margin = raw + (5 - @as(i32, skill)) - target;
        if (margin >= t.repair_fault_margin) clean += w else if (margin >= 0) fault += w else redo += w;
    }
    return .{
        .skill = skill,
        .target = target,
        .clean_pct = @intCast(clean * 100 / 36),
        .fault_pct = @intCast(fault * 100 / 36),
        .redo_pct = @intCast(100 - clean * 100 / 36 - fault * 100 / 36),
        .tech = if (tech) |p| p.id else .none,
    };
}

/// "tech skill 4 vs target 7 · 72% clean / 17% fault / 11% redo" for logs and queues.
pub fn repairOddsText(alloc: std.mem.Allocator, gs: *GameState, hq_id: types.HqId, unit_id: types.UnitId) ![]const u8 {
    const o = repairOdds(gs, hq_id, unit_id);
    return std.fmt.allocPrint(alloc, "tech skill {d} vs target {d} · {d}% clean / {d}% fault / {d}% redo", .{ o.skill, o.target, o.clean_pct, o.fault_pct, o.redo_pct });
}

const RepairResult = enum { clean, fault, redo, botch };

/// The roll itself, at the end of the bay time (MekHQ: the repair check).
fn rollRepair(gs: *GameState, hq_id: types.HqId, unit_id: types.UnitId) RepairResult {
    const t = tuning.hq_ops;
    const o = repairOdds(gs, hq_id, unit_id);
    const raw = gs.rng.roll2d6(.maintenance);
    if (raw == 2) return .botch;
    const margin = @as(i32, raw) + (5 - @as(i32, o.skill)) - o.target;
    if (margin >= t.repair_fault_margin) return .clean;
    if (margin >= 0) return .fault;
    return .redo;
}

/// Apply a fault or botch to the hull; returns the log tail.
fn applyRepairResult(gs: *GameState, u: *unit_mod.Unit, result: RepairResult) ![]const u8 {
    switch (result) {
        .clean, .redo => return "",
        .fault => {
            // A fault left in: the machine is fussier from here on.
            const q = @intFromEnum(u.quality);
            if (q > 0) u.quality = @enumFromInt(q - 1);
            return try std.fmt.allocPrint(gs.allocator(), " — {s}with a lingering fault (quality now {s}){s}", .{ "{a}", @tagName(u.quality), "{/}" });
        },
        .botch => {
            var gear: u32 = 0;
            for (u.slots.items) |sl| if (sl.class != .structure and sl.condition != .destroyed and sl.condition != .missing) {
                gear += 1;
            };
            if (gear == 0) return " — botched, but nothing else to break";
            var pick = gs.rng.random(.maintenance).uintLessThan(u32, gear);
            for (u.slots.items) |*sl| {
                if (sl.class == .structure or sl.condition == .destroyed or sl.condition == .missing) continue;
                if (pick == 0) {
                    sl.condition = .destroyed;
                    return try std.fmt.allocPrint(gs.allocator(), " — {s}BOTCHED (natural 2): {s} destroyed on the bench, order another{s}", .{ "{c}", sl.part_key, "{/}" });
                }
                pick -= 1;
            }
            return "";
        },
    }
}

pub fn runDaily(gs: *GameState) !void {
    const today = gs.clock.day_index;

    // Finish due jobs (a failed repair roll keeps the job on the bench).
    var i: usize = 0;
    while (i < gs.bay_jobs.items.len) {
        const job = &gs.bay_jobs.items[i];
        if (job.done_day == null or today < job.done_day.?) {
            i += 1;
            continue;
        }
        if (!try completeJob(gs, job)) {
            i += 1;
            continue;
        }
        _ = gs.bay_jobs.orderedRemove(i);
    }

    // Start queued jobs, FIFO, while slots are free.
    var hit = gs.hqs.iterator();
    while (hit.next()) |entry| {
        const hq_id = entry.value_ptr.id;
        var free = baySlots(gs, hq_id) -| activeJobs(gs, hq_id);
        for (gs.bay_jobs.items) |*job| {
            if (free == 0) break;
            if (job.hq != hq_id or job.started_day != null) continue;
            job.started_day = today;
            job.done_day = today + job.duration_days;
            free -= 1;
            if (gs.unit(job.unit)) |u| {
                if (job.kind == .depot_repair) u.status = .repairing;
                if (job.kind == .refit) u.status = .refitting;
                if (job.kind == .reactivation) u.reactivation_done_day = job.done_day;
            }
        }
    }

    // Construction lands.
    var hit2 = gs.hqs.iterator();
    while (hit2.next()) |entry| {
        const hq = entry.value_ptr;
        var pi: usize = 0;
        while (pi < hq.projects.items.len) {
            const p = hq.projects.items[pi];
            if (p.phase(today) != .complete) {
                pi += 1;
                continue;
            }
            if (p.facility) |kind| {
                var found = false;
                for (hq.facilities.items) |*f| {
                    if (f.kind == kind) {
                        f.level = p.target_level;
                        found = true;
                    }
                }
                if (!found) try hq.facilities.append(gs.allocator(), .{ .kind = kind, .level = p.target_level });
                try gs.log(.construction, .{ .hq = hq.id }, "[construction] {s} now level {d} at {s} — staffing requirement now {d}", .{
                    @tagName(kind), p.target_level, hq.name, hq.staffRequired().total(),
                });
            } else if (p.kind == .tier_upgrade) {
                hq.tier = .regional;
                hq.monthly_upkeep = 25_000;
                const more = [_]hq_mod.FacilityKind{ .comms, .spaceport, .hospital, .hiring_hall, .training_ground };
                for (more) |kind| {
                    if (hq.facilityLevel(kind) == 0) try hq.facilities.append(gs.allocator(), .{ .kind = kind, .level = 1 });
                }
                try gs.log(.construction, .{ .hq = hq.id }, "[construction] {s} is now a REGIONAL HQ — influence ring {d} LY, staffing requirement {d}", .{
                    hq.name, hq.influenceLy(), hq.staffRequired().total(),
                });
            }
            _ = hq.projects.orderedRemove(pi);
        }
    }
}

/// Returns false when the job stays on the bench (a failed repair roll).
fn completeJob(gs: *GameState, job: *state_mod.BayJob) !bool {
    const today = gs.clock.day_index;
    // The repair check (12C.12): depot work and refits can go wrong.
    if (job.kind == .depot_repair or job.kind == .refit) {
        const result = rollRepair(gs, job.hq, job.unit);
        if (result == .redo) {
            const redo = @max(1, types.applyBp(@as(i64, job.duration_days), tuning.hq_ops.repair_redo_bp));
            job.done_day = today + @as(u32, @intCast(redo));
            if (gs.unit(job.unit)) |u| try gs.log(.construction, .{ .hq = job.hq }, "[bay] {s} {s} failed the check — the work is redone ({d} more day{s})", .{ u.chassis_key, @tagName(job.kind), redo, if (redo == 1) "" else "s" });
            return false;
        }
        if (gs.unit(job.unit)) |u| {
            const tail = try applyRepairResult(gs, u, result);
            if (tail.len > 0) try gs.log(.construction, .{ .hq = job.hq }, "[bay] {s} {s}{s}", .{ u.chassis_key, @tagName(job.kind), tail });
        }
    }
    switch (job.kind) {
        .depot_repair => if (gs.unit(job.unit)) |u| {
            for (u.slots.items) |*s| {
                if (s.class == .structure) s.condition = .ok;
            }
            if (u.status == .repairing) u.status = .ready;
            try gs.log(.construction, .{ .hq = job.hq }, "[bay] {s} structural repair complete", .{u.chassis_key});
            // Big jobs hurt people (Stage 9C.2): snake-eyes on 2d6 (≈3%)
            // injures the hull's tech on the last day of the rebuild. // TUNE
            if (gs.rng.roll2d6(.medical) == 2 and u.tech != .none) {
                try @import("maintenance.zig").injureTech(gs, u.tech, 10 + gs.rng.roll2d6(.medical), "bay accident");
            }
        },
        .reactivation => if (gs.unit(job.unit)) |u| {
            u.status = .ready;
            u.reactivation_done_day = null;
            try gs.log(.construction, .{ .hq = job.hq }, "[bay] {s} reactivated from cold storage", .{u.chassis_key});
        },
        .fabrication => {
            const site: types.Site = .{ .hq = job.hq };
            const room = gs.siteFreeTons(site) / @max(1, part_mod.tons(job.item_key));
            if (room > 0) try gs.addStock(site, job.item_key, 1);
            try gs.log(.construction, .{ .hq = job.hq }, "[bay] fabricated {s}{s}", .{
                job.item_key, if (room == 0) " — no warehouse room, scrapped" else "",
            });
        },
        .refit => if (gs.unit(job.unit)) |u| {
            // Stage 10: the committed plan lands on the hull; removed mounts
            // go back on the shelf.
            var pi: usize = 0;
            while (pi < gs.refit_plans.items.len) : (pi += 1) {
                const plan = &gs.refit_plans.items[pi];
                if (plan.unit != job.unit or !plan.committed) continue;
                try gs.applyRefit(plan, .{ .hq = job.hq });
                _ = gs.refit_plans.orderedRemove(pi);
                break;
            }
            if (u.status == .refitting) u.status = .ready;
            try gs.log(.construction, .{ .hq = job.hq }, "[bay] {s} refit complete — {d} mounts fitted", .{ u.chassis_key, u.slots.items.len });
        },
    }
    if (job.cost > 0) {
        try gs.postTreasury(.{ .hq = job.hq }, .{
            .day = gs.clock.day_index,
            .amount = -types.applyBp(job.cost, gs.commanderMultBp(.repair)),
            .category = .maintenance,
            .hq = job.hq,
            .note = @tagName(job.kind),
        });
    }
    return true;
}

test "12C.12: repair odds favour the sharper tech and the better hull; the parts sum to 100" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1212 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .chief_engineer);
    const hq_id = gs.hqs.keys()[0];
    const uid = try gs.addUnit("AS7-D");
    const none = repairOdds(&gs, hq_id, uid); // no tech at all: skill 7
    try std.testing.expectEqual(@as(u32, 100), @as(u32, none.clean_pct) + none.fault_pct + none.redo_pct);
    const tech = try gs.hirePerson("Ace", "Wrench", .tech_mek);
    try gs.person(tech).?.skills.put(gs.allocator(), .tech_mek, 2);
    gs.unit(uid).?.tech = tech;
    const ace = repairOdds(&gs, hq_id, uid);
    try std.testing.expect(ace.clean_pct > none.clean_pct);
    try std.testing.expectEqual(tech, ace.tech);
    gs.unit(uid).?.quality = .a; // the worst machine
    const worst = repairOdds(&gs, hq_id, uid);
    try std.testing.expect(worst.clean_pct < ace.clean_pct);
    try std.testing.expect(worst.target > ace.target);
}

test "bays are slots: jobs queue when full and finish in order" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 31 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .chief_engineer); // mek_bay lv1 → 2 slots
    const hq_id = gs.hqs.keys()[0];

    try queueFabrication(&gs, hq_id, "comp_arm", 3); // 6 days each, 3 jobs, 2 slots
    try runDaily(&gs);
    try std.testing.expectEqual(@as(u32, 2), activeJobs(&gs, hq_id));

    gs.clock.day_index += 6;
    try runDaily(&gs); // two finish, third starts
    try std.testing.expectEqual(@as(u32, 1 + 2), gs.stockCount(.{ .hq = hq_id }, "comp_arm")); // 1 seeded
    try std.testing.expectEqual(@as(u32, 1), activeJobs(&gs, hq_id));
    gs.clock.day_index += 6;
    try runDaily(&gs);
    try std.testing.expectEqual(@as(u32, 4), gs.stockCount(.{ .hq = hq_id }, "comp_arm"));
    try std.testing.expectEqual(@as(usize, 0), gs.bay_jobs.items.len);
}

test "depot repair needs the right components, then holds a bay" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 32 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .chief_engineer);
    const hq_id = gs.hqs.keys()[0];
    const uid = try gs.addUnit("SHD-2H");
    const u = gs.unit(uid).?;
    u.slots.items[1].condition = .destroyed; // ct.structure → comp_ct
    u.slots.items[6].condition = .destroyed; // ll.structure → comp_leg

    // Warehouse seeded with one of each component: both available.
    try std.testing.expect(try queueDepotRepair(&gs, uid));
    try std.testing.expectEqual(@as(u32, 0), gs.stockCount(.{ .hq = hq_id }, "comp_ct"));
    try runDaily(&gs);
    try std.testing.expectEqual(unit_mod.UnitStatus.repairing, u.status);

    // The bench keeps a job that fails its repair check (12C.12), so walk
    // the days until it is off the bench.
    gs.clock.day_index += 7 + 5 * 2;
    var days: u32 = 0;
    while (hasJobForUnit(&gs, uid) and days < 200) : (days += 1) {
        try runDaily(&gs);
        gs.clock.day_index += 1;
    }
    try std.testing.expect(!u.needsDepot());
    try std.testing.expectEqual(unit_mod.UnitStatus.ready, u.status);

    // Second wreck with no components left: refused, nothing consumed.
    const uid2 = try gs.addUnit("SHD-2H");
    gs.unit(uid2).?.slots.items[1].condition = .destroyed;
    try std.testing.expect(!(try queueDepotRepair(&gs, uid2)));
}

test "construction projects: paperwork then build, staffing bill rises" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 33 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    const hq_id = gs.hqs.keys()[0];
    const before = gs.hqs.values()[0].staffRequired().total();

    try startUpgrade(&gs, hq_id, .warehouse);
    try std.testing.expectError(error.ProjectInProgress, startUpgrade(&gs, hq_id, .warehouse));
    const p = gs.hqs.values()[0].projects.items[0];
    try std.testing.expectEqual(@as(u8, 2), p.target_level);

    gs.clock.day_index = p.construction_done_day;
    try runDaily(&gs);
    try std.testing.expectEqual(@as(u8, 2), gs.hqs.values()[0].facilityLevel(.warehouse));
    try std.testing.expect(gs.hqs.values()[0].staffRequired().total() > before);
}
