//! Physical artillery placement and bounded local supply.
//! No MekHQ counterpart: project acquisition and topology policy (docs/mekhq-map.md).

const types = @import("types.zig");
const operations = @import("artillery_operations.zig");

/// Project limits in docs/p2-artillery-acquisition-design.md, not source battery size.
pub const company_formation_cap: u32 = 1;
pub const carrier_vehicle_bays: u32 = 1;
pub const intact_condition_pct: u8 = 100;

pub const Freight = struct {
    from_hq: types.HqId,
    to_hq: types.HqId,
    dispatch_day: u32,
    eta_day: u32,
    paid_cost: types.CBills,
};

/// Exactly one player placement or terminal ownership history; all payloads persisted.
pub const Placement = union(enum) {
    hq_pool: types.HqId,
    company: types.ForceId,
    freight: Freight,
    sold,
    destroyed,
};

/// Organizational identity, physical carrier and persisted operational history.
pub const Formation = struct {
    id: types.ArtilleryFormationId,
    hull: types.HullInstanceId,
    acquisition_day: u32,
    paid_price: types.CBills,
    placement: Placement,
    quality: types.Quality = .c,
    armor_pct: u8 = intact_condition_pct,
    last_maintenance_day: ?u32 = null,
    tech: types.PersonId = .none,
    crew: operations.Crew = @splat(.none),
    slots: operations.Slots = @splat(.{}),
};

/// One HQ's current calendar-period board. Consumption survives save and same-month sync.
pub const Offer = struct {
    id: types.ArtilleryOfferId,
    hq: types.HqId,
    year: u16,
    month: u8,
    available: bool = true,
};
