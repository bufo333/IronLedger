//! Black-market dispersed listing placement: eligibility predicate and listing
//! constructor. MekHQ counterpart: AtB black market / `market/UnitMarket`
//! grey-market offers (docs/mekhq-map.md). Design: docs/p3f-faction-loop-design.md §2.3.
//! Pure: no I/O, no wall clock, no global state (ARCH rule 2).

const std = @import("std");
const types = @import("../domain/types.zig");
const market = @import("../econ/market.zig");
const GameState = @import("state.zig").GameState;
const rng_mod = @import("rng.zig");

/// Who is evaluating a black-market listing offer.
pub const BuyerKind = enum { player, pirate, merc_company };

/// Single owner of the "can buyer X take listing Y" rule (rule 20/3).
/// Returns true iff the listing is a black-market offer whose visibility
/// window has opened on the given day.
/// `gs` and `buyer` are retained for the P3f.3 per-buyer reach gate on
/// listing.planet_key; until then every black-market world is reachable
/// by every buyer.
pub fn buyerEligible(gs: *const GameState, listing: market.Listing, buyer: BuyerKind, current_day: u32) bool {
    _ = gs;
    _ = buyer;
    if (!listing.black_market) return false;
    if (listing.available_after > current_day) return false;
    // P3f.3 fills per-buyer reach gating of listing.planet_key.
    return true;
}

/// Compile-ready dispersed listing constructor used by P3f.2.
/// Constructs a black-market listing placed on `planet_key`, becoming
/// visible at `battle_day + delay_days`.
/// `gs` and `rng` are retained for the P3f.2 world-selection and pricing
/// logic; P3f.2 fills price, item key, and id selection.
pub fn makeDispersedListing(
    gs: *GameState,
    hull_instance_id: types.HullInstanceId,
    planet_key: []const u8,
    battle_day: u32,
    rng: *rng_mod.Rng,
    delay_days: u32,
) market.Listing {
    _ = gs;
    _ = rng;
    return market.Listing{
        .kind = .unit,
        .item_key = "",
        .rarity = .common,
        .price = 0,
        .black_market = true,
        .planet_key = planet_key,
        .available_after = battle_day + delay_days,
        .hull_instance_id = hull_instance_id,
    };
}

test "buyerEligible: black_market flag and available_after gate access for all BuyerKinds" {
    // Rule 67: buyerEligible is the single owner of the black-market listing
    // eligibility predicate. Table-driven over the two axes:
    // {black_market true/false} x {available_after <= current_day / >}.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 57100 });
    defer gs.deinit();

    const current_day: u32 = 50;

    const Case = struct {
        black_market: bool,
        available_after: u32,
        want: bool,
    };
    const cases = [_]Case{
        .{ .black_market = true, .available_after = 0, .want = true },
        .{ .black_market = true, .available_after = 50, .want = true },
        .{ .black_market = true, .available_after = 51, .want = false },
        .{ .black_market = false, .available_after = 0, .want = false },
        .{ .black_market = false, .available_after = 50, .want = false },
    };
    const buyers = [_]BuyerKind{ .player, .pirate, .merc_company };

    for (cases) |c| {
        const listing = market.Listing{
            .kind = .unit,
            .item_key = "SHD-2H",
            .rarity = .common,
            .price = 0,
            .black_market = c.black_market,
            .available_after = c.available_after,
        };
        for (buyers) |buyer| {
            const got = buyerEligible(&gs, listing, buyer, current_day);
            try std.testing.expectEqual(c.want, got);
        }
    }
}
