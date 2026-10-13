//! The outfit's money (ARCH §11): moving it between the outfit, its HQs and
//! its deployed companies, what it costs each month, what it is worth and
//! what it may borrow. A transfer debits at once and the credit travels by
//! courier; a discretionary purchase refuses rather than overdraw; the
//! liquidation value backs the credit line and decides insolvency. The
//! ledger-and-balance primitive itself, `GameState.postTreasury`, stays
//! with the state it keeps in step. MekHQ counterpart: `finances/Finances`
//! (one account, payroll and loans); the per-entity treasuries, couriers
//! and liquidation-backed credit are this game's (docs/mekhq-map.md).

const artillery = @import("artillery.zig");
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

pub const TransferError = error{ InsufficientTreasury, UnknownTreasury } || std.mem.Allocator.Error;

fn validateTreasuryExists(gs: *GameState, t: Treasury) TransferError!void {
    switch (t) {
        .outfit => {},
        .hq => |id| if (!gs.hqs.contains(id)) return error.UnknownTreasury,
        .company => |id| if (!gs.forces.contains(id)) return error.UnknownTreasury,
    }
}

fn applyBalance(gs: *GameState, treasury: Treasury, delta: types.CBills) void {
    switch (treasury) {
        .outfit => gs.funds += delta,
        .hq => |id| gs.hqs.getPtr(id).?.funds += delta,
        .company => |id| gs.forces.getPtr(id).?.local_funds += delta,
    }
}

/// Move money between treasuries.  Both treasuries are validated and all
/// ledger and courier capacity is reserved before any mutation.  The source
/// is debited immediately (refused if short); the credit travels by courier
/// for `eta_days` (0 = instant, as for founding capital handed over on site).
pub fn transferFunds(gs: *GameState, from: Treasury, to: Treasury, amount: types.CBills, eta_days: u32) TransferError!void {
    // -- validate --
    if (amount <= 0) return error.InsufficientTreasury;
    try validateTreasuryExists(gs, from);
    try validateTreasuryExists(gs, to);
    if (gs.treasuryBalance(from) < amount) return error.InsufficientTreasury;

    // -- prepare: reserve capacity for every fallible append --
    if (eta_days == 0) {
        try gs.reserveLedger(2); // debit + credit
    } else {
        try gs.reserveLedger(1); // debit only
        try gs.reserveCourier(1);
    }

    // -- commit: no allocation can fail past this point --
    const from_tags = from.tags();
    gs.ledger.transactions.appendAssumeCapacity(.{
        .day = gs.clock.day_index,
        .amount = -amount,
        .category = .fund_transfer,
        .company = from_tags.company,
        .hq = from_tags.hq,
        .note = "funds dispatched",
    });
    applyBalance(gs, from, -amount);

    if (eta_days == 0) {
        const to_tags = to.tags();
        gs.ledger.transactions.appendAssumeCapacity(.{
            .day = gs.clock.day_index,
            .amount = amount,
            .category = .fund_transfer,
            .company = to_tags.company,
            .hq = to_tags.hq,
            .note = "funds received",
        });
        applyBalance(gs, to, amount);
    } else {
        gs.fund_couriers.appendAssumeCapacity(.{
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

/// Courier days to reach a treasury from the outfit's seat:
/// `logistics.daysBetween`, same-world floor included.
pub fn courierEtaDays(gs: *GameState, to: Treasury) u32 {
    const home_key: []const u8 = gs.seatPlanetKey() orelse return logistics.same_world_days;
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

// --------------------------------------------------------- attribution

/// The books a cost lands in (ARCH §11): a company's own operating cost
/// carries its tag, and its contract's tag while the company is out on it.
/// `.none`/`.none` is shared outfit overhead.
pub const Attribution = struct {
    company: types.ForceId = .none,
    contract: types.ContractId = .none,
};

/// The attribution of a cost one company incurs today: the company, plus
/// the contract it is out on (in transit or on station), if any.
pub fn attributionFor(gs: *GameState, company: types.ForceId) Attribution {
    if (company == .none) return .{};
    return .{
        .company = company,
        .contract = if (gs.deploymentContract(company)) |c| c.id else .none,
    };
}

/// One company's share of an outfit charge, before the charge's multiplier.
pub const CompanyAmount = struct {
    company: types.ForceId,
    amount: types.CBills,
};

/// An outfit charge split by company: the whole before its multiplier, and
/// each company's part of it in `gs.forces` order. What no company holds is
/// shared overhead.
pub const CompanySplit = struct {
    raw_total: types.CBills,
    per_company: []CompanyAmount,
};

/// One zero bucket per company, in `gs.forces` order, allocated from `alloc`.
pub fn companyBuckets(alloc: std.mem.Allocator, gs: *GameState) ![]CompanyAmount {
    var out: std.ArrayListUnmanaged(CompanyAmount) = .empty;
    for (gs.forces.values()) |f| if (f.echelon == .company) try out.append(alloc, .{ .company = f.id, .amount = 0 });
    return out.toOwnedSlice(alloc);
}

/// Add `amount` to `company`'s bucket. A force outside every company
/// (`.none`) adds nothing: its share stays overhead.
pub fn addToBucket(buckets: []CompanyAmount, company: types.ForceId, amount: types.CBills) void {
    if (company == .none) return;
    for (buckets) |*b| if (b.company == company) {
        b.amount += amount;
        return;
    };
}

/// Post an outfit-treasury charge split by company (ARCH §11). Each
/// company with a nonzero part gets one row of `−applyBp(part, mult_bp)`
/// tagged by `attributionFor`, in `per_company` order; one untagged row
/// carries the rest of `applyBp(raw_total, mult_bp)`: the unassigned share
/// and the truncation remainder. The rows sum to the single-row charge, so
/// outfit funds move exactly as one posting of the whole would. Every row's
/// ledger capacity is reserved before the first append: on error nothing
/// is posted. Each part and `raw_total` are non-negative, and the parts sum
/// to at most `raw_total`.
pub fn postAttributedCharge(
    gs: *GameState,
    category: finance_mod.Category,
    note: []const u8,
    mult_bp: types.Bp,
    raw_total: types.CBills,
    per_company: []const CompanyAmount,
) !void {
    var rows: usize = 0;
    var attributed: types.CBills = 0;
    for (per_company) |part| {
        const amount = types.applyBp(part.amount, mult_bp);
        if (amount == 0) continue;
        rows += 1;
        attributed += amount;
    }
    const overhead = types.applyBp(raw_total, mult_bp) - attributed;
    std.debug.assert(overhead >= 0);
    if (overhead != 0) rows += 1;
    try gs.reserveLedger(rows);

    for (per_company) |part| {
        const amount = types.applyBp(part.amount, mult_bp);
        if (amount == 0) continue;
        const tags = attributionFor(gs, part.company);
        gs.commitTreasuryPosting(.{ .treasury = .outfit, .txn = .{
            .day = gs.clock.day_index,
            .amount = -amount,
            .category = category,
            .company = tags.company,
            .contract = tags.contract,
            .note = note,
        } });
    }
    if (overhead != 0) gs.commitTreasuryPosting(.{ .treasury = .outfit, .txn = .{
        .day = gs.clock.day_index,
        .amount = -overhead,
        .category = category,
        .note = note,
    } });
}

// ------------------------------------------------------ monthly costs

/// The hangar ledger (ARCH §9.8): every hull bills, running or not.
/// The payday, the employer's cost reckoning and the forecast all read it.
pub fn monthlyHullUpkeep(gs: *GameState) types.CBills {
    var total: types.CBills = 0;
    var it = gs.units.iterator();
    while (it.next()) |entry| total += entry.value_ptr.monthlyBill();
    total += artillery.monthlyCarry(gs);
    return total;
}

/// `monthlyHullUpkeep` split by company: each hull bills to the company it
/// serves in and each artillery carrier to the company it is attached to;
/// hulls and carriers in an HQ pool or on the road are overhead.
pub fn hullUpkeepSplit(alloc: std.mem.Allocator, gs: *GameState) !CompanySplit {
    const buckets = try companyBuckets(alloc, gs);
    var it = gs.units.iterator();
    while (it.next()) |entry| addToBucket(buckets, gs.companyOf(entry.value_ptr.force), entry.value_ptr.monthlyBill());
    for (buckets) |*b| b.amount += artillery.companyMonthlyCarry(gs, b.company);
    return .{ .raw_total = monthlyHullUpkeep(gs), .per_company = buckets };
}

/// Sum of monthly salaries for everyone on the books (active or wounded),
/// after the paymaster's discount if the commander has one.
pub fn monthlyPayroll(gs: *GameState) types.CBills {
    return types.applyBp(monthlySalaries(gs), commander_mod.costMultBp(gs.commander, .payroll));
}

/// Sum of monthly salaries for everyone on the books, before any discount.
fn monthlySalaries(gs: *GameState) types.CBills {
    var total: types.CBills = 0;
    var it = gs.people.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        if (p.isOnBooks()) total += p.monthlySalary();
    }
    return total;
}

/// Payroll split by company before the paymaster's discount: each
/// company's `companyMonthlyPayroll`; staff outside every company are
/// overhead. With that discount applied the whole is `monthlyPayroll`.
pub fn payrollSplit(alloc: std.mem.Allocator, gs: *GameState) !CompanySplit {
    const buckets = try companyBuckets(alloc, gs);
    for (buckets) |*b| b.amount = companyMonthlyPayroll(gs, b.company);
    return .{ .raw_total = monthlySalaries(gs), .per_company = buckets };
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

/// The day index of the coming payday. Today's payday, if today is one,
/// has already been paid.
pub fn nextPayday(gs: *GameState) u32 {
    return gs.clock.day_index + gs.clock.date.daysUntilNextPayday();
}

/// What the coming payday pays in contract money: the monthly net (base
/// pay less the advance's share) of every contract
/// `Contract.paidOnPayday` holds paid on that day.
pub fn nextPaydayContractPay(gs: *GameState) types.CBills {
    const payday = nextPayday(gs);
    var total: types.CBills = 0;
    for (gs.contracts.values()) |*c| {
        if (c.paidOnPayday(payday)) total += c.monthly_net;
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
    for (gs.artillery_formations.values()) |*f| total += artillery.saleValue(f);
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
    // Resolve by typed LoanId (not by index).
    var loan_index: ?usize = null;
    for (gs.loans.items, 0..) |l, i| {
        if (l.id == r.loan) {
            loan_index = i;
            break;
        }
    }
    const idx = loan_index orelse return Error.NoSuchLoan;
    const loan = &gs.loans.items[idx];
    const amount = @min(r.amount, loan.balance);
    if (amount <= 0) return Error.NoSuchLoan;
    if (gs.funds < amount) return Error.InsufficientTreasury;
    loan.balance -= amount;
    try gs.postTransaction(.{ .day = gs.clock.day_index, .amount = -amount, .category = .loan_principal, .note = "early repayment" });
    if (loan.balance <= 0) _ = gs.loans.orderedRemove(idx);
    return .{};
}

pub fn execTransfer(gs: *GameState, t: @FieldType(Command, "transfer")) Error!Result {
    try validateTreasury(gs, t.from);
    try validateTreasury(gs, t.to);
    const eta = courierEtaDays(gs, t.to);
    try gs.reserveLog(1);
    try transferFunds(gs, t.from, t.to, t.amount, eta);
    const tags = t.to.tags();
    try gs.log(.finance, .{ .company = tags.company, .hq = tags.hq }, "[finance] {s} c-bills dispatched by courier (eta {d} days)", .{ try types.moneyText(gs.allocator(), t.amount), eta });
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
    if (l.term_months > tuning.finance.loan_max_term_months) return Error.LoanTermTooLong;
    if (l.principal > try creditRemaining(gs.scratch(), gs)) return Error.CreditExceeded;
    const rate_bp: types.Bp = tuning.finance.loan_rate_bp; // 12%/yr simple interest
    const total_interest = finance_mod.totalInterest(l.principal, rate_bp, l.term_months);
    const loan_id: types.LoanId = @enumFromInt(gs.next_loan_id);
    try gs.loans.append(gs.allocator(), .{
        .id = loan_id,
        .principal = l.principal,
        .balance = l.principal,
        .rate_bp = rate_bp,
        .term_months = l.term_months,
        .next_pay_day = gs.clock.day_index + types.days_per_month,
        .payment = @divTrunc(l.principal + total_interest, l.term_months),
    });
    gs.next_loan_id += 1;
    try gs.postTransaction(.{
        .day = gs.clock.day_index,
        .amount = l.principal,
        .category = .loan_principal,
        .note = "loan drawdown",
    });
    return .{ .loan = loan_id };
}

pub fn execSetSharesPct(gs: *GameState, pct: @FieldType(Command, "set_shares_pct")) Error!Result {
    if (pct > 100) return Error.BadPercent;
    gs.share_profit_bp = @as(types.Bp, pct) * 100;
    try gs.log(.decision, .{}, "[shares] profit share set to {d}% of contract profit", .{pct});
    return .{};
}

pub fn execAdjustSharesPct(gs: *GameState, delta: @FieldType(Command, "adjust_shares_pct")) Error!Result {
    const pct: i64 = types.bpPercent(gs.share_profit_bp);
    const next: i64 = std.math.clamp(pct + delta, 0, 100);
    _ = try commands.execute(gs, .{ .set_shares_pct = @intCast(next) });
    return .{ .shares_pct = @intCast(next) };
}

/// Two companies, only the first out on a running contract (rule 71's
/// asymmetric fixture for attribution).
fn attributionFixture(gs: *GameState) !struct { deployed: types.ForceId, home: types.ForceId, contract: types.ContractId } {
    const deployed = try gs.createForce("Alpha", .company, .none);
    const home = try gs.createForce("Bravo", .company, .none);
    const cid: types.ContractId = @enumFromInt(gs.next_contract_id);
    gs.next_contract_id += 1;
    try gs.contracts.put(gs.allocator(), cid, .{ .id = cid, .kind = .garrison_duty, .employer_key = "LC", .enemy_key = "PER", .planet_key = "galatea", .terms = .{ .length_months = 6, .base_pay_month = 400_000 }, .status = .active, .assigned_company = deployed, .monthly_net = 300_000 });
    return .{ .deployed = deployed, .home = home, .contract = cid };
}

test "an attributed charge posts one row per company plus the overhead, and moves funds as one posting would" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1301 });
    defer gs.deinit();
    const fx = try attributionFixture(&gs);
    const idle = try gs.createForce("Charlie", .company, .none);
    try std.testing.expectEqual(Attribution{ .company = fx.deployed, .contract = fx.contract }, attributionFor(&gs, fx.deployed));
    try std.testing.expectEqual(Attribution{ .company = fx.home }, attributionFor(&gs, fx.home));
    try std.testing.expectEqual(Attribution{}, attributionFor(&gs, .none));

    const funds = gs.funds;
    const parts = [_]CompanyAmount{
        .{ .company = fx.deployed, .amount = 1_000 },
        .{ .company = fx.home, .amount = 333 },
        .{ .company = idle, .amount = 0 },
    };
    // A 2% discount: 1_000 → 980, 333 → 326, and the whole 2_000 → 1_960.
    try postAttributedCharge(&gs, .payroll, "monthly payroll", 9_800, 2_000, &parts);
    const rows = gs.ledger.transactions.items;
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqualDeep(finance_mod.Transaction{ .day = 0, .amount = -980, .category = .payroll, .company = fx.deployed, .contract = fx.contract, .note = "monthly payroll" }, rows[0]);
    try std.testing.expectEqualDeep(finance_mod.Transaction{ .day = 0, .amount = -326, .category = .payroll, .company = fx.home, .note = "monthly payroll" }, rows[1]);
    try std.testing.expectEqualDeep(finance_mod.Transaction{ .day = 0, .amount = -654, .category = .payroll, .note = "monthly payroll" }, rows[2]);
    try std.testing.expectEqual(funds - types.applyBp(2_000, 9_800), gs.funds);

    // Every part held by a company: no overhead row.
    try postAttributedCharge(&gs, .hull_upkeep, "hangar & hull upkeep", types.full_bp, 500, &.{.{ .company = fx.home, .amount = 500 }});
    try std.testing.expectEqual(@as(usize, 4), gs.ledger.transactions.items.len);
    // Nothing owed: nothing posted.
    try postAttributedCharge(&gs, .hull_upkeep, "hangar & hull upkeep", types.full_bp, 0, parts[2..]);
    try std.testing.expectEqual(@as(usize, 4), gs.ledger.transactions.items.len);
}

test "a failed attributed charge posts no row and moves no funds" {
    const digest = @import("digest.zig");
    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 1302 });
    const fx = try attributionFixture(&gs);
    try std.testing.expectEqual(@as(usize, 0), gs.ledger.transactions.capacity);
    const before = digest.stateHash(&gs);
    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;
    const parts = [_]CompanyAmount{ .{ .company = fx.deployed, .amount = 700 }, .{ .company = fx.home, .amount = 200 } };
    try std.testing.expectError(error.OutOfMemory, postAttributedCharge(&gs, .payroll, "monthly payroll", types.full_bp, 1_000, &parts));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
}

test "the payday split owners bill each company its own staff and hulls" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1303 });
    defer gs.deinit();
    const fx = try attributionFixture(&gs);
    const lance = try gs.createForce("1st Lance", .lance, fx.deployed);
    const hand = try gs.hirePerson("Alpha", "Hand", .mekwarrior);
    gs.person(hand).?.assigned_force = lance;
    const loose = try gs.hirePerson("Pool", "Hand", .astech);
    const hull = try gs.addUnit("SHD-2H");
    gs.unit(hull).?.force = lance;
    _ = try gs.addUnit("CGT-3"); // in the pool: overhead

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const payroll = try payrollSplit(arena.allocator(), &gs);
    try std.testing.expectEqual(gs.person(hand).?.monthlySalary() + gs.person(loose).?.monthlySalary(), payroll.raw_total);
    try std.testing.expectEqual(@as(usize, 2), payroll.per_company.len);
    try std.testing.expectEqual(CompanyAmount{ .company = fx.deployed, .amount = gs.person(hand).?.monthlySalary() }, payroll.per_company[0]);
    try std.testing.expectEqual(CompanyAmount{ .company = fx.home, .amount = 0 }, payroll.per_company[1]);
    const hulls = try hullUpkeepSplit(arena.allocator(), &gs);
    try std.testing.expectEqual(monthlyHullUpkeep(&gs), hulls.raw_total);
    try std.testing.expectEqual(gs.unit(hull).?.monthlyBill(), hulls.per_company[0].amount);
    try std.testing.expectEqual(@as(types.CBills, 0), hulls.per_company[1].amount);
}

test "the forecast's contract pay is what the coming payday posts" {
    const tick = @import("tick.zig");
    const founding = @import("founding.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1304 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .paymaster);
    const fx = try attributionFixture(&gs);
    const ending = try gs.createForce("Charlie", .company, .none);
    // Read on 3025-01-31 (day 30): the payday is day 31.
    gs.clock.date = .{ .year = 3025, .month = 1, .day = 31 };
    gs.clock.day_index = 30;
    gs.contracts.getPtr(fx.contract).?.end_day = 200;
    const arriving: types.ContractId = @enumFromInt(gs.next_contract_id);
    const finishing: types.ContractId = @enumFromInt(gs.next_contract_id + 1);
    gs.next_contract_id += 2;
    try gs.contracts.put(gs.allocator(), arriving, .{ .id = arriving, .kind = .garrison_duty, .employer_key = "LC", .enemy_key = "PER", .planet_key = "galatea", .terms = .{ .length_months = 3, .base_pay_month = 200_000 }, .status = .transit, .assigned_company = fx.home, .arrive_day = 31, .monthly_net = 150_000 });
    try gs.contracts.put(gs.allocator(), finishing, .{ .id = finishing, .kind = .garrison_duty, .employer_key = "LC", .enemy_key = "PER", .planet_key = "galatea", .terms = .{ .length_months = 1, .base_pay_month = 100_000 }, .status = .active, .assigned_company = ending, .end_day = 31, .monthly_net = 75_000 });
    try std.testing.expectEqual(@as(u32, 31), nextPayday(&gs));
    const forecast = nextPaydayContractPay(&gs);
    try std.testing.expectEqual(@as(types.CBills, 300_000 + 150_000), forecast);

    const from = gs.ledger.transactions.items.len;
    try tick.advanceDay(&gs);
    try std.testing.expect(gs.clock.date.isPayday());
    var posted: types.CBills = 0;
    for (gs.ledger.transactions.items[from..]) |t| if (t.category == .contract_payment) {
        posted += t.amount;
    };
    try std.testing.expectEqual(forecast, posted);
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

test "a failed transfer allocation leaves state unchanged" {
    const digest = @import("digest.zig");

    // Courier path — a true regression: pre-reserve exactly one ledger slot
    // so the debit append can succeed without allocating (`reserveLedger`
    // rounds up via `growCapacity`, so grow to exactly one slot directly).
    // On the old code the debit commits using that slot and only the
    // courier append then fails; on the fixed code `reserveCourier` is
    // checked before any mutation.
    {
        // Outer arena holds actual memory; gs.deinit is not called because
        // the outer arena owns teardown (same pattern as hq_ops.zig:1110).
        var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer outer.deinit();
        var gs = GameState.init(outer.allocator(), .{ .seed = 500 });
        const co = try gs.createForce("Alpha", .company, .none);
        gs.funds = 100_000;
        try gs.ledger.transactions.ensureTotalCapacityPrecise(gs.allocator(), 1);
        const before = digest.stateHash(&gs);

        // Block every further allocation from the arena.
        gs.arena.state.used_list = null;
        gs.arena.state.free_list = null;
        gs.arena.child_allocator = std.testing.failing_allocator;

        try std.testing.expectError(error.OutOfMemory, transferFunds(&gs, .outfit, .{ .company = co }, 1_000, 5));
        try std.testing.expectEqual(before, digest.stateHash(&gs));
    }

    // Instant-credit path: with no ledger capacity reserved at all, the
    // fixed code's `reserveLedger(2)` must fail before either the debit or
    // the credit is posted, leaving state untouched.
    {
        var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer outer.deinit();
        var gs = GameState.init(outer.allocator(), .{ .seed = 501 });
        const co = try gs.createForce("Alpha", .company, .none);
        gs.funds = 100_000;
        const before = digest.stateHash(&gs);

        gs.arena.state.used_list = null;
        gs.arena.state.free_list = null;
        gs.arena.child_allocator = std.testing.failing_allocator;

        try std.testing.expectError(error.OutOfMemory, transferFunds(&gs, .outfit, .{ .company = co }, 1_000, 0));
        try std.testing.expectEqual(before, digest.stateHash(&gs));
    }
}

test "insolvency holds the turn; bankruptcy ends the campaign" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 5 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .FS, .profession = .paymaster } });
    _ = try commands.execute(&gs, .{ .new_company = "Alpha" });
    gs.funds = -1;
    try std.testing.expectError(commands.Error.Insolvent, commands.execute(&gs, .advance_day));
    // Money couriered back from an HQ covers the hole before it lands.
    const hq0 = gs.seat();
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
    _ = try commands.execute(&gs, .{ .repay_loan = .{ .loan = gs.loans.items[0].id, .amount = bal } });
    try std.testing.expectEqual(@as(usize, 0), gs.loans.items.len);
    // Selling a hull raises money; disbanding the company raises the rest.
    const before = gs.funds;
    const uid = gs.units.keys()[0];
    _ = try commands.execute(&gs, .{ .sell_unit = uid });
    try std.testing.expect(gs.funds > before);
    try std.testing.expect(gs.unit(uid) == null);
    // Beyond everything: game over, and the next advance refuses.
    gs.funds = -1_000_000_000;
    const folded = try commands.execute(&gs, .advance_day);
    try std.testing.expectEqual(@as(u32, 0), folded.days_advanced);
    try std.testing.expectEqual(.bankrupt, folded.stopped);
    try std.testing.expect(gs.bankrupt);
    try std.testing.expectError(commands.Error.Bankrupt, commands.execute(&gs, .advance_day));
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
    const hq = gs.seat();
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

test "execTakeLoan returns the LoanId of the newly created loan" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 42, .start_funds = 0 });
    defer gs.deinit();
    const r = try commands.execute(&gs, .{ .take_loan = .{ .principal = 500_000, .term_months = 6 } });
    // The returned id is non-none and keys the new loan entry.
    try std.testing.expect(r.loan != .none);
    try std.testing.expectEqual(@as(usize, 1), gs.loans.items.len);
    try std.testing.expectEqual(r.loan, gs.loans.items[0].id);
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
    const hq_id = gs.seat();

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

test "courierEtaDays floors at same_world_days and rises with jump distance" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 93 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    // Same-world case: outfit and company at the same HQ → same_world_days floor.
    const same_world = courierEtaDays(&gs, .{ .company = co });
    try std.testing.expectEqual(logistics.same_world_days, same_world);
    // A far-off HQ: ETA must be at least same_world_days.
    gs.funds = 20_000_000;
    _ = try commands.execute(&gs, .{ .found_hq = .{ .name = "Far", .planet_key = "zebebelgenubi" } });
    const far = gs.hqs.keys()[gs.hqs.count() - 1];
    const far_eta = courierEtaDays(&gs, .{ .hq = far });
    try std.testing.expect(far_eta >= logistics.same_world_days);
    // Outfit-to-outfit is always same-world (both at the seat).
    try std.testing.expectEqual(logistics.same_world_days, courierEtaDays(&gs, .outfit));
}

test "loan term over the cap is refused before any state changes (rules 13, 69)" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 42 });
    defer gs.deinit();
    const term_too_long: u16 = @intCast(tuning.finance.loan_max_term_months + 1);
    const funds_before = gs.funds;
    const loans_before = gs.loans.items.len;
    const next_id_before = gs.next_loan_id;
    const txn_before = gs.ledger.transactions.items.len;
    try std.testing.expectError(error.LoanTermTooLong, commands.execute(&gs, .{ .take_loan = .{ .principal = 100_000, .term_months = term_too_long } }));
    try std.testing.expectEqual(funds_before, gs.funds);
    try std.testing.expectEqual(loans_before, gs.loans.items.len);
    try std.testing.expectEqual(next_id_before, gs.next_loan_id);
    try std.testing.expectEqual(txn_before, gs.ledger.transactions.items.len);
}
