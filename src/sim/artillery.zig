//! Artillery ownership, bounded HQ acquisition, placement and accounting.
//! No MekHQ counterpart: project policy (docs/mekhq-map.md).

const std = @import("std");
const types = @import("../domain/types.zig");
const dom = @import("../domain/artillery_formation.zig");
const catalogue = @import("../domain/artillery_catalogue.zig");
const hull_dom = @import("../domain/hull_instance.zig");
const hq_dom = @import("../domain/hq.zig");
const clock = @import("../domain/clock.zig");
const planet = @import("../domain/planet.zig");
const unit = @import("../domain/unit.zig");
const market = @import("../econ/market.zig");
const state = @import("state.zig");
const GameState = state.GameState;
const commands = @import("commands.zig");
const posture = @import("posture.zig");
const sites = @import("sites.zig");
const operations = @import("artillery_operations.zig");
const field_delivery = @import("artillery_field.zig");
const operation_rules = @import("../domain/artillery_operations.zig");
const battle_report = @import("../domain/battle_report.zig");
const combat_rules = @import("../domain/artillery_combat.zig");
const tuning = @import("../domain/tuning.zig").t;

/// The sole approved carrier construction entry; static data validates this catalogue.
pub fn carrier() *const catalogue.Entry {
    return &catalogue.catalogue[0];
}

/// Calculated construction cost is the project purchase price; no RNG or markup.
pub fn purchasePrice() types.CBills {
    return (catalogue.calculated(carrier()) catch unreachable).cost;
}

/// Regional/brigade monthly supply exists in `year` only from the carrier's
/// introduction year on. The one owner of artillery market eligibility. Pure.
pub fn marketEligibleIn(hq: *const hq_dom.Hq, year: u16) bool {
    return hq.tier != .field and year >= carrier().intro_year;
}

/// `marketEligibleIn` at the campaign clock's year.
pub fn marketEligible(gs: *const GameState, hq: *const hq_dom.Hq) bool {
    return marketEligibleIn(hq, gs.clock.date.year);
}

/// Prepare the founding board for `date`, the campaign's start date: the offer
/// is judged and stamped with that year and month. Reserves capacity only;
/// changes no ID, stock or RNG.
pub fn prepareInitialOffer(gs: *GameState, hq: *const hq_dom.Hq, id: types.HqId, date: clock.Date) !?dom.Offer {
    if (!marketEligibleIn(hq, date.year)) return null;
    if (gs.next_artillery_offer_id == 0 or gs.next_artillery_offer_id == std.math.maxInt(u32)) return error.ArtilleryIdExhausted;
    try gs.artillery_offers.ensureUnusedCapacity(gs.allocator(), 1);
    return .{ .id = @enumFromInt(gs.next_artillery_offer_id), .hq = id, .year = date.year, .month = date.month };
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
    if (!isCarried(f)) return error.ArtilleryUnavailable;
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

/// The company's attachment slots in use: attached carriers plus carriers on
/// field freight to it. `dom.company_formation_cap` bounds this count.
pub fn committedCount(gs: *const GameState, co: types.ForceId) u32 {
    return attachedCount(gs, co) + field_delivery.inboundCount(gs, co);
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

/// Home attachment eligibility, the one owner the command and the send picker
/// consume: a pooled carrier with no bay job joins a combat company physically
/// home at that same HQ, within the attachment cap. Returns that home HQ. A
/// company in the field takes field freight instead (`artillery_field`).
/// Source: docs/p2-artillery-acquisition-design.md. Pure; no RNG.
pub fn attachCheck(gs: *GameState, f: *const dom.Formation, co: types.ForceId) commands.Error!types.HqId {
    if (!isCarried(f)) return error.ArtilleryUnavailable;
    if (operations.hasJob(gs, f.id)) return error.ArtilleryBayJob;
    const company = gs.forces.getPtr(co) orelse return error.UnknownForce;
    if (company.echelon != .company) return error.NotACompany;
    if (f.placement != .hq_pool) return error.ArtilleryNotPooled;
    switch (posture.companyPosture(gs, co)) {
        .home => {},
        .deployed, .idle_afield => return error.ArtilleryCompanyAfield,
        .en_route, .returning => return error.ArtilleryCompanyTravelling,
    }
    const home = gs.homeHqFor(co);
    if (!gs.hqs.contains(home)) return error.UnknownHq;
    if (f.placement.hq_pool != home) return error.ArtilleryWrongHq;
    if (committedCount(gs, co) >= dom.company_formation_cap) return error.ArtilleryAttachmentFull;
    return home;
}

/// Attach only at the company's actual home pool; the carrier follows parent
/// posture. Pool crew join the company's books; the pool mechanic is cleared.
pub fn attach(gs: *GameState, request: @FieldType(commands.Command, "attach_artillery")) commands.Error!commands.Result {
    const f = gs.artillery_formations.getPtr(request.formation) orelse return error.NoSuchArtilleryFormation;
    const home = try attachCheck(gs, f, request.company);
    const log = try gs.prepareLog(.rotation, .{ .hq = home, .company = request.company }, "[artillery] formation {d} attached to company {d}", .{ @intFromEnum(f.id), @intFromEnum(request.company) });
    f.tech = .none;
    f.placement = .{ .company = request.company };
    field_delivery.joinCompany(gs, f, request.company);
    gs.commitLog(log);
    return .{};
}

/// Detach at actual home only, preserving both persistent identities.
pub fn detach(gs: *GameState, id: types.ArtilleryFormationId) commands.Error!commands.Result {
    const f = try owned(gs, id);
    if (operations.hasJob(gs, f.id)) return error.ArtilleryBayJob;
    if (f.placement != .company) return error.ArtilleryWrongLocation;
    const co = f.placement.company;
    const home = try companyHome(gs, co);
    const log = try gs.prepareLog(.rotation, .{ .hq = home, .company = co }, "[artillery] formation {d} detached at HQ {d}", .{ @intFromEnum(id), @intFromEnum(home) });
    f.tech = .none;
    f.crew = @splat(.none);
    f.placement = .{ .hq_pool = home };
    gs.commitLog(log);
    return .{};
}

/// Quote and commit explicit HQ freight once. Invalid planets never reach
/// freightQuote's compatibility fallback; date/funds exhaustion refuses unchanged.
/// Pool crew and the mechanic stay behind on their books.
pub fn transfer(gs: *GameState, request: @FieldType(commands.Command, "transfer_artillery")) commands.Error!commands.Result {
    const f = try owned(gs, request.formation);
    if (operations.hasJob(gs, f.id)) return error.ArtilleryBayJob;
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
    f.tech = .none;
    f.crew = @splat(.none);
    f.placement = .{ .freight = .{ .from_hq = from, .to_hq = request.to_hq, .dispatch_day = gs.clock.day_index, .eta_day = eta, .paid_cost = quote.cost } };
    gs.commitLog(log);
    return .{ .artillery_formation = request.formation, .hq = request.to_hq, .artillery_freight_cost = quote.cost, .artillery_eta_day = eta, .in_transit = true };
}

/// Complete each due freight entity atomically in stored order, including field
/// freight arrival and diversion (`artillery_field.arrive`). Each entity's log is
/// prepared before its mutation; earlier entities may commit before a later OOM,
/// and a retry sees their new placement and never repeats them.
pub fn runArrivals(gs: *GameState) !void {
    for (gs.artillery_formations.values()) |*f| switch (f.placement) {
        .freight => |t| {
            if (t.eta_day > gs.clock.day_index) continue;
            if (!gs.hqs.contains(t.to_hq)) return error.CorruptSave;
            const log = try gs.prepareLog(.delivery, .{ .hq = t.to_hq }, "[artillery] formation {d} delivered to HQ {d}", .{ @intFromEnum(f.id), @intFromEnum(t.to_hq) });
            f.placement = .{ .hq_pool = t.to_hq };
            gs.commitLog(log);
        },
        .field_freight, .field_return => try field_delivery.arrive(gs, f),
        .hq_pool, .company, .sold, .destroyed => {},
    };
}

/// HQ deletion cannot orphan a pool or any endpoint of committed freight.
pub fn hqHasCarriers(gs: *const GameState, hq: types.HqId) bool {
    for (gs.artillery_formations.values()) |f| switch (f.placement) {
        .hq_pool => |id| if (id == hq) return true,
        .freight => |t| if (t.from_hq == hq or t.to_hq == hq) return true,
        .field_freight => |t| if (t.from_hq == hq) return true,
        .field_return => |t| if (t.to_hq == hq) return true,
        .company, .sold, .destroyed => {},
    };
    for (gs.bay_jobs.items) |job| if (job.hq == hq and job.artillery != .none) return true;
    return false;
}

/// Delete only the removed HQ's board records after the HQ sale prepares all work.
pub fn removeHqOffers(gs: *GameState, hq: types.HqId) void {
    var i: usize = 0;
    while (i < gs.artillery_offers.items.len) {
        if (gs.artillery_offers.items[i].hq == hq) _ = gs.artillery_offers.orderedRemove(i) else i += 1;
    }
}

/// Shared hull resale with actual quality, armor and the named chassis cap.
pub fn saleValue(f: *const dom.Formation) types.CBills {
    const condition = if (f.slots[@intFromEnum(operation_rules.Slot.chassis)].condition == .ok) f.armor_pct else @min(f.armor_pct, operation_rules.damaged_chassis_sale_cap_pct);
    return if (!isCarried(f)) 0 else market.intactHullSaleValue(f.paid_price, condition, f.quality);
}

/// Player placement eligibility for asset accounting, independent of readiness.
/// Source: combat design, Terminal history. Sold and destroyed history carry no cost.
pub fn isCarried(f: *const dom.Formation) bool {
    return f.placement != .sold and f.placement != .destroyed;
}

/// Dispose of an irrecoverable or scuttled carrier through the physical hull's
/// terminal lifecycle owner. Retains typed identities and closed provenance.
/// Source: combat design, Recovery and terminal history. Caller owns engagement staging.
pub fn destroy(gs: *GameState, id: types.ArtilleryFormationId) !void {
    const f = gs.artillery_formations.getPtr(id) orelse return error.NoSuchArtilleryFormation;
    if (!isCarried(f)) return error.ArtilleryUnavailable;
    _ = gs.hull_instances.get(f.hull) orelse return error.CorruptSave;
    gs.finalizeDestroyedWreck(f.hull);
    f.placement = .destroyed;
    f.armor_pct = 0;
    f.slots[@intFromEnum(operation_rules.Slot.chassis)].condition = .destroyed;
    for (&f.slots) |*slot| slot.rounds = 0;
    f.crew = @splat(.none);
    f.tech = .none;
    var index: usize = 0;
    while (index < gs.bay_jobs.items.len) {
        if (gs.bay_jobs.items[index].artillery == id) _ = gs.bay_jobs.orderedRemove(index) else index += 1;
    }
}

/// Each player carrier pays the vehicle carry owner once, including freight.
pub fn monthlyCarry(gs: *const GameState) types.CBills {
    var total: types.CBills = 0;
    for (gs.artillery_formations.values()) |f| if (isCarried(&f)) {
        total += unit.monthlyCarryCost(.vehicle);
    };
    return total;
}

/// The part of `monthlyCarry` billed to one company: its attached
/// carriers. Pooled and freighted carriers are outfit overhead.
pub fn companyMonthlyCarry(gs: *const GameState, company: types.ForceId) types.CBills {
    var total: types.CBills = 0;
    for (gs.artillery_formations.values()) |f| switch (f.placement) {
        .company => |id| if (id == company) {
            total += unit.monthlyCarryCost(.vehicle);
        },
        else => {},
    };
    return total;
}

/// Sale from an HQ pool credits that treasury, retains the carrier identity and
/// appends explicit market ownership. All fallible work precedes the commit.
pub fn sell(gs: *GameState, id: types.ArtilleryFormationId) commands.Error!commands.Result {
    const f = try owned(gs, id);
    if (operations.hasJob(gs, f.id)) return error.ArtilleryBayJob;
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
    f.tech = .none;
    f.crew = @splat(.none);
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
    try operations.validate(gs);
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
        if (h.catalogue != .artillery or !std.mem.eql(u8, h.base_key, carrier().key) or h.intro_year != carrier().intro_year or h.status != (if (f.placement == .destroyed) hull_dom.HullStatus.permanently_destroyed else hull_dom.HullStatus.active) or h.loadout.items.len != 0 or h.pre_campaign) return error.CorruptSave;
        if (h.owner != (if (f.placement == .destroyed) hull_dom.HullOwner.destroyed else if (f.placement == .sold) hull_dom.HullOwner.market else hull_dom.HullOwner.player)) return error.CorruptSave;
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
    for (gs.maintenance_entries.items) |e| {
        if (gs.hull_instances.get(e.hull_instance_id)) |h| {
            if (h.catalogue == .artillery and e.action != .repair) return error.CorruptSave;
        }
    }
    for (gs.hull_combat_records.items) |e| {
        const h = gs.hull_instances.get(e.hull_instance_id) orelse return error.CorruptSave;
        if (h.catalogue != .artillery) continue;
        const r = gs.battle_reports.find(e.battle_id) orelse return error.CorruptSave;
        const a = r.artillery orelse return error.CorruptSave;
        if (!a.physical_participation or r.conceded or a.no_fire == .enemy_forfeit or a.hull != h.id or e.contract_id != r.contract or e.kills != 0 or e.hits_taken != @intFromBool(a.severity != null) or e.armor_lost != a.armor_before -| a.armor_after or e.destroyed != (a.newly_wrecked or a.damage == .permanently_destroyed or a.damage == .scuttled) or e.cause != a.cause) return error.CorruptSave;
        var damaged: u8 = 0;
        var destroyed: u8 = 0;
        for (a.slots_before, a.slots_after) |before, after| {
            if (before.condition == after.condition) continue;
            damaged += @intFromBool(after.condition == .damaged);
            destroyed += @intFromBool(after.condition == .destroyed);
        }
        if (e.slots_damaged != damaged or e.slots_destroyed != destroyed) return error.CorruptSave;
        var count: usize = 0;
        for (gs.hull_combat_records.items) |other| if (other.hull_instance_id == h.id and other.battle_id == e.battle_id) {
            count += 1;
        };
        if (count != 1) return error.CorruptSave;
    }
    for (gs.battle_reports.kept.items) |r| if (r.artillery) |a| {
        try validateResult(gs, &r, &a);
    };
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

/// Four due arrivals: two HQ freights, field freight whose company is on
/// station (it attaches) and field freight whose company came home (it
/// diverts). `field_first` stores the field entities before the HQ freights.
fn dueArrivals(gs: *GameState, field_first: bool) !void {
    const home = try fixture(gs);
    const far = try @import("founding.zig").foundHq(gs, "Far", .regional, "skye");
    const destination = try @import("founding.zig").foundHq(gs, "Destination", .field, "alkaid");
    gs.hqs.getPtr(far).?.funds = purchasePrice() * 4;
    try syncMarkets(gs);
    const earlier = [2]commands.Result{ try buyAt(gs, home), try buyAt(gs, far) };
    gs.clock.date.month += 1;
    try syncMarkets(gs);
    const later = [2]commands.Result{ try buyAt(gs, home), try buyAt(gs, far) };
    const by_hq = if (field_first) later else earlier;
    const to_field = if (field_first) earlier else later;
    try gs.hq_links.append(gs.allocator(), .{ .a = home, .b = far, .level = 2, .established_day = 0 });
    try gs.hq_links.append(gs.allocator(), .{ .a = far, .b = destination, .level = 2, .established_day = 0 });
    const outward = try transfer(gs, .{ .formation = by_hq[0].artillery_formation, .to_hq = far });
    const onward = try transfer(gs, .{ .formation = by_hq[1].artillery_formation, .to_hq = destination });
    var eta = @max(outward.artillery_eta_day, onward.artillery_eta_day);
    // Each field carrier ships from its own pool to a company of that HQ.
    for (to_field, [_][]const u8{ "On station", "Recalled" }, [_]types.HqId{ home, far }) |bought, name, source| {
        const co = try gs.createForce(name, .company, .none);
        if (source != home) try @import("toe.zig").assignCompanyToHq(gs, co, source);
        const cid: types.ContractId = @enumFromInt(gs.next_contract_id);
        gs.next_contract_id += 1;
        try gs.contracts.put(gs.allocator(), cid, .{ .id = cid, .kind = .garrison_duty, .employer_key = "LC", .enemy_key = "PER", .planet_key = "galatea", .status = .active, .assigned_company = co, .terms = .{ .length_months = 6, .base_pay_month = 400_000 } });
        const shipped = try commands.execute(gs, .{ .ship_artillery_to_company = .{ .formation = bought.artillery_formation, .company = co } });
        eta = @max(eta, shipped.artillery_eta_day);
        if (source == far) gs.contracts.getPtr(cid).?.status = .completed;
    }
    gs.clock.day_index = eta;
}

test "partial artillery arrival allocation failure retries each carrier exactly once" {
    // The arena reaches its child allocator only for the first entities'
    // logs, so each stored order puts one kind of entity in those places.
    for ([_]bool{ false, true }) |field_first| try partialArrivalRetryForTest(field_first);
}

fn partialArrivalRetryForTest(field_first: bool) !void {
    const digest = @import("digest.zig");
    var clean = GameState.init(std.testing.allocator, .{});
    defer clean.deinit();
    try dueArrivals(&clean, field_first);
    try runArrivals(&clean);
    const complete = digest.stateHash(&clean);
    const entities = 4;
    var committed_before_failure = [_]bool{false} ** entities;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer outer.deinit();
        var gs = GameState.init(outer.allocator(), .{});
        defer gs.deinit();
        try dueArrivals(&gs, field_first);
        var original: [entities]dom.Formation = undefined;
        @memcpy(&original, gs.artillery_formations.values());
        const log_count = gs.event_log.items.len;
        const ledger_count = gs.ledger.transactions.items.len;
        const funds = gs.funds;
        var hq_funds: [3]types.CBills = undefined;
        for (&hq_funds, gs.hqs.values()) |*kept, h| kept.* = h.funds;
        const reservations = [2]u32{ gs.hq_links.items[0].tons_this_week, gs.hq_links.items[1].tons_this_week };
        const next_formation = gs.next_artillery_formation_id;
        const next_hull = gs.next_hull_instance_id;
        const next_offer = gs.next_artillery_offer_id;
        const before = digest.stateHash(&gs);
        // One append fits; the next must grow. A fresh arena makes the
        // failing allocator exercise real log preparation allocations.
        try gs.reserveLog(entities);
        gs.event_log.capacity = log_count + 1;
        gs.arena.state = .{};
        var failing = std.testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = fail_index, .resize_fail_index = 0 });
        gs.arena.child_allocator = failing.allocator();
        const result = runArrivals(&gs);
        gs.arena.child_allocator = outer.allocator();
        if (result) |_| {
            try std.testing.expectEqual(complete, digest.stateHash(&gs));
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            // Earlier entities committed whole, each with one log; the failed
            // entity and every later one are untouched.
            var done: usize = 0;
            while (done < entities and !std.meta.eql(original[done].placement, gs.artillery_formations.values()[done].placement)) done += 1;
            for (original[done..], gs.artillery_formations.values()[done..]) |was, now| try std.testing.expectEqualDeep(was, now);
            try std.testing.expectEqual(log_count + done, gs.event_log.items.len);
            if (done == 0) try std.testing.expectEqual(before, digest.stateHash(&gs));
            committed_before_failure[done] = true;
            try std.testing.expectEqual(ledger_count, gs.ledger.transactions.items.len);
            try std.testing.expectEqual(funds, gs.funds);
            for (hq_funds, gs.hqs.values()) |kept, h| try std.testing.expectEqual(kept, h.funds);
            try std.testing.expectEqual(reservations, [2]u32{ gs.hq_links.items[0].tons_this_week, gs.hq_links.items[1].tons_this_week });
            try std.testing.expectEqual(next_formation, gs.next_artillery_formation_id);
            try std.testing.expectEqual(next_hull, gs.next_hull_instance_id);
            try std.testing.expectEqual(next_offer, gs.next_artillery_offer_id);
            try runArrivals(&gs);
            // Compare all gameplay state with uninterrupted delivery, including
            // log order/tags, charges, reservations, hull history, IDs and RNG.
            try std.testing.expectEqual(complete, digest.stateHash(&gs));
            try std.testing.expectEqual(log_count + entities, gs.event_log.items.len);
            try runArrivals(&gs);
            try std.testing.expectEqual(complete, digest.stateHash(&gs));
        }
    }
    // Failures landed at the first entity and after it had committed.
    try std.testing.expect(committed_before_failure[0] and committed_before_failure[1]);
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
    try std.testing.expectError(error.ArtilleryWrongHq, attach(&gs, .{ .formation = first.artillery_formation, .company = co }));
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

test "attach refusals name a company in the field or a carrier pooled elsewhere and change nothing" {
    const digest = @import("digest.zig");
    const toe = @import("toe.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const home = try fixture(&gs);
    const other = try @import("founding.zig").foundHq(&gs, "Other", .regional, "skye");
    const co = try gs.createForce("Company", .company, .none);
    try toe.assignCompanyToHq(&gs, co, home);
    const bought = try buyAt(&gs, home);
    const request: commands.Command = .{ .attach_artillery = .{ .formation = bought.artillery_formation, .company = co } };
    const cid: types.ContractId = @enumFromInt(gs.next_contract_id);
    gs.next_contract_id += 1;
    try gs.contracts.put(gs.allocator(), cid, .{ .id = cid, .kind = .garrison_duty, .employer_key = "LC", .enemy_key = "PER", .planet_key = "galatea", .status = .active, .assigned_company = co, .terms = .{ .length_months = 6, .base_pay_month = 400_000 } });
    try std.testing.expect(posture.companyPosture(&gs, co) == .deployed);
    const deployed = digest.stateHash(&gs);
    try std.testing.expectError(error.ArtilleryCompanyAfield, commands.execute(&gs, request));
    try std.testing.expectEqual(deployed, digest.stateHash(&gs));
    gs.contracts.getPtr(cid).?.status = .completed;
    gs.force(co).?.location_planet = "galatea";
    try std.testing.expect(posture.companyPosture(&gs, co) == .idle_afield);
    const afield = digest.stateHash(&gs);
    try std.testing.expectError(error.ArtilleryCompanyAfield, commands.execute(&gs, request));
    try std.testing.expectEqual(afield, digest.stateHash(&gs));
    gs.force(co).?.location_planet = null;
    try toe.assignCompanyToHq(&gs, co, other);
    const elsewhere = digest.stateHash(&gs);
    try std.testing.expectError(error.ArtilleryWrongHq, commands.execute(&gs, request));
    try std.testing.expectEqual(elsewhere, digest.stateHash(&gs));
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
    @setEvalBranchQuota(200_000);
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
    // The digest pins quality, armor, empty crew/tech, canonical condition and
    // magazines, service checkpoint and acquisition/transport history together
    // (docs/p2-artillery-operations-design.md,
    // Acquisition, placement, sale and defaults).
    try std.testing.expectEqual(@as(u64, 2107009959650156614), digest.stateHash(&gs));
}

fn validatePlacement(gs: *GameState, f: dom.Formation) error{CorruptSave}!void {
    switch (f.placement) {
        .hq_pool => |id| if (id == .none or !gs.hqs.contains(id)) return error.CorruptSave,
        .company => |co| {
            const c = gs.forces.getPtr(co) orelse return error.CorruptSave;
            if (c.echelon != .company or !gs.hqs.contains(gs.homeHqFor(co)) or committedCount(gs, co) > dom.company_formation_cap) return error.CorruptSave;
        },
        .freight => |t| {
            const a = gs.hqs.getPtr(t.from_hq) orelse return error.CorruptSave;
            const b = gs.hqs.getPtr(t.to_hq) orelse return error.CorruptSave;
            if (t.from_hq == t.to_hq or planet.find(a.planet_key) == null or planet.find(b.planet_key) == null) return error.CorruptSave;
            try validateJourney(gs, f, t.dispatch_day, t.eta_day, t.paid_cost);
        },
        .field_freight => |t| {
            const a = gs.hqs.getPtr(t.from_hq) orelse return error.CorruptSave;
            const c = gs.forces.getPtr(t.company) orelse return error.CorruptSave;
            if (planet.find(a.planet_key) == null or c.echelon != .company or committedCount(gs, t.company) > dom.company_formation_cap) return error.CorruptSave;
            try validateJourney(gs, f, t.dispatch_day, t.eta_day, t.paid_cost);
        },
        .field_return => |t| {
            const b = gs.hqs.getPtr(t.to_hq) orelse return error.CorruptSave;
            if (planet.find(b.planet_key) == null) return error.CorruptSave;
            try validateJourney(gs, f, t.dispatch_day, t.eta_day, t.paid_cost);
        },
        .sold, .destroyed => {},
    }
}

/// Every freight leg left after acquisition, no later than today, arrives after
/// it left and paid a nonnegative charge.
fn validateJourney(gs: *const GameState, f: dom.Formation, dispatch_day: u32, eta_day: u32, paid_cost: types.CBills) error{CorruptSave}!void {
    if (dispatch_day < f.acquisition_day or dispatch_day > gs.clock.day_index or eta_day <= dispatch_day or paid_cost < 0) return error.CorruptSave;
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
    if (f.placement == .destroyed) {
        if (count != 1 or previous.?.isOpen() or f.armor_pct != 0 or f.tech != .none or operations.hasJob(gs, f.id) or f.slots[@intFromEnum(operation_rules.Slot.chassis)].condition != .destroyed) return error.CorruptSave;
        for (f.crew) |id| if (id != .none) return error.CorruptSave;
        for (f.slots) |slot| if (slot.rounds != 0) return error.CorruptSave;
        return;
    }
    if (!previous.?.isOpen()) return error.CorruptSave;
    if (f.placement == .sold) {
        if (count != 2 or previous.?.acquisition_type != .transfer or !std.mem.eql(u8, previous.?.prior_owner_key, "player")) return error.CorruptSave;
    } else if (count != 1) return error.CorruptSave;
}

fn validateResult(gs: *GameState, r: *const @import("../domain/battle_report.zig").BattleReport, a: *const @import("../domain/battle_report.zig").ArtilleryResult) error{CorruptSave}!void {
    const combat = @import("../domain/artillery_combat.zig");
    const f = gs.artillery_formations.getPtr(a.formation) orelse return error.CorruptSave;
    if (a.formation == .none or @intFromEnum(a.formation) >= gs.next_artillery_formation_id or a.hull != f.hull or a.hull == .none or @intFromEnum(a.hull) >= gs.next_hull_instance_id or !std.mem.eql(u8, a.catalogue_key, carrier().key) or !std.mem.eql(u8, a.catalogue_name, carrier().name) or a.armor_before > dom.intact_condition_pct or a.armor_after > a.armor_before or a.compensation_basis < 0 or a.compensation_basis > f.paid_price) return error.CorruptSave;
    try operation_rules.validateSlots(&a.slots_before);
    try operation_rules.validateSlots(&a.slots_after);
    if (!std.meta.eql(combat.loadedRounds(&a.slots_before), a.rounds_before) or !std.meta.eql(combat.loadedRounds(&a.slots_after), a.rounds_after)) return error.CorruptSave;
    for (a.rounds_before, a.rounds_after, a.fired_rounds, a.lost_rounds) |before, after, fired, lost| {
        if (@as(u32, after) + fired + lost != before) return error.CorruptSave;
    }
    const fired = a.fire != .not_fired;
    if ((a.target != null) != fired or (a.accuracy_roll != null) != fired or (a.carrier_power != null) != fired or (a.no_fire == .none) != fired or a.fired_rounds[0] != @as(u16, @intFromBool(fired)) or a.fired_rounds[1] > 4) return error.CorruptSave;
    if (r.conceded and a.no_fire != .no_line_units) return error.CorruptSave;
    switch (a.no_fire) {
        .none => {},
        .not_present => if (a.physical_participation or a.readiness != .not_present) return error.CorruptSave,
        .not_ready => if (!a.physical_participation or a.readiness == null) return error.CorruptSave,
        .no_line_units => if (!r.conceded) return error.CorruptSave,
        .enemy_forfeit => if (r.conceded or r.outcome != .victory or r.scenario.len != 0 or r.hulls.len != 0 or r.enemy_destroyed_bv != 0) return error.CorruptSave,
        .zero_enemy_power => if (!a.physical_participation or a.readiness != null or a.enemy_power_before != 0) return error.CorruptSave,
    }
    if (fired) {
        if (!a.physical_participation or a.readiness != null or a.target.? < combat.minimum_target or a.target.? > combat.maximum_target or a.accuracy_roll.? < combat.minimum_target or a.accuracy_roll.? > combat.maximum_target or a.carrier_power.? < 0 or a.enemy_power_before == null or a.enemy_power_after == null or a.enemy_power_before.? <= 0) return error.CorruptSave;
        if ((a.fire == .hit) != (a.accuracy_roll.? >= a.target.?)) return error.CorruptSave;
        if (a.suppressed_power != (if (a.fire == .hit) combat.suppressedPower(a.enemy_power_before.?, a.carrier_power.?) else 0)) return error.CorruptSave;
    } else if (a.suppressed_power != 0) return error.CorruptSave;
    if ((a.enemy_power_before != null) != (a.enemy_power_after != null)) return error.CorruptSave;
    if (a.enemy_power_before) |power| if (power < 0 or a.enemy_power_after.? != power - a.suppressed_power or a.enemy_power_after.? != r.enemy_power) return error.CorruptSave;
    const no_fight = r.conceded or a.no_fire == .enemy_forfeit;
    if (no_fight and (fired or a.severity != null or a.exposure_percent != null or a.damage != .not_exposed or a.recovery != null or a.compensation_basis != 0 or a.fired_rounds[1] != 0)) return error.CorruptSave;
    if (!a.physical_participation and (a.damage != .not_exposed or a.exposure_percent != null or a.fired_rounds[1] != 0)) return error.CorruptSave;
    if (a.exposure_percent) |pct| {
        if (pct > combat.percent_scale or (a.exposure_roll != null) != (pct > 0)) return error.CorruptSave;
        if (a.exposure_roll) |roll| if (roll >= combat.percent_scale or (a.severity != null) != (roll < pct)) return error.CorruptSave;
    } else if (a.exposure_roll != null or a.severity != null) return error.CorruptSave;
    if (a.severity) |severity| if (severity < combat.minimum_target or severity > combat.maximum_target or (a.struck_slot != null) != (severity >= @import("../domain/tuning.zig").t.battle.slot_hit_severity)) return error.CorruptSave;
    if (a.severity == null and (a.struck_slot != null or a.struck_seat != null or a.newly_wrecked)) return error.CorruptSave;
    try validateCapturedDamage(r, a, no_fight);
    try validateCapturedCrew(gs, r, a, fired);
    if (a.recovery != null and (r.held_field or (a.damage != .recovered and a.damage != .scuttled))) return error.CorruptSave;
    if (a.recovery) |recovery_roll| if (recovery_roll.target != tuning.loss.recovery_target) return error.CorruptSave;
    if (a.damage == .recovered and (a.recovery == null or a.recovery.?.roll < a.recovery.?.target)) return error.CorruptSave;
    if (a.damage == .scuttled and (a.recovery == null or a.recovery.?.roll >= a.recovery.?.target or a.cause != .scrap)) return error.CorruptSave;
    if (a.damage == .permanently_destroyed and a.cause != .ammo) return error.CorruptSave;
    const terminal = a.damage == .permanently_destroyed or a.damage == .scuttled;
    if (terminal or a.damage == .recoverable or a.damage == .recovered) {
        if (a.armor_after != 0 or a.slots_after[@intFromEnum(operation_rules.Slot.chassis)].condition != .destroyed) return error.CorruptSave;
    }
    if (terminal) for (a.rounds_after) |rounds| if (rounds != 0) return error.CorruptSave;
    if (a.compensation_basis != combat.damageValue(f.paid_price, a.severity orelse 0, a.newly_wrecked, terminal)) return error.CorruptSave;
    var history: usize = 0;
    for (gs.hull_combat_records.items) |entry| if (entry.hull_instance_id == a.hull and entry.battle_id == r.id) {
        history += 1;
    };
    if (history != @intFromBool(a.physical_participation and !no_fight)) return error.CorruptSave;
}

/// Captured fate determines XP and evacuation evidence independently of later
/// personnel status. Source: artillery combat design, Recovery and rewards.
fn validateCapturedCrew(gs: *GameState, r: *const battle_report.BattleReport, a: *const battle_report.ArtilleryResult, fired: bool) error{CorruptSave}!void {
    const terminal = a.damage == .permanently_destroyed or a.damage == .scuttled;
    var present: usize = 0;
    for (a.seats, operation_rules.seats, 0..) |seat, identity, index| {
        if (seat.seat != identity) return error.CorruptSave;
        if (seat.person == .none) {
            if (seat.name.len != 0 or seat.present or !seat.outcome.untouched() or seat.escape != null or seat.xp_participation) return error.CorruptSave;
        } else {
            if (@intFromEnum(seat.person) >= gs.next_person_id or gs.person(seat.person) == null or seat.name.len == 0) return error.CorruptSave;
            for (a.seats[0..index]) |other| if (other.person == seat.person) return error.CorruptSave;
        }
        present += @intFromBool(seat.present);
        if (seat.present and !a.physical_participation) return error.CorruptSave;
        const survivor = seat.present and seat.outcome.fate != .kia;
        if (seat.xp_participation != (fired and survivor and seat.outcome.fate != .missing)) return error.CorruptSave;
        if ((seat.escape != null) != (survivor and !r.held_field and terminal)) return error.CorruptSave;
        if (seat.outcome.fate == .missing and (seat.escape == null or seat.escape.?.roll >= seat.escape.?.target)) return error.CorruptSave;
        if (seat.outcome.wound) |w| if (w.severity < 1 or w.severity > 3 or a.struck_seat != identity) return error.CorruptSave;
        if (seat.outcome.fate == .kia and a.struck_seat != identity) return error.CorruptSave;
        if (!seat.outcome.untouched() and !seat.present) return error.CorruptSave;
        if (seat.escape) |escape| {
            if (escape.target != tuning.loss.escape_target or (seat.outcome.fate == .missing) != (escape.roll < escape.target)) return error.CorruptSave;
        }
    }
    if (a.severity != null and (a.struck_seat != null) != (present > 0)) return error.CorruptSave;
    if (a.struck_seat) |seat| if (!a.seats[@intFromEnum(seat)].present) return error.CorruptSave;
}

/// Replay only captured ammunition and damage facts, never mutable live condition.
/// Readiness and random choice are recorded inputs; the pure damage owner checks
/// their deterministic consequence, including canonical spending and terminal loss.
fn validateCapturedDamage(r: *const battle_report.BattleReport, a: *const battle_report.ArtilleryResult, no_fight: bool) error{CorruptSave}!void {
    var slots = a.slots_before;
    if (a.fire != .not_fired and combat_rules.spendRound(&slots, .long_tom) == null) return error.CorruptSave;
    if (a.fired_rounds[1] > 0 and combat_rules.defensiveFire(&slots, combat_rules.exposure_divisor) != a.fired_rounds[1]) return error.CorruptSave;
    const was_wrecked = a.armor_before == 0 and slots[@intFromEnum(operation_rules.Slot.chassis)].condition == .destroyed;
    var armor = a.armor_before;
    var expected_damage: combat_rules.DamageOutcome = .not_exposed;
    var expected_cause: unit.WreckCause = .none;
    var newly_wrecked = false;
    if (a.physical_participation and !no_fight) {
        if (a.exposure_percent == null) return error.CorruptSave;
        expected_damage = if (was_wrecked) .recoverable else .unhit;
        if (a.severity) |severity| {
            const hit = combat_rules.carrierHit(armor, slots, severity, a.struck_slot);
            armor = hit.armor_pct;
            slots = hit.slots;
            newly_wrecked = hit.wrecked and !was_wrecked;
            expected_cause = hit.cause;
            expected_damage = if (hit.terminal) .permanently_destroyed else if (hit.wrecked) .recoverable else .damaged;
        }
        if (expected_damage == .recoverable and !r.held_field) {
            const recovery_roll = a.recovery orelse return error.CorruptSave;
            expected_damage = if (recovery_roll.roll >= recovery_roll.target) .recovered else .scuttled;
            if (expected_damage == .scuttled) expected_cause = .scrap;
        } else if (a.recovery != null) return error.CorruptSave;
        if (expected_damage == .permanently_destroyed or expected_damage == .scuttled) {
            armor = 0;
            slots[@intFromEnum(operation_rules.Slot.chassis)].condition = .destroyed;
            for (&slots) |*slot| slot.rounds = 0;
        }
    }
    if (a.damage != expected_damage or a.cause != expected_cause or a.newly_wrecked != newly_wrecked or a.armor_after != armor or !std.meta.eql(a.slots_after, slots)) return error.CorruptSave;
}

test "artillery reports reject invented armor slot and casualty changes without a hit" {
    const battle_artillery = @import("artillery_battle.zig");
    const reports = @import("../domain/battle_report.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const id = try operations.fixtureForTest(&gs, true);
    const f = gs.artillery_formations.get(id).?;
    const c: @import("../domain/contract.zig").Contract = .{ .id = @enumFromInt(1), .kind = .recon_raid, .employer_key = "LC", .enemy_key = "DC", .planet_key = gs.seatPlanetKey().?, .assigned_company = f.placement.company, .terms = .{ .length_months = 6, .base_pay_month = 400_000 } };
    var a = (try battle_artillery.snapshot(&gs, &c, .not_ready)).?;
    a.damage = .unhit;
    a.exposure_percent = 0;
    const r: reports.BattleReport = .{ .id = @enumFromInt(1), .day = 0, .contract = c.id, .company = c.assigned_company, .kind = "recon_raid", .enemy_key = "DC", .scenario = "", .terrain = "", .weather = "", .outcome = .victory, .held_field = true };
    try battle_artillery.recordHistory(&gs, a, r.id, r.contract);
    try validateResult(&gs, &r, &a);
    var bad = a;
    bad.armor_after -= 1;
    try std.testing.expectError(error.CorruptSave, validateResult(&gs, &r, &bad));
    bad = a;
    bad.slots_after[@intFromEnum(operation_rules.Slot.main_gun)].condition = .damaged;
    try std.testing.expectError(error.CorruptSave, validateResult(&gs, &r, &bad));
    bad = a;
    bad.seats[0].outcome.fate = .kia;
    try std.testing.expectError(error.CorruptSave, validateResult(&gs, &r, &bad));
}
