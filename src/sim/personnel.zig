//! Personnel bookkeeping that spans people and forces (Stage 12B.4).
//! Mirrors MekHQ `personnel/ranks` + the AtB "commander/lance leader"
//! designations: ranks follow seats and experience unless pinned.

const std = @import("std");
const types = @import("../domain/types.zig");
const person_mod = @import("../domain/person.zig");
const rank_mod = @import("../domain/rank.zig");
const GameState = @import("state.zig").GameState;

/// Recompute every unpinned rank: the best fit combat crew in a company is
/// its commander (Captain), the best in each line or air lance its leader
/// (Lieutenant), everyone else ranks by experience. Company and lance
/// `commander` fields follow. Returns promotions made.
pub fn refreshRanks(gs: *GameState) !u32 {
    var changed: u32 = 0;
    // Start everyone unpinned at their experience rank.
    var pit = gs.people.iterator();
    while (pit.next()) |e| {
        const p = e.value_ptr;
        if (p.status != .active or p.rank_pinned) continue;
        const r = rank_mod.Rank.forExperience(p.experience());
        if (p.rank != r) {
            if (@intFromEnum(r) > @intFromEnum(p.rank)) changed += 1;
            p.rank = r;
        }
    }
    // Seats: lance leaders, then company commanders (the best of the leaders).
    var fit = gs.forces.iterator();
    while (fit.next()) |fe| {
        const f = fe.value_ptr;
        if (f.echelon != .company) continue;
        var company_best: types.PersonId = .none;
        var company_best_skill: u8 = 99;
        for (f.children.items) |cid| {
            const lance = gs.force(cid) orelse continue;
            if (lance.echelon != .lance and lance.echelon != .air_lance) continue;
            var best: types.PersonId = .none;
            var best_skill: u8 = 99;
            for (lance.units.items) |uid| {
                const u = gs.unit(uid) orelse continue;
                const p = gs.person(u.pilot) orelse continue;
                if (p.status != .active) continue;
                const skill = p.skill(p.role.primarySkill()) orelse 7;
                if (skill < best_skill or (skill == best_skill and p.xp > (gs.person(best) orelse p).xp)) {
                    best = p.id;
                    best_skill = skill;
                }
            }
            lance.commander = best;
            if (gs.person(best)) |leader| {
                if (!leader.rank_pinned and @intFromEnum(leader.rank) < @intFromEnum(rank_mod.Rank.lieutenant)) {
                    leader.rank = .lieutenant;
                    changed += 1;
                }
                if (best_skill < company_best_skill) {
                    company_best = best;
                    company_best_skill = best_skill;
                }
            }
        }
        f.commander = company_best;
        if (gs.person(company_best)) |cmdr| if (!cmdr.rank_pinned and @intFromEnum(cmdr.rank) < @intFromEnum(rank_mod.Rank.captain)) {
            cmdr.rank = .captain;
            changed += 1;
        };
    }
    return changed;
}

test "ranks follow seats: a lance leader is a lieutenant, the company commander a captain, the rest by experience" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1234 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    const co = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha");
    _ = try refreshRanks(&gs);
    const cmdr = gs.force(co).?.commander;
    try std.testing.expect(cmdr != .none);
    try std.testing.expectEqual(rank_mod.Rank.captain, gs.person(cmdr).?.rank);
    var lieutenants: u32 = 0;
    var officers: u32 = 0;
    var pit = gs.people.iterator();
    while (pit.next()) |e| {
        if (e.value_ptr.rank == .lieutenant) lieutenants += 1;
        if (e.value_ptr.rank.isOfficer()) officers += 1;
    }
    try std.testing.expect(lieutenants >= 3);
    try std.testing.expectEqual(lieutenants + 1, officers);
    // A pinned rank survives the refresh; pay follows rank.
    const tech = blk: {
        var it = gs.people.iterator();
        while (it.next()) |e| if (e.value_ptr.role == .tech_mek) break :blk e.value_ptr;
        unreachable;
    };
    const before = tech.monthlySalary();
    tech.rank = .major;
    tech.rank_pinned = true;
    _ = try refreshRanks(&gs);
    try std.testing.expectEqual(rank_mod.Rank.major, tech.rank);
    try std.testing.expect(tech.monthlySalary() > before);
}
