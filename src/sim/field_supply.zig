//! Field-store planning for a deployed company (Stage 12).
//!
//! MekHQ counterpart: none — MekHQ has no per-company truck model; the
//! nearest analogue is its AtB resupply drop. Here every line a company
//! burns in the field (provisions, medical, armor, each munition family)
//! gets a floor and a target sized from consumption, the transit time of
//! its supply line and the tonnage its trucks can carry, with a budget
//! share per category so no single line crowds the others out. The
//! resupply policy (tick.runPolicies) and the load-out at acceptance
//! (field_supply.loadOutCompany) both follow the same plan, and the
//! Supply screen shows it.

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const part_mod = @import("../domain/part.zig");
const sites = @import("sites.zig");
const toe = @import("toe.zig");
const GameState = @import("state.zig").GameState;
const treasury = @import("treasury.zig");
const commands = @import("commands.zig");

/// Truck budget per category, in percent of field capacity: ammo, armor
/// and medical are capped so provisions — the one line that burns every
/// day — always has the rest of the trucks.
pub const ammo_share_pct: u32 = tuning.field_supply.ammo_share_pct;
pub const armor_share_pct: u32 = tuning.field_supply.armor_share_pct;
pub const medical_share_pct: u32 = tuning.field_supply.medical_share_pct;

/// A ton of a munition family feeds this many mounts for one engagement
/// (one source for battle and resupply: the tuning table).
pub const mounts_per_ammo_ton: u32 = tuning.battle.mounts_per_ammo_ton;
/// Engagements come roughly this often on station.
pub const days_per_battle: u32 = tuning.field_supply.days_per_battle;
/// A provisions shipment tops up this many days past the floor.
pub const provisions_cadence_days: u32 = tuning.field_supply.provisions_cadence_days;

comptime {
    std.debug.assert(mounts_per_ammo_ton > 0);
    std.debug.assert(days_per_battle > 0);
}

pub const Line = struct {
    key: []const u8,
    /// Ship when on hand + inbound drops under this.
    floor: u32,
    /// Ship up to this.
    target: u32,
    /// Why (mounts, days, hulls) — for the Supply screen.
    note: []const u8,
    /// Cut back to fit the ammo share of the hold (the screen flags it).
    trimmed: bool = false,
};

pub const Plan = struct {
    lines: []Line,
    transit_days: u32,
    provisions_per_day: u32,
    capacity: u32,
    total_target: u32,
};

/// The plan for one company. `transit_days` is the supply line's transit
/// (0 at home); `min_days` the days of provisions to keep on hand past
/// the transit; `ammo_battles` overrides the munition target (0 = auto).
pub fn plan(alloc: std.mem.Allocator, gs: *GameState, company: types.ForceId, transit_days: u32, min_days: u32, ammo_battles: u8) !Plan {
    var lines: std.ArrayListUnmanaged(Line) = .empty;
    const cap = sites.siteCapacityTons(gs, .{ .company = company }) orelse 0;
    const heads = toe.companyHeadcount(gs, company);
    const per_day: u32 = part_mod.provisionsPerDay(heads);

    // Provisions: enough on hand or on the way to eat through the transit
    // plus the safety days, topped up a fortnight past that. Uncapped: on a
    // long line most of it rides in convoys, and the trucks only ever hold
    // what the other shares leave.
    {
        const floor_days = transit_days + min_days;
        const target_days = floor_days + provisions_cadence_days;
        try lines.append(alloc, .{ .key = "provisions", .floor = per_day * floor_days, .target = per_day * target_days, .note = try std.fmt.allocPrint(alloc, "{d} heads eat {d}t/day · keep {d} days on hand + inbound ({d} transit + {d})", .{ heads, per_day, floor_days, transit_days, min_days }) });
    }

    // Medical: a few tons, more while people are hurt.
    {
        var wounded: u32 = 0;
        var pit = gs.people.iterator();
        while (pit.next()) |e| if (e.value_ptr.status == .wounded and gs.companyOf(e.value_ptr.assigned_force) == company) {
            wounded += 1;
        };
        const share = @max(2, cap * medical_share_pct / 100);
        const target = @min(4 + wounded, share);
        try lines.append(alloc, .{ .key = "medical_supplies", .floor = @max(1, target / 2), .target = target, .note = try std.fmt.allocPrint(alloc, "a ton per wound treated · {d} wounded now", .{wounded}) });
    }

    // Armor: field repairs patch a ton per hull per week of damage.
    var hulls: u32 = 0;
    var family_mounts = try munitionMounts(alloc, gs, company, false);
    {
        var uit = gs.units.iterator();
        while (uit.next()) |e| {
            const u = e.value_ptr;
            if (u.isParked() or gs.companyOf(u.force) != company) continue;
            if (u.kind == .mek or u.kind == .vehicle) hulls += 1;
        }
        const share = @max(2, cap * armor_share_pct / 100);
        const target = std.math.clamp(hulls / 2, 2, share);
        try lines.append(alloc, .{ .key = "armor", .floor = @max(1, target / 2), .target = target, .note = try std.fmt.allocPrint(alloc, "{d} hulls · a ton patches one hull's plating", .{hulls}) });
    }

    // Munitions: per family the company actually fires. Floor = the battles
    // fought while a shipment travels, plus one; target = floor + 2 (or the
    // override). The families share the ammo budget pro rata.
    {
        const floor_battles: u32 = 1 + (std.math.divCeil(u32, transit_days, days_per_battle) catch unreachable);
        const target_battles: u32 = if (ammo_battles > 0) @max(@as(u32, ammo_battles), floor_battles) else floor_battles + 2;
        const budget = cap * ammo_share_pct / 100;
        var sum: u32 = 0;
        const first_ammo = lines.items.len;
        for (part_mod.munition_keys) |key| {
            const mounts = family_mounts.get(key) orelse continue;
            if (mounts == 0) continue;
            const per_battle = tonsPerBattle(mounts);
            const target = per_battle * target_battles;
            sum += target;
            try lines.append(alloc, .{ .key = key, .floor = per_battle * floor_battles, .target = target, .note = try std.fmt.allocPrint(alloc, "{d} mounts · {d}t per battle · {d} battles floor, {d} target", .{ mounts, per_battle, floor_battles, target_battles }) });
        }
        if (sum > budget and budget > 0) {
            for (lines.items[first_ammo..]) |*l| {
                const mounts = family_mounts.get(l.key) orelse 1;
                const per_battle = tonsPerBattle(mounts);
                l.target = @max(per_battle, l.target * budget / sum);
                l.floor = @min(l.floor, l.target);
                l.trimmed = true;
                l.note = try std.fmt.allocPrint(alloc, "{s} · {d}% ammo share", .{ l.note, ammo_share_pct });
            }
        }
    }

    var total: u32 = 0;
    for (lines.items) |l| total += l.target * part_mod.tons(l.key);
    return .{ .lines = try lines.toOwnedSlice(alloc), .transit_days = transit_days, .provisions_per_day = per_day, .capacity = cap, .total_target = total };
}

/// Kit out a company from the home warehouse before it ships: a month
/// of provisions, medical, ammo for its weapons, armor and structure —
/// as far as its trucks can carry (the field plan sizes it).
pub fn loadOutCompany(gs: *GameState, company_id: types.ForceId) !void {
    const home = gs.homeSiteFor(company_id);
    const dest: types.Site = .{ .company = company_id };
    // The same plan the resupply policy follows, sized for the contract's
    // transit so the trucks land with the line already covered.
    const transit: u32 = if (gs.deploymentContract(company_id)) |c| c.transit_days else 0;
    var arena = std.heap.ArenaAllocator.init(gs.scratch());
    defer arena.deinit();
    const p = try plan(arena.allocator(), gs, company_id, transit, 14, 0);
    // Capped lines first; provisions fill whatever the trucks have left.
    for (p.lines) |l| if (!std.mem.eql(u8, l.key, "provisions")) {
        _ = try sites.moveStock(gs, home, dest, l.key, l.target);
    };
    for (p.lines) |l| if (std.mem.eql(u8, l.key, "provisions")) {
        _ = try sites.moveStock(gs, home, dest, l.key, l.target);
    };
}

/// Tons of one munition family an engagement burns: a ton feeds
/// `mounts_per_ammo_ton` mounts.
pub fn tonsPerBattle(mounts: u32) u32 {
    return std.math.divCeil(u32, mounts, mounts_per_ammo_ton) catch unreachable;
}

/// Engagements of one munition family the company's stores can feed.
pub const AmmoFights = struct { key: []const u8, fights: u32 };

/// Per family the company's fighting mounts fire, in `part.munition_keys`
/// order: whole engagements the stock at its site feeds.
pub fn ammoFights(alloc: std.mem.Allocator, gs: *GameState, company: types.ForceId) ![]AmmoFights {
    const mounts = try munitionMounts(alloc, gs, company, true);
    const site = sites.siteForForce(gs, company);
    var out: std.ArrayListUnmanaged(AmmoFights) = .empty;
    for (part_mod.munition_keys) |key| {
        const n = mounts.get(key) orelse continue;
        const per_battle = tonsPerBattle(n);
        if (per_battle == 0) continue;
        try out.append(alloc, .{ .key = key, .fights = gs.stockCount(site, key) / per_battle });
    }
    return out.toOwnedSlice(alloc);
}

/// The local supplies valve's price multiplier (ARCH §9.6) for a company
/// on a contract: on a beachhead, remoteness beyond the ring eased by the
/// world's industry; inside the rings, the ordinary field markup.
pub fn localPriceMultBp(c: *const @import("../domain/contract.zig").Contract) types.Bp {
    if (!c.beachhead) return tuning.finance.field_markup_bp;
    const industry = if (@import("../domain/planet.zig").find(c.planet_key)) |w| w.industry else 0;
    return @import("../econ/logistics.zig").localPurchaseMultBp(30, industry);
}

/// One line of an emergency resupply.
pub const RushLine = struct { key: []const u8, qty: u32 };

/// What an emergency resupply would buy: every line, its weight and price.
pub const Rush = struct {
    lines: []const RushLine,
    tons: u32,
    price: types.CBills,
    mult_bp: types.Bp,
};

/// Emergency resupply before a fight: the local supplies valve
/// extended to munitions and armour. One more fight of each munition
/// family the company fires and is short on, and a ton of armour for each
/// hull below full plating less the armour already carried, bought on the
/// contract world at the valve's price. Pure: `commands` checks room and
/// funds and carries it out.
pub fn rushQuote(alloc: std.mem.Allocator, gs: *GameState, c: *const @import("../domain/contract.zig").Contract) !Rush {
    const company = c.assigned_company;
    const site = sites.siteForForce(gs, company);
    var lines: std.ArrayListUnmanaged(RushLine) = .empty;
    const mounts = try munitionMounts(alloc, gs, company, true);
    for (part_mod.munition_keys) |key| {
        const n = mounts.get(key) orelse continue;
        const per_battle = tonsPerBattle(n);
        const have = gs.stockCount(site, key);
        if (have < per_battle) try lines.append(alloc, .{ .key = key, .qty = per_battle - have });
    }
    var dented: u32 = 0;
    var uit = gs.units.iterator();
    while (uit.next()) |e| {
        const u = e.value_ptr;
        if (gs.companyOf(u.force) == company and u.takesFieldWork() and u.armor_pct < 100) dented += 1;
    }
    const armor_have = gs.stockCount(site, "armor");
    if (dented > armor_have) try lines.append(alloc, .{ .key = "armor", .qty = dented - armor_have });
    const mult = localPriceMultBp(c);
    var tons: u32 = 0;
    var price: types.CBills = 0;
    for (lines.items) |l| {
        tons += l.qty * part_mod.tons(l.key);
        price += types.applyBp(part_mod.cost(l.key) * l.qty, mult);
    }
    return .{ .lines = try lines.toOwnedSlice(alloc), .tons = tons, .price = price, .mult_bp = mult };
}

/// Tons already on the road to a site (every line): the room check and
/// the resupply plan both read it, so what one sends the other accepts.
pub fn inboundTonsTo(gs: *GameState, site: types.Site) u32 {
    var n: u32 = 0;
    for (gs.part_orders.items) |o| {
        if (o.inFlight() and std.meta.eql(o.dest, site)) n += o.quantity * part_mod.tons(o.part_key);
    }
    return n;
}

/// Tons already on the road to a company's trucks (every line).
pub fn inboundTons(gs: *GameState, company: types.ForceId) u32 {
    return inboundTonsTo(gs, .{ .company = company });
}

/// Working weapon mounts per munition family across a company:
/// `fighting` counts only the line lances' hulls with a tech to reload
/// them (what a battle can feed); otherwise every hull that is not parked
/// (what the trucks must carry). The one census the fight, the plan, the
/// checklist and the stock list all read.
pub fn munitionMounts(alloc: std.mem.Allocator, gs: *GameState, company: types.ForceId, fighting: bool) !std.StringArrayHashMapUnmanaged(u32) {
    var out: std.StringArrayHashMapUnmanaged(u32) = .empty;
    var uit = gs.units.iterator();
    while (uit.next()) |e| {
        const u = e.value_ptr;
        if (u.isParked() or gs.companyOf(u.force) != company) continue;
        if (fighting) {
            const lance = gs.force(u.force) orelse continue;
            if (!lance.isCombatLance()) continue;
            const t = gs.person(u.tech) orelse continue; // nobody to reload it
            if (!t.isAvailable(gs.clock.day_index)) continue;
        }
        for (u.slots.items) |s| {
            if (s.class != .weapon or s.condition != .ok) continue;
            const fam = part_mod.munitionFor(s.part_key) orelse continue;
            const g = try out.getOrPut(alloc, fam);
            if (!g.found_existing) g.value_ptr.* = 0;
            g.value_ptr.* += 1;
        }
    }
    return out;
}

pub fn inboundQty(gs: *GameState, company: types.ForceId, key: []const u8) u32 {
    var n: u32 = 0;
    for (gs.part_orders.items) |o| {
        if (o.dest != .company or o.dest.company != company) continue;
        if (!std.mem.eql(u8, o.part_key, key)) continue;
        if (o.inFlight()) n += o.quantity;
    }
    return n;
}

/// Emergency resupply: the quote from `rushQuote`,
/// checked against truck room and local funds before anything moves.
pub fn emergencyResupply(gs: *GameState, id: types.ContractId) !u32 {
    const c = gs.contracts.getPtr(id) orelse return error.UnknownContract;
    if (c.status != .active) return error.NoContact;
    var arena = std.heap.ArenaAllocator.init(gs.scratch());
    defer arena.deinit();
    const rush = try rushQuote(arena.allocator(), gs, c);
    if (rush.lines.len == 0) return error.NothingToRush;
    const site = sites.siteForForce(gs, c.assigned_company);
    if (sites.siteCapacityTons(gs, site)) |cap| {
        if (sites.siteTons(gs, site) + inboundTonsTo(gs, site) + rush.tons > cap) return error.StorageFull;
    }
    if (gs.treasuryBalance(.{ .company = c.assigned_company }) < rush.price) return error.CompanyFundsShort;
    for (rush.lines) |l| try gs.addStock(site, l.key, 0); // every stock slot exists before money moves
    try gs.reserveLedger(1);
    try treasury.debit(gs, .{ .company = c.assigned_company }, .{
        .day = gs.clock.day_index,
        .amount = -rush.price,
        .category = if (c.beachhead) .local_supplies else .supplies,
        .company = c.assigned_company,
        .contract = id,
        .note = "emergency resupply",
    });
    for (rush.lines) |l| gs.addStock(site, l.key, l.qty) catch unreachable; // slots reserved above
    try gs.log(.delivery, .{ .company = c.assigned_company, .contract = id }, "[resupply] emergency purchase on {s}: {d}t for {d} c-bills", .{ c.planet_key, rush.tons, rush.price });
    return rush.tons;
}

// ---- C4b exec wrappers ----
const Error = commands.Error;
const Result = commands.Result;
const Command = commands.Command;

pub fn execSetSupplyPolicy(gs: *GameState, sp: @FieldType(Command, "set_supply_policy")) Error!Result {
    setSupplyPolicy(gs, sp.company, sp.min_days, sp.tons, sp.ammo_battles) catch |err| return @errorCast(err);
    return .{};
}

pub fn execTrimStock(gs: *GameState, company: @FieldType(Command, "trim_stock")) Error!Result {
    const tons = trimStock(gs, company) catch |err| return @errorCast(err);
    return .{ .tons_moved = tons };
}

pub fn execEmergencyResupply(gs: *GameState, id: @FieldType(Command, "emergency_resupply")) Error!Result {
    const tons = emergencyResupply(gs, id) catch |err| return @errorCast(err);
    return .{ .tons_moved = tons };
}

test "the plan fits the trucks and only stocks munitions the company fires" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 5 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try plan(a, &gs, co, 24, 14, 0);
    try std.testing.expect(p.capacity > 0);
    // Everything but provisions fits inside its share of the trucks.
    var capped: u32 = 0;
    for (p.lines) |l| if (!std.mem.eql(u8, l.key, "provisions")) {
        capped += l.target * part_mod.tons(l.key);
    };
    try std.testing.expect(capped <= p.capacity * (ammo_share_pct + armor_share_pct + medical_share_pct) / 100);
    var ammo_tons: u32 = 0;
    var provisions: ?Line = null;
    for (p.lines) |l| {
        try std.testing.expect(l.floor <= l.target);
        if (std.mem.startsWith(u8, l.key, "ammo_")) {
            ammo_tons += l.target;
            try std.testing.expect(l.target > 0);
        }
        if (std.mem.eql(u8, l.key, "provisions")) provisions = l;
    }
    try std.testing.expect(ammo_tons <= p.capacity * ammo_share_pct / 100);
    // 24 days of transit plus 14 safety days at a ton a day.
    try std.testing.expect(provisions.?.floor >= 38);
    // A longer line raises the ammo floor.
    const far = try plan(a, &gs, co, 60, 14, 0);
    for (far.lines, 0..) |l, i| if (std.mem.startsWith(u8, l.key, "ammo_")) {
        try std.testing.expect(l.floor >= p.lines[i].floor);
    };
}

// ---- C4b field-supply command handlers moved from commands.zig ----

/// Set the automatic resupply policy for a deployed company.
pub fn setSupplyPolicy(gs: *GameState, company: types.ForceId, min_days: u16, tons: u32, ammo_battles: u8) !void {
    const f = gs.force(company) orelse return error.UnknownForce;
    if (f.echelon != .company) return error.NotACompany;
    var i: usize = 0;
    while (i < gs.supply_policies.items.len) : (i += 1) {
        if (gs.supply_policies.items[i].company == company) {
            if (min_days == 0) {
                _ = gs.supply_policies.orderedRemove(i);
            } else {
                gs.supply_policies.items[i].min_days = min_days;
                gs.supply_policies.items[i].tons = tons;
                gs.supply_policies.items[i].ammo_battles = ammo_battles;
            }
            return;
        }
    }
    if (min_days == 0) return;
    try gs.supply_policies.append(gs.allocator(), .{ .company = company, .min_days = min_days, .tons = tons, .ammo_battles = ammo_battles });
}

/// Trim a deployed company's field stores to its field plan; returns tons moved.
pub fn trimStock(gs: *GameState, company: types.ForceId) !u32 {
    const f = gs.force(company) orelse return error.UnknownForce;
    if (f.echelon != .company) return error.NotACompany;

    // ---- prepare: scratch arena for the plan and move list ----
    var arena = std.heap.ArenaAllocator.init(gs.scratch());
    defer arena.deinit();
    const scratch_allocator = arena.allocator();
    var min_days: u32 = 14;
    var battles: u8 = 0;
    for (gs.supply_policies.items) |sp| if (sp.company == company) {
        min_days = sp.min_days;
        battles = sp.ammo_battles;
    };
    const transit = treasury.courierEtaDays(gs, .{ .company = company });
    const p = try plan(scratch_allocator, gs, company, transit, min_days, battles);
    const site: types.Site = .{ .company = company };

    // Snapshot the keys first: sending home edits the stock map.
    const Move = struct { key: []const u8, excess: u32, line: []const u8 };
    var moves: std.ArrayListUnmanaged(Move) = .empty;
    var moved: u32 = 0;
    if (gs.stockMap(site)) |m| {
        var it = m.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            const have = e.value_ptr.*;
            if (have == 0) continue;
            var target: ?u32 = null;
            for (p.lines) |l| if (std.mem.eql(u8, l.key, key)) {
                target = l.target;
            };
            const def = part_mod.find(key);
            const consumable = part_mod.isComponent(key) or (def != null and (def.?.mount == .ammo or def.?.mount == .none));
            const excess: u32 = if (target) |t| have -| t else if (consumable) have else 0;
            if (excess == 0) continue;
            var date_buf: [10]u8 = undefined;
            const line = try std.fmt.allocPrint(gs.allocator(), "{s} [supply] {s} returns {d} {s} to the home HQ ({s})", .{
                gs.clock.date.text(&date_buf),
                f.name,
                excess,
                key,
                if (target != null) "over the plan's target" else "no line in the plan",
            });
            try moves.append(scratch_allocator, .{ .key = key, .excess = excess, .line = line });
            moved += excess * part_mod.tons(key);
        }
    }
    // Reserve all fallible destinations before the first mutation (rule 12).
    try sites.reserveSendHome(gs, company, moves.items.len);
    try gs.reserveLog(moves.items.len);

    // ---- commit: no fallible operation past this point ----
    for (moves.items) |m| {
        std.debug.assert(gs.takeStock(site, m.key, m.excess));
        sites.sendHomeAssumeCapacity(gs, company, m.key, m.excess);
        gs.event_log.appendAssumeCapacity(.{
            .day = gs.clock.day_index,
            .category = .delivery,
            .company = company,
            .text = m.line,
        });
    }
    return moved;
}

test "trim_stock propagates OutOfMemory and moves nothing" {
    // `outer` owns every byte the campaign arena ever hands out, so
    // detaching the arena's own headroom tracking below cannot leak.
    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 2025 });
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "E", .origin = .CC, .profession = .paymaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    const site: types.Site = .{ .company = co };
    _ = try commands.execute(&gs, .{ .accept_contract = .{ .offer_index = 0, .company = co } });
    _ = gs.takeStock(site, "provisions", gs.stockCount(site, "provisions"));
    try gs.addStock(site, "comp_arm", 1);
    const comp_arm_before = gs.stockCount(site, "comp_arm");
    const orders_before = gs.part_orders.items.len;
    const funds_before = gs.funds;

    // Discard the arena's spare headroom and fail every further allocation
    // (calibrated: 1500 bytes fails inside `trimStock`'s own internal
    // `plan()` call, verified against a stack trace — before it ever
    // touches stock): the refusal must surface as OutOfMemory and send
    // nothing home.
    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    const buf = try std.testing.allocator.alloc(u8, 1500);
    defer std.testing.allocator.free(buf);
    var fba = std.heap.FixedBufferAllocator.init(buf);
    gs.arena.child_allocator = fba.allocator();

    try std.testing.expectError(error.OutOfMemory, commands.execute(&gs, .{ .trim_stock = co }));
    try std.testing.expectEqual(comp_arm_before, gs.stockCount(site, "comp_arm"));
    try std.testing.expectEqual(orders_before, gs.part_orders.items.len);
    try std.testing.expectEqual(funds_before, gs.funds);
}

test "trim_stock is atomic when any allocation fails" {
    const digest = @import("digest.zig");
    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 2025 });
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "E", .origin = .CC, .profession = .paymaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    const site: types.Site = .{ .company = co };
    _ = try commands.execute(&gs, .{ .accept_contract = .{ .offer_index = 0, .company = co } });
    _ = gs.takeStock(site, "provisions", gs.stockCount(site, "provisions"));
    try gs.addStock(site, "ammo_lrm", 30);
    try gs.addStock(site, "ammo_ac20", 3);
    try gs.addStock(site, "comp_arm", 1);

    const before = digest.stateHash(&gs);

    var i: usize = 0;
    while (true) : (i += 1) {
        gs.arena.state.used_list = null;
        gs.arena.state.free_list = null;
        var failing = std.testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = i });
        gs.arena.child_allocator = failing.allocator();

        if (trimStock(&gs, co)) |_| {
            // Success: the state must have changed (work happened).
            try std.testing.expect(digest.stateHash(&gs) != before);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(before, digest.stateHash(&gs));
        }
    }
}

test "trim_stock returns excess and unplanned consumables home, keeps spares" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 2025 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "E", .origin = .CC, .profession = .paymaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    const site: @import("../domain/types.zig").Site = .{ .company = co };
    _ = try commands.execute(&gs, .{ .accept_contract = .{ .offer_index = 0, .company = co } });
    // Overstock one family, add a family nothing fires, a component and a spare laser.
    _ = gs.takeStock(site, "provisions", gs.stockCount(site, "provisions"));
    try gs.addStock(site, "ammo_lrm", 30);
    try gs.addStock(site, "ammo_ac20", 3);
    try gs.addStock(site, "comp_arm", 1);
    try gs.addStock(site, "mlas", 2);
    const before = gs.part_orders.items.len;
    const r = try commands.execute(&gs, .{ .trim_stock = co });
    try std.testing.expect(r.tons_moved > 0);
    try std.testing.expect(gs.part_orders.items.len > before);
    try std.testing.expectEqual(@as(u32, 0), gs.stockCount(site, "comp_arm"));
    try std.testing.expectEqual(@as(u32, 2), gs.stockCount(site, "mlas"));
    var lrm_target: u32 = 0;
    var ac20_planned = false;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try plan(arena.allocator(), &gs, co, treasury.courierEtaDays(&gs, .{ .company = co }), 14, 0);
    for (p.lines) |l| {
        if (std.mem.eql(u8, l.key, "ammo_lrm")) lrm_target = l.target;
        if (std.mem.eql(u8, l.key, "ammo_ac20")) ac20_planned = true;
    }
    try std.testing.expect(gs.stockCount(site, "ammo_lrm") <= lrm_target);
    if (!ac20_planned) try std.testing.expectEqual(@as(u32, 0), gs.stockCount(site, "ammo_ac20"));
    // Trimming again moves nothing.
    try std.testing.expectEqual(@as(u32, 0), (try commands.execute(&gs, .{ .trim_stock = co })).tons_moved);
}

test "deployment eats field stores, then buys local, then goes hungry" {
    const tick = @import("tick.zig");
    const sites_m = @import("sites.zig");
    const finance_mod = @import("../econ/finance.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 2025 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "E", .origin = .CC, .profession = .paymaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    const site: @import("../domain/types.zig").Site = .{ .company = co };

    // Accepting a contract loads the trucks from the home warehouse.
    _ = try commands.execute(&gs, .{ .accept_contract = .{ .offer_index = 0, .company = co } });
    const loaded = gs.stockCount(site, "provisions");
    try std.testing.expect(loaded > 0);
    try std.testing.expect(sites_m.siteTons(&gs, site) <= sites_m.siteCapacityTons(&gs, site).?);
    // No employer convoys, no resupply policy, no float for this test (the
    // deployment defaults would feed them): the trucks are all they have.
    gs.contracts.values()[0].terms.overhead_pct = 0;
    gs.supply_policies.clearRetainingCapacity();
    gs.policies.clearRetainingCapacity();

    // On station, provisions burn daily out of the field stores.
    const c = gs.contracts.values()[0];
    try tick.advanceReading(&gs, c.transit_days + 10);
    try std.testing.expect(gs.stockCount(site, "provisions") < loaded);

    // Stores run dry: either the valve bought local (salvage money) or the
    // company went hungry (no money) — never a silent third option.
    gs.force(co).?.local_funds = 0;
    try tick.advanceReading(&gs, 40);
    const mid = finance_mod.summarize(&gs.ledger, 0, gs.clock.day_index, .{ .company = co });
    try std.testing.expect(gs.force(co).?.supply_shortage_days > 0 or
        mid.category(.supplies) + mid.category(.local_supplies) < 0);

    // ...until a courier arrives and the local-purchase valve opens (the
    // courier takes the map transit, however far this seed's contract is).
    _ = try commands.execute(&gs, .{ .transfer = .{ .from = .outfit, .to = .{ .company = co }, .amount = 500_000 } });
    try tick.advanceReading(&gs, treasury.courierEtaDays(&gs, .{ .company = co }) + 3);
    try std.testing.expectEqual(@as(u16, 0), gs.force(co).?.supply_shortage_days);
    const s = finance_mod.summarize(&gs.ledger, 0, gs.clock.day_index, .{ .company = co });
    try std.testing.expect(s.category(.supplies) + s.category(.local_supplies) < 0);
}

test "the resupply plan keeps a deployed company fed and armed on a long line" {
    const tick = @import("tick.zig");
    const sites_m = @import("sites.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 2025 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "E", .origin = .CC, .profession = .paymaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    const hq = gs.hqs.keys()[0];
    const site: @import("../domain/types.zig").Site = .{ .company = co };
    for (part_mod.munition_keys) |k| try gs.addStock(.{ .hq = hq }, k, 60);
    try gs.addStock(.{ .hq = hq }, "provisions", 400);
    try gs.addStock(.{ .hq = hq }, "medical_supplies", 30);
    try gs.addStock(.{ .hq = hq }, "armor", 60);
    // The nearest offer: the plan is judged on supply, not on a long transit.
    var nearest: usize = 0;
    for (gs.contract_offers.items, 0..) |o, i| if (o.dist_ly < gs.contract_offers.items[nearest].dist_ly) {
        nearest = i;
    };
    _ = try commands.execute(&gs, .{ .accept_contract = .{ .offer_index = nearest, .company = co } });
    // The load-out follows the plan: within capacity, no munitions the company cannot fire.
    const cap = sites_m.siteCapacityTons(&gs, site).?;
    try std.testing.expect(sites_m.siteTons(&gs, site) <= cap);
    _ = try commands.execute(&gs, .{ .set_supply_policy = .{ .company = co, .min_days = 14, .tons = 0 } });
    _ = try commands.execute(&gs, .{ .set_policy = .{ .entity = .{ .company = co }, .floor = 300_000, .monthly_cap = 600_000 } });
    var day: u32 = 0;
    var hungry_days: u32 = 0;
    var dry_battles: u32 = 0;
    while (day < 150) : (day += 1) {
        try tick.advanceReading(&gs, 1);
        try std.testing.expect(sites_m.siteTons(&gs, site) <= cap);
        if (gs.stockCount(site, "provisions") == 0) hungry_days += 1;
    }
    for (gs.event_log.items) |e| if (std.mem.indexOf(u8, e.text, "silenced") != null and std.mem.indexOf(u8, e.text, "| 0 mounts silenced") == null) {
        dry_battles += 1;
    };
    try std.testing.expectEqual(@as(u32, 0), hungry_days);
    try std.testing.expectEqual(@as(u32, 0), dry_battles);
}
