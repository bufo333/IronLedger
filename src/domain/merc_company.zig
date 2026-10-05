//! Persistent world merc company: the identity entity for an independent
//! mercenary outfit operating in the same theatre as the player. Introduced
//! by the P3e entity split (docs/p3c-economy-design.md §8); first producer
//! is P3e.5. No MekHQ counterpart (docs/p3c-economy-design.md §8).

const std = @import("std");
const types = @import("types.zig");
const rival_mod = @import("rival.zig");

/// Re-export FactionSide and RivalDoctrine from rival.zig for consumers of
/// this module who need the enums without importing rival.zig directly.
pub const FactionSide = rival_mod.FactionSide;
pub const RivalDoctrine = rival_mod.RivalDoctrine;

/// A persistent world merc company (docs/p3c-economy-design.md §8).
/// Stored in GameState.merc_companies keyed by MercCompanyId.
/// No producer this increment — the collection is empty until P3e.5.
pub const MercCompany = struct {
    id: types.MercCompanyId = .none,
    /// Key into rival_archetypes.zon.
    archetype_key: []const u8 = "",
    /// Commander name (generated).
    commander_first: []const u8 = "",
    commander_last: []const u8 = "",
    /// Unit name: display name for this merc company.
    unit_name: []const u8 = "",
    /// Faction key (side affiliation).
    faction_key: []const u8 = "",
    /// Which side of the conflict.
    side: FactionSide = .employer,
    /// Operational doctrine.
    doctrine: RivalDoctrine = .cautious,
};

test "MercCompany defaults" {
    const mc: MercCompany = .{};
    try std.testing.expectEqual(types.MercCompanyId.none, mc.id);
    try std.testing.expectEqualStrings("", mc.archetype_key);
    try std.testing.expectEqualStrings("", mc.unit_name);
    try std.testing.expectEqual(FactionSide.employer, mc.side);
    try std.testing.expectEqual(RivalDoctrine.cautious, mc.doctrine);
}
