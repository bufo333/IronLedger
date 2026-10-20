//! Artillery field delivery: freighting a pooled carrier, its seated crew and
//! mechanic to a company in the field, attachment on arrival, and diversion
//! back to the source pool when the company leaves the field or disbands.
//! No MekHQ counterpart: project policy (docs/mekhq-map.md).

const std = @import("std");
const types = @import("../domain/types.zig");
const dom = @import("../domain/artillery_formation.zig");
const person = @import("../domain/person.zig");
const planet = @import("../domain/planet.zig");
const tuning = @import("../domain/tuning.zig").t;
const state = @import("state.zig");
const GameState = state.GameState;
const commands = @import("commands.zig");
const posture = @import("posture.zig");
const sites = @import("sites.zig");
const treasury = @import("treasury.zig");
const hq_ops = @import("hq_ops.zig");
const personnel = @import("personnel.zig");
const artillery = @import("artillery.zig");
const crew = @import("artillery_crew.zig");
const operations = @import("artillery_operations.zig");

/// A priced field shipment. `freight` holds the route to book on dispatch; its
/// route slice lives in the quote's allocator.
pub const FieldQuote = struct {
    formation: types.ArtilleryFormationId,
    from_hq: types.HqId,
    company: types.ForceId,
    cost: types.CBills,
    days: u32,
    eta_day: u32,
    freight: sites.Freight,
};

/// Carriers on field freight to `company`. Each holds one of its attachment
/// slots until it arrives or diverts (`artillery.committedCount`).
pub fn inboundCount(gs: *const GameState, company: types.ForceId) u32 {
    var count: u32 = 0;
    for (gs.artillery_formations.values()) |f| switch (f.placement) {
        .field_freight => |t| count += @intFromBool(t.company == company),
        else => {},
    };
    return count;
}

/// A company in the field: on station under contract or idle on a world.
/// `operationSite` treats both as the company's field site.
fn afield(gs: *GameState, company: types.ForceId) bool {
    return switch (posture.companyPosture(gs, company)) {
        .deployed, .idle_afield => true,
        .home, .en_route, .returning => false,
    };
}

/// Why one seated occupant or the mechanic of a carrier pooled at `from` cannot
/// ride field freight, or null. Travellers are available for duty, present at
/// that HQ and on no company's books. Source: docs/p2-artillery-operations-design.md,
/// Crew and personnel policy.
pub fn travelBlock(gs: *GameState, p: *const person.Person, from: types.HqId) ?commands.Error {
    if (!personnel.availableForDuty(p, gs.clock.day_index) or !crew.personPresent(gs, p, .{ .hq = from })) return error.ArtilleryCrewCannotTravel;
    if (p.assigned_force != .none) return error.ArtilleryCrewOtherCompany;
    return null;
}

/// The one owner of field-freight eligibility and price, consumed by the
/// command, the send picker and the detail view: a pooled carrier with no bay
/// job ships to a combat company in the field with a free attachment slot, its
/// crew and mechanic able to travel, at the existing freight quote from its HQ
/// (route, throughput and that HQ's transport staff), paid by that HQ.
/// Source: docs/p2-artillery-acquisition-design.md. Pure (rule 26): books no
/// throughput, moves no money, consumes no RNG; the route lives in `alloc`.
pub fn fieldFreightQuote(gs: *GameState, alloc: std.mem.Allocator, id: types.ArtilleryFormationId, company: types.ForceId) commands.Error!FieldQuote {
    const f = gs.artillery_formations.getPtr(id) orelse return error.NoSuchArtilleryFormation;
    if (!artillery.isCarried(f)) return error.ArtilleryUnavailable;
    if (operations.hasJob(gs, id)) return error.ArtilleryBayJob;
    if (f.placement != .hq_pool) return error.ArtilleryNotPooled;
    const from = f.placement.hq_pool;
    const co = gs.forces.getPtr(company) orelse return error.UnknownForce;
    if (co.echelon != .company) return error.NotACompany;
    switch (posture.companyPosture(gs, company)) {
        .deployed, .idle_afield => {},
        .home => return error.ArtilleryCompanyHome,
        .en_route, .returning => return error.ArtilleryCompanyTravelling,
    }
    if (artillery.committedCount(gs, company) >= dom.company_formation_cap) return error.ArtilleryAttachmentFull;
    for (f.crew ++ [1]types.PersonId{f.tech}) |traveller| {
        if (traveller == .none) continue;
        const p = gs.person(traveller) orelse return error.CorruptSave;
        if (travelBlock(gs, p, from)) |err| return err;
    }
    const hq = gs.hqs.getPtr(from) orelse return error.UnknownHq;
    const field_world = sites.sitePlanetKey(gs, .{ .company = company }) orelse return error.UnknownPlanet;
    if (planet.find(hq.planet_key) == null or planet.find(field_world) == null) return error.UnknownPlanet;
    const quote = sites.freightQuote(gs, alloc, .{ .hq = from }, .{ .company = company }, artillery.carrier().vehicle.tons) catch |err| return @errorCast(err);
    const eta = std.math.add(u32, gs.clock.day_index, quote.days) catch return error.ArtilleryDateExhausted;
    if (hq.funds < quote.cost) return error.InsufficientTreasury;
    return .{ .formation = id, .from_hq = from, .company = company, .cost = quote.cost, .days = quote.days, .eta_day = eta, .freight = quote };
}

/// Dispatch quoted field freight once. The posting (tagged with the company
/// and its contract, ARCH §11) and the owned log are prepared before the
/// charge, the route booking, the placement and the travellers' leave commit.
/// The travelling mechanic leaves every other technician slot it held.
pub fn ship(gs: *GameState, request: @FieldType(commands.Command, "ship_artillery_to_company")) commands.Error!commands.Result {
    var arena = std.heap.ArenaAllocator.init(gs.scratch());
    defer arena.deinit();
    const q = try fieldFreightQuote(gs, arena.allocator(), request.formation, request.company);
    const f = gs.artillery_formations.getPtr(q.formation).?;
    const books = treasury.attributionFor(gs, q.company);
    const posting = try gs.prepareTreasuryPosting(.{ .hq = q.from_hq }, .{ .day = gs.clock.day_index, .amount = -q.cost, .category = .freight, .hq = q.from_hq, .company = books.company, .contract = books.contract, .note = "artillery field freight" });
    const log = try gs.prepareLog(.delivery, .{ .hq = q.from_hq, .company = q.company }, "[artillery] formation {d} field freight to company {d}, ETA d{d}, cost {d}", .{ @intFromEnum(f.id), @intFromEnum(q.company), q.eta_day, q.cost });
    gs.commitTreasuryPosting(posting);
    sites.commitFreight(gs, q.freight);
    f.placement = .{ .field_freight = .{ .from_hq = q.from_hq, .company = q.company, .dispatch_day = gs.clock.day_index, .eta_day = q.eta_day, .paid_cost = q.cost } };
    holdTravellers(gs, f, q.eta_day);
    if (f.tech != .none) {
        for (gs.units.values()) |*u| if (u.tech == f.tech) {
            u.tech = .none;
        };
        for (gs.artillery_formations.values()) |*other| if (other.id != f.id and other.tech == f.tech) {
            other.tech = .none;
        };
    }
    gs.commitLog(log);
    return .{ .artillery_formation = f.id, .hq = q.from_hq, .artillery_freight_cost = q.cost, .artillery_eta_day = q.eta_day, .in_transit = true };
}

/// Travellers are on leave until the carrier arrives, as transferred pilots are.
fn holdTravellers(gs: *GameState, f: *const dom.Formation, eta_day: u32) void {
    for (f.crew ++ [1]types.PersonId{f.tech}) |traveller| if (gs.person(traveller)) |p| {
        p.leave_until_day = eta_day;
    };
}

/// Seated occupants and the mechanic join the company's books, leaving any HQ
/// posting; HQ staffing is refreshed. Shared by home attachment and arrival.
pub fn joinCompany(gs: *GameState, f: *const dom.Formation, company: types.ForceId) void {
    for (f.crew ++ [1]types.PersonId{f.tech}) |member| if (gs.person(member)) |p| {
        p.assigned_force = company;
        p.posted_hq = .none;
    };
    hq_ops.refreshHqStaffing(gs);
}

/// A field shipment turned back to its source pool, prepared without mutation.
pub const Diversion = struct {
    formation: types.ArtilleryFormationId,
    leg: dom.FieldReturn,
    log: state.LogEntry,
};

/// The return leg retraces the days already travelled, never less than the
/// minimum freight time; no refund and no new charge. Source:
/// docs/p2-artillery-acquisition-design.md.
fn prepareDiversion(gs: *GameState, f: *const dom.Formation) !Diversion {
    const t = f.placement.field_freight;
    if (!gs.hqs.contains(t.from_hq)) return error.CorruptSave;
    const elapsed = gs.clock.day_index -| t.dispatch_day;
    const eta = std.math.add(u32, gs.clock.day_index, @max(elapsed, tuning.logistics.freight_min_days)) catch return error.ArtilleryDateExhausted;
    const log = try gs.prepareLog(.delivery, .{ .hq = t.from_hq, .company = t.company }, "[artillery] formation {d} diverted to HQ {d}: company {d} left the field, ETA d{d}", .{ @intFromEnum(f.id), @intFromEnum(t.from_hq), @intFromEnum(t.company), eta });
    return .{ .formation = f.id, .leg = .{ .to_hq = t.from_hq, .dispatch_day = t.dispatch_day, .eta_day = eta, .paid_cost = t.paid_cost }, .log = log };
}

fn commitDiversion(gs: *GameState, d: Diversion) void {
    const f = gs.artillery_formations.getPtr(d.formation).?;
    f.placement = .{ .field_return = d.leg };
    holdTravellers(gs, f, d.leg.eta_day);
    gs.commitLog(d.log);
}

/// Daily arrival for one field entity, atomic for that entity (rule 17): field
/// freight whose company is no longer in the field diverts; due field freight
/// attaches and its travellers join the company; a due return pools at its HQ
/// with crew and mechanic still seated on unchanged books.
pub fn arrive(gs: *GameState, f: *dom.Formation) !void {
    switch (f.placement) {
        .field_freight => |t| {
            if (!gs.forces.contains(t.company)) return error.CorruptSave;
            if (!afield(gs, t.company)) {
                commitDiversion(gs, try prepareDiversion(gs, f));
                return;
            }
            if (t.eta_day > gs.clock.day_index) return;
            const log = try gs.prepareLog(.delivery, .{ .company = t.company }, "[artillery] formation {d} arrived and attached to company {d}", .{ @intFromEnum(f.id), @intFromEnum(t.company) });
            f.placement = .{ .company = t.company };
            joinCompany(gs, f, t.company);
            gs.commitLog(log);
        },
        .field_return => |t| {
            if (t.eta_day > gs.clock.day_index) return;
            if (!gs.hqs.contains(t.to_hq)) return error.CorruptSave;
            const log = try gs.prepareLog(.delivery, .{ .hq = t.to_hq }, "[artillery] formation {d} returned to the HQ {d} pool", .{ @intFromEnum(f.id), @intFromEnum(t.to_hq) });
            f.placement = .{ .hq_pool = t.to_hq };
            gs.commitLog(log);
        },
        .hq_pool, .company, .freight, .sold, .destroyed => {},
    }
}

/// Prepare the diversion of every carrier on field freight to `company`, which
/// is about to be removed. Allocates the list in `alloc` and each log's text in
/// the campaign; the caller reserves log capacity for all of them and commits
/// them with `commitDiversions` so no field freight names a removed force.
pub fn prepareDiversions(gs: *GameState, alloc: std.mem.Allocator, company: types.ForceId) ![]Diversion {
    var out: std.ArrayListUnmanaged(Diversion) = .empty;
    errdefer out.deinit(alloc);
    for (gs.artillery_formations.values()) |*f| switch (f.placement) {
        .field_freight => |t| if (t.company == company) try out.append(alloc, try prepareDiversion(gs, f)),
        else => {},
    };
    return out.toOwnedSlice(alloc);
}

/// Commit prepared diversions; log capacity was reserved by the caller.
pub fn commitDiversions(gs: *GameState, diversions: []const Diversion) void {
    for (diversions) |d| commitDiversion(gs, d);
}

const FieldFixture = struct {
    home: types.HqId,
    company: types.ForceId,
    contract: types.ContractId,
    formation: types.ArtilleryFormationId,
    crew: [4]types.PersonId,
    mechanic: types.PersonId,
};

/// A carrier pooled at the seat HQ with every seat and its mechanic posted
/// there, and a combat company of that HQ deployed under contract on Galatea.
fn fixtureForTest(gs: *GameState) !FieldFixture {
    const rules = @import("../domain/artillery_operations.zig");
    const home = try @import("founding.zig").createCommander(gs, "T", .LC, .quartermaster);
    gs.hqs.getPtr(home).?.funds = artillery.purchasePrice() * 4;
    const bought = try artillery.buy(gs, .{ .hq = home, .offer = gs.artillery_offers.items[0].id });
    var out: FieldFixture = .{ .home = home, .company = .none, .contract = .none, .formation = bought.artillery_formation, .crew = @splat(.none), .mechanic = .none };
    for (rules.seats, &out.crew) |seat, *id| {
        id.* = try gs.hirePerson(@tagName(seat), "Crew", .vehicle_crew);
        try gs.person(id.*).?.skills.put(gs.allocator(), rules.seatSkill(seat), 4);
        gs.person(id.*).?.posted_hq = home;
    }
    out.mechanic = try gs.hirePerson("Pool", "Mechanic", .tech_mechanic);
    try gs.person(out.mechanic).?.skills.put(gs.allocator(), .tech_mechanic, 4);
    gs.person(out.mechanic).?.posted_hq = home;
    hq_ops.refreshHqStaffing(gs);
    for (rules.seats, out.crew) |seat, id| _ = try crew.assign(gs, .{ .formation = out.formation, .seat = seat, .person = id });
    _ = try crew.assignTech(gs, .{ .formation = out.formation, .person = out.mechanic });
    out.company = try gs.createForce("Field", .company, .none);
    try @import("toe.zig").assignCompanyToHq(gs, out.company, home);
    out.contract = try deployForTest(gs, out.company, "galatea");
    return out;
}

fn deployForTest(gs: *GameState, company: types.ForceId, world: []const u8) !types.ContractId {
    const cid: types.ContractId = @enumFromInt(gs.next_contract_id);
    gs.next_contract_id += 1;
    try gs.contracts.put(gs.allocator(), cid, .{ .id = cid, .kind = .garrison_duty, .employer_key = "LC", .enemy_key = "PER", .planet_key = world, .status = .active, .assigned_company = company, .terms = .{ .length_months = 6, .base_pay_month = 400_000 } });
    return cid;
}

fn shipForTest(fx: FieldFixture) commands.Command {
    return .{ .ship_artillery_to_company = .{ .formation = fx.formation, .company = fx.company } };
}

fn travellersForTest(fx: FieldFixture) [5]types.PersonId {
    return fx.crew ++ [1]types.PersonId{fx.mechanic};
}

test "field freight charges its quote to the source HQ with the company's tags and puts crew and mechanic on the road" {
    const digest = @import("digest.zig");
    const combat = @import("../domain/artillery_combat.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const fx = try fixtureForTest(&gs);
    const hull = try gs.addUnit("SHD-2H");
    gs.unit(hull).?.tech = fx.mechanic;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const before = digest.stateHash(&gs);
    const quote = try fieldFreightQuote(&gs, arena.allocator(), fx.formation, fx.company);
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    try std.testing.expect(quote.cost > 0);
    const hq_funds = gs.hqs.getPtr(fx.home).?.funds;
    const outfit_funds = gs.funds;
    const result = try commands.execute(&gs, shipForTest(fx));
    try std.testing.expectEqual(quote.cost, result.artillery_freight_cost);
    try std.testing.expectEqual(quote.eta_day, result.artillery_eta_day);
    try std.testing.expect(result.in_transit);
    try std.testing.expectEqual(hq_funds - quote.cost, gs.hqs.getPtr(fx.home).?.funds);
    try std.testing.expectEqual(outfit_funds, gs.funds);
    const txn = gs.ledger.transactions.items[gs.ledger.transactions.items.len - 1];
    try std.testing.expectEqual(-quote.cost, txn.amount);
    try std.testing.expectEqual(@import("../econ/finance.zig").Category.freight, txn.category);
    try std.testing.expectEqual(fx.home, txn.hq);
    try std.testing.expectEqual(fx.company, txn.company);
    try std.testing.expectEqual(fx.contract, txn.contract);
    const f = gs.artillery_formations.getPtr(fx.formation).?;
    try std.testing.expectEqualDeep(dom.Placement{ .field_freight = .{ .from_hq = fx.home, .company = fx.company, .dispatch_day = 0, .eta_day = quote.eta_day, .paid_cost = quote.cost } }, f.placement);
    for (travellersForTest(fx)) |id| try std.testing.expectEqual(@as(?u32, quote.eta_day), gs.person(id).?.leave_until_day);
    try std.testing.expectEqual(fx.mechanic, f.tech);
    try std.testing.expectEqual(fx.crew, f.crew);
    try std.testing.expectEqual(types.PersonId.none, gs.unit(hull).?.tech);
    try std.testing.expectEqual(@as(?combat.ReadinessBlock, .not_attached), operations.readinessBlock(&gs, f));
    try std.testing.expectEqual(@as(u32, 1), artillery.committedCount(&gs, fx.company));
    try std.testing.expectEqual(@as(u32, 0), artillery.attachedCount(&gs, fx.company));
    try artillery.validate(&gs);
}

test "field freight from two unequal HQs prices each route and charges and books only its source" {
    const founding = @import("founding.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const fx = try fixtureForTest(&gs);
    const far = try founding.foundHq(&gs, "Far", .regional, "skye");
    gs.hqs.getPtr(far).?.funds = artillery.purchasePrice() * 4;
    try gs.hq_links.append(gs.allocator(), .{ .a = fx.home, .b = far, .level = 2, .established_day = 0 });
    try artillery.syncMarkets(&gs);
    const offer = for (gs.artillery_offers.items) |o| {
        if (o.hq == far) break o.id;
    } else return error.TestUnexpectedResult;
    const remote = (try artillery.buy(&gs, .{ .hq = far, .offer = offer })).artillery_formation;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const at_home = try fieldFreightQuote(&gs, arena.allocator(), fx.formation, fx.company);
    const at_far = try fieldFreightQuote(&gs, arena.allocator(), remote, fx.company);
    // The far carrier rides the far → home route before the final leg.
    try std.testing.expect(at_far.cost > at_home.cost);
    try std.testing.expect(at_far.days >= at_home.days);
    const home_funds = gs.hqs.getPtr(fx.home).?.funds;
    const far_funds = gs.hqs.getPtr(far).?.funds;
    _ = try commands.execute(&gs, .{ .ship_artillery_to_company = .{ .formation = remote, .company = fx.company } });
    try std.testing.expectEqual(far_funds - at_far.cost, gs.hqs.getPtr(far).?.funds);
    try std.testing.expectEqual(home_funds, gs.hqs.getPtr(fx.home).?.funds);
    try std.testing.expectEqual(artillery.carrier().vehicle.tons, gs.hq_links.items[0].tons_this_week);
    // The inbound carrier holds the company's one attachment slot.
    try std.testing.expectError(error.ArtilleryAttachmentFull, fieldFreightQuote(&gs, arena.allocator(), fx.formation, fx.company));
    try artillery.validate(&gs);
}

fn expectRefusedForTest(gs: *GameState, cmd: commands.Command, expected: anyerror) !void {
    const digest = @import("digest.zig");
    const before = digest.stateHash(gs);
    try std.testing.expectError(expected, commands.execute(gs, cmd));
    try std.testing.expectEqual(before, digest.stateHash(gs));
}

test "every field freight refusal leaves the whole campaign unchanged" {
    const founding = @import("founding.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const fx = try fixtureForTest(&gs);
    const ship_cmd = shipForTest(fx);
    const f = gs.artillery_formations.getPtr(fx.formation).?;
    const contract = gs.contracts.getPtr(fx.contract).?;
    try expectRefusedForTest(&gs, .{ .ship_artillery_to_company = .{ .formation = @enumFromInt(99), .company = fx.company } }, error.NoSuchArtilleryFormation);
    f.placement = .sold;
    try expectRefusedForTest(&gs, ship_cmd, error.ArtilleryUnavailable);
    f.placement = .{ .hq_pool = fx.home };
    try gs.bay_jobs.append(gs.allocator(), .{ .hq = fx.home, .kind = .artillery_depot_repair, .artillery = fx.formation, .duration_days = 2, .queued_day = 0 });
    try expectRefusedForTest(&gs, ship_cmd, error.ArtilleryBayJob);
    gs.bay_jobs.items.len = 0;
    f.placement = .{ .company = fx.company };
    try expectRefusedForTest(&gs, ship_cmd, error.ArtilleryNotPooled);
    f.placement = .{ .hq_pool = fx.home };
    try expectRefusedForTest(&gs, .{ .ship_artillery_to_company = .{ .formation = fx.formation, .company = @enumFromInt(99) } }, error.UnknownForce);
    const lance = try gs.createForce("Lance", .lance, fx.company);
    try expectRefusedForTest(&gs, .{ .ship_artillery_to_company = .{ .formation = fx.formation, .company = lance } }, error.NotACompany);
    contract.status = .completed;
    try expectRefusedForTest(&gs, ship_cmd, error.ArtilleryCompanyHome);
    gs.force(fx.company).?.return_eta_day = 30;
    try expectRefusedForTest(&gs, ship_cmd, error.ArtilleryCompanyTravelling);
    gs.force(fx.company).?.return_eta_day = null;
    contract.status = .transit;
    try expectRefusedForTest(&gs, ship_cmd, error.ArtilleryCompanyTravelling);
    contract.status = .active;
    const holder: types.ArtilleryFormationId = @enumFromInt(99);
    try gs.artillery_formations.put(gs.allocator(), holder, .{ .id = holder, .hull = .none, .acquisition_day = 0, .paid_price = 0, .placement = .{ .company = fx.company } });
    try expectRefusedForTest(&gs, ship_cmd, error.ArtilleryAttachmentFull);
    _ = gs.artillery_formations.orderedRemove(holder);
    gs.person(fx.crew[1]).?.status = .wounded;
    try expectRefusedForTest(&gs, ship_cmd, error.ArtilleryCrewCannotTravel);
    gs.person(fx.crew[1]).?.status = .active;
    gs.person(fx.mechanic).?.leave_until_day = 5;
    try expectRefusedForTest(&gs, ship_cmd, error.ArtilleryCrewCannotTravel);
    gs.person(fx.mechanic).?.leave_until_day = null;
    // Another company home at the seat HQ, with the mechanic on its books.
    const other = try gs.createForce("Other", .company, .none);
    gs.person(fx.mechanic).?.assigned_force = other;
    try expectRefusedForTest(&gs, ship_cmd, error.ArtilleryCrewOtherCompany);
    gs.person(fx.mechanic).?.assigned_force = .none;
    contract.planet_key = "nowhere";
    try expectRefusedForTest(&gs, ship_cmd, error.UnknownPlanet);
    contract.planet_key = "galatea";
    // An unlinked source HQ has no route to the company's home.
    const far = try founding.foundHq(&gs, "Far", .regional, "skye");
    const seated = f.crew;
    const mechanic = f.tech;
    f.crew = @splat(.none);
    f.tech = .none;
    f.placement = .{ .hq_pool = far };
    gs.hqs.getPtr(far).?.funds = gs.hqs.getPtr(fx.home).?.funds;
    try expectRefusedForTest(&gs, ship_cmd, error.NoRoute);
    f.placement = .{ .hq_pool = fx.home };
    f.crew = seated;
    f.tech = mechanic;
    gs.clock.day_index = std.math.maxInt(u32);
    try expectRefusedForTest(&gs, ship_cmd, error.ArtilleryDateExhausted);
    gs.clock.day_index = 0;
    const funds = gs.hqs.getPtr(fx.home).?.funds;
    gs.hqs.getPtr(fx.home).?.funds = 0;
    gs.funds = funds;
    try expectRefusedForTest(&gs, ship_cmd, error.InsufficientTreasury);
    gs.hqs.getPtr(fx.home).?.funds = funds;
    _ = try commands.execute(&gs, ship_cmd);
    try artillery.validate(&gs);
}

test "field freight attaches on arrival and its crew and mechanic join the company ready to fire" {
    const digest = @import("digest.zig");
    const rules = @import("../domain/artillery_operations.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const fx = try fixtureForTest(&gs);
    const staff = gs.hqs.getPtr(fx.home).?.staff_assigned;
    const result = try commands.execute(&gs, shipForTest(fx));
    gs.clock.day_index = result.artillery_eta_day - 1;
    try artillery.runArrivals(&gs);
    try std.testing.expect(gs.artillery_formations.get(fx.formation).?.placement == .field_freight);
    gs.clock.day_index = result.artillery_eta_day;
    try artillery.runArrivals(&gs);
    const f = gs.artillery_formations.getPtr(fx.formation).?;
    try std.testing.expectEqual(dom.Placement{ .company = fx.company }, f.placement);
    for (travellersForTest(fx)) |id| {
        try std.testing.expectEqual(fx.company, gs.person(id).?.assigned_force);
        try std.testing.expectEqual(types.HqId.none, gs.person(id).?.posted_hq);
    }
    try std.testing.expectEqual(staff - 5, gs.hqs.getPtr(fx.home).?.staff_assigned);
    try std.testing.expectEqual(@as(u32, 1), artillery.attachedCount(&gs, fx.company));
    try std.testing.expectEqual(types.Site{ .company = fx.company }, operations.operationSite(&gs, f).?);
    // With maintenance current and a loaded bin, the battery can fire.
    f.last_maintenance_day = gs.clock.day_index;
    f.slots[@intFromEnum(rules.Slot.long_tom_bin_1)].rounds = rules.long_tom_rounds_per_bin;
    try std.testing.expect(operations.operationalReadiness(&gs, f));
    try artillery.validate(&gs);
    const arrived = digest.stateHash(&gs);
    try artillery.runArrivals(&gs);
    try std.testing.expectEqual(arrived, digest.stateHash(&gs));
}

test "field freight turns back to its source pool when its company is recalled or redeploys, with no refund" {
    for ([_]enum { recall, redeploy }{ .recall, .redeploy }) |departure| {
        var gs = GameState.init(std.testing.allocator, .{});
        defer gs.deinit();
        const fx = try fixtureForTest(&gs);
        const result = try commands.execute(&gs, shipForTest(fx));
        const funds = gs.hqs.getPtr(fx.home).?.funds;
        const ledger = gs.ledger.transactions.items.len;
        gs.clock.day_index = 2;
        const contract = gs.contracts.getPtr(fx.contract).?;
        switch (departure) {
            .recall => {
                contract.status = .completed;
                gs.force(fx.company).?.return_eta_day = 40;
            },
            .redeploy => contract.status = .transit,
        }
        try artillery.runArrivals(&gs);
        const eta = @as(u32, 2) + @as(u32, @max(2, tuning.logistics.freight_min_days));
        try std.testing.expectEqualDeep(dom.Placement{ .field_return = .{ .to_hq = fx.home, .dispatch_day = 0, .eta_day = eta, .paid_cost = result.artillery_freight_cost } }, gs.artillery_formations.get(fx.formation).?.placement);
        for (travellersForTest(fx)) |id| try std.testing.expectEqual(@as(?u32, eta), gs.person(id).?.leave_until_day);
        try std.testing.expectEqual(funds, gs.hqs.getPtr(fx.home).?.funds);
        try std.testing.expectEqual(ledger, gs.ledger.transactions.items.len);
        try std.testing.expectEqual(@as(u32, 0), artillery.committedCount(&gs, fx.company));
        try artillery.validate(&gs);
        gs.clock.day_index = eta;
        try artillery.runArrivals(&gs);
        const f = gs.artillery_formations.get(fx.formation).?;
        try std.testing.expectEqual(dom.Placement{ .hq_pool = fx.home }, f.placement);
        try std.testing.expectEqual(fx.crew, f.crew);
        try std.testing.expectEqual(fx.mechanic, f.tech);
        for (travellersForTest(fx)) |id| {
            try std.testing.expectEqual(types.ForceId.none, gs.person(id).?.assigned_force);
            try std.testing.expectEqual(fx.home, gs.person(id).?.posted_hq);
        }
        try std.testing.expectEqual(funds, gs.hqs.getPtr(fx.home).?.funds);
        try artillery.validate(&gs);
    }
}

test "disbanding a company turns its inbound field freight back inside the command" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const fx = try fixtureForTest(&gs);
    _ = try commands.execute(&gs, shipForTest(fx));
    // The company comes home before any daily pass diverts the carrier.
    gs.contracts.getPtr(fx.contract).?.status = .completed;
    gs.clock.day_index = 1;
    _ = try commands.execute(&gs, .{ .disband_company = fx.company });
    try std.testing.expect(gs.forces.get(fx.company) == null);
    const placement = gs.artillery_formations.get(fx.formation).?.placement;
    try std.testing.expectEqual(fx.home, placement.field_return.to_hq);
    try std.testing.expectEqual(@as(u32, 1) + @as(u32, @max(1, tuning.logistics.freight_min_days)), placement.field_return.eta_day);
    try artillery.validate(&gs);
}

test "dispatch, home attachment with pool crew and disband diversion change nothing at each allocation failure" {
    const digest = @import("digest.zig");
    for ([_]enum { ship, attach, disband }{ .ship, .attach, .disband }) |action| {
        var failed = false;
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer outer.deinit();
            var gs = GameState.init(outer.allocator(), .{});
            const fx = try fixtureForTest(&gs);
            const contract = gs.contracts.getPtr(fx.contract).?;
            const cmd: commands.Command = switch (action) {
                .ship => shipForTest(fx),
                .attach => blk: {
                    contract.status = .completed;
                    break :blk .{ .attach_artillery = .{ .formation = fx.formation, .company = fx.company } };
                },
                .disband => blk: {
                    _ = try commands.execute(&gs, shipForTest(fx));
                    contract.status = .completed;
                    break :blk .{ .disband_company = fx.company };
                },
            };
            const before = digest.stateHash(&gs);
            gs.arena.state = .{};
            var failing = std.testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = fail_index });
            gs.arena.child_allocator = failing.allocator();
            const result = commands.execute(&gs, cmd);
            gs.arena.child_allocator = outer.allocator();
            if (result) |_| {
                // The success path is the full command: pool crew joined on attach.
                if (action == .attach) for (fx.crew) |id| try std.testing.expectEqual(fx.company, gs.person(id).?.assigned_force);
                break;
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expectEqual(before, digest.stateHash(&gs));
                failed = true;
            }
        }
        try std.testing.expect(failed);
    }
}

test "travelling crew and mechanics stay with their carrier and its HQ endpoints cannot be sold" {
    const founding = @import("founding.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const fx = try fixtureForTest(&gs);
    const far = try founding.foundHq(&gs, "Far", .regional, "skye");
    try gs.hq_links.append(gs.allocator(), .{ .a = fx.home, .b = far, .level = 2, .established_day = 0 });
    const other = try gs.createForce("Other", .company, .none);
    // HQ freight leaves pool crew and the mechanic behind on their books.
    const f = gs.artillery_formations.getPtr(fx.formation).?;
    const moved = try commands.execute(&gs, .{ .transfer_artillery = .{ .formation = fx.formation, .to_hq = far } });
    try std.testing.expectEqual(@as([4]types.PersonId, @splat(.none)), f.crew);
    try std.testing.expectEqual(types.PersonId.none, f.tech);
    for (fx.crew) |id| try std.testing.expectEqual(fx.home, gs.person(id).?.posted_hq);
    try std.testing.expectError(error.HqInUse, commands.execute(&gs, .{ .sell_hq = far }));
    gs.clock.day_index = moved.artillery_eta_day;
    try artillery.runArrivals(&gs);
    // Seat posted crew at far and ship from there; far is now a field-freight source.
    for (fx.crew, @import("../domain/artillery_operations.zig").seats) |id, seat| {
        gs.person(id).?.posted_hq = far;
        _ = try commands.execute(&gs, .{ .assign_artillery_crew = .{ .formation = fx.formation, .seat = seat, .person = id } });
    }
    gs.hqs.getPtr(far).?.funds = artillery.purchasePrice();
    // A new week reopens the link the HQ freight used.
    @import("network.zig").resetWeeklyThroughput(&gs);
    _ = try commands.execute(&gs, shipForTest(fx));
    for (fx.crew) |id| {
        try expectRefusedForTest(&gs, .{ .post_person = .{ .person = id, .hq = fx.home } }, error.PersonDeployed);
        try expectRefusedForTest(&gs, .{ .transfer_person = .{ .person = id, .to_force = other } }, error.PersonDeployed);
    }
    try expectRefusedForTest(&gs, .{ .sell_hq = far }, error.HqInUse);
    // Diverted home: the return leg's HQ is held too, and so are its travellers.
    gs.contracts.getPtr(fx.contract).?.status = .completed;
    gs.clock.day_index += 1;
    try artillery.runArrivals(&gs);
    try std.testing.expect(gs.artillery_formations.get(fx.formation).?.placement == .field_return);
    try expectRefusedForTest(&gs, .{ .sell_hq = far }, error.HqInUse);
    try expectRefusedForTest(&gs, .{ .post_person = .{ .person = fx.crew[0], .hq = fx.home } }, error.PersonDeployed);
    try artillery.validate(&gs);
}

/// Clearing any traveller from a carrier on either field leg is refused with
/// the whole campaign unchanged, and the traveller still cannot be posted away
/// or transferred.
fn expectTravellersHeldForTest(gs: *GameState, fx: FieldFixture, other: types.ForceId) !void {
    for (@import("../domain/artillery_operations.zig").seats) |seat| try expectRefusedForTest(gs, .{ .unassign_artillery_crew = .{ .formation = fx.formation, .seat = seat } }, error.ArtilleryNoServiceSite);
    try expectRefusedForTest(gs, .{ .unassign_artillery_tech = fx.formation }, error.ArtilleryNoServiceSite);
    for (travellersForTest(fx)) |id| {
        try expectRefusedForTest(gs, .{ .post_person = .{ .person = id, .hq = fx.home } }, error.PersonDeployed);
        try expectRefusedForTest(gs, .{ .transfer_person = .{ .person = id, .to_force = other } }, error.PersonDeployed);
    }
    const f = gs.artillery_formations.get(fx.formation).?;
    try std.testing.expectEqual(fx.crew, f.crew);
    try std.testing.expectEqual(fx.mechanic, f.tech);
}

test "travellers on either field leg cannot be cleared from their carrier, so arrival and diversion still carry them" {
    for ([_]enum { arrive, divert }{ .arrive, .divert }) |ending| {
        var gs = GameState.init(std.testing.allocator, .{});
        defer gs.deinit();
        const fx = try fixtureForTest(&gs);
        const other = try gs.createForce("Other", .company, .none);
        const result = try commands.execute(&gs, shipForTest(fx));
        try expectTravellersHeldForTest(&gs, fx, other);
        switch (ending) {
            .arrive => {
                gs.clock.day_index = result.artillery_eta_day;
                try artillery.runArrivals(&gs);
                try std.testing.expectEqual(dom.Placement{ .company = fx.company }, gs.artillery_formations.get(fx.formation).?.placement);
                for (travellersForTest(fx)) |id| try std.testing.expectEqual(fx.company, gs.person(id).?.assigned_force);
            },
            .divert => {
                gs.contracts.getPtr(fx.contract).?.status = .completed;
                gs.clock.day_index = 1;
                try artillery.runArrivals(&gs);
                const leg = gs.artillery_formations.get(fx.formation).?.placement.field_return;
                for (travellersForTest(fx)) |id| try std.testing.expectEqual(@as(?u32, leg.eta_day), gs.person(id).?.leave_until_day);
                try expectTravellersHeldForTest(&gs, fx, other);
                gs.clock.day_index = leg.eta_day;
                try artillery.runArrivals(&gs);
                const f = gs.artillery_formations.get(fx.formation).?;
                try std.testing.expectEqual(dom.Placement{ .hq_pool = fx.home }, f.placement);
                try std.testing.expectEqual(fx.crew, f.crew);
                try std.testing.expectEqual(fx.mechanic, f.tech);
                // Back in the pool, the seats clear again.
                _ = try commands.execute(&gs, .{ .unassign_artillery_tech = fx.formation });
            },
        }
        try artillery.validate(&gs);
    }
}

test "invalid field placements and pool books are corrupt" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const fx = try fixtureForTest(&gs);
    try artillery.validate(&gs);
    // A company member on a pool seat.
    gs.person(fx.crew[0]).?.assigned_force = fx.company;
    try std.testing.expectError(error.CorruptSave, artillery.validate(&gs));
    gs.person(fx.crew[0]).?.assigned_force = .none;
    // A pool seat posted at another HQ.
    const far = try @import("founding.zig").foundHq(&gs, "Far", .regional, "skye");
    gs.person(fx.crew[0]).?.posted_hq = far;
    try std.testing.expectError(error.CorruptSave, artillery.validate(&gs));
    gs.person(fx.crew[0]).?.posted_hq = fx.home;
    _ = try commands.execute(&gs, shipForTest(fx));
    try artillery.validate(&gs);
    const f = gs.artillery_formations.getPtr(fx.formation).?;
    const shipped = f.placement;
    // Field freight to a lance.
    const lance = try gs.createForce("Lance", .lance, fx.company);
    f.placement.field_freight.company = lance;
    try std.testing.expectError(error.CorruptSave, artillery.validate(&gs));
    f.placement = shipped;
    // Inbound plus attached over the company's cap.
    const holder: types.ArtilleryFormationId = @enumFromInt(99);
    gs.next_artillery_formation_id = 100;
    try gs.artillery_formations.put(gs.allocator(), holder, .{ .id = holder, .hull = .none, .acquisition_day = 0, .paid_price = 0, .placement = .{ .company = fx.company } });
    try std.testing.expectError(error.CorruptSave, artillery.validate(&gs));
    _ = gs.artillery_formations.orderedRemove(holder);
    // A travelling mechanic on a company's books.
    gs.person(fx.mechanic).?.assigned_force = fx.company;
    try std.testing.expectError(error.CorruptSave, artillery.validate(&gs));
    gs.person(fx.mechanic).?.assigned_force = .none;
    // A return leg to a missing HQ, and one that arrives before it left.
    f.placement = .{ .field_return = .{ .to_hq = @enumFromInt(99), .dispatch_day = 0, .eta_day = 5, .paid_cost = 0 } };
    try std.testing.expectError(error.CorruptSave, artillery.validate(&gs));
    f.placement = .{ .field_return = .{ .to_hq = fx.home, .dispatch_day = 0, .eta_day = 0, .paid_cost = 0 } };
    try std.testing.expectError(error.CorruptSave, artillery.validate(&gs));
    f.placement = .{ .field_return = .{ .to_hq = fx.home, .dispatch_day = 0, .eta_day = 5, .paid_cost = 0 } };
    try artillery.validate(&gs);
}

test "a field arrival stops an advance as a landing, while a diversion keeps the carrier on the road" {
    const checklist = @import("checklist.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ true, false }) |arrives| {
        var gs = GameState.init(std.testing.allocator, .{});
        defer gs.deinit();
        const fx = try fixtureForTest(&gs);
        // Mid-month, so payday does not stop the advance first.
        gs.clock.date.day = 15;
        const result = try commands.execute(&gs, shipForTest(fx));
        if (!arrives) gs.contracts.getPtr(fx.contract).?.status = .completed;
        gs.clock.day_index = if (arrives) result.artillery_eta_day else 1;
        const watch = try checklist.watchDay(arena.allocator(), &gs);
        try artillery.runArrivals(&gs);
        const stop = checklist.advanceStop(&gs, &watch);
        if (arrives) {
            try std.testing.expect(gs.artillery_formations.get(fx.formation).?.placement == .company);
            try std.testing.expectEqual(checklist.StopReason.arrival, stop.?.reason);
        } else {
            try std.testing.expect(gs.artillery_formations.get(fx.formation).?.placement == .field_return);
            try std.testing.expect(stop == null or stop.?.reason != .arrival);
        }
    }
}

test "fixed seed field dispatch, diversion and arrival script has a pinned digest" {
    const digest = @import("digest.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 6702 });
    defer gs.deinit();
    const fx = try fixtureForTest(&gs);
    const first = try commands.execute(&gs, shipForTest(fx));
    gs.clock.day_index = 2;
    gs.contracts.getPtr(fx.contract).?.status = .completed;
    gs.force(fx.company).?.location_planet = null;
    try artillery.runArrivals(&gs);
    gs.clock.day_index = gs.artillery_formations.get(fx.formation).?.placement.field_return.eta_day;
    try artillery.runArrivals(&gs);
    _ = try deployForTest(&gs, fx.company, "galatea");
    const second = try commands.execute(&gs, shipForTest(fx));
    gs.clock.day_index = second.artillery_eta_day;
    try artillery.runArrivals(&gs);
    try artillery.validate(&gs);
    try std.testing.expect(first.artillery_freight_cost > 0);
    try std.testing.expectEqual(dom.Placement{ .company = fx.company }, gs.artillery_formations.get(fx.formation).?.placement);
    try std.testing.expectEqual(@as(u64, 1222345396927766881), digest.stateHash(&gs));
}
