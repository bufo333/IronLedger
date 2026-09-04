//! TO&E: the force tree. Outfit → battalion → company → lance.
//! Mirrors MekHQ `force/Force.java`, extended so *companies* are deployable
//! profit centers (ARCH §3.1) with attached support lances.

const std = @import("std");
const types = @import("types.zig");

pub const Echelon = enum {
    outfit, // the whole mercenary command (the player)
    battalion,
    company, // unit of contract assignment
    support_company, // the attached support echelon (e.g. "Omega Company")
    air_company, // aerofighter wing attached via an HQ's air slot (ARCH §9.3)
    lance, // unit of battle resolution
    air_lance,
    support_lance, // see SupportLanceKind — grouped under a support_company
};

/// The support company's lance kinds (ARCH §9.3). Each feeds a concrete
/// campaign/autoresolve modifier — support wins battles here.
pub const SupportLanceKind = enum {
    mash, // wounded survival, healing speed in the field
    security, // prisoner handling, rear security, ransom events
    mess, // fatigue/morale recovery, provisions buffer
    salvage, // post-battle salvage yield
    transport, // supply buffer, shipment handling at the deployed end
};

/// AtB lance roles: what a lance is tasked with while on contract; drives
/// scenario generation odds and training XP (Stage 6/7).
pub const LanceRole = enum { fighting, defense, scouting, training, unassigned };

pub const Force = struct {
    id: types.ForceId,
    parent: types.ForceId = .none,
    /// Player-editable (ARCH §9.8 identity).
    name: []const u8,
    /// Emblem image bytes (png/jpg), player-provided; shown on rosters/AARs.
    emblem: ?[]const u8 = null,
    /// Local operating funds for deployed companies: field purchases draw
    /// only from this — the brigade treasury cannot teleport (ARCH §9.8).
    local_funds: types.CBills = 0,
    /// Field stores (Stage 9B): travel with the company, capped by its
    /// logistics trucks' cargo tonnage.
    stock: std.StringArrayHashMapUnmanaged(u32) = .empty,
    /// Consecutive days the company went hungry (no provisions, no local
    /// funds to buy them). Feeds battle mods and morale.
    supply_shortage_days: u16 = 0,
    echelon: Echelon,
    commander: types.PersonId = .none,
    /// For companies: the HQ that supplies it (shipments originate there).
    supplying_hq: types.HqId = .none,
    role: LanceRole = .unassigned,
    support_kind: ?SupportLanceKind = null, // set iff echelon == .support_lance
    // Rotation tracking for companies (ARCH §9.7): each contract completed
    // without returning to a regional HQ banks fatigue for everyone attached
    // (person.contractFatigueGain); rotating home resets the counter and
    // starts fatigue decay & training eligibility.
    last_rotation_day: ?u32 = null,
    contracts_since_rotation: u16 = 0,
    /// Where the company physically is when not home (Stage 9E): the
    /// contract world it last worked, until recalled or redeployed.
    location_planet: ?[]const u8 = null,
    /// Non-null while the company is travelling home.
    return_eta_day: ?u32 = null,
    units: std.ArrayListUnmanaged(types.UnitId) = .empty,
    children: std.ArrayListUnmanaged(types.ForceId) = .empty,

    pub fn deinit(self: *Force, alloc: std.mem.Allocator) void {
        self.units.deinit(alloc);
        self.children.deinit(alloc);
    }
};

/// Standard lance size in the Inner Sphere. (Clan stars/level IIs: icebox.)
pub const lance_size = 4;
/// A company starts at 3 lances; HQ mek-bay investment raises the cap to 5
/// (`Hq.capacity().lances_per_company`, ARCH §9.3).
pub const base_lances_per_company = 3;
pub const max_lances_per_company = 5;
pub const base_meks_per_company = lance_size * base_lances_per_company;

test "company math" {
    try std.testing.expectEqual(@as(usize, 12), base_meks_per_company);
    try std.testing.expectEqual(@as(usize, 20), lance_size * max_lances_per_company);
}
