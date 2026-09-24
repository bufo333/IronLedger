//! Treasuries (ARCH §11): moving money between the outfit, its HQs and its
//! deployed companies. A transfer debits at once and the credit travels by
//! courier; a discretionary purchase refuses rather than overdraw. The
//! ledger-and-balance primitive itself, `GameState.postTreasury`, stays
//! with the state it keeps in step. MekHQ counterpart: `finances/Finances`
//! (one account); the per-entity treasuries and couriers are this game's.

const std = @import("std");
const types = @import("../domain/types.zig");
const planet_mod = @import("../domain/planet.zig");
const logistics = @import("../econ/logistics.zig");
const finance_mod = @import("../econ/finance.zig");
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
