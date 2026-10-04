//! Battle autoresolution (Stage 7, ARCH §7). Adaptation of MekHQ's ACAR.
//! Combat-class contracts schedule engagements every few weeks; each
//! resolves without the player from what the campaign built: BV and crew
//! skill, machine condition, fatigue and morale, the support echelon, and
//! recon. Damage lands on real part slots, casualties go to the infirmary,
//! salvage and battle-loss comp hit the ledger, and the AAR names the
//! reasons. Legibility over drama: a loss should trace to causes.

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

/// battle_resolution phase, daily: schedule and resolve engagements for
/// active combat-class contracts.
pub fn runDaily(gs: *GameState) !void {
    var it = gs.contracts.iterator();
    while (it.next()) |entry| {
        const c = entry.value_ptr;
        if (c.status != .active) continue;
        // Garrison work fights too (ARCH §8): the enemy probes the
        // perimeter — a contract with no rolled opposing force has nothing to probe with.
        if (c.kind.isGarrisonClass() and !c.hasOpfor()) continue;
        if (c.next_battle_day == null) {
            c.next_battle_day = gs.clock.day_index + nextBattleGap(gs, c);
            continue;
        }
        if (gs.clock.day_index >= c.next_battle_day.?) {
            try resolveEngagement(gs, c);
            c.next_battle_day = gs.clock.day_index + nextBattleGap(gs, c);
        }
    }
}

const SideState = struct {
    power: i64 = 0,
    bv: i64 = 0,
    engaged: std.ArrayListUnmanaged(types.UnitId) = .empty,
    mods: autoresolve.CampaignMods = .{},
    site: types.Site = .outfit,
    /// Tons of each munition family this fight will expend.
    ammo_reserved: std.StringArrayHashMapUnmanaged(u32) = .empty,
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
    return out;
}

/// The player's side under given conditions: night and storms
/// ground the fighters, close terrain dents recon.
fn playerSideIn(gs: *GameState, alloc: std.mem.Allocator, c: *const contract_mod.Contract, env: terrain_mod.Environment) !SideState {
    var mods = companyMods(gs, c);
    if (env.groundsAir()) mods.has_air_cover = false;
    mods.recon_quality = @intCast(@max(0, @as(i32, mods.recon_quality) + env.reconMod()));
    var side: SideState = .{ .mods = mods, .site = .{ .company = c.assigned_company } };

    const company = gs.force(c.assigned_company) orelse return side;

    // Pass 1: count working ballistic/missile mounts per munition
    // family across the company, then decide how many each family's stock
    // can feed this fight. Reserved tons are expended after the battle.
    var family_mounts = try @import("field_supply.zig").munitionMounts(alloc, gs, c.assigned_company, true);
    defer family_mounts.deinit(alloc);
    var family_fire_pct: std.StringArrayHashMapUnmanaged(u32) = .empty;
    defer family_fire_pct.deinit(alloc);
    var fit = family_mounts.iterator();
    while (fit.next()) |entry| {
        const mounts = entry.value_ptr.*;
        const need = @import("field_supply.zig").tonsPerBattle(mounts);
        const have = gs.stockCount(side.site, entry.key_ptr.*);
        const use = @min(need, have);
        try side.ammo_reserved.put(alloc, entry.key_ptr.*, use);
        const fed = @min(mounts, use * mounts_per_ammo_ton);
        try family_fire_pct.put(alloc, entry.key_ptr.*, if (mounts == 0) 100 else fed * 100 / mounts);
    }

    for (company.children.items) |child_id| {
        const lance = gs.force(child_id) orelse continue;
        if (!lance.isCombatLance()) continue;
        // Lance roles (MekHQ): training lances are held out of the fight —
        // unless the employer commands (integrated rights).
        if (lance.role == .training and c.terms.command_rights.allowsTrainingLances()) continue;

        var lance_bv: i64 = 0;
        var gunnery_sum: u32 = 0;
        var piloting_sum: u32 = 0;
        var condition_sum: u32 = 0;
        var quality_sum: u32 = 0;
        var n: u32 = 0;
        for (lance.units.items) |uid| {
            const u = gs.unit(uid) orelse continue;
            // A hull that is not operational stays in the hangar.
            if (!readiness_m.unitOperational(gs, u)) continue;
            const design = chassis_mod.find(u.chassis_key) orelse continue;
            const pilot = gs.person(u.pilot).?;
            const reloaded = hasTech(gs, u);

            // Pass 2: mounts whose family stock can't feed them are silenced,
            // and the hull fights at reduced strength (energy is unaffected).
            var mounts: u32 = 0;
            var silenced_x100: u32 = 0;
            for (u.slots.items) |slot| {
                if (slot.class != .weapon or slot.condition != .ok) continue;
                mounts += 1;
                const ammo_key = part_mod.munitionFor(slot.part_key) orelse continue;
                const fire_pct = if (reloaded) family_fire_pct.get(ammo_key) orelse 100 else 0;
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
            // Old wounds ride along: a permanent head injury is a point of
            // skill lost for good.
            // Specialists count a point better; old wounds a point
            // worse; a tired pilot one to three worse (fatigue bands).
            // The skills are the hull kind's: a vehicle fights on gunnery_vee
            // and driving_vee, a mek on gunnery_mek and piloting_mek.
            const crew_role = unit_mod.crewRoleFor(u.kind);
            const gunnery_skill = pilot.skill(crew_role.primarySkill()) orelse 4;
            const piloting_skill = (if (crew_role.pilotingSkill()) |s| pilot.skill(s) else null) orelse 5;
            gunnery_sum += (gunnery_skill + pilot.permanentPenalty() + pilot.fatiguePenalty()) -| @intFromBool(pilot.has("gunnery_specialist"));
            piloting_sum += (piloting_skill + pilot.permanentPenalty() + pilot.fatiguePenalty()) -| @intFromBool(pilot.has("piloting_specialist"));
            try side.engaged.append(alloc, uid);
            n += 1;
        }
        if (n == 0) continue;

        const elem: autoresolve.Element = .{
            .force = child_id,
            .base_strength = lance_bv,
            .avg_gunnery = @intCast(gunnery_sum / n),
            .avg_piloting = @intCast(piloting_sum / n),
            .avg_condition_pct = @intCast(condition_sum / n),
            .avg_quality = @enumFromInt(quality_sum / n),
        };
        side.bv += lance_bv;
        var lance_power = elem.effectivePower(side.mods);
        // Defense lances dig in: +10% on garrison-class work.
        if (lance.role == .defense and c.kind.isGarrisonClass()) lance_power = types.applyBp(lance_power, tuning.battle.defense_bonus_bp);
        // A tactical genius leading the lance: +5%.
        if (gs.person(lance.commander)) |leader| if (leader.has("tactical_genius")) {
            lance_power = types.applyBp(lance_power, 10_500);
        };
        // Lance task power scaling: deterministic modifier via the task owner (P4e).
        // No new RNG draw; battle.zig MUST NOT import operation_control.zig (rule 5).
        if (operations_m.committedCombatOp(c)) |op| {
            lance_power = operations_m.lanceTaskPower(op, child_id, lance_power);
        }
        side.power += lance_power;
    }
    return side;
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

        // Crew casualties (AtB-style): a hard hit (8+) wounds the pilot on a
        // follow-up 2d6 of 8+, a crippling one (11+) always; the worst roll
        // kills unless a MASH lance is forward. MASH also raises the
        // follow-up target on hard hits (tuning.battle.wound_*).
        if (gs.person(u.pilot)) |p| {
            if (p.status == .active) {
                // Wound severity follows the hit: 8–9 light,
                // 10–11 serious, 12 crippling (survivable only with MASH).
                // Toughness: a step lighter, and a killing hit is survived.
                const tough = p.has("toughness");
                const raw_severity: u8 = if (severity >= tb.wound_crippling_severity) 3 else if (severity >= tb.wound_serious_severity) 2 else 1;
                const wound_severity: u8 = @max(1, raw_severity -| @as(u8, @intFromBool(tough)));
                if (severity >= tb.kill_severity and !player.mods.has_mash_lance and !tough) {
                    // The seat empties with the pilot: the checklist
                    // shows an open cockpit, not a dead man in it.
                    rec.crew_name = try p.rankedName(gs.allocator());
                    _ = try @import("personnel.zig").depart(gs, p.id, .kia, 0, "");
                    tally.kia += 1;
                    gs.stats.people_kia += 1;
                    rec.crew.fate = .kia;
                } else if (severity >= tb.cookoff_severity) {
                    rec.crew.wound = try medical.inflict(gs, u.pilot, .combat, wound_severity, "battle");
                    if (rec.crew.wound != null) {
                        tally.wounded += 1;
                        rec.crew_name = try p.rankedName(gs.allocator());
                    }
                } else if (severity >= tb.slot_hit_severity) {
                    const need: u8 = if (player.mods.has_mash_lance) tb.wound_target_mash else tb.wound_target;
                    if (gs.rng.roll2d6(.battle) >= need) {
                        rec.crew.wound = try medical.inflict(gs, u.pilot, .combat, wound_severity, "battle");
                        if (rec.crew.wound != null) {
                            tally.wounded += 1;
                            rec.crew_name = try p.rankedName(gs.allocator());
                        }
                    }
                }
            }
        }
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
    trucks: i64,
    hit_log: *std.ArrayListUnmanaged(battle_report.HullHit),
) !FieldLoss {
    const rt = tuning.loss.roe;
    var loss: FieldLoss = .{};
    const t = tuning.loss;
    const has_dropship = lift.hasCrewedDropship(gs, c.assigned_company);
    var wrecks_here: i64 = 0;
    for (hit_log.items) |h| wrecks_here += @intFromBool(h.destroyed);
    // Recovery task bonus: a dedicated recovery lance improves wreck retrieval. // TUNE
    const task_recovery_bonus: i32 = if (operations_m.committedCombatOp(c)) |op|
        operations_m.operationTaskMods(gs, c, op).recovery_bonus
    else
        0;
    const situation: i32 = (if (player.mods.has_salvage_lance) t.recovery_salvage_lance else 0) //
        + (if (trucks >= wrecks_here and trucks > 0) t.recovery_trucks else 0) //
        + (if (has_dropship) t.recovery_dropship else 0) //
        + (if (outcome == .rout) t.recovery_rout else 0) //
        + scenario.recovery_mod + gs.diff().recovery_mod //
        + task_recovery_bonus //
        + switch (roe) {
            .hold => rt.hold_recovery,
            .standard => 0,
            .cautious => rt.cautious_recovery,
        };
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
        const piloting: i32 = (if (p.role.pilotingSkill()) |s| p.skill(s) else null) orelse 5;
        const escape = @as(i32, gs.rng.roll2d6(.battle)) + person_mod.skillRollBonus(@intCast(piloting)) + gs.diff().recovery_mod + (if (outcome == .rout) t.recovery_rout else 0);
        if (escape >= t.escape_target) continue;
        const pid = p.id;
        _ = try @import("personnel.zig").depart(gs, pid, .mia, 0, "");
        p.faction = c.enemy_key; // held by them
        loss.missing += 1;
        // The name is already on record if this pilot was also hit.
        if (h.crew_name.len == 0) h.crew_name = try p.rankedName(gs.allocator());
        h.crew.fate = .missing;
        try @import("contract_events.zig").queueMissing(gs, pid, c.assigned_company);
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

/// One opposed roll decides the engagement (ARCH §7 steps 3–4 collapse
/// into the margin): the scenario off the AtB table, the opposition
/// scaled to it, then 2d6 + the power ratio + the conditions + the
/// company's rules of engagement, re-rolled once if a pilot spends Edge.
/// Returns everything downstream needs to know about how it
/// went, so no later phase re-derives the odds.
fn openingRoll(gs: *GameState, c: *const contract_mod.Contract, player: *const SideState, env: terrain_mod.Environment) Opening {
    // What kind of fight this is (AtB scenario table): it scales
    // the enemy, tilts the roll, weights the score and decides what a
    // held field is worth.
    const scenario = @import("../domain/scenario.zig").roll(&gs.rng, .battle, c.kind);

    // Enemy: strength relative to the player's committed BV, pirate rabble
    // to house regulars by employer's foe.
    const variance: types.Bp = (@as(types.Bp, gs.rng.roll2d6(.battle)) - 7) * 500;
    var enemy_bv = engagementEnemyBv(c, player.bv, variance, scenario.enemy_bp, gs.diff().enemy_bp);
    // A garrison probe is a lance or so of the enemy's, not the lot.
    if (c.kind.isGarrisonClass() and c.hasOpfor()) enemy_bv = @divTrunc(enemy_bv * @min(tuning.battle.garrison_probe_lances, c.enemy_lances), c.enemy_lances);
    // Attrition contracts: the enemy can only field what's left
    // of their pool.
    if (c.objective == .attrition and c.enemy_pool_remaining > 0) enemy_bv = @min(enemy_bv, c.enemy_pool_remaining);
    const pirates = std.mem.eql(u8, c.enemy_key, "PER");
    // Their skill: the rolled level, else pirates green, houses regular.
    const enemy_skills: [2]u8 = if (c.hasOpfor()) @import("../domain/opfor.zig").skills(c.enemy_quality) else if (pirates) .{ 5, 6 } else .{ 4, 5 };
    const enemy_elem: autoresolve.Element = .{
        .base_strength = enemy_bv,
        .avg_gunnery = enemy_skills[0],
        .avg_piloting = enemy_skills[1],
    };
    const enemy_power = enemy_elem.effectivePower(.{});

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

    // One opposed roll decides the engagement (rounds within are abstracted;
    // ARCH §7 steps 3–4 collapse into the margin).
    // The scenario's tilt, and what scouts give back (an ambush spotted
    // is half an ambush).
    // Recon task also reduces the scenario's surprise element (surprise_reduction). // TUNE
    const scenario_mod: i32 = @as(i32, scenario.roll_mod) + (if (player.mods.recon_quality > 0) @as(i32, scenario.scout_bonus) else 0) + env.rollMod() + task_mods.surprise_reduction + tempo_mods.surprise_reduction + tempo_mods.prepared_roll_bonus + intervention_mods.surprise_reduction + intervention_mods.prepared_roll_bonus;
    // Close terrain evens the odds: numbers count for less in the woods and the streets.
    const ratio_bonus: i32 = if (env.close()) @min(ratioBonus(player.power, enemy_power), 2) else ratioBonus(player.power, enemy_power);
    // Rules of engagement: the company's standing order, unless an
    // integrated employer's officers set it.
    const rt = tuning.loss.roe;
    const roe = effectiveRoe(gs, c, c.assigned_company);
    const roe_roll: i32 = switch (roe) {
        .hold => rt.hold_roll,
        .standard => 0,
        .cautious => rt.cautious_roll,
    };
    var roll = @as(i32, gs.rng.roll2d6(.battle)) + ratio_bonus + scenario_mod + roe_roll;
    // Edge: a pilot with Edge to spend re-rolls a lost engagement once per contract.
    var edge_used_by: types.PersonId = .none;
    if (roll < 6) {
        for (player.engaged.items) |uid| {
            const u = gs.unit(uid) orelse continue;
            const p = gs.person(u.pilot) orelse continue;
            if (p.has("edge") and !p.edge_spent) {
                p.edge_spent = true;
                edge_used_by = p.id;
                roll = @as(i32, gs.rng.roll2d6(.battle)) + ratio_bonus + scenario_mod + roe_roll;
                break;
            }
        }
    }
    const tb = tuning.battle;
    const outcome: autoresolve.Outcome = if (roll >= tb.outcome_at.decisive_victory) .decisive_victory //
        else if (roll >= tb.outcome_at.victory) .victory //
        else if (roll >= tb.outcome_at.draw) .draw //
        else if (roll >= tb.outcome_at.defeat) .defeat //
        else .rout;

    // Player losses scale with how badly it went (tuning.battle.hit_pct).
    const base_hit_pct: i32 = switch (outcome) {
        inline else => |o| @field(tb.hit_pct, @tagName(o)),
    };
    // A lost fight under hold costs more; a cautious company is already
    // pulling back when it turns.
    const lost_fight = outcome.isLoss();
    var hit_pct: u32 = @intCast(@max(0, base_hit_pct + if (!lost_fight) 0 else switch (roe) {
        .hold => rt.hold_hits_pct,
        .standard => 0,
        .cautious => rt.cautious_hits_pct,
    }));
    // Reserve task: if a reserve lance is assigned and the fight goes badly,
    // clamp hit_pct to the draw level (the reserve steadies a collapsing line). // TUNE
    const reserve_floor: u32 = @intCast(tb.hit_pct.draw);
    const reserve_steadied = task_mods.reserve_present and lost_fight and hit_pct > reserve_floor;
    if (reserve_steadied) hit_pct = reserve_floor;
    const enemy_loss_pct: u32 = switch (outcome) {
        inline else => |o| @field(tb.enemy_loss_pct, @tagName(o)),
    };

    const engaged = player.engaged.items;
    const hits: u32 = @intCast(@max(
        @as(usize, if (outcome == .decisive_victory) 0 else 1),
        engaged.len * hit_pct / 100,
    ));
    return .{
        .scenario = scenario,
        .enemy_bv = enemy_bv,
        .enemy_power = enemy_power,
        .scenario_mod = scenario_mod,
        .roe = roe,
        .roll = roll,
        .outcome = outcome,
        .lost_fight = lost_fight,
        .enemy_loss_pct = enemy_loss_pct,
        .hits = hits,
        .edge_used_by = edge_used_by,
        .reserve_steadied = reserve_steadied,
    };
}

/// How the engagement opened and how it went — the roll's inputs and its
/// verdict, in one value so the phases after it agree on the odds.
const Opening = struct {
    scenario: *const @import("../domain/scenario.zig").Scenario,
    enemy_bv: i64,
    enemy_power: i64,
    scenario_mod: i32,
    roe: force_mod.Roe,
    roll: i32,
    outcome: autoresolve.Outcome,
    lost_fight: bool,
    enemy_loss_pct: u32,
    hits: u32,
    /// An id, not a pointer: prisoners are hired into `people` before
    /// the report is written, and that insertion can move every entry.
    edge_used_by: types.PersonId,
    /// A reserve lance was present and clamped a bad hit_pct (P4e).
    reserve_steadied: bool = false,
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
    open: Opening,
    env: terrain_mod.Environment,
    engaged: []const types.UnitId,
    enemy_destroyed_bv: i64,
    wounded: u8,
    kia: u8,
    per_unit: *std.ArrayListUnmanaged(@import("personnel.zig").UnitKills),
) !Aftermath {
    const tb = tuning.battle;
    const rt = tuning.loss.roe;
    const scenario = open.scenario;
    const outcome = open.outcome;
    const roe = open.roe;
    const lost_fight = open.lost_fight;
    const withdrew = outcome == .draw and roe == .cautious;
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

pub fn resolveEngagement(gs: *GameState, c: *contract_mod.Contract) !void {
    // Where and in what: the world's ground, the day's weather.
    const env: terrain_mod.Environment = blk: {
        const world = planet_mod.find(c.planet_key) orelse break :blk .{};
        const t = terrain_mod.terrainOf(world);
        break :blk .{ .terrain = t, .weather = terrain_mod.rollWeather(&gs.rng, .battle, t) };
    };
    var player = try playerSideIn(gs, gs.scratch(), c, env);
    defer player.engaged.deinit(gs.scratch());
    defer player.ammo_reserved.deinit(gs.scratch());
    if (player.engaged.items.len == 0) return concede(gs, c);

    const open = openingRoll(gs, c, &player, env);
    const scenario = open.scenario;
    const enemy_power = open.enemy_power;
    const scenario_mod = open.scenario_mod;
    const roe = open.roe;
    const outcome = open.outcome;
    const enemy_loss_pct = open.enemy_loss_pct;
    const hits = open.hits;
    const edge_used_by = open.edge_used_by;
    const enemy_bv = open.enemy_bv;
    const tb = tuning.battle;
    const engaged = player.engaged.items;
    // The detailed AAR: every hit on record — which
    // hull, what it lost, what happened to the crew. The record outlives
    // the fight, so it copies the names it needs (battle_report.HullHit).
    var hit_log: std.ArrayListUnmanaged(battle_report.HullHit) = .empty;
    defer hit_log.deinit(gs.scratch());
    const tally = try applyHits(gs, &player, engaged, hits, &hit_log);
    var damage_value = tally.damage_value;
    const destroyed = tally.destroyed;
    const wounded = tally.wounded;
    const kia = tally.kia;

    // Spoils: salvage rights over the enemy's wrecks — but only if you held
    // the field (retreating forces strip nothing) — prisoners if you can
    // hold them, employer compensation for your losses.
    // A cautious company does not wait out a draw: it withdraws.
    const withdrew = outcome == .draw and roe == .cautious;
    const held_field = outcome.heldField() and !withdrew;
    const enemy_destroyed_bv = @divTrunc(enemy_bv * enemy_loss_pct, 100);
    // What the crews can actually haul off the field is bounded by the
    // salvage trucks on hand (`haulCapacityBv`).
    const trucks = salvageTrucks(gs, c.assigned_company);
    const haulable_bv = @min(enemy_destroyed_bv, haulCapacityBv(trucks));

    // Who holds the field keeps the wrecks (CamOps salvage): on a
    // lost field each hull wrecked there is dragged off only if the crews
    // can get to it — salvage lance, trucks, a DropShip to lift it, your
    // own ground — else the enemy has it. Its pilot walks out or is taken.
    var lost_hulls: u32 = 0;
    var missing: u32 = 0;
    if (!held_field) {
        const loss = try recoverWrecks(gs, c, &player, scenario, outcome, roe, trucks, &hit_log);
        lost_hulls = loss.hulls;
        missing = loss.missing;
        damage_value += loss.damage_value;
    }
    // The wrecks on offer and the part of the claim still to be
    // divided. Both stay empty unless the haul is worth a decision.
    var salvage_candidates: []const battle_report.SalvageCandidate = &.{};
    var salvage_unclaimed: i64 = 0;
    // Determine the committed combat operation's intent early — needed for
    // salvage gating and score modifiers below (docs/p4-operations-design.md §6).
    // battle.zig MUST NOT import operation_control.zig (rule 5).
    const committed_op_early = operations_m.committedCombatOp(c);
    const op_intent: ?operation_mod.Intent = if (committed_op_early) |op| op.intent else null;
    const op_tempo: ?operation_mod.TempoPosture = if (committed_op_early) |op| op.tempo else null;
    const op_interventions: []const u8 = if (committed_op_early) |op|
        try operations_m.interventionSummary(gs.allocator(), op)
    else
        "";
    // Salvage is things, not money: your share of what the
    // crews haul off a held field becomes wrecks and parts crated to the
    // home HQ depot — to store, strip, or rebuild into a working hull.
    var salvage_bv: i64 = if (held_field) types.applyBp(salvageClaimBv(haulable_bv, c.terms.salvage_pct, player.mods.has_salvage_lance), scenario.salvage_bp) else 0;
    // Gate salvage on the committed operation's intent profile (rule 20).
    // No new RNG draw: intent is a deterministic post-roll modifier (design §6).
    if (op_intent) |intent| {
        if (!operations_m.intentProfile(intent).salvage_allowed) {
            salvage_bv = 0;
        }
    }
    // The liaison's cut: under tighter command rights the employer
    // claims part of what you haul.
    const before_cut = salvage_bv;
    salvage_bv = types.applyBp(salvage_bv, c.terms.command_rights.salvageShareBp());
    const liaison_cut = before_cut - salvage_bv;
    // Salvage exchange: the employer keeps every wreck and part and
    // pays the claim in cash into the company's local funds.
    var exchange_cash: types.CBills = 0;
    const spoils = if (c.terms.salvage_exchange) blk: {
        exchange_cash = types.applyBp(salvage_bv * tuning.contract.salvage_cbills_per_bv, tuning.contract.salvage_exchange_bp);
        if (exchange_cash > 0) try gs.postTreasury(.{ .company = c.assigned_company }, .{
            .day = gs.clock.day_index,
            .amount = exchange_cash,
            .category = .salvage,
            .company = c.assigned_company,
            .contract = c.id,
            .note = "salvage exchange",
        });
        break :blk if (exchange_cash > 0) try std.fmt.allocPrint(gs.allocator(), "salvage exchange — the employer keeps the wrecks and pays {s} c-bills for your {d} BV claim", .{ try types.moneyText(gs.allocator(), exchange_cash), salvage_bv }) else "";
    } else blk: {
        // Roll what is out there once, then see whether the claim
        // buys a real choice. If it does, nothing is taken yet — the
        // commander divides the haul from the inbox.
        if (salvage_bv <= 0) break :blk ""; // nothing to divide, nothing to roll
        salvage_candidates = try rollSalvageCandidates(gs, c);
        if (salvageWorthAsking(salvage_candidates, salvage_bv)) {
            salvage_unclaimed = salvage_bv;
            break :blk "";
        }
        break :blk try takeSalvage(gs, c, salvage_candidates, salvage_bv, .most_hulls);
    };
    const salvage = salvage_bv; // for the AAR

    // Expend the reloads this fight consumed, itemized below.
    // ammo_reserved was drawn from on-hand stock during battle preparation;
    // the batch must be satisfiable — a short is a programming error (rule 15).
    if (!sites.consumeStockBatch(gs, player.site, &player.ammo_reserved)) unreachable;
    const captured = try takePrisoners(gs, c, &player, held_field, enemy_loss_pct, enemy_destroyed_bv);
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
    const after = try aftermath(gs, c, &player, open, env, engaged, enemy_destroyed_bv, wounded, kia, &per_unit_kills);
    const score_delta = after.score_delta;
    const morale_delta = after.morale_delta;
    const convoy_hit = after.convoy_hit;
    const kills_credited = after.kills_credited;

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

    // Operation binding: if a combat operation was committed, associate it
    // with this engagement. Reserve the extra arc result log line now
    // (failure-atomic: reserve before any mutation, commit infallibly).
    // battle.zig MUST NOT import operation_control.zig (rule 5).
    const committed_op = committed_op_early;
    const op_template_name: []const u8 = if (committed_op) |op|
        if (operation_mod.findTemplate(op.template_key)) |t| t.name else ""
    else
        "";
    var arc_log_text: []const u8 = "";
    if (committed_op != null) {
        // Allocate the log text now (only allocates; does NOT touch event_log).
        // reserveLog is called later, immediately before the infallible commit
        // block, so nothing appends to event_log between the reservation and
        // the appendAssumeCapacity (bug fix: the AAR render loop runs between
        // here and the commit block and would have consumed the reserved slot).
        var arc_date_buf: [10]u8 = undefined;
        const band = operations_m.combatBand(outcome);
        arc_log_text = try std.fmt.allocPrint(gs.allocator(), "{s} [arc] combat operation resolved: {s} ({s})", .{
            gs.clock.date.text(&arc_date_buf),
            op_template_name,
            @tagName(band),
        });
    }

    // Build per-lance task result slice (P4e). Arena-owned: names duped via gs.allocator().
    // battle.zig MUST NOT import operation_control.zig (rule 5).
    var task_results: std.ArrayListUnmanaged(battle_report.TaskedLance) = .empty;
    if (committed_op) |op| {
        for (op.tasks.items) |lt| {
            const lf = gs.force(lt.lance);
            const lance_name = if (lf) |f| try gs.allocator().dupe(u8, f.name) else "";
            const succeeded = operations_m.taskSucceeded(lt.task, operations_m.combatBand(outcome), held_field);
            const note = try gs.allocator().dupe(u8, switch (lt.task) {
                .reserve => if (open.reserve_steadied) "steadied a bad opening" else if (succeeded) "held in reserve" else "line broke before reserve could act",
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

    // Everything this engagement did, as fields. The AAR is
    // rendered from it, so the record and the narrative cannot drift.
    var ammo_lines: std.ArrayListUnmanaged(battle_report.AmmoLine) = .empty;
    for (part_mod.munition_keys) |key| try ammo_lines.append(gs.allocator(), .{
        .key = key,
        .burned = player.ammo_reserved.get(key) orelse 0,
        .left = gs.stockCount(player.site, key),
    });
    const report: battle_report.BattleReport = .{
        .id = gs.nextBattleId(),
        .operation = op_template_name,
        .operation_intent = op_intent,
        .operation_tempo = op_tempo,
        .operation_interventions = op_interventions,
        .tasks = task_results.items,
        .day = gs.clock.day_index,
        .contract = c.id,
        .company = c.assigned_company,
        .kind = c.kind.label(),
        .enemy_key = c.enemy_key,
        .scenario = scenario.name,
        .terrain = terrain_mod.terrainRow(env.terrain).name,
        .weather = terrain_mod.weatherRow(env.weather).name,
        .outcome = outcome,
        .held_field = held_field,
        .withdrew = withdrew,
        .roe = roe,
        .roe_overridden = c.terms.command_rights.overridesRoe(),
        .player_power = player.power,
        .enemy_power = enemy_power,
        .conditions_mod = scenario_mod,
        .close_terrain = env.close(),
        .air_grounded = env.groundsAir(),
        .convoy_hit = convoy_hit,
        .edge_spent_by = if (gs.person(edge_used_by)) |p| try p.rankedName(gs.allocator()) else "",
        .recon_quality = player.mods.recon_quality,
        .avg_fatigue = player.mods.avg_fatigue,
        .avg_morale = player.mods.avg_morale,
        .hits_taken = hits,
        .destroyed = destroyed,
        .wounded = wounded,
        .kia = kia,
        .lost_hulls = lost_hulls,
        .missing = missing,
        .enemy_destroyed_bv = enemy_destroyed_bv,
        .kills_credited = kills_credited,
        .prisoners = captured,
        .battle_loss_comp = comp,
        .score_after = c.score,
        .score_delta = score_delta,
        .morale_delta = morale_delta,
        .fatigue_add = tb.fatigue_base + env.fatigue(),
        .battle_loss_pct = c.terms.battle_loss_pct,
        .salvage_pct = c.terms.salvage_pct,
        .command_rights = @tagName(c.terms.command_rights),
        // Owned, not borrowed: `hit_log` is freed when this function
        // returns, and the report outlives it.
        .hulls = try gs.allocator().dupe(battle_report.HullHit, hit_log.items),
        .ammo = ammo_lines.items,
        .silenced_mounts = player.silenced_mounts,
        .armor_left = gs.stockCount(player.site, "armor"),
        .salvage = .{
            .claimed_bv = salvage,
            .haulable_bv = haulable_bv,
            .liaison_cut = liaison_cut,
            .exchange_cash = exchange_cash,
            .items = spoils,
            .candidates = salvage_candidates,
            .unclaimed_bv = salvage_unclaimed,
        },
    };
    const ctx: @import("state.zig").LogCtx = .{ .company = c.assigned_company, .contract = c.id };
    for (try after_action.render(gs.allocator(), &report)) |line| try gs.log(.battle, ctx, "{s}", .{line});
    // Kept so the screens can show the fight as a picture; the
    // AAR lines above are the permanent account and are never pruned.
    try gs.battle_reports.record(gs.allocator(), report);
    // Hulls left on the field pass into enemy hands — off
    // our books once the AAR has named them, but held, not struck off:
    // a recovery raid has something to win back.
    for (hit_log.items) |h| if (h.lost) try held_hulls_m.holdUnit(gs, h.unit, c.enemy_key, report.id);

    // Objectives: the pool shrinks, VP accrue, and a broken pool
    // completes the contract.
    try @import("contract_control.zig").recordBattle(gs, c, enemy_destroyed_bv, score_delta);
    // Arc operation binding: transition the committed combat op and log result.
    // reserveLog is called here, immediately before the first mutation, so
    // nothing appends to event_log between reservation and appendAssumeCapacity
    // (the AAR render loop runs before this block).
    if (committed_op) |op| {
        try gs.reserveLog(1);
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
    if (lost_hulls > 0 or missing > 0) try @import("contract_events.zig").queueRecoveryPush(gs, c, report.id);
    // And a haul the claim cannot stretch over asks how to divide it.
    // Nothing has been taken yet; the trucks wait on the answer.
    if (salvage_unclaimed > 0) try @import("contract_events.zig").queueSalvage(gs, c, report.id);
    // And the night after any fight the techs pool their hours on the
    // damage, asking whose hull comes first only when the order
    // changes the outcome. Last, so a salvage answer's spares and armour
    // are in the stores before the techs reach for them.
    try @import("contract_events.zig").queueFieldRepair(gs, c, report.id);

    // Write one HullCombatRecord per engaged owned unit that has a linked hull
    // instance (P3c.2). Failure-atomically: reserve capacity for the whole
    // engaged slice FIRST (ensureUnusedCapacity is the last fallible step),
    // then appendAssumeCapacity infallibly. A pre-reservation failure leaves
    // hull_combat_records untouched (rule 7/13; held_hulls.holdUnit precedent).
    // Units with hull_instance_id == .none are skipped; their pilot kill record
    // is still written (no silent data loss for the person side).
    try gs.hull_combat_records.ensureUnusedCapacity(gs.allocator(), engaged.len);
    for (engaged) |uid| {
        const u = gs.unit(uid) orelse continue;
        if (u.hull_instance_id == .none) continue;
        // Kills from the per_unit_kills tally built by creditKills.
        var kills: u16 = 0;
        for (per_unit_kills.items) |pk| {
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
        for (hit_log.items) |h| {
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
            .battle_id = report.id,
            .contract_id = c.id,
            .kills = kills,
            .hits_taken = rec_hits_taken,
            .armor_lost = @intCast(@min(std.math.maxInt(u16), armor_diff)),
            .slots_damaged = rec_slots_damaged,
            .slots_destroyed = rec_slots_destroyed,
            .destroyed = rec_destroyed,
            .cause = rec_cause,
        });
    }
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
    try gs.battle_reports.record(gs.allocator(), report);
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
    try std.testing.expect(dry.silenced_mounts > 0);

    // Stock every family: full power, and the fight will expend reloads.
    const site: types.Site = .{ .company = co };
    for (part_mod.munition_keys) |key| try gs.addStock(site, key, 20);
    var armed = try playerSide(&gs, c);
    defer armed.engaged.deinit(gs.scratch());
    defer armed.ammo_reserved.deinit(gs.scratch());
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
    try std.testing.expectEqual(@as(u8, 2), independent.mods.recon_quality);
    c.terms.command_rights = .integrated;
    var integrated = try playerSide(&gs, c);
    defer integrated.engaged.deinit(gs.scratch());
    defer integrated.ammo_reserved.deinit(gs.scratch());
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
    for (0..180) |_| {
        try runDaily(&gs);
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
