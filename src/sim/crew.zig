//! Who may take a hull's pilot or tech seat, and filling those seats
//! (Stage 9C.2, `docs/mekhq-map.md`).
//!
//! MekHQ counterpart: none — MekHQ has no unassigned-pool seat model;
//! see `docs/mekhq-map.md`.

const std = @import("std");
const types = @import("../domain/types.zig");
const person_mod = @import("../domain/person.zig");
const unit_mod = @import("../domain/unit.zig");
const GameState = @import("state.zig").GameState;

/// `any`: whichever seat the person's role fits — pilot roles
/// take the crew seat, tech roles the tech slot.
pub const Slot = enum { pilot, tech, any };

/// Nobody's pilot, nobody's tech, not posted to an HQ, not on a
/// company's books: what the assignment column calls "unassigned".
pub fn isUnassigned(gs: *GameState, p: *const person_mod.Person) bool {
    if (p.posted_hq != .none or p.assigned_force != .none) return false;
    if (gs.pilotSeat(p.id) != .none) return false;
    var uit = gs.units.iterator();
    while (uit.next()) |e| if (e.value_ptr.tech == p.id) return false;
    return true;
}

/// Why a person cannot take a seat or tech slot on a hull today, or
/// null: the one answer `assignSlot` refuses with and the picker dims with.
pub fn assignBlock(gs: *GameState, u: *const unit_mod.Unit, p: *const person_mod.Person) ?[]const u8 {
    if (!p.isAvailable(gs.clock.day_index)) return if (p.status == .wounded) "wounded" else "unavailable";
    if (u.force == .none and !canReachPool(gs, p)) return "away with their company";
    return null;
}

/// Can this person work a hull in the unassigned pool? The
/// pool sits at the outfit's seat; their company must be home there
/// (or they belong to no company at all).
pub fn canReachPool(gs: *GameState, p: *const person_mod.Person) bool {
    const company = gs.companyOf(p.assigned_force);
    if (company == .none) return true;
    if (!gs.isCompanyHome(company)) return false;
    const seat: types.HqId = if (gs.hqs.count() > 0) gs.hqs.keys()[0] else .none;
    return gs.homeHqFor(company) == seat;
}

pub const AssignSlotError = error{ UnknownUnit, UnknownPerson, WrongRole, Unavailable, NoTechSlot, PersonAway };

/// Put a person in a hull's pilot or tech slot. A pilot leaves any
/// previous hull; a tech may cover several hulls (hours permitting —
/// the maintenance pass enforces the budget, not this).
pub fn assignSlot(gs: *GameState, unit_id: types.UnitId, slot: Slot, person_id: types.PersonId) AssignSlotError!void {
    const u = gs.unit(unit_id) orelse return error.UnknownUnit;
    const p = gs.person(person_id) orelse return error.UnknownPerson;
    if (assignBlock(gs, u, p)) |why| return if (std.mem.eql(u8, why, "away with their company")) error.PersonAway else error.Unavailable;
    const resolved: Slot = if (slot != .any) slot else if (p.role == unit_mod.crewRoleFor(u.kind)) .pilot else if (unit_mod.techRoleFor(u.kind) == p.role) .tech else return error.WrongRole;
    switch (resolved) {
        .any => unreachable,
        .pilot => {
            if (p.role != unit_mod.crewRoleFor(u.kind)) return error.WrongRole;
            // One seat per pilot.
            var it = gs.units.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.pilot == person_id) entry.value_ptr.pilot = .none;
            }
            u.pilot = person_id;
            p.assigned_force = u.force;
        },
        .tech => {
            const need = unit_mod.techRoleFor(u.kind) orelse return error.NoTechSlot;
            if (p.role != need) return error.WrongRole;
            u.tech = person_id;
            if (p.assigned_force == .none) p.assigned_force = gs.companyOf(u.force);
        },
    }
}

pub fn unassignSlot(gs: *GameState, unit_id: types.UnitId, slot: Slot) error{UnknownUnit}!void {
    const u = gs.unit(unit_id) orelse return error.UnknownUnit;
    switch (slot) {
        .pilot => u.pilot = .none,
        .tech => u.tech = .none,
        .any => {
            u.pilot = .none;
            u.tech = .none;
        },
    }
}

/// Fill every open pilot/tech slot in a company from its own people
/// (and the unassigned pool). Returns how many slots remain open.
pub fn autoAssign(gs: *GameState, company: types.ForceId) !u32 {
    var open: u32 = 0;
    var uit = gs.units.iterator();
    while (uit.next()) |entry| {
        const u = entry.value_ptr;
        if (gs.companyOf(u.force) != company or u.isParked()) continue;

        // A seat needs filling when empty or its pilot is away; a spent
        // pilot is benched only when someone fresher is free.
        const seated = if (u.pilot != .none) gs.person(u.pilot) else null;
        const pilot_missing = seated == null or !seated.?.isAvailable(gs.clock.day_index);
        const pilot_spent = seated != null and seated.?.isUnfit();
        if (pilot_missing or pilot_spent) {
            const role = unit_mod.crewRoleFor(u.kind);
            var pit = gs.people.iterator();
            var found = false;
            while (pit.next()) |pe| {
                const p = pe.value_ptr;
                if (p.role != role or !p.isAvailable(gs.clock.day_index) or p.posted_hq != .none) continue;
                if (gs.companyOf(p.assigned_force) != company and p.assigned_force != .none) continue;
                if (gs.pilotSeat(p.id) != .none) continue;
                if (pilot_spent and p.isUnfit()) continue; // no better off
                assignSlot(gs, u.id, .pilot, p.id) catch continue;
                found = true;
                break;
            }
            if (!found and pilot_missing) open += 1;
        }
        if (unit_mod.techRoleFor(u.kind)) |role| {
            if (u.tech == .none or !(gs.person(u.tech) orelse continue).isAvailable(gs.clock.day_index)) {
                const hours = gs.hullHours(u);
                if (gs.findFreeTech(role, company, hours) orelse gs.findFreeTech(role, .none, hours)) |tid| {
                    assignSlot(gs, u.id, .tech, tid) catch {
                        open += 1;
                        continue;
                    };
                } else open += 1;
            }
        }
    }
    return open;
}

test "auto-assign benches a spent pilot when a fresher one is free, keeps them when nobody is" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 121 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    const co = try gs.createForce("Alpha", .company, .none);
    const lance = try gs.createForce("1st", .lance, co);
    const mek = try gs.addUnit("LCT-1V");
    gs.unit(mek).?.force = lance;
    const worn = try gs.hirePerson("Worn", "Out", .mekwarrior);
    gs.person(worn).?.assigned_force = co;
    gs.person(worn).?.fatigue = 100;
    try assignSlot(&gs, mek, .pilot, worn);
    // Alone, the spent pilot keeps the seat; only the tech slot counts as open.
    try std.testing.expectEqual(@as(u32, 1), try autoAssign(&gs, co));
    try std.testing.expectEqual(worn, gs.unit(mek).?.pilot);
    // A fresh pilot on the books takes over.
    const fresh = try gs.hirePerson("Fresh", "Face", .mekwarrior);
    gs.person(fresh).?.assigned_force = co;
    _ = try autoAssign(&gs, co);
    try std.testing.expectEqual(fresh, gs.unit(mek).?.pilot);
    try std.testing.expect(gs.pilotSeat(worn) == .none);
}

test "assignBlock's reason matches crewChoices' dim and the assign command's refusal for the same two blocks" {
    const queries = @import("queries.zig");
    const commands = @import("commands.zig");
    const starter_company = @import("starter_company.zig");

    var gs = GameState.init(std.testing.allocator, .{ .seed = 913 });
    defer gs.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    _ = try gs.createCommander("T", .LC, .line_officer);
    const company_id = try starter_company.generateInto(&gs, "Alpha");

    var mek: types.UnitId = .none;
    var uit = gs.units.iterator();
    while (uit.next()) |e| if (e.value_ptr.kind == .mek and gs.companyOf(e.value_ptr.force) == company_id) {
        mek = e.value_ptr.id;
        break;
    };
    try std.testing.expect(mek != .none);
    const u = gs.unit(mek).?;

    // A wounded pilot: assignBlock and crewChoices agree on "unavailable",
    // and the real command refuses Unavailable.
    const wounded = try gs.hirePerson("Hurt", "Pilot", .mekwarrior);
    gs.person(wounded).?.assigned_force = company_id;
    gs.person(wounded).?.status = .wounded;
    const wounded_p = gs.person(wounded).?;
    const wounded_reason = assignBlock(&gs, u, wounded_p) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("wounded", wounded_reason);
    const wounded_rows = try queries.crewChoices(al, &gs, mek);
    var wounded_row_why: ?[]const u8 = null;
    for (wounded_rows) |r| {
        if (r.id == @intFromEnum(wounded)) wounded_row_why = r.why;
    }
    try std.testing.expectEqualStrings(wounded_reason, wounded_row_why orelse return error.TestExpectedEqual);
    try std.testing.expectError(commands.Error.Unavailable, commands.execute(&gs, .{ .assign = .{ .unit = mek, .slot = .pilot, .person = wounded } }));

    // An unassigned pool hull (force == .none), and a pilot whose own
    // company is away from the seat: assignBlock and crewChoices agree on
    // "away with their company", and the real command refuses PersonAway.
    const away_pilot = try gs.hirePerson("Far", "Away", .mekwarrior);
    const away_co = try gs.createForce("Bravo", .company, .none);
    gs.person(away_pilot).?.assigned_force = away_co;
    gs.force(away_co).?.location_planet = "galatea";
    try std.testing.expect(!gs.isCompanyHome(away_co));

    const pool_mek = try gs.addUnit("LCT-1V");
    const pool_u = gs.unit(pool_mek).?;
    try std.testing.expect(pool_u.force == .none);
    const away_p = gs.person(away_pilot).?;
    const away_reason = assignBlock(&gs, pool_u, away_p) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("away with their company", away_reason);
    const away_rows = try queries.crewChoices(al, &gs, pool_mek);
    var away_row_why: ?[]const u8 = null;
    for (away_rows) |r| {
        if (r.id == @intFromEnum(away_pilot)) away_row_why = r.why;
    }
    try std.testing.expectEqualStrings(away_reason, away_row_why orelse return error.TestExpectedEqual);
    try std.testing.expectError(commands.Error.PersonAway, commands.execute(&gs, .{ .assign = .{ .unit = pool_mek, .slot = .pilot, .person = away_pilot } }));
}
