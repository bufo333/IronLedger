//! Contract event decks & the decision engine (Stage 6, ARCH §8).
//! Mirrors MekHQ's AtB monthly events: each active contract rolls 2d6 on
//! its class deck (garrison vs. combat) on the 1st. Auto events apply
//! immediately; decisions land in the inbox with a deadline (turn-based —
//! time never stops; the default applies if the deadline passes).

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const events = @import("events.zig");
const contract_mod = @import("../domain/contract.zig");
const GameState = @import("state.zig").GameState;
const unit_mod = @import("../domain/unit.zig");

pub const decision_window_days = tuning.contract.decision_window_days;

// ------------------------------------------------------------------ decks
// Static decks; dynamic magnitudes go through relative effects.

// The inbox rule (12.24, play feedback): an event is a dice roll logged
// with its result unless it meaningfully moves money or breaks hulls —
// cash in or out, supply losses, salvage and stock windfalls, damage — and
// those are decisions the player sees. Fatigue, morale, XP, score,
// reputation and standing swings resolve on their own.

pub const Entry = struct {
    kind: events.EventKind,
    log: []const u8,
    auto_effects: []const events.Effect = &.{},
    options: []const events.Option = &.{},
    default_choice: usize = 0,
};

fn garrisonDeck(roll: u8) Entry {
    return switch (roll) {
        2 => .{ .kind = .pirate_raid, .log = "Pirate raiders hit the perimeter", .options = &.{
            .{ .label = "Sortie and run them down", .effects = &.{ .{ .damage_random_units = 1 }, .{ .xp_all = 2 }, .{ .fatigue = 6 }, .{ .score = 2 } } },
            .{ .label = "Hold the perimeter", .effects = &.{ .{ .damage_random_units = 1 }, .{ .morale = -3 }, .{ .score = 1 } } },
            .{ .label = "Leave it to the militia", .effects = &.{ .{ .morale = -3 }, .{ .score = -1 } } },
        }, .default_choice = 1 },
        3 => .{ .kind = .disease_outbreak, .log = "Disease outbreak in the cantonment", .auto_effects = &.{
            .{ .fatigue = 10 }, .{ .morale = -5 },
        } },
        4 => .{ .kind = .logistics_failure, .log = "Supply convoy lost to breakdowns", .options = &.{
            .{ .label = "Buy replacements locally", .effects = &.{.{ .supply_loss = 40_000 }} },
            .{ .label = "Tighten rations until the next convoy", .effects = &.{ .{ .morale = -4 }, .{ .fatigue = 3 } } },
        }, .default_choice = 0 },
        5 => .{ .kind = .civil_disturbance, .log = "Civil disturbance in the capital", .options = &.{
            .{ .label = "Suppress it firmly (employer pays, locals resent)", .effects = &.{ .{ .cash = 100_000 }, .{ .reputation = -2 } } },
            .{ .label = "Measured response (long patrols)", .effects = &.{ .{ .reputation = 2 }, .{ .fatigue = 5 } } },
            .{ .label = "Stay in barracks", .effects = &.{.{ .reputation = -1 }} },
        }, .default_choice = 1 },
        9 => .{ .kind = .sports_riot, .log = "Company wins the garrison games", .auto_effects = &.{
            .{ .morale = 4 },
        } },
        10 => .{ .kind = .bonus_payment, .log = "Employer pays a performance bonus", .options = &.{
            .{ .label = "Bank it", .effects = &.{.{ .cash_monthly_pct = 50 }} },
            .{ .label = "Share half with the troops", .effects = &.{ .{ .cash_monthly_pct = 25 }, .{ .morale = 5 } } },
        }, .default_choice = 0 },
        11 => .{ .kind = .equipment_cache, .log = "Scouts find a sealed supply cache", .options = &.{
            .{ .label = "Crack it open quietly", .effects = &.{ .{ .parts_windfall = 3 }, .{ .reputation = -1 } } },
            .{ .label = "Report it to the employer", .effects = &.{.{ .reputation = 2 }} },
        }, .default_choice = 1 },
        12 => .{ .kind = .off_contract_request, .log = "Local governor requests off-contract work", .options = &.{
            .{ .label = "Accept the side job", .effects = &.{ .{ .cash_monthly_pct = 150 }, .{ .reputation = -2 }, .{ .fatigue = 8 } } },
            .{ .label = "Decline politely", .effects = &.{.{ .reputation = 1 }} },
        }, .default_choice = 1 },
        // Routine XP comes from payday service and training lances; a quiet
        // month just keeps spirits steady.
        else => .{ .kind = .quiet_month, .log = "A quiet month on station", .auto_effects = &.{
            .{ .morale = 1 },
        } },
    };
}

fn combatDeck(roll: u8) Entry {
    return switch (roll) {
        2 => .{ .kind = .betrayal, .log = "Liaison feeds the enemy your patrol routes", .auto_effects = &.{
            .{ .morale = -8 }, .{ .score = -2 },
        } },
        3 => .{ .kind = .supply_interdiction, .log = "Enemy interdiction chokes resupply", .options = &.{
            .{ .label = "Run the blockade in force", .effects = &.{ .{ .fatigue = 6 }, .{ .damage_random_units = 1 }, .{ .score = 1 } } },
            .{ .label = "Pay smugglers to bring it through", .effects = &.{.{ .supply_loss = 60_000 }} },
            .{ .label = "Ration and wait it out", .effects = &.{ .{ .morale = -5 }, .{ .fatigue = 3 } } },
        }, .default_choice = 1 },
        4 => .{ .kind = .enemy_reinforcements, .log = "Enemy reinforcements land", .auto_effects = &.{
            .{ .score = -1 },
        } },
        9 => .{ .kind = .intel_windfall, .log = "Recon delivers an intel windfall; the lances act on it overnight", .auto_effects = &.{
            .{ .score = 2 }, .{ .xp_all = 1 }, .{ .fatigue = 3 },
        } },
        10 => .{ .kind = .captured_salvage, .log = "Battlefield salvage recovered", .options = &.{
            .{ .label = "Crate it home for the depot", .effects = &.{.{ .parts_windfall = 2 }} },
            .{ .label = "Strip it for the trucks now", .effects = &.{ .{ .field_stock = .{ .key = "armor", .qty = 4 } }, .{ .field_stock = .{ .key = "mlas", .qty = 1 } }, .{ .fatigue = 3 } } },
        }, .default_choice = 0 },
        11 => .{ .kind = .local_support_offer, .log = "Local militia offers support — for a price", .options = &.{
            .{ .label = "Pay them 100k", .effects = &.{ .{ .cash = -100_000 }, .{ .score = 2 } } },
            .{ .label = "Refuse", .effects = &.{} },
        }, .default_choice = 1 },
        8 => .{ .kind = .salvage_dispute, .log = "The employer's salvage officer disputes your claim on the field", .options = &.{
            .{ .label = "Hand the disputed hulls over", .effects = &.{ .{ .cash = -100_000 }, .{ .employer_standing = 3 } } },
            .{ .label = "Split the difference", .effects = &.{ .{ .cash = -50_000 }, .{ .employer_standing = 1 } } },
            .{ .label = "Stand on the contract terms", .effects = &.{ .{ .employer_standing = -4 }, .{ .score = -1 } } },
        }, .default_choice = 1 },
        12 => .{ .kind = .daring_opportunity, .log = "A daring strike could break the enemy line", .options = &.{
            .{ .label = "Strike (risk the machines)", .effects = &.{ .{ .score = 3 }, .{ .damage_random_units = 2 }, .{ .fatigue = 10 } } },
            .{ .label = "Hold position", .effects = &.{} },
        }, .default_choice = 1 },
        // Real engagements (sim/battle.zig) carry the damage now; the deck's
        // middle band is the grind between them.
        else => .{ .kind = .heavy_fighting, .log = "Sustained patrol operations grind on", .auto_effects = &.{
            .{ .fatigue = 5 },
        } },
    };
}

/// Weekly happenings (Stage 12): rolled every week a contract is active,
/// on top of the monthly deck. Most weeks are quiet; the tails bring
/// small choices so the player has something to decide between battles.
fn weeklyDeck(garrison: bool, roll: u8) Entry {
    if (garrison) return switch (roll) {
        2 => .{ .kind = .night_raid, .log = "Saboteurs are probing the wire at night", .options = &.{
            .{ .label = "Stand-to all night", .effects = &.{ .{ .fatigue = 4 }, .{ .xp_all = 1 } } },
            .{ .label = "Trust the pickets", .effects = &.{ .{ .damage_random_units = 1 }, .{ .morale = -2 } } },
        }, .default_choice = 0 },
        3 => .{ .kind = .smuggler_offer, .log = "A smuggler offers parts off the back of a truck", .options = &.{
            .{ .label = "Buy them, no questions", .effects = &.{ .{ .parts_windfall = 2 }, .{ .cash = -40_000 }, .{ .reputation = -1 } } },
            .{ .label = "Turn them in to the employer", .effects = &.{.{ .reputation = 1 }} },
            .{ .label = "Send them away", .effects = &.{} },
        }, .default_choice = 2 },
        // Flavour happens on its own (12.24): the inbox is for trade-offs.
        4 => .{ .kind = .employer_inspection, .log = "The employer's liaison inspects the hangar — a long day of parade polish", .auto_effects = &.{
            .{ .fatigue = 2 },
        } },
        10 => .{ .kind = .local_festival, .log = "The town's harvest festival — the company gets the day", .auto_effects = &.{
            .{ .morale = 3 },
        } },
        11 => .{ .kind = .training_exercise, .log = "A quiet week spent on live-fire drills", .auto_effects = &.{
            .{ .xp_all = 1 }, .{ .fatigue = 3 },
        } },
        12 => .{ .kind = .press_visit, .log = "A news crew embeds with the company for a week; the troops enjoy the attention", .auto_effects = &.{
            .{ .morale = 2 }, .{ .fatigue = 1 },
        } },
        else => .{ .kind = .quiet_week, .log = "" },
    };
    return switch (roll) {
        2 => .{ .kind = .night_raid, .log = "Enemy raiders are working toward the laager in the dark", .options = &.{
            .{ .label = "Stand-to and meet them", .effects = &.{ .{ .fatigue = 5 }, .{ .xp_all = 1 }, .{ .score = 1 } } },
            .{ .label = "Trust the pickets", .effects = &.{ .{ .damage_random_units = 1 }, .{ .morale = -3 }, .{ .score = -1 } } },
        }, .default_choice = 0 },
        3 => .{ .kind = .ambush_warning, .log = "Locals warn of an ambush on the supply road", .options = &.{
            .{ .label = "Escort the convoy in force", .effects = &.{ .{ .fatigue = 6 }, .{ .score = 1 } } },
            .{ .label = "Reroute and delay", .effects = &.{.{ .supply_loss = 20_000 }} },
            .{ .label = "Ignore it", .effects = &.{ .{ .damage_convoy_units = 1 }, .{ .score = -1 } } },
        }, .default_choice = 0 },
        4 => .{ .kind = .bad_weather, .log = "A week of storms grounds both sides", .auto_effects = &.{
            .{ .morale = 2 },
        } },
        9 => .{ .kind = .black_market_contact, .log = "A black-market fixer offers munitions off the books", .options = &.{
            .{ .label = "Buy a load (60k local funds, no paperwork)", .effects = &.{ .{ .cash = -60_000 }, .{ .field_stock = .{ .key = "ammo_lrm", .qty = 4 } }, .{ .field_stock = .{ .key = "ammo_srm", .qty = 4 } }, .{ .employer_standing = -2 }, .{ .reputation = -1 } } },
            .{ .label = "Tip off the employer's provost", .effects = &.{ .{ .employer_standing = 3 }, .{ .morale = -1 } } },
            .{ .label = "Decline", .effects = &.{} },
        }, .default_choice = 2 },
        10 => .{ .kind = .supply_cache, .log = "Patrols overrun an enemy supply cache", .options = &.{
            .{ .label = "Haul it back (a long night)", .effects = &.{ .{ .parts_windfall = 1 }, .{ .field_stock = .{ .key = "ammo_srm", .qty = 2 } }, .{ .fatigue = 3 } } },
            .{ .label = "Mark it and move on", .effects = &.{} },
        }, .default_choice = 0 },
        11 => .{ .kind = .prisoner_exchange, .log = "The enemy proposes a prisoner exchange", .options = &.{
            .{ .label = "Exchange — honour among soldiers", .effects = &.{ .{ .reputation = 2 }, .{ .morale = 2 } } },
            .{ .label = "Ransom them instead (50k)", .effects = &.{ .{ .cash = 50_000 }, .{ .reputation = -1 } } },
        }, .default_choice = 0 },
        12 => .{ .kind = .field_promotion, .log = "A lance leader distinguishes themselves — the company stands taller", .auto_effects = &.{
            .{ .morale = 3 },
        } },
        else => .{ .kind = .quiet_week, .log = "" },
    };
}

/// The static deck entry for an event kind (options live in the decks, so
/// a saved pending decision is rebuilt from its kind — Stage 11).
pub fn entryForKind(kind: events.EventKind) ?Entry {
    if (kind == .notice_given) return noticeEntry();
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
        // Most weeks nothing worth a line happens (12.24: play feedback).
        if (gs.rng.random(.events).uintLessThan(u32, 10_000) >= tuning.contract.weekly_event_chance_bp) continue;
        const roll = gs.rng.roll2d6(.events);
        const deck = weeklyDeck(c.kind.isGarrisonClass(), roll);
        if (deck.kind == .quiet_week) continue;
        const ctx: @import("state.zig").LogCtx = .{ .company = c.assigned_company, .contract = c.id };
        if (deck.options.len == 0) {
            try applyEffects(gs, deck.auto_effects, c);
            try gs.log(.contract, ctx, "[{s}] (2d6 = {d}) {s}{s}", .{ @tagName(c.kind), roll, deck.log, try effectsPlain(gs, deck.auto_effects) });
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

/// " — fatigue +3, morale −2" for an automatic event's log line.
fn effectsPlain(gs: *GameState, effects: []const events.Effect) ![]const u8 {
    if (effects.len == 0) return "";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(gs.allocator(), " — ");
    for (effects, 0..) |e, i| {
        if (i > 0) try out.appendSlice(gs.allocator(), ", ");
        const piece: []const u8 = switch (e) {
            .fatigue => |f| try std.fmt.allocPrint(gs.allocator(), "fatigue +{d}", .{f}),
            .morale => |m| try std.fmt.allocPrint(gs.allocator(), "morale {s}{d}", .{ if (m < 0) "−" else "+", @abs(m) }),
            .xp_all => |x| try std.fmt.allocPrint(gs.allocator(), "XP +{d} all", .{x}),
            .score => |s| try std.fmt.allocPrint(gs.allocator(), "score {s}{d}", .{ if (s < 0) "−" else "+", @abs(s) }),
            .reputation => |r| try std.fmt.allocPrint(gs.allocator(), "reputation {s}{d}", .{ if (r < 0) "−" else "+", @abs(r) }),
            .employer_standing => |d| try std.fmt.allocPrint(gs.allocator(), "employer standing {s}{d}", .{ if (d < 0) "−" else "+", @abs(d) }),
            else => @tagName(e),
        };
        try out.appendSlice(gs.allocator(), piece);
    }
    return out.items;
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
            try gs.log(.contract, ctx, "[{s}] (2d6 = {d}) {s}{s}", .{ @tagName(c.kind), roll, deck.log, try effectsPlain(gs, deck.auto_effects) });
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
    try applyEffectsFor(gs, ev.options[choice].effects, c, ev.person);
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
            try applyEffectsFor(gs, opt.effects, c, ev.person);
            try gs.log(.decision, .{ .company = ev.company, .contract = ev.contract }, "[deadline] {s}: no answer — defaulted to \"{s}\"", .{ @tagName(ev.kind), opt.label });
            _ = gs.event_queue.pending.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

fn applyEffects(gs: *GameState, effects: []const events.Effect, contract: ?*contract_mod.Contract) !void {
    return applyEffectsFor(gs, effects, contract, .none);
}

fn applyEffectsFor(gs: *GameState, effects: []const events.Effect, contract: ?*contract_mod.Contract, person_id: types.PersonId) !void {
    const company: types.ForceId = if (contract) |c| c.assigned_company else if (gs.person(person_id)) |p| gs.companyOf(p.assigned_force) else .none;
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
            .employer_standing => |delta| if (contract) |c| {
                const now = try gs.adjustStanding(c.employer_key, delta);
                try gs.log(.contract, .{ .company = company, .contract = contract_id }, "[standing] {s} {s}{d} → {d}", .{ c.employer_key, if (delta < 0) "−" else "+", @abs(delta), now });
            },
            .raise_pct => |pct| if (gs.person(person_id)) |p| {
                const was = p.monthlySalary();
                p.salary_override = types.applyBp(was, 10_000 + @as(types.Bp, pct) * 100);
                p.morale = @intCast(@min(100, @as(u32, p.morale) + 10));
                try gs.log(.rotation, .{ .company = company }, "[turnover] {s} {s} stays on a raise: {d} → {d} c-bills/mo", .{ p.first_name, p.last_name, was, p.monthlySalary() });
            },
            .retention_bonus_months => |months| if (gs.person(person_id)) |p| {
                const bonus = p.monthlySalary() * months;
                try gs.postTransaction(.{ .day = gs.clock.day_index, .amount = -bonus, .category = .payroll, .company = company, .note = "retention bonus" });
                p.morale = @intCast(@min(100, @as(u32, p.morale) + 5));
                try gs.log(.rotation, .{ .company = company }, "[turnover] {s} {s} stays for a {d} c-bill retention bonus", .{ p.first_name, p.last_name, bonus });
            },
            .let_go => try letGo(gs, person_id, false),
            .replace_from_hall => try letGo(gs, person_id, true),
            .field_stock => |fs| {
                const site: types.Site = if (company != .none) .{ .company = company } else gs.defaultSite();
                // Trucks have finite room: what does not fit is left on the dock.
                const room: u32 = if (gs.siteCapacityTons(site)) |cap| cap -| gs.siteTons(site) else fs.qty;
                const qty = @min(@as(u32, fs.qty), room);
                if (qty > 0) try gs.addStock(site, fs.key, qty);
            },
        }
    }
}

/// Someone leaves: status by service length, seats vacated; optionally
/// the halls are asked for a replacement in the same role.
fn letGo(gs: *GameState, person_id: types.PersonId, replace: bool) !void {
    const p = gs.person(person_id) orelse return;
    if (p.status != .active) return;
    const t = @import("../domain/tuning.zig").t.person;
    const retiring = p.tenureMonths(gs.clock.day_index) >= t.retire_tenure_months;
    p.status = if (retiring) .retired else .resigned;
    const company = gs.companyOf(p.assigned_force);
    var uit = gs.units.iterator();
    while (uit.next()) |ue| {
        if (ue.value_ptr.pilot == person_id) ue.value_ptr.pilot = .none;
        if (ue.value_ptr.tech == person_id) ue.value_ptr.tech = .none;
    }
    try gs.log(.rotation, .{ .company = company, .hq = p.posted_hq }, "[turnover] {s} {s} ({s}) {s}", .{ p.first_name, p.last_name, @tagName(p.role), if (retiring) "retires" else "resigns" });
    if (!replace) return;
    for (gs.candidates.items, 0..) |cand, i| if (cand.spec.role == p.role) {
        const r = @import("commands.zig").execute(gs, .{ .hire_candidate = i }) catch |err| {
            try gs.log(.rotation, .{ .company = company }, "[turnover] no replacement hired: {s}", .{@errorName(err)});
            return;
        };
        if (gs.person(r.hired)) |np| {
            np.assigned_force = company;
            try gs.log(.rotation, .{ .company = company }, "[turnover] {s} {s} hired from the hall to replace them — assign a seat", .{ np.first_name, np.last_name });
        }
        return;
    };
    try gs.log(.rotation, .{ .company = company }, "[turnover] no {s} on the hiring halls to replace them — hire when one walks in", .{@tagName(p.role)});
}

/// The notice decision (Stage 12.25): keep them or let them go.
pub fn noticeEntry() Entry {
    return .{ .kind = .notice_given, .log = "hands in notice — morale or fatigue has worn them down", .options = &.{
        .{ .label = "A raise (+25% for good)", .effects = &.{.{ .raise_pct = 25 }} },
        .{ .label = "A retention bonus (3 months' pay, once)", .effects = &.{.{ .retention_bonus_months = 3 }} },
        .{ .label = "Let them go and hire a replacement from the hall", .effects = &.{.replace_from_hall} },
        .{ .label = "Let them go", .effects = &.{.let_go} },
    }, .default_choice = 3 };
}

/// Queue the notice decision for a person unless one is already pending.
pub fn queueNotice(gs: *GameState, person_id: types.PersonId) !void {
    for (gs.event_queue.pending.items) |ev| if (ev.person == person_id and ev.needsDecision()) return;
    const p = gs.person(person_id) orelse return;
    const e = noticeEntry();
    try gs.event_queue.push(gs.allocator(), .{
        .day = gs.clock.day_index,
        .kind = .notice_given,
        .company = gs.companyOf(p.assigned_force),
        .person = person_id,
        .options = e.options,
        .default_choice = e.default_choice,
        .deadline_day = gs.clock.day_index + decision_window_days,
    });
    try gs.log(.decision, .{ .company = gs.companyOf(p.assigned_force), .hq = p.posted_hq }, "[turnover] DECISION: {s} {s} ({s}, {d} c-bills/mo, morale {d}, fatigue {d}) hands in notice — raise, bonus, replace, or let go (inbox, {d} days)", .{
        p.first_name, p.last_name, @tagName(p.role), p.monthlySalary(), p.morale, p.fatigue, decision_window_days,
    });
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

test "12.22: the black market and a salvage dispute move standing and field stock" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1222 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    const co = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha");
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
    gs.force(co).?.local_funds = 200_000;
    const bm = entryForKind(.black_market_contact).?;
    const before = gs.stockCount(.{ .company = co }, "ammo_lrm");
    try applyEffects(&gs, bm.options[0].effects, c); // buy
    try std.testing.expect(gs.stockCount(.{ .company = co }, "ammo_lrm") > before);
    try std.testing.expectEqual(@as(i32, -2), gs.standing("LC"));
    try std.testing.expectEqual(@as(i64, 140_000), gs.force(co).?.local_funds);
    const sd = entryForKind(.salvage_dispute).?;
    try applyEffects(&gs, sd.options[0].effects, c); // hand it over
    try std.testing.expectEqual(@as(i32, 1), gs.standing("LC"));
    try applyEffects(&gs, sd.options[2].effects, c); // stand firm
    try std.testing.expectEqual(@as(i32, -3), gs.standing("LC"));
    try std.testing.expectEqual(@as(i32, -1), c.score);
    // Both kinds are in a deck the rollers reach.
    try std.testing.expect(combatDeck(8).kind == .salvage_dispute);
    try std.testing.expect(weeklyDeck(false, 9).kind == .black_market_contact);
}

test "12.24: automatic events never move money, stock or hulls — those are decisions" {
    var roll: u8 = 2;
    while (roll <= 12) : (roll += 1) {
        const decks = [_]Entry{ garrisonDeck(roll), combatDeck(roll), weeklyDeck(true, roll), weeklyDeck(false, roll) };
        for (decks) |e| {
            if (e.options.len > 0) continue;
            for (e.auto_effects) |fx| switch (fx) {
                .fatigue, .morale, .xp_all, .score, .reputation, .employer_standing => {},
                .cash, .cash_monthly_pct, .supply_loss, .parts_windfall, .field_stock, .damage_random_units, .damage_convoy_units, .raise_pct, .retention_bonus_months, .let_go, .replace_from_hall => {
                    std.debug.print("auto event {s} carries a player-facing effect\n", .{@tagName(e.kind)});
                    return error.TestUnexpectedResult;
                },
            };
        }
    }
}

test "12.25: notice is a decision — a raise keeps them, letting go vacates the seat, replacing hires from the hall" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1225 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    const co = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha");
    var pilot: types.PersonId = .none;
    var mek: types.UnitId = .none;
    var uit = gs.units.iterator();
    while (uit.next()) |e| if (e.value_ptr.kind == .mek and pilot == .none) {
        pilot = e.value_ptr.pilot;
        mek = e.value_ptr.id;
    };
    try queueNotice(&gs, pilot);
    try queueNotice(&gs, pilot); // no duplicate
    try std.testing.expectEqual(@as(usize, 1), gs.event_queue.pending.items.len);
    const before = gs.person(pilot).?.monthlySalary();
    try resolveChoice(&gs, 0, 0); // raise
    try std.testing.expect(gs.person(pilot).?.monthlySalary() > before);
    try std.testing.expectEqual(@import("../domain/person.zig").Status.active, gs.person(pilot).?.status);
    // Let go: the seat opens.
    try queueNotice(&gs, pilot);
    try resolveChoice(&gs, 0, 3);
    try std.testing.expectEqual(@import("../domain/person.zig").Status.resigned, gs.person(pilot).?.status);
    try std.testing.expectEqual(types.PersonId.none, gs.unit(mek).?.pilot);
    // Replace: a mekwarrior on the hall is hired into the company.
    const other = gs.unit(gs.units.keys()[1]).?.pilot;
    try gs.candidates.append(gs.allocator(), .{ .hq = gs.hqs.keys()[0], .spec = @import("../gen/person_gen.zig").generate(&gs.rng, .mekwarrior), .asking_bonus = 0, .listed_day = 0, .expires_day = 400 });
    const people_before = gs.people.count();
    try queueNotice(&gs, other);
    try resolveChoice(&gs, 0, 2);
    try std.testing.expectEqual(people_before + 1, gs.people.count());
    try std.testing.expectEqual(co, gs.person(gs.people.keys()[gs.people.count() - 1]).?.assigned_force);
}
