//! Weekly maintenance checks and repair work (Stage 5, ARCH §9.7), on the
//! Stage 9C.2 tech-time budget: every hull needs an assigned tech, every
//! tech has weekly hours, and hulls nobody has hours for roll uncovered.
//! Mirrors MekHQ's maintenance system: tech skill vs. a target number from
//! quality and conditions; failures drift quality A-ward and break parts.
//! Techs get hurt doing it, and free techs are swapped in when they do.

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const unit_mod = @import("../domain/unit.zig");
const part_mod = @import("../domain/part.zig");
const person_mod = @import("../domain/person.zig");
const chassis_mod = @import("../domain/chassis.zig");
const hq_ops = @import("hq_ops.zig");
const GameState = @import("state.zig").GameState;

/// Hours a field repair costs the hull's tech (tuning.maintenance).
const hours_damaged_slot = tuning.maintenance.hours_damaged_slot;
const hours_destroyed_slot = tuning.maintenance.hours_destroyed_slot;
const hours_armor_patch = tuning.maintenance.hours_armor_patch;

/// Hours and labour for one field job on a slot (tuning.maintenance):
/// one rule for the weekly pass and the field repair push (12G.6).
fn slotHours(wrecked: bool) u32 {
    return if (wrecked) hours_destroyed_slot else hours_damaged_slot;
}

fn slotLabour(part_key: []const u8, wrecked: bool) types.CBills {
    return @divTrunc(part_mod.cost(part_key), if (wrecked) tuning.maintenance.labour_destroyed_divisor else tuning.maintenance.labour_damaged_divisor);
}

/// Bill repair labour and materials, scaled by the commander's bonus.
fn postRepairLabour(gs: *GameState, labour: types.CBills) !void {
    if (labour <= 0) return;
    try gs.postTransaction(.{
        .day = gs.clock.day_index,
        .amount = -types.applyBp(labour, gs.commanderMultBp(.repair)),
        .category = .maintenance,
        .note = "repair labor & materials",
    });
}

/// Remaining weekly hours per tech, built lazily as hulls come up.
const HourBook = struct {
    map: std.AutoHashMapUnmanaged(types.PersonId, u32) = .empty,
    alloc: std.mem.Allocator,

    fn spend(self: *HourBook, gs: *GameState, tech: *const person_mod.Person, hours: u32, base_load: u32) !bool {
        const entry = try self.map.getOrPut(self.alloc, tech.id);
        if (!entry.found_existing) entry.value_ptr.* = gs.techHoursAvailable(tech) -| base_load;
        if (entry.value_ptr.* < hours) return false;
        entry.value_ptr.* -= hours;
        return true;
    }
};

fn unitTonnage(u: *const unit_mod.Unit) u8 {
    return if (chassis_mod.find(u.chassis_key)) |d| d.tonnage else 50;
}

/// Weekly consumables a hull eats in maintenance: its price over the
/// tuned divisor. The employer's cost reckoning sums it by the month.
pub fn weeklyConsumables(u: *const unit_mod.Unit) types.CBills {
    return @divTrunc(u.purchase_price, tuning.maintenance.consumables_divisor);
}

/// Expected monthly maintenance consumables across the outfit (52 weeks
/// over 12 months), for the employer's per-company cost.
pub fn monthlyConsumablesEstimate(gs: *GameState) types.CBills {
    var total: types.CBills = 0;
    var it = gs.units.iterator();
    while (it.next()) |entry| {
        const u = entry.value_ptr;
        if (u.status == .mothballed or u.kind == .infantry) continue;
        total += weeklyConsumables(u);
    }
    return @divTrunc(total * 52, 12);
}

/// The hull's tech if assigned and fit for duty today.
fn activeTech(gs: *GameState, u: *const unit_mod.Unit) ?*person_mod.Person {
    const t = gs.person(u.tech) orelse return null;
    return if (t.isAvailable(gs.clock.day_index)) t else null;
}

/// Weekly maintenance: one check per active hull, worked by its tech from
/// their hour budget; no tech (or no hours) → rolls uncovered (tuning.maintenance).
pub fn runWeeklyMaintenance(gs: *GameState) !void {
    var book: HourBook = .{ .alloc = gs.scratch() };
    defer book.map.deinit(book.alloc);
    var upkeep_cost: types.CBills = 0;

    var it = gs.units.iterator();
    while (it.next()) |entry| {
        const u = entry.value_ptr;
        if (!u.takesFieldWork()) continue;
        if (u.kind == .infantry) continue; // platoons maintain their own kit

        // What this hull asks of this tech (12C.15): quality, design and skill.
        const need_hours = if (activeTech(gs, u)) |t| gs.techHoursFor(t, u) else gs.hullHours(u);
        var covered = false;
        var skill: u8 = 7;
        var tech_id: types.PersonId = .none;
        if (activeTech(gs, u)) |t| {
            if (try book.spend(gs, t, need_hours, 0)) {
                covered = true;
                skill = t.skill(unit_mod.techRoleFor(u.kind).?.primarySkill()) orelse 7;
                tech_id = t.id;
            }
        }

        const deployed = gs.isCompanyDeployed(gs.companyOf(u.force));
        var tn: i32 = tuning.maintenance.target_base + u.quality.maintenanceModifier();
        if (deployed) tn += tuning.maintenance.target_deployed; // field conditions
        if (!covered) tn += tuning.maintenance.target_uncovered; // nobody turning wrenches

        const raw = gs.rng.roll2d6(.maintenance);
        const total: i32 = @as(i32, raw) + (5 - @as(i32, skill));

        const before_q = u.quality;
        if (total <= tn - tuning.maintenance.quality_drop_margin) {
            // Clear miss: quality drifts toward A; a snake-eyes week also
            // breaks a piece of gear (weapon, equipment, ammo feed, armor —
            // field-fixable). Neglect never cores a torso: structure is
            // battle damage (12.19: a quiet garrison was filling the depot).
            const q = @intFromEnum(u.quality);
            if (q > 0) u.quality = @enumFromInt(q - 1);
            if (raw == 2 and u.slots.items.len > 0) {
                var gear: u32 = 0;
                for (u.slots.items) |s| if (s.class != .structure) {
                    gear += 1;
                };
                if (gear > 0) {
                    var pick = gs.rng.random(.maintenance).uintLessThan(u32, gear);
                    for (u.slots.items) |*slot| {
                        if (slot.class == .structure) continue;
                        if (pick == 0) {
                            slot.condition = switch (slot.condition) {
                                .ok => .damaged,
                                .damaged => .destroyed,
                                else => slot.condition,
                            };
                            break;
                        }
                        pick -= 1;
                    }
                }
            }
        } else if (total >= tn + tuning.maintenance.quality_rise_margin) {
            // Exceptional work slowly restores a machine (rare by design).
            const q = @intFromEnum(u.quality);
            if (q < 5) u.quality = @enumFromInt(q + 1);
        }
        // Quality drift is news (12C.13): the letter on the resale ticket moved.
        if (u.quality != before_q) try gs.log(.construction, .{ .company = gs.companyOf(u.force) }, "[maintenance] {s} #{d} quality {s} {s} → {s}{s}", .{
            u.chassis_key, @intFromEnum(u.id), if (@intFromEnum(u.quality) < @intFromEnum(before_q)) "slips" else "lifts", @tagName(before_q), @tagName(u.quality), if (!covered) " (nobody turning wrenches)" else "",
        });

        // Accidents happen in the hangar (Stage 9C.2): snake-eyes while
        // working a hull, and then only one bad week in twelve hurts the
        // tech (≈0.23% per hull-week; a 32-hull company sees one every
        // three months or so; tuning.maintenance.accident_*).
        if (covered and raw == 2 and gs.rng.roll2d6(.maintenance) <= tuning.maintenance.accident_target) try injureTech(gs, tech_id, tuning.maintenance.accident_days_base + gs.rng.roll2d6(.medical), "maintenance accident");

        if (covered) {
            u.last_maintenance_day = gs.clock.day_index;
            upkeep_cost += weeklyConsumables(u);
        }
    }

    if (upkeep_cost > 0) {
        try gs.postTransaction(.{
            .day = gs.clock.day_index,
            .amount = -types.applyBp(upkeep_cost, gs.commanderMultBp(.repair)),
            .category = .maintenance,
            .note = "weekly maintenance consumables",
        });
    }
}

/// A tech goes down: wounded for `days`, and every hull they covered gets a
/// free tech swapped in if one exists — logged either way, surfaced in the
/// end-turn checklist as an open slot otherwise.
pub fn injureTech(gs: *GameState, tech_id: types.PersonId, days: u32, cause: []const u8) !void {
    const t = gs.person(tech_id) orelse return;
    if (t.status != .active) return;
    // The accident's size sets the wound (Stage 12.16): a short spell is a
    // light injury, a long one serious, the worst crippling.
    const severity: u8 = if (days <= tuning.maintenance.injury_days_serious) 1 else if (days <= tuning.maintenance.injury_days_crippling) 2 else 3;
    try @import("medical.zig").inflict(gs, tech_id, .accident, severity, cause);
    const company = gs.companyOf(t.assigned_force);

    var swapped: u32 = 0;
    var open: u32 = 0;
    var it = gs.units.iterator();
    while (it.next()) |entry| {
        const u = entry.value_ptr;
        if (u.tech != tech_id) continue;
        const role = unit_mod.techRoleFor(u.kind) orelse continue;
        const hours = gs.hullHours(u);
        if (gs.findFreeTech(role, gs.companyOf(u.force), hours)) |replacement| {
            u.tech = replacement;
            swapped += 1;
        } else {
            u.tech = .none;
            open += 1;
        }
    }
    if (swapped + open > 0) {
        try gs.log(.medical, .{ .company = company }, "[roster] {d} hull(s) reassigned to free techs, {d} left without a tech", .{ swapped, open });
    }
}

/// Weekly repair pass: field work by the hull's own tech from their spare
/// hours; depot work becomes a bay job (Stage 9C). Destroyed parts consume
/// spares from the hull's site.
pub fn runWeeklyRepairs(gs: *GameState) !void {
    var depot_ok = false;
    var hqit = gs.hqs.iterator();
    while (hqit.next()) |entry| {
        if (entry.value_ptr.supportsStructuralRepair()) depot_ok = true;
    }
    var book: HourBook = .{ .alloc = gs.scratch() };
    defer book.map.deinit(book.alloc);

    var labor_cost: types.CBills = 0;
    var it = gs.units.iterator();
    while (it.next()) |entry| {
        const u = entry.value_ptr;
        if (!u.takesFieldWork()) continue;
        const tech = activeTech(gs, u) orelse continue; // no tech, no repairs
        const base_load = gs.techLoadHours(tech.id);
        const at_home = gs.isCompanyHome(gs.companyOf(u.force)); // not merely off contract: a company returning or idling afield is away too
        const site = gs.siteForForce(u.force);

        for (u.slots.items) |*slot| {
            const tier = unit_mod.repairTier(slot.class, slot.condition) orelse continue;
            switch (tier) {
                .field => switch (slot.condition) {
                    .damaged => if (try book.spend(gs, tech, slotHours(false), base_load)) {
                        slot.condition = .ok;
                        labor_cost += slotLabour(slot.part_key, false);
                    },
                    .destroyed, .missing => if (gs.stockCount(site, slot.part_key) > 0) {
                        if (try book.spend(gs, tech, slotHours(true), base_load)) {
                            _ = gs.takeStock(site, slot.part_key, 1);
                            slot.condition = .ok;
                            labor_cost += slotLabour(slot.part_key, true);
                        }
                    },
                    .ok => {},
                },
                // Structural work is a bay job (Stage 9C): queued once per
                // hull, components taken from the warehouse up front.
                .depot => if (at_home and depot_ok and !hq_ops.hasJobForUnit(gs, u.id)) {
                    _ = hq_ops.queueDepotRepair(gs, u.id) catch false;
                },
            }
        }

        // Armor patching: 15%/week, spares and hours permitting.
        if (u.armor_pct < 100 and gs.stockCount(site, "armor") > 0) {
            if (try book.spend(gs, tech, hours_armor_patch, base_load)) {
                _ = gs.takeStock(site, "armor", 1);
                u.armor_pct = @min(100, u.armor_pct + tuning.maintenance.armor_patch_pct);
                labor_cost += tuning.maintenance.armor_patch_labour;
            }
        }
    }

    try postRepairLabour(gs, labor_cost);
}

// ── The field repair push (12G.6) ────────────────────────────────────
//
// The night after a fight the company's techs pool a share of their spare
// hours and work through the damage with the field armour and spares, in
// the order the commander chose. `repairPlan` is pure: the inbox row and
// the command both call it on live stores, so the plan offered and the
// plan carried out cannot differ. Field work only: structure stays depot
// work and wrecks still go home. MekHQ counterpart: the Repair Bay tab,
// where the player sets which tech works which task.

/// One field job a damaged hull wants: a slot by index into its slots.
pub const SlotJob = struct {
    index: u16,
    part_key: []const u8,
    /// Destroyed or missing: takes a spare as well as hours.
    wrecked: bool,
};

/// A damaged hull as the push sees it.
pub const RepairNeed = struct {
    unit: types.UnitId,
    name: []const u8,
    bv: i64,
    armor_pct: u8,
    slots: []const SlotJob,
    /// Below `tuning.unit.shot_up_condition_pct` (`Unit.conditionPct`):
    /// damage worth a commander's decision, not just a tidy-up.
    shot_up: bool = false,
};

pub const Spare = struct { key: []const u8, count: u32 };

/// What the night has to spend: pooled hours, armour tons, and the spares
/// on hand for the parts the damage wants.
pub const RepairBudget = struct {
    hours: u32,
    armor_tons: u32,
    spares: []const Spare = &.{},
};

/// What one hull gets under one order.
pub const HullRepair = struct {
    unit: types.UnitId,
    name: []const u8,
    armor_before: u8,
    armor_after: u8,
    /// Slot indices put right, in the order the techs did them.
    fixed: []const u16,
    /// Of `fixed`, the ones that took a spare.
    parts: u32,
    patches: u32,
    /// Field work still outstanding when the night ran out.
    left: bool,
};

pub const RepairPlan = struct {
    order: types.RepairOrder,
    /// Every hull that wanted work, in the order the techs took them.
    hulls: []const HullRepair,
    hours: u32,
    armor_tons: u32,

    /// Hulls that still want field work after the night.
    pub fn leftCount(self: RepairPlan) u32 {
        var n: u32 = 0;
        for (self.hulls) |h| n += @intFromBool(h.left);
        return n;
    }
};

/// How the damage is worked under one order (12G.6). Pure: no state and
/// no dice. Each job is one damaged slot (hours), one wrecked slot (hours
/// and a spare) or one armour patch (hours and a ton, up to full plating).
/// Worst-hit and heaviest take each hull as far as the budget reaches
/// before the next; spread gives every hull one job a round, worst first.
pub fn repairPlan(alloc: std.mem.Allocator, needs: []const RepairNeed, budget: RepairBudget, order: types.RepairOrder) !RepairPlan {
    const t = tuning.maintenance;
    const rank = try alloc.alloc(usize, needs.len);
    for (rank, 0..) |*r, i| r.* = i;
    const Ctx = struct {
        needs: []const RepairNeed,
        order: types.RepairOrder,
        fn before(ctx: @This(), a: usize, b: usize) bool {
            const x = ctx.needs[a];
            const y = ctx.needs[b];
            return switch (ctx.order) {
                .heaviest_first => x.bv > y.bv,
                .worst_first, .spread => x.armor_pct < y.armor_pct or (x.armor_pct == y.armor_pct and x.slots.len > y.slots.len),
            };
        }
    };
    std.sort.insertion(usize, rank, Ctx{ .needs = needs, .order = order }, Ctx.before);

    const Work = struct {
        armor: u8,
        fixed: std.ArrayListUnmanaged(u16) = .empty,
        done: []bool,
        parts: u32 = 0,
        patches: u32 = 0,
    };
    const work = try alloc.alloc(Work, needs.len);
    for (work, needs) |*w, n| {
        w.* = .{ .armor = n.armor_pct, .done = try alloc.alloc(bool, n.slots.len) };
        @memset(w.done, false);
    }
    const spares = try alloc.alloc(u32, budget.spares.len);
    for (spares, budget.spares) |*c, sp| c.* = sp.count;
    var hours = budget.hours;
    var tons = budget.armor_tons;

    const Step = struct {
        fn spareFor(sp: []const Spare, key: []const u8) ?usize {
            for (sp, 0..) |s, i| if (std.mem.eql(u8, s.key, key)) return i;
            return null;
        }
    };
    // One job on hull `i`, the first the budget affords; false when none.
    const step = struct {
        fn run(a: std.mem.Allocator, n: RepairNeed, w: *Work, sp_keys: []const Spare, sp: []u32, h: *u32, tn: *u32) !bool {
            for (n.slots, 0..) |job, j| {
                if (w.done[j] or h.* < slotHours(job.wrecked)) continue;
                if (job.wrecked) {
                    const k = Step.spareFor(sp_keys, job.part_key) orelse continue;
                    if (sp[k] == 0) continue;
                    sp[k] -= 1;
                    w.parts += 1;
                }
                h.* -= slotHours(job.wrecked);
                w.done[j] = true;
                try w.fixed.append(a, job.index);
                return true;
            }
            if (w.armor < 100 and tn.* > 0 and h.* >= hours_armor_patch) {
                h.* -= hours_armor_patch;
                tn.* -= 1;
                w.armor = @min(100, w.armor + t.armor_patch_pct);
                w.patches += 1;
                return true;
            }
            return false;
        }
    }.run;

    switch (order) {
        .worst_first, .heaviest_first => for (rank) |i| {
            while (try step(alloc, needs[i], &work[i], budget.spares, spares, &hours, &tons)) {}
        },
        .spread => while (true) {
            var progressed = false;
            for (rank) |i| {
                if (try step(alloc, needs[i], &work[i], budget.spares, spares, &hours, &tons)) progressed = true;
            }
            if (!progressed) break;
        },
    }

    const out = try alloc.alloc(HullRepair, needs.len);
    for (rank, out) |i, *o| {
        const w = &work[i];
        const slots_left = std.mem.indexOfScalar(bool, w.done, false) != null;
        o.* = .{
            .unit = needs[i].unit,
            .name = needs[i].name,
            .armor_before = needs[i].armor_pct,
            .armor_after = w.armor,
            .fixed = try w.fixed.toOwnedSlice(alloc),
            .parts = w.parts,
            .patches = w.patches,
            .left = slots_left or w.armor < 100,
        };
    }
    return .{ .order = order, .hulls = out, .hours = budget.hours - hours, .armor_tons = budget.armor_tons - tons };
}

/// Is there a real choice here (12G.6)? Only when some hull is shot up
/// and the three orders leave the hulls in different shape — otherwise
/// the night goes the one way there is, or is a tidy-up, and the
/// commander is not troubled with it.
pub fn repairWorthAsking(alloc: std.mem.Allocator, needs: []const RepairNeed, budget: RepairBudget) !bool {
    for (needs) |n| {
        if (n.shot_up) break;
    } else return false;
    const base = try repairPlan(alloc, needs, budget, .worst_first);
    for ([_]types.RepairOrder{ .spread, .heaviest_first }) |order| {
        const other = try repairPlan(alloc, needs, budget, order);
        for (base.hulls) |a| {
            for (other.hulls) |b| {
                if (a.unit != b.unit) continue;
                if (a.armor_after != b.armor_after or a.fixed.len != b.fixed.len) return true;
            }
        }
    }
    return false;
}

/// The company's damaged hulls with field work to do: not wrecked, not on
/// the bench, and short of armour or carrying a broken non-structure slot.
pub fn repairNeeds(gs: *GameState, alloc: std.mem.Allocator, company: types.ForceId) ![]RepairNeed {
    var out: std.ArrayListUnmanaged(RepairNeed) = .empty;
    var it = gs.units.iterator();
    while (it.next()) |entry| {
        const u = entry.value_ptr;
        if (gs.companyOf(u.force) != company or !u.takesFieldWork()) continue;
        var jobs: std.ArrayListUnmanaged(SlotJob) = .empty;
        for (u.slots.items, 0..) |slot, i| {
            const tier = unit_mod.repairTier(slot.class, slot.condition) orelse continue;
            if (tier != .field or slot.condition == .ok) continue;
            try jobs.append(alloc, .{ .index = @intCast(i), .part_key = slot.part_key, .wrecked = slot.condition != .damaged });
        }
        if (jobs.items.len == 0 and u.armor_pct >= 100) continue;
        const design = chassis_mod.find(u.chassis_key);
        try out.append(alloc, .{
            .unit = u.id,
            .name = if (design) |d| d.name else u.chassis_key,
            .bv = if (design) |d| d.bv else 0,
            .armor_pct = u.armor_pct,
            .slots = try jobs.toOwnedSlice(alloc),
            .shot_up = u.conditionPct() < tuning.unit.shot_up_condition_pct,
        });
    }
    return out.toOwnedSlice(alloc);
}

/// The night's budget: `push_hours_bp` of the spare weekly hours of every
/// fit tech on the company's hulls, pooled; the field armour; the spares
/// on hand for the parts the damage wants.
pub fn repairBudget(gs: *GameState, alloc: std.mem.Allocator, company: types.ForceId, needs: []const RepairNeed) !RepairBudget {
    var seen: std.AutoHashMapUnmanaged(types.PersonId, void) = .empty;
    var spare_hours: u32 = 0;
    var it = gs.units.iterator();
    while (it.next()) |entry| {
        const u = entry.value_ptr;
        if (gs.companyOf(u.force) != company or !u.takesFieldWork()) continue;
        const tech = activeTech(gs, u) orelse continue;
        if ((try seen.getOrPut(alloc, tech.id)).found_existing) continue;
        spare_hours += gs.techHoursAvailable(tech) -| gs.techLoadHours(tech.id);
    }
    const site = gs.siteForForce(company);
    var spares: std.ArrayListUnmanaged(Spare) = .empty;
    for (needs) |n| for (n.slots) |job| {
        if (!job.wrecked) continue;
        for (spares.items) |sp| {
            if (std.mem.eql(u8, sp.key, job.part_key)) break;
        } else try spares.append(alloc, .{ .key = job.part_key, .count = gs.stockCount(site, job.part_key) });
    };
    return .{
        .hours = @intCast(types.applyBp(spare_hours, tuning.maintenance.push_hours_bp)),
        .armor_tons = gs.stockCount(site, "armor"),
        .spares = try spares.toOwnedSlice(alloc),
    };
}

/// The plan for this company tonight, from live stores. The inbox row and
/// `repairPush` both come through here.
pub fn planFor(gs: *GameState, alloc: std.mem.Allocator, company: types.ForceId, order: types.RepairOrder) !RepairPlan {
    const needs = try repairNeeds(gs, alloc, company);
    return repairPlan(alloc, needs, try repairBudget(gs, alloc, company, needs), order);
}

/// Carry out the night's work in `order` (12G.6): slots put right, spares
/// and armour taken from the field stores, labour billed. Returns the plan
/// it carried out, for the log, in `alloc` (a caller's scratch arena).
pub fn repairPush(gs: *GameState, alloc: std.mem.Allocator, company: types.ForceId, order: types.RepairOrder) !RepairPlan {
    const plan = try planFor(gs, alloc, company, order);
    const site = gs.siteForForce(company);
    var labour: types.CBills = 0;
    for (plan.hulls) |h| {
        const u = gs.unit(h.unit) orelse continue;
        for (h.fixed) |idx| {
            const slot = &u.slots.items[idx];
            const wrecked = slot.condition != .damaged;
            if (wrecked and !gs.takeStock(site, slot.part_key, 1)) return error.InsufficientStock;
            slot.condition = .ok;
            labour += slotLabour(slot.part_key, wrecked);
        }
        if (h.patches > 0) {
            if (!gs.takeStock(site, "armor", h.patches)) return error.InsufficientStock;
            u.armor_pct = h.armor_after;
            labour += tuning.maintenance.armor_patch_labour * @as(types.CBills, h.patches);
        }
    }
    try postRepairLabour(gs, labour);
    return plan;
}

/// "Atlas 12%→57% +1 slot · Locust 30%→45% · 2 hulls still short of full
/// repair":
/// what one plan does, in a line for the log and the inbox.
pub fn pushSummary(alloc: std.mem.Allocator, plan: RepairPlan) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var touched: u32 = 0;
    for (plan.hulls) |h| {
        if (h.fixed.len == 0 and h.patches == 0) continue;
        if (touched > 0) try out.appendSlice(alloc, " · ");
        touched += 1;
        try out.print(alloc, "{s} {d}%→{d}%", .{ h.name, h.armor_before, h.armor_after });
        const slots = h.fixed.len;
        if (slots > 0) try out.print(alloc, " +{d} slot{s}", .{ slots, if (slots == 1) "" else "s" });
    }
    if (touched == 0) try out.appendSlice(alloc, "nothing the night could reach");
    const left = plan.leftCount();
    if (left > 0) try out.print(alloc, " · {d} hull{s} still short of full repair", .{ left, if (left == 1) "" else "s" });
    return out.toOwnedSlice(alloc);
}

test "no tech, no maintenance: an unassigned hull rots; an assigned one holds" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 99 });
    defer gs.deinit();
    const uid = try gs.addUnit("SHD-2H");
    gs.unit(uid).?.quality = .f;
    for (0..52) |_| try runWeeklyMaintenance(&gs);
    const neglected = gs.unit(uid).?.quality;
    try std.testing.expect(@intFromEnum(neglected) < @intFromEnum(types.Quality.f));

    var gs2 = GameState.init(std.testing.allocator, .{ .seed = 99 });
    defer gs2.deinit();
    const uid2 = try gs2.addUnit("SHD-2H");
    gs2.unit(uid2).?.quality = .f;
    const tech = try gs2.hirePerson("Clay", "Cluny", .tech_mek);
    try gs2.person(tech).?.skills.put(gs2.allocator(), .tech_mek, 2);
    try gs2.assignSlot(uid2, .tech, tech);
    for (0..52) |_| try runWeeklyMaintenance(&gs2);
    try std.testing.expect(@intFromEnum(gs2.unit(uid2).?.quality) >= @intFromEnum(neglected));
    try std.testing.expect(gs2.ledger.balance() < 0); // consumables were paid for
}

test "tech hours are a budget: too many hulls leave some uncovered" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 100 });
    defer gs.deinit();
    const tech = try gs.hirePerson("Solo", "Tech", .tech_mek);
    // 40h budget, no astechs → 20h effective; an Atlas costs 10h/week.
    var uids: [4]types.UnitId = undefined;
    for (&uids) |*id| {
        id.* = try gs.addUnit("AS7-D");
        try gs.assignSlot(id.*, .tech, tech);
    }
    try std.testing.expectEqual(@as(u32, 40), gs.techLoadHours(tech));
    try std.testing.expectEqual(@as(u32, 20), gs.techHoursAvailable(gs.person(tech).?));
    try runWeeklyMaintenance(&gs);
    var maintained: u32 = 0;
    for (uids) |id| {
        if (gs.unit(id).?.last_maintenance_day != null) maintained += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), maintained);
}

test "an injured tech is swapped for a free one" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 101 });
    defer gs.deinit();
    const co = try gs.createForce("Alpha", .company, .none);
    const uid = try gs.addUnit("SHD-2H");
    try gs.assignUnit(uid, co, .none);
    const t1 = try gs.hirePerson("A", "One", .tech_mek);
    const t2 = try gs.hirePerson("B", "Two", .tech_mek);
    gs.person(t1).?.assigned_force = co;
    gs.person(t2).?.assigned_force = co;
    try gs.assignSlot(uid, .tech, t1);

    try injureTech(&gs, t1, 10, "test");
    try std.testing.expectEqual(person_mod.Status.wounded, gs.person(t1).?.status);
    try std.testing.expectEqual(t2, gs.unit(uid).?.tech);
}

test "repairs consume spares; depot work needs the HQ" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7 });
    defer gs.deinit();
    const uid = try gs.addUnit("SHD-2H");
    const u = gs.unit(uid).?;
    const tech = try gs.hirePerson("Clay", "Cluny", .tech_mek);
    try gs.assignSlot(uid, .tech, tech);

    for (u.slots.items) |*slot| {
        if (slot.class == .weapon) {
            slot.condition = .destroyed;
            break;
        }
    }
    u.slots.items[1].condition = .destroyed; // ct.structure

    try runWeeklyRepairs(&gs);
    try std.testing.expect(u.needsDepot());

    _ = try gs.createCommander("T", .LC, .chief_engineer);
    try gs.addSpare("ac5", 1);
    try runWeeklyRepairs(&gs);
    try std.testing.expectEqual(@as(u32, 0), gs.spareCount("ac5"));
    try std.testing.expect(hq_ops.hasJobForUnit(&gs, uid));
    try hq_ops.runDaily(&gs);
    gs.clock.day_index += 30;
    // A failed repair check keeps the job on the bench (12C.12): walk it off.
    var days: u32 = 0;
    while (hq_ops.hasJobForUnit(&gs, uid) and days < 200) : (days += 1) {
        try hq_ops.runDaily(&gs);
        gs.clock.day_index += 1;
    }
    try std.testing.expect(!u.needsDepot());
    // Structure is whole; a botched check may have cost a piece of gear.
    for (u.slots.items) |slot| if (slot.class == .structure) try std.testing.expectEqual(unit_mod.PartCondition.ok, slot.condition);
}

test "12G.6: the three repair orders spend one night three ways" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const needs = [_]RepairNeed{
        .{ .unit = @enumFromInt(1), .name = "Atlas", .bv = 1897, .armor_pct = 10, .slots = &.{}, .shot_up = true },
        .{ .unit = @enumFromInt(2), .name = "Locust", .bv = 432, .armor_pct = 5, .slots = &.{}, .shot_up = true },
        .{ .unit = @enumFromInt(3), .name = "Commando", .bv = 541, .armor_pct = 55, .slots = &.{}, .shot_up = true },
    };
    // Four tons of plating, hours to spare: the armour is what runs out.
    const budget: RepairBudget = .{ .hours = 40, .armor_tons = 4 };
    const patch = tuning.maintenance.armor_patch_pct;

    // Worst-hit first: the Locust takes every ton.
    const worst = try repairPlan(a, &needs, budget, .worst_first);
    try std.testing.expectEqual(@as(types.UnitId, @enumFromInt(2)), worst.hulls[0].unit);
    try std.testing.expectEqual(5 + 4 * patch, worst.hulls[0].armor_after);
    try std.testing.expectEqual(@as(u32, 4), worst.armor_tons);
    try std.testing.expectEqual(@as(u32, 3), worst.leftCount()); // all three still short of full plating

    // Spread: a patch each, then the worst again.
    const spread = try repairPlan(a, &needs, budget, .spread);
    for (spread.hulls) |h| try std.testing.expect(h.patches >= 1);
    try std.testing.expectEqual(5 + 2 * patch, spread.hulls[0].armor_after);

    // Heaviest first: the Atlas takes every ton.
    const heavy = try repairPlan(a, &needs, budget, .heaviest_first);
    try std.testing.expectEqualStrings("Atlas", heavy.hulls[0].name);
    try std.testing.expectEqual(10 + 4 * patch, heavy.hulls[0].armor_after);

    try std.testing.expect(try repairWorthAsking(a, &needs, budget));
    // Enough for everything: every order does the same night, so no question.
    try std.testing.expect(!try repairWorthAsking(a, &needs, .{ .hours = 1000, .armor_tons = 100 }));
    // Nothing to work with: nothing to choose between either.
    try std.testing.expect(!try repairWorthAsking(a, &needs, .{ .hours = 0, .armor_tons = 4 }));
    // Scuffed paint is a tidy-up, not a decision.
    var scuffed = needs;
    for (&scuffed) |*n| n.shot_up = false;
    try std.testing.expect(!try repairWorthAsking(a, &scuffed, budget));
}

test "12G.6: a wrecked slot takes a spare as well as hours, and waits without one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const needs = [_]RepairNeed{.{ .unit = @enumFromInt(1), .name = "Wolverine", .bv = 1101, .armor_pct = 100, .slots = &.{
        .{ .index = 3, .part_key = "mlas", .wrecked = true },
        .{ .index = 4, .part_key = "srm6", .wrecked = true },
        .{ .index = 5, .part_key = "hsink", .wrecked = false },
    } }};
    const plan = try repairPlan(a, &needs, .{ .hours = 40, .armor_tons = 0, .spares = &.{.{ .key = "mlas", .count = 1 }} }, .worst_first);
    const h = plan.hulls[0];
    // The laser has a spare, the heat sink only wants hours; no SRM on hand.
    try std.testing.expectEqualSlices(u16, &.{ 3, 5 }, h.fixed);
    try std.testing.expectEqual(@as(u32, 1), h.parts);
    try std.testing.expect(h.left);
    try std.testing.expectEqual(slotHours(true) + slotHours(false), plan.hours);
}
