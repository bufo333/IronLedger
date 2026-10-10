//! Project artillery firing, suppression, exposure and loss valuation.
//! No MekHQ numerical counterpart: docs/p2-artillery-battle-design.md owns these rules.

const std = @import("std");
const types = @import("types.zig");
const operations = @import("artillery_operations.zig");
const tuning = @import("tuning.zig").t;
const unit = @import("unit.zig");

/// Combat design, Participation and firing: loaded rounds per engagement salvo.
pub const salvo_rounds: u16 = 1;
pub const target_offset: i16 = 4;
pub const minimum_target: u8 = 2;
pub const maximum_target: u8 = 12;
/// Combat design, Participation and firing: divisor for enemy/carrier power caps.
pub const suppression_divisor: i64 = 4;
/// Combat design, Carrier exposure: half the ordinary opening hit percentage.
pub const exposure_divisor: u32 = 2;
pub const percent_scale: u32 = 100;
pub const mg_reduction_points: u32 = 1;
/// Combat design, Rewards and accounting: each newly wrecked/terminal half-price.
pub const wreck_value_divisor: types.CBills = 2;

pub const ReadinessBlock = enum { not_attached, not_present, depot_job, armor, mechanic, chassis, main_gun, communications, maintenance, crew, ammunition };
pub const NoFire = enum { none, not_present, not_ready, no_line_units, enemy_forfeit, zero_enemy_power };
pub const FireOutcome = enum { not_fired, hit, miss };
pub const DamageOutcome = enum { not_exposed, unhit, damaged, recoverable, permanently_destroyed, scuttled, recovered };
pub const Rounds = [operations.families.len]u16;

/// Lower gunnery and better existing recon reduce the bounded 2d6 target.
/// Source: combat design, Participation and firing. No RNG or mutation.
pub fn firingTarget(effective_gunnery: u8, recon_quality: u8) u8 {
    const target = @as(i16, effective_gunnery) + target_offset - @as(i16, recon_quality);
    return @intCast(std.math.clamp(target, minimum_target, maximum_target));
}

/// Temporary opening-power reduction, capped independently by enemy and carrier.
/// Source: combat design, Participation and firing. Floor rounding; no kill credit.
pub fn suppressedPower(enemy_power: i64, carrier_power: i64) i64 {
    return @min(@divTrunc(@max(0, enemy_power), suppression_divisor), @divTrunc(@max(0, carrier_power), suppression_divisor));
}

/// Bounded rear-area exposure after defensive rounds; percent, not basis points.
/// Source: combat design, Carrier exposure. No extra draw when this returns zero.
pub fn exposurePercent(opening_hit_pct: u32, mg_rounds_fired: u16) u8 {
    const base = @min(percent_scale, opening_hit_pct / exposure_divisor);
    return @intCast(base -| (@as(u32, mg_rounds_fired) * mg_reduction_points));
}

/// Loaded magazines by family, including surviving rounds in damaged bins.
/// Source: combat design, Ammunition accounting. Canonical capacities bound sums.
pub fn loadedRounds(slots: *const operations.Slots) Rounds {
    var result: Rounds = @splat(0);
    for (operations.descriptors, slots) |descriptor, slot| if (descriptor.family) |family| {
        result[@intFromEnum(family)] += slot.rounds;
    };
    return result;
}

/// Expend one actual loaded round from the first intact nonempty canonical bin.
/// Source: combat design, Firing and defensive fire. Refusal changes no slot.
pub fn spendRound(slots: *operations.Slots, family: operations.Family) ?operations.Slot {
    for (operations.descriptors, slots) |descriptor, *slot| {
        if (descriptor.family == family and slot.condition == .ok and slot.rounds >= salvo_rounds) {
            slot.rounds -= salvo_rounds;
            return descriptor.slot;
        }
    }
    return null;
}

/// One round per intact MG mount in canonical order, stopping when its bin empties.
/// Source: combat design, Defensive fire. Zero base exposure spends no ammunition.
pub fn defensiveFire(slots: *operations.Slots, opening_hit_pct: u32) u16 {
    if (exposurePercent(opening_hit_pct, 0) == 0) return 0;
    var fired: u16 = 0;
    for (operations.descriptors, slots) |descriptor, slot| {
        const key = descriptor.catalogue_key orelse continue;
        if (!std.mem.eql(u8, key, "machine_gun") or slot.condition != .ok) continue;
        if (spendRound(slots, .machine_gun) == null) break;
        fired += salvo_rounds;
    }
    return fired;
}

pub const CarrierHit = struct { armor_pct: u8, slots: operations.Slots, wrecked: bool, terminal: bool, cause: unit.WreckCause };

/// Apply ordinary severity thresholds to the canonical carrier, without RNG.
/// Loaded struck bins cook off; structural wrecks remain recoverable. Source:
/// combat design, Carrier exposure and damage. Returned slots own their value.
pub fn carrierHit(armor_before: u8, before: operations.Slots, severity: u8, struck: ?operations.Slot) CarrierHit {
    var result: CarrierHit = .{ .armor_pct = armor_before -| (severity * tuning.battle.armor_per_severity), .slots = before, .wrecked = false, .terminal = false, .cause = .none };
    if (struck) |slot| {
        const index = @intFromEnum(slot);
        result.terminal = operations.descriptor(slot).family != null and before[index].rounds > 0 and severity >= tuning.battle.cookoff_severity;
        _ = operations.deteriorate(&result.slots[index]);
    }
    result.wrecked = result.terminal or severity >= tuning.battle.kill_severity or (result.armor_pct == 0 and severity >= tuning.battle.kill_armorless_severity) or result.slots[@intFromEnum(operations.Slot.chassis)].condition == .destroyed;
    if (result.wrecked) {
        result.armor_pct = 0;
        result.slots[@intFromEnum(operations.Slot.chassis)].condition = .destroyed;
        result.cause = if (result.terminal) .ammo else .cored;
    }
    return result;
}

test "carrier hit uses canonical deterioration and only loaded ammunition cooks off" {
    var slots: operations.Slots = @splat(.{});
    const empty = carrierHit(100, slots, tuning.battle.cookoff_severity, .long_tom_bin_1);
    try std.testing.expect(!empty.terminal);
    slots[@intFromEnum(operations.Slot.long_tom_bin_1)].rounds = 1;
    const loaded = carrierHit(100, slots, tuning.battle.cookoff_severity, .long_tom_bin_1);
    try std.testing.expect(loaded.terminal and loaded.wrecked);
    try std.testing.expectEqual(unit.WreckCause.ammo, loaded.cause);
    var damaged = slots;
    damaged[@intFromEnum(operations.Slot.chassis)].condition = .damaged;
    const structure = carrierHit(100, damaged, tuning.battle.slot_hit_severity, .chassis);
    try std.testing.expect(structure.wrecked and !structure.terminal);
    try std.testing.expectEqual(unit.PartCondition.destroyed, structure.slots[@intFromEnum(operations.Slot.chassis)].condition);
}

/// Incremental compensation basis for this engagement, capped at acquisition price.
/// Source: combat design, Rewards and accounting; severity value uses ordinary tuning.
pub fn damageValue(paid_price: types.CBills, severity: u8, newly_wrecked: bool, terminal: bool) types.CBills {
    const price = @max(0, paid_price);
    const half = @divTrunc(price, wreck_value_divisor);
    const ordinary = @as(i128, severity) * tuning.battle.damage_value_per_severity;
    const value = ordinary + (if (newly_wrecked) @as(i128, half) else 0) + (if (terminal) @as(i128, price - half) else 0);
    return @intCast(@min(price, value));
}

test "firing target and suppression preserve bounds floor rounding and skill direction" {
    try std.testing.expectEqual(@as(u8, 8), firingTarget(4, 0));
    try std.testing.expectEqual(@as(u8, 5), firingTarget(4, 3));
    try std.testing.expectEqual(minimum_target, firingTarget(0, 3));
    try std.testing.expectEqual(maximum_target, firingTarget(255, 0));
    try std.testing.expect(firingTarget(2, 0) < firingTarget(5, 0));
    try std.testing.expectEqual(@as(i64, 25), suppressedPower(103, 1000));
    try std.testing.expectEqual(@as(i64, 0), suppressedPower(0, 1000));
    try std.testing.expectEqual(@as(i64, 0), suppressedPower(100, -1));
}

test "canonical loaded rounds and MG spending distinguish dry partial and damaged bins" {
    var slots: operations.Slots = @splat(.{});
    slots[@intFromEnum(operations.Slot.long_tom_bin_1)] = .{ .condition = .damaged, .rounds = 3 };
    slots[@intFromEnum(operations.Slot.long_tom_bin_2)].rounds = 1;
    try std.testing.expectEqual(operations.Slot.long_tom_bin_2, spendRound(&slots, .long_tom).?);
    try std.testing.expect(spendRound(&slots, .long_tom) == null);
    try std.testing.expectEqual(@as(u16, 3), loadedRounds(&slots)[@intFromEnum(operations.Family.long_tom)]);
    slots[@intFromEnum(operations.Slot.machine_gun_bin)].rounds = 2;
    try std.testing.expectEqual(@as(u16, 0), defensiveFire(&slots, 0));
    try std.testing.expectEqual(@as(u16, 2), defensiveFire(&slots, 30));
    try std.testing.expectEqual(@as(u8, 13), exposurePercent(30, 2));
    try std.testing.expectEqual(@as(u8, 0), exposurePercent(2, 4));
    try std.testing.expectEqual(@as(u8, 100), exposurePercent(400, 0));
    try operations.validateSlots(&slots);
}

test "incremental damage valuation caps every wreck and terminal combination at price" {
    try std.testing.expectEqual(@as(types.CBills, 0), damageValue(100, 0, false, false));
    try std.testing.expectEqual(@as(types.CBills, 50), damageValue(100, 0, true, false));
    try std.testing.expectEqual(@as(types.CBills, 51), damageValue(101, 0, false, true));
    try std.testing.expectEqual(@as(types.CBills, 100), damageValue(100, 12, true, true));
}
