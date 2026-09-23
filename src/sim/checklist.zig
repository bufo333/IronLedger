//! The end-turn checklist (Stage 9C.2, ARCH §9.9): everything the player
//! should know before time moves. A pure query over GameState — the CLI
//! refuses to advance until it's acknowledged; the TUI renders it as a
//! modal. Nothing slips past a turn boundary unannounced.

const std = @import("std");
const person_mod = @import("../domain/person.zig");
const types = @import("../domain/types.zig");
const unit_mod = @import("../domain/unit.zig");
const part_mod = @import("../domain/part.zig");
const hq_ops = @import("hq_ops.zig");
const medical = @import("medical.zig");
const GameState = @import("state.zig").GameState;

pub const WarningKind = enum {
    decision_due,
    open_slots,
    understaffed_hq,
    /// Someone reaches retirement age within the quarter (play feedback:
    /// HQs lost admins "without my knowledge").
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
    /// People with a year in and morale or fatigue past the line: they
    /// roll to leave on payday (Stage 12.20).
    restless_crew,
    /// A company's manning table has open seats beyond pilots and techs
    /// (astechs, doctors, medics, office) — quietly slowing repairs and
    /// healing (12B.11).
    manning_short,
    /// Seated pilots in the spent fatigue band (12C.1): +3 to gunnery and
    /// piloting until they rest; the auto-assigner benches them when it can.
    unfit_crew,
    /// A company fields hulls whose structure its home HQ's bay is not
    /// rated to rebuild (12E.2): heavy assemblies need bay 2, assault bay 3
    /// at a regional HQ.
    unrebuildable_hulls,
    /// An active contract rates 4½ skulls or worse for the company on it
    /// today (12E.5): consider cautious ROE or recall.
    outmatched,
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
};

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

    // Send the company away: the same damage is no longer a backlog.
    gs.forces.getPtr(res.created_force).?.location_planet = "galatea";
    const away = try turnWarnings(&gs, arena.allocator());
    for (away) |w| try std.testing.expect(w.kind != .depot_backlog);
}

/// Build the checklist. `alloc` owns the returned slice and texts.
pub fn turnWarnings(gs: *GameState, alloc: std.mem.Allocator) ![]Warning {
    var out: std.ArrayListUnmanaged(Warning) = .empty;
    const day = gs.clock.day_index;

    // Money first: nothing else matters if the outfit cannot pay.
    if (gs.funds + gs.inboundToOutfit() < 0) {
        const folds = gs.isInsolvent();
        try out.append(alloc, .{ .kind = .insolvent, .text = try std.fmt.allocPrint(alloc, "outfit treasury overdrawn ({d}{s}) — take a loan (credit {d}), transfer funds back from an HQ or company, or sell assets (worth {d}){s}", .{
            gs.funds, if (gs.inboundToOutfit() > 0) try std.fmt.allocPrint(alloc, ", {d} on the road", .{gs.inboundToOutfit()}) else "", gs.creditRemaining(), gs.liquidationValue(), if (folds) "; nothing left covers it: the outfit folds" else "",
        }) });
    }

    // Outmatched on an active contract (12E.5): the company's skulls today.
    {
        const offer_rating = @import("offer_rating.zig");
        const warn = @import("../domain/skulls.zig").table.warn_half_skulls;
        var cit = gs.contracts.iterator();
        while (cit.next()) |ce| {
            const c = ce.value_ptr;
            if (c.status != .active) continue;
            const rt = (try offer_rating.rateOffer(alloc, gs, c, c.assigned_company)) orelse continue;
            if (rt.half_hi < warn) continue;
            try out.append(alloc, .{ .kind = .outmatched, .text = try std.fmt.allocPrint(alloc, "{s} is outmatched on {s}: {s} — wins {d}% of fights, loses the field {d}%; consider cautious ROE (Forces o) or recall", .{
                if (gs.force(c.assigned_company)) |f| f.name else "—", c.planet_key, try offer_rating.skullText(alloc, rt), rt.win_pct, rt.lose_field_pct,
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

    // Spent pilots still in a seat (12C.1).
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
        var uit = gs.units.iterator();
        while (uit.next()) |uentry| {
            const u = uentry.value_ptr;
            if (gs.companyOf(u.force) != f.id or u.isParked()) continue;
            const pilot_ok = if (gs.person(u.pilot)) |p| p.isAvailable(day) else false;
            if (!pilot_ok) no_pilot += 1;
            if (unit_mod.techRoleFor(u.kind) != null) {
                const tech_ok = if (gs.person(u.tech)) |t| t.isAvailable(day) else false;
                if (!tech_ok) no_tech += 1;
            }
        }
        if (no_pilot + no_tech > 0) {
            try out.append(alloc, .{ .kind = .open_slots, .text = try std.fmt.allocPrint(alloc, "{s}: {d} hull(s) without a pilot, {d} without a tech (no repairs/reloads)", .{ f.name, no_pilot, no_tech }) });
        }
        // The rest of the manning table (12B.11): who is short and by how much.
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
                try std.fmt.allocPrint(alloc, "{s} manning short: {s} (deployed — hire at an HQ hall, then :xfer person <id> co:{d}; they travel to the company)", .{ f.name, text.items, @intFromEnum(f.id) })
            else
                try std.fmt.allocPrint(alloc, "{s} manning short: {s} (Forces r → MANNING; :crew co:{d} hires from the halls)", .{ f.name, text.items, @intFromEnum(f.id) }) });
        }
        if (f.supply_shortage_days > 0) {
            try out.append(alloc, .{ .kind = .hungry, .text = try std.fmt.allocPrint(alloc, "{s} has been hungry {d} day(s) — send provisions or funds", .{ f.name, f.supply_shortage_days }) });
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
            if (dry > 0) try out.append(alloc, .{ .kind = .dry_ammo, .text = try std.fmt.allocPrint(alloc, "{s}: {s} at zero in the field stores — those mounts fall silent", .{ f.name, names.items }) });
            if (f.local_funds < 0) try out.append(alloc, .{ .kind = .overdrawn, .text = try std.fmt.allocPrint(alloc, "{s} operating funds overdrawn ({d})", .{ f.name, f.local_funds }) });
        }
    }

    // Contract control (Stage 9E).
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
        try out.append(alloc, .{ .kind = .company_idle_afield, .text = try std.fmt.allocPrint(alloc, "{s} is idling on {s} eating its trucks — accept work from the field or `recall co:{d}`", .{ f.name, f.location_planet.?, @intFromEnum(f.id) }) });
    }

    // HQ staffing, treasuries, bays.
    var hit = gs.hqs.iterator();
    while (hit.next()) |hentry| {
        const hq = hentry.value_ptr;
        const req = hq.staffRequired().total();
        if (hq.staff_assigned < req) {
            // Which desks are short, and who walked lately (play feedback: the
            // bare count said nothing about why or what to do).
            var short: std.ArrayListUnmanaged(u8) = .empty;
            for (hq.staffRequired().desks()) |d| {
                const have = gs.hqStaff(hq.id, d.role).count;
                if (have >= d.need) continue;
                if (short.items.len > 0) try short.appendSlice(alloc, ", ");
                try short.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{d} {s}", .{ d.need - have, d.name }));
            }
            var left: u32 = 0;
            var last_name: []const u8 = "";
            for (gs.event_log.items) |e| {
                if (e.hq != hq.id or e.day + 90 < day or std.mem.indexOf(u8, e.text, "[turnover]") == null) continue;
                if (std.mem.indexOf(u8, e.text, " retires") == null and std.mem.indexOf(u8, e.text, " resigns") == null) continue;
                left += 1;
                const start = (std.mem.indexOf(u8, e.text, "[turnover] ") orelse continue) + 11;
                const stop = std.mem.indexOfPos(u8, e.text, start, " (") orelse e.text.len;
                last_name = e.text[start..stop];
            }
            try out.append(alloc, .{ .kind = .understaffed_hq, .text = try std.fmt.allocPrint(alloc, "{s} understaffed {d}/{d} (short {s}) — facilities run a level low{s} · HQ screen: S autostaff from the pool, h hire at the hall; answer notice decisions in the inbox before they expire", .{
                hq.name, hq.staff_assigned, req, if (short.items.len > 0) short.items else "none by desk: posted staff hold the wrong roles",
                if (left > 0) try std.fmt.allocPrint(alloc, " · {d} left in the last quarter (last: {s})", .{ left, last_name }) else "",
            }) });
        }
        if (hq.funds < 0) {
            try out.append(alloc, .{ .kind = .overdrawn, .text = try std.fmt.allocPrint(alloc, "{s} treasury overdrawn ({d})", .{ hq.name, hq.funds }) });
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
        // Hulls this HQ's bay could not rebuild (12E.2), per company based here.
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
                co.name, heavy, assault, hq.name, hq.effectiveFacilityLevel(.mek_bay),
            }) });
        }
        if (waiting > 0 and idle > 0) {
            try out.append(alloc, .{ .kind = .depot_backlog, .text = try std.fmt.allocPrint(alloc, "{d} hull(s) need depot work and {d} bay slot(s) sit idle — components or techs missing (see `demand`, `roster`)", .{ waiting, idle }) });
        }
    }

    // Retirements coming (play feedback): the age line is a hard stop at the
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
            if (first.len == 0) first = try std.fmt.allocPrint(alloc, "{s} {s} ({s}{s})", .{ p.first_name, p.last_name, @tagName(p.role), if (p.posted_hq != .none) try std.fmt.allocPrint(alloc, ", {s}", .{if (gs.hqs.getPtr(p.posted_hq)) |h| h.name else "HQ"}) else "" });
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

test "12C.1: a spent pilot in a seat is a checklist warning" {
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

test "play feedback: the understaffed warning names the short desks, and retirements are announced a quarter out" {
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

test "12E.2: a company with hulls its home bay cannot rebuild is flagged" {
    const commands = @import("commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1222 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (try turnWarnings(&gs, arena.allocator())) |w| try std.testing.expect(w.kind != .unrebuildable_hulls); // lights and mediums (12E.1)
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
