//! Scenario types (Stage 12C.9). Adaptation of MekHQ/AtB `AtBScenario` types
//! (stand-up, hold the line, breakthrough, ambush, convoy, base attack,
//! recon, extraction) abridged to the autoresolver's levers. Data in
//! data/tables/scenarios.zon.

const std = @import("std");
const types = @import("types.zig");
const contract = @import("contract.zig");
const rng_mod = @import("../sim/rng.zig");

pub const Scenario = struct {
    key: []const u8,
    name: []const u8,
    /// Opposing force relative to the contract kind's baseline.
    enemy_bp: types.Bp,
    /// Shift on the engagement roll (negative: the enemy chose the ground).
    roll_mod: i8,
    /// What a scouting lance gives back (an ambush spotted is half an ambush).
    scout_bonus: i8,
    /// Share of the salvage claim a held field yields (raids move on).
    salvage_bp: types.Bp,
    /// Weight of this fight in the contract score.
    score_mult: u8,
    /// The support train sits in the line of fire on a defeat.
    support_exposed: bool,
    /// Recovering wrecks off a lost field: your own ground helps,
    /// the enemy's lines hurt.
    recovery_mod: i8 = 0,
};

pub const KindTable = struct { kind: []const u8, table: [6][]const u8 };

pub const Table = struct { scenarios: []const Scenario, by_kind: []const KindTable };

pub const table: Table = @import("scenarios_zon");

pub fn find(key: []const u8) ?*const Scenario {
    for (table.scenarios) |*s| if (std.mem.eql(u8, s.key, key)) return s;
    return null;
}

/// The six faces of a kind's scenario table (the rating averages
/// over them exactly instead of rolling).
pub fn faces(kind: contract.ContractKind) [6]*const Scenario {
    var out: [6]*const Scenario = undefined;
    const standup = find("standup").?;
    for (&out) |*f| f.* = standup;
    for (table.by_kind) |row| if (std.mem.eql(u8, row.kind, @tagName(kind))) {
        for (row.table, 0..) |key, i| out[i] = find(key) orelse standup;
    };
    return out;
}

/// Roll the scenario for an engagement on `kind`: d6 on the kind's table
/// (a stand-up fight when a kind has no table).
pub fn roll(rng: *rng_mod.Rng, stream: rng_mod.Stream, kind: contract.ContractKind) *const Scenario {
    const face = rng.random(stream).uintLessThan(usize, 6);
    for (table.by_kind) |row| if (std.mem.eql(u8, row.kind, @tagName(kind))) {
        return find(row.table[face]) orelse find("standup").?;
    };
    return find("standup").?;
}

test "data: every contract kind has a table and every entry resolves" {
    inline for (@typeInfo(contract.ContractKind).@"enum".fields) |f| {
        var found = false;
        for (table.by_kind) |row| if (std.mem.eql(u8, row.kind, f.name)) {
            found = true;
            for (row.table) |key| try std.testing.expect(find(key) != null);
        };
        try std.testing.expect(found);
    }
    var rng = rng_mod.Rng.init(9);
    const a = roll(&rng, .battle, .recon_raid);
    try std.testing.expect(a.salvage_bp <= 10_000);
    try std.testing.expect(find("ambush").?.roll_mod < 0 and find("ambush").?.scout_bonus > 0);
}
