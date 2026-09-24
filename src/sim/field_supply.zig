//! Field-store planning for a deployed company (Stage 12).
//!
//! MekHQ counterpart: none — MekHQ has no per-company truck model; the
//! nearest analogue is its AtB resupply drop. Here every line a company
//! burns in the field (provisions, medical, armor, each munition family)
//! gets a floor and a target sized from consumption, the transit time of
//! its supply line and the tonnage its trucks can carry, with a budget
//! share per category so no single line crowds the others out. The
//! resupply policy (tick.runPolicies) and the load-out at acceptance
//! (state.loadOutCompany) both follow the same plan, and the Supply
//! screen shows it.

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const part_mod = @import("../domain/part.zig");
const GameState = @import("state.zig").GameState;

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
    const cap = gs.siteCapacityTons(.{ .company = company }) orelse 0;
    const heads = gs.companyHeadcount(company);
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
        const floor_battles: u32 = 1 + (std.math.divCeil(u32, transit_days, days_per_battle) catch 0);
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

/// Tons of one munition family an engagement burns: a ton feeds
/// `mounts_per_ammo_ton` mounts.
pub fn tonsPerBattle(mounts: u32) u32 {
    return std.math.divCeil(u32, mounts, mounts_per_ammo_ton) catch 0;
}

/// Engagements of one munition family the company's stores can feed.
pub const AmmoFights = struct { key: []const u8, fights: u32 };

/// Per family the company's fighting mounts fire, in `part.munition_keys`
/// order: whole engagements the stock at its site feeds.
pub fn ammoFights(alloc: std.mem.Allocator, gs: *GameState, company: types.ForceId) ![]AmmoFights {
    const mounts = try munitionMounts(alloc, gs, company, true);
    const site = gs.siteForForce(company);
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
    const site = gs.siteForForce(company);
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

test "the plan fits the trucks and only stocks munitions the company fires" {
    const commands = @import("commands.zig");
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
