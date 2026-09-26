//! Lift: transport availability and berth queries (ARCH §4).
//! MekHQ counterpart: none; transport availability is checked inline
//! across AtB (`docs/mekhq-map.md`).

const unit_mod = @import("../domain/unit.zig");
const types = @import("../domain/types.zig");
const GameState = @import("state.zig").GameState;

/// Transports of one kind holding a berth at an HQ.
pub fn transportsBerthedAt(gs: *GameState, hq_id: types.HqId, kind: unit_mod.UnitKind) u32 {
    var n: u32 = 0;
    var it = gs.units.iterator();
    while (it.next()) |entry| {
        const u = entry.value_ptr;
        if (u.kind == kind and u.berth_hq == hq_id and u.status != .destroyed) n += 1;
    }
    return n;
}

/// A ship is fit to sail when it is berthed, ready, crewed and not
/// already carrying a company (its `force` is set for the tour).
pub fn transportAvailable(gs: *GameState, u: *const unit_mod.Unit) bool {
    if (!u.kind.isTransport() or u.status != .ready or u.force != .none) return false;
    const crew = gs.person(u.pilot) orelse return false;
    return crew.isAvailable(gs.clock.day_index);
}

/// A crewed jumpship berthed at either end of a link (the dedicated
/// line of a level-3 supply link, GAMEPLAY "requires owning one").
pub fn ownsCrewedJumpshipAt(gs: *GameState, a: types.HqId, b: types.HqId) bool {
    var it = gs.units.iterator();
    while (it.next()) |entry| {
        const u = entry.value_ptr;
        if (u.kind != .jumpship or (u.berth_hq != a and u.berth_hq != b)) continue;
        if (u.status == .destroyed) continue;
        const crew = gs.person(u.pilot) orelse continue;
        if (crew.isAvailable(gs.clock.day_index)) return true;
    }
    return false;
}

/// A crewed dropship in the company's own hangar: it lifts and escorts
/// the company on the way in.
pub fn hasCrewedDropship(gs: *GameState, company: types.ForceId) bool {
    var it = gs.units.iterator();
    while (it.next()) |e| {
        const u = e.value_ptr;
        if (u.kind == .dropship and u.force == company and u.pilot != .none) return true;
    }
    return false;
}
