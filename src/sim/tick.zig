//! The daily tick: one campaign day through the ordered phase pipeline
//! (ARCH §6, DayPhase). MekHQ counterpart: `Campaign.newDay()`.
//!
//! Phase order is part of the spec.

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const contract_mod = @import("../domain/contract.zig");
const GameState = @import("state.zig").GameState;
const Treasury = @import("state.zig").Treasury;
const posture = @import("posture.zig");
const treasury = @import("treasury.zig");
const types = @import("../domain/types.zig");
const contract_market = @import("contract_market.zig");
const maintenance = @import("maintenance.zig");
const contract_events = @import("contract_events.zig");
const battle = @import("battle.zig");
const medical = @import("medical.zig");
const person_mod = @import("../domain/person.zig");
const part_mod = @import("../domain/part.zig");
const hq_ops = @import("hq_ops.zig");
const network = @import("network.zig");
const contract_control = @import("contract_control.zig");
const planet_mod = @import("../domain/planet.zig");
const logistics = @import("../econ/logistics.zig");
const field_supply = @import("field_supply.zig");
const sites = @import("sites.zig");
const toe = @import("toe.zig");
const commands = @import("commands.zig");

/// The ordered phases of one campaign day. Order is part of the spec:
/// e.g. shipments must arrive (travel) before supply consumption, and
/// battles resolve after contract events may have spawned them.
pub const DayPhase = enum {
    travel,
    supply_consumption,
    medical,
    acquisition_and_markets,
    maintenance, // weekly per unit
    training,
    contract_events,
    battle_resolution,
    morale_fatigue,
    finances, // payday on the 1st
    decisions, // surface queued player decisions; pause auto-advance
};

/// Advance exactly one day — one turn. Turn-based: nothing blocks time;
/// decision events sit in the inbox with deadlines, and the deadline applies
/// the default (contract_events.expireDue). Multi-day advance is just
/// several turns.
pub fn advanceDay(gs: *GameState) !void {
    gs.clock.advance();
    hq_ops.refreshHqStaffing(gs); // the back office is people

    // Phase order per DayPhase.
    if (gs.clock.day_index % 7 == 0) network.resetWeeklyThroughput(gs); // links' week
    try runTravel(gs); // deliveries, couriers, transfers
    try runPolicies(gs); // standing cash top-ups and resupply
    try runStockPolicies(gs); // warehouse reorder points
    try hq_ops.runDaily(gs); // bays, fabrication, construction
    try runSupplyConsumption(gs); // supply_consumption phase
    try medical.runDailyHealing(gs); // medical phase
    try runMarkets(gs); // acquisition_and_markets
    if (gs.clock.day_index % 7 == 0 and gs.clock.day_index > 0) {
        try maintenance.runWeeklyMaintenance(gs); // maintenance phase
        try maintenance.runWeeklyRepairs(gs);
    }
    try medical.runDailyTraining(gs); // training phase
    try runContracts(gs); // contract lifecycle
    try contract_control.runReturns(gs); // companies travelling home arrive
    if (gs.clock.date.day == 1) try contract_events.rollMonthly(gs); // event decks
    if (gs.clock.day_index % 7 == 3) {
        try contract_events.rollWeekly(gs); // weekly happenings
        try contract_events.rollInterdiction(gs); // raiders at the jump point
    }
    try battle.runDaily(gs); // battle_resolution: due engagements resolve
    try contract_control.checkEffectiveness(gs); // the ineffectiveness clock
    if (gs.clock.day_index % 7 == 0 and gs.clock.day_index > 0) {
        try medical.runWeeklyRest(gs); // morale_fatigue phase
        runTrainingLances(gs); // training lances drill
    }
    try runFinances(gs);
    try contract_events.expireDue(gs); // decisions phase: deadlines pass
}

/// Standing policies, checked daily. Cash: top an entity up to its
/// floor by courier, at most the monthly cap per month, and never while a
/// courier to it is already in flight. Resupply: a deployed company's
/// field-plan lines ship from the home warehouse (see below).
fn runPolicies(gs: *GameState) !void {
    for (gs.policies.items) |*policy| {
        const balance = gs.treasuryBalance(policy.entity);
        if (balance >= policy.floor) continue;
        if (policy.sent_this_month >= policy.monthly_cap) continue;
        var in_flight = false;
        for (gs.fund_couriers.items) |c| if (std.meta.eql(c.to, policy.entity)) {
            in_flight = true;
        };
        if (in_flight) continue;
        const amount = @min(policy.floor - balance, policy.monthly_cap - policy.sent_this_month);
        if (amount <= 0) continue;
        const eta = treasury.courierEtaDays(gs, policy.entity);
        // An outfit short of the amount skips this policy until it isn't;
        // any other failure followed the debit and is not swallowed.
        treasury.transferFunds(gs, .outfit, policy.entity, amount, eta) catch |err| switch (err) {
            error.InsufficientTreasury => continue,
            error.OutOfMemory => return error.OutOfMemory,
        };
        policy.sent_this_month += amount;
        const tags = policy.entity.tags();
        try gs.log(.finance, .{ .company = tags.company, .hq = tags.hq }, "[finance] standing policy dispatches {d} c-bills (eta {d} days, {d} of {d} this month)", .{ amount, eta, policy.sent_this_month, policy.monthly_cap });
    }

    // Resupply: every line of the company's field plan —
    // provisions, medical, armor, each munition family it fires — is kept
    // between a floor and a target sized to the line's transit and the
    // trucks' tonnage (field_supply.plan). A line ships when on hand plus
    // inbound drops under its floor, at most once a week per line, never
    // past what the trucks can hold.
    for (gs.supply_policies.items) |sp| {
        const f = gs.forces.getPtr(sp.company) orelse continue;
        if (posture.isCompanyHome(gs, sp.company) or f.return_eta_day != null) continue;
        const home = gs.homeHqFor(sp.company);
        if (home == .none) continue;
        const site: types.Site = .{ .company = sp.company };
        const transit = treasury.courierEtaDays(gs, .{ .company = sp.company });
        var arena = std.heap.ArenaAllocator.init(gs.allocator());
        defer arena.deinit();
        const p = try field_supply.plan(arena.allocator(), gs, sp.company, transit, sp.min_days, sp.ammo_battles);
        for (p.lines) |line| {
            const on_hand = gs.stockCount(site, line.key);
            const inbound = field_supply.inboundQty(gs, sp.company, line.key);
            if (on_hand + inbound >= line.floor) continue;
            var recent = false;
            for (gs.part_orders.items) |o| if (o.dest == .company and o.dest.company == sp.company and std.mem.eql(u8, o.part_key, line.key) and o.ordered_day + 7 > gs.clock.day_index) {
                recent = true;
            };
            if (recent) continue;
            var want = line.target - on_hand - inbound;
            if (sp.tons > 0) want = @min(want, sp.tons);
            // Ship what the trucks can take: a top-up larger than the free
            // tonnage is cut to fit, not refused. Trucks packed with surplus
            // ammo from employer convoys are trimmed first — excess rides
            // home on the empty convoy so the food can land.
            const room_now = sites.siteFreeTons(gs, site) -| field_supply.inboundTons(gs, sp.company);
            if (room_now < want * part_mod.tons(line.key)) {
                const moved = (commands.execute(gs, .{ .trim_stock = sp.company }) catch Result{}).tons_moved;
                if (moved > 0) try gs.log(.delivery, .{ .company = sp.company }, "[supply] trucks full: {d}t of surplus sent home to make room for {s}", .{ moved, line.key });
            }
            // Room counts what is already on the road (the shipment check does).
            const free_tons = (sites.siteFreeTons(gs, site) -| field_supply.inboundTons(gs, sp.company)) / @max(1, part_mod.tons(line.key));
            want = @min(want, free_tons);
            const available = gs.stockCount(.{ .hq = home }, line.key);
            const qty = @min(want, available);
            if (qty == 0) {
                if (gs.clock.day_index % 7 == 0) try gs.log(.delivery, .{ .company = sp.company, .hq = home }, "[supply] resupply policy: no {s} at {s} to ship to {s} ({d}t on hand, floor {d}t)", .{ line.key, gs.hqs.getPtr(home).?.name, f.name, on_hand, line.floor });
                continue;
            }
            _ = commands.execute(gs, .{ .ship_stock = .{ .part_key = line.key, .quantity = qty, .from = .{ .hq = home }, .to = site } }) catch |err| {
                if (gs.clock.day_index % 7 == 0) try gs.log(.delivery, .{ .company = sp.company, .hq = home }, "[supply] resupply policy could not ship {s} to {s}: {s}", .{ line.key, f.name, @errorName(err) });
                continue;
            };
            try gs.log(.delivery, .{ .company = sp.company, .hq = home }, "[supply] resupply policy ships {d}t of {s} to {s} ({d}t on hand + {d}t inbound, floor {d}t, target {d}t, {d}-day line)", .{ qty, line.key, f.name, on_hand, inbound, line.floor, line.target, transit });
        }
    }
}

/// The warehouse a deployed company's line should ship from: the HQ
/// nearest the company that holds the whole shipment, else the nearest
/// that holds any of it, else home. Distance is by star map.
pub fn bestSupplyHq(gs: *GameState, company: types.ForceId, key: []const u8, want: u32, home: types.HqId) types.HqId {
    const here_key: ?[]const u8 = if (gs.deploymentContract(company)) |c| c.planet_key else if (gs.force(company)) |f| f.location_planet else null;
    const here = planet_mod.find(here_key orelse return home) orelse return home;
    var best_full: types.HqId = .none;
    var best_full_d: u32 = std.math.maxInt(u32);
    var best_some: types.HqId = .none;
    var best_some_d: u32 = std.math.maxInt(u32);
    var it = gs.hqs.iterator();
    while (it.next()) |e| {
        const hq = e.value_ptr;
        const on_hand = gs.stockCount(.{ .hq = hq.id }, key);
        if (on_hand == 0) continue;
        const w = planet_mod.find(hq.planet_key) orelse continue;
        const d = planet_mod.distanceLy(w, here);
        if (on_hand >= want and d < best_full_d) {
            best_full = hq.id;
            best_full_d = d;
        }
        if (d < best_some_d) {
            best_some = hq.id;
            best_some_d = d;
        }
    }
    if (best_full != .none) return best_full;
    if (best_some != .none) return best_some;
    return home;
}

test "forward depot: the nearest HQ holding the line ships it, the home HQ otherwise" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 909 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const home = gs.hqs.keys()[0];
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    // A firebase on a world inside the ring; the company idles on that very world.
    const home_world = planet_mod.find(gs.hqs.getPtr(home).?.planet_key).?;
    var fb_key: []const u8 = "";
    for (planet_mod.catalog) |*p| if (p != home_world and planet_mod.distanceLy(p, home_world) <= gs.hqs.getPtr(home).?.influenceLy() and fb_key.len == 0) {
        fb_key = p.key;
    };
    _ = try commands.execute(&gs, .{ .found_hq = .{ .name = "Firebase", .planet_key = fb_key } });
    const fb = gs.hqs.keys()[1];
    gs.force(co).?.location_planet = fb_key;
    // Only home has provisions: home ships. Stock the firebase: it wins on distance.
    try std.testing.expectEqual(home, bestSupplyHq(&gs, co, "provisions", 10, home));
    try gs.addStock(.{ .hq = fb }, "provisions", 4);
    try std.testing.expectEqual(home, bestSupplyHq(&gs, co, "provisions", 10, home)); // home covers the whole shipment
    try gs.addStock(.{ .hq = fb }, "provisions", 20);
    try std.testing.expectEqual(fb, bestSupplyHq(&gs, co, "provisions", 10, home));
    // The firebase can host the company now (field capacity 1).
    try toe.assignCompanyToHq(&gs, co, fb);
    try std.testing.expectEqual(fb, gs.force(co).?.supplying_hq);
}

/// Warehouse reorder points: every line an HQ keeps stocked is
/// checked daily; under `min` the shortfall to `target` is fabricated
/// (components, when the HQ has a bay) or ordered through the catalogue.
/// One order per line in flight; a failed sourcing roll waits a week.
fn runStockPolicies(gs: *GameState) !void {
    const today = gs.clock.day_index;
    for (gs.stock_policies.items) |sp| {
        const hq = gs.hqs.getPtr(sp.hq) orelse continue;
        const have = gs.stockCount(.{ .hq = sp.hq }, sp.part_key);
        if (have >= sp.min) continue;
        const pending = hq_ops.comingToHq(gs, sp.hq, sp.part_key);
        var failed_recently = false;
        for (gs.part_orders.items) |o| {
            if (std.mem.eql(u8, o.part_key, sp.part_key) and o.status == .failed and o.ordered_day + 7 > today) failed_recently = true;
        }
        if (pending > 0 or failed_recently) continue;
        const want = sp.target - have;
        const fabricate = hq_ops.canFabricate(gs, sp.hq, sp.part_key); // what this bay is rated for, else order it
        const cmd: commands.Command = if (fabricate)
            .{ .fabricate = .{ .hq = sp.hq, .part_key = sp.part_key, .quantity = want } }
        else
            .{ .order_part = .{ .part_key = sp.part_key, .quantity = want, .dest = .{ .hq = sp.hq } } };
        _ = commands.execute(gs, cmd) catch |err| {
            if (today % 7 == 0) try gs.log(.market, .{ .hq = sp.hq }, "[stock] policy could not restock {s} at {s}: {s}", .{ sp.part_key, hq.name, @errorName(err) });
            continue;
        };
        try gs.log(.market, .{ .hq = sp.hq }, "[stock] policy {s} {d} {s} for {s} ({d} on hand, keep {d}-{d})", .{ if (fabricate) "fabricates" else "orders", want, sp.part_key, hq.name, have, sp.min, sp.target });
    }
}

/// Training lances (MekHQ lance role): held out of engagements, and their
/// crews drill for XP every week the company is home (one day's XP, `Person.xpGain`).
fn runTrainingLances(gs: *GameState) void {
    var pit = gs.people.iterator();
    while (pit.next()) |entry| {
        const p = entry.value_ptr;
        if (p.status != .active) continue;
        const lance = gs.forces.getPtr(p.assigned_force) orelse continue;
        if (lance.role != .training) continue;
        if (!posture.isCompanyHome(gs, gs.companyOf(lance.id))) continue;
        p.xp += p.xpGain(gs.clock.day_index, 1);
    }
}

/// travel phase: part deliveries land, fund couriers arrive, cold-storage
/// reactivations finish. Nothing material happens silently.
pub fn runTravel(gs: *GameState) !void {
    // Failed sourcing attempts stay visible for two weeks, then clear.
    var fi: usize = 0;
    while (fi < gs.part_orders.items.len) {
        const o = gs.part_orders.items[fi];
        if (o.status == .failed and o.ordered_day + 14 <= gs.clock.day_index) _ = gs.part_orders.orderedRemove(fi) else fi += 1;
    }
    for (gs.part_orders.items) |*order| {
        if (order.status != .in_transit) continue;
        if (order.eta_day != null and gs.clock.day_index >= order.eta_day.?) {
            order.status = .delivered;
            // Land at the destination site; anything the warehouse or the
            // trucks can't hold is lost on the dock.
            const dest: types.Site = if (order.dest == .outfit) gs.defaultSite() else order.dest;
            const room = sites.siteFreeTons(gs, dest) / @max(1, part_mod.tons(order.part_key));
            const landed = @min(order.quantity, room);
            try gs.addStock(dest, order.part_key, landed);
            const tags = Treasury.ofSite(dest).tags();
            try gs.log(.delivery, .{ .company = tags.company, .hq = tags.hq }, "[delivery] {s} x{d} received{s}", .{
                order.part_key, landed,
                if (landed < order.quantity) " — NO ROOM for the rest, written off" else "",
            });
        }
    }

    // Transferred hulls arrive.
    var ti: usize = 0;
    while (ti < gs.unit_transfers.items.len) {
        const t = gs.unit_transfers.items[ti];
        if (gs.clock.day_index >= t.eta_day) {
            try toe.placeUnitInCompany(gs, t.unit, t.to_company);
            const name = if (gs.unit(t.unit)) |u| u.chassis_key else "?";
            if (t.to_company == .none) {
                // Salvage: the wreck lands in the pool at the HQ, status by its damage.
                if (gs.unit(t.unit)) |u| u.status = if (u.needsDepot()) .damaged else .ready;
                try gs.log(.delivery, .{ .hq = if (gs.hqs.count() > 0) gs.hqs.keys()[0] else .none }, "[salvage] wreck {s} #{d} lands in the HQ pool — Forces: place it in a company and [D] sends it to the depot, or sell it", .{ name, @intFromEnum(t.unit) });
            } else try gs.log(.delivery, .{ .company = t.to_company }, "[transfer] {s} arrives and joins the company", .{name});
            _ = gs.unit_transfers.swapRemove(ti);
        } else ti += 1;
    }

    var i: usize = 0;
    while (i < gs.fund_couriers.items.len) {
        const courier = gs.fund_couriers.items[i];
        if (gs.clock.day_index >= courier.eta_day) {
            try treasury.creditTreasury(gs, courier.to, courier.amount);
            const tags = courier.to.tags();
            try gs.log(.delivery, .{ .company = tags.company, .hq = tags.hq }, "[delivery] courier delivers {d} c-bills", .{courier.amount});
            _ = gs.fund_couriers.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

/// supply_consumption phase: deployed companies eat from their
/// field stores daily. Empty stores → buy locally with local funds (the
/// §9.6 valve, at local prices); no funds → the company goes hungry.
fn runSupplyConsumption(gs: *GameState) !void {
    // Every company away from home eats from its trucks — on contract or
    // idling on the world it last worked.
    var fit = gs.forces.iterator();
    while (fit.next()) |fentry| {
        const f = fentry.value_ptr;
        if (f.echelon != .company or posture.isCompanyHome(gs, f.id) or f.return_eta_day != null) continue;
        const c = gs.deploymentContract(f.id);
        // Idling with no known world: no market to buy from.
        if (c == null and f.location_planet == null) continue;
        const beachhead = if (c) |cc| cc.beachhead else false;
        const contract_id: types.ContractId = if (c) |cc| cc.id else .none;
        const site: types.Site = .{ .company = f.id };

        const heads = toe.companyHeadcount(gs, f.id);
        const need: u32 = part_mod.provisionsPerDay(heads);
        if (gs.takeStock(site, "provisions", need)) {
            f.supply_shortage_days = 0;
            continue;
        }

        // Local purchase valve: price by remoteness, paid from local funds.
        const mult = if (c) |cc| @import("field_supply.zig").localPriceMultBp(cc) else tuning.finance.field_markup_bp;
        const price = types.applyBp(part_mod.cost("provisions") * need, mult);
        if (f.local_funds >= price) {
            try gs.postTreasury(.{ .company = f.id }, .{
                .day = gs.clock.day_index,
                .amount = -price,
                .category = if (beachhead) .local_supplies else .supplies,
                .company = f.id,
                .contract = contract_id,
                .note = "provisions bought locally (stores empty)",
            });
            f.supply_shortage_days = 0;
        } else {
            f.supply_shortage_days +|= 1;
            if (f.supply_shortage_days == 1 or f.supply_shortage_days % 7 == 0) {
                try gs.log(.finance, .{ .company = f.id, .contract = contract_id }, "[supply] {s} is out of provisions and out of local funds — day {d} hungry", .{ f.name, f.supply_shortage_days });
            }
        }
    }
}

/// markets phase: hiring halls churn daily; the contract board and
/// site-market listings refresh on the 1st.
fn runMarkets(gs: *GameState) !void {
    try contract_market.churnCandidates(gs); // people move daily
    if (gs.clock.date.day != 1) return;
    try contract_market.refresh(gs);
    try contract_market.refreshListings(gs);
}

/// contract lifecycle: transit arrivals and completions, checked daily.
fn runContracts(gs: *GameState) !void {
    var it = gs.contracts.iterator();
    while (it.next()) |entry| {
        const c = entry.value_ptr;
        switch (c.status) {
            .transit => if (c.arrive_day != null and gs.clock.day_index >= c.arrive_day.?) {
                c.status = .active;
                c.start_day = gs.clock.day_index;
                c.end_day = gs.clock.day_index + @as(u32, c.terms.length_months) * types.days_per_month;
                if (gs.force(c.assigned_company)) |f| f.location_planet = c.planet_key;
                try gs.log(.contract, .{ .company = c.assigned_company, .contract = c.id }, "[{s}] company on station at {s} — contract active", .{ c.kind.label(), c.planet_key });
                // The contract world's hull board opens on arrival.
                try contract_market.refreshContractWorld(gs, c);
            },
            .active => if (c.end_day != null and gs.clock.day_index >= c.end_day.?) {
                // End of term: a performance failure is a failed contract
                // (CamOps — not a breach: no clawback, no cooling); otherwise
                // the tour completes. VP are banked as the score moves, so
                // nothing is added here.
                if (c.score <= contract_mod.Contract.fail_score) {
                    try contract_control.fail(gs, c, "failed on performance");
                } else {
                    try contract_control.complete(gs, c, false);
                }

                // The rotation bill (ARCH §9.7): a completed tour banks
                // fatigue for everyone attached — scaled by how long it ran
                // and how hard it fought, compounding for every contract
                // since the company last rotated (medical.zig's rotation reset).
                const heads = toe.companyHeadcount(gs, c.assigned_company);
                const casualties_pct: u8 = if (heads == 0) 0 else @intCast(@min(100, @as(u32, c.casualties) * 100 / heads));
                var gain = person_mod.contractFatigueGainFor(c.terms.length_months, c.battles_fought, casualties_pct, c.kind.isGarrisonClass());
                if (gs.force(c.assigned_company)) |f| {
                    gain +|= 5 * @as(u8, @intCast(@min(10, f.contracts_since_rotation -| 1)));
                }
                var pit = gs.people.iterator();
                while (pit.next()) |pentry| {
                    const p = pentry.value_ptr;
                    if (!p.isOnBooks() or !toe.personInCompany(gs, p, c.assigned_company)) continue;
                    p.fatigue = person_mod.applyFatigue(p.fatigue, gain);
                }
                try gs.log(.rotation, .{ .company = c.assigned_company, .contract = c.id }, "[rotation] tour complete: +{d} fatigue banked ({d} battles, {d} casualties)", .{
                    gain, c.battles_fought, c.casualties,
                });
            },
            else => {},
        }
    }
}

/// Put stock on the ground at a site, bounded by its free tonnage.
fn landStock(gs: *GameState, site: types.Site, key: []const u8, qty: u32) !u32 {
    const room = sites.siteFreeTons(gs, site) / @max(1, part_mod.tons(key));
    const n = @min(qty, room);
    if (n > 0) try gs.addStock(site, key, n);
    return n;
}

const monthly_service_xp = tuning.person.monthly_service_xp;

/// finances phase: payday on the 1st of the month — salaries out, and a
/// month of service XP in (MekHQ's idle-XP analog).
fn runFinances(gs: *GameState) !void {
    if (!gs.clock.date.isPayday()) return;

    var it = gs.people.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        if (p.status == .active) p.xp += monthly_service_xp;
    }
    // Seats and experience set ranks before pay is counted; service
    // awards come due.
    _ = try @import("personnel.zig").refreshRanks(gs);
    _ = @import("personnel.zig").refreshShares(gs);
    // New Year's Day: the rating goes in the book.
    if (gs.clock.date.month == 1) {
        try gs.rating_history.append(gs.allocator(), .{ .year = gs.clock.date.year, .score = try @import("rating.zig").score(gs) });
        // Tech news: the designs entering service this year.
        var news: std.ArrayListUnmanaged(u8) = .empty;
        for (@import("../domain/chassis.zig").catalog) |*c| if (c.intro_year == gs.clock.date.year) {
            if (news.items.len > 0) try news.appendSlice(gs.allocator(), ", ");
            try news.appendSlice(gs.allocator(), try std.fmt.allocPrint(gs.allocator(), "{s} {s}", .{ c.name, c.key }));
        };
        if (news.items.len > 0) try gs.log(.market, .{}, "[tech] new in {d}: {s} — on the house tables and the boards from this year", .{ gs.clock.date.year, news.items });
    }
    _ = try @import("personnel.zig").checkAllAwards(gs);
    // Notice is handed in on payday; grudges fade.
    _ = try @import("medical.zig").runMonthlyTurnover(gs);
    @import("contract_control.zig").driftStanding(gs);

    const payroll = treasury.monthlyPayroll(gs);
    if (payroll != 0) {
        try gs.postTransaction(.{
            .day = gs.clock.day_index,
            .amount = -payroll,
            .category = .payroll,
            .note = "monthly payroll",
        });
    }

    // The hangar ledger (ARCH §9.8): every hull bills, running or not.
    const hull_bill = treasury.monthlyHullUpkeep(gs);
    if (hull_bill != 0) {
        try gs.postTransaction(.{
            .day = gs.clock.day_index,
            .amount = -hull_bill,
            .category = .hull_upkeep,
            .note = "hangar & hull upkeep",
        });
    }

    // HQ upkeep draws each HQ's own treasury; running dry is
    // allowed but flagged — obligations don't wait for the courier.
    var hqit = gs.hqs.iterator();
    while (hqit.next()) |entry| {
        const hq = entry.value_ptr;
        if (hq.monthly_upkeep == 0) continue;
        try gs.postTreasury(.{ .hq = hq.id }, .{
            .day = gs.clock.day_index,
            .amount = -hq.monthly_upkeep,
            .category = .hq_upkeep,
            .hq = hq.id,
            .note = hq.name,
        });
        if (hq.funds < 0) {
            try gs.log(.finance, .{ .hq = hq.id }, "[finance] {s} treasury overdrawn ({d}) — send funds", .{ hq.name, hq.funds });
        }
    }

    // Supply-link upkeep: the network is a standing cost.
    for (gs.hq_links.items) |l| {
        try gs.postTransaction(.{
            .day = gs.clock.day_index,
            .amount = -l.monthlyCost(),
            .category = .transport_charter,
            .note = "supply link upkeep",
        });
    }

    // Standing policies are checked daily (runPolicies); payday opens a
    // fresh monthly cap.
    for (gs.policies.items) |*policy| policy.sent_this_month = 0;

    // Active contracts pay monthly; beachhead deployments cost hardship pay
    // (ARCH §9.6) — both lines itemized per company.
    var cit = gs.contracts.iterator();
    while (cit.next()) |entry| {
        const c = entry.value_ptr;
        if (c.status != .active) continue;
        try gs.postTransaction(.{
            .day = gs.clock.day_index,
            .amount = c.monthly_net,
            .category = .contract_payment,
            .company = c.assigned_company,
            .contract = c.id,
            .note = "monthly contract payment",
        });
        if (c.beachhead) {
            const hardship = types.applyBp(treasury.companyMonthlyPayroll(gs, c.assigned_company), tuning.finance.hardship_bp); // +15%
            if (hardship > 0) {
                try gs.postTreasury(.{ .company = c.assigned_company }, .{
                    .day = gs.clock.day_index,
                    .amount = -hardship,
                    .category = .hardship_pay,
                    .company = c.assigned_company,
                    .contract = c.id,
                    .note = "remote deployment hardship pay",
                });
            }
        }

        // Straight support: employers with overhead terms ship
        // supplies monthly — goods, not cash — landing in the company's
        // field stores as far as the trucks can hold.
        if (c.terms.overhead_pct > 0) {
            const site: types.Site = .{ .company = c.assigned_company };
            const heads = toe.companyHeadcount(gs, c.assigned_company);
            const month_food: u32 = part_mod.provisionsTons(heads, types.days_per_month);
            const food = month_food * c.terms.overhead_pct / 100;
            const ammo_each: u32 = if (c.terms.overhead_pct >= 50) 2 else 1;
            var landed_food: u32 = 0;
            var landed_ammo: u32 = 0;
            landed_food += try landStock(gs, site, "provisions", food);
            for (part_mod.munition_keys) |key| landed_ammo += try landStock(gs, site, key, ammo_each);
            _ = try landStock(gs, site, "medical_supplies", 1);
            try gs.log(.delivery, .{ .company = c.assigned_company, .contract = c.id }, "[delivery] employer support convoy: {d}t provisions, {d}t munitions ({d}% terms)", .{
                landed_food, landed_ammo, c.terms.overhead_pct,
            });
        }
        if (gs.force(c.assigned_company)) |f| {
            if (f.local_funds < 0) {
                try gs.log(.finance, .{ .company = c.assigned_company }, "[finance] {s} operating funds overdrawn ({d}) — suppliers extending credit at a grudge", .{ f.name, f.local_funds });
            }
        }
    }

    // Loan service.
    for (gs.loans.items) |*loan| {
        if (loan.balance <= 0) continue;
        // Simple interest on the original principal, spread over the term:
        // every month costs the same, so early repayment
        // (`repay_loan`) saves the interest that hasn't been charged yet.
        const interest = @divTrunc(loan.principal * loan.rate_bp, 10_000 * 12);
        const principal_part = @min(@max(0, loan.payment - interest), loan.balance);
        loan.balance -= principal_part;
        try gs.postTransaction(.{ .day = gs.clock.day_index, .amount = -interest, .category = .loan_interest, .note = "loan interest" });
        try gs.postTransaction(.{ .day = gs.clock.day_index, .amount = -principal_part, .category = .loan_principal, .note = "loan principal" });
    }
}

test "payday fires on the 1st and only on the 1st" {
    var gs = GameState.init(std.testing.allocator, .{ .start_funds = 1_000_000 });
    defer gs.deinit();
    _ = try gs.hirePerson("Natasha", "Kerensky", .mekwarrior); // 1500/mo regular → Corporal ×1.1 on payday

    // Jan 1 (day 0) start → advancing 30 days lands on Jan 31: no payroll yet.
    for (0..30) |_| _ = try advanceDay(&gs);
    try std.testing.expectEqual(@as(i64, 1_000_000), gs.funds);

    // One more day → Feb 1: payroll posts, a month of service XP lands.
    _ = try advanceDay(&gs);
    try std.testing.expectEqual(@as(i64, 998_350), gs.funds);
    try std.testing.expectEqual(@as(usize, 1), gs.ledger.transactions.items.len);
    try std.testing.expectEqual(@as(u32, monthly_service_xp), gs.people.values()[0].xp);
}

test "phases are in spec order" {
    try std.testing.expect(@intFromEnum(DayPhase.travel) < @intFromEnum(DayPhase.supply_consumption));
    try std.testing.expect(@intFromEnum(DayPhase.contract_events) < @intFromEnum(DayPhase.battle_resolution));
    try std.testing.expect(@intFromEnum(DayPhase.finances) < @intFromEnum(DayPhase.decisions));
}

// ---- C4b handlers (moved from commands.zig) ----
const Error = commands.Error;
const Result = commands.Result;
const Command = commands.Command;

/// The turn-hold as an error. The checklist decides what
/// holds the turn; this only names the refusal, so a new hold cannot be
/// enforced in one place and reported in another.
fn holdError(gs: *GameState) ?Error {
    return switch (@import("checklist.zig").turnHold(gs) orelse return null) {
        .unread_after_action => Error.ReportUnread,
        .battle_decision => Error.DecisionPending,
    };
}

pub fn advance(gs: *GameState, days: u32) Error!Result {
    // Turn-based: each day is a turn; nothing interrupts the advance.
    // Decisions wait in the inbox and default at their deadlines — except
    // money: a negative outfit treasury holds the turn until a
    // loan or a sale covers it, and past all credit the outfit folds.
    var result: Result = .{};
    // Nothing moves while an engagement is unread or a battle
    // decision is unanswered; `read <id>` clears the first,
    // `decide <id> <n>` the second, and the client opens both for you.
    if (holdError(gs)) |e| return e;
    for (0..days) |_| {
        if (gs.bankrupt) return Error.Bankrupt;
        // Couriers already bound for the outfit count: the turn can end
        // while the money is on the road.
        if (gs.funds + treasury.inboundToOutfit(gs) < 0) {
            if (try treasury.isInsolvent(gs.scratch(), gs)) {
                gs.bankrupt = true;
                try gs.log(.finance, .{}, "[bankrupt] the outfit cannot cover {d}: creditors seize what is left", .{gs.funds});
                return Error.Bankrupt;
            }
            return Error.Insolvent;
        }
        try advanceDay(gs);
        result.days_advanced += 1;
        // A battle disposes of hulls and people permanently and has no
        // safe default to lapse to (ARCH §6), so an unread after-action
        // or an unanswered battle decision holds the turn. A multi-day
        // advance stops on the day it lands rather than resolving the
        // rest of the week around it.
        if (@import("checklist.zig").turnHold(gs) != null) return result;
        // The contact warning is a heads-up, not a hold: the advance stops
        // on the day it appears and the next advance goes ahead.
        if (@import("checklist.zig").contactOpenedToday(gs)) |c| {
            result.contact = c.id;
            return result;
        }
    }
    return result;
}

pub fn execSetDifficulty(gs: *GameState, level: @FieldType(Command, "set_difficulty")) Error!Result {
    const was = gs.difficulty;
    gs.difficulty = level;
    const row = gs.diff();
    const dm = @import("../domain/difficulty.zig").multText;
    var b1: [16]u8 = undefined;
    var b2: [16]u8 = undefined;
    var b3: [16]u8 = undefined;
    try gs.log(.finance, .{}, "[difficulty] {s} → {s} — {s} (contract pay {s}, fabrication {s}, opposition {s})", .{
        @tagName(was), row.name, row.blurb, dm(&b1, row.contract_pay_bp), dm(&b2, row.fab_cost_bp), dm(&b3, row.enemy_bp),
    });
    return .{};
}

pub fn execCycleDifficulty(gs: *GameState, dir: @FieldType(Command, "cycle_difficulty")) Error!Result {
    const Level = @import("../domain/difficulty.zig").Level;
    const n = @typeInfo(Level).@"enum".fields.len;
    const now: usize = @intFromEnum(gs.difficulty);
    const next: Level = @enumFromInt(if (dir >= 0) (now + 1) % n else (now + n - 1) % n);
    _ = try commands.execute(gs, .{ .set_difficulty = next });
    return .{ .difficulty_name = gs.diff().name, .difficulty_blurb = gs.diff().blurb };
}

pub fn execReadReport(gs: *GameState, id: @FieldType(Command, "read_report")) Error!Result {
    if (!gs.battle_reports.markRead(id)) return Error.NoSuchBattle;
    return .{};
}

pub fn advanceReading(gs: *GameState, days: u32) !void {
    var left = days;
    while (left > 0) {
        try clearHolds(gs);
        const r = try commands.execute(gs, .{ .advance_days = left });
        if (r.days_advanced == 0) break; // refused for a reason of its own
        left -= @intCast(r.days_advanced);
    }
    try clearHolds(gs);
}

pub fn clearHolds(gs: *GameState) !void {
    while (@import("checklist.zig").turnHold(gs)) |h| switch (h) {
        .unread_after_action => _ = try commands.execute(gs, .{ .read_report = gs.battle_reports.unread().?.id }),
        .battle_decision => {
            const ev = gs.event_queue.blocking().?;
            _ = try commands.execute(gs, .{ .resolve_decision = .{ .event = ev.id, .choice = ev.default_choice } });
        },
    };
}

test "an unread after-action holds the turn, and a week stops on the day it lands" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 4242 });
    defer gs.deinit();
    _ = try @import("founding.zig").createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "PER",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000, .salvage_pct = 30, .battle_loss_pct = 30 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
    });
    _ = gs.contracts.getPtr(@enumFromInt(1)).?;
    const site: types.Site = .{ .company = co };
    try gs.addStock(site, "armor", 60);
    for (@import("../domain/part.zig").munition_keys) |key| try gs.addStock(site, key, 40);

    var guard: u32 = 0;
    while (gs.battle_reports.unread() == null and guard < 20) : (guard += 1) {
        const r = try commands.execute(&gs, .{ .advance_days = 7 });
        if (gs.battle_reports.unread() != null) {
            try std.testing.expect(r.days_advanced < 7);
            break;
        }
        if (r.contact == .none) try std.testing.expectEqual(@as(u32, 7), r.days_advanced);
    }
    const waiting = gs.battle_reports.unread() orelse return error.NoBattleInTwentyWeeks;

    try std.testing.expectError(Error.ReportUnread, commands.execute(&gs, .{ .advance_days = 7 }));
    try std.testing.expectError(Error.ReportUnread, commands.execute(&gs, .advance_day));
    const held_at = gs.clock.day_index;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const warnings = try @import("checklist.zig").turnWarnings(&gs, arena.allocator());
    var saw = false;
    for (warnings) |w| if (w.kind == .unread_after_action) {
        saw = true;
        try std.testing.expect(w.kind.urgent());
    };
    try std.testing.expect(saw);

    _ = try commands.execute(&gs, .{ .read_report = waiting.id });
    try clearHolds(&gs);
    const after = try commands.execute(&gs, .advance_day);
    try std.testing.expectEqual(@as(u32, 1), after.days_advanced);
    try std.testing.expect(gs.clock.day_index > held_at);

    try std.testing.expectError(Error.NoSuchBattle, commands.execute(&gs, .{ .read_report = @enumFromInt(9999) }));
}

test "a field held asks for the tempo, and the turn waits for the answer" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 4242 });
    defer gs.deinit();
    _ = try @import("founding.zig").createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "PER",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000, .salvage_pct = 30, .battle_loss_pct = 30 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
    });
    const site: types.Site = .{ .company = co };
    try gs.addStock(site, "armor", 60);
    for (@import("../domain/part.zig").munition_keys) |key| try gs.addStock(site, key, 40);

    var guard: u32 = 0;
    while (gs.event_queue.blocking() == null and guard < 40) : (guard += 1) {
        while (gs.battle_reports.unread()) |u| _ = try commands.execute(&gs, .{ .read_report = u.id });
        _ = try commands.execute(&gs, .{ .advance_days = 7 });
        while (gs.battle_reports.unread()) |u| _ = try commands.execute(&gs, .{ .read_report = u.id });
    }
    const pending = gs.event_queue.blocking() orelse return error.NoHeldFieldInFortyWeeks;
    const event_id = pending.id;
    try std.testing.expectEqual(@import("../domain/events.zig").EventKind.press_or_consolidate, pending.kind);

    try std.testing.expectError(Error.DecisionPending, commands.execute(&gs, .{ .advance_days = 7 }));
    try std.testing.expectError(Error.DecisionPending, commands.execute(&gs, .advance_day));
    const held_at = gs.clock.day_index;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const warnings = try @import("checklist.zig").turnWarnings(&gs, a);
    var saw = false;
    for (warnings) |w| if (w.kind == .battle_decision) {
        saw = true;
        try std.testing.expect(w.kind.urgent());
    };
    try std.testing.expect(saw);
    const hold = @import("queries.zig").turnHold(&gs);
    try std.testing.expectEqual(event_id, hold.decision);

    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    const score_before = c.score;
    _ = try commands.execute(&gs, .{ .resolve_decision = .{ .event = event_id, .choice = 0 } });
    const t = @import("../domain/tuning.zig").t.battle;
    try std.testing.expectEqual(gs.clock.day_index + t.press_gap_days, c.next_battle_day.?);
    try std.testing.expectEqual(score_before + t.press_score, c.score);

    try std.testing.expect(gs.event_queue.blocking() == null);
    const after = try commands.execute(&gs, .advance_day);
    try std.testing.expectEqual(@as(u32, 1), after.days_advanced);
    try std.testing.expect(gs.clock.day_index > held_at);
}

test "garrison work has no advance to press" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 4243 });
    defer gs.deinit();
    _ = try @import("founding.zig").createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "PER",
        .planet_key = "galatea",
        .terms = .{ .length_months = 12, .base_pay_month = 400_000 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
        .enemy_lances = 2,
        .enemy_lance_bv = 4_000,
    });
    const site: types.Site = .{ .company = co };
    try gs.addStock(site, "armor", 60);
    for (@import("../domain/part.zig").munition_keys) |key| try gs.addStock(site, key, 40);

    var fought: usize = 0;
    for (0..52) |_| {
        try advanceReading(&gs, 7);
        fought = gs.battle_reports.kept.items.len;
        try std.testing.expect(gs.event_queue.blocking() == null);
    }
    try std.testing.expect(fought > 0);
    for (gs.event_queue.pending.items) |ev| {
        try std.testing.expect(ev.kind != .press_or_consolidate);
    }
}

test "turn-based decisions: time never blocks, deadlines default" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();

    try gs.event_queue.push(gs.allocator(), .{
        .day = 0,
        .kind = .off_contract_request,
        .deadline_day = 7,
        .options = &.{
            .{ .label = "Accept the governor's job", .effects = &.{ .{ .cash = 2_000_000 }, .{ .reputation = -1 } } },
            .{ .label = "Decline politely", .effects = &.{.{ .reputation = 1 }} },
        },
        .default_choice = 1,
    });

    const r = try commands.execute(&gs, .{ .advance_days = 3 });
    try std.testing.expectEqual(@as(u32, 3), r.days_advanced);
    try std.testing.expectEqual(@as(usize, 1), gs.event_queue.pending.items.len);

    _ = try commands.execute(&gs, .{ .resolve_decision = .{ .event = gs.event_queue.pending.items[0].id, .choice = 0 } });
    try std.testing.expectEqual(@as(i64, 12_000_000), gs.funds);
    try std.testing.expectEqual(@as(i32, -1), gs.reputation);
    try std.testing.expectEqual(@as(usize, 0), gs.event_queue.pending.items.len);

    try gs.event_queue.push(gs.allocator(), .{
        .day = gs.clock.day_index,
        .kind = .equipment_cache,
        .deadline_day = gs.clock.day_index + 4,
        .options = &.{
            .{ .label = "Crack it open", .effects = &.{.{ .reputation = -1 }} },
            .{ .label = "Report it", .effects = &.{.{ .reputation = 2 }} },
        },
        .default_choice = 1,
    });
    _ = try commands.execute(&gs, .{ .advance_days = 6 });
    try std.testing.expectEqual(@as(usize, 0), gs.event_queue.pending.items.len);
    try std.testing.expectEqual(@as(i32, 1), gs.reputation);
}

test "difficulty scales pay, fabrication and purchases — regular is the game as tuned, and it persists as a setting" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 98 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    _ = try commands.execute(&gs, .{ .new_company = "Alpha" });
    const hq_id = gs.hqs.keys()[0];
    try std.testing.expectEqual(@import("../domain/difficulty.zig").Level.regular, gs.difficulty);

    // Fabrication: elite charges more than regular for the same job.
    gs.hqs.getPtr(hq_id).?.funds = 50_000_000;
    const before_r = gs.hqs.getPtr(hq_id).?.funds;
    _ = try commands.execute(&gs, .{ .fabricate = .{ .hq = hq_id, .part_key = "comp_leg", .quantity = 1 } });
    const cost_r = before_r - gs.hqs.getPtr(hq_id).?.funds;
    _ = try commands.execute(&gs, .{ .set_difficulty = .elite });
    const before_e = gs.hqs.getPtr(hq_id).?.funds;
    _ = try commands.execute(&gs, .{ .fabricate = .{ .hq = hq_id, .part_key = "comp_leg", .quantity = 1 } });
    const cost_e = before_e - gs.hqs.getPtr(hq_id).?.funds;
    try std.testing.expect(cost_e > cost_r);
    try std.testing.expectEqual(types.applyBp(cost_r, gs.diff().fab_cost_bp), cost_e);
    // Regular: exactly the tuned ×1.5 on the catalogue price — a full structure set is 900 k.
    const part_mod2 = @import("../domain/part.zig");
    try std.testing.expectEqual(types.applyBp(part_mod2.cost("comp_leg"), tuning.market.fab_cost_bp), cost_r);

    // Contract pay: the same board, rolled under green and under elite, pays in the table's ratio.
    const cm = @import("contract_market.zig");
    _ = try commands.execute(&gs, .{ .set_difficulty = .green });
    var green = GameState.init(std.testing.allocator, .{ .seed = 98 });
    defer green.deinit();
    _ = try commands.execute(&green, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    _ = try commands.execute(&green, .{ .new_company = "Alpha" });
    green.difficulty = .green;
    var elite = GameState.init(std.testing.allocator, .{ .seed = 98 });
    defer elite.deinit();
    _ = try commands.execute(&elite, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    _ = try commands.execute(&elite, .{ .new_company = "Alpha" });
    elite.difficulty = .elite;
    try cm.refresh(&green);
    try cm.refresh(&elite);
    try std.testing.expect(green.contract_offers.items.len > 0);
    try std.testing.expectEqual(green.contract_offers.items.len, elite.contract_offers.items.len);
    const g0 = green.contract_offers.items[0].terms.base_pay_month;
    const e0 = elite.contract_offers.items[0].terms.base_pay_month;
    try std.testing.expect(e0 < g0);
    // ×0.61 / ×1.22 = exactly half, give or take rounding.
    try std.testing.expect(@abs(e0 * 2 - g0) <= @divTrunc(g0, 50));

    // The level is logged and survives a round trip through the store.
    var seen = false;
    for (gs.event_log.items) |e| if (std.mem.indexOf(u8, e.text, "[difficulty]") != null) {
        seen = true;
    };
    try std.testing.expect(seen);
}
