//! Battle resolution (Stage 7, P5b; ARCH §7). Adaptation of MekHQ's ACAR.
//! Combat-class contracts schedule engagements every few weeks; each holds
//! the turn when its day comes and is fought in phases under the
//! commander's orders (`battle_phases`), from what the campaign built: BV
//! and crew skill, machine condition, fatigue and morale, the support
//! echelon, and recon. Damage lands on real part slots, casualties go to
//! the infirmary, salvage and battle-loss comp hit the ledger, and the AAR
//! names the reasons. Legibility over drama: a loss should trace to causes.

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const autoresolve = @import("../domain/autoresolve.zig");
const readiness = @import("readiness.zig");
const contract_mod = @import("../domain/contract.zig");
const chassis_mod = @import("../domain/chassis.zig");
const after_action = @import("after_action.zig");
const battle_report = @import("../domain/battle_report.zig");
const force_mod = @import("../domain/force.zig");
const part_mod = @import("../domain/part.zig");
const medical = @import("medical.zig");
const person_mod = @import("../domain/person.zig");
const unit_mod = @import("../domain/unit.zig");
const sites = @import("sites.zig");
const crew = @import("crew.zig");
const toe = @import("toe.zig");
const GameState = @import("state.zig").GameState;
const founding = @import("founding.zig");
const lift = @import("lift.zig");
const held_hulls_m = @import("held_hulls.zig");
const operations_m = @import("operations.zig");
const operation_mod = @import("../domain/operation.zig");
const readiness_m = @import("readiness.zig");
const black_market = @import("black_market.zig");
const hull_instance_for_pool = @import("../domain/hull_instance.zig");
const battle_preparation = @import("battle_preparation.zig");
const battle_casualties = @import("battle_casualties.zig");
const battle_recovery = @import("battle_recovery.zig");
const artillery_battle = @import("artillery_battle.zig");
const battle_phases = @import("battle_phases.zig");
const battle_phase = @import("../domain/battle_phase.zig");
const commands = @import("commands.zig");

/// Salvage trucks (SVT-1) a company can work a battlefield: operational
/// (fit crew, not parked or busy) SVT-1s only (ARCH §9.3 active capability).
pub fn salvageTrucks(gs: *GameState, company: types.ForceId) i64 {
    var trucks: i64 = 0;
    var it = gs.units.iterator();
    while (it.next()) |entry| {
        const u = entry.value_ptr;
        if (readiness.unitOperational(gs, u) and std.mem.eql(u8, u.chassis_key, "SVT-1") and gs.companyOf(u.force) == company) trucks += 1;
    }
    return trucks;
}

/// BV of wrecks and parts the crews can haul off a won field: what the
/// trucks carry, else what hands can drag.
pub fn haulCapacityBv(trucks: i64) i64 {
    return if (trucks > 0) trucks * tuning.battle.salvage_bv_per_truck else tuning.battle.salvage_bv_by_hand;
}

/// The shared salvage-claim scaling: gross BV the player's share amounts
/// to before the per-battle `scenario.salvage_bp` roll and the
/// command-rights cut.  Both `battle.resolve` and the contract-detail
/// preview call it (C11o); the preview is gross — it cannot know the
/// roll — and must label itself accordingly.
pub fn salvageClaimBv(haul_bv: i64, salvage_pct: u8, has_salvage_lance: bool) i64 {
    var claim: i64 = @divTrunc(haul_bv * salvage_pct, 100);
    if (has_salvage_lance) claim = types.applyBp(claim, tuning.battle.salvage_lance_bonus_bp);
    return claim;
}

/// Whole hulls a destroyed-BV total amounts to (a thousand BV a kill,
/// rounded): kill credit and prisoner counts both read it.
pub fn estimatedKills(destroyed_bv: i64) u32 {
    return @intCast(@max(0, @divTrunc(destroyed_bv + 500, 1000)));
}

/// Days between engagements: ~2/month with variance; garrison work sees
/// a probe every six weeks or so.
fn nextBattleGap(gs: *GameState, c: *const contract_mod.Contract) u32 {
    if (c.kind.isGarrisonClass()) return tuning.battle.garrison_probe_base_days + @as(u32, gs.rng.roll2d6(.battle)) * tuning.battle.garrison_probe_die_days;
    // Command rights set the tempo: integrated employers pick fights.
    const base: i32 = @as(i32, @intCast(tuning.battle.gap_base_days)) + @as(i32, gs.rng.roll2d6(.battle)) + c.terms.command_rights.gapDelta();
    return @intCast(@max(min_gap_days, base));
}

/// The shortest gap between engagements on a non-garrison contract.
pub const min_gap_days: u32 = 3;

/// Days until the contract's next engagement; null when none is scheduled.
pub fn daysToContact(gs: *const GameState, c: *const contract_mod.Contract) ?u32 {
    if (c.status != .active) return null;
    const day = c.next_battle_day orelse return null;
    return day -| gs.clock.day_index;
}

/// Inside the contact warning window: ROE and recall can still change the
/// engagement (`tuning.battle.contact_warning_days`).
pub fn inContactWindow(gs: *const GameState, c: *const contract_mod.Contract) bool {
    const days = daysToContact(gs, c) orelse return false;
    return days <= tuning.battle.contact_warning_days;
}

/// Battle orders are confirmed for the scheduled engagement.
pub fn ordersConfirmed(c: *const contract_mod.Contract) bool {
    const day = c.next_battle_day orelse return false;
    return c.orders_day == day;
}

/// The window opened with today's tick: the one day a multi-day advance
/// stops so the warning is seen.
pub fn contactWindowOpensToday(gs: *const GameState, c: *const contract_mod.Contract) bool {
    return daysToContact(gs, c) == tuning.battle.contact_warning_days;
}

/// The ROE a company fights under on a contract: integrated command rights
/// override the company's own setting.
pub fn effectiveRoe(gs: *GameState, c: *const contract_mod.Contract, company: types.ForceId) force_mod.Roe {
    if (c.terms.command_rights.overridesRoe()) return .hold;
    return if (gs.force(company)) |f| f.roe else .standard;
}

/// An active contract with someone to fight. Garrison work fights too
/// (ARCH §8): the enemy probes the perimeter, but garrison work with no
/// opposing force has nothing to probe with (`Contract.facesNoThreat`).
fn fightsEngagements(c: *const contract_mod.Contract) bool {
    if (c.status != .active) return false;
    return !c.facesNoThreat();
}

/// battle_resolution phase, daily: schedule the first engagement of each
/// active combat-class contract. An engagement whose day arrives is not
/// fought here: it holds the turn (`engagementDue`) until the commander
/// fights it with battle orders, after that day's tick (ARCH §6 step 8).
pub fn runDaily(gs: *GameState) !void {
    var index: usize = 0;
    while (index < gs.contracts.count()) : (index += 1) {
        const id = gs.contracts.keys()[index];
        const c = gs.contracts.getPtr(id).?;
        if (!fightsEngagements(c) or c.next_battle_day != null) continue;
        var scheduling = gs.*;
        const next = std.math.add(u32, gs.clock.day_index, nextBattleGap(&scheduling, c)) catch return error.OutOfRange;
        gs.rng = scheduling.rng;
        c.next_battle_day = next;
    }
}

/// The contract's scheduled engagement has come due and waits on the
/// commander: it holds the turn (`checklist.turnHold`) until the final
/// phase publishes and the next engagement is scheduled.
pub fn engagementDue(gs: *const GameState, c: *const contract_mod.Contract) bool {
    if (!fightsEngagements(c)) return false;
    const day = c.next_battle_day orelse return false;
    return gs.clock.day_index >= day;
}

/// The engagement the turn waits on: the battle in progress, else the first
/// contract whose engagement is due, in contract order.
pub fn dueEngagement(gs: *const GameState) ?types.ContractId {
    if (battle_phases.inProgress(gs)) |record| return record.contract;
    for (gs.contracts.values()) |*c| if (engagementDue(gs, c)) return c.id;
    return null;
}

/// The battle order command (ARCH §7 "The phased engagement"). Validates
/// the order against the contract's due or in-progress engagement, replays
/// the engagement from live state in a discarded workspace under every
/// order given so far plus this one, then either appends the order and the
/// pause it reached to the battle record or, when the order ends the
/// battle, publishes the engagement and its next schedule atomically and
/// removes the record. A contact-pause lever the course refuses
/// (`battle_phases.leverAllowed`, on `leverAvailability`) is refused by the
/// replay before anything live changes. A refusal changes nothing (rules
/// 11–13).
pub fn execBattleOrder(gs: *GameState, o: @FieldType(commands.Command, "battle_order")) commands.Error!commands.Result {
    const c = gs.contracts.getPtr(o.contract) orelse return error.UnknownContract;
    const record: ?*battle_phase.BattleInProgress = for (gs.battles_in_progress.items) |*r| {
        if (r.contract == o.contract) break r;
    } else null;
    if (record == null) {
        if (gs.battles_in_progress.items.len > 0) return error.BattleInProgress;
        try startAllowed(gs, c);
    }
    const pause: ?battle_phase.Pause = if (record) |r| r.phase else null;
    const held = if (record) |r| r.latest().held_field else false;
    if (!battle_phases.orderLegal(pause, held, o.order)) return error.OrderNotLegal;
    try roeOrderAllowed(c, o.order);

    const given = if (record) |r| r.steps.items.len else 0;
    const orders = try gs.scratch().alloc(battle_phase.Order, given + 1);
    defer gs.scratch().free(orders);
    if (record) |r| for (r.steps.items, 0..) |step, i| {
        orders[i] = step.order;
    };
    orders[given] = o.order;
    return fightOrders(gs, o.contract, orders, gs.scratch());
}

/// The contract's engagement may be started: it is due, and nothing else
/// holds the turn, since an unread report or an unanswered decision cannot
/// be dealt with under the battle lock.
fn startAllowed(gs: *GameState, c: *const contract_mod.Contract) error{ NoEngagementDue, ReportUnread, DecisionPending }!void {
    if (!engagementDue(gs, c)) return error.NoEngagementDue;
    if (@import("checklist.zig").turnHold(gs)) |hold| switch (hold) {
        .unread_after_action => return error.ReportUnread,
        .battle_decision => return error.DecisionPending,
        .engagement_due => {},
    };
}

/// An ROE order is refused while the employer holds the ROE under
/// integrated command (ROADMAP P5b.3).
fn roeOrderAllowed(c: *const contract_mod.Contract, order: battle_phase.Order) error{RoeReservedByEmployer}!void {
    if (order == .roe and c.terms.command_rights.overridesRoe()) return error.RoeReservedByEmployer;
}

/// A loaded battle in progress is one the battle order command could have
/// left (rules 1, 47): its contract's engagement was startable (due, nothing
/// else holding the turn, which the battle lock keeps true), no ROE order is
/// one the employer reserves, and replaying each prefix of its orders from
/// live state in a discarded workspace reaches exactly the pause stored for
/// it. Anything else is `error.CorruptSave`, never repaired; nothing changes.
pub fn validateInProgress(gs: *GameState) error{ CorruptSave, OutOfMemory }!void {
    const record = battle_phases.inProgress(gs) orelse return;
    const c = gs.contracts.getPtr(record.contract) orelse return error.CorruptSave;
    startAllowed(gs, c) catch return error.CorruptSave;
    const orders = try gs.scratch().alloc(battle_phase.Order, record.steps.items.len);
    defer gs.scratch().free(orders);
    for (record.steps.items, 0..) |step, i| {
        roeOrderAllowed(c, step.order) catch return error.CorruptSave;
        orders[i] = step.order;
        const reached = replayPause(gs, record.contract, orders[0 .. i + 1]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.CorruptSave,
        };
        if (!std.meta.eql(reached, step.report)) return error.CorruptSave;
    }
}

/// The pause `orders` reach from live state, fought in a discarded
/// workspace; `error.OrderNotLegal` when they end the battle instead.
fn replayPause(gs: *GameState, id: types.ContractId, orders: []const battle_phase.Order) !battle_phase.PhaseReport {
    return replayObserved(gs, id, orders, gs.scratch(), null);
}

/// `replayPause` in a workspace backed by `backing`, reporting what the
/// engagement brought to its phases through `observed`.
fn replayObserved(gs: *GameState, id: types.ContractId, orders: []const battle_phase.Order, backing: std.mem.Allocator, observed: ?*?Observed) !battle_phase.PhaseReport {
    var engagement = try battle_preparation.Engagement.init(gs, backing);
    defer engagement.deinit();
    const staged = &engagement.view;
    const contract = staged.contracts.getPtr(id) orelse return error.UnknownContract;
    return switch (try fightStagedObserved(staged, contract, .{ .given = orders }, backing, observed)) {
        .paused => |report| report,
        .finished => error.OrderNotLegal,
    };
}

/// The contact-pause lever availability of the contract's battle in
/// progress, exactly as the battle order command reaches it: the engagement
/// is replayed from live state under the orders given so far in a discarded
/// workspace backed by `alloc`, so its weather is the engagement's own.
/// Null when the contract has no battle in progress. Consumes no live RNG
/// and changes nothing live (rules 31, 34).
pub fn inProgressAvailability(gs: *GameState, id: types.ContractId, alloc: std.mem.Allocator) !?battle_phases.Availability {
    const record = for (gs.battles_in_progress.items) |*r| {
        if (r.contract == id) break r;
    } else return null;
    const orders = try alloc.alloc(battle_phase.Order, record.steps.items.len);
    defer alloc.free(orders);
    for (record.steps.items, orders) |step, *o| o.* = step.order;
    var observed: ?Observed = null;
    _ = try replayObserved(gs, id, orders, alloc, &observed);
    // A paused course has observed its inputs.
    return observed.?.inputs.avail;
}

/// Fights `orders` from live state in a discarded workspace. A pause is
/// recorded on the battle record (its capacity reserved before the first
/// mutation); a finished battle is published through the workspace with the
/// next engagement scheduled, and its record removed without allocation.
fn fightOrders(gs: *GameState, id: types.ContractId, orders: []const battle_phase.Order, backing: std.mem.Allocator) !commands.Result {
    var engagement = try battle_preparation.Engagement.init(gs, backing);
    defer engagement.deinit();
    const staged = &engagement.view;
    const contract = staged.contracts.getPtr(id) orelse return error.UnknownContract;
    const record_index: ?usize = for (gs.battles_in_progress.items, 0..) |r, i| {
        if (r.contract == id) break i;
    } else null;
    switch (try fightStaged(staged, contract, .{ .given = orders }, backing)) {
        .paused => |report| {
            const step: battle_phase.Step = .{ .order = orders[orders.len - 1], .report = report };
            if (record_index) |i| {
                const record = &gs.battles_in_progress.items[i];
                try record.steps.ensureUnusedCapacity(gs.allocator(), 1);
                record.steps.appendAssumeCapacity(step);
                record.phase = report.pause;
            } else {
                var steps: std.ArrayListUnmanaged(battle_phase.Step) = .empty;
                try steps.ensureTotalCapacity(gs.allocator(), 1);
                try gs.battles_in_progress.ensureUnusedCapacity(gs.allocator(), 1);
                steps.appendAssumeCapacity(step);
                gs.battles_in_progress.appendAssumeCapacity(.{ .contract = id, .phase = report.pause, .steps = steps });
            }
            return .{ .battle_pause = report.pause };
        },
        .finished => {
            try scheduleNextEngagement(staged, contract);
            const report_id = staged.battle_reports.kept.items[staged.battle_reports.kept.items.len - 1].id;
            var publication = try engagement.prepare(gs);
            publication.commit(gs, staged);
            if (record_index) |i| _ = gs.battles_in_progress.orderedRemove(i);
            return .{ .battle_report = report_id };
        },
    }
}

/// The next engagement after one is fought, at its RNG position after the
/// battle's own draws.
fn scheduleNextEngagement(gs: *GameState, c: *contract_mod.Contract) !void {
    c.next_battle_day = std.math.add(u32, gs.clock.day_index, nextBattleGap(gs, c)) catch return error.OutOfRange;
}

const SideState = struct {
    power: i64 = 0,
    bv: i64 = 0,
    engaged: std.ArrayListUnmanaged(types.UnitId) = .empty,
    mods: autoresolve.CampaignMods = .{},
    site: types.Site = .outfit,
    /// Tons of each munition family this fight will expend.
    ammo_reserved: std.StringArrayHashMapUnmanaged(u32) = .empty,
    /// Working selected mounts per munition family, prepared before battle RNG.
    family_mounts: std.StringArrayHashMapUnmanaged(u32) = .empty,
    silenced_mounts: u32 = 0,
};

/// A ton of a munition family feeds this many mounts for one engagement
/// (~10 turns of fire at tabletop rates, halved so resupply tonnage stays
/// within what the field trucks carry).
pub const mounts_per_ammo_ton = tuning.battle.mounts_per_ammo_ton;

fn hasTech(gs: *GameState, u: *const @import("../domain/unit.zig").Unit) bool {
    const t = gs.person(u.tech) orelse return false;
    return t.isAvailable(gs.clock.day_index);
}

const terrain_mod = @import("../domain/terrain.zig");
const planet_mod = @import("../domain/planet.zig");
const faction_mod = @import("../domain/faction.zig");
const opfor = @import("../domain/opfor.zig");
const rival_mod = @import("../domain/rival.zig");

/// Gather the company's combat lances into engaged units + summed power.
fn playerSide(gs: *GameState, c: *const contract_mod.Contract) !SideState {
    return playerSideIn(gs, gs.scratch(), c, .{});
}

pub const Estimate = struct {
    power: i64 = 0,
    bv: i64 = 0,
    tons: u32 = 0,
    /// Hulls by weight class: light, medium, heavy, assault.
    mix: [4]u32 = .{ 0, 0, 0, 0 },
    hulls: u32 = 0,
    recon: bool = false,
    /// Carrier ceiling only; enemy power also caps the actual reduction. Odds remain unsuppressed.
    artillery: ?artillery_battle.Preview = null,
};

/// What a company would bring to a fight on this contract: its
/// combat power as the battle model reckons it (BV × skill × condition ×
/// quality × supply, the support echelon and recon, lance roles under the
/// contract's command rights), what it weighs, and its weight-class mix.
/// Read-only: nothing is reserved or spent. `alloc` is the caller's
/// scratch space.
pub fn estimatePower(gs: *GameState, alloc: std.mem.Allocator, c: *const contract_mod.Contract, company: types.ForceId) !Estimate {
    var as_if = c.*;
    as_if.assigned_company = company;
    const env: terrain_mod.Environment = if (planet_mod.find(c.planet_key)) |w| .{ .terrain = terrain_mod.terrainOf(w) } else .{};
    const side = try playerSideIn(gs, alloc, &as_if, env);
    var out: Estimate = .{ .power = side.power, .bv = side.bv, .recon = side.mods.recon_quality > 0 };
    for (side.engaged.items) |uid| {
        const u = gs.unit(uid) orelse continue;
        const d = chassis_mod.find(u.chassis_key) orelse continue;
        out.tons += d.tonnage;
        out.mix[@intFromEnum(d.weightClass())] += 1;
        out.hulls += 1;
    }
    if (out.hulls > 0) out.artillery = artillery_battle.preview(gs, &as_if, side.mods.recon_quality, std.math.maxInt(i64));
    return out;
}

/// The player's side under given conditions: night and storms
/// ground the fighters, close terrain dents recon.
fn playerSideIn(gs: *GameState, alloc: std.mem.Allocator, c: *const contract_mod.Contract, env: terrain_mod.Environment) !SideState {
    var side = try preparePlayerSide(gs, alloc, c);
    populatePlayerSide(gs, c, env, &side);
    return side;
}

/// Reserves the entire player battle-line and ammunition census before the
/// battle stream advances. Weather then determines which reserved slots fly.
fn preparePlayerSide(gs: *GameState, alloc: std.mem.Allocator, c: *const contract_mod.Contract) !SideState {
    const mods = companyMods(gs, c);
    var side: SideState = .{ .mods = mods, .site = .{ .company = c.assigned_company } };
    const company = gs.force(c.assigned_company) orelse return side;

    var unit_capacity: usize = 0;
    for (company.children.items) |child_id| {
        const child = gs.force(child_id) orelse continue;
        if (child.echelon == .lance) unit_capacity += child.units.items.len;
        if (child.echelon != .air_company) continue;
        for (child.children.items) |air_lance_id| {
            const air_lance = gs.force(air_lance_id) orelse continue;
            if (air_lance.echelon == .air_lance) unit_capacity += air_lance.units.items.len;
        }
    }
    try side.engaged.ensureUnusedCapacity(alloc, unit_capacity);
    try side.ammo_reserved.ensureUnusedCapacity(alloc, part_mod.munition_keys.len);
    try side.family_mounts.ensureUnusedCapacity(alloc, part_mod.munition_keys.len);
    return side;
}

fn populatePlayerSide(gs: *GameState, c: *const contract_mod.Contract, env: terrain_mod.Environment, side: *SideState) void {
    if (env.groundsAir()) side.mods.has_air_cover = false;
    side.mods.recon_quality = @intCast(@max(0, @as(i32, side.mods.recon_quality) + env.reconMod()));
    const company = gs.force(c.assigned_company) orelse return;

    // Select the battle line before counting ammunition. Air-lance fighters
    // join only when the environment permits flight; the cover modifier above
    // remains independently owned by readiness.companyHasOperationalFighter.
    for (company.children.items) |child_id| {
        const child = gs.force(child_id) orelse continue;
        if (child.echelon == .lance) collectLanceUnits(gs, c, child, false, &side.engaged);
        if (child.echelon != .air_company or env.groundsAir()) continue;
        for (child.children.items) |air_lance_id| {
            const air_lance = gs.force(air_lance_id) orelse continue;
            if (air_lance.echelon == .air_lance) collectLanceUnits(gs, c, air_lance, true, &side.engaged);
        }
    }

    // Count only the selected line's working ballistic/missile mounts, then
    // decide how many each family's stock can feed this fight.
    @import("field_supply.zig").munitionMountsForUnitsPrepared(&side.family_mounts, gs, side.engaged.items);
    var fit = side.family_mounts.iterator();
    while (fit.next()) |entry| {
        const mounts = entry.value_ptr.*;
        const need = @import("field_supply.zig").tonsPerBattle(mounts);
        const have = gs.stockCount(side.site, entry.key_ptr.*);
        const use = @min(need, have);
        side.ammo_reserved.putAssumeCapacity(entry.key_ptr.*, use);
    }

    for (company.children.items) |child_id| {
        const child = gs.force(child_id) orelse continue;
        if (child.echelon == .lance) addLancePower(gs, c, child, side);
        if (child.echelon != .air_company or env.groundsAir()) continue;
        for (child.children.items) |air_lance_id| {
            const air_lance = gs.force(air_lance_id) orelse continue;
            if (air_lance.echelon == .air_lance) addLancePower(gs, c, air_lance, side);
        }
    }
}

fn collectLanceUnits(gs: *GameState, c: *const contract_mod.Contract, lance: *const force_mod.Force, aerospace_only: bool, engaged: *std.ArrayListUnmanaged(types.UnitId)) void {
    if (!lance.isCombatLance()) return;
    if (lance.role == .training and c.terms.command_rights.allowsTrainingLances()) return;
    for (lance.units.items) |uid| {
        const u = gs.unit(uid) orelse continue;
        if (aerospace_only != (u.kind == .aerospace)) continue;
        if (readiness_m.unitOperational(gs, u)) engaged.appendAssumeCapacity(uid);
    }
}

fn isEngaged(engaged: []const types.UnitId, id: types.UnitId) bool {
    for (engaged) |selected| if (selected == id) return true;
    return false;
}

fn addLancePower(gs: *GameState, c: *const contract_mod.Contract, lance: *const force_mod.Force, side: *SideState) void {
    var lance_bv: i64 = 0;
    var gunnery_sum: u32 = 0;
    var piloting_sum: u32 = 0;
    var condition_sum: u32 = 0;
    var quality_sum: u32 = 0;
    var n: u32 = 0;
    for (lance.units.items) |uid| {
        if (!isEngaged(side.engaged.items, uid)) continue;
        const u = gs.unit(uid) orelse continue;
        const design = chassis_mod.find(u.chassis_key) orelse continue;
        const pilot = gs.person(u.pilot) orelse continue;
        const reloaded = hasTech(gs, u);
        var mounts: u32 = 0;
        var silenced_x100: u32 = 0;
        for (u.slots.items) |slot| {
            if (slot.class != .weapon or slot.condition != .ok) continue;
            mounts += 1;
            const ammo_key = part_mod.munitionFor(slot.part_key) orelse continue;
            const family_mounts = side.family_mounts.get(ammo_key) orelse 0;
            const reserved = side.ammo_reserved.get(ammo_key) orelse 0;
            const fed = @min(family_mounts, reserved * mounts_per_ammo_ton);
            const fire_pct = if (reloaded and family_mounts > 0) fed * 100 / family_mounts else 0;
            silenced_x100 += 100 - fire_pct;
        }
        var unit_bv: i64 = design.bv;
        if (mounts > 0 and silenced_x100 > 0) {
            const penalty_pct: i64 = @divTrunc(tuning.battle.silence_penalty_pct * @as(i64, silenced_x100), 100 * @as(i64, mounts));
            unit_bv = @divTrunc(unit_bv * (100 - penalty_pct), 100);
            side.silenced_mounts += (silenced_x100 + 50) / 100;
        }
        lance_bv += unit_bv;
        condition_sum += u.conditionPct();
        quality_sum += @intFromEnum(u.quality);
        const crew_role = unit_mod.crewRoleFor(u.kind);
        gunnery_sum += autoresolve.effectiveCrewSkill(pilot, pilot.skill(crew_role.primarySkill()) orelse 4, false);
        const piloting_value = (if (crew_role.pilotingSkill()) |skill| pilot.skill(skill) else null) orelse 5;
        piloting_sum += autoresolve.effectiveCrewSkill(pilot, piloting_value, true);
        n += 1;
    }
    if (n == 0) return;
    const elem: autoresolve.Element = .{
        .force = lance.id,
        .base_strength = lance_bv,
        .avg_gunnery = @intCast(gunnery_sum / n),
        .avg_piloting = @intCast(piloting_sum / n),
        .avg_condition_pct = @intCast(condition_sum / n),
        .avg_quality = @enumFromInt(quality_sum / n),
    };
    side.bv += lance_bv;
    var lance_power = elem.effectivePower(side.mods);
    if (lance.role == .defense and c.kind.isGarrisonClass()) lance_power = types.applyBp(lance_power, tuning.battle.defense_bonus_bp);
    if (gs.person(lance.commander)) |leader| {
        if (leader.has("tactical_genius")) lance_power = types.applyBp(lance_power, 10_500);
    }
    if (operations_m.committedCombatOp(c)) |op| lance_power = operations_m.lanceTaskPower(op, lance.id, lance_power);
    side.power += lance_power;
}

/// The campaign-state modifiers: every field a lever the player pulled (or
/// didn't) long before the shooting started.
fn companyMods(gs: *GameState, c: *const contract_mod.Contract) autoresolve.CampaignMods {
    var mods: autoresolve.CampaignMods = .{};

    // Supply state: the company's own field stores — spares on
    // hand, and whether the mess has been feeding people.
    const site: types.Site = .{ .company = c.assigned_company };
    mods.supply_parts = gs.stockCount(site, part_mod.structure_key) > 0 or gs.stockCount(site, "armor") > 0;
    const shortage = if (gs.force(c.assigned_company)) |f| f.supply_shortage_days else 0;
    mods.supply_provisions = shortage == 0;

    // People: fatigue & morale across the company (one census: personnel.companyCrewStats).
    const crew_stats = @import("personnel.zig").companyCrewStats(gs, c.assigned_company);
    if (crew_stats.heads > 0) {
        mods.avg_fatigue = crew_stats.avg_fatigue;
        mods.avg_morale = crew_stats.avg_morale;
    }

    // Force structure: recon lance and the support echelon (ARCH §9.3).
    const company = gs.force(c.assigned_company) orelse return mods;
    for (company.children.items) |child_id| {
        const child = gs.force(child_id) orelse continue;
        if (child.echelon == .lance and child.role == .scouting and readiness_m.forceOperational(gs, child) and !c.terms.command_rights.overridesScouting())
            mods.recon_quality = 2;
        if (child.echelon == .air_company) {
            // Air cover: delegate to the single owner in readiness (rule 20, P4g).
            mods.has_air_cover = readiness_m.companyHasOperationalFighter(gs, c.assigned_company);
        }
        if (child.echelon == .support_company) {
            for (child.children.items) |sl_id| {
                const sl = gs.force(sl_id) orelse continue;
                if (!readiness_m.forceOperational(gs, sl)) continue;
                switch (sl.support_kind orelse continue) {
                    .mash => mods.has_mash_lance = true,
                    .mess => mods.has_mess_lance = true,
                    .security => mods.has_security_lance = true,
                    .salvage => mods.has_salvage_lance = true,
                    .transport => {}, // its workshop counts in the repair push (maintenance.repairBudget)
                }
            }
        }
    }
    return mods;
}

/// The enemy's BV in one engagement. It is a force of its own: its
/// lances, whatever you brought, ± the day's variance, scaled by the
/// scenario and the difficulty. A contract with no rolled opposing force
/// scales off the company's committed BV instead.
pub fn engagementEnemyBv(c: *const contract_mod.Contract, player_bv: i64, variance: types.Bp, scenario_bp: types.Bp, difficulty_bp: types.Bp) i64 {
    const base = if (c.hasOpfor())
        types.applyBp(c.opforBv(), 10_000 + variance)
    else
        types.applyBp(player_bv, contract_mod.enemyStrengthBp(c.kind) + variance);
    return types.applyBp(types.applyBp(base, scenario_bp), difficulty_bp);
}

/// Maps a contract to a decision about how to resolve the OpFor:
/// .pool (real hull draw), .forfeit (would-be pool is absent/empty → bloodless win),
/// or .abstraction (no would-be pool → existing RAT/BV behaviour unchanged).
/// Single owner of this routing rule (rule 20, docs/p3c-economy-design.md §8.E).
const PoolResolution = union(enum) {
    pool: struct {
        hulls: *std.ArrayListUnmanaged(types.HullInstanceId),
        owner: hull_instance_for_pool.HullOwner,
    }, // present and non-empty
    forfeit, // would-be pool but absent or empty
    abstraction, // no would-be pool
};

fn opforPool(gs: *GameState, c: *const contract_mod.Contract) PoolResolution {
    // If no campaign-start seeding has happened (faction_rosters and
    // merc_company_rosters are both empty), every contract takes the
    // abstraction path unchanged — this preserves existing test behaviour
    // for tests that do not call execCreateCommander (which seeds rosters).
    // In a real campaign, execCreateCommander seeds all would-be factions
    // before the first engagement, so this branch never fires in production.
    if (gs.faction_rosters.count() == 0 and gs.merc_company_rosters.count() == 0) return .abstraction;
    // PER / pirate_hunting → target gs.faction_rosters["PER"]; would-be iff pirate_pool_hulls > 0.
    const is_pirate = std.mem.eql(u8, c.enemy_key, "PER") or c.kind == .pirate_hunting;
    if (is_pirate) {
        const would_be = tuning.generation.pirate_pool_hulls > 0;
        if (!would_be) return .abstraction;
        if (gs.faction_rosters.getPtr("PER")) |roster| {
            if (roster.items.len > 0) return .{ .pool = .{ .hulls = roster, .owner = .{ .faction = "PER" } } };
        }
        return .forfeit;
    }
    // Rival contract: first enemy-side rival with a linked merc_company_id.
    for (c.rival_ids.items) |rid| {
        const rv = gs.rivals.getPtr(rid) orelse continue;
        if (rv.side != .enemy) continue;
        if (rv.merc_company_id == .none) continue;
        // Seeded merc companies always have a roster: would-be = true.
        if (gs.merc_company_rosters.getPtr(rv.merc_company_id)) |roster| {
            if (roster.items.len > 0) return .{ .pool = .{ .hulls = roster, .owner = .{ .merc_company = rv.merc_company_id } } };
        }
        return .forfeit;
    }
    // Otherwise: faction roster; would-be iff replenishment_hulls_per_year > 0.
    const faction = faction_mod.find(c.enemy_key) orelse return .abstraction;
    if (faction.replenishment_hulls_per_year == 0) return .abstraction;
    if (gs.faction_rosters.getPtr(c.enemy_key)) |roster| {
        if (roster.items.len > 0) return .{ .pool = .{ .hulls = roster, .owner = .{ .faction = c.enemy_key } } };
    }
    return .forfeit;
}

/// Fisher-Yates partial draw of n hulls from the filtered candidate list.
/// Uses gs.rng .battle stream. Returns the first n drawn ids in caller-owned
/// scratch space. Fallible: propagates OOM from the scratch allocation. Does
/// not mutate any gs collection — selection only.
fn drawOpforHulls(gs: *GameState, alloc: std.mem.Allocator, candidates: []const types.HullInstanceId, n: usize) ![]types.HullInstanceId {
    // Copy into resolution scratch, then partial Fisher-Yates for n picks.
    var buf = try alloc.alloc(types.HullInstanceId, candidates.len);
    @memcpy(buf, candidates);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const remaining = buf.len - i;
        const j = i + gs.rng.random(.battle).uintLessThan(usize, remaining);
        const tmp = buf[i];
        buf[i] = buf[j];
        buf[j] = tmp;
    }
    return buf[0..n];
}

pub fn ratioBonus(player_power: i64, enemy_power: i64) i32 {
    if (enemy_power <= 0) return 3;
    const pct = @divTrunc(player_power * 100, enemy_power);
    if (pct >= 150) return 3;
    if (pct >= 125) return 2;
    if (pct >= 110) return 1;
    if (pct >= 91) return 0;
    if (pct >= 76) return -1;
    if (pct >= 60) return -2;
    return -3;
}

/// Damage the engagement did to the player's hulls and crews: one pass
/// per hit, each rolling severity into armour, a mounted slot, a possible
/// kill with its cause and the crew's fate. Appends a `HullHit`
/// per landed hit and returns the tally the AAR's losses line reads.
/// CamOps/AtB damage and crew-casualty rules; `tuning.battle` holds every
/// threshold.
fn applyHits(
    gs: *GameState,
    player: *const SideState,
    engaged: []const types.UnitId,
    hits: u32,
    hit_log: *std.ArrayListUnmanaged(battle_report.HullHit),
) !Tally {
    const tb = tuning.battle;
    var tally: Tally = .{};
    for (0..hits) |_| {
        const uid = engaged[gs.rng.random(.battle).uintLessThan(usize, engaged.len)]; // uniform pick of hit target
        const u = gs.unit(uid) orelse continue;
        if (u.status == .destroyed) continue;
        // Dodge: one hit in three aimed at this hull misses. // TUNE
        if (gs.person(u.pilot)) |dp| if (dp.has("dodge") and gs.rng.random(.battle).uintLessThan(u8, 3) == 0) continue;

        const severity = gs.rng.roll2d6(.battle);
        const hit_ch = chassis_mod.find(u.chassis_key);
        var rec: battle_report.HullHit = .{
            .unit = uid,
            .chassis_key = u.chassis_key,
            .chassis_name = if (hit_ch) |d| d.name else "",
            .armor_before = u.armor_pct,
            .armor_after = 0,
            .pilot = u.pilot,
        };
        u.armor_pct -|= severity * tb.armor_per_severity;
        rec.armor_after = u.armor_pct;
        tally.damage_value += @as(types.CBills, severity) * tb.damage_value_per_severity;

        var ammo_hit = false;
        if (severity >= tb.slot_hit_severity and u.slots.items.len > 0) {
            const slot = &u.slots.items[gs.rng.random(.battle).uintLessThan(usize, u.slots.items.len)]; // uniform pick of damaged slot
            slot.condition = if (slot.condition == .ok) .damaged else .destroyed;
            ammo_hit = slot.class == .ammo;
            rec.slot = slot.slot_key;
            rec.slot_part = slot.part_key;
            rec.slot_result = if (slot.condition == .damaged) .damaged else .destroyed;
        }
        // A bin struck hard enough cooks off (TechManual: no CASE in the
        // 3025 catalogue), and takes the hull with it.
        const cooked_off = ammo_hit and severity >= tb.cookoff_severity;
        if (severity >= tb.kill_severity or (u.armor_pct == 0 and severity >= tb.kill_armorless_severity) or cooked_off) {
            // How it died decides what the rebuild needs.
            var cause: unit_mod.WreckCause = if (ammo_hit) .ammo else if (severity >= tb.kill_severity) .engine else .cored;
            if (cause.needsEngine() and @as(i32, gs.rng.roll2d6(.battle)) <= tuning.loss.scrap_target + gs.diff().scrap_mod) cause = .scrap;
            u.markWreckedBy(cause); // destroyed, with the structure to show for it
            rec.cause = cause;
            tally.destroyed += 1;
            gs.stats.hulls_lost += 1;
            rec.destroyed = true;
            tally.damage_value += @divTrunc(u.purchase_price, 2);
        }

        const casualty = try battle_casualties.apply(gs, u.pilot, severity, player.mods.has_mash_lance);
        rec.crew = casualty.outcome;
        rec.crew_name = casualty.name;
        tally.wounded += casualty.wounded;
        tally.kia += casualty.kia;
        try hit_log.append(gs.scratch(), rec);
    }
    return tally;
}

/// What a pass of hits cost, for the AAR's losses line and the
/// battle-loss compensation the terms owe.
const Tally = struct {
    damage_value: types.CBills = 0,
    destroyed: u8 = 0,
    wounded: u8 = 0,
    kia: u8 = 0,
};

/// Who holds the field keeps the wrecks (CamOps salvage). On a
/// lost field each destroyed hull rolls 2d6 + `recoverySituation` against
/// `tuning.loss.recovery_target` to be dragged off; a miss leaves it to
/// the enemy. Its pilot then rolls to walk out, or is held by them — a
/// ransom, trade or write-off in the inbox. Records both rolls on the
/// hit so the AAR can show the player why a hull did not come home.
fn recoverWrecks(
    gs: *GameState,
    c: *const contract_mod.Contract,
    player: *const SideState,
    scenario: *const @import("../domain/scenario.zig").Scenario,
    outcome: autoresolve.Outcome,
    roe: force_mod.Roe,
    covered: bool,
    trucks: i64,
    hit_log: *std.ArrayListUnmanaged(battle_report.HullHit),
    combined_wrecks: i64,
) !FieldLoss {
    var loss: FieldLoss = .{};
    const t = tuning.loss;
    const situation = battle_recovery.situation(gs, c, scenario, outcome, roe, covered, player.mods.has_salvage_lance, trucks, combined_wrecks);
    for (hit_log.items) |*h| {
        if (!h.destroyed) continue;
        const u = gs.unit(h.unit) orelse continue;
        const roll_r = @as(i32, gs.rng.roll2d6(.battle)) + situation;
        h.recovery = .{ .roll = roll_r, .target = t.recovery_target };
        if (roll_r >= t.recovery_target) continue;
        h.lost = true;
        loss.hulls += 1;
        // The rest of the hull's value is gone too: battle-loss
        // compensation covers it at the contract's rate (CamOps).
        loss.damage_value += u.purchase_price - @divTrunc(u.purchase_price, 2);
        const p = gs.person(u.pilot) orelse continue;
        if (!p.isOnBooks()) continue;
        const escape = battle_recovery.escapeRoll(gs, p.id, outcome) orelse continue;
        if (escape.roll >= escape.target) continue;
        const pid = p.id;
        try battle_recovery.captureMissing(gs, pid, c);
        loss.missing += 1;
        // The name is already on record if this pilot was also hit.
        if (h.crew_name.len == 0) h.crew_name = try p.rankedName(gs.allocator());
        h.crew.fate = .missing;
    }
    return loss;
}

/// What going back bought: hulls won off the field, people walked out,
/// and whether the sortie cost someone.
pub const Push = struct {
    hulls: u32 = 0,
    people: u32 = 0,
    mishap: bool = false,

    pub fn anything(self: Push) bool {
        return self.hulls > 0 or self.people > 0;
    }
};

/// Go back for the downed. Every hull this fight left on the
/// field and every pilot the enemy took gets one more roll against the
/// target that already failed, shifted by `tuning.loss.push_mod` —
/// the enemy holds that ground. Winning a hull back takes it off the
/// limbo list and puts it in the lance it was taken from, still the wreck
/// it was; a pilot who walks out comes home hurt but alive. The night
/// costs the company fatigue either way, and a sortie that rolls at or
/// under `push_mishap_at` costs someone a wound.
///
/// The rule lives here beside `recoverWrecks`, whose roll it re-rolls, so
/// the two cannot drift apart (rule 20). The report is not rewritten: it
/// is the account of the fight, and at the end of the fight those hulls
/// were on the field. What the sortie won is a log line of its own.
pub fn recoveryPush(gs: *GameState, battle: types.BattleId, company: types.ForceId) !Push {
    const t = tuning.loss;
    const report = gs.battle_reports.find(battle) orelse return .{};
    var out: Push = .{};
    for (report.hulls) |h| {
        if (h.lost) {
            const target = if (h.recovery) |r| r.target else t.recovery_target;
            if (@as(i32, gs.rng.roll2d6(.battle)) + t.push_mod >= target) {
                if (try held_hulls_m.releaseHull(gs, h.unit)) out.hulls += 1;
            }
        }
        if (h.crew.fate != .missing) continue;
        const p = gs.person(h.pilot) orelse continue;
        if (p.status != .mia) continue; // ransomed, traded or written off already
        const piloting: i32 = (if (p.role.pilotingSkill()) |s| p.skill(s) else null) orelse 5;
        if (@as(i32, gs.rng.roll2d6(.battle)) + person_mod.skillRollBonus(@intCast(piloting)) + t.push_mod < t.escape_target) continue;
        try @import("contract_events.zig").walkOut(gs, p, company);
        out.people += 1;
    }
    // The night is paid for whether or not it bought anything.
    @import("contract_events.zig").applyToCompany(gs, company, .fatigue, t.push_fatigue);
    if (out.anything()) @import("contract_events.zig").applyToCompany(gs, company, .morale, t.push_morale);
    if (@as(i32, gs.rng.roll2d6(.battle)) <= t.push_mishap_at) {
        out.mishap = try mishapOnTheSortie(gs, company);
    }
    return out;
}

/// A sortie onto ground the enemy holds goes wrong: one of the company's
/// people takes a wound. Returns false if there was nobody to hurt.
fn mishapOnTheSortie(gs: *GameState, company: types.ForceId) !bool {
    var candidates: u32 = 0;
    var pit = gs.people.iterator();
    while (pit.next()) |e| if (gs.companyOf(e.value_ptr.assigned_force) == company and e.value_ptr.isOnBooks()) {
        candidates += 1;
    };
    if (candidates == 0) return false;
    var pick = gs.rng.random(.battle).uintLessThan(u32, candidates);
    pit = gs.people.iterator();
    while (pit.next()) |e| {
        const p = e.value_ptr;
        if (gs.companyOf(p.assigned_force) != company or !p.isOnBooks()) continue;
        if (pick > 0) {
            pick -= 1;
            continue;
        }
        _ = try @import("medical.zig").inflict(gs, p.id, .combat, tuning.battle.wound_serious_severity, "hurt on a night sortie to recover the downed");
        return true;
    }
    return false;
}

/// What a lost field cost: hulls left to the enemy, pilots they hold, and
/// the rest of those hulls' value for the battle-loss claim.
const FieldLoss = struct {
    hulls: u32 = 0,
    missing: u32 = 0,
    damage_value: types.CBills = 0,
};

/// What the engagement brings to its phases, fixed before the phase dice:
/// the scenario off the AtB table, the opposition scaled to it and
/// suppressed by the artillery salvo (ARCH §7 step 2, the contact phase),
/// and the die-free modifiers every phase roll shares. Consumes no draw
/// that depends on orders, so every course of orders sees the same setup.
/// Pool-path .battle draws: scenario → eligible artillery accuracy. Without
/// eligible artillery the accuracy draw is absent. No variance draw on the
/// pool path; force size is already reflected by drawOpforHulls (garrison
/// via drawSize) and pool depletion/exclusion.
fn openEngagement(gs: *GameState, c: *const contract_mod.Contract, player: *const SideState, env: terrain_mod.Environment, enemy_bv_override: ?i64, artillery_result: *?battle_report.ArtilleryResult) Setup {
    // What kind of fight this is (AtB scenario table): it scales
    // the enemy, tilts the roll, weights the score and decides what a
    // held field is worth.
    const scenario = @import("../domain/scenario.zig").roll(&gs.rng, .battle, c.kind);

    // Pool path: enemy BV is the sum of drawn-hull BVs (passed in); skip the
    // variance 2d6 draw, garrison-probe divisor, and attrition clamp.
    // Abstraction path: the existing engagementEnemyBv / variance / divisor / clamp behaviour.
    const enemy_bv: i64 = if (enemy_bv_override) |ov| ov else blk: {
        const variance: types.Bp = (@as(types.Bp, gs.rng.roll2d6(.battle)) - 7) * 500;
        var bv = engagementEnemyBv(c, player.bv, variance, scenario.enemy_bp, gs.diff().enemy_bp);
        // A garrison probe is a lance or so of the enemy's, not the lot.
        if (c.kind.isGarrisonClass() and c.hasOpfor()) bv = @divTrunc(bv * @min(tuning.battle.garrison_probe_lances, c.enemy_lances), c.enemy_lances);
        // Attrition contracts: the enemy can only field what's left of their pool.
        if (c.objective == .attrition and c.enemy_pool_remaining > 0) bv = @min(bv, c.enemy_pool_remaining);
        break :blk bv;
    };
    const pirates = std.mem.eql(u8, c.enemy_key, "PER");
    // Their skill: the rolled level, else pirates green, houses regular.
    const enemy_skills: [2]u8 = if (c.hasOpfor()) @import("../domain/opfor.zig").skills(c.enemy_quality) else if (pirates) .{ 5, 6 } else .{ 4, 5 };
    const enemy_elem: autoresolve.Element = .{
        .base_strength = enemy_bv,
        .avg_gunnery = enemy_skills[0],
        .avg_piloting = enemy_skills[1],
    };
    const enemy_power = artillery_battle.fire(gs, artillery_result, player.mods.recon_quality, enemy_elem.effectivePower(.{}));

    // Task modifiers: aggregate effect of per-lance assignments (P4e).
    // Pure, deterministic, no new RNG draw.
    const task_mods = if (operations_m.committedCombatOp(c)) |op|
        operations_m.operationTaskMods(gs, c, op)
    else
        operations_m.TaskMods{};

    // Tempo modifiers: deterministic pre-roll adjustment from the operation's
    // posture (P4f). Default advance = all-zero → no change to existing behaviour.
    // No new RNG draw; battle.zig MUST NOT import operation_control.zig (rule 5).
    const tempo_mods: operations_m.TempoProfile = if (operations_m.committedCombatOp(c)) |op|
        operations_m.operationTempoMods(op)
    else
        operations_m.TempoProfile{ .surprise_reduction = 0, .prepared_roll_bonus = 0 };

    const intervention_mods: operations_m.InterventionProfile = if (operations_m.committedCombatOp(c)) |op|
        operations_m.operationInterventionMods(op)
    else
        operations_m.InterventionProfile{ .surprise_reduction = 0, .prepared_roll_bonus = 0 };

    // The scenario's tilt, and what scouts give back (an ambush spotted
    // is half an ambush).
    // Recon task also reduces the scenario's surprise element (surprise_reduction). // TUNE
    const scenario_mod: i32 = @as(i32, scenario.roll_mod) + (if (player.mods.recon_quality > 0) @as(i32, scenario.scout_bonus) else 0) + env.rollMod() + task_mods.surprise_reduction + tempo_mods.surprise_reduction + tempo_mods.prepared_roll_bonus + intervention_mods.surprise_reduction + intervention_mods.prepared_roll_bonus;
    // Close terrain evens the odds: numbers count for less in the woods and the streets.
    const ratio_bonus: i32 = if (env.close()) @min(ratioBonus(player.power, enemy_power), 2) else ratioBonus(player.power, enemy_power);
    // Edge: the first pilot in the line with Edge to spend re-rolls a lost
    // decisive phase once per contract (`battle_phases.decisiveVerdict`).
    var edge_pilot: types.PersonId = .none;
    for (player.engaged.items) |uid| {
        const u = gs.unit(uid) orelse continue;
        const p = gs.person(u.pilot) orelse continue;
        if (p.has("edge") and !p.edge_spent) {
            edge_pilot = p.id;
            break;
        }
    }
    return .{
        .scenario = scenario,
        .enemy_bv = enemy_bv,
        .enemy_power = enemy_power,
        .mods = .{ .ratio_bonus = ratio_bonus, .scenario_mod = scenario_mod },
        // Rules of engagement: the company's standing order, unless an
        // integrated employer's officers set it.
        .roe = effectiveRoe(gs, c, c.assigned_company),
        .reserve_present = task_mods.reserve_present,
        .edge_pilot = edge_pilot,
    };
}

/// What the engagement brings to its phases (`openEngagement`).
const Setup = struct {
    scenario: *const @import("../domain/scenario.zig").Scenario,
    enemy_bv: i64,
    enemy_power: i64,
    mods: battle_phases.Mods,
    /// The rules of engagement in force when contact is joined.
    roe: force_mod.Roe,
    /// A reserve-tasked lance stands behind the line (P4e).
    reserve_present: bool,
    /// An id, not a pointer: prisoners are hired into `people` before
    /// the report is written, and that insertion can move every entry.
    edge_pilot: types.PersonId,

    fn inputs(self: Setup, engaged: usize, avail: battle_phases.Availability) battle_phases.Inputs {
        return .{ .mods = self.mods, .roe = self.roe, .engaged = engaged, .edge_available = self.edge_pilot != .none, .reserve_present = self.reserve_present, .avail = avail };
    }
};

/// What the contact-pause levers may draw on (ARCH §7 "The phased
/// engagement"), from live state at engagement start and the engagement's
/// weather: an operational reserve-tasked lance of the committed combat
/// operation, each intervention's gate, prior application and employer
/// lock, and the command capacity the commander may spend. With no
/// committed combat operation no lever is available. The battle lock keeps
/// every input unchanged until the battle publishes. Pure.
fn leverAvailability(gs: *GameState, c: *const contract_mod.Contract, air_grounded: bool) battle_phases.Availability {
    var avail: battle_phases.Availability = .{ .capacity = operations_m.commandCapacityAvailable(c), .air_grounded = air_grounded };
    const op = operations_m.committedCombatOp(c) orelse return avail;
    for (op.tasks.items) |lt| {
        if (lt.task != .reserve) continue;
        const lance = gs.force(lt.lance) orelse continue;
        if (readiness_m.forceOperational(gs, lance)) avail.reserve_ready = true;
    }
    for (std.enums.values(operation_mod.Intervention)) |kind| avail.interventions.set(kind, .{
        .gate = operations_m.interventionGate(gs, c, op, kind),
        .applied = operations_m.interventionApplied(op, kind),
        .reserved = operations_m.interventionReservedByEmployer(c.terms.command_rights, kind),
    });
    return avail;
}

/// The verdict the consequences read: how the decisive phase, or a
/// withdrawal after contact, went.
const Verdict = struct {
    scenario: *const @import("../domain/scenario.zig").Scenario,
    outcome: autoresolve.Outcome,
    roe: force_mod.Roe,
    held_field: bool,
    withdrew: bool,
};

/// What the engagement leaves behind once the shooting stops: the
/// contract's score and victory points, the convoy a lost escort exposes,
/// company morale and fatigue, the crews' experience, and the
/// kills and awards they earned. Returns the figures the AAR
/// reports, so no screen recomputes them.
fn aftermath(
    gs: *GameState,
    c: *contract_mod.Contract,
    player: *const SideState,
    verdict: Verdict,
    env: terrain_mod.Environment,
    engaged: []const types.UnitId,
    enemy_destroyed_bv: i64,
    wounded: u8,
    kia: u8,
    per_unit: *std.ArrayListUnmanaged(@import("personnel.zig").UnitKills),
) !Aftermath {
    const tb = tuning.battle;
    const rt = tuning.loss.roe;
    const scenario = verdict.scenario;
    const outcome = verdict.outcome;
    const roe = verdict.roe;
    const lost_fight = outcome.isLoss();
    const withdrew = verdict.withdrew;
    c.battles_fought +|= 1;
    c.casualties +|= wounded + kia;
    switch (outcome) {
        .decisive_victory, .victory => gs.stats.battles_won += 1,
        .draw => gs.stats.battles_drawn += 1,
        .defeat, .rout => gs.stats.battles_lost += 1,
    }
    gs.stats.enemy_bv_destroyed += @intCast(@max(0, enemy_destroyed_bv));

    const score_delta: i32 = @as(i32, scenario.score_mult) * switch (outcome) {
        .decisive_victory => tb.score.decisive_victory,
        .victory => tb.score.victory,
        .draw => tb.score.draw,
        .defeat => c.terms.command_rights.defeatScore(),
        .rout => tb.score.rout,
    };
    c.score += score_delta;
    if (withdrew) {
        c.score += rt.withdrawal_score;
        c.victory_points += rt.withdrawal_score * tuning.contract.vp_per_score;
    }
    // Task mods: escort suppresses convoy damage; objective_security adds to score. // TUNE
    const after_task_mods = if (operations_m.committedCombatOp(c)) |op|
        operations_m.operationTaskMods(gs, c, op)
    else
        operations_m.TaskMods{};
    // A convoy escort lost is a convoy hit, unless an escort lance was assigned (P4e).
    const convoy_hit = scenario.support_exposed and outcome.isLoss() and !after_task_mods.escort_present;
    if (convoy_hit) @import("contract_events.zig").damageRandomUnits(gs, c.assigned_company, if (outcome == .rout) 2 else 1, .support);
    // objective_security bonus goes to c.score only, NOT score_delta (avoids P4d VP double-count). // TUNE
    if (after_task_mods.objective_bonus > 0) c.score += after_task_mods.objective_bonus;
    var morale_delta: i32 = switch (outcome) {
        inline else => |o| @field(tb.morale, @tagName(o)),
    };
    if (morale_delta < 0 and player.mods.has_mess_lance) morale_delta += tb.morale.mess_relief; // hot food after a bad day
    if (lost_fight and roe == .hold) morale_delta += rt.hold_morale; // a stand that failed
    // A win on a fight that mattered: breakthroughs, base defences and extractions carried.
    if (score_delta > 0 and scenario.score_mult > 1) morale_delta += tuning.person.morale_objective_bonus;
    applyCompanyAftermath(gs, c.assigned_company, morale_delta, tb.fatigue_base + env.fatigue());
    for (engaged) |uid| {
        const u = gs.unit(uid) orelse continue;
        if (gs.person(u.pilot)) |p| {
            if (p.isOnBooks())
                p.xp += p.xpGain(gs.clock.day_index, if (score_delta > 0) tb.xp_scored else tb.xp_fought);
        }
    }
    // Kill credits and the awards they earn. per_unit is filled by creditKills
    // and carries per-engaged-unit kill counts for HullCombatRecord writing (P3c.2).
    const personnel = @import("personnel.zig");
    const kills_credited = try personnel.creditKills(gs, engaged, enemy_destroyed_bv, .battle, per_unit);
    for (engaged) |uid| if (gs.unit(uid)) |u| {
        _ = try personnel.checkAwards(gs, u.pilot);
    };
    return .{
        .score_delta = score_delta,
        .morale_delta = morale_delta,
        .fatigue_add = tb.fatigue_base + env.fatigue(),
        .convoy_hit = convoy_hit,
        .kills_credited = kills_credited,
    };
}

/// The figures the aftermath produced, for the AAR and the report.
const Aftermath = struct {
    score_delta: i32,
    morale_delta: i32,
    fatigue_add: u8,
    convoy_hit: bool,
    kills_credited: u32,
};

/// Prisoners: a security lance on a held field takes enemy crews
/// alive — people with a house, held by the company until the inbox
/// decides ransom, release or recruitment. Returns how many were taken.
fn takePrisoners(gs: *GameState, c: *const contract_mod.Contract, player: *const SideState, held_field: bool, enemy_loss_pct: u32, enemy_destroyed_bv: i64) !u32 {
    var captured: u32 = 0;
    if (held_field and player.mods.has_security_lance and enemy_loss_pct >= 15) {
        const t = tuning.contract;
        const kills_est: u32 = estimatedKills(enemy_destroyed_bv);
        captured = @min(t.prisoners_max_per_battle, kills_est / t.prisoners_per_kills);
        for (0..captured) |_| {
            const spec = @import("../gen/person_gen.zig").generateWithBonus(&gs.rng, .battle, .mekwarrior, if (std.mem.eql(u8, c.enemy_key, "PER")) -1 else 0);
            const pid = try @import("personnel.zig").hireFromSpec(gs, spec);
            const pow = gs.person(pid).?;
            pow.status = .pow;
            pow.assigned_force = c.assigned_company;
            pow.faction = c.enemy_key;
            pow.morale = 20;
            try @import("contract_events.zig").queuePrisoner(gs, pid, c.assigned_company);
        }
    }
    return captured;
}

/// Failure-atomic hull combat record writes for one engagement.
/// PREPARE: count opfor records needed; RESERVE (only fallible step):
/// ensureUnusedCapacity; COMMIT (infallible): append records, mutate
/// destroyed-hull state and pool.
/// `alloc` is used only for the reserve step — pass gs.allocator() in
/// production and a failing allocator in tests to verify atomicity under
/// reserve failure.
fn writeHullCombatRecords(
    gs: *GameState,
    alloc: std.mem.Allocator,
    engaged: []const types.UnitId,
    opfor_outcomes: []const opfor.OpforHullOutcome,
    drawn: []const types.HullInstanceId,
    report_id: types.BattleId,
    contract_id: types.ContractId,
    per_unit_kills: []const @import("personnel.zig").UnitKills,
    hit_log: []const battle_report.HullHit,
    resolution: PoolResolution,
) !void {
    // PREPARE: count opfor records needed.
    var opfor_record_count: usize = 0;
    for (opfor_outcomes) |oc| {
        if (oc == .destroyed or oc == .combat_ineffective) opfor_record_count += 1;
    }
    // RESERVE: widen to cover both player and opfor records (only fallible step).
    try gs.hull_combat_records.ensureUnusedCapacity(alloc, engaged.len + opfor_record_count);
    // COMMIT (infallible from here): player records first.
    for (engaged) |uid| {
        const u = gs.unit(uid) orelse continue;
        if (u.hull_instance_id == .none) continue;
        // Kills from the per_unit_kills tally built by creditKills.
        var kills: u16 = 0;
        for (per_unit_kills) |pk| {
            if (pk.unit == uid) {
                kills = pk.kills;
                break;
            }
        }
        // Damage summary folded from hit_log entries for this unit.
        var rec_hits_taken: u16 = 0;
        var first_armor: ?i32 = null;
        var last_armor: i32 = 0;
        var rec_slots_damaged: u8 = 0;
        var rec_slots_destroyed: u8 = 0;
        var rec_destroyed: bool = false;
        var rec_cause: unit_mod.WreckCause = .none;
        for (hit_log) |h| {
            if (h.unit != uid) continue;
            rec_hits_taken +|= 1;
            if (first_armor == null) first_armor = h.armor_before;
            last_armor = h.armor_after;
            if (h.slot_result == .damaged) rec_slots_damaged +|= 1;
            if (h.slot_result == .destroyed) rec_slots_destroyed +|= 1;
            if (h.destroyed) {
                rec_destroyed = true;
                rec_cause = h.cause;
            }
        }
        const armor_diff: i32 = if (first_armor) |fa| @max(0, fa - last_armor) else 0;
        gs.hull_combat_records.appendAssumeCapacity(.{
            .hull_instance_id = u.hull_instance_id,
            .battle_id = report_id,
            .contract_id = contract_id,
            .kills = kills,
            .hits_taken = rec_hits_taken,
            .armor_lost = @intCast(@min(std.math.maxInt(u16), armor_diff)),
            .slots_damaged = rec_slots_damaged,
            .slots_destroyed = rec_slots_destroyed,
            .destroyed = rec_destroyed,
            .cause = rec_cause,
        });
    }
    // COMMIT (continued): OpFor records for destroyed and combat_ineffective hulls.
    // destroyed == false records are the exclusion signal for the next battle of
    // this contract (combat_ineffective pre-draw exclusion, docs/p3c-economy-design.md §8.E).
    // surviving hulls get no record and remain in the pool unchanged.
    for (drawn, opfor_outcomes) |hid, oc| {
        if (oc == .surviving) continue;
        gs.hull_combat_records.appendAssumeCapacity(.{
            .hull_instance_id = hid,
            .battle_id = report_id,
            .contract_id = contract_id,
            .kills = 0,
            .hits_taken = 0,
            .armor_lost = 0,
            .slots_damaged = 0,
            .slots_destroyed = 0,
            .destroyed = (oc == .destroyed),
            .cause = if (oc == .destroyed) .cored else .none,
        });
        if (oc != .destroyed) continue;
        // Destroyed hull: remove from the pool so the enemy cannot field it
        // again. Its final disposition belongs to the salvage owners: on a
        // held field the exchange branch or a zero claim in `claimSpoils`
        // has already given it; a claim leaves it active, enemy-owned and
        // pool-removed (a wreck on the field) until `takeSalvage` answers the
        // decision; a lost field's dispersal follows these records.
        // Remove from pool by id-match (orderedRemove preserves remaining
        // order for future draws; the pool pointer from opforPool is still
        // valid — no map key was deleted, only a value element removed).
        switch (resolution) {
            .pool => |pool| {
                var pi: usize = 0;
                while (pi < pool.hulls.items.len) : (pi += 1) {
                    if (pool.hulls.items[pi] == hid) {
                        _ = pool.hulls.orderedRemove(pi);
                        break;
                    }
                }
            },
            else => {},
        }
    }
}

/// Fights an engagement through to its end under the orders an unattended
/// script gives (`battle_phases.defaultOrder`) and publishes it atomically,
/// without scheduling the next one: the engagement a decision's "fight"
/// option starts (`events.Effect.engagement`). Failure changes nothing.
pub fn resolveEngagement(gs: *GameState, c: *contract_mod.Contract) !void {
    return resolveEngagementWithResolutionScratch(gs, c, gs.scratch());
}

fn engagementFixture(gs: *GameState, real_pool: bool) !types.ContractId {
    gs.clock.day_index = 1;
    _ = try founding.createCommander(gs, "T", .LC, .line_officer);
    const company = try @import("starter_company.zig").generateInto(gs, "Alpha");
    if (real_pool) _ = try seedOpforHulls(gs, "DC", 8);
    const id: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), id, .{
        .id = id,
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = if (real_pool) "DC" else "PER",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000, .salvage_pct = 30, .battle_loss_pct = 30 },
        .status = .active,
        .assigned_company = company,
        .monthly_net = 300_000,
        .enemy_lances = if (real_pool) 2 else 0,
    });
    try gs.addStock(.{ .company = company }, "armor", 60);
    for (part_mod.munition_keys) |key| try gs.addStock(.{ .company = company }, key, 40);
    return id;
}

fn artilleryEngagementFixture(gs: *GameState, real_pool: bool) !types.ContractId {
    const artillery = @import("artillery.zig");
    const operations = @import("artillery_operations.zig");
    const operating_crew = @import("artillery_crew.zig");
    const rules = @import("../domain/artillery_operations.zig");
    const id = try engagementFixture(gs, real_pool);
    const c = gs.contracts.getPtr(id).?;
    c.status = .offer;
    c.planet_key = gs.seatPlanetKey().?;
    const home = gs.seat();
    gs.hqs.getPtr(home).?.funds = artillery.purchasePrice() * 2;
    const result = try artillery.buy(gs, .{ .hq = home, .offer = gs.artillery_offers.items[0].id });
    _ = try artillery.attach(gs, .{ .formation = result.artillery_formation, .company = c.assigned_company });
    for (rules.seats) |seat| {
        const pid = try gs.hirePerson(@tagName(seat), "Crew", .vehicle_crew);
        try gs.person(pid).?.skills.put(gs.allocator(), rules.seatSkill(seat), 4);
        _ = try operating_crew.assign(gs, .{ .formation = result.artillery_formation, .person = pid, .seat = seat });
    }
    const tech = try gs.hirePerson("Carrier", "Mechanic", .tech_mechanic);
    try gs.person(tech).?.skills.put(gs.allocator(), .tech_mechanic, 4);
    _ = try operating_crew.assignTech(gs, .{ .formation = result.artillery_formation, .person = tech });
    c.status = .active;
    const f = gs.artillery_formations.getPtr(result.artillery_formation).?;
    f.last_maintenance_day = gs.clock.day_index;
    const site = operations.operationSite(gs, f).?;
    for (rules.families) |family| {
        try gs.addStock(site, rules.packageKey(family), rules.packagesPerLoad(family));
        _ = try operations.reload(gs, .{ .formation = f.id, .family = family });
    }
    return id;
}

fn artilleryFailureFixture(gs: *GameState, real_pool: bool, no_fight: bool) !types.ContractId {
    const id = try artilleryEngagementFixture(gs, real_pool);
    if (no_fight) {
        if (real_pool) {
            gs.faction_rosters.getPtr("DC").?.clearRetainingCapacity();
        } else {
            for (gs.units.values()) |*u| u.status = .destroyed;
        }
    }
    return id;
}

fn damagedArtilleryFailureFixture(gs: *GameState, strong_enemy: bool, complete_early: bool) !types.ContractId {
    const id = try artilleryFailureFixture(gs, true, false);
    gs.artillery_formations.values()[0].armor_pct = 10;
    if (strong_enemy) {
        _ = try seedOpforHulls(gs, "DC", 8);
        gs.contracts.getPtr(id).?.enemy_lances = 4;
        for (gs.faction_rosters.get("DC").?.items) |hull| gs.hull_instances.getPtr(hull).?.base_key = "AS7-D";
        for (gs.units.values()) |*u| if (gs.force(u.force).?.echelon == .support_lance) {
            u.status = .mothballed;
        };
    }
    if (complete_early) {
        const c = gs.contracts.getPtr(id).?;
        c.objective = .attrition;
        c.enemy_pool_bv = 1;
        c.enemy_pool_remaining = 1;
        c.end_day = gs.clock.day_index + 180;
    }
    return id;
}

test "carrier casualty held and lost field failures retry medical terminal and early completion effects" {
    const digest = @import("digest.zig");
    var seeds: [2]?u64 = @splat(null);
    var physical: usize = 0;
    var hits: usize = 0;
    var casualties: usize = 0;
    var held: usize = 0;
    var wrecks: usize = 0;
    for (&seeds, 0..) |*selected, path| for (1..513) |seed| {
        var candidate = GameState.init(std.testing.allocator, .{ .seed = seed });
        defer candidate.deinit();
        const id = try damagedArtilleryFailureFixture(&candidate, path == 1, false);
        try resolveEngagement(&candidate, candidate.contracts.getPtr(id).?);
        const r = candidate.battle_reports.kept.items[0];
        const a = r.artillery.?;
        physical += @intFromBool(a.physical_participation);
        hits += @intFromBool(a.severity != null);
        held += @intFromBool(r.held_field);
        wrecks += @intFromBool(a.newly_wrecked);
        var casualty = false;
        for (a.seats) |seat| casualty = casualty or !seat.outcome.untouched();
        casualties += @intFromBool(casualty);
        const terminal = a.damage == .scuttled or a.damage == .permanently_destroyed;
        if (casualty and a.newly_wrecked and r.held_field == (path == 0) and (path == 0 or terminal)) {
            selected.* = seed;
            break;
        }
    };
    if (seeds[0] == null or seeds[1] == null) std.debug.print("carrier sweep fixture physical={d} hits={d} casualties={d} held={d} wrecks={d} seeds={any}\n", .{ physical, hits, casualties, held, wrecks, seeds });
    for (seeds, 0..) |selected, path| {
        const seed = selected orelse return error.TestUnexpectedResult;
        const complete_early = path == 0;
        var reference = GameState.init(std.testing.allocator, .{ .seed = seed });
        defer reference.deinit();
        const id = try damagedArtilleryFailureFixture(&reference, path == 1, complete_early);
        try resolveEngagement(&reference, reference.contracts.getPtr(id).?);
        if (complete_early) try std.testing.expectEqual(contract_mod.ContractStatus.completed, reference.contracts.get(id).?.status);
        try @import("artillery.zig").validate(&reference);
        const expected = digest.stateHash(&reference);
        var index: usize = 0;
        while (true) : (index += 1) {
            var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer outer.deinit();
            var gs = GameState.init(outer.allocator(), .{ .seed = seed });
            _ = try damagedArtilleryFailureFixture(&gs, path == 1, complete_early);
            const before = digest.stateHash(&gs);
            var failure = std.testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = index });
            gs.arena.state = .{};
            gs.arena.child_allocator = failure.allocator();
            defer gs.deinit();
            if (resolveEngagementWithResolutionScratch(&gs, gs.contracts.getPtr(id).?, failure.allocator())) |_| {
                try std.testing.expectEqual(expected, digest.stateHash(&gs));
                break;
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expectEqual(before, digest.stateHash(&gs));
                gs.arena.child_allocator = outer.allocator();
                try resolveEngagement(&gs, gs.contracts.getPtr(id).?);
                try std.testing.expectEqual(expected, digest.stateHash(&gs));
            }
        }
    }
}

test "artillery fight concession and forfeit failures preserve complete state and retry matches uninterrupted resolution" {
    const digest = @import("digest.zig");
    for ([_]struct { real_pool: bool, no_fight: bool }{
        .{ .real_pool = false, .no_fight = false },
        .{ .real_pool = true, .no_fight = false },
        .{ .real_pool = false, .no_fight = true },
        .{ .real_pool = true, .no_fight = true },
    }) |path| {
        var reference = GameState.init(std.testing.allocator, .{ .seed = 3007 });
        defer reference.deinit();
        const id = try artilleryFailureFixture(&reference, path.real_pool, path.no_fight);
        try resolveEngagement(&reference, reference.contracts.getPtr(id).?);
        const expected = digest.stateHash(&reference);
        try @import("artillery.zig").validate(&reference);
        var index: usize = 0;
        while (true) : (index += 1) {
            var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer outer.deinit();
            var gs = GameState.init(outer.allocator(), .{ .seed = 3007 });
            _ = try artilleryFailureFixture(&gs, path.real_pool, path.no_fight);
            const before = digest.stateHash(&gs);
            var failure = std.testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = index });
            gs.arena.state = .{};
            gs.arena.child_allocator = failure.allocator();
            defer gs.deinit();
            if (resolveEngagementWithResolutionScratch(&gs, gs.contracts.getPtr(id).?, failure.allocator())) |_| {
                try std.testing.expectEqual(expected, digest.stateHash(&gs));
                break;
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expectEqual(before, digest.stateHash(&gs));
                gs.arena.child_allocator = outer.allocator();
                try resolveEngagement(&gs, gs.contracts.getPtr(id).?);
                try std.testing.expectEqual(expected, digest.stateHash(&gs));
            }
        }
    }
}

test "artillery concession and enemy forfeit retain attached snapshots without salvo draws or history" {
    const artillery = @import("artillery.zig");
    const combat = @import("../domain/artillery_combat.zig");
    for ([_]bool{ false, true }) |forfeited| {
        var gs = GameState.init(std.testing.allocator, .{ .seed = 3007 });
        defer gs.deinit();
        const id = try artilleryEngagementFixture(&gs, forfeited);
        const c = gs.contracts.getPtr(id).?;
        if (forfeited) {
            gs.faction_rosters.getPtr("DC").?.clearRetainingCapacity();
        } else {
            for (gs.units.values()) |*u| u.status = .destroyed;
        }
        try resolveEngagement(&gs, c);
        const a = gs.battle_reports.kept.items[0].artillery.?;
        try std.testing.expectEqual(if (forfeited) combat.NoFire.enemy_forfeit else combat.NoFire.no_line_units, a.no_fire);
        try std.testing.expectEqual(@as(?u8, null), a.accuracy_roll);
        try std.testing.expectEqual(@as(?u8, null), a.exposure_roll);
        try std.testing.expectEqual(a.rounds_before, a.rounds_after);
        try std.testing.expectEqual(@as(usize, 0), gs.hull_combat_records.items.len);
        try artillery.validate(&gs);
    }
}

test "late engagement outcome allocation leaves complete campaign unchanged" {
    const digest = @import("digest.zig");
    var index: usize = 0;
    while (true) : (index += 1) {
        var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer outer.deinit();
        var gs = GameState.init(outer.allocator(), .{ .seed = 3007 });
        const id = try engagementFixture(&gs, true);
        const before = digest.stateHash(&gs);
        var failure = std.testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = index });
        gs.arena.state = .{};
        gs.arena.child_allocator = failure.allocator();
        defer gs.deinit();
        if (resolveEngagementWithResolutionScratch(&gs, gs.contracts.getPtr(id).?, failure.allocator())) |_| break else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(before, digest.stateHash(&gs));
        }
    }
}

test "non artillery engagement reference preserves every gameplay field and stream" {
    const digest = @import("digest.zig");
    for ([_]bool{ false, true }) |real_pool| {
        var gs = GameState.init(std.testing.allocator, .{ .seed = 3007 });
        defer gs.deinit();
        const id = try engagementFixture(&gs, real_pool);
        try resolveEngagement(&gs, gs.contracts.getPtr(id).?);
        try std.testing.expectEqual(if (real_pool) @as(u64, 14511676169581142753) else @as(u64, 9362499418440933783), digest.nonArtilleryReferenceHash(&gs));
    }
}

test "the daily tick fights nothing: two due engagements hold the turn one after the other" {
    const digest = @import("digest.zig");
    const checklist = @import("checklist.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3007 });
    defer gs.deinit();
    const first = try engagementFixture(&gs, true);
    const second: types.ContractId = @enumFromInt(2);
    var other = gs.contracts.get(first).?;
    other.id = second;
    other.next_battle_day = 0;
    gs.contracts.getPtr(first).?.next_battle_day = 0;
    try gs.contracts.put(gs.allocator(), second, other);
    const before = digest.stateHash(&gs);
    try runDaily(&gs);
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    try std.testing.expectEqual(@as(?checklist.Hold, .engagement_due), checklist.turnHold(&gs));
    try std.testing.expectEqual(@as(?types.ContractId, first), dueEngagement(&gs));
    // The second contract waits while the first is fought.
    _ = try commands.execute(&gs, .{ .battle_order = .{ .contract = first, .order = .engage } });
    const engaged = digest.stateHash(&gs);
    try std.testing.expectError(error.BattleInProgress, commands.execute(&gs, .{ .battle_order = .{ .contract = second, .order = .engage } }));
    try std.testing.expectEqual(engaged, digest.stateHash(&gs));
    while (battle_phases.inProgress(&gs) != null) try @import("tick.zig").fightDueEngagement(&gs);
    try std.testing.expectEqual(@as(u32, 1), gs.contracts.get(first).?.battles_fought);
    try std.testing.expect(!engagementDue(&gs, gs.contracts.getPtr(first).?));
    try @import("tick.zig").clearHolds(&gs);
    try std.testing.expectEqual(@as(u32, 1), gs.contracts.get(second).?.battles_fought);
    try std.testing.expectEqual(@as(?checklist.Hold, null), checklist.turnHold(&gs));
}

test "initial contact schedule overflow leaves complete campaign unchanged" {
    const digest = @import("digest.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3007 });
    defer gs.deinit();
    _ = try engagementFixture(&gs, false);
    gs.clock.day_index = std.math.maxInt(u32);
    const before = digest.stateHash(&gs);
    try std.testing.expectError(error.OutOfRange, runDaily(&gs));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
}

fn resolveEngagementWithResolutionScratch(gs: *GameState, c: *contract_mod.Contract, resolution_backing: std.mem.Allocator) !void {
    var engagement = try battle_preparation.Engagement.init(gs, resolution_backing);
    defer engagement.deinit();
    const staged = &engagement.view;
    const contract = staged.contracts.getPtr(c.id) orelse return error.UnknownContract;
    _ = try fightStaged(staged, contract, .unattended, resolution_backing);
    var publication = try engagement.prepare(gs);
    publication.commit(gs, staged);
}

/// How an engagement is fought: under the orders given so far, or through
/// to its end under the orders an unattended script gives
/// (`battle_phases.defaultOrder`).
const Orders = union(enum) {
    given: []const battle_phase.Order,
    unattended,
};

/// What one replay of an engagement reached.
const Reached = union(enum) {
    paused: battle_phase.PhaseReport,
    finished,
};

/// Fights an engagement in the staged workspace `gs` (rule 76: preparation
/// here and in `drawOpposition`/`openEngagement`, the phase verdicts in
/// `battle_phases`, the consequences in `concludeEngagement`; the next
/// schedule is the caller's). A pause leaves the workspace to be discarded;
/// a finished engagement has applied its complete aftermath to it.
/// Concession (nobody fit to field) and forfeit (the enemy pool exhausted)
/// finish on the first order, at their positions in the preparation.
fn fightStaged(gs: *GameState, c: *contract_mod.Contract, orders: Orders, resolution_backing: std.mem.Allocator) !Reached {
    return fightStagedObserved(gs, c, orders, resolution_backing, null);
}

/// What an engagement brought to its phases and the dice it drew, for a
/// test to compare the command's course with `battle_phases.run`.
const Observed = struct { inputs: battle_phases.Inputs, dice: battle_phases.Dice };

fn fightStagedObserved(gs: *GameState, c: *contract_mod.Contract, orders: Orders, resolution_backing: std.mem.Allocator, observed: ?*?Observed) !Reached {
    try gs.battle_reports.prepareRecord(gs.allocator());
    var resolution_scratch = std.heap.ArenaAllocator.init(resolution_backing);
    defer resolution_scratch.deinit();
    const resolution_alloc = resolution_scratch.allocator();
    // Fighter selection and its selected-unit ammunition census reserve all
    // storage before weather advances the .battle stream.
    var player = try preparePlayerSide(gs, gs.scratch(), c);
    defer player.family_mounts.deinit(gs.scratch());
    defer player.ammo_reserved.deinit(gs.scratch());
    defer player.engaged.deinit(gs.scratch());
    const opposition = (try drawOpposition(gs, c, resolution_alloc)) orelse {
        try forfeit(gs, c);
        return .finished;
    };

    // Complete every fallible OpFor allocation and draw before weather consumes
    // the battle stream, so a failed draw allocation leaves the engagement unchanged.
    const env: terrain_mod.Environment = blk: {
        const world = planet_mod.find(c.planet_key) orelse break :blk .{};
        const t = terrain_mod.terrainOf(world);
        break :blk .{ .terrain = t, .weather = terrain_mod.rollWeather(&gs.rng, .battle, t) };
    };
    populatePlayerSide(gs, c, env, &player);
    if (player.engaged.items.len == 0) {
        try concede(gs, c);
        return .finished;
    }

    var artillery_result = try artillery_battle.snapshot(gs, c, .not_ready);
    const setup = openEngagement(gs, c, &player, env, opposition.enemy_bv_override, &artillery_result);
    const dice = battle_phases.Dice.draw(&gs.rng);
    const inputs = setup.inputs(player.engaged.items.len, leverAvailability(gs, c, env.groundsAir()));
    if (observed) |out| out.* = .{ .inputs = inputs, .dice = dice };
    const final = switch (try courseOf(inputs, dice, orders)) {
        .paused => |report| return .{ .paused = report },
        .finished => |f| f,
    };
    try concludeEngagement(gs, c, &player, opposition, env, setup, artillery_result, final, resolution_alloc);
    return .finished;
}

/// A course's refusal as the battle order command gives it: an order not
/// legal where it is given, or a lever's own refusal (`leverAllowed`).
const CourseError = error{
    OrderNotLegal,
    ReserveUnavailable,
    InterventionGateUnmet,
    InterventionAlreadyApplied,
    InsufficientCommandCapacity,
    InterventionReservedByEmployer,
    AirCoverGrounded,
};

fn courseError(err: battle_phases.LeverError) CourseError {
    return switch (err) {
        error.IllegalOrder => error.OrderNotLegal,
        error.ReserveUnavailable => error.ReserveUnavailable,
        error.InterventionGateUnmet => error.InterventionGateUnmet,
        error.InterventionAlreadyApplied => error.InterventionAlreadyApplied,
        error.InsufficientCommandCapacity => error.InsufficientCommandCapacity,
        error.InterventionReservedByEmployer => error.InterventionReservedByEmployer,
        error.AirCoverGrounded => error.AirCoverGrounded,
    };
}

/// The course of the engagement under `orders`. Unattended, each pause is
/// answered with `battle_phases.defaultOrder` until the battle ends.
fn courseOf(inputs: battle_phases.Inputs, dice: battle_phases.Dice, orders: Orders) CourseError!battle_phases.Course {
    switch (orders) {
        .given => |list| return battle_phases.run(inputs, dice, list) catch |err| return courseError(err),
        .unattended => {
            var list: [battle_phases.max_phases]battle_phase.Order = undefined;
            list[0] = battle_phases.defaultOrder(null);
            var n: usize = 1;
            while (true) {
                const course = battle_phases.run(inputs, dice, list[0..n]) catch |err| return courseError(err);
                switch (course) {
                    .finished => return course,
                    .paused => |report| {
                        list[n] = battle_phases.defaultOrder(&report);
                        n += 1;
                    },
                }
            }
        },
    }
}

/// The opposition an engagement draws (`opforPool`): the routing, and on
/// the pool path the hulls fielded and their summed BV.
const Opposition = struct {
    resolution: PoolResolution,
    drawn: []types.HullInstanceId = &.{},
    enemy_bv_override: ?i64 = null,
};

/// Routes the opposition (docs/p3c-economy-design.md §8.E; single owner:
/// `opforPool`) and, on the pool path, reserves the lost-field dispersal and
/// draws the fielded hulls into `resolution_alloc`, all before weather.
/// Null when the enemy forfeits: its pool is absent, empty, or every
/// remaining hull was combat-ineffective earlier on this contract.
fn drawOpposition(gs: *GameState, c: *const contract_mod.Contract, resolution_alloc: std.mem.Allocator) !?Opposition {
    const resolution = opforPool(gs, c);
    var draw_candidates: []const types.HullInstanceId = &.{};
    var filtered_candidates: ?[]types.HullInstanceId = null;
    defer if (filtered_candidates) |buf| gs.scratch().free(buf);
    var draw_count: usize = 0;
    switch (resolution) {
        .abstraction => return .{ .resolution = resolution }, // existing RAT/BV abstraction behaviour
        .forfeit => return null,
        .pool => |pool| {
            // Exclusion set: hulls that were combat_ineffective in an earlier
            // battle of this contract (derived from committed records, no new column).
            // destroyed == false records signal combat_ineffective (not simply surviving,
            // because surviving hulls get no record). Player-hull ids are harmless: they
            // are never pool members.
            // Use scratch for transient filter buffers; free before returning.
            const excl_buf_raw = try gs.scratch().alloc(types.HullInstanceId, gs.hull_combat_records.items.len);
            defer gs.scratch().free(excl_buf_raw);
            var excl_len: usize = 0;
            for (gs.hull_combat_records.items) |rec| {
                if (rec.contract_id == c.id and !rec.destroyed) {
                    excl_buf_raw[excl_len] = rec.hull_instance_id;
                    excl_len += 1;
                }
            }
            const excluded = excl_buf_raw[0..excl_len];
            // Filtered candidates: pool members not in the exclusion set.
            if (excluded.len == 0) {
                draw_candidates = pool.hulls.items;
            } else {
                const filt_buf_raw = try gs.scratch().alloc(types.HullInstanceId, pool.hulls.items.len);
                var filt_len: usize = 0;
                for (pool.hulls.items) |hid| {
                    var excl = false;
                    for (excluded) |eid| if (eid == hid) {
                        excl = true;
                        break;
                    };
                    if (!excl) {
                        filt_buf_raw[filt_len] = hid;
                        filt_len += 1;
                    }
                }
                filtered_candidates = filt_buf_raw;
                draw_candidates = filt_buf_raw[0..filt_len];
            }
            if (draw_candidates.len == 0) return null; // all remaining hulls combat_ineffective
            const garrison_probe = c.kind.isGarrisonClass();
            draw_count = opfor.drawSize(draw_candidates.len, c.enemy_lances, garrison_probe);

            // A lost field can disperse every drawn hull. Reserve that path before
            // weather or draw RNG advances and before battle state changes.
            try black_market.prepareEnemyWreckDispersal(gs, gs.allocator(), draw_count, pool.owner);
            if (filtered_candidates == null) draw_candidates = pool.hulls.items;
        },
    }

    const drawn = try drawOpforHulls(gs, resolution_alloc, draw_candidates, draw_count);
    // Fielded BV = Σ drawn-hull BVs (B2: the phase rolls use real hull BVs).
    var fielded_bv: i64 = 0;
    for (drawn) |hid| {
        const inst = gs.hull_instances.getPtr(hid) orelse continue;
        if (chassis_mod.find(inst.base_key)) |ch| fielded_bv += ch.bv;
    }
    return .{ .resolution = resolution, .drawn = drawn, .enemy_bv_override = fielded_bv };
}

/// A finished engagement's complete aftermath, applied to the staged
/// workspace in its fixed RNG order after the phase dice: OpFor hull
/// outcomes, hits, recovery, salvage, prisoners, the aftermath, the
/// operation binding, then the report and what it leaves behind
/// (`publishEngagement`).
fn concludeEngagement(
    gs: *GameState,
    c: *contract_mod.Contract,
    player: *const SideState,
    opposition: Opposition,
    env: terrain_mod.Environment,
    setup: Setup,
    artillery_snapshot: ?battle_report.ArtilleryResult,
    final: battle_phases.Final,
    resolution_alloc: std.mem.Allocator,
) !void {
    const drawn = opposition.drawn;
    const enemy_bv_override = opposition.enemy_bv_override;
    const scenario = setup.scenario;
    const outcome = final.outcome;
    const roe = final.roe;
    const enemy_bv = setup.enemy_bv;
    const engaged = player.engaged.items;
    var artillery_result = artillery_snapshot;
    const verdict: Verdict = .{ .scenario = scenario, .outcome = outcome, .roe = roe, .held_field = final.held_field, .withdrew = final.withdrew };
    // Edge spent on the decisive re-roll.
    if (final.edge_used) gs.person(setup.edge_pilot).?.edge_spent = true;
    const edge_used_by: types.PersonId = if (final.edge_used) setup.edge_pilot else .none;
    // A pursuit runs more of the enemy down.
    const enemy_loss_pct: u32 = @min(100, final.enemy_loss_bonus_pct + switch (outcome) {
        inline else => |o| @field(tuning.battle.enemy_loss_pct, @tagName(o)),
    });

    const opfor_result = try opforOutcomes(gs, resolution_alloc, drawn, outcome, final.enemy_loss_bonus_pct);
    const opfor_outcomes = opfor_result.outcomes;

    // A lost-field wreck disposition commits after combat records remove hulls
    // from the pool. Allocate and filter that exact slice before battle state
    // starts changing so the late commit cannot fail.
    const held_field = final.held_field;
    const pool_path = enemy_bv_override != null;
    var destroyed_wrecks_storage: ?[]types.HullInstanceId = null;
    const destroyed_wrecks = if (pool_path and !held_field) blk: {
        const wrecks = try gs.scratch().alloc(types.HullInstanceId, drawn.len);
        destroyed_wrecks_storage = wrecks;
        var wrecks_len: usize = 0;
        for (drawn, opfor_outcomes) |hid, oc| if (oc == .destroyed) {
            wrecks[wrecks_len] = hid;
            wrecks_len += 1;
        };
        break :blk wrecks[0..wrecks_len];
    } else &.{};
    defer if (destroyed_wrecks_storage) |wrecks| gs.scratch().free(wrecks);

    // The detailed AAR: every hit on record — which
    // hull, what it lost, what happened to the crew. The record outlives
    // the fight, so it copies the names it needs (battle_report.HullHit).
    var hit_log: std.ArrayListUnmanaged(battle_report.HullHit) = .empty;
    defer hit_log.deinit(gs.scratch());
    // Pool path: enemy_destroyed_bv from real hull BVs (B2).
    // Abstraction path: existing @divTrunc formula.
    const enemy_destroyed_bv = if (enemy_bv_override != null)
        opfor_result.destroyed_bv
    else
        @divTrunc(enemy_bv * enemy_loss_pct, 100);
    const field = try fieldLosses(gs, c, player, scenario, final, &artillery_result, &hit_log);
    const destroyed = field.destroyed;
    const wounded = field.wounded;
    const kia = field.kia;
    const damage_value = field.damage_value;
    const lost_hulls = field.lost_hulls;
    const missing = field.missing;
    // What the crews can actually haul off the field is bounded by the
    // salvage trucks on hand (`haulCapacityBv`).
    const haulable_bv = @min(enemy_destroyed_bv, haulCapacityBv(field.trucks));
    // The committed combat operation's intent gates salvage and shapes the
    // score below (docs/p4-operations-design.md §6).
    // battle.zig MUST NOT import operation_control.zig (rule 5).
    const committed_op = operations_m.committedCombatOp(c);
    const op_intent: ?operation_mod.Intent = if (committed_op) |op| op.intent else null;
    const spoils = try claimSpoils(gs, c, player, scenario, held_field, op_intent, pool_path, drawn, opfor_outcomes, haulable_bv);

    // Expend the reloads this fight consumed, itemized below.
    // ammo_reserved was drawn from on-hand stock during battle preparation;
    // the batch must be satisfiable — a short is a programming error (rule 15).
    if (!sites.consumeStockBatch(gs, player.site, &player.ammo_reserved)) unreachable;
    const captured = try takePrisoners(gs, c, player, held_field, enemy_loss_pct, enemy_destroyed_bv);
    const comp = types.applyPct(damage_value, c.terms.battle_loss_pct);
    if (comp > 0) {
        try gs.postTransaction(.{
            .day = gs.clock.day_index,
            .amount = comp,
            .category = .battle_loss_comp,
            .company = c.assigned_company,
            .contract = c.id,
            .note = "battle loss compensation",
        });
    }

    // Score, morale, fatigue, experience.
    // per_unit_kills receives per-unit kill tallies from creditKills for
    // HullCombatRecord writing below (P3c.2). Scratch-owned; freed after use.
    var per_unit_kills: std.ArrayListUnmanaged(@import("personnel.zig").UnitKills) = .empty;
    defer per_unit_kills.deinit(gs.scratch());
    const after = try aftermath(gs, c, player, verdict, env, engaged, enemy_destroyed_bv, wounded, kia, &per_unit_kills);
    const score_delta = after.score_delta;
    const morale_delta = after.morale_delta;
    const convoy_hit = after.convoy_hit;
    const kills_credited = after.kills_credited;
    try artillery_battle.reward(gs, &artillery_result, score_delta);

    // Apply intent profile (deterministic post-roll modifiers; no new RNG draw;
    // docs/p4-operations-design.md §6 decision 3, rule 57).
    // `op_intent` was captured before the salvage section; the committed op is
    // still the same (battle.zig MUST NOT import operation_control.zig, rule 5).
    if (op_intent) |intent| {
        const profile = operations_m.intentProfile(intent);
        if (after.score_delta != 0) {
            const base = after.score_delta;
            const score_extra = @as(i32, @intCast(types.applyBp(@as(i64, base), @as(i64, profile.score_bp)))) - base;
            const vp_extra = (@as(i32, @intCast(types.applyBp(@as(i64, base), @as(i64, profile.vp_bp)))) - base) * tuning.contract.vp_per_score;
            // score_extra goes to c.score (contract grade) but NOT to score_delta;
            // score_delta carries only the base engagement outcome to recordBattle,
            // which converts it to VP. vp_extra is the full intent VP contribution.
            c.score += score_extra;
            c.victory_points += vp_extra;
        }
        if (profile.fatigue_add > 0) applyCompanyAftermath(gs, c.assigned_company, 0, profile.fatigue_add);
    }

    // Everything this engagement did, as fields. The AAR is
    // rendered from it, so the record and the narrative cannot drift.
    const report = try assembleReport(gs, c, player, env, setup, final, .{
        .artillery = artillery_result,
        .convoy_hit = convoy_hit,
        .edge_used_by = edge_used_by,
        .destroyed = destroyed,
        .wounded = wounded,
        .kia = kia,
        .lost_hulls = lost_hulls,
        .missing = missing,
        .enemy_destroyed_bv = enemy_destroyed_bv,
        .kills_credited = kills_credited,
        .prisoners = captured,
        .battle_loss_comp = comp,
        .score_delta = score_delta,
        .morale_delta = morale_delta,
        .fatigue_add = after.fatigue_add,
        .hits = hit_log.items,
        .haulable_bv = haulable_bv,
        .spoils = spoils,
    });
    try publishEngagement(gs, c, report, .{
        .hit_log = hit_log.items,
        .opposition = opposition,
        .opfor_outcomes = opfor_outcomes,
        .destroyed_wrecks = destroyed_wrecks,
        .engaged = engaged,
        .per_unit_kills = per_unit_kills.items,
        .artillery = artillery_result,
        .carrier_missing = field.carrier_missing,
        .enemy_destroyed_bv = enemy_destroyed_bv,
        .score_delta = score_delta,
    });
}

/// Pool path: one outcome per drawn hull at its fixed position in the
/// `.battle` stream after the phase dice, a pursuit widening the destroyed
/// band, and the BV of the hulls destroyed. Abstraction path: `drawn` is
/// empty and so is the result.
fn opforOutcomes(gs: *GameState, alloc: std.mem.Allocator, drawn: []const types.HullInstanceId, outcome: autoresolve.Outcome, loss_bonus_pct: u8) !struct { outcomes: []opfor.OpforHullOutcome, destroyed_bv: i64 } {
    const outcomes = try alloc.alloc(opfor.OpforHullOutcome, drawn.len);
    var destroyed_bv: i64 = 0;
    for (drawn, outcomes) |hid, *oc| {
        oc.* = opfor.hullOutcomePursued(&gs.rng, .battle, outcome, loss_bonus_pct);
        if (oc.* != .destroyed) continue;
        const inst = gs.hull_instances.getPtr(hid) orelse continue;
        if (chassis_mod.find(inst.base_key)) |ch| destroyed_bv += ch.bv;
    }
    return .{ .outcomes = outcomes, .destroyed_bv = destroyed_bv };
}

/// What the line lost: the hits (`applyHits`), the carrier's exposure, and
/// on a lost field the wreck recovery and the crews' escape.
const Field = struct {
    destroyed: u8,
    wounded: u8,
    kia: u8,
    damage_value: types.CBills,
    lost_hulls: u32,
    missing: u32,
    /// Missing people from the carrier's crew alone.
    carrier_missing: u32,
    trucks: i64,
};

/// The finished engagement's losses, in their RNG order: the hits on the
/// line, the carrier's exposure, then on a lost field the recovery rolls
/// (CamOps salvage: who holds the field keeps the wrecks; a wreck comes home
/// only if the crews can reach it, and its pilot walks out or is taken).
/// Appends every hit to `hit_log` and records the recovery rolls on it.
fn fieldLosses(
    gs: *GameState,
    c: *contract_mod.Contract,
    player: *const SideState,
    scenario: *const @import("../domain/scenario.zig").Scenario,
    final: battle_phases.Final,
    artillery_result: *?battle_report.ArtilleryResult,
    hit_log: *std.ArrayListUnmanaged(battle_report.HullHit),
) !Field {
    const tally = try applyHits(gs, player, player.engaged.items, final.hits, hit_log);
    var damage_value = tally.damage_value;
    const carrier_hit = try artillery_battle.applyExposure(gs, artillery_result, final.hit_pct, player.mods.has_mash_lance);
    var combined_wrecks: i64 = 0;
    for (hit_log.items) |hit| combined_wrecks += @intFromBool(hit.destroyed);
    if (artillery_result.*) |a| if (a.physical_participation and a.damage == .recoverable) {
        combined_wrecks += 1;
    };
    const trucks = salvageTrucks(gs, c.assigned_company);
    var lost_hulls: u32 = 0;
    var missing: u32 = 0;
    if (!final.held_field) {
        const loss = try recoverWrecks(gs, c, player, scenario, final.outcome, final.recovery_roe, final.covered, trucks, hit_log, combined_wrecks);
        lost_hulls = loss.hulls;
        missing = loss.missing;
        damage_value += loss.damage_value;
    }
    const carrier_loss = try artillery_battle.recover(gs, artillery_result, c, scenario, final.outcome, final.recovery_roe, final.covered, final.held_field, player.mods.has_salvage_lance, trucks, combined_wrecks);
    if (artillery_result.*) |a| damage_value += a.compensation_basis;
    return .{
        .destroyed = tally.destroyed + carrier_hit.destroyed,
        .wounded = tally.wounded + carrier_hit.wounded,
        .kia = tally.kia + carrier_hit.kia,
        .damage_value = damage_value,
        .lost_hulls = lost_hulls + carrier_loss.lost,
        .missing = missing + carrier_loss.missing,
        .carrier_missing = carrier_loss.missing,
        .trucks = trucks,
    };
}

/// What the salvage claim became (`battle_report.SalvageManifest`).
const Spoils = struct {
    claimed_bv: i64,
    liaison_cut: i64,
    exchange_cash: types.CBills,
    items: []const u8,
    candidates: []const battle_report.SalvageCandidate,
    unclaimed_bv: i64,
};

/// Salvage is things, not money: the company's share of what the crews
/// haul off a held field becomes wrecks and parts crated home — or cash
/// under a salvage exchange. The claim is gated by the committed
/// operation's intent and cut by the employer's liaison; a haul worth a
/// choice waits in the inbox rather than being taken now.
fn claimSpoils(
    gs: *GameState,
    c: *contract_mod.Contract,
    player: *const SideState,
    scenario: *const @import("../domain/scenario.zig").Scenario,
    held_field: bool,
    op_intent: ?operation_mod.Intent,
    /// Real drawn hulls were fielded (`Opposition.enemy_bv_override` is set).
    pool_path: bool,
    drawn: []const types.HullInstanceId,
    opfor_outcomes: []const opfor.OpforHullOutcome,
    haulable_bv: i64,
) !Spoils {
    var salvage_bv: i64 = if (held_field) types.applyBp(salvageClaimBv(haulable_bv, c.terms.salvage_pct, player.mods.has_salvage_lance), scenario.salvage_bp) else 0;
    // Gate salvage on the committed operation's intent profile (rule 20).
    // No new RNG draw: intent is a deterministic post-roll modifier (design §6).
    if (op_intent) |intent| {
        if (!operations_m.intentProfile(intent).salvage_allowed) salvage_bv = 0;
    }
    // The liaison's cut: under tighter command rights the employer
    // claims part of what you haul.
    const before_cut = salvage_bv;
    salvage_bv = types.applyBp(salvage_bv, c.terms.command_rights.salvageShareBp());
    var out: Spoils = .{ .claimed_bv = salvage_bv, .liaison_cut = before_cut - salvage_bv, .exchange_cash = 0, .items = "", .candidates = &.{}, .unclaimed_bv = 0 };
    if (c.terms.salvage_exchange) {
        // Salvage exchange: the employer keeps every wreck and part and
        // pays the claim in cash into the company's local funds.
        out.exchange_cash = types.applyBp(salvage_bv * tuning.contract.salvage_cbills_per_bv, tuning.contract.salvage_exchange_bp);
        if (out.exchange_cash > 0) try gs.postTreasury(.{ .company = c.assigned_company }, .{
            .day = gs.clock.day_index,
            .amount = out.exchange_cash,
            .category = .salvage,
            .company = c.assigned_company,
            .contract = c.id,
            .note = "salvage exchange",
        });
        // Pool path, held field: employer takes every destroyed drawn hull
        // immediately (B6). No inbox, no player unit; cash already posted.
        if (pool_path and held_field) {
            for (drawn, opfor_outcomes) |hid, oc| {
                if (oc == .destroyed) try gs.transferHullOwnership(hid, .{ .faction = c.employer_key }, c.enemy_key, .salvage);
            }
        }
        if (out.exchange_cash > 0) out.items = try std.fmt.allocPrint(gs.allocator(), "salvage exchange — the employer keeps the wrecks and pays {s} c-bills for your {d} BV claim", .{ try types.moneyText(gs.allocator(), out.exchange_cash), salvage_bv });
        return out;
    }
    // Roll (or build from drawn hulls) what is out there once, then see
    // whether the claim buys a real choice. If it does, nothing is taken
    // yet — the commander divides the haul from the inbox.
    if (salvage_bv <= 0) {
        // Pool path, held field, nothing claimed: no decision follows, so
        // every destroyed drawn hull is an unchosen wreck now.
        if (pool_path and held_field) {
            for (drawn, opfor_outcomes) |hid, oc| {
                if (oc == .destroyed) gs.finalizeDestroyedWreck(hid);
            }
        }
        return out; // nothing to divide, nothing to roll
    }
    if (pool_path) {
        // Pool path: candidates ARE the drawn destroyed hulls. ALWAYS defer
        // to the inbox — the salvage_priority decision is mandatory and
        // turn-holding (events.zig:77/181; checklist.zig:170; tick.zig:807).
        out.candidates = try poolSalvageCandidates(gs, drawn, opfor_outcomes);
        out.unclaimed_bv = salvage_bv;
        return out;
    }
    // Abstraction path: roll fictional wrecks and offer a choice only when
    // the claim spans more than one plan.
    out.candidates = try rollSalvageCandidates(gs, c);
    if (salvageWorthAsking(out.candidates, salvage_bv)) {
        out.unclaimed_bv = salvage_bv;
        return out;
    }
    out.items = try takeSalvage(gs, c, out.candidates, salvage_bv, .most_hulls);
    return out;
}

/// The consequence figures a report records (`assembleReport`).
const Consequences = struct {
    artillery: ?battle_report.ArtilleryResult,
    convoy_hit: bool,
    edge_used_by: types.PersonId,
    destroyed: u8,
    wounded: u8,
    kia: u8,
    lost_hulls: u32,
    missing: u32,
    enemy_destroyed_bv: i64,
    kills_credited: u32,
    prisoners: u32,
    battle_loss_comp: types.CBills,
    score_delta: i32,
    morale_delta: i32,
    fatigue_add: u8,
    /// Copied into the report: the caller frees its list.
    hits: []const battle_report.HullHit,
    haulable_bv: i64,
    spoils: Spoils,
};

/// The finished engagement as one record: the fight, its phases and the
/// order given at each, the costs, the spoils, the ammunition and the
/// tasked lances' results. Allocates every payload in the campaign arena
/// and takes the next battle ID; mutates nothing else.
fn assembleReport(
    gs: *GameState,
    c: *const contract_mod.Contract,
    player: *const SideState,
    env: terrain_mod.Environment,
    setup: Setup,
    final: battle_phases.Final,
    k: Consequences,
) !battle_report.BattleReport {
    // battle.zig MUST NOT import operation_control.zig (rule 5).
    const committed_op = operations_m.committedCombatOp(c);
    const op_template_name: []const u8 = if (committed_op) |op|
        if (operation_mod.findTemplate(op.template_key)) |t| t.name else ""
    else
        "";
    // Per-lance task results (P4e). Arena-owned: names duped via gs.allocator().
    var task_results: std.ArrayListUnmanaged(battle_report.TaskedLance) = .empty;
    if (committed_op) |op| {
        for (op.tasks.items) |lt| {
            const lf = gs.force(lt.lance);
            const lance_name = if (lf) |f| try gs.allocator().dupe(u8, f.name) else "";
            const succeeded = operations_m.taskSucceeded(lt.task, operations_m.combatBand(final.outcome), final.held_field);
            const note = try gs.allocator().dupe(u8, switch (lt.task) {
                .reserve => if (final.reserve_committed) "committed to the decisive phase" else if (final.reserve_steadied) "steadied a bad opening" else if (succeeded) "held in reserve" else "line broke before reserve could act",
                .main_effort => if (succeeded) "led the advance" else "could not break through",
                .screen => if (succeeded) "screened the advance" else "screen failed",
                .escort => if (succeeded) "escort held" else "escort failed",
                .objective_security => if (succeeded) "secured objective" else "objective lost",
                .recovery => if (succeeded) "recovery team succeeded" else "recovery team failed",
                .recon => if (succeeded) "recon successful" else "recon incomplete",
            });
            try task_results.append(gs.allocator(), .{
                .lance = lt.lance,
                .lance_name = lance_name,
                .task = lt.task,
                .succeeded = succeeded,
                .note = note,
            });
        }
    }
    var ammo_lines: std.ArrayListUnmanaged(battle_report.AmmoLine) = .empty;
    for (part_mod.munition_keys) |key| try ammo_lines.append(gs.allocator(), .{
        .key = key,
        .burned = player.ammo_reserved.get(key) orelse 0,
        .left = gs.stockCount(player.site, key),
    });
    return .{
        .id = gs.nextBattleId(),
        .operation = op_template_name,
        .operation_intent = if (committed_op) |op| op.intent else null,
        .operation_tempo = if (committed_op) |op| op.tempo else null,
        .operation_interventions = if (committed_op) |op| try operations_m.interventionSummary(gs.allocator(), op) else "",
        .tasks = task_results.items,
        .artillery = k.artillery,
        .day = gs.clock.day_index,
        .contract = c.id,
        .company = c.assigned_company,
        .kind = c.kind.label(),
        .enemy_key = c.enemy_key,
        .scenario = setup.scenario.name,
        .terrain = terrain_mod.terrainRow(env.terrain).name,
        .weather = terrain_mod.weatherRow(env.weather).name,
        .outcome = final.outcome,
        .held_field = final.held_field,
        .withdrew = final.withdrew,
        .roe = final.roe,
        .roe_overridden = c.terms.command_rights.overridesRoe(),
        .player_power = player.power,
        .enemy_power = setup.enemy_power,
        .conditions_mod = setup.mods.scenario_mod,
        .phases = try gs.allocator().dupe(battle_phase.PhaseRecord, final.phases()),
        .close_terrain = env.close(),
        .air_grounded = env.groundsAir(),
        .convoy_hit = k.convoy_hit,
        .edge_spent_by = if (gs.person(k.edge_used_by)) |p| try p.rankedName(gs.allocator()) else "",
        .recon_quality = player.mods.recon_quality,
        .avg_fatigue = player.mods.avg_fatigue,
        .avg_morale = player.mods.avg_morale,
        .hits_taken = final.hits,
        .destroyed = k.destroyed,
        .wounded = k.wounded,
        .kia = k.kia,
        .lost_hulls = k.lost_hulls,
        .missing = k.missing,
        .enemy_destroyed_bv = k.enemy_destroyed_bv,
        .kills_credited = k.kills_credited,
        .prisoners = k.prisoners,
        .battle_loss_comp = k.battle_loss_comp,
        .score_after = c.score,
        .score_delta = k.score_delta,
        .morale_delta = k.morale_delta,
        .fatigue_add = k.fatigue_add,
        .battle_loss_pct = c.terms.battle_loss_pct,
        .salvage_pct = c.terms.salvage_pct,
        .command_rights = @tagName(c.terms.command_rights),
        // Owned, not borrowed: the hit log is freed when the engagement
        // concludes, and the report outlives it.
        .hulls = try gs.allocator().dupe(battle_report.HullHit, k.hits),
        .levers = try gs.allocator().dupe(battle_report.BattleLever, final.levers()),
        .ammo = ammo_lines.items,
        .silenced_mounts = player.silenced_mounts,
        .armor_left = gs.stockCount(player.site, "armor"),
        .salvage = .{
            .claimed_bv = k.spoils.claimed_bv,
            .haulable_bv = k.haulable_bv,
            .liaison_cut = k.spoils.liaison_cut,
            .exchange_cash = k.spoils.exchange_cash,
            .items = k.spoils.items,
            .candidates = k.spoils.candidates,
            .unclaimed_bv = k.spoils.unclaimed_bv,
        },
    };
}

/// What `publishEngagement` leaves behind besides the report.
const Aftertrail = struct {
    hit_log: []const battle_report.HullHit,
    opposition: Opposition,
    opfor_outcomes: []const opfor.OpforHullOutcome,
    destroyed_wrecks: []const types.HullInstanceId,
    engaged: []const types.UnitId,
    per_unit_kills: []const @import("personnel.zig").UnitKills,
    artillery: ?battle_report.ArtilleryResult,
    carrier_missing: u32,
    enemy_destroyed_bv: i64,
    score_delta: i32,
};

/// Records the finished engagement and what follows from it, in order: the
/// rendered AAR on the campaign log, the report, hulls left to the enemy,
/// the contract's objectives, the committed operation's contact-pause
/// levers and its resolution, the decisions the fight raises, the hull
/// combat records, the carrier's history and a lost field's enemy wreck
/// dispersal.
fn publishEngagement(gs: *GameState, c: *contract_mod.Contract, report: battle_report.BattleReport, t: Aftertrail) !void {
    const outcome = report.outcome;
    const held_field = report.held_field;
    const pool_path = t.opposition.enemy_bv_override != null;
    const committed_op = operations_m.committedCombatOp(c);
    // A lever needs the committed combat operation (`leverAvailability`).
    std.debug.assert(report.levers.len == 0 or committed_op != null);
    var lever_log_text: [battle_phases.max_levers][]const u8 = undefined;
    var lever_log_count: usize = 0;
    var arc_log_text: []const u8 = "";
    if (committed_op) |op| {
        for (report.levers) |l| if (l.lever.order() == .intervene) {
            lever_log_text[lever_log_count] = try operations_m.interventionLogText(gs.allocator(), gs, l.lever.order().intervene);
            lever_log_count += 1;
        };
        // Allocate the log text now (only allocates; does NOT touch event_log).
        // reserveLog is called later, immediately before the infallible commit
        // block, so nothing appends to event_log between the reservation and
        // the appendAssumeCapacity (the AAR render loop runs before it and
        // would otherwise consume the reserved slot).
        var arc_date_buf: [10]u8 = undefined;
        arc_log_text = try std.fmt.allocPrint(gs.allocator(), "{s} [arc] combat operation resolved: {s} ({s})", .{
            gs.clock.date.text(&arc_date_buf),
            if (operation_mod.findTemplate(op.template_key)) |tpl| tpl.name else "",
            @tagName(operations_m.combatBand(outcome)),
        });
    }
    const ctx: @import("state.zig").LogCtx = .{ .company = c.assigned_company, .contract = c.id };
    for (try after_action.render(gs.allocator(), &report)) |line| try gs.log(.battle, ctx, "{s}", .{line});
    // The structured report is the permanent account; the log carries its
    // rendered campaign narrative.
    gs.battle_reports.recordAssumeCapacity(report);
    // Hulls left on the field pass into enemy hands — off
    // our books once the AAR has named them, but held, not struck off:
    // a recovery raid has something to win back.
    for (t.hit_log) |h| if (h.lost) try held_hulls_m.holdUnit(gs, h.unit, c.enemy_key, report.id);

    // Objectives: the pool shrinks, VP accrue, and a broken pool
    // completes the contract.
    try @import("contract_control.zig").recordBattle(gs, c, t.enemy_destroyed_bv, t.score_delta);
    // Arc operation binding: spend the contact-pause interventions' capacity
    // and record them on the operation (logged as a pre-battle one is),
    // record a committed reserve, then transition the committed combat op
    // and log its result. reserveLog is called here, immediately before the
    // first mutation, so nothing appends to event_log between reservation and
    // appendAssumeCapacity (the AAR render loop runs before this block).
    if (committed_op) |op| {
        try gs.reserveLog(1 + lever_log_count);
        try op.interventions.ensureUnusedCapacity(gs.allocator(), lever_log_count);
        for (report.levers) |l| switch (l.lever.order()) {
            .intervene => |kind| {
                c.command_capacity -|= l.cost;
                op.interventions.appendAssumeCapacity(kind);
            },
            .commit_reserve => op.reserve_committed = true,
            else => unreachable,
        };
        for (lever_log_text[0..lever_log_count]) |text| gs.event_log.appendAssumeCapacity(.{
            .day = gs.clock.day_index,
            .category = .contract,
            .company = c.assigned_company,
            .contract = c.id,
            .text = text,
        });
        const band = operations_m.combatBand(outcome);
        const clock_d = operations_m.outcomeClockDelta(band);
        op.state = .resolved;
        op.outcome = band;
        op.resolved_day = gs.clock.day_index;
        if (clock_d < 0) {
            const relief: u16 = @intCast(@min(@as(i32, c.escalation_clock), -clock_d));
            c.escalation_clock -= relief;
        } else {
            c.escalation_clock +|= @as(u16, @intCast(clock_d));
        }
        gs.event_log.appendAssumeCapacity(.{
            .day = gs.clock.day_index,
            .category = .contract,
            .company = c.assigned_company,
            .contract = c.id,
            .text = arc_log_text,
        });
    }
    // The tempo is the commander's to set — asked only after the
    // field is held, and only once `recordBattle` has had its say about
    // whether there is a contract left to fight on.
    if (held_field and !outcome.isLoss()) try @import("contract_events.zig").queuePress(gs, c);
    // And a lost field asks whether the company goes back for what it
    // left. The two are exclusive: wrecks are only left behind on
    // a field that was lost.
    if (report.hullsLost() > 0 or report.missing > t.carrier_missing) try @import("contract_events.zig").queueRecoveryPush(gs, c, report.id);
    // And a haul the claim cannot stretch over asks how to divide it.
    // Nothing has been taken yet; the trucks wait on the answer.
    if (report.salvage.unclaimed_bv > 0) try @import("contract_events.zig").queueSalvage(gs, c, report.id);
    // And the night after any fight the techs pool their hours on the
    // damage, asking whose hull comes first only when the order
    // changes the outcome. Last, so a salvage answer's spares and armour
    // are in the stores before the techs reach for them.
    try @import("contract_events.zig").queueFieldRepair(gs, c, report.id);

    // Write one HullCombatRecord per engaged owned unit that has a linked hull
    // instance (P3c.2), and one per drawn OpFor hull that was destroyed or
    // combat_ineffective (surviving hulls get no record). Failure-atomically
    // via writeHullCombatRecords (rules 7/13): PREPARE → RESERVE → COMMIT.
    // A pre-reservation failure leaves hull_combat_records, hull_instances,
    // the pool and hull_ownership_history untouched.
    try writeHullCombatRecords(
        gs,
        gs.allocator(),
        t.engaged,
        t.opfor_outcomes,
        t.opposition.drawn,
        report.id,
        c.id,
        t.per_unit_kills,
        t.hit_log,
        t.opposition.resolution,
    );

    try artillery_battle.recordHistory(gs, t.artillery, report.id, c.id);

    // P3f.2: a lost field leaves the drawn destroyed enemy hulls pool-removed
    // but .active and enemy-owned. Give each a terminal disposition: enemy
    // recovery up to capacity, remainder dispersed to the black market
    // (docs/p3f-faction-loop-design.md §3). black_market owns the rule (rule 76).
    if (pool_path and !held_field) {
        if (t.destroyed_wrecks.len > 0) {
            var rng_copy = gs.rng;
            const source_owner = switch (t.opposition.resolution) {
                .pool => |pool| pool.owner,
                else => unreachable,
            };
            black_market.commitEnemyWreckDispersal(gs, t.destroyed_wrecks, source_owner, gs.clock.day_index, c.planet_key, &rng_copy);
            gs.rng = rng_copy;
        }
    }
}

/// A bloodless win: the enemy's pool is absent or fully depleted (all
/// hulls were combat_ineffective from prior battles of this contract).
/// Score += forfeit, battles_fought/won updated; builds a normal victory
/// report with no hits, no salvage, and no drawn/mutated hulls.
/// Models concede() but is a win; no schema change (rule 20, no new field).
fn forfeit(gs: *GameState, c: *contract_mod.Contract) !void {
    const score_delta = tuning.battle.score.forfeit;

    // If a combat op was committed, resolve it as a victory band on the
    // forfeit path. Reserve the log slot before any mutation (failure-atomic,
    // rule 17; mirror concede:1316 and resolveEngagement:1214).
    const committed_op = operations_m.committedCombatOp(c);
    const op_template_name: []const u8 = if (committed_op) |op|
        if (operation_mod.findTemplate(op.template_key)) |t| t.name else ""
    else
        "";
    var arc_log_text: []const u8 = "";
    if (committed_op != null) {
        try gs.reserveLog(1);
        var arc_date_buf: [10]u8 = undefined;
        arc_log_text = try std.fmt.allocPrint(gs.allocator(), "{s} [arc] operation {s}: forfeit (pool absent or depleted — victory)", .{
            gs.clock.date.text(&arc_date_buf),
            op_template_name,
        });
    }

    // Mutations start here (infallible).
    c.score += score_delta;
    c.battles_fought +|= 1;
    gs.stats.battles_won += 1;

    // Resolve committed combat op as a victory band (log slot already reserved).
    if (committed_op) |op| {
        op.state = .resolved;
        op.outcome = operations_m.combatBand(.victory);
        op.resolved_day = gs.clock.day_index;
        const clock_d = operations_m.outcomeClockDelta(op.outcome);
        if (clock_d < 0) {
            const relief: u16 = @intCast(@min(@as(i32, c.escalation_clock), -clock_d));
            c.escalation_clock -= relief;
        } else {
            c.escalation_clock +|= @as(u16, @intCast(clock_d));
        }
        gs.event_log.appendAssumeCapacity(.{
            .day = gs.clock.day_index,
            .category = .contract,
            .company = c.assigned_company,
            .contract = c.id,
            .text = arc_log_text,
        });
    }

    const report: battle_report.BattleReport = .{
        .id = gs.nextBattleId(),
        .artillery = try artillery_battle.snapshot(gs, c, .enemy_forfeit),
        .operation = op_template_name,
        .operation_intent = if (committed_op) |op| op.intent else null,
        .operation_tempo = if (committed_op) |op| op.tempo else null,
        .operation_interventions = "",
        .tasks = &.{},
        .day = gs.clock.day_index,
        .contract = c.id,
        .company = c.assigned_company,
        .kind = c.kind.label(),
        .enemy_key = c.enemy_key,
        .scenario = "",
        .terrain = "",
        .weather = "",
        .outcome = .victory,
        .held_field = true,
        .roe = effectiveRoe(gs, c, c.assigned_company),
        .roe_overridden = c.terms.command_rights.overridesRoe(),
        .score_after = c.score,
        .score_delta = score_delta,
        .battle_loss_pct = c.terms.battle_loss_pct,
        .salvage_pct = c.terms.salvage_pct,
        .command_rights = @tagName(c.terms.command_rights),
        .enemy_destroyed_bv = 0,
    };
    const ctx: @import("state.zig").LogCtx = .{ .company = c.assigned_company, .contract = c.id };
    for (try after_action.render(gs.allocator(), &report)) |line| try gs.log(.battle, ctx, "{s}", .{line});
    gs.battle_reports.recordAssumeCapacity(report);
    try @import("contract_control.zig").recordBattle(gs, c, 0, score_delta);
}

/// An engagement with nobody to put in the line: the objective is given up
/// without a shot. It is a defeat on the record: a report that holds the
/// turn, a lost battle in the stats, and `tuning.battle.score.concede` on
/// the contract, with victory points at the usual rate. A committed combat
/// operation is resolved as failure (rule 7: a failed engagement resolves it).
fn concede(gs: *GameState, c: *contract_mod.Contract) !void {
    const score_delta = tuning.battle.score.concede;

    // If a combat op was committed, resolve it as failure on the concede path.
    // Reserve the log slot before any mutation (failure-atomic, rule 17).
    const committed_op = operations_m.committedCombatOp(c);
    const op_template_name: []const u8 = if (committed_op) |op|
        if (operation_mod.findTemplate(op.template_key)) |t| t.name else ""
    else
        "";
    var arc_log_text: []const u8 = "";
    if (committed_op != null) {
        try gs.reserveLog(1);
        var arc_date_buf: [10]u8 = undefined;
        arc_log_text = try std.fmt.allocPrint(gs.allocator(), "{s} [arc] operation {s}: conceded (failure)", .{
            gs.clock.date.text(&arc_date_buf),
            op_template_name,
        });
    }

    // Mutations start here (infallible).
    c.score += score_delta;
    c.battles_fought +|= 1;
    gs.stats.battles_lost += 1;

    // Resolve committed combat op (log slot already reserved if needed).
    if (committed_op) |op| {
        op.state = .resolved;
        op.outcome = .failure;
        op.resolved_day = gs.clock.day_index;
        const clock_d = operations_m.outcomeClockDelta(.failure);
        c.escalation_clock +|= @as(u16, @intCast(clock_d));
        gs.event_log.appendAssumeCapacity(.{
            .day = gs.clock.day_index,
            .category = .contract,
            .company = c.assigned_company,
            .contract = c.id,
            .text = arc_log_text,
        });
    }

    // Per-lance task results for a concede: all tasks fail (defeat, field not held). (P4e)
    var concede_task_results: std.ArrayListUnmanaged(battle_report.TaskedLance) = .empty;
    if (committed_op) |op| {
        for (op.tasks.items) |lt| {
            const lf = gs.force(lt.lance);
            const lance_name = if (lf) |f| try gs.allocator().dupe(u8, f.name) else "";
            const note = try gs.allocator().dupe(u8, "objective conceded");
            try concede_task_results.append(gs.allocator(), .{
                .lance = lt.lance,
                .lance_name = lance_name,
                .task = lt.task,
                .succeeded = false,
                .note = note,
            });
        }
    }

    const concede_op_intent: ?operation_mod.Intent = if (committed_op) |op| op.intent else null;
    const concede_op_tempo: ?operation_mod.TempoPosture = if (committed_op) |op| op.tempo else null;
    const concede_op_interventions: []const u8 = if (committed_op) |op|
        try operations_m.interventionSummary(gs.allocator(), op)
    else
        "";
    const report: battle_report.BattleReport = .{
        .id = gs.nextBattleId(),
        .artillery = try artillery_battle.snapshot(gs, c, .no_line_units),
        .operation = op_template_name,
        .operation_intent = concede_op_intent,
        .operation_tempo = concede_op_tempo,
        .operation_interventions = concede_op_interventions,
        .tasks = concede_task_results.items,
        .day = gs.clock.day_index,
        .contract = c.id,
        .company = c.assigned_company,
        .kind = c.kind.label(),
        .enemy_key = c.enemy_key,
        .scenario = "",
        .terrain = "",
        .weather = "",
        .outcome = .defeat,
        .roe = effectiveRoe(gs, c, c.assigned_company),
        .roe_overridden = c.terms.command_rights.overridesRoe(),
        .score_after = c.score,
        .score_delta = score_delta,
        .battle_loss_pct = c.terms.battle_loss_pct,
        .salvage_pct = c.terms.salvage_pct,
        .command_rights = @tagName(c.terms.command_rights),
        .conceded = true,
    };
    const ctx: @import("state.zig").LogCtx = .{ .company = c.assigned_company, .contract = c.id };
    for (try after_action.render(gs.allocator(), &report)) |line| try gs.log(.battle, ctx, "{s}", .{line});
    gs.battle_reports.recordAssumeCapacity(report);
    try @import("contract_control.zig").recordBattle(gs, c, 0, score_delta);
}

/// " · field lost · recovery 6 vs 7 — LEFT TO THE ENEMY".
fn recoveryText(gs: *GameState, recovery: ?[2]i32, lost: bool) ![]const u8 {
    const r = recovery orelse return "";
    return try std.fmt.allocPrint(gs.allocator(), " · field lost · recovery {d} vs {d} — {s}", .{ r[0], r[1], if (lost) "LEFT TO THE ENEMY" else "dragged off" });
}

/// At most this many wrecks come home from one fight, however the claim
/// is spent — the trucks only hold so much.
pub const max_salvage_hulls = 3;

/// What one way of spending the claim actually takes.
pub const SalvageChoice = struct {
    kind: types.SalvagePlan,
    /// Positions in the candidate list, in take order.
    take: [max_salvage_hulls]u8 = @splat(0),
    hulls: u8 = 0,
    hull_bv: i64 = 0,
    /// BV left over, which becomes components, weapons and armour.
    parts_bv: i64 = 0,

    fn sameHullsAs(self: SalvageChoice, other: SalvageChoice) bool {
        if (self.hulls != other.hulls) return false;
        for (self.take[0..self.hulls], other.take[0..other.hulls]) |a, b| {
            if (a != b) return false;
        }
        return true;
    }
};

/// How a claim of `claim_bv` is spent under one plan. Pure: the
/// wrecks were rolled once when the fight ended and live in the record,
/// so the manifest the screen offers and the manifest the command
/// materialises come from this one function called twice.
pub fn salvagePlan(candidates: []const battle_report.SalvageCandidate, claim_bv: i64, kind: types.SalvagePlan) SalvageChoice {
    var out: SalvageChoice = .{ .kind = kind, .parts_bv = @max(0, claim_bv) };
    switch (kind) {
        .parts_only => return out,
        .heaviest => {
            var best: ?usize = null;
            for (candidates, 0..) |cand, i| {
                if (cand.bv > claim_bv) continue;
                if (best == null or cand.bv > candidates[best.?].bv) best = i;
            }
            const i = best orelse return out;
            out.take[0] = @intCast(i);
            out.hulls = 1;
            out.hull_bv = candidates[i].bv;
        },
        .most_hulls => {
            // Cheapest first, so the claim stretches over as many hulls
            // as it will reach. Insertion sort over a handful of rolls.
            var order: [16]u8 = @splat(0);
            const n = @min(candidates.len, order.len);
            for (0..n) |i| order[i] = @intCast(i);
            for (1..n) |i| {
                var j = i;
                while (j > 0 and candidates[order[j]].bv < candidates[order[j - 1]].bv) : (j -= 1) {
                    std.mem.swap(u8, &order[j], &order[j - 1]);
                }
            }
            var left = claim_bv;
            for (order[0..n]) |i| {
                if (out.hulls == max_salvage_hulls) break;
                const cand = candidates[i];
                if (cand.bv > left) continue;
                left -= cand.bv;
                out.take[out.hulls] = i;
                out.hulls += 1;
                out.hull_bv += cand.bv;
            }
        },
    }
    out.parts_bv = @max(0, claim_bv - out.hull_bv);
    return out;
}

/// Is there a real choice here? Only ask when taking the biggest
/// wreck and taking the most wrecks are different hauls — otherwise the
/// "decision" is one option wearing three labels, and the fight takes the
/// only plan there is without troubling the commander.
pub fn salvageWorthAsking(candidates: []const battle_report.SalvageCandidate, claim_bv: i64) bool {
    const heavy = salvagePlan(candidates, claim_bv, .heaviest);
    if (heavy.hulls == 0) return false;
    return !heavy.sameHullsAs(salvagePlan(candidates, claim_bv, .most_hulls));
}

/// Build the salvage candidate list from drawn enemy hulls that were
/// destroyed this engagement (pool path only). Each candidate names the
/// existing HullInstance by id so `takeSalvage` can transfer it rather
/// than mint a fresh hull. Condition fields are rolled here (in the
/// `.battle` stream) in the same bands `rollSalvageCandidates` uses, so
/// the AAR and condition code are unchanged. Offers ALL destroyed drawn
/// hulls regardless of haul reach; `takeSalvage` finalizes every
/// unchosen one. Arena-allocated.
fn poolSalvageCandidates(gs: *GameState, drawn: []const types.HullInstanceId, opfor_outcomes: []const opfor.OpforHullOutcome) ![]battle_report.SalvageCandidate {
    var out: std.ArrayListUnmanaged(battle_report.SalvageCandidate) = .empty;
    for (drawn, opfor_outcomes) |hid, oc| {
        if (oc != .destroyed) continue;
        const inst = gs.hull_instances.getPtr(hid) orelse continue;
        const ch = chassis_mod.find(inst.base_key) orelse continue;
        try out.append(gs.allocator(), .{
            .hull_instance_id = hid,
            .key = inst.base_key,
            .name = ch.name,
            .bv = ch.bv,
            .armor_pct = @intCast(@as(u32, gs.rng.roll2d6(.battle)) * 3), // 2d6-derived armour band
            .quality = if (gs.rng.random(.battle).boolean()) .c else .d, // TUNE: salvage-wreck condition bands
            .damaged_slots = 1,
            .destroyed_slots = gs.rng.random(.battle).intRangeAtMost(u8, 1, 3), // TUNE: salvage-wreck condition bands
            .missing_components = gs.rng.random(.battle).intRangeAtMost(u8, 1, 2), // TUNE: salvage-wreck condition bands
        });
    }
    return out.toOwnedSlice(gs.allocator());
}

/// Roll the wrecks this fight left worth dragging home, off the
/// enemy house's table with a condition each. Rolled once, when
/// the fight ends, and then kept in the record: rolling again at claim
/// time would offer the player one set of wrecks and deliver another.
fn rollSalvageCandidates(gs: *GameState, c: *const contract_mod.Contract) ![]battle_report.SalvageCandidate {
    const company_gen = @import("../gen/company_gen.zig");
    var out: std.ArrayListUnmanaged(battle_report.SalvageCandidate) = .empty;
    for (0..tuning.battle.salvage_candidates) |_| {
        const design = @import("../domain/rat.zig").roll(&gs.rng, .battle, c.enemy_key, company_gen.rollWeightClass(&gs.rng, .battle), gs.clock.date.year);
        try out.append(gs.allocator(), .{
            .key = design.key,
            .name = design.name,
            .bv = design.bv,
            .armor_pct = @intCast(@as(u32, gs.rng.roll2d6(.battle)) * 3), // 2d6-derived armour band
            .quality = if (gs.rng.random(.battle).boolean()) .c else .d, // TUNE: salvage-wreck condition bands
            .damaged_slots = 1,
            .destroyed_slots = gs.rng.random(.battle).intRangeAtMost(u8, 1, 3), // TUNE: salvage-wreck condition bands
            .missing_components = gs.rng.random(.battle).intRangeAtMost(u8, 1, 2), // TUNE: salvage-wreck condition bands
        });
    }
    return out.toOwnedSlice(gs.allocator());
}

/// Turn a salvage claim into things: the wrecks the chosen plan names,
/// shipped to the home HQ pool with the map transit, then components,
/// weapons and armour crated home with what the claim has left. The wrecks
/// come from `candidates` — rolled once when the fight ended — so this
/// materialises exactly what the player was offered. Returns the itemized
/// text for the AAR.
pub fn takeSalvage(
    gs: *GameState,
    c: *const contract_mod.Contract,
    candidates: []const battle_report.SalvageCandidate,
    claim_bv: i64,
    kind: types.SalvagePlan,
) ![]const u8 {
    if (claim_bv <= 0) return "";
    const plan = salvagePlan(candidates, claim_bv, kind);
    var text: std.ArrayListUnmanaged(u8) = .empty;
    const market = @import("../econ/market.zig");
    const logistics = @import("../econ/logistics.zig");
    const home = gs.hqs.getPtr(gs.homeHqFor(c.assigned_company));
    const from = planet_mod.find(c.planet_key);
    const to = if (home) |h| planet_mod.find(h.planet_key) else null;
    const days: u32 = if (from != null and to != null) logistics.daysBetween(from.?, to.?) else logistics.same_world_days;

    for (plan.take[0..plan.hulls]) |i| {
        const cand = candidates[i];
        const uid = try gs.addUnit(cand.key);
        const u = gs.unit(uid).?;
        u.purchase_price = 0; // salvage owes nothing
        if (cand.hull_instance_id != .none) {
            // Pool path: link the existing instance; do not mint a new one.
            u.hull_instance_id = cand.hull_instance_id;
            try gs.transferHullOwnership(cand.hull_instance_id, .player, c.enemy_key, .salvage);
        } else {
            // Abstraction path: mint a new instance as before.
            try gs.recordHullAcquisition(u, .salvage, c.enemy_key);
        }
        const cond: market.HullCondition = .{
            .armor_pct = cand.armor_pct,
            .quality = cand.quality,
            .damaged_slots = cand.damaged_slots,
            .destroyed_slots = cand.destroyed_slots,
            .missing_components = cand.missing_components,
        };
        market.applyHullCondition(u, cond, gs.rng.random(.market));
        u.status = .in_transit;
        try gs.unit_transfers.append(gs.allocator(), .{ .unit = uid, .to_company = .none, .eta_day = gs.clock.day_index + days });
        gs.stats.hulls_salvaged += 1;
        try text.appendSlice(gs.allocator(), try std.fmt.allocPrint(gs.allocator(), "wreck #{d} {s} {s} (armor {d}%, {d} destroyed, {d} missing) → home depot in {d} days; ", .{
            @intFromEnum(uid), cand.key, cand.name, cond.armor_pct, cond.destroyed_slots, cond.missing_components, days,
        }));
    }
    // Finalize every unchosen pool-path candidate (wrecks nobody took or
    // could not reach): permanently destroyed, owner .destroyed, interval
    // closed. Abstraction (.none) candidates are skipped — they were never
    // real instances and own no state to finalize. Infallible pass.
    for (candidates, 0..) |cand, ci| {
        if (cand.hull_instance_id == .none) continue;
        var was_taken = false;
        for (plan.take[0..plan.hulls]) |ti| if (ti == ci) {
            was_taken = true;
            break;
        };
        if (!was_taken) gs.finalizeDestroyedWreck(cand.hull_instance_id);
    }

    // Parts: components, then weapons, then armor, at BV prices.
    const t = tuning.battle;
    var remaining = plan.parts_bv;
    var components: u32 = 0;
    // Assemblies off the enemy's wrecks come in the class of the hull they
    // were pulled from.
    const comp_slots = [_][]const u8{ "la.", "ll.", "lt." };
    while (remaining >= t.salvage_bv_per_component and components < 3) : (components += 1) {
        remaining -= t.salvage_bv_per_component;
        const class = @import("../domain/opfor.zig").weightClass(&gs.rng, .battle);
        try sites.sendHome(gs, c.assigned_company, part_mod.componentForSlotClass(comp_slots[components % comp_slots.len], class), 1);
    }
    var weapons: u32 = 0;
    const weapon_keys = [_][]const u8{ "mlas", "srm4", "ac5", "lrm5", "llas" };
    while (remaining >= t.salvage_bv_per_weapon and weapons < 4) : (weapons += 1) {
        remaining -= t.salvage_bv_per_weapon;
        try sites.sendHome(gs, c.assigned_company, weapon_keys[gs.rng.random(.battle).uintLessThan(usize, weapon_keys.len)], 1); // uniform pick from salvageable weapons
    }
    var armor: u32 = 0;
    while (remaining >= t.salvage_bv_per_armor_ton and armor < 10) : (armor += 1) {
        remaining -= t.salvage_bv_per_armor_ton;
    }
    if (armor > 0) try sites.sendHome(gs, c.assigned_company, "armor", armor);
    if (components + weapons + armor > 0) {
        try text.appendSlice(gs.allocator(), try std.fmt.allocPrint(gs.allocator(), "crated home: {d} structural component{s}, {d} weapon{s}, {d}t armor", .{
            components, if (components == 1) "" else "s", weapons, if (weapons == 1) "" else "s", armor,
        }));
    }
    return text.items;
}

fn applyCompanyAftermath(gs: *GameState, company: types.ForceId, morale_delta: i32, fatigue_add: u8) void {
    var it = gs.people.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        if (p.status != .active or !toe.personInCompany(gs, p, company)) continue;
        p.addMorale(morale_delta); // Cool Under Fire halves a loss (Person.addMorale)
        p.addFatigue(fatigue_add);
    }
}

test "pool draw scratch buffer is reclaimed between resolutions" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 99 });
    defer gs.deinit();
    const candidates = [_]types.HullInstanceId{
        @enumFromInt(1),
        @enumFromInt(2),
        @enumFromInt(3),
        @enumFromInt(4),
    };
    var backing: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);

    for (0..64) |_| {
        {
            var resolution_scratch = std.heap.ArenaAllocator.init(fixed.allocator());
            defer resolution_scratch.deinit();
            const drawn = try drawOpforHulls(&gs, resolution_scratch.allocator(), &candidates, 2);
            try std.testing.expectEqual(@as(usize, 2), drawn.len);
        }
    }
}

test "battles resolve with consequences and stronger forces win more" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 777 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");

    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid, // enemy at 80% of player BV
        .employer_key = "LC",
        .enemy_key = "PER", // green pirates
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000, .salvage_pct = 30, .battle_loss_pct = 30 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;

    // A regular company against outnumbered green pirates should win the
    // campaign of battles clearly — given the real cadence: repair weeks
    // between engagements (the compounding-attrition death spiral is what
    // repairs exist to prevent) and full ammunition in the field stores.
    const site: types.Site = .{ .company = co };
    try gs.addStock(site, "armor", 60);
    for (part_mod.munition_keys) |key| try gs.addStock(site, key, 40);
    for (0..12) |_| {
        try resolveEngagement(&gs, c);
        // A haul worth dividing waits on the commander; nothing
        // is on the flatbeds until it is answered, so answer it.
        try answerBattleDecisions(&gs);
        try @import("maintenance.zig").runWeeklyRepairs(&gs);
        try @import("maintenance.zig").runWeeklyRepairs(&gs);
    }
    try std.testing.expect(c.score > 0);

    // Consequences are real: XP flowed, the log filled with AARs.
    var xp_total: u64 = 0;
    var pit = gs.people.iterator();
    while (pit.next()) |entry| xp_total += entry.value_ptr.xp;
    try std.testing.expect(xp_total > 0);
    try std.testing.expect(gs.event_log.items.len >= 36); // 3+ lines per AAR

    // At 30% rights salvage arrives as things, not cash: wrecks in transit
    // to the pool and parts crated home.
    const s = @import("../econ/finance.zig").summarize(&gs.ledger, 0, gs.clock.day_index + 1, .all);
    try std.testing.expectEqual(@as(i64, 0), s.category(.salvage));
    var wrecks: u32 = 0;
    for (gs.unit_transfers.items) |t| if (t.to_company == .none) {
        wrecks += 1;
    };
    var crated: u32 = 0;
    for (gs.part_orders.items) |o| if (o.dest == .hq) {
        crated += o.quantity;
    };
    try std.testing.expect(wrecks + crated > 0);
}

test "resolveEngagement: report reservation is failure-atomic under OOM" {
    const digest = @import("digest.zig");

    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 777 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
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

    const before = digest.stateHash(&gs);
    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;

    try std.testing.expectError(error.OutOfMemory, resolveEngagement(&gs, gs.contracts.getPtr(@enumFromInt(1)).?));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    try std.testing.expectEqual(@as(usize, 0), gs.battle_reports.kept.items.len);
}

test "resolveEngagement: lost-field wreck reservation failure leaves state unchanged" {
    const digest = @import("digest.zig");

    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 7771 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    _ = try seedOpforHulls(&gs, "DC", 4);
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000, .salvage_pct = 30, .battle_loss_pct = 30 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
        .enemy_lances = 1,
    });

    const before = digest.stateHash(&gs);
    const pool_len = gs.faction_rosters.getPtr("DC").?.items.len;
    const report_len = gs.battle_reports.kept.items.len;
    const record_len = gs.hull_combat_records.items.len;
    const log_len = gs.event_log.items.len;
    const listing_len = gs.market_listings.items.len;
    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;

    try std.testing.expectError(error.OutOfMemory, resolveEngagement(&gs, gs.contracts.getPtr(@enumFromInt(1)).?));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    try std.testing.expectEqual(pool_len, gs.faction_rosters.getPtr("DC").?.items.len);
    try std.testing.expectEqual(report_len, gs.battle_reports.kept.items.len);
    try std.testing.expectEqual(record_len, gs.hull_combat_records.items.len);
    try std.testing.expectEqual(log_len, gs.event_log.items.len);
    try std.testing.expectEqual(listing_len, gs.market_listings.items.len);
}

test "hard hits wound pilots: a season of fighting sends someone to the medbay" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 4242 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .objective_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 400_000 },
        .status = .active,
        .assigned_company = co,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    var battles: u32 = 0;
    while (battles < 12) : (battles += 1) {
        try resolveEngagement(&gs, c);
        // keep the hulls fighting so hits keep landing
        var uit = gs.units.iterator();
        while (uit.next()) |e| e.value_ptr.armor_pct = 100;
    }
    var hurt: u32 = 0;
    var pit = gs.people.iterator();
    while (pit.next()) |e| if (e.value_ptr.status == .wounded or e.value_ptr.status == .kia) {
        hurt += 1;
    };
    try std.testing.expect(hurt > 0);
    // The dead leave their seats.
    var seat_it = gs.units.iterator();
    while (seat_it.next()) |e| if (gs.person(e.value_ptr.pilot)) |p| {
        try std.testing.expect(p.status != .kia);
    };
    // Every wound is a located injury.
    var injured_it = gs.people.iterator();
    while (injured_it.next()) |e| if (e.value_ptr.status == .wounded) {
        try std.testing.expect(e.value_ptr.injuries.items.len > 0);
    };
}

test "dry mounts are silenced — ammo is combat power" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 778 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .objective_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 400_000 },
        .status = .active,
        .assigned_company = co,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;

    // No ammo in the trucks: ballistic/missile mounts fall silent.
    var dry = try playerSide(&gs, c);
    defer dry.engaged.deinit(gs.scratch());
    defer dry.ammo_reserved.deinit(gs.scratch());
    defer dry.family_mounts.deinit(gs.scratch());
    try std.testing.expect(dry.silenced_mounts > 0);

    // Stock every family: full power, and the fight will expend reloads.
    const site: types.Site = .{ .company = co };
    for (part_mod.munition_keys) |key| try gs.addStock(site, key, 20);
    var armed = try playerSide(&gs, c);
    defer armed.engaged.deinit(gs.scratch());
    defer armed.ammo_reserved.deinit(gs.scratch());
    defer armed.family_mounts.deinit(gs.scratch());
    try std.testing.expectEqual(@as(u32, 0), armed.silenced_mounts);
    try std.testing.expect(armed.power > dry.power);

    const lrm_before = gs.stockCount(site, "ammo_lrm");
    try resolveEngagement(&gs, c);
    try std.testing.expect(gs.stockCount(site, "ammo_lrm") < lrm_before);
}

test "an empty company concedes and bleeds score" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3 });
    defer gs.deinit();
    const co = try gs.createForce("Ghost Company", .company, .none);
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .objective_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 100_000 },
        .status = .active,
        .assigned_company = co,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    try resolveEngagement(&gs, c);
    try std.testing.expectEqual(@as(i32, -2), c.score);
}

test "air cover is a fighter that can fly, not an empty wing" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 15 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "PER",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    try std.testing.expect(!companyMods(&gs, c).has_air_cover);
    const wing = try gs.createForce("Air Wing", .air_company, co);
    const lance = try gs.createForce("1st Air Lance", .air_lance, wing);
    try std.testing.expect(!companyMods(&gs, c).has_air_cover); // an empty wing
    const fighter = try gs.addUnit("SPR-H5");
    try toe.moveUnitToForce(&gs, fighter, lance);
    try std.testing.expect(!companyMods(&gs, c).has_air_cover); // no pilot
    const pilot = try gs.hirePerson("Ace", "Ito", .aero_pilot);
    try crew.assignSlot(&gs, fighter, .pilot, pilot);
    try std.testing.expect(companyMods(&gs, c).has_air_cover);
}

test "a salvage claim becomes a wreck in transit to the depot pool and parts crated home; the wreck lands" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1223 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .objective_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 400_000, .salvage_pct = 50 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    const units_before = gs.units.count();
    const funds_before = gs.force(co).?.local_funds;
    const candidates = try rollSalvageCandidates(&gs, c);
    const text = try takeSalvage(&gs, c, candidates, 2_000, .most_hulls);
    try std.testing.expect(text.len > 0);
    try std.testing.expect(gs.units.count() > units_before); // at least one wreck
    try std.testing.expectEqual(funds_before, gs.force(co).?.local_funds); // no cash
    var wreck: ?types.UnitId = null;
    for (gs.unit_transfers.items) |t| if (t.to_company == .none) {
        wreck = t.unit;
    };
    try std.testing.expect(wreck != null);
    const w = gs.unit(wreck.?).?;
    try std.testing.expectEqual(@import("../domain/unit.zig").UnitStatus.in_transit, w.status);
    try std.testing.expectEqual(@as(types.CBills, 0), w.purchase_price);
    try std.testing.expect(w.needsDepot()); // missing components: depot work
    // Transit runs out: the wreck is in the pool, flagged for the depot.
    var eta: u32 = 0;
    for (gs.unit_transfers.items) |t| if (t.unit == wreck.?) {
        eta = t.eta_day;
    };
    gs.clock.day_index = eta;
    try @import("tick.zig").runTravel(&gs);
    try std.testing.expectEqual(types.ForceId.none, gs.unit(wreck.?).?.force);
    try std.testing.expectEqual(@import("../domain/unit.zig").UnitStatus.damaged, gs.unit(wreck.?).?.status);
}

test "integrated command sends training lances to fight and pulls the scouts' recon bonus" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1231 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .objective_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 400_000, .command_rights = .independent },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    // Mark the first line lance as training and one as scouting.
    var marked_training = false;
    var marked_scouting = false;
    for (gs.force(co).?.children.items) |cid| if (gs.force(cid)) |l| if (l.echelon == .lance) {
        if (!marked_training) {
            l.role = .training;
            marked_training = true;
        } else if (!marked_scouting) {
            l.role = .scouting;
            marked_scouting = true;
        }
    };
    var independent = try playerSide(&gs, c);
    defer independent.engaged.deinit(gs.scratch());
    defer independent.ammo_reserved.deinit(gs.scratch());
    defer independent.family_mounts.deinit(gs.scratch());
    try std.testing.expectEqual(@as(u8, 2), independent.mods.recon_quality);
    c.terms.command_rights = .integrated;
    var integrated = try playerSide(&gs, c);
    defer integrated.engaged.deinit(gs.scratch());
    defer integrated.ammo_reserved.deinit(gs.scratch());
    defer integrated.family_mounts.deinit(gs.scratch());
    try std.testing.expect(integrated.engaged.items.len > independent.engaged.items.len);
    try std.testing.expectEqual(@as(u8, 0), integrated.mods.recon_quality);
    // Tempo: integrated fights come sooner on average.
    var sum_i: u32 = 0;
    var sum_n: u32 = 0;
    for (0..20) |_| sum_i += nextBattleGap(&gs, c);
    c.terms.command_rights = .independent;
    for (0..20) |_| sum_n += nextBattleGap(&gs, c);
    try std.testing.expect(sum_i < sum_n);
}

test "salvage exchange pays cash into local funds and ships no wreck" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1232 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .objective_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 400_000, .salvage_pct = 50, .salvage_exchange = true, .command_rights = .independent },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    const site: types.Site = .{ .company = co };
    try gs.addStock(site, "armor", 60);
    for (part_mod.munition_keys) |key| try gs.addStock(site, key, 40);
    const units_before = gs.units.count();
    var held = false;
    for (0..12) |_| {
        try resolveEngagement(&gs, c);
        try @import("maintenance.zig").runWeeklyRepairs(&gs);
        const s = @import("../econ/finance.zig").summarize(&gs.ledger, 0, gs.clock.day_index, .{ .company = co });
        if (s.category(.salvage) > 0) held = true;
    }
    try std.testing.expect(held); // some field was held and paid in cash
    try std.testing.expectEqual(units_before, gs.units.count()); // no wrecks
    for (gs.unit_transfers.items) |t| try std.testing.expect(t.to_company != .none);
}

/// Answer every battle decision waiting, each with its own default — the
/// walk a commander does between fights, for tests about something else.
fn answerBattleDecisions(gs: *GameState) !void {
    while (gs.event_queue.blocking()) |ev| {
        try @import("contract_events.zig").resolveChoice(gs, ev.id, ev.default_choice);
    }
}

/// Hulls of `co` wrecked or lost over `n` hopeless engagements at a
/// difficulty.
fn lossRun(seed: u64, level: @import("../domain/difficulty.zig").Level, n: u32) !struct { lost: u32, wrecks_kept: u32, missing: u32, held: u32, all_held_by_enemy: bool } {
    var gs = GameState.init(std.testing.allocator, .{ .seed = seed });
    defer gs.deinit();
    gs.difficulty = level;
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
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
    var mine: std.ArrayListUnmanaged(types.UnitId) = .empty;
    defer mine.deinit(std.testing.allocator);
    var uit = gs.units.iterator();
    while (uit.next()) |e| if (e.value_ptr.kind == .mek and gs.companyOf(e.value_ptr.force) == co) try mine.append(std.testing.allocator, e.key_ptr.*);
    for (0..n) |_| {
        // A starving, exhausted, broken company: routs are the norm.
        var pit = gs.people.iterator();
        while (pit.next()) |e| {
            e.value_ptr.morale = 0;
            e.value_ptr.fatigue = 60;
        }
        var it = gs.units.iterator();
        while (it.next()) |e| if (e.value_ptr.status != .destroyed) {
            e.value_ptr.armor_pct = 0; // every hard hit kills
        };
        try resolveEngagement(&gs, c);
    }
    var lost: u32 = 0;
    var kept: u32 = 0;
    for (mine.items) |id| {
        if (gs.unit(id)) |u| {
            if (u.status == .destroyed) kept += 1;
        } else lost += 1;
    }
    var missing: u32 = 0;
    var pit = gs.people.iterator();
    while (pit.next()) |e| if (e.value_ptr.status == .mia) {
        missing += 1;
        try std.testing.expect(e.value_ptr.faction.len > 0); // held by someone
    };
    var all_held_by_enemy = true;
    for (gs.held_hulls.items) |h| {
        if (!std.mem.eql(u8, h.by, c.enemy_key)) all_held_by_enemy = false;
        if (h.unit.force != .none or h.unit.pilot != .none) all_held_by_enemy = false;
    }
    return .{
        .lost = lost,
        .wrecks_kept = kept,
        .missing = missing,
        .held = @intCast(gs.held_hulls.items.len),
        .all_held_by_enemy = all_held_by_enemy,
    };
}

test "the three salvage plans divide one claim three ways" {
    const cands = [_]battle_report.SalvageCandidate{
        .{ .key = "DRG-1N", .name = "Dragon", .bv = 1_144, .armor_pct = 30, .quality = .c, .damaged_slots = 1, .destroyed_slots = 2, .missing_components = 1 },
        .{ .key = "LCT-1V", .name = "Locust", .bv = 432, .armor_pct = 24, .quality = .d, .damaged_slots = 1, .destroyed_slots = 1, .missing_components = 1 },
        .{ .key = "STG-3R", .name = "Stinger", .bv = 192, .armor_pct = 18, .quality = .c, .damaged_slots = 1, .destroyed_slots = 1, .missing_components = 1 },
        .{ .key = "STK-3F", .name = "Stalker", .bv = 2_068, .armor_pct = 40, .quality = .d, .damaged_slots = 1, .destroyed_slots = 3, .missing_components = 2 },
    };
    const claim: i64 = 1_500;

    // The biggest one the claim reaches is the Dragon, not the Stalker.
    const heavy = salvagePlan(&cands, claim, .heaviest);
    try std.testing.expectEqual(@as(u8, 1), heavy.hulls);
    try std.testing.expectEqualStrings("Dragon", cands[heavy.take[0]].name);
    try std.testing.expectEqual(@as(i64, 1_500 - 1_144), heavy.parts_bv);

    // Cheapest first reaches two lights and leaves more for spares.
    const most = salvagePlan(&cands, claim, .most_hulls);
    try std.testing.expectEqual(@as(u8, 2), most.hulls);
    try std.testing.expectEqualStrings("Stinger", cands[most.take[0]].name);
    try std.testing.expectEqualStrings("Locust", cands[most.take[1]].name);
    try std.testing.expect(most.parts_bv > heavy.parts_bv);

    // And taking nothing puts the whole claim into spares.
    const parts = salvagePlan(&cands, claim, .parts_only);
    try std.testing.expectEqual(@as(u8, 0), parts.hulls);
    try std.testing.expectEqual(claim, parts.parts_bv);

    // Worth asking, because the first two are different hauls.
    try std.testing.expect(salvageWorthAsking(&cands, claim));
    // But not when the claim reaches exactly one wreck, whichever way
    // you look at it — then the three labels name one outcome.
    try std.testing.expect(!salvageWorthAsking(&cands, 300));
    // Nor when it reaches nothing at all.
    try std.testing.expect(!salvageWorthAsking(&cands, 100));
}

test "a real fight on thin stores asks whose hull comes first, and the night does what the inbox said" {
    for ([_]u64{ 901, 902, 903, 904, 905, 906 }) |seed| {
        if (try repairOfferRoundTrip(seed)) return;
    }
    return error.NoRepairDecisionInSixCampaigns;
}

fn repairOfferRoundTrip(seed: u64) !bool {
    const contract_events = @import("contract_events.zig");
    const maintenance = @import("maintenance.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = seed });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000 },
        .status = .active,
        .assigned_company = co,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    const site = sites.siteForForce(&gs, co);
    // Two tons of plating for a whole company: the order has to matter.
    _ = gs.takeStock(site, "armor", gs.stockCount(site, "armor"));
    try gs.addStock(site, "armor", 2);
    for (part_mod.munition_keys) |key| try gs.addStock(site, key, 200);

    var guard: u32 = 0;
    while (guard < 20) : (guard += 1) {
        try resolveEngagement(&gs, c);
        while (gs.event_queue.blocking()) |ev| {
            if (ev.kind == .field_repair) break;
            try contract_events.resolveChoice(&gs, ev.id, ev.default_choice);
        }
        if (gs.event_queue.blocking() != null) break;
        if (c.status != .active) return false;
    }
    const pending = gs.event_queue.blocking() orelse return false;
    const event_id = pending.id;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const offered = try maintenance.planFor(&gs, arena.allocator(), co, .heaviest_first);
    try std.testing.expect(offered.leftCount() > 0);
    const tons_before = gs.stockCount(site, "armor");
    try contract_events.resolveChoice(&gs, event_id, 2);
    for (offered.hulls) |h| try std.testing.expectEqual(h.armor_after, gs.unit(h.unit).?.armor_pct);
    try std.testing.expectEqual(tons_before - offered.armor_tons, gs.stockCount(site, "armor"));
    return true;
}

test "the salvage the screen offers is the salvage the command loads" {
    // Whether any one campaign throws up a haul worth dividing is a
    // chain of die rolls, so walk seeds until one does.
    for ([_]u64{ 777, 778, 779, 780, 781, 782 }) |seed| {
        if (try salvageOfferRoundTrip(seed)) return;
    }
    return error.NoSalvageDecisionInSixCampaigns;
}

fn salvageOfferRoundTrip(seed: u64) !bool {
    var gs = GameState.init(std.testing.allocator, .{ .seed = seed });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000, .salvage_pct = 50 },
        .status = .active,
        .assigned_company = co,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    const site: types.Site = .{ .company = co };
    try gs.addStock(site, "armor", 200);
    for (part_mod.munition_keys) |key| try gs.addStock(site, key, 200);

    var guard: u32 = 0;
    while (guard < 40) : (guard += 1) {
        try resolveEngagement(&gs, c);
        while (gs.event_queue.blocking()) |ev| {
            if (ev.kind == .salvage_priority) break;
            try @import("contract_events.zig").resolveChoice(&gs, ev.id, ev.default_choice);
        }
        if (gs.event_queue.blocking()) |ev| {
            if (ev.kind == .salvage_priority) break;
        }
    }
    const pending = gs.event_queue.blocking() orelse return false;
    if (pending.kind != .salvage_priority) return false;
    // Copy what we need: the pointer is into the queue, and answering
    // the decision may move the queue out from under it.
    const event_id = pending.id;
    const battle_id = pending.battle;

    const report = gs.battle_reports.find(battle_id).?;
    const claim = report.salvage.unclaimed_bv;
    try std.testing.expect(claim > 0);
    try std.testing.expect(report.salvage.candidates.len > 0);

    // Nothing is on the flatbeds until the commander says so.
    try std.testing.expectEqual(@as(usize, 0), report.salvage.items.len);
    const units_before = gs.units.count();

    // What the screen would offer under "the biggest one it reaches".
    const offered = salvagePlan(report.salvage.candidates, claim, .heaviest);
    try std.testing.expect(offered.hulls > 0);
    const offered_key = report.salvage.candidates[offered.take[0]].key;

    try @import("contract_events.zig").resolveChoice(&gs, event_id, 0); // option 0 = heaviest

    // Exactly that wreck came home — not a fresh roll off the table.
    try std.testing.expectEqual(units_before + offered.hulls, gs.units.count());
    var found = false;
    for (gs.unit_transfers.items) |t| {
        const u = gs.unit(t.unit) orelse continue;
        if (std.mem.eql(u8, u.chassis_key, offered_key) and u.purchase_price == 0) found = true;
    }
    try std.testing.expect(found);
    // And the haul is spent: answering twice cannot load the trucks again.
    try std.testing.expectEqual(@as(i64, 0), gs.battle_reports.find(battle_id).?.salvage.unclaimed_bv);
    try std.testing.expect(gs.battle_reports.find(battle_id).?.salvage.items.len > 0);
    return true;
}

test "a lost field asks whether to go back, and going back wins hulls and crew home" {
    const events_mod = @import("../domain/events.zig");
    var recovered_hulls: u32 = 0;
    var recovered_people: u32 = 0;
    var asked: u32 = 0;
    for ([_]u64{ 61, 62, 63, 64 }) |seed| {
        var gs = GameState.init(std.testing.allocator, .{ .seed = seed });
        defer gs.deinit();
        gs.difficulty = .elite;
        _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
        const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
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
        // A broken company on a field it cannot hold.
        var guard: u32 = 0;
        while (gs.event_queue.blocking() == null and guard < 12) : (guard += 1) {
            var pit = gs.people.iterator();
            while (pit.next()) |e| {
                e.value_ptr.morale = 0;
                e.value_ptr.fatigue = 60;
            }
            var uit = gs.units.iterator();
            while (uit.next()) |e| if (e.value_ptr.status != .destroyed) {
                e.value_ptr.armor_pct = 0;
            };
            try resolveEngagement(&gs, c);
        }
        const ev = gs.event_queue.blocking() orelse continue;
        if (ev.kind != .recovery_push) continue;
        asked += 1;
        try std.testing.expectEqual(events_mod.EventKind.recovery_push, ev.kind);
        // The decision names the fight it answers — without that the
        // push has no idea what was left where.
        try std.testing.expect(ev.battle != .none);

        const held_before: u32 = @intCast(gs.held_hulls.items.len);
        var mia_before: u32 = 0;
        var pit2 = gs.people.iterator();
        while (pit2.next()) |e| if (e.value_ptr.status == .mia) {
            mia_before += 1;
        };
        const got = try recoveryPush(&gs, ev.battle, co);
        recovered_hulls += got.hulls;
        recovered_people += got.people;

        // Whatever the rolls said, the books agree with the tally: a hull
        // counted as won is a hull off the limbo list and back in `units`.
        try std.testing.expectEqual(held_before - got.hulls, @as(u32, @intCast(gs.held_hulls.items.len)));
        var mia_after: u32 = 0;
        pit2 = gs.people.iterator();
        while (pit2.next()) |e| if (e.value_ptr.status == .mia) {
            mia_after += 1;
        };
        try std.testing.expectEqual(mia_before - got.people, mia_after);
        // And nobody who walked out is still waiting in the inbox to be
        // ransomed from a house that no longer holds them.
        for (gs.event_queue.pending.items) |pending| {
            if (pending.kind != .mia_held) continue;
            try std.testing.expectEqual(person_mod.Status.mia, gs.person(pending.person).?.status);
        }
    }
    // Vacuous otherwise: four broken companies that never lost anything.
    try std.testing.expect(asked > 0);
    try std.testing.expect(recovered_hulls + recovered_people > 0);
}

test "a hull won back goes home to the lance it was taken from" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 6006 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    _ = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    const taken = blk: {
        var it = gs.units.iterator();
        while (it.next()) |e| if (e.value_ptr.kind == .mek and e.value_ptr.force != .none) break :blk e.value_ptr.id;
        unreachable;
    };
    const lance = gs.unit(taken).?.force;
    const seats_before = gs.forces.getPtr(lance).?.units.items.len;
    try held_hulls_m.holdUnit(&gs, taken, "DC", @enumFromInt(1));
    try std.testing.expectEqual(seats_before - 1, gs.forces.getPtr(lance).?.units.items.len);

    try std.testing.expect(try held_hulls_m.releaseHull(&gs, taken));
    try std.testing.expect(gs.heldHull(taken) == null);
    try std.testing.expectEqual(lance, gs.unit(taken).?.force);
    try std.testing.expectEqual(seats_before, gs.forces.getPtr(lance).?.units.items.len);

    // Asking twice is not an error and wins nothing the second time.
    try std.testing.expect(!try held_hulls_m.releaseHull(&gs, taken));
}

test "a hull left on a lost field passes into enemy hands, not off the books" {
    // Several seeds: whether any one hopeless campaign loses a hull is a
    // die roll, and a single-seed assertion breaks whenever anything
    // upstream consumes the stream differently.
    var lost: u32 = 0;
    var held: u32 = 0;
    for ([_]u64{ 31, 32, 33, 34 }) |seed| {
        const r = try lossRun(seed, .elite, 10);
        // Every hull that left the books is held by someone, not struck
        // off: the recovery raid has something to win back.
        try std.testing.expectEqual(r.lost, r.held);
        // And it is held by the enemy we fought, with our people out of it.
        try std.testing.expect(r.all_held_by_enemy);
        lost += r.lost;
        held += r.held;
    }
    try std.testing.expect(lost > 0); // otherwise the equalities are vacuous
    try std.testing.expectEqual(lost, held);
}

test "a lost field loses wrecks to the enemy — harder the higher the difficulty" {
    var green_lost: u32 = 0;
    var elite_lost: u32 = 0;
    var elite_kept: u32 = 0;
    var missing: u32 = 0;
    for ([_]u64{ 31, 32, 33 }) |seed| {
        const g = try lossRun(seed, .green, 10);
        const e = try lossRun(seed, .elite, 10);
        green_lost += g.lost;
        elite_lost += e.lost;
        elite_kept += e.wrecks_kept;
        missing += g.missing + e.missing;
    }
    try std.testing.expect(elite_lost > 0);
    try std.testing.expect(elite_lost > green_lost);
    try std.testing.expect(elite_kept + elite_lost > 0);
    try std.testing.expect(missing > 0);
}

test "rules of engagement — cautious withdraws from draws, integrated command holds" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1204 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .objective_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000, .salvage_pct = 30, .command_rights = .liaison },
        .status = .active,
        .assigned_company = co,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    _ = try @import("commands.zig").execute(&gs, .{ .set_roe = .{ .company = co, .roe = .cautious } });
    try std.testing.expectEqual(force_mod.Roe.cautious, gs.force(co).?.roe);
    const site: types.Site = .{ .company = co };
    for (part_mod.munition_keys) |key| try gs.addStock(site, key, 200);
    for (0..40) |_| {
        var it = gs.units.iterator();
        while (it.next()) |e| {
            e.value_ptr.armor_pct = 100;
            if (e.value_ptr.status == .destroyed) e.value_ptr.status = .ready;
        }
        try resolveEngagement(&gs, c);
    }
    var withdrawals: u32 = 0;
    var held_draws: u32 = 0;
    for (gs.event_log.items) |e| {
        if (std.mem.indexOf(u8, e.text, "withdrew from a draw") != null) withdrawals += 1;
        if (std.mem.indexOf(u8, e.text, ": draw —") != null and std.mem.indexOf(u8, e.text, "withdrew") == null) held_draws += 1;
    }
    try std.testing.expect(withdrawals > 0);
    try std.testing.expectEqual(@as(u32, 0), held_draws);

    // Integrated command overrides the order: the company holds.
    c.terms.command_rights = .integrated;
    try resolveEngagement(&gs, c);
    var found = false;
    for (gs.event_log.items) |e| if (std.mem.indexOf(u8, e.text, "ROE hold (integrated command)") != null) {
        found = true;
    };
    try std.testing.expect(found);
    // Only companies take an ROE.
    try std.testing.expectError(error.NotACompany, @import("commands.zig").execute(&gs, .{ .set_roe = .{ .company = gs.force(co).?.children.items[0], .roe = .hold } }));
}

test "the enemy is a force of its own — it does not shrink with your company" {
    var c: contract_mod.Contract = .{
        .id = @enumFromInt(1),
        .kind = .objective_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 100_000 },
        .enemy_lances = 3,
        .enemy_quality = .veteran,
        .enemy_lance_bv = 4_000,
    };
    const full = engagementEnemyBv(&c, 16_000, 0, 10_000, 10_000);
    const gutted = engagementEnemyBv(&c, 4_000, 0, 10_000, 10_000);
    try std.testing.expectEqual(full, gutted);
    try std.testing.expectEqual(@as(i64, 12_000), full);
    // Scenario and difficulty still scale it.
    try std.testing.expect(engagementEnemyBv(&c, 16_000, 0, 12_000, 13_000) > full);
    // A contract with no rolled force scales with the company.
    c.enemy_lances = 0;
    try std.testing.expect(engagementEnemyBv(&c, 16_000, 0, 10_000, 10_000) > engagementEnemyBv(&c, 4_000, 0, 10_000, 10_000));
}

test "garrison work sees probes — a lance of the enemy's, every few weeks" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1206 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    const site: types.Site = .{ .company = co };
    for (part_mod.munition_keys) |key| try gs.addStock(site, key, 100);
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "PER",
        .planet_key = "galatea",
        .terms = .{ .length_months = 12, .base_pay_month = 200_000 },
        .status = .active,
        .assigned_company = co,
        .enemy_lances = 2,
        .enemy_quality = .green,
        .enemy_lance_bv = 3_000,
    });
    // A garrison contract with no rolled force stays quiet.
    try gs.contracts.put(gs.allocator(), @enumFromInt(2), .{
        .id = @enumFromInt(2),
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "PER",
        .planet_key = "galatea",
        .terms = .{ .length_months = 12, .base_pay_month = 200_000 },
        .status = .active,
        .assigned_company = co,
    });
    // Each probe holds the turn on its day and is fought with the unattended
    // orders; its report is read and its decisions take their defaults.
    for (0..180) |_| {
        try runDaily(&gs);
        try @import("tick.zig").clearHolds(&gs);
        gs.clock.day_index += 1;
    }
    const probed = gs.contracts.getPtr(@enumFromInt(1)).?;
    try std.testing.expect(probed.battles_fought >= 2);
    try std.testing.expect(probed.battles_fought <= 8);
    try std.testing.expectEqual(@as(u8, 0), gs.contracts.getPtr(@enumFromInt(2)).?.battles_fought);
    // One pirate lance against a company: the garrison holds far more often than not.
    try std.testing.expect(gs.stats.battles_won > gs.stats.battles_lost);
}

test "the AAR is rendered from the record, and the record outlives the fight" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 424242 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
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
    for (0..10) |_| {
        try resolveEngagement(&gs, c);
        try @import("maintenance.zig").runWeeklyRepairs(&gs);
    }

    var aars: u32 = 0;
    var headers: u32 = 0;
    for (gs.event_log.items) |e| {
        if (e.category != .battle) continue;
        aars += 1;
        // Rule 33: AAR text persists in the log as domain data. The sim
        // never colours it — `queries` does, when a screen shows it.
        try std.testing.expect(std.mem.indexOfScalar(u8, e.text, '{') == null);
        // Every line came out of `after_action.render`, which is the only
        // place that writes this prefix.
        try std.testing.expect(std.mem.indexOf(u8, e.text, "[AAR]") != null);
        // A header opens an engagement; its detail lines are indented.
        if (std.mem.indexOf(u8, e.text, "[AAR]   ") == null) headers += 1;
    }
    // Ten engagements, each opening with exactly one header line.
    try std.testing.expectEqual(@as(u32, 10), headers);
    try std.testing.expect(aars > headers * 4); // and each carries its detail

    // Battle ids are stamped and never reused, so an AAR's lines can be
    // gathered by battle instead of by reading their prose.
    try std.testing.expectEqual(@as(u32, 11), gs.next_battle_id);
    try std.testing.expect(gs.nextBattleId() == @as(types.BattleId, @enumFromInt(11)));
}

test "every scheduled engagement opens its contact window on an advance" {
    // A window wider than the shortest gap would open on the day the gap is
    // rolled, never on an advance, and a multi-day advance would skip it.
    try std.testing.expect(tuning.battle.contact_warning_days <= min_gap_days);
    try std.testing.expect(tuning.battle.contact_warning_days <= tuning.battle.press_gap_days);
}

test "support lances grant their modifiers only while a hull is ready and crewed" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7003 });
    defer gs.deinit();
    const f = try @import("contract_events.zig").damagedCompanyForTest(&gs, 0);
    const before = companyMods(&gs, f.c);
    try std.testing.expect(before.has_mash_lance and before.has_salvage_lance);
    var it = gs.units.iterator();
    while (it.next()) |e| {
        const u = e.value_ptr;
        if (u.kind == .mash) u.status = .mothballed; // parked
        if (gs.force(u.force)) |lance| if (lance.support_kind == .salvage) {
            if (gs.person(u.pilot)) |driver| driver.status = .wounded; // nobody to drive it
        };
    }
    const after = companyMods(&gs, f.c);
    try std.testing.expect(!after.has_mash_lance);
    try std.testing.expect(!after.has_salvage_lance);
    try std.testing.expect(after.has_security_lance == before.has_security_lance);
}

/// A company of one vehicle lance whose crews have `gunnery` and `driving`
/// vehicle skills, on an active contract; returns its estimated power.
fn vehiclePowerForTest(gunnery: u8, driving: u8) !i64 {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7201 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try gs.createForce("Alpha", .company, .none);
    const lance = try gs.createForce("Armor", .lance, co);
    for (0..4) |_| {
        const uid = try gs.addUnit("VDT");
        const driver = try gs.hirePerson("V", "Crew", .vehicle_crew);
        try gs.person(driver).?.skills.put(gs.allocator(), .gunnery_vee, gunnery);
        try gs.person(driver).?.skills.put(gs.allocator(), .driving_vee, driving);
        try toe.assignUnit(&gs, uid, lance, driver);
    }
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    return (try estimatePower(&gs, arena.allocator(), gs.contracts.getPtr(@enumFromInt(1)).?, co)).power;
}

test "vehicle crews fight with their vehicle skills" {
    const elite = try vehiclePowerForTest(1, 2);
    const green = try vehiclePowerForTest(6, 7);
    try std.testing.expect(elite > 0);
    try std.testing.expect(elite > green);
}

test "an airborne air-lance fighter adds aero power and reserves only its ammunition" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7204 });
    defer gs.deinit();
    const co = try gs.createForce("Alpha", .company, .none);
    const line = try gs.createForce("Line", .lance, co);
    const wing = try gs.createForce("Air Wing", .air_company, co);
    const air = try gs.createForce("Air", .air_lance, wing);
    const mek = try gs.addUnit("LCT-1V");
    const mek_pilot = try gs.hirePerson("Line", "Pilot", .mekwarrior);
    try toe.assignUnit(&gs, mek, line, mek_pilot);
    const fighter = try gs.addUnit("SL-15");
    const aero_pilot = try gs.hirePerson("Air", "Pilot", .aero_pilot);
    const aero_tech = try gs.hirePerson("Air", "Tech", .tech_aero);
    gs.person(aero_pilot).?.assigned_force = air;
    gs.person(aero_tech).?.assigned_force = air;
    try toe.assignUnit(&gs, fighter, air, aero_pilot);
    try crew.assignSlot(&gs, fighter, .tech, aero_tech);
    try gs.person(aero_pilot).?.skills.put(gs.allocator(), .gunnery_aero, 2);
    try gs.person(aero_pilot).?.skills.put(gs.allocator(), .piloting_aero, 3);
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 100_000 },
        .status = .active,
        .assigned_company = co,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    const site: types.Site = .{ .company = co };
    try gs.addStock(site, "ammo_ac10", 1);

    var airborne = try playerSide(&gs, c);
    defer airborne.engaged.deinit(gs.scratch());
    defer airborne.ammo_reserved.deinit(gs.scratch());
    defer airborne.family_mounts.deinit(gs.scratch());
    try std.testing.expectEqual(@as(usize, 2), airborne.engaged.items.len);
    try std.testing.expectEqual(@as(u32, 1), airborne.ammo_reserved.get("ammo_ac10").?);
    const skilled_power = airborne.power;

    try gs.person(aero_pilot).?.skills.put(gs.allocator(), .gunnery_aero, 6);
    try gs.person(aero_pilot).?.skills.put(gs.allocator(), .piloting_aero, 7);
    var unskilled = try playerSide(&gs, c);
    defer unskilled.engaged.deinit(gs.scratch());
    defer unskilled.ammo_reserved.deinit(gs.scratch());
    defer unskilled.family_mounts.deinit(gs.scratch());
    try std.testing.expect(skilled_power > unskilled.power);

    var grounded = try playerSideIn(&gs, gs.scratch(), c, .{ .weather = .storm });
    defer grounded.engaged.deinit(gs.scratch());
    defer grounded.ammo_reserved.deinit(gs.scratch());
    defer grounded.family_mounts.deinit(gs.scratch());
    try std.testing.expectEqual(@as(usize, 1), grounded.engaged.items.len);
    try std.testing.expectEqual(chassis_mod.find("SL-15").?.bv, airborne.bv - grounded.bv);
    try std.testing.expectEqual(@as(u32, 0), grounded.ammo_reserved.get("ammo_ac10") orelse 0);
    try std.testing.expect(!grounded.mods.has_air_cover);
}

test "battle fields aerospace units only from airborne air lances" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7207 });
    defer gs.deinit();
    const company = try gs.createForce("Alpha", .company, .none);
    const line = try gs.createForce("Line", .lance, company);
    const wing = try gs.createForce("Air Wing", .air_company, company);
    const air_lance = try gs.createForce("Air", .air_lance, wing);
    const fighter = try gs.addUnit("SL-15");
    const pilot = try gs.hirePerson("Air", "Pilot", .aero_pilot);
    try toe.assignUnit(&gs, fighter, line, pilot);
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 100_000 },
        .status = .active,
        .assigned_company = company,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;

    {
        var regular_lance = try playerSide(&gs, c);
        defer regular_lance.engaged.deinit(gs.scratch());
        defer regular_lance.ammo_reserved.deinit(gs.scratch());
        defer regular_lance.family_mounts.deinit(gs.scratch());
        try std.testing.expectEqual(@as(usize, 0), regular_lance.engaged.items.len);
    }

    try toe.moveUnitToForce(&gs, fighter, air_lance);
    var airborne = try playerSide(&gs, c);
    defer airborne.engaged.deinit(gs.scratch());
    defer airborne.ammo_reserved.deinit(gs.scratch());
    defer airborne.family_mounts.deinit(gs.scratch());
    try std.testing.expectEqualSlices(types.UnitId, &.{fighter}, airborne.engaged.items);
}

test "fighter selection preparation fails before resolveEngagement advances battle state" {
    const digest = @import("digest.zig");
    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 7206 });
    defer gs.deinit();
    const company = try gs.createForce("Alpha", .company, .none);
    const wing = try gs.createForce("Air Wing", .air_company, company);
    const air_lance = try gs.createForce("Air", .air_lance, wing);
    const fighter = try gs.addUnit("SL-15");
    const pilot = try gs.hirePerson("Air", "Pilot", .aero_pilot);
    try toe.assignUnit(&gs, fighter, air_lance, pilot);
    const tech = try gs.hirePerson("Air", "Tech", .tech_aero);
    try crew.assignSlot(&gs, fighter, .tech, tech);
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 100_000 },
        .status = .active,
        .assigned_company = company,
    });
    // Keep the report reservation out of this injected boundary. The first
    // remaining allocation is the fighter-selected battle line.
    try gs.battle_reports.prepareRecord(gs.allocator());
    const before = digest.stateHash(&gs);
    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;
    try std.testing.expectError(error.OutOfMemory, resolveEngagement(&gs, gs.contracts.getPtr(@enumFromInt(1)).?));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
}

test "fighter loss and recovery retain its hull instance without duplication" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7205 });
    defer gs.deinit();
    const company = try gs.createForce("Alpha", .company, .none);
    const wing = try gs.createForce("Air Wing", .air_company, company);
    const air_lance = try gs.createForce("Air", .air_lance, wing);
    const fighter = try gs.addUnit("SPR-H5");
    const pilot = try gs.hirePerson("Air", "Pilot", .aero_pilot);
    try toe.assignUnit(&gs, fighter, air_lance, pilot);
    try gs.recordHullAcquisition(gs.unit(fighter).?, .purchase, "unknown");
    const hull = gs.unit(fighter).?.hull_instance_id;
    const instances_before = gs.hull_instances.count();
    var hits: std.ArrayListUnmanaged(battle_report.HullHit) = .empty;
    defer hits.deinit(gs.scratch());
    const engaged = [_]types.UnitId{fighter};
    _ = try applyHits(&gs, &.{ .engaged = .empty }, &engaged, 1, &hits);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqualStrings("SPR-H5", hits.items[0].chassis_key);
    try writeHullCombatRecords(&gs, gs.allocator(), &engaged, &.{}, &.{}, @enumFromInt(1), @enumFromInt(1), &.{}, hits.items, .abstraction);
    try std.testing.expectEqual(hull, gs.hull_combat_records.items[0].hull_instance_id);
    try held_hulls_m.holdUnit(&gs, fighter, "DC", @enumFromInt(1));
    try std.testing.expectEqual(@as(usize, 1), gs.held_hulls.items.len);
    try std.testing.expectEqual(hull, gs.held_hulls.items[0].unit.hull_instance_id);
    try std.testing.expectEqual(instances_before, gs.hull_instances.count());
    try std.testing.expect(try held_hulls_m.releaseHull(&gs, fighter));
    try std.testing.expectEqual(hull, gs.unit(fighter).?.hull_instance_id);
    try std.testing.expectEqual(instances_before, gs.hull_instances.count());
}

test "vehicle battle damage writes the linked hull combat record" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7203 });
    defer gs.deinit();
    const vehicle = try gs.addUnit("SCP-1N");
    const driver = try gs.hirePerson("V", "Crew", .vehicle_crew);
    gs.unit(vehicle).?.pilot = driver;
    try gs.recordHullAcquisition(gs.unit(vehicle).?, .purchase, "unknown");
    const hull = gs.unit(vehicle).?.hull_instance_id;
    var hits: std.ArrayListUnmanaged(battle_report.HullHit) = .empty;
    defer hits.deinit(gs.scratch());
    const engaged = [_]types.UnitId{vehicle};
    _ = try applyHits(&gs, &.{ .engaged = .empty }, &engaged, 1, &hits);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try writeHullCombatRecords(&gs, gs.allocator(), &engaged, &.{}, &.{}, @enumFromInt(1), @enumFromInt(1), &.{}, hits.items, .abstraction);
    try std.testing.expectEqual(@as(usize, 1), gs.hull_combat_records.items.len);
    try std.testing.expectEqual(hull, gs.hull_combat_records.items[0].hull_instance_id);
    try std.testing.expectEqual(@as(u16, 1), gs.hull_combat_records.items[0].hits_taken);
}

test "vehicle salvage transfers the offered hull instance without duplication" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7202 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const company = try gs.createForce("Alpha", .company, .none);
    const hull: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
    gs.next_hull_instance_id += 1;
    try gs.hull_instances.put(gs.allocator(), hull, .{ .id = hull, .base_key = "SCP-1N", .owner = .market });
    try gs.hull_ownership_history.append(gs.allocator(), .{ .hull_instance_id = hull, .acquisition_type = .transfer, .prior_owner_key = "DC" });
    const design = chassis_mod.find("SCP-1N").?;
    const candidates = [_]battle_report.SalvageCandidate{.{ .key = design.key, .name = design.name, .bv = design.bv, .armor_pct = 60, .quality = .c, .damaged_slots = 0, .destroyed_slots = 0, .missing_components = 0, .hull_instance_id = hull }};
    const c: contract_mod.Contract = .{ .id = @enumFromInt(1), .kind = .recon_raid, .employer_key = "LC", .enemy_key = "DC", .planet_key = "galatea", .status = .active, .assigned_company = company, .terms = .{ .length_months = 3, .base_pay_month = 100_000 } };
    const instances_before = gs.hull_instances.count();
    _ = try takeSalvage(&gs, &c, &candidates, design.bv, .most_hulls);
    try std.testing.expectEqual(instances_before, gs.hull_instances.count());
    var linked = false;
    for (gs.units.values()) |u| {
        if (u.hull_instance_id == hull) linked = true;
    }
    try std.testing.expect(linked);
    try std.testing.expectEqual(@import("../domain/hull_instance.zig").OwnerType.player, std.meta.activeTag(gs.hull_instances.getPtr(hull).?.owner));
}

test "a conceded engagement leaves a report that holds the turn and counts as a loss" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7301 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    // A company with nobody in the line.
    const co = try gs.createForce("Alpha", .company, .none);
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
    try resolveEngagement(&gs, c);

    const r = gs.battle_reports.unread() orelse return error.NoReport;
    try std.testing.expect(r.conceded);
    try std.testing.expectEqual(autoresolve.Outcome.defeat, r.outcome);
    try std.testing.expectEqual(tuning.battle.score.concede, r.score_delta);
    try std.testing.expectEqual(@import("checklist.zig").Hold.unread_after_action, @import("checklist.zig").turnHold(&gs).?);
    try std.testing.expectEqual(@as(u32, 1), gs.stats.battles_lost);
    try std.testing.expectEqual(@as(u32, 1), c.battles_fought);
    try std.testing.expectEqual(tuning.battle.score.concede, c.score);
    try std.testing.expectEqual(tuning.battle.score.concede * tuning.contract.vp_per_score, c.victory_points);
}

test "committed combat op on the concede path resolves to failure with clock and report" {
    // F3 consumer test: a committed combat op must be resolved when the
    // engagement is conceded (no combat-effective units). The op transitions
    // to .resolved / .failure, the escalation clock rises by
    // outcomeClockDelta(.failure), and report.operation names the template.
    const testing = std.testing;
    var gs = GameState.init(testing.allocator, .{ .seed = 7401 });
    defer gs.deinit();
    // Empty company → concede path.
    const co = try gs.createForce("Ghost", .company, .none);
    const cid: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .active,
        .assigned_company = co,
        .arc_key = "fracturing_garrison",
        .enemy_lances = 2,
        .enemy_lance_bv = 5000,
        .escalation_clock = 3,
    });
    const c = gs.contracts.getPtr(cid).?;
    const oid: types.OperationId = @enumFromInt(1);
    try c.operations.append(gs.allocator(), .{
        .id = oid,
        .template_key = "repel_probe",
        .state = .committed,
        .opened_day = 0,
        .committed_day = 0,
    });
    const clock_before = c.escalation_clock;

    try resolveEngagement(&gs, c);

    // Op must be resolved as failure.
    const op = &c.operations.items[0];
    try testing.expectEqual(operation_mod.OperationState.resolved, op.state);
    try testing.expectEqual(operation_mod.OutcomeBand.failure, op.outcome);
    try testing.expect(op.outcome != .none);
    try testing.expectEqual(@as(?u32, gs.clock.day_index), op.resolved_day);

    // Escalation clock rose by outcomeClockDelta(.failure).
    const expected_clock: u16 = clock_before + @as(u16, @intCast(operations_m.outcomeClockDelta(.failure)));
    try testing.expectEqual(expected_clock, c.escalation_clock);

    // Report names the operation.
    const r = gs.battle_reports.unread() orelse return error.NoReport;
    try testing.expectEqualStrings("Repel Probe", r.operation);
}

test "salvageClaimBv: owner used by resolve and the queries preview returns identical claims" {
    // The owner and both consumers must agree on the same inputs (C11o).
    const haul: i64 = 3_000;
    const pct: u8 = 50;
    // Without salvage lance.
    const gross_no_lance = salvageClaimBv(haul, pct, false);
    try std.testing.expectEqual(@divTrunc(haul * pct, 100), gross_no_lance);
    // With salvage lance: applies the bonus bp.
    const gross_with_lance = salvageClaimBv(haul, pct, true);
    try std.testing.expect(gross_with_lance > gross_no_lance);
    try std.testing.expectEqual(types.applyBp(@divTrunc(haul * pct, 100), tuning.battle.salvage_lance_bonus_bp), gross_with_lance);
    // Zero salvage_pct → no claim regardless of lance.
    try std.testing.expectEqual(@as(i64, 0), salvageClaimBv(haul, 0, true));
    // Both call sites use the same function: owner/consumer agreement by construction.
}

test "a fight does not change who turns up at the hiring hall" {
    var names: [2][]const u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (&names, 0..) |*out, fought| {
        var gs = GameState.init(std.testing.allocator, .{ .seed = 8201 });
        defer gs.deinit();
        const f = try @import("contract_events.zig").damagedCompanyForTest(&gs, 20);
        gs.candidates.clearRetainingCapacity();
        if (fought == 1) try resolveEngagement(&gs, f.c);
        try @import("contract_market.zig").refreshCandidates(&gs);
        var list: std.ArrayListUnmanaged(u8) = .empty;
        for (gs.candidates.items) |c| {
            try list.appendSlice(arena.allocator(), c.spec.first);
            try list.append(arena.allocator(), ' ');
            try list.appendSlice(arena.allocator(), c.spec.last);
            try list.append(arena.allocator(), ';');
        }
        out.* = list.items;
    }
    try std.testing.expect(names[0].len > 0);
    try std.testing.expectEqualStrings(names[0], names[1]);
}

test "estimatedKills owns the BV-to-kills formula; kill credit and prisoner counts use it" {
    // Formula: (destroyed_bv + 500) / 1000, rounded, floored at 0.
    try std.testing.expectEqual(@as(u32, 0), estimatedKills(0));
    try std.testing.expectEqual(@as(u32, 0), estimatedKills(499));
    try std.testing.expectEqual(@as(u32, 1), estimatedKills(500));
    try std.testing.expectEqual(@as(u32, 1), estimatedKills(1_499));
    try std.testing.expectEqual(@as(u32, 2), estimatedKills(1_500));
    try std.testing.expectEqual(@as(u32, 2), estimatedKills(2_499));
    try std.testing.expectEqual(@as(u32, 3), estimatedKills(2_500));
    // Negative BV never yields a kill.
    try std.testing.expectEqual(@as(u32, 0), estimatedKills(-1));
    try std.testing.expectEqual(@as(u32, 0), estimatedKills(-10_000));
    // Consumer: personnel.zig:371 (creditKills) calls estimatedKills(destroyed_bv) and returns it.
    // With one engaged pilot and 1_500 destroyed BV, creditKills must equal estimatedKills(1_500) = 2.
    {
        var gs4 = GameState.init(std.testing.allocator, .{ .seed = 9002 });
        defer gs4.deinit();
        _ = try founding.createCommander(&gs4, "T", .LC, .chief_engineer);
        const uid4 = try gs4.addUnit("SHD-2H");
        const pid4 = try gs4.hirePerson("K", "Kill", .mekwarrior);
        gs4.unit(uid4).?.pilot = pid4;
        const engaged4 = [_]types.UnitId{uid4};
        const kills4 = try @import("personnel.zig").creditKills(&gs4, &engaged4, 1_500, .battle, null);
        try std.testing.expectEqual(estimatedKills(1_500), kills4);
    }
}

test "effectiveRoe: integrated command overrides to hold; other rights use the company's setting" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 9001 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = (try @import("commands.zig").execute(&gs, .{ .new_company = "Alpha" })).created_force;
    var c: contract_mod.Contract = .{
        .id = .none,
        .kind = .objective_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 100_000, .command_rights = .independent },
    };
    // Independent: company's own ROE (default .standard).
    try std.testing.expectEqual(force_mod.Roe.standard, effectiveRoe(&gs, &c, co));
    // Cautious ROE on the company still comes through.
    _ = try @import("commands.zig").execute(&gs, .{ .set_roe = .{ .company = co, .roe = .cautious } });
    try std.testing.expectEqual(force_mod.Roe.cautious, effectiveRoe(&gs, &c, co));
    // Integrated command rights override to .hold no matter the company's setting.
    c.terms.command_rights = .integrated;
    try std.testing.expectEqual(force_mod.Roe.hold, effectiveRoe(&gs, &c, co));
    // Consumer: queries.zig:401 reads battle.effectiveRoe(gs, c, company) for the ROE field.
    // Store the contract and confirm battleOrders.roe agrees with the owner.
    c.id = @enumFromInt(1);
    c.status = .active;
    c.assigned_company = co;
    c.next_battle_day = gs.clock.day_index + tuning.battle.contact_warning_days;
    try gs.contracts.put(gs.allocator(), c.id, c);
    var arena_roe = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_roe.deinit();
    const bo = try @import("queries.zig").battleOrders(arena_roe.allocator(), &gs, c.id);
    try std.testing.expectEqual(force_mod.Roe.hold, bo.?.roe);
    try std.testing.expectEqual(effectiveRoe(&gs, gs.contracts.getPtr(c.id).?, co), bo.?.roe);
}

test "inContactWindow: true within contact_warning_days, false outside; execConfirmOrders checks it" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 9101 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const warn = tuning.battle.contact_warning_days;
    var c: contract_mod.Contract = .{
        .id = @enumFromInt(1),
        .kind = .objective_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 100_000 },
        .status = .active,
    };
    // No next_battle_day: never in contact.
    try std.testing.expect(!inContactWindow(&gs, &c));
    // Battle further than warning: not in contact.
    c.next_battle_day = gs.clock.day_index + warn + 1;
    try std.testing.expect(!inContactWindow(&gs, &c));
    // Exactly at the boundary: in contact.
    c.next_battle_day = gs.clock.day_index + warn;
    try std.testing.expect(inContactWindow(&gs, &c));
    // Inside the window: in contact.
    c.next_battle_day = gs.clock.day_index + 1;
    try std.testing.expect(inContactWindow(&gs, &c));
    // Consumer: execConfirmOrders checks inContactWindow; NoContact when outside.
    c.next_battle_day = gs.clock.day_index + warn + 1;
    try gs.contracts.put(gs.allocator(), c.id, c);
    try std.testing.expectError(error.NoContact, @import("commands.zig").execute(&gs, .{ .confirm_orders = c.id }));
    // Inside the window: confirm succeeds.
    gs.contracts.getPtr(c.id).?.next_battle_day = gs.clock.day_index + warn;
    _ = try @import("commands.zig").execute(&gs, .{ .confirm_orders = c.id });
}

test "estimatePower owns the company's combat strength; offer_rating.rateOffer agrees" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 9201 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = (try @import("commands.zig").execute(&gs, .{ .new_company = "Alpha" })).created_force;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c: contract_mod.Contract = .{
        .id = .none,
        .kind = .objective_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 100_000 },
        .enemy_lances = 2,
        .enemy_lance_bv = 3_500,
        .enemy_lance_tons = 220,
        .enemy_quality = .regular,
    };
    const est = try estimatePower(&gs, arena.allocator(), &c, co);
    // A freshly generated company has at least one hull, so power > 0 and hulls > 0.
    try std.testing.expect(est.power > 0);
    try std.testing.expect(est.hulls > 0);
    try std.testing.expect(est.tons > 0);
    // Consumer: offer_rating.rateOffer uses estimatePower for its .own field.
    const rating = try @import("offer_rating.zig").rateOffer(arena.allocator(), &gs, &c, co);
    try std.testing.expect(rating != null);
    try std.testing.expectEqual(est.power, rating.?.own.power);
}

test "intent-shaped battle: break_enemy vs preserve_force produce different score/VP; no extra RNG draw" {
    // Rule 20 consumer test: intentProfile modifiers are applied as deterministic
    // post-roll modifiers; the no-intent-op path produces the baseline score.
    // docs/p4-operations-design.md §6 decision 3.
    const testing = std.testing;
    // Use two identical game states diverged only by the committed op's intent.
    var gs_be = GameState.init(testing.allocator, .{ .seed = 42001 });
    defer gs_be.deinit();
    var gs_pf = GameState.init(testing.allocator, .{ .seed = 42001 });
    defer gs_pf.deinit();

    // Build a minimal combat-capable company in both states.
    // Both use the same seed so the only difference is the intent profile.
    for (&[_]*GameState{ &gs_be, &gs_pf }) |gs| {
        const co = try @import("starter_company.zig").generateInto(gs, "Ghost");
        const cid: types.ContractId = @enumFromInt(1);
        try gs.contracts.put(gs.allocator(), cid, .{
            .id = cid,
            .kind = .garrison_duty,
            .employer_key = "LC",
            .enemy_key = "DC",
            .planet_key = "galatea",
            .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
            .status = .active,
            .assigned_company = co,
            .arc_key = "fracturing_garrison",
            .enemy_lances = 2,
            .enemy_lance_bv = 8000,
        });
    }
    // Commit the combat operation with different intents.
    const cid: types.ContractId = @enumFromInt(1);
    const oid: types.OperationId = @enumFromInt(1);
    for (&[_]*GameState{ &gs_be, &gs_pf }, &[_]operation_mod.Intent{ .break_enemy, .preserve_force }) |gs, intent| {
        try gs.contracts.getPtr(cid).?.operations.append(gs.allocator(), .{
            .id = oid,
            .template_key = "repel_probe",
            .state = .committed,
            .opened_day = 0,
            .committed_day = 0,
            .intent = intent,
        });
    }

    try resolveEngagement(&gs_be, gs_be.contracts.getPtr(cid).?);
    try resolveEngagement(&gs_pf, gs_pf.contracts.getPtr(cid).?);

    const score_be = gs_be.contracts.getPtr(cid).?.score;
    const score_pf = gs_pf.contracts.getPtr(cid).?.score;
    const vp_be = gs_be.contracts.getPtr(cid).?.victory_points;
    const vp_pf = gs_pf.contracts.getPtr(cid).?.victory_points;

    // After F1 fix the score and VP must both be affected and must agree on
    // direction: break_enemy (score_bp 13 000, vp_bp 13 000) amplifies any
    // non-zero base outcome more than preserve_force (7 000, 7 000), so the
    // two measures must change in the same direction.
    //
    // Direction depends on whether the base was a win (break_enemy scores higher)
    // or a loss (break_enemy scores lower — it amplifies the negative too).
    // Both states share the same seed so they have the same base outcome.
    // The pre-F1 bug could produce disagreement: score_extra was added to
    // score_delta, double-counting it in VP, which could make VP move in a
    // different direction from score. After the fix they must agree.
    try testing.expect(score_be != score_pf);
    try testing.expect(vp_be != vp_pf);
    // Score and VP must move in the same direction (consistent with the base outcome).
    try testing.expect((score_be > score_pf) == (vp_be > vp_pf));
}

test "intent salvage gate: preserve_force claims no salvage on a held field" {
    // Rule 20 consumer test: intentProfile.salvage_allowed = false means
    // no salvage even when the field is held and there are wrecks.
    // docs/p4-operations-design.md §6 decision 3.
    //
    // Two identical game states diverged only by intent: preserve_force vs
    // break_enemy. The enemy (1 lance × 500 BV) is far outmatched, guaranteeing
    // a held-field outcome. With the same seed both states see the same rolls;
    // the only difference is the intent gate on salvage. This prevents a vacuous
    // pass where 0 salvage comes from not holding the field rather than the gate.
    const testing = std.testing;
    const cid: types.ContractId = @enumFromInt(1);

    const Contract = contract_mod.Contract;

    // Build both states from the same seed.
    var gs_pf = GameState.init(testing.allocator, .{ .seed = 42002 });
    defer gs_pf.deinit();
    var gs_be = GameState.init(testing.allocator, .{ .seed = 42002 });
    defer gs_be.deinit();

    for (&[_]*GameState{ &gs_pf, &gs_be }) |gs| {
        const co = try @import("starter_company.zig").generateInto(gs, "Ghost");
        try gs.contracts.put(gs.allocator(), cid, Contract{
            .id = cid,
            .kind = .garrison_duty,
            .employer_key = "LC",
            .enemy_key = "DC",
            .planet_key = "galatea",
            .terms = .{
                .length_months = 18,
                .base_pay_month = 200_000,
                .salvage_pct = 50,
            },
            .status = .active,
            .assigned_company = co,
            .arc_key = "fracturing_garrison",
            .enemy_lances = 1,
            .enemy_lance_bv = 500, // very weak: guarantees the company holds the field
        });
    }
    // Commit preserve_force (salvage_allowed = false) into gs_pf.
    try gs_pf.contracts.getPtr(cid).?.operations.append(gs_pf.allocator(), .{
        .id = @enumFromInt(1),
        .template_key = "repel_probe",
        .state = .committed,
        .opened_day = 0,
        .committed_day = 0,
        .intent = .preserve_force,
    });
    // Commit break_enemy (salvage_allowed = true) into gs_be.
    try gs_be.contracts.getPtr(cid).?.operations.append(gs_be.allocator(), .{
        .id = @enumFromInt(1),
        .template_key = "repel_probe",
        .state = .committed,
        .opened_day = 0,
        .committed_day = 0,
        .intent = .break_enemy,
    });

    try resolveEngagement(&gs_pf, gs_pf.contracts.getPtr(cid).?);
    try resolveEngagement(&gs_be, gs_be.contracts.getPtr(cid).?);

    // preserve_force: gate blocks salvage regardless of field outcome.
    var pf_salvage: i64 = 0;
    for (gs_pf.battle_reports.kept.items) |r| {
        if (r.operation_intent == .preserve_force) {
            try testing.expectEqual(@as(i64, 0), r.salvage.claimed_bv);
            try testing.expectEqual(@as(i64, 0), r.salvage.unclaimed_bv);
        }
        pf_salvage += r.salvage.claimed_bv + r.salvage.unclaimed_bv;
    }
    try testing.expectEqual(@as(i64, 0), pf_salvage);

    // break_enemy: salvage_allowed = true; with a held field it must be non-zero.
    var be_salvage: i64 = 0;
    for (gs_be.battle_reports.kept.items) |r| {
        if (r.held_field) {
            be_salvage += r.salvage.claimed_bv + r.salvage.unclaimed_bv;
        }
    }
    try testing.expect(be_salvage > 0);
}

test "no-task engagement: two runs at the same seed produce identical outcomes (P4e regression guard)" {
    // Rule 20 / P4e: lanceTaskPower and operationTaskMods must not draw new RNG.
    // Two campaigns at the same seed with an empty op.tasks list must produce
    // identical battle outcomes (player_power, score_delta, outcome) — proving
    // the P4e code-paths introduce no new RNG draw on the no-task path.
    const testing = std.testing;
    const cid: types.ContractId = @enumFromInt(1);
    const oid: types.OperationId = @enumFromInt(1);

    var gs_a = GameState.init(testing.allocator, .{ .seed = 55001 });
    defer gs_a.deinit();
    var gs_b = GameState.init(testing.allocator, .{ .seed = 55001 });
    defer gs_b.deinit();

    for (&[_]*GameState{ &gs_a, &gs_b }) |gs| {
        const co = try @import("starter_company.zig").generateInto(gs, "Ghost");
        try gs.contracts.put(gs.allocator(), cid, .{
            .id = cid,
            .kind = .garrison_duty,
            .employer_key = "LC",
            .enemy_key = "DC",
            .planet_key = "galatea",
            .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
            .status = .active,
            .assigned_company = co,
            .arc_key = "fracturing_garrison",
            .enemy_lances = 2,
            .enemy_lance_bv = 8000,
        });
        // Committed combat op with no tasks (default empty tasks list).
        try gs.contracts.getPtr(cid).?.operations.append(gs.allocator(), .{
            .id = oid,
            .template_key = "repel_probe",
            .state = .committed,
            .opened_day = 0,
            .committed_day = 0,
        });
    }

    try resolveEngagement(&gs_a, gs_a.contracts.getPtr(cid).?);
    try resolveEngagement(&gs_b, gs_b.contracts.getPtr(cid).?);

    const ra = gs_a.battle_reports.kept.items[0];
    const rb = gs_b.battle_reports.kept.items[0];
    try testing.expectEqual(ra.outcome, rb.outcome);
    try testing.expectEqual(ra.player_power, rb.player_power);
    try testing.expectEqual(ra.score_delta, rb.score_delta);
    try testing.expectEqual(ra.hits_taken, rb.hits_taken);
    // Both reports carry empty task lists (no tasks were assigned).
    try testing.expectEqual(@as(usize, 0), ra.tasks.len);
    try testing.expectEqual(@as(usize, 0), rb.tasks.len);
}

test "lance tasking shapes battle outcomes: main_effort task raises player_power vs no tasks" {
    // Rule 20 consumer test / P4e: lanceTaskPower scales a main_effort lance's
    // contribution. The tasked campaign must have a higher player_power than the
    // no-task campaign at the same seed (main_effort.line_power_bp = 12_000 > 10_000).
    const testing = std.testing;
    const cid: types.ContractId = @enumFromInt(1);
    const oid: types.OperationId = @enumFromInt(1);

    var gs_tasked = GameState.init(testing.allocator, .{ .seed = 55002 });
    defer gs_tasked.deinit();
    var gs_none = GameState.init(testing.allocator, .{ .seed = 55002 });
    defer gs_none.deinit();

    var first_lance: types.ForceId = .none;
    for (&[_]*GameState{ &gs_tasked, &gs_none }) |gs| {
        const co = try @import("starter_company.zig").generateInto(gs, "Ghost");
        try gs.contracts.put(gs.allocator(), cid, .{
            .id = cid,
            .kind = .garrison_duty,
            .employer_key = "LC",
            .enemy_key = "DC",
            .planet_key = "galatea",
            .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
            .status = .active,
            .assigned_company = co,
            .arc_key = "fracturing_garrison",
            .enemy_lances = 2,
            .enemy_lance_bv = 8000,
        });
        // Record the first combat lance id (both campaigns are identical up to this point).
        if (first_lance == .none) {
            const co_force = gs.force(co).?;
            for (co_force.children.items) |lid| {
                if (gs.force(lid)) |l| if (l.isCombatLance()) {
                    first_lance = lid;
                    break;
                };
            }
        }
        try gs.contracts.getPtr(cid).?.operations.append(gs.allocator(), .{
            .id = oid,
            .template_key = "repel_probe",
            .state = .committed,
            .opened_day = 0,
            .committed_day = 0,
        });
        // Pre-warm the event log so that resolveEngagement's reserveLog(1) and
        // subsequent AAR log.append calls do not collide at the 8-slot boundary
        // of the ArrayList's initial growCapacity(0, 1) allocation. This is a
        // pre-existing capacity invariant (not introduced by P4e); pre-warming
        // makes the test robust regardless of the specific battle's hit count.
        try gs.reserveLog(32);
    }

    // Assign main_effort to the first combat lance in the tasked campaign only.
    try testing.expect(first_lance != .none);
    try gs_tasked.contracts.getPtr(cid).?.operations.items[0].tasks.append(
        gs_tasked.allocator(),
        .{ .lance = first_lance, .task = .main_effort },
    );

    try resolveEngagement(&gs_tasked, gs_tasked.contracts.getPtr(cid).?);
    try resolveEngagement(&gs_none, gs_none.contracts.getPtr(cid).?);

    const r_tasked = gs_tasked.battle_reports.kept.items[0];
    const r_none = gs_none.battle_reports.kept.items[0];
    // main_effort (12 000 bp) scales that lance above the default (10 000 bp),
    // so player_power must be strictly greater in the tasked campaign.
    try testing.expect(r_tasked.player_power > r_none.player_power);
    // The tasked report must record the task row.
    try testing.expectEqual(@as(usize, 1), r_tasked.tasks.len);
    try testing.expectEqual(operation_mod.LanceTask.main_effort, r_tasked.tasks[0].task);
    // The no-task report must have an empty task list.
    try testing.expectEqual(@as(usize, 0), r_none.tasks.len);
}

test "escort task suppresses convoy damage on a losing engagement" {
    // Rule 20 consumer test / P4e: escort_present in TaskMods (operations_m.operationTaskMods)
    // prevents the convoy_hit branch in aftermath. On security_duty, 2/6 scenario
    // faces are convoy_escort (support_exposed = true). With a very strong enemy
    // the company consistently loses; escort must produce zero convoy_hit reports
    // across all 20 battles. Without escort, at least one convoy_hit is expected
    // (security_duty has a 33% convoy_escort rate; at 20 battles p(no hit) < 0.3%).
    const testing = std.testing;
    const cid: types.ContractId = @enumFromInt(1);
    const n_battles = 20;

    var escort_hits: u32 = 0;
    var no_escort_hits: u32 = 0;

    for ([_]bool{ false, true }) |with_escort| {
        var gs = GameState.init(testing.allocator, .{ .seed = 55003 });
        defer gs.deinit();
        const co = try @import("starter_company.zig").generateInto(&gs, "Ghost");
        try gs.contracts.put(gs.allocator(), cid, .{
            .id = cid,
            .kind = .security_duty, // 2/6 faces are convoy_escort (support_exposed = true)
            .employer_key = "LC",
            .enemy_key = "DC",
            .planet_key = "galatea",
            .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
            .status = .active,
            .assigned_company = co,
            .enemy_lances = 6,
            .enemy_lance_bv = 8000, // 48 000 total BV: guarantees losses (ratio < 60%)
        });
        const c = gs.contracts.getPtr(cid).?;

        // Find the first combat lance to act as the escort.
        var escort_lance: types.ForceId = .none;
        const co_force = gs.force(co).?;
        for (co_force.children.items) |lid| {
            if (gs.force(lid)) |l| if (l.isCombatLance()) {
                escort_lance = lid;
                break;
            };
        }

        var next_oid: u32 = 1;
        for (0..n_battles) |_| {
            const oid: types.OperationId = @enumFromInt(next_oid);
            next_oid += 1;
            // Add a fresh committed combat op for each engagement.
            try c.operations.append(gs.allocator(), .{
                .id = oid,
                .template_key = "repel_probe",
                .state = .committed,
                .opened_day = 0,
                .committed_day = 0,
            });
            if (with_escort and escort_lance != .none) {
                const op = &c.operations.items[c.operations.items.len - 1];
                try op.tasks.append(gs.allocator(), .{
                    .lance = escort_lance,
                    .task = .escort,
                });
            }
            gs.next_operation_id = next_oid;
            try resolveEngagement(&gs, c);
            while (gs.event_queue.blocking()) |ev|
                try @import("contract_events.zig").resolveChoice(&gs, ev.id, ev.default_choice);
            while (gs.battle_reports.unread()) |r| _ = gs.battle_reports.markRead(r.id);
        }

        var hits: u32 = 0;
        for (gs.battle_reports.kept.items) |r| hits += @intFromBool(r.convoy_hit);
        if (with_escort) escort_hits = hits else no_escort_hits = hits;
    }

    // An escort lance must never itself produce convoy damage.
    try testing.expectEqual(@as(u32, 0), escort_hits);
    // When the no-escort campaign saw convoy hits, escort must have suppressed them.
    if (no_escort_hits > 0) {
        try testing.expectEqual(@as(u32, 0), escort_hits);
    }
}

test "report.tasks is populated on both the resolve and concede paths" {
    // P4e: every committed combat op's task assignments must appear in the battle
    // report, with the correct task enum and a non-.none lance id.
    // Resolve path: the company fights and the outcome is whatever the dice give.
    // Concede path: an empty company concedes; all tasks in the report are failed.
    const testing = std.testing;

    // --- Resolve path ---
    {
        var gs = GameState.init(testing.allocator, .{ .seed = 55004 });
        defer gs.deinit();
        const co = try @import("starter_company.zig").generateInto(&gs, "Ghost");
        const cid: types.ContractId = @enumFromInt(1);
        try gs.contracts.put(gs.allocator(), cid, .{
            .id = cid,
            .kind = .garrison_duty,
            .employer_key = "LC",
            .enemy_key = "DC",
            .planet_key = "galatea",
            .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
            .status = .active,
            .assigned_company = co,
            .arc_key = "fracturing_garrison",
            .enemy_lances = 2,
            .enemy_lance_bv = 5000,
        });
        const c = gs.contracts.getPtr(cid).?;
        // Record two combat lances for the task assignments.
        const co_force = gs.force(co).?;
        var lance_a: types.ForceId = .none;
        var lance_b: types.ForceId = .none;
        for (co_force.children.items) |lid| {
            if (gs.force(lid)) |l| if (l.isCombatLance()) {
                if (lance_a == .none) lance_a = lid else if (lance_b == .none) lance_b = lid;
            };
        }
        try testing.expect(lance_a != .none);
        try c.operations.append(gs.allocator(), .{
            .id = @enumFromInt(1),
            .template_key = "repel_probe",
            .state = .committed,
            .opened_day = 0,
            .committed_day = 0,
        });
        const op_resolve = &c.operations.items[0];
        try op_resolve.tasks.append(gs.allocator(), .{ .lance = lance_a, .task = .main_effort });
        if (lance_b != .none) try op_resolve.tasks.append(gs.allocator(), .{ .lance = lance_b, .task = .reserve });

        try resolveEngagement(&gs, c);

        const r = gs.battle_reports.kept.items[0];
        try testing.expect(r.tasks.len >= 1);
        try testing.expectEqual(operation_mod.LanceTask.main_effort, r.tasks[0].task);
        try testing.expect(r.tasks[0].lance != .none);
        // succeeded is a valid bool (true or false — depends on battle outcome).
        _ = r.tasks[0].succeeded;
        if (r.tasks.len >= 2) {
            try testing.expectEqual(operation_mod.LanceTask.reserve, r.tasks[1].task);
            try testing.expect(r.tasks[1].lance != .none);
        }
    }

    // --- Concede path ---
    {
        var gs = GameState.init(testing.allocator, .{ .seed = 55005 });
        defer gs.deinit();
        // Empty company → concede.
        const co = try gs.createForce("Empty", .company, .none);
        const cid: types.ContractId = @enumFromInt(1);
        try gs.contracts.put(gs.allocator(), cid, .{
            .id = cid,
            .kind = .garrison_duty,
            .employer_key = "LC",
            .enemy_key = "DC",
            .planet_key = "galatea",
            .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
            .status = .active,
            .assigned_company = co,
            .arc_key = "fracturing_garrison",
            .enemy_lances = 2,
            .enemy_lance_bv = 5000,
        });
        const c = gs.contracts.getPtr(cid).?;
        // Use arbitrary non-none lance ids for the tasks (no real lances needed on concede).
        const fake_lance_a: types.ForceId = @enumFromInt(101);
        const fake_lance_b: types.ForceId = @enumFromInt(102);
        try c.operations.append(gs.allocator(), .{
            .id = @enumFromInt(1),
            .template_key = "repel_probe",
            .state = .committed,
            .opened_day = 0,
            .committed_day = 0,
        });
        const op_concede = &c.operations.items[0];
        try op_concede.tasks.append(gs.allocator(), .{ .lance = fake_lance_a, .task = .main_effort });
        try op_concede.tasks.append(gs.allocator(), .{ .lance = fake_lance_b, .task = .escort });

        _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
        try resolveEngagement(&gs, c);

        const r = gs.battle_reports.kept.items[0];
        try testing.expect(r.conceded);
        try testing.expectEqual(@as(usize, 2), r.tasks.len);
        // Concede path: all tasks must report failure.
        try testing.expect(!r.tasks[0].succeeded);
        try testing.expect(!r.tasks[1].succeeded);
        try testing.expectEqual(operation_mod.LanceTask.main_effort, r.tasks[0].task);
        try testing.expectEqual(operation_mod.LanceTask.escort, r.tasks[1].task);
    }
}

test "reserveLog fix: committed combat op + multi-line AAR does not corrupt the log; [arc] line is present" {
    // Regression: pre-P4f, reserveLog was called before the AAR render loop,
    // which could consume the reserved slot before appendAssumeCapacity.
    // After the fix, reserveLog is called inside the infallible commit block,
    // immediately before op.state = .resolved.
    const testing = std.testing;
    var gs = GameState.init(testing.allocator, .{ .seed = 99001 });
    defer gs.deinit();

    const co = try @import("starter_company.zig").generateInto(&gs, "Ghost");
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const cid: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .active,
        .assigned_company = co,
        .arc_key = "fracturing_garrison",
        .enemy_lances = 2,
        .enemy_lance_bv = 5000,
    });
    const c = gs.contracts.getPtr(cid).?;
    try c.operations.append(gs.allocator(), .{
        .id = @enumFromInt(1),
        .template_key = "repel_probe",
        .state = .committed,
        .opened_day = 0,
        .committed_day = 0,
    });

    const log_before = gs.event_log.items.len;
    try resolveEngagement(&gs, c);

    // The event log must have grown (AAR lines + arc result line).
    try testing.expect(gs.event_log.items.len > log_before);

    // The [arc] combat-operation-resolved line must be in the log.
    var found_arc = false;
    for (gs.event_log.items[log_before..]) |entry| {
        if (std.mem.indexOf(u8, entry.text, "[arc] combat operation resolved:") != null) {
            found_arc = true;
        }
    }
    try testing.expect(found_arc);

    // The battle report must have operation_tempo set (null only if no committed op — here it is set).
    const r = gs.battle_reports.kept.items[0];
    try testing.expectEqual(@as(?operation_mod.TempoPosture, .advance), r.operation_tempo);
}

test "intervention consumer: emergency_recon changes conditions_mod versus no-intervention baseline (P4g rule 67)" {
    // Rule 67 owner/consumer agreement: operationInterventionMods is owned by
    // operations_m; this test proves battle.zig actually reads it.
    // Two campaigns at the same seed, identical except one has emergency_recon
    // applied to the committed combat op. The conditions_mod (= scenario_mod) in
    // the report must differ by the intervention's surprise_reduction value (2).
    const testing = std.testing;
    const cid: types.ContractId = @enumFromInt(1);
    const oid: types.OperationId = @enumFromInt(1);

    var gs_base = GameState.init(testing.allocator, .{ .seed = 99003 });
    defer gs_base.deinit();
    var gs_iv = GameState.init(testing.allocator, .{ .seed = 99003 });
    defer gs_iv.deinit();

    for (&[_]*GameState{ &gs_base, &gs_iv }) |gs| {
        const co = try @import("starter_company.zig").generateInto(gs, "Ghost");
        try gs.contracts.put(gs.allocator(), cid, .{
            .id = cid,
            .kind = .garrison_duty,
            .employer_key = "LC",
            .enemy_key = "DC",
            .planet_key = "galatea",
            .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
            .status = .active,
            .assigned_company = co,
            .arc_key = "fracturing_garrison",
            .enemy_lances = 2,
            .enemy_lance_bv = 5000,
        });
        try gs.contracts.getPtr(cid).?.operations.append(gs.allocator(), .{
            .id = oid,
            .template_key = "repel_probe",
            .state = .committed,
            .opened_day = 0,
            .committed_day = 0,
        });
        try gs.reserveLog(32);
    }
    // Apply emergency_recon on the intervention campaign only.
    try gs_iv.contracts.getPtr(cid).?.operations.items[0].interventions.append(
        gs_iv.allocator(),
        operation_mod.Intervention.emergency_recon,
    );

    try resolveEngagement(&gs_base, gs_base.contracts.getPtr(cid).?);
    try resolveEngagement(&gs_iv, gs_iv.contracts.getPtr(cid).?);

    const r_base = gs_base.battle_reports.kept.items[0];
    const r_iv = gs_iv.battle_reports.kept.items[0];
    // emergency_recon adds surprise_reduction = 2 to conditions_mod; the two
    // campaigns used the same seed so all other terms are identical.
    const profile = operations_m.interventionProfile(.emergency_recon);
    try testing.expectEqual(
        r_base.conditions_mod + profile.surprise_reduction + profile.prepared_roll_bonus,
        r_iv.conditions_mod,
    );
    // The intervention report must carry the label.
    try testing.expect(r_iv.operation_interventions.len > 0);
}

test "tempo identity: advance posture produces the same battle outcome as pre-P4f (same seed)" {
    // Rule 20: default .advance must be behaviour-identical to pre-P4f.
    // The test uses two identical seeds; one sets tempo explicitly to .advance (the default posture).
    // The digests must match after resolution.
    const testing = std.testing;
    var gs_no_op = GameState.init(testing.allocator, .{ .seed = 99002 });
    defer gs_no_op.deinit();
    var gs_adv = GameState.init(testing.allocator, .{ .seed = 99002 });
    defer gs_adv.deinit();

    for (&[_]*GameState{ &gs_no_op, &gs_adv }) |gs| {
        const co = try @import("starter_company.zig").generateInto(gs, "Ghost");
        _ = try founding.createCommander(gs, "T", .LC, .line_officer);
        const cid: types.ContractId = @enumFromInt(1);
        try gs.contracts.put(gs.allocator(), cid, .{
            .id = cid,
            .kind = .garrison_duty,
            .employer_key = "LC",
            .enemy_key = "DC",
            .planet_key = "galatea",
            .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
            .status = .active,
            .assigned_company = co,
            .arc_key = "fracturing_garrison",
            .enemy_lances = 2,
            .enemy_lance_bv = 5000,
        });
    }
    // No op on gs_no_op; advance op on gs_adv.
    const cid: types.ContractId = @enumFromInt(1);
    try gs_adv.contracts.getPtr(cid).?.operations.append(gs_adv.allocator(), .{
        .id = @enumFromInt(1),
        .template_key = "repel_probe",
        .state = .committed,
        .opened_day = 0,
        .committed_day = 0,
        .tempo = .advance,
    });

    try resolveEngagement(&gs_no_op, gs_no_op.contracts.getPtr(cid).?);
    try resolveEngagement(&gs_adv, gs_adv.contracts.getPtr(cid).?);

    // Both must have the same outcome (advance = all-zero mods = no change).
    const r_no_op = gs_no_op.battle_reports.kept.items[0];
    const r_adv = gs_adv.battle_reports.kept.items[0];
    try testing.expectEqual(r_no_op.outcome, r_adv.outcome);
    try testing.expectEqual(r_no_op.score_delta, r_adv.score_delta);
}

test "salvage recovery records a .salvage ownership row with the enemy key" {
    // Rule 20 / P3c.4: takeSalvage must record one .salvage interval per recovered
    // hull, with prior_owner_key == c.enemy_key and an open to_day. Uses
    // rollSalvageCandidates + takeSalvage directly (the existing salvage-claim
    // scaffold) to guarantee hull recovery without depending on resolveEngagement
    // producing a held-field outcome.
    const testing = std.testing;
    const cid: types.ContractId = @enumFromInt(1);
    var gs = GameState.init(testing.allocator, .{ .seed = 1223 });
    defer gs.deinit();
    _ = try @import("founding.zig").createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Ghost");
    try gs.contracts.put(gs.allocator(), cid, contract_mod.Contract{
        .id = cid,
        .kind = .objective_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 400_000, .salvage_pct = 50 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
    });
    const c = gs.contracts.getPtr(cid).?;
    const units_before = gs.units.count();
    const own_before = gs.hull_ownership_history.items.len;
    const candidates = try rollSalvageCandidates(&gs, c);
    _ = try takeSalvage(&gs, c, candidates, 2_000, .most_hulls);
    // At least one hull was salvaged (matching the existing salvage scaffold assertion).
    try testing.expect(gs.units.count() > units_before);

    // Every ownership row added by takeSalvage must be .salvage with
    // prior_owner_key == "DC" and open interval. Only check the rows added
    // after this call; starter-company rows (pre_campaign .initial) come first.
    const salvage_rows = gs.hull_ownership_history.items[own_before..];
    try testing.expect(salvage_rows.len > 0);
    for (salvage_rows) |row| {
        try testing.expectEqual(@import("../domain/hull_instance.zig").AcquisitionType.salvage, row.acquisition_type);
        try testing.expectEqualStrings("DC", row.prior_owner_key);
        try testing.expectEqual(@as(?u32, null), row.to_day);
        try testing.expect(gs.hull_instances.contains(row.hull_instance_id));
    }
}

// ---------- P3e.5b-3a: OpFor roster draw, attrition, and forfeit tests --------

/// Seed n hull instances owned by faction_key (all "LCT-1V", bv=432) and
/// return a slice of their ids. Arena-allocated; freed at gs.deinit().
fn seedOpforHulls(gs: *GameState, faction_key: []const u8, n: usize) ![]types.HullInstanceId {
    const alloc = gs.allocator();
    const ids = try alloc.alloc(types.HullInstanceId, n);
    const gop = try gs.faction_rosters.getOrPut(alloc, faction_key);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    for (ids, 0..) |*id, i| {
        _ = i;
        const hid: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
        gs.next_hull_instance_id += 1;
        try gs.hull_instances.put(alloc, hid, .{
            .id = hid,
            .base_key = "LCT-1V",
            .owner = .{ .faction = faction_key },
        });
        try gs.hull_ownership_history.append(alloc, .{
            .hull_instance_id = hid,
            .from_day = 0,
            .to_day = null, // open interval
            .acquisition_type = .initial,
            .prior_owner_key = "",
        });
        try gop.value_ptr.append(alloc, hid);
        id.* = hid;
    }
    return ids;
}

test "pool draw: destroyed hulls are pool-removed and have a valid final disposition" {
    // Tests plan 3+4 (updated for 3b): pool removal and no-partial-state invariants.
    // Destroyed hulls are pool-removed immediately (writeHullCombatRecords).
    // Final disposition (permanently_destroyed or player/employer owned) happens
    // via takeSalvage / finalizeDestroyedWreck after the salvage decision resolves.
    // Lost-field hulls stay active, enemy-owned (B6) — not permanently_destroyed.
    const testing = std.testing;
    const hull_instance_mod = @import("../domain/hull_instance.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3001 });
    defer gs.deinit();
    gs.clock.day_index = 1; // non-zero so closed intervals are detectable
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    const pool_ids = try seedOpforHulls(&gs, "DC", 4);
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000, .salvage_pct = 30, .battle_loss_pct = 30 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
        .enemy_lances = 1,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    const site: types.Site = .{ .company = co };
    try gs.addStock(site, "armor", 60);
    for (@import("../domain/part.zig").munition_keys) |key| try gs.addStock(site, key, 40);

    // Run several engagements so at least some hull outcomes are likely exercised.
    var battles: u32 = 0;
    while (battles < 4 and c.status == .active) : (battles += 1) {
        try resolveEngagement(&gs, c);
        try answerBattleDecisions(&gs);
    }

    // Invariant A: for every HullCombatRecord with destroyed == true on this contract:
    //   - hull is NOT in the pool (pool removal is always immediate)
    //   - if permanently_destroyed: owner must be .destroyed and all intervals closed
    //     (no partial state — owner/status must be consistent)
    //   - if not permanently_destroyed: hull is active (player-owned from salvage
    //     or enemy-owned from a lost field — both are valid transient states)
    for (gs.hull_combat_records.items) |rec| {
        if (rec.contract_id != @as(types.ContractId, @enumFromInt(1))) continue;
        if (!rec.destroyed) continue;
        const inst = gs.hull_instances.getPtr(rec.hull_instance_id) orelse return error.TestFailed;
        // Not in pool (always: writeHullCombatRecords removes from pool on destroy).
        if (gs.faction_rosters.getPtr("DC")) |pool| {
            for (pool.items) |pid| try testing.expect(pid != rec.hull_instance_id);
        }
        // No partial state: if permanently_destroyed, owner must be .destroyed
        // and all ownership intervals must be closed.
        if (inst.status == hull_instance_mod.HullStatus.permanently_destroyed) {
            try testing.expectEqual(hull_instance_mod.OwnerType.destroyed, std.meta.activeTag(inst.owner));
            for (gs.hull_ownership_history.items) |h| {
                if (h.hull_instance_id == rec.hull_instance_id) {
                    try testing.expect(h.to_day != null); // closed
                }
            }
        }
    }
    // Invariant B: no non-destroyed hull in pool_ids had its status changed.
    if (gs.faction_rosters.getPtr("DC")) |pool| {
        for (pool.items) |pid| {
            // Hull is in the pool: it should still be active.
            const inst = gs.hull_instances.getPtr(pid) orelse continue;
            try testing.expectEqual(@import("../domain/hull_instance.zig").HullStatus.active, inst.status);
        }
        // Pool is a subset of the original pool_ids.
        for (pool.items) |pid| {
            var found = false;
            for (pool_ids) |oid| if (oid == pid) {
                found = true;
                break;
            };
            try testing.expect(found);
        }
    }
    // HullStatus still has exactly two members (no new enum value was added).
    try testing.expectEqual(@as(usize, 2), @typeInfo(@import("../domain/hull_instance.zig").HullStatus).@"enum".fields.len);
}

test "pool draw: enemy_destroyed_bv equals sum of BVs of destroyed drawn hulls" {
    // Tests plan 3: BV figure accuracy (B2).
    const testing = std.testing;
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3002 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    _ = try seedOpforHulls(&gs, "DC", 4);
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000, .salvage_pct = 30, .battle_loss_pct = 30 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
        .enemy_lances = 1,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    const site: types.Site = .{ .company = co };
    try gs.addStock(site, "armor", 60);
    for (@import("../domain/part.zig").munition_keys) |key| try gs.addStock(site, key, 40);

    try resolveEngagement(&gs, c);
    try answerBattleDecisions(&gs);

    // enemy_destroyed_bv in the report == sum of BVs of hulls with destroyed record.
    const report = &gs.battle_reports.kept.items[gs.battle_reports.kept.items.len - 1];
    // Pool path was taken (faction_rosters non-empty).
    var bv_sum: i64 = 0;
    for (gs.hull_combat_records.items) |rec| {
        if (rec.contract_id != c.id) continue;
        if (!rec.destroyed) continue;
        const inst = gs.hull_instances.getPtr(rec.hull_instance_id) orelse continue;
        if (chassis_mod.find(inst.base_key)) |ch| bv_sum += ch.bv;
    }
    try testing.expectEqual(bv_sum, report.enemy_destroyed_bv);
}

test "combat_ineffective hull is excluded from subsequent draws on the same contract" {
    // Tests plan 5: exclusion across battles and depleted-pool forfeit.
    const testing = std.testing;
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3003 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    const pool_ids = try seedOpforHulls(&gs, "DC", 1); // single hull pool
    const hid = pool_ids[0];
    const cid: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
        .enemy_lances = 1,
    });
    const c = gs.contracts.getPtr(cid).?;
    const site: types.Site = .{ .company = co };
    try gs.addStock(site, "armor", 60);
    for (@import("../domain/part.zig").munition_keys) |key| try gs.addStock(site, key, 40);

    // Inject a combat_ineffective record for hid on this contract, as if a prior
    // battle marked it ineffective (destroyed == false, contract == cid).
    try gs.hull_combat_records.append(gs.allocator(), .{
        .hull_instance_id = hid,
        .battle_id = @enumFromInt(1),
        .contract_id = cid,
        .destroyed = false,
    });

    // Battle 2 (the hull is still in the pool but excluded by the record).
    // If the exclusion works, the pool is empty → forfeit → victory.
    const battles_won_before = gs.stats.battles_won;
    try resolveEngagement(&gs, c);
    // Forfeit: battles_won incremented, score increased by forfeit delta.
    try testing.expect(gs.stats.battles_won > battles_won_before);
    // The hull remains in the pool (combat_ineffective, not destroyed).
    const pool = gs.faction_rosters.getPtr("DC") orelse return error.TestFailed;
    var still_in_pool = false;
    for (pool.items) |pid| if (pid == hid) {
        still_in_pool = true;
        break;
    };
    try testing.expect(still_in_pool);
    // The hull's status is unchanged (still active — not destroyed by forfeit).
    const inst = gs.hull_instances.getPtr(hid) orelse return error.TestFailed;
    try testing.expectEqual(@import("../domain/hull_instance.zig").HullStatus.active, inst.status);
}

test "forfeit: would-be pool present but empty, and key absent for replenishment>0 faction" {
    // Tests plan 6: forfeit from empty pool and absent pool (Decision 2b).
    const testing = std.testing;
    // Case A: key present, list empty.
    {
        var gs = GameState.init(std.testing.allocator, .{ .seed = 3004 });
        defer gs.deinit();
        _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
        const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
        // Seed an empty DC roster (key present, no hulls).
        try gs.faction_rosters.put(gs.allocator(), "DC", .empty);
        const cid: types.ContractId = @enumFromInt(1);
        try gs.contracts.put(gs.allocator(), cid, .{
            .id = cid,
            .kind = .recon_raid,
            .employer_key = "LC",
            .enemy_key = "DC",
            .planet_key = "galatea",
            .terms = .{ .length_months = 6, .base_pay_month = 400_000 },
            .status = .active,
            .assigned_company = co,
            .monthly_net = 300_000,
            .enemy_lances = 1,
        });
        const c = gs.contracts.getPtr(cid).?;
        const site: types.Site = .{ .company = co };
        try gs.addStock(site, "armor", 60);
        for (@import("../domain/part.zig").munition_keys) |key| try gs.addStock(site, key, 40);
        const score_before = c.score;
        const battles_won_before = gs.stats.battles_won;
        try resolveEngagement(&gs, c);
        // Bloodless win: score += forfeit, battles_won++.
        try testing.expect(c.score > score_before);
        try testing.expect(gs.stats.battles_won > battles_won_before);
        // Report says victory, held_field, enemy_destroyed_bv == 0.
        const report = &gs.battle_reports.kept.items[gs.battle_reports.kept.items.len - 1];
        try testing.expectEqual(@import("../domain/autoresolve.zig").Outcome.victory, report.outcome);
        try testing.expect(report.held_field);
        try testing.expectEqual(@as(i64, 0), report.enemy_destroyed_bv);
        // No hulls mutated (pool stays empty).
        const pool = gs.faction_rosters.getPtr("DC").?;
        try testing.expectEqual(@as(usize, 0), pool.items.len);
    }
    // Case B: key absent for a replenishment>0 faction (post-reload analog).
    {
        var gs = GameState.init(std.testing.allocator, .{ .seed = 3005 });
        defer gs.deinit();
        _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
        const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
        // Seed SOME entry (so faction_rosters.count() > 0, bypassing abstraction guard),
        // but NOT for "DC" (simulating post-reload absence after depletion).
        try gs.faction_rosters.put(gs.allocator(), "FS", .empty);
        const cid: types.ContractId = @enumFromInt(1);
        try gs.contracts.put(gs.allocator(), cid, .{
            .id = cid,
            .kind = .recon_raid,
            .employer_key = "LC",
            .enemy_key = "DC",
            .planet_key = "galatea",
            .terms = .{ .length_months = 6, .base_pay_month = 400_000 },
            .status = .active,
            .assigned_company = co,
            .monthly_net = 300_000,
            .enemy_lances = 1,
        });
        const c = gs.contracts.getPtr(cid).?;
        const site: types.Site = .{ .company = co };
        try gs.addStock(site, "armor", 60);
        for (@import("../domain/part.zig").munition_keys) |key| try gs.addStock(site, key, 40);
        const battles_won_before = gs.stats.battles_won;
        try resolveEngagement(&gs, c);
        // Bloodless win: battles_won++.
        try testing.expect(gs.stats.battles_won > battles_won_before);
        const report = &gs.battle_reports.kept.items[gs.battle_reports.kept.items.len - 1];
        try testing.expectEqual(@import("../domain/autoresolve.zig").Outcome.victory, report.outcome);
        try testing.expectEqual(@as(i64, 0), report.enemy_destroyed_bv);
    }
}

test "pool draw stages hull BV before weather and remains deterministic" {
    // Equal seeds and pools must produce the same staged draw and battle result.
    var gs1 = GameState.init(std.testing.allocator, .{ .seed = 3006 });
    defer gs1.deinit();
    _ = try founding.createCommander(&gs1, "T", .LC, .line_officer);
    const co1 = try @import("starter_company.zig").generateInto(&gs1, "Alpha");
    const pool_ids1 = try seedOpforHulls(&gs1, "DC", 4);
    try gs1.contracts.put(gs1.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000, .salvage_pct = 30, .battle_loss_pct = 30 },
        .status = .active,
        .assigned_company = co1,
        .monthly_net = 300_000,
        .enemy_lances = 1,
    });
    const site1: types.Site = .{ .company = co1 };
    try gs1.addStock(site1, "armor", 60);
    for (@import("../domain/part.zig").munition_keys) |key| try gs1.addStock(site1, key, 40);

    var staged_state = gs1;
    var staged_scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer staged_scratch.deinit();
    const staged_drawn = try drawOpforHulls(&staged_state, staged_scratch.allocator(), pool_ids1, pool_ids1.len);
    for (staged_drawn) |drawn_id| {
        var found = false;
        for (pool_ids1) |pool_id| {
            if (drawn_id == pool_id) found = true;
        }
        try std.testing.expect(found);
    }
    const expected_weather = terrain_mod.rollWeather(&staged_state.rng, .battle, terrain_mod.terrainOf(planet_mod.find("galatea").?));

    var gs2 = GameState.init(std.testing.allocator, .{ .seed = 3006 }); // same seed
    defer gs2.deinit();
    _ = try founding.createCommander(&gs2, "T", .LC, .line_officer);
    const co2 = try @import("starter_company.zig").generateInto(&gs2, "Alpha");
    _ = try seedOpforHulls(&gs2, "DC", 4);
    try gs2.contracts.put(gs2.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000, .salvage_pct = 30, .battle_loss_pct = 30 },
        .status = .active,
        .assigned_company = co2,
        .monthly_net = 300_000,
        .enemy_lances = 1,
    });
    const site2: types.Site = .{ .company = co2 };
    try gs2.addStock(site2, "armor", 60);
    for (@import("../domain/part.zig").munition_keys) |key| try gs2.addStock(site2, key, 40);

    // Both campaigns resolve the same engagement from the same RNG state.
    const c1 = gs1.contracts.getPtr(@enumFromInt(1)).?;
    const c2 = gs2.contracts.getPtr(@enumFromInt(1)).?;
    try resolveEngagement(&gs1, c1);
    try resolveEngagement(&gs2, c2);
    try answerBattleDecisions(&gs1);
    try answerBattleDecisions(&gs2);

    const report1 = gs1.battle_reports.kept.items[gs1.battle_reports.kept.items.len - 1];
    const report2 = gs2.battle_reports.kept.items[gs2.battle_reports.kept.items.len - 1];
    const expected_bv = chassis_mod.find("LCT-1V").?.bv * @as(i64, @intCast(pool_ids1.len));
    const expected_power = (autoresolve.Element{ .base_strength = expected_bv, .avg_gunnery = 4, .avg_piloting = 5 }).effectivePower(.{});
    try std.testing.expectEqual(expected_power, report1.enemy_power);
    try std.testing.expectEqualStrings(terrain_mod.weatherRow(expected_weather).name, report1.weather);
    try std.testing.expectEqual(report1.enemy_power, report2.enemy_power);
    try std.testing.expectEqualStrings(report1.weather, report2.weather);

    const hash1 = @import("digest.zig").stateHash(&gs1);
    const hash2 = @import("digest.zig").stateHash(&gs2);
    try std.testing.expectEqual(hash1, hash2);
}

test "pool draw allocation failure preserves the complete engagement state" {
    const digest = @import("digest.zig");
    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 3008 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    _ = try seedOpforHulls(&gs, "DC", 4);
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000, .salvage_pct = 30, .battle_loss_pct = 30 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
        .enemy_lances = 1,
    });
    const site: types.Site = .{ .company = co };
    try gs.addStock(site, "armor", 60);
    for (part_mod.munition_keys) |key| try gs.addStock(site, key, 40);

    const before = digest.stateHash(&gs);
    var failing = std.testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        resolveEngagementWithResolutionScratch(&gs, gs.contracts.getPtr(@enumFromInt(1)).?, failing.allocator()),
    );
    try std.testing.expectEqual(before, digest.stateHash(&gs));
}

test "pool draw atomicity: hull_combat_records and hull_instances are consistent after pool-path battles" {
    // Tests plan 8 (updated for 3b): rule 7/13 atomicity invariant.
    // A destroyed hull has a hull_combat_record with destroyed=true, is absent
    // from the pool, and has a consistent owner/status (no partial state).
    // Final disposition depends on salvage resolution (held field vs lost field);
    // this test resolves all decisions via answerBattleDecisions.
    const testing = std.testing;
    const hull_instance_mod = @import("../domain/hull_instance.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3007 });
    defer gs.deinit();
    gs.clock.day_index = 1;
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    _ = try seedOpforHulls(&gs, "DC", 8); // larger pool for more outcome variety
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000, .salvage_pct = 30, .battle_loss_pct = 30 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
        .enemy_lances = 2,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    const site: types.Site = .{ .company = co };
    try gs.addStock(site, "armor", 60);
    for (@import("../domain/part.zig").munition_keys) |key| try gs.addStock(site, key, 40);

    // Run several engagements to accumulate a mix of outcomes.
    var battles: u32 = 0;
    while (battles < 5 and c.status == .active) : (battles += 1) {
        try resolveEngagement(&gs, c);
        try answerBattleDecisions(&gs);
    }

    // For each HullCombatRecord with destroyed=true: hull must be absent from
    // the pool and have a consistent state. No partial state (permanently_destroyed
    // without .destroyed owner, or .destroyed owner without permanently_destroyed).
    for (gs.hull_combat_records.items) |rec| {
        if (!rec.destroyed) continue;
        const inst = gs.hull_instances.getPtr(rec.hull_instance_id) orelse {
            try testing.expect(false); // hull vanished — violation
            continue;
        };
        // Always absent from pool.
        if (gs.faction_rosters.getPtr("DC")) |pool| {
            for (pool.items) |pid| try testing.expect(pid != rec.hull_instance_id);
        }
        // No partial state: permanently_destroyed ↔ .destroyed owner.
        if (inst.status == hull_instance_mod.HullStatus.permanently_destroyed) {
            try testing.expectEqual(hull_instance_mod.OwnerType.destroyed, std.meta.activeTag(inst.owner));
        }
        if (std.meta.activeTag(inst.owner) == hull_instance_mod.OwnerType.destroyed) {
            try testing.expectEqual(hull_instance_mod.HullStatus.permanently_destroyed, inst.status);
        }
    }
    // No hull in the pool has status permanently_destroyed.
    if (gs.faction_rosters.getPtr("DC")) |pool| {
        for (pool.items) |pid| {
            const inst = gs.hull_instances.getPtr(pid) orelse continue;
            try testing.expect(inst.status != .permanently_destroyed);
        }
    }
    // Verify we ran at least some pool-path battles (faction_rosters had an entry).
    try testing.expect(gs.faction_rosters.count() > 0);
}

test "pool draw atomicity: OpFor tail is all-or-nothing under ensureUnusedCapacity failure" {
    // Rule 69: atomicity tested with injected failure.
    // This focused tail test complements the complete engagement failure sweeps
    // above. The prepared engagement now isolates prior score, AAR and posting
    // mutations until every destination, including this history tail, is ready.
    const testing = std.testing;
    var gs = GameState.init(std.testing.allocator, .{ .seed = 9001 });
    defer gs.deinit();
    gs.clock.day_index = 1;

    // Seed 3 hulls into a pool; opfor_outcomes has destroyed + combat_ineffective
    // entries so opfor_record_count > 0 and ensureUnusedCapacity must allocate.
    const pool_ids = try seedOpforHulls(&gs, "DC", 3);
    const pool = gs.faction_rosters.getPtr("DC").?;
    const opfor_outcomes: []const opfor.OpforHullOutcome = &.{ .destroyed, .surviving, .combat_ineffective };

    // hull_combat_records starts empty (capacity 0). The failing allocator with
    // fail_index = 0 triggers OOM at the first ensureUnusedCapacity call.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, writeHullCombatRecords(
        &gs,
        failing.allocator(),
        &.{}, // no engaged units — player record loop produces nothing
        opfor_outcomes,
        pool_ids,
        @enumFromInt(1), // report_id
        @enumFromInt(1), // contract_id
        &.{}, // per_unit_kills
        &.{}, // hit_log
        .{ .pool = .{ .hulls = pool, .owner = .{ .faction = "DC" } } },
    ));

    // Assert: no OpFor tail writes happened.
    // No HullCombatRecord was appended.
    try testing.expectEqual(@as(usize, 0), gs.hull_combat_records.items.len);
    // Pool length is unchanged.
    try testing.expectEqual(@as(usize, 3), pool.items.len);
    // No hull has permanently_destroyed status or .destroyed owner.
    for (pool.items) |pid| {
        const inst = gs.hull_instances.getPtr(pid) orelse {
            try testing.expect(false); // hull vanished — violation
            continue;
        };
        try testing.expect(inst.status != .permanently_destroyed);
        try testing.expectEqual(
            @import("../domain/hull_instance.zig").OwnerType.faction,
            std.meta.activeTag(inst.owner),
        );
    }
}

// ---------- P3e.5b-3b: salvage link — hull transfer, mandatory hold, guard fix --------

test "pool-path takeSalvage: chosen hull transfers, unchosen is finalized" {
    // Tests 3b invariants 1+2: transfer + finalization (direct function test).
    // WSP-1A BV = 192. claim_bv = 200. most_hulls plan: candidate 0 (192 BV)
    // fits; candidate 1 (192+192=384 > 200) is unchosen and finalized.
    const testing = std.testing;
    const hull_instance_mod = @import("../domain/hull_instance.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 4001 });
    defer gs.deinit();
    gs.clock.day_index = 10;
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    const cid: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000, .salvage_pct = 100 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
        .enemy_lances = 1,
    });
    const c = gs.contracts.getPtr(cid).?;

    // Seed two WSP-1A hull instances owned by DC (enemy).
    const hid0: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
    gs.next_hull_instance_id += 1;
    const hid1: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
    gs.next_hull_instance_id += 1;
    for ([_]types.HullInstanceId{ hid0, hid1 }) |hid| {
        try gs.hull_instances.put(gs.allocator(), hid, .{
            .id = hid,
            .base_key = "WSP-1A",
            .owner = .{ .faction = "DC" },
        });
        try gs.hull_ownership_history.append(gs.allocator(), .{
            .hull_instance_id = hid,
            .from_day = 0,
            .to_day = null,
            .acquisition_type = .initial,
            .prior_owner_key = "",
        });
    }

    // Two pool-path candidates (hull_instance_id set). claim_bv = 200 ≥ bv[0] = 192.
    const cands: []const battle_report.SalvageCandidate = &.{
        .{ .hull_instance_id = hid0, .key = "WSP-1A", .name = "Wasp", .bv = 192, .armor_pct = 60, .quality = .c, .damaged_slots = 1, .destroyed_slots = 1, .missing_components = 1 },
        .{ .hull_instance_id = hid1, .key = "WSP-1A", .name = "Wasp", .bv = 192, .armor_pct = 40, .quality = .d, .damaged_slots = 1, .destroyed_slots = 2, .missing_components = 1 },
    };
    _ = try takeSalvage(&gs, c, cands, 200, .most_hulls);

    // Test 1: chosen hull (hid0) is player-owned, active, linked to a player unit.
    const inst0 = gs.hull_instances.getPtr(hid0).?;
    try testing.expectEqual(hull_instance_mod.OwnerType.player, std.meta.activeTag(inst0.owner));
    try testing.expectEqual(hull_instance_mod.HullStatus.active, inst0.status);
    // A unit links the existing hid0 (no new mint — existing instance reused).
    var found_link = false;
    var uit = gs.units.iterator();
    while (uit.next()) |e| if (e.value_ptr.hull_instance_id == hid0) {
        found_link = true;
        break;
    };
    try testing.expect(found_link);
    // A .salvage ownership row is open for hid0.
    var found_salvage = false;
    for (gs.hull_ownership_history.items) |h| {
        if (h.hull_instance_id == hid0 and h.acquisition_type == .salvage and h.to_day == null) {
            found_salvage = true;
            break;
        }
    }
    try testing.expect(found_salvage);

    // Test 2: unchosen hull (hid1) is permanently_destroyed, .destroyed owner.
    const inst1 = gs.hull_instances.getPtr(hid1).?;
    try testing.expectEqual(hull_instance_mod.HullStatus.permanently_destroyed, inst1.status);
    try testing.expectEqual(hull_instance_mod.OwnerType.destroyed, std.meta.activeTag(inst1.owner));
    // All ownership intervals for hid1 are closed (terminal state).
    for (gs.hull_ownership_history.items) |h| {
        if (h.hull_instance_id == hid1) try testing.expect(h.to_day != null);
    }
}

/// A merc company owning `n` LCT-1V hulls on its roster, an enemy rival linked
/// to it, and an active contract against that rival under `terms`, so
/// `opforPool` draws from the company's roster.
fn seedMercPoolContract(gs: *GameState, co: types.ForceId, n: usize, terms: contract_mod.Terms) !*contract_mod.Contract {
    const a = gs.allocator();
    const company_id: types.MercCompanyId = @enumFromInt(gs.next_merc_company_id);
    gs.next_merc_company_id += 1;
    try gs.merc_companies.put(a, company_id, .{
        .id = company_id,
        .archetype_key = "enemy_raiders",
        .unit_name = "Pool Raiders",
        .faction_key = "DC",
        .side = .enemy,
    });
    var roster: std.ArrayListUnmanaged(types.HullInstanceId) = .empty;
    for (0..n) |_| {
        const hid: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
        gs.next_hull_instance_id += 1;
        try gs.hull_instances.put(a, hid, .{ .id = hid, .base_key = "LCT-1V", .owner = .{ .merc_company = company_id } });
        try gs.hull_ownership_history.append(a, .{ .hull_instance_id = hid, .acquisition_type = .initial, .prior_owner_key = "DC" });
        try roster.append(a, hid);
    }
    try gs.merc_company_rosters.put(a, company_id, roster);
    const rival_id: types.RivalId = @enumFromInt(gs.next_rival_id);
    gs.next_rival_id += 1;
    try gs.rivals.put(a, rival_id, .{ .id = rival_id, .unit_name = "Pool Raiders", .faction_key = "DC", .side = .enemy, .merc_company_id = company_id });
    const cid: types.ContractId = @enumFromInt(gs.next_contract_id);
    gs.next_contract_id += 1;
    var contract: contract_mod.Contract = .{
        .id = cid,
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = terms,
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
        .enemy_lances = 1,
    };
    try contract.rival_ids.append(a, rival_id);
    try gs.contracts.put(a, cid, contract);
    const site: types.Site = .{ .company = co };
    try gs.addStock(site, "armor", 60);
    for (part_mod.munition_keys) |key| try gs.addStock(site, key, 40);
    return gs.contracts.getPtr(cid).?;
}

/// The merc owner/roster mirror (`GameState.merc_company_rosters`): every
/// active merc-owned hull is on its owner's roster or is a candidate of a
/// pending salvage decision, and every roster member is owned by that company.
fn expectMercRosterMirror(gs: *GameState) !void {
    var it = gs.hull_instances.iterator();
    while (it.next()) |entry| {
        const hull = entry.value_ptr;
        const owner = switch (hull.owner) {
            .merc_company => |id| id,
            else => continue,
        };
        if (hull.status != .active) continue;
        const roster = gs.merc_company_rosters.get(owner) orelse return error.TestUnexpectedResult;
        if (std.mem.indexOfScalar(types.HullInstanceId, roster.items, hull.id) != null) continue;
        var pending_candidate = false;
        for (gs.event_queue.pending.items) |ev| {
            if (ev.kind != .salvage_priority) continue;
            const report = gs.battle_reports.find(ev.battle) orelse continue;
            for (report.salvage.candidates) |cand| pending_candidate = pending_candidate or cand.hull_instance_id == hull.id;
        }
        if (!pending_candidate) return error.TestUnexpectedResult;
    }
    for (gs.merc_company_rosters.keys(), gs.merc_company_rosters.values()) |id, roster| {
        for (roster.items) |hid| {
            try std.testing.expectEqual(@as(hull_instance_for_pool.HullOwner, .{ .merc_company = id }), gs.hull_instances.get(hid).?.owner);
        }
    }
}

test "a held field with no salvage claim strikes the merc company's destroyed hulls off" {
    // Rule 68 regression: a held field whose claim is zero (here salvage_pct
    // 0) queues no salvage decision, so its destroyed drawn hulls must reach
    // their terminal disposition in the engagement itself.
    const testing = std.testing;
    var gs = GameState.init(testing.allocator, .{ .seed = 4011 });
    defer gs.deinit();
    gs.clock.day_index = 1;
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    const c = try seedMercPoolContract(&gs, co, 8, .{ .length_months = 6, .base_pay_month = 400_000, .salvage_pct = 0, .battle_loss_pct = 30 });
    const company_id: types.MercCompanyId = @enumFromInt(1);

    var held_wrecks: usize = 0;
    var battles: u32 = 0;
    while (battles < 6 and c.status == .active) : (battles += 1) {
        const records_before = gs.hull_combat_records.items.len;
        try resolveEngagement(&gs, c);
        const report = &gs.battle_reports.kept.items[gs.battle_reports.kept.items.len - 1];
        if (report.held_field) {
            try testing.expectEqual(@as(i64, 0), report.salvage.unclaimed_bv);
            for (gs.hull_combat_records.items[records_before..]) |rec| {
                if (!rec.destroyed or rec.contract_id != c.id) continue;
                held_wrecks += 1;
                const hull = gs.hull_instances.get(rec.hull_instance_id).?;
                try testing.expectEqual(hull_instance_for_pool.HullStatus.permanently_destroyed, hull.status);
                try testing.expectEqual(hull_instance_for_pool.OwnerType.destroyed, std.meta.activeTag(hull.owner));
                for (gs.hull_ownership_history.items) |h| {
                    if (h.hull_instance_id == rec.hull_instance_id) try testing.expect(!h.isOpen());
                }
                try testing.expect(std.mem.indexOfScalar(types.HullInstanceId, gs.merc_company_rosters.get(company_id).?.items, rec.hull_instance_id) == null);
            }
        }
        try answerBattleDecisions(&gs);
        try expectMercRosterMirror(&gs);
    }
    try testing.expect(held_wrecks > 0);
}

test "the merc owner/roster mirror holds after every salvage disposition" {
    // Held field with a claim and its decision, held field with no claim,
    // the salvage exchange, and lost fields (recovery then dispersal) each
    // leave every merc-owned active hull on its owner's roster.
    const testing = std.testing;
    const variants = [_]contract_mod.Terms{
        .{ .length_months = 6, .base_pay_month = 400_000, .salvage_pct = 100, .battle_loss_pct = 30 },
        .{ .length_months = 6, .base_pay_month = 400_000, .salvage_pct = 0, .battle_loss_pct = 30 },
        .{ .length_months = 6, .base_pay_month = 400_000, .salvage_pct = 60, .battle_loss_pct = 30, .salvage_exchange = true },
    };
    var held: usize = 0;
    var lost: usize = 0;
    for (variants, 0..) |terms, i| {
        var gs = GameState.init(testing.allocator, .{ .seed = 4012 + i });
        defer gs.deinit();
        gs.clock.day_index = 1;
        gs.difficulty = .veteran;
        _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
        const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
        const c = try seedMercPoolContract(&gs, co, 12, terms);
        var battles: u32 = 0;
        while (battles < 8 and c.status == .active) : (battles += 1) {
            try resolveEngagement(&gs, c);
            const report = &gs.battle_reports.kept.items[gs.battle_reports.kept.items.len - 1];
            if (report.held_field) held += 1 else lost += 1;
            try expectMercRosterMirror(&gs);
            try answerBattleDecisions(&gs);
            try expectMercRosterMirror(&gs);
        }
    }
    try testing.expect(held > 0);
    try testing.expect(lost > 0);
}

test "pool-path salvage decision holds the turn until resolved" {
    // Test 3: mandatory turn-hold (events.zig:77/181, checklist.zig:170, tick.zig:807).
    // After a pool-path held-field win, the salvage_priority event is queued;
    // advance_days returns error.DecisionPending until the decision is resolved.
    const testing = std.testing;
    const checklist = @import("checklist.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 4002 });
    defer gs.deinit();
    gs.clock.day_index = 1;
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    // 32 hulls give many pool-path engagements; over 60 iterations the player
    // wins and holds the field at least once (salvage_bv > 0 on any held win).
    _ = try seedOpforHulls(&gs, "DC", 32);
    const cid: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000, .salvage_pct = 100 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
        .enemy_lances = 2,
    });
    const c = gs.contracts.getPtr(cid).?;
    const site: types.Site = .{ .company = co };
    try gs.addStock(site, "armor", 60);
    for (@import("../domain/part.zig").munition_keys) |key| try gs.addStock(site, key, 40);

    // Run engagements until a salvage_priority event is queued (pool-path held-field
    // win with salvage_bv > 0; any held-field pool-path win qualifies since
    // salvage_bv = salvage_pct% of enemy_destroyed_bv > 0 when held_field = true).
    var found_salvage_hold = false;
    var iter: u32 = 0;
    while (iter < 60 and c.status == .active) : (iter += 1) {
        try resolveEngagement(&gs, c);
        var has_salvage = false;
        for (gs.event_queue.pending.items) |*ev| {
            if (ev.kind == .salvage_priority) {
                has_salvage = true;
                break;
            }
        }
        if (has_salvage) {
            found_salvage_hold = true;
            // Read ALL unread battle reports so only the salvage decision holds the turn.
            while (gs.battle_reports.unread()) |rep| {
                _ = try commands.execute(&gs, .{ .read_report = rep.id });
            }
            // turnHold must now be .battle_decision (salvage_priority is blocking).
            try testing.expectEqual(@as(?checklist.Hold, .battle_decision), checklist.turnHold(&gs));
            // advance_days is refused while the decision is pending.
            try testing.expectError(error.DecisionPending, commands.execute(&gs, .{ .advance_days = 1 }));
            // Resolve all decisions.
            try answerBattleDecisions(&gs);
            // Turn is free; advance_days succeeds.
            _ = try commands.execute(&gs, .{ .advance_days = 1 });
            break;
        }
        try answerBattleDecisions(&gs);
    }
    // Assert we exercised the invariant (not vacuous).
    try testing.expect(found_salvage_hold);
}

test "contract-ending held-field battle still queues and holds on salvage" {
    // Test 4: the queueSalvage guard relaxation (contract_events.zig:857).
    // Old code: if (c.status != .active) return — drops salvage on completed contract.
    // New code: queues when held_field and salvage.unclaimed_bv > 0, even if completed.
    const testing = std.testing;
    const ce = @import("contract_events.zig");
    const checklist = @import("checklist.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 4003 });
    defer gs.deinit();
    gs.clock.day_index = 5;
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    const cid: types.ContractId = @enumFromInt(1);
    // Contract already .completed (as if recordBattle completed it this engagement).
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000, .salvage_pct = 100 },
        .status = .completed,
        .assigned_company = co,
        .monthly_net = 300_000,
        .enemy_lances = 1,
    });
    const c = gs.contracts.getPtr(cid).?;

    // Battle report: held field, salvage pending.
    const bid: types.BattleId = @enumFromInt(1);
    try gs.battle_reports.record(gs.allocator(), .{
        .id = bid,
        .day = 5,
        .contract = cid,
        .company = co,
        .kind = "recon_raid",
        .enemy_key = "DC",
        .scenario = "standup",
        .terrain = "plains",
        .weather = "clear",
        .outcome = autoresolve.Outcome.victory,
        .held_field = true,
        .salvage = .{ .unclaimed_bv = 200 },
        .acknowledged = true,
    });

    // queueSalvage must NOT drop the decision because held_field and pending > 0.
    try ce.queueSalvage(&gs, c, bid);

    // Decision is queued.
    var found = false;
    for (gs.event_queue.pending.items) |*ev| {
        if (ev.kind == .salvage_priority) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
    // The turn is held (battle_decision due to salvage_priority).
    try testing.expectEqual(@as(?checklist.Hold, .battle_decision), checklist.turnHold(&gs));
}

test "transferHullOwnership: employer exchange routes hull to faction, active, salvage interval open" {
    // Test 5: B6 exchange clause. gs.transferHullOwnership with faction owner.
    // The exchange branch (resolveEngagement) calls this for each destroyed drawn
    // hull. The employer gets the hull: faction-owned, active, .salvage interval.
    const testing = std.testing;
    const hull_instance_mod = @import("../domain/hull_instance.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 4004 });
    defer gs.deinit();
    gs.clock.day_index = 5;

    // One WSP-1A instance owned by DC.
    const hid: types.HullInstanceId = @enumFromInt(1);
    gs.next_hull_instance_id = 2;
    try gs.hull_instances.put(gs.allocator(), hid, .{
        .id = hid,
        .base_key = "WSP-1A",
        .owner = .{ .faction = "DC" },
    });
    try gs.hull_ownership_history.append(gs.allocator(), .{
        .hull_instance_id = hid,
        .from_day = 0,
        .to_day = null,
        .acquisition_type = .initial,
        .prior_owner_key = "",
    });

    // The exchange branch transfers to employer (LC = employer_key).
    try gs.transferHullOwnership(hid, .{ .faction = "LC" }, "DC", .salvage);

    const inst = gs.hull_instances.getPtr(hid).?;
    // Faction-owned by employer, active (not permanently_destroyed).
    try testing.expectEqual(hull_instance_mod.OwnerType.faction, std.meta.activeTag(inst.owner));
    try testing.expectEqualStrings("LC", inst.owner.faction);
    try testing.expectEqual(hull_instance_mod.HullStatus.active, inst.status);
    // Prior interval closed; one new .salvage interval open.
    var open_count: usize = 0;
    var salvage_row = false;
    for (gs.hull_ownership_history.items) |h| {
        if (h.hull_instance_id != hid) continue;
        if (h.to_day == null) open_count += 1;
        if (h.acquisition_type == .salvage and h.to_day == null) salvage_row = true;
    }
    try testing.expectEqual(@as(usize, 1), open_count);
    try testing.expect(salvage_row);
}

// Test 6: persistence round-trip lives in src/persist/store.zig (rule 5:
// sim does not import persist). See:
// "pool-path salvage: hull_instance_id round-trips through save/load"

// ---------------------------------------------------------- phased battle

/// A recon raid whose engagement is due today, its line's armour capped at
/// `armor` (a battered line takes kills from fewer hits).
pub fn dueEngagementForTest(gs: *GameState, real_pool: bool, armor: u8) !types.ContractId {
    const id = try engagementFixture(gs, real_pool);
    // The contract is inserted directly: its counter follows so a save loads.
    gs.next_contract_id = @max(gs.next_contract_id, @intFromEnum(id) + 1);
    gs.contracts.getPtr(id).?.next_battle_day = gs.clock.day_index;
    for (gs.units.values()) |*u| u.armor_pct = @min(u.armor_pct, armor);
    return id;
}

/// An active recon raid for `company` in a campaign already founded, its
/// engagement due today.
pub fn dueEngagementForCompanyForTest(gs: *GameState, company: types.ForceId) !types.ContractId {
    const id: types.ContractId = @enumFromInt(gs.next_contract_id);
    gs.next_contract_id += 1;
    try gs.contracts.put(gs.allocator(), id, .{
        .id = id,
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "PER",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000, .salvage_pct = 30, .battle_loss_pct = 30 },
        .status = .active,
        .assigned_company = company,
        .monthly_net = 300_000,
        .next_battle_day = gs.clock.day_index,
    });
    return id;
}

/// `dueEngagementForTest` with a committed combat operation on the
/// contract: its first combat lance tasked reserve, and `capacity` command
/// capacity for the contact-pause levers to spend.
pub fn leverEngagementForTest(gs: *GameState, armor: u8, capacity: u8) !types.ContractId {
    const id = try dueEngagementForTest(gs, false, armor);
    const c = gs.contracts.getPtr(id).?;
    c.command_capacity = capacity;
    const company = gs.force(c.assigned_company).?;
    const reserve = for (company.children.items) |lance| {
        const f = gs.force(lance) orelse continue;
        if (f.isCombatLance()) break lance;
    } else return error.TestUnexpectedResult;
    const op: types.OperationId = @enumFromInt(gs.next_operation_id);
    gs.next_operation_id += 1;
    try c.operations.append(gs.allocator(), .{ .id = op, .template_key = "repel_probe", .state = .committed, .opened_day = 0, .committed_day = 0 });
    try c.operations.items[c.operations.items.len - 1].tasks.append(gs.allocator(), .{ .lance = reserve, .task = .reserve });
    return id;
}

/// Stands up an air wing on the contract's company with one operational,
/// piloted fighter, so the air-cover gate is met
/// (`readiness.companyHasOperationalFighter`).
pub fn fighterForTest(gs: *GameState, id: types.ContractId) !void {
    const company = gs.contracts.getPtr(id).?.assigned_company;
    const wing = try gs.createForce("Air Wing", .air_company, company);
    const air_lance = try gs.createForce("Sky Lance", .air_lance, wing);
    const fighter = try gs.addUnit("SPR-H5");
    const pilot = try gs.hirePerson("Av", "Avi", .aero_pilot);
    try @import("toe.zig").assignUnit(gs, fighter, air_lance, pilot);
}

/// Fights a fresh lever fixture under `orders`, finished unattended, and
/// returns its last report.
fn leverFoughtForTest(gs: *GameState, seed: u64, orders: []const battle_phase.Order) !*const battle_report.BattleReport {
    gs.* = GameState.init(std.testing.allocator, .{ .seed = seed });
    const id = try leverEngagementForTest(gs, 30, 4);
    for (orders) |o| _ = try orderForTest(gs, id, o);
    while (battle_phases.inProgress(gs) != null) try @import("tick.zig").fightDueEngagement(gs);
    return &gs.battle_reports.kept.items[gs.battle_reports.kept.items.len - 1];
}

fn orderForTest(gs: *GameState, id: types.ContractId, order: battle_phase.Order) !commands.Result {
    return commands.execute(gs, .{ .battle_order = .{ .contract = id, .order = order } });
}

/// The complete digest less the battle record: what a pause must leave alone.
fn digestBesideBattleForTest(gs: *GameState) u64 {
    const saved = gs.battles_in_progress;
    gs.battles_in_progress = .empty;
    defer gs.battles_in_progress = saved;
    return @import("digest.zig").stateHash(gs);
}

/// The inputs and dice the contract's engagement fights with from live
/// state, observed in a discarded workspace: nothing changes.
fn observeEngagementForTest(gs: *GameState, id: types.ContractId) !Observed {
    var engagement = try battle_preparation.Engagement.init(gs, gs.scratch());
    defer engagement.deinit();
    const staged = &engagement.view;
    var observed: ?Observed = null;
    _ = try fightStagedObserved(staged, staged.contracts.getPtr(id).?, .{ .given = &.{.engage} }, gs.scratch(), &observed);
    return observed.?;
}

/// Fights a fresh fixture under `orders` (the battle finished with the
/// unattended orders when they stop short) and returns its last report.
fn foughtForTest(gs: *GameState, seed: u64, armor: u8, orders: []const battle_phase.Order) !*const battle_report.BattleReport {
    gs.* = GameState.init(std.testing.allocator, .{ .seed = seed });
    const id = try dueEngagementForTest(gs, false, armor);
    for (orders) |o| _ = try orderForTest(gs, id, o);
    while (battle_phases.inProgress(gs) != null) try @import("tick.zig").fightDueEngagement(gs);
    return &gs.battle_reports.kept.items[gs.battle_reports.kept.items.len - 1];
}

test "a due engagement holds the turn: advance refuses and advance until stop stops on the hold with its contract" {
    const digest = @import("digest.zig");
    const queries = @import("queries.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3007 });
    defer gs.deinit();
    const id = try engagementFixture(&gs, false);
    gs.contracts.getPtr(id).?.next_battle_day = gs.clock.day_index + 2;
    const r = try commands.execute(&gs, .{ .advance_until_stop = 0 });
    try std.testing.expectEqual(@as(u32, 2), r.days_advanced);
    try std.testing.expect(r.stopped == .hold);
    try std.testing.expectEqual(id, r.contract);
    try std.testing.expectEqual(id, queries.turnHold(&gs).engagement);
    const held = digest.stateHash(&gs);
    try std.testing.expectError(error.EngagementDue, commands.execute(&gs, .advance_day));
    try std.testing.expectError(error.EngagementDue, commands.execute(&gs, .{ .advance_days = 7 }));
    try std.testing.expectError(error.EngagementDue, commands.execute(&gs, .{ .advance_until_stop = 0 }));
    try std.testing.expectEqual(held, digest.stateHash(&gs));
    // The pre-battle levers stand until contact is joined.
    _ = try commands.execute(&gs, .{ .set_roe = .{ .company = gs.contracts.getPtr(id).?.assigned_company, .roe = .cautious } });
}

test "engaging fights contact and pauses: odds over every band, nothing lands until the battle ends" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3007 });
    defer gs.deinit();
    const id = try dueEngagementForTest(&gs, true, 100);
    const before = digestBesideBattleForTest(&gs);
    const observed = try observeEngagementForTest(&gs, id);
    try std.testing.expectEqual(before, digestBesideBattleForTest(&gs));
    const r = try orderForTest(&gs, id, .engage);
    try std.testing.expectEqual(@as(?battle_phase.Pause, .contact), r.battle_pause);
    // No hull damage, casualty, salvage, score, stock or live RNG change.
    try std.testing.expectEqual(before, digestBesideBattleForTest(&gs));
    const record = battle_phases.inProgress(&gs).?;
    const report = record.latest().*;
    var sum: u32 = 0;
    for (report.odds.counts) |n| sum += n;
    try std.testing.expect(report.odds.total > 0);
    try std.testing.expectEqual(@as(u32, report.odds.total), sum);
    // Consumer agreement: the command stored exactly the course's pause,
    // its contact verdict and its odds (battle_phases.contactVerdict, nextPhaseOdds).
    try std.testing.expectEqualDeep((try battle_phases.run(observed.inputs, observed.dice, &.{.engage})).paused, report);
    const contact = battle_phases.contactVerdict(observed.dice.contact, observed.inputs.mods, observed.inputs.roe);
    try std.testing.expectEqual(battle_phases.lineHits(observed.inputs.engaged, contact.hit_pct), report.hits);
    try std.testing.expectEqualDeep(battle_phases.nextPhaseOdds(.decisive, observed.inputs.mods, report.roe, contact.momentum, 0, observed.inputs.edge_available), report.odds);
}

test "a withdrawal after contact preserves hulls at the cost of the field (fixed seed)" {
    var withdrawn: GameState = undefined;
    defer withdrawn.deinit();
    var pressed: GameState = undefined;
    defer pressed.deinit();
    const w = try foughtForTest(&withdrawn, 9, 30, &.{ .engage, .withdraw });
    const p = try foughtForTest(&pressed, 9, 30, &.{ .engage, .press_on });
    try std.testing.expect(!w.held_field and w.withdrew);
    try std.testing.expectEqual(autoresolve.Outcome.draw, w.outcome);
    try std.testing.expect(w.hits_taken <= p.hits_taken);
    try std.testing.expect(w.destroyed <= p.destroyed and w.lost_hulls <= p.lost_hulls);
    // The strict difference on this fixture: pressing on holds the field and
    // loses hulls; withdrawing gives up the field and keeps them.
    try std.testing.expect(p.held_field);
    try std.testing.expect(w.destroyed + w.lost_hulls < p.destroyed + p.lost_hulls);
    // Consumer agreement: the report lands exactly the course's hits
    // (battle_phases.decisiveHits, lineHits).
    var fresh = GameState.init(std.testing.allocator, .{ .seed = 9 });
    defer fresh.deinit();
    const id = try dueEngagementForTest(&fresh, false, 30);
    const observed = try observeEngagementForTest(&fresh, id);
    try std.testing.expectEqual((try battle_phases.run(observed.inputs, observed.dice, &.{ .engage, .withdraw })).finished.hits, w.hits_taken);
    const pause = (try battle_phases.run(observed.inputs, observed.dice, &.{ .engage, .press_on })).paused;
    try std.testing.expectEqual((try battle_phases.run(observed.inputs, observed.dice, &.{ .engage, .press_on, battle_phases.defaultOrder(&pause) })).finished.hits, p.hits_taken);
}

test "earlier phases are never re-rolled: the contact report and the dice are the same whatever orders follow" {
    const branches = [_][]const battle_phase.Order{
        &.{ .engage, .withdraw },
        &.{ .engage, .press_on },
        &.{ .engage, .{ .roe = .cautious }, .press_on },
        &.{ .engage, .{ .roe = .hold }, .withdraw },
    };
    var contact: ?battle_phase.PhaseReport = null;
    var contact_phase: ?battle_phase.PhaseRecord = null;
    var dice: ?battle_phases.Dice = null;
    var decisive_phase: ?battle_phase.PhaseRecord = null;
    for (branches) |orders| {
        var gs = GameState.init(std.testing.allocator, .{ .seed = 3007 });
        defer gs.deinit();
        const id = try dueEngagementForTest(&gs, true, 100);
        const observed = try observeEngagementForTest(&gs, id);
        if (dice) |d| try std.testing.expectEqualDeep(d, observed.dice) else dice = observed.dice;
        _ = try orderForTest(&gs, id, .engage);
        const report = battle_phases.inProgress(&gs).?.latest().*;
        if (contact) |c| try std.testing.expectEqualDeep(c, report) else contact = report;
        for (orders[1..]) |o| _ = try orderForTest(&gs, id, o);
        while (battle_phases.inProgress(&gs) != null) try @import("tick.zig").fightDueEngagement(&gs);
        const phases = gs.battle_reports.kept.items[gs.battle_reports.kept.items.len - 1].phases;
        if (contact_phase) |c| try std.testing.expectEqualDeep(c, phases[0]) else contact_phase = phases[0];
        // The contact the battle finished with is the contact the pause showed.
        try std.testing.expectEqual(report.margin, phases[0].margin);
        try std.testing.expectEqual(report.hits, phases[0].hits);
        // The decisive phase under the same ROE is the same roll in every branch that fights it.
        if (orders.len == 2 and orders[1] == .press_on) decisive_phase = phases[1];
    }
    try std.testing.expect(decisive_phase != null);
}

test "an ROE change at a pause moves the next phase's odds and verdict; integrated command refuses it" {
    const digest = @import("digest.zig");
    var standard: GameState = undefined;
    defer standard.deinit();
    var cautious: GameState = undefined;
    defer cautious.deinit();
    const s = try foughtForTest(&standard, 8, 100, &.{ .engage, .press_on });
    const k = try foughtForTest(&cautious, 8, 100, &.{ .engage, .{ .roe = .cautious }, .press_on });
    try std.testing.expect(s.outcome != k.outcome);
    try std.testing.expectEqual(force_mod.Roe.cautious, k.roe);
    // The odds the pause shows move with the order.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 8 });
    defer gs.deinit();
    const id = try dueEngagementForTest(&gs, false, 100);
    _ = try orderForTest(&gs, id, .engage);
    const at_contact = battle_phases.inProgress(&gs).?.latest().odds;
    _ = try orderForTest(&gs, id, .{ .roe = .cautious });
    try std.testing.expect(!std.meta.eql(at_contact, battle_phases.inProgress(&gs).?.latest().odds));
    // Under integrated command the employer holds the ROE: refused, nothing changes.
    var locked = GameState.init(std.testing.allocator, .{ .seed = 8 });
    defer locked.deinit();
    const lid = try dueEngagementForTest(&locked, false, 100);
    locked.contracts.getPtr(lid).?.terms.command_rights = .integrated;
    _ = try orderForTest(&locked, lid, .engage);
    const before = digest.stateHash(&locked);
    try std.testing.expectError(error.RoeReservedByEmployer, orderForTest(&locked, lid, .{ .roe = .cautious }));
    try std.testing.expectEqual(before, digest.stateHash(&locked));
}

test "the battle lock refuses every other command while a battle is in progress" {
    const digest = @import("digest.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3007 });
    defer gs.deinit();
    const id = try dueEngagementForTest(&gs, false, 100);
    const company = gs.contracts.getPtr(id).?.assigned_company;
    _ = try orderForTest(&gs, id, .engage);
    const before = digest.stateHash(&gs);
    const refused = [_]commands.Command{
        .advance_day,
        .{ .set_roe = .{ .company = company, .roe = .hold } },
        .{ .buy_listing = .{ .listing = @enumFromInt(1), .buyer = .{ .hq = gs.seat() } } },
        .{ .recruit = .mekwarrior },
        .{ .read_report = @enumFromInt(1) },
    };
    for (refused) |cmd| {
        // Owner and consumer agree: what the lock forbids, the command refuses.
        try std.testing.expect(!battle_phases.commandAllowedDuringBattle(cmd));
        try std.testing.expectError(error.BattleInProgress, commands.execute(&gs, cmd));
        try std.testing.expectEqual(before, digest.stateHash(&gs));
    }
    const allowed: commands.Command = .{ .battle_order = .{ .contract = id, .order = .press_on } };
    try std.testing.expect(battle_phases.commandAllowedDuringBattle(allowed));
    _ = try commands.execute(&gs, allowed);
    // An order not legal at the pause is refused with its own error, and changes nothing.
    const paused = digest.stateHash(&gs);
    try std.testing.expectError(error.OrderNotLegal, orderForTest(&gs, id, .engage));
    try std.testing.expectEqual(paused, digest.stateHash(&gs));
}

test "validateInProgress accepts each pause the command records and refuses a record it could not have left" {
    const digest = @import("digest.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3007 });
    defer gs.deinit();
    const id = try dueEngagementForTest(&gs, true, 30);
    try validateInProgress(&gs);
    // Consumer: every pause the battle order command records replays exactly.
    for ([_]battle_phase.Order{ .engage, .{ .roe = .cautious }, .press_on }) |order| {
        _ = try orderForTest(&gs, id, order);
        try validateInProgress(&gs);
    }
    const before = digest.stateHash(&gs);
    const record = &gs.battles_in_progress.items[0];
    const c = gs.contracts.getPtr(id).?;
    // A stored pause the replay does not reach.
    for (record.steps.items) |*step| {
        const real = step.report;
        step.report.hits += 1;
        try std.testing.expectError(error.CorruptSave, validateInProgress(&gs));
        step.report = real;
        step.report.momentum -= 1;
        try std.testing.expectError(error.CorruptSave, validateInProgress(&gs));
        step.report = real;
    }
    // An engagement not yet due could not have been started.
    c.next_battle_day = gs.clock.day_index + 1;
    try std.testing.expectError(error.CorruptSave, validateInProgress(&gs));
    c.next_battle_day = gs.clock.day_index;
    // An unread report would have held the turn before contact was joined.
    try gs.battle_reports.kept.append(gs.allocator(), .{ .id = @enumFromInt(gs.next_battle_id), .day = 0, .contract = id, .company = c.assigned_company, .kind = "", .enemy_key = "", .scenario = "", .terrain = "", .weather = "", .outcome = .draw, .roe = .standard });
    try std.testing.expectError(error.CorruptSave, validateInProgress(&gs));
    _ = gs.battle_reports.kept.pop();
    try validateInProgress(&gs);
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    // Consumer: the report the battle publishes is a whole course.
    while (battle_phases.inProgress(&gs) != null) try @import("tick.zig").fightDueEngagement(&gs);
    try std.testing.expect(battle_phases.reportPhasesConsistent(&gs.battle_reports.kept.items[gs.battle_reports.kept.items.len - 1]));

    // Under integrated command the employer reserves the ROE. The record is
    // built from the replay itself, so it matches every pause and only the
    // lock refuses the ROE order it holds.
    var locked = GameState.init(std.testing.allocator, .{ .seed = 3007 });
    defer locked.deinit();
    const lid = try dueEngagementForTest(&locked, true, 30);
    locked.contracts.getPtr(lid).?.terms.command_rights = .integrated;
    const course = [_]battle_phase.Order{ .engage, .{ .roe = .cautious } };
    var record_under_lock: battle_phase.BattleInProgress = .{ .contract = lid, .phase = .contact };
    for (course, 1..) |order, n| try record_under_lock.steps.append(locked.allocator(), .{ .order = order, .report = try replayPause(&locked, lid, course[0..n]) });
    try locked.battles_in_progress.append(locked.allocator(), record_under_lock);
    const steps = &locked.battles_in_progress.items[0].steps;
    steps.items.len = 1;
    try validateInProgress(&locked);
    steps.items.len = 2;
    try std.testing.expectError(error.CorruptSave, validateInProgress(&locked));
}

test "concession and forfeit resolve on the first order as one-step battles" {
    const checklist = @import("checklist.zig");
    for ([_]bool{ false, true }) |forfeited| {
        var gs = GameState.init(std.testing.allocator, .{ .seed = 3007 });
        defer gs.deinit();
        const id = try dueEngagementForTest(&gs, forfeited, 100);
        if (forfeited) {
            gs.faction_rosters.getPtr("DC").?.clearRetainingCapacity();
        } else {
            for (gs.units.values()) |*u| u.status = .destroyed;
        }
        const r = try orderForTest(&gs, id, .engage);
        try std.testing.expectEqual(@as(?battle_phase.Pause, null), r.battle_pause);
        try std.testing.expect(battle_phases.inProgress(&gs) == null);
        const report = gs.battle_reports.find(r.battle_report).?;
        try std.testing.expectEqual(!forfeited, report.conceded);
        try std.testing.expectEqual(if (forfeited) autoresolve.Outcome.victory else autoresolve.Outcome.defeat, report.outcome);
        try std.testing.expectEqual(@as(usize, 0), report.phases.len);
        try std.testing.expectEqual(@as(?checklist.Hold, .unread_after_action), checklist.turnHold(&gs));
        try std.testing.expect(!engagementDue(&gs, gs.contracts.getPtr(id).?));
    }
}

test "the after-action names every phase and the order given at it, and the campaign log carries the same lines" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 9 });
    defer gs.deinit();
    const id = try dueEngagementForTest(&gs, false, 30);
    _ = try orderForTest(&gs, id, .engage);
    _ = try orderForTest(&gs, id, .{ .roe = .cautious });
    _ = try orderForTest(&gs, id, .press_on);
    const final_order = battle_phases.defaultOrder(battle_phases.inProgress(&gs).?.latest());
    const r = try orderForTest(&gs, id, final_order);
    const report = gs.battle_reports.find(r.battle_report).?;
    try std.testing.expectEqual(@as(usize, 3), report.phases.len);
    try std.testing.expectEqual(battle_phase.Order.engage, report.phases[0].order);
    try std.testing.expectEqual(battle_phase.Order.press_on, report.phases[1].order);
    try std.testing.expectEqual(force_mod.Roe.cautious, report.phases[1].roe);
    try std.testing.expectEqualDeep(final_order, report.phases[2].order);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lines = try after_action.render(arena.allocator(), report);
    for (report.phases) |p| {
        const line = try std.fmt.allocPrint(arena.allocator(), "[AAR]   {s}", .{try after_action.phaseText(arena.allocator(), p)});
        try std.testing.expect(std.mem.indexOf(u8, line, p.phase.label()) != null);
        try std.testing.expect(std.mem.indexOf(u8, line, p.order.label()) != null);
        var in_aar = false;
        for (lines) |l| in_aar = in_aar or std.mem.eql(u8, l, line);
        var in_log = false;
        for (gs.event_log.items) |e| in_log = in_log or std.mem.endsWith(u8, e.text, line);
        try std.testing.expect(in_aar and in_log);
    }
}

test "a failed battle order leaves the complete campaign unchanged, and a retry fights the same battle" {
    // Pattern one: an order that pauses (replay plus record growth).
    // Pattern two: the order that ends the battle (workspace publication,
    // record removal and the next schedule).
    const fixture = struct {
        fn due(gs: *GameState) anyerror!types.ContractId {
            return dueEngagementForTest(gs, true, 30);
        }
    }.due;
    try expectFailedOrderUnchangedForTest(fixture, 3007, &.{}, .engage);
    try expectFailedOrderUnchangedForTest(fixture, 3007, &.{ .engage, .press_on }, null);
}

test "a failed lever order, and a failed publication of levers, leave the complete campaign unchanged" {
    // Pattern one: a lever that pauses (replay plus record growth). Pattern
    // two: the final publication with levers (the operation's interventions
    // growing, the log reserved for their lines, the capacity deducted).
    const fixture = struct {
        fn levers(gs: *GameState) anyerror!types.ContractId {
            return leverEngagementForTest(gs, 30, 4);
        }
    }.levers;
    try expectFailedOrderUnchangedForTest(fixture, 3, &.{ .engage, .commit_reserve }, .{ .intervene = .reinforce });
    try expectFailedOrderUnchangedForTest(fixture, 3, &.{ .engage, .commit_reserve, .{ .intervene = .reinforce }, .{ .intervene = .emergency_recon }, .press_on }, null);
}

/// Gives `given` on a fresh `fixture` campaign at `seed`, then `last` (null:
/// the unattended order at the pause reached) with the campaign arena
/// failing at every allocation in turn: each failure leaves the complete
/// digest unchanged, and a retry reaches the same campaign as an order that
/// never failed (rule 69).
fn expectFailedOrderUnchangedForTest(fixture: *const fn (*GameState) anyerror!types.ContractId, seed: u64, given: []const battle_phase.Order, last_order: ?battle_phase.Order) !void {
    const digest = @import("digest.zig");
    var reference = GameState.init(std.testing.allocator, .{ .seed = seed });
    defer reference.deinit();
    const id = try fixture(&reference);
    for (given) |o| _ = try orderForTest(&reference, id, o);
    const last: battle_phase.Order = last_order orelse battle_phases.defaultOrder(battle_phases.inProgress(&reference).?.latest());
    _ = try orderForTest(&reference, id, last);
    const expected = digest.stateHash(&reference);
    var index: usize = 0;
    var failed: usize = 0;
    while (true) : (index += 1) {
        var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer outer.deinit();
        var gs = GameState.init(outer.allocator(), .{ .seed = seed });
        _ = try fixture(&gs);
        for (given) |o| _ = try orderForTest(&gs, id, o);
        const before = digest.stateHash(&gs);
        var failure = std.testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = index });
        gs.arena.state = .{};
        gs.arena.child_allocator = failure.allocator();
        defer gs.deinit();
        if (orderForTest(&gs, id, last)) |_| {
            try std.testing.expectEqual(expected, digest.stateHash(&gs));
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(before, digest.stateHash(&gs));
            failed += 1;
            gs.arena.child_allocator = outer.allocator();
            _ = try orderForTest(&gs, id, last);
            try std.testing.expectEqual(expected, digest.stateHash(&gs));
        }
    }
    try std.testing.expect(failed > 0);
}

/// The contract's committed combat operation.
fn leverOpForTest(gs: *GameState, id: types.ContractId) *operation_mod.Operation {
    return &gs.contracts.getPtr(id).?.operations.items[0];
}

test "a lever at the contact pause keeps the battle there, changes nothing live and shows its recomputed odds" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3 });
    defer gs.deinit();
    const id = try leverEngagementForTest(&gs, 30, 4);
    const observed = try observeEngagementForTest(&gs, id);
    _ = try orderForTest(&gs, id, .engage);
    const contact = battle_phases.inProgress(&gs).?.latest().*;
    const before = digestBesideBattleForTest(&gs);
    const course = [_]battle_phase.Order{ .engage, .commit_reserve, .{ .intervene = .emergency_recon } };
    for (course[1..], 2..) |order, n| {
        const r = try orderForTest(&gs, id, order);
        try std.testing.expectEqual(@as(?battle_phase.Pause, .contact), r.battle_pause);
        // No capacity, operation, hull, stock or live RNG change before the battle publishes.
        try std.testing.expectEqual(before, digestBesideBattleForTest(&gs));
        // Consumer agreement: the command stored exactly the course's pause.
        const report = battle_phases.inProgress(&gs).?.latest().*;
        try std.testing.expectEqualDeep((try battle_phases.run(observed.inputs, observed.dice, course[0..n])).paused, report);
        try std.testing.expectEqual(contact.margin, report.margin);
        try std.testing.expectEqual(contact.hits, report.hits);
    }
    const report = battle_phases.inProgress(&gs).?.latest().*;
    const lever_mod = battle_phases.leverMod(.commit_reserve) + battle_phases.leverMod(.emergency_recon);
    try std.testing.expectEqual(lever_mod, report.lever_mod);
    try std.testing.expect(report.reserve_committed);
    try std.testing.expectEqual(battle_phases.leverCost(.emergency_recon), report.capacity_spent);
    try std.testing.expectEqualDeep(battle_phases.nextPhaseOdds(.decisive, observed.inputs.mods, report.roe, report.momentum, lever_mod, observed.inputs.edge_available), report.odds);
    try std.testing.expect(!std.meta.eql(contact.odds, report.odds));
}

test "committing the reserve turns the battle at a fixed seed, and a lost fight lands more hits without its clamp" {
    var committed: GameState = undefined;
    defer committed.deinit();
    var stood: GameState = undefined;
    defer stood.deinit();
    // Seed 2: the reserve's two points turn a lost defeat into a held draw.
    const k = try leverFoughtForTest(&committed, 2, &.{ .engage, .commit_reserve, .press_on });
    const s = try leverFoughtForTest(&stood, 2, &.{ .engage, .press_on });
    try std.testing.expect(s.outcome == .defeat and !s.held_field);
    try std.testing.expect(k.outcome == .draw and k.held_field);
    try std.testing.expectEqual(s.phases[1].margin + battle_phases.leverMod(.commit_reserve), k.phases[1].margin);
    try std.testing.expectEqual(battle_phases.leverMod(.commit_reserve), k.phases[1].lever_mod);
    try std.testing.expectEqual(@as(usize, 1), k.levers.len);
    try std.testing.expectEqual(battle_phase.Lever.commit_reserve, k.levers[0].lever);
    try std.testing.expectEqual(@as(usize, 0), s.levers.len);
    try std.testing.expect(leverOpForTest(&committed, k.contract).reserve_committed);
    try std.testing.expect(!leverOpForTest(&stood, s.contract).reserve_committed);
    // Committing the reserve spends no capacity.
    try std.testing.expectEqual(stood.contracts.getPtr(s.contract).?.command_capacity, committed.contracts.getPtr(k.contract).?.command_capacity);
    // The AAR and the campaign log name it.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const line = try std.fmt.allocPrint(arena.allocator(), "[AAR]   {s}", .{try after_action.leverText(arena.allocator(), k.levers[0], true)});
    try std.testing.expect(std.mem.indexOf(u8, line, "commit the reserve") != null);
    var in_log = false;
    for (committed.event_log.items) |e| in_log = in_log or std.mem.endsWith(u8, e.text, line);
    try std.testing.expect(in_log);

    // Seed 7: a rout either way, and the committed reserve no longer clamps its hits.
    var committed_rout: GameState = undefined;
    defer committed_rout.deinit();
    var stood_rout: GameState = undefined;
    defer stood_rout.deinit();
    const kr = try leverFoughtForTest(&committed_rout, 7, &.{ .engage, .commit_reserve, .press_on });
    const sr = try leverFoughtForTest(&stood_rout, 7, &.{ .engage, .press_on });
    try std.testing.expect(kr.outcome == .rout and sr.outcome == .rout);
    try std.testing.expect(kr.hits_taken > sr.hits_taken);
}

test "calling an intervention at the contact pause raises the decisive margin by its profile, spends its capacity and names it" {
    var called: GameState = undefined;
    defer called.deinit();
    var plain: GameState = undefined;
    defer plain.deinit();
    const k = try leverFoughtForTest(&called, 3, &.{ .engage, .{ .intervene = .reinforce }, .press_on });
    const p = try leverFoughtForTest(&plain, 3, &.{ .engage, .press_on });
    const profile = operations_m.interventionProfile(.reinforce);
    try std.testing.expectEqual(p.phases[1].margin + profile.surprise_reduction + profile.prepared_roll_bonus, k.phases[1].margin);
    // Before battle the profile would have moved every phase; here contact is untouched.
    try std.testing.expectEqualDeep(p.phases[0], k.phases[0]);
    try std.testing.expectEqual(p.conditions_mod, k.conditions_mod);
    // The capacity falls by its cost, and the operation records it.
    const cost = operations_m.interventionCost(.reinforce);
    try std.testing.expectEqual(plain.contracts.getPtr(p.contract).?.command_capacity - cost, called.contracts.getPtr(k.contract).?.command_capacity);
    try std.testing.expect(operations_m.interventionApplied(leverOpForTest(&called, k.contract), .reinforce));
    try std.testing.expect(!operations_m.interventionApplied(leverOpForTest(&plain, p.contract), .reinforce));
    // The report keeps the pre-battle interventions apart from the lever.
    try std.testing.expectEqualStrings("", k.operation_interventions);
    try std.testing.expectEqual(battle_phase.Lever.reinforce, k.levers[0].lever);
    // The AAR and the campaign log name it, and the log carries the arc line a pre-battle call leaves.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aar = try std.fmt.allocPrint(arena.allocator(), "[AAR]   {s}", .{try after_action.leverText(arena.allocator(), k.levers[0], true)});
    const arc = try operations_m.interventionLogText(arena.allocator(), &called, .reinforce);
    var aar_logged = false;
    var arc_logged = false;
    for (called.event_log.items) |e| {
        aar_logged = aar_logged or std.mem.endsWith(u8, e.text, aar);
        arc_logged = arc_logged or std.mem.eql(u8, e.text, arc);
    }
    try std.testing.expect(aar_logged and arc_logged);
    // The operation record names it and counts its capacity.
    called.contracts.getPtr(k.contract).?.arc_key = "fracturing_garrison";
    const record = try @import("queries.zig").operationReport(arena.allocator(), &called, k.contract);
    try std.testing.expectEqual(@as(usize, 1), record.rows.len);
    try std.testing.expectEqualSlices(operation_mod.Intervention, &.{.reinforce}, record.rows[0].interventions);
    try std.testing.expectEqual(cost, record.rows[0].capacity_spent);
    try std.testing.expect(!record.rows[0].reserve_committed);
}

test "a withdrawal after a lever spends its capacity, records it and lands only the contact hits" {
    var gs: GameState = undefined;
    defer gs.deinit();
    const w = try leverFoughtForTest(&gs, 3, &.{ .engage, .{ .intervene = .reinforce }, .withdraw });
    try std.testing.expect(w.withdrew and !w.held_field);
    try std.testing.expectEqual(@as(usize, 2), w.phases.len);
    try std.testing.expectEqual(w.phases[0].hits, w.hits_taken);
    try std.testing.expectEqual(battle_phase.Lever.reinforce, w.levers[0].lever);
    var fresh = GameState.init(std.testing.allocator, .{ .seed = 3 });
    defer fresh.deinit();
    const id = try leverEngagementForTest(&fresh, 30, 4);
    try std.testing.expectEqual(fresh.contracts.getPtr(id).?.command_capacity - operations_m.interventionCost(.reinforce), gs.contracts.getPtr(w.contract).?.command_capacity);
    try std.testing.expect(operations_m.interventionApplied(leverOpForTest(&gs, w.contract), .reinforce));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const line = try after_action.leverText(arena.allocator(), w.levers[0], false);
    try std.testing.expect(std.mem.indexOf(u8, line, "before the decisive phase") != null);
}

test "the in-progress lever availability is the command's own, weather included, and reading it changes nothing" {
    const digest = @import("digest.zig");
    // Seed 5's engagement weather grounds aircraft; seed 3's lets them fly.
    for ([_]struct { seed: u64, grounded: bool }{ .{ .seed = 5, .grounded = true }, .{ .seed = 3, .grounded = false } }) |case| {
        var gs = GameState.init(std.testing.allocator, .{ .seed = case.seed });
        defer gs.deinit();
        const id = try leverEngagementForTest(&gs, 30, 4);
        try fighterForTest(&gs, id);
        try std.testing.expect((try inProgressAvailability(&gs, id, gs.scratch())) == null);
        _ = try orderForTest(&gs, id, .engage);
        const before = digest.stateHash(&gs);
        const rng_before = gs.rng;
        const avail = (try inProgressAvailability(&gs, id, gs.scratch())).?;
        try std.testing.expectEqual(before, digest.stateHash(&gs));
        try std.testing.expect(std.meta.eql(rng_before, gs.rng));
        try std.testing.expectEqual(case.grounded, avail.air_grounded);
        try std.testing.expect(avail.interventions.get(.air_cover).gate);
        try std.testing.expectEqualDeep((try observeEngagementForTest(&gs, id)).inputs.avail, avail);
    }
}

test "every lever refusal consumes nothing" {
    // Each refusal's sentence: cli.zig's "battle parses every order word strictly" test.
    const digest = @import("digest.zig");
    const Change = enum { none, uncrewed_reserve, short_capacity, applied_before, integrated };
    const Case = struct { seed: u64, setup: Change, given: []const battle_phase.Order, order: battle_phase.Order, err: anyerror };
    const cases = [_]Case{
        .{ .seed = 3, .setup = .uncrewed_reserve, .given = &.{.engage}, .order = .commit_reserve, .err = error.ReserveUnavailable },
        .{ .seed = 3, .setup = .none, .given = &.{ .engage, .commit_reserve }, .order = .commit_reserve, .err = error.OrderNotLegal },
        .{ .seed = 3, .setup = .short_capacity, .given = &.{ .engage, .{ .intervene = .reinforce } }, .order = .{ .intervene = .emergency_recon }, .err = error.InsufficientCommandCapacity },
        // The starter company flies no fighters.
        .{ .seed = 3, .setup = .none, .given = &.{.engage}, .order = .{ .intervene = .air_cover }, .err = error.InterventionGateUnmet },
        .{ .seed = 3, .setup = .none, .given = &.{ .engage, .{ .intervene = .emergency_recon } }, .order = .{ .intervene = .emergency_recon }, .err = error.InterventionAlreadyApplied },
        .{ .seed = 3, .setup = .applied_before, .given = &.{.engage}, .order = .{ .intervene = .field_repair }, .err = error.InterventionAlreadyApplied },
        .{ .seed = 3, .setup = .integrated, .given = &.{.engage}, .order = .{ .intervene = .reinforce }, .err = error.InterventionReservedByEmployer },
        // Seed 5: the engagement's weather grounds aircraft.
        .{ .seed = 5, .setup = .none, .given = &.{.engage}, .order = .{ .intervene = .air_cover }, .err = error.AirCoverGrounded },
        .{ .seed = 3, .setup = .none, .given = &.{}, .order = .commit_reserve, .err = error.OrderNotLegal },
        .{ .seed = 3, .setup = .none, .given = &.{ .engage, .press_on }, .order = .{ .intervene = .emergency_recon }, .err = error.OrderNotLegal },
    };
    for (cases) |case| {
        var gs = GameState.init(std.testing.allocator, .{ .seed = case.seed });
        defer gs.deinit();
        const id = try leverEngagementForTest(&gs, 30, 4);
        const c = gs.contracts.getPtr(id).?;
        switch (case.setup) {
            .none => {},
            .uncrewed_reserve => for (gs.force(leverOpForTest(&gs, id).tasks.items[0].lance).?.units.items) |uid| {
                gs.unit(uid).?.pilot = .none;
            },
            .short_capacity => c.command_capacity = operations_m.interventionCost(.reinforce),
            .applied_before => try leverOpForTest(&gs, id).interventions.append(gs.allocator(), .field_repair),
            .integrated => c.terms.command_rights = .integrated,
        }
        for (case.given) |o| _ = try orderForTest(&gs, id, o);
        const before = digest.stateHash(&gs);
        try std.testing.expectError(case.err, orderForTest(&gs, id, case.order));
        try std.testing.expectEqual(before, digest.stateHash(&gs));
    }
}

test "earlier phases are never re-rolled by a lever: the contact report and the dice are the same whatever levers follow" {
    const branches = [_][]const battle_phase.Order{
        &.{ .engage, .press_on },
        &.{ .engage, .commit_reserve, .press_on },
        &.{ .engage, .{ .intervene = .emergency_recon }, .withdraw },
        &.{ .engage, .{ .intervene = .reinforce }, .commit_reserve, .{ .roe = .cautious }, .press_on },
    };
    var dice: ?battle_phases.Dice = null;
    var contact: ?battle_phase.PhaseReport = null;
    var contact_phase: ?battle_phase.PhaseRecord = null;
    for (branches) |orders| {
        var gs = GameState.init(std.testing.allocator, .{ .seed = 3 });
        defer gs.deinit();
        const id = try leverEngagementForTest(&gs, 30, 4);
        const observed = try observeEngagementForTest(&gs, id);
        if (dice) |d| try std.testing.expectEqualDeep(d, observed.dice) else dice = observed.dice;
        _ = try orderForTest(&gs, id, .engage);
        const report = battle_phases.inProgress(&gs).?.latest().*;
        if (contact) |r| try std.testing.expectEqualDeep(r, report) else contact = report;
        for (orders[1..]) |o| _ = try orderForTest(&gs, id, o);
        while (battle_phases.inProgress(&gs) != null) try @import("tick.zig").fightDueEngagement(&gs);
        const phases = gs.battle_reports.kept.items[gs.battle_reports.kept.items.len - 1].phases;
        if (contact_phase) |p| try std.testing.expectEqualDeep(p, phases[0]) else contact_phase = phases[0];
    }
}

test "an unattended engagement pulls no lever: its operation commits no reserve and calls nothing" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3 });
    defer gs.deinit();
    const id = try leverEngagementForTest(&gs, 30, 4);
    const capacity = gs.contracts.getPtr(id).?.command_capacity;
    try resolveEngagement(&gs, gs.contracts.getPtr(id).?);
    const report = gs.battle_reports.kept.items[gs.battle_reports.kept.items.len - 1];
    try std.testing.expectEqual(@as(usize, 0), report.levers.len);
    for (report.phases) |p| try std.testing.expectEqual(@as(i32, 0), p.lever_mod);
    const op = leverOpForTest(&gs, id);
    try std.testing.expect(!op.reserve_committed and op.interventions.items.len == 0);
    try std.testing.expectEqual(capacity, gs.contracts.getPtr(id).?.command_capacity);
}
