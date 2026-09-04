//! Battle autoresolution (Stage 7, ARCH §7) — descended from MekHQ's ACAR.
//! Combat-class contracts schedule engagements every few weeks; each
//! resolves without the player from what the campaign built: BV and crew
//! skill, machine condition, fatigue and morale, the support echelon, and
//! recon. Damage lands on real part slots, casualties go to the infirmary,
//! salvage and battle-loss comp hit the ledger, and the AAR names the
//! reasons. Legibility over drama: a loss should trace to causes.

const std = @import("std");
const types = @import("../domain/types.zig");
const autoresolve = @import("autoresolve.zig");
const contract_mod = @import("../domain/contract.zig");
const chassis_mod = @import("../domain/chassis.zig");
const force_mod = @import("../domain/force.zig");
const part_mod = @import("../domain/part.zig");
const GameState = @import("state.zig").GameState;

/// Days between engagements: ~2/month with variance. // TUNE
fn nextBattleGap(gs: *GameState) u32 {
    return 8 + gs.rng.roll2d6(.battle);
}

/// battle_resolution phase, daily: schedule and resolve engagements for
/// active combat-class contracts.
pub fn runDaily(gs: *GameState) !void {
    var it = gs.contracts.iterator();
    while (it.next()) |entry| {
        const c = entry.value_ptr;
        if (c.status != .active or c.kind.isGarrisonClass()) continue;
        if (c.next_battle_day == null) {
            c.next_battle_day = gs.clock.day_index + nextBattleGap(gs);
            continue;
        }
        if (gs.clock.day_index >= c.next_battle_day.?) {
            try resolveEngagement(gs, c);
            c.next_battle_day = gs.clock.day_index + nextBattleGap(gs);
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
/// (~10 turns of fire at tabletop rates). // TUNE
const mounts_per_ammo_ton = 3;

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
                const penalty_pct: i64 = @divTrunc(60 * @as(i64, silenced_x100), 100 * @as(i64, mounts)); // TUNE
                unit_bv = @divTrunc(unit_bv * (100 - penalty_pct), 100);
                side.silenced_mounts += (silenced_x100 + 50) / 100;
            }
            lance_bv += unit_bv;
            condition_sum += u.conditionPct();
            quality_sum += @intFromEnum(u.quality);
            gunnery_sum += pilot.skill(.gunnery_mek) orelse 4;
            piloting_sum += pilot.skill(.piloting_mek) orelse 5;
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
        side.power += elem.effectivePower(side.mods);
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
        if (child.echelon == .lance and child.role == .scouting and child.units.items.len > 0)
            mods.recon_quality = 2;
        if (child.echelon == .air_company) mods.has_air_cover = true;
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
    for (0..hits) |_| {
        const uid = engaged[gs.rng.random(.battle).uintLessThan(usize, engaged.len)];
        const u = gs.unit(uid) orelse continue;
        if (u.status == .destroyed) continue;

        const severity = gs.rng.roll2d6(.battle);
        u.armor_pct -|= @intCast(severity * 4);
        damage_value += @as(types.CBills, severity) * 20_000;

        if (severity >= 8 and u.slots.items.len > 0) {
            const slot = &u.slots.items[gs.rng.random(.battle).uintLessThan(usize, u.slots.items.len)];
            slot.condition = if (slot.condition == .ok) .damaged else .destroyed;
        }
        if (severity == 12 or (u.armor_pct == 0 and severity >= 10)) {
            u.status = .destroyed;
            destroyed += 1;
            damage_value += @divTrunc(u.purchase_price, 2);
        }

        // Crew casualties: MASH coverage turns the worst rolls survivable.
        if (gs.person(u.pilot)) |p| {
            if (severity == 12 and !player.mods.has_mash_lance and p.status == .active) {
                p.status = .kia;
                kia += 1;
            } else if (severity >= 10 and p.status == .active) {
                p.status = .wounded;
                wounded += 1;
            }
        }
    }

    // Spoils: salvage rights over the enemy's wrecks — but only if you held
    // the field (retreating forces strip nothing) — prisoners if you can
    // hold them, employer compensation for your losses.
    const held_field = outcome == .decisive_victory or outcome == .victory or outcome == .draw;
    const enemy_destroyed_bv = @divTrunc(enemy_bv * enemy_loss_pct, 100);
    // What the crews can actually haul off the field is bounded by the
    // salvage trucks on hand (400 BV-worth each; 200 hand-carried). // TUNE
    var trucks: i64 = 0;
    var tit = gs.units.iterator();
    while (tit.next()) |entry| {
        const u = entry.value_ptr;
        if (u.status != .destroyed and std.mem.eql(u8, u.chassis_key, "SVT-1") and gs.companyOf(u.force) == c.assigned_company) trucks += 1;
    }
    const haulable_bv = @min(enemy_destroyed_bv, if (trucks > 0) trucks * 300 else 150);
    var salvage: types.CBills = if (held_field)
        @divTrunc(haulable_bv * 2_000 * c.terms.salvage_pct, 100)
    else
        0;
    if (player.mods.has_salvage_lance) salvage = types.applyBp(salvage, 12_500); // crews strip fast
    // Field income lands in the company's local funds (Stage 9A): sold
    // salvage and ransoms are cash-in-hand out there, not a wire home.
    if (salvage > 0) {
        try gs.postTreasury(.{ .company = c.assigned_company }, .{
            .day = gs.clock.day_index,
            .amount = salvage,
            .category = .salvage,
            .company = c.assigned_company,
            .contract = c.id,
            .note = "battlefield salvage",
        });
        // Stripped limbs ride home in the trucks — if there's room to spare
        // after the reloads (crews won't bury the ammo under wrecks).
        const stripped: u32 = @intCast(@min(2, @divTrunc(enemy_destroyed_bv, 500)));
        const salvage_keys = [_][]const u8{ "comp_arm", "comp_leg" };
        for (0..stripped) |i| {
            const key = salvage_keys[i % salvage_keys.len];
            if (gs.siteFreeTons(player.site) -| 20 >= part_mod.tons(key)) try gs.addStock(player.site, key, 1);
        }
    }

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
        .defeat => -1,
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

    const ctx: @import("state.zig").LogCtx = .{ .company = c.assigned_company, .contract = c.id };
    try gs.log(.battle, ctx, "[AAR] {s} vs {s}: {s} — power {d} vs {d} (recon {d}, fatigue {d}, morale {d})", .{
        @tagName(c.kind),          c.enemy_key,           @tagName(outcome),
        player.power,              enemy_power,           player.mods.recon_quality,
        player.mods.avg_fatigue,   player.mods.avg_morale,
    });
    try gs.log(.battle, ctx, "[AAR]   losses: {d} hit / {d} destroyed, {d} wounded, {d} KIA | salvage {d} | comp {d} | score {d}", .{
        hits, destroyed, wounded, kia, salvage, comp, c.score,
    });
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
    try gs.log(.battle, ctx, "[AAR]   expended: {d}t AC/5, {d}t AC/20, {d}t LRM, {d}t SRM, {d}t MG | {d} mounts silenced (dry)", .{
        expended_ac5, expended_ac20, expended_lrm, expended_srm, expended_mg, player.silenced_mounts,
    });

    // Objectives (Stage 9E): the pool shrinks, VP accrue, and a broken pool
    // completes the contract.
    try @import("contract_control.zig").recordBattle(gs, c, enemy_destroyed_bv, score_delta);
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
    try std.testing.expect(gs.event_log.items.len >= 24); // 2 lines per AAR

    // And the ledger saw salvage income at 30% rights.
    const s = @import("../econ/finance.zig").summarize(&gs.ledger, 0, gs.clock.day_index + 1, .all);
    try std.testing.expect(s.category(.salvage) > 0);
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
