//! The outfit's Dragoons rating (CamOps "Mercenary Rating", MekHQ
//! `rating/UnitRating` / `CamOpsReputation`): six scored parts and a
//! letter. This is a rule, not a screen: the contract market sets pay
//! from it, negotiation rolls against it, the recruit bonus reads it and
//! the New Year entry records it. `queries.rating` phrases the parts.

const std = @import("std");
const types = @import("../domain/types.zig");
const tuning = @import("../domain/tuning.zig").t;
const person_mod = @import("../domain/person.zig");
const personnel = @import("personnel.zig");
const GameState = @import("state.zig").GameState;
const hq_ops = @import("hq_ops.zig");
const treasury = @import("treasury.zig");

/// The six parts with the numbers each was scored from, so a screen can
/// phrase them without recomputing anything.
pub const Report = struct {
    score: i32,
    experience: struct { score: i32, crews: u32, avg_x10: u32 },
    command: struct { score: i32, desks_have: u32, desks_need: u32, officers: u32 },
    record: struct { score: i32, closed: u32, reputation: i32 },
    transport: struct { score: i32, covered_bp: i64, jumpship: bool },
    support: struct { score: i32, have: u32, need: u32 },
    finances: struct { score: i32, debt: types.CBills, months: i64, overdrawn: bool },
};

/// Letter index 0…5 (F, D, C, B, A, A*) — what the board reads.
pub fn index(total: i32) u8 {
    const t = tuning.rating;
    if (total >= t.letter_a_star) return 5;
    if (total >= t.letter_a) return 4;
    if (total >= t.letter_b) return 3;
    if (total >= t.letter_c) return 2;
    if (total >= t.letter_d) return 1;
    return 0;
}

pub fn letter(total: i32) []const u8 {
    return switch (index(total)) {
        0 => "F",
        1 => "D",
        2 => "C",
        3 => "B",
        4 => "A",
        else => "A*",
    };
}

/// Pay multiplier the letter earns.
pub fn payBp(idx: u8) types.Bp {
    const t = tuning.rating;
    return switch (idx) {
        0 => t.pay_bp_f,
        1 => t.pay_bp_d,
        2 => t.pay_bp_c,
        3 => t.pay_bp_b,
        4 => t.pay_bp_a,
        else => t.pay_bp_a_star,
    };
}

/// The score alone. Allocation-free, so the market and the dice can call
/// it without an arena and nothing is swallowed on the way.
pub fn score(gs: *GameState) i32 {
    return report(gs).score;
}

pub fn currentIndex(gs: *GameState) u8 {
    return index(score(gs));
}

pub fn report(gs: *GameState) Report {
    const t = tuning.rating;
    var r: Report = undefined;
    var total: i32 = 0;

    // Experience: average primary skill of the active combat crews.
    {
        var sum: u32 = 0;
        var n: u32 = 0;
        var pit = gs.people.iterator();
        while (pit.next()) |e| {
            const p = e.value_ptr;
            if (p.status != .active or !p.role.isCombat()) continue;
            sum += p.skill(p.role.primarySkill()) orelse 7;
            n += 1;
        }
        const avg_x10: u32 = if (n > 0) sum * 10 / n else 70;
        const s: i32 = if (avg_x10 <= 30) 40 else if (avg_x10 <= 35) 30 else if (avg_x10 <= 40) 20 else if (avg_x10 <= 50) 10 else 0;
        r.experience = .{ .score = s, .crews = n, .avg_x10 = avg_x10 };
        total += s;
    }
    // Command: desks staffed at every HQ, officers on the books.
    {
        var need: u32 = 0;
        var have: u32 = 0;
        var hit = gs.hqs.iterator();
        while (hit.next()) |e| {
            const hq = e.value_ptr;
            for (hq.staffRequired().desks()) |d| {
                need += d.need;
                have += @min(d.need, hq_ops.hqStaff(gs, hq.id, d.role).count);
            }
        }
        var officers: u32 = 0;
        var pit = gs.people.iterator();
        while (pit.next()) |e| if (e.value_ptr.status == .active and e.value_ptr.rank.isOfficer()) {
            officers += 1;
        };
        const desk_score: i32 = if (need == 0) 10 else @intCast(have * 10 / need);
        const officer_score: i32 = @intCast(@min(10, officers * 2));
        r.command = .{ .score = desk_score + officer_score, .desks_have = have, .desks_need = need, .officers = officers };
        total += r.command.score;
    }
    // Combat record: every contract's outcome, plus what events did to the name.
    {
        var pts: i32 = 0;
        var done: u32 = 0;
        for (gs.contracts.values()) |c| {
            switch (c.status) {
                .completed => {
                    done += 1;
                    pts += switch (c.gradeOf()) {
                        .outstanding => t.record_outstanding,
                        .strong => t.record_strong,
                        .satisfactory => t.record_satisfactory,
                        .poor => t.record_poor,
                    };
                },
                .failed => {
                    done += 1;
                    pts += t.record_failed;
                },
                .breached => {
                    done += 1;
                    pts += t.record_breached;
                },
                else => {},
            }
        }
        pts += gs.reputation;
        if (done == 0) pts += t.record_unproven; // nobody has seen you fight
        const s = std.math.clamp(pts, -t.record_cap, t.record_cap);
        r.record = .{ .score = s, .closed = done, .reputation = gs.reputation };
        total += s;
    }
    // Transport: own lift for the companies at home, own jumpship.
    {
        const commands = @import("commands.zig");
        var covered_sum: i64 = 0;
        var companies: u32 = 0;
        var jumpship = false;
        var fit = gs.forces.iterator();
        while (fit.next()) |e| {
            const f = e.value_ptr;
            if (f.echelon != .company) continue;
            companies += 1;
            const plan = commands.planLift(gs, f.id, false) catch continue;
            covered_sum += plan.covered_bp;
            if (plan.own_jumpship) jumpship = true;
        }
        const covered_bp: i64 = if (companies > 0) @divTrunc(covered_sum, companies) else 0;
        var s: i32 = @intCast(@divTrunc(covered_bp * 20, 10_000));
        if (jumpship) s += 10;
        r.transport = .{ .score = s, .covered_bp = covered_bp, .jumpship = jumpship };
        total += s;
    }
    // Support: techs, astechs and medical against the manning tables.
    {
        var need: u32 = 0;
        var have: u32 = 0;
        var fit = gs.forces.iterator();
        while (fit.next()) |e| {
            const f = e.value_ptr;
            if (f.echelon != .company) continue;
            for (personnel.manningNeeds(gs, f.id)) |n| {
                if (!(n.role.isTech() or n.role == .astech or n.role == .doctor or n.role == .medic)) continue;
                need += n.need;
                have += @min(n.need, personnel.manningHave(gs, f.id, n.role));
            }
        }
        const s: i32 = if (need == 0) 10 else @intCast(have * 20 / need);
        r.support = .{ .score = s, .have = have, .need = need };
        total += s;
    }
    // Finances: debt against payroll, and the colour of the treasury.
    {
        var debt: types.CBills = 0;
        for (gs.loans.items) |l| debt += l.balance;
        const payroll = treasury.monthlyPayroll(gs);
        var s: i32 = 10;
        var months: i64 = 0;
        if (debt > 0) {
            months = if (payroll > 0) @divTrunc(debt, payroll) else 99;
            s = if (months <= 6) 0 else -10;
        }
        const overdrawn = gs.funds < 0;
        if (overdrawn) s -= 20;
        r.finances = .{ .score = s, .debt = debt, .months = months, .overdrawn = overdrawn };
        total += s;
    }
    r.score = total;
    return r;
}

test "letters step at the tuned thresholds and pay follows the letter" {
    try std.testing.expectEqualStrings("F", letter(-1));
    try std.testing.expectEqualStrings("A*", letter(120));
    try std.testing.expectEqual(@as(u8, 0), index(-1));
    try std.testing.expectEqual(@as(u8, 5), index(120));
    try std.testing.expectEqual(tuning.rating.pay_bp_f, payBp(0));
    try std.testing.expectEqual(tuning.rating.pay_bp_a_star, payBp(5));
}

test "the report's parts sum to the score; a fresh outfit is unproven and debt-free" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    const r = report(&gs);
    try std.testing.expectEqual(r.experience.score + r.command.score + r.record.score + r.transport.score + r.support.score + r.finances.score, r.score);
    try std.testing.expectEqual(@as(u32, 0), r.record.closed);
    try std.testing.expect(!r.finances.overdrawn);
    try std.testing.expectEqual(score(&gs), r.score);
}
