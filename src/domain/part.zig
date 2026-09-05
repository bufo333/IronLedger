//! Parts: catalog references, inventory, acquisition orders.
//! Mirrors MekHQ `parts/*` + `Quartermaster` acquisition flow. Stage 5.

const std = @import("std");
const types = @import("types.zig");

/// How a mountable item attaches (Stage 10 MekLab).
pub const MountType = enum { none, energy, ballistic, missile, equipment, ammo };

/// Who builds it (12C.14): periphery worlds source Inner Sphere parts
/// rated D or worse with a penalty.
pub const TechBase = enum { inner_sphere, periphery };

/// TechManual availability code for 3025 (A everywhere … F almost nowhere).
pub const Availability = enum { a, b, c, d, e, f };

/// The sourcing modifiers on an acquisition roll (12C.14).
pub const Sourcing = struct {
    avail: i32,
    periphery: i32,
    comms: i32,

    pub fn total(self: Sourcing) i32 {
        return self.avail + self.periphery + self.comms;
    }

    /// "availability D −1, periphery market −2, comms +1" (empty when all zero).
    pub fn text(self: Sourcing, alloc: std.mem.Allocator, def: *const PartDef) ![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        if (self.avail != 0) try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "availability {s} {s}{d}", .{ @tagName(def.availability), if (self.avail > 0) "+" else "", self.avail }));
        if (self.periphery != 0) {
            if (out.items.len > 0) try out.appendSlice(alloc, ", ");
            try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "periphery market {d}", .{self.periphery}));
        }
        if (self.comms != 0) {
            if (out.items.len > 0) try out.appendSlice(alloc, ", ");
            try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "comms reach +{d}", .{self.comms}));
        }
        return out.toOwnedSlice(alloc);
    }
};

/// What this world and this HQ do to a part's acquisition roll.
pub fn sourcing(def: *const PartDef, periphery_world: bool, comms_level: u8) Sourcing {
    const t = @import("tuning.zig").t.market;
    const avail: i32 = switch (def.availability) {
        .a => t.avail_mod.a,
        .b => t.avail_mod.b,
        .c => t.avail_mod.c,
        .d => t.avail_mod.d,
        .e => t.avail_mod.e,
        .f => t.avail_mod.f,
    };
    const scarce = @intFromEnum(def.availability) >= @intFromEnum(Availability.d);
    return .{
        .avail = avail,
        .periphery = if (periphery_world and def.tech_base == .inner_sphere and scarce) -t.periphery_penalty else 0,
        .comms = @as(i32, comms_level / 2) * t.comms_bonus_per_two_levels,
    };
}

/// Static part definition; catalog data in data/parts.zon.
pub const PartDef = struct {
    key: []const u8,
    name: []const u8,
    cost: types.CBills,
    rarity: types.Rarity,
    /// Storage/shipping weight per stock unit (Stage 9B).
    pallet_tons: u16 = 1,
    /// Sourcing (12C.14): who builds it and how widely it is stocked.
    tech_base: TechBase = .inner_sphere,
    availability: Availability = .c,
    // Construction facts for mountable items (Stage 10); `mount == .none`
    // means the lab can't install it.
    mass_half_tons: u16 = 0,
    crits: u8 = 0,
    heat: u8 = 0,
    mount: MountType = .none,

    pub fn mountable(self: *const PartDef) bool {
        return self.mount != .none;
    }
};

pub const catalog: []const PartDef = @import("parts_zon");

pub fn find(key: []const u8) ?*const PartDef {
    for (catalog) |*p| {
        if (std.mem.eql(u8, p.key, key)) return p;
    }
    return null;
}

pub fn cost(key: []const u8) types.CBills {
    return if (find(key)) |p| p.cost else 25_000; // unknown parts: generic price
}

pub fn tons(key: []const u8) u32 {
    return if (find(key)) |p| p.pallet_tons else 1;
}

/// Munition family a weapon draws on; null for energy weapons and
/// non-weapons. Per-munition tracking at family granularity (ARCH §7).
pub fn munitionFor(weapon_key: []const u8) ?[]const u8 {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "ac5", "ammo_ac5" },   .{ "ac20", "ammo_ac20" }, .{ "mg", "ammo_mg" },
        .{ "ac2", "ammo_ac2" },   .{ "ac10", "ammo_ac10" },
        .{ "lrm5", "ammo_lrm" },  .{ "lrm10", "ammo_lrm" }, .{ "lrm15", "ammo_lrm" },
        .{ "lrm20", "ammo_lrm" }, .{ "srm2", "ammo_srm" },  .{ "srm4", "ammo_srm" },
        .{ "srm6", "ammo_srm" },
    };
    for (table) |row| {
        if (std.mem.eql(u8, row[0], weapon_key)) return row[1];
    }
    return null;
}

pub const munition_keys = [_][]const u8{ "ammo_ac2", "ammo_ac5", "ammo_ac10", "ammo_ac20", "ammo_lrm", "ammo_srm", "ammo_mg" };

/// Short label for a munition family ("AC/5", "LRM").
pub fn munitionLabel(key: []const u8) []const u8 {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "ammo_ac2", "AC/2" }, .{ "ammo_ac5", "AC/5" }, .{ "ammo_ac10", "AC/10" }, .{ "ammo_ac20", "AC/20" },
        .{ "ammo_lrm", "LRM" },  .{ "ammo_srm", "SRM" },  .{ "ammo_mg", "MG" },
    };
    for (table) |row| if (std.mem.eql(u8, row[0], key)) return row[1];
    return key;
}

pub const component_keys = [_][]const u8{ "comp_head", "comp_ct", "comp_torso", "comp_arm", "comp_leg", "comp_chassis" };

pub fn isComponent(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "comp_");
}

/// The structural component a structure slot needs (Stage 9C), by the
/// location prefix of its slot key ("lt.structure" → side torso).
pub fn componentForSlot(slot_key: []const u8) []const u8 {
    if (std.mem.startsWith(u8, slot_key, "hd.")) return "comp_head";
    if (std.mem.startsWith(u8, slot_key, "ct.")) return "comp_ct";
    if (std.mem.startsWith(u8, slot_key, "lt.") or std.mem.startsWith(u8, slot_key, "rt.")) return "comp_torso";
    if (std.mem.startsWith(u8, slot_key, "la.") or std.mem.startsWith(u8, slot_key, "ra.")) return "comp_arm";
    if (std.mem.startsWith(u8, slot_key, "ll.") or std.mem.startsWith(u8, slot_key, "rl.")) return "comp_leg";
    return "comp_chassis";
}

/// Bay days to fabricate one component. // TUNE
pub fn fabricationDays(key: []const u8) u32 {
    if (std.mem.eql(u8, key, "comp_ct")) return 12;
    if (std.mem.eql(u8, key, "comp_torso")) return 9;
    if (std.mem.eql(u8, key, "comp_leg")) return 8;
    if (std.mem.eql(u8, key, "comp_arm")) return 6;
    if (std.mem.eql(u8, key, "comp_head")) return 5;
    return 7;
}

/// Provisions: one ton feeds this many person-days (~5 kg/person/day). // TUNE
pub const provisions_person_days_per_ton = 200;

/// A quantity of one catalog part sitting in an HQ or company inventory.
pub const StockLine = struct {
    part_key: []const u8,
    quantity: u32,
};

pub const OrderStatus = enum { sourcing, in_transit, delivered, failed, cancelled };

/// An acquisition order: logistics-admin sourcing roll (MekHQ-style, modified
/// by planet tech/industry rating and HQ facilities), then transit to ETA.
pub const AcquisitionOrder = struct {
    part_key: []const u8,
    quantity: u32,
    /// Where the goods land (Stage 9B): HQ warehouse or a deployed company.
    dest: types.Site = .outfit,
    ordered_day: u32,
    eta_day: ?u32 = null,
    cost: types.CBills,
    status: OrderStatus = .sourcing,
};

test "12C.14: sourcing modifiers — scarce parts, periphery worlds and comms reach" {
    const ppc = find("ppc").?;
    try std.testing.expect(@intFromEnum(ppc.availability) >= @intFromEnum(Availability.d));
    const home = sourcing(ppc, false, 0);
    const fringe = sourcing(ppc, true, 0);
    const wired = sourcing(ppc, true, 4);
    try std.testing.expect(fringe.total() < home.total());
    try std.testing.expect(wired.total() > fringe.total());
    const mlas = find("mlas").?;
    try std.testing.expectEqual(@as(i32, 0), sourcing(mlas, true, 0).periphery); // a staple is a staple everywhere
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const txt = try fringe.text(arena.allocator(), ppc);
    try std.testing.expect(std.mem.indexOf(u8, txt, "periphery market") != null);
}

test "every chassis loadout part resolves in the part catalog" {
    const chassis = @import("chassis.zig");
    for (chassis.catalog) |c| {
        for (c.loadout) |slot| {
            try std.testing.expect(find(slot.part) != null);
        }
    }
    for (component_keys) |k| try std.testing.expect(find(k) != null); // the fabrication guarantee
}

test "structure slots map to per-location components" {
    try std.testing.expectEqualStrings("comp_torso", componentForSlot("rt.structure"));
    try std.testing.expectEqualStrings("comp_leg", componentForSlot("ll.structure"));
    try std.testing.expectEqualStrings("comp_head", componentForSlot("hd.structure"));
    try std.testing.expectEqualStrings("comp_chassis", componentForSlot("chassis.structure"));
    try std.testing.expect(isComponent("comp_arm") and !isComponent("armor"));
}

test "acquisition order starts unsourced" {
    const o: AcquisitionOrder = .{ .part_key = "ac5", .quantity = 2, .ordered_day = 10, .cost = 25_000 };
    try std.testing.expectEqual(OrderStatus.sourcing, o.status);
    try std.testing.expect(o.eta_day == null);
}
