//! The daily tick: one campaign day through the ordered phase pipeline
//! (ARCH §6, clock.DayPhase). Mirrors MekHQ `Campaign.newDay()`.
//!
//! Stage 1 wires the pipeline with most phases stubbed; each later stage
//! fills in its phase without touching the order. Order is part of the spec.

const std = @import("std");
const GameState = @import("state.zig").GameState;
const types = @import("../domain/types.zig");
const contract_market = @import("../econ/contract_market.zig");
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

/// Advance exactly one day — one turn. Turn-based: nothing blocks time;
/// decision events sit in the inbox with deadlines, and the deadline applies
/// the default (contract_events.expireDue). Multi-day advance is just
/// several turns.
pub fn advanceDay(gs: *GameState) !void {
    gs.clock.advance();
    gs.refreshHqStaffing(); // the back office is people (Stage 9C)

    // Phase order per clock.DayPhase — stubs marked with their stage.
    if (gs.clock.day_index % 7 == 0) network.resetWeeklyThroughput(gs); // links' week (Stage 9D)
    try runTravel(gs); // deliveries, couriers, transfers
    try runPolicies(gs); // standing cash top-ups and resupply (Stage 12: daily)
    try runStockPolicies(gs); // warehouse reorder points (Stage 12)
    try hq_ops.runDaily(gs); // bays, fabrication, construction (Stage 9C)
    try runSupplyConsumption(gs); // supply_consumption phase (Stage 9B)
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
    if (gs.clock.day_index % 7 == 3) try contract_events.rollWeekly(gs); // weekly happenings (Stage 12)
    try battle.runDaily(gs); // battle_resolution: due engagements resolve
    try contract_control.checkEffectiveness(gs); // the ineffectiveness clock (Stage 9E)
    if (gs.clock.day_index % 7 == 0 and gs.clock.day_index > 0) {
        try medical.runWeeklyRest(gs); // morale_fatigue phase
        runTrainingLances(gs); // lance roles (Stage 12)
    }
    try runFinances(gs);
    try contract_events.expireDue(gs); // decisions phase: deadlines pass
}

/// Standing policies, daily (Stage 12). Cash: top an entity up to its
/// floor by courier, at most the monthly cap per month, and never while a
/// courier to it is already in flight. Provisions: ship the policy's
/// tonnage from the home warehouse when a deployed company's days of
/// supply fall under the floor, one shipment in flight at a time.
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
        const eta = gs.courierEtaDays(policy.entity);
        gs.transferFunds(.outfit, policy.entity, amount, eta) catch continue;
        policy.sent_this_month += amount;
        const tags = GameState.treasuryTags(policy.entity);
        try gs.log(.finance, .{ .company = tags.company, .hq = tags.hq }, "[finance] standing policy dispatches {d} c-bills (eta {d} days, {d} of {d} this month)", .{ amount, eta, policy.sent_this_month, policy.monthly_cap });
    }

    const commands = @import("commands.zig");
    for (gs.supply_policies.items) |sp| {
        const f = gs.forces.getPtr(sp.company) orelse continue;
        if (gs.isCompanyHome(sp.company) or f.return_eta_day != null) continue;
        const heads = gs.companyHeadcount(sp.company);
        const per_day: u32 = @max(1, (heads + part_mod.provisions_person_days_per_ton - 1) / part_mod.provisions_person_days_per_ton);
        const tons = gs.stockCount(.{ .company = sp.company }, "provisions");
        if (tons / per_day >= sp.min_days) continue;
        var in_flight = false;
        for (gs.part_orders.items) |o| {
            if (o.dest == .company and o.dest.company == sp.company and std.mem.eql(u8, o.part_key, "provisions") and (o.status == .in_transit or o.status == .sourcing)) in_flight = true;
        }
        if (in_flight) continue;
        const home = gs.homeHqFor(sp.company);
        if (home == .none) continue;
        const available = gs.stockCount(.{ .hq = home }, "provisions");
        const qty = @min(sp.tons, available);
        if (qty == 0) {
            if (gs.clock.day_index % 7 == 0) try gs.log(.delivery, .{ .company = sp.company, .hq = home }, "[supply] resupply policy: no provisions at {s} to ship to {s}", .{ gs.hqs.getPtr(home).?.name, f.name });
            continue;
        }
        _ = commands.execute(gs, .{ .ship_stock = .{ .part_key = "provisions", .quantity = qty, .from = .{ .hq = home }, .to = .{ .company = sp.company } } }) catch |err| {
            if (gs.clock.day_index % 7 == 0) try gs.log(.delivery, .{ .company = sp.company, .hq = home }, "[supply] resupply policy could not ship to {s}: {s}", .{ f.name, @errorName(err) });
            continue;
        };
        try gs.log(.delivery, .{ .company = sp.company, .hq = home }, "[supply] resupply policy ships {d}t of provisions to {s} ({d} days left in the field)", .{ qty, f.name, tons / per_day });
    }

    // Munitions under the same policy: each family the company's weapons
    // fire is kept at a few battles' worth (battle.mounts_per_ammo_ton per ton), one
    // shipment per family in flight at a time.
    for (gs.supply_policies.items) |sp| {
        const f = gs.forces.getPtr(sp.company) orelse continue;
        if (gs.isCompanyHome(sp.company) or f.return_eta_day != null) continue;
        const home = gs.homeHqFor(sp.company);
        if (home == .none) continue;
        for (part_mod.munition_keys) |key| {
            var mounts: u32 = 0;
            var uit = gs.units.iterator();
            while (uit.next()) |e| {
                const u = e.value_ptr;
                if (u.status == .destroyed or u.status == .mothballed or gs.companyOf(u.force) != sp.company) continue;
                for (u.slots.items) |s| {
                    if (s.class != .weapon or s.condition != .ok) continue;
                    const fam = part_mod.munitionFor(s.part_key) orelse continue;
                    if (std.mem.eql(u8, fam, key)) mounts += 1;
                }
            }
            if (mounts == 0) continue;
            const per_battle: u32 = std.math.divCeil(u32, mounts, battle.mounts_per_ammo_ton) catch 1;
            // Battles come every ~15 days; a shipment takes the link's transit
            // time. Floor = enough to fight through the transit plus one;
            // target = floor + 2. `ammo_battles` overrides the target.
            const transit = gs.courierEtaDays(.{ .company = sp.company });
            const floor_battles: u32 = 1 + (transit + 14) / 15; // ceil(transit / 15) battles fought while a shipment travels
            const target_battles: u32 = if (sp.ammo_battles > 0) @max(@as(u32, sp.ammo_battles), floor_battles) else floor_battles + 2;
            const have = gs.stockCount(.{ .company = sp.company }, key);
            if (have >= per_battle * floor_battles) continue;
            var in_flight = false;
            for (gs.part_orders.items) |o| {
                if (o.dest == .company and o.dest.company == sp.company and std.mem.eql(u8, o.part_key, key) and (o.status == .in_transit or o.status == .sourcing)) in_flight = true;
            }
            if (in_flight) continue;
            const available = gs.stockCount(.{ .hq = home }, key);
            const want = per_battle * target_battles - have;
            const qty = @min(want, available);
            if (qty == 0) {
                if (gs.clock.day_index % 7 == 0) try gs.log(.delivery, .{ .company = sp.company, .hq = home }, "[supply] resupply policy: no {s} at {s} to ship to {s}", .{ key, gs.hqs.getPtr(home).?.name, f.name });
                continue;
            }
            _ = commands.execute(gs, .{ .ship_stock = .{ .part_key = key, .quantity = qty, .from = .{ .hq = home }, .to = .{ .company = sp.company } } }) catch |err| {
                if (gs.clock.day_index % 7 == 0) try gs.log(.delivery, .{ .company = sp.company, .hq = home }, "[supply] resupply policy could not ship {s} to {s}: {s}", .{ key, f.name, @errorName(err) });
                continue;
            };
            try gs.log(.delivery, .{ .company = sp.company, .hq = home }, "[supply] resupply policy ships {d}t of {s} to {s} ({d} mounts, {d}t on hand, target {d} battles for a {d}-day line)", .{ qty, key, f.name, mounts, have, target_battles, transit });
        }
    }
}

/// Warehouse reorder points (Stage 12): every line an HQ keeps stocked is
/// checked daily; under `min` the shortfall to `target` is fabricated
/// (components, when the HQ has a bay) or ordered through the catalogue.
/// One order per line in flight; a failed sourcing roll waits a week.
fn runStockPolicies(gs: *GameState) !void {
    const commands = @import("commands.zig");
    const today = gs.clock.day_index;
    for (gs.stock_policies.items) |sp| {
        const hq = gs.hqs.getPtr(sp.hq) orelse continue;
        const have = gs.stockCount(.{ .hq = sp.hq }, sp.part_key);
        if (have >= sp.min) continue;
        var pending: u32 = 0;
        var failed_recently = false;
        for (gs.part_orders.items) |o| {
            if (!std.mem.eql(u8, o.part_key, sp.part_key)) continue;
            if (o.dest == .hq and o.dest.hq == sp.hq and (o.status == .in_transit or o.status == .sourcing)) pending += o.quantity;
            if (o.status == .failed and o.ordered_day + 7 > today) failed_recently = true;
        }
        for (gs.bay_jobs.items) |j| if (j.hq == sp.hq and j.kind == .fabrication and j.done_day == null and std.mem.eql(u8, j.item_key, sp.part_key)) {
            pending += 1;
        };
        if (pending > 0 or failed_recently) continue;
        const want = sp.target - have;
        const fabricate = part_mod.isComponent(sp.part_key) and hq_ops.baySlots(gs, sp.hq) > 0;
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
/// crews drill for XP every week the company is home. // TUNE
fn runTrainingLances(gs: *GameState) void {
    var pit = gs.people.iterator();
    while (pit.next()) |entry| {
        const p = entry.value_ptr;
        if (p.status != .active) continue;
        const lance = gs.forces.getPtr(p.assigned_force) orelse continue;
        if (lance.role != .training) continue;
        if (!gs.isCompanyHome(gs.companyOf(lance.id))) continue;
        p.xp += 1;
    }
}

/// travel phase: part deliveries land, fund couriers arrive, cold-storage
/// reactivations finish. Nothing material happens silently.
fn runTravel(gs: *GameState) !void {
    for (gs.part_orders.items) |*order| {
        if (order.status != .in_transit) continue;
        if (order.eta_day != null and gs.clock.day_index >= order.eta_day.?) {
            order.status = .delivered;
            // Land at the destination site; anything the warehouse or the
            // trucks can't hold is lost on the dock (Stage 9B).
            const dest: types.Site = if (order.dest == .outfit) gs.defaultSite() else order.dest;
            const room = gs.siteFreeTons(dest) / @max(1, part_mod.tons(order.part_key));
            const landed = @min(order.quantity, room);
            try gs.addStock(dest, order.part_key, landed);
            const tags = GameState.treasuryTags(GameState.siteTreasury(dest));
            try gs.log(.delivery, .{ .company = tags.company, .hq = tags.hq }, "[delivery] {s} x{d} received{s}", .{
                order.part_key, landed, if (landed < order.quantity) " — NO ROOM for the rest, written off" else "",
            });
        }
    }

    // Transferred hulls arrive (Stage 9D).
    var ti: usize = 0;
    while (ti < gs.unit_transfers.items.len) {
        const t = gs.unit_transfers.items[ti];
        if (gs.clock.day_index >= t.eta_day) {
            try gs.placeUnitInCompany(t.unit, t.to_company);
            const name = if (gs.unit(t.unit)) |u| u.chassis_key else "?";
            try gs.log(.delivery, .{ .company = t.to_company }, "[transfer] {s} arrives and joins the company", .{name});
            _ = gs.unit_transfers.swapRemove(ti);
        } else ti += 1;
    }

    var i: usize = 0;
    while (i < gs.fund_couriers.items.len) {
        const courier = gs.fund_couriers.items[i];
        if (gs.clock.day_index >= courier.eta_day) {
            try gs.creditTreasury(courier.to, courier.amount);
            const tags = GameState.treasuryTags(courier.to);
            try gs.log(.delivery, .{ .company = tags.company, .hq = tags.hq }, "[delivery] courier delivers {d} c-bills", .{courier.amount});
            _ = gs.fund_couriers.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

/// supply_consumption phase (Stage 9B): deployed companies eat from their
/// field stores daily. Empty stores → buy locally with local funds (the
/// §9.6 valve, at local prices); no funds → the company goes hungry.
fn runSupplyConsumption(gs: *GameState) !void {
    // Every company away from home eats from its trucks — on contract or
    // idling on the world it last worked (Stage 9E).
    var fit = gs.forces.iterator();
    while (fit.next()) |fentry| {
        const f = fentry.value_ptr;
        if (f.echelon != .company or gs.isCompanyHome(f.id) or f.return_eta_day != null) continue;
        const c = gs.deploymentContract(f.id);
        const planet_key: []const u8 = if (c) |cc| cc.planet_key else (f.location_planet orelse continue);
        const beachhead = if (c) |cc| cc.beachhead else false;
        const contract_id: types.ContractId = if (c) |cc| cc.id else .none;
        const site: types.Site = .{ .company = f.id };

        const heads = gs.companyHeadcount(f.id);
        const need: u32 = @intCast(std.math.divCeil(u32, heads, part_mod.provisions_person_days_per_ton) catch 1);
        if (gs.takeStock(site, "provisions", need)) {
            f.supply_shortage_days = 0;
            continue;
        }

        // Local purchase valve: price by remoteness, paid from local funds.
        const industry = if (planet_mod.find(planet_key)) |w| w.industry else 0;
        const mult = if (beachhead) logistics.localPurchaseMultBp(30, industry) else 15_000; // field markup // TUNE
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

/// markets phase: contract board and site-market listings refresh monthly;
/// hiring halls weekly.
fn runMarkets(gs: *GameState) !void {
    try contract_market.churnCandidates(gs); // people move daily (Stage 9C.3)
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
                c.end_day = gs.clock.day_index + @as(u32, c.terms.length_months) * 30;
                if (gs.force(c.assigned_company)) |f| f.location_planet = c.planet_key;
                try gs.log(.contract, .{ .company = c.assigned_company, .contract = c.id }, "[{s}] company on station at {s} — contract active", .{ @tagName(c.kind), c.planet_key });
            },
            .active => if (c.end_day != null and gs.clock.day_index >= c.end_day.?) {
                // End of term (Stage 9E): a performance failure is a breach;
                // otherwise the tour completes, reputation by VP + score.
                if (c.score <= -5) {
                    try contract_control.breach(gs, c, "failed on performance");
                } else {
                    c.victory_points += c.score * 5;
                    try contract_control.complete(gs, c, false);
                }

                // The rotation bill (ARCH §9.7): a completed tour banks
                // fatigue for everyone attached — scaled by how long it ran
                // and how hard it fought, compounding for every contract
                // since the company last rested at a regional HQ.
                const heads = gs.companyHeadcount(c.assigned_company);
                const casualties_pct: u8 = if (heads == 0) 0 else @intCast(@min(100, @as(u32, c.casualties) * 100 / heads));
                var gain = person_mod.contractFatigueGain(c.terms.length_months, c.battles_fought, casualties_pct);
                if (gs.force(c.assigned_company)) |f| {
                    gain +|= 5 * @as(u8, @intCast(@min(10, f.contracts_since_rotation -| 1)));
                }
                var pit = gs.people.iterator();
                while (pit.next()) |pentry| {
                    const p = pentry.value_ptr;
                    if (p.status != .active and p.status != .wounded) continue;
                    var walk = p.assigned_force;
                    const in_company = while (walk != .none) {
                        if (walk == c.assigned_company) break true;
                        walk = (gs.forces.getPtr(walk) orelse break false).parent;
                    } else false;
                    if (in_company) p.fatigue = person_mod.applyFatigue(p.fatigue, gain);
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
    const room = gs.siteFreeTons(site) / @max(1, part_mod.tons(key));
    const n = @min(qty, room);
    if (n > 0) try gs.addStock(site, key, n);
    return n;
}

/// finances phase: payday on the 1st of the month — salaries out, and a
/// month of service XP in (MekHQ's idle-XP analog; scenario and task XP
/// arrive with Stages 5/7). // TUNE
const monthly_service_xp = 1;

fn runFinances(gs: *GameState) !void {
    if (!gs.clock.date.isPayday()) return;

    var it = gs.people.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        if (p.status == .active) p.xp += monthly_service_xp;
    }

    const payroll = gs.monthlyPayroll();
    if (payroll != 0) {
        try gs.postTransaction(.{
            .day = gs.clock.day_index,
            .amount = -payroll,
            .category = .payroll,
            .note = "monthly payroll",
        });
    }

    // The hangar ledger (ARCH §9.8): every hull bills, running or not.
    var hull_bill: i64 = 0;
    var uit = gs.units.iterator();
    while (uit.next()) |entry| hull_bill += entry.value_ptr.monthlyBill();
    if (hull_bill != 0) {
        try gs.postTransaction(.{
            .day = gs.clock.day_index,
            .amount = -hull_bill,
            .category = .hull_upkeep,
            .note = "hangar & hull upkeep",
        });
    }

    // HQ upkeep draws each HQ's own treasury (Stage 9A); running dry is
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

    // Supply-link upkeep (Stage 9D): the network is a standing cost.
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
            const hardship = types.applyBp(gs.companyMonthlyPayroll(c.assigned_company), 1_500); // +15% TUNE
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

        // Straight support (Stage 9B): employers with overhead terms ship
        // supplies monthly — goods, not cash — landing in the company's
        // field stores as far as the trucks can hold.
        if (c.terms.overhead_pct > 0) {
            const site: types.Site = .{ .company = c.assigned_company };
            const heads = gs.companyHeadcount(c.assigned_company);
            const month_food: u32 = @intCast(std.math.divCeil(u32, heads * 30, part_mod.provisions_person_days_per_ton) catch 1);
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
        // Simple interest on the original principal, spread over the term
        // (Stage 12 rule): every month costs the same, so early repayment
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
    _ = try gs.hirePerson("Natasha", "Kerensky", .mekwarrior); // 1500/mo regular

    // Jan 1 (day 0) start → advancing 30 days lands on Jan 31: no payroll yet.
    for (0..30) |_| _ = try advanceDay(&gs);
    try std.testing.expectEqual(@as(i64, 1_000_000), gs.funds);

    // One more day → Feb 1: payroll posts, a month of service XP lands.
    _ = try advanceDay(&gs);
    try std.testing.expectEqual(@as(i64, 998_500), gs.funds);
    try std.testing.expectEqual(@as(usize, 1), gs.ledger.transactions.items.len);
    try std.testing.expectEqual(@as(u32, monthly_service_xp), gs.people.values()[0].xp);
}
