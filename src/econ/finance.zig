//! Finances: transaction ledger, per-company P&L, loans.
//! Mirrors MekHQ `finances/Finances.java`; extended with company-level
//! cost/profit centers (ARCH §11). All amounts are integer C-bills.

const std = @import("std");
const types = @import("../domain/types.zig");

pub const Category = enum {
    contract_payment,
    advance,
    salvage,
    battle_loss_comp,
    breach_clawback,
    payroll,
    hardship_pay, // remote-deployment payroll bonus (ARCH §9.6)
    maintenance,
    hull_upkeep, // per-hull monthly carry cost, running or not (ARCH §9.8)
    parts,
    supplies,
    local_supplies, // bought beyond the ring at 2–4× (ARCH §9.6)
    freight,
    unit_purchase,
    unit_sale,
    fabrication, // structural parts made at a regional HQ (ARCH §9.8)
    fund_transfer, // outfit treasury ↔ company local funds (ARCH §9.8)
    hq_construction,
    hq_upkeep,
    transport_charter,
    loan_principal,
    loan_interest,
    event,
    misc,
};

pub const Transaction = struct {
    day: u32,
    amount: types.CBills, // signed: income +, expense −
    category: Category,
    /// Cost/profit center; .none = outfit-level overhead.
    company: types.ForceId = .none,
    /// HQ cost center (Stage 9A).
    hq: types.HqId = .none,
    contract: types.ContractId = .none,
    note: []const u8 = "",
};

/// Which entity's books to read (Stage 9A).
pub const EntityFilter = union(enum) {
    all,
    company: types.ForceId,
    hq: types.HqId,

    pub fn matches(self: EntityFilter, t: *const Transaction) bool {
        return switch (self) {
            .all => true,
            .company => |id| t.company == id,
            .hq => |id| t.hq == id,
        };
    }
};

pub const Ledger = struct {
    transactions: std.ArrayListUnmanaged(Transaction) = .empty,

    pub fn deinit(self: *Ledger, alloc: std.mem.Allocator) void {
        self.transactions.deinit(alloc);
    }

    pub fn post(self: *Ledger, alloc: std.mem.Allocator, txn: Transaction) !void {
        try self.transactions.append(alloc, txn);
    }

    pub fn balance(self: *const Ledger) types.CBills {
        var total: types.CBills = 0;
        for (self.transactions.items) |t| total += t.amount;
        return total;
    }

    /// Net for one company over [from_day, to_day] — the monthly P&L view.
    pub fn companyNet(self: *const Ledger, company: types.ForceId, from_day: u32, to_day: u32) types.CBills {
        var total: types.CBills = 0;
        for (self.transactions.items) |t| {
            if (t.company == company and t.day >= from_day and t.day <= to_day) total += t.amount;
        }
        return total;
    }
};

/// Per-category totals over a period — the P&L view (GAMEPLAY.md's monthly
/// heartbeat). Income and expenses are kept separate so the report reads
/// like a statement, not a number.
pub const Summary = struct {
    income: types.CBills = 0,
    expenses: types.CBills = 0, // stored positive
    by_category: [category_count]types.CBills = @splat(0),

    pub const category_count = @typeInfo(Category).@"enum".fields.len;

    pub fn net(self: *const Summary) types.CBills {
        return self.income - self.expenses;
    }

    pub fn category(self: *const Summary, cat: Category) types.CBills {
        return self.by_category[@intFromEnum(cat)];
    }
};

/// Summarize [from_day, to_day] for the whole outfit or one entity's books.
pub fn summarize(ledger: *const Ledger, from_day: u32, to_day: u32, filter: EntityFilter) Summary {
    var s: Summary = .{};
    for (ledger.transactions.items) |*t| {
        if (t.day < from_day or t.day > to_day) continue;
        if (!filter.matches(t)) continue;
        s.by_category[@intFromEnum(t.category)] += t.amount;
        if (t.amount >= 0) s.income += t.amount else s.expenses -= t.amount;
    }
    return s;
}

pub const Loan = struct {
    principal: types.CBills,
    balance: types.CBills,
    rate_bp: types.Bp, // annual, basis points
    term_months: u16,
    next_pay_day: u32,
    payment: types.CBills,
};

test "summary splits income from expenses by category" {
    const alloc = std.testing.allocator;
    var ledger: Ledger = .{};
    defer ledger.deinit(alloc);

    try ledger.post(alloc, .{ .day = 5, .amount = 800_000, .category = .contract_payment });
    try ledger.post(alloc, .{ .day = 6, .amount = -250_000, .category = .payroll });
    try ledger.post(alloc, .{ .day = 7, .amount = -50_000, .category = .hull_upkeep });
    try ledger.post(alloc, .{ .day = 40, .amount = -999_999, .category = .payroll }); // out of range

    const s = summarize(&ledger, 1, 31, .all);
    try std.testing.expectEqual(@as(types.CBills, 800_000), s.income);
    try std.testing.expectEqual(@as(types.CBills, 300_000), s.expenses);
    try std.testing.expectEqual(@as(types.CBills, 500_000), s.net());
    try std.testing.expectEqual(@as(types.CBills, -250_000), s.category(.payroll));
}

test "ledger balance and company P&L" {
    const alloc = std.testing.allocator;
    var ledger: Ledger = .{};
    defer ledger.deinit(alloc);

    const alpha: types.ForceId = @enumFromInt(10);
    const bravo: types.ForceId = @enumFromInt(20);

    try ledger.post(alloc, .{ .day = 1, .amount = 1_000_000, .category = .contract_payment, .company = alpha });
    try ledger.post(alloc, .{ .day = 1, .amount = -400_000, .category = .payroll, .company = alpha });
    try ledger.post(alloc, .{ .day = 1, .amount = -700_000, .category = .payroll, .company = bravo });
    try ledger.post(alloc, .{ .day = 2, .amount = -50_000, .category = .hq_upkeep });

    try std.testing.expectEqual(@as(types.CBills, -150_000), ledger.balance());
    try std.testing.expectEqual(@as(types.CBills, 600_000), ledger.companyNet(alpha, 1, 31));
    try std.testing.expectEqual(@as(types.CBills, -700_000), ledger.companyNet(bravo, 1, 31));
}
