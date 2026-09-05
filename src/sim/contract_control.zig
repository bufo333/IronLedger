//! Contract objectives, lifecycle control & the breach clause (Stage 9E,
//! ARCH §7/§11). Duration contracts hold until the end date; attrition
//! contracts grind an opposition pool down across battles and can be
//! closed out once it's substantially broken. Recalling early, or falling
//! below half strength with no replacements bought in time, triggers the
//! breach clause: advance clawback, forfeited remainder, reputation, and a
//! cooling employer.

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const contract_mod = @import("../domain/contract.zig");
const chassis_mod = @import("../domain/chassis.zig");
const planet_mod = @import("../domain/planet.zig");
const logistics = @import("../econ/logistics.zig");
const GameState = @import("state.zig").GameState;

pub const grace_days: u32 = tuning.contract.grace_days;
pub const cooling_days: u32 = tuning.contract.cooling_days;

/// Combat BV a company can actually field today: hulls with a fit pilot,
/// not destroyed, not in the depot.
pub fn fieldableBv(gs: *GameState, company: types.ForceId) i64 {
    var total: i64 = 0;
    var it = gs.units.iterator();
    while (it.next()) |entry| {
        const u = entry.value_ptr;
        if (gs.companyOf(u.force) != company or !u.kind.isCombat()) continue;
        if (u.status == .destroyed or u.status == .repairing or u.status == .mothballed or u.status == .in_transit) continue;
        const pilot = gs.person(u.pilot) orelse continue;
        if (!pilot.isAvailable(gs.clock.day_index)) continue;
        const design = chassis_mod.find(u.chassis_key) orelse continue;
        total += design.bv;
    }
    return total;
}

/// At acceptance: set the objective, remember what was committed, and
/// size the opposition.
pub fn onAccept(gs: *GameState, c: *contract_mod.Contract) void {
    c.objective = contract_mod.objectiveFor(c.kind);
    c.committed_bv = fieldableBv(gs, c.assigned_company);
    if (c.objective == .attrition) {
        c.enemy_pool_bv = types.applyBp(c.committed_bv, contract_mod.enemyPoolBp(c.kind, c.terms.length_months));
        c.enemy_pool_remaining = c.enemy_pool_bv;
    }
}

/// After a battle: the pool shrinks, victory points accrue, and a broken
/// pool completes the objective outright.
pub fn recordBattle(gs: *GameState, c: *contract_mod.Contract, enemy_destroyed_bv: i64, score_delta: i32) !void {
    c.victory_points += score_delta * 5;
    if (c.objective != .attrition) return;
    c.enemy_pool_remaining = @max(0, c.enemy_pool_remaining - enemy_destroyed_bv);
    c.victory_points += @intCast(@divTrunc(enemy_destroyed_bv * 20, @max(1, c.enemy_pool_bv)));
    if (c.enemy_pool_remaining == 0) {
        try complete(gs, c, true);
    } else if (c.objectivesMet()) {
        try gs.log(.contract, .{ .company = c.assigned_company, .contract = c.id }, "[objective] {s}: opposition {d}% destroyed — objectives substantially met; `complete` to close out, or keep grinding", .{
            @tagName(c.kind), c.poolDestroyedPct(),
        });
    }
}

/// Close a contract out. `objectives_broken` (the pool hit zero) earns the
/// completion bonus — half the remaining payments; an early close-out on a
/// substantially-met objective forfeits the remainder without breach.
pub fn complete(gs: *GameState, c: *contract_mod.Contract, objectives_broken: bool) !void {
    if (c.status != .active) return;
    const months_left: i64 = if (c.end_day) |end| @divTrunc(@as(i64, end) - @as(i64, gs.clock.day_index), 30) else 0;
    if (objectives_broken and months_left > 0) {
        const bonus = @divTrunc(c.monthly_net * @max(0, months_left), 2);
        try gs.postTransaction(.{
            .day = gs.clock.day_index,
            .amount = bonus,
            .category = .contract_payment,
            .company = c.assigned_company,
            .contract = c.id,
            .note = "early completion bonus",
        });
    }
    c.status = .completed;
    // Reputation by victory points: a tour in the red earns none (12.19:
    // a raid closed at −8 VP was still "reputation rises"). // TUNE
    const vp_bonus = std.math.clamp(@divTrunc(c.victory_points, 25), -1, 3);
    const gain: i32 = if (c.victory_points < 0) vp_bonus else 1 + vp_bonus; // −8 VP → 0, −25 VP → −1
    gs.reputation += gain;
    // Standing (12.21): the employer remembers a tour served, and so does
    // whoever you served it against.
    const t = tuning.contract;
    const employer_now = try gs.adjustStanding(c.employer_key, @max(2, t.standing_complete_gain + @divTrunc(c.victory_points, 10)) + @as(i32, @intFromBool(c.beachhead)) * 2);
    const enemy_now = if (!std.mem.eql(u8, c.enemy_key, "PER")) try gs.adjustStanding(c.enemy_key, -t.standing_enemy_loss) else 0;
    try gs.log(.contract, .{ .company = c.assigned_company, .contract = c.id }, "[standing] {s} +{d} → {d}{s}", .{ c.employer_key, @max(2, t.standing_complete_gain + @divTrunc(c.victory_points, 10)), employer_now, if (!std.mem.eql(u8, c.enemy_key, "PER")) try std.fmt.allocPrint(gs.allocator(), " · {s} −{d} → {d}", .{ c.enemy_key, t.standing_enemy_loss, enemy_now }) else "" });
    try finishTour(gs, c);
    try gs.log(.contract, .{ .company = c.assigned_company, .contract = c.id }, "[{s}] contract COMPLETE ({s}, {d} VP, score {d}) — reputation {s}", .{
        @tagName(c.kind), if (objectives_broken) "objectives broken" else "closed out", c.victory_points, c.score, if (vp_bonus > 0) "soars" else if (gain > 0) "rises" else if (gain == 0) "unchanged" else "slips",
    });
}

/// The breach clause: recalled early, or combat-ineffective with no
/// replacements in time. Pro-rated advance back, remainder forfeited,
/// reputation −2, and the employer's faction cools for a year.
pub fn breach(gs: *GameState, c: *contract_mod.Contract, reason: []const u8) !void {
    if (c.status != .active and c.status != .transit) return;
    const total_days: i64 = @as(i64, c.terms.length_months) * 30;
    const elapsed: i64 = if (c.start_day) |s| @as(i64, gs.clock.day_index) - @as(i64, s) else 0;
    const remaining_frac_bp: types.Bp = @intCast(std.math.clamp(@divTrunc((total_days - elapsed) * 10_000, @max(1, total_days)), 0, 10_000));
    const clawback = types.applyBp(c.terms.advanceAmount(), remaining_frac_bp);
    if (clawback > 0) {
        try gs.postTransaction(.{
            .day = gs.clock.day_index,
            .amount = -clawback,
            .category = .breach_clawback,
            .company = c.assigned_company,
            .contract = c.id,
            .note = "advance clawback",
        });
    }
    c.status = .breached;
    c.breach_day = gs.clock.day_index;
    gs.reputation -= 2;
    try gs.faction_cooling.append(gs.allocator(), .{ .faction = c.employer_key, .until_day = gs.clock.day_index + cooling_days });
    const standing_now = try gs.adjustStanding(c.employer_key, -tuning.contract.standing_breach_loss);
    try gs.log(.contract, .{ .company = c.assigned_company, .contract = c.id }, "[standing] {s} −{d} → {d}", .{ c.employer_key, tuning.contract.standing_breach_loss, standing_now });
    try finishTour(gs, c);
    try gs.log(.contract, .{ .company = c.assigned_company, .contract = c.id }, "[{s}] CONTRACT BREACHED ({s}) — {d} clawed back, remainder forfeited, {s} employers cool for a year", .{
        @tagName(c.kind), reason, clawback, c.employer_key,
    });
}

/// Shared end-of-tour bookkeeping: the company stays on the world it
/// worked until recalled or redeployed.
fn finishTour(gs: *GameState, c: *const contract_mod.Contract) !void {
    if (gs.force(c.assigned_company)) |f| {
        f.location_planet = c.planet_key;
        f.contracts_since_rotation += 1;
    }
}

/// Send a company home from wherever it is. Recalling mid-contract is a
/// breach. Returns the days until it arrives.
pub fn recall(gs: *GameState, company: types.ForceId) !u32 {
    if (gs.deploymentContract(company)) |c| {
        if (c.status == .active) try breach(gs, c, "recalled by command") else {
            // Aborted in transit: no clawback, no fee — the dropships turn
            // around from the destination they were bound for.
            c.status = .breached;
            c.breach_day = gs.clock.day_index;
            if (gs.force(company)) |f| f.location_planet = c.planet_key;
        }
    }
    const f = gs.force(company) orelse return 0;
    const from_key = f.location_planet orelse return 0;
    const home = gs.hqs.getPtr(gs.homeHqFor(company)) orelse return 0;
    const a = planet_mod.find(from_key) orelse return 0;
    const b = planet_mod.find(home.planet_key) orelse return 0;
    const days = if (a == b) 3 else logistics.transitDays(planet_mod.jumpsBetween(a, b));
    f.return_eta_day = gs.clock.day_index + days;
    f.location_planet = null;
    try gs.log(.contract, .{ .company = company }, "[movement] {s} recalled home — {d} days in transit", .{ f.name, days });
    return days;
}

/// Daily: the combat-ineffectiveness clock. Below half the committed
/// force, the grace window opens (buy local replacements with local
/// funds); expire it unfilled and the employer declares breach.
pub fn checkEffectiveness(gs: *GameState) !void {
    var it = gs.contracts.iterator();
    while (it.next()) |entry| {
        const c = entry.value_ptr;
        if (c.status != .active or c.committed_bv <= 0) continue;
        const now = fieldableBv(gs, c.assigned_company);
        const effective = now * 2 >= c.committed_bv;
        if (effective) {
            if (c.ineffective_since != null) {
                c.ineffective_since = null;
                try gs.log(.contract, .{ .company = c.assigned_company, .contract = c.id }, "[objective] company back above half strength — employer satisfied", .{});
            }
            continue;
        }
        if (c.ineffective_since == null) {
            c.ineffective_since = gs.clock.day_index;
            try gs.log(.contract, .{ .company = c.assigned_company, .contract = c.id }, "[objective] COMBAT-INEFFECTIVE: fieldable {d} BV of {d} committed — {d} days to buy replacements locally or be declared in breach", .{
                now, c.committed_bv, grace_days,
            });
        } else if (gs.clock.day_index >= c.ineffective_since.? + grace_days) {
            try breach(gs, c, "combat-ineffective past the grace window");
        }
    }
}

/// The transports that sailed with a company (Stage 12.15) go back to
/// their berths once it is home. Returns how many.
pub fn releaseCarriers(gs: *GameState, company: types.ForceId) !u32 {
    var n: u32 = 0;
    var it = gs.units.iterator();
    while (it.next()) |entry| {
        const u = entry.value_ptr;
        if (!u.kind.isTransport() or u.force != company) continue;
        if (gs.force(company)) |f| {
            for (f.units.items, 0..) |id, i| if (id == u.id) {
                _ = f.units.orderedRemove(i);
                break;
            };
        }
        u.force = .none;
        if (gs.person(u.pilot)) |p| p.assigned_force = .none;
        n += 1;
    }
    return n;
}

/// Payday: standing drifts back toward neutral — grudges and gratitude
/// both fade (Stage 12.21).
pub fn driftStanding(gs: *GameState) void {
    const step = tuning.contract.standing_drift_per_month;
    var it = gs.faction_standing.iterator();
    while (it.next()) |entry| {
        const v = entry.value_ptr;
        if (v.* > 0) v.* -= @min(step, v.*) else if (v.* < 0) v.* += @min(step, -v.*);
    }
}

/// Daily: companies travelling home arrive.
pub fn runReturns(gs: *GameState) !void {
    var it = gs.forces.iterator();
    while (it.next()) |entry| {
        const f = entry.value_ptr;
        if (f.return_eta_day) |eta| if (gs.clock.day_index >= eta) {
            f.return_eta_day = null;
            f.location_planet = null;
            const ships = try releaseCarriers(gs, f.id);
            try gs.log(.contract, .{ .company = f.id }, "[movement] {s} is home{s}", .{ f.name, if (ships > 0) " — its ships return to their berths" else "" });
        };
    }
}

test "attrition contracts break when the pool does; duration ones don't care" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 50 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    const co = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha");

    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .objective_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
        .start_day = 0,
        .end_day = 180,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    onAccept(&gs, c);
    try std.testing.expectEqual(contract_mod.ObjectiveKind.attrition, c.objective);
    try std.testing.expect(c.enemy_pool_bv > c.committed_bv);

    // Grind 80% of the pool: objectives substantially met, still active.
    try recordBattle(&gs, c, @divTrunc(c.enemy_pool_bv * 8, 10), 2);
    try std.testing.expect(c.objectivesMet());
    try std.testing.expectEqual(contract_mod.ContractStatus.active, c.status);
    // Finish it: pool broken → completed with a bonus and VP-scaled reputation.
    const funds_before = gs.funds;
    try recordBattle(&gs, c, c.enemy_pool_remaining, 1);
    try std.testing.expectEqual(contract_mod.ContractStatus.completed, c.status);
    try std.testing.expect(gs.funds > funds_before);
    try std.testing.expect(gs.reputation >= 2);
    try std.testing.expectEqualStrings("galatea", gs.force(co).?.location_planet.?);
}

test "the breach clause: clawback, reputation, cooling employer" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 51 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .FS, .paymaster);
    const co = try gs.createForce("Alpha", .company, .none);
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .garrison_duty,
        .employer_key = "FS",
        .enemy_key = "PER",
        .planet_key = "caph",
        .terms = .{ .length_months = 12, .base_pay_month = 400_000, .advance_pct = 25 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
        .start_day = 0,
        .end_day = 360,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    gs.clock.day_index = 90; // a quarter in: 75% of the advance comes back
    const rep_before = gs.reputation;
    const funds_before = gs.funds;
    _ = try recall(&gs, co);
    try std.testing.expectEqual(contract_mod.ContractStatus.breached, c.status);
    try std.testing.expectEqual(funds_before - @divTrunc(c.terms.advanceAmount() * 3, 4), gs.funds);
    try std.testing.expectEqual(rep_before - 2, gs.reputation);
    try std.testing.expect(gs.factionCooling("FS"));
    try std.testing.expect(!gs.factionCooling("LC"));
    try std.testing.expect(gs.force(co).?.return_eta_day != null);
}

test "combat-ineffective past the grace window is breach" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 52 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .DC, .chief_engineer);
    const co = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "DC",
        .enemy_key = "LC",
        .planet_key = "dyev",
        .terms = .{ .length_months = 3, .base_pay_month = 400_000 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
        .start_day = 0,
        .end_day = 90,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    onAccept(&gs, c);

    // Wreck most of the company.
    var uit = gs.units.iterator();
    var wrecked: u32 = 0;
    while (uit.next()) |entry| {
        if (entry.value_ptr.kind == .mek and wrecked < 12) {
            entry.value_ptr.status = .destroyed;
            wrecked += 1;
        }
    }
    try checkEffectiveness(&gs);
    try std.testing.expect(c.ineffective_since != null);
    try std.testing.expectEqual(contract_mod.ContractStatus.active, c.status);
    gs.clock.day_index += grace_days + 1;
    try checkEffectiveness(&gs);
    try std.testing.expectEqual(contract_mod.ContractStatus.breached, c.status);
}

test "12.21: standing rises with the employer and falls with the enemy on completion, drops on breach, drifts home" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1221 });
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
        .monthly_net = 300_000,
        .victory_points = 30,
    });
    try complete(&gs, gs.contracts.getPtr(@enumFromInt(1)).?, true);
    try std.testing.expect(gs.standing("LC") >= 5);
    try std.testing.expect(gs.standing("DC") < 0);
    const lc_after = gs.standing("LC");
    driftStanding(&gs);
    try std.testing.expectEqual(lc_after - 1, gs.standing("LC"));
    // A breach with the Combine drops them well below the shun line over a couple of tours.
    try gs.contracts.put(gs.allocator(), @enumFromInt(2), .{
        .id = @enumFromInt(2),
        .kind = .garrison_duty,
        .employer_key = "DC",
        .enemy_key = "PER",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
    });
    try breach(&gs, gs.contracts.getPtr(@enumFromInt(2)).?, "test");
    try std.testing.expect(gs.standing("DC") <= -20);
}
