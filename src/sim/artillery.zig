//! Artillery ownership, bounded HQ acquisition, placement and accounting.
//! No MekHQ counterpart: project policy (docs/mekhq-map.md).

const std = @import("std");
const types = @import("../domain/types.zig");
const dom = @import("../domain/artillery_formation.zig");
const catalogue = @import("../domain/artillery_catalogue.zig");
const hull_dom = @import("../domain/hull_instance.zig");
const hq_dom = @import("../domain/hq.zig");
const planet = @import("../domain/planet.zig");
const unit = @import("../domain/unit.zig");
const market = @import("../econ/market.zig");
const state = @import("state.zig");
const GameState = state.GameState;
const commands = @import("commands.zig");
const posture = @import("posture.zig");
const sites = @import("sites.zig");

/// The sole approved carrier construction entry; static data validates this catalogue.
pub fn carrier() *const catalogue.Entry {
    return &catalogue.catalogue[0];
}

/// Calculated construction cost is the project purchase price; no RNG or markup.
pub fn purchasePrice() types.CBills {
    return (catalogue.calculated(carrier()) catch unreachable).cost;
}

/// Regional/brigade monthly supply exists only after the carrier's introduction year.
pub fn marketEligible(gs: *const GameState, hq: *const hq_dom.Hq) bool {
    return hq.tier != .field and gs.clock.date.year >= carrier().intro_year;
}

/// Prepare the initial founding board, without changing IDs or stock.
pub fn prepareInitialOffer(gs: *GameState, hq: *const hq_dom.Hq, id: types.HqId) !?dom.Offer {
    if (!marketEligible(gs, hq)) return null;
    if (gs.next_artillery_offer_id == 0 or gs.next_artillery_offer_id == std.math.maxInt(u32)) return error.ArtilleryIdExhausted;
    try gs.artillery_offers.ensureUnusedCapacity(gs.allocator(), 1);
    return .{ .id = @enumFromInt(gs.next_artillery_offer_id), .hq = id, .year = gs.clock.date.year, .month = gs.clock.date.month };
}

/// Install a prepared founding board without allocation or random draws.
pub fn commitInitialOffer(gs: *GameState, offer: ?dom.Offer) void {
    if (offer) |o| {
        gs.artillery_offers.appendAssumeCapacity(o);
        gs.next_artillery_offer_id += 1;
    }
}

fn currentOffer(gs: *GameState, hq: types.HqId) ?usize {
    for (gs.artillery_offers.items, 0..) |o, i| if (o.hq == hq) return i;
    return null;
}

/// Synchronize all eligible HQs atomically in stable HQ-ID order. Same-period
/// consumed stock remains consumed; rollover never accumulates unsold supply.
pub fn syncMarkets(gs: *GameState) !void {
    var ids: std.ArrayListUnmanaged(types.HqId) = .empty;
    defer ids.deinit(gs.scratch());
    var hit = gs.hqs.iterator();
    while (hit.next()) |e| if (marketEligible(gs, e.value_ptr)) {
        const old = if (currentOffer(gs, e.key_ptr.*)) |i| gs.artillery_offers.items[i] else null;
        if (old == null or old.?.year != gs.clock.date.year or old.?.month != gs.clock.date.month) try ids.append(gs.scratch(), e.key_ptr.*);
    };
    std.mem.sort(types.HqId, ids.items, {}, struct {
        fn less(_: void, a: types.HqId, b: types.HqId) bool {
            return @intFromEnum(a) < @intFromEnum(b);
        }
    }.less);
    if (gs.next_artillery_offer_id == 0 or ids.items.len > std.math.maxInt(u32) - gs.next_artillery_offer_id) return error.ArtilleryIdExhausted;
    try gs.artillery_offers.ensureUnusedCapacity(gs.allocator(), ids.items.len);
    for (ids.items) |id| {
        const offer: dom.Offer = .{ .id = @enumFromInt(gs.next_artillery_offer_id), .hq = id, .year = gs.clock.date.year, .month = gs.clock.date.month };
        if (currentOffer(gs, id)) |i| gs.artillery_offers.items[i] = offer else gs.artillery_offers.appendAssumeCapacity(offer);
        gs.next_artillery_offer_id += 1;
    }
}

fn owned(gs: *GameState, id: types.ArtilleryFormationId) commands.Error!*dom.Formation {
    const f = gs.artillery_formations.getPtr(id) orelse return error.NoSuchArtilleryFormation;
    if (f.placement == .sold) return error.ArtilleryUnavailable;
    return f;
}

/// Purchase one local board offer. All allocation and ledger/log preparation
/// precede stock consumption, payment, physical identity and placement commit.
pub fn buy(gs: *GameState, request: @FieldType(commands.Command, "buy_artillery")) commands.Error!commands.Result {
    const hq = gs.hqs.getPtr(request.hq) orelse return error.UnknownHq;
    var index: ?usize = null;
    for (gs.artillery_offers.items, 0..) |o, i| if (o.id == request.offer) {
        index = i;
        break;
    };
    const i = index orelse return error.NoSuchArtilleryOffer;
    const offer = gs.artillery_offers.items[i];
    if (offer.hq != request.hq) return error.ArtilleryWrongLocation;
    if (!marketEligible(gs, hq) or !offer.available or offer.year != gs.clock.date.year or offer.month != gs.clock.date.month) return error.ArtilleryUnavailable;
    const price = purchasePrice();
    if (hq.funds < price) return error.InsufficientTreasury;
    if (gs.next_artillery_formation_id == 0 or gs.next_artillery_formation_id == std.math.maxInt(u32)) return error.ArtilleryIdExhausted;
    if (gs.next_hull_instance_id == 0 or gs.next_hull_instance_id == std.math.maxInt(u32)) return error.HullInstanceIdExhausted;
    const fid: types.ArtilleryFormationId = @enumFromInt(gs.next_artillery_formation_id);
    const hid: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
    try gs.artillery_formations.ensureUnusedCapacity(gs.allocator(), 1);
    try gs.hull_instances.ensureUnusedCapacity(gs.allocator(), 1);
    try gs.hull_ownership_history.ensureUnusedCapacity(gs.allocator(), 1);
    const posting = try gs.prepareTreasuryPosting(.{ .hq = request.hq }, .{ .day = gs.clock.day_index, .amount = -price, .category = .unit_purchase, .hq = request.hq, .note = "artillery carrier purchased" });
    const log = try gs.prepareLog(.market, .{ .hq = request.hq }, "[artillery] formation {d} purchased at HQ {d} for {d}", .{ @intFromEnum(fid), @intFromEnum(request.hq), price });
    gs.commitTreasuryPosting(posting);
    gs.artillery_offers.items[i].available = false;
    gs.hull_instances.putAssumeCapacity(hid, .{ .id = hid, .catalogue = .artillery, .base_key = carrier().key, .intro_year = carrier().intro_year });
    gs.hull_ownership_history.appendAssumeCapacity(.{ .hull_instance_id = hid, .from_day = gs.clock.day_index, .acquisition_type = .purchase, .prior_owner_key = "market" });
    gs.artillery_formations.putAssumeCapacity(fid, .{ .id = fid, .hull = hid, .acquisition_day = gs.clock.day_index, .paid_price = price, .placement = .{ .hq_pool = request.hq } });
    gs.next_artillery_formation_id += 1;
    gs.next_hull_instance_id += 1;
    gs.commitLog(log);
    return .{ .artillery_formation = fid, .hull_instance = hid, .hq = request.hq };
}

/// Direct attachment count, separate from all Unit and support slots.
pub fn attachedCount(gs: *const GameState, co: types.ForceId) u32 {
    var count: u32 = 0;
    for (gs.artillery_formations.values()) |f| if (f.placement == .company and f.placement.company == co) {
        count += 1;
    };
    return count;
}

/// Validate the actual combat company and home locality, with no posture fallback.
fn companyHome(gs: *GameState, co: types.ForceId) commands.Error!types.HqId {
    const f = gs.forces.getPtr(co) orelse return error.UnknownForce;
    if (f.echelon != .company) return error.NotACompany;
    if (!posture.isCompanyHome(gs, co)) return error.ArtilleryWrongLocation;
    const hq = gs.homeHqFor(co);
    if (!gs.hqs.contains(hq)) return error.UnknownHq;
    return hq;
}

/// Attach only at the company's actual home pool; the carrier follows parent posture.
pub fn attach(gs: *GameState, request: @FieldType(commands.Command, "attach_artillery")) commands.Error!commands.Result {
    const f = try owned(gs, request.formation);
    const home = try companyHome(gs, request.company);
    if (f.placement != .hq_pool or f.placement.hq_pool != home) return error.ArtilleryWrongLocation;
    if (attachedCount(gs, request.company) >= dom.company_formation_cap) return error.ArtilleryAttachmentFull;
    const log = try gs.prepareLog(.rotation, .{ .hq = home, .company = request.company }, "[artillery] formation {d} attached to company {d}", .{ @intFromEnum(f.id), @intFromEnum(request.company) });
    f.placement = .{ .company = request.company };
    gs.commitLog(log);
    return .{};
}

/// Detach at actual home only, preserving both persistent identities.
pub fn detach(gs: *GameState, id: types.ArtilleryFormationId) commands.Error!commands.Result {
    const f = try owned(gs, id);
    if (f.placement != .company) return error.ArtilleryWrongLocation;
    const co = f.placement.company;
    const home = try companyHome(gs, co);
    const log = try gs.prepareLog(.rotation, .{ .hq = home, .company = co }, "[artillery] formation {d} detached at HQ {d}", .{ @intFromEnum(id), @intFromEnum(home) });
    f.placement = .{ .hq_pool = home };
    gs.commitLog(log);
    return .{};
}

/// Quote and commit explicit HQ freight once. Invalid planets never reach
/// freightQuote's compatibility fallback; date/funds exhaustion refuses unchanged.
pub fn transfer(gs: *GameState, request: @FieldType(commands.Command, "transfer_artillery")) commands.Error!commands.Result {
    const f = try owned(gs, request.formation);
    if (f.placement != .hq_pool) return error.ArtilleryWrongLocation;
    const from = f.placement.hq_pool;
    if (from == request.to_hq) return error.ArtilleryWrongLocation;
    const a = gs.hqs.getPtr(from) orelse return error.UnknownHq;
    const b = gs.hqs.getPtr(request.to_hq) orelse return error.UnknownHq;
    if (planet.find(a.planet_key) == null or planet.find(b.planet_key) == null) return error.UnknownPlanet;
    var arena = std.heap.ArenaAllocator.init(gs.scratch());
    defer arena.deinit();
    const quote = sites.freightQuote(gs, arena.allocator(), .{ .hq = from }, .{ .hq = request.to_hq }, carrier().vehicle.tons) catch |err| return @errorCast(err);
    const eta = std.math.add(u32, gs.clock.day_index, quote.days) catch return error.ArtilleryDateExhausted;
    if (a.funds < quote.cost) return error.InsufficientTreasury;
    const posting = try gs.prepareTreasuryPosting(.{ .hq = from }, .{ .day = gs.clock.day_index, .amount = -quote.cost, .category = .freight, .hq = from, .note = "artillery freight" });
    const log = try gs.prepareLog(.delivery, .{ .hq = from }, "[artillery] formation {d} freight to HQ {d}, ETA d{d}, cost {d}", .{ @intFromEnum(f.id), @intFromEnum(request.to_hq), eta, quote.cost });
    gs.commitTreasuryPosting(posting);
    sites.commitFreight(gs, quote);
    f.placement = .{ .freight = .{ .from_hq = from, .to_hq = request.to_hq, .dispatch_day = gs.clock.day_index, .eta_day = eta, .paid_cost = quote.cost } };
    gs.commitLog(log);
    return .{ .artillery_formation = request.formation, .hq = request.to_hq, .artillery_freight_cost = quote.cost, .artillery_eta_day = eta, .in_transit = true };
}

/// Complete each due freight entity atomically in stored order. Earlier arrivals
/// may commit before a later OOM; retries see pool placement and never deliver twice.
pub fn runArrivals(gs: *GameState) !void {
    for (gs.artillery_formations.values()) |*f| {
        if (f.placement != .freight or f.placement.freight.eta_day > gs.clock.day_index) continue;
        const to = f.placement.freight.to_hq;
        if (!gs.hqs.contains(to)) return error.CorruptSave;
        const log = try gs.prepareLog(.delivery, .{ .hq = to }, "[artillery] formation {d} delivered to HQ {d}", .{ @intFromEnum(f.id), @intFromEnum(to) });
        f.placement = .{ .hq_pool = to };
        gs.commitLog(log);
    }
}

/// HQ deletion cannot orphan a pool or either endpoint of committed freight.
pub fn hqHasCarriers(gs: *const GameState, hq: types.HqId) bool {
    for (gs.artillery_formations.values()) |f| switch (f.placement) {
        .hq_pool => |id| if (id == hq) return true,
        .freight => |t| if (t.from_hq == hq or t.to_hq == hq) return true,
        else => {},
    };
    return false;
}

/// Delete only the removed HQ's board records after the HQ sale prepares all work.
pub fn removeHqOffers(gs: *GameState, hq: types.HqId) void {
    var i: usize = 0;
    while (i < gs.artillery_offers.items.len) {
        if (gs.artillery_offers.items[i].hq == hq) _ = gs.artillery_offers.orderedRemove(i) else i += 1;
    }
}

/// Shared intact baseline-quality resale arithmetic; accounting inputs are not readiness.
pub fn saleValue(f: *const dom.Formation) types.CBills {
    return if (f.placement == .sold) 0 else market.intactHullSaleValue(f.paid_price, dom.intact_condition_pct, .c);
}

/// Each player carrier pays the vehicle carry owner once, including freight.
pub fn monthlyCarry(gs: *const GameState) types.CBills {
    var total: types.CBills = 0;
    for (gs.artillery_formations.values()) |f| if (f.placement != .sold) {
        total += unit.monthlyCarryCost(.vehicle);
    };
    return total;
}

/// Sale from an HQ pool credits that treasury, retains the carrier identity and
/// appends explicit market ownership. All fallible work precedes the commit.
pub fn sell(gs: *GameState, id: types.ArtilleryFormationId) commands.Error!commands.Result {
    const f = try owned(gs, id);
    if (f.placement != .hq_pool) return error.ArtilleryWrongLocation;
    const hq = f.placement.hq_pool;
    const h = gs.hqs.getPtr(hq) orelse return error.UnknownHq;
    const value = saleValue(f);
    _ = std.math.add(types.CBills, h.funds, value) catch return error.ArtilleryFundsExhausted;
    const ownership = try gs.prepareHullTransfer(f.hull, .market, "player", .transfer);
    const posting = try gs.prepareTreasuryPosting(.{ .hq = hq }, .{ .day = gs.clock.day_index, .amount = value, .category = .unit_sale, .hq = hq, .note = "artillery carrier sold" });
    const log = try gs.prepareLog(.market, .{ .hq = hq }, "[artillery] formation {d} sold for {d}", .{ @intFromEnum(id), value });
    gs.commitHullTransfer(ownership);
    gs.commitTreasuryPosting(posting);
    f.placement = .sold;
    gs.commitLog(log);
    return .{};
}

fn forbidConventionalReference(gs: *const GameState, hid: types.HullInstanceId) error{CorruptSave}!void {
    if (gs.hull_instances.get(hid)) |h| if (h.catalogue == .artillery) return error.CorruptSave;
}

/// Validate artillery's complete identity/placement/accounting invariants and
/// separation from conventional payloads. No repair, mutation, allocation or RNG.
pub fn validate(gs: *GameState) error{CorruptSave}!void {
    if (gs.next_artillery_formation_id == 0 or gs.next_artillery_offer_id == 0) return error.CorruptSave;
    for (gs.artillery_offers.items, 0..) |o, i| {
        if (o.id == .none or @intFromEnum(o.id) >= gs.next_artillery_offer_id) return error.CorruptSave;
        const h = gs.hqs.getPtr(o.hq) orelse return error.CorruptSave;
        if (!marketEligible(gs, h) or o.year != gs.clock.date.year or o.month != gs.clock.date.month) return error.CorruptSave;
        for (gs.artillery_offers.items[0..i]) |earlier| if (earlier.id == o.id or earlier.hq == o.hq) return error.CorruptSave;
    }
    for (gs.artillery_formations.values(), 0..) |f, i| {
        if (f.id == .none or @intFromEnum(f.id) >= gs.next_artillery_formation_id or f.hull == .none or @intFromEnum(f.hull) >= gs.next_hull_instance_id) return error.CorruptSave;
        if (f.paid_price != purchasePrice() or f.acquisition_day > gs.clock.day_index) return error.CorruptSave;
        const h = gs.hull_instances.getPtr(f.hull) orelse return error.CorruptSave;
        if (h.catalogue != .artillery or !std.mem.eql(u8, h.base_key, carrier().key) or h.intro_year != carrier().intro_year or h.status != .active or h.loadout.items.len != 0 or h.pre_campaign) return error.CorruptSave;
        if (h.owner != (if (f.placement == .sold) hull_dom.HullOwner.market else hull_dom.HullOwner.player)) return error.CorruptSave;
        for (gs.artillery_formations.values()[0..i]) |earlier| if (earlier.hull == f.hull) return error.CorruptSave;
        try validatePlacement(gs, f);
        try validateHistory(gs, f);
    }
    for (gs.hull_instances.values()) |h| {
        if (h.catalogue != .artillery) continue;
        var count: usize = 0;
        for (gs.artillery_formations.values()) |f| if (f.hull == h.id) {
            count += 1;
        };
        if (count != 1) return error.CorruptSave;
    }
    for (gs.units.values()) |u| try forbidConventionalReference(gs, u.hull_instance_id);
    for (gs.held_hulls.items) |h| try forbidConventionalReference(gs, h.unit.hull_instance_id);
    for (gs.faction_rosters.values()) |roster| for (roster.items) |hid| try forbidConventionalReference(gs, hid);
    for (gs.merc_company_rosters.values()) |roster| for (roster.items) |hid| try forbidConventionalReference(gs, hid);
    for (gs.market_listings.items) |o| try forbidConventionalReference(gs, o.hull_instance_id);
    for (gs.maintenance_entries.items) |e| try forbidConventionalReference(gs, e.hull_instance_id);
    for (gs.hull_combat_records.items) |e| try forbidConventionalReference(gs, e.hull_instance_id);
    for (gs.battle_reports.kept.items) |r| for (r.salvage.candidates) |c| try forbidConventionalReference(gs, c.hull_instance_id);
}

fn fixture(gs: *GameState) !types.HqId {
    const home = try @import("founding.zig").createCommander(gs, "T", .LC, .quartermaster);
    gs.hqs.getPtr(home).?.funds = purchasePrice() * 4;
    return home;
}

fn buyAt(gs: *GameState, hq: types.HqId) !commands.Result {
    return commands.execute(gs, .{ .buy_artillery = .{ .hq = hq, .offer = gs.artillery_offers.items[currentOffer(gs, hq).?].id } });
}

test "local monthly artillery offers preserve conventional stock RNG and consumed supply" {
    const digest = @import("digest.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const home = try fixture(&gs);
    const far = try @import("founding.zig").foundHq(&gs, "Far", .regional, "skye");
    const field = try @import("founding.zig").foundHq(&gs, "Field", .field, "alkaid");
    const rng_before = gs.rng;
    const stock_before = gs.market_listings.items.len;
    try syncMarkets(&gs);
    try std.testing.expectEqual(rng_before, gs.rng);
    try std.testing.expectEqual(stock_before, gs.market_listings.items.len);
    try std.testing.expectEqual(@as(usize, 2), gs.artillery_offers.items.len);
    try std.testing.expect(currentOffer(&gs, field) == null);
    const offer = gs.artillery_offers.items[currentOffer(&gs, home).?].id;
    const before = digest.stateHash(&gs);
    try std.testing.expectError(error.ArtilleryWrongLocation, commands.execute(&gs, .{ .buy_artillery = .{ .hq = far, .offer = offer } }));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    try std.testing.expectError(error.InsufficientTreasury, buyAt(&gs, far));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    const bought = try buyAt(&gs, home);
    try std.testing.expect(bought.artillery_formation != .none and bought.hull_instance != .none);
    try std.testing.expectEqual(purchasePrice(), gs.artillery_formations.get(bought.artillery_formation).?.paid_price);
    try std.testing.expectEqual(hull_dom.HullCatalogue.artillery, gs.hull_instances.get(bought.hull_instance).?.catalogue);
    const consumed = digest.stateHash(&gs);
    try syncMarkets(&gs);
    try std.testing.expectEqual(consumed, digest.stateHash(&gs));
    try std.testing.expectError(error.ArtilleryUnavailable, buyAt(&gs, home));
    try std.testing.expectEqual(consumed, digest.stateHash(&gs));
    gs.clock.date.month += 1;
    try syncMarkets(&gs);
    try std.testing.expectEqual(@as(usize, 2), gs.artillery_offers.items.len);
    try std.testing.expect(gs.artillery_offers.items[currentOffer(&gs, home).?].id != offer);
    try std.testing.expect(gs.artillery_offers.items[currentOffer(&gs, home).?].available);
    try validate(&gs);
}

test "attachment follows parent posture without adding conventional combat or operational state" {
    const digest = @import("digest.zig");
    const lift = @import("lift.zig");
    const toe = @import("toe.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const home = try fixture(&gs);
    const co = try gs.createForce("Company", .company, .none);
    try toe.assignCompanyToHq(&gs, co, home);
    const lance = try gs.createForce("Lance", .lance, co);
    const bought = try buyAt(&gs, home);
    const id = bought.artillery_formation;
    const pooled = digest.stateHash(&gs);
    try std.testing.expectError(error.NotACompany, commands.execute(&gs, .{ .attach_artillery = .{ .formation = id, .company = lance } }));
    try std.testing.expectEqual(pooled, digest.stateHash(&gs));
    _ = try commands.execute(&gs, .{ .attach_artillery = .{ .formation = id, .company = co } });
    try std.testing.expectEqual(@as(u32, 1), attachedCount(&gs, co));
    try std.testing.expectEqual(@as(u32, 1), lift.companyLiftDemand(&gs, co)[2]);
    const query = try lift.planLiftQuery(&gs, co);
    const commit = try lift.planLift(&gs, co, false);
    try std.testing.expectEqual(query.needed, commit.needed);
    try std.testing.expectEqual(@as(usize, 0), gs.units.count());
    const attached = digest.stateHash(&gs);
    try std.testing.expectError(error.ArtilleryAttached, commands.execute(&gs, .{ .disband_company = co }));
    try std.testing.expectEqual(attached, digest.stateHash(&gs));
    gs.forces.getPtr(co).?.location_planet = "galatea";
    const away = digest.stateHash(&gs);
    try std.testing.expectError(error.ArtilleryWrongLocation, commands.execute(&gs, .{ .detach_artillery = id }));
    try std.testing.expectEqual(away, digest.stateHash(&gs));
    gs.forces.getPtr(co).?.return_eta_day = 40;
    const returning = digest.stateHash(&gs);
    try std.testing.expectError(error.ArtilleryWrongLocation, commands.execute(&gs, .{ .detach_artillery = id }));
    try std.testing.expectEqual(returning, digest.stateHash(&gs));
    try std.testing.expectEqual(@as(u32, 1), (try lift.planLiftQuery(&gs, co)).needed);
    gs.forces.getPtr(co).?.return_eta_day = null;
    gs.forces.getPtr(co).?.location_planet = null;
    _ = try commands.execute(&gs, .{ .detach_artillery = id });
    try std.testing.expectEqual(@as(u32, 0), lift.companyLiftDemand(&gs, co)[2]);
    try std.testing.expectEqual(bought.hull_instance, gs.artillery_formations.get(id).?.hull);
    try validate(&gs);
}

test "freight charges local funds reserves catalogue mass and arrives only once" {
    const digest = @import("digest.zig");
    const treasury = @import("treasury.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const home = try fixture(&gs);
    const far = try @import("founding.zig").foundHq(&gs, "Far", .regional, "skye");
    try gs.hq_links.append(gs.allocator(), .{ .a = home, .b = far, .level = 2, .established_day = 0 });
    const bought = try buyAt(&gs, home);
    const id = bought.artillery_formation;
    const before = digest.stateHash(&gs);
    try std.testing.expectError(error.ArtilleryWrongLocation, commands.execute(&gs, .{ .transfer_artillery = .{ .formation = id, .to_hq = home } }));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    const funds = gs.hqs.getPtr(home).?.funds;
    const far_funds = gs.hqs.getPtr(far).?.funds;
    const carry = treasury.monthlyHullUpkeep(&gs);
    const result = try commands.execute(&gs, .{ .transfer_artillery = .{ .formation = id, .to_hq = far } });
    try std.testing.expectEqual(home, gs.artillery_formations.get(id).?.placement.freight.from_hq);
    try std.testing.expectEqual(far, result.hq);
    try std.testing.expectEqual(funds - result.artillery_freight_cost, gs.hqs.getPtr(home).?.funds);
    try std.testing.expectEqual(far_funds, gs.hqs.getPtr(far).?.funds);
    try std.testing.expectEqual(carrier().vehicle.tons, gs.hq_links.items[0].tons_this_week);
    try std.testing.expectEqual(carry, treasury.monthlyHullUpkeep(&gs));
    const transit = digest.stateHash(&gs);
    try std.testing.expectError(error.ArtilleryWrongLocation, commands.execute(&gs, .{ .sell_artillery = id }));
    try std.testing.expectEqual(transit, digest.stateHash(&gs));
    try std.testing.expectError(error.HqInUse, commands.execute(&gs, .{ .sell_hq = far }));
    try std.testing.expectEqual(transit, digest.stateHash(&gs));
    gs.clock.day_index = result.artillery_eta_day;
    try runArrivals(&gs);
    try std.testing.expectEqual(dom.Placement{ .hq_pool = far }, gs.artillery_formations.get(id).?.placement);
    const arrived = digest.stateHash(&gs);
    try runArrivals(&gs);
    try std.testing.expectEqual(arrived, digest.stateHash(&gs));
    _ = try commands.execute(&gs, .{ .sell_artillery = id });
    try std.testing.expectEqual(@as(types.CBills, 0), monthlyCarry(&gs));
    try std.testing.expectEqual(@as(types.CBills, 0), saleValue(gs.artillery_formations.getPtr(id).?));
    try std.testing.expectEqual(hull_dom.HullOwner.market, gs.hull_instances.get(bought.hull_instance).?.owner);
    try validate(&gs);
}

test "purchase freight disposal and arrival failures preserve complete gameplay digest" {
    const digest = @import("digest.zig");
    for (0..4) |operation| {
        var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer outer.deinit();
        var gs = GameState.init(outer.allocator(), .{});
        defer gs.deinit();
        const home = try fixture(&gs);
        const far = try @import("founding.zig").foundHq(&gs, "Far", .regional, "skye");
        try gs.hq_links.append(gs.allocator(), .{ .a = home, .b = far, .level = 2, .established_day = 0 });
        const bought: commands.Result = if (operation != 0) try buyAt(&gs, home) else .{};
        if (operation == 3) {
            const trip = try transfer(&gs, .{ .formation = bought.artillery_formation, .to_hq = far });
            gs.clock.day_index = trip.artillery_eta_day;
        }
        const before = digest.stateHash(&gs);
        const arena_state = gs.arena.state;
        const child = gs.arena.child_allocator;
        gs.arena.state = .{};
        gs.arena.child_allocator = std.testing.failing_allocator;
        defer {
            gs.arena.state = arena_state;
            gs.arena.child_allocator = child;
        }
        switch (operation) {
            0 => try std.testing.expectError(error.OutOfMemory, buyAt(&gs, home)),
            1 => try std.testing.expectError(error.OutOfMemory, transfer(&gs, .{ .formation = bought.artillery_formation, .to_hq = far })),
            2 => try std.testing.expectError(error.OutOfMemory, sell(&gs, bought.artillery_formation)),
            3 => try std.testing.expectError(error.OutOfMemory, runArrivals(&gs)),
            else => unreachable,
        }
        try std.testing.expectEqual(before, digest.stateHash(&gs));
    }
}

test "attachment cap actual home and noncombat echelons refuse atomically" {
    const digest = @import("digest.zig");
    const toe = @import("toe.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const home = try fixture(&gs);
    const other = try @import("founding.zig").foundHq(&gs, "Other", .regional, "skye");
    const co = try gs.createForce("Company", .company, .none);
    try toe.assignCompanyToHq(&gs, co, other);
    const first = try buyAt(&gs, home);
    const pooled = @import("digest.zig").stateHash(&gs);
    try std.testing.expectError(error.ArtilleryWrongLocation, attach(&gs, .{ .formation = first.artillery_formation, .company = co }));
    try std.testing.expectEqual(pooled, digest.stateHash(&gs));
    try toe.assignCompanyToHq(&gs, co, home);
    _ = try attach(&gs, .{ .formation = first.artillery_formation, .company = co });
    gs.clock.date.month += 1;
    try syncMarkets(&gs);
    const second = try buyAt(&gs, home);
    const before = digest.stateHash(&gs);
    try std.testing.expectError(error.ArtilleryAttachmentFull, attach(&gs, .{ .formation = second.artillery_formation, .company = co }));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    for ([_]@import("../domain/force.zig").Echelon{ .support_company, .air_company, .lance }) |echelon| {
        const invalid = try gs.createForce("Wrong echelon", echelon, co);
        const bad = digest.stateHash(&gs);
        try std.testing.expectError(error.NotACompany, attach(&gs, .{ .formation = second.artillery_formation, .company = invalid }));
        try std.testing.expectEqual(bad, digest.stateHash(&gs));
    }
    try validate(&gs);
}

test "freight route funds and date exhaustion refuse without consuming anything" {
    const digest = @import("digest.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const home = try fixture(&gs);
    const other = try @import("founding.zig").foundHq(&gs, "Other", .regional, "skye");
    const first = try buyAt(&gs, home);
    const request: @FieldType(commands.Command, "transfer_artillery") = .{ .formation = first.artillery_formation, .to_hq = other };
    const unlinked = digest.stateHash(&gs);
    try std.testing.expectError(error.NoRoute, transfer(&gs, request));
    try std.testing.expectEqual(unlinked, digest.stateHash(&gs));
    try gs.hq_links.append(gs.allocator(), .{ .a = home, .b = other, .level = 2, .established_day = 0 });
    gs.hq_links.items[0].tons_this_week = gs.hq_links.items[0].tonsPerWeek();
    const saturated = digest.stateHash(&gs);
    try std.testing.expectError(error.NoRoute, transfer(&gs, request));
    try std.testing.expectEqual(saturated, digest.stateHash(&gs));
    gs.hq_links.items[0].tons_this_week = 0;
    gs.hqs.getPtr(home).?.funds = 0;
    gs.funds = 1_000_000_000;
    const broke = digest.stateHash(&gs);
    try std.testing.expectError(error.InsufficientTreasury, transfer(&gs, request));
    try std.testing.expectEqual(broke, digest.stateHash(&gs));
    gs.hqs.getPtr(home).?.funds = purchasePrice();
    gs.clock.day_index = std.math.maxInt(u32);
    const exhausted = digest.stateHash(&gs);
    try std.testing.expectError(error.ArtilleryDateExhausted, transfer(&gs, request));
    try std.testing.expectEqual(exhausted, digest.stateHash(&gs));
    gs.clock.day_index = 0;
    gs.hqs.getPtr(other).?.planet_key = gs.hqs.getPtr(home).?.planet_key;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const quote = try sites.freightQuote(&gs, arena.allocator(), .{ .hq = home }, .{ .hq = other }, carrier().vehicle.tons);
    const moved = try transfer(&gs, request);
    try std.testing.expectEqual(quote.cost, moved.artillery_freight_cost);
    try std.testing.expectEqual(quote.days, moved.artillery_eta_day);
    try std.testing.expectEqual(carrier().vehicle.tons, gs.hq_links.items[0].tons_this_week);
}

test "market synchronization ID exhaustion and allocation failure leave every board unchanged" {
    const digest = @import("digest.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const home = try fixture(&gs);
    gs.next_artillery_formation_id = std.math.maxInt(u32);
    const formation_max = digest.stateHash(&gs);
    try std.testing.expectError(error.ArtilleryIdExhausted, buyAt(&gs, home));
    try std.testing.expectEqual(formation_max, digest.stateHash(&gs));
    gs.next_artillery_formation_id = 1;
    gs.next_hull_instance_id = std.math.maxInt(u32);
    const hull_max = digest.stateHash(&gs);
    try std.testing.expectError(error.HullInstanceIdExhausted, buyAt(&gs, home));
    try std.testing.expectEqual(hull_max, digest.stateHash(&gs));
    gs.next_artillery_offer_id = std.math.maxInt(u32);
    gs.clock.date.month += 1;
    const offer_max = digest.stateHash(&gs);
    try std.testing.expectError(error.ArtilleryIdExhausted, syncMarkets(&gs));
    try std.testing.expectEqual(offer_max, digest.stateHash(&gs));
    gs.next_artillery_offer_id = 2;
    const arena_state = gs.arena.state;
    const child = gs.arena.child_allocator;
    gs.arena.state = .{};
    gs.arena.child_allocator = std.testing.failing_allocator;
    defer {
        gs.arena.state = arena_state;
        gs.arena.child_allocator = child;
    }
    gs.artillery_offers.capacity = gs.artillery_offers.items.len;
    const before = digest.stateHash(&gs);
    try std.testing.expectError(error.OutOfMemory, syncMarkets(&gs));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
}

test "attached carrier travels outward redeploys recalls and returns with company lift demand" {
    const lift = @import("lift.zig");
    const control = @import("contract_control.zig");
    const contract_market = @import("contract_market.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 71 });
    defer gs.deinit();
    const home = try fixture(&gs);
    const co = try @import("starter_company.zig").generateInto(&gs, "Company");
    const before = try lift.planLiftQuery(&gs, co);
    const bought = try buyAt(&gs, home);
    _ = try attach(&gs, .{ .formation = bought.artillery_formation, .company = co });
    try std.testing.expectEqual(before.needed + dom.carrier_vehicle_bays, (try lift.planLiftQuery(&gs, co)).needed);
    try contract_market.refresh(&gs);
    const offer = for (gs.contract_offers.items) |*o| {
        if (contract_market.offerEligible(&gs, o, co)) break o.id;
    } else return error.TestUnexpectedResult;
    _ = try commands.execute(&gs, .{ .accept_contract = .{ .company = co, .offer = offer } });
    try std.testing.expect(posture.companyPosture(&gs, co) == .en_route);
    try std.testing.expectEqual(co, gs.artillery_formations.get(bought.artillery_formation).?.placement.company);
    try std.testing.expectError(error.ArtilleryWrongLocation, detach(&gs, bought.artillery_formation));
    const contract = gs.deploymentContract(co).?;
    contract.status = .active;
    try std.testing.expect(posture.companyPosture(&gs, co) == .deployed);
    try std.testing.expectError(error.ArtilleryWrongLocation, detach(&gs, bought.artillery_formation));
    const world = contract.planet_key;
    contract.status = .completed;
    gs.force(co).?.location_planet = world;
    try std.testing.expect(posture.companyPosture(&gs, co) == .idle_afield);
    const redeploy_offer = for (gs.contract_offers.items) |*o| {
        if (contract_market.offerEligible(&gs, o, co)) break o.id;
    } else return error.TestUnexpectedResult;
    _ = try commands.execute(&gs, .{ .accept_contract = .{ .company = co, .offer = redeploy_offer } });
    try std.testing.expect(posture.companyPosture(&gs, co) == .en_route);
    try std.testing.expectEqual(co, gs.artillery_formations.get(bought.artillery_formation).?.placement.company);
    try std.testing.expectEqual(before.needed + dom.carrier_vehicle_bays, (try lift.planLiftQuery(&gs, co)).needed);
    _ = try commands.execute(&gs, .{ .recall_company = co });
    try std.testing.expect(posture.companyPosture(&gs, co) == .returning);
    const arrival = gs.force(co).?.return_eta_day.?;
    gs.clock.day_index = arrival;
    try control.runReturns(&gs);
    try std.testing.expect(posture.isCompanyHome(&gs, co));
    _ = try detach(&gs, bought.artillery_formation);
    try std.testing.expectEqual(dom.Placement{ .hq_pool = home }, gs.artillery_formations.get(bought.artillery_formation).?.placement);
}

test "fixed seed artillery acquisition attachment freight and disposal script has pinned digest" {
    const digest = @import("digest.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 625 });
    defer gs.deinit();
    const home = try fixture(&gs);
    const co = try gs.createForce("Company", .company, .none);
    try @import("toe.zig").assignCompanyToHq(&gs, co, home);
    const bought = try buyAt(&gs, home);
    _ = try commands.execute(&gs, .{ .attach_artillery = .{ .formation = bought.artillery_formation, .company = co } });
    _ = try commands.execute(&gs, .{ .detach_artillery = bought.artillery_formation });
    const far = try @import("founding.zig").foundHq(&gs, "Far", .regional, "skye");
    try gs.hq_links.append(gs.allocator(), .{ .a = home, .b = far, .level = 2, .established_day = 0 });
    const transfer_result = try commands.execute(&gs, .{ .transfer_artillery = .{ .formation = bought.artillery_formation, .to_hq = far } });
    gs.clock.day_index = transfer_result.artillery_eta_day;
    try runArrivals(&gs);
    _ = try commands.execute(&gs, .{ .sell_artillery = bought.artillery_formation });
    try validate(&gs);
    try std.testing.expectEqual(bought.hull_instance, gs.artillery_formations.get(bought.artillery_formation).?.hull);
    try std.testing.expectEqual(dom.Placement.sold, gs.artillery_formations.get(bought.artillery_formation).?.placement);
    try std.testing.expectEqual(@as(usize, 0), gs.units.count());
    try std.testing.expectEqual(@as(types.CBills, 0), monthlyCarry(&gs));
    try std.testing.expectEqual(@as(usize, 2), gs.hull_ownership_history.items.len);
    try std.testing.expectEqual(@as(?u32, transfer_result.artillery_eta_day), gs.hull_ownership_history.items[0].to_day);
    try std.testing.expect(gs.hull_ownership_history.items[1].isOpen());
    try std.testing.expectEqual(@as(u64, 3971801592459885178), digest.stateHash(&gs));
}

fn validatePlacement(gs: *GameState, f: dom.Formation) error{CorruptSave}!void {
    switch (f.placement) {
        .hq_pool => |id| if (id == .none or !gs.hqs.contains(id)) return error.CorruptSave,
        .company => |co| {
            const c = gs.forces.getPtr(co) orelse return error.CorruptSave;
            if (c.echelon != .company or !gs.hqs.contains(gs.homeHqFor(co)) or attachedCount(gs, co) > dom.company_formation_cap) return error.CorruptSave;
        },
        .freight => |t| {
            const a = gs.hqs.getPtr(t.from_hq) orelse return error.CorruptSave;
            const b = gs.hqs.getPtr(t.to_hq) orelse return error.CorruptSave;
            if (t.from_hq == t.to_hq or planet.find(a.planet_key) == null or planet.find(b.planet_key) == null or t.dispatch_day < f.acquisition_day or t.dispatch_day > gs.clock.day_index or t.eta_day <= t.dispatch_day or t.paid_cost < 0) return error.CorruptSave;
        },
        .sold => {},
    }
}

fn validateHistory(gs: *const GameState, f: dom.Formation) error{CorruptSave}!void {
    var count: usize = 0;
    var first: ?hull_dom.HullOwnershipHistory = null;
    var previous: ?hull_dom.HullOwnershipHistory = null;
    for (gs.hull_ownership_history.items) |h| {
        if (h.hull_instance_id != f.hull) continue;
        if (first == null) first = h;
        if (h.from_day > gs.clock.day_index) return error.CorruptSave;
        if (h.to_day) |day| if (day < h.from_day or day > gs.clock.day_index) return error.CorruptSave;
        if (previous) |p| if (p.to_day == null or p.to_day.? != h.from_day) return error.CorruptSave;
        previous = h;
        count += 1;
    }
    const initial = first orelse return error.CorruptSave;
    if (initial.from_day != f.acquisition_day or initial.acquisition_type != .purchase or !std.mem.eql(u8, initial.prior_owner_key, "market")) return error.CorruptSave;
    if (!previous.?.isOpen()) return error.CorruptSave;
    if (f.placement == .sold) {
        if (count != 2 or previous.?.acquisition_type != .transfer or !std.mem.eql(u8, previous.?.prior_owner_key, "player")) return error.CorruptSave;
    } else if (count != 1) return error.CorruptSave;
}
