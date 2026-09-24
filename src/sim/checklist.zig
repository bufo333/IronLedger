//! The end-turn checklist (Stage 9C.2, ARCH §9.9): everything the player
//! should know before time moves. A pure query over GameState — the CLI
//! refuses to advance until it's acknowledged; the TUI renders it as a
//! modal. Nothing slips past a turn boundary unannounced.
//! No direct MekHQ counterpart: MekHQ reports these in its daily log and nag
//! dialogs (docs/mekhq-map.md).

const std = @import("std");
const person_mod = @import("../domain/person.zig");
const types = @import("../domain/types.zig");
const unit_mod = @import("../domain/unit.zig");
const part_mod = @import("../domain/part.zig");
const hq_ops = @import("hq_ops.zig");
const table = @import("table.zig");
const medical = @import("medical.zig");
const GameState = @import("state.zig").GameState;

pub const WarningKind = enum {
    decision_due,
    open_slots,
    understaffed_hq,
    /// Someone reaches retirement age within the quarter.
    retiring_soon,
    hungry,
    dry_ammo,
    overdrawn,
    depot_backlog,
    medbay_over_capacity,
    tech_overloaded,
    combat_ineffective,
    objectives_met,
    company_idle_afield,
    /// Wounded people nobody has admitted to a medbay (they don't heal).
    untreated_wounded,
    /// The outfit treasury is negative: the turn cannot advance until a
    /// loan or a sale covers it; past the credit limit, the outfit folds.
    insolvent,
    /// People at home who roll to leave on payday
    /// (`medical.turnoverRisk`): a year in and restless.
    restless_crew,
    /// A company's manning table has open seats beyond pilots and techs
    /// (astechs, doctors, medics, office) — quietly slowing repairs and
    /// healing.
    manning_short,
    /// Seated pilots in the spent fatigue band: +3 to gunnery and
    /// piloting until they rest; the auto-assigner benches them when it can.
    unfit_crew,
    /// A company fields meks whose structure its home HQ's bay is not
    /// rated to rebuild: heavy assemblies need bay 2, assault bay 3
    /// at a regional HQ.
    unrebuildable_hulls,
    /// An engagement resolved that nobody has read. With `battle_decision`,
    /// it holds the turn outright (`turnHold`), acknowledged or not.
    unread_after_action,
    /// An active contract rates 4½ skulls or worse for the company on it
    /// today: consider cautious ROE or recall.
    outmatched,
    /// A battle decision nobody has answered. Like the unread
    /// after-action, the turn waits on it rather than defaulting.
    battle_decision,
    /// An engagement is inside the contact warning window: the odds, the
    /// strength and the ammunition while ROE and recall can still act.
    contact_imminent,
    /// Hulls whose pilot or tech is wounded or on leave: the seat waits
    /// for them and the hull sits out until they are back.
    crew_recovering,

    /// Costs the outfit something if it is left (ARCH §9.9): the screens
    /// mark it red. Advisory — the turn ends anyway; only `turnHold` and
    /// an insolvent outfit refuse an advance.
    pub fn urgent(self: WarningKind) bool {
        return switch (self) {
            .unread_after_action, .battle_decision, .decision_due, .understaffed_hq, .overdrawn, .combat_ineffective, .dry_ammo, .hungry, .untreated_wounded, .insolvent => true,
            else => false,
        };
    }

    /// The end-turn prompt asks about it. A warning the commander has
    /// nothing to do about this turn stays on the Desk and does not
    /// stop the turn to say so again.
    pub fn prompts(self: WarningKind) bool {
        return switch (self) {
            .crew_recovering => false,
            else => true,
        };
    }
};

/// Does any working weapon in the company draw on this munition family?
/// (`field_supply.munitionMounts` is the census; callers with several
/// families to ask about take the map once.)
fn companyFires(gs: *GameState, company: types.ForceId, family: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(gs.scratch());
    defer arena.deinit();
    const mounts = @import("field_supply.zig").munitionMounts(arena.allocator(), gs, company, false) catch return false;
    return mounts.contains(family);
}

pub const Warning = struct {
    kind: WarningKind,
    text: []const u8,
    /// The contract the warning is about, when it is about one (the
    /// contact warning opens that contract's battle orders).
    contract: types.ContractId = .none,
};

/// The contact warning for one contract: days to contact, the skulls and
/// odds under the ROE in force, fieldable strength against what was
/// committed, whole engagements of each munition family, and what the
/// commander can still do.
pub fn contactText(alloc: std.mem.Allocator, gs: *GameState, c: *const @import("../domain/contract.zig").Contract) ![]const u8 {
    const battle = @import("battle.zig");
    const offer_rating = @import("offer_rating.zig");
    const company = c.assigned_company;
    const days = battle.daysToContact(gs, c) orelse 0;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const world = if (@import("../domain/planet.zig").find(c.planet_key)) |p| p.name else c.planet_key;
    try out.print(alloc, "{s}: contact on {s} in {d} day{s}", .{ if (gs.force(company)) |f| try table.plain(alloc, f.name) else "—", world, days, if (days == 1) "" else "s" });
    if (try offer_rating.rateOffer(alloc, gs, c, company)) |rt| {
        try out.print(alloc, " — {s}{s}, wins {d}% of fights, loses the field {d}%", .{
            if (rt.warrantsWarning()) "OUTMATCHED at " else "", try offer_rating.skullText(alloc, rt), rt.win_pct, rt.lose_field_pct,
        });
    }
    const fieldable = @import("contract_control.zig").fieldableBv(gs, company);
    if (c.committed_bv > 0) {
        try out.print(alloc, " · fieldable {d} BV ({d}% of committed)", .{ fieldable, @divTrunc(fieldable * 100, c.committed_bv) });
    } else try out.print(alloc, " · fieldable {d} BV", .{fieldable});
    const ammo = try @import("field_supply.zig").ammoFights(alloc, gs, company);
    for (ammo, 0..) |a, i| {
        try out.appendSlice(alloc, if (i == 0) " · ammo " else ", ");
        if (a.fights == 0) {
            try out.print(alloc, "{s} dry", .{part_mod.munitionLabel(a.key)});
        } else try out.print(alloc, "{s} {d} fight{s}", .{ part_mod.munitionLabel(a.key), a.fights, if (a.fights == 1) "" else "s" });
    }
    if (c.terms.command_rights.overridesRoe()) {
        try out.appendSlice(alloc, " · ROE held by the employer's command");
    } else {
        try out.print(alloc, " · ROE {s}", .{@tagName(battle.effectiveRoe(gs, c, company))});
    }
    try out.appendSlice(alloc, " · give battle orders");
    return out.toOwnedSlice(alloc);
}

/// The first contract whose contact window opened with today's tick; a
/// multi-day advance stops on that day and does not refuse the next.
pub fn contactOpenedToday(gs: *GameState) ?*const @import("../domain/contract.zig").Contract {
    const battle = @import("battle.zig");
    var it = gs.contracts.iterator();
    while (it.next()) |e| {
        if (battle.contactWindowOpensToday(gs, e.value_ptr)) return e.value_ptr;
    }
    return null;
}

/// Why time is not moving (ARCH §6). Two things stop a turn outside
/// money, and both dispose of something permanent with no safe default to
/// lapse to: an engagement nobody has read, and a battle decision nobody
/// has answered. One function decides, so `advance` and the checklist
/// cannot disagree about whether the turn is held.
pub const Hold = enum { unread_after_action, battle_decision };

pub fn turnHold(gs: *GameState) ?Hold {
    if (gs.battle_reports.unread() != null) return .unread_after_action;
    if (gs.event_queue.blocking() != null) return .battle_decision;
    return null;
}

test "depot backlog only counts hulls whose company is home" {
    const commands = @import("commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 21 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const res = try commands.execute(&gs, .{ .new_company = "Alpha" });
    // Break a structure slot on one hull.
    const uid = gs.units.keys()[0];
    const u = gs.unit(uid).?;
    for (u.slots.items) |*s| if (s.class == .structure) {
        s.condition = .destroyed;
        break;
    };
    try std.testing.expect(u.needsDepot());
    // Empty the warehouse of components so the bay cannot start the job.
    if (gs.hqs.getPtr(gs.hqs.keys()[0])) |h| h.stock.clearRetainingCapacity();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const home = try turnWarnings(&gs, arena.allocator());
    var found = false;
    for (home) |w| if (w.kind == .depot_backlog) {
        found = true;
    };
    try std.testing.expect(found);

    // Send the company away: the same damage is not a backlog.
    gs.forces.getPtr(res.created_force).?.location_planet = "galatea";
    const away = try turnWarnings(&gs, arena.allocator());
    for (away) |w| try std.testing.expect(w.kind != .depot_backlog);
}

/// Build the checklist. `alloc` owns the returned slice and texts.
pub fn turnWarnings(gs: *GameState, alloc: std.mem.Allocator) ![]Warning {
    var out: std.ArrayListUnmanaged(Warning) = .empty;
    const day = gs.clock.day_index;

    // An engagement nobody has read: the turn waits on it, so it
    // leads — there is nothing to decide until the commander has seen it.
    if (gs.battle_reports.unread()) |r| {
        try out.append(alloc, .{ .kind = .unread_after_action, .text = try std.fmt.allocPrint(alloc, "after-action from day {d} unread: {s} on {s} — {s}, field {s}", .{
            r.day, r.scenario, r.terrain, @tagName(r.outcome), if (r.held_field) "held" else "lost",
        }) });
    }

    // A battle decision nobody has answered: the turn waits on
    // it too, so it sits with the report it followed.
    if (gs.event_queue.blocking()) |ev| {
        const entry = @import("contract_events.zig").entryForKind(ev.kind);
        try out.append(alloc, .{ .kind = .battle_decision, .text = try std.fmt.allocPrint(alloc, "decision #{d} from day {d} unanswered: {s}", .{
            @intFromEnum(ev.id), ev.day, if (entry) |e| e.log else @tagName(ev.kind),
        }) });
    }

    // Money first: nothing else matters if the outfit cannot pay.
    if (gs.funds + @import("treasury.zig").inboundToOutfit(gs) < 0) {
        const folds = @import("treasury.zig").isInsolvent(gs);
        try out.append(alloc, .{ .kind = .insolvent, .text = try std.fmt.allocPrint(alloc, "outfit treasury overdrawn ({d}{s}) — take a loan (credit {d}), transfer funds back from an HQ or company, or sell assets (worth {d}){s}", .{
            gs.funds, if (@import("treasury.zig").inboundToOutfit(gs) > 0) try std.fmt.allocPrint(alloc, ", {d} on the road", .{@import("treasury.zig").inboundToOutfit(gs)}) else "", @import("treasury.zig").creditRemaining(gs), @import("treasury.zig").liquidationValue(gs), if (folds) "; nothing left covers it: the outfit folds" else "",
        }) });
    }

    // Contact inside the warning window replaces the outmatched warning for
    // that contract; outside it, an outmatched company is still warned.
    {
        const offer_rating = @import("offer_rating.zig");
        const battle = @import("battle.zig");
        var cit = gs.contracts.iterator();
        while (cit.next()) |ce| {
            const c = ce.value_ptr;
            if (c.status != .active) continue;
            if (battle.inContactWindow(gs, c)) {
                if (!battle.ordersConfirmed(c)) try out.append(alloc, .{ .kind = .contact_imminent, .text = try contactText(alloc, gs, c), .contract = c.id });
                continue;
            }
            const rt = (try offer_rating.rateOffer(alloc, gs, c, c.assigned_company)) orelse continue;
            if (!rt.warrantsWarning()) continue;
            try out.append(alloc, .{ .kind = .outmatched, .text = try std.fmt.allocPrint(alloc, "{s} is outmatched on {s}: {s} — wins {d}% of fights, loses the field {d}%; consider cautious ROE (Forces o) or recall", .{
                if (gs.force(c.assigned_company)) |f| try table.plain(alloc, f.name) else "—",
                c.planet_key,
                try offer_rating.skullText(alloc, rt),
                rt.win_pct,
                rt.lose_field_pct,
            }) });
        }
    }

    // Wounded waiting for a bed.
    {
        var n: u32 = 0;
        var pit = gs.people.iterator();
        while (pit.next()) |e| if (e.value_ptr.status == .wounded and !e.value_ptr.medbay_admitted) {
            n += 1;
        };
        if (n > 0 and !gs.auto_admit) try out.append(alloc, .{ .kind = .untreated_wounded, .text = try std.fmt.allocPrint(alloc, "{d} wounded await{s} medbay admission (they don't heal until admitted)", .{ n, if (n == 1) "s" else "" }) });
    }
    {
        const t = @import("../domain/tuning.zig").t.person;
        var restless: u32 = 0;
        var pit = gs.people.iterator();
        while (pit.next()) |e| {
            const p = e.value_ptr;
            if (p.status == .active and !gs.isCompanyDeployed(gs.companyOf(p.assigned_force)) and medical.turnoverRisk(p, day) > 0) restless += 1;
        }
        if (restless > 0) try out.append(alloc, .{ .kind = .restless_crew, .text = try std.fmt.allocPrint(alloc, "{d} restless (morale < {d} or fatigue > {d}, a year in) — they roll to quit on payday: rotate home, grant leave, feed and rest them", .{ restless, t.restless_morale, t.exhausted_fatigue }) });
    }

    // Spent pilots still in a seat.
    {
        var n: u32 = 0;
        var uit = gs.units.iterator();
        while (uit.next()) |e| {
            const u = e.value_ptr;
            if (u.isParked() or u.pilot == .none) continue;
            if (gs.person(u.pilot)) |p| if (p.status == .active and p.isUnfit()) {
                n += 1;
            };
        }
        if (n > 0) try out.append(alloc, .{ .kind = .unfit_crew, .text = try std.fmt.allocPrint(alloc, "{d} spent pilot{s} still seated (fatigue {d}+: +3 gunnery and piloting) — Forces A seats fresher crews, leave and rest bring them back", .{ n, if (n == 1) "" else "s", @import("../domain/tuning.zig").t.person.fatigue_spent }) });
    }

    // Decisions about to default.
    for (gs.event_queue.pending.items) |ev| {
        if (ev.needsDecision() and ev.deadline_day <= day + 2) {
            try out.append(alloc, .{ .kind = .decision_due, .text = try std.fmt.allocPrint(alloc, "decision '{s}' defaults on day {d} (today {d})", .{ @tagName(ev.kind), ev.deadline_day, day }) });
        }
    }

    // Open pilot/tech slots per company.
    var fit = gs.forces.iterator();
    while (fit.next()) |fentry| {
        const f = fentry.value_ptr;
        if (f.echelon != .company) continue;
        var no_pilot: u32 = 0;
        var no_tech: u32 = 0;
        var wait_pilot: u32 = 0;
        var wait_tech: u32 = 0;
        var back: ?u32 = null;
        var uit = gs.units.iterator();
        while (uit.next()) |uentry| {
            const u = uentry.value_ptr;
            if (gs.companyOf(u.force) != f.id or u.isParked()) continue;
            const pilot = gs.person(u.pilot);
            switch (if (pilot) |p| p.seatState(day) else .away) {
                .fit => {},
                .recovering => {
                    wait_pilot += 1;
                    if (pilot.?.backDay(day)) |d| back = @max(back orelse 0, d);
                },
                .away => no_pilot += 1,
            }
            if (unit_mod.techRoleFor(u.kind) != null) {
                const tech = gs.person(u.tech);
                switch (if (tech) |t| t.seatState(day) else .away) {
                    .fit => {},
                    .recovering => {
                        wait_tech += 1;
                        if (tech.?.backDay(day)) |d| back = @max(back orelse 0, d);
                    },
                    .away => no_tech += 1,
                }
            }
        }
        if (no_pilot + no_tech > 0) {
            try out.append(alloc, .{ .kind = .open_slots, .text = try std.fmt.allocPrint(alloc, "{s}: {d} hull(s) without a pilot, {d} without a tech (no repairs/reloads)", .{ try table.plain(alloc, f.name), no_pilot, no_tech }) });
        }
        if (wait_pilot + wait_tech > 0) {
            const until = if (back) |d| try std.fmt.allocPrint(alloc, " — all back by day {d}", .{d}) else "";
            try out.append(alloc, .{ .kind = .crew_recovering, .text = try std.fmt.allocPrint(alloc, "{s}: {d} hull(s) sit out while the pilot heals or rests, {d} wait on the tech{s} (Forces A seats a spare)", .{ try table.plain(alloc, f.name), wait_pilot, wait_tech, until }) });
        }
        // The rest of the manning table: who is short and by how much.
        {
            var text: std.ArrayListUnmanaged(u8) = .empty;
            var short_total: u32 = 0;
            for (@import("personnel.zig").manningLines(gs, f.id)) |m| {
                const open = m.open;
                if (open == 0) continue;
                if (m.role.fillsHullSeat()) continue; // the seat warning above covers hulls
                if (text.items.len > 0) try text.appendSlice(alloc, ", ");
                try text.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{d} {s}", .{ open, @tagName(m.role) }));
                short_total += open;
            }
            // A deployed company can't hire from the halls; people reach it by transfer.
            if (short_total > 0) try out.append(alloc, .{ .kind = .manning_short, .text = if (gs.isCompanyDeployed(f.id))
                try std.fmt.allocPrint(alloc, "{s} manning short: {s} (deployed — hire at an HQ hall, then :xfer person <id> co:{d}; they travel to the company)", .{ try table.plain(alloc, f.name), text.items, @intFromEnum(f.id) })
            else
                try std.fmt.allocPrint(alloc, "{s} manning short: {s} (Forces r → MANNING; :crew co:{d} hires from the halls)", .{ try table.plain(alloc, f.name), text.items, @intFromEnum(f.id) }) });
        }
        if (f.supply_shortage_days > 0) {
            try out.append(alloc, .{ .kind = .hungry, .text = try std.fmt.allocPrint(alloc, "{s} has been hungry {d} day(s) — send provisions or funds", .{ try table.plain(alloc, f.name), f.supply_shortage_days }) });
        }
        if (gs.isCompanyDeployed(f.id)) {
            // Only the families the company's working mounts actually fire.
            var dry: u32 = 0;
            var names: std.ArrayListUnmanaged(u8) = .empty;
            const fires = try @import("field_supply.zig").munitionMounts(alloc, gs, f.id, false);
            for (part_mod.munition_keys) |key| {
                if (!fires.contains(key)) continue;
                if (gs.stockCount(.{ .company = f.id }, key) > 0) continue;
                dry += 1;
                if (names.items.len > 0) try names.appendSlice(alloc, ", ");
                try names.appendSlice(alloc, key);
            }
            if (dry > 0) try out.append(alloc, .{ .kind = .dry_ammo, .text = try std.fmt.allocPrint(alloc, "{s}: {s} at zero in the field stores — those mounts fall silent", .{ try table.plain(alloc, f.name), names.items }) });
            if (f.local_funds < 0) try out.append(alloc, .{ .kind = .overdrawn, .text = try std.fmt.allocPrint(alloc, "{s} operating funds overdrawn ({d})", .{ try table.plain(alloc, f.name), f.local_funds }) });
        }
    }

    // Contract control.
    var cit = gs.contracts.iterator();
    while (cit.next()) |centry| {
        const c = centry.value_ptr;
        if (c.status != .active) continue;
        if (c.ineffective_since) |since| {
            const left = (since + @import("contract_control.zig").grace_days) -| day;
            try out.append(alloc, .{ .kind = .combat_ineffective, .text = try std.fmt.allocPrint(alloc, "{s}: COMBAT-INEFFECTIVE — {d} day(s) to buy local replacements or the employer declares breach", .{ c.kind.label(), left }) });
        }
        if (c.objectivesMet()) {
            try out.append(alloc, .{ .kind = .objectives_met, .text = try std.fmt.allocPrint(alloc, "{s}: objectives substantially met ({d}% of opposition destroyed) — `complete {d}` to close out", .{ c.kind.label(), c.poolDestroyedPct(), @intFromEnum(c.id) }) });
        }
    }
    var idle_it = gs.forces.iterator();
    while (idle_it.next()) |fentry| {
        const f = fentry.value_ptr;
        if (f.echelon != .company or gs.companyPosture(f.id) != .idle_afield) continue;
        try out.append(alloc, .{ .kind = .company_idle_afield, .text = try std.fmt.allocPrint(alloc, "{s} is idling on {s} eating its trucks — accept work from the field or `recall co:{d}`", .{ try table.plain(alloc, f.name), f.location_planet.?, @intFromEnum(f.id) }) });
    }

    // HQ staffing, treasuries, bays.
    var hit = gs.hqs.iterator();
    while (hit.next()) |hentry| {
        const hq = hentry.value_ptr;
        const req = hq.staffRequired().total();
        // Only a shortfall that costs a level is worth a warning.
        const steps = hq.understaffingSteps();
        if (steps > 0) {
            // Which desks are short, and who walked lately.
            var short: std.ArrayListUnmanaged(u8) = .empty;
            for (hq.staffRequired().desks()) |d| {
                const have = gs.hqStaff(hq.id, d.role).count;
                if (have >= d.need) continue;
                if (short.items.len > 0) try short.appendSlice(alloc, ", ");
                try short.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{d} {s}", .{ d.need - have, d.name }));
            }
            // Who walked from this HQ's desks in the last quarter: the
            // departed keep their posting on the record (personnel.depart).
            var left: u32 = 0;
            var last_name: []const u8 = "";
            var last_day: u32 = 0;
            var lit = gs.people.iterator();
            while (lit.next()) |le| {
                const lp = le.value_ptr;
                const gone_day = lp.departed_day orelse continue;
                if (lp.posted_hq != hq.id or gone_day + 90 < day) continue;
                if (lp.status != .retired and lp.status != .resigned) continue;
                left += 1;
                if (gone_day >= last_day) {
                    last_day = gone_day;
                    last_name = try table.plain(alloc, try lp.fullName(alloc));
                }
            }
            try out.append(alloc, .{ .kind = .understaffed_hq, .text = try std.fmt.allocPrint(alloc, "{s} understaffed {d}/{d} (short {s}) — facilities run {d} level{s} low{s} · HQ screen: S autostaff from the pool, h hire at the hall; answer notice decisions in the inbox before they expire", .{
                try table.plain(alloc, hq.name), hq.staff_assigned,           req, if (short.items.len > 0) short.items else "none by desk: posted staff hold the wrong roles",
                steps,                           if (steps == 1) "" else "s",
                if (left > 0) try std.fmt.allocPrint(alloc, " · {d} left in the last quarter (last: {s})", .{ left, last_name }) else "",
            }) });
        }
        if (hq.funds < 0) {
            try out.append(alloc, .{ .kind = .overdrawn, .text = try std.fmt.allocPrint(alloc, "{s} treasury overdrawn ({d})", .{ try table.plain(alloc, hq.name), hq.funds }) });
        }
        const idle = hq_ops.baySlots(gs, hq.id) -| hq_ops.activeJobs(gs, hq.id);
        var waiting: u32 = 0;
        var uit = gs.units.iterator();
        while (uit.next()) |uentry| {
            const u = uentry.value_ptr;
            // Only hulls that are actually home count: a deployed, idle-afield
            // or returning company cannot use the bay, so its structural damage
            // is not a backlog yet (it shows in the Lab instead).
            // Cold storage and the unassigned pool are parked on purpose:
            // their damage is the player's to schedule, not a backlog.
            if (u.status == .mothballed or u.force == .none) continue;
            if (gs.homeHqFor(u.force) != hq.id) continue; // this HQ's bay, its hulls
            if (u.needsDepot() and u.status != .repairing and gs.isCompanyHome(gs.companyOf(u.force)) and !hq_ops.hasJobForUnit(gs, u.id)) waiting += 1;
        }
        // Hulls this HQ's bay could not rebuild, per company based here.
        var rit = gs.forces.iterator();
        while (rit.next()) |ce| {
            const co = ce.value_ptr;
            if (co.echelon != .company or gs.homeHqFor(co.id) != hq.id) continue;
            var heavy: u32 = 0;
            var assault: u32 = 0;
            var rut = gs.units.iterator();
            while (rut.next()) |he| {
                const hu = he.value_ptr;
                if (hu.kind != .mek or gs.companyOf(hu.force) != co.id) continue;
                if (hq_ops.bayCanRebuild(gs, hq.id, hu.chassis_key)) continue;
                const class = (@import("../domain/chassis.zig").find(hu.chassis_key) orelse continue).weightClass();
                if (class == .assault) assault += 1 else heavy += 1;
            }
            if (heavy + assault > 0) try out.append(alloc, .{ .kind = .unrebuildable_hulls, .text = try std.fmt.allocPrint(alloc, "{s} fields {d} heavy and {d} assault hull(s) {s} (bay {d}) cannot rebuild structure for — heavy needs bay 2, assault bay 3 at a regional HQ", .{
                try table.plain(alloc, co.name), heavy, assault, try table.plain(alloc, hq.name), hq.effectiveFacilityLevel(.mek_bay),
            }) });
        }
        if (waiting > 0 and idle > 0) {
            try out.append(alloc, .{ .kind = .depot_backlog, .text = try std.fmt.allocPrint(alloc, "{d} hull(s) need depot work and {d} bay slot(s) sit idle — components or techs missing (see `demand`, `roster`)", .{ waiting, idle }) });
        }
    }

    // Retirements coming: the age line is a hard stop at the
    // monthly turnover, so say who reaches it within the quarter.
    {
        const tp = @import("../domain/tuning.zig").t.person;
        var n: u32 = 0;
        var first: []const u8 = "";
        var pit2 = gs.people.iterator();
        while (pit2.next()) |e| {
            const p = e.value_ptr;
            if (p.status != .active) continue;
            const age = p.ageYears(day + 90) orelse continue;
            if (age < tp.age_retire) continue;
            n += 1;
            if (first.len == 0) first = try std.fmt.allocPrint(alloc, "{s} ({s}{s})", .{ try table.plain(alloc, try p.fullName(alloc)), @tagName(p.role), if (p.posted_hq != .none) try std.fmt.allocPrint(alloc, ", {s}", .{if (gs.hqs.getPtr(p.posted_hq)) |h| h.name else "HQ"}) else "" });
        }
        if (n > 0) try out.append(alloc, .{ .kind = .retiring_soon, .text = try std.fmt.allocPrint(alloc, "{d} reach{s} retirement age ({d}) within the quarter — {s}{s}; hire the replacement now (halls churn daily)", .{ n, if (n == 1) "es" else "", tp.age_retire, first, if (n > 1) try std.fmt.allocPrint(alloc, " and {d} more", .{n - 1}) else "" }) });
    }

    // Medbay over capacity at home.
    var wounded_home: u32 = 0;
    var pit = gs.people.iterator();
    while (pit.next()) |pentry| {
        const p = pentry.value_ptr;
        if (p.status == .wounded and gs.isCompanyHome(gs.companyOf(p.assigned_force))) wounded_home += 1;
    }
    const beds = medical.bedCapacity(gs, .none, false);
    if (wounded_home > beds) {
        try out.append(alloc, .{ .kind = .medbay_over_capacity, .text = try std.fmt.allocPrint(alloc, "medbay over capacity: {d} wounded for {d} beds — triage priorities decide who heals", .{ wounded_home, beds }) });
    }

    // Techs carrying more hulls than their hours allow.
    var overloaded: u32 = 0;
    var tit = gs.people.iterator();
    while (tit.next()) |tentry| {
        const t = tentry.value_ptr;
        if (!t.isAvailable(day)) continue;
        if (!t.role.isTech()) continue;
        if (gs.techLoadHours(t.id) > gs.techHoursAvailable(t)) overloaded += 1;
    }
    if (overloaded > 0) {
        try out.append(alloc, .{ .kind = .tech_overloaded, .text = try std.fmt.allocPrint(alloc, "{d} tech(s) assigned more hulls than their weekly hours cover — some hulls roll uncovered", .{overloaded}) });
    }

    return out.toOwnedSlice(alloc);
}

test "the checklist names open slots and overloaded techs" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 61 });
    defer gs.deinit();
    const co = try gs.createForce("Alpha", .company, .none);
    const uid = try gs.addUnit("AS7-D");
    try gs.assignUnit(uid, co, .none); // no pilot, no tech

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const warnings = try turnWarnings(&gs, arena.allocator());
    var saw_open = false;
    for (warnings) |w| {
        if (w.kind == .open_slots) saw_open = true;
    }
    try std.testing.expect(saw_open);
}

test "a wounded pilot keeps the seat: a Desk note the end-turn prompt skips, not an open seat" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 63 });
    defer gs.deinit();
    const co = try gs.createForce("Alpha", .company, .none);
    const uid = try gs.addUnit("AS7-D");
    try gs.assignUnit(uid, co, .none);
    const pid = try gs.hirePerson("Hurt", "Pilot", .mekwarrior);
    gs.person(pid).?.assigned_force = co;
    try gs.assignSlot(uid, .pilot, pid);
    const tid = try gs.hirePerson("Fit", "Tech", .tech_mek);
    gs.person(tid).?.assigned_force = co;
    try gs.assignSlot(uid, .tech, tid);
    const p = gs.person(pid).?;
    p.status = .wounded;
    p.wound_heal_day = gs.clock.day_index + 12;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recovering: ?Warning = null;
    for (try turnWarnings(&gs, arena.allocator())) |w| {
        try std.testing.expect(w.kind != .open_slots);
        if (w.kind == .crew_recovering) recovering = w;
    }
    const w = recovering orelse return error.TestExpectedEqual;
    try std.testing.expect(!w.kind.prompts());
    try std.testing.expect(std.mem.indexOf(u8, w.text, try std.fmt.allocPrint(arena.allocator(), "day {d}", .{gs.clock.day_index + 12})) != null);

    // Missing in action leaves the seat open: that one the prompt asks about.
    p.status = .mia;
    var open = false;
    for (try turnWarnings(&gs, arena.allocator())) |x| if (x.kind == .open_slots) {
        open = x.kind.prompts();
    };
    try std.testing.expect(open);
}

test "a spent pilot in a seat is a checklist warning" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 62 });
    defer gs.deinit();
    const co = try gs.createForce("Alpha", .company, .none);
    const uid = try gs.addUnit("AS7-D");
    try gs.assignUnit(uid, co, .none);
    const pid = try gs.hirePerson("Worn", "Out", .mekwarrior);
    gs.person(pid).?.assigned_force = co;
    try gs.assignSlot(uid, .pilot, pid);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (try turnWarnings(&gs, arena.allocator())) |w| try std.testing.expect(w.kind != .unfit_crew);
    gs.person(pid).?.fatigue = 100;
    var saw = false;
    for (try turnWarnings(&gs, arena.allocator())) |w| if (w.kind == .unfit_crew) {
        saw = true;
    };
    try std.testing.expect(saw);
}

test "dry-ammo warning names only the families the company fires" {
    const commands = @import("commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 2025 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "E", .origin = .CC, .profession = .paymaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    _ = try commands.execute(&gs, .{ .accept_contract = .{ .offer_index = 0, .company = co } });
    const site: types.Site = .{ .company = co };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Find a family the company fires and one it does not.
    var fired: ?[]const u8 = null;
    var unused: ?[]const u8 = null;
    for (part_mod.munition_keys) |key| {
        if (companyFires(&gs, co, key)) {
            if (fired == null) fired = key;
        } else if (unused == null) unused = key;
    }
    try std.testing.expect(fired != null and unused != null);
    // Empty the unused family: no warning.
    _ = gs.takeStock(site, unused.?, gs.stockCount(site, unused.?));
    var dry_warnings: u32 = 0;
    for (try turnWarnings(&gs, a)) |w| if (w.kind == .dry_ammo) {
        dry_warnings += 1;
    };
    try std.testing.expectEqual(@as(u32, 0), dry_warnings);
    // Empty a fired family: one warning that names it.
    _ = gs.takeStock(site, fired.?, gs.stockCount(site, fired.?));
    var named = false;
    for (try turnWarnings(&gs, a)) |w| if (w.kind == .dry_ammo) {
        dry_warnings += 1;
        if (std.mem.indexOf(u8, w.text, fired.?) != null) named = true;
    };
    try std.testing.expectEqual(@as(u32, 1), dry_warnings);
    try std.testing.expect(named);
}

test "a staffing shortfall that costs no level raises no warning; one that does names the levels" {
    const commands = @import("commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 94 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const hq = gs.hqs.getPtr(gs.hqs.keys()[0]).?;
    const req = hq.staffRequired().total();
    try std.testing.expect(req >= 4);

    hq.staff_assigned = req - 1; // under 25% short: no level lost
    try std.testing.expectEqual(@as(u8, 0), hq.understaffingSteps());
    for (try turnWarnings(&gs, al)) |w| try std.testing.expect(w.kind != .understaffed_hq);

    hq.staff_assigned = req / 2; // half short: two levels
    try std.testing.expectEqual(@as(u8, 2), hq.understaffingSteps());
    var saw = false;
    for (try turnWarnings(&gs, al)) |w| if (w.kind == .understaffed_hq) {
        saw = std.mem.indexOf(u8, w.text, "run 2 levels low") != null;
    };
    try std.testing.expect(saw);
}

test "the understaffed warning names the short desks, and retirements are announced a quarter out" {
    const commands = @import("commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 93 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const hq = gs.hqs.values()[0];
    // Strip every finance admin: the warning must say "finance".
    var pit = gs.people.iterator();
    while (pit.next()) |e| if (e.value_ptr.posted_hq == hq.id and e.value_ptr.role == .admin_finance) {
        e.value_ptr.status = .resigned;
    };
    gs.refreshHqStaffing();
    var saw_short = false;
    for (try turnWarnings(&gs, al)) |w| if (w.kind == .understaffed_hq) {
        try std.testing.expect(std.mem.indexOf(u8, w.text, "finance") != null);
        try std.testing.expect(std.mem.indexOf(u8, w.text, "S autostaff") != null);
        saw_short = true;
    };
    try std.testing.expect(saw_short);
    // Someone two months short of the line: announced.
    const tp = @import("../domain/tuning.zig").t.person;
    const someone = gs.people.values()[0].id;
    gs.person(someone).?.born_day = @as(i32, @intCast(gs.clock.day_index)) - @as(i32, @intCast(tp.age_retire)) * 365 + 60;
    var saw_retire = false;
    for (try turnWarnings(&gs, al)) |w| if (w.kind == .retiring_soon) {
        try std.testing.expect(std.mem.indexOf(u8, w.text, "retirement age") != null);
        saw_retire = true;
    };
    try std.testing.expect(saw_retire);
}

test "a company with hulls its home bay cannot rebuild is flagged" {
    const commands = @import("commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1222 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (try turnWarnings(&gs, arena.allocator())) |w| try std.testing.expect(w.kind != .unrebuildable_hulls); // lights and mediums
    const lance = gs.force(co).?.children.items[0];
    const big = try gs.addUnit("AS7-D");
    try gs.moveUnitToForce(big, lance);
    var found = false;
    for (try turnWarnings(&gs, arena.allocator())) |w| if (w.kind == .unrebuildable_hulls) {
        found = true;
    };
    try std.testing.expect(found);
    try std.testing.expect(!hq_ops.bayCanRebuild(&gs, gs.hqs.keys()[0], "AS7-D"));
    try std.testing.expect(hq_ops.bayCanRebuild(&gs, gs.hqs.keys()[0], "SHD-2H"));
}

/// A company on an active raid contract with ammunition in its stores.
fn contactFixture(gs: *GameState) !*@import("../domain/contract.zig").Contract {
    _ = try gs.createCommander("T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000 },
        .status = .active,
        .assigned_company = co,
        .committed_bv = @import("contract_control.zig").fieldableBv(gs, co),
        .enemy_lances = 2,
        .enemy_lance_bv = 3_000,
    });
    for (part_mod.munition_keys) |key| try gs.addStock(gs.siteForForce(co), key, 20);
    return gs.contracts.getPtr(@enumFromInt(1)).?;
}

test "an engagement inside the window warns with odds, strength, ammunition and the levers" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1208 });
    defer gs.deinit();
    const c = try contactFixture(&gs);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    c.next_battle_day = gs.clock.day_index + @import("../domain/tuning.zig").t.battle.contact_warning_days + 1;
    for (try turnWarnings(&gs, a)) |w| try std.testing.expect(w.kind != .contact_imminent);

    c.next_battle_day = gs.clock.day_index + 2;
    var found: ?[]const u8 = null;
    for (try turnWarnings(&gs, a)) |w| {
        try std.testing.expect(w.kind != .outmatched); // the contact warning carries the rating
        if (w.kind == .contact_imminent) found = w.text;
    }
    const text = found orelse return error.NoContactWarning;
    try std.testing.expect(!WarningKind.contact_imminent.urgent());
    for ([_][]const u8{ "contact on Galatea in 2 days", "skull", "fieldable", "100% of committed", "ammo ", "ROE standard", "give battle orders" }) |want| {
        if (std.mem.indexOf(u8, text, want) == null) {
            std.debug.print("missing \"{s}\" in: {s}\n", .{ want, text });
            return error.TestUnexpectedResult;
        }
    }
    // Integrated command holds the ROE, and the warning says so.
    c.terms.command_rights = .integrated;
    const held = try contactText(a, &gs, c);
    try std.testing.expect(std.mem.indexOf(u8, held, "held by the employer") != null);
}

test "a multi-day advance stops once when contact comes into view, and the next goes on" {
    const commands = @import("commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1209 });
    defer gs.deinit();
    const c = try contactFixture(&gs);
    const window = @import("../domain/tuning.zig").t.battle.contact_warning_days;
    c.next_battle_day = gs.clock.day_index + window + 2;

    const first = try commands.execute(&gs, .{ .advance_days = 7 });
    try std.testing.expectEqual(@as(u32, 2), first.days_advanced);
    try std.testing.expectEqual(c.id, first.contact);

    // Not refused, and not stopped again before the fight.
    const second = try commands.execute(&gs, .{ .advance_days = 1 });
    try std.testing.expectEqual(@as(u32, 1), second.days_advanced);
    try std.testing.expectEqual(types.ContractId.none, second.contact);
}

test "confirming battle orders clears the contact warning until the next engagement" {
    const commands = @import("commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1211 });
    defer gs.deinit();
    const c = try contactFixture(&gs);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Count = struct {
        fn contact(al: std.mem.Allocator, g: *GameState) !u32 {
            var n: u32 = 0;
            for (try turnWarnings(g, al)) |w| n += @intFromBool(w.kind == .contact_imminent);
            return n;
        }
    };
    // Out of the window there is nothing to give orders for.
    c.next_battle_day = gs.clock.day_index + 20;
    try std.testing.expectError(commands.Error.NoContact, commands.execute(&gs, .{ .confirm_orders = c.id }));

    c.next_battle_day = gs.clock.day_index + 2;
    try std.testing.expectEqual(@as(u32, 1), try Count.contact(a, &gs));
    for (try turnWarnings(&gs, a)) |w| if (w.kind == .contact_imminent) try std.testing.expectEqual(c.id, w.contract);
    _ = try commands.execute(&gs, .{ .confirm_orders = c.id });
    try std.testing.expectEqual(@as(u32, 0), try Count.contact(a, &gs));
    // A new engagement asks for new orders.
    c.next_battle_day = gs.clock.day_index + 3;
    try std.testing.expectEqual(@as(u32, 1), try Count.contact(a, &gs));
}

test "emergency resupply buys what the quote says, and refuses before money moves" {
    const commands = @import("commands.zig");
    const field_supply = @import("field_supply.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1212 });
    defer gs.deinit();
    const c = try contactFixture(&gs);
    const co = c.assigned_company;
    const site = gs.siteForForce(co);
    c.next_battle_day = gs.clock.day_index + 2;
    // Stores already cover the fight: nothing to buy.
    try std.testing.expectError(commands.Error.NothingToRush, commands.execute(&gs, .{ .emergency_resupply = c.id }));
    // Carry two tons of each munition (room on the trucks), run the LRM
    // racks dry, and dent two hulls.
    for (part_mod.munition_keys) |key| {
        _ = gs.takeStock(site, key, gs.stockCount(site, key));
        if (!std.mem.eql(u8, key, "ammo_lrm")) try gs.addStock(site, key, 2);
    }
    var dented: u32 = 0;
    var it = gs.units.iterator();
    while (it.next()) |e| if (dented < 2 and gs.companyOf(e.value_ptr.force) == co and e.value_ptr.kind == .mek) {
        e.value_ptr.armor_pct = 50;
        dented += 1;
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const quote = try field_supply.rushQuote(arena.allocator(), &gs, c);
    try std.testing.expect(quote.lines.len > 0);
    // Without the local funds, nothing moves.
    gs.force(co).?.local_funds = quote.price - 1;
    const lrm_before = gs.stockCount(site, "ammo_lrm");
    try std.testing.expectError(commands.Error.CompanyFundsShort, commands.execute(&gs, .{ .emergency_resupply = c.id }));
    try std.testing.expectEqual(lrm_before, gs.stockCount(site, "ammo_lrm"));
    // With them, the stores gain exactly the quoted lines and the funds pay the quoted price.
    gs.force(co).?.local_funds = quote.price + 1_000;
    var before: [8]u32 = undefined;
    for (quote.lines, 0..) |l, i| before[i] = gs.stockCount(site, l.key);
    _ = try commands.execute(&gs, .{ .emergency_resupply = c.id });
    for (quote.lines, 0..) |l, i| try std.testing.expectEqual(before[i] + l.qty, gs.stockCount(site, l.key));
    try std.testing.expectEqual(@as(types.CBills, 1_000), gs.force(co).?.local_funds);
}
