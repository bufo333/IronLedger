//! Persistent bounded per-world state (ROADMAP P4h.4).
//! Five numeric dimensions track the world's condition across deployments;
//! each is clamped to a single named range. A cause label and day record
//! the most recent change for history display. No MekHQ counterpart
//! (P4 operations design §§3,5).

const std = @import("std");

/// The five dimensions of per-world state (ROADMAP P4h.4).
pub const WorldDim = enum {
    security,
    civilian_support,
    infrastructure_strain,
    employer_control,
    enemy_influence,

    /// Short display label (markup-safe).
    pub fn label(self: WorldDim) []const u8 {
        return switch (self) {
            .security => "security",
            .civilian_support => "civ.support",
            .infrastructure_strain => "infra.strain",
            .employer_control => "emp.control",
            .enemy_influence => "enemy.infl",
        };
    }
};

/// Min/max bounds for world state dimensions (rule 24: single named constant). // TUNE
pub const world_min: i16 = -100; // TUNE
pub const world_max: i16 = 100; // TUNE

/// Per-world state persisted across contracts (P4h.4).
/// Stored in GameState.world_states keyed by planet_key.
pub const WorldState = struct {
    security: i16 = 0,
    civilian_support: i16 = 0,
    infrastructure_strain: i16 = 0,
    employer_control: i16 = 0,
    enemy_influence: i16 = 0,
    /// Short markup-safe label for the most recent change cause.
    last_cause: []const u8 = "",
    /// Day index of the most recent change.
    last_cause_day: u32 = 0,
};

// ---- Tests -----------------------------------------------------------------

test "WorldState defaults are zero" {
    const ws: WorldState = .{};
    try std.testing.expectEqual(@as(i16, 0), ws.security);
    try std.testing.expectEqual(@as(i16, 0), ws.civilian_support);
    try std.testing.expectEqual(@as(i16, 0), ws.infrastructure_strain);
    try std.testing.expectEqual(@as(i16, 0), ws.employer_control);
    try std.testing.expectEqual(@as(i16, 0), ws.enemy_influence);
    try std.testing.expectEqual(@as(u32, 0), ws.last_cause_day);
    try std.testing.expectEqualStrings("", ws.last_cause);
}

test "WorldDim labels are non-empty and markup-safe" {
    const markupSafe = struct {
        fn f(s: []const u8) bool {
            if (!std.unicode.utf8ValidateSlice(s)) return false;
            var it = std.unicode.Utf8View.initUnchecked(s).iterator();
            while (it.nextCodepoint()) |cp| {
                if (cp == '{' or cp < 0x20 or cp == 0x7f or (cp >= 0x80 and cp < 0xa0)) return false;
            }
            return true;
        }
    }.f;

    inline for (@typeInfo(WorldDim).@"enum".fields) |f| {
        const dim: WorldDim = @enumFromInt(f.value);
        const lbl = dim.label();
        try std.testing.expect(lbl.len > 0);
        try std.testing.expect(markupSafe(lbl));
    }
}

test "world_min and world_max are +-100" {
    try std.testing.expectEqual(@as(i16, -100), world_min);
    try std.testing.expectEqual(@as(i16, 100), world_max);
}
