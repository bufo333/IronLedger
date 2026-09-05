//! Special pilot abilities (Stage 12B.6). Mirrors AtB/MekHQ `SpecialAbility`
//! (`personnel/SpecialAbility.java`) abridged to eight the autoresolve model
//! honours: each is one modifier — skill points, hit avoidance, wound
//! survival, healing, morale, lance power, or a re-roll. Data in
//! data/tables/abilities.zon; bought with XP at a training ground.

const std = @import("std");

pub const AbilityRow = struct {
    key: []const u8,
    name: []const u8,
    xp_cost: u32,
    text: []const u8,
};

pub const table: []const AbilityRow = @import("abilities_zon");

pub fn find(key: []const u8) ?*const AbilityRow {
    for (table) |*a| if (std.mem.eql(u8, a.key, key)) return a;
    return null;
}

test "abilities load with unique keys and XP costs" {
    try std.testing.expectEqual(@as(usize, 8), table.len);
    for (table, 0..) |a, i| {
        try std.testing.expect(a.xp_cost > 0);
        for (table[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a.key, b.key));
    }
    try std.testing.expect(find("edge") != null and find("foo") == null);
}
