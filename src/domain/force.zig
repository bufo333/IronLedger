//! TO&E: the force tree. Outfit → battalion → company → lance.
//! Adaptation of MekHQ `force/Force.java`: *companies* are deployable
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

    /// What the trade does for the company (the raise wizard's support table).
    pub fn describe(self: SupportLanceKind) []const u8 {
        return switch (self) {
            .transport => "20t of field stores each — the trucks are the company's supply capacity",
            .salvage => "5t each and 600 BV of wrecks and parts hauled per won battle, shipped to the home depot",
            .mash => "wounded heal in the field; four medics ride with the lance",
            .security => "guards the laager against raids (infantry, no hull crew)",
            .mess => "fatigue and morale recover faster in the field; a provisions buffer",
        };
    }

    /// The staple hull each support trade fields (the raise wizard buys
    /// them off the home board): salvage trucks, MASH rigs, cargo trucks,
    /// a security platoon; mess lances take cargo trucks too.
    pub fn hullKey(kind: SupportLanceKind) []const u8 {
        return switch (kind) {
            .salvage => "SVT-1",
            .mash => "MASH-27",
            .transport, .mess => "CGT-3",
            .security => "SEC-PLT",
        };
    }
};

/// What `new_lance` raises: a line lance, an air lance under
/// the company's air wing, or a support lance of one kind under Omega.
pub const NewLanceKind = union(enum) {
    line,
    air,
    support: SupportLanceKind,
};

/// AtB lance roles: what a lance is tasked with while on contract; drives
/// scenario generation odds and training XP.
pub const LanceRole = enum {
    fighting,
    defense,
    scouting,
    training,
    unassigned,

    /// The role a lance steps to: fighting → defense → scouting → training
    /// → fighting; an unassigned lance steps to fighting.
    pub fn next(self: LanceRole) LanceRole {
        return switch (self) {
            .fighting => .defense,
            .defense => .scouting,
            .scouting => .training,
            .training, .unassigned => .fighting,
        };
    }

    /// The step back through the same order.
    pub fn prev(self: LanceRole) LanceRole {
        return switch (self) {
            .fighting, .unassigned => .training,
            .defense => .fighting,
            .scouting => .defense,
            .training => .scouting,
        };
    }

    /// What the role does to the lance (the Forces screen says it when o cycles).
    pub fn describe(self: LanceRole) []const u8 {
        return switch (self) {
            .fighting => "fights in every engagement",
            .defense => "+10% power on garrison-class contracts",
            .scouting => "recon: better intel before battles",
            .training => "held out of battles; crews gain XP weekly at home",
            .unassigned => "",
        };
    }
};

/// Rules of engagement for a company (the withdrawal thresholds of
/// ARCH §7 as a standing order): how long it stands when a fight turns.
/// `hold` fights to the last — a harder roll for the enemy, but a lost
/// fight costs more hulls and fewer come back; `cautious` pulls out at the
/// first real losses — fewer hits and more wrecks dragged off, but a draw
/// becomes a withdrawal (no field, no salvage). MekHQ counterpart: none
/// (StratCon's "retreat" is per scenario); ACAR's withdrawal thresholds.
pub const Roe = enum {
    hold,
    standard,
    cautious,

    /// The ROE a company steps to: standard → cautious → hold → standard.
    pub fn next(self: Roe) Roe {
        return switch (self) {
            .standard => .cautious,
            .cautious => .hold,
            .hold => .standard,
        };
    }

    /// The step back through the same order.
    pub fn prev(self: Roe) Roe {
        return switch (self) {
            .standard => .hold,
            .cautious => .standard,
            .hold => .cautious,
        };
    }

    pub fn describe(self: Roe) []const u8 {
        return switch (self) {
            .hold => "hold the ground — +1 to the roll; a lost fight costs more hulls and fewer are recovered",
            .standard => "standard — withdraw when the fight is lost",
            .cautious => "cautious — withdraw at first losses: −1 to the roll, fewer hits, more wrecks recovered; a draw is a withdrawal",
        };
    }
};

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
    /// Field stores: travel with the company, capped by its
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
    /// Companies: rules of engagement.
    roe: Roe = .standard,
    support_kind: ?SupportLanceKind = null, // set iff echelon == .support_lance
    // Rotation tracking for companies (ARCH §9.7): each contract completed
    // without returning to a regional HQ banks fatigue for everyone attached
    // (person.contractFatigueGain); rotating home resets the counter and
    // starts fatigue decay & training eligibility.
    last_rotation_day: ?u32 = null,
    contracts_since_rotation: u16 = 0,
    /// Where the company physically is when not home: the
    /// contract world it last worked, until recalled or redeployed.
    location_planet: ?[]const u8 = null,
    /// Non-null while the company is travelling home.
    return_eta_day: ?u32 = null,
    units: std.ArrayListUnmanaged(types.UnitId) = .empty,
    children: std.ArrayListUnmanaged(types.ForceId) = .empty,

    /// A line lance the battle fields: mek or air.
    pub fn isCombatLance(self: *const Force) bool {
        return self.echelon == .lance or self.echelon == .air_lance;
    }

    pub fn deinit(self: *Force, alloc: std.mem.Allocator) void {
        self.units.deinit(alloc);
        self.children.deinit(alloc);
    }
};

/// Standard lance size in the Inner Sphere; Clan stars and Level IIs are not modelled.
pub const lance_size = 4;
/// A company starts at 3 lances; HQ mek-bay investment raises the cap to 5
/// (`Hq.capacity().lances_per_company`, ARCH §9.3).
pub const base_lances_per_company = 3;
pub const max_lances_per_company = 5;
/// Air lances per air wing (tuning.force).
pub const max_air_lances = @import("tuning.zig").t.force.max_air_lances;
pub const base_meks_per_company = lance_size * base_lances_per_company;

test "company math" {
    try std.testing.expectEqual(@as(usize, 12), base_meks_per_company);
    try std.testing.expectEqual(@as(usize, 20), lance_size * max_lances_per_company);
}

test "stepping a lance role or an ROE back undoes stepping it forward" {
    for (std.enums.values(LanceRole)) |r| {
        if (r == .unassigned) continue; // steps into the cycle, never back to itself
        try std.testing.expectEqual(r, r.next().prev());
        try std.testing.expectEqual(r, r.prev().next());
    }
    for (std.enums.values(Roe)) |r| {
        try std.testing.expectEqual(r, r.next().prev());
        try std.testing.expectEqual(r, r.prev().next());
    }
}
