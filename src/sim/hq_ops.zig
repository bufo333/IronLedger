//! HQ operations (Stage 9C, ARCH §9.4): mek bays as occupied slots with
//! queues, construction/upgrade projects, and component fabrication. The
//! back office sets the pace: command admins shorten paperwork, and the
//! whole staff must be there for facilities to run at built level. It also
//! owns the back-office staff counts (`hqStaff`), the staffing refresh, and
//! autostaffing.
//! No MekHQ counterpart: the HQ network is this game's extension
//! (docs/mekhq-map.md).

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const hq_mod = @import("../domain/hq.zig");
const part_mod = @import("../domain/part.zig");
const unit_mod = @import("../domain/unit.zig");
const person_mod = @import("../domain/person.zig");
const sites = @import("sites.zig");
const toe = @import("toe.zig");
const commander_mod = @import("../domain/commander.zig");
const state_mod = @import("state.zig");
const GameState = state_mod.GameState;
const founding = @import("founding.zig");
const posture = @import("posture.zig");
const refit_m = @import("refit.zig");
const planet_mod = @import("../domain/planet.zig");
const market_mod = @import("../econ/market.zig");
const treasury = @import("treasury.zig");
const network = @import("network.zig");
const lift_mod = @import("lift.zig");
const commands = @import("commands.zig");

// ----------------------------------------------------- the back office

/// `count` is how many admins of the role are posted; `best_skill` is the
/// lowest, i.e. best, admin skill among them (rule 60), staying at its
/// default of 7 when `count` is zero — no admin posted.
pub const StaffSummary = struct { count: u32 = 0, best_skill: u8 = 7 };

/// Reads the current postings at `hq_id` into a `StaffSummary` for `role`.
pub fn hqStaff(gs: *GameState, hq_id: types.HqId, role: person_mod.Role) StaffSummary {
    var s: StaffSummary = .{};
    var it = gs.people.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        if (p.status != .active or p.posted_hq != hq_id or p.role != role) continue;
        s.count += 1;
        s.best_skill = @min(s.best_skill, p.skill(.admin) orelse 7);
    }
    return s;
}

/// Recompute every HQ's `staff_assigned` from real postings (derived
/// state, rebuilt after every posting change and on load).
pub fn refreshHqStaffing(gs: *GameState) void {
    var hit = gs.hqs.iterator();
    while (hit.next()) |entry| entry.value_ptr.staff_assigned = 0;
    var it = gs.people.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        if (p.status != .active or p.posted_hq == .none) continue;
        if (gs.hqs.getPtr(p.posted_hq)) |h| h.staff_assigned += 1;
    }
}

/// Recruit and post admins until an HQ meets its staffing requirement (the
/// convenience path; the hiring hall is the considered one). Returns how
/// many were hired.
pub fn staffHqToRequirement(gs: *GameState, hq_id: types.HqId) !u32 {
    const hq = gs.hqs.getPtr(hq_id) orelse return error.UnknownHq;
    const req = hq.staffRequired();
    var hired: u32 = 0;
    const plan = [_]struct { person_mod.Role, u32 }{
        .{ .admin_command, req.admin },
        .{ .admin_logistics, req.logistics / 2 },
        .{ .admin_transport, req.logistics - req.logistics / 2 },
        .{ .admin_hr, req.hr },
        .{ .admin_finance, req.finance },
    };
    for (plan) |entry| {
        const have = hqStaff(gs, hq_id, entry[0]).count;
        var n: u32 = entry[1] -| have;
        while (n > 0) : (n -= 1) {
            const pid = try @import("personnel.zig").recruitGenerated(gs, entry[0], hq_id, .market);
            gs.person(pid).?.posted_hq = hq_id;
            hired += 1;
        }
    }
    refreshHqStaffing(gs);
    return hired;
}

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
    const cmd = hqStaff(gs, hq_id, .admin_command);
    return hq_mod.paperworkDays(@min(cmd.count, 5));
}

pub const QueueError = error{ UnknownUnit, NoHq, NoBay, MissingComponents, WrittenOff } || std.mem.Allocator.Error;

// ---- the one rule for structural needs ----
//
// "Which components does this hull need, and where" is answered once,
// here: the depot queue, the Market DEMAND pane, the Forces DAMAGE pane,
// the unassigned pool and the REPL `demand` verb all call it, so the depot
// never refuses a wreck for a part the screens say is on hand (rule 20).

/// One structural component the depot consumes rebuilding a hull: the slot
/// it restores and the comp_* key for the hull's weight class.
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

/// The HQ that hosts a new company: `preferred` when
/// it has a free combat-company slot, else the first HQ that has one,
/// else `.none`. `new_company` and the Forces screen's + share it.
pub fn hqWithCompanySlot(gs: *GameState, preferred: types.HqId) types.HqId {
    if (gs.hqs.getPtr(preferred)) |h| if (toe.companiesAtHq(gs, preferred) < h.capacity().combat_companies) return preferred;
    var hit = gs.hqs.iterator();
    while (hit.next()) |e| if (toe.companiesAtHq(gs, e.value_ptr.id) < e.value_ptr.capacity().combat_companies) return e.value_ptr.id;
    return .none;
}

/// Where a hull's components must sit for the depot to use them: its own
/// home HQ, the seat for the unassigned pool.
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
    return sites.siteForForce(gs, u.force);
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
        if (f.echelon != .company or gs.homeHqFor(f.id) != hq_id or posture.isCompanyHome(gs, f.id)) continue;
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

/// The new engine a rebuild needs: TechManual price for the
/// design, zero unless the hull died of an engine kill or a cook-off.
pub fn engineCharge(u: *const unit_mod.Unit) types.CBills {
    if (!u.wreck.needsEngine()) return 0;
    const design = @import("../domain/chassis.zig").find(u.chassis_key) orelse return 0;
    return unit_mod.engineCost(design.tonnage, design.walk_mp);
}

/// What bringing this hull back would cost at today's prices:
/// every destroyed or missing component fabricated, the depot labour, and
/// the engine. Null for scrap. The hangar sets it against a new hull.
pub fn rebuildEstimate(gs: *GameState, u: *const unit_mod.Unit) ?types.CBills {
    if (u.wreck == .scrap) return null;
    var total: types.CBills = 0;
    var needed: i64 = 0; // every structure hit is bay labour, damaged ones included
    for (u.slots.items) |s| {
        if (s.class == .structure and s.condition != .ok) needed += 1;
    }
    var buf: [max_depot_needs]DepotNeed = undefined;
    for (depotNeedsBuf(u, &buf)) |n| {
        const def = part_mod.find(n.component) orelse continue;
        total += types.applyBp(types.applyBp(def.cost, market_mod.structural_fab_cost_mult_bp), gs.diff().fab_cost_bp);
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
    // The hull's own home HQ (its company's supplying HQ) does
    // the work and supplies the components — not the outfit's first HQ.
    const hq_id = gs.homeHqFor(u.force);
    const hq = gs.hqs.getPtr(hq_id) orelse return error.NoHq;
    if (!hq.supportsStructuralRepair()) return error.NoBay;
    if (hasJobForUnit(gs, unit_id)) return true;
    if (u.wreck == .scrap) return error.WrittenOff; // strip it
    // A destroyed hull with every structure slot intact is cored here, so
    // the rebuild needs its component like any other wreck. The coring
    // below is provisional: a refusal in the component check that follows
    // restores it, so an expected refusal leaves the hull untouched (13).
    var needs_coring = false;
    if (u.status == .destroyed) {
        var any = false;
        for (u.slots.items) |s| if (s.class == .structure and s.condition != .ok) {
            any = true;
        };
        needs_coring = !any;
    }
    // Reserve bay-job capacity before any mutation (rule 12): the append
    // after the takeStock loop must not fail with the hull already cored
    // or stock already consumed.
    try gs.bay_jobs.ensureUnusedCapacity(gs.allocator(), 1);
    const prev_wreck = u.wreck;
    if (needs_coring) u.markWrecked();

    if (!u.needsDepot()) return true; // whole: nothing to queue
    // Bay time scales with every structure hit, damaged ones included.
    var needed: u32 = 0;
    for (u.slots.items) |s| {
        if (s.class == .structure and s.condition != .ok) needed += 1;
    }
    // Every component present before any is consumed (`depotShortfall` is
    // the same check the screens print).
    if (depotShortfall(gs, u) != null) {
        if (needs_coring) uncore(u, prev_wreck);
        return false;
    }
    var buf: [max_depot_needs]DepotNeed = undefined;
    for (depotNeedsBuf(u, &buf)) |n| {
        if (!gs.takeStock(.{ .hq = hq_id }, n.component, 1)) {
            if (needs_coring) uncore(u, prev_wreck);
            return false;
        }
    }

    gs.bay_jobs.appendAssumeCapacity(.{
        .hq = hq_id,
        .kind = .depot_repair,
        .unit = unit_id,
        .duration_days = tuning.hq_ops.depot_base_days + tuning.hq_ops.depot_days_per_component * needed + (if (u.wreck.needsEngine()) tuning.loss.engine_rebuild_days else 0),
        .queued_day = gs.clock.day_index,
        .cost = @divTrunc(u.purchase_price, tuning.hq_ops.depot_labour_divisor) * needed + engineCharge(u), // a new engine goes in with an engine kill
    });
    return true;
}

/// Undo `queueDepotRepair`'s provisional coring: a hull that needed coring
/// had every structure slot intact beforehand, so restoring the wreck
/// cause and putting that one slot back to `.ok` is exact, not a guess.
fn uncore(u: *unit_mod.Unit, prev_wreck: unit_mod.WreckCause) void {
    u.wreck = prev_wreck;
    for (u.slots.items) |*s| if (s.class == .structure and s.condition != .ok) {
        s.condition = .ok;
    };
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

/// Can this HQ's bay fabricate this component? A bay at all, at
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

/// Can this HQ rebuild the structure of this design? Its bay must be rated
/// for the design's weight-class assemblies — the centre torso is the
/// test, vehicles included. A design with no chassis entry rates medium.
pub fn bayCanRebuild(gs: *GameState, hq_id: types.HqId, chassis_key: []const u8) bool {
    return canFabricate(gs, hq_id, part_mod.componentFor("ct.structure", chassis_key));
}

/// "needs a level-2 bay to rebuild" / "needs a level-3 bay at a regional
/// HQ to rebuild" for a design's assemblies, or "" when the lightest bay
/// will do.
pub fn rebuildNeed(chassis_key: []const u8) []const u8 {
    const def = part_mod.find(part_mod.componentFor("ct.structure", chassis_key)) orelse return "";
    if (def.fab_regional) return "needs a level-3 bay at a regional HQ to rebuild";
    if (def.fab_min_bay >= 2) return "needs a level-2 bay to rebuild";
    return "";
}

/// Fabricate components in the bay: the §9.8 guarantee — always available,
/// at a premium, over bay time — for what the bay is rated to build.
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

/// Why a facility cannot be upgraded right now: the command refuses on it
/// before a C-bill moves, the HQ screen dims on it.
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

pub const tier_upgrade_cost: types.CBills = tuning.hq_ops.tier_upgrade_cost;
pub const tier_upgrade_build_days: u32 = tuning.hq_ops.tier_upgrade_build_days;

/// Field → regional: the beachhead becomes a ring. A project with
/// paperwork then a long build; on completion the HQ gains the regional
/// facility set and starts projecting influence.
pub fn startTierUpgrade(gs: *GameState, hq_id: types.HqId) !void {
    const hq = gs.hqs.getPtr(hq_id) orelse return error.UnknownHq;
    if (hq.tier != .field) return error.MaxLevel;
    for (hq.projects.items) |p| {
        if (p.kind == .tier_upgrade) return error.ProjectInProgress;
    }
    const paperwork = paperworkDaysFor(gs, hq_id);
    try hq.projects.ensureUnusedCapacity(gs.allocator(), 1);
    var date_buf: [10]u8 = undefined;
    const line = try std.fmt.allocPrint(
        gs.allocator(),
        "{s} [construction] {s} → regional HQ: {d} days paperwork, {d} days build",
        .{ gs.clock.date.text(&date_buf), hq.name, paperwork, tier_upgrade_build_days },
    );
    try gs.reserveLog(1);
    // ---- commit: no fallible operation past this point ----
    hq.projects.appendAssumeCapacity(.{
        .kind = .tier_upgrade,
        .started_day = gs.clock.day_index,
        .paperwork_done_day = gs.clock.day_index + paperwork,
        .construction_done_day = gs.clock.day_index + paperwork + tier_upgrade_build_days,
        .cost = tier_upgrade_cost,
    });
    gs.event_log.appendAssumeCapacity(.{
        .day = gs.clock.day_index,
        .category = .construction,
        .hq = hq_id,
        .text = line,
    });
}

// ------------------------------------------------- repair outcomes

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

/// Apply a fault or botch to the hull; fills `buf` with the log tail and
/// returns the written slice.  Uses bufPrint so it cannot fail after the
/// mutation — caller must pre-allocate `buf` with sufficient space (128 bytes
/// covers every possible outcome; C5 pattern, sites.zig §prepare/commit).
fn applyRepairResultBuf(gs: *GameState, u: *unit_mod.Unit, result: RepairResult, buf: []u8) []const u8 {
    switch (result) {
        .clean, .redo => return "",
        .fault => {
            // A fault left in: the machine is fussier from here on.
            const q = @intFromEnum(u.quality);
            if (q > 0) u.quality = @enumFromInt(q - 1);
            return std.fmt.bufPrint(buf, " — with a lingering fault (quality now {s})", .{@tagName(u.quality)}) catch unreachable;
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
                    return std.fmt.bufPrint(buf, " — BOTCHED (natural 2): {s} destroyed on the bench, order another", .{sl.part_key}) catch unreachable;
                }
                pick -= 1;
            }
            return "";
        },
    }
}

/// Daily: finish due jobs, start queued jobs as slots free up, and land
/// completed construction.
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
    // ---- Prepare: reserve all list capacities and pre-allocate log-line
    // buffers before any RNG draw, so an OOM returns before mutating state
    // (rule 12, C5q).  Because the job is removed only on `true`, a
    // non-failing commit tail guarantees rollRepair runs exactly once.
    //
    // Log budget per job kind:
    //   depot_repair: redo(1) or [tail(0-1) + complete(1) + wound(1) +
    //                 awards(0-N) + roster(0-1)] → max 4 + award_table.len
    //   refit:        redo(1) or [tail(0-1) + complete(1)]               → max 2
    //   reactivation: complete(1)                                          → 1
    //   fabrication:  complete(1)                                          → 1
    const award_table = @import("../domain/award.zig").table;
    const n_logs: usize = switch (job.kind) {
        .depot_repair => 4 + award_table.len,
        .refit => 2,
        .reactivation, .fabrication => 1,
    };
    try gs.reserveLog(n_logs);
    if (job.cost > 0) try gs.reserveLedger(1);

    // Fabrication: the stock-map may need a new key slot.
    if (job.kind == .fabrication) {
        const fab_site: types.Site = .{ .hq = job.hq };
        if (gs.stockMap(fab_site)) |m| try m.ensureUnusedCapacity(gs.allocator(), 1);
    }

    // Refit: pre-reserve applyRefit's slot and stock-map capacity before the
    // repair roll so its own prepare-phase ensureUnusedCapacity calls are
    // no-ops (idempotent) on re-entry.
    if (job.kind == .refit) {
        for (gs.refit_plans.items) |*plan| {
            if (plan.unit != job.unit or !plan.committed) continue;
            const u = gs.unit(plan.unit) orelse break;
            var n_installs: usize = 0;
            for (plan.ops.items) |op| if (op == .install) {
                n_installs += 1;
            };
            try u.slots.ensureUnusedCapacity(gs.allocator(), n_installs);
            for (plan.ops.items) |op| {
                if (op != .remove) continue;
                for (u.slots.items) |s| {
                    if (std.mem.eql(u8, s.slot_key, op.remove) and s.condition == .ok) {
                        const dest_map = gs.stockMap(.{ .hq = job.hq }) orelse break;
                        try dest_map.ensureUnusedCapacity(gs.allocator(), 1);
                        break;
                    }
                }
            }
            break;
        }
    }

    // Depot-repair injure branch: pre-reserve everything inflict + checkAwards
    // + injureTech need so the commit tail (which inlines those functions) is
    // allocation-free (rule 17, C5q).  All the log slots are already included
    // in n_logs above.
    var injure_tech_ptr: ?*person_mod.Person = null;
    var injure_full_name: []const u8 = "";
    var injure_ranked_name: []const u8 = "";
    var injure_wound_buf: []u8 = &.{};
    var injure_award_bufs: [][]u8 = &.{};
    var injure_roster_buf: []u8 = &.{};
    if (job.kind == .depot_repair) blk: {
        const u = gs.unit(job.unit) orelse break :blk;
        if (u.tech == .none) break :blk;
        const t = gs.person(u.tech) orelse break :blk;
        injure_tech_ptr = t;
        injure_full_name = try t.fullName(gs.allocator());
        injure_ranked_name = try t.rankedName(gs.allocator());
        injure_wound_buf = try gs.allocator().alloc(u8, 256);
        injure_award_bufs = try gs.allocator().alloc([]u8, award_table.len);
        for (injure_award_bufs) |*buf| buf.* = try gs.allocator().alloc(u8, 256);
        injure_roster_buf = try gs.allocator().alloc(u8, 256);
        try t.injuries.ensureUnusedCapacity(gs.allocator(), 1);
        try t.awards.ensureUnusedCapacity(gs.allocator(), award_table.len);
    }

    // Pre-allocate log-line buffers (commit tail uses bufPrint — cannot fail).
    // 256 bytes covers the date prefix, chassis_key, kind tag, and any tail.
    var repair_result_buf: [128]u8 = undefined; // for applyRepairResultBuf (stack)
    const needs_repair_log = job.kind == .depot_repair or job.kind == .refit;
    const redo_buf: []u8 = if (needs_repair_log) try gs.allocator().alloc(u8, 256) else &.{};
    const tail_line_buf: []u8 = if (needs_repair_log) try gs.allocator().alloc(u8, 256) else &.{};
    const complete_buf: []u8 = try gs.allocator().alloc(u8, 256);

    // ---- Commit: roll and mutate — list appends use appendAssumeCapacity,
    // string formatting uses bufPrint, both cannot fail. ----
    var date_buf: [10]u8 = undefined;
    const date_str = gs.clock.date.text(&date_buf);

    if (job.kind == .depot_repair or job.kind == .refit) {
        const result = rollRepair(gs, job.hq, job.unit);
        if (result == .redo) {
            const redo = @max(1, types.applyBp(@as(i64, job.duration_days), tuning.hq_ops.repair_redo_bp));
            job.done_day = today + @as(u32, @intCast(redo));
            if (gs.unit(job.unit)) |u| {
                const line = std.fmt.bufPrint(redo_buf, "{s} [bay] {s} {s} failed the check — the work is redone ({d} more day{s})", .{
                    date_str, u.chassis_key, @tagName(job.kind), redo, if (redo == 1) "" else "s",
                }) catch unreachable;
                gs.event_log.appendAssumeCapacity(.{ .day = today, .category = .construction, .hq = job.hq, .text = line });
            }
            return false;
        }
        if (gs.unit(job.unit)) |u| {
            const tail = applyRepairResultBuf(gs, u, result, &repair_result_buf);
            if (tail.len > 0) {
                const line = std.fmt.bufPrint(tail_line_buf, "{s} [bay] {s} {s}{s}", .{
                    date_str, u.chassis_key, @tagName(job.kind), tail,
                }) catch unreachable;
                gs.event_log.appendAssumeCapacity(.{ .day = today, .category = .construction, .hq = job.hq, .text = line });
            }
        }
    }
    switch (job.kind) {
        .depot_repair => if (gs.unit(job.unit)) |u| {
            for (u.slots.items) |*s| {
                if (s.class == .structure) s.condition = .ok;
            }
            u.wreck = .none;
            if (u.status == .repairing) u.status = .ready;
            const line = std.fmt.bufPrint(complete_buf, "{s} [bay] {s} structural repair complete", .{
                date_str, u.chassis_key,
            }) catch unreachable;
            gs.event_log.appendAssumeCapacity(.{ .day = today, .category = .construction, .hq = job.hq, .text = line });
            // Big jobs hurt people: snake-eyes on 2d6 (≈3%) injures
            // the hull's tech on the last day of the rebuild.
            // Inlined from injureTech + inflict + checkAwards; all
            // allocations were pre-reserved above, so no fallible ops here.
            if (gs.rng.roll2d6(.medical) == 2 and u.tech != .none) {
                const acc_days = tuning.maintenance.bay_accident_days_base + gs.rng.roll2d6(.medical);
                if (injure_tech_ptr) |it| if (it.status == .active) {
                    const severity: u8 = if (acc_days <= tuning.maintenance.injury_days_serious) 1 else if (acc_days <= tuning.maintenance.injury_days_crippling) 2 else 3;
                    // inflict: location, permanent check, append injury.
                    const location = @import("medical.zig").rollLocation(gs, .accident);
                    const permanent = severity >= 3 and (location == .head or location == .internal) and gs.rng.roll2d6(.medical) <= tuning.medical.permanent_target;
                    it.injuries.appendAssumeCapacity(.{
                        .location = location,
                        .severity = @min(severity, 3),
                        .incurred_day = today,
                        .permanent = permanent,
                    });
                    it.status = .wounded;
                    it.wound_heal_day = null;
                    if (!gs.auto_admit) it.medbay_admitted = false;
                    // checkAwards: Wound Badge and any others that became eligible.
                    for (award_table, 0..) |a, ai| {
                        if (it.hasAward(a.key)) continue;
                        if (it.counter(a.kind, today) < a.threshold) continue;
                        it.awards.appendAssumeCapacity(a.key);
                        it.last_award_day = today;
                        it.morale = @intCast(@min(100, @as(u32, it.morale) + a.morale));
                        const award_line = std.fmt.bufPrint(injure_award_bufs[ai], "{s} [award] {s} receives the {s} ({s} {d})", .{
                            date_str,                  injure_ranked_name, a.name, @tagName(a.kind),
                            it.counter(a.kind, today),
                        }) catch unreachable;
                        gs.event_log.appendAssumeCapacity(.{
                            .day = today,
                            .category = .rotation,
                            .company = gs.companyOf(it.assigned_force),
                            .hq = it.posted_hq,
                            .contract = .none,
                            .text = award_line,
                        });
                    }
                    // Wound log.
                    const wound_line = std.fmt.bufPrint(injure_wound_buf, "{s} [medbay] {s} wounded (bay accident): {s} {s}{s}", .{
                        date_str,                                       injure_full_name,
                        @import("medical.zig").severityLabel(severity), @tagName(location),
                        if (permanent) " — permanent" else "",
                    }) catch unreachable;
                    gs.event_log.appendAssumeCapacity(.{
                        .day = today,
                        .category = .medical,
                        .company = gs.companyOf(it.assigned_force),
                        .hq = .none,
                        .contract = .none,
                        .text = wound_line,
                    });
                    // injureTech roster reassignment.
                    const tech_company = gs.companyOf(it.assigned_force);
                    var swapped: u32 = 0;
                    var open: u32 = 0;
                    var rit = gs.units.iterator();
                    while (rit.next()) |uentry| {
                        const ru = uentry.value_ptr;
                        if (ru.tech != it.id) continue;
                        const role = unit_mod.techRoleFor(ru.kind) orelse continue;
                        const needed = @import("maintenance.zig").hullHours(gs, ru);
                        if (@import("maintenance.zig").findFreeTech(gs, role, gs.companyOf(ru.force), needed)) |replacement| {
                            ru.tech = replacement;
                            swapped += 1;
                        } else {
                            ru.tech = .none;
                            open += 1;
                        }
                    }
                    if (swapped + open > 0) {
                        const roster_line = std.fmt.bufPrint(injure_roster_buf, "{s} [roster] {d} hull(s) reassigned to free techs, {d} left without a tech", .{
                            date_str, swapped, open,
                        }) catch unreachable;
                        gs.event_log.appendAssumeCapacity(.{
                            .day = today,
                            .category = .medical,
                            .company = tech_company,
                            .hq = .none,
                            .contract = .none,
                            .text = roster_line,
                        });
                    }
                };
            }
        },
        .reactivation => if (gs.unit(job.unit)) |u| {
            u.status = .ready;
            u.reactivation_done_day = null;
            const line = std.fmt.bufPrint(complete_buf, "{s} [bay] {s} reactivated from cold storage", .{
                date_str, u.chassis_key,
            }) catch unreachable;
            gs.event_log.appendAssumeCapacity(.{ .day = today, .category = .construction, .hq = job.hq, .text = line });
        },
        .fabrication => {
            const site: types.Site = .{ .hq = job.hq };
            const room = sites.siteFreeTons(gs, site) / @max(1, part_mod.tons(job.item_key));
            // Capacity pre-reserved above; addStock cannot fail for a new key.
            if (room > 0) gs.addStock(site, job.item_key, 1) catch unreachable;
            const line = std.fmt.bufPrint(complete_buf, "{s} [bay] fabricated {s}{s}", .{
                date_str,
                job.item_key,
                if (room == 0) " — no warehouse room, scrapped" else "",
            }) catch unreachable;
            gs.event_log.appendAssumeCapacity(.{ .day = today, .category = .construction, .hq = job.hq, .text = line });
        },
        .refit => if (gs.unit(job.unit)) |u| {
            // The committed plan lands on the hull; removed mounts go back
            // on the shelf.  applyRefit is atomic (prepare + commit); its
            // prepare-phase allocations are idempotent with the reservations
            // above, so this call cannot leave the hull half-applied.
            var pi: usize = 0;
            while (pi < gs.refit_plans.items.len) : (pi += 1) {
                const plan = &gs.refit_plans.items[pi];
                if (plan.unit != job.unit or !plan.committed) continue;
                try refit_m.applyRefit(gs, plan, .{ .hq = job.hq });
                _ = gs.refit_plans.orderedRemove(pi);
                break;
            }
            if (u.status == .refitting) u.status = .ready;
            const line = std.fmt.bufPrint(complete_buf, "{s} [bay] {s} refit complete — {d} mounts fitted", .{
                date_str, u.chassis_key, u.slots.items.len,
            }) catch unreachable;
            gs.event_log.appendAssumeCapacity(.{ .day = today, .category = .construction, .hq = job.hq, .text = line });
        },
    }
    if (job.cost > 0) {
        try gs.postTreasury(.{ .hq = job.hq }, .{
            .day = gs.clock.day_index,
            .amount = -types.applyBp(job.cost, commander_mod.costMultBp(gs.commander, .repair)),
            .category = .maintenance,
            .hq = job.hq,
            .note = @tagName(job.kind),
        });
    }
    return true;
}

// ---- C4b HQ/network command handlers moved from commands.zig ----

/// A world is reachable for founding if a ring or beachhead band covers
/// it, or the outfit has worked a contract there.
fn reachable(gs: *GameState, world: *const planet_mod.Planet) bool {
    var hit = gs.hqs.iterator();
    while (hit.next()) |entry| {
        const hq = entry.value_ptr;
        const hq_world = planet_mod.find(hq.planet_key) orelse continue;
        if (market_mod.visibilityFor(planet_mod.distanceLy(hq_world, world), hq.influenceLy()) != .hidden) return true;
    }
    var cit = gs.contracts.iterator();
    while (cit.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.planet_key, world.key)) return true;
    }
    return false;
}

/// Found a field HQ on a reachable world.
pub fn foundHq(gs: *GameState, name: []const u8, planet_key: []const u8) !types.HqId {
    const world = planet_mod.find(planet_key) orelse return error.UnknownPlanet;
    if (!reachable(gs, world)) return error.NotReachable;
    const cost: types.CBills = tuning.hq.found_field_hq_cost;
    if (gs.treasuryBalance(.outfit) < cost) return error.InsufficientTreasury;
    // The HQ is built and its slots reserved before the money moves.
    const hq = founding.prepareHq(gs, name, .field, world.key) catch |err| switch (err) {
        error.UnknownPlanet => return error.UnknownPlanet,
        error.NotReachable => return error.NotReachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
    try gs.hqs.ensureUnusedCapacity(gs.allocator(), 1);
    try gs.reserveLedger(1);
    var date_buf: [10]u8 = undefined;
    const line = try std.fmt.allocPrint(
        gs.allocator(),
        "{s} [network] field HQ \"{s}\" founded on {s} — post staff, send funds, link it",
        .{ gs.clock.date.text(&date_buf), name, world.name },
    );
    try gs.reserveLog(1);
    // ---- commit: no fallible operation past this point ----
    try treasury.debit(gs, .outfit, .{
        .day = gs.clock.day_index,
        .amount = -cost,
        .category = .hq_construction,
        .note = "field HQ founded",
    });
    const id = gs.commitHq(hq);
    gs.event_log.appendAssumeCapacity(.{
        .day = gs.clock.day_index,
        .category = .construction,
        .hq = id,
        .text = line,
    });
    return id;
}

/// Field → regional tier upgrade.
pub fn upgradeTier(gs: *GameState, hq_id: types.HqId) !void {
    const h = gs.hqs.getPtr(hq_id) orelse return error.UnknownHq;
    if (h.tier != .field) return error.MaxLevel;
    for (h.projects.items) |p| if (p.kind == .tier_upgrade) return error.ProjectInProgress;
    if (gs.treasuryBalance(.{ .hq = hq_id }) < tier_upgrade_cost) return error.InsufficientTreasury;
    try gs.reserveLedger(1);
    startTierUpgrade(gs, hq_id) catch |err| switch (err) {
        error.ProjectInProgress => return error.ProjectInProgress,
        error.MaxLevel => return error.MaxLevel,
        error.UnknownHq => return error.UnknownHq,
        error.OutOfMemory => return error.OutOfMemory,
    };
    try treasury.debit(gs, .{ .hq = hq_id }, .{
        .day = gs.clock.day_index,
        .amount = -tier_upgrade_cost,
        .category = .hq_construction,
        .hq = hq_id,
        .note = "regional upgrade",
    });
}

/// Recruit and post admins until an HQ meets its staffing requirement.
pub fn autostaff(gs: *GameState, hq_id: types.HqId) !void {
    _ = staffHqToRequirement(gs, hq_id) catch |err| switch (err) {
        error.UnknownHq => return error.UnknownHq,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

/// Fabricate structural components in the HQ mek bay.
pub fn fabricate(gs: *GameState, hq_id: types.HqId, part_key: []const u8, quantity: u32) !void {
    var actual_hq = hq_id;
    if (actual_hq == .none) actual_hq = gs.seat();
    if (gs.hqs.getPtr(actual_hq) == null) return error.UnknownHq;
    const def = part_mod.find(part_key) orelse return error.UnknownPart;
    if (!part_mod.isComponent(def.key)) return error.NotAComponent;
    if (baySlots(gs, actual_hq) == 0) return error.NoBay;
    if (!canFabricate(gs, actual_hq, def.key)) return error.BayTooSmall;
    const total = types.applyBp(types.applyBp(def.cost * quantity, market_mod.structural_fab_cost_mult_bp), gs.diff().fab_cost_bp);
    try gs.bay_jobs.ensureUnusedCapacity(gs.allocator(), quantity);
    try gs.reserveLedger(1);
    try treasury.debit(gs, .{ .hq = actual_hq }, .{
        .day = gs.clock.day_index,
        .amount = -total,
        .category = .fabrication,
        .hq = actual_hq,
        .note = def.name,
    });
    try queueFabrication(gs, actual_hq, def.key, quantity);
}

/// Build or level up a facility at an HQ.
pub fn upgradeFacility(gs: *GameState, hq_id: types.HqId, kind: hq_mod.FacilityKind) !void {
    const hq = gs.hqs.getPtr(hq_id) orelse return error.UnknownHq;
    if (upgradeBlock(gs, hq_id, kind)) |why| return switch (why) {
        .in_progress => error.ProjectInProgress,
        .maxed => error.MaxLevel,
        .funds_short => error.InsufficientTreasury,
    };
    const to_level = hq.facilityLevel(kind) + 1;
    const cost = hq_mod.upgradeCost(kind, to_level);
    try hq.projects.ensureUnusedCapacity(gs.allocator(), 1);
    try gs.reserveLedger(1);
    try treasury.debit(gs, .{ .hq = hq_id }, .{
        .day = gs.clock.day_index,
        .amount = -cost,
        .category = .hq_construction,
        .hq = hq_id,
        .note = @tagName(kind),
    });
    startUpgrade(gs, hq_id, kind) catch |err| switch (err) {
        error.ProjectInProgress => return error.ProjectInProgress,
        error.MaxLevel => return error.MaxLevel,
        error.UnknownHq => return error.UnknownHq,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

/// Sell off an HQ (not the last one; companies must be reassigned first).
pub fn sellHq(gs: *GameState, hq_id: types.HqId) !void {
    const h = gs.hqs.getPtr(hq_id) orelse return error.UnknownHq;
    if (gs.hqs.count() <= 1) return error.LastHq;
    if (toe.companiesAtHq(gs, hq_id) > 0) return error.HqInUse;
    const value = market_mod.hqSaleValue(h) + h.funds;
    const name = h.name;
    var pit = gs.people.iterator();
    while (pit.next()) |e| if (e.value_ptr.posted_hq == hq_id) {
        e.value_ptr.posted_hq = .none;
    };
    var i: usize = 0;
    while (i < gs.bay_jobs.items.len) {
        if (gs.bay_jobs.items[i].hq == hq_id) {
            if (gs.unit(gs.bay_jobs.items[i].unit)) |u| {
                if (u.status == .repairing) u.status = .damaged;
                if (u.status == .refitting) u.status = .ready;
            }
            _ = gs.bay_jobs.orderedRemove(i);
        } else i += 1;
    }
    i = 0;
    while (i < gs.hq_links.items.len) {
        const l = gs.hq_links.items[i];
        if (l.a == hq_id or l.b == hq_id) _ = gs.hq_links.orderedRemove(i) else i += 1;
    }
    i = 0;
    while (i < gs.candidates.items.len) {
        if (gs.candidates.items[i].hq == hq_id) _ = gs.candidates.orderedRemove(i) else i += 1;
    }
    i = 0;
    while (i < gs.market_listings.items.len) {
        if (gs.market_listings.items[i].hq == hq_id) _ = gs.market_listings.orderedRemove(i) else i += 1;
    }
    // Its standing orders, reorder points and the goods on the road
    // to it go with it; transports berthed there move to the seat.
    i = 0;
    while (i < gs.policies.items.len) {
        if (std.meta.eql(gs.policies.items[i].entity, .{ .hq = hq_id })) _ = gs.policies.orderedRemove(i) else i += 1;
    }
    i = 0;
    while (i < gs.stock_policies.items.len) {
        if (gs.stock_policies.items[i].hq == hq_id) _ = gs.stock_policies.orderedRemove(i) else i += 1;
    }
    for (gs.part_orders.items) |*o| if (o.inFlight() and std.meta.eql(o.dest, .{ .hq = hq_id })) {
        o.status = .cancelled;
    };
    // Money already dispatched to the sold HQ still lands — at the outfit.
    for (gs.fund_couriers.items) |*c| if (std.meta.eql(c.to, .{ .hq = hq_id })) {
        c.to = .outfit;
    };
    _ = gs.hqs.orderedRemove(hq_id);
    const seat: types.HqId = gs.seat();
    var uit2 = gs.units.iterator();
    while (uit2.next()) |e| if (e.value_ptr.berth_hq == hq_id) {
        e.value_ptr.berth_hq = seat;
    };
    refreshHqStaffing(gs);
    try gs.postTransaction(.{ .day = gs.clock.day_index, .amount = value, .category = .unit_sale, .note = "HQ sold" });
    try gs.log(.market, .{}, "[sale] {s} sold off for {d}", .{ name, value });
}

/// Send a hull to the depot for structural repair; returns the HQ whose bay took it.
pub fn depot(gs: *GameState, unit_id: types.UnitId) !types.HqId {
    const u = gs.unit(unit_id) orelse return error.UnknownUnit;
    if (!u.needsDepot()) return error.NothingToRepair;
    if (posture.isCompanyDeployed(gs, gs.companyOf(u.force))) return error.UnitDeployed;
    if (!posture.isCompanyHome(gs, gs.companyOf(u.force))) return error.UnitAway;
    const queued = queueDepotRepair(gs, unit_id) catch |err| return switch (err) {
        error.NoHq => error.NoHq,
        error.NoBay => error.NoBay,
        error.UnknownUnit => error.UnknownUnit,
        error.WrittenOff => error.WrittenOff,
        error.MissingComponents => error.MissingComponents,
        error.OutOfMemory => error.OutOfMemory,
    };
    if (!queued) return error.MissingComponents;
    return depotHqFor(gs, u);
}

/// Reactivate a mothballed hull (queues a bay job).
pub fn reactivate(gs: *GameState, unit_id: types.UnitId) !void {
    const u = gs.unit(unit_id) orelse return error.UnknownUnit;
    if (u.status != .mothballed) return error.NotMothballed;
    if (hasJobForUnit(gs, unit_id)) return error.ProjectInProgress;
    try queueReactivation(gs, unit_id);
}

// ---- C4b exec wrappers ----
const Error = commands.Error;
const Result = commands.Result;
const Command = commands.Command;

pub fn execFoundHq(gs: *GameState, f: @FieldType(Command, "found_hq")) Error!Result {
    const hq_id = foundHq(gs, f.name, f.planet_key) catch |err| return @errorCast(err);
    return .{ .created_hq = hq_id };
}

pub fn execUpgradeTier(gs: *GameState, hq_id: @FieldType(Command, "upgrade_tier")) Error!Result {
    upgradeTier(gs, hq_id) catch |err| return @errorCast(err);
    return .{};
}

pub fn execAutostaff(gs: *GameState, hq_id: @FieldType(Command, "autostaff")) Error!Result {
    autostaff(gs, hq_id) catch |err| return @errorCast(err);
    return .{};
}

pub fn execSellHq(gs: *GameState, hq_id: @FieldType(Command, "sell_hq")) Error!Result {
    sellHq(gs, hq_id) catch |err| return @errorCast(err);
    return .{};
}

pub fn execReactivate(gs: *GameState, unit_id: @FieldType(Command, "reactivate")) Error!Result {
    reactivate(gs, unit_id) catch |err| return @errorCast(err);
    return .{};
}

pub fn execFabricate(gs: *GameState, f0: @FieldType(Command, "fabricate")) Error!Result {
    fabricate(gs, f0.hq, f0.part_key, f0.quantity) catch |err| return @errorCast(err);
    return .{};
}

pub fn execUpgradeFacility(gs: *GameState, u: @FieldType(Command, "upgrade_facility")) Error!Result {
    upgradeFacility(gs, u.hq, u.kind) catch |err| return @errorCast(err);
    return .{};
}

pub fn execDepot(gs: *GameState, unit_id: @FieldType(Command, "depot")) Error!Result {
    const hq_id = depot(gs, unit_id) catch |err| return @errorCast(err);
    return .{ .hq = hq_id };
}

pub fn execCoverShortfall(gs: *GameState, c: @FieldType(Command, "cover_shortfall")) Error!Result {
    if (canFabricate(gs, c.hq, c.part_key)) {
        var res = try commands.execute(gs, .{ .fabricate = .{ .hq = c.hq, .part_key = c.part_key, .quantity = c.quantity } });
        res.fabricated = true;
        return res;
    }
    return commands.execute(gs, .{ .order_part = .{ .part_key = c.part_key, .quantity = c.quantity, .dest = .{ .hq = c.hq } } });
}

test "fabricate propagates OutOfMemory and changes nothing" {
    // `outer` owns every byte the campaign arena ever hands out, so
    // detaching the arena's own headroom tracking below cannot leak.
    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 55 });
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const hq_id = gs.seat();
    const funds_before = gs.hqs.values()[0].funds;
    const jobs_before = gs.bay_jobs.items.len;
    const stock_before = gs.stockCount(.{ .hq = hq_id }, "comp_leg");

    // Discard the arena's spare headroom and fail every further allocation
    // (calibrated: 500 bytes fails at `fabricate`'s very first step,
    // `bay_jobs.ensureUnusedCapacity`, verified against a stack trace):
    // the refusal must surface as OutOfMemory before the debit or the bay
    // job queue it reserves capacity for, not queue a job or spend funds.
    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    const buf = try std.testing.allocator.alloc(u8, 500);
    defer std.testing.allocator.free(buf);
    var fba = std.heap.FixedBufferAllocator.init(buf);
    gs.arena.child_allocator = fba.allocator();

    try std.testing.expectError(error.OutOfMemory, commands.execute(&gs, .{ .fabricate = .{ .hq = hq_id, .part_key = "comp_leg", .quantity = 3 } }));
    try std.testing.expectEqual(funds_before, gs.hqs.values()[0].funds);
    try std.testing.expectEqual(jobs_before, gs.bay_jobs.items.len);
    try std.testing.expectEqual(stock_before, gs.stockCount(.{ .hq = hq_id }, "comp_leg"));
}

test "depot propagates OutOfMemory instead of mapping it to NoBay" {
    // `outer` owns every byte the campaign arena ever hands out, so
    // detaching the arena's own headroom tracking below cannot leak.
    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 4001 });
    _ = try founding.createCommander(&gs, "T", .LC, .chief_engineer);
    const uid = try gs.addUnit("SHD-2H");
    const u = gs.unit(uid).?;
    u.slots.items[1].condition = .destroyed; // ct.structure -> comp_ct, seeded on the shelf

    // Discard the arena's spare headroom and fail every further allocation:
    // queueDepotRepair's bay-job append must surface as OutOfMemory, not NoBay.
    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;

    try std.testing.expectError(error.OutOfMemory, depot(&gs, uid));
}

test "queueDepotRepair leaves stock unchanged when bay-job allocation fails" {
    const digest = @import("digest.zig");

    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 4002 });
    _ = try founding.createCommander(&gs, "T", .LC, .chief_engineer);
    const hq_id = gs.seat();
    const uid = try gs.addUnit("SHD-2H");
    const u = gs.unit(uid).?;
    u.slots.items[1].condition = .destroyed; // ct.structure -> needs comp_ct

    // Verify the component is on the shelf (founding seeds it).
    try std.testing.expect(gs.stockCount(.{ .hq = hq_id }, "comp_ct") > 0);

    const before = digest.stateHash(&gs);

    // Block every further allocation: ensureUnusedCapacity on
    // bay_jobs must fail before any stock is consumed.
    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;

    try std.testing.expectError(error.OutOfMemory, queueDepotRepair(&gs, uid));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
}

test "repair odds favour the sharper tech and the better hull; the parts sum to 100" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1212 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .chief_engineer);
    const hq_id = gs.seat();
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
    _ = try founding.createCommander(&gs, "T", .LC, .chief_engineer); // mek_bay lv1 → 2 slots
    const hq_id = gs.seat();

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
    _ = try founding.createCommander(&gs, "T", .LC, .chief_engineer);
    const hq_id = gs.seat();
    const uid = try gs.addUnit("SHD-2H");
    const u = gs.unit(uid).?;
    u.slots.items[1].condition = .destroyed; // ct.structure → comp_ct
    u.slots.items[6].condition = .destroyed; // ll.structure → comp_leg

    // Warehouse seeded with one of each component: both available.
    try std.testing.expect(try queueDepotRepair(&gs, uid));
    try std.testing.expectEqual(@as(u32, 0), gs.stockCount(.{ .hq = hq_id }, "comp_ct"));
    try runDaily(&gs);
    try std.testing.expectEqual(unit_mod.UnitStatus.repairing, u.status);

    // The bench keeps a job that fails its repair check, so walk
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

test "depot refusal for a destroyed-but-intact hull leaves the hull untouched" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 36 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .chief_engineer);
    const hq_id = gs.seat();
    const uid = try gs.addUnit("SHD-2H");
    const u = gs.unit(uid).?;
    u.status = .destroyed; // crew killed, hull structure intact: coring rebuilds it

    // Strip every structural component the depot could take.
    for (part_mod.component_keys) |key| while (gs.takeStock(.{ .hq = hq_id }, key, 1)) {};

    try std.testing.expect(!(try queueDepotRepair(&gs, uid)));
    try std.testing.expectEqual(unit_mod.WreckCause.none, u.wreck);
    try std.testing.expectEqual(unit_mod.UnitStatus.destroyed, u.status);
    for (u.slots.items) |s| if (s.class == .structure) {
        try std.testing.expectEqual(unit_mod.PartCondition.ok, s.condition);
    };
}

test "one rule for structural needs: the depot, the demand ledger and the screens read the same list" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 34 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .chief_engineer);
    const hq_id = gs.seat();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    // Clear the seeded shelf so the shortfall is real.
    while (gs.takeStock(.{ .hq = hq_id }, "comp_ct", 1)) {}
    while (gs.takeStock(.{ .hq = hq_id }, "comp_torso", 1)) {}

    // An ammo wreck: centre torso and both sides gone,
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
    _ = try founding.createCommander(&gs, "T", .LC, .chief_engineer);
    const hq_id = gs.seat();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
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
    _ = try founding.createCommander(&gs, "T", .LC, .paymaster);
    const hq_id = gs.seat();
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

test "tier upgrade: refusals keep the money; a funded field HQ starts the project and pays once" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1230 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const home = gs.seat();
    const home_funds = gs.hqs.getPtr(home).?.funds;
    try std.testing.expectError(commands.Error.MaxLevel, commands.execute(&gs, .{ .upgrade_tier = home })); // already regional
    try std.testing.expectEqual(home_funds, gs.hqs.getPtr(home).?.funds);
    // A firebase with an empty till: refused, nothing debited, no project.
    const home_world = planet_mod.find(gs.hqs.getPtr(home).?.planet_key).?;
    var key: []const u8 = "";
    for (planet_mod.catalog) |*p| if (p != home_world and planet_mod.distanceLy(p, home_world) <= gs.hqs.getPtr(home).?.influenceLy() and key.len == 0) {
        key = p.key;
    };
    _ = try commands.execute(&gs, .{ .found_hq = .{ .name = "Firebase", .planet_key = key } });
    const fb = gs.hqs.keys()[1];
    gs.hqs.getPtr(fb).?.funds = 0;
    try std.testing.expectError(commands.Error.InsufficientTreasury, commands.execute(&gs, .{ .upgrade_tier = fb }));
    try std.testing.expectEqual(@as(usize, 0), gs.hqs.getPtr(fb).?.projects.items.len);
    // Funded: the project starts and the cost is paid exactly once.
    gs.hqs.getPtr(fb).?.funds = tier_upgrade_cost + 1;
    _ = try commands.execute(&gs, .{ .upgrade_tier = fb });
    try std.testing.expectEqual(@as(types.CBills, 1), gs.hqs.getPtr(fb).?.funds);
    try std.testing.expectEqual(@as(usize, 1), gs.hqs.getPtr(fb).?.projects.items.len);
    try std.testing.expectError(commands.Error.ProjectInProgress, commands.execute(&gs, .{ .upgrade_tier = fb }));
    try std.testing.expectEqual(@as(types.CBills, 1), gs.hqs.getPtr(fb).?.funds);
}

test "components — fabrication is guaranteed, purchase is a roll" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 55 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const hq_id = gs.seat();

    // The guarantee: fabrication always happens, at the premium, over bay
    // time (level-1 bay = 2 slots, so 3 legs take two 8-day rounds).
    const hq_funds_before = gs.hqs.values()[0].funds;
    _ = try commands.execute(&gs, .{ .fabricate = .{ .hq = hq_id, .part_key = "comp_leg", .quantity = 3 } });
    try std.testing.expect(gs.hqs.values()[0].funds < hq_funds_before);
    try std.testing.expectError(commands.Error.NotAComponent, commands.execute(&gs, .{
        .fabricate = .{ .hq = hq_id, .part_key = "mlas", .quantity = 1 },
    }));
    _ = try commands.execute(&gs, .{ .advance_days = 17 });
    try std.testing.expectEqual(@as(u32, 1 + 3), gs.stockCount(.{ .hq = hq_id }, "comp_leg")); // 1 seeded

    // Common parts source most months; failures cost nothing. Orders are
    // paid by the HQ treasury.
    const hq_before_order = gs.hqs.values()[0].funds;
    _ = try commands.execute(&gs, .{ .order_part = .{ .part_key = "mlas", .quantity = 2 } });
    const order = gs.part_orders.items[gs.part_orders.items.len - 1];
    if (order.status == .failed) {
        try std.testing.expectEqual(hq_before_order, gs.hqs.values()[0].funds);
    } else {
        try std.testing.expect(gs.hqs.values()[0].funds < hq_before_order);
        _ = try commands.execute(&gs, .{ .advance_days = 12 });
        try std.testing.expectEqual(@as(u32, 2), gs.spareCount("mlas"));
    }
    try std.testing.expectError(commands.Error.UnknownPart, commands.execute(&gs, .{ .order_part = .{ .part_key = "gauss", .quantity = 1 } }));
}

test "construction is paid by the HQ and the back office sets the pace" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 57 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .FS, .profession = .paymaster } });
    const hq_id = gs.seat();
    gs.hqs.values()[0].funds = 5_000_000;

    // Starter HQ staff are real people, posted, and cover the requirement.
    try std.testing.expect(hqStaff(&gs, hq_id, .admin_command).count > 0);
    try std.testing.expect(gs.hqs.values()[0].staff_assigned >= gs.hqs.values()[0].staffRequired().total());

    // Command admins push permits through: strip the office and paperwork
    // slows down; post them back and it recovers.
    const staffed = paperworkDaysFor(&gs, hq_id);
    var pit = gs.people.iterator();
    while (pit.next()) |entry| {
        if (entry.value_ptr.role == .admin_command) entry.value_ptr.posted_hq = .none;
    }
    refreshHqStaffing(&gs);
    const unstaffed = paperworkDaysFor(&gs, hq_id);
    try std.testing.expect(unstaffed > staffed);
    for (0..2) |_| {
        const id = try @import("personnel.zig").recruitGenerated(&gs, .admin_command, gs.homeHqFor(.none), .market);
        _ = try commands.execute(&gs, .{ .post_person = .{ .person = id, .hq = hq_id } });
    }
    try std.testing.expect(paperworkDaysFor(&gs, hq_id) < unstaffed);

    // Upgrade the mess: paid now from HQ funds, lands after its span.
    _ = try commands.execute(&gs, .{ .upgrade_facility = .{ .hq = hq_id, .kind = .mess } });
    try std.testing.expect(gs.hqs.values()[0].funds < 5_000_000);
    try std.testing.expectError(commands.Error.ProjectInProgress, commands.execute(&gs, .{ .upgrade_facility = .{ .hq = hq_id, .kind = .mess } }));
    const p = gs.hqs.values()[0].projects.items[0];
    _ = try commands.execute(&gs, .{ .advance_days = p.construction_done_day - gs.clock.day_index + 1 });
    try std.testing.expectEqual(@as(u8, 2), gs.hqs.values()[0].facilityLevel(.mess));
}

test "one HQ, one company — the second needs a second regional HQ" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 81 });
    defer gs.deinit();
    // A Combine commander: every DC world is within reach of Zebebelgenubi
    // and none within reach of Callison, whichever world the HQ landed on.
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .DC, .profession = .paymaster } });
    const home = gs.seat();

    const alpha = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    try std.testing.expectEqual(home, gs.force(alpha).?.supplying_hq);
    try std.testing.expectError(commands.Error.CapacityFull, commands.execute(&gs, .{ .new_company = "Bravo" }));

    // Found a field HQ on a reachable world: a forward base that hosts one
    // company as it stands, and only one.
    gs.funds = 20_000_000;
    try std.testing.expectError(commands.Error.NotReachable, commands.execute(&gs, .{ .found_hq = .{ .name = "Far", .planet_key = "callison" } }));
    _ = try commands.execute(&gs, .{ .found_hq = .{ .name = "Firebase", .planet_key = "zebebelgenubi" } });
    const fb = gs.hqs.keys()[1];
    const bravo = (try commands.execute(&gs, .{ .new_company_at = .{ .name = "Bravo", .hq = fb } })).created_force;
    try std.testing.expectEqual(fb, gs.force(bravo).?.supplying_hq);
    try std.testing.expectError(commands.Error.CapacityFull, commands.execute(&gs, .{ .new_company_at = .{ .name = "Charlie", .hq = fb } }));

    // Fund it (the courier takes as long as the jumps take), upgrade it to
    // regional, wait out the build: still one company, now with full service.
    _ = try commands.execute(&gs, .{ .transfer = .{ .from = .outfit, .to = .{ .hq = fb }, .amount = 4_000_000 } });
    while (gs.fund_couriers.items.len > 0) _ = try commands.execute(&gs, .{ .advance_days = 5 });
    _ = try commands.execute(&gs, .{ .upgrade_tier = fb });
    const p = gs.hqs.values()[1].projects.items[0];
    _ = try commands.execute(&gs, .{ .advance_days = p.construction_done_day - gs.clock.day_index + 1 });
    try std.testing.expectEqual(hq_mod.HqTier.regional, gs.hqs.values()[1].tier);
    _ = try commands.execute(&gs, .{ .autostaff = fb });
    try std.testing.expectError(commands.Error.CapacityFull, commands.execute(&gs, .{ .new_company_at = .{ .name = "Charlie", .hq = fb } }));

    // Link the two: shipments between them ride the link and count against it.
    _ = try commands.execute(&gs, .{ .link = .{ .a = home, .b = fb, .level = 1 } });
    try std.testing.expectEqual(@as(usize, 1), gs.hq_links.items.len);
    gs.hqs.values()[0].funds = 10_000_000;
    try gs.addStock(.{ .hq = home }, "armor", 60);
    _ = try commands.execute(&gs, .{ .ship_stock = .{ .part_key = "armor", .quantity = 30, .from = .{ .hq = home }, .to = .{ .hq = fb } } });
    try std.testing.expectError(commands.Error.ThroughputExceeded, commands.execute(&gs, .{
        .ship_stock = .{ .part_key = "armor", .quantity = 20, .from = .{ .hq = home }, .to = .{ .hq = fb } },
    }));

    // Transfer a mek Alpha → Bravo: different worlds, so it ships.
    const alpha_lance = gs.force(gs.force(alpha).?.children.items[0]).?;
    const uid = alpha_lance.units.items[0];
    _ = try commands.execute(&gs, .{ .transfer_unit = .{ .unit = uid, .to_company = bravo } });
    try std.testing.expectEqual(unit_mod.UnitStatus.in_transit, gs.unit(uid).?.status);
    _ = try commands.execute(&gs, .{ .advance_days = 40 });
    try std.testing.expectEqual(bravo, gs.companyOf(gs.unit(uid).?.force));
    try std.testing.expect(gs.unit(uid).?.tech == .none); // needs a Bravo tech
}

test "depot work happens at the hull's home HQ — its components, its bay — not the outfit's first one" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 97 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const home = gs.seat();
    // A second HQ in the home ring, raised to regional with a staffed bay.
    const home_world = planet_mod.find(gs.hqs.getPtr(home).?.planet_key).?;
    var key: []const u8 = "";
    for (planet_mod.catalog) |*p| if (p != home_world and planet_mod.distanceLy(p, home_world) <= gs.hqs.getPtr(home).?.influenceLy() and key.len == 0) {
        key = p.key;
    };
    _ = try commands.execute(&gs, .{ .found_hq = .{ .name = "Firebase", .planet_key = key } });
    const fb = gs.hqs.keys()[1];
    {
        const h = gs.hqs.getPtr(fb).?;
        h.tier = .regional;
        try h.facilities.append(gs.allocator(), .{ .kind = .mek_bay, .level = 1 });
        h.staff_assigned = 999; // fully staffed, so the bay counts (and hosts four lances)
    }
    const co = (try commands.execute(&gs, .{ .new_company_at = .{ .name = "Bravo", .hq = fb } })).created_force;
    try std.testing.expectEqual(fb, gs.homeHqFor(co));

    // One of Bravo's meks loses a side torso.
    var uid: types.UnitId = .none;
    var it = gs.units.iterator();
    while (it.next()) |e| if (e.value_ptr.kind == .mek and gs.companyOf(e.value_ptr.force) == co) {
        for (e.value_ptr.slots.items) |*s| if (s.class == .structure and std.mem.startsWith(u8, s.slot_key, "lt.")) {
            s.condition = .destroyed;
            uid = e.value_ptr.id;
            break;
        };
        if (uid != .none) break;
    };
    try std.testing.expect(uid != .none);

    // The torso assembly sits in Bravo's own depot; the first HQ has none.
    const torso = part_mod.componentFor("lt.structure", gs.unit(uid).?.chassis_key); // by weight class
    _ = gs.takeStock(.{ .hq = home }, torso, gs.stockCount(.{ .hq = home }, torso));
    _ = gs.takeStock(.{ .hq = fb }, torso, gs.stockCount(.{ .hq = fb }, torso));
    try gs.addStock(.{ .hq = fb }, torso, 1);
    _ = try commands.execute(&gs, .{ .depot = uid });
    try std.testing.expect(hasJobForUnit(&gs, uid));
    for (gs.bay_jobs.items) |j| if (j.unit == uid) try std.testing.expectEqual(fb, j.hq);
    try std.testing.expectEqual(@as(u32, 0), gs.stockCount(.{ .hq = fb }, torso));
}

test "a wreck is rebuilt in the depot — a component and bay time — and comes back ready" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 95 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    const home = gs.seat();
    gs.hqs.getPtr(home).?.staff_assigned = 999;
    var uid: types.UnitId = .none;
    var uit = gs.units.iterator();
    while (uit.next()) |e| if (e.value_ptr.kind == .mek and gs.companyOf(e.value_ptr.force) == co) {
        uid = e.value_ptr.id;
        break;
    };
    const u = gs.unit(uid).?;
    // Killed in action: destroyed, centre torso gone; a damaged ammo bin on top.
    u.markWrecked();
    for (u.slots.items) |*s| if (s.class == .ammo) {
        s.condition = .damaged;
        break;
    };
    try std.testing.expect(u.needsDepot());
    var ct_destroyed = false;
    for (u.slots.items) |s| if (std.mem.startsWith(u8, s.slot_key, "ct.") and s.class == .structure and s.condition == .destroyed) {
        ct_destroyed = true;
    };
    try std.testing.expect(ct_destroyed);

    // No centre torso on the shelf: the depot asks for it; with one, it queues.
    const ct = part_mod.componentFor("ct.structure", u.chassis_key); // by weight class
    _ = gs.takeStock(.{ .hq = home }, ct, gs.stockCount(.{ .hq = home }, ct));
    try std.testing.expectError(commands.Error.MissingComponents, commands.execute(&gs, .{ .depot = uid }));
    try gs.addStock(.{ .hq = home }, ct, 1);
    _ = try commands.execute(&gs, .{ .depot = uid });
    try std.testing.expect(hasJobForUnit(&gs, uid));
    try std.testing.expectEqual(@as(u32, 0), gs.stockCount(.{ .hq = home }, ct));
    // Bay time passes (a failed check redoes the work); the wreck is a hull again.
    var days: u32 = 0;
    while (hasJobForUnit(&gs, uid) and days < 300) : (days += 1) {
        try runDaily(&gs);
        gs.clock.day_index += 1;
    }
    try std.testing.expect(!hasJobForUnit(&gs, uid));
    try std.testing.expectEqual(unit_mod.UnitStatus.ready, gs.unit(uid).?.status);
    try std.testing.expect(!gs.unit(uid).?.needsDepot());

    // A wreck from an older save — destroyed, structure untouched — gets its wreck on the way in.
    const legacy = try gs.addUnit("LCT-1V");
    gs.unit(legacy).?.status = .destroyed;
    try std.testing.expect(gs.unit(legacy).?.needsDepot());
    try gs.addStock(.{ .hq = home }, "comp_ct_l", 1); // a Locust's centre torso is a light assembly
    _ = try commands.execute(&gs, .{ .depot = legacy });
    try std.testing.expect(hasJobForUnit(&gs, legacy));
    try std.testing.expectEqual(@as(u32, 0), gs.stockCount(.{ .hq = home }, "comp_ct_l"));
}

test "how a hull died decides the rebuild — engine kills cost an engine, scrap only strips" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1202 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const home = gs.seat();
    gs.hqs.getPtr(home).?.staff_assigned = 999;

    // An ammunition explosion guts both side torsos and needs an engine.
    const boom = try gs.addUnit("SHD-2H");
    gs.unit(boom).?.markWreckedBy(.ammo);
    var torsos: u32 = 0;
    for (gs.unit(boom).?.slots.items) |s| if (s.class == .structure and s.condition == .destroyed) {
        torsos += 1;
    };
    try std.testing.expectEqual(@as(u32, 3), torsos); // ct + lt + rt
    // TechManual engine price for the Shadow Hawk (55 t, walk 5 → 275).
    try std.testing.expectEqual(@as(types.CBills, 5_000 * 275 * 55 / 75), engineCharge(gs.unit(boom).?));
    try gs.addStock(.{ .hq = home }, "comp_ct", 1);
    try gs.addStock(.{ .hq = home }, "comp_torso", 2);
    _ = try commands.execute(&gs, .{ .depot = boom });
    var job_cost: types.CBills = 0;
    var job_days: u32 = 0;
    for (gs.bay_jobs.items) |j| if (j.unit == boom) {
        job_cost = j.cost;
        job_days = j.duration_days;
    };
    try std.testing.expect(job_cost >= engineCharge(gs.unit(boom).?));
    try std.testing.expect(job_days >= tuning.loss.engine_rebuild_days);
    try std.testing.expect(rebuildEstimate(&gs, gs.unit(boom).?) != null);

    // Scrap is refused by the depot and priced as parts.
    const junk = try gs.addUnit("SHD-2H");
    gs.unit(junk).?.markWreckedBy(.scrap);
    gs.unit(junk).?.armor_pct = 50;
    try std.testing.expectError(commands.Error.WrittenOff, commands.execute(&gs, .{ .depot = junk }));
    try std.testing.expect(rebuildEstimate(&gs, gs.unit(junk).?) == null);
    try std.testing.expect(beyondEconomicalRepair(&gs, gs.unit(junk).?));
    try std.testing.expect(try market_mod.unitSaleValue(std.testing.allocator, gs.unit(junk).?) > 0); // the guns are still worth something

    // Stripping crates the guns and the armour left on it, and the hull is gone.
    const ac5_before = gs.stockCount(.{ .hq = home }, "ac5");
    const armor_before = gs.stockCount(.{ .hq = home }, "armor");
    const ct_before = gs.stockCount(.{ .hq = home }, "comp_ct");
    _ = try commands.execute(&gs, .{ .strip_unit = junk });
    try std.testing.expect(gs.unit(junk) == null);
    try std.testing.expectEqual(ac5_before + 1, gs.stockCount(.{ .hq = home }, "ac5"));
    try std.testing.expect(gs.stockCount(.{ .hq = home }, "armor") > armor_before);
    try std.testing.expectEqual(ct_before, gs.stockCount(.{ .hq = home }, "comp_ct")); // scrap has no structure left
}

test "heavy assemblies need a level-2 bay, assault ones a level-3 bay at a regional HQ" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1208 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const hq_id = gs.seat();
    const h = gs.hqs.getPtr(hq_id).?;
    h.staff_assigned = 999;
    h.funds = 50_000_000;
    const bay = for (h.facilities.items) |*f| {
        if (f.kind == .mek_bay) break f;
    } else return error.TestUnexpectedResult;
    bay.level = 1;
    _ = try commands.execute(&gs, .{ .fabricate = .{ .hq = hq_id, .part_key = "comp_ct_l", .quantity = 1 } });
    _ = try commands.execute(&gs, .{ .fabricate = .{ .hq = hq_id, .part_key = "comp_ct", .quantity = 1 } });
    try std.testing.expectError(commands.Error.BayTooSmall, commands.execute(&gs, .{ .fabricate = .{ .hq = hq_id, .part_key = "comp_ct_h", .quantity = 1 } }));
    bay.level = 2;
    _ = try commands.execute(&gs, .{ .fabricate = .{ .hq = hq_id, .part_key = "comp_ct_h", .quantity = 1 } });
    try std.testing.expectError(commands.Error.BayTooSmall, commands.execute(&gs, .{ .fabricate = .{ .hq = hq_id, .part_key = "comp_ct_a", .quantity = 1 } }));
    bay.level = 3;
    _ = try commands.execute(&gs, .{ .fabricate = .{ .hq = hq_id, .part_key = "comp_ct_a", .quantity = 1 } });
    // A field HQ never builds assault assemblies, whatever its bay.
    h.tier = .field;
    try std.testing.expect(!canFabricate(&gs, hq_id, "comp_ct_a"));
    try std.testing.expect(canFabricate(&gs, hq_id, "comp_ct_h"));
}

test "an upgrade the HQ cannot afford is refused before a C-bill moves, from the same rule the screen dims on" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 909 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const hq = gs.seat();
    gs.hqs.getPtr(hq).?.funds = 1;
    try std.testing.expectEqual(UpgradeBlock.funds_short, upgradeBlock(&gs, hq, .mess).?);
    try std.testing.expectError(commands.Error.InsufficientTreasury, commands.execute(&gs, .{ .upgrade_facility = .{ .hq = hq, .kind = .mess } }));
    try std.testing.expectEqual(@as(types.CBills, 1), gs.hqs.getPtr(hq).?.funds);
    gs.hqs.getPtr(hq).?.funds = 50_000_000;
    try std.testing.expect(upgradeBlock(&gs, hq, .mess) == null);
    _ = try commands.execute(&gs, .{ .upgrade_facility = .{ .hq = hq, .kind = .mess } });
    try std.testing.expectEqual(UpgradeBlock.in_progress, upgradeBlock(&gs, hq, .mess).?);
}

test "selling an HQ redirects its in-flight courier to the outfit treasury, not into the void" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 91 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .DC, .profession = .paymaster } });
    gs.funds = 20_000_000;
    _ = try commands.execute(&gs, .{ .found_hq = .{ .name = "Far", .planet_key = "zebebelgenubi" } });
    const far = gs.hqs.keys()[1];
    _ = try commands.execute(&gs, .{ .transfer = .{ .from = .outfit, .to = .{ .hq = far }, .amount = 1_000_000 } });
    try std.testing.expectEqual(@as(usize, 1), gs.fund_couriers.items.len);
    const eta = gs.fund_couriers.items[0].eta_day;
    try std.testing.expect(eta > gs.clock.day_index);

    // Sell Far before the courier lands: the money must not vanish.
    _ = try commands.execute(&gs, .{ .sell_hq = far });
    try std.testing.expectEqual(@as(usize, 1), gs.fund_couriers.items.len);
    try std.testing.expectEqual(state_mod.Treasury.outfit, gs.fund_couriers.items[0].to);
    try std.testing.expectEqual(@as(types.CBills, 1_000_000), gs.fund_couriers.items[0].amount);
    const funds_after_sale = gs.funds;

    const ledger_before = gs.ledger.transactions.items.len;
    while (gs.clock.day_index < eta) _ = try commands.execute(&gs, .{ .advance_days = 1 });
    try std.testing.expectEqual(@as(usize, 0), gs.fund_couriers.items.len);
    try std.testing.expectEqual(funds_after_sale + 1_000_000, gs.funds);

    var found = false;
    for (gs.ledger.transactions.items[ledger_before..]) |t| if (t.category == .fund_transfer and t.amount == 1_000_000) {
        found = true;
    };
    try std.testing.expect(found);
}

test "selling an HQ resets a repairing hull instead of leaving it stuck" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 91 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .DC, .profession = .paymaster } });
    gs.funds = 20_000_000;
    _ = try commands.execute(&gs, .{ .found_hq = .{ .name = "Far", .planet_key = "zebebelgenubi" } });
    const far = gs.hqs.keys()[1];

    const uid = try gs.addUnit("SHD-2H");
    const u = gs.unit(uid).?;
    u.status = .repairing;
    try gs.bay_jobs.append(gs.allocator(), .{
        .hq = far,
        .kind = .depot_repair,
        .unit = uid,
        .duration_days = 10,
        .queued_day = gs.clock.day_index,
    });

    _ = try commands.execute(&gs, .{ .sell_hq = far });
    try std.testing.expectEqual(unit_mod.UnitStatus.damaged, u.status);
}

test "selling an HQ resets a refitting hull instead of leaving it stuck" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 91 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .DC, .profession = .paymaster } });
    gs.funds = 20_000_000;
    _ = try commands.execute(&gs, .{ .found_hq = .{ .name = "Far", .planet_key = "zebebelgenubi" } });
    const far = gs.hqs.keys()[1];

    const uid = try gs.addUnit("SHD-2H");
    const u = gs.unit(uid).?;
    u.status = .refitting;
    try gs.bay_jobs.append(gs.allocator(), .{
        .hq = far,
        .kind = .refit,
        .unit = uid,
        .duration_days = 10,
        .queued_day = gs.clock.day_index,
    });

    _ = try commands.execute(&gs, .{ .sell_hq = far });
    try std.testing.expectEqual(unit_mod.UnitStatus.ready, u.status);
}

test "a failed foundHq leaves state unchanged" {
    const digest = @import("digest.zig");

    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 92 });
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);

    const before = digest.stateHash(&gs);

    // Block every further allocation. prepareHq's first allocation (the
    // HQ name dupe) must fail before anything commits.
    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;

    try std.testing.expectError(error.OutOfMemory, foundHq(&gs, "Far", "alkaid"));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
}

test "upgradeTier leaves the HQ, its projects, the log and the ledger unchanged when an allocation fails" {
    const digest = @import("digest.zig");

    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 1230 });
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const home = gs.seat();
    const home_world = planet_mod.find(gs.hqs.getPtr(home).?.planet_key).?;
    var key: []const u8 = "";
    for (planet_mod.catalog) |*p| if (p != home_world and planet_mod.distanceLy(p, home_world) <= gs.hqs.getPtr(home).?.influenceLy() and key.len == 0) {
        key = p.key;
    };
    _ = try commands.execute(&gs, .{ .found_hq = .{ .name = "Firebase", .planet_key = key } });
    const fb = gs.hqs.keys()[1];
    gs.hqs.getPtr(fb).?.funds = tier_upgrade_cost + 1;

    const before = digest.stateHash(&gs);

    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;

    try std.testing.expectError(error.OutOfMemory, commands.execute(&gs, .{ .upgrade_tier = fb }));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
}

test "a due depot-repair bay job is unchanged — no RNG consumed, no treasury debit — when the first allocation fails" {
    const digest = @import("digest.zig");

    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 5050 });
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const hq = gs.seat();
    gs.hqs.getPtr(hq).?.funds = 5_000_000;
    const uid = try gs.addUnit("LCT-1V");
    gs.unit(uid).?.status = .repairing;

    // Plant a depot-repair job that is due today (day 0).
    try gs.bay_jobs.append(gs.allocator(), .{
        .hq = hq,
        .kind = .depot_repair,
        .unit = uid,
        .duration_days = 0,
        .queued_day = 0,
        .started_day = 0,
        .done_day = 0,
        .cost = 10_000,
    });

    const before = digest.stateHash(&gs);
    const unit_status_before = gs.unit(uid).?.status;
    const funds_before = gs.hqs.getPtr(hq).?.funds;

    // Block all further allocations: reserveLog(n_logs) — the first call inside
    // completeJob — fails before rollRepair ever runs (no RNG consumed).
    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;

    try std.testing.expectError(error.OutOfMemory, runDaily(&gs));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    try std.testing.expectEqual(@as(usize, 1), gs.bay_jobs.items.len);
    try std.testing.expectEqual(unit_status_before, gs.unit(uid).?.status);
    try std.testing.expectEqual(funds_before, gs.hqs.getPtr(hq).?.funds);
}

test "bay-job injure-branch: when the bay accident fires the injury is atomically committed" {
    // Scan seeds until one produces a completed depot-repair with a bay accident
    // (roll2d6(.medical) == 2 in the commit tail).  With ≈2.8% per-seed odds,
    // 500 seeds reliably yields several hits.  For each hit verify:
    //   - the job is gone (the repair completed)
    //   - the tech is wounded and their injuries list is non-empty
    //   - status and list are consistent (no partial injury state)
    const crew_m = @import("crew.zig");
    var found: bool = false;
    for (5051..5551) |seed_val| {
        var gs = GameState.init(std.testing.allocator, .{ .seed = @intCast(seed_val) });
        defer gs.deinit();
        _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
        const hq2 = gs.seat();
        gs.hqs.getPtr(hq2).?.funds = 5_000_000;
        const uid2 = try gs.addUnit("LCT-1V");
        gs.unit(uid2).?.status = .repairing;
        const tech_id = try gs.hirePerson("Ace", "Wrench", .tech_mek);
        try crew_m.assignSlot(&gs, uid2, .tech, tech_id);
        try gs.bay_jobs.append(gs.allocator(), .{
            .hq = hq2,
            .kind = .depot_repair,
            .unit = uid2,
            .duration_days = 0,
            .queued_day = 0,
            .started_day = 0,
            .done_day = 0,
            .cost = 0,
        });

        const jobs_before = gs.bay_jobs.items.len;
        try runDaily(&gs);

        const job_done = gs.bay_jobs.items.len < jobs_before;
        const tech = gs.person(tech_id).?;
        if (job_done and tech.status == .wounded) {
            // Bay accident fired and injury was committed.
            // Verify atomicity: status and injuries list are both present.
            try std.testing.expect(tech.injuries.items.len > 0);
            // wound_heal_day is null: the medbay has not triaged yet.
            try std.testing.expectEqual(@as(?u32, null), tech.wound_heal_day);
            found = true;
            break;
        }
    }
    // The seed range must contain at least one hit.
    try std.testing.expect(found);
}
