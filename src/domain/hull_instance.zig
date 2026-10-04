//! Persisted hull instance: the lifecycle record of one physical hull
//! from acquisition through use and eventual destruction. Distinct from
//! the `unit` (which is the owned slot in a campaign roster) and
//! `unit_slot` (live condition per part slot). The design loadout here
//! records the INTENDED fit; `unit_slot` records the live condition.
//! MekHQ counterpart: Mek.history + Mek.variants (docs/mekhq-map.md).

const std = @import("std");
const types = @import("types.zig");

/// Who owns this hull right now. One of five kinds (docs/p3c-economy-design.md §2).
/// Persisted as three typed columns: owner_type (tag name), owner_faction_key
/// (FactionRow.key when .faction, else ""), owner_rival_id (RivalId int when
/// .rival, else 0).
pub const OwnerType = enum { player, faction, rival, market, destroyed };

/// Current owner of a HullInstance. Illegal states are unrepresentable: you
/// cannot hold owner_type=faction with a rival id (rule 20, no-partial-truth).
/// - .player / .market / .destroyed: no id payload
/// - .faction: payload is the faction stable string key (FactionRow.key, e.g. "LC")
/// - .rival: payload is types.RivalId (FK into GameState.rivals)
pub const HullOwner = union(OwnerType) {
    player,
    faction: []const u8,
    rival: types.RivalId,
    market,
    destroyed,
};

/// The operational status of this physical hull.
pub const HullStatus = enum { active, permanently_destroyed };

/// One slot of a hull's DESIGN loadout (part meant to be installed).
/// Distinct from unit_slot, which is the owned unit's LIVE condition
/// (design §7, owner Decision A).
pub const HullLoadout = struct { part_key: []const u8 = "" };

pub const HullInstance = struct {
    id: types.HullInstanceId = .none,
    base_key: []const u8 = "", // -> chassis.zon stable key
    name: ?[]const u8 = null,
    nickname: ?[]const u8 = null,
    status: HullStatus = .active,
    intro_year: u16 = 0, // TUNE: sourced from base chassis intro_year
    pre_campaign: bool = false,
    loadout: std.ArrayListUnmanaged(HullLoadout) = .empty,
    /// Current owner. Defaults to .player (all construction sites create player hulls).
    /// Loaders never rely on this default — they read owner_type explicitly, fail-closed.
    owner: HullOwner = .player,

    pub fn deinit(self: *HullInstance, alloc: std.mem.Allocator) void {
        self.loadout.deinit(alloc);
    }
};

/// Per-engagement combat record for a physical hull: kills credited to it and
/// a damage summary, parallel to the pilot kill record in Person. No owned
/// allocations; no deinit needed. (P3c.2, docs/p3c-hull-lifecycle-design.md §1, §4)
pub const HullCombatRecord = struct {
    hull_instance_id: types.HullInstanceId = .none,
    /// Backlink to the battle report; may age out of the bounded journal.
    /// Not reference-validated on load: battle reports are pruned, so a live
    /// record legitimately points at a gone battle. Only hull_instance_id is a
    /// validated FK.
    battle_id: types.BattleId = .none,
    /// Backlink to the contract; contracts are removed after completion.
    /// Not reference-validated for the same reason as battle_id.
    contract_id: types.ContractId = .none,
    /// Kills credited to this hull this engagement, sourced from creditKills.
    kills: u16 = 0,
    // Damage summary — every field sourced from an existing battle_report.HullHit
    // field (armor_before/after, slot_result, destroyed, cause); nothing invented.
    /// Count of HullHit rows for this unit.
    hits_taken: u16 = 0,
    /// first.armor_before − last.armor_after, floored at 0.
    armor_lost: u16 = 0,
    /// HullHit.slot_result == .damaged count.
    slots_damaged: u8 = 0,
    /// HullHit.slot_result == .destroyed count.
    slots_destroyed: u8 = 0,
    /// True when any HullHit.destroyed was set for this unit.
    destroyed: bool = false,
    /// HullHit.cause from the destroying hit; .none if not destroyed.
    cause: @import("unit.zig").WreckCause = .none,
};

test "HullCombatRecord defaults" {
    const r: HullCombatRecord = .{};
    try std.testing.expectEqual(types.HullInstanceId.none, r.hull_instance_id);
    try std.testing.expectEqual(types.BattleId.none, r.battle_id);
    try std.testing.expectEqual(types.ContractId.none, r.contract_id);
    try std.testing.expectEqual(@as(u16, 0), r.kills);
    try std.testing.expectEqual(@as(u16, 0), r.hits_taken);
    try std.testing.expectEqual(@as(u16, 0), r.armor_lost);
    try std.testing.expectEqual(@as(u8, 0), r.slots_damaged);
    try std.testing.expectEqual(@as(u8, 0), r.slots_destroyed);
    try std.testing.expect(!r.destroyed);
    try std.testing.expectEqual(@import("unit.zig").WreckCause.none, r.cause);
}

/// What a maintenance-log entry records. P3c.3 writes .repair (depot structural
/// repair) and .modify (loadout refit); .inspection is reserved for later triggers.
pub const MaintenanceAction = enum {
    repair,
    modify,
    inspection,

    /// The one owner of the stored short description for each action (rule 24).
    /// Static literals (markup-safe, no allocation) so the write stays atomic.
    pub fn describe(self: MaintenanceAction) []const u8 {
        return switch (self) {
            .repair => "depot structural repair",
            .modify => "loadout refit",
            .inspection => "scheduled inspection",
        };
    }
};

/// One maintenance event on a physical hull: who worked it, when, what kind,
/// and the labor cost of the job it queued. Child of HullInstance, keyed
/// (cid, hull_instance_id, ord). hull_instance_id is the one validated FK; tech
/// and battle_id are historical backlinks and are NOT reference-validated
/// (the tech may leave, battle reports age out — HullCombatRecord precedent).
/// (P3c.3, docs/p3c-hull-lifecycle-design.md §1, §2)
pub const MaintenanceEntry = struct {
    hull_instance_id: types.HullInstanceId = .none,
    day: u32 = 0,
    tech: types.PersonId = .none,
    action: MaintenanceAction = .repair,
    description: []const u8 = "",
    battle_id: types.BattleId = .none,
    cost: types.CBills = 0,
};

test "MaintenanceEntry defaults and describe" {
    const e: MaintenanceEntry = .{};
    try std.testing.expectEqual(types.HullInstanceId.none, e.hull_instance_id);
    try std.testing.expectEqual(types.PersonId.none, e.tech);
    try std.testing.expectEqual(MaintenanceAction.repair, e.action);
    try std.testing.expectEqual(@as(types.CBills, 0), e.cost);
    try std.testing.expectEqualStrings("depot structural repair", MaintenanceAction.repair.describe());
    try std.testing.expectEqualStrings("loadout refit", MaintenanceAction.modify.describe());
    try std.testing.expectEqualStrings("scheduled inspection", MaintenanceAction.inspection.describe());
}

/// How a hull came into its current owner's hands. .initial seeds the
/// provenance chain for hulls that predate the ownership log (migration);
/// .transfer is reserved for future depot/inter-force moves (P3e). (P3c.4)
pub const AcquisitionType = enum { purchase, salvage, transfer, initial };

/// One ownership interval for a physical hull: who it belonged to before
/// this interval (prior_owner_key — a faction key, "player", or "unknown";
/// a free provenance string that may name a gone entity, NOT a typed FK),
/// how the current owner got it, and the day span. to_day == 0 is the
/// still-open current interval. Child of HullInstance, keyed
/// (cid, hull_instance_id, ord); hull_instance_id is the one validated FK.
/// Append-only: a row is never deleted or rewritten; the single permitted
/// mutation is stamping to_day when the open interval closes (P3c.4,
/// docs/p3c-hull-lifecycle-design.md §1, §2).
pub const HullOwnershipHistory = struct {
    hull_instance_id: types.HullInstanceId = .none,
    from_day: u32 = 0,
    to_day: u32 = 0, // 0 = current owner (open interval)
    acquisition_type: AcquisitionType = .initial,
    prior_owner_key: []const u8 = "",
};

test "HullOwnershipHistory defaults" {
    const h: HullOwnershipHistory = .{};
    try std.testing.expectEqual(types.HullInstanceId.none, h.hull_instance_id);
    try std.testing.expectEqual(@as(u32, 0), h.from_day);
    try std.testing.expectEqual(@as(u32, 0), h.to_day);
    try std.testing.expectEqual(AcquisitionType.initial, h.acquisition_type);
    try std.testing.expectEqualStrings("", h.prior_owner_key);
}

test "HullInstance defaults and loadout append" {
    const inst: HullInstance = .{};
    try std.testing.expectEqual(types.HullInstanceId.none, inst.id);
    try std.testing.expectEqual(HullStatus.active, inst.status);
    try std.testing.expectEqual(@as(usize, 0), inst.loadout.items.len);
    try std.testing.expect(inst.name == null);
    try std.testing.expect(inst.nickname == null);
    // P3e.2: default owner is .player
    try std.testing.expectEqual(OwnerType.player, std.meta.activeTag(inst.owner));
    try std.testing.expect(inst.owner == .player);

    var inst2: HullInstance = .{
        .id = @enumFromInt(1),
        .base_key = "SHD-2H",
        .status = .active,
        .intro_year = 2750,
        .pre_campaign = true,
    };
    defer inst2.deinit(std.testing.allocator);
    try inst2.loadout.append(std.testing.allocator, .{ .part_key = "medium_laser" });
    try inst2.loadout.append(std.testing.allocator, .{ .part_key = "srm_4" });
    try std.testing.expectEqual(@as(usize, 2), inst2.loadout.items.len);
    try std.testing.expectEqualStrings("medium_laser", inst2.loadout.items[0].part_key);
}
