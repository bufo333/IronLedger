//! The situation engine (ARCHITECTURE.md §8 "Situations"): which situation
//! an arc contract raises next, raising it into the decision inbox, and
//! applying an answer. Selection reads campaign state alone and draws no
//! RNG; raising and answering are failure-atomic (rules 11–14).
//! No MekHQ counterpart (ROADMAP P5c).

const std = @import("std");
const types = @import("../domain/types.zig");
const contract_mod = @import("../domain/contract.zig");
const situation_mod = @import("../domain/situation.zig");
const actor_mod = @import("../domain/actor.zig");
const state_mod = @import("state.zig");
const GameState = state_mod.GameState;
const actors = @import("actors.zig");
const world_state = @import("world_state.zig");
const contract_events = @import("contract_events.zig");

pub const Situation = situation_mod.Situation;
pub const SituationRecord = situation_mod.SituationRecord;

/// The situation a contract raises next and the actor who owns it.
pub const Due = struct {
    situation: *const Situation,
    actor: types.ActorId,
};

/// The contract's attached actor of this archetype, or null.
pub fn ownerOf(gs: *GameState, c: *const contract_mod.Contract, archetype_key: []const u8) ?*actor_mod.Actor {
    for (c.actor_ids.items) |id| {
        const a = gs.actor(id) orelse continue;
        if (std.mem.eql(u8, a.archetype_key, archetype_key)) return a;
    }
    return null;
}

/// The contract's record of the situation with this key, or null.
pub fn recordOf(c: *const contract_mod.Contract, key: []const u8) ?*SituationRecord {
    for (c.situations.items) |*r| if (std.mem.eql(u8, r.key, key)) return r;
    return null;
}

/// Rule owner: the situation an active contract raises next — the first
/// situations.zon row, in table order, of the contract's arc that it has
/// not raised, whose beat the arc has reached, whose owner archetype is
/// attached to the contract, and whose flag requirement that actor
/// carries. Null when none is due. Pure: reads campaign state, draws no RNG.
pub fn nextDue(gs: *GameState, c: *const contract_mod.Contract) ?Due {
    if (c.status != .active) return null;
    for (situation_mod.table.situations) |*s| {
        if (!std.mem.eql(u8, s.arc, c.arc_key)) continue;
        if (recordOf(c, s.key) != null) continue;
        if (c.arc_beat < s.minBeatIndex()) continue;
        const owner = ownerOf(gs, c, s.owner) orelse continue;
        if (s.requires_actor_flag) |flag| if (!owner.flags.contains(flag)) continue;
        return .{ .situation = s, .actor = owner.id };
    }
    return null;
}

/// Raise the situation `nextDue` names: a decision in the inbox with the
/// contract's decision window and the row's default, a record on the
/// contract, and a log line naming the owner (and, for a callback, why it
/// came back). Returns false, changing nothing, when none is due.
/// Failure-atomic: queue, record and log room are reserved and the line
/// formatted before the first mutation.
pub fn queueDue(gs: *GameState, c: *contract_mod.Contract) !bool {
    const due = nextDue(gs, c) orelse return false;
    const s = due.situation;
    const owner = gs.actor(due.actor).?; // nextDue found it attached
    const archetype = actor_mod.find(s.owner).?; // validated with the table
    const today = gs.clock.day_index;
    const window = contract_events.decision_window_days;

    // PREPARE
    try gs.event_queue.pending.ensureUnusedCapacity(gs.allocator(), 1);
    try c.situations.ensureUnusedCapacity(gs.allocator(), 1);
    const line = try gs.prepareLog(.decision, .{ .company = c.assigned_company, .contract = c.id }, "[situation] DECISION: {s} {s} ({s}) {s}{s}{s} (inbox, {d} days to answer)", .{
        owner.first_name, owner.last_name, archetype.name, s.title,
        if (s.callback_note.len > 0) " — " else "",
        s.callback_note,  window,
    });

    // COMMIT
    _ = gs.event_queue.pushAssumeCapacity(.{
        .day = today,
        .kind = .situation,
        .contract = c.id,
        .company = c.assigned_company,
        .options = s.eventOptions(),
        .default_choice = s.default_choice,
        .deadline_day = today + window,
        .situation = s.key,
        .actor = owner.id,
    });
    c.situations.appendAssumeCapacity(.{ .key = s.key, .day = today, .actor = owner.id });
    gs.commitLog(line);
    return true;
}

/// How an answer reached a situation.
pub const How = enum { answered, defaulted };

/// Apply answer `choice` to the pending situation `event_id`: the option's
/// costs (`contract_events.prepareCosts`), the owner's relationship and
/// flags (`actors`), the contract world's state and flags (`world_state`),
/// the record's choice and a log line naming the owner and the cost; the
/// event leaves the inbox. Validate, prepare, commit (rules 11–14): an
/// error changes nothing. A choice out of range is `NoSuchChoice`; an
/// event that is not a pending situation is `NoSuchDecision` or
/// `NotADecision`; a situation whose row, contract, record or owner is
/// missing is `CorruptSave`.
pub fn resolve(gs: *GameState, event_id: types.EventId, choice: usize, how: How) !void {
    // VALIDATE
    const at = gs.event_queue.indexOf(event_id) orelse return error.NoSuchDecision;
    const ev = gs.event_queue.pending.items[at];
    if (ev.kind != .situation or !ev.needsDecision()) return error.NotADecision;
    const s = situation_mod.find(ev.situation) orelse return error.CorruptSave;
    if (choice >= s.options.len) return error.NoSuchChoice;
    const c = gs.contracts.getPtr(ev.contract) orelse return error.CorruptSave;
    const record = recordOf(c, s.key) orelse return error.CorruptSave;
    if (record.choice != null or record.actor != ev.actor) return error.CorruptSave;
    const owner = gs.actor(ev.actor) orelse return error.CorruptSave;
    const archetype = actor_mod.find(owner.archetype_key) orelse return error.CorruptSave;
    const opt = &s.options[choice];
    const actor_flags = opt.actorFlags();
    const world_flags = opt.worldFlags();
    const moves_actor = !opt.relationship.isZero();
    const moves_world = c.planet_key.len > 0 and (!opt.world.isZero() or world_flags.count() > 0);
    const ctx: state_mod.LogCtx = .{ .company = c.assigned_company, .contract = c.id };

    // PREPARE: one reservation covers every line this answer writes.
    try gs.reserveLog(1 + contract_events.costLogLines(opt.costs, c) + @intFromBool(moves_actor) + @intFromBool(moves_world));
    const costs = try contract_events.prepareCosts(gs, opt.costs, c, c.assigned_company);
    const relationship: ?actors.PreparedAdjust = if (moves_actor) try actors.prepareAdjustRelationship(gs, owner.id, opt.relationship, opt.label) else null;
    const world: ?world_state.PreparedWorldAdjust = if (moves_world) try world_state.prepareWorldAdjust(gs, c.planet_key, opt.world, opt.label) else null;
    const cost_text = try contract_events.effectsPlain(gs, opt.costs);
    const line = switch (how) {
        .answered => try gs.prepareLog(.decision, ctx, "[situation] {s} {s} ({s}): chose \"{s}\"{s} · {s}", .{ owner.first_name, owner.last_name, archetype.name, opt.label, cost_text, opt.remembers }),
        .defaulted => try gs.prepareLog(.decision, ctx, "[deadline] situation: {s} {s} ({s}): no answer — defaulted to \"{s}\"{s} · {s}", .{ owner.first_name, owner.last_name, archetype.name, opt.label, cost_text, opt.remembers }),
    };

    // COMMIT: infallible from here.
    gs.commitLog(line);
    contract_events.commitCosts(gs, &costs);
    if (relationship) |p| actors.commitAdjustRelationship(gs, p);
    owner.flags = actors.setFlags(owner.flags, actor_flags);
    if (world) |p| {
        world_state.commitWorldAdjust(gs, p);
        const ws = gs.world_states.getPtr(c.planet_key).?; // the commit made it
        ws.flags = world_state.setFlags(ws.flags, world_flags);
    }
    record.choice = @intCast(choice);
    _ = gs.event_queue.pending.orderedRemove(at);
}

// ---- Tests -----------------------------------------------------------------

const testing = std.testing;
const founding = @import("founding.zig");
const starter_company = @import("starter_company.zig");
const commands = @import("commands.zig");
const digest = @import("digest.zig");
const checklist = @import("checklist.zig");
const field_supply = @import("field_supply.zig");
const operations = @import("operations.zig");
const contract_market = @import("contract_market.zig");
const campaign_scripts = @import("campaign_scripts.zig");
const world_state_dom = @import("../domain/world_state.zig");

/// An active garrison-duty contract on galatea, on the arc with
/// situations, its actors attached, for the starter company.
pub fn garrisonContractForTest(gs: *GameState) !*contract_mod.Contract {
    _ = try founding.createCommander(gs, "T", .LC, .line_officer);
    const co = try starter_company.generateInto(gs, "Alpha");
    return plantGarrisonForTest(gs, co, "galatea");
}

/// Another such contract for `company` on `planet`.
pub fn plantGarrisonForTest(gs: *GameState, company: types.ForceId, planet: []const u8) !*contract_mod.Contract {
    const id: types.ContractId = @enumFromInt(gs.next_contract_id);
    gs.next_contract_id += 1;
    var c: contract_mod.Contract = .{
        .id = id,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = planet,
        .terms = .{ .length_months = 12, .base_pay_month = 400_000 },
        .status = .active,
        .assigned_company = company,
        .start_day = gs.clock.day_index,
        .end_day = gs.clock.day_index + 360,
        .arc_key = "fracturing_garrison",
    };
    try actors.instantiateActors(gs, &c, gs.next_actor_id);
    gs.next_actor_id += @intCast(c.actor_ids.items.len);
    try gs.contracts.put(gs.allocator(), id, c);
    return gs.contracts.getPtr(id).?;
}

/// A founded campaign that has accepted a garrison-arc contract off the
/// board and funded its company; the contract is in transit.
pub fn acceptedGarrisonForTest(gs: *GameState) !types.ContractId {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try founding.createCommander(gs, "T", .LC, .line_officer);
    const co = try starter_company.generateInto(gs, "Alpha");
    const offer: types.ContractId = hunt: for (0..24) |_| {
        for (gs.contract_offers.items) |*o| {
            const arc = operations.selectArcKeyFor(o.kind) orelse continue;
            if (situation_mod.arcHasSituations(arc) and contract_market.offerEligible(gs, o, co)) break :hunt o.id;
        }
        try campaign_scripts.clearHoldsForTest(gs, arena.allocator());
        _ = try commands.execute(gs, .{ .advance_days = 30 });
    } else return error.NoGarrisonOffer;
    _ = try commands.execute(gs, .{ .accept_contract = .{ .offer = offer, .company = co } });
    _ = try commands.execute(gs, .{ .transfer = .{ .from = .outfit, .to = .{ .company = co }, .amount = 500_000 } });
    return offer;
}

/// Plant a garrison contract for the campaign's first company and raise
/// its first situation; returns the decision's id (client test fixture).
pub fn raisedSituationForTest(gs: *GameState) !types.EventId {
    for (gs.forces.values()) |f| if (f.echelon == .company) {
        const c = try plantGarrisonForTest(gs, f.id, "galatea");
        try testing.expect(try queueDue(gs, c));
        return pendingForTest(gs, "crates_off_the_books").?;
    };
    return error.NoCompany;
}

/// The pending situation with this key, if any.
fn pendingForTest(gs: *GameState, key: []const u8) ?types.EventId {
    for (gs.event_queue.pending.items) |ev| if (ev.kind == .situation and std.mem.eql(u8, ev.situation, key)) return ev.id;
    return null;
}

fn lastLogForTest(gs: *GameState) []const u8 {
    return gs.event_log.items[gs.event_log.items.len - 1].text;
}

test "nextDue: beat gate, flag gate, an attached owner, once per contract — and no dice" {
    var gs = GameState.init(testing.allocator, .{ .seed = 5101 });
    defer gs.deinit();
    const c = try garrisonContractForTest(&gs);
    const dice = gs.rng;
    try testing.expectEqualStrings("crates_off_the_books", nextDue(&gs, c).?.situation.key);
    try testing.expectEqual(ownerOf(&gs, c, "black_market").?.id, nextDue(&gs, c).?.actor);
    try testing.expect(try queueDue(&gs, c));
    // The drill waits for the complication beat; the callback for its flag.
    try testing.expect(nextDue(&gs, c) == null);
    c.arc_beat = 1;
    try testing.expectEqualStrings("drill_the_militia", nextDue(&gs, c).?.situation.key);
    // A contract without the owner attached raises nothing.
    var bare = c.*;
    bare.actor_ids = .empty;
    bare.situations = .empty;
    try testing.expect(nextDue(&gs, &bare) == null);
    try testing.expect(try queueDue(&gs, c));
    c.arc_beat = 2;
    try testing.expect(nextDue(&gs, c) == null);
    ownerOf(&gs, c, "black_market").?.flags.insert(.did_business);
    try testing.expectEqualStrings("the_contact_returns", nextDue(&gs, c).?.situation.key);
    try testing.expect(try queueDue(&gs, c));
    // Each situation comes up once; nothing is left.
    try testing.expect(nextDue(&gs, c) == null);
    try testing.expect(!try queueDue(&gs, c));
    try testing.expectEqual(@as(usize, 3), c.situations.items.len);
    // Only an active contract raises one.
    var done = bare;
    done.actor_ids = c.actor_ids;
    done.status = .completed;
    try testing.expect(nextDue(&gs, &done) == null);
    try testing.expectEqual(dice, gs.rng);
}

test "the 1st of the month raises a situation on an arc contract without a die; other contracts roll their deck" {
    var gs = GameState.init(testing.allocator, .{ .seed = 5102 });
    defer gs.deinit();
    const c = try garrisonContractForTest(&gs);
    const dice = gs.rng;
    try contract_events.rollMonthly(&gs);
    try testing.expectEqual(dice, gs.rng);
    try testing.expect(pendingForTest(&gs, "crates_off_the_books") != null);
    try testing.expect(std.mem.indexOf(u8, lastLogForTest(&gs), "[situation] DECISION:") != null);
    // Nothing due next month: a quiet line, still no die.
    try contract_events.rollMonthly(&gs);
    try testing.expectEqual(dice, gs.rng);
    try testing.expect(std.mem.indexOf(u8, lastLogForTest(&gs), "[situation] a quiet month on station") != null);
    try testing.expectEqual(@as(usize, 1), gs.event_queue.pending.items.len);

    // A cadre contract, and a garrison contract without an arc, roll the deck.
    c.status = .completed;
    const template = c.*;
    for ([_]contract_mod.ContractKind{ .cadre_duty, .garrison_duty }) |kind| {
        var other = template;
        other.id = @enumFromInt(gs.next_contract_id);
        gs.next_contract_id += 1;
        other.kind = kind;
        other.arc_key = "";
        other.status = .active;
        other.actor_ids = .empty;
        other.situations = .empty;
        try gs.contracts.put(gs.allocator(), other.id, other);
        const before = gs.rng;
        try contract_events.rollMonthly(&gs);
        try testing.expect(!std.meta.eql(before, gs.rng));
        gs.contracts.getPtr(other.id).?.status = .completed;
    }
}

test "an answer applies exactly its costs, its deltas and its flags; the record and the log name them" {
    var gs = GameState.init(testing.allocator, .{ .seed = 5103 });
    defer gs.deinit();
    const c = try garrisonContractForTest(&gs);
    const co = c.assigned_company;
    const contact = ownerOf(&gs, c, "black_market").?.id;
    try testing.expect(try queueDue(&gs, c));
    const funds = gs.force(co).?.local_funds;
    const ledger = gs.ledger.transactions.items.len;
    _ = try commands.execute(&gs, .{ .resolve_decision = .{ .event = pendingForTest(&gs, "crates_off_the_books").?, .choice = 0 } });
    // Buy: 60,000 out of the company's fund, employer standing −1.
    try testing.expectEqual(funds - 60_000, gs.force(co).?.local_funds);
    try testing.expectEqual(ledger + 1, gs.ledger.transactions.items.len);
    try testing.expectEqual(@as(i32, -1), gs.standing("LC"));
    const a = gs.actor(contact).?;
    try testing.expectEqual(@as(i16, 10), a.trust);
    try testing.expectEqual(@as(i16, 5), a.debt);
    try testing.expect(a.flags.contains(.did_business));
    try testing.expect(gs.worldState("galatea").?.flags.contains(.black_market_open));
    try testing.expectEqual(@as(?u8, 0), recordOf(c, "crates_off_the_books").?.choice);
    try testing.expect(pendingForTest(&gs, "crates_off_the_books") == null);
    var named = false;
    for (gs.event_log.items) |e| if (std.mem.indexOf(u8, e.text, "chose \"Buy the crates, no paperwork\" — -60,000 C") != null) {
        named = std.mem.indexOf(u8, e.text, a.first_name) != null;
    };
    try testing.expect(named);

    // Keep the company on the line: +3 on the clock, respect −10, the town's support −5.
    c.arc_beat = 1;
    try testing.expect(try queueDue(&gs, c));
    const clock = c.escalation_clock;
    const militia = ownerOf(&gs, c, "militia_commander").?;
    _ = try commands.execute(&gs, .{ .resolve_decision = .{ .event = pendingForTest(&gs, "drill_the_militia").?, .choice = 1 } });
    try testing.expectEqual(clock + 3, c.escalation_clock);
    try testing.expectEqual(@as(i16, -10), militia.respect);
    try testing.expectEqual(@as(i16, -5), gs.worldState("galatea").?.civilian_support);
    try testing.expect(militia.flags.count() == 0);

    // Cutting ties ends the business: the callback's flag clears.
    c.arc_beat = 2;
    try testing.expect(try queueDue(&gs, c));
    _ = try commands.execute(&gs, .{ .resolve_decision = .{ .event = pendingForTest(&gs, "the_contact_returns").?, .choice = 1 } });
    try testing.expectEqual(clock + 3 + 5, c.escalation_clock);
    try testing.expect(gs.actor(contact).?.flags.contains(.cut_ties));
    try testing.expect(!gs.actor(contact).?.flags.contains(.did_business));
    try testing.expectEqual(@as(i16, 15), gs.actor(contact).?.hostility);
}

test "turning the contact in costs the company fatigue and spirit and shuts the market" {
    var gs = GameState.init(testing.allocator, .{ .seed = 5104 });
    defer gs.deinit();
    const c = try garrisonContractForTest(&gs);
    try testing.expect(try queueDue(&gs, c));
    var expected: std.ArrayListUnmanaged(struct { id: types.PersonId, fatigue: u8, morale: u8 }) = .empty;
    defer expected.deinit(testing.allocator);
    for (gs.people.values()) |p| if (p.status == .active and @import("toe.zig").personInCompany(&gs, &p, c.assigned_company)) {
        var after = p;
        after.addFatigue(3);
        after.addMorale(-1);
        try expected.append(testing.allocator, .{ .id = p.id, .fatigue = after.fatigue, .morale = after.morale });
    };
    try testing.expect(expected.items.len > 0);
    _ = try commands.execute(&gs, .{ .resolve_decision = .{ .event = pendingForTest(&gs, "crates_off_the_books").?, .choice = 1 } });
    for (expected.items) |e| {
        try testing.expectEqual(e.fatigue, gs.person(e.id).?.fatigue);
        try testing.expectEqual(e.morale, gs.person(e.id).?.morale);
    }
    const contact = ownerOf(&gs, c, "black_market").?;
    try testing.expectEqual(@as(i16, 20), contact.hostility);
    try testing.expect(contact.flags.contains(.informed_on));
    try testing.expect(gs.worldState("galatea").?.flags.contains(.black_market_closed));
}

test "an unanswered situation stops the advance the day it lands and the day before it defaults, then defaults" {
    var gs = GameState.init(testing.allocator, .{ .seed = 5105 });
    defer gs.deinit();
    const c = try garrisonContractForTest(&gs);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const watch = try checklist.watchDay(arena.allocator(), &gs);
    try testing.expect(try queueDue(&gs, c));
    try testing.expectEqual(checklist.StopReason.decision_due, checklist.advanceStop(&gs, &watch).?.reason);
    const ev = gs.event_queue.find(pendingForTest(&gs, "crates_off_the_books").?).?.*;
    try testing.expect(!ev.holdsTurn());
    gs.clock.day_index = ev.deadline_day - 2;
    try testing.expect(checklist.advanceStop(&gs, null) == null);
    gs.clock.day_index = ev.deadline_day - 1;
    try testing.expectEqual(checklist.StopReason.decision_due, checklist.advanceStop(&gs, null).?.reason);
    gs.clock.day_index = ev.deadline_day;
    try contract_events.expireDue(&gs);
    try testing.expect(pendingForTest(&gs, "crates_off_the_books") == null);
    try testing.expectEqual(@as(?u8, 2), recordOf(c, "crates_off_the_books").?.choice);
    try testing.expect(std.mem.indexOf(u8, lastLogForTest(&gs), "no answer — defaulted to \"Send them away\"") != null);
    // Sending them away leaves no flag behind.
    try testing.expect(gs.worldState("galatea") == null);
    try testing.expectEqual(@as(usize, 0), ownerOf(&gs, c, "black_market").?.flags.count());
}

test "a refused answer consumes nothing" {
    var gs = GameState.init(testing.allocator, .{ .seed = 5106 });
    defer gs.deinit();
    const c = try garrisonContractForTest(&gs);
    try testing.expect(try queueDue(&gs, c));
    const id = pendingForTest(&gs, "crates_off_the_books").?;
    const before = digest.stateHash(&gs);
    try testing.expectError(error.NoSuchChoice, commands.execute(&gs, .{ .resolve_decision = .{ .event = id, .choice = 3 } }));
    try testing.expectEqual(before, digest.stateHash(&gs));
    _ = try commands.execute(&gs, .{ .resolve_decision = .{ .event = id, .choice = 2 } });
    const answered = digest.stateHash(&gs);
    try testing.expectError(error.NoSuchDecision, commands.execute(&gs, .{ .resolve_decision = .{ .event = id, .choice = 0 } }));
    try testing.expectEqual(answered, digest.stateHash(&gs));
}

/// The destinations a failure-injection case reserves before it runs, so
/// the first failing allocation lands on a later prepare step.
const ReservedForTest = struct {
    pending: bool = false,
    record: bool = false,
    log: bool = false,
    ledger: bool = false,
    standing: bool = false,
};

/// Raise (or, with `answer`, buy the crates on) the first situation of a
/// fresh garrison contract with the campaign arena failing at its
/// `fail_index`th fresh allocation after `reserved` is set aside. Every
/// destination starts full and the log is long, so each growth needs an
/// allocation of its own. On a failure the complete digest is unchanged
/// and a retry completes; returns whether a failure was injected.
fn atomicCaseForTest(answer: bool, reserved: ReservedForTest, fail_index: usize) !bool {
    var outer = std.heap.ArenaAllocator.init(testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 5107 });
    defer gs.deinit();
    const c = try garrisonContractForTest(&gs);
    if (answer) try testing.expect(try queueDue(&gs, c));
    for (0..256) |_| try gs.event_log.append(gs.allocator(), .{ .day = 0, .category = .misc, .text = "padding" });
    gs.event_log.capacity = gs.event_log.items.len;
    gs.ledger.transactions.capacity = gs.ledger.transactions.items.len;
    gs.event_queue.pending.capacity = gs.event_queue.pending.items.len;
    c.situations.capacity = c.situations.items.len;
    if (reserved.pending) try gs.event_queue.pending.ensureUnusedCapacity(gs.allocator(), 1);
    if (reserved.record) try c.situations.ensureUnusedCapacity(gs.allocator(), 1);
    if (reserved.log) try gs.reserveLog(8);
    if (reserved.ledger) try gs.reserveLedger(4);
    if (reserved.standing) try gs.faction_standing.ensureUnusedCapacity(gs.allocator(), 1);
    const before = digest.stateHash(&gs);
    const arena_state = gs.arena.state;
    const child = gs.arena.child_allocator;
    // A fresh arena over the failing allocator, its first node a small one
    // made here (allocation 0), and no node grown in place: every growth of
    // the operation is a counted allocation.
    var failing = std.testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = fail_index + 1, .resize_fail_index = 0 });
    gs.arena.state = .{};
    gs.arena.child_allocator = failing.allocator();
    _ = try gs.allocator().alloc(u8, 1);
    const result: anyerror!void = if (answer) contract_events.resolveChoice(&gs, gs.event_queue.pending.items[0].id, 0) else if (queueDue(&gs, c)) |_| {} else |err| err;
    gs.arena.state = arena_state;
    gs.arena.child_allocator = child;
    if (result) |_| {
        try testing.expect(!failing.has_induced_failure);
        return false;
    } else |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        try testing.expectEqual(before, digest.stateHash(&gs));
        if (answer) try contract_events.resolveChoice(&gs, gs.event_queue.pending.items[0].id, 0) else try testing.expect(try queueDue(&gs, c));
        try testing.expect(before != digest.stateHash(&gs));
        return true;
    }
}

test "raising a situation is atomic at each of its prepare steps" {
    // The inbox slot, the record slot, the log line's text, the log slot.
    try testing.expect(try atomicCaseForTest(false, .{}, 0));
    try testing.expect(try atomicCaseForTest(false, .{ .pending = true }, 0));
    try testing.expect(try atomicCaseForTest(false, .{ .pending = true, .record = true, .log = true }, 0));
    try testing.expect(try atomicCaseForTest(false, .{ .pending = true, .record = true }, 1));
}

test "answering a situation is atomic at each of its prepare steps" {
    // The log slots, the ledger slot, the employer's standing entry …
    try testing.expect(try atomicCaseForTest(true, .{}, 0));
    try testing.expect(try atomicCaseForTest(true, .{ .log = true }, 0));
    try testing.expect(try atomicCaseForTest(true, .{ .log = true, .ledger = true }, 0));
    // … then every string and the world's entry, one allocation at a time.
    var failures: usize = 0;
    for (0..32) |fail_index| {
        if (!try atomicCaseForTest(true, .{ .log = true, .ledger = true, .standing = true }, fail_index)) break;
        failures += 1;
    }
    try testing.expect(failures >= 2);
}

test "an actor's flags recur with it, and a world's stay on the planet for the next contract" {
    var gs = GameState.init(testing.allocator, .{ .seed = 5108 });
    defer gs.deinit();
    const first = try garrisonContractForTest(&gs);
    try testing.expect(try queueDue(&gs, first));
    _ = try commands.execute(&gs, .{ .resolve_decision = .{ .event = pendingForTest(&gs, "crates_off_the_books").?, .choice = 0 } });
    first.status = .completed;
    const second = try plantGarrisonForTest(&gs, first.assigned_company, "galatea");
    const contact = ownerOf(&gs, second, "black_market").?;
    try testing.expect(contact.recurring);
    try testing.expect(contact.flags.contains(.did_business));
    try testing.expect(gs.worldState("galatea").?.flags.contains(.black_market_open));
    // The new contract raises its own situations from the start.
    try testing.expectEqualStrings("crates_off_the_books", nextDue(&gs, second).?.situation.key);
}

test "a world's flags price only that world's supplies" {
    var gs = GameState.init(testing.allocator, .{ .seed = 5109 });
    defer gs.deinit();
    const here = try garrisonContractForTest(&gs);
    const there = try plantGarrisonForTest(&gs, here.assigned_company, "skye");
    const here_before = field_supply.localPriceMultBp(&gs, here);
    const there_before = field_supply.localPriceMultBp(&gs, there);
    try testing.expect(try queueDue(&gs, here));
    _ = try commands.execute(&gs, .{ .resolve_decision = .{ .event = pendingForTest(&gs, "crates_off_the_books").?, .choice = 0 } });
    const t = @import("../domain/tuning.zig").t.situations;
    try testing.expectEqual(types.applyBp(here_before, t.black_market_price_bp), field_supply.localPriceMultBp(&gs, here));
    try testing.expectEqual(there_before, field_supply.localPriceMultBp(&gs, there));
}

/// What one garrison contract played to its end leaves behind.
const PlayedForTest = struct {
    finale: []const u8,
    raised: usize,
    callback: bool,
    price_bp: types.Bp,
    unflagged_price_bp: types.Bp,
    situation_log_lines: usize,
};

/// Play the accepted garrison contract at `seed` to its end, answering the
/// crates with `crates` and the militia with `militia`, the callback with
/// its first answer, and everything else with its default.
fn playGarrisonForTest(al: std.mem.Allocator, seed: u64, crates: usize, militia: usize) !PlayedForTest {
    var gs = GameState.init(testing.allocator, .{ .seed = seed });
    defer gs.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const id = try acceptedGarrisonForTest(&gs);
    var callback = false;
    for (0..900) |_| {
        _ = arena.reset(.retain_capacity);
        try campaign_scripts.clearHoldsForTest(&gs, arena.allocator());
        for ([_][]const u8{ "crates_off_the_books", "drill_the_militia", "the_contact_returns" }, [_]usize{ crates, militia, 0 }) |key, choice| {
            const ev = pendingForTest(&gs, key) orelse continue;
            if (std.mem.eql(u8, key, "the_contact_returns")) callback = true;
            _ = try commands.execute(&gs, .{ .resolve_decision = .{ .event = ev, .choice = choice } });
        }
        if (gs.contracts.getPtr(id).?.isClosed()) break;
        _ = try commands.execute(&gs, .advance_day);
    } else return error.ContractNeverEnded;
    const c = gs.contracts.getPtr(id).?;
    const price = field_supply.localPriceMultBp(&gs, c);
    const ws = gs.worldState(c.planet_key) orelse return error.NoWorldState;
    const flags = ws.flags;
    ws.flags = .{};
    const unflagged = field_supply.localPriceMultBp(&gs, c);
    ws.flags = flags;
    var lines: usize = 0;
    for (gs.event_log.items) |e| lines += @intFromBool(e.contract == id and std.mem.indexOf(u8, e.text, "[situation]") != null);
    return .{
        .finale = try al.dupe(u8, c.arc_finale_key),
        .raised = c.situations.items.len,
        .callback = callback,
        .price_bp = price,
        .unflagged_price_bp = unflagged,
        .situation_log_lines = lines,
    };
}

test "the same contract played with opposite answers raises different situations, prices and finales" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const t = @import("../domain/tuning.zig").t.situations;
    // Bought the crates and drilled the militia.
    const traded = try playGarrisonForTest(al, 5110, 0, 0);
    // Turned the contact in and kept the company on the line.
    const informed = try playGarrisonForTest(al, 5110, 1, 1);
    try testing.expect(traded.callback);
    try testing.expect(!informed.callback);
    try testing.expectEqual(@as(usize, 3), traded.raised);
    try testing.expectEqual(@as(usize, 2), informed.raised);
    try testing.expectEqual(types.applyBp(traded.unflagged_price_bp, t.black_market_price_bp), traded.price_bp);
    try testing.expectEqual(types.applyBp(informed.unflagged_price_bp, t.informant_price_bp), informed.price_bp);
    try testing.expectEqualStrings("held_with_the_town", traded.finale);
    try testing.expectEqualStrings("held", informed.finale);
    try testing.expect(traded.situation_log_lines > informed.situation_log_lines);
    // Sending the contact away leaves the price and the callback as if
    // nothing had been offered.
    const declined = try playGarrisonForTest(al, 5110, 2, 1);
    try testing.expect(!declined.callback);
    try testing.expectEqual(declined.unflagged_price_bp, declined.price_bp);
    try testing.expectEqualStrings("held", declined.finale);
}
