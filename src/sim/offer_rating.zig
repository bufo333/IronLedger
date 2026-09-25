//! How one company would fare on one contract (Stage 12E), and how much
//! of the opposition the outfit's comms let it see. MekHQ has no
//! counterpart: AtB shows the player the scenario's forces outright. This
//! is combat math (`battle.estimatePower`, the scenario tables, the ROE
//! modifiers): the checklist warns from it and the board colours it, so
//! it lives here and `queries` phrases it.

const std = @import("std");
const types = @import("../domain/types.zig");
const tuning = @import("../domain/tuning.zig").t;
const contract_mod = @import("../domain/contract.zig");
const planet_mod = @import("../domain/planet.zig");
const opfor = @import("../domain/opfor.zig");
const skulls = @import("../domain/skulls.zig");
const scenario = @import("../domain/scenario.zig");
const terrain = @import("../domain/terrain.zig");
const force_mod = @import("../domain/force.zig");
const battle = @import("battle.zig");
const rating = @import("rating.zig");
const GameState = @import("state.zig").GameState;

/// How well one HQ reads an opposition: its comms level, one more for a
/// B-or-better outfit rating (employers share).
pub fn intelLevel(gs: *GameState, hq_id: types.HqId) u8 {
    const comms: u8 = if (gs.hqs.getPtr(hq_id)) |hq| hq.effectiveFacilityLevel(.comms) else 0;
    return comms + @intFromBool(rating.currentIndex(gs) >= 3);
}

/// The enemy's lance count as the intel reads it: exact from
/// comms 3, within a lance either way from comms 1, the kind's whole
/// range blind.
pub const LanceIntel = struct { lo: u8, hi: u8, mid: u8, exact: bool };

/// The HQ whose comms read a contract's opposition: the board that
/// offered it, else the company's home HQ.
pub fn intelHq(gs: *GameState, c: *const contract_mod.Contract) types.HqId {
    if (c.offer_hq != .none and gs.hqs.getPtr(c.offer_hq) != null) return c.offer_hq;
    return gs.homeHqFor(c.assigned_company);
}

pub fn lanceIntel(gs: *GameState, c: *const contract_mod.Contract) LanceIntel {
    const intel = intelLevel(gs, intelHq(gs, c));
    const row = opfor.rowFor(c.kind);
    if (intel >= 3) return .{ .lo = c.enemy_lances, .hi = c.enemy_lances, .mid = c.enemy_lances, .exact = true };
    if (intel >= 1) {
        const lo = @max(row.lances_min, c.enemy_lances -| 1);
        const hi = @min(row.lances_max, c.enemy_lances + 1);
        return .{ .lo = lo, .hi = hi, .mid = (lo + hi + 1) / 2, .exact = lo == hi };
    }
    return .{ .lo = row.lances_min, .hi = row.lances_max, .mid = (row.lances_min + row.lances_max + 1) / 2, .exact = row.lances_min == row.lances_max };
}

/// One company against one contract: skulls (a range when the intel
/// cannot count the enemy's lances), the tonnage on both sides, and the
/// chance of winning a fight or losing the field.
pub const OfferRating = struct {
    company: types.ForceId,
    /// Half skulls against the fewest and the most lances the intel allows
    /// (equal when the count is known).
    half_lo: u8,
    half_hi: u8,
    /// Power ratio (own ÷ enemy, bp) at the intel's best estimate.
    ratio_bp: types.Bp,
    outmatched: bool,
    own: battle.Estimate,
    enemy_tons_lo: u32,
    enemy_tons_hi: u32,
    /// Chance to win a fight (victory or better) and to give up the field
    /// (defeat or rout; a draw too under cautious ROE), averaged exactly
    /// over the contract kind's scenario table.
    win_pct: u32,
    lose_field_pct: u32,
    exact: bool,

    /// The rating the screens warn about: the upper skull estimate at or
    /// past `skulls.table.warn_half_skulls`.
    pub fn warrantsWarning(self: OfferRating) bool {
        return self.half_hi >= skulls.table.warn_half_skulls;
    }
};

pub fn rateOffer(alloc: std.mem.Allocator, gs: *GameState, c: *const contract_mod.Contract, company: types.ForceId) !?OfferRating {
    if (!c.hasOpfor()) return null;
    const own = try battle.estimatePower(gs, alloc, c, company);
    const intel = intelLevel(gs, intelHq(gs, c));
    // Garrison work meets a probe, not the whole force.
    const probe: ?u8 = if (c.kind.isGarrisonClass()) @min(tuning.battle.garrison_probe_lances, c.enemy_lances) else null;
    const li = lanceIntel(gs, c);
    const exact = li.exact or probe != null;
    const lo: i64 = probe orelse li.lo;
    const hi: i64 = probe orelse li.hi;
    const mid: i64 = probe orelse li.mid;
    const sk = opfor.skills(if (intel >= 1) c.enemy_quality else .regular);
    const faces = scenario.faces(c.kind);
    var mean_bp: i64 = 0;
    for (faces) |f| mean_bp += f.enemy_bp;
    mean_bp = @divTrunc(mean_bp, faces.len);
    const Power = struct {
        fn at(gs_: *GameState, lance_bv: i64, lances: i64, scen_bp: i64, g: u8, p: u8) i64 {
            const elem: @import("autoresolve.zig").Element = .{ .base_strength = types.applyBp(types.applyBp(lance_bv * lances, gs_.diff().enemy_bp), @intCast(scen_bp)), .avg_gunnery = g, .avg_piloting = p };
            return elem.effectivePower(.{});
        }
    };
    const ratio_lo = skulls.ratioBp(own.power, Power.at(gs, c.enemy_lance_bv, lo, mean_bp, sk[0], sk[1]));
    const ratio_hi = skulls.ratioBp(own.power, Power.at(gs, c.enemy_lance_bv, hi, mean_bp, sk[0], sk[1]));
    const ratio_mid = skulls.ratioBp(own.power, Power.at(gs, c.enemy_lance_bv, mid, mean_bp, sk[0], sk[1]));
    // The dice, face by face: ratio bonus (capped in close terrain),
    // the scenario's tilt, scouts, and the company's rules of engagement.
    const close = if (planet_mod.find(c.planet_key)) |w| (terrain.Environment{ .terrain = terrain.terrainOf(w) }).close() else false;
    const roe = battle.effectiveRoe(gs, c, company);
    const roe_roll: i32 = switch (roe) {
        .hold => tuning.loss.roe.hold_roll,
        .standard => 0,
        .cautious => tuning.loss.roe.cautious_roll,
    };
    var win: u32 = 0;
    var lose: u32 = 0;
    for (faces) |f| {
        var bonus = battle.ratioBonus(own.power, Power.at(gs, c.enemy_lance_bv, mid, f.enemy_bp, sk[0], sk[1]));
        if (close) bonus = @min(bonus, 2);
        const mods: i32 = bonus + f.roll_mod + (if (own.recon) @as(i32, f.scout_bonus) else 0) + roe_roll;
        win += skulls.chanceAtLeast(8, mods);
        lose += 100 - skulls.chanceAtLeast(if (roe == .cautious) 8 else 6, mods);
    }
    return .{
        .company = company,
        .half_lo = skulls.fromRatioBp(ratio_lo),
        .half_hi = skulls.fromRatioBp(ratio_hi),
        .ratio_bp = ratio_mid,
        .outmatched = skulls.outmatched(ratio_mid),
        .own = own,
        .enemy_tons_lo = c.enemy_lance_tons * @as(u32, @intCast(lo)),
        .enemy_tons_hi = c.enemy_lance_tons * @as(u32, @intCast(hi)),
        .win_pct = win / @as(u32, faces.len),
        .lose_field_pct = lose / @as(u32, faces.len),
        .exact = exact,
    };
}

/// "3.5 skulls", "2–4 skulls", "3 skulls (outmatched)": the number the
/// checklist and the board both print.
pub fn skullText(alloc: std.mem.Allocator, r: OfferRating) ![]const u8 {
    var a: [8]u8 = undefined;
    var b: [8]u8 = undefined;
    const lo = skulls.number(&a, r.half_lo);
    if (r.half_lo == r.half_hi) return try std.fmt.allocPrint(alloc, "{s} skull{s}{s}", .{ lo, if (r.half_lo == 2) "" else "s", if (r.outmatched) " (outmatched)" else "" });
    return try std.fmt.allocPrint(alloc, "{s}–{s} skulls", .{ lo, skulls.number(&b, r.half_hi) });
}

test "an offer's intel is the comms of the board that offered it" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7702 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    const seat = gs.hqs.keys()[0];
    const second = try @import("hq_network.zig").foundHq(&gs, "Second", .regional, "alkaid");
    for ([_]types.HqId{ seat, second }) |id| gs.hqs.getPtr(id).?.staff_assigned = 999;
    for (gs.hqs.getPtr(seat).?.facilities.items) |*f| {
        if (f.kind == .comms) f.level = 3;
    }
    for (gs.hqs.getPtr(second).?.facilities.items) |*f| {
        if (f.kind == .comms) f.level = 0;
    }
    var c: contract_mod.Contract = .{
        .id = @enumFromInt(1),
        .kind = .objective_raid,
        .employer_key = "LC",
        .enemy_key = "FWL",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 100_000 },
        .enemy_lances = 3,
        .enemy_lance_bv = 4_000,
        .enemy_lance_tons = 220,
        .offer_hq = seat,
    };
    try std.testing.expect(lanceIntel(&gs, &c).exact);
    c.offer_hq = second;
    try std.testing.expect(!lanceIntel(&gs, &c).exact);
}

test "blind intel widens the lance range; comms 3 pins it" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    const c: contract_mod.Contract = .{
        .id = .none,
        .kind = .objective_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 100_000 },
        .enemy_lances = 3,
        .enemy_quality = .regular,
        .enemy_lance_bv = 4_000,
        .enemy_lance_tons = 220,
    };
    const blind = lanceIntel(&gs, &c);
    try std.testing.expect(blind.lo <= 3 and blind.hi >= 3);
    const hq = gs.hqs.getPtr(gs.hqs.keys()[0]).?;
    hq.staff_assigned = 999;
    const comms = for (hq.facilities.items) |*f| {
        if (f.kind == .comms) break f;
    } else return error.TestUnexpectedResult;
    comms.level = 3;
    const seen = lanceIntel(&gs, &c);
    try std.testing.expect(seen.exact);
    try std.testing.expectEqual(@as(u8, 3), seen.lo);
}
