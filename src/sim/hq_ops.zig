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

/// A bay's occupancy: jobs on the bench and jobs waiting for a slot. The
/// desk, the HQ screen, the Lab and the checklist print this one count.
pub const BayLoad = struct { busy: u32, queued: u32 };

pub fn bayLoad(gs: *GameState, hq_id: types.HqId) BayLoad {
    var load: BayLoad = .{ .busy = 0, .queued = 0 };
    for (gs.bay_jobs.items) |j| {
        if (j.hq != hq_id) continue;
        if (j.started_day != null) load.busy += 1 else load.queued += 1;
    }
    return load;
}

pub fn activeJobs(gs: *GameState, hq_id: types.HqId) u32 {
    return bayLoad(gs, hq_id).busy;
}

/// Units of a part already bound for an HQ's shelf: orders in flight to
/// it plus fabrication jobs in its bay. Reorder points, the demand ledger
/// and the keep-stocked pane all count "coming" this way.
pub fn comingToHq(gs: *GameState, hq_id: types.HqId, key: []const u8) u32 {
    var coming: u32 = 0;
    for (gs.part_orders.items) |o| if (std.mem.eql(u8, o.part_key, key) and o.dest == .hq and o.dest.hq == hq_id and o.inFlight()) {
        coming += o.quantity;
    };
    for (gs.bay_jobs.items) |j| if (j.hq == hq_id and j.kind == .fabrication and j.done_day == null and std.mem.eql(u8, j.item_key, key)) {
        coming += 1;
    };
    return coming;
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

pub const QueueError = error{ UnknownUnit, NoHq, NoBay, MissingComponents, WrittenOff } || std.mem.Allocator.Error;

// ---- the one rule for structural needs ----
//
// Play feedback: the depot queue, the Market DEMAND pane, the Forces DAMAGE
// pane, the unassigned pool and the REPL `demand` verb each re-derived "which
// components does this hull need, and where" with their own filters, and a
// wreck could be refused by the depot while every screen said nothing was
// missing. Everything below reads the same slots and the same shelves; the
// rule lives here once and every reader calls it.

/// One structural component the depot consumes rebuilding a hull: the slot
/// it restores and the comp_* key for the hull's weight class (12D.8).
pub const DepotNeed = struct { slot_key: []const u8, component: []const u8 };

/// What the depot takes from the hull's home warehouse when its job is
/// queued: one component per destroyed or missing structure slot. Damaged
/// structure is bay time alone; a scrap wreck cannot be rebuilt and needs
/// nothing; every other wreck is counted like any hull. Empty for whole hulls.
pub fn depotNeeds(alloc: std.mem.Allocator, u: *const unit_mod.Unit) ![]DepotNeed {
    var buf: [max_depot_needs]DepotNeed = undefined;
    return alloc.dupe(DepotNeed, depotNeedsBuf(u, &buf));
}

/// A hull has at most eight structure locations (head, three torsos, four limbs).
pub const max_depot_needs = 8;

/// `depotNeeds` without an allocator: the needs land in `buf`.
pub fn depotNeedsBuf(u: *const unit_mod.Unit, buf: []DepotNeed) []DepotNeed {
    var n: usize = 0;
    if (u.wreck == .scrap) return buf[0..0];
    for (u.slots.items) |s| {
        if (!slotNeedsComponent(s) or n == buf.len) continue;
        buf[n] = .{ .slot_key = s.slot_key, .component = part_mod.componentFor(s.slot_key, u.chassis_key) };
        n += 1;
    }
    return buf[0..n];
}

/// The slot-level half of `depotNeeds`, for callers walking a hull's slots.
pub fn slotNeedsComponent(s: unit_mod.PartSlot) bool {
    return s.class == .structure and (s.condition == .destroyed or s.condition == .missing);
}

/// Where a hull's components must sit for the depot to use them: its own
/// home HQ (Stage 9D), the seat for the unassigned pool.
pub fn depotHqFor(gs: *GameState, u: *const unit_mod.Unit) types.HqId {
    return gs.homeHqFor(u.force);
}

/// The first component `depotNeeds` lists that the hull's home warehouse
/// lacks, or null when the depot could start today. Counts per key, so two
/// torsos want two assemblies.
pub fn depotShortfall(gs: *GameState, u: *const unit_mod.Unit) ?[]const u8 {
    const hq_id = depotHqFor(gs, u);
    var buf: [max_depot_needs]DepotNeed = undefined;
    const needs = depotNeedsBuf(u, &buf);
    for (needs, 0..) |n, i| {
        var wanted: u32 = 0;
        for (needs[0 .. i + 1]) |m| if (std.mem.eql(u8, m.component, n.component)) {
            wanted += 1;
        };
        if (gs.stockCount(.{ .hq = hq_id }, n.component) < wanted) return n.component;
    }
    return null;
}

// ---- the one rule for field spares ----
//
// Field work (armor, weapons, equipment, ammo) is done where the hull sits
// by its own tech from that site's shelf: the weekly repair pass takes
// the part there, `replace` orders it there, and every screen's "need /
// on hand / coming / short" for gear reads this ledger for that site.

/// A field-work mount that wants a spare: destroyed or missing (a damaged
/// one is hours alone).
pub fn slotNeedsSpare(s: unit_mod.PartSlot) bool {
    if (s.condition != .destroyed and s.condition != .missing) return false;
    return unit_mod.repairTier(s.class, s.condition) == .field;
}

/// Where a hull's field work happens and its spares must sit.
pub fn spareSiteFor(gs: *GameState, u: *const unit_mod.Unit) types.Site {
    return gs.siteForForce(u.force);
}

/// Units of a part already ordered to a site and still on the way.
pub fn comingToSite(gs: *GameState, site: types.Site, key: []const u8) u32 {
    var coming: u32 = 0;
    for (gs.part_orders.items) |o| if (std.mem.eql(u8, o.part_key, key) and o.inFlight() and std.meta.eql(o.dest, site)) {
        coming += o.quantity;
    };
    return coming;
}

/// The spares ledger for one site: every hull whose field work happens
/// there (scrap excepted), aggregated by part key in first-seen order,
/// against the site's shelf and the orders bound for it.
pub fn spareDemand(alloc: std.mem.Allocator, gs: *GameState, site: types.Site) ![]ComponentLine {
    var need: std.StringArrayHashMapUnmanaged(u32) = .empty;
    var uit = gs.units.iterator();
    while (uit.next()) |e| {
        const u = e.value_ptr;
        if (u.wreck == .scrap or !std.meta.eql(spareSiteFor(gs, u), site)) continue;
        for (u.slots.items) |s| {
            if (!slotNeedsSpare(s)) continue;
            const g = try need.getOrPut(alloc, s.part_key);
            if (!g.found_existing) g.value_ptr.* = 0;
            g.value_ptr.* += 1;
        }
    }
    var out: std.ArrayListUnmanaged(ComponentLine) = .empty;
    var it = need.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        const n = e.value_ptr.*;
        const on_hand = gs.stockCount(site, key);
        const coming = comingToSite(gs, site, key);
        try out.append(alloc, .{ .key = key, .need = n, .on_hand = on_hand, .coming = coming, .short = n -| (on_hand + coming) });
    }
    return out.toOwnedSlice(alloc);
}

/// The sites whose gear an HQ's Market screen answers for: the HQ's own
/// shelf, then the field stores of every company homed there that is away.
pub fn spareSitesOf(alloc: std.mem.Allocator, gs: *GameState, hq_id: types.HqId) ![]types.Site {
    var out: std.ArrayListUnmanaged(types.Site) = .empty;
    try out.append(alloc, .{ .hq = hq_id });
    var fit = gs.forces.iterator();
    while (fit.next()) |e| {
        const f = e.value_ptr;
        if (f.echelon != .company or gs.homeHqFor(f.id) != hq_id or gs.isCompanyHome(f.id)) continue;
        try out.append(alloc, .{ .company = f.id });
    }
    return out.toOwnedSlice(alloc);
}

/// One line of the components ledger: what the hulls homed at an HQ need,
/// what its shelf holds, what is ordered or being fabricated for it, and
/// the gap the player has to close.
pub const ComponentLine = struct {
    key: []const u8,
    need: u32,
    on_hand: u32,
    coming: u32,
    short: u32,
};

/// The components ledger for one HQ's depot: every hull whose home HQ it is
/// (one company when `company` is given), aggregated by component key in
/// first-seen order. A hull already in the bay has had its parts taken, so
/// it is not demand. `coming` counts part orders bound for the HQ and
/// fabrication jobs in its bay. Every screen that prints a structural
/// shortfall prints these lines.
pub fn componentDemand(alloc: std.mem.Allocator, gs: *GameState, hq_id: types.HqId, company: ?types.ForceId) ![]ComponentLine {
    var need: std.StringArrayHashMapUnmanaged(u32) = .empty;
    var uit = gs.units.iterator();
    while (uit.next()) |e| {
        const u = e.value_ptr;
        if (depotHqFor(gs, u) != hq_id or hasJobForUnit(gs, u.id)) continue;
        if (company) |c| if (gs.companyOf(u.force) != c) continue;
        for (try depotNeeds(alloc, u)) |n| {
            const g = try need.getOrPut(alloc, n.component);
            if (!g.found_existing) g.value_ptr.* = 0;
            g.value_ptr.* += 1;
        }
    }
    var out: std.ArrayListUnmanaged(ComponentLine) = .empty;
    var it = need.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        const n = e.value_ptr.*;
        const on_hand = gs.stockCount(.{ .hq = hq_id }, key);
        const coming = comingToHq(gs, hq_id, key);
        try out.append(alloc, .{ .key = key, .need = n, .on_hand = on_hand, .coming = coming, .short = n -| (on_hand + coming) });
    }
    return out.toOwnedSlice(alloc);
}

/// The new engine a rebuild needs (12D.2): TechManual price for the
/// design, zero unless the hull died of an engine kill or a cook-off.
pub fn engineCharge(u: *const unit_mod.Unit) types.CBills {
    if (!u.wreck.needsEngine()) return 0;
    const design = @import("../domain/chassis.zig").find(u.chassis_key) orelse return 0;
    return unit_mod.engineCost(design.tonnage, design.walk_mp);
}

/// What bringing this hull back would cost at today's prices (12D.2):
/// every destroyed or missing component fabricated, the depot labour, and
/// the engine. Null for scrap. The hangar sets it against a new hull.
pub fn rebuildEstimate(gs: *GameState, u: *const unit_mod.Unit) ?types.CBills {
    if (u.wreck == .scrap) return null;
    const market = @import("../econ/market.zig");
    var total: types.CBills = 0;
    var needed: i64 = 0; // every structure hit is bay labour, damaged ones included
    for (u.slots.items) |s| {
        if (s.class == .structure and s.condition != .ok) needed += 1;
    }
    var buf: [max_depot_needs]DepotNeed = undefined;
    for (depotNeedsBuf(u, &buf)) |n| {
        const def = part_mod.find(n.component) orelse continue;
        total += types.applyBp(types.applyBp(def.cost, market.structural_fab_cost_mult_bp), gs.diff().fab_cost_bp);
    }
    total += @divTrunc(u.purchase_price, tuning.hq_ops.depot_labour_divisor) * needed;
    return total + engineCharge(u);
}

/// True when a rebuild costs more than `writeoff_bp` of a new hull.
pub fn beyondEconomicalRepair(gs: *GameState, u: *const unit_mod.Unit) bool {
    if (u.status != .destroyed) return false;
    const est = rebuildEstimate(gs, u) orelse return true;
    const design = @import("../domain/chassis.zig").find(u.chassis_key) orelse return false;
    return est > types.applyBp(design.cost, tuning.loss.writeoff_bp);
}

/// Queue a depot repair: takes the needed structural components from the
/// HQ's warehouse up front (false = something's missing; see `demand`).
pub fn queueDepotRepair(gs: *GameState, unit_id: types.UnitId) QueueError!bool {
    const u = gs.unit(unit_id) orelse return error.UnknownUnit;
    if (gs.hqs.count() == 0) return error.NoHq;
    // The hull's own home HQ (its company's supplying HQ, Stage 9D) does
    // the work and supplies the components — not the outfit's first HQ.
    const hq_id = gs.homeHqFor(u.force);
    const hq = gs.hqs.getPtr(hq_id) orelse return error.NoHq;
    if (!hq.supportsStructuralRepair()) return error.NoBay;
    if (hasJobForUnit(gs, unit_id)) return true;
    if (u.wreck == .scrap) return error.WrittenOff; // strip it (12D.2)
    // A wreck from before kills wrecked structure (saves predating 12.31)
    // carries no structural damage: give it the wreck it is, so the rebuild
    // needs its component like any other.
    if (u.status == .destroyed) {
        var any = false;
        for (u.slots.items) |s| if (s.class == .structure and s.condition != .ok) {
            any = true;
        };
        if (!any) u.markWrecked();
    }

    if (!u.needsDepot()) return true; // whole: nothing to queue
    // Bay time scales with every structure hit, damaged ones included.
    var needed: u32 = 0;
    for (u.slots.items) |s| {
        if (s.class == .structure and s.condition != .ok) needed += 1;
    }
    // Every component present before any is consumed (`depotShortfall` is
    // the same check the screens print).
    if (depotShortfall(gs, u) != null) return false;
    var buf: [max_depot_needs]DepotNeed = undefined;
    for (depotNeedsBuf(u, &buf)) |n| {
        if (!gs.takeStock(.{ .hq = hq_id }, n.component, 1)) return false;
    }

    try gs.bay_jobs.append(gs.allocator(), .{
        .hq = hq_id,
        .kind = .depot_repair,
        .unit = unit_id,
        .duration_days = tuning.hq_ops.depot_base_days + tuning.hq_ops.depot_days_per_component * needed + (if (u.wreck.needsEngine()) tuning.loss.engine_rebuild_days else 0),
        .queued_day = gs.clock.day_index,
        .cost = @divTrunc(u.purchase_price, tuning.hq_ops.depot_labour_divisor) * needed + engineCharge(u), // a new engine goes in with an engine kill (12D.2)
    });
    return true;
}

pub fn queueReactivation(gs: *GameState, unit_id: types.UnitId) QueueError!void {
    const u = gs.unit(unit_id) orelse return error.UnknownUnit;
    if (gs.hqs.count() == 0) return error.NoHq;
    const hq_id = gs.homeHqFor(u.force); // its own home HQ's bay, as for depot work
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

/// Can this HQ's bay fabricate this component (12D.8)? A bay at all, at
/// the level the assembly's class needs (heavy 2, assault 3), and for
/// assault assemblies a regional or brigade HQ.
pub fn canFabricate(gs: *GameState, hq_id: types.HqId, key: []const u8) bool {
    const def = part_mod.find(key) orelse return false;
    if (!part_mod.isComponent(key) or baySlots(gs, hq_id) == 0) return false;
    const hq = gs.hqs.getPtr(hq_id) orelse return false;
    if (hq.effectiveFacilityLevel(.mek_bay) < def.fab_min_bay) return false;
    if (def.fab_regional and hq.tier == .field) return false;
    return true;
}

/// Can this HQ rebuild the structure of this design (12E.2)? Its bay must
/// be rated for the design's assemblies — the centre torso is the test.
/// Vehicles and anything without a chassis entry need nothing special.
pub fn bayCanRebuild(gs: *GameState, hq_id: types.HqId, chassis_key: []const u8) bool {
    return canFabricate(gs, hq_id, part_mod.componentFor("ct.structure", chassis_key));
}

/// "needs bay 2" / "needs bay 3 at a regional HQ" for a design's
/// assemblies, or "" when the lightest bay will do (12E.2).
pub fn rebuildNeed(chassis_key: []const u8) []const u8 {
    const def = part_mod.find(part_mod.componentFor("ct.structure", chassis_key)) orelse return "";
    if (def.fab_regional) return "needs a level-3 bay at a regional HQ to rebuild";
    if (def.fab_min_bay >= 2) return "needs a level-2 bay to rebuild";
    return "";
}

/// Fabricate components in the bay: the §9.8 guarantee — always available,
/// at a premium, over bay time — for what the bay is rated to build (12D.8).
/// Cost is paid by the caller up front.
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
/// Why a facility cannot be upgraded right now, or null when it can:
/// the command refuses on it before a C-bill moves, the HQ screen dims on it.
pub const UpgradeBlock = enum { in_progress, maxed, funds_short };

pub fn upgradeBlock(gs: *GameState, hq_id: types.HqId, kind: hq_mod.FacilityKind) ?UpgradeBlock {
    const hq = gs.hqs.getPtr(hq_id) orelse return .maxed;
    for (hq.projects.items) |p| {
        if (p.facility == kind and p.phase(gs.clock.day_index) != .complete) return .in_progress;
    }
    const to_level = hq.facilityLevel(kind) + 1;
    if (to_level > hq_mod.max_facility_level) return .maxed;
    if (hq.funds < hq_mod.upgradeCost(kind, to_level)) return .funds_short;
    return null;
}

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
            return try std.fmt.allocPrint(gs.allocator(), " — with a lingering fault (quality now {s})", .{@tagName(u.quality)});
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
                    return try std.fmt.allocPrint(gs.allocator(), " — BOTCHED (natural 2): {s} destroyed on the bench, order another", .{sl.part_key});
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
            u.wreck = .none;
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

test "one rule for structural needs: the depot, the demand ledger and the screens read the same list" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 34 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .chief_engineer);
    const hq_id = gs.hqs.keys()[0];
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    // Clear the seeded shelf so the shortfall is real.
    while (gs.takeStock(.{ .hq = hq_id }, "comp_ct", 1)) {}
    while (gs.takeStock(.{ .hq = hq_id }, "comp_torso", 1)) {}

    // An ammo wreck (the play report): centre torso and both sides gone,
    // one leg damaged. Damaged structure wants bay time, not a part.
    const uid = try gs.addUnit("SHD-2H");
    const u = gs.unit(uid).?;
    u.markWreckedBy(.ammo);
    u.slots.items[6].condition = .damaged; // ll.structure
    const needs = try depotNeeds(al, u);
    try std.testing.expectEqual(@as(usize, 3), needs.len);
    try std.testing.expectEqualStrings("comp_ct", needs[0].component);
    try std.testing.expectEqualStrings("comp_torso", needs[1].component);
    try std.testing.expectEqualStrings("comp_torso", needs[2].component);

    // The depot refuses for exactly what the ledger shows short.
    try std.testing.expectEqualStrings("comp_ct", depotShortfall(&gs, u).?);
    try std.testing.expect(!(try queueDepotRepair(&gs, uid)));
    var ledger = try componentDemand(al, &gs, hq_id, null);
    try std.testing.expectEqual(@as(usize, 2), ledger.len);
    try std.testing.expectEqual(@as(u32, 1), ledger[0].short); // comp_ct
    try std.testing.expectEqual(@as(u32, 2), ledger[1].short); // comp_torso ×2
    // …and both screens print that ledger: the Market pane and the Forces pane.
    const q = @import("queries.zig");
    const m = try q.market(al, &gs, .all, hq_id);
    try std.testing.expectEqual(@as(usize, 2), m.demand.len);
    try std.testing.expectEqualStrings("comp_ct", m.demand[0].key);
    try std.testing.expectEqual(@as(u32, 2), m.demand[1].short);
    const cd = try q.companyDamage(al, &gs, gs.companyOf(u.force));
    try std.testing.expectEqualStrings("comp_torso", cd.short_key.?);

    // One torso is not enough: the rule counts per key, so two torsos want two.
    try gs.addStock(.{ .hq = hq_id }, "comp_ct", 1);
    try gs.addStock(.{ .hq = hq_id }, "comp_torso", 1);
    try std.testing.expectEqualStrings("comp_torso", depotShortfall(&gs, u).?);
    try std.testing.expect(!(try queueDepotRepair(&gs, uid)));
    try std.testing.expectEqual(@as(u32, 1), gs.stockCount(.{ .hq = hq_id }, "comp_ct")); // nothing consumed on refusal
    try gs.addStock(.{ .hq = hq_id }, "comp_torso", 1);
    try std.testing.expect(depotShortfall(&gs, u) == null);
    ledger = try componentDemand(al, &gs, hq_id, null);
    try std.testing.expectEqual(@as(u32, 0), ledger[0].short + ledger[1].short);
    try std.testing.expect(try queueDepotRepair(&gs, uid));
    try std.testing.expectEqual(@as(u32, 0), gs.stockCount(.{ .hq = hq_id }, "comp_torso"));

    // Scrap wants nothing: no needs, no ledger line, no refusal by parts.
    const junk = try gs.addUnit("SHD-2H");
    gs.unit(junk).?.markWreckedBy(.scrap);
    try std.testing.expectEqual(@as(usize, 0), (try depotNeeds(al, gs.unit(junk).?)).len);
    try std.testing.expectEqual(@as(usize, 0), (try componentDemand(al, &gs, hq_id, null)).len);
}

test "one rule for field spares: replace orders what the site's ledger says is short, and the Market shows the same line" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 35 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .chief_engineer);
    const hq_id = gs.hqs.keys()[0];
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const commands = @import("commands.zig");
    _ = try commands.execute(&gs, .{ .new_company = "Alpha" });

    // A hull at home with one weapon shot away; the shelf is bare of it.
    const uid = try gs.addUnit("SHD-2H");
    const u = gs.unit(uid).?;
    var key: []const u8 = "";
    for (u.slots.items) |*s| if (s.class == .weapon) {
        s.condition = .destroyed;
        key = s.part_key;
        break;
    };
    while (gs.takeStock(.{ .hq = hq_id }, key, 1)) {}
    const site = spareSiteFor(&gs, u);
    try std.testing.expect(site == .hq);

    var ledger = try spareDemand(al, &gs, site);
    try std.testing.expectEqual(@as(usize, 1), ledger.len);
    try std.testing.expectEqualStrings(key, ledger[0].key);
    try std.testing.expectEqual(@as(u32, 1), ledger[0].short);
    const m = try @import("queries.zig").market(al, &gs, .all, hq_id);
    var seen = false;
    for (m.demand) |d| if (std.mem.eql(u8, d.key, key) and d.short == 1) {
        seen = true;
    };
    try std.testing.expect(seen);

    // Ordering covers it: the ledger says one coming, none short; a second
    // replace has nothing left to order.
    const r = try commands.execute(&gs, .{ .replace_gear = uid });
    try std.testing.expectEqual(@as(u32, 1), r.ordered + r.unsourced);
    ledger = try spareDemand(al, &gs, site);
    if (ledger[0].coming > 0) {
        try std.testing.expectEqual(@as(u32, 0), ledger[0].short);
        const again = try commands.execute(&gs, .{ .replace_gear = uid });
        try std.testing.expectEqual(@as(u32, 0), again.ordered + again.unsourced);
    }
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
