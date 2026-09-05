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
const force_mod = @import("../domain/force.zig");
const part_mod = @import("../domain/part.zig");
const medical = @import("medical.zig");
const person_mod = @import("../domain/person.zig");
const GameState = @import("state.zig").GameState;

/// Days between engagements: ~2/month with variance.
fn nextBattleGap(gs: *GameState, c: *const contract_mod.Contract) u32 {
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
        if (c.status != .active or c.kind.isGarrisonClass()) continue;
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
fn playerSide(gs: *GameState, c: *const contract_mod.Contract) !SideState {
    var side: SideState = .{ .mods = companyMods(gs, c), .site = .{ .company = c.assigned_company } };

    const company = gs.force(c.assigned_company) orelse return side;

    // Pass 1 (Stage 9B): count working ballistic/missile mounts per munition
    // family across the company, then decide how many each family's stock
    // can feed this fight. Reserved tons are expended after the battle.
    var family_mounts: std.StringArrayHashMapUnmanaged(u32) = .empty;
    var family_fire_pct: std.StringArrayHashMapUnmanaged(u32) = .empty;
    for (company.children.items) |child_id| {
        const lance = gs.force(child_id) orelse continue;
        if (lance.echelon != .lance and lance.echelon != .air_lance) continue;
        for (lance.units.items) |uid| {
            const u = gs.unit(uid) orelse continue;
            if (u.status == .destroyed or u.status == .mothballed) continue;
            if (!hasTech(gs, u)) continue; // nobody to reload it (Stage 9C.2)
            for (u.slots.items) |slot| {
                if (slot.class != .weapon or slot.condition != .ok) continue;
                const key = part_mod.munitionFor(slot.part_key) orelse continue;
                const e = try family_mounts.getOrPut(gs.allocator(), key);
                if (!e.found_existing) e.value_ptr.* = 0;
                e.value_ptr.* += 1;
            }
        }
    }
    var fit = family_mounts.iterator();
    while (fit.next()) |entry| {
        const mounts = entry.value_ptr.*;
        const need = std.math.divCeil(u32, mounts, mounts_per_ammo_ton) catch 1;
        const have = gs.stockCount(side.site, entry.key_ptr.*);
        const use = @min(need, have);
        try side.ammo_reserved.put(gs.allocator(), entry.key_ptr.*, use);
        const fed = @min(mounts, use * mounts_per_ammo_ton);
        try family_fire_pct.put(gs.allocator(), entry.key_ptr.*, if (mounts == 0) 100 else fed * 100 / mounts);
    }

    for (company.children.items) |child_id| {
        const lance = gs.force(child_id) orelse continue;
        if (lance.echelon != .lance and lance.echelon != .air_lance) continue;
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
            if (u.status == .destroyed or u.status == .mothballed or u.status == .repairing or u.status == .refitting) continue;
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
            gunnery_sum += (pilot.skill(.gunnery_mek) orelse 4) + pilot.permanentPenalty();
            piloting_sum += (pilot.skill(.piloting_mek) orelse 5) + pilot.permanentPenalty();
            try side.engaged.append(gs.allocator(), uid);
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

    // People: fatigue & morale across the company.
    var fatigue_sum: u32 = 0;
    var morale_sum: u32 = 0;
    var n: u32 = 0;
    var pit = gs.people.iterator();
    while (pit.next()) |entry| {
        const p = entry.value_ptr;
        if (p.status != .active) continue;
        var f = p.assigned_force;
        const in_company = while (f != .none) {
            if (f == c.assigned_company) break true;
            f = (gs.forces.getPtr(f) orelse break false).parent;
        } else false;
        if (!in_company) continue;
        fatigue_sum += p.fatigue;
        morale_sum += p.morale;
        n += 1;
    }
    if (n > 0) {
        mods.avg_fatigue = @intCast(fatigue_sum / n);
        mods.avg_morale = @intCast(morale_sum / n);
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

fn ratioBonus(player_power: i64, enemy_power: i64) i32 {
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

pub fn resolveEngagement(gs: *GameState, c: *contract_mod.Contract) !void {
    var player = try playerSide(gs, c);
    defer player.engaged.deinit(gs.allocator());
    if (player.engaged.items.len == 0) {
        c.score -= 2;
        try gs.log(.battle, .{ .company = c.assigned_company, .contract = c.id }, "[AAR] {s}: no combat-effective units — objective conceded", .{@tagName(c.kind)});
        return;
    }

    // Enemy: strength relative to the player's committed BV, pirate rabble
    // to house regulars by employer's foe.
    const variance: types.Bp = (@as(types.Bp, gs.rng.roll2d6(.battle)) - 7) * 500;
    var enemy_bv = types.applyBp(player.bv, contract_mod.enemyStrengthBp(c.kind) + variance);
    // Attrition contracts (Stage 9E): the enemy can only field what's left
    // of their pool.
    if (c.objective == .attrition and c.enemy_pool_remaining > 0) enemy_bv = @min(enemy_bv, c.enemy_pool_remaining);
    const pirates = std.mem.eql(u8, c.enemy_key, "PER");
    const enemy_elem: autoresolve.Element = .{
        .base_strength = enemy_bv,
        .avg_gunnery = if (pirates) 5 else 4,
        .avg_piloting = if (pirates) 6 else 5,
    };
    const enemy_power = enemy_elem.effectivePower(.{});

    // One opposed roll decides the engagement (rounds within are abstracted;
    // ARCH §7 steps 3–4 collapse into the margin).
    const roll = @as(i32, gs.rng.roll2d6(.battle)) + ratioBonus(player.power, enemy_power);
    const outcome: autoresolve.Outcome = if (roll >= 11) .decisive_victory //
        else if (roll >= 8) .victory //
        else if (roll >= 6) .draw //
        else if (roll >= 4) .defeat //
        else .rout;

    // Player losses scale with how badly it went. // TUNE
    const hit_pct: u32 = switch (outcome) {
        .decisive_victory => 8,
        .victory => 15,
        .draw => 25,
        .defeat => 40,
        .rout => 55,
    };
    const enemy_loss_pct: u32 = switch (outcome) {
        .decisive_victory => 40,
        .victory => 25,
        .draw => 15,
        .defeat => 8,
        .rout => 4,
    };

    const engaged = player.engaged.items;
    const hits: u32 = @intCast(@max(
        @as(usize, if (outcome == .decisive_victory) 0 else 1),
        engaged.len * hit_pct / 100,
    ));
    var damage_value: types.CBills = 0;
    var destroyed: u8 = 0;
    var wounded: u8 = 0;
    var kia: u8 = 0;
    // The detailed AAR (Stage 12.23): every hit on record — which hull,
    // what it lost, what happened to the crew.
    const Hit = struct { unit: types.UnitId, armor_before: u8, armor_after: u8, slot: ?[]const u8, slot_part: []const u8, slot_result: []const u8, destroyed: bool, crew: []const u8 };
    var hit_log: std.ArrayListUnmanaged(Hit) = .empty;
    defer hit_log.deinit(gs.allocator());
    for (0..hits) |_| {
        const uid = engaged[gs.rng.random(.battle).uintLessThan(usize, engaged.len)];
        const u = gs.unit(uid) orelse continue;
        if (u.status == .destroyed) continue;

        const severity = gs.rng.roll2d6(.battle);
        var rec: Hit = .{ .unit = uid, .armor_before = u.armor_pct, .armor_after = 0, .slot = null, .slot_part = "", .slot_result = "", .destroyed = false, .crew = "" };
        u.armor_pct -|= @intCast(severity * 4);
        rec.armor_after = u.armor_pct;
        damage_value += @as(types.CBills, severity) * 20_000;

        if (severity >= 8 and u.slots.items.len > 0) {
            const slot = &u.slots.items[gs.rng.random(.battle).uintLessThan(usize, u.slots.items.len)];
            slot.condition = if (slot.condition == .ok) .damaged else .destroyed;
            rec.slot = slot.slot_key;
            rec.slot_part = slot.part_key;
            rec.slot_result = if (slot.condition == .damaged) "damaged" else "destroyed";
        }
        if (severity == 12 or (u.armor_pct == 0 and severity >= 10)) {
            u.status = .destroyed;
            destroyed += 1;
            rec.destroyed = true;
            damage_value += @divTrunc(u.purchase_price, 2);
        }

        // Crew casualties (AtB-style): a hard hit (8+) wounds the pilot on a
        // follow-up 2d6 of 8+, a crippling one (11+) always; the worst roll
        // kills unless a MASH lance is forward. MASH also halves the wound
        // chance on hard hits. // TUNE
        if (gs.person(u.pilot)) |p| {
            if (p.status == .active) {
                // Wound severity follows the hit (Stage 12.16): 8–9 light,
                // 10–11 serious, 12 crippling (survivable only with MASH).
                const wound_severity: u8 = if (severity >= 12) 3 else if (severity >= 10) 2 else 1;
                if (severity == 12 and !player.mods.has_mash_lance) {
                    p.status = .kia;
                    kia += 1;
                    rec.crew = try std.fmt.allocPrint(gs.allocator(), "{s} KIA", .{try p.rankedName(gs.allocator())});
                } else if (severity >= 11) {
                    try medical.inflict(gs, u.pilot, .combat, wound_severity, "battle");
                    wounded += 1;
                    rec.crew = try woundText(gs, p);
                } else if (severity >= 8) {
                    const need: u8 = if (player.mods.has_mash_lance) 9 else 8;
                    if (gs.rng.roll2d6(.battle) >= need) {
                        try medical.inflict(gs, u.pilot, .combat, wound_severity, "battle");
                        wounded += 1;
                        rec.crew = try woundText(gs, p);
                    }
                }
            }
        }
        try hit_log.append(gs.allocator(), rec);
    }

    // Spoils: salvage rights over the enemy's wrecks — but only if you held
    // the field (retreating forces strip nothing) — prisoners if you can
    // hold them, employer compensation for your losses.
    const held_field = outcome == .decisive_victory or outcome == .victory or outcome == .draw;
    const enemy_destroyed_bv = @divTrunc(enemy_bv * enemy_loss_pct, 100);
    // What the crews can actually haul off the field is bounded by the
    // salvage trucks on hand (300 BV-worth each; 150 hand-carried).
    var trucks: i64 = 0;
    var tit = gs.units.iterator();
    while (tit.next()) |entry| {
        const u = entry.value_ptr;
        if (u.status != .destroyed and std.mem.eql(u8, u.chassis_key, "SVT-1") and gs.companyOf(u.force) == c.assigned_company) trucks += 1;
    }
    const haulable_bv = @min(enemy_destroyed_bv, if (trucks > 0) trucks * tuning.battle.salvage_bv_per_truck else tuning.battle.salvage_bv_by_hand);
    // Salvage is things, not money (Stage 12.23): your share of what the
    // crews haul off a held field becomes wrecks and parts crated to the
    // home HQ depot — to store, strip, or rebuild into a working hull.
    var salvage_bv: i64 = if (held_field) @divTrunc(haulable_bv * c.terms.salvage_pct, 100) else 0;
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
    const ransom: types.CBills = if (held_field and player.mods.has_security_lance and enemy_loss_pct >= 15) 50_000 else 0;
    if (ransom > 0) {
        try gs.postTreasury(.{ .company = c.assigned_company }, .{
            .day = gs.clock.day_index,
            .amount = ransom,
            .category = .event,
            .company = c.assigned_company,
            .contract = c.id,
            .note = "prisoner ransom",
        });
    }
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
    c.battles_fought +|= 1;
    c.casualties +|= wounded + kia;

    const score_delta: i32 = switch (outcome) {
        .decisive_victory => 2,
        .victory => 1,
        .draw => 0,
        .defeat => c.terms.command_rights.defeatScore(),
        .rout => -2,
    };
    c.score += score_delta;
    var morale_delta: i32 = switch (outcome) {
        .decisive_victory => 5,
        .victory => 3,
        .draw => -1,
        .defeat => -5,
        .rout => -10,
    };
    if (morale_delta < 0 and player.mods.has_mess_lance) morale_delta += 2; // hot food after a bad day
    applyCompanyAftermath(gs, c.assigned_company, morale_delta, 4);
    for (engaged) |uid| {
        const u = gs.unit(uid) orelse continue;
        if (gs.person(u.pilot)) |p| {
            if (p.status == .active or p.status == .wounded)
                p.xp += if (score_delta > 0) 3 else 2;
        }
    }
    // Kill credits and the awards they earn (12B.5).
    const personnel = @import("personnel.zig");
    const kills_credited = try personnel.creditKills(gs, engaged, enemy_destroyed_bv);
    for (engaged) |uid| if (gs.unit(uid)) |u| {
        _ = try personnel.checkAwards(gs, u.pilot);
    };

    const ctx: @import("state.zig").LogCtx = .{ .company = c.assigned_company, .contract = c.id };
    try gs.log(.battle, ctx, "[AAR] {s} vs {s}: {s} — power {d} vs {d} (recon {d}, fatigue {d}, morale {d})", .{
        @tagName(c.kind),        c.enemy_key,            @tagName(outcome),
        player.power,            enemy_power,            player.mods.recon_quality,
        player.mods.avg_fatigue, player.mods.avg_morale,
    });
    try gs.log(.battle, ctx, "[AAR]   losses: {d} hit / {d} destroyed, {d} wounded, {d} KIA | enemy losses {d} BV ≈ {d} kill{s} credited | salvage {d} BV claimed | comp {d} | score {d}", .{
        hits, destroyed, wounded, kia, enemy_destroyed_bv, kills_credited, if (kills_credited == 1) "" else "s", salvage, comp, c.score,
    });
    // Every hit on record.
    for (hit_log.items) |h| {
        const u = gs.unit(h.unit) orelse continue;
        const ch = chassis_mod.find(u.chassis_key);
        try gs.log(.battle, ctx, "[AAR]   #{d} {s} {s}: {s}armor {d}%→{d}%{s}{s}{s}{s}", .{
            @intFromEnum(h.unit),
            u.chassis_key,
            if (ch) |d| d.name else "",
            if (h.destroyed) "DESTROYED · " else "",
            h.armor_before,
            h.armor_after,
            if (h.slot) |sk| try std.fmt.allocPrint(gs.allocator(), " · {s} ({s}) {s}", .{ sk, h.slot_part, h.slot_result }) else "",
            if (h.crew.len > 0) " · " else "",
            h.crew,
            if (!h.destroyed and h.slot == null and h.crew.len == 0) " · armor only" else "",
        });
    }
    if (spoils.len > 0) try gs.log(.battle, ctx, "[AAR]   salvage: {s}{s}", .{ spoils, if (liaison_cut > 0) try std.fmt.allocPrint(gs.allocator(), " (the employer's liaison claimed {d} BV under {s} command rights)", .{ liaison_cut, @tagName(c.terms.command_rights) }) else "" }) else if (held_field) try gs.log(.battle, ctx, "[AAR]   salvage: field held, nothing worth hauling ({d} BV destroyed, {d} haulable, {d}% rights)", .{ enemy_destroyed_bv, haulable_bv, c.terms.salvage_pct }) else try gs.log(.battle, ctx, "[AAR]   salvage: none — the field was not held", .{});
    var expended_ac5: u32 = 0;
    var expended_ac20: u32 = 0;
    var expended_lrm: u32 = 0;
    var expended_srm: u32 = 0;
    var expended_mg: u32 = 0;
    var eit = player.ammo_reserved.iterator();
    while (eit.next()) |entry| {
        const k = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        if (std.mem.eql(u8, k, "ammo_ac5")) expended_ac5 = v;
        if (std.mem.eql(u8, k, "ammo_ac20")) expended_ac20 = v;
        if (std.mem.eql(u8, k, "ammo_lrm")) expended_lrm = v;
        if (std.mem.eql(u8, k, "ammo_srm")) expended_srm = v;
        if (std.mem.eql(u8, k, "ammo_mg")) expended_mg = v;
    }
    try gs.log(.battle, ctx, "[AAR]   expended: {d}t AC/5, {d}t AC/20, {d}t LRM, {d}t SRM, {d}t MG | {d} mounts silenced (dry) | left in the trucks: {d}t AC/5, {d}t AC/20, {d}t LRM, {d}t SRM, {d}t MG, {d}t armor", .{
        expended_ac5,                                 expended_ac20,                                 expended_lrm,                                 expended_srm,                                 expended_mg,                                 player.silenced_mounts,
        gs.stockCount(player.site, "ammo_ac5"),      gs.stockCount(player.site, "ammo_ac20"),      gs.stockCount(player.site, "ammo_lrm"),      gs.stockCount(player.site, "ammo_srm"),      gs.stockCount(player.site, "ammo_mg"),      gs.stockCount(player.site, "armor"),
    });

    // Objectives (Stage 9E): the pool shrinks, VP accrue, and a broken pool
    // completes the contract.
    try @import("contract_control.zig").recordBattle(gs, c, enemy_destroyed_bv, score_delta);
}

/// "Lori Kalmar wounded (serious torso)" from the injury just inflicted.
fn woundText(gs: *GameState, p: *const person_mod.Person) ![]const u8 {
    if (p.injuries.items.len == 0) return try std.fmt.allocPrint(gs.allocator(), "{s} wounded", .{try p.rankedName(gs.allocator())});
    const inj = p.injuries.items[p.injuries.items.len - 1];
    return try std.fmt.allocPrint(gs.allocator(), "{s} wounded ({s} {s}{s})", .{ try p.rankedName(gs.allocator()), medical.severityLabel(inj.severity), @tagName(inj.location), if (inj.permanent) ", permanent" else "" });
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
    const planet_mod = @import("../domain/planet.zig");
    const logistics = @import("../econ/logistics.zig");
    const home = gs.hqs.getPtr(gs.homeHqFor(c.assigned_company));
    const from = planet_mod.find(c.planet_key);
    const to = if (home) |h| planet_mod.find(h.planet_key) else null;
    const days: u32 = if (from != null and to != null and from.? != to.?) logistics.transitDays(planet_mod.jumpsBetween(from.?, to.?)) else 3;

    // Wrecks: up to two per battle, each a RAT roll that must fit the claim.
    var wrecks: u32 = 0;
    var tries: u8 = 0;
    while (wrecks < 2 and tries < 4) : (tries += 1) {
        var buf: [32]*const chassis_mod.Chassis = undefined;
        const pool = chassis_mod.ofWeightClass(company_gen.rollWeightClass(&gs.rng), &buf);
        if (pool.len == 0) continue;
        const design = pool[gs.rng.random(.battle).uintLessThan(usize, pool.len)];
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
        try text.appendSlice(gs.allocator(), try std.fmt.allocPrint(gs.allocator(), "wreck #{d} {s} {s} (armor {d}%, {d} destroyed, {d} missing) → home depot in {d} days; ", .{
            @intFromEnum(uid), design.key, design.name, cond.armor_pct, cond.destroyed_slots, cond.missing_components, days,
        }));
    }
    // Parts: components, then weapons, then armor, at BV prices.
    const t = tuning.battle;
    var components: u32 = 0;
    const comp_keys = [_][]const u8{ "comp_arm", "comp_leg", "comp_torso" };
    while (remaining >= t.salvage_bv_per_component and components < 3) : (components += 1) {
        remaining -= t.salvage_bv_per_component;
        try gs.sendHome(c.assigned_company, comp_keys[components % comp_keys.len], 1);
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
        if (p.status != .active) continue;
        var f = p.assigned_force;
        const in_company = while (f != .none) {
            if (f == company) break true;
            f = (gs.forces.getPtr(f) orelse break false).parent;
        } else false;
        if (!in_company) continue;
        p.morale = @intCast(std.math.clamp(@as(i32, p.morale) + morale_delta, 0, 100));
        p.fatigue = @min(100, p.fatigue + fatigue_add);
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
