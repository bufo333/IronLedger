//! Random assignment tables (Stage 12B.8). Mirrors AtB's RATs (MekHQ
//! `universe/RATManager`, abridged): per house, per weight class, the
//! designs that turn up — in company generation, on the boards, and as the
//! wrecks salvaged off a house's regiment. Data in data/tables/rat.zon.

const std = @import("std");
const chassis = @import("chassis.zig");
const rng_mod = @import("../sim/rng.zig");

pub const RatRow = struct {
    faction: []const u8,
    light: []const []const u8,
    medium: []const []const u8,
    heavy: []const []const u8,
    assault: []const []const u8,

    pub fn pool(self: *const RatRow, class: chassis.WeightClass) []const []const u8 {
        return switch (class) {
            .light => self.light,
            .medium => self.medium,
            .heavy => self.heavy,
            .assault => self.assault,
        };
    }
};

pub const table: []const RatRow = @import("rat_zon");

/// The table for a faction key; unknown houses roll like the Periphery.
pub fn forFaction(key: []const u8) *const RatRow {
    for (table) |*r| if (std.mem.eql(u8, r.faction, key)) return r;
    for (table) |*r| if (std.mem.eql(u8, r.faction, "PER")) return r;
    return &table[0];
}

/// One design off a house's table for a weight class; falls back to the
/// whole catalogue class if the row is empty or names a missing design.
pub fn roll(rng: *rng_mod.Rng, stream: rng_mod.Stream, faction: []const u8, class: chassis.WeightClass) *const chassis.Chassis {
    const pool = forFaction(faction).pool(class);
    if (pool.len > 0) {
        const key = pool[rng.random(stream).uintLessThan(usize, pool.len)];
        if (chassis.find(key)) |c| return c;
    }
    var buf: [64]*const chassis.Chassis = undefined;
    const all = chassis.ofWeightClass(class, &buf);
    return all[rng.random(stream).uintLessThan(usize, all.len)];
}

test "every RAT entry names a catalogue mek of the right class; every house has all four classes" {
    try std.testing.expect(table.len >= 6);
    for (table) |row| {
        inline for (.{ chassis.WeightClass.light, .medium, .heavy, .assault }) |class| {
            const pool = row.pool(class);
            try std.testing.expect(pool.len > 0);
            for (pool) |key| {
                const c = chassis.find(key) orelse {
                    std.debug.print("RAT {s}: unknown design {s}\n", .{ row.faction, key });
                    return error.TestUnexpectedResult;
                };
                try std.testing.expect(c.kind == .mek);
                if (c.weightClass() != class) {
                    std.debug.print("RAT {s}: {s} is {s}, listed as {s}\n", .{ row.faction, key, @tagName(c.weightClass()), @tagName(class) });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
    try std.testing.expectEqualStrings("PER", forFaction("nobody").faction);
}
