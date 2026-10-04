//! Persisted hull instance: the lifecycle record of one physical hull
//! from acquisition through use and eventual destruction. Distinct from
//! the `unit` (which is the owned slot in a campaign roster) and
//! `unit_slot` (live condition per part slot). The design loadout here
//! records the INTENDED fit; `unit_slot` records the live condition.
//! MekHQ counterpart: Mek.history + Mek.variants (docs/mekhq-map.md).

const std = @import("std");
const types = @import("types.zig");

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

    pub fn deinit(self: *HullInstance, alloc: std.mem.Allocator) void {
        self.loadout.deinit(alloc);
    }
};

test "HullInstance defaults and loadout append" {
    const inst: HullInstance = .{};
    try std.testing.expectEqual(types.HullInstanceId.none, inst.id);
    try std.testing.expectEqual(HullStatus.active, inst.status);
    try std.testing.expectEqual(@as(usize, 0), inst.loadout.items.len);
    try std.testing.expect(inst.name == null);
    try std.testing.expect(inst.nickname == null);

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
