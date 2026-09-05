//! Person & name generation. Mirrors MekHQ's `RandomNameGenerator` +
//! AtB personnel generation: experience rolled on 2d6, skills set from the
//! experience band. Name tables live in data/tables/names.zon.

const std = @import("std");
const types = @import("../domain/types.zig");
const person = @import("../domain/person.zig");
const rng_mod = @import("../sim/rng.zig");
const company_gen = @import("company_gen.zig");

/// Name tables from data/tables/names.zon (Stage 12.17).
const names: struct { first: []const []const u8, last: []const []const u8, callsigns: []const []const u8 } = @import("names_zon");
const first_names = names.first;
const last_names = names.last;
const callsigns = names.callsigns;

pub const GeneratedPerson = struct {
    first: []const u8,
    last: []const u8,
    callsign: ?[]const u8,
    role: person.Role,
    experience: types.ExperienceLevel,
    /// Primary/secondary skill levels for the role (gunnery/piloting for
    /// combat crews; primary tech/medical/admin skill twice for support).
    primary_skill: u8,
    secondary_skill: u8,
    /// Age in years at generation (12C.4).
    age: u8 = 30,
};

/// Age band by trade and experience (12C.4, MekHQ `RandomAge`-style):
/// cockpits skew young and the elite have been at it a while; techs span
/// a career; doctors and desk staff have had one already.
pub fn rollAge(rng: *rng_mod.Rng, role: person.Role, xp: types.ExperienceLevel) u8 {
    const r = rng.random(.generation);
    const band: struct { u8, u8 } = if (role.isCombat())
        switch (xp) {
            .green => .{ 19, 25 },
            .regular => .{ 23, 32 },
            .veteran => .{ 28, 40 },
            .elite => .{ 33, 48 },
        }
    else switch (role) {
        .doctor => .{ 30, 60 },
        .admin_command, .admin_logistics, .admin_transport, .admin_hr, .admin_finance => .{ 25, 55 },
        .astech, .medic => .{ 18, 40 },
        else => .{ 20, 50 }, // techs and ship crews
    };
    return band[0] + r.uintLessThan(u8, band[1] - band[0] + 1);
}

/// Skill levels per experience band (combat convention: gunnery/piloting;
/// support roles use `primary` only).
fn skillsFor(xp: types.ExperienceLevel) struct { u8, u8 } {
    return switch (xp) {
        .elite => .{ 2, 3 },
        .veteran => .{ 3, 4 },
        .regular => .{ 4, 5 },
        .green => .{ 5, 6 },
    };
}

pub fn generate(rng: *rng_mod.Rng, role: person.Role) GeneratedPerson {
    return generateWithBonus(rng, role, 0);
}

/// `bonus` shifts the 2d6 experience roll (hiring hall + HR office, Stage 9C).
pub fn generateWithBonus(rng: *rng_mod.Rng, role: person.Role, bonus: i32) GeneratedPerson {
    const r = rng.random(.generation);
    const xp = company_gen.rollExperienceWithBonus(rng, bonus);
    const skills = skillsFor(xp);
    const combat = role.isCombat();
    return .{
        .first = first_names[r.uintLessThan(usize, first_names.len)],
        .last = last_names[r.uintLessThan(usize, last_names.len)],
        // Mekwarriors and aero jocks pick up callsigns; ~half have one.
        .callsign = if ((role == .mekwarrior or role == .aero_pilot) and r.boolean())
            callsigns[r.uintLessThan(usize, callsigns.len)]
        else
            null,
        .role = role,
        .experience = xp,
        .primary_skill = skills[0],
        .secondary_skill = if (combat) skills[1] else skills[0],
        .age = rollAge(rng, role, xp),
    };
}

test "12C.4: ages sit in the trade's band" {
    var rng = rng_mod.Rng.init(4);
    for (0..40) |_| {
        const pilot = generate(&rng, .mekwarrior);
        try std.testing.expect(pilot.age >= 19 and pilot.age <= 48);
        const doc = generate(&rng, .doctor);
        try std.testing.expect(doc.age >= 30 and doc.age <= 60);
    }
}

test "generation is deterministic per seed and skills match the band" {
    var a = rng_mod.Rng.init(99);
    var b = rng_mod.Rng.init(99);
    for (0..50) |_| {
        const pa = generate(&a, .mekwarrior);
        const pb = generate(&b, .mekwarrior);
        try std.testing.expectEqualStrings(pa.first, pb.first);
        try std.testing.expectEqualStrings(pa.last, pb.last);
        try std.testing.expectEqual(pa.experience, pb.experience);

        // Skill levels must encode the rolled experience band.
        const expected: struct { u8, u8 } = skillsFor(pa.experience);
        try std.testing.expectEqual(expected[0], pa.primary_skill);
        try std.testing.expectEqual(expected[1], pa.secondary_skill);
    }
}

test "experience distribution is 2d6-shaped over many rolls" {
    var rng = rng_mod.Rng.init(4242);
    var regulars: u32 = 0;
    var elites: u32 = 0;
    for (0..2_000) |_| {
        switch (generate(&rng, .mekwarrior).experience) {
            .regular => regulars += 1,
            .elite => elites += 1,
            else => {},
        }
    }
    try std.testing.expect(regulars > 1_000); // 6–9 on 2d6 dominates
    try std.testing.expect(elites > 0 and elites < 200); // 12s are rare
}
