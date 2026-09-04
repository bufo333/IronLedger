//! Contract event decks & the decision engine (Stage 6, ARCH §8).
//! Mirrors MekHQ's AtB monthly events: each active contract rolls 2d6 on
//! its class deck (garrison vs. combat) on the 1st. Auto events apply
//! immediately; decisions land in the inbox with a deadline (turn-based —
//! time never stops; the default applies if the deadline passes).

const std = @import("std");
const types = @import("../domain/types.zig");
const events = @import("events.zig");
const contract_mod = @import("../domain/contract.zig");
const GameState = @import("state.zig").GameState;
const unit_mod = @import("../domain/unit.zig");

pub const decision_window_days = 7; // TUNE

// ------------------------------------------------------------------ decks
// Static decks; dynamic magnitudes go through relative effects.

pub const Entry = struct {
    kind: events.EventKind,
    log: []const u8,
    auto_effects: []const events.Effect = &.{},
    options: []const events.Option = &.{},
    default_choice: usize = 0,
};

fn garrisonDeck(roll: u8) Entry {
    return switch (roll) {
        2 => .{ .kind = .pirate_raid, .log = "Pirate raiders hit the perimeter", .auto_effects = &.{
            .{ .damage_random_units = 2 }, .{ .morale = -5 }, .{ .xp_all = 1 }, .{ .score = 1 },
        } },
        3 => .{ .kind = .disease_outbreak, .log = "Disease outbreak in the cantonment", .auto_effects = &.{
            .{ .fatigue = 10 }, .{ .morale = -5 },
        } },
        4 => .{ .kind = .logistics_failure, .log = "Supply convoy lost to breakdowns", .auto_effects = &.{
            .{ .supply_loss = 40_000 },
        } },
        5 => .{ .kind = .civil_disturbance, .log = "Civil disturbance in the capital", .options = &.{
            .{ .label = "Suppress it firmly (employer pays, locals resent)", .effects = &.{ .{ .cash = 100_000 }, .{ .reputation = -2 } } },
            .{ .label = "Measured response (long patrols)", .effects = &.{ .{ .reputation = 2 }, .{ .fatigue = 5 } } },
            .{ .label = "Stay in barracks", .effects = &.{.{ .reputation = -1 }} },
        }, .default_choice = 1 },
        9 => .{ .kind = .sports_riot, .log = "Company wins the garrison games", .auto_effects = &.{
            .{ .morale = 4 },
        } },
        10 => .{ .kind = .bonus_payment, .log = "Employer pays a performance bonus", .auto_effects = &.{
            .{ .cash_monthly_pct = 50 },
        } },
        11 => .{ .kind = .equipment_cache, .log = "Scouts find a sealed supply cache", .options = &.{
            .{ .label = "Crack it open quietly", .effects = &.{ .{ .parts_windfall = 3 }, .{ .reputation = -1 } } },
            .{ .label = "Report it to the employer", .effects = &.{.{ .reputation = 2 }} },
        }, .default_choice = 1 },
        12 => .{ .kind = .off_contract_request, .log = "Local governor requests off-contract work", .options = &.{
            .{ .label = "Accept the side job", .effects = &.{ .{ .cash_monthly_pct = 150 }, .{ .reputation = -2 }, .{ .fatigue = 8 } } },
            .{ .label = "Decline politely", .effects = &.{.{ .reputation = 1 }} },
        }, .default_choice = 1 },
        else => .{ .kind = .quiet_month, .log = "A quiet month on station", .auto_effects = &.{
            .{ .xp_all = 1 },
        } },
    };
}

fn combatDeck(roll: u8) Entry {
    return switch (roll) {
        2 => .{ .kind = .betrayal, .log = "Liaison feeds the enemy your patrol routes", .auto_effects = &.{
            .{ .morale = -8 }, .{ .score = -2 },
        } },
        3 => .{ .kind = .supply_interdiction, .log = "Enemy interdiction chokes resupply", .auto_effects = &.{
            .{ .supply_loss = 60_000 }, .{ .fatigue = 5 },
        } },
        4 => .{ .kind = .enemy_reinforcements, .log = "Enemy reinforcements land", .auto_effects = &.{
            .{ .score = -1 },
        } },
        9 => .{ .kind = .intel_windfall, .log = "Recon delivers an intel windfall", .auto_effects = &.{
            .{ .score = 2 }, .{ .xp_all = 1 },
        } },
        10 => .{ .kind = .captured_salvage, .log = "Battlefield salvage recovered", .auto_effects = &.{
            .{ .parts_windfall = 2 }, .{ .cash = 100_000 },
        } },
        11 => .{ .kind = .local_support_offer, .log = "Local militia offers support — for a price", .options = &.{
            .{ .label = "Pay them 100k", .effects = &.{ .{ .cash = -100_000 }, .{ .score = 2 } } },
            .{ .label = "Refuse", .effects = &.{} },
        }, .default_choice = 1 },
        12 => .{ .kind = .daring_opportunity, .log = "A daring strike could break the enemy line", .options = &.{
            .{ .label = "Strike (risk the machines)", .effects = &.{ .{ .score = 3 }, .{ .damage_random_units = 2 }, .{ .fatigue = 10 } } },
            .{ .label = "Hold position", .effects = &.{} },
        }, .default_choice = 1 },
        // Real engagements (sim/battle.zig) carry the damage now; the deck's
        // middle band is the grind between them.
        else => .{ .kind = .heavy_fighting, .log = "Sustained patrol operations grind on", .auto_effects = &.{
            .{ .fatigue = 5 }, .{ .xp_all = 1 },
        } },
    };
}

/// Weekly happenings (Stage 12): rolled every week a contract is active,
/// on top of the monthly deck. Most weeks are quiet; the tails bring
/// small choices so the player has something to decide between battles.
fn weeklyDeck(garrison: bool, roll: u8) Entry {
    if (garrison) return switch (roll) {
        2 => .{ .kind = .night_raid, .log = "Saboteurs slip through the wire at night", .auto_effects = &.{
            .{ .damage_random_units = 1 }, .{ .morale = -2 }, .{ .xp_all = 1 },
        } },
        3 => .{ .kind = .smuggler_offer, .log = "A smuggler offers parts off the back of a truck", .options = &.{
            .{ .label = "Buy them, no questions", .effects = &.{ .{ .parts_windfall = 2 }, .{ .cash = -40_000 }, .{ .reputation = -1 } } },
            .{ .label = "Turn them in to the employer", .effects = &.{.{ .reputation = 1 }} },
            .{ .label = "Send them away", .effects = &.{} },
        }, .default_choice = 2 },
        4 => .{ .kind = .employer_inspection, .log = "The employer's liaison announces an inspection", .options = &.{
            .{ .label = "Full parade and hangar tour", .effects = &.{ .{ .reputation = 1 }, .{ .fatigue = 4 } } },
            .{ .label = "Working visit only", .effects = &.{} },
            .{ .label = "Plead operational tempo", .effects = &.{.{ .reputation = -1 }} },
        }, .default_choice = 1 },
        10 => .{ .kind = .local_festival, .log = "The town holds its harvest festival", .options = &.{
            .{ .label = "Sponsor it (50k)", .effects = &.{ .{ .cash = -50_000 }, .{ .morale = 6 }, .{ .reputation = 1 } } },
            .{ .label = "Give the company the day", .effects = &.{ .{ .morale = 3 }, .{ .fatigue = 2 } } },
            .{ .label = "Keep to the schedule", .effects = &.{} },
        }, .default_choice = 1 },
        11 => .{ .kind = .training_exercise, .log = "Quiet week — time for a live-fire exercise?", .options = &.{
            .{ .label = "Run it hard", .effects = &.{ .{ .xp_all = 2 }, .{ .fatigue = 6 } } },
            .{ .label = "Light drills", .effects = &.{.{ .xp_all = 1 }} },
            .{ .label = "Stand down", .effects = &.{.{ .morale = 2 }} },
        }, .default_choice = 1 },
        12 => .{ .kind = .press_visit, .log = "A news crew wants to embed with the company", .options = &.{
            .{ .label = "Welcome them", .effects = &.{ .{ .reputation = 2 }, .{ .fatigue = 2 } } },
            .{ .label = "Refuse", .effects = &.{} },
        }, .default_choice = 0 },
        else => .{ .kind = .quiet_week, .log = "" },
    };
    return switch (roll) {
        2 => .{ .kind = .night_raid, .log = "Enemy raiders hit the laager before dawn", .auto_effects = &.{
            .{ .damage_random_units = 1 }, .{ .morale = -3 }, .{ .xp_all = 1 }, .{ .score = -1 },
        } },
        3 => .{ .kind = .ambush_warning, .log = "Locals warn of an ambush on the supply road", .options = &.{
            .{ .label = "Escort the convoy in force", .effects = &.{ .{ .fatigue = 6 }, .{ .score = 1 } } },
            .{ .label = "Reroute and delay", .effects = &.{.{ .supply_loss = 20_000 }} },
            .{ .label = "Ignore it", .effects = &.{ .{ .damage_convoy_units = 1 }, .{ .score = -1 } } },
        }, .default_choice = 0 },
        4 => .{ .kind = .bad_weather, .log = "A week of storms grounds both sides", .auto_effects = &.{
            .{ .morale = 2 },
        } },
        10 => .{ .kind = .supply_cache, .log = "Patrols overrun an enemy supply cache", .auto_effects = &.{
            .{ .parts_windfall = 1 }, .{ .xp_all = 1 },
        } },
        11 => .{ .kind = .prisoner_exchange, .log = "The enemy proposes a prisoner exchange", .options = &.{
            .{ .label = "Exchange — honour among soldiers", .effects = &.{ .{ .reputation = 2 }, .{ .morale = 2 } } },
            .{ .label = "Ransom them instead (50k)", .effects = &.{ .{ .cash = 50_000 }, .{ .reputation = -1 } } },
        }, .default_choice = 0 },
        12 => .{ .kind = .field_promotion, .log = "A lance leader distinguishes themselves", .auto_effects = &.{
            .{ .xp_all = 2 }, .{ .morale = 3 },
        } },
        else => .{ .kind = .quiet_week, .log = "" },
    };
}

/// The static deck entry for an event kind (options live in the decks, so
/// a saved pending decision is rebuilt from its kind — Stage 11).
pub fn entryForKind(kind: events.EventKind) ?Entry {
    var roll: u8 = 2;
    while (roll <= 12) : (roll += 1) {
        const g = garrisonDeck(roll);
        if (g.kind == kind) return g;
        const c = combatDeck(roll);
        if (c.kind == kind) return c;
        const wg = weeklyDeck(true, roll);
        if (wg.kind == kind) return wg;
        const wc = weeklyDeck(false, roll);
        if (wc.kind == kind) return wc;
    }
    return null;
}

/// Weekly roll for every active contract (Stage 12): quiet most weeks.
pub fn rollWeekly(gs: *GameState) !void {
    var it = gs.contracts.iterator();
    while (it.next()) |entry| {
        const c = entry.value_ptr;
        if (c.status != .active) continue;
        const roll = gs.rng.roll2d6(.events);
        const deck = weeklyDeck(c.kind.isGarrisonClass(), roll);
        if (deck.kind == .quiet_week) continue;
        const ctx: @import("state.zig").LogCtx = .{ .company = c.assigned_company, .contract = c.id };
        if (deck.options.len == 0) {
            try applyEffects(gs, deck.auto_effects, c);
            try gs.log(.contract, ctx, "[{s}] {s}", .{ @tagName(c.kind), deck.log });
        } else {
            try gs.event_queue.push(gs.allocator(), .{
                .day = gs.clock.day_index,
                .kind = deck.kind,
                .contract = c.id,
                .company = c.assigned_company,
                .options = deck.options,
                .default_choice = deck.default_choice,
                .deadline_day = gs.clock.day_index + decision_window_days,
            });
            try gs.log(.decision, ctx, "[{s}] DECISION: {s} (inbox, {d} days to answer)", .{ @tagName(c.kind), deck.log, decision_window_days });
        }
    }
}

test "weekly deck: every non-quiet kind resolves through entryForKind" {
    var roll: u8 = 2;
    while (roll <= 12) : (roll += 1) {
        for ([_]bool{ true, false }) |g| {
            const e = weeklyDeck(g, roll);
            if (e.kind == .quiet_week) continue;
            try std.testing.expect(entryForKind(e.kind) != null);
            if (e.options.len > 0) try std.testing.expect(e.default_choice < e.options.len);
        }
    }
}

// ----------------------------------------------------------------- engine

/// Monthly roll for every active contract (called on the 1st).
pub fn rollMonthly(gs: *GameState) !void {
    var it = gs.contracts.iterator();
    while (it.next()) |entry| {
        const c = entry.value_ptr;
        if (c.status != .active) continue;

        const roll = gs.rng.roll2d6(.events);
        const deck = if (c.kind.isGarrisonClass()) garrisonDeck(roll) else combatDeck(roll);

        const ctx: @import("state.zig").LogCtx = .{ .company = c.assigned_company, .contract = c.id };
        if (deck.options.len == 0) {
            try applyEffects(gs, deck.auto_effects, c);
            try gs.log(.contract, ctx, "[{s}] {s}", .{ @tagName(c.kind), deck.log });
        } else {
            try gs.event_queue.push(gs.allocator(), .{
                .day = gs.clock.day_index,
                .kind = deck.kind,
                .contract = c.id,
                .company = c.assigned_company,
                .options = deck.options,
                .default_choice = deck.default_choice,
                .deadline_day = gs.clock.day_index + decision_window_days,
            });
            try gs.log(.decision, ctx, "[{s}] DECISION: {s} (inbox, {d} days to answer)", .{ @tagName(c.kind), deck.log, decision_window_days });
        }
    }
}

/// Resolve one inbox decision by index. Player-initiated, between turns.
pub fn resolveChoice(gs: *GameState, event_index: usize, choice: usize) !void {
    const pending = gs.event_queue.pending.items;
    if (event_index >= pending.len) return error.NoSuchEvent;
    const ev = &pending[event_index];
    if (!ev.needsDecision()) return error.NotADecision;
    if (choice >= ev.options.len) return error.NoSuchChoice;

    ev.chosen = choice;
    const c = if (ev.contract != .none) gs.contracts.getPtr(ev.contract) else null;
    try applyEffects(gs, ev.options[choice].effects, c);
    try gs.log(.decision, .{ .company = ev.company, .contract = ev.contract }, "[decision] {s}: chose \"{s}\"", .{ @tagName(ev.kind), ev.options[choice].label });
    _ = gs.event_queue.pending.orderedRemove(event_index);
}

/// Turn upkeep (decisions phase, daily): deadlines pass, defaults apply.
pub fn expireDue(gs: *GameState) !void {
    var i: usize = 0;
    while (i < gs.event_queue.pending.items.len) {
        const ev = &gs.event_queue.pending.items[i];
        if (ev.needsDecision() and gs.clock.day_index >= ev.deadline_day) {
            const opt = ev.options[ev.default_choice];
            const c = if (ev.contract != .none) gs.contracts.getPtr(ev.contract) else null;
            try applyEffects(gs, opt.effects, c);
            try gs.log(.decision, .{ .company = ev.company, .contract = ev.contract }, "[deadline] {s}: no answer — defaulted to \"{s}\"", .{ @tagName(ev.kind), opt.label });
            _ = gs.event_queue.pending.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

fn applyEffects(gs: *GameState, effects: []const events.Effect, contract: ?*contract_mod.Contract) !void {
    const company: types.ForceId = if (contract) |c| c.assigned_company else .none;
    const contract_id: types.ContractId = if (contract) |c| c.id else .none;

    // Field events move field money (Stage 9A): company-tagged cash flows
    // through the company's local funds; outfit-level events stay central.
    const treasury: @import("state.zig").Treasury = if (company != .none) .{ .company = company } else .outfit;
    for (effects) |effect| {
        switch (effect) {
            .cash => |amount| try gs.postTreasury(treasury, .{
                .day = gs.clock.day_index,
                .amount = amount,
                .category = .event,
                .company = company,
                .contract = contract_id,
                .note = "contract event",
            }),
            .cash_monthly_pct => |pct| if (contract) |c| {
                try gs.postTreasury(treasury, .{
                    .day = gs.clock.day_index,
                    .amount = @divTrunc(c.monthly_net * pct, 100),
                    .category = .event,
                    .company = company,
                    .contract = contract_id,
                    .note = "contract event",
                });
            },
            .supply_loss => |amount| try gs.postTreasury(treasury, .{
                .day = gs.clock.day_index,
                .amount = -amount,
                .category = .supplies,
                .company = company,
                .contract = contract_id,
                .note = "event: supply losses",
            }),
            .reputation => |delta| gs.reputation += delta,
            .score => |delta| if (contract) |c| {
                c.score += delta;
            },
            .morale => |delta| applyToCompany(gs, company, .morale, delta),
            .fatigue => |amount| applyToCompany(gs, company, .fatigue, @intCast(amount)),
            .xp_all => |amount| applyToCompany(gs, company, .xp, @intCast(amount)),
            .parts_windfall => |n| {
                // Weapons stay with the company (field techs can fit them);
                // structure goes home with the next convoy (depot work).
                if (company != .none) {
                    try gs.addStock(.{ .company = company }, "mlas", n);
                    try gs.sendHome(company, "comp_arm", n);
                } else {
                    try gs.addStock(gs.defaultSite(), "comp_arm", n);
                    try gs.addStock(gs.defaultSite(), "mlas", n);
                }
            },
            .damage_random_units => |n| damageRandomUnits(gs, company, n, .line),
            .damage_convoy_units => |n| damageRandomUnits(gs, company, n, .support),
        }
    }
}

const PersonStat = enum { morale, fatigue, xp };

fn applyToCompany(gs: *GameState, company: types.ForceId, stat: PersonStat, delta: i32) void {
    var it = gs.people.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        if (p.status != .active) continue;
        var f = p.assigned_force;
        const in_company = while (f != .none) {
            if (f == company) break true;
            f = (gs.forces.getPtr(f) orelse break false).parent;
        } else false;
        if (!in_company) continue;
        switch (stat) {
            .morale => p.morale = @intCast(std.math.clamp(@as(i32, p.morale) + delta, 0, 100)),
            .fatigue => p.fatigue = @intCast(@min(@as(i32, @import("../domain/person.zig").max_fatigue), @as(i32, p.fatigue) + delta)),
            .xp => p.xp += @intCast(delta),
        }
    }
}

/// Which echelon an event's wear lands on: the line lances that stand in
/// the way of raids, or the support train (trucks, ambulances, salvage
/// rigs) that sits in the rear and only gets hit when the convoy does.
const Echelon = enum { line, support };

fn inEchelon(gs: *GameState, u: *const unit_mod.Unit, which: Echelon) bool {
    const f = gs.force(u.force) orelse return false;
    return switch (which) {
        .line => f.echelon == .lance or f.echelon == .air_lance,
        .support => f.echelon == .support_lance and u.kind != .infantry,
    };
}

/// Abstract wear from an event: armor loss, and on a bad roll a broken
/// slot. Line-lance hulls by default; the support echelon is in reserve
/// and is only touched by convoy events.
fn damageRandomUnits(gs: *GameState, company: types.ForceId, n: u8, which: Echelon) void {
    if (gs.units.count() == 0) return;
    const values = gs.units.values();
    var applied: u8 = 0;
    var attempts: u32 = 0;
    while (applied < n and attempts < 40) : (attempts += 1) {
        const u = &values[gs.rng.random(.events).uintLessThan(usize, values.len)];
        if (gs.companyOf(u.force) != company or u.status == .destroyed or u.status == .mothballed) continue;
        if (!inEchelon(gs, u, which)) continue;
        const wear = gs.rng.roll2d6(.events);
        u.armor_pct -|= wear * 3;
        if (wear >= 10 and u.slots.items.len > 0) {
            const slot = &u.slots.items[gs.rng.random(.events).uintLessThan(usize, u.slots.items.len)];
            if (slot.condition == .ok) slot.condition = .damaged;
        }
        applied += 1;
    }
}

test "event wear lands on the line lances; only convoy events touch the support train" {
    const commands = @import("commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 2025 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "E", .origin = .CC, .profession = .paymaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    for (0..30) |_| damageRandomUnits(&gs, co, 2, .line);
    var uit = gs.units.iterator();
    var line_worn: u32 = 0;
    while (uit.next()) |e| {
        const u = e.value_ptr;
        if (gs.companyOf(u.force) != co) continue;
        if (inEchelon(&gs, u, .support)) {
            try std.testing.expectEqual(@as(u8, 100), u.armor_pct);
        } else if (u.armor_pct < 100) line_worn += 1;
    }
    try std.testing.expect(line_worn > 0);
    damageRandomUnits(&gs, co, 3, .support);
    var support_worn: u32 = 0;
    uit = gs.units.iterator();
    while (uit.next()) |e| if (inEchelon(&gs, e.value_ptr, .support) and e.value_ptr.armor_pct < 100) {
        support_worn += 1;
    };
    try std.testing.expect(support_worn > 0);
}

test "auto events apply, decisions queue with deadlines, defaults fire" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 42 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);

    // Hand-plant an active garrison contract.
    const co = try gs.createForce("Alpha", .company, .none);
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "PER",
        .planet_key = "galatea",
        .terms = .{ .length_months = 12, .base_pay_month = 400_000 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
    });

    // Roll many months: the log fills, and some decisions hit the inbox.
    for (0..24) |_| try rollMonthly(&gs);
    try std.testing.expect(gs.event_log.items.len >= 24);

    if (gs.event_queue.pending.items.len > 0) {
        const before = gs.event_queue.pending.items.len;
        // Answer one by hand...
        try resolveChoice(&gs, 0, 0);
        try std.testing.expectEqual(before - 1, gs.event_queue.pending.items.len);
        // ...and let the rest hit their deadlines: inbox drains, log notes it.
        gs.clock.day_index += decision_window_days + 1;
        try expireDue(&gs);
        try std.testing.expectEqual(@as(usize, 0), gs.event_queue.pending.items.len);
    }
}

test "effects change real state: cash, reputation, score, spares" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 43 });
    defer gs.deinit();
    const co = try gs.createForce("Alpha", .company, .none);
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .objective_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 400_000 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;

    try applyEffects(&gs, &.{
        .{ .cash_monthly_pct = 50 }, .{ .reputation = 2 }, .{ .score = 3 }, .{ .parts_windfall = 2 },
    }, c);
    // Field cash lands in the company's local funds (Stage 9A), not home.
    try std.testing.expectEqual(@as(i64, 150_000), gs.force(co).?.local_funds); // +50% of 300k
    try std.testing.expectEqual(@as(i64, 10_000_000), gs.funds);
    try std.testing.expectEqual(@as(i32, 2), gs.reputation);
    try std.testing.expectEqual(@as(i32, 3), c.score);
    // Weapons stay with the company; structural parts are crated home (Stage 12).
    try std.testing.expectEqual(@as(u32, 2), gs.stockCount(.{ .company = co }, "mlas"));
    try std.testing.expectEqual(@as(u32, 0), gs.stockCount(.{ .company = co }, "comp_arm"));
    var crated: u32 = gs.stockCount(gs.defaultSite(), "comp_arm"); // no HQ in this test → the outfit depot
    for (gs.part_orders.items) |o| if (std.mem.eql(u8, o.part_key, "comp_arm") and o.dest == .hq and o.status == .in_transit) {
        crated += o.quantity;
    };
    try std.testing.expectEqual(@as(u32, 2), crated);
}
