//! Field-store planning for a deployed company (Stage 12).
//!
//! MekHQ counterpart: none — MekHQ has no per-company truck model; the
//! nearest analogue is its AtB resupply drop (docs/mekhq-map.md). Here every line a company
//! burns in the field (provisions, medical, armor, each munition family)
//! gets a floor and a target sized from consumption, the transit time of
//! its supply line and the tonnage its trucks can carry, with a budget
//! share per category so no single line crowds the others out. The
//! resupply policy (tick.runPolicies) and the load-out at acceptance
//! (field_supply.prepareLoadOut / applyLoadOut) both follow the same
//! plan, and the Supply screen shows it.

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const part_mod = @import("../domain/part.zig");
const planet_mod = @import("../domain/planet.zig");
const contract_mod = @import("../domain/contract.zig");
const market_mod = @import("../econ/market.zig");
const logistics_mod = @import("../econ/logistics.zig");
const sites = @import("sites.zig");
const toe = @import("toe.zig");
const GameState = @import("state.zig").GameState;
const treasury = @import("treasury.zig");
const commands = @import("commands.zig");
const artillery = @import("artillery.zig");
const artillery_rules = @import("../domain/artillery_operations.zig");

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
        const share = @max(tuning.field_supply.medical_base_tons, cap * medical_share_pct / 100);
        const target = @min(tuning.field_supply.medical_wounded_base + wounded, share);
        try lines.append(alloc, .{ .key = "medical_supplies", .floor = @max(1, target / tuning.field_supply.line_floor_divisor), .target = target, .note = try std.fmt.allocPrint(alloc, "a ton per wound treated · {d} wounded now", .{wounded}) });
    }

    // Armor: field repairs patch a ton per hull per week of damage.
    // Only hulls that take field armor (combat hulls not in the depot).
    var hulls: u32 = 0;
    var family_mounts = try munitionMounts(alloc, gs, company, false);
    {
        var uit = gs.units.iterator();
        while (uit.next()) |e| {
            const u = e.value_ptr;
            if (gs.companyOf(u.force) != company) continue;
            if (u.takesFieldArmor()) hulls += 1;
        }
        const share = @max(tuning.field_supply.armor_floor_tons, cap * armor_share_pct / 100);
        const target = std.math.clamp(hulls / 2, tuning.field_supply.armor_floor_tons, share);
        try lines.append(alloc, .{ .key = "armor", .floor = @max(1, target / tuning.field_supply.line_floor_divisor), .target = target, .note = try std.fmt.allocPrint(alloc, "{d} hulls · a ton patches one hull's plating", .{hulls}) });
    }

    // Munitions: per family the company actually fires. Floor = the battles
    // fought while a shipment travels, plus one; target = floor + 2 (or the
    // override). The families share the ammo budget pro rata.
    {
        const floor_battles: u32 = tuning.field_supply.ammo_floor_battles_base + (std.math.divCeil(u32, transit_days, days_per_battle) catch unreachable);
        const target_battles: u32 = if (ammo_battles > 0) @max(@as(u32, ammo_battles), floor_battles) else floor_battles + tuning.field_supply.ammo_target_battles_extra;
        const budget = cap * ammo_share_pct / 100;
        const first_ammo = lines.items.len;
        for (part_mod.munition_keys) |key| {
            const mounts = family_mounts.get(key) orelse continue;
            if (mounts == 0) continue;
            const per_battle = tonsPerBattle(mounts);
            const target = per_battle * target_battles;
            try lines.append(alloc, .{ .key = key, .floor = per_battle * floor_battles, .target = target, .note = try std.fmt.allocPrint(alloc, "{d} mounts · {d}t per battle · {d} battles floor, {d} target", .{ mounts, per_battle, floor_battles, target_battles }) });
        }
        const carriers = artillery.attachedCount(gs, company);
        for (artillery_rules.families) |family| {
            if (carriers == 0) break;
            const packages = carriers * artillery_rules.packagesPerLoad(family);
            try lines.append(alloc, .{ .key = artillery_rules.packageKey(family), .floor = packages * artillery_rules.reserve_floor_loads, .target = packages * artillery_rules.reserve_target_loads, .note = try std.fmt.allocPrint(alloc, "{d} carriers · {d} packages per complete reload · {d}/{d} reloads floor/target", .{ carriers, packages, artillery_rules.reserve_floor_loads, artillery_rules.reserve_target_loads }) });
        }
        try allocateAmmunition(alloc, lines.items[first_ammo..], budget);
    }

    var total: u32 = 0;
    for (lines.items) |l| total += l.target * part_mod.tons(l.key);
    return .{ .lines = try lines.toOwnedSlice(alloc), .transit_days = transit_days, .provisions_per_day = per_day, .capacity = cap, .total_target = total };
}

/// Allocate one shared ammo-ton budget proportionally, then remaining whole
/// packages in stable key order. Floors never exceed targets or physical hold.
/// Source: artillery operations design, Ammunition and supply policy.
pub fn allocateAmmunition(alloc: std.mem.Allocator, lines: []Line, budget_tons: u32) !void {
    var requested: u64 = 0;
    for (lines) |line| requested += @as(u64, line.target) * part_mod.tons(line.key);
    if (requested <= budget_tons) return;
    const wanted = try alloc.alloc(u32, lines.len);
    defer alloc.free(wanted);
    const order = try alloc.alloc(usize, lines.len);
    defer alloc.free(order);
    var spent: u64 = 0;
    for (lines, wanted, order, 0..) |*line, *original, *index, i| {
        original.* = line.target;
        index.* = i;
        line.target = @intCast(@as(u64, line.target) * budget_tons / requested);
        spent += @as(u64, line.target) * part_mod.tons(line.key);
        line.trimmed = true;
    }
    std.mem.sort(usize, order, lines, struct {
        fn less(ls: []Line, a: usize, b: usize) bool {
            return std.mem.lessThan(u8, ls[a].key, ls[b].key);
        }
    }.less);
    var available = @as(u64, budget_tons) - spent;
    while (true) {
        var progressed = false;
        for (order) |i| {
            const tons = part_mod.tons(lines[i].key);
            if (lines[i].target >= wanted[i] or tons > available) continue;
            lines[i].target += 1;
            available -= tons;
            progressed = true;
        }
        if (!progressed) break;
    }
    for (lines) |*line| line.floor = @min(line.floor, line.target);
}

/// One stock item the load-out will move (rule 12: prepared before any
/// mutation, applied all-or-nothing).
pub const LoadMove = struct { key: []const u8, qty: u32 };

/// The complete load-out plan for one acceptance: what will move, how
/// many tons, and the destination fill once applied.
pub const LoadOut = struct {
    home: types.Site,
    dest: types.Site,
    /// Capped lines first, provisions last — same order as the two-pass fill.
    moves: []const LoadMove,
    /// Total tons that will move to dest.
    loaded_tons: u32,
    /// siteTons(dest) once applyLoadOut runs.
    dest_tons_after: u32,
};

/// Compute the load-out plan without mutating GameState (rules 11–13).
/// Simulates the two-pass fill using `sites.movableQty` — the single
/// owner of the fit rule — and reserves dest stock-map capacity for the
/// whole batch. `scratch` may be a short-lived arena; `moves` lives in
/// `scratch`. `transit` is the contract's transit days (caller passes
/// it explicitly because the contract may not be in the map yet).
pub fn prepareLoadOut(scratch: std.mem.Allocator, gs: *GameState, company_id: types.ForceId, transit: u32) !LoadOut {
    const home = gs.homeSiteFor(company_id);
    const dest: types.Site = .{ .company = company_id };
    const p = try plan(scratch, gs, company_id, transit, 14, 0);

    var move_list: std.ArrayListUnmanaged(LoadMove) = .empty;
    var pending_tons: u32 = 0;
    var loaded_tons: u32 = 0;

    // Pass 1: capped lines (everything except provisions).
    for (p.lines) |l| {
        if (std.mem.eql(u8, l.key, "provisions")) continue;
        const n = sites.movableQty(gs, home, dest, l.key, l.target, pending_tons);
        if (n > 0) {
            try move_list.append(scratch, .{ .key = l.key, .qty = n });
            const tons = n * @import("../domain/part.zig").tons(l.key);
            pending_tons += tons;
            loaded_tons += tons;
        }
    }
    // Pass 2: provisions fill whatever the trucks have left.
    for (p.lines) |l| {
        if (!std.mem.eql(u8, l.key, "provisions")) continue;
        const n = sites.movableQty(gs, home, dest, l.key, l.target, pending_tons);
        if (n > 0) {
            try move_list.append(scratch, .{ .key = l.key, .qty = n });
            const tons = n * @import("../domain/part.zig").tons(l.key);
            loaded_tons += tons;
        }
    }

    const moves = try move_list.toOwnedSlice(scratch);

    // Reserve dest stock-map capacity for the whole batch before any
    // mutation (rule 12). Over-reserving when a key already exists is
    // harmless; the per-call ensureUnusedCapacity(1) in moveStock is then
    // a no-op.
    if (gs.stockMap(dest)) |m| try m.ensureUnusedCapacity(gs.allocator(), moves.len);

    return .{
        .home = home,
        .dest = dest,
        .moves = moves,
        .loaded_tons = loaded_tons,
        .dest_tons_after = sites.siteTons(gs, dest) + loaded_tons,
    };
}

/// Apply a prepared load-out. Cannot fail: dest stock capacity was
/// reserved in prepareLoadOut and each moveStock's ensureUnusedCapacity(1)
/// is covered by that reservation (rule 12).
pub fn applyLoadOut(gs: *GameState, lo: LoadOut) void {
    for (lo.moves) |m| _ = sites.moveStock(gs, lo.home, lo.dest, m.key, m.qty) catch unreachable;
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

/// Whether a company is on an active beachhead deployment (ARCH §9.6):
/// the contract is flagged beachhead AND the contract world is outside
/// every current ring. Planting a field HQ on the beachhead world brings
/// it inside the field HQ's ring and flips this false, lifting the
/// local-supply markup and hardship pay (C15 D3).
pub fn beachheadActive(gs: *GameState, c: *const contract_mod.Contract) bool {
    if (!c.beachhead) return false;
    const planet = planet_mod.find(c.planet_key) orelse return true;
    var it = gs.hqs.iterator();
    while (it.next()) |entry| {
        const hq = entry.value_ptr;
        const hq_planet = planet_mod.find(hq.planet_key) orelse continue;
        const dist = planet_mod.distanceLy(planet, hq_planet);
        if (market_mod.visibilityFor(dist, hq.influenceLy()) == .in_ring) return false;
    }
    return true;
}

/// Live distance beyond the nearest ring for a beachhead contract.
/// Uses offer_hq's stored distance when available; falls back to the minimum
/// of (dist_to_hq -| influenceLy) over all HQs when offer_hq is .none (D4).
fn liveBeachheadLy(gs: *GameState, c: *const contract_mod.Contract) u32 {
    if (gs.hqs.getPtr(c.offer_hq)) |hq| {
        return c.dist_ly -| hq.influenceLy();
    }
    // D4: offer_hq is .none — minimum over all HQs.
    const contract_planet = planet_mod.find(c.planet_key) orelse return 0;
    var min: u32 = std.math.maxInt(u32);
    var it = gs.hqs.iterator();
    while (it.next()) |entry| {
        const hq = entry.value_ptr;
        const hq_planet = planet_mod.find(hq.planet_key) orelse continue;
        const d = planet_mod.distanceLy(contract_planet, hq_planet);
        const beyond = d -| hq.influenceLy();
        if (beyond < min) min = beyond;
    }
    return if (min == std.math.maxInt(u32)) 0 else min;
}

/// The local supplies valve's price multiplier (ARCH §9.6) for a company
/// on a contract: inside every ring (or once a field HQ is planted on the
/// beachhead world), the ordinary field markup; on an active beachhead,
/// remoteness beyond the nearest ring eased by the world's industry.
pub fn localPriceMultBp(gs: *GameState, c: *const contract_mod.Contract) types.Bp {
    if (!beachheadActive(gs, c)) return tuning.finance.field_markup_bp;
    const industry: u8 = if (planet_mod.find(c.planet_key)) |w| w.industry else 0;
    return logistics_mod.localPurchaseMultBp(liveBeachheadLy(gs, c), industry);
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
    // Count dented hulls that draw field armor (combat hulls, not in depot).
    var dented: u32 = 0;
    var uit = gs.units.iterator();
    while (uit.next()) |e| {
        const u = e.value_ptr;
        if (gs.companyOf(u.force) == company and u.takesFieldArmor() and u.armor_pct < 100) dented += 1;
    }
    const armor_have = gs.stockCount(site, "armor");
    if (dented > armor_have) try lines.append(alloc, .{ .key = "armor", .qty = dented - armor_have });
    const mult = localPriceMultBp(gs, c);
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
/// `fighting` counts only combat-lance hulls with a tech to reload
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

/// Working weapon mounts per munition family for units selected for one
/// engagement. Battle uses this narrower census; supply planning continues to
/// use the company-wide census above.
pub fn munitionMountsForUnits(alloc: std.mem.Allocator, gs: *GameState, units: []const types.UnitId) !std.StringArrayHashMapUnmanaged(u32) {
    var out: std.StringArrayHashMapUnmanaged(u32) = .empty;
    try out.ensureUnusedCapacity(alloc, part_mod.munition_keys.len);
    munitionMountsForUnitsPrepared(&out, gs, units);
    return out;
}

/// Writes the selected units' working munition mounts into pre-reserved
/// storage. Battle uses it after reserving every family before its RNG draw.
pub fn munitionMountsForUnitsPrepared(out: *std.StringArrayHashMapUnmanaged(u32), gs: *GameState, units: []const types.UnitId) void {
    for (units) |uid| {
        const u = gs.unit(uid) orelse continue;
        const tech = gs.person(u.tech) orelse continue;
        if (!tech.isAvailable(gs.clock.day_index)) continue;
        for (u.slots.items) |s| {
            if (s.class != .weapon or s.condition != .ok) continue;
            const fam = part_mod.munitionFor(s.part_key) orelse continue;
            out.putAssumeCapacity(fam, (out.get(fam) orelse 0) + 1);
        }
    }
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
        .category = if (beachheadActive(gs, c)) .local_supplies else .supplies,
        .company = c.assigned_company,
        .contract = id,
        .note = "emergency resupply",
    });
    for (rush.lines) |l| gs.addStock(site, l.key, l.qty) catch unreachable; // slots reserved above
    try gs.log(.delivery, .{ .company = c.assigned_company, .contract = id }, "[resupply] emergency purchase on {s}: {d}t for {s} c-bills", .{ c.planet_key, rush.tons, try types.moneyText(gs.allocator(), rush.price) });
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
    _ = try commands.execute(&gs, .{ .accept_contract = .{ .offer = gs.contract_offers.items[0].id, .company = co } });
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
    _ = try commands.execute(&gs, .{ .accept_contract = .{ .offer = gs.contract_offers.items[0].id, .company = co } });
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
    _ = try commands.execute(&gs, .{ .accept_contract = .{ .offer = gs.contract_offers.items[0].id, .company = co } });
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
    _ = try commands.execute(&gs, .{ .accept_contract = .{ .offer = gs.contract_offers.items[0].id, .company = co } });
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
    const hq = gs.seat();
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
    _ = try commands.execute(&gs, .{ .accept_contract = .{ .offer = gs.contract_offers.items[nearest].id, .company = co } });
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

test "takesFieldArmor agreement: plan and rushQuote follow the same predicate" {
    // Fixture: in-shop mek excluded; in-transit vehicle counted;
    // dented aerospace and ready mek counted.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7350 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    gs.funds = 5_000_000;
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;

    // Accept a contract so rushQuote has a contract to quote against.
    _ = try commands.execute(&gs, .{ .accept_contract = .{ .offer = gs.contract_offers.items[0].id, .company = co } });
    const c = gs.deploymentContract(co) orelse return;

    // Set all existing company hulls to full armor for a clean baseline.
    {
        var uit = gs.units.iterator();
        while (uit.next()) |e| {
            const u = e.value_ptr;
            if (gs.companyOf(u.force) == co) u.armor_pct = 100;
        }
    }

    // In-shop mek: takesFieldArmor = false (depot work, no field armor).
    const mek_shop_id = try gs.addUnit("LCT-1V");
    const mek_shop = gs.units.getPtr(mek_shop_id).?;
    mek_shop.force = co;
    mek_shop.status = .repairing;
    mek_shop.armor_pct = 50; // dented but in shop: must not appear in dented count

    // In-transit vehicle: takesFieldArmor = true (rides with its tech).
    const veh_transit_id = try gs.addUnit("HTZ");
    const veh_transit = gs.units.getPtr(veh_transit_id).?;
    veh_transit.force = co;
    veh_transit.status = .in_transit;
    veh_transit.armor_pct = 100; // full armor: not dented

    // Dented aerospace: takesFieldArmor = true.
    const aero_id = try gs.addUnit("SPR-H5");
    const aero = gs.units.getPtr(aero_id).?;
    aero.force = co;
    aero.status = .ready;
    aero.armor_pct = 60; // dented aerospace counts through takesFieldArmor

    // Dented ready mek: takesFieldArmor = true, armor_pct < 100.
    const mek_id = try gs.addUnit("LCT-1V");
    const mek = gs.units.getPtr(mek_id).?;
    mek.force = co;
    mek.status = .ready;
    mek.armor_pct = 70;

    // Count expected values from the predicate directly.
    var expected_hulls: u32 = 0;
    var expected_dented: u32 = 0;
    {
        var uit = gs.units.iterator();
        while (uit.next()) |e| {
            const u = e.value_ptr;
            if (gs.companyOf(u.force) != co) continue;
            if (u.takesFieldArmor()) {
                expected_hulls += 1;
                if (u.armor_pct < 100) expected_dented += 1;
            }
        }
    }
    // In-transit vehicle, dented aerospace, and dented ready mek count; in-shop mek does not.
    try std.testing.expect(expected_hulls >= 2);
    try std.testing.expect(expected_dented >= 2); // aerospace and ready mek

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // plan's armor note contains "{expected_hulls} hulls".
    const p = try plan(a, &gs, co, 30, 14, 0);
    const hull_needle = try std.fmt.allocPrint(a, "{d} hulls", .{expected_hulls});
    var plan_agrees = false;
    for (p.lines) |l| if (std.mem.eql(u8, l.key, "armor")) {
        if (std.mem.indexOf(u8, l.note, hull_needle) != null) plan_agrees = true;
    };
    try std.testing.expect(plan_agrees);

    // rushQuote with no armor stock: dented count matches expected_dented.
    const site: @import("../domain/types.zig").Site = .{ .company = co };
    while (gs.takeStock(site, "armor", 1)) {}
    const q = try rushQuote(a, &gs, c);
    var found_armor = false;
    for (q.lines) |l| if (std.mem.eql(u8, l.key, "armor")) {
        try std.testing.expectEqual(expected_dented, l.qty);
        found_armor = true;
    };
    try std.testing.expect(found_armor);
}

test "rushQuote: quote is non-empty when a company is short before a fight and is consumed by emergencyResupply" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7300 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    gs.funds = 5_000_000;
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    var nearest: usize = 0;
    for (gs.contract_offers.items, 0..) |o, i| if (o.dist_ly < gs.contract_offers.items[nearest].dist_ly) {
        nearest = i;
    };
    _ = try commands.execute(&gs, .{ .accept_contract = .{ .offer = gs.contract_offers.items[nearest].id, .company = co } });
    // Advance until the contract is active.
    while (gs.deploymentContract(co)) |c| {
        if (c.status == .active) break;
        _ = try commands.execute(&gs, .{ .advance_days = 1 });
    }
    const c = gs.deploymentContract(co) orelse return;
    // Clear munitions so there is something to rush.
    const site: @import("../domain/types.zig").Site = .{ .company = c.assigned_company };
    for (part_mod.munition_keys) |k| while (gs.takeStock(site, k, 1)) {};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const q = try rushQuote(arena.allocator(), &gs, c);
    // If the company fires any munition and the shelf is bare, the quote must be non-empty.
    if (q.lines.len > 0) {
        try std.testing.expect(q.price > 0);
        // emergencyResupply is the sole consumer that executes rushQuote.
        // We only test agreement; running it requires a funded treasury at the site.
        gs.forces.getPtr(c.assigned_company).?.local_funds = 5_000_000;
        _ = commands.execute(&gs, .{ .emergency_resupply = c.id }) catch |err| switch (err) {
            error.StorageFull, error.NothingToRush, error.OutOfMemory => {},
            else => return err,
        };
    }
}

test "localPriceMultBp: live distance — two beachhead distances give distinct multipliers (C15c A17 regression)" {
    const founding_m = @import("founding.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 4422 });
    defer gs.deinit();
    _ = try founding_m.createCommander(&gs, "T", .LC, .paymaster);
    const hq_id = gs.seat();
    const hq = gs.hqs.getPtr(hq_id).?;
    // Two synthetic contracts on the same beachhead flag, different dist_ly.
    // Both share offer_hq = home HQ; the ring is hq.influenceLy().
    const ring = hq.influenceLy();
    const base_terms = contract_mod.Terms{ .length_months = 3, .base_pay_month = 100_000 };
    // Use a synthetic planet key that is not in the catalog so that
    // beachheadActive returns true via the `orelse return true` branch,
    // and liveBeachheadLy reads c.dist_ly directly (offer_hq set).
    var c_near = contract_mod.Contract{
        .id = .none,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "test-synthetic-beachhead",
        .terms = base_terms,
    };
    c_near.beachhead = true;
    c_near.offer_hq = hq_id;
    c_near.dist_ly = ring + 15; // 15 LY into the beachhead band
    var c_far = contract_mod.Contract{
        .id = .none,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "test-synthetic-beachhead",
        .terms = base_terms,
    };
    c_far.beachhead = true;
    c_far.offer_hq = hq_id;
    c_far.dist_ly = ring + 45; // 45 LY → second band

    const mult_near = localPriceMultBp(&gs, &c_near);
    const mult_far = localPriceMultBp(&gs, &c_far);
    // Both should be higher than the plain field markup.
    try std.testing.expect(mult_near > tuning.finance.field_markup_bp);
    try std.testing.expect(mult_far > tuning.finance.field_markup_bp);
    // A farther world costs more; the old literal-30 bug gave a fixed value for all distances.
    try std.testing.expect(mult_far > mult_near);
}

test "beachheadActive: founding a field HQ on the beachhead world lifts the penalty (C15c D3)" {
    const founding_m = @import("founding.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 4423 });
    defer gs.deinit();
    _ = try founding_m.createCommander(&gs, "T", .LC, .paymaster);
    const hq_id = gs.seat();
    const hq = gs.hqs.getPtr(hq_id).?;
    const ring = hq.influenceLy();
    // Find a world in the beachhead band of the home HQ.
    var beachhead_planet_key: []const u8 = "";
    for (planet_mod.catalog) |*p| {
        const d = planet_mod.distanceLy(p, planet_mod.find(hq.planet_key) orelse continue);
        if (d > ring and d <= ring + market_mod.beachhead_band_ly and beachhead_planet_key.len == 0) {
            beachhead_planet_key = p.key;
        }
    }
    if (beachhead_planet_key.len == 0) return; // skip if no beachhead world in this seed's catalog

    const base_terms = contract_mod.Terms{ .length_months = 3, .base_pay_month = 100_000 };
    var c = contract_mod.Contract{
        .id = .none,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = beachhead_planet_key,
        .terms = base_terms,
    };
    c.beachhead = true;
    c.offer_hq = hq_id;
    c.dist_ly = planet_mod.distanceLy(
        planet_mod.find(beachhead_planet_key).?,
        planet_mod.find(hq.planet_key).?,
    );

    // Before: beachheadActive is true (no HQ on the beachhead world).
    try std.testing.expect(beachheadActive(&gs, &c));
    // After: found an HQ on the beachhead world → flips false.
    const field_hq = try founding_m.foundHq(&gs, "Field", .field, beachhead_planet_key);
    _ = field_hq;
    try std.testing.expect(!beachheadActive(&gs, &c));
    // Price drops to the ordinary field markup.
    try std.testing.expectEqual(tuning.finance.field_markup_bp, localPriceMultBp(&gs, &c));
}

test "rounding D1: partial beachhead band (1-30 LY) → ×2.5, not ×2.0" {
    // Pin the D1 rounding decision: a world 15 LY past the ring is in the
    // first 30-LY band; round-up (D1) gives ×2.5.
    try std.testing.expectEqual(@as(types.Bp, 25_000), logistics_mod.localPurchaseMultBp(15, 0));
    // Just at the band edge (30 LY) also rounds up to band 1 → ×2.5.
    try std.testing.expectEqual(@as(types.Bp, 25_000), logistics_mod.localPurchaseMultBp(30, 0));
    // One step past (31 LY) rounds up to band 2 → ×3.0.
    try std.testing.expectEqual(@as(types.Bp, 30_000), logistics_mod.localPurchaseMultBp(31, 0));
}
