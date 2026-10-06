//! Logo-key catalog: every `.png` basename under data/logos/, generated at
//! build time (build.zig scan → logos.zon) and imported at comptime. Pure
//! (ARCH rule 2). No MekHQ counterpart (docs/mekhq-map.md).

const keys = @import("logos_zon");
/// All logo keys, sorted ascending by byte order (deterministic pool order
/// for seedMercCompanies, which draws randomly without replacement from this
/// sorted pool rather than assigning by index).
pub const all_keys: []const []const u8 = &keys;

// ---- Tests -----------------------------------------------------------------

const std = @import("std");

test "logo catalog: non-empty, sorted ascending, and unique" {
    try std.testing.expect(all_keys.len > 0);
    for (0..all_keys.len) |i| {
        if (i + 1 < all_keys.len) {
            // Strict ascending order (also implies uniqueness).
            try std.testing.expect(std.mem.lessThan(u8, all_keys[i], all_keys[i + 1]));
        }
    }
}
