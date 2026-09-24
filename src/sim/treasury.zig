//! The outfit's money (ARCH §11): moving it between the outfit, its HQs and
//! its deployed companies, what it costs each month, what it is worth and
//! what it may borrow. A transfer debits at once and the credit travels by
//! courier; a discretionary purchase refuses rather than overdraw; the
//! liquidation value backs the credit line and decides insolvency. The
//! ledger-and-balance primitive itself, `GameState.postTreasury`, stays
//! with the state it keeps in step. MekHQ counterpart: `finances/Finances`
//! (one account, payroll and loans); the per-entity treasuries, couriers
//! and liquidation-backed credit are this game's.

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const planet_mod = @import("../domain/planet.zig");
const unit_mod = @import("../domain/unit.zig");
const chassis_mod = @import("../domain/chassis.zig");
const part_mod = @import("../domain/part.zig");
const hq_mod = @import("../domain/hq.zig");
const logistics = @import("../econ/logistics.zig");
const finance_mod = @import("../econ/finance.zig");
const market = @import("../econ/market.zig");
const state_mod = @import("state.zig");
const GameState = state_mod.GameState;
const Treasury = state_mod.Treasury;

pub const TransferError = error{InsufficientTreasury} || std.mem.Allocator.Error;

/// Move money between treasuries. The source is debited immediately (refused
/// if short); the credit travels by courier for `eta_days` (0 = instant, as
/// for founding capital handed over on site).
pub fn transferFunds(gs: *GameState, from: Treasury, to: Treasury, amount: types.CBills, eta_days: u32) TransferError!void {
    if (amount <= 0 or gs.treasuryBalance(from) < amount) return error.InsufficientTreasury;
    const from_tags = from.tags();
    try gs.postTreasury(from, .{
        .day = gs.clock.day_index,
        .amount = -amount,
        .category = .fund_transfer,
        .company = from_tags.company,
        .hq = from_tags.hq,
        .note = "funds dispatched",
    });
    if (eta_days == 0) {
        try creditTreasury(gs, to, amount);
    } else {
        try gs.fund_couriers.append(gs.allocator(), .{
            .to = to,
            .amount = amount,
            .sent_day = gs.clock.day_index,
            .eta_day = gs.clock.day_index + eta_days,
        });
    }
}

/// A courier's money arriving: the receiving side of a transfer.
pub fn creditTreasury(gs: *GameState, to: Treasury, amount: types.CBills) !void {
    const tags = to.tags();
    try gs.postTreasury(to, .{
        .day = gs.clock.day_index,
        .amount = amount,
        .category = .fund_transfer,
        .company = tags.company,
        .hq = tags.hq,
        .note = "funds received",
    });
}

/// Debit a purchase from a treasury, refusing (not overdrawing) if short:
/// the "treasury cannot teleport" rule for discretionary spending.
pub fn debit(gs: *GameState, treasury: Treasury, txn: finance_mod.Transaction) TransferError!void {
    if (gs.treasuryBalance(treasury) < -txn.amount) return error.InsufficientTreasury;
    try gs.postTreasury(treasury, txn);
}

/// Money already on its way to the outfit's treasury (couriers in transit):
/// it counts toward solvency at turn end, so pulling funds back unblocks
/// the turn before they land.
pub fn inboundToOutfit(gs: *GameState) types.CBills {
    var sum: types.CBills = 0;
    for (gs.fund_couriers.items) |c| if (c.to == .outfit) {
        sum += c.amount;
    };
    return sum;
}

/// Courier days to reach a treasury from the outfit's seat (first HQ):
/// `logistics.daysBetween`, same-world floor included.
pub fn courierEtaDays(gs: *GameState, to: Treasury) u32 {
    const home_key: []const u8 = if (gs.hqs.count() > 0) gs.hqs.values()[0].planet_key else return logistics.same_world_days;
    const dest_key: []const u8 = switch (to) {
        .outfit => home_key,
        .hq => |id| if (gs.hqs.getPtr(id)) |h| h.planet_key else home_key,
        .company => |id| blk: {
            if (gs.deploymentContract(id)) |c| break :blk c.planet_key;
            if (gs.hqs.getPtr(gs.homeHqFor(id))) |h| break :blk h.planet_key;
            break :blk home_key;
        },
    };
    const home = planet_mod.find(home_key) orelse return logistics.same_world_days;
    const dest = planet_mod.find(dest_key) orelse return logistics.same_world_days;
    return logistics.daysBetween(home, dest);
}

// ------------------------------------------------------ monthly costs

/// The hangar ledger (ARCH §9.8): every hull bills, running or not.
/// The payday, the employer's cost reckoning and the forecast all read it.
pub fn monthlyHullUpkeep(gs: *GameState) types.CBills {
    var total: types.CBills = 0;
    var it = gs.units.iterator();
    while (it.next()) |entry| total += entry.value_ptr.monthlyBill();
    return total;
}

/// Sum of monthly salaries for everyone on the books (active or wounded),
/// after the paymaster's discount if the commander has one.
pub fn monthlyPayroll(gs: *GameState) types.CBills {
    var total: types.CBills = 0;
    var it = gs.people.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        if (p.isOnBooks()) total += p.monthlySalary();
    }
    return types.applyBp(total, gs.commanderMultBp(.payroll));
}

/// Monthly payroll for everyone assigned under one company's subtree.
pub fn companyMonthlyPayroll(gs: *GameState, company_id: types.ForceId) types.CBills {
    var total: types.CBills = 0;
    var it = gs.people.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        if (!p.isOnBooks() or !gs.personInCompany(p, company_id)) continue;
        total += p.monthlySalary();
    }
    return total;
}

// -------------------------------------------------------- liquidation

/// What a hull fetches on a forced sale: half its value, scaled by
/// condition.
pub fn unitSaleValue(u: *const unit_mod.Unit) types.CBills {
    // A wreck is worth what can be stripped off it.
    if (u.status == .destroyed) return stripValue(u);
    const base: types.CBills = if (u.purchase_price > 0) u.purchase_price else if (chassis_mod.find(u.chassis_key)) |c| c.cost else 0;
    const by_condition = @divTrunc(base * @as(types.CBills, u.conditionPct()) * tuning.unit.sale_bp, 10_000 * 100);
    // Quality on the ticket: ± per step from C (A worst, F best).
    const steps: i64 = @as(i64, @intFromEnum(u.quality)) - @intFromEnum(types.Quality.c);
    return types.applyBp(by_condition, @intCast(10_000 + steps * tuning.maintenance.quality_sale_bp_per_step));
}

/// One line of what stripping a hull recovers.
pub const StripLine = struct { key: []const u8, qty: u32 };

/// What a hull yields stripped for parts (MekHQ "salvage unit"): every
/// intact weapon and piece of equipment, every intact structural
/// component, and the armour still on it. Ammunition bins and damaged gear
/// go with the scrap.
pub fn stripParts(alloc: std.mem.Allocator, u: *const unit_mod.Unit) ![]StripLine {
    var out: std.ArrayListUnmanaged(StripLine) = .empty;
    for (u.slots.items) |s| {
        if (s.condition != .ok) continue;
        const key: []const u8 = switch (s.class) {
            .weapon, .equipment => s.part_key,
            .structure => part_mod.componentFor(s.slot_key, u.chassis_key),
            .armor, .ammo => continue,
        };
        if (part_mod.find(key) == null) continue;
        for (out.items) |*l| {
            if (std.mem.eql(u8, l.key, key)) {
                l.qty += 1;
                break;
            }
        } else try out.append(alloc, .{ .key = key, .qty = 1 });
    }
    if (chassis_mod.find(u.chassis_key)) |design| {
        const armor_tons: u32 = @as(u32, design.armor_half_tons) * u.armor_pct / 200;
        if (armor_tons > 0) try out.append(alloc, .{ .key = "armor", .qty = armor_tons });
    }
    return out.toOwnedSlice(alloc);
}

/// Resale value of everything `stripParts` would recover.
pub fn stripValue(u: *const unit_mod.Unit) types.CBills {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const lines = stripParts(fba.allocator(), u) catch return 0;
    var total: types.CBills = 0;
    for (lines) |l| total += stockSaleValue(l.key, l.qty);
    return total;
}

/// What an HQ's facilities fetch: 40% of what they cost to build.
pub fn hqSaleValue(h: *const hq_mod.Hq) types.CBills {
    var total: types.CBills = 0;
    for (h.facilities.items) |f| {
        var lvl: u8 = 1;
        while (lvl <= f.level) : (lvl += 1) total += hq_mod.upgradeCost(f.kind, lvl);
    }
    return @divTrunc(total * @as(types.CBills, tuning.hq.sale_pct), 100);
}

/// Resale value of `qty` of a stock line: market.stock_resale_bp of
/// catalogue cost, component_resale_bp for comp_* parts.
pub fn stockSaleValue(key: []const u8, qty: u32) types.CBills {
    const def = part_mod.find(key) orelse return 0;
    const bp: types.Bp = if (part_mod.isComponent(key)) market.component_resale_bp else market.stock_resale_bp;
    return types.applyBp(def.cost * qty, bp);
}

/// Nothing left covers the hole: funds, everything sellable and every
/// credit line together are below zero. The checklist warns on it and the
/// payday folds the outfit on it; one expression.
pub fn isInsolvent(gs: *GameState) bool {
    return gs.funds + liquidationValue(gs) + creditRemaining(gs) < 0;
}

/// Everything the outfit could raise by selling hulls, stock and all HQs
/// but the first.
pub fn liquidationValue(gs: *GameState) types.CBills {
    var total: types.CBills = 0;
    var uit = gs.units.iterator();
    while (uit.next()) |e| total += unitSaleValue(e.value_ptr);
    var sit = gs.spare_parts.iterator();
    while (sit.next()) |e| total += stockSaleValue(e.key_ptr.*, e.value_ptr.*);
    var hqs_it = gs.hqs.iterator();
    while (hqs_it.next()) |e| {
        var st = e.value_ptr.stock.iterator();
        while (st.next()) |line| total += stockSaleValue(line.key_ptr.*, line.value_ptr.*);
    }
    var first = true;
    var hit = gs.hqs.iterator();
    while (hit.next()) |e| {
        if (first) {
            first = false;
            continue;
        }
        total += hqSaleValue(e.value_ptr);
    }
    return total;
}

/// Lenders extend half the liquidation value plus a floor.
pub fn creditLimit(gs: *GameState) types.CBills {
    return types.applyBp(liquidationValue(gs), tuning.finance.credit_liquidation_bp) + tuning.finance.credit_floor;
}

/// The credit line left after every open loan.
pub fn creditRemaining(gs: *GameState) types.CBills {
    var owed: types.CBills = 0;
    for (gs.loans.items) |l| owed += l.balance;
    return @max(0, creditLimit(gs) - owed);
}

test "quality moves the resale ticket" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1213 });
    defer gs.deinit();
    const uid = try gs.addUnit("SHD-2H");
    const u = gs.unit(uid).?;
    u.quality = .c;
    const c = unitSaleValue(u);
    u.quality = .f;
    try std.testing.expect(unitSaleValue(u) > c);
    u.quality = .a;
    try std.testing.expect(unitSaleValue(u) < c);
}

test "the credit line is backed by what the outfit could sell, less what it owes" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1214 });
    defer gs.deinit();
    _ = try gs.addUnit("SHD-2H");
    const worth = liquidationValue(&gs);
    try std.testing.expect(worth > 0);
    try std.testing.expectEqual(types.applyBp(worth, tuning.finance.credit_liquidation_bp) + tuning.finance.credit_floor, creditLimit(&gs));
    try std.testing.expectEqual(creditLimit(&gs), creditRemaining(&gs));
    gs.funds = -(worth + creditRemaining(&gs)) - 1;
    try std.testing.expect(isInsolvent(&gs));
    gs.funds = 0;
    try std.testing.expect(!isInsolvent(&gs));
}

test "a transfer debits now and credits on arrival; a short treasury refuses and nothing moves" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 71 });
    defer gs.deinit();
    const co = try gs.createForce("Alpha", .company, .none);
    const start = gs.funds;

    // Instant: both sides move together.
    try transferFunds(&gs, .outfit, .{ .company = co }, 1_000, 0);
    try std.testing.expectEqual(start - 1_000, gs.funds);
    try std.testing.expectEqual(@as(types.CBills, 1_000), gs.treasuryBalance(.{ .company = co }));

    // By courier: the debit lands today, the credit rides in transit and
    // counts toward the outfit only when it is bound there.
    try transferFunds(&gs, .{ .company = co }, .outfit, 400, 5);
    try std.testing.expectEqual(@as(types.CBills, 600), gs.treasuryBalance(.{ .company = co }));
    try std.testing.expectEqual(@as(types.CBills, 400), inboundToOutfit(&gs));
    try std.testing.expectEqual(start - 1_000, gs.funds);

    // Short: refused before anything is posted.
    const posted = gs.ledger.transactions.items.len;
    try std.testing.expectError(error.InsufficientTreasury, transferFunds(&gs, .{ .company = co }, .outfit, 10_000, 0));
    try std.testing.expectError(error.InsufficientTreasury, debit(&gs, .{ .company = co }, .{ .day = 0, .amount = -10_000, .category = .unit_purchase, .note = "too dear" }));
    try std.testing.expectEqual(posted, gs.ledger.transactions.items.len);
    try std.testing.expectEqual(@as(types.CBills, 600), gs.treasuryBalance(.{ .company = co }));
}
