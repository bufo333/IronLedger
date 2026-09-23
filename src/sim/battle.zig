//! Battle autoresolution (Stage 7, ARCH §7) — descended from MekHQ's ACAR.
//! Combat-class contracts schedule engagements every few weeks; each
//! resolves without the player from what the campaign built: BV and crew
//! skill, machine condition, fatigue and morale, the support echelon, and
//! recon. Damage lands on real part slots, casualties go to the infirmary,
//! salvage and battle-loss comp hit the ledger, and the AAR names the
//! reasons. Legibility over drama: a loss should trace to causes.

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const autoresolve = @import("autoresolve.zig");
const contract_mod = @import("../domain/contract.zig");
const chassis_mod = @import("../domain/chassis.zig");
const after_action = @import("after_action.zig");
const force_mod = @import("../domain/force.zig");
const part_mod = @import("../domain/part.zig");
const medical = @import("medical.zig");
const person_mod = @import("../domain/person.zig");
const unit_mod = @import("../domain/unit.zig");
const GameState = @import("state.zig").GameState;

/// Salvage trucks (SVT-1) a company fields, wrecks excepted.
pub fn salvageTrucks(gs: *GameState, company: types.ForceId) i64 {
    var trucks: i64 = 0;
    var it = gs.units.iterator();
    while (it.next()) |entry| {
        const u = entry.value_ptr;
        if (u.status != .destroyed and std.mem.eql(u8, u.chassis_key, "SVT-1") and gs.companyOf(u.force) == company) trucks += 1;
    }
    return trucks;
}

/// BV of wrecks and parts the crews can haul off a won field: what the
/// trucks carry, else what hands can drag.
pub fn haulCapacityBv(trucks: i64) i64 {
    return if (trucks > 0) trucks * tuning.battle.salvage_bv_per_truck else tuning.battle.salvage_bv_by_hand;
}

/// Whole hulls a destroyed-BV total amounts to (a thousand BV a kill,
/// rounded): kill credit and prisoner counts both read it.
pub fn estimatedKills(destroyed_bv: i64) u32 {
    return @intCast(@max(0, @divTrunc(destroyed_bv + 500, 1000)));
}

/// Days between engagements: ~2/month with variance; garrison work sees
/// a probe every six weeks or so (12D.6).
fn nextBattleGap(gs: *GameState, c: *const contract_mod.Contract) u32 {
    if (c.kind.isGarrisonClass()) return tuning.battle.garrison_probe_base_days + @as(u32, gs.rng.roll2d6(.battle)) * tuning.battle.garrison_probe_die_days;
    // Command rights set the tempo (12B.1): integrated employers pick fights.
    const base: i32 = @as(i32, @intCast(tuning.battle.gap_base_days)) + @as(i32, gs.rng.roll2d6(.battle)) + c.terms.command_rights.gapDelta();
    return @intCast(@max(3, base));
}

/// battle_resolution phase, daily: schedule and resolve engagements for
/// active combat-class contracts.
pub fn runDaily(gs: *GameState) !void {
    var it = gs.contracts.iterator();
    while (it.next()) |entry| {
        const c = entry.value_ptr;
        if (c.status != .active) continue;
        // Garrison work fights too (12D.6, ARCH §8): the enemy probes the
        // perimeter — contracts from before 12D.5 have no force to probe with.
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
/// (~10 turns of fire at tabletop rates; halved on 2026-09-04 because
/// resupply tonnage was swamping the field trucks).
pub const mounts_per_ammo_ton = tuning.battle.mounts_per_ammo_ton;

fn hasTech(gs: *GameState, u: *const @import("../domain/unit.zig").Unit) bool {
    const t = gs.person(u.tech) orelse return false;
    return t.isAvailable(gs.clock.day_index);
}

/// Gather the company's combat lances into engaged units + summed power.
const terrain_mod = @import("../domain/terrain.zig");
const planet_mod = @import("../domain/planet.zig");

fn playerSide(gs: *GameState, c: *const contract_mod.Contract) !SideState {
    return playerSideIn(gs, gs.allocator(), c, .{});
}

/// What a company would bring to a fight on this contract (12E.3): its
/// combat power as the battle model reckons it (BV × skill × condition ×
/// quality × supply, the support echelon and recon, lance roles under the
/// contract's command rights), what it weighs, and its weight-class mix.
/// Read-only: nothing is reserved or spent. `alloc` is the caller's
/// scratch space.
pub const Estimate = struct {
    power: i64 = 0,
    bv: i64 = 0,
    tons: u32 = 0,
    /// Hulls by weight class: light, medium, heavy, assault.
    mix: [4]u32 = .{ 0, 0, 0, 0 },
    hulls: u32 = 0,
    recon: bool = false,
};

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

/// The player's side under given conditions (12C.10): night and storms
/// ground the fighters, close terrain dents recon.
fn playerSideIn(gs: *GameState, alloc: std.mem.Allocator, c: *const contract_mod.Contract, env: terrain_mod.Environment) !SideState {
    var mods = companyMods(gs, c);
    if (env.groundsAir()) mods.has_air_cover = false;
    mods.recon_quality = @intCast(@max(0, @as(i32, mods.recon_quality) + env.reconMod()));
    var side: SideState = .{ .mods = mods, .site = .{ .company = c.assigned_company } };

    const company = gs.force(c.assigned_company) orelse return side;

    // Pass 1 (Stage 9B): count working ballistic/missile mounts per munition
    // family across the company, then decide how many each family's stock
    // can feed this fight. Reserved tons are expended after the battle.
    var family_mounts = try @import("field_supply.zig").munitionMounts(alloc, gs, c.assigned_company, true);
    var family_fire_pct: std.StringArrayHashMapUnmanaged(u32) = .empty;
    var fit = family_mounts.iterator();
    while (fit.next()) |entry| {
        const mounts = entry.value_ptr.*;
        const need = std.math.divCeil(u32, mounts, mounts_per_ammo_ton) catch 1;
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
        // unless the employer commands (12B.1 integrated rights).
        if (lance.role == .training and c.terms.command_rights.allowsTrainingLances()) continue;

        var lance_bv: i64 = 0;
        var gunnery_sum: u32 = 0;
        var piloting_sum: u32 = 0;
        var condition_sum: u32 = 0;
        var quality_sum: u32 = 0;
        var n: u32 = 0;
        for (lance.units.items) |uid| {
            const u = gs.unit(uid) orelse continue;
            if (!u.canFight()) continue;
            const design = chassis_mod.find(u.chassis_key) orelse continue;
            // No pilot fit for duty → the hull stays in the hangar (Stage 9C.2).
            const pilot = gs.person(u.pilot) orelse continue;
            if (!pilot.isAvailable(gs.clock.day_index)) continue;
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
            // skill lost for good (Stage 12.16).
            // Specialists (12B.6) count a point better; old wounds a point
            // worse; a tired pilot one to three worse (12C.1 fatigue bands).
            gunnery_sum += ((pilot.skill(.gunnery_mek) orelse 4) + pilot.permanentPenalty() + pilot.fatiguePenalty()) -| @intFromBool(pilot.has("gunnery_specialist"));
            piloting_sum += ((pilot.skill(.piloting_mek) orelse 5) + pilot.permanentPenalty() + pilot.fatiguePenalty()) -| @intFromBool(pilot.has("piloting_specialist"));
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
        // A tactical genius leading the lance (12B.6): +5%.
        if (gs.person(lance.commander)) |leader| if (leader.has("tactical_genius")) {
            lance_power = types.applyBp(lance_power, 10_500);
        };
        side.power += lance_power;
    }
    return side;
}

/// The campaign-state modifiers: every field a lever the player pulled (or
/// didn't) long before the shooting started.
fn companyMods(gs: *GameState, c: *const contract_mod.Contract) autoresolve.CampaignMods {
    var mods: autoresolve.CampaignMods = .{};

    // Supply state (Stage 9B): the company's own field stores — spares on
    // hand, and whether the mess has been feeding people.
    const site: types.Site = .{ .company = c.assigned_company };
    mods.supply_parts = gs.stockCount(site, "structure") > 0 or gs.stockCount(site, "armor") > 0;
    const shortage = if (gs.force(c.assigned_company)) |f| f.supply_shortage_days else 0;
    mods.supply_provisions = shortage == 0;

    // People: fatigue & morale across the company (one census: personnel.companyCrewStats).
    const crew = @import("personnel.zig").companyCrewStats(gs, c.assigned_company);
    if (crew.heads > 0) {
        mods.avg_fatigue = crew.avg_fatigue;
        mods.avg_morale = crew.avg_morale;
    }

    // Force structure: recon lance and the support echelon (ARCH §9.3).
    const company = gs.force(c.assigned_company) orelse return mods;
    for (company.children.items) |child_id| {
        const child = gs.force(child_id) orelse continue;
        if (child.echelon == .lance and child.role == .scouting and child.units.items.len > 0 and !c.terms.command_rights.overridesScouting())
            mods.recon_quality = 2;
        if (child.echelon == .air_company) {
            // Air cover is a fighter that can fly: ready, with a pilot.
            for (child.children.items) |al_id| {
                const al = gs.force(al_id) orelse continue;
                for (al.units.items) |uid| {
                    const u = gs.unit(uid) orelse continue;
                    if (u.kind != .aerospace or u.status != .ready) continue;
                    const pilot = gs.person(u.pilot) orelse continue;
                    if (pilot.isAvailable(gs.clock.day_index)) mods.has_air_cover = true;
                }
            }
        }
        if (child.echelon == .support_company) {
            for (child.children.items) |sl_id| {
                const sl = gs.force(sl_id) orelse continue;
                if (sl.units.items.len == 0) continue;
                switch (sl.support_kind orelse continue) {
                    .mash => mods.has_mash_lance = true,
                    .mess => mods.has_mess_lance = true,
                    .security => mods.has_security_lance = true,
                    .salvage => mods.has_salvage_lance = true,
                    .transport => mods.has_field_repair = true,
                }
            }
        }
    }
    return mods;
}

/// The enemy's BV in one engagement. It is a force of its own (12D.5): its
/// lances, whatever you brought, ± the day's variance, scaled by the
/// scenario and the difficulty (12.32). Contracts from before 12D.5 still
/// mirror the company's committed BV.
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
/// kill with its cause (12D.2) and the crew's fate. Appends a `HullHit`
/// per landed hit and returns the tally the AAR's losses line reads.
/// CamOps/AtB damage and crew-casualty rules; `tuning.battle` holds every
/// threshold.
fn applyHits(
    gs: *GameState,
    player: *const SideState,
    engaged: []const types.UnitId,
    hits: u32,
    hit_log: *std.ArrayListUnmanaged(after_action.HullHit),
) !Tally {
    const tb = tuning.battle;
    var tally: Tally = .{};
    for (0..hits) |_| {
        const uid = engaged[gs.rng.random(.battle).uintLessThan(usize, engaged.len)];
        const u = gs.unit(uid) orelse continue;
        if (u.status == .destroyed) continue;
        // Dodge (12B.6): one hit in three aimed at this hull misses.
        if (gs.person(u.pilot)) |dp| if (dp.has("dodge") and gs.rng.random(.battle).uintLessThan(u8, 3) == 0) continue;

        const severity = gs.rng.roll2d6(.battle);
        const hit_ch = chassis_mod.find(u.chassis_key);
        var rec: after_action.HullHit = .{
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
            const slot = &u.slots.items[gs.rng.random(.battle).uintLessThan(usize, u.slots.items.len)];
            slot.condition = if (slot.condition == .ok) .damaged else .destroyed;
            ammo_hit = slot.class == .ammo;
            rec.slot = slot.slot_key;
            rec.slot_part = slot.part_key;
            rec.slot_result = if (slot.condition == .damaged) .damaged else .destroyed;
        }
        // A bin struck hard enough cooks off (TechManual: no CASE in the
        // 3025 catalogue), and takes the hull with it (12D.2).
        const cooked_off = ammo_hit and severity >= tb.cookoff_severity;
        if (severity >= tb.kill_severity or (u.armor_pct == 0 and severity >= tb.kill_armorless_severity) or cooked_off) {
            // How it died decides what the rebuild needs (12D.2).
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
        // kills unless a MASH lance is forward. MASH also halves the wound
        // chance on hard hits (tuning.battle.wound_*).
        if (gs.person(u.pilot)) |p| {
            if (p.status == .active) {
                // Wound severity follows the hit (Stage 12.16): 8–9 light,
                // 10–11 serious, 12 crippling (survivable only with MASH).
                // Toughness (12B.6): a step lighter, and a killing hit is survived.
                const tough = p.has("toughness");
                const raw_severity: u8 = if (severity >= tb.wound_crippling_severity) 3 else if (severity >= tb.wound_serious_severity) 2 else 1;
                const wound_severity: u8 = @max(1, raw_severity -| @as(u8, @intFromBool(tough)));
                if (severity >= tb.kill_severity and !player.mods.has_mash_lance and !tough) {
                    // The seat empties with the pilot (12D.1): the checklist
                    // shows an open cockpit, not a dead man in it.
                    rec.crew_name = try p.rankedName(gs.allocator());
                    _ = try @import("personnel.zig").depart(gs, p.id, .kia, 0, "");
                    tally.kia += 1;
                    gs.stats.people_kia += 1;
                    rec.crew.fate = .kia;
                } else if (severity >= tb.cookoff_severity) {
                    try medical.inflict(gs, u.pilot, .combat, wound_severity, "battle");
                    tally.wounded += 1;
                    rec.crew_name = try p.rankedName(gs.allocator());
                    rec.crew.wound = lastWound(p);
                } else if (severity >= tb.slot_hit_severity) {
                    const need: u8 = if (player.mods.has_mash_lance) tb.wound_target_mash else tb.wound_target;
                    if (gs.rng.roll2d6(.battle) >= need) {
                        try medical.inflict(gs, u.pilot, .combat, wound_severity, "battle");
                        tally.wounded += 1;
                        rec.crew_name = try p.rankedName(gs.allocator());
                        rec.crew.wound = lastWound(p);
                    }
                }
            }
        }
        try hit_log.append(gs.allocator(), rec);
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

/// Who holds the field keeps the wrecks (12D.3, CamOps salvage). On a
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
    hit_log: *std.ArrayListUnmanaged(after_action.HullHit),
) !FieldLoss {
    const rt = tuning.loss.roe;
    var loss: FieldLoss = .{};
        const t = tuning.loss;
        const has_dropship = gs.hasCrewedDropship(c.assigned_company);
        var wrecks_here: i64 = 0;
        for (hit_log.items) |h| wrecks_here += @intFromBool(h.destroyed);
        const situation: i32 = (if (player.mods.has_salvage_lance) t.recovery_salvage_lance else 0) //
        + (if (trucks >= wrecks_here and trucks > 0) t.recovery_trucks else 0) //
        + (if (has_dropship) t.recovery_dropship else 0) //
        + (if (outcome == .rout) t.recovery_rout else 0) //
        + scenario.recovery_mod + gs.diff().recovery_mod //
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
            const piloting: i32 = p.skill(.piloting_mek) orelse 5;
            const escape = @as(i32, gs.rng.roll2d6(.battle)) + (5 - piloting) + gs.diff().recovery_mod + (if (outcome == .rout) t.recovery_rout else 0);
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
/// company's rules of engagement, re-rolled once if a pilot spends Edge
/// (12B.6). Returns everything downstream needs to know about how it
/// went, so no later phase re-derives the odds.
fn openingRoll(gs: *GameState, c: *const contract_mod.Contract, player: *const SideState, env: terrain_mod.Environment) Opening {
    // What kind of fight this is (12C.9, AtB scenario table): it scales
    // the enemy, tilts the roll, weights the score and decides what a
    // held field is worth.
    const scenario = @import("../domain/scenario.zig").roll(&gs.rng, .battle, c.kind);

    // Enemy: strength relative to the player's committed BV, pirate rabble
    // to house regulars by employer's foe.
    const variance: types.Bp = (@as(types.Bp, gs.rng.roll2d6(.battle)) - 7) * 500;
    var enemy_bv = engagementEnemyBv(c, player.bv, variance, scenario.enemy_bp, gs.diff().enemy_bp);
    // A garrison probe is a lance or so of the enemy's, not the lot (12D.6).
    if (c.kind.isGarrisonClass() and c.hasOpfor()) enemy_bv = @divTrunc(enemy_bv * @min(tuning.battle.garrison_probe_lances, c.enemy_lances), c.enemy_lances);
    // Attrition contracts (Stage 9E): the enemy can only field what's left
    // of their pool.
    if (c.objective == .attrition and c.enemy_pool_remaining > 0) enemy_bv = @min(enemy_bv, c.enemy_pool_remaining);
    const pirates = std.mem.eql(u8, c.enemy_key, "PER");
    // Their skill: the rolled level (12D.5), else pirates green, houses regular.
    const enemy_skills: [2]u8 = if (c.hasOpfor()) @import("../domain/opfor.zig").skills(c.enemy_quality) else if (pirates) .{ 5, 6 } else .{ 4, 5 };
    const enemy_elem: autoresolve.Element = .{
        .base_strength = enemy_bv,
        .avg_gunnery = enemy_skills[0],
        .avg_piloting = enemy_skills[1],
    };
    const enemy_power = enemy_elem.effectivePower(.{});

    // One opposed roll decides the engagement (rounds within are abstracted;
    // ARCH §7 steps 3–4 collapse into the margin).
    // The scenario's tilt, and what scouts give back (an ambush spotted
    // is half an ambush).
    const scenario_mod: i32 = @as(i32, scenario.roll_mod) + (if (player.mods.recon_quality > 0) @as(i32, scenario.scout_bonus) else 0) + env.rollMod();
    // Close terrain evens the odds: numbers count for less in the woods and the streets.
    const ratio_bonus: i32 = if (env.close()) @min(ratioBonus(player.power, enemy_power), 2) else ratioBonus(player.power, enemy_power);
    // Rules of engagement (12D.4): the company's standing order, unless an
    // integrated employer's officers set it.
    const rt = tuning.loss.roe;
    const roe: force_mod.Roe = if (c.terms.command_rights.overridesRoe()) .hold else if (gs.force(c.assigned_company)) |f| f.roe else .standard;
    const roe_roll: i32 = switch (roe) {
        .hold => rt.hold_roll,
        .standard => 0,
        .cautious => rt.cautious_roll,
    };
    var roll = @as(i32, gs.rng.roll2d6(.battle)) + ratio_bonus + scenario_mod + roe_roll;
    // Edge (12B.6): a pilot with Edge to spend re-rolls a lost engagement once per contract.
    var edge_used_by: ?*person_mod.Person = null;
    if (roll < 6) {
        for (player.engaged.items) |uid| {
            const u = gs.unit(uid) orelse continue;
            const p = gs.person(u.pilot) orelse continue;
            if (p.has("edge") and !p.edge_spent) {
                p.edge_spent = true;
                edge_used_by = p;
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
    // pulling back when it turns (12D.4).
    const lost_fight = outcome.isLoss();
    const hit_pct: u32 = @intCast(@max(0, base_hit_pct + if (!lost_fight) 0 else switch (roe) {
        .hold => rt.hold_hits_pct,
        .standard => 0,
        .cautious => rt.cautious_hits_pct,
    }));
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
    edge_used_by: ?*person_mod.Person,
};

/// What the engagement leaves behind once the shooting stops: the
/// contract's score and victory points, the convoy a lost escort exposes
/// (12C.9), company morale and fatigue, the crews' experience, and the
/// kills and awards they earned (12B.5). Returns the figures the AAR
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
    // A convoy escort lost is a convoy hit (12C.9): the support train takes it.
    const convoy_hit = scenario.support_exposed and outcome.isLoss();
    if (convoy_hit) @import("contract_events.zig").damageRandomUnits(gs, c.assigned_company, if (outcome == .rout) 2 else 1, .support);
    var morale_delta: i32 = switch (outcome) {
        inline else => |o| @field(tb.morale, @tagName(o)),
    };
    if (morale_delta < 0 and player.mods.has_mess_lance) morale_delta += tb.morale.mess_relief; // hot food after a bad day
    if (lost_fight and roe == .hold) morale_delta += rt.hold_morale; // a stand that failed
    // A win on a fight that mattered (12C.11): breakthroughs, base defences and extractions carried.
    if (score_delta > 0 and scenario.score_mult > 1) morale_delta += tuning.person.morale_objective_bonus;
    applyCompanyAftermath(gs, c.assigned_company, morale_delta, tb.fatigue_base + env.fatigue());
    for (engaged) |uid| {
        const u = gs.unit(uid) orelse continue;
        if (gs.person(u.pilot)) |p| {
            if (p.isOnBooks())
                p.xp += p.xpGain(gs.clock.day_index, if (score_delta > 0) tb.xp_scored else tb.xp_fought);
        }
    }
    // Kill credits and the awards they earn (12B.5).
    const personnel = @import("personnel.zig");
    const kills_credited = try personnel.creditKills(gs, engaged, enemy_destroyed_bv);
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

/// Prisoners (12B.7): a security lance on a held field takes enemy crews
/// alive — people with a house, held by the company until the inbox
/// decides ransom, release or recruitment. Returns how many were taken.
fn takePrisoners(gs: *GameState, c: *const contract_mod.Contract, player: *const SideState, held_field: bool, enemy_loss_pct: u32, enemy_destroyed_bv: i64) !u32 {
    var captured: u32 = 0;
    if (held_field and player.mods.has_security_lance and enemy_loss_pct >= 15) {
        const t = tuning.contract;
        const kills_est: u32 = estimatedKills(enemy_destroyed_bv);
        captured = @min(t.prisoners_max_per_battle, kills_est / t.prisoners_per_kills);
        for (0..captured) |_| {
            const spec = @import("../gen/person_gen.zig").generateWithBonus(&gs.rng, .mekwarrior, if (std.mem.eql(u8, c.enemy_key, "PER")) -1 else 0);
            const pid = try gs.hireFromSpec(spec);
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
    // Where and in what (12C.10): the world's ground, the day's weather.
    const env: terrain_mod.Environment = blk: {
        const world = planet_mod.find(c.planet_key) orelse break :blk .{};
        const t = terrain_mod.terrainOf(world);
        break :blk .{ .terrain = t, .weather = terrain_mod.rollWeather(&gs.rng, .battle, t) };
    };
    var player = try playerSideIn(gs, gs.allocator(), c, env);
    defer player.engaged.deinit(gs.allocator());
    if (player.engaged.items.len == 0) {
        c.score -= 2;
        c.victory_points -= 10;
        try gs.log(.battle, .{ .company = c.assigned_company, .contract = c.id }, "[AAR] {s}: no combat-effective units — objective conceded", .{c.kind.label()});
        return;
    }

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
    // The detailed AAR (Stage 12.23, 12G.3): every hit on record — which
    // hull, what it lost, what happened to the crew. The record outlives
    // the fight, so it copies the names it needs (after_action.HullHit).
    var hit_log: std.ArrayListUnmanaged(after_action.HullHit) = .empty;
    defer hit_log.deinit(gs.allocator());
    const tally = try applyHits(gs, &player, engaged, hits, &hit_log);
    var damage_value = tally.damage_value;
    const destroyed = tally.destroyed;
    const wounded = tally.wounded;
    const kia = tally.kia;

    // Spoils: salvage rights over the enemy's wrecks — but only if you held
    // the field (retreating forces strip nothing) — prisoners if you can
    // hold them, employer compensation for your losses.
    // A cautious company does not wait out a draw: it withdraws (12D.4).
    const withdrew = outcome == .draw and roe == .cautious;
    const held_field = outcome.heldField() and !withdrew;
    const enemy_destroyed_bv = @divTrunc(enemy_bv * enemy_loss_pct, 100);
    // What the crews can actually haul off the field is bounded by the
    // salvage trucks on hand (300 BV-worth each; 150 hand-carried).
    const trucks = salvageTrucks(gs, c.assigned_company);
    const haulable_bv = @min(enemy_destroyed_bv, haulCapacityBv(trucks));

    // Who holds the field keeps the wrecks (12D.3, CamOps salvage): on a
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
    // Salvage is things, not money (Stage 12.23): your share of what the
    // crews haul off a held field becomes wrecks and parts crated to the
    // home HQ depot — to store, strip, or rebuild into a working hull.
    var salvage_bv: i64 = if (held_field) types.applyBp(@divTrunc(haulable_bv * c.terms.salvage_pct, 100), scenario.salvage_bp) else 0;
    if (player.mods.has_salvage_lance) salvage_bv = types.applyBp(salvage_bv, tuning.battle.salvage_lance_bonus_bp); // crews strip fast
    // The liaison's cut (12B.1): under tighter command rights the employer
    // claims part of what you haul.
    const before_cut = salvage_bv;
    salvage_bv = types.applyBp(salvage_bv, c.terms.command_rights.salvageShareBp());
    const liaison_cut = before_cut - salvage_bv;
    // Salvage exchange (12B.2): the employer keeps every wreck and part and
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
        break :blk if (exchange_cash > 0) try std.fmt.allocPrint(gs.allocator(), "salvage exchange — the employer keeps the wrecks and pays {d} c-bills for your {d} BV claim", .{ exchange_cash, salvage_bv }) else "";
    } else try claimSalvage(gs, c, salvage_bv);
    const salvage = salvage_bv; // for the AAR

    // Expend the reloads this fight consumed (Stage 9B), itemized below.
    var ammo_it = player.ammo_reserved.iterator();
    while (ammo_it.next()) |entry| {
        _ = gs.takeStock(player.site, entry.key_ptr.*, entry.value_ptr.*);
    }
    const captured = try takePrisoners(gs, c, &player, held_field, enemy_loss_pct, enemy_destroyed_bv);
    const comp = @divTrunc(damage_value * c.terms.battle_loss_pct, 100);
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
    const after = try aftermath(gs, c, &player, open, env, engaged, enemy_destroyed_bv, wounded, kia);
    const score_delta = after.score_delta;
    const morale_delta = after.morale_delta;
    const convoy_hit = after.convoy_hit;
    const kills_credited = after.kills_credited;

    // Everything this engagement did, as fields (12G.3). The AAR is
    // rendered from it, so the record and the narrative cannot drift.
    var ammo_lines: std.ArrayListUnmanaged(after_action.AmmoLine) = .empty;
    for (part_mod.munition_keys) |key| try ammo_lines.append(gs.allocator(), .{
        .key = key,
        .burned = player.ammo_reserved.get(key) orelse 0,
        .left = gs.stockCount(player.site, key),
    });
    const report: after_action.BattleReport = .{
        .id = gs.nextBattleId(),
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
        .edge_spent_by = if (edge_used_by) |p| try p.rankedName(gs.allocator()) else "",
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
        // returns, and the report outlives it (12G.4).
        .hulls = try gs.allocator().dupe(after_action.HullHit, hit_log.items),
        .ammo = ammo_lines.items,
        .silenced_mounts = player.silenced_mounts,
        .armor_left = gs.stockCount(player.site, "armor"),
        .salvage = .{
            .claimed_bv = salvage,
            .haulable_bv = haulable_bv,
            .liaison_cut = liaison_cut,
            .exchange_cash = exchange_cash,
            .items = spoils,
        },
    };
    const ctx: @import("state.zig").LogCtx = .{ .company = c.assigned_company, .contract = c.id };
    for (try after_action.render(gs.allocator(), &report)) |line| try gs.log(.battle, ctx, "{s}", .{line});
    // Kept so the screens can show the fight as a picture (12G.4); the
    // AAR lines above are the permanent account and are never pruned.
    try gs.battle_reports.record(gs.allocator(), report);
    // Hulls left on the field are gone for good (12D.3) — struck off once
    // the AAR has named them.
    for (hit_log.items) |h| if (h.lost) gs.removeUnit(h.unit);

    // Objectives (Stage 9E): the pool shrinks, VP accrue, and a broken pool
    // completes the contract.
    try @import("contract_control.zig").recordBattle(gs, c, enemy_destroyed_bv, score_delta);
}

/// " · field lost · recovery 6 vs 7 — LEFT TO THE ENEMY" (12D.3).
fn recoveryText(gs: *GameState, recovery: ?[2]i32, lost: bool) ![]const u8 {
    const r = recovery orelse return "";
    return try std.fmt.allocPrint(gs.allocator(), " · field lost · recovery {d} vs {d} — {s}", .{ r[0], r[1], if (lost) "LEFT TO THE ENEMY" else "dragged off" });
}

/// The wound `medical.inflict` just recorded, as fields for the report
/// (12G.3). Null when the roll wounded nobody.
fn lastWound(p: *const person_mod.Person) ?after_action.CrewOutcome.Wound {
    if (p.injuries.items.len == 0) return null;
    const inj = p.injuries.items[p.injuries.items.len - 1];
    return .{ .severity = inj.severity, .location = inj.location, .permanent = inj.permanent };
}

/// Turn a salvage claim in BV into things (Stage 12.23): whole wrecks
/// first — an enemy hull rolled off the RAT that fits the claim, created
/// as a wreck and shipped to the home HQ pool with the map transit — then
/// parts: structural components, weapons and armor tons, crated home.
/// Returns the itemized text for the AAR.
fn claimSalvage(gs: *GameState, c: *contract_mod.Contract, claim_bv: i64) ![]const u8 {
    if (claim_bv <= 0) return "";
    var text: std.ArrayListUnmanaged(u8) = .empty;
    var remaining = claim_bv;
    const company_gen = @import("../gen/company_gen.zig");
    const market = @import("../econ/market.zig");
    const logistics = @import("../econ/logistics.zig");
    const home = gs.hqs.getPtr(gs.homeHqFor(c.assigned_company));
    const from = planet_mod.find(c.planet_key);
    const to = if (home) |h| planet_mod.find(h.planet_key) else null;
    const days: u32 = if (from != null and to != null) logistics.daysBetween(from.?, to.?) else logistics.same_world_days;

    // Wrecks: up to two per battle, each a RAT roll that must fit the claim.
    var wrecks: u32 = 0;
    var tries: u8 = 0;
    while (wrecks < 2 and tries < 4) : (tries += 1) {
        // Off the enemy house's table (12B.8): Combine wrecks are Dragons.
        const design = @import("../domain/rat.zig").roll(&gs.rng, .battle, c.enemy_key, company_gen.rollWeightClass(&gs.rng), gs.clock.date.year);
        if (design.bv > remaining) continue;
        remaining -= design.bv;
        const uid = try gs.addUnit(design.key);
        const u = gs.unit(uid).?;
        u.purchase_price = 0; // salvage owes nothing
        // A wreck: shot up, some guns gone, a limb or torso missing.
        const cond: market.HullCondition = .{
            .armor_pct = @intCast(@as(u32, gs.rng.roll2d6(.battle)) * 3),
            .quality = if (gs.rng.random(.battle).boolean()) .c else .d,
            .damaged_slots = 1,
            .destroyed_slots = @intCast(gs.rng.random(.battle).intRangeAtMost(u8, 1, 3)),
            .missing_components = @intCast(gs.rng.random(.battle).intRangeAtMost(u8, 1, 2)),
        };
        gs.applyHullCondition(uid, cond);
        u.status = .in_transit;
        try gs.unit_transfers.append(gs.allocator(), .{ .unit = uid, .to_company = .none, .eta_day = gs.clock.day_index + days });
        wrecks += 1;
        gs.stats.hulls_salvaged += 1;
        try text.appendSlice(gs.allocator(), try std.fmt.allocPrint(gs.allocator(), "wreck #{d} {s} {s} (armor {d}%, {d} destroyed, {d} missing) → home depot in {d} days; ", .{
            @intFromEnum(uid), design.key, design.name, cond.armor_pct, cond.destroyed_slots, cond.missing_components, days,
        }));
    }
    // Parts: components, then weapons, then armor, at BV prices.
    const t = tuning.battle;
    var components: u32 = 0;
    // Assemblies off the enemy's wrecks come in the class of the hull they
    // were pulled from (12D.8).
    const comp_slots = [_][]const u8{ "la.", "ll.", "lt." };
    while (remaining >= t.salvage_bv_per_component and components < 3) : (components += 1) {
        remaining -= t.salvage_bv_per_component;
        const class = @import("../domain/opfor.zig").weightClass(&gs.rng, .battle);
        try gs.sendHome(c.assigned_company, part_mod.componentForSlotClass(comp_slots[components % comp_slots.len], class), 1);
    }
    var weapons: u32 = 0;
    const weapon_keys = [_][]const u8{ "mlas", "srm4", "ac5", "lrm5", "llas" };
    while (remaining >= t.salvage_bv_per_weapon and weapons < 4) : (weapons += 1) {
        remaining -= t.salvage_bv_per_weapon;
        try gs.sendHome(c.assigned_company, weapon_keys[gs.rng.random(.battle).uintLessThan(usize, weapon_keys.len)], 1);
    }
    var armor: u32 = 0;
    while (remaining >= t.salvage_bv_per_armor_ton and armor < 10) : (armor += 1) {
        remaining -= t.salvage_bv_per_armor_ton;
    }
    if (armor > 0) try gs.sendHome(c.assigned_company, "armor", armor);
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
        if (p.status != .active or !gs.personInCompany(p, company)) continue;
        p.addMorale(morale_delta); // Cool Under Fire halves a loss (Person.addMorale)
        p.addFatigue(fatigue_add);
    }
}

test "battles resolve with consequences and stronger forces win more" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 777 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    const co = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha");

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

    // And the ledger saw salvage income at 30% rights.
    const s = @import("../econ/finance.zig").summarize(&gs.ledger, 0, gs.clock.day_index + 1, .all);
    // Salvage is things now (12.23): wrecks in transit to the pool and parts crated home, no cash.
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
    _ = try gs.createCommander("T", .LC, .line_officer);
    const co = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha");
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
    // The dead leave their seats (12D.1).
    var seat_it = gs.units.iterator();
    while (seat_it.next()) |e| if (gs.person(e.value_ptr.pilot)) |p| {
        try std.testing.expect(p.status != .kia);
    };
    // Every wound is a located injury (Stage 12.16).
    var injured_it = gs.people.iterator();
    while (injured_it.next()) |e| if (e.value_ptr.status == .wounded) {
        try std.testing.expect(e.value_ptr.injuries.items.len > 0);
    };
}

test "9B: dry mounts are silenced — ammo is combat power" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 778 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    const co = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha");
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
    defer dry.engaged.deinit(gs.allocator());
    try std.testing.expect(dry.silenced_mounts > 0);

    // Stock every family: full power, and the fight will expend reloads.
    const site: types.Site = .{ .company = co };
    for (part_mod.munition_keys) |key| try gs.addStock(site, key, 20);
    var armed = try playerSide(&gs, c);
    defer armed.engaged.deinit(gs.allocator());
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

test "12.15: air cover is a fighter that can fly, not an empty wing" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 15 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    const co = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha");
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
    try gs.moveUnitToForce(fighter, lance);
    try std.testing.expect(!companyMods(&gs, c).has_air_cover); // no pilot
    const pilot = try gs.hirePerson("Ace", "Ito", .aero_pilot);
    try gs.assignSlot(fighter, .pilot, pilot);
    try std.testing.expect(companyMods(&gs, c).has_air_cover);
}

test "12.23: a salvage claim becomes a wreck in transit to the depot pool and parts crated home; the wreck lands" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1223 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    const co = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha");
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
    const text = try claimSalvage(&gs, c, 2_000);
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

test "12B.1: integrated command sends training lances to fight and pulls the scouts' recon bonus" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1231 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    const co = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha");
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
    defer independent.engaged.deinit(gs.allocator());
    try std.testing.expectEqual(@as(u8, 2), independent.mods.recon_quality);
    c.terms.command_rights = .integrated;
    var integrated = try playerSide(&gs, c);
    defer integrated.engaged.deinit(gs.allocator());
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

test "12B.2: salvage exchange pays cash into local funds and ships no wreck" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1232 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    const co = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha");
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

/// Hulls of `co` wrecked or lost over `n` hopeless engagements at a
/// difficulty (12D.3 test helper).
fn lossRun(seed: u64, level: @import("../domain/difficulty.zig").Level, n: u32) !struct { lost: u32, wrecks_kept: u32, missing: u32 } {
    var gs = GameState.init(std.testing.allocator, .{ .seed = seed });
    defer gs.deinit();
    gs.difficulty = level;
    _ = try gs.createCommander("T", .LC, .line_officer);
    const co = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha");
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
    return .{ .lost = lost, .wrecks_kept = kept, .missing = missing };
}

test "12D.3: a lost field loses wrecks to the enemy — harder the higher the difficulty" {
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

test "12D.4: rules of engagement — cautious withdraws from draws, integrated command holds" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1204 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    const co = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha");
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

test "12D.5: the enemy is a force of its own — it does not shrink with your company" {
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
    // A contract from before 12D.5 still mirrors the company.
    c.enemy_lances = 0;
    try std.testing.expect(engagementEnemyBv(&c, 16_000, 0, 10_000, 10_000) > engagementEnemyBv(&c, 4_000, 0, 10_000, 10_000));
}

test "12D.6: garrison work sees probes — a lance of the enemy's, every few weeks" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1206 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    const co = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha");
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
    // An older garrison contract (no rolled force) stays quiet.
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

test "12G.3: the AAR is rendered from the record, and the record outlives the fight" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 424242 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    const co = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha");
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
        // Rule 16: AAR text persists in the log as domain data. The sim
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
    // gathered by battle instead of by reading their prose (12G.3).
    try std.testing.expectEqual(@as(u32, 11), gs.next_battle_id);
    try std.testing.expect(gs.nextBattleId() == @as(types.BattleId, @enumFromInt(11)));
}
