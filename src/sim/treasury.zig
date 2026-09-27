//! The outfit's money (ARCH §11): moving it between the outfit, its HQs and
//! its deployed companies, what it costs each month, what it is worth and
//! what it may borrow. A transfer debits at once and the credit travels by
//! courier; a discretionary purchase refuses rather than overdraw; the
//! liquidation value backs the credit line and decides insolvency. The
//! ledger-and-balance primitive itself, `GameState.postTreasury`, stays
//! with the state it keeps in step. MekHQ counterpart: `finances/Finances`
//! (one account, payroll and loans); the per-entity treasuries, couriers
//! and liquidation-backed credit are this game's (docs/mekhq-map.md).

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const planet_mod = @import("../domain/planet.zig");
const logistics = @import("../econ/logistics.zig");
const finance_mod = @import("../econ/finance.zig");
const market = @import("../econ/market.zig");
const commander_mod = @import("../domain/commander.zig");
const state_mod = @import("state.zig");
const GameState = state_mod.GameState;
const Treasury = state_mod.Treasury;
const toe = @import("toe.zig");
const commands = @import("commands.zig");

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
    return types.applyBp(total, commander_mod.costMultBp(gs.commander, .payroll));
}

/// Monthly payroll for everyone assigned under one company's subtree.
pub fn companyMonthlyPayroll(gs: *GameState, company_id: types.ForceId) types.CBills {
    var total: types.CBills = 0;
    var it = gs.people.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        if (!p.isOnBooks() or !toe.personInCompany(gs, p, company_id)) continue;
        total += p.monthlySalary();
    }
    return total;
}

// -------------------------------------------------------- liquidation

/// Nothing left covers the hole: funds, everything sellable and every
/// credit line together are below zero. The checklist warns on it and the
/// payday folds the outfit on it; one expression.
pub fn isInsolvent(alloc: std.mem.Allocator, gs: *GameState) !bool {
    return gs.funds + try liquidationValue(alloc, gs) + try creditRemaining(alloc, gs) < 0;
}

/// Everything the outfit could raise by selling hulls, stock and all HQs
/// but the first.
pub fn liquidationValue(alloc: std.mem.Allocator, gs: *GameState) !types.CBills {
    var total: types.CBills = 0;
    var uit = gs.units.iterator();
    while (uit.next()) |e| total += try market.unitSaleValue(alloc, e.value_ptr);
    var sit = gs.spare_parts.iterator();
    while (sit.next()) |e| total += market.stockSaleValue(e.key_ptr.*, e.value_ptr.*);
    var hqs_it = gs.hqs.iterator();
    while (hqs_it.next()) |e| {
        var st = e.value_ptr.stock.iterator();
        while (st.next()) |line| total += market.stockSaleValue(line.key_ptr.*, line.value_ptr.*);
    }
    var first = true;
    var hit = gs.hqs.iterator();
    while (hit.next()) |e| {
        if (first) {
            first = false;
            continue;
        }
        total += market.hqSaleValue(e.value_ptr);
    }
    return total;
}

/// Lenders extend half the liquidation value plus a floor.
pub fn creditLimit(alloc: std.mem.Allocator, gs: *GameState) !types.CBills {
    return types.applyBp(try liquidationValue(alloc, gs), tuning.finance.credit_liquidation_bp) + tuning.finance.credit_floor;
}

/// The credit line left after every open loan.
pub fn creditRemaining(alloc: std.mem.Allocator, gs: *GameState) !types.CBills {
    var owed: types.CBills = 0;
    for (gs.loans.items) |l| owed += l.balance;
    return @max(0, try creditLimit(alloc, gs) - owed);
}

// ---- C4b handlers (moved from commands.zig) ----
const Error = commands.Error;
const Result = commands.Result;
const Command = commands.Command;

fn validateTreasury(gs: *GameState, t: Treasury) Error!void {
    switch (t) {
        .outfit => {},
        .hq => |id| if (gs.hqs.getPtr(id) == null) return Error.UnknownTreasury,
        .company => |id| {
            const f = gs.force(id) orelse return Error.UnknownTreasury;
            if (f.echelon != .company) return Error.NotACompany;
        },
    }
}

pub fn execRepayLoan(gs: *GameState, r: @FieldType(Command, "repay_loan")) Error!Result {
    if (r.index >= gs.loans.items.len) return Error.NoSuchLoan;
    const loan = &gs.loans.items[r.index];
    const amount = @min(r.amount, loan.balance);
    if (amount <= 0) return Error.NoSuchLoan;
    if (gs.funds < amount) return Error.InsufficientTreasury;
    loan.balance -= amount;
    try gs.postTransaction(.{ .day = gs.clock.day_index, .amount = -amount, .category = .loan_principal, .note = "early repayment" });
    if (loan.balance <= 0) _ = gs.loans.orderedRemove(r.index);
    return .{};
}

pub fn execTransfer(gs: *GameState, t: @FieldType(Command, "transfer")) Error!Result {
    try validateTreasury(gs, t.from);
    try validateTreasury(gs, t.to);
    const eta = courierEtaDays(gs, t.to);
    try transferFunds(gs, t.from, t.to, t.amount, eta);
    const tags = t.to.tags();
    try gs.log(.finance, .{ .company = tags.company, .hq = tags.hq }, "[finance] {d} c-bills dispatched by courier (eta {d} days)", .{ t.amount, eta });
    return .{};
}

pub fn execSetPolicy(gs: *GameState, p: @FieldType(Command, "set_policy")) Error!Result {
    try validateTreasury(gs, p.entity);
    if (p.entity == .outfit) return Error.UnknownTreasury;
    // One policy per entity: replace if present; a zero floor or cap removes it.
    const remove = p.floor <= 0 or p.monthly_cap <= 0;
    for (gs.policies.items, 0..) |*existing, i| {
        if (std.meta.eql(existing.entity, p.entity)) {
            if (remove) {
                _ = gs.policies.orderedRemove(i);
            } else {
                existing.floor = p.floor;
                existing.monthly_cap = p.monthly_cap;
            }
            return .{};
        }
    }
    if (remove) return .{};
    try gs.policies.append(gs.allocator(), .{ .entity = p.entity, .floor = p.floor, .monthly_cap = p.monthly_cap });
    return .{};
}

pub fn execTakeLoan(gs: *GameState, l: @FieldType(Command, "take_loan")) Error!Result {
    if (l.principal <= 0 or l.term_months == 0) return Error.NoSuchLoan;
    if (l.principal > try creditRemaining(gs.scratch(), gs)) return Error.CreditExceeded;
    const rate_bp: types.Bp = tuning.finance.loan_rate_bp; // 12%/yr simple interest
    const total_interest = @divTrunc(l.principal * rate_bp * l.term_months, 10_000 * 12);
    try gs.loans.append(gs.allocator(), .{
        .principal = l.principal,
        .balance = l.principal,
        .rate_bp = rate_bp,
        .term_months = l.term_months,
        .next_pay_day = gs.clock.day_index + 30,
        .payment = @divTrunc(l.principal + total_interest, l.term_months),
    });
    try gs.postTransaction(.{
        .day = gs.clock.day_index,
        .amount = l.principal,
        .category = .loan_principal,
        .note = "loan drawdown",
    });
    return .{};
}

pub fn execSetSharesPct(gs: *GameState, pct: @FieldType(Command, "set_shares_pct")) Error!Result {
    if (pct > 100) return Error.BadPercent;
    gs.share_profit_bp = @as(types.Bp, pct) * 100;
    try gs.log(.decision, .{}, "[shares] profit share set to {d}% of contract income", .{pct});
    return .{};
}

pub fn execAdjustSharesPct(gs: *GameState, delta: @FieldType(Command, "adjust_shares_pct")) Error!Result {
    const pct: i64 = types.bpPercent(gs.share_profit_bp);
    const next: i64 = std.math.clamp(pct + delta, 0, 100);
    _ = try commands.execute(gs, .{ .set_shares_pct = @intCast(next) });
    return .{ .shares_pct = @intCast(next) };
}

test "the credit line is backed by what the outfit could sell, less what it owes" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1214 });
    defer gs.deinit();
    _ = try gs.addUnit("SHD-2H");
    const worth = try liquidationValue(std.testing.allocator, &gs);
    try std.testing.expect(worth > 0);
    try std.testing.expectEqual(types.applyBp(worth, tuning.finance.credit_liquidation_bp) + tuning.finance.credit_floor, try creditLimit(std.testing.allocator, &gs));
    try std.testing.expectEqual(try creditLimit(std.testing.allocator, &gs), try creditRemaining(std.testing.allocator, &gs));
    gs.funds = -(worth + try creditRemaining(std.testing.allocator, &gs)) - 1;
    try std.testing.expect(try isInsolvent(std.testing.allocator, &gs));
    gs.funds = 0;
    try std.testing.expect(!(try isInsolvent(std.testing.allocator, &gs)));
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

test "insolvency holds the turn; bankruptcy ends the campaign" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 5 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .FS, .profession = .paymaster } });
    _ = try commands.execute(&gs, .{ .new_company = "Alpha" });
    gs.funds = -1;
    try std.testing.expectError(commands.Error.Insolvent, commands.execute(&gs, .advance_day));
    // Money couriered back from an HQ covers the hole before it lands.
    const hq0 = gs.hqs.keys()[0];
    gs.hqs.getPtr(hq0).?.funds = 100_000;
    _ = try commands.execute(&gs, .{ .transfer = .{ .from = .{ .hq = hq0 }, .to = .outfit, .amount = 50_000 } });
    try std.testing.expect(gs.funds < 0 and inboundToOutfit(&gs) >= 50_000);
    _ = try commands.execute(&gs, .advance_day);
    gs.funds = -1;
    gs.fund_couriers.clearRetainingCapacity();
    try std.testing.expectError(commands.Error.Insolvent, commands.execute(&gs, .advance_day));
    // A loan within the credit limit unblocks the turn.
    _ = try commands.execute(&gs, .{ .take_loan = .{ .principal = 100_000, .term_months = 6 } });
    try std.testing.expect(gs.funds > 0);
    _ = try commands.execute(&gs, .advance_day);
    // Early repayment clears the loan.
    gs.funds = 1_000_000;
    const bal = gs.loans.items[0].balance;
    _ = try commands.execute(&gs, .{ .repay_loan = .{ .index = 0, .amount = bal } });
    try std.testing.expectEqual(@as(usize, 0), gs.loans.items.len);
    // Selling a hull raises money; disbanding the company raises the rest.
    const before = gs.funds;
    const uid = gs.units.keys()[0];
    _ = try commands.execute(&gs, .{ .sell_unit = uid });
    try std.testing.expect(gs.funds > before);
    try std.testing.expect(gs.unit(uid) == null);
    // Beyond everything: game over.
    gs.funds = -1_000_000_000;
    try std.testing.expectError(commands.Error.Bankrupt, commands.execute(&gs, .advance_day));
    try std.testing.expect(gs.bankrupt);
}

test "a policy the outfit cannot fund is skipped, and the day still advances" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 13 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    gs.policies.clearRetainingCapacity();
    _ = try commands.execute(&gs, .{ .set_policy = .{ .entity = .{ .company = co }, .floor = 300_000, .monthly_cap = 400_000 } });
    gs.forces.getPtr(co).?.local_funds = 0;
    gs.funds = 1_000; // far short of the top-up
    gs.clock.date.day = 10;
    const day = gs.clock.day_index;
    _ = try commands.execute(&gs, .advance_day);
    try std.testing.expectEqual(day + 1, gs.clock.day_index);
    try std.testing.expectEqual(@as(usize, 0), gs.fund_couriers.items.len);
    try std.testing.expectEqual(@as(i64, 0), gs.policies.items[0].sent_this_month);
}

test "policies run daily under a monthly cap; resupply ships provisions to a company in the field" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    const hq = gs.hqs.keys()[0];
    gs.policies.clearRetainingCapacity(); // drop the starter HQ's default top-up — this test counts policies

    // Cash: a top-up dispatches on the next day, not on payday, and no second
    // courier leaves while the first is in flight.
    _ = try commands.execute(&gs, .{ .set_policy = .{ .entity = .{ .company = co }, .floor = 300_000, .monthly_cap = 400_000 } });
    gs.forces.getPtr(co).?.local_funds = 0;
    gs.clock.date.day = 10; // well away from payday
    _ = try commands.execute(&gs, .advance_day);
    try std.testing.expectEqual(@as(usize, 1), gs.fund_couriers.items.len);
    try std.testing.expectEqual(@as(i64, 300_000), gs.policies.items[0].sent_this_month);
    _ = try commands.execute(&gs, .advance_day);
    try std.testing.expectEqual(@as(usize, 1), gs.fund_couriers.items.len);
    // A zero floor clears the policy; setting it again starts fresh.
    _ = try commands.execute(&gs, .{ .set_policy = .{ .entity = .{ .company = co }, .floor = 0, .monthly_cap = 0 } });
    try std.testing.expectEqual(@as(usize, 0), gs.policies.items.len);
    _ = try commands.execute(&gs, .{ .set_policy = .{ .entity = .{ .company = co }, .floor = 300_000, .monthly_cap = 400_000 } });
    try std.testing.expectEqual(@as(usize, 1), gs.policies.items.len);
    gs.policies.items[0].sent_this_month = 300_000;

    // Provisions: the company is afield with empty stores; the policy ships
    // from home once, and not again while that shipment is in transit.
    try gs.addStock(.{ .hq = hq }, "provisions", 50);
    gs.forces.getPtr(co).?.location_planet = "galatea";
    _ = gs.takeStock(.{ .company = co }, "provisions", gs.stockCount(.{ .company = co }, "provisions"));
    _ = try commands.execute(&gs, .{ .set_supply_policy = .{ .company = co, .min_days = 14, .tons = 20 } });
    _ = try commands.execute(&gs, .advance_day);
    var shipments: usize = 0;
    for (gs.part_orders.items) |o| if (std.mem.eql(u8, o.part_key, "provisions") and o.dest == .company) {
        shipments += 1;
        try std.testing.expectEqual(@as(u32, 20), o.quantity);
    };
    try std.testing.expectEqual(@as(usize, 1), shipments);
    _ = try commands.execute(&gs, .advance_day);
    shipments = 0;
    for (gs.part_orders.items) |o| if (std.mem.eql(u8, o.part_key, "provisions") and o.dest == .company and o.status != .delivered) {
        shipments += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), shipments);
    // Munitions ride the same policy: a family the weapons fire, at zero in
    // the field, gets two battles' worth from home.
    try gs.addStock(.{ .hq = hq }, "ammo_lrm", 40);
    _ = gs.takeStock(.{ .company = co }, "ammo_lrm", gs.stockCount(.{ .company = co }, "ammo_lrm"));
    _ = try commands.execute(&gs, .advance_day);
    var lrm_shipped: u32 = 0;
    for (gs.part_orders.items) |o| if (std.mem.eql(u8, o.part_key, "ammo_lrm") and o.dest == .company and o.status != .delivered) {
        lrm_shipped += o.quantity;
    };
    try std.testing.expect(lrm_shipped > 0);
    // zero safety days removes it
    _ = try commands.execute(&gs, .{ .set_supply_policy = .{ .company = co, .min_days = 0, .tons = 0 } });
    try std.testing.expectEqual(@as(usize, 0), gs.supply_policies.items.len);
}

test "payroll drains funds over three months, resignations stop costing" {
    var gs = GameState.init(std.testing.allocator, .{ .start_funds = 1_000_000 });
    defer gs.deinit();

    const warrior = (try commands.execute(&gs, .{ .hire = .{ .first = "A", .last = "B", .role = .mekwarrior } })).hired;
    _ = try commands.execute(&gs, .{ .hire = .{ .first = "C", .last = "D", .role = .astech } });

    _ = try commands.execute(&gs, .{ .advance_days = 31 }); // Feb 1: (1500 + 400) × 1.1 — regulars rank Corporal
    try std.testing.expectEqual(@as(i64, 997_910), gs.funds);

    _ = try commands.execute(&gs, .{ .fire = warrior });
    _ = try commands.execute(&gs, .{ .advance_days = 28 }); // Mar 1: 440 only
    try std.testing.expectEqual(@as(i64, 997_470), gs.funds);
}

test "loans draw down and get serviced monthly" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 8, .start_funds = 0 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .take_loan = .{ .principal = 1_200_000, .term_months = 12 } });
    try std.testing.expectEqual(@as(i64, 1_200_000), gs.funds);

    _ = try commands.execute(&gs, .{ .advance_days = 62 }); // two paydays
    try std.testing.expect(gs.funds < 1_200_000);
    try std.testing.expect(gs.loans.items[0].balance < 1_200_000);
    const s = @import("../econ/finance.zig").summarize(&gs.ledger, 1, gs.clock.day_index, .all);
    try std.testing.expect(s.category(.loan_interest) < 0);
}

test "treasuries — HQ purchases draw HQ funds and refuse when short" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 91 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const hq_id = gs.hqs.keys()[0];

    // Founding capital moved outfit → HQ on-site.
    try std.testing.expectEqual(@as(i64, 1_000_000), gs.hqs.values()[0].funds);
    try std.testing.expectEqual(@as(i64, 9_000_000), gs.funds);

    // A fabrication job is paid by the HQ, not the outfit.
    _ = try commands.execute(&gs, .{ .fabricate = .{ .hq = hq_id, .part_key = "comp_leg", .quantity = 2 } });
    try std.testing.expect(gs.hqs.values()[0].funds < 1_000_000);
    try std.testing.expectEqual(@as(i64, 9_000_000), gs.funds);

    // Drain the HQ: the next purchase is refused, nothing overdraws.
    gs.hqs.values()[0].funds = 1_000;
    try std.testing.expectError(commands.Error.InsufficientTreasury, commands.execute(&gs, .{
        .fabricate = .{ .hq = hq_id, .part_key = "comp_leg", .quantity = 1 },
    }));
    try std.testing.expectEqual(@as(i64, 1_000), gs.hqs.values()[0].funds);

    // The HQ's own P&L sees the purchase; the outfit filter does not.
    const fin = @import("../econ/finance.zig");
    try std.testing.expect(fin.summarize(&gs.ledger, 0, 1, .{ .hq = hq_id }).category(.fabrication) < 0);
    try std.testing.expectEqual(@as(i64, 0), fin.summarize(&gs.ledger, 0, 1, .{ .company = @enumFromInt(1) }).category(.fabrication));
}

test "couriers debit now, credit on arrival; policies top up on payday" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 92 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .DC, .profession = .paymaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;

    const outfit_before = gs.funds;
    _ = try commands.execute(&gs, .{ .transfer = .{ .from = .outfit, .to = .{ .company = co }, .amount = 250_000 } });
    try std.testing.expectEqual(outfit_before - 250_000, gs.funds);
    try std.testing.expectEqual(@as(i64, 0), gs.force(co).?.local_funds); // still in transit
    try std.testing.expectEqual(@as(usize, 1), gs.fund_couriers.items.len);

    _ = try commands.execute(&gs, .{ .advance_days = 3 }); // same-planet minimum
    try std.testing.expectEqual(@as(i64, 250_000), gs.force(co).?.local_funds);
    try std.testing.expectEqual(@as(usize, 0), gs.fund_couriers.items.len);

    // Refused when the source is short.
    try std.testing.expectError(commands.Error.InsufficientTreasury, commands.execute(&gs, .{
        .transfer = .{ .from = .{ .company = co }, .to = .outfit, .amount = 999_999 },
    }));

    // Standing policy (checked daily, capped per month): below the
    // floor → a courier leaves the next day for the month's cap; payday
    // opens a fresh cap, so crossing Feb 1 brings a second 100k — never the
    // full 350k gap.
    _ = try commands.execute(&gs, .{ .set_policy = .{ .entity = .{ .company = co }, .floor = 600_000, .monthly_cap = 100_000 } });
    _ = try commands.execute(&gs, .{ .advance_days = 5 });
    try std.testing.expectEqual(@as(i64, 350_000), gs.force(co).?.local_funds); // January's cap, arrived
    _ = try commands.execute(&gs, .{ .advance_days = 30 }); // crosses Feb 1
    try std.testing.expectEqual(@as(i64, 450_000), gs.force(co).?.local_funds); // February's cap, and no more
}
