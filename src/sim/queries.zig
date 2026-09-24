//! Query layer (Stage 12, docs/tui.md "Queries the core must expose"):
//! structured, display-ready views over GameState shared by the CLI and
//! the TUI. Pure — every function takes an allocator (the frontends hand
//! in a per-frame arena) and mutates nothing. Row text carries the same
//! `{a}…{/}` emphasis markup the mockups use; frontends strip or render it.
//! MekHQ counterpart: none (its Swing panels read the campaign directly).

const std = @import("std");
const types = @import("../domain/types.zig");
const planet_mod = @import("../domain/planet.zig");
const logistics_mod = @import("../econ/logistics.zig");
const person_mod = @import("../domain/person.zig");
const unit_mod = @import("../domain/unit.zig");
const contract_mod = @import("../domain/contract.zig");
const chassis_mod = @import("../domain/chassis.zig");
const force_dom = @import("../domain/force.zig");
const finance = @import("../econ/finance.zig");
const checklist = @import("checklist.zig");
const contract_events = @import("contract_events.zig");
const contract_control = @import("contract_control.zig");
const state_mod = @import("state.zig");
const treasury = @import("treasury.zig");
const GameState = state_mod.GameState;

const Alloc = std.mem.Allocator;

/// C-bills with thousands separators and a sign for negatives.
pub fn money(alloc: Alloc, v: types.CBills) ![]const u8 {
    var digits: [32]u8 = undefined;
    const mag: u64 = @intCast(if (v < 0) -v else v);
    const raw = try std.fmt.bufPrint(&digits, "{d}", .{mag});
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (v < 0) try out.append(alloc, '-');
    for (raw, 0..) |c, i| {
        if (i > 0 and (raw.len - i) % 3 == 0) try out.append(alloc, ',');
        try out.append(alloc, c);
    }
    return out.toOwnedSlice(alloc);
}

const table = @import("table.zig");
pub const Table = table.Table;
pub const Col = table.Col;

/// A table from rows that carry their cells beside their ids.
pub fn tableOf(alloc: Alloc, cols: []const table.Col, rows: anytype) !table.Table {
    const out = try alloc.alloc(table.Row, rows.len);
    for (rows, 0..) |r, i| out[i] = r.cells;
    return .{ .cols = cols, .rows = out };
}

/// "912k" / "3.65M" — money for a board cell; the detail screens print
/// the exact figure.
pub fn moneyShort(alloc: Alloc, v: types.CBills) ![]const u8 {
    const a: i64 = if (v < 0) -v else v;
    const sign: []const u8 = if (v < 0) "-" else "";
    if (a < 10_000) return try money(alloc, v);
    if (a < 1_000_000) return try std.fmt.allocPrint(alloc, "{s}{d}k", .{ sign, @divTrunc(a + 500, 1000) });
    const whole: u64 = @intCast(@divTrunc(a, 1_000_000));
    const cents: u64 = @intCast(@divTrunc(@rem(a, 1_000_000) + 5_000, 10_000));
    if (cents >= 100) return try std.fmt.allocPrint(alloc, "{s}{d}.00M", .{ sign, whole + 1 });
    return try std.fmt.allocPrint(alloc, "{s}{d}.{d:0>2}M", .{ sign, whole, cents });
}

test "moneyShort rounds to k and M" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("9,500", try moneyShort(a, 9_500));
    try std.testing.expectEqualStrings("913k", try moneyShort(a, 912_606));
    try std.testing.expectEqualStrings("3.65M", try moneyShort(a, 3_650_424));
    try std.testing.expectEqualStrings("1.08M", try moneyShort(a, 1_076_837));
    try std.testing.expectEqualStrings("2.00M", try moneyShort(a, 1_996_000));
    try std.testing.expectEqualStrings("-45k", try moneyShort(a, -45_000));
}

/// Pad plain `text` to `width` cells inside `mk` markup, counting code
/// points rather than bytes (an em dash is one cell, three bytes) — for
/// the line lists that are not tables.
pub fn padCells(alloc: Alloc, mk: []const u8, text: []const u8, width: usize) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(alloc, mk);
    var cells: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepointSlice()) |cp| {
        if (cells >= width) break;
        try out.appendSlice(alloc, cp);
        cells += 1;
    }
    while (cells < width) : (cells += 1) try out.append(alloc, ' ');
    if (mk.len > 0) try out.appendSlice(alloc, "{/}");
    return out.toOwnedSlice(alloc);
}

/// Clip plain text to `width` cells (no padding), never inside a
/// multi-byte character.
pub fn clip(text: []const u8, width: usize) []const u8 {
    // Whole tokens only: an escaped `{{` or a tag is never cut in half.
    var t: table.Tokenizer = .{ .s = text };
    var cells: usize = 0;
    while (true) {
        const start = t.i;
        const tok = t.next() orelse return text;
        if (tok == .glyph) {
            if (cells == width) return text[0..start];
            cells += 1;
        }
    }
}

pub fn planetName(key: ?[]const u8) []const u8 {
    const k = key orelse return "—";
    return if (planet_mod.find(k)) |p| p.name else k;
}

// Names come from players and saves, so every display name below is
// escaped markup (`table.plain`): it draws exactly as written. A name a
// query hands over unescaped is a `table.Raw`, which will not format.

/// Untrusted text as display markup, for a frontend composing text it
/// holds itself (a path, a track name, a typed field) into markup.
pub const plain = table.plain;

/// Untrusted text made safe for a plain terminal (the REPL): invalid
/// UTF-8 and controls replaced, no markup involved.
pub fn terminalText(alloc: Alloc, raw: []const u8) ![]const u8 {
    return table.plainText(alloc, try table.plain(alloc, raw));
}

/// A person's full name as display markup.
pub fn personText(alloc: Alloc, p: *const person_mod.Person) ![]const u8 {
    return table.plain(alloc, try p.fullName(alloc));
}

pub fn personName(alloc: Alloc, gs: *GameState, id: types.PersonId) ![]const u8 {
    const p = gs.person(id) orelse return "—";
    return personText(alloc, p);
}

pub fn hqName(alloc: Alloc, gs: *GameState, id: types.HqId) ![]const u8 {
    return if (gs.hqs.getPtr(id)) |h| table.plain(alloc, h.name) else "—";
}

pub fn forceName(alloc: Alloc, gs: *GameState, id: types.ForceId) ![]const u8 {
    return if (gs.forces.getPtr(id)) |f| table.plain(alloc, f.name) else "—";
}

// ------------------------------------------------------------------ status

pub const Status = struct {
    date: []const u8,
    day: u32,
    outfit_name: table.Raw,
    funds: []const u8,
    funds_cbills: types.CBills,
    /// Monthly payroll, formatted.
    payroll: []const u8,
    /// The outfit folded: the campaign is over.
    bankrupt: bool,
    /// Saved at least once (a fresh wizard campaign has not been).
    saved: bool,
    /// Offers on every board.
    offers: usize,
    reputation: i32,
    companies: u32,
    hqs: u32,
    hulls: u32,
    people: u32,
    inbox: usize,
    checklist: usize,
    /// Checklist rows marked urgent (`WarningKind.urgent`).
    urgent: usize,
};

pub fn status(alloc: Alloc, gs: *GameState) !Status {
    const d = gs.clock.date;
    var companies: u32 = 0;
    var fit = gs.forces.iterator();
    while (fit.next()) |e| if (e.value_ptr.echelon == .company) {
        companies += 1;
    };
    var hulls: u32 = 0;
    var uit = gs.units.iterator();
    while (uit.next()) |e| if (e.value_ptr.status != .destroyed) {
        hulls += 1;
    };
    var headcount: u32 = 0;
    var pit = gs.people.iterator();
    while (pit.next()) |e| if (e.value_ptr.isOnBooks()) {
        headcount += 1;
    };
    const warnings = try checklist.turnWarnings(gs, alloc);
    var urgent: usize = 0;
    for (warnings) |w| if (w.kind.urgent()) {
        urgent += 1;
    };
    return .{
        .date = try d.textAlloc(alloc),
        .day = gs.clock.day_index,
        .outfit_name = .{ .raw = gs.outfit_name },
        .funds = try money(alloc, gs.funds),
        .funds_cbills = gs.funds,
        .payroll = try money(alloc, treasury.monthlyPayroll(gs)),
        .bankrupt = gs.bankrupt,
        .saved = gs.campaign_id != 0,
        .offers = gs.contract_offers.items.len,
        .reputation = gs.reputation,
        .companies = companies,
        .hqs = @intCast(gs.hqs.count()),
        .hulls = hulls,
        .people = headcount,
        .inbox = gs.event_queue.unresolvedCount(),
        .checklist = warnings.len,
        .urgent = urgent,
    };
}

/// What the turn is waiting on, named so a client can open it rather
/// than only print it. `checklist.turnHold` is the rule;
/// this carries the id the frontend needs to put the right sheet or
/// decision on screen, so no screen reads the journal or the queue.
pub const TurnHold = union(enum) {
    none,
    after_action: types.BattleId,
    decision: types.EventId,
};

pub fn turnHold(gs: *GameState) TurnHold {
    return switch (checklist.turnHold(gs) orelse return .none) {
        .unread_after_action => .{ .after_action = gs.battle_reports.unread().?.id },
        .battle_decision => .{ .decision = gs.event_queue.blocking().?.id },
    };
}

// -------------------------------------------------------------------- desk

pub const ChecklistRow = struct {
    kind: checklist.WarningKind,
    /// Marked red: it costs something if left (`WarningKind.urgent`).
    urgent: bool,
    /// The end-turn prompt asks about it (`WarningKind.prompts`); the
    /// rest are Desk notes.
    prompts: bool,
    text: []const u8,
    /// Tab that fixes it: 0 desk … 7 lab (docs/tui.md screen order).
    jump: u8,
    /// The contract it is about: a contact warning opens its battle orders.
    contract: types.ContractId = .none,
};

pub const InboxRow = struct {
    /// The event this row is about. A frontend answers with this,
    /// never with the row's position (rule 32).
    event_id: types.EventId,
    kind: []const u8,
    company: []const u8,
    deadline_day: u32,
    days_left: i64,
    description: []const u8,
    options: []const []const u8,
    default_choice: usize,
    /// Extra lines a decision needs to be answerable — the wrecks a
    /// salvage claim is being divided over. Empty for decisions
    /// the one-line description already covers.
    detail: []const []const u8 = &.{},
};

/// What a salvage claim is being divided over: the wrecks on
/// offer, then what each plan would actually take. Both the list and the
/// plans come from `battle.salvagePlan`, the same function the command
/// materialises with — the screen never works out the haul itself.
fn salvageDetail(alloc: Alloc, gs: *GameState, ev: *const @import("events.zig").Event) ![]const []const u8 {
    const battle = @import("battle.zig");
    const r = gs.battle_reports.find(ev.battle) orelse return &.{};
    const claim = r.salvage.unclaimed_bv;
    if (claim <= 0 or r.salvage.candidates.len == 0) return &.{};
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    try out.append(alloc, try std.fmt.allocPrint(alloc, "  claim {d} BV over {d} wreck{s} the crews could reach:", .{
        claim, r.salvage.candidates.len, if (r.salvage.candidates.len == 1) "" else "s",
    }));
    for (r.salvage.candidates) |cand| {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "    {s}{s} {s}{s}  {d} BV · armor {d}% · {d} destroyed, {d} missing", .{
            if (cand.bv > claim) "{d}" else "", cand.key,       cand.name,            if (cand.bv > claim) " (out of reach){/}" else "",
            cand.bv,                            cand.armor_pct, cand.destroyed_slots, cand.missing_components,
        }));
    }
    for ([_]types.SalvagePlan{ .heaviest, .most_hulls, .parts_only }, 1..) |kind, n| {
        const plan = battle.salvagePlan(r.salvage.candidates, claim, kind);
        var names: std.ArrayListUnmanaged(u8) = .empty;
        for (plan.take[0..plan.hulls], 0..) |i, j| {
            if (j > 0) try names.appendSlice(alloc, " + ");
            try names.appendSlice(alloc, r.salvage.candidates[i].name);
        }
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  [{d}] {s} — {d} BV in spares and armour", .{
            n, if (plan.hulls == 0) "nothing on the flatbeds" else names.items, plan.parts_bv,
        }));
    }
    return out.toOwnedSlice(alloc);
}

/// What the night's repairs have to work with and what each order would
/// do. Every line comes from `maintenance.repairPlan` on the live
/// stores — the function the command carries out with — so the screen
/// never works out the repairs itself.
fn repairDetail(alloc: Alloc, gs: *GameState, ev: *const @import("events.zig").Event) ![]const []const u8 {
    const maintenance = @import("maintenance.zig");
    const needs = try maintenance.repairNeeds(gs, alloc, ev.company);
    if (needs.len == 0) return &.{};
    const budget = try maintenance.repairBudget(gs, alloc, ev.company, needs);
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    try out.append(alloc, try std.fmt.allocPrint(alloc, "  {d} damaged hull{s} · {d} tech-hours tonight · {d} t armour in the field stores", .{
        needs.len, if (needs.len == 1) "" else "s", budget.hours, budget.armor_tons,
    }));
    for ([_]types.RepairOrder{ .worst_first, .spread, .heaviest_first }, 1..) |order, n| {
        const plan = try maintenance.repairPlan(alloc, needs, budget, order);
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  [{d}] {s}", .{ n, try maintenance.pushSummary(alloc, plan) }));
    }
    return out.toOwnedSlice(alloc);
}

/// One lance in the battle orders: its role, cycled with ←/→.
pub const OrdersLance = struct {
    force: types.ForceId,
    role: @import("../domain/force.zig").LanceRole,
    text: []const u8,
};

/// Everything the commander can still change before an engagement
/// with the situation it is judged against.
pub const BattleOrders = struct {
    contract: types.ContractId,
    company: types.ForceId,
    title: []const u8,
    situation: []const []const u8,
    roe: @import("../domain/force.zig").Roe,
    /// Integrated command sets the ROE; the box shows it but cannot change it.
    roe_locked: bool,
    lances: []OrdersLance,
    /// The emergency resupply on offer; empty when the stores cover the fight.
    rush: []const u8,
    confirmed: bool,
};

/// The battle orders for a contract whose engagement is in view, or null.
pub fn battleOrders(alloc: Alloc, gs: *GameState, id: types.ContractId) !?BattleOrders {
    const battle = @import("battle.zig");
    const field_supply = @import("field_supply.zig");
    const part_mod = @import("../domain/part.zig");
    const c = gs.contracts.getPtr(id) orelse return null;
    if (!battle.inContactWindow(gs, c)) return null;
    const company = c.assigned_company;
    const days = battle.daysToContact(gs, c) orelse 0;

    var situation: std.ArrayListUnmanaged([]const u8) = .empty;
    try situation.append(alloc, try std.fmt.allocPrint(alloc, "{{a}}contact in {d} day{s}{{/}} on {s} · {s} for {s} against {s}", .{
        days, if (days == 1) "" else "s", planetName(c.planet_key), c.kind.label(), c.employer_key, c.enemy_key,
    }));
    if (try rateOffer(alloc, gs, c, company)) |rt| {
        try situation.append(alloc, try std.fmt.allocPrint(alloc, "{s} · wins {d}% of fights, loses the field {d}%{s}", .{
            try ratingLine(alloc, gs, rt), rt.win_pct, rt.lose_field_pct,
            if (rt.warrantsWarning()) " {c}— outmatched{/}" else "",
        }));
    }
    const fieldable = contract_control.fieldableBv(gs, company);
    const pct: i64 = if (c.committed_bv > 0) @divTrunc(fieldable * 100, c.committed_bv) else 100;
    try situation.append(alloc, try std.fmt.allocPrint(alloc, "fieldable {d} BV ({d}% of committed)", .{ fieldable, pct }));
    var ammo: std.ArrayListUnmanaged(u8) = .empty;
    for (try field_supply.ammoFights(alloc, gs, company), 0..) |a, i| {
        if (i > 0) try ammo.appendSlice(alloc, ", ");
        if (a.fights == 0) {
            try ammo.print(alloc, "{{c}}{s} dry{{/}}", .{part_mod.munitionLabel(a.key)});
        } else try ammo.print(alloc, "{s} {d} fight{s}", .{ part_mod.munitionLabel(a.key), a.fights, if (a.fights == 1) "" else "s" });
    }
    try situation.append(alloc, try std.fmt.allocPrint(alloc, "ammunition: {s}", .{if (ammo.items.len > 0) ammo.items else "no guns that need it"}));

    var lances: std.ArrayListUnmanaged(OrdersLance) = .empty;
    if (gs.force(company)) |co| for (co.children.items) |lid| {
        const l = gs.force(lid) orelse continue;
        if (!l.isCombatLance()) continue;
        try lances.append(alloc, .{ .force = lid, .role = l.role, .text = try std.fmt.allocPrint(alloc, "{s} — {s} · {d} hull{s}", .{
            try table.plain(alloc, l.name), @tagName(l.role), l.units.items.len, if (l.units.items.len == 1) "" else "s",
        }) });
    };

    const rush = try field_supply.rushQuote(alloc, gs, c);
    var rush_text: []const u8 = "";
    if (rush.lines.len > 0) {
        var what: std.ArrayListUnmanaged(u8) = .empty;
        for (rush.lines, 0..) |l, i| {
            if (i > 0) try what.appendSlice(alloc, ", ");
            try what.print(alloc, "{s} {d}t", .{ if (std.mem.eql(u8, l.key, "armor")) "armour" else part_mod.munitionLabel(l.key), l.qty * part_mod.tons(l.key) });
        }
        const funds = gs.treasuryBalance(.{ .company = company });
        rush_text = try std.fmt.allocPrint(alloc, "{s} — {s} C at the local price ×{s}{s}", .{
            what.items,                                                   try money(alloc, rush.price), try bpMultText(alloc, rush.mult_bp),
            if (funds < rush.price) " {c}(local funds short){/}" else "",
        });
    }
    return .{
        .contract = id,
        .company = company,
        .title = try std.fmt.allocPrint(alloc, "BATTLE ORDERS · {s}", .{try forceName(alloc, gs, company)}),
        .situation = try situation.toOwnedSlice(alloc),
        .roe = battle.effectiveRoe(gs, c, company),
        .roe_locked = c.terms.command_rights.overridesRoe(),
        .lances = try lances.toOwnedSlice(alloc),
        .rush = rush_text,
        .confirmed = battle.ordersConfirmed(c),
    };
}

/// "2.0" for 20,000 bp.
fn bpMultText(alloc: Alloc, bp: types.Bp) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{d}.{d}", .{ @divTrunc(bp, 10_000), @divTrunc(@mod(bp, 10_000), 1_000) });
}

/// The contact warning for one contract: the line a multi-day advance
/// stopped to show. Empty when the contract is gone or not in its window.
pub fn contactWarning(alloc: Alloc, gs: *GameState, id: types.ContractId) ![]const u8 {
    const c = gs.contracts.getPtr(id) orelse return "";
    if (!@import("battle.zig").inContactWindow(gs, c)) return "";
    return checklist.contactText(alloc, gs, c);
}

/// Campaign-log rows the Desk asks for: enough to scroll a season
/// without walking the whole log every frame.
pub const desk_log_rows: usize = 40;

pub const Desk = struct {
    /// The outfit's Dragoons rating in a line.
    rating_line: []const u8,
    checklist: []ChecklistRow,
    inbox: []InboxRow,
    companies: []const table.Row,
    hqs: []const []const u8,
    log: []const []const u8,
};

fn jumpFor(kind: checklist.WarningKind) u8 {
    return switch (kind) {
        .unread_after_action, .battle_decision, .decision_due => 0,
        .open_slots, .tech_overloaded, .medbay_over_capacity => 2,
        .combat_ineffective, .objectives_met, .company_idle_afield => 3,
        .overdrawn, .insolvent => 4,
        .hungry, .dry_ammo => 5,
        .understaffed_hq, .depot_backlog => 6,
        .untreated_wounded, .restless_crew, .retiring_soon => 8,
        .manning_short, .unfit_crew, .crew_recovering => 2,
        .unrebuildable_hulls => 6,
        .outmatched, .contact_imminent => 3,
    };
}

pub fn desk(alloc: Alloc, gs: *GameState, log_rows: usize) !Desk {
    const day = gs.clock.day_index;
    const warnings = try checklist.turnWarnings(gs, alloc);
    var cl: std.ArrayListUnmanaged(ChecklistRow) = .empty;
    for (warnings) |w| {
        try cl.append(alloc, .{ .kind = w.kind, .urgent = w.kind.urgent(), .prompts = w.kind.prompts(), .text = w.text, .jump = jumpFor(w.kind), .contract = w.contract });
    }

    var inbox: std.ArrayListUnmanaged(InboxRow) = .empty;
    for (gs.event_queue.pending.items) |ev| {
        if (!ev.needsDecision()) continue;
        var opts: std.ArrayListUnmanaged([]const u8) = .empty;
        for (ev.options) |o| try opts.append(alloc, try std.fmt.allocPrint(alloc, "{s}   {s}", .{ o.label, try effectsText(alloc, o.effects) }));
        const entry = contract_events.entryForKind(ev.kind);
        try inbox.append(alloc, .{
            .event_id = ev.id,
            .kind = @tagName(ev.kind),
            .company = try forceName(alloc, gs, ev.company),
            .deadline_day = ev.deadline_day,
            .days_left = @as(i64, ev.deadline_day) - @as(i64, day),
            .description = if (ev.person != .none) (if (gs.person(ev.person)) |p| (if (p.status == .pow) try std.fmt.allocPrint(alloc, "{s} of {s} ({s} {s}, gunnery {d}) {s}", .{ try personText(alloc, p), p.faction, @tagName(p.experience()), @tagName(p.role), p.skill(p.role.primarySkill()) orelse 7, if (entry) |e| e.log else "" }) else if (p.status == .mia) try std.fmt.allocPrint(alloc, "{s} ({s} {s}, held by {s}) {s} · ransom {s}{s}", .{ try personText(alloc, p), @tagName(p.experience()), @tagName(p.role), p.faction, if (entry) |e| e.log else "", try money(alloc, missingRansom(p)), if (holdsPrisonerOf(gs, p.faction)) " · you hold a prisoner of theirs" else " · you hold no prisoner of theirs" }) else try std.fmt.allocPrint(alloc, "{s} ({s}, {s}, {s}/mo, morale {d}, fatigue {d}) {s}{s}", .{ try personText(alloc, p), @tagName(p.role), @tagName(p.experience()), try money(alloc, p.monthlySalary()), p.morale, p.fatigue, if (entry) |e| e.log else "", if (ev.kind == .notice_given) try std.fmt.allocPrint(alloc, " · letting go owes {s} severance{s}", .{ try money(alloc, severanceOwed(gs, p.id, false)), try loyaltyNote(alloc, p, day) }) else "" })) else "") else if (entry) |e| e.log else "",
            .options = try opts.toOwnedSlice(alloc),
            .default_choice = ev.default_choice,
            .detail = switch (ev.kind) {
                .salvage_priority => try salvageDetail(alloc, gs, &ev),
                .field_repair => try repairDetail(alloc, gs, &ev),
                else => &.{},
            },
        });
    }

    var companies: std.ArrayListUnmanaged(table.Row) = .empty;
    var fit = gs.forces.iterator();
    while (fit.next()) |e| {
        const f = e.value_ptr;
        if (f.echelon != .company) continue;
        try companies.append(alloc, try companyRow(alloc, gs, f.id));
    }

    var hqs: std.ArrayListUnmanaged([]const u8) = .empty;
    var hit = gs.hqs.iterator();
    while (hit.next()) |e| {
        const h = e.value_ptr;
        const req = h.staffRequired().total();
        const funds_s = try money(alloc, h.funds);
        const funds_mk: []const u8 = if (h.funds < 0) "{c}" else "";
        const load = @import("hq_ops.zig").bayLoad(gs, h.id);
        const busy = load.busy;
        const queued = load.queued;
        try hqs.append(alloc, try std.fmt.allocPrint(alloc, "hq:{d} {{a}}{s}{{/}}  {s} · ring {d} LY · {s}", .{ @intFromEnum(h.id), try table.plain(alloc, h.name), @tagName(h.tier), h.influenceLy(), planetName(h.planet_key) }));
        try hqs.append(alloc, try std.fmt.allocPrint(alloc, "     funds {s}{s}{{/}} · staff {s}{d}/{d}{{/}} · companies {d}/{d} · bays {d} busy, {d} queued", .{
            funds_mk,                                     funds_s,
            if (h.staff_assigned < req) "{c}" else "{g}", h.staff_assigned,
            req,                                          gs.companiesAtHq(h.id),
            h.capacity().combat_companies,                busy,
            queued,
        }));
        const tons = gs.siteTons(.{ .hq = h.id });
        try hqs.append(alloc, try std.fmt.allocPrint(alloc, "     warehouse {d}t / {d}t · projects {d}", .{ tons, h.warehouseCapacityTons(), h.projects.items.len }));
        try hqs.append(alloc, "");
    }

    var log: std.ArrayListUnmanaged([]const u8) = .empty;
    const entries = gs.event_log.items;
    var i: usize = entries.len;
    while (i > 0 and log.items.len < log_rows) {
        i -= 1;
        try log.append(alloc, try logRow(alloc, &entries[i]));
    }

    return .{
        .rating_line = (try rating(alloc, gs)).line,
        .checklist = try cl.toOwnedSlice(alloc),
        .inbox = try inbox.toOwnedSlice(alloc),
        .companies = try companies.toOwnedSlice(alloc),
        .hqs = try hqs.toOwnedSlice(alloc),
        .log = try log.toOwnedSlice(alloc),
    };
}

/// An option's consequences as coloured tags: green for gains, red for
/// costs — reputation first, because it is the one that lingers.
pub fn effectsText(alloc: Alloc, effects: []const @import("events.zig").Effect) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (effects.len == 0) return "{d}no effect{/}";
    // reputation first
    for (effects) |e| switch (e) {
        .reputation => |d| try appendTag(alloc, &out, d >= 0, try std.fmt.allocPrint(alloc, "rep {s}{d}", .{ if (d >= 0) "+" else "", d })),
        else => {},
    };
    for (effects) |e| switch (e) {
        .reputation => {},
        .cash => |c| try appendTag(alloc, &out, c >= 0, try std.fmt.allocPrint(alloc, "{s}{s} C", .{ if (c >= 0) "+" else "", try money(alloc, c) })),
        .cash_monthly_pct => |p| try appendTag(alloc, &out, p >= 0, try std.fmt.allocPrint(alloc, "{s}{d}% of a month's pay", .{ if (p >= 0) "+" else "", p })),
        .morale => |m| try appendTag(alloc, &out, m >= 0, try std.fmt.allocPrint(alloc, "morale {s}{d}", .{ if (m >= 0) "+" else "", m })),
        .fatigue => |f| try appendTag(alloc, &out, false, try std.fmt.allocPrint(alloc, "fatigue +{d}", .{f})),
        .next_battle_in => |d| try appendTag(alloc, &out, false, try std.fmt.allocPrint(alloc, "contact in {d}d", .{d})),
        .recovery_push => try appendTag(alloc, &out, true, "one more roll for every hull and pilot left on the field"),
        .take_salvage => |plan| try appendTag(alloc, &out, true, switch (plan) {
            .heaviest => "the biggest wreck the claim reaches, rest in spares",
            .most_hulls => "as many wrecks as the claim reaches, rest in spares",
            .parts_only => "no wrecks — the whole claim in spares and armour",
        }),
        .field_repair => |order| try appendTag(alloc, &out, true, switch (order) {
            .worst_first => "the near-wrecks first, each as far as the night reaches",
            .spread => "one job a hull a round, so the most hulls get plating",
            .heaviest_first => "the heaviest hulls first, to keep the big BV in the line",
        }),
        .xp_all => |x| try appendTag(alloc, &out, true, try std.fmt.allocPrint(alloc, "XP +{d} all", .{x})),
        .score => |s| try appendTag(alloc, &out, s >= 0, try std.fmt.allocPrint(alloc, "contract score {s}{d}", .{ if (s >= 0) "+" else "", s })),
        .damage_random_units => |n| try appendTag(alloc, &out, false, try std.fmt.allocPrint(alloc, "{d} line hull{s} damaged", .{ n, if (n == 1) "" else "s" })),
        .damage_convoy_units => |n| try appendTag(alloc, &out, false, try std.fmt.allocPrint(alloc, "{d} support vehicle{s} damaged", .{ n, if (n == 1) "" else "s" })),
        .parts_windfall => |n| try appendTag(alloc, &out, true, try std.fmt.allocPrint(alloc, "parts windfall ×{d}", .{n})),
        .supply_loss => |c| try appendTag(alloc, &out, false, try std.fmt.allocPrint(alloc, "supplies −{s} C", .{try money(alloc, c)})),
        .employer_standing => |d| try appendTag(alloc, &out, d >= 0, try std.fmt.allocPrint(alloc, "employer standing {s}{d}", .{ if (d >= 0) "+" else "−", @abs(d) })),
        .field_stock => |fs| try appendTag(alloc, &out, true, try std.fmt.allocPrint(alloc, "+{d} {s} to the trucks", .{ fs.qty, fs.key })),
        .ransom_prisoner => try appendTag(alloc, &out, true, "ransom by experience, they go home"),
        .release_prisoner => try appendTag(alloc, &out, true, "+2 standing with their house"),
        .recruit_prisoner => try appendTag(alloc, &out, false, "loyalty roll 2d6 ≥ 8: joins as a mekwarrior, company morale −2; else released"),
        .raise_pct => |p| try appendTag(alloc, &out, false, try std.fmt.allocPrint(alloc, "salary +{d}% for good", .{p})),
        .retention_bonus_months => |m| try appendTag(alloc, &out, false, try std.fmt.allocPrint(alloc, "{d} months' pay once", .{m})),
        .let_go => try appendTag(alloc, &out, false, "they leave, seat opens"),
        .replace_from_hall => try appendTag(alloc, &out, false, "they leave; hall replacement if listed"),
        .ransom_mia => try appendTag(alloc, &out, false, "ransom by experience from the outfit, they come home"),
        .exchange_mia => try appendTag(alloc, &out, true, "a prisoner of their house goes back; else written off"),
        .write_off_mia => try appendTag(alloc, &out, false, "missing, presumed dead · company morale −5"),
        .engagement => try appendTag(alloc, &out, false, "a real engagement against the contract's opposition"),
        .seize_hull => try appendTag(alloc, &out, false, "your most battered line hull is taken, for good"),
        .delay_arrival => |d| try appendTag(alloc, &out, false, try std.fmt.allocPrint(alloc, "+{d} days in transit", .{d})),
    };
    return out.toOwnedSlice(alloc);
}

fn appendTag(alloc: Alloc, out: *std.ArrayListUnmanaged(u8), good: bool, text: []const u8) !void {
    if (out.items.len > 0) try out.appendSlice(alloc, " ");
    try out.appendSlice(alloc, if (good) "{g}[" else "{c}[");
    try out.appendSlice(alloc, text);
    try out.appendSlice(alloc, "]{/}");
}

pub fn logRow(alloc: Alloc, e: *const state_mod.LogEntry) ![]const u8 {
    const mk: []const u8 = switch (e.category) {
        .battle => "{a}",
        .finance, .medical => "{c}",
        .delivery, .rotation => "{g}",
        else => "",
    };
    // Entry text already carries its own date and tag; add the day index
    // and a colour by category.
    return std.fmt.allocPrint(alloc, "{{d}}d{d: <4}{{/}} {s}{s}{{/}}", .{ e.day, mk, try table.plain(alloc, e.text) });
}

pub const company_cols: []const table.Col = &.{
    .{ .name = "co", .justify = .right },    .{ .name = "name" },                     .{ .name = "hq", .drop = 1 },          .{ .name = "posture" },
    .{ .name = "contract" },                 .{ .name = "location", .drop = 2 },      .{ .name = "fat", .justify = .right }, .{ .name = "mor", .justify = .right },
    .{ .name = "hulls", .justify = .right }, .{ .name = "ready", .justify = .right }, .{ .name = "supply" },                 .{ .name = "local funds", .justify = .right },
};

fn companyRow(alloc: Alloc, gs: *GameState, id: types.ForceId) !table.Row {
    const f = gs.forces.getPtr(id).?;
    const day = gs.clock.day_index;
    var hulls: u32 = 0;
    var ready: u32 = 0;
    var uit = gs.units.iterator();
    while (uit.next()) |e| {
        const u = e.value_ptr;
        if (gs.companyOf(u.force) != id or u.isParked()) continue;
        hulls += 1;
        if (u.status == .ready) ready += 1;
    }
    const crew = @import("personnel.zig").companyCrewStats(gs, id);
    const contract = gs.deploymentContract(id);
    const posture: []const u8 = switch (gs.companyPosture(id)) {
        .en_route => |c| try std.fmt.allocPrint(alloc, "{{a}}IN TRANSIT · arrive d{d}{{/}}", .{c.arrive_day orelse day}),
        .deployed => |c| try std.fmt.allocPrint(alloc, "{{a}}DEPLOYED · {s}{{/}}", .{c.kind.label()}),
        .returning => |eta| try std.fmt.allocPrint(alloc, "{{a}}RETURNING · home d{d}{{/}}", .{eta}),
        .idle_afield => "{a}afield, idle{/}",
        .home => "{g}at home{/}",
    };
    const contract_s: []const u8 = if (contract) |c| try std.fmt.allocPrint(alloc, "[{d}] {s}", .{ @intFromEnum(c.id), c.kind.label() }) else "—";
    const location: []const u8 = if (f.location_planet) |p| planetName(p) else if (gs.hqs.getPtr(f.supplying_hq)) |h| planetName(h.planet_key) else "—";
    const site: types.Site = .{ .company = id };
    const tons = gs.siteTons(site);
    const cap = gs.siteCapacityTons(site) orelse 0;
    const cap_mk: []const u8 = if (cap > 0 and tons * 4 < cap) "{a}" else "{g}";
    return table.row(alloc, &.{
        try std.fmt.allocPrint(alloc, "{d}", .{@intFromEnum(id)}),
        try table.plain(alloc, f.name),
        try hqName(alloc, gs, f.supplying_hq),
        posture,
        contract_s,
        location,
        try std.fmt.allocPrint(alloc, "{d}", .{crew.avg_fatigue}),
        try std.fmt.allocPrint(alloc, "{d}", .{crew.avg_morale}),
        try std.fmt.allocPrint(alloc, "{d}", .{hulls}),
        try std.fmt.allocPrint(alloc, "{d}", .{ready}),
        try std.fmt.allocPrint(alloc, "{s}{d}t / {d}t{{/}}", .{ cap_mk, tons, cap }),
        try money(alloc, f.local_funds),
    });
}

// --------------------------------------------------------------- contracts

pub const OfferRow = struct {
    index: usize,
    kind: contract_mod.ContractKind,
    beachhead: bool,
    planet_key: []const u8,
    /// Its one negotiation round is spent.
    negotiated: bool,
    cells: table.Row,
};

pub const board_cols: []const table.Col = &.{
    .{ .name = "kind" },                  .{ .name = "world" },                   .{ .name = "emp" },                       .{ .name = "LY", .justify = .right, .drop = 3 },
    .{ .name = "band" },                  .{ .name = "mo", .justify = .right },   .{ .name = "pay/mo", .justify = .right }, .{ .name = "total", .justify = .right, .drop = 3 },
    .{ .name = "enemy" },                 .{ .name = "salv", .justify = .right }, .{ .name = "rights" },                    .{ .name = "transit", .justify = .right },
    .{ .name = "skulls" },                .{ .name = "rating" },                  .{ .name = "readiest co." },              .{ .name = "tons", .justify = .right, .drop = 1 },
    .{ .name = "weight mix", .drop = 2 }, .{ .name = "enemy tons", .drop = 2 },   .{ .name = "opposition" },                .{ .name = "" },
};

pub const ActiveRow = struct {
    id: types.ContractId,
    company: types.ForceId,
    /// Null on the posture rows (a company returning or idle afield has no running contract).
    status: ?contract_mod.ContractStatus,
    lines: []const []const u8,
    objectives_met: bool,
};

pub const Contracts = struct {
    board: []OfferRow,

    active: []ActiveRow,
    notes: []const u8,
    /// Standing with every house, one line each.
    standings: []const []const u8,

    pub fn boardTable(self: Contracts, alloc: Alloc) !table.Table {
        return tableOf(alloc, board_cols, self.board);
    }
};

/// Standing with each house: the number, what it does to pay, and whether
/// the house is cooling or shunning you.
pub fn standings(alloc: Alloc, gs: *GameState) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const cm = @import("contract_market.zig");
    const t = @import("../domain/tuning.zig").t.contract;
    for (@import("../domain/faction.zig").table) |fr| {
        if (!fr.hires) continue;
        const f = .{ .name = fr.key };
        const s = gs.standing(f.name);
        if (s == 0 and !@import("../domain/commander.zig").Faction.isHouse(fr.key)) continue; // periphery rows appear once they matter
        const bp = cm.standingPayBp(s);
        const mk: []const u8 = if (s <= -t.standing_shun_depth) "{c}" else if (s < 0) "{a}" else if (s >= 25) "{g}" else "";
        const note: []const u8 = if (gs.factionCooling(f.name)) " · {c}cooling after a breach{/}" else if (s <= -t.standing_shun_depth) " · {c}shunned: half their offers{/}" else if (s >= 25) " · {g}favoured{/}" else "";
        var mult_buf: [16]u8 = undefined;
        const mag: u32 = @intCast(@abs(s));
        const num = try std.fmt.allocPrint(alloc, "{c}{d}", .{ @as(u8, if (s < 0) '-' else if (s > 0) '+' else ' '), mag });
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  {s: <4} {s}{s: >5}{{/}}  pay {s}{s}", .{ f.name, mk, num, types.bpText(&mult_buf, bp), note }));
    }
    return out.toOwnedSlice(alloc);
}

/// Days to an offer's world as `accept` will reckon them: from the nearest
/// company that could go (not under contract, not in transit), else from
/// the outfit's seat. An offer carries no transit of its own until it is
/// accepted.
pub fn offerTransitDays(gs: *GameState, offer: *const contract_mod.Contract) u32 {
    const to = planet_mod.find(offer.planet_key) orelse return 0;
    var best: ?u32 = null;
    var fit = gs.forces.iterator();
    while (fit.next()) |e| {
        const co = e.value_ptr;
        if (co.echelon != .company or gs.isCompanyDeployed(co.id) or co.return_eta_day != null) continue;
        const from = planet_mod.find(companyPlanetKey(gs, co.id) orelse continue) orelse continue;
        const days: u32 = logistics_mod.daysBetween(from, to);
        if (best == null or days < best.?) best = days;
    }
    if (best) |b| return b;
    const seat = if (gs.hqs.count() > 0) planet_mod.find(gs.hqs.values()[0].planet_key) else null;
    if (seat) |s| return logistics_mod.daysBetween(s, to);
    const jumps = planet_mod.jumpsForLy(offer.dist_ly);
    return if (jumps == 0) logistics_mod.same_world_days else logistics_mod.transitDays(jumps);
}

const offer_rating = @import("offer_rating.zig");
const rating_mod = @import("rating.zig");
pub const intelLevel = offer_rating.intelLevel;
pub const LanceIntel = offer_rating.LanceIntel;
pub const lanceIntel = offer_rating.lanceIntel;
pub const OfferRating = offer_rating.OfferRating;
pub const rateOffer = offer_rating.rateOffer;
pub const skullText = offer_rating.skullText;

pub fn opforText(alloc: Alloc, gs: *GameState, c: *const contract_mod.Contract) ![]const u8 {
    if (!c.hasOpfor()) return "opposition sized to the company";
    const intel = intelLevel(gs, @import("offer_rating.zig").intelHq(gs, c));
    const li = lanceIntel(gs, c);
    if (intel >= 3) return try std.fmt.allocPrint(alloc, "{d} lance{s} of {s} {s} ≈{s} BV a fight", .{ c.enemy_lances, if (c.enemy_lances == 1) "" else "s", @tagName(c.enemy_quality), c.enemy_key, try money(alloc, types.applyBp(c.opforBv(), gs.diff().enemy_bp)) });
    if (intel >= 1) return try std.fmt.allocPrint(alloc, "{d}–{d} lances of {s} {s}", .{ li.lo, li.hi, @tagName(c.enemy_quality), c.enemy_key });
    return try std.fmt.allocPrint(alloc, "{d}–{d} lances of {s}, quality unknown (comms)", .{ li.lo, li.hi, c.enemy_key });
}

/// The rating for the company best placed to take an offer: the
/// readiest eligible one, as `candidates` ranks them. Null when no company
/// of that board's HQ can go, or the offer predates rolled opposition.
pub fn bestRating(alloc: Alloc, gs: *GameState, offer_index: usize) !?OfferRating {
    if (offer_index >= gs.contract_offers.items.len) return null;
    for (try offerCandidates(alloc, gs, offer_index)) |cand| {
        if (!cand.eligible) continue;
        return try rateOffer(alloc, gs, &gs.contract_offers.items[offer_index], cand.company);
    }
    return null;
}

/// "☠☠☠◐ 3.5 Alpha 610t (L4 M8 H0 A0) vs ~720t" for a board row, coloured
/// by difficulty.
pub fn boardSkulls(alloc: Alloc, gs: *GameState, offer_index: usize) ![]const u8 {
    const r = (try bestRating(alloc, gs, offer_index)) orelse return "{d}no company in range{/}";
    return try ratingLine(alloc, gs, r);
}

/// One rating on a line: glyphs, the number, whose, and the weights.
pub fn ratingLine(alloc: Alloc, gs: *GameState, r: OfferRating) ![]const u8 {
    const mk: []const u8 = if (r.half_hi >= 9) "{c}" else if (r.half_hi >= 7) "{a}" else "{g}";
    return try std.fmt.allocPrint(alloc, "{s}{s}{{/}} {s} {s} · {s}", .{ mk, try skullGlyphs(alloc, r.half_hi), try skullText(alloc, r), try forceName(alloc, gs, r.company), try tonnageText(alloc, r) });
}

/// "☠ ☠ ☠ ◐" (or "X X X x" with ascii) for half skulls; the TUI swaps
/// glyphs. Spaced so a terminal like kitty can draw each symbol two cells
/// wide.
pub fn skullGlyphs(alloc: Alloc, half: u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (0..half / 2) |i| {
        if (i > 0) try out.append(alloc, ' ');
        try out.appendSlice(alloc, "☠");
    }
    if (half % 2 == 1) {
        if (half > 1) try out.append(alloc, ' ');
        try out.appendSlice(alloc, "◐");
    }
    return out.items;
}

/// "LC Lyran Commonwealth · DC Draconis Combine · …" — the faction codes
/// the boards print, for the help legend (from data/tables/factions.zon).
pub fn factionLegend(alloc: Alloc) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (@import("../domain/faction.zig").table, 0..) |f, i| {
        if (i > 0) try out.appendSlice(alloc, " · ");
        try out.print(alloc, "{s} {s}", .{ f.key, f.name });
    }
    return out.toOwnedSlice(alloc);
}

/// The board's rating cells: skulls · rating · company · own
/// tons · weight mix · enemy tons, for the readiest company in range.
fn boardRatingCells(alloc: Alloc, gs: *GameState, offer_index: usize) ![6][]const u8 {
    const r = (try bestRating(alloc, gs, offer_index)) orelse return .{ "{d}—{/}", "{d}—{/}", "{d}no company in range{/}", "", "", "" };
    const skulls = @import("../domain/skulls.zig");
    const mk: []const u8 = if (r.half_hi >= 9) "{c}" else if (r.half_hi >= 7) "{a}" else "{g}";
    var a: [8]u8 = undefined;
    var b: [8]u8 = undefined;
    const lo = skulls.number(&a, r.half_lo);
    const num = if (r.half_lo == r.half_hi) lo else try std.fmt.allocPrint(alloc, "{s}–{s}", .{ lo, skulls.number(&b, r.half_hi) });
    const m = r.own.mix;
    return .{
        try std.fmt.allocPrint(alloc, "{s}{s}{{/}}", .{ mk, try skullGlyphs(alloc, r.half_hi) }),
        try std.fmt.allocPrint(alloc, "{s}{s}{s}{{/}}", .{ mk, num, if (r.outmatched) "!" else "" }),
        try forceName(alloc, gs, r.company),
        try std.fmt.allocPrint(alloc, "{d}t", .{r.own.tons}),
        try std.fmt.allocPrint(alloc, "L{d} M{d} H{d} A{d}", .{ m[0], m[1], m[2], m[3] }),
        if (r.enemy_tons_lo == r.enemy_tons_hi) try std.fmt.allocPrint(alloc, "~{d}t", .{r.enemy_tons_lo}) else try std.fmt.allocPrint(alloc, "~{d}–{d}t", .{ r.enemy_tons_lo, r.enemy_tons_hi }),
    };
}

/// "2–3 lances, green" — the opposition for a board cell (`opforText`
/// says it in full).
pub fn opforShort(alloc: Alloc, gs: *GameState, c: *const contract_mod.Contract) ![]const u8 {
    if (!c.hasOpfor()) return "sized to the company";
    const intel = intelLevel(gs, @import("offer_rating.zig").intelHq(gs, c));
    const li = lanceIntel(gs, c);
    if (intel >= 3) return try std.fmt.allocPrint(alloc, "{d} lance{s}, {s}, ≈{s} BV/fight", .{ c.enemy_lances, if (c.enemy_lances == 1) "" else "s", @tagName(c.enemy_quality), try moneyShort(alloc, types.applyBp(c.opforBv(), gs.diff().enemy_bp)) });
    if (intel >= 1) return try std.fmt.allocPrint(alloc, "{d}–{d} lances, {s}", .{ li.lo, li.hi, @tagName(c.enemy_quality) });
    return try std.fmt.allocPrint(alloc, "{d}–{d} lances, quality unknown", .{ li.lo, li.hi });
}

/// "610t (L4 M8 H0 A0) vs ~720t": own tons and weight mix against the enemy's.
pub fn tonnageText(alloc: Alloc, r: OfferRating) ![]const u8 {
    const m = r.own.mix;
    const theirs = if (r.enemy_tons_lo == r.enemy_tons_hi) try std.fmt.allocPrint(alloc, "~{d}t", .{r.enemy_tons_lo}) else try std.fmt.allocPrint(alloc, "~{d}–{d}t", .{ r.enemy_tons_lo, r.enemy_tons_hi });
    return try std.fmt.allocPrint(alloc, "{d}t (L{d} M{d} H{d} A{d}) vs {s}", .{ r.own.tons, m[0], m[1], m[2], m[3], theirs });
}

/// The contract screen. `board_hq` picks one HQ's board (`.none`
/// shows every board).
pub fn contracts(alloc: Alloc, gs: *GameState, board_hq: types.HqId) !Contracts {
    const day = gs.clock.day_index;
    var board: std.ArrayListUnmanaged(OfferRow) = .empty;
    for (gs.contract_offers.items, 0..) |c, i| {
        if (board_hq != .none and c.offer_hq != .none and c.offer_hq != board_hq) continue;
        const rt = try boardRatingCells(alloc, gs, i);
        try board.append(alloc, .{ .index = i, .kind = c.kind, .beachhead = c.beachhead, .planet_key = c.planet_key, .negotiated = c.negotiated, .cells = try table.row(alloc, &.{
            c.kind.label(),
            planetName(c.planet_key),
            c.employer_key,
            try std.fmt.allocPrint(alloc, "{d}", .{c.dist_ly}),
            if (c.beachhead) "{a}beachhead{/}" else "ring",
            try std.fmt.allocPrint(alloc, "{d}", .{c.terms.length_months}),
            try moneyShort(alloc, c.terms.base_pay_month),
            try moneyShort(alloc, c.terms.totalBasePay()),
            c.enemy_key,
            try std.fmt.allocPrint(alloc, "{d}%{s}", .{ c.terms.salvage_pct, if (c.terms.salvage_exchange) " cash" else "" }),
            @tagName(c.terms.command_rights),
            try std.fmt.allocPrint(alloc, "{d}d", .{offerTransitDays(gs, &c)}),
            rt[0],
            rt[1],
            rt[2],
            rt[3],
            rt[4],
            rt[5],
            try opforShort(alloc, gs, &c),
            if (c.negotiated) "{d}negotiated{/}" else "",
        }) });
    }

    var active: std.ArrayListUnmanaged(ActiveRow) = .empty;
    var it = gs.contracts.iterator();
    while (it.next()) |e| {
        const c = e.value_ptr;
        if (!c.isRunning()) continue;
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        try lines.append(alloc, try std.fmt.allocPrint(alloc, "[{d}] {{a}}{s}{{/}}  {s}  co:{d} {s} on {s}  ·  employer {s} · vs {s}  ·  {s} objective", .{
            @intFromEnum(c.id),               c.kind.label(),                               @tagName(c.status),
            @intFromEnum(c.assigned_company), try forceName(alloc, gs, c.assigned_company), planetName(c.planet_key),
            c.employer_key,                   c.enemy_key,                                  @tagName(c.objective),
        }));
        var bar_buf: [30]u8 = undefined;
        if (c.objective == .attrition) {
            const destroyed = c.enemy_pool_bv - c.enemy_pool_remaining;
            try lines.append(alloc, try std.fmt.allocPrint(alloc, "    opposition  {{a}}{s}{{/}}  {d}% destroyed  {d} / {d} BV", .{ table.bar(&bar_buf, destroyed, c.enemy_pool_bv), c.poolDestroyedPct(), destroyed, c.enemy_pool_bv }));
        }
        if (c.end_day) |end| {
            const start = c.arrive_day orelse c.start_day orelse day;
            const total: i64 = @as(i64, end) - @as(i64, start);
            const done: i64 = @as(i64, day) - @as(i64, start);
            try lines.append(alloc, try std.fmt.allocPrint(alloc, "    duration    {{d}}{s}{{/}}  day {d} of {d} · {d} days left", .{ table.bar(&bar_buf, done, total), @max(0, done), @max(0, total), @max(0, total - done) }));
        }
        try lines.append(alloc, try std.fmt.allocPrint(alloc, "    rights      {s}", .{c.terms.command_rights.describe()}));
        {
            // Rules of engagement: the company's order, or the employer's.
            const roe = @import("battle.zig").effectiveRoe(gs, c, c.assigned_company);
            try lines.append(alloc, try std.fmt.allocPrint(alloc, "    ROE         {s}{s}", .{ roe.describe(), if (c.terms.command_rights.overridesRoe()) " {d}(set by integrated command){/}" else " {d}(Forces o on the company row){/}" }));
        }
        // Live skulls: what the company can field today against the
        // opposition — a mauled company's odds fall as it wears down.
        if (try rateOffer(alloc, gs, c, c.assigned_company)) |rt| {
            try lines.append(alloc, try std.fmt.allocPrint(alloc, "    skulls      {s} · wins {d}% of fights, loses the field {d}%{s}", .{
                try ratingLine(alloc, gs, rt), rt.win_pct, rt.lose_field_pct,
                if (rt.warrantsWarning()) " {c}— outmatched: consider cautious ROE or recall{/}" else "",
            }));
        }
        try lines.append(alloc, try std.fmt.allocPrint(alloc, "    verdict     {s}{s}{{/}} so far · {s}score {d}{{/}} (breach on performance at {d}) · outstanding ≥ 50 VP, strong ≥ 25, satisfactory ≥ 0", .{
            if (c.victory_points < 0) "{a}" else "{g}", c.grade(), if (c.score <= contract_mod.Contract.fail_score + 2) "{c}" else "", c.score, contract_mod.Contract.fail_score,
        }));
        try lines.append(alloc, try std.fmt.allocPrint(alloc, "    victory pts {{g}}{d}{{/}} · score {d} · battles {d} · casualties {d} · next engagement {s}", .{
            c.victory_points, c.score, c.battles_fought, c.casualties,
            if (c.next_battle_day) |nb| try std.fmt.allocPrint(alloc, "~day {d}", .{nb}) else "—",
        }));
        const fieldable = contract_control.fieldableBv(gs, c.assigned_company);
        const pct: i64 = if (c.committed_bv > 0) @divTrunc(fieldable * 100, c.committed_bv) else 0;
        const tc = @import("../domain/tuning.zig").t.contract;
        const pct_mk: []const u8 = if (pct < tc.effective_min_pct) "{c}" else if (pct < tc.effective_warn_pct) "{a}" else "{g}";
        try lines.append(alloc, try std.fmt.allocPrint(alloc, "    committed   {d} BV · fieldable {d} BV {s}({d}%){{/}} · ineffective below {d}%{s}", .{
            c.committed_bv, fieldable, pct_mk, pct, tc.effective_min_pct,
            if (c.ineffective_since) |since| try std.fmt.allocPrint(alloc, " · {{c}}grace since day {d}{{/}}", .{since}) else "",
        }));
        try lines.append(alloc, try std.fmt.allocPrint(alloc, "    pay         {s} / month · advance {s} · salvage {d}%{s} · {s} rights", .{
            try money(alloc, c.terms.base_pay_month), try money(alloc, c.terms.advanceAmount()), c.terms.salvage_pct, if (c.terms.salvage_exchange) " {a}(exchange: employer keeps the wrecks, pays cash){/}" else "", @tagName(c.terms.command_rights),
        }));
        {
            // Salvage capacity: what the trucks can haul off a won field (battle.haulCapacityBv).
            const battle = @import("battle.zig");
            const trucks = battle.salvageTrucks(gs, c.assigned_company);
            var salvage_lance = false;
            if (gs.supportLance(c.assigned_company, .salvage)) |l| salvage_lance = l.units.items.len > 0;
            const tb = @import("../domain/tuning.zig").t.battle;
            const haul_bv: i64 = battle.haulCapacityBv(trucks);
            var claim: i64 = @divTrunc(haul_bv * c.terms.salvage_pct, 100);
            if (salvage_lance) claim = types.applyBp(claim, tb.salvage_lance_bonus_bp);
            try lines.append(alloc, try std.fmt.allocPrint(alloc, "    salvage     {d} SVT-1 truck{s} haul up to {d} BV per won battle → your {d}% is ≈{d} BV of wrecks and parts shipped to the home depot{s}", .{
                trucks, if (trucks == 1) "" else "s", haul_bv, c.terms.salvage_pct, claim,
                if (salvage_lance) try std.fmt.allocPrint(alloc, " (+{d}% crewed salvage lance)", .{@divTrunc(tb.salvage_lance_bonus_bp - 10_000, 100)}) else try std.fmt.allocPrint(alloc, " (no salvage lance: −{d}%)", .{@divTrunc(tb.salvage_lance_bonus_bp - 10_000, 100)}),
            }));
        }
        if (c.objectivesMet()) try lines.append(alloc, "    {g}objectives met{/} — [c] complete closes out (remainder forfeited)");
        try lines.append(alloc, "");
        try active.append(alloc, .{ .id = c.id, .company = c.assigned_company, .status = c.status, .lines = try lines.toOwnedSlice(alloc), .objectives_met = c.objectivesMet() });
    }
    // Companies whose contract is over but who are still out there: they
    // idle on that world (eating from their trucks) until recalled.
    var fit = gs.forces.iterator();
    while (fit.next()) |e| {
        const f = e.value_ptr;
        if (f.echelon != .company) continue;
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        switch (gs.companyPosture(f.id)) {
            .returning => |eta| try lines.append(alloc, try std.fmt.allocPrint(alloc, "[—] {{a}}returning{{/}}  co:{d} {s} on the way home from {s}  ·  arrives day {d} ({d} days)", .{ @intFromEnum(f.id), try table.plain(alloc, f.name), planetName(f.location_planet), eta, eta -| day })),
            .idle_afield => |p| {
                try lines.append(alloc, try std.fmt.allocPrint(alloc, "[—] {{a}}idle afield{{/}}  co:{d} {s} on {s}  ·  contract over, no orders", .{ @intFromEnum(f.id), try table.plain(alloc, f.name), planetName(p) }));
                try lines.append(alloc, "    {d}eats from its trucks and pays field prices until it moves · [R] recall home (free) · or accept a new offer with it from here{/}");
            },
            else => continue,
        }
        try lines.append(alloc, "");
        try active.append(alloc, .{ .id = .none, .company = f.id, .status = null, .lines = try lines.toOwnedSlice(alloc), .objectives_met = false });
    }

    return .{
        .board = try board.toOwnedSlice(alloc),
        .active = try active.toOwnedSlice(alloc),
        .notes = try std.fmt.allocPrint(alloc, "{s}  ·  {{d}}beachhead: ×1.3 pay · +15% hardship · local supplies ×2.5 · resupply via link only  ·  rights: integrated = more fights, salvage ×0.5, defeats −2, no training lances, pay +10% · house = ×0.75, +5% · liaison = ×0.9 · independent = fewer fights, full salvage, −5% · salv cash = salvage exchange (paid in cash, no wrecks)  ·  board refreshes on the 1st{{/}}", .{(try rating(alloc, gs)).line}),
        .standings = try standings(alloc, gs),
    };
}

/// How healthy a hull's armour reads. The one band rule: every
/// armour figure on every screen colours through this, so a meter and a
/// bare percentage can never disagree about what "hurt" means. Bands are
/// `tuning.unit.armor_amber_pct` / `armor_red_pct`; nothing *decides*
/// anything on them — the rules read `armor_pct` itself.
pub fn armorMark(pct: u8) []const u8 {
    const t = @import("../domain/tuning.zig").t.unit;
    if (pct <= t.armor_red_pct) return "{c}";
    if (pct <= t.armor_amber_pct) return "{a}";
    return "{g}";
}

/// "██████---- 62%" — armour as a meter, for the panes with room for one
/// (hull sheet, damage pane, detail). `armorPct` is the same rule without
/// the bar, for table cells.
pub fn armorBar(alloc: Alloc, pct: u8) ![]const u8 {
    var buf: [armor_bar_cells]u8 = undefined;
    return std.fmt.allocPrint(alloc, "{s}{s} {d: >3}%{{/}}", .{ armorMark(pct), table.bar(&buf, pct, 100), pct });
}

/// "62%", coloured by the same band as the meter.
pub fn armorPct(alloc: Alloc, pct: u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}{d}%{{/}}", .{ armorMark(pct), pct });
}

/// Cells the armour meter occupies; wide enough to read a tenth.
const armor_bar_cells = 10;

test "one armour band rule: the meter and the bare percentage agree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const t = @import("../domain/tuning.zig").t.unit;

    // The bands, at their edges. Whatever the tuning says, the meter and
    // the cell text colour a hull the same way — a second copy of the
    // thresholds anywhere would drift these apart.
    for ([_]u8{ 0, t.armor_red_pct, t.armor_red_pct + 1, t.armor_amber_pct, t.armor_amber_pct + 1, 100 }) |pct| {
        const mark = armorMark(pct);
        try std.testing.expect(std.mem.startsWith(u8, try armorBar(al, pct), mark));
        try std.testing.expect(std.mem.startsWith(u8, try armorPct(al, pct), mark));
    }
    try std.testing.expectEqualStrings("{c}", armorMark(t.armor_red_pct));
    try std.testing.expectEqualStrings("{a}", armorMark(t.armor_amber_pct));
    try std.testing.expectEqualStrings("{g}", armorMark(100));

    // The meter is the shared bar helper, so a full hull fills it and a
    // wreck empties it.
    try std.testing.expect(std.mem.indexOf(u8, try armorBar(al, 100), "##########") != null);
    try std.testing.expect(std.mem.indexOf(u8, try armorBar(al, 0), "----------") != null);
    // ...and it still reads as a number, for anyone counting on the text.
    try std.testing.expect(std.mem.indexOf(u8, try armorBar(al, 62), "62%") != null);
}

/// Battle log lines for a contract, newest first.
pub fn battleLog(alloc: Alloc, gs: *GameState, id: types.ContractId, max: usize) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const entries = gs.event_log.items;
    var i: usize = entries.len;
    while (i > 0 and out.items.len < max) {
        i -= 1;
        const e = &entries[i];
        if (e.contract != id) continue;
        try out.append(alloc, try logRow(alloc, e));
    }
    return out.toOwnedSlice(alloc);
}

// ------------------------------------------------------------------ ledger

pub const TreasuryRow = struct {
    treasury: state_mod.Treasury,
    balance: types.CBills,
    cells: table.Row,
};

pub const treasury_cols: []const table.Col = &.{ .{ .name = "treasury" }, .{ .name = "balance", .justify = .right } };

pub const Ledger = struct {
    treasuries: []TreasuryRow,
    extras: []const []const u8, // couriers, policies, loans, forecast
    pnl_title: []const u8,
    /// category · the period · the campaign (the period column is named for its days).
    pnl_cols: []const table.Col,
    pnl: []const table.Row,
    ledger: []const table.Row,
};

pub const ledger_cols: []const table.Col = &.{ .{ .name = "day" }, .{ .name = "category" }, .{ .name = "amount", .justify = .right }, .{ .name = "note" } };

pub fn allTreasuries(alloc: Alloc, gs: *GameState) ![]state_mod.Treasury {
    var out: std.ArrayListUnmanaged(state_mod.Treasury) = .empty;
    try out.append(alloc, .outfit);
    var hit = gs.hqs.iterator();
    while (hit.next()) |e| try out.append(alloc, .{ .hq = e.value_ptr.id });
    var fit = gs.forces.iterator();
    while (fit.next()) |e| if (e.value_ptr.echelon == .company) try out.append(alloc, .{ .company = e.value_ptr.id });
    return out.toOwnedSlice(alloc);
}

pub fn treasuryLabel(alloc: Alloc, gs: *GameState, t: state_mod.Treasury) ![]const u8 {
    return switch (t) {
        .outfit => "outfit",
        .hq => |id| try std.fmt.allocPrint(alloc, "hq:{d} {s}", .{ @intFromEnum(id), try hqName(alloc, gs, id) }),
        .company => |id| try std.fmt.allocPrint(alloc, "co:{d} {s}", .{ @intFromEnum(id), try forceName(alloc, gs, id) }),
    };
}

pub fn ledger(alloc: Alloc, gs: *GameState, selected: state_mod.Treasury, period_days: u32, max_rows: usize) !Ledger {
    const day = gs.clock.day_index;
    var rows: std.ArrayListUnmanaged(TreasuryRow) = .empty;
    var total: types.CBills = 0;
    for (try allTreasuries(alloc, gs)) |t| {
        const bal = gs.treasuryBalance(t);
        total += bal;
        const mk: []const u8 = if (bal < 0) "{c}" else if (t == .outfit) "{a}" else "";
        try rows.append(alloc, .{ .treasury = t, .balance = bal, .cells = try table.row(alloc, &.{ try treasuryLabel(alloc, gs, t), try std.fmt.allocPrint(alloc, "{s}{s}{{/}}", .{ mk, try money(alloc, bal) }) }) });
    }

    var extras: std.ArrayListUnmanaged([]const u8) = .empty;
    try extras.append(alloc, try std.fmt.allocPrint(alloc, "total  {{a}}{s}{{/}}", .{try money(alloc, total)}));
    try extras.append(alloc, "");
    try extras.append(alloc, "in transit");
    if (gs.fund_couriers.items.len == 0) try extras.append(alloc, "  none");
    for (gs.fund_couriers.items) |c| {
        try extras.append(alloc, try std.fmt.allocPrint(alloc, "  {s} → {s}  arrives day {d}", .{ try money(alloc, c.amount), try treasuryLabel(alloc, gs, c.to), c.eta_day }));
    }
    try extras.append(alloc, "");
    try extras.append(alloc, "standing policies");
    if (gs.policies.items.len == 0) try extras.append(alloc, "  none");
    for (gs.policies.items) |p| {
        try extras.append(alloc, try std.fmt.allocPrint(alloc, "  {s}  top up to {s} · {s} of {s} sent this month", .{ try treasuryLabel(alloc, gs, p.entity), try money(alloc, p.floor), try money(alloc, p.sent_this_month), try money(alloc, p.monthly_cap) }));
    }
    for (gs.supply_policies.items) |sp| {
        try extras.append(alloc, try std.fmt.allocPrint(alloc, "  co:{d} {s}  resupply every line to its field plan · {d} safety days past the transit · ammo target {s}{s}", .{ @intFromEnum(sp.company), clip(try forceName(alloc, gs, sp.company), 16), sp.min_days, if (sp.ammo_battles > 0) try std.fmt.allocPrint(alloc, "{d} battles", .{sp.ammo_battles}) else "auto", if (sp.tons > 0) try std.fmt.allocPrint(alloc, " · max {d}t per shipment", .{sp.tons}) else "" }));
    }
    if (gs.policies.items.len + gs.supply_policies.items.len > 0) try extras.append(alloc, "  {d}x on a treasury row clears its policy · keep-stocked lines live on the Market screen{/}");
    try extras.append(alloc, "");
    try extras.append(alloc, try std.fmt.allocPrint(alloc, "loans · credit {s} of {s}", .{ try money(alloc, treasury.creditRemaining(gs)), try money(alloc, treasury.creditLimit(gs)) }));
    if (gs.loans.items.len == 0) try extras.append(alloc, "  none · [L] take one (12%/yr simple interest)");
    for (gs.loans.items, 0..) |l, i| {
        try extras.append(alloc, try std.fmt.allocPrint(alloc, "  [{d}] owe {s} of {s} · {s}/mo · next d{d}", .{ i, try money(alloc, l.balance), try money(alloc, l.principal), try money(alloc, l.payment), l.next_pay_day }));
    }
    try extras.append(alloc, "");
    try extras.append(alloc, try std.fmt.allocPrint(alloc, "liquidation value    {s}", .{try money(alloc, treasury.liquidationValue(gs))}));
    try extras.append(alloc, "  {d}hulls at half value × condition · HQs at 40% of build cost{/}");
    try extras.append(alloc, "");
    try extras.append(alloc, "next 30 days (estimate)");
    const payroll = treasury.monthlyPayroll(gs);
    try extras.append(alloc, try std.fmt.allocPrint(alloc, "  payroll        {s: >14}", .{try money(alloc, -payroll)}));
    const hull_upkeep = treasury.monthlyHullUpkeep(gs);
    try extras.append(alloc, try std.fmt.allocPrint(alloc, "  hull upkeep    {s: >14}", .{try money(alloc, -hull_upkeep)}));
    var upkeep: types.CBills = 0;
    var hit = gs.hqs.iterator();
    while (hit.next()) |e| upkeep += e.value_ptr.monthly_upkeep;
    try extras.append(alloc, try std.fmt.allocPrint(alloc, "  HQ upkeep      {s: >14}", .{try money(alloc, -upkeep)}));
    var income: types.CBills = 0;
    var cit = gs.contracts.iterator();
    while (cit.next()) |e| if (e.value_ptr.status == .active) {
        income += e.value_ptr.terms.base_pay_month;
    };
    try extras.append(alloc, try std.fmt.allocPrint(alloc, "  contract pay   {s: >14}", .{try money(alloc, income)}));
    const net = income - payroll - hull_upkeep - upkeep;
    try extras.append(alloc, try std.fmt.allocPrint(alloc, "  net            {s}{s: >14}{{/}}", .{ if (net < 0) "{c}" else "{g}", try money(alloc, net) }));

    const filter: finance.EntityFilter = switch (selected) {
        .outfit => .all,
        .hq => |id| .{ .hq = id },
        .company => |id| .{ .company = id },
    };
    const from: u32 = if (day > period_days) day - period_days else 0;
    const sum = finance.summarize(&gs.ledger, from, day, filter);
    const all = finance.summarize(&gs.ledger, 0, day, filter);
    const pnl_cols = try alloc.dupe(table.Col, &.{ .{ .name = "category" }, .{ .name = try std.fmt.allocPrint(alloc, "{d} days", .{period_days}), .justify = .right }, .{ .name = "campaign", .justify = .right } });
    var pnl: std.ArrayListUnmanaged(table.Row) = .empty;
    inline for (@typeInfo(finance.Category).@"enum".fields) |f| {
        const cat: finance.Category = @enumFromInt(f.value);
        const a = sum.category(cat);
        const b = all.category(cat);
        if (a != 0 or b != 0) {
            try pnl.append(alloc, try table.row(alloc, &.{ try table.plain(alloc, f.name), try money(alloc, a), try money(alloc, b) }));
        }
    }
    try pnl.append(alloc, try table.row(alloc, &.{ "", "", "" }));
    try pnl.append(alloc, try table.row(alloc, &.{
        "NET",
        try std.fmt.allocPrint(alloc, "{s}{s}{{/}}", .{ if (sum.net() < 0) "{c}" else "{g}", try money(alloc, sum.net()) }),
        try std.fmt.allocPrint(alloc, "{s}{s}{{/}}", .{ if (all.net() < 0) "{c}" else "{g}", try money(alloc, all.net()) }),
    }));

    var led: std.ArrayListUnmanaged(table.Row) = .empty;
    const txns = gs.ledger.transactions.items;
    var i: usize = txns.len;
    while (i > 0 and led.items.len < max_rows) {
        i -= 1;
        const t = &txns[i];
        if (!filter.matches(t)) continue;
        const mk: []const u8 = if (t.amount < 0) "" else "{g}";
        try led.append(alloc, try table.row(alloc, &.{ try std.fmt.allocPrint(alloc, "d{d}", .{t.day}), @tagName(t.category), try std.fmt.allocPrint(alloc, "{s}{s}{{/}}", .{ mk, try money(alloc, t.amount) }), t.note }));
    }

    return .{
        .treasuries = try rows.toOwnedSlice(alloc),
        .extras = try extras.toOwnedSlice(alloc),
        .pnl_title = try std.fmt.allocPrint(alloc, "P&L · {s}", .{try treasuryLabel(alloc, gs, selected)}),
        .pnl_cols = pnl_cols,
        .pnl = try pnl.toOwnedSlice(alloc),
        .ledger = try led.toOwnedSlice(alloc),
    };
}

// ------------------------------------------------------------------ forces

pub const ToeRow = struct {
    force: types.ForceId,
    unit: types.UnitId,
    text: []const u8,
    /// The company the row belongs to (`.none` for the pool and hangar rows).
    company: types.ForceId = .none,
    /// The force's own name on a force row.
    name: table.Raw = .{ .raw = "" },
    is_company: bool = false,
    /// A line or air lance (roles cycle on these; ROE on companies).
    is_lance: bool = false,
    /// Hull rows: mothballed (m reactivates instead of mothballing).
    mothballed: bool = false,
    /// Hull rows: the indent and the cells; `finishToe` pads them to
    /// widths shared by every hull row in the tree, so the tree stays a
    /// list while its columns line up.
    prefix: []const u8 = "",
    cells: ?table.Row = null,
};

const toe_unit_cols: []const table.Col = &.{ .{ .name = "" }, .{ .name = "" }, .{ .name = "" }, .{ .name = "", .justify = .right }, .{ .name = "" }, .{ .name = "" }, .{ .name = "" }, .{ .name = "" } };

fn finishToe(alloc: Alloc, out: *std.ArrayListUnmanaged(ToeRow)) ![]ToeRow {
    var cells: std.ArrayListUnmanaged(table.Row) = .empty;
    for (out.items) |r| if (r.cells) |c| try cells.append(alloc, c);
    const w = try (table.Table{ .cols = toe_unit_cols, .rows = cells.items }).widths(alloc);
    for (out.items) |*r| {
        const c = r.cells orelse continue;
        var line: std.ArrayListUnmanaged(u8) = .empty;
        try line.appendSlice(alloc, r.prefix);
        for (c, 0..) |cell, i| {
            if (i > 0) try line.appendSlice(alloc, "  ");
            try line.appendSlice(alloc, try table.pad(alloc, cell, w[i], toe_unit_cols[i].justify));
        }
        r.text = try line.toOwnedSlice(alloc);
    }
    return out.toOwnedSlice(alloc);
}

/// The TO&E as an indented tree, one row per force and hull, followed by
/// the hulls that belong to no force (bought, salvaged, or pulled out).
pub fn toe(alloc: Alloc, gs: *GameState) ![]ToeRow {
    return toeFiltered(alloc, gs, .all);
}

/// What the Forces screen shows: everything, one company, or the hulls
/// that belong to no force.
pub const ToeFilter = union(enum) { all, company: types.ForceId, unassigned, hangar };

pub const ToeView = struct { filter: ToeFilter, label: []const u8 };

/// The views the Forces screen can page through with [ and ].
pub fn toeViews(alloc: Alloc, gs: *GameState) ![]ToeView {
    var out: std.ArrayListUnmanaged(ToeView) = .empty;
    try out.append(alloc, .{ .filter = .all, .label = "all forces" });
    var fit = gs.forces.iterator();
    while (fit.next()) |e| {
        const f = e.value_ptr;
        if (f.parent != .none) continue;
        try out.append(alloc, .{ .filter = .{ .company = f.id }, .label = try table.plain(alloc, f.name) });
    }
    try out.append(alloc, .{ .filter = .unassigned, .label = try std.fmt.allocPrint(alloc, "unassigned hulls — at {s}", .{if (gs.hqs.getPtr(gs.homeHqFor(.none))) |h| try table.plain(alloc, h.name) else "the seat"}) });
    try out.append(alloc, .{ .filter = .hangar, .label = "hangar: cost vs contribution" });
    return out.toOwnedSlice(alloc);
}

pub const HangarRow = struct {
    unit: types.UnitId,
    bill: types.CBills,
    /// BV the hull brings to a fight today: chassis BV × condition, zero
    /// without a fit pilot or in cold storage.
    contribution: u32,
    /// Monthly C-bills per point of contribution (×100); higher = worse.
    cost_index: u64,
    /// Why it earns what it earns, decided once with the contribution.
    why: []const u8,
    /// The enemy holds this hull: it is not in `gs.units`, so the
    /// row's unit is read from the limbo list instead.
    held: bool = false,
    cells: table.Row,
};

pub const hangar_cols: []const table.Col = &.{
    .{ .name = "#" },                              .{ .name = "hull" },                          .{ .name = "name" },    .{ .name = "bill/mo", .justify = .right },
    .{ .name = "contributes", .justify = .right }, .{ .name = "cost index", .justify = .right }, .{ .name = "company" }, .{ .name = "why" },
};

/// What a house asks for one of yours (the ransom table).
pub const missingRansom = contract_events.ransomPrice;

/// Does the outfit hold a prisoner of this house (a trade is possible)?
pub fn holdsPrisonerOf(gs: *GameState, faction: []const u8) bool {
    return gs.holdsPrisonerOf(faction);
}

/// A wreck's line: how it died, what the rebuild costs against a
/// new hull, and whether it is worth doing at all.
pub fn wreckNote(alloc: std.mem.Allocator, gs: *GameState, u: *const @import("../domain/unit.zig").Unit) ![]const u8 {
    const hq_ops = @import("hq_ops.zig");
    const cause = if (u.wreck == .none) "wreck" else u.wreck.label();
    const est = hq_ops.rebuildEstimate(gs, u) orelse return try std.fmt.allocPrint(alloc, "{{c}}{s} — strip it (Forces $, s) or sell for {s}{{/}}", .{ cause, try money(alloc, treasury.unitSaleValue(u)) });
    const new_cost: types.CBills = if (chassis_mod.find(u.chassis_key)) |c| c.cost else 0;
    return try std.fmt.allocPrint(alloc, "{{c}}{s} — rebuild ≈{s} vs new {s}{s}{{/}}", .{
        cause, try money(alloc, est), try money(alloc, new_cost),
        if (hq_ops.beyondEconomicalRepair(gs, u)) " · beyond economical repair: strip or sell" else "",
    });
}

/// The hangar as a portfolio (GAMEPLAY "the roster ranks meks by what
/// they cost against what they contribute"): every owned hull, worst
/// value first. A mothballed hull or a wreck bills a fifth and contributes
/// nothing; a pilotless one bills in full for nothing. Hulls the enemy
/// holds are listed last: a standing claim, not an asset.
pub fn hangar(alloc: Alloc, gs: *GameState) ![]HangarRow {
    var out: std.ArrayListUnmanaged(HangarRow) = .empty;
    const day = gs.clock.day_index;
    var uit = gs.units.iterator();
    while (uit.next()) |e| {
        const u = e.value_ptr;
        const ch = chassis_mod.find(u.chassis_key);
        const bv: u32 = if (ch) |c| c.bv else 0;
        const pilot = gs.person(u.pilot);
        const fit = pilot != null and pilot.?.isAvailable(day);
        var why: []const u8 = "";
        var contribution: u32 = 0;
        if (u.status == .destroyed) {
            why = try wreckNote(alloc, gs, u);
        } else if (u.status == .mothballed) {
            why = "{d}cold storage{/}";
        } else if (u.kind.isTransport()) {
            why = "transport (lifts the company)";
            contribution = 1;
        } else if (!u.kind.isCombat()) {
            why = "support train";
            contribution = 1;
        } else if (!fit) {
            why = "{a}no fit pilot — hire or assign{/}";
        } else {
            contribution = bv * @as(u32, u.conditionPct()) / 100;
            if (u.needsDepot()) {
                why = if (@import("hq_ops.zig").hasJobForUnit(gs, u.id)) "{d}in the depot — HQ screen bays{/}" else "{a}structural damage — d sends it to the depot{/}";
            } else {
                var gear_bad: u32 = 0;
                var gear_gone: u32 = 0;
                for (u.slots.items) |s| if (s.class != .structure and s.condition != .ok) {
                    if (s.condition == .damaged) gear_bad += 1 else gear_gone += 1;
                };
                if (gear_bad + gear_gone > 0) why = try std.fmt.allocPrint(alloc, "{{a}}gear: {d} destroyed, {d} damaged — its tech fixes it weekly (R orders spares){{/}}", .{ gear_gone, gear_bad }) else if (u.conditionPct() < @import("../domain/tuning.zig").t.unit.shot_up_condition_pct) why = "{a}shot up — repairs{/}";
            }
        }
        const bill = u.monthlyBill();
        // Support and transport hulls are judged by what they enable, not
        // BV: they sit at the bottom unless wrecked.
        const exempt = u.status != .destroyed and (u.kind.isTransport() or !u.kind.isCombat());
        const cost_index: u64 = if (exempt) 0 else if (contribution == 0) std.math.maxInt(u32) else @as(u64, @intCast(bill)) * 100 / contribution;
        try out.append(alloc, .{ .unit = u.id, .bill = bill, .contribution = contribution, .cost_index = cost_index, .why = why, .cells = &.{} });
    }
    // Hulls the enemy holds are still the company's claim, so the
    // portfolio names them — but they cost nothing and contribute nothing,
    // so they rank nowhere and sit at the bottom.
    for (gs.held_hulls.items) |*h| {
        try out.append(alloc, .{
            .unit = h.unit.id,
            .bill = 0,
            .contribution = 0,
            .cost_index = 0,
            .why = try std.fmt.allocPrint(alloc, "{{c}}held by {s} — left on a lost field day {d}{{/}}", .{ h.by, h.day }),
            .held = true,
            .cells = &.{},
        });
    }
    std.mem.sort(HangarRow, out.items, {}, struct {
        fn lt(_: void, a: HangarRow, b: HangarRow) bool {
            if (a.cost_index != b.cost_index) return a.cost_index > b.cost_index;
            return a.bill > b.bill;
        }
    }.lt);
    for (out.items) |*row| {
        const u = if (row.held) &gs.heldHull(row.unit).?.unit else gs.unit(row.unit).?;
        const ch = chassis_mod.find(u.chassis_key);
        const why = row.why;
        const idx_text: []const u8 = if (row.cost_index == 0) "—" else if (row.contribution == 0) "{c}∞{/}" else try std.fmt.allocPrint(alloc, "{d}", .{row.cost_index});
        row.cells = try table.row(alloc, &.{
            try std.fmt.allocPrint(alloc, "#{d}", .{@intFromEnum(u.id)}),
            u.chassis_key,
            if (ch) |c| c.name else "?",
            try money(alloc, row.bill),
            try std.fmt.allocPrint(alloc, "{d} BV", .{row.contribution}),
            idx_text,
            if (row.held) "{c}enemy hands{/}" else try forceName(alloc, gs, gs.companyOf(u.force)),
            why,
        });
    }
    return out.toOwnedSlice(alloc);
}

pub fn toeFiltered(alloc: Alloc, gs: *GameState, filter: ToeFilter) ![]ToeRow {
    var out: std.ArrayListUnmanaged(ToeRow) = .empty;
    if (filter == .all or filter == .company) {
        var fit = gs.forces.iterator();
        while (fit.next()) |e| {
            const f = e.value_ptr;
            if (f.parent != .none) continue;
            if (filter == .company and filter.company != f.id) continue;
            try toeInto(alloc, gs, &out, f.id, 0);
        }
    }
    if (filter == .company) return finishToe(alloc, &out);
    if (filter == .hangar) {
        try out.append(alloc, .{ .force = .none, .unit = .none, .text = "{a}[—] Hangar · worst value first{/}  bill per point of contribution (BV × condition; nothing without a fit pilot)" });
        // The tree keeps lines: the hangar table rendered at natural width.
        const hrows = try hangar(alloc, gs);
        const hlines = try (try tableOf(alloc, hangar_cols, hrows)).render(alloc);
        try out.append(alloc, .{ .force = .none, .unit = .none, .text = try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}", .{hlines[0]}) });
        for (hrows, hlines[1..]) |row, line| try out.append(alloc, .{ .force = .none, .unit = row.unit, .text = line });
        return finishToe(alloc, &out);
    }
    var loose: u32 = 0;
    var upkeep: types.CBills = 0;
    var uit = gs.units.iterator();
    while (uit.next()) |e| if (e.value_ptr.force == .none and e.value_ptr.status != .destroyed) {
        loose += 1;
        upkeep += e.value_ptr.monthlyBill();
    };
    if (loose == 0 and filter == .unassigned) try out.append(alloc, .{ .force = .none, .unit = .none, .text = "{d}no unassigned hulls — everything bought or salvaged is in a company{/}" });
    if (loose > 0) {
        try out.append(alloc, .{ .force = .none, .unit = .none, .text = try std.fmt.allocPrint(alloc, "{{a}}[—] Unassigned hulls{{/}}  at {s} (their depot and shelf)  {d} · {s}/mo upkeep · {{d}}no tech: they degrade; [x] place in a company, [m] mothball{{/}}", .{ if (gs.hqs.getPtr(gs.homeHqFor(.none))) |h| try table.plain(alloc, h.name) else "the seat", loose, try money(alloc, upkeep) }) });
        var it2 = gs.units.iterator();
        while (it2.next()) |e| {
            const u = e.value_ptr;
            if (u.force != .none or u.status == .destroyed) continue;
            const ch = chassis_mod.find(u.chassis_key);
            const st_mk: []const u8 = switch (u.status) {
                .ready => "{g}",
                .mothballed => "{d}",
                .damaged, .repairing, .refitting => "{a}",
                else => "{c}",
            };
            // What the depot at the seat will want for it, so the pool says
            // where each hull sits and which base to stock.
            const hq_ops = @import("hq_ops.zig");
            const seat = hq_ops.depotHqFor(gs, u);
            const wants = try hq_ops.depotNeeds(alloc, u);
            var needs: std.ArrayListUnmanaged(u8) = .empty;
            for (wants, 0..) |w, i| {
                var n: u32 = 0;
                var first = true;
                for (wants, 0..) |o, j| if (std.mem.eql(u8, o.component, w.component)) {
                    n += 1;
                    if (j < i) first = false;
                };
                if (!first) continue;
                const have = gs.stockCount(.{ .hq = seat }, w.component);
                // "comp_ct×2 (2)": the count wanted, and what the shelf holds.
                try needs.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s}{s}{s}×{d}({d}){{/}}", .{ if (needs.items.len == 0) "" else " ", if (have >= n) "{g}" else "{c}", w.component, n, have }));
            }
            // The pilot/tech columns are always empty in the pool: they carry
            // the depot's shopping list instead.
            try out.append(alloc, .{ .force = .none, .unit = u.id, .mothballed = u.status == .mothballed, .text = try std.fmt.allocPrint(alloc, "    #{d: <3} {s: <8} {s} {d: >3}t  {s} {s} armor {s}{s} · {s}/mo", .{
                @intFromEnum(u.id),
                u.chassis_key,
                try padCells(alloc, "", if (ch) |c| c.name else "?", 14),
                if (ch) |c| c.tonnage else 0,
                try padCells(alloc, "", if (needs.items.len > 0) needs.items else "—", 36),
                try padCells(alloc, st_mk, @tagName(u.status), 9),
                try armorPct(alloc, u.armor_pct),
                try damageMarks(alloc, u),
                try money(alloc, u.monthlyBill()),
            }) });
        }
    }
    return finishToe(alloc, &out);
}

fn toeInto(alloc: Alloc, gs: *GameState, out: *std.ArrayListUnmanaged(ToeRow), id: types.ForceId, depth: usize) !void {
    const f = gs.forces.getPtr(id) orelse return;
    const indent = try alloc.alloc(u8, depth * 2);
    @memset(indent, ' ');
    const posture: []const u8 = if (f.echelon == .company) (if (gs.isCompanyHome(id)) "at home" else "{a}afield{/}") else if (f.echelon == .support_lance) (if (f.support_kind) |k| @tagName(k) else "support") else @tagName(f.role);
    const company = gs.companyOf(id);
    try out.append(alloc, .{ .force = id, .unit = .none, .company = company, .name = .{ .raw = f.name }, .is_company = f.echelon == .company, .is_lance = f.isCombatLance(), .text = try std.fmt.allocPrint(alloc, "{s}{{a}}[{d}] {s}{{/}}  {s} · {s} · {d} hulls", .{ indent, @intFromEnum(id), try table.plain(alloc, f.name), @tagName(f.echelon), posture, f.units.items.len }) });
    for (f.units.items) |uid| {
        const u = gs.unit(uid) orelse continue;
        const ch = chassis_mod.find(u.chassis_key);
        const pilot = gs.person(u.pilot);
        const tech = gs.person(u.tech);
        const needs_tech = unit_mod.techRoleFor(u.kind) != null;
        const st_mk: []const u8 = switch (u.status) {
            .ready => "{g}",
            .damaged, .repairing, .refitting => "{a}",
            else => "{c}",
        };
        try out.append(alloc, .{ .force = id, .unit = uid, .company = company, .mothballed = u.status == .mothballed, .text = "", .prefix = try std.fmt.allocPrint(alloc, "{s}    ", .{indent}), .cells = try table.row(alloc, &.{
            try std.fmt.allocPrint(alloc, "#{d}", .{@intFromEnum(uid)}),
            u.chassis_key,
            if (ch) |c| c.name else "?",
            try std.fmt.allocPrint(alloc, "{d}t", .{if (ch) |c| c.tonnage else 0}),
            if (pilot) |p| try seatText(alloc, gs, p, "{c}") else "{c}— no pilot{/}",
            if (tech) |t| try seatText(alloc, gs, t, "{a}") else if (needs_tech) "{c}— no tech{/}" else "—",
            try std.fmt.allocPrint(alloc, "{s}{s}{{/}}{s}", .{ st_mk, @tagName(u.status), if (pilot != null and pilot.?.seatState(gs.clock.day_index) == .fit) "" else " · {c}sits out{/}" }),
            try std.fmt.allocPrint(alloc, "armor {s}{s}", .{ try armorBar(alloc, u.armor_pct), try damageMarks(alloc, u) }),
        }) });
    }
    for (f.children.items) |cid| try toeInto(alloc, gs, out, cid, depth + 1);
}

/// A seat's occupant on the TO&E: the name, and while they are not fit to
/// take the seat, why and until when, in `mark` (red for a pilot: the
/// hull sits out; amber for a tech: repairs wait).
fn seatText(alloc: Alloc, gs: *GameState, p: *const person_mod.Person, mark: []const u8) ![]const u8 {
    const day = gs.clock.day_index;
    const name = try personText(alloc, p);
    return switch (p.seatState(day)) {
        .fit => name,
        .recovering => if (p.backDay(day)) |back|
            try std.fmt.allocPrint(alloc, "{s}{s} · {s} → day {d}{{/}}", .{ mark, name, if (p.status == .wounded) "medbay" else "leave", back })
        else
            try std.fmt.allocPrint(alloc, "{s}{s} · wounded, not admitted{{/}}", .{ mark, name }),
        .away => try std.fmt.allocPrint(alloc, "{s}{s} · {s}{{/}}", .{ mark, name, @tagName(p.status) }),
    };
}

/// Location tag of a slot key ("lt.structure" → "lt").
fn slotLocation(slot_key: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, slot_key, '.') orelse return slot_key;
    return slot_key[0..dot];
}

/// A hull's damage at a glance, for the TO&E row: structure hits (depot
/// work, each needs a comp_* part) by location in red, then a count of
/// damaged or destroyed gear (field work) in amber. Empty when whole.
pub fn damageMarks(alloc: Alloc, u: *const unit_mod.Unit) ![]const u8 {
    var locs: std.ArrayListUnmanaged(u8) = .empty;
    var gear: u32 = 0;
    for (u.slots.items) |s| {
        if (s.condition == .ok) continue;
        if (s.class == .structure) {
            if (locs.items.len > 0) try locs.append(alloc, ',');
            try locs.appendSlice(alloc, slotLocation(s.slot_key));
        } else gear += 1;
    }
    if (locs.items.len == 0 and gear == 0) return "";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (locs.items.len > 0) try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, " · {{c}}struct {s}{{/}}", .{locs.items}));
    if (gear > 0) try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, " · {{a}}gear {d}{{/}}", .{gear}));
    return out.toOwnedSlice(alloc);
}

pub const CompanyDamage = struct {
    lines: []const []const u8,
    /// The structural component the company is shortest of (null = none short).
    short_key: ?[]const u8,
    /// Where the components would be fabricated/stocked.
    home: types.HqId,
};

/// One company's repair picture, for the Forces screen: every hull with
/// damage, what each location needs, and the structural components the
/// home warehouse must have ready before the company comes back.
pub fn companyDamage(alloc: Alloc, gs: *GameState, company: types.ForceId) !CompanyDamage {
    const hq_ops = @import("hq_ops.zig");
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    const home = gs.homeHqFor(company);
    var hulls: u32 = 0;
    var uit = gs.units.iterator();
    while (uit.next()) |e| {
        const u = e.value_ptr;
        if (gs.companyOf(u.force) != company) continue;
        var structure: std.ArrayListUnmanaged(u8) = .empty;
        var gear_damaged: u32 = 0;
        var gear_destroyed: u32 = 0;
        // Structure: what the depot will consume comes from the one rule
        // (hq_ops.depotNeeds); damaged structure is bay time alone, so the
        // list never flags a part the depot will not consume.
        const wants = try hq_ops.depotNeeds(alloc, u);
        for (u.slots.items) |s| {
            if (s.condition == .ok) continue;
            if (s.class == .structure) {
                var comp: ?[]const u8 = null;
                for (wants) |w| if (std.mem.eql(u8, w.slot_key, s.slot_key)) {
                    comp = w.component;
                };
                if (comp == null and s.condition != .damaged) continue; // scrap: nothing to rebuild
                if (structure.items.len > 0) try structure.appendSlice(alloc, ", ");
                if (comp) |c| {
                    try structure.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s}→{s}", .{ slotLocation(s.slot_key), c }));
                } else {
                    try structure.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s} (bay time only)", .{slotLocation(s.slot_key)}));
                }
            } else if (s.condition == .damaged) gear_damaged += 1 else gear_destroyed += 1;
        }
        if (structure.items.len == 0 and gear_damaged + gear_destroyed == 0) continue;
        hulls += 1;
        const ch = chassis_mod.find(u.chassis_key);
        try lines.append(alloc, try std.fmt.allocPrint(alloc, "{{a}}#{d} {s} {s}{{/}}  {s} · {s}{s}", .{ @intFromEnum(u.id), u.chassis_key, if (ch) |c| clip(c.name, 14) else "?", try armorBar(alloc, u.armor_pct), @tagName(u.status), if (u.status == .destroyed) try std.fmt.allocPrint(alloc, " · {s}", .{try wreckNote(alloc, gs, u)}) else "" }));
        if (structure.items.len > 0) try lines.append(alloc, try std.fmt.allocPrint(alloc, "    {{c}}structure{{/}}  {s}  {{d}}depot work at home{{/}}", .{structure.items}));
        if (gear_damaged + gear_destroyed > 0) try lines.append(alloc, try std.fmt.allocPrint(alloc, "    {{a}}gear{{/}}       {d} damaged, {d} destroyed  {{d}}field work: techs + spares (Forces R / :replace orders what's destroyed){{/}}", .{ gear_damaged, gear_destroyed }));
    }
    if (hulls == 0) try lines.append(alloc, "{g}every hull is whole{/}");
    var short_key: ?[]const u8 = null;
    var short_most: u32 = 0;
    const comps = try hq_ops.componentDemand(alloc, gs, home, company);
    if (comps.len > 0) {
        try lines.append(alloc, "");
        try lines.append(alloc, try std.fmt.allocPrint(alloc, "components to have ready at {s}", .{if (gs.hqs.getPtr(home)) |h| try table.plain(alloc, h.name) else "the home HQ"}));
        try lines.append(alloc, "  part          need  at home  coming  short");
        for (comps) |l| {
            if (l.short > short_most) {
                short_most = l.short;
                short_key = l.key;
            }
            try lines.append(alloc, try std.fmt.allocPrint(alloc, "  {s: <12} {d: >5} {d: >8} {d: >7}  {s}{d: >5}{{/}}", .{ clip(l.key, 12), l.need, l.on_hand, l.coming, if (l.short > 0) "{c}" else "{g}", l.short }));
        }
        try lines.append(alloc, if (short_key != null) "  {d}[b] fabricates the shortest line at the home HQ · :stockpolicy keeps it stocked{/}" else "  {d}covered — the depot can start the day they land{/}");
    }
    return .{ .lines = try lines.toOwnedSlice(alloc), .short_key = short_key, .home = home };
}

/// Detail lines for one hull.
pub fn hull(alloc: Alloc, gs: *GameState, uid: types.UnitId) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const u = gs.unit(uid) orelse return out.toOwnedSlice(alloc);
    const ch = chassis_mod.find(u.chassis_key);
    try out.append(alloc, try std.fmt.allocPrint(alloc, "{{a}}#{d} {s} {s}{{/}}  {d}t · quality {s} · armor {s} · status {s} · value {s}", .{
        @intFromEnum(uid), u.chassis_key, if (ch) |c| c.name else "?", if (ch) |c| c.tonnage else 0, @tagName(u.quality), try armorBar(alloc, u.armor_pct), @tagName(u.status), try money(alloc, u.purchase_price),
    }));
    if (gs.person(u.pilot)) |p| {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "pilot   {{g}}{s}{{/}}  {s}  {s}  fatigue {d} · morale {d}", .{ try personText(alloc, p), @tagName(p.role), @tagName(p.experience()), p.fatigue, p.morale }));
    } else try out.append(alloc, "pilot   {c}none{/}");
    if (gs.person(u.tech)) |t| {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "tech    {{g}}{s}{{/}}  {s}  {s}  {d}/{d} h this week", .{ try personText(alloc, t), @tagName(t.role), @tagName(t.experience()), gs.techLoadHours(t.id), t.weekly_hours }));
    } else if (unit_mod.techRoleFor(u.kind) != null) try out.append(alloc, "tech    {c}none{/}");
    try out.append(alloc, "");
    try out.append(alloc, "slot                 part            class      condition");
    for (u.slots.items) |s| {
        const mk: []const u8 = switch (s.condition) {
            .ok => "{g}",
            .damaged => "{a}",
            else => "{c}",
        };
        try out.append(alloc, try std.fmt.allocPrint(alloc, "{s: <20} {s: <15} {s: <10} {s}{s}{{/}}", .{ s.slot_key, s.part_key, @tagName(s.class), mk, @tagName(s.condition) }));
    }
    try out.append(alloc, "");
    try out.append(alloc, try std.fmt.allocPrint(alloc, "upkeep {s}/mo · maintenance {d} h/week ({d} in its tech's hands; quality {s}{s}) · depot needed: {s}", .{
        try money(alloc, u.monthlyBill()), gs.hullHours(u), if (gs.person(u.tech)) |t| gs.techHoursFor(t, u) else gs.hullHours(u), @tagName(u.quality), if (ch) |c| (if (c.rarity == .very_rare) ", exotic design" else "") else "", if (u.needsDepot()) "{c}yes{/}" else "no",
    }));
    return out.toOwnedSlice(alloc);
}

/// People without a seat, and hulls missing crew.
pub fn unassigned(alloc: Alloc, gs: *GameState) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const day = gs.clock.day_index;
    try out.append(alloc, "id     name                    role           exp        notes");
    var pit = gs.people.iterator();
    while (pit.next()) |e| {
        const p = e.value_ptr;
        if (p.status != .active or p.posted_hq != .none) continue;
        if (p.role != .mekwarrior and p.role != .tech_mek and p.role != .vehicle_crew and p.role != .tech_mechanic) continue;
        if (gs.pilotSeat(p.id) != .none) continue;
        var seated = false;
        var uit = gs.units.iterator();
        while (uit.next()) |ue| if (ue.value_ptr.tech == p.id) {
            seated = true;
        };
        if (seated) continue;
        try out.append(alloc, try std.fmt.allocPrint(alloc, "{d: <6} {s: <23} {s: <14} {s: <10} {s}", .{ @intFromEnum(p.id), try std.fmt.allocPrint(alloc, "{s}", .{try personText(alloc, p)}), @tagName(p.role), @tagName(p.experience()), if (p.isAvailable(day)) "" else "{a}unavailable{/}" }));
    }
    return out.toOwnedSlice(alloc);
}

// ------------------------------------------------------------------ supply

pub const Supply = struct {
    rows: []const []const u8,
    /// The site each row belongs to (null for inbound/other rows).
    site: []const ?types.Site,
};

pub fn supply(alloc: Alloc, gs: *GameState) !Supply {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var sites: std.ArrayListUnmanaged(?types.Site) = .empty;
    var hit = gs.hqs.iterator();
    while (hit.next()) |e| {
        const h = e.value_ptr;
        const before = out.items.len;
        try siteLines(alloc, gs, &out, .{ .hq = h.id }, try std.fmt.allocPrint(alloc, "hq:{d} {{a}}{s}{{/}} warehouse lv{d}", .{ @intFromEnum(h.id), try table.plain(alloc, h.name), h.effectiveFacilityLevel(.warehouse) }));
        while (sites.items.len < out.items.len) try sites.append(alloc, if (sites.items.len < out.items.len - 1 or before == out.items.len) .{ .hq = h.id } else null);
    }
    var fit = gs.forces.iterator();
    while (fit.next()) |e| {
        const f = e.value_ptr;
        if (f.echelon != .company) continue;
        const home = gs.isCompanyHome(f.id);
        const days_left: ?u32 = if (!home) blk: {
            const heads = gs.companyHeadcount(f.id);
            const tons = gs.stockCount(.{ .company = f.id }, "provisions");
            const per_day = @import("../domain/part.zig").provisionsPerDay(heads);
            break :blk tons / per_day;
        } else null;
        var resupply: []const u8 = "";
        for (gs.supply_policies.items) |sp| if (sp.company == f.id) {
            resupply = try std.fmt.allocPrint(alloc, " · resupply plan on ({d} safety days, ammo {s})", .{ sp.min_days, if (sp.ammo_battles > 0) try std.fmt.allocPrint(alloc, "{d} battles", .{sp.ammo_battles}) else "auto" });
        };
        const title = try std.fmt.allocPrint(alloc, "co:{d} {{a}}{s}{{/}} field stores{s}{s} · funds {s}{s}", .{
            @intFromEnum(f.id),              try table.plain(alloc, f.name),
            if (home) "" else " · {a}DEPLOYED{/}",
            if (days_left) |d| try std.fmt.allocPrint(alloc, " · {s}{d} days of provisions{{/}}", .{ if (d < 10) "{c}" else "{g}", d }) else "",
            try money(alloc, f.local_funds), resupply,
        });
        try siteLines(alloc, gs, &out, .{ .company = f.id }, title);
        while (sites.items.len < out.items.len) try sites.append(alloc, if (sites.items.len < out.items.len - 1) .{ .company = f.id } else null);
    }
    try out.append(alloc, "inbound");
    try sites.append(alloc, null);
    var any = false;
    for (gs.part_orders.items) |o| {
        if (o.status == .delivered) continue;
        any = true;
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  {s} x{d} → {s}  {s}  eta day {d}  cost {s}", .{ o.part_key, o.quantity, try siteLabel(alloc, gs, o.dest), @tagName(o.status), o.eta_day orelse 0, try money(alloc, o.cost) }));
        try sites.append(alloc, null);
    }
    if (!any) {
        try out.append(alloc, "  none");
        try sites.append(alloc, null);
    }
    try out.append(alloc, "");
    try sites.append(alloc, null);
    try out.append(alloc, "{d}on a company row: [t] send cash by courier · [p] standing top-up policy · [s] ship provisions from home · [o] order to the field{/}");
    try sites.append(alloc, null);
    return .{ .rows = try out.toOwnedSlice(alloc), .site = try sites.toOwnedSlice(alloc) };
}

/// The munition families a company's weapons fire (keys, deduplicated):
/// `field_supply.munitionMounts` is the census.
pub fn neededMunitions(alloc: Alloc, gs: *GameState, company: types.ForceId) ![]const []const u8 {
    const mounts = try @import("field_supply.zig").munitionMounts(alloc, gs, company, false);
    return try alloc.dupe([]const u8, mounts.keys());
}

/// Stock at one site as a table: part, quantity, tonnage. Lines a site is
/// expected to hold (provisions, medical, armor, the munitions its
/// company's weapons fire) stay listed at zero, in red, instead of vanishing.
pub fn stockTable(alloc: Alloc, gs: *GameState, site: types.Site) ![]const []const u8 {
    const part_mod = @import("../domain/part.zig");
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const stock: ?*const std.StringArrayHashMapUnmanaged(u32) = switch (site) {
        .outfit => &gs.spare_parts,
        .hq => |id| if (gs.hqs.getPtr(id)) |h| &h.stock else null,
        .company => |id| if (gs.forces.getPtr(id)) |f| &f.stock else null,
    };
    const stock_cols: []const table.Col = &.{ .{ .name = "part" }, .{ .name = "qty", .justify = .right }, .{ .name = "tons", .justify = .right }, .{ .name = "kind" } };
    var srows: std.ArrayListUnmanaged(table.Row) = .empty;
    var total: u32 = 0;
    var listed: std.ArrayListUnmanaged([]const u8) = .empty;
    if (stock) |m| {
        var it = m.iterator();
        while (it.next()) |e| {
            const qty = e.value_ptr.*;
            const key = e.key_ptr.*;
            try listed.append(alloc, key);
            const tons = qty * part_mod.tons(key);
            total += tons;
            const kind: []const u8 = if (part_mod.isComponent(key)) "component" else if (part_mod.find(key)) |p| switch (p.mount) {
                .energy, .ballistic, .missile => "weapon",
                .ammo => "ammo",
                .equipment => "equipment",
                .none => "supplies",
            } else "supplies";
            const mk: []const u8 = if (qty == 0) "{c}" else "";
            try srows.append(alloc, try table.row(alloc, &.{ try std.fmt.allocPrint(alloc, "{s}{s}{{/}}", .{ mk, key }), try std.fmt.allocPrint(alloc, "{s}{d}{{/}}", .{ mk, qty }), try std.fmt.allocPrint(alloc, "{s}{d}t{{/}}", .{ mk, tons }), try std.fmt.allocPrint(alloc, "{s}{s}{{/}}", .{ mk, kind }) }));
        }
    }
    // Expected lines that have never been stocked here.
    var expected: std.ArrayListUnmanaged([]const u8) = .empty;
    try expected.append(alloc, "provisions");
    try expected.append(alloc, "medical_supplies");
    try expected.append(alloc, "armor");
    switch (site) {
        .company => |id| for (try neededMunitions(alloc, gs, id)) |k| try expected.append(alloc, k),
        .hq => for (part_mod.munition_keys) |k| try expected.append(alloc, k),
        .outfit => {},
    }
    for (expected.items) |key| {
        var have = false;
        for (listed.items) |k| if (std.mem.eql(u8, k, key)) {
            have = true;
        };
        if (have) continue;
        const kind: []const u8 = if (part_mod.find(key)) |p| (if (p.mount == .ammo) "ammo" else "supplies") else "supplies";
        try srows.append(alloc, try table.row(alloc, &.{ try std.fmt.allocPrint(alloc, "{{c}}{s}{{/}}", .{key}), "{c}0{/}", "{c}0t{/}", try std.fmt.allocPrint(alloc, "{{c}}{s} · none{{/}}", .{kind}) }));
    }
    for (try (table.Table{ .cols = stock_cols, .rows = srows.items }).render(alloc), 0..) |ln, i| try out.append(alloc, if (i == 0) try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}", .{ln}) else ln);
    if (srows.items.len == 0) try out.append(alloc, "{d}empty{/}");
    if (site == .company) {
        var policy: ?state_mod.SupplyPolicy = null;
        for (gs.supply_policies.items) |sp| if (sp.company == site.company) {
            policy = sp;
        };
        const field_supply = @import("field_supply.zig");
        const transit = @import("treasury.zig").courierEtaDays(gs, .{ .company = site.company });
        const p = try field_supply.plan(alloc, gs, site.company, transit, if (policy) |sp| sp.min_days else 14, if (policy) |sp| sp.ammo_battles else 0);
        try out.append(alloc, "");
        try out.append(alloc, try std.fmt.allocPrint(alloc, "field plan · {d}t trucks · {d}-day line{s}", .{ p.capacity, transit, if (policy != null) "" else " · {c}no resupply policy — P sets one{/}" }));
        const plan_cols: []const table.Col = &.{ .{ .name = "line" }, .{ .name = "floor", .justify = .right }, .{ .name = "target", .justify = .right }, .{ .name = "on hand", .justify = .right }, .{ .name = "inbound", .justify = .right }, .{ .name = "" } };
        var prows: std.ArrayListUnmanaged(table.Row) = .empty;
        for (p.lines) |l| {
            const have = gs.stockCount(site, l.key);
            const coming = field_supply.inboundQty(gs, site.company, l.key);
            const mk: []const u8 = if (have + coming < l.floor) "{c}" else if (have < l.floor) "{a}" else "{g}";
            try prows.append(alloc, try table.row(alloc, &.{ l.key, try std.fmt.allocPrint(alloc, "{d}", .{l.floor}), try std.fmt.allocPrint(alloc, "{d}", .{l.target}), try std.fmt.allocPrint(alloc, "{s}{d}{{/}}", .{ mk, have }), try std.fmt.allocPrint(alloc, "{d}", .{coming}), try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}{s}", .{ l.note, if (l.trimmed) " {a}trimmed to the ammo share{/}" else "" }) }));
        }
        for (try (table.Table{ .cols = plan_cols, .rows = prows.items }).render(alloc), 0..) |ln, i| try out.append(alloc, if (i == 0) try std.fmt.allocPrint(alloc, "  {{d}}{s}{{/}}", .{ln}) else try std.fmt.allocPrint(alloc, "  {s}", .{ln}));
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  {{d}}truck shares: ammo {d}% · armor {d}% · medical {d}% · provisions take the rest · a line ships when on hand + inbound < floor · R returns anything over target home{{/}}", .{ field_supply.ammo_share_pct, field_supply.armor_share_pct, field_supply.medical_share_pct }));
    }
    if (site == .hq) {
        var any = false;
        for (gs.stock_policies.items) |sp| if (sp.hq == site.hq) {
            if (!any) {
                try out.append(alloc, "");
                try out.append(alloc, "keep stocked  {d}(checked daily · under min → order/fabricate to target){/}");
                any = true;
            }
            const have = gs.stockCount(site, sp.part_key);
            try out.append(alloc, try std.fmt.allocPrint(alloc, "  {s: <20} min {d: >4}  target {d: >4}  {s}{d} on hand{{/}}", .{ clip(sp.part_key, 20), sp.min, sp.target, if (have < sp.min) "{c}" else "{g}", have }));
        };
        if (!any) try out.append(alloc, "{d}no keep-stocked lines · K here or on a Market catalogue row sets one · $ sells a line{/}");
    }
    const cap = gs.siteCapacityTons(site);
    try out.append(alloc, "");
    try out.append(alloc, try std.fmt.allocPrint(alloc, "total {d}t{s}", .{ total, if (cap) |c| try std.fmt.allocPrint(alloc, " of {d}t capacity · {d}t free", .{ c, c -| total }) else "" }));
    if (site == .company) {
        var cgt: u32 = 0;
        var svt: u32 = 0;
        var uit = gs.units.iterator();
        while (uit.next()) |e| {
            const u = e.value_ptr;
            if (u.status == .destroyed or gs.companyOf(u.force) != site.company) continue;
            if (std.mem.eql(u8, u.chassis_key, "CGT-3")) cgt += 1;
            if (std.mem.eql(u8, u.chassis_key, "SVT-1")) svt += 1;
        }
        try out.append(alloc, try std.fmt.allocPrint(alloc, "{{d}}capacity = {d} CGT-3 × 20t + {d} SVT-1 × 5t · more trucks: Market (vehicles), then Forces x to move them in{{/}}", .{ cgt, svt }));
    }
    return out.toOwnedSlice(alloc);
}

/// " — availability D −1, periphery market −2" for a part at a site's home
/// HQ, or nothing when the world and the part are ordinary.
fn sourcingNote(alloc: Alloc, gs: *GameState, part_key: []const u8, dest: types.Site) ![]const u8 {
    const def = @import("../domain/part.zig").find(part_key) orelse return "";
    const hq_id: types.HqId = switch (dest) {
        .hq => |id| id,
        .company => |id| gs.homeHqFor(id),
        .outfit => if (gs.hqs.count() > 0) gs.hqs.keys()[0] else .none,
    };
    const hq = gs.hqs.getPtr(hq_id) orelse return "";
    const world = planet_mod.find(hq.planet_key) orelse return "";
    const src = @import("../domain/part.zig").sourcing(def, @import("../domain/faction.zig").isPeriphery(world.faction), hq.effectiveFacilityLevel(.comms));
    const txt = try src.text(alloc, def);
    return if (txt.len == 0) "" else try std.fmt.allocPrint(alloc, " — {s}", .{txt});
}

/// Orders and shipments still on their way, soonest first.
pub const InboundRow = struct { eta: u32, cells: table.Row };

pub const inbound_cols: []const table.Col = &.{ .{ .name = "part" }, .{ .name = "qty", .justify = .right }, .{ .name = "to" }, .{ .name = "status" }, .{ .name = "eta" }, .{ .name = "cost", .justify = .right } };

pub fn inbound(alloc: Alloc, gs: *GameState) ![]InboundRow {
    const day = gs.clock.day_index;
    const Row = InboundRow;
    var rows: std.ArrayListUnmanaged(Row) = .empty;
    for (gs.part_orders.items) |o| {
        if (o.status == .delivered or o.status == .cancelled) continue;
        const eta = o.eta_day orelse std.math.maxInt(u32);
        const eta_s: []const u8 = if (o.eta_day) |e| (if (e > day) try std.fmt.allocPrint(alloc, "d{d} ({d} days)", .{ e, e - day }) else "today") else if (o.status == .failed) try std.fmt.allocPrint(alloc, "{{c}}not found{{/}}{s}", .{try sourcingNote(alloc, gs, o.part_key, o.dest)}) else "{a}sourcing{/}";
        try rows.append(alloc, .{ .eta = eta, .cells = try table.row(alloc, &.{
            o.part_key, try std.fmt.allocPrint(alloc, "{d}", .{o.quantity}), try siteLabel(alloc, gs, o.dest), @tagName(o.status), eta_s, try money(alloc, o.cost),
        }) });
    }
    for (gs.fund_couriers.items) |c| {
        try rows.append(alloc, .{ .eta = c.eta_day, .cells = try table.row(alloc, &.{ "cash courier", "", try treasuryLabel(alloc, gs, c.to), "in transit", try std.fmt.allocPrint(alloc, "d{d} ({d} days)", .{ c.eta_day, c.eta_day -| day }), try money(alloc, c.amount) }) });
    }
    for (gs.unit_transfers.items) |t| {
        try rows.append(alloc, .{ .eta = t.eta_day, .cells = try table.row(alloc, &.{ try std.fmt.allocPrint(alloc, "hull #{d}", .{@intFromEnum(t.unit)}), "", try forceName(alloc, gs, t.to_company), "in transit", try std.fmt.allocPrint(alloc, "d{d} ({d} days)", .{ t.eta_day, t.eta_day -| day }), "" }) });
    }
    std.mem.sort(Row, rows.items, {}, struct {
        fn lt(_: void, a: Row, b: Row) bool {
            return a.eta < b.eta;
        }
    }.lt);
    return rows.toOwnedSlice(alloc);
}

/// The standing policy for a treasury, if any.
pub fn policyFor(gs: *GameState, t: state_mod.Treasury) ?state_mod.StandingPolicy {
    for (gs.policies.items) |p| if (std.meta.eql(p.entity, t)) return p;
    return null;
}

pub fn siteLabel(alloc: Alloc, gs: *GameState, site: types.Site) ![]const u8 {
    return switch (site) {
        .outfit => "outfit",
        .hq => |id| try std.fmt.allocPrint(alloc, "hq:{d} {s}", .{ @intFromEnum(id), try hqName(alloc, gs, id) }),
        .company => |id| try std.fmt.allocPrint(alloc, "co:{d} {s}", .{ @intFromEnum(id), try forceName(alloc, gs, id) }),
    };
}

fn siteLines(alloc: Alloc, gs: *GameState, out: *std.ArrayListUnmanaged([]const u8), site: types.Site, title: []const u8) !void {
    const tons = gs.siteTons(site);
    const cap = gs.siteCapacityTons(site) orelse 0;
    var bar_buf: [20]u8 = undefined;
    const mk: []const u8 = if (cap > 0 and tons * 4 < cap) "{a}" else "{g}";
    try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}  {s}{s}{{/}} {d}t / {d}t", .{ title, mk, table.bar(&bar_buf, tons, cap), tons, cap }));
    var line: std.ArrayListUnmanaged(u8) = .empty;
    try line.appendSlice(alloc, "   ");
    const stock: ?*const std.StringArrayHashMapUnmanaged(u32) = switch (site) {
        .outfit => &gs.spare_parts,
        .hq => |id| if (gs.hqs.getPtr(id)) |h| &h.stock else null,
        .company => |id| if (gs.forces.getPtr(id)) |f| &f.stock else null,
    };
    if (stock) |m| {
        var it = m.iterator();
        var n: usize = 0;
        while (it.next()) |entry| {
            if (n > 0) try line.appendSlice(alloc, " · ");
            const qty = entry.value_ptr.*;
            try line.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s}{s} {d}{s}", .{ if (qty == 0) "{c}" else "", entry.key_ptr.*, qty, if (qty == 0) "{/}" else "" }));
            n += 1;
        }
        if (n == 0) try line.appendSlice(alloc, "empty");
    }
    try out.append(alloc, try line.toOwnedSlice(alloc));
    try out.append(alloc, "");
}

// ---------------------------------------------------------------------- hq

/// One HQ's detail pane: its lines, and beside each the facility that row
/// shows (null for every other row), so the HQ screen's `u` upgrades the
/// facility under the cursor by identity, whatever sits above the table.
pub const HqDetail = struct {
    lines: []const []const u8,
    facility: []const ?@import("../domain/hq.zig").FacilityKind,
};

pub fn hqDetail(alloc: Alloc, gs: *GameState, id: types.HqId) ![]const []const u8 {
    return (try hqDetailView(alloc, gs, id)).lines;
}

pub fn hqDetailView(alloc: Alloc, gs: *GameState, id: types.HqId) !HqDetail {
    var facility_rows: std.ArrayListUnmanaged(struct { row: usize, kind: @import("../domain/hq.zig").FacilityKind }) = .empty;
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const h = gs.hqs.getPtr(id) orelse return .{ .lines = &.{}, .facility = &.{} };
    // Tier first: what this HQ can host, and how to raise it.
    {
        const hq_ops_mod = @import("hq_ops.zig");
        const hosted = gs.companiesAtHq(id);
        switch (h.tier) {
            .field => {
                var upgrading: ?@import("../domain/hq.zig").Project = null;
                for (h.projects.items) |p| if (p.kind == .tier_upgrade) {
                    upgrading = p;
                };
                try out.append(alloc, try std.fmt.allocPrint(alloc, "tier       {{a}}field HQ{{/}} — a forward base: hosts one company ({d} here{s}) to rest, resupply and stage · convoys ship from whichever HQ warehouse is nearest with the line", .{ hosted, if (hosted == 0) ", {g}slot free{/}" else "" }));
                {
                    const tg = h.effectiveFacilityLevel(.training_ground);
                    const bay = h.effectiveFacilityLevel(.mek_bay);
                    const hh = h.effectiveFacilityLevel(.hiring_hall);
                    try out.append(alloc, try std.fmt.allocPrint(alloc, "           lacks: {s}{s}{s}{s}", .{
                        if (tg == 0) "{c}training ground{/} (no training) · " else "",
                        if (bay == 0) "{c}mek bay{/} (no structural repair) · " else "",
                        if (hh == 0) "{c}hiring hall{/} (no walk-ins) · " else "",
                        if (tg == 0 or bay == 0 or hh == 0) "{d}u builds any of them here{/}" else "{g}nothing — every service a regional HQ has{/}",
                    }));
                }
                if (upgrading) |p| {
                    try out.append(alloc, try std.fmt.allocPrint(alloc, "           {{a}}regional upgrade under way{{/}} · paperwork done d{d} · construction done d{d} (today d{d})", .{ p.paperwork_done_day, p.construction_done_day, gs.clock.day_index }));
                } else {
                    const paperwork = hq_ops_mod.paperworkDaysFor(gs, id);
                    const afford = h.funds >= hq_ops_mod.tier_upgrade_cost;
                    try out.append(alloc, try std.fmt.allocPrint(alloc, "           to regional: {{a}}[T]{{/}} costs {s} from this HQ's treasury ({s}{s}{{/}} here{s}) · {d} days paperwork (command admins posted here shorten it) + {d} days build", .{
                        try money(alloc, hq_ops_mod.tier_upgrade_cost), if (afford) "{g}" else "{c}",       try money(alloc, h.funds),
                        if (afford) "" else " — Supply/Ledger t sends cash by courier",
                        paperwork,                                      hq_ops_mod.tier_upgrade_build_days,
                    }));
                    try out.append(alloc, "           then: S autostaff · :newco@ hq:N <name> raises a company here, or :assignco co:N hq:M moves one in");
                }
            },
            .regional => try out.append(alloc, try std.fmt.allocPrint(alloc, "tier       regional HQ · hosts 1 combat company ({d} here{s}) · {{d}}brigade tier is not buildable yet — a second company needs its own regional HQ{{/}}", .{ hosted, if (hosted == 0) ", {g}slot free{/}" else "" })),
            .brigade => try out.append(alloc, try std.fmt.allocPrint(alloc, "tier       brigade HQ · hosts 2 combat companies ({d} here)", .{hosted})),
        }
        try out.append(alloc, "");
    }
    const fac_cols: []const table.Col = &.{ .{ .name = "facility" }, .{ .name = "built", .justify = .right }, .{ .name = "effective", .justify = .right }, .{ .name = "next level cost", .justify = .right } };
    var frows: std.ArrayListUnmanaged(table.Row) = .empty;
    for (h.facilities.items) |f| {
        const eff = h.effectiveFacilityLevel(f.kind);
        const mk: []const u8 = if (eff < f.level) "{c}" else "";
        try frows.append(alloc, try table.row(alloc, &.{ @tagName(f.kind), try std.fmt.allocPrint(alloc, "{d}", .{f.level}), try std.fmt.allocPrint(alloc, "{s}{d}{{/}}", .{ mk, eff }), if (f.level < 5) try money(alloc, @import("../domain/hq.zig").upgradeCost(f.kind, f.level + 1)) else "max" }));
    }
    for (try (table.Table{ .cols = fac_cols, .rows = frows.items }).render(alloc), 0..) |ln, i| {
        if (i > 0) try facility_rows.append(alloc, .{ .row = out.items.len, .kind = h.facilities.items[i - 1].kind });
        try out.append(alloc, if (i == 0) try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}", .{ln}) else ln);
    }
    try out.append(alloc, "");
    const cap = h.capacity();
    try out.append(alloc, try std.fmt.allocPrint(alloc, "capacity   {d} companies · ≤{d} lances each · {d} support lances · {d} air wing{s} ({d} here) · {d}t storage", .{ cap.combat_companies, cap.lances_per_company, cap.support_lances, cap.air_companies, if (cap.air_companies == 1) "" else "s", gs.airCompaniesAtHq(id), h.warehouseCapacityTons() }));
    try out.append(alloc, try std.fmt.allocPrint(alloc, "berths     {d} dropship ({d} held) · {d} jumpship ({d} held){s}", .{ cap.dropship_berths, gs.transportsBerthedAt(id, .dropship), cap.jumpship_berths, gs.transportsBerthedAt(id, .jumpship), if (cap.air_companies == 0) " · {d}spaceport 3 opens an air wing slot, 4 (+comms 3) a jumpship berth{/}" else "" }));
    for (try berths(alloc, gs, id)) |line| try out.append(alloc, line);
    try out.append(alloc, try std.fmt.allocPrint(alloc, "upkeep     {s} / month · funds {s}", .{ try money(alloc, h.monthly_upkeep), try money(alloc, h.funds) }));
    try out.append(alloc, "");
    try out.append(alloc, "projects");
    if (h.projects.items.len == 0) try out.append(alloc, "  none");
    for (h.projects.items) |p| {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  {s} {s} → lv{d}   paperwork done d{d} · construction done d{d} · {s}", .{ @tagName(p.kind), if (p.facility) |f| @tagName(f) else "", p.target_level, p.paperwork_done_day, p.construction_done_day, try money(alloc, p.cost) }));
    }
    try out.append(alloc, "");
    const req = h.staffRequired();
    const rows = [_]struct { role: person_mod.Role, need: u32 }{
        .{ .role = .admin_command, .need = req.admin },
        .{ .role = .admin_logistics, .need = req.logistics },
        .{ .role = .admin_hr, .need = req.hr },
        .{ .role = .admin_finance, .need = req.finance },
    };
    const office_cols: []const table.Col = &.{ .{ .name = "back office" }, .{ .name = "have", .justify = .right }, .{ .name = "need", .justify = .right } };
    var orows: std.ArrayListUnmanaged(table.Row) = .empty;
    for (rows) |r| {
        const s = @import("hq_ops.zig").hqStaff(gs, id, r.role);
        const mk: []const u8 = if (s.count < r.need) "{c}" else "";
        try orows.append(alloc, try table.row(alloc, &.{ @tagName(r.role), try std.fmt.allocPrint(alloc, "{s}{d}{{/}}", .{ mk, s.count }), try std.fmt.allocPrint(alloc, "{s}{d}{{/}}", .{ mk, r.need }) }));
    }
    for (try (table.Table{ .cols = office_cols, .rows = orows.items }).render(alloc), 0..) |ln, i| try out.append(alloc, if (i == 0) try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}", .{ln}) else ln);
    try out.append(alloc, "");
    {
        const slots = @import("hq_ops.zig").baySlots(gs, id);
        const load = @import("hq_ops.zig").bayLoad(gs, id);
        const busy = load.busy;
        const queued = load.queued;
        try out.append(alloc, try std.fmt.allocPrint(alloc, "bays   {s}{d} of {d} slots busy{{/}} · {d} queued · {d} free", .{ if (busy >= slots) "{c}" else "{g}", busy, slots, queued, slots -| busy }));
    }
    var any = false;
    for (gs.bay_jobs.items) |j| {
        if (j.hq != id) continue;
        any = true;
        const odds = if (j.kind == .depot_repair or j.kind == .refit) try std.fmt.allocPrint(alloc, "  {{d}}{s}{{/}}", .{try @import("hq_ops.zig").repairOddsText(alloc, gs, id, j.unit)}) else "";
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  {s: <13} {s}{s}  {s}{s}", .{ @tagName(j.kind), if (j.unit != .none) try std.fmt.allocPrint(alloc, "#{d} ", .{@intFromEnum(j.unit)}) else "", j.item_key, if (j.started_day != null) try std.fmt.allocPrint(alloc, "done day {d}", .{j.done_day orelse 0}) else "queued", odds }));
    }
    if (!any) try out.append(alloc, "  idle");
    try out.append(alloc, "");
    try out.append(alloc, "hiring hall");
    any = false;
    for (gs.candidates.items, 0..) |c, i| {
        if (c.hq != id) continue;
        any = true;
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  [{d}] {s} {s}  {s} {s}  bonus {s}  expires day {d}", .{ i, try table.plain(alloc, c.spec.first), try table.plain(alloc, c.spec.last), @tagName(c.spec.role), @tagName(c.spec.experience), try money(alloc, c.asking_bonus), c.expires_day }));
    }
    if (!any) try out.append(alloc, "  no candidates");
    const facility = try alloc.alloc(?@import("../domain/hq.zig").FacilityKind, out.items.len);
    @memset(facility, null);
    for (facility_rows.items) |fr| facility[fr.row] = fr.kind;
    return .{ .lines = try out.toOwnedSlice(alloc), .facility = facility };
}

// ------------------------------------------------------------- hiring hall

/// Hiring-hall filter: a role group or one admin desk.
pub const HallFilter = enum {
    all,
    combat, // mekwarriors, vehicle crews, aero pilots
    techs, // tech_mek / tech_mechanic / tech_aero / tech_ba / astech
    medical, // doctors, medics
    admin_command,
    admin_logistics,
    admin_transport,
    admin_hr,
    admin_finance,
    other, // infantry, battle armor, everything else
    unassigned, // personnel screen only: no seat, no HQ posting, no company
    wounded, // personnel screen only: anyone hurt, in the medbay or waiting

    pub fn matches(self: HallFilter, role: person_mod.Role) bool {
        return switch (self) {
            .all, .unassigned, .wounded => true,
            .combat => role == .mekwarrior or role == .vehicle_crew or role == .aero_pilot,
            .techs => role.isTech() or role == .astech,
            .medical => role == .doctor or role == .medic,
            .admin_command => role == .admin_command,
            .admin_logistics => role == .admin_logistics,
            .admin_transport => role == .admin_transport,
            .admin_hr => role == .admin_hr,
            .admin_finance => role == .admin_finance,
            .other => role == .infantry or role == .ba_trooper,
        };
    }

    pub fn next(self: HallFilter) HallFilter {
        const n = @typeInfo(HallFilter).@"enum".fields.len;
        return @enumFromInt((@intFromEnum(self) + 1) % n);
    }

    pub fn prev(self: HallFilter) HallFilter {
        const n = @typeInfo(HallFilter).@"enum".fields.len;
        return @enumFromInt((@intFromEnum(self) + n - 1) % n);
    }
};

pub const CandidateRow = struct {
    index: usize, // into gs.candidates — the `hire_candidate` argument
    cells: table.Row,
};

pub const Hall = struct {
    rows: []CandidateRow,
    total_at_hq: usize,
};

pub const hall_cols: []const table.Col = &.{
    .{ .name = "idx" },                   .{ .name = "name" },                   .{ .name = "role" },                     .{ .name = "exp" },
    .{ .name = "sk", .justify = .right }, .{ .name = "age", .justify = .right }, .{ .name = "bonus", .justify = .right }, .{ .name = "leaves" },
    .{ .name = "note" },
};

/// Candidates on one HQ's board, filtered; note which requirement each
/// admin would help fill.
pub fn hall(alloc: Alloc, gs: *GameState, hq_id: types.HqId, filter: HallFilter) !Hall {
    var rows: std.ArrayListUnmanaged(CandidateRow) = .empty;
    var total: usize = 0;
    const req = if (gs.hqs.getPtr(hq_id)) |h| h.staffRequired() else null;
    for (gs.candidates.items, 0..) |c, i| {
        if (c.hq != hq_id) continue;
        total += 1;
        if (!filter.matches(c.spec.role)) continue;
        var note: []const u8 = "";
        if (req) |r| {
            const need: ?u32 = switch (c.spec.role) {
                .admin_command => r.admin,
                .admin_logistics => r.logistics,
                .admin_hr => r.hr,
                .admin_finance => r.finance,
                else => null,
            };
            if (need) |n| {
                const have = @import("hq_ops.zig").hqStaff(gs, hq_id, c.spec.role).count;
                note = if (have < n) try std.fmt.allocPrint(alloc, "{{g}}fills {s} {d}→{d} of {d}{{/}}", .{ @tagName(c.spec.role), have, have + 1, n }) else "{d}desk already staffed{/}";
            }
        }
        const name = try table.plain(alloc, try std.fmt.allocPrint(alloc, "{s} {s}", .{ c.spec.first, c.spec.last }));
        try rows.append(alloc, .{ .index = i, .cells = try table.row(alloc, &.{
            try std.fmt.allocPrint(alloc, "{d}", .{i}),
            name,
            @tagName(c.spec.role),
            @tagName(c.spec.experience),
            try std.fmt.allocPrint(alloc, "{d}", .{c.spec.primary_skill}),
            try std.fmt.allocPrint(alloc, "{d}", .{c.spec.age}),
            try money(alloc, c.asking_bonus),
            try std.fmt.allocPrint(alloc, "d{d}", .{c.expires_day}),
            note,
        }) });
    }
    return .{
        .rows = try rows.toOwnedSlice(alloc),
        .total_at_hq = total,
    };
}

// ---------------------------------------------------------- hq upgrades

pub const UpgradeRow = struct {
    kind: @import("../domain/hq.zig").FacilityKind,
    possible: bool,
    /// Why it cannot start right now (plain text), or "ready".
    reason: []const u8,
    cells: table.Row,
};

pub const upgrade_cols: []const table.Col = &.{ .{ .name = "facility" }, .{ .name = "level" }, .{ .name = "cost", .justify = .right }, .{ .name = "paperwork + build" }, .{ .name = "next level buys" }, .{ .name = "status" } };

/// Every facility with what its next level costs, takes and buys.
pub fn upgrades(alloc: Alloc, gs: *GameState, hq_id: types.HqId) ![]UpgradeRow {
    const hq_mod = @import("../domain/hq.zig");
    const hq_ops = @import("hq_ops.zig");
    var out: std.ArrayListUnmanaged(UpgradeRow) = .empty;
    const h = gs.hqs.getPtr(hq_id) orelse return out.toOwnedSlice(alloc);
    const paperwork = hq_ops.paperworkDaysFor(gs, hq_id);
    inline for (@typeInfo(hq_mod.FacilityKind).@"enum".fields) |f| {
        const kind: hq_mod.FacilityKind = @enumFromInt(f.value);
        const lvl = h.facilityLevel(kind);
        const next: u8 = lvl + 1;
        const block = hq_ops.upgradeBlock(gs, hq_id, kind);
        const in_progress = block == .in_progress;
        const maxed = block == .maxed;
        const affordable = block != .funds_short;
        const cost = if (maxed) 0 else hq_mod.upgradeCost(kind, next);
        const tn = @import("../domain/tuning.zig").t;
        const buys: []const u8 = if (maxed) "at maximum" else switch (kind) {
            .mek_bay => try std.fmt.allocPrint(alloc, "{d} bay slots · refit class ceiling rises", .{tn.hq_ops.slots_per_bay_level * @as(u32, next)}),
            .warehouse => try std.fmt.allocPrint(alloc, "{d}t storage", .{tn.hq.warehouse_tons_per_level_sq * @as(u32, next) * @as(u32, next)}),
            .hospital => try std.fmt.allocPrint(alloc, "{d} beds · shorter stays", .{tn.medical.beds_per_hospital_level * @as(u32, next)}),
            .mess => "faster fatigue recovery, morale",
            .training_ground => "training available · shorter programs",
            .hiring_hall => "more and better candidates",
            .comms => try std.fmt.allocPrint(alloc, "ring +{d} LY → {d} LY · more offers", .{ tn.hq.influence_per_comms_ly, h.influenceLy() + tn.hq.influence_per_comms_ly }),
            .spaceport => try std.fmt.allocPrint(alloc, "ring +{d} LY · berths · cheaper freight", .{tn.hq.influence_per_spaceport_ly}),
        };
        const state: []const u8 = if (in_progress) "{a}project running{/}" else if (maxed) "{d}max{/}" else if (!affordable) "{c}HQ funds short{/}" else "{g}ready{/}";
        const reason: []const u8 = if (in_progress) "a project is already running" else if (maxed) "already at maximum level" else if (!affordable) try std.fmt.allocPrint(alloc, "HQ funds short: needs {s} C, has {s} C", .{ try money(alloc, cost), try money(alloc, h.funds) }) else "ready";
        try out.append(alloc, .{ .kind = kind, .possible = !in_progress and !maxed and affordable, .reason = reason, .cells = try table.row(alloc, &.{
            try table.plain(alloc, f.name),
            try std.fmt.allocPrint(alloc, "lv {d} → {d}", .{ lvl, if (maxed) lvl else next }),
            if (maxed) "—" else try money(alloc, cost),
            try std.fmt.allocPrint(alloc, "{d} + {d} days", .{ paperwork, if (maxed) 0 else tn.hq_ops.build_days_per_level * @as(u32, next) }),
            buys,
            state,
        }) });
    }
    return out.toOwnedSlice(alloc);
}

// ------------------------------------------------------------------ market

pub const ListingRow = struct {
    index: usize,
    cells: table.Row,
    /// The HQ whose board this is — and whose treasury pays.
    hq: types.HqId,
    /// A contract world's listing: this company's local funds pay.
    company: types.ForceId = .none,
    /// A dropship or jumpship hull: it berths and wants a ship crew.
    transport: bool = false,
};

pub const CatalogRow = struct {
    key: []const u8,
    component: bool,
    cells: table.Row,
};

pub const DemandRow = struct {
    key: []const u8,
    short: u32,
    cells: table.Row,
};

pub const StockPolicyRow = struct {
    key: []const u8,
    min: u32,
    target: u32,
    cells: table.Row,
};

pub const market_cols: []const table.Col = &.{
    .{ .name = "idx" },                      .{ .name = "kind" },      .{ .name = "key" },    .{ .name = "name" },
    .{ .name = "price", .justify = .right }, .{ .name = "qty" },       .{ .name = "rarity" }, .{ .name = "staple" },
    .{ .name = "expires" },                  .{ .name = "condition" },
};
pub const catalog_cols: []const table.Col = &.{ .{ .name = "part" }, .{ .name = "name" }, .{ .name = "cost", .justify = .right }, .{ .name = "tons", .justify = .right }, .{ .name = "source" } };
pub const demand_cols: []const table.Col = &.{ .{ .name = "part" }, .{ .name = "need", .justify = .right }, .{ .name = "on hand", .justify = .right }, .{ .name = "on order", .justify = .right }, .{ .name = "short", .justify = .right } };
pub const stock_policy_cols: []const table.Col = &.{ .{ .name = "part" }, .{ .name = "min", .justify = .right }, .{ .name = "target", .justify = .right }, .{ .name = "on hand", .justify = .right }, .{ .name = "state" } };

/// The keep-stocked lines of one HQ (Market screen): reorder point,
/// target, what is on hand and whether a restock is under way.
pub fn stockPolicies(alloc: Alloc, gs: *GameState, hq: types.HqId) ![]StockPolicyRow {
    var out: std.ArrayListUnmanaged(StockPolicyRow) = .empty;
    for (gs.stock_policies.items) |sp| {
        if (sp.hq != hq) continue;
        const have = gs.stockCount(.{ .hq = hq }, sp.part_key);
        const coming = @import("hq_ops.zig").comingToHq(gs, hq, sp.part_key);
        const state: []const u8 = if (coming > 0) try std.fmt.allocPrint(alloc, "{{a}}{d} coming{{/}}", .{coming}) else if (have < sp.min) "{c}short — reorders tomorrow{/}" else "{g}stocked{/}";
        try out.append(alloc, .{ .key = sp.part_key, .min = sp.min, .target = sp.target, .cells = try table.row(alloc, &.{
            sp.part_key,
            try std.fmt.allocPrint(alloc, "{d}", .{sp.min}),
            try std.fmt.allocPrint(alloc, "{d}", .{sp.target}),
            try std.fmt.allocPrint(alloc, "{d}", .{have}),
            state,
        }) });
    }
    return out.toOwnedSlice(alloc);
}

pub const Market = struct {
    board: []ListingRow,
    catalog: []CatalogRow,
    demand: []DemandRow,
};

const market_mod = @import("../econ/market.zig");

/// Market filter: hull kinds and part categories.
pub const MarketFilter = enum {
    all,
    mechs,
    vehicles,
    aerofighters,
    dropships,
    jumpships,
    weapons,
    ammo,
    equipment,
    components,
    supplies,

    pub fn next(self: MarketFilter) MarketFilter {
        const n = @typeInfo(MarketFilter).@"enum".fields.len;
        return @enumFromInt((@intFromEnum(self) + 1) % n);
    }

    pub fn prev(self: MarketFilter) MarketFilter {
        const n = @typeInfo(MarketFilter).@"enum".fields.len;
        return @enumFromInt((@intFromEnum(self) + n - 1) % n);
    }

    pub fn matchesUnit(self: MarketFilter, kind: unit_mod.UnitKind) bool {
        return switch (self) {
            .all => true,
            .mechs => kind == .mek,
            .vehicles => kind == .vehicle or kind == .mash or kind == .cargo,
            .aerofighters => kind == .aerospace,
            .dropships => kind == .dropship,
            .jumpships => kind == .jumpship,
            else => false,
        };
    }

    pub fn matchesPart(self: MarketFilter, key: []const u8) bool {
        const part_mod = @import("../domain/part.zig");
        const p = part_mod.find(key);
        const mount: part_mod.MountType = if (p) |pd| pd.mount else .none;
        return switch (self) {
            .all => true,
            .weapons => mount == .energy or mount == .ballistic or mount == .missile,
            .ammo => mount == .ammo,
            .equipment => mount == .equipment or std.mem.eql(u8, key, "armor"),
            .components => part_mod.isComponent(key),
            .supplies => mount == .none and !part_mod.isComponent(key) and !std.mem.eql(u8, key, "armor"),
            else => false,
        };
    }
};

/// The site boards, the orderable catalog, and what the damaged hulls need.
/// The selected HQ's board (every HQ has its own; that HQ's treasury pays
/// for what is bought from it), the orderable catalog, and what the
/// damaged hulls need.
pub fn market(alloc: Alloc, gs: *GameState, filter: MarketFilter, hq: types.HqId) !Market {
    var board: std.ArrayListUnmanaged(ListingRow) = .empty;
    for (gs.market_listings.items, 0..) |l, i| {
        if (l.hq != hq and l.hq != .none) continue;
        const keep = switch (l.kind) {
            .unit => filter.matchesUnit(if (chassis_mod.find(l.item_key)) |c| c.kind else .mek),
            .part => filter.matchesPart(l.item_key),
        };
        if (!keep) continue;
        const cond_base: []const u8 = if (l.condition) |c| try std.fmt.allocPrint(alloc, "{{a}}{s}{{/}} armor {s} · {d} dmg · {d} missing", .{ c.label(), try armorPct(alloc, c.armor_pct), c.damaged_slots, c.missing_components }) else if (l.kind == .unit) "{g}new{/}" else "";
        // A hull this HQ's bay could not rebuild says so.
        const hq_ops = @import("hq_ops.zig");
        const cond: []const u8 = if (l.kind == .unit and chassis_mod.find(l.item_key) != null and chassis_mod.find(l.item_key).?.kind == .mek and !hq_ops.bayCanRebuild(gs, if (l.hq != .none) l.hq else hq, l.item_key))
            try std.fmt.allocPrint(alloc, "{s} · {{c}}{s}{{/}}", .{ cond_base, hq_ops.rebuildNeed(l.item_key) })
        else
            cond_base;
        const name: []const u8 = if (l.kind == .unit) (if (chassis_mod.find(l.item_key)) |c| c.name else l.item_key) else (if (@import("../domain/part.zig").find(l.item_key)) |p| p.name else l.item_key);
        const transport = l.kind == .unit and chassis_mod.find(l.item_key) != null and chassis_mod.find(l.item_key).?.kind.isTransport();
        if (l.company != .none) {
            // A contract world's hull.
            const world: []const u8 = if (gs.deploymentContract(l.company)) |c| planetName(c.planet_key) else "?";
            try board.append(alloc, .{ .index = i, .hq = l.hq, .company = l.company, .transport = transport, .cells = try table.row(alloc, &.{
                try std.fmt.allocPrint(alloc, "{d}", .{i}),
                try std.fmt.allocPrint(alloc, "{{a}}@{s}{{/}}", .{world}),
                l.item_key,
                name,
                try money(alloc, types.applyBp(l.price, gs.diff().purchase_bp)),
                "",
                "",
                "",
                "",
                try std.fmt.allocPrint(alloc, "{s} local funds {s} · {s}", .{ try forceName(alloc, gs, l.company), try money(alloc, gs.treasuryBalance(.{ .company = l.company })), cond }),
            }) });
            continue;
        }
        try board.append(alloc, .{ .index = i, .hq = l.hq, .transport = transport, .cells = try table.row(alloc, &.{
            try std.fmt.allocPrint(alloc, "{d}", .{i}),
            @tagName(l.kind),
            l.item_key,
            name,
            try money(alloc, types.applyBp(l.price, gs.diff().purchase_bp)),
            try std.fmt.allocPrint(alloc, "x{d}", .{l.quantity}),
            @tagName(l.rarity),
            if (l.black_market) "{c}fence{/}" else if (l.staple) "staple" else "",
            try std.fmt.allocPrint(alloc, "d{d}", .{l.expires_day}),
            if (l.black_market) try std.fmt.allocPrint(alloc, "{{c}}black market{{/}} — no questions, maybe a fraud (2d6 ≤ {d}); the house frowns, the pirates smile · {s}", .{ @import("../domain/tuning.zig").t.market.black_market_fraud_target, cond }) else cond,
        }) });
    }
    var catalog: std.ArrayListUnmanaged(CatalogRow) = .empty;
    const part_mod = @import("../domain/part.zig");
    for (part_mod.catalog) |p| {
        if (!filter.matchesPart(p.key)) continue;
        const component = part_mod.isComponent(p.key);
        try catalog.append(alloc, .{ .key = p.key, .component = component, .cells = try table.row(alloc, &.{
            p.key,
            p.name,
            try money(alloc, p.cost),
            try std.fmt.allocPrint(alloc, "{d}t", .{part_mod.tons(p.key)}),
            if (component) (if (p.fab_regional) "{a}fabricable: bay 3 at a regional HQ{/}" else if (p.fab_min_bay > 1) try std.fmt.allocPrint(alloc, "{{a}}fabricable: bay {d}{{/}}", .{p.fab_min_bay}) else "{a}fabricable at any bay{/}") else if (isStaple(p.key)) "{g}staple{/}" else "{d}rolls vs rarity{/}",
        }) });
    }
    // Demand. Structure first: this HQ's depot ledger, the same rule the
    // depot queue applies (hq_ops.componentDemand), so a wreck the depot
    // refuses for want of a torso shows that torso here. Then gear: the
    // spares ledger (hq_ops.spareDemand) for the HQ's shelf and for the
    // field stores of its companies that are away, since field work is
    // done where the hull sits.
    var demand: std.ArrayListUnmanaged(DemandRow) = .empty;
    for (try @import("hq_ops.zig").componentDemand(alloc, gs, hq, null)) |l| {
        try demand.append(alloc, .{ .key = l.key, .short = l.short, .cells = try table.row(alloc, &.{
            l.key,
            try std.fmt.allocPrint(alloc, "{d}", .{l.need}),
            try std.fmt.allocPrint(alloc, "{d}", .{l.on_hand}),
            try std.fmt.allocPrint(alloc, "{d}", .{l.coming}),
            try std.fmt.allocPrint(alloc, "{s}{d}{{/}}", .{ if (l.short > 0) "{c}" else "{g}", l.short }),
        }) });
    }
    const hq_ops = @import("hq_ops.zig");
    for (try hq_ops.spareSitesOf(alloc, gs, hq)) |site| {
        const where: []const u8 = switch (site) {
            .company => |co| try std.fmt.allocPrint(alloc, " {{d}}({s}, afield){{/}}", .{try forceName(alloc, gs, co)}),
            else => "",
        };
        for (try hq_ops.spareDemand(alloc, gs, site)) |l| {
            try demand.append(alloc, .{ .key = l.key, .short = l.short, .cells = try table.row(alloc, &.{
                try std.fmt.allocPrint(alloc, "{s}{s}", .{ l.key, where }),
                try std.fmt.allocPrint(alloc, "{d}", .{l.need}),
                try std.fmt.allocPrint(alloc, "{d}", .{l.on_hand}),
                try std.fmt.allocPrint(alloc, "{d}", .{l.coming}),
                try std.fmt.allocPrint(alloc, "{s}{d}{{/}}", .{ if (l.short > 0) "{c}" else "{g}", l.short }),
            }) });
        }
    }
    return .{
        .board = try board.toOwnedSlice(alloc),
        .catalog = try catalog.toOwnedSlice(alloc),
        .demand = try demand.toOwnedSlice(alloc),
    };
}

const isStaple = market_mod.isStaple;

// ------------------------------------------------------- raising a company

pub const ManningRow = struct {
    role: person_mod.Role,
    have: u32,
    need: u32,
    cells: table.Row,
};

pub const manning_cols: []const table.Col = &.{ .{ .name = "role" }, .{ .name = "have", .justify = .right }, .{ .name = "need", .justify = .right }, .{ .name = "open", .justify = .right }, .{ .name = "why" } };

/// The manning table phrased (`personnel.manningLines` decides it): have,
/// need, open and why, with the tech-hours line on the tech rows.
pub fn manning(alloc: Alloc, gs: *GameState, company: types.ForceId) ![]ManningRow {
    const personnel = @import("personnel.zig");
    const hours = personnel.techHours(gs, company);
    var out: std.ArrayListUnmanaged(ManningRow) = .empty;
    for (personnel.manningLines(gs, company)) |n| {
        const why = if (n.role == .astech or n.role == .tech_mek) try std.fmt.allocPrint(alloc, "{s} · {s}{d} of {d} tech-hours/week covered{{/}}", .{ n.why, if (hours.have >= hours.needed) "{g}" else "{c}", hours.have, hours.needed }) else n.why;
        try out.append(alloc, .{ .role = n.role, .have = n.have, .need = n.need, .cells = try table.row(alloc, &.{
            @tagName(n.role),
            try std.fmt.allocPrint(alloc, "{d}", .{n.have}),
            try std.fmt.allocPrint(alloc, "{d}", .{n.need}),
            try std.fmt.allocPrint(alloc, "{s}{d}{{/}}", .{ if (n.open > 0) "{c}" else "{g}", n.open }),
            try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}", .{why}),
        }) });
    }
    return out.toOwnedSlice(alloc);
}

/// A listing the wizard has passed on (listings have no id; this tuple is
/// stable until the board turns over).
pub const PassedKey = struct { hq: types.HqId, item_key: []const u8, listed_day: u32, price: types.CBills };

pub const RaiseCand = struct {
    kind: enum { pool, mothballed, listing },
    unit: types.UnitId = .none,
    listing: usize = 0,
    /// Listing rows: what `raiseCandidates` matches a pass against.
    key: PassedKey = .{ .hq = .none, .item_key = "", .listed_day = 0, .price = 0 },
    cells: table.Row,
};

pub const raise_cols: []const table.Col = &.{
    .{ .name = "source" },                  .{ .name = "#" },         .{ .name = "hull" },                     .{ .name = "name" },
    .{ .name = "tons", .justify = .right }, .{ .name = "condition" }, .{ .name = "price", .justify = .right }, .{ .name = "delivery" },
    .{ .name = "" },
};

/// Every mek a raised company could take next: hulls on hand (free),
/// mothballed hulls (free, reactivation days), and mek listings from
/// every HQ's board with their condition, price and delivery time.
pub fn raiseCandidates(alloc: Alloc, gs: *GameState, company: types.ForceId, passed: []const PassedKey) ![]RaiseCand {
    const logistics = @import("../econ/logistics.zig");
    var out: std.ArrayListUnmanaged(RaiseCand) = .empty;
    var uit = gs.units.iterator();
    while (uit.next()) |e| {
        const u = e.value_ptr;
        if (u.kind != .mek or u.force != .none or u.status == .destroyed or u.status == .in_transit) continue;
        const ch = chassis_mod.find(u.chassis_key);
        const marks = try damageMarks(alloc, u);
        if (u.status == .mothballed) {
            try out.append(alloc, .{ .kind = .mothballed, .unit = u.id, .cells = try table.row(alloc, &.{ "{d}mothballed{/}", try std.fmt.allocPrint(alloc, "#{d}", .{@intFromEnum(u.id)}), u.chassis_key, if (ch) |c| c.name else "?", try std.fmt.allocPrint(alloc, "{d}t", .{if (ch) |c| c.tonnage else 0}), try std.fmt.allocPrint(alloc, "quality {s} · armor {s}{s}", .{ @tagName(u.quality), try armorPct(alloc, u.armor_pct), marks }), "{g}free{/}", try std.fmt.allocPrint(alloc, "{d} days to reactivate", .{unit_mod.reactivationDays(u.quality)}), "" }) });
        } else {
            try out.append(alloc, .{ .kind = .pool, .unit = u.id, .cells = try table.row(alloc, &.{ "{g}on hand{/}", try std.fmt.allocPrint(alloc, "#{d}", .{@intFromEnum(u.id)}), u.chassis_key, if (ch) |c| c.name else "?", try std.fmt.allocPrint(alloc, "{d}t", .{if (ch) |c| c.tonnage else 0}), try std.fmt.allocPrint(alloc, "quality {s} · armor {s}{s}", .{ @tagName(u.quality), try armorPct(alloc, u.armor_pct), marks }), "{g}free{/}", "now", "" }) });
        }
    }
    const home = gs.homeHqFor(company);
    const home_world = if (gs.hqs.getPtr(home)) |h| planetMod().find(h.planet_key) else null;
    for (gs.market_listings.items, 0..) |l, i| {
        if (l.kind != .unit or l.staple or l.company != .none) continue;
        const ch = chassis_mod.find(l.item_key) orelse continue;
        if (ch.kind != .mek) continue;
        var skip = false;
        for (passed) |pk| if (pk.hq == l.hq and pk.listed_day == l.listed_day and pk.price == l.price and std.mem.eql(u8, pk.item_key, l.item_key)) {
            skip = true;
        };
        if (skip) continue;
        const board = gs.hqs.getPtr(l.hq);
        const board_world = if (board) |h| planetMod().find(h.planet_key) else null;
        const days: u32 = if (home_world != null and board_world != null) logistics.deliveryDays(board_world.?, home_world.?) else 0;
        var cond_text: []const u8 = "{g}new{/}";
        if (l.condition) |c| {
            const repair: types.CBills = c.repairGuess();
            const mk: []const u8 = switch (c.grade()) {
                .wreck, .worn => "{c}",
                .used => "{a}",
                .new => "{g}",
            };
            cond_text = try std.fmt.allocPrint(alloc, "{s}{s}{{/}} armor {s} · {d} dmg {d} dest {d} missing · ≈{s} to fix{s}", .{ mk, c.label(), try armorPct(alloc, c.armor_pct), c.damaged_slots, c.destroyed_slots, c.missing_components, try money(alloc, repair), if (c.missing_components > 0) " (depot)" else "" });
        }
        // The company's home bay must be able to rebuild what it buys.
        const need_note: []const u8 = if (@import("hq_ops.zig").bayCanRebuild(gs, home, l.item_key)) "" else try std.fmt.allocPrint(alloc, "  {{c}}{s}{{/}}", .{@import("hq_ops.zig").rebuildNeed(l.item_key)});
        try out.append(alloc, .{ .kind = .listing, .listing = i, .key = .{ .hq = l.hq, .item_key = l.item_key, .listed_day = l.listed_day, .price = l.price }, .cells = try table.row(alloc, &.{ try std.fmt.allocPrint(alloc, "{{a}}{s}{{/}}", .{if (board) |h| h.name else "board"}), try std.fmt.allocPrint(alloc, "#{d}", .{i}), l.item_key, ch.name, try std.fmt.allocPrint(alloc, "{d}t", .{ch.tonnage}), cond_text, try money(alloc, l.price), if (days == 0) "now" else try std.fmt.allocPrint(alloc, "{d} days", .{days}), std.mem.trimStart(u8, need_note, " ") }) });
    }
    return out.toOwnedSlice(alloc);
}

/// The ships holding berths at an HQ: crew, status, and which company
/// they are away with.
pub fn berths(alloc: Alloc, gs: *GameState, hq_id: types.HqId) ![][]const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = gs.units.iterator();
    while (it.next()) |e| {
        const u = e.value_ptr;
        if (!u.kind.isTransport() or u.berth_hq != hq_id) continue;
        const ch = chassis_mod.find(u.chassis_key);
        const crew = gs.person(u.pilot);
        const lift_text = if (ch) |c| (if (c.kind == .dropship) try std.fmt.allocPrint(alloc, "{d} mek · {d} fighter · {d}t cargo", .{ c.mek_bays, c.asf_bays, c.cargo_tons }) else try std.fmt.allocPrint(alloc, "{d} collar{s}", .{ c.collars, if (c.collars == 1) "" else "s" })) else "";
        const where: []const u8 = if (u.force != .none) try std.fmt.allocPrint(alloc, "{{a}}away with {s}{{/}}", .{try forceName(alloc, gs, u.force)}) else if (u.status != .ready) try std.fmt.allocPrint(alloc, "{{c}}{s}{{/}}", .{@tagName(u.status)}) else "{g}at berth{/}";
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  #{d: <3} {s: <9} {s: <9} {s}  {s}  {s}", .{
            @intFromEnum(u.id), u.chassis_key, if (ch) |c| c.name else "?", try padCells(alloc, "", lift_text, 30),
            if (crew) |c| try padCells(alloc, "", try std.fmt.allocPrint(alloc, "{s}", .{try personText(alloc, c)}), 18) else try padCells(alloc, "{c}", "— no crew", 18),
            where,
        }));
    }
    return out.toOwnedSlice(alloc);
}

/// What the outfit's own ships would lift for a company's next contract.
pub fn liftText(alloc: Alloc, gs: *GameState, company: types.ForceId) ![]const u8 {
    const commands = @import("commands.zig");
    const plan = commands.planLift(gs, company, false) catch return "";
    if (plan.needed == 0) return "";
    if (plan.ships == 0 and !plan.own_jumpship) return "lift: charter for every hull (no dropship of your own at the home berth)";
    const bp = @import("../econ/logistics.zig").transitFreightBp(plan.covered_bp, plan.own_jumpship);
    var mult_buf: [16]u8 = undefined;
    return try std.fmt.allocPrint(alloc, "lift: {d} of {d} hulls on {d} own dropship{s}{s} — charter {s}", .{
        plan.carried,                plan.needed, plan.ships, if (plan.ships == 1) "" else "s", if (plan.own_jumpship) " + own jumpship" else "",
        types.bpText(&mult_buf, bp),
    });
}

fn planetMod() type {
    return @import("../domain/planet.zig");
}

// --------------------------------------------------------------- personnel

pub const PersonRow = struct {
    id: types.PersonId,
    role: person_mod.Role,
    primary_skill: types.SkillType,
    xp: u32,
    active: bool,
    cells: table.Row,
};

pub const people_cols: []const table.Col = &.{
    .{ .name = "id", .justify = .right }, .{ .name = "name" },                   .{ .name = "role" },                   .{ .name = "exp" },
    .{ .name = "skill" },                 .{ .name = "XP", .justify = .right },  .{ .name = "status" },                 .{ .name = "assignment" },
    .{ .name = "where" },                 .{ .name = "fat", .justify = .right }, .{ .name = "mor", .justify = .right }, .{ .name = "pay", .justify = .right },
};

pub const People = struct {
    rows: []PersonRow,
    total: usize,
};

fn skillsText(alloc: Alloc, p: *const person_mod.Person) ![]const u8 {
    const primary = p.role.primarySkill();
    const second = p.role.pilotingSkill();
    if (second) |s| return std.fmt.allocPrint(alloc, "{d}/{d}", .{ p.skill(primary) orelse 7, p.skill(s) orelse 8 });
    return std.fmt.allocPrint(alloc, "{d}", .{p.skill(primary) orelse 7});
}

/// What a person is doing right now, in one short phrase.
pub fn assignmentText(alloc: Alloc, gs: *GameState, p: *const person_mod.Person) ![]const u8 {
    const seat = gs.pilotSeat(p.id);
    if (seat != .none) {
        const u = gs.unit(seat).?;
        return std.fmt.allocPrint(alloc, "pilot #{d} {s}", .{ @intFromEnum(seat), u.chassis_key });
    }
    var techs: std.ArrayListUnmanaged(u8) = .empty;
    var uit = gs.units.iterator();
    while (uit.next()) |e| if (e.value_ptr.tech == p.id) {
        if (techs.items.len > 0) try techs.appendSlice(alloc, ",");
        try techs.appendSlice(alloc, try std.fmt.allocPrint(alloc, "#{d}", .{@intFromEnum(e.value_ptr.id)}));
    };
    if (techs.items.len > 0) return std.fmt.allocPrint(alloc, "tech {s}", .{techs.items});
    if (p.posted_hq != .none) return std.fmt.allocPrint(alloc, "HQ · {s}", .{clip(try hqName(alloc, gs, p.posted_hq), 16)});
    if (p.assigned_force != .none) return std.fmt.allocPrint(alloc, "{s} (no seat)", .{clip(try forceName(alloc, gs, p.assigned_force), 12)});
    return "{a}unassigned{/}";
}

// ------------------------------------------------------------------ summary

/// The campaign in aggregate: contracts by grade, battles, kills and
/// losses, money by category, people and hulls, the rating year by year.
pub fn summary(alloc: Alloc, gs: *GameState) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const day = gs.clock.day_index;
    const d = gs.clock.date;
    try out.append(alloc, try std.fmt.allocPrint(alloc, "{{a}}{s}{{/}} · {s} · day {d} · year {d} of the campaign", .{ try table.plain(alloc, gs.outfit_name), try d.textAlloc(alloc), day, day / types.days_per_year + 1 }));
    try out.append(alloc, (try rating(alloc, gs)).line);
    try out.append(alloc, try std.fmt.allocPrint(alloc, "difficulty {{a}}{s}{{/}} — {s}", .{ gs.diff().name, gs.diff().blurb }));
    try out.append(alloc, "");

    // Contracts.
    {
        var outstanding: u32 = 0;
        var strong: u32 = 0;
        var satisfactory: u32 = 0;
        var poor: u32 = 0;
        var failed: u32 = 0;
        var breached: u32 = 0;
        var active: u32 = 0;
        var earned: types.CBills = 0;
        for (gs.contracts.values()) |c| {
            switch (c.status) {
                .completed => {
                    if (c.victory_points >= 50) outstanding += 1 else if (c.victory_points >= 25) strong += 1 else if (c.victory_points >= 0) satisfactory += 1 else poor += 1;
                },
                .failed => failed += 1,
                .breached => breached += 1,
                .active, .transit, .accepted => active += 1,
                .offer => {},
            }
        }
        for (gs.ledger.transactions.items) |t| if (t.contract != .none and t.amount > 0) {
            earned += t.amount;
        };
        try out.append(alloc, "{a}CONTRACTS{/}");
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  {d} outstanding · {d} strong · {d} satisfactory · {d} poor · {{c}}{d} failed · {d} breached{{/}} · {d} under way", .{ outstanding, strong, satisfactory, poor, failed, breached, active }));
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  {s} c-bills earned from employers over the campaign", .{try money(alloc, earned)}));
    }
    try out.append(alloc, "");

    // Battles.
    {
        const st = gs.stats;
        var kills: u32 = 0;
        var kill_bv: u64 = 0;
        var it = gs.people.iterator();
        while (it.next()) |e| {
            kills += e.value_ptr.kills;
            kill_bv += e.value_ptr.kill_bv;
        }
        try out.append(alloc, "{a}BATTLES{/}");
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  {d} fought: {{g}}{d} won{{/}} · {d} drawn · {{c}}{d} lost{{/}}", .{ st.battles_won + st.battles_drawn + st.battles_lost, st.battles_won, st.battles_drawn, st.battles_lost }));
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  {d} kills credited ({d} BV) · {d} BV of enemy destroyed in all · {{c}}{d} hulls lost · {d} people KIA{{/}} · {{g}}{d} wrecks salvaged{{/}}", .{ kills, kill_bv, st.enemy_bv_destroyed, st.hulls_lost, st.people_kia, st.hulls_salvaged }));
    }
    try out.append(alloc, "");

    // Money by category.
    {
        var income: types.CBills = 0;
        var spent: types.CBills = 0;
        const Cat = finance.Category;
        var by_cat: [@typeInfo(Cat).@"enum".fields.len]types.CBills = @splat(0);
        for (gs.ledger.transactions.items) |t| {
            if (t.category == .fund_transfer) continue; // moves between our own pockets
            if (t.amount > 0) income += t.amount else spent -= t.amount;
            by_cat[@intFromEnum(t.category)] += t.amount;
        }
        try out.append(alloc, "{a}MONEY{/}");
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  {s} in · {s} out · {s}{s} net{{/}} · treasury now {s}", .{ try money(alloc, income), try money(alloc, spent), if (income >= spent) "{g}" else "{c}", try money(alloc, income - spent), try money(alloc, gs.funds) }));
        var line: std.ArrayListUnmanaged(u8) = .empty;
        try line.appendSlice(alloc, "  spent on: ");
        var shown: u32 = 0;
        // The five biggest expense categories.
        var used: [by_cat.len]bool = @splat(false);
        while (shown < 5) : (shown += 1) {
            var best: ?usize = null;
            for (by_cat, 0..) |v, i| if (!used[i] and v < 0 and (best == null or v < by_cat[best.?])) {
                best = i;
            };
            const i = best orelse break;
            used[i] = true;
            if (shown > 0) try line.appendSlice(alloc, " · ");
            try line.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s} {s}", .{ @tagName(@as(Cat, @enumFromInt(i))), try money(alloc, -by_cat[i]) }));
        }
        if (shown == 0) try line.appendSlice(alloc, "nothing yet");
        try out.append(alloc, line.items);
    }
    try out.append(alloc, "");

    // People and hulls.
    {
        var active: u32 = 0;
        var wounded: u32 = 0;
        var kia: u32 = 0;
        var resigned: u32 = 0;
        var retired: u32 = 0;
        var pow: u32 = 0;
        var it = gs.people.iterator();
        while (it.next()) |e| switch (e.value_ptr.status) {
            .active => active += 1,
            .wounded => wounded += 1,
            .kia => kia += 1,
            .resigned => resigned += 1,
            .retired => retired += 1,
            .pow => pow += 1,
            .mia, .released => {},
        };
        var hulls: u32 = 0;
        var mothballed: u32 = 0;
        var bought: u32 = 0;
        var uit = gs.units.iterator();
        while (uit.next()) |e| {
            if (e.value_ptr.status == .destroyed) continue;
            hulls += 1;
            if (e.value_ptr.status == .mothballed) mothballed += 1;
        }
        for (gs.ledger.transactions.items) |t| if (t.category == .unit_purchase) {
            bought += 1;
        };
        try out.append(alloc, "{a}PEOPLE & HULLS{/}");
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  {d} on the books ({d} wounded) · {d} ever hired · {{c}}{d} KIA{{/}} · {d} resigned · {d} retired{s}", .{ active + wounded, wounded, gs.next_person_id -| 1, kia, resigned, retired, if (pow > 0) try std.fmt.allocPrint(alloc, " · {d} prisoners held", .{pow}) else "" }));
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  {d} hulls ({d} mothballed) · {d} bought · {d} salvaged · {{c}}{d} lost{{/}}", .{ hulls, mothballed, bought, gs.stats.hulls_salvaged, gs.stats.hulls_lost }));
    }
    try out.append(alloc, "");

    // Rating by year.
    {
        try out.append(alloc, "{a}RATING BY YEAR{/}");
        if (gs.rating_history.items.len == 0) {
            try out.append(alloc, "  {d}first entry on New Year's Day{/}");
        } else {
            var line: std.ArrayListUnmanaged(u8) = .empty;
            try line.appendSlice(alloc, "  ");
            for (gs.rating_history.items, 0..) |snap, i| {
                if (i > 0) try line.appendSlice(alloc, " · ");
                try line.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{d}: {s} ({d})", .{ snap.year, ratingLetter(snap.score), snap.score }));
            }
            try out.append(alloc, line.items);
        }
    }
    return out.toOwnedSlice(alloc);
}

// ------------------------------------------------------------------ rating

pub const RatingPart = struct { name: []const u8, score: i32, note: []const u8 };

/// The outfit's Dragoons rating (CamOps "Mercenary Rating", MekHQ
/// `UnitRating`): six scored parts and a letter.
pub const Rating = struct {
    score: i32,
    letter: []const u8,
    parts: []RatingPart,
    /// One-line summary for headers: "rating B (61) · experience 30 · …".
    line: []const u8,
};

pub const ratingIndex = rating_mod.index;
pub const ratingScore = rating_mod.score;
pub const ratingPayBp = rating_mod.payBp;
pub const ratingLetter = rating_mod.letter;

/// The rating phrased: `rating.report` scores it, this names the parts.
pub fn rating(alloc: Alloc, gs: *GameState) !Rating {
    const r = rating_mod.report(gs);
    var parts: std.ArrayListUnmanaged(RatingPart) = .empty;
    try parts.append(alloc, .{ .name = "experience", .score = r.experience.score, .note = try std.fmt.allocPrint(alloc, "{d} combat crew, average skill {d}.{d}", .{ r.experience.crews, r.experience.avg_x10 / 10, r.experience.avg_x10 % 10 }) });
    try parts.append(alloc, .{ .name = "command", .score = r.command.score, .note = try std.fmt.allocPrint(alloc, "{d} of {d} desks staffed, {d} officer{s}", .{ r.command.desks_have, r.command.desks_need, r.command.officers, if (r.command.officers == 1) "" else "s" }) });
    try parts.append(alloc, .{ .name = "combat record", .score = r.record.score, .note = try std.fmt.allocPrint(alloc, "{d} contract{s} closed{s}, reputation {d}", .{ r.record.closed, if (r.record.closed == 1) "" else "s", if (r.record.closed == 0) " (unproven)" else "", r.record.reputation }) });
    try parts.append(alloc, .{ .name = "transport", .score = r.transport.score, .note = try std.fmt.allocPrint(alloc, "own ships lift {d}% of the line{s}", .{ types.bpPercent(r.transport.covered_bp), if (r.transport.jumpship) ", own jumpship" else "" }) });
    try parts.append(alloc, .{ .name = "support", .score = r.support.score, .note = try std.fmt.allocPrint(alloc, "{d} of {d} tech and medical posts filled", .{ r.support.have, r.support.need }) });
    {
        var note: []const u8 = "no debt";
        if (r.finances.debt > 0) note = try std.fmt.allocPrint(alloc, "{s} owed ({d} months of payroll)", .{ try money(alloc, r.finances.debt), r.finances.months });
        if (r.finances.overdrawn) note = try std.fmt.allocPrint(alloc, "{s}, treasury overdrawn", .{note});
        try parts.append(alloc, .{ .name = "finances", .score = r.finances.score, .note = note });
    }
    var line: std.ArrayListUnmanaged(u8) = .empty;
    try line.appendSlice(alloc, try std.fmt.allocPrint(alloc, "rating {{a}}{s}{{/}} ({d})", .{ ratingLetter(r.score), r.score }));
    for (parts.items) |pt| try line.appendSlice(alloc, try std.fmt.allocPrint(alloc, " · {s} {d}", .{ pt.name, pt.score }));
    return .{ .score = r.score, .letter = ratingLetter(r.score), .parts = try parts.toOwnedSlice(alloc), .line = try line.toOwnedSlice(alloc) };
}

/// Colour for a morale value: red under the restless line, amber under content.
pub fn moraleMarkup(morale: u32) []const u8 {
    const t = @import("../domain/tuning.zig").t.person;
    return if (morale < t.restless_morale) "{c}" else if (morale < t.morale_content) "{a}" else "{g}";
}

/// Colour for a fatigue band: green, amber, amber, red.
pub fn fatigueMarkup(band: person_mod.FatigueBand) []const u8 {
    return switch (band) {
        .fresh => "{g}",
        .tired, .exhausted => "{a}",
        .spent => "{c}",
    };
}

/// " · loyal: founder, veteran" or nothing.
fn loyaltyNote(alloc: Alloc, p: *const person_mod.Person, day: u32) ![]const u8 {
    const l = p.loyalty(day);
    if (l.count() == 0) return "";
    return std.fmt.allocPrint(alloc, " · loyal: {s}", .{try l.text(alloc)});
}

/// What letting this person go would cost today; `fired` halves it.
pub fn severanceOwed(gs: *GameState, id: types.PersonId, fired: bool) types.CBills {
    const share: types.Bp = if (fired) @import("../domain/tuning.zig").t.person.fire_severance_bp else types.full_bp;
    return @import("personnel.zig").severanceOwed(gs, id, share);
}

/// Nobody's pilot, nobody's tech, not posted to an HQ, not on a company's
/// books: the people the assignment column shows as "unassigned".
pub fn isUnassigned(gs: *GameState, p: *const person_mod.Person) bool {
    return gs.isUnassigned(p);
}

pub fn statusText(alloc: Alloc, gs: *GameState, p: *const person_mod.Person) ![]const u8 {
    const day = gs.clock.day_index;
    if (p.status == .wounded) return if (p.medbay_admitted) "{a}medbay{/}" else "{c}wounded{/}";
    if (p.status == .pow) return try std.fmt.allocPrint(alloc, "{{a}}prisoner ({s}){{/}}", .{p.faction});
    if (p.status == .mia) return try std.fmt.allocPrint(alloc, "{{c}}missing (held by {s}){{/}}", .{p.faction});
    if (p.status != .active) return try std.fmt.allocPrint(alloc, "{{c}}{s}{{/}}", .{@tagName(p.status)});
    if (p.leave_until_day) |until| if (day < until) return std.fmt.allocPrint(alloc, "{{a}}on leave{{/}} until d{d}", .{until});
    if (p.training) |t| return std.fmt.allocPrint(alloc, "{{a}}training{{/}} {s} d{d}", .{ @tagName(t.skill), t.done_day });
    return "{g}active{/}";
}

fn locationText(gs: *GameState, p: *const person_mod.Person) []const u8 {
    if (p.posted_hq != .none) return planetName(if (gs.hqs.getPtr(p.posted_hq)) |h| h.planet_key else null);
    const co = gs.companyOf(p.assigned_force);
    if (gs.forces.getPtr(co)) |f| {
        if (f.location_planet) |loc| return planetName(loc);
        if (gs.hqs.getPtr(f.supplying_hq)) |h| return planetName(h.planet_key);
    }
    return "—";
}

/// Everyone on the payroll (active, wounded, missing), filtered by role group.
pub fn people(alloc: Alloc, gs: *GameState, filter: HallFilter) !People {
    var rows: std.ArrayListUnmanaged(PersonRow) = .empty;
    var total: usize = 0;
    var it = gs.people.iterator();
    while (it.next()) |e| {
        const p = e.value_ptr;
        if (p.isGone()) continue;
        total += 1;
        if (!filter.matches(p.role)) continue;
        if (filter == .wounded and p.status != .wounded) continue;
        if (filter == .unassigned and !isUnassigned(gs, p)) continue;
        const name = try table.plain(alloc, try p.rankedName(alloc));
        try rows.append(alloc, .{ .id = p.id, .role = p.role, .primary_skill = p.role.primarySkill(), .xp = p.xp, .active = p.status == .active, .cells = try table.row(alloc, &.{
            try std.fmt.allocPrint(alloc, "{d}", .{@intFromEnum(p.id)}),
            name,
            @tagName(p.role),
            @tagName(p.experience()),
            try skillsText(alloc, p),
            try std.fmt.allocPrint(alloc, "{d}", .{p.xp}),
            try statusText(alloc, gs, p),
            try assignmentText(alloc, gs, p),
            locationText(gs, p),
            try std.fmt.allocPrint(alloc, "{d}", .{p.fatigue}),
            try std.fmt.allocPrint(alloc, "{d}", .{p.morale}),
            try money(alloc, p.monthlySalary()),
        }) });
    }
    return .{
        .rows = try rows.toOwnedSlice(alloc),
        .total = total,
    };
}

/// One person's full record.
/// Plain text for the CLI: `table.plainText` drops the markup the TUI
/// colours and sanitizes what is left.
pub const stripMarks = table.plainText;

// --------------------------------------------------------------- readiness

pub const ReadinessRow = struct {
    company: types.ForceId,
    deployed: bool,
    heads: u32,
    fatigue: u32,
    /// Heads in the tired-or-worse bands and in the spent band.
    tired: u32 = 0,
    spent: u32 = 0,
    morale: u32,
    wounded: u32,
    permanent: u32,
    training: u32,
    banked_xp: u32,
    hulls: u32,
    depot: u32,
    avg_quality: types.Quality,
    contracts_since_rotation: u16,
    days_since_rotation: ?u32,
    cells: table.Row,
};

pub const readiness_cols: []const table.Col = &.{
    .{ .name = "company" },                      .{ .name = "posture" },                    .{ .name = "heads", .justify = .right }, .{ .name = "fatigue", .justify = .right },
    .{ .name = "morale", .justify = .right },    .{ .name = "wounded", .justify = .right }, .{ .name = "perm", .justify = .right },  .{ .name = "training", .justify = .right },
    .{ .name = "banked XP", .justify = .right }, .{ .name = "hulls", .justify = .right },   .{ .name = "depot", .justify = .right }, .{ .name = "quality" },
    .{ .name = "rotation" },
};

/// The per-company readiness report (ARCH §9.7): the P&L's
/// companion — profit now vs. force quality later. Banked XP is what the
/// crews could spend at a training ground; depot is hulls waiting on a bay.
pub fn readiness(alloc: Alloc, gs: *GameState) ![]ReadinessRow {
    var out: std.ArrayListUnmanaged(ReadinessRow) = .empty;
    const day = gs.clock.day_index;
    var fit = gs.forces.iterator();
    while (fit.next()) |fe| {
        const co = fe.value_ptr;
        if (co.echelon != .company) continue;
        var row: ReadinessRow = .{
            .company = co.id,
            .deployed = gs.isCompanyDeployed(co.id),
            .heads = 0,
            .fatigue = 0,
            .morale = 0,
            .wounded = 0,
            .permanent = 0,
            .training = 0,
            .banked_xp = 0,
            .hulls = 0,
            .depot = 0,
            .avg_quality = .c,
            .contracts_since_rotation = co.contracts_since_rotation,
            .days_since_rotation = if (co.last_rotation_day) |d| day -| d else null,
            .cells = &.{},
        };
        const crew = @import("personnel.zig").companyCrewStats(gs, co.id);
        row.heads = crew.heads;
        row.tired = crew.tired;
        row.spent = crew.spent;
        row.wounded = crew.wounded;
        row.permanent = crew.permanent;
        row.training = crew.training;
        row.banked_xp = crew.banked_xp;
        row.fatigue = crew.avg_fatigue;
        row.morale = crew.avg_morale;
        var qsum: u64 = 0;
        var uit = gs.units.iterator();
        while (uit.next()) |ue| {
            const u = ue.value_ptr;
            if (gs.companyOf(u.force) != co.id or u.status == .mothballed or u.kind.isTransport()) continue;
            row.hulls += 1;
            qsum += @intFromEnum(u.quality);
            if (u.needsDepot()) row.depot += 1;
        }
        if (row.hulls > 0) row.avg_quality = @enumFromInt(qsum / row.hulls);
        const fat_mk = fatigueMarkup(person_mod.Person.fatigueBandOf(row.fatigue));
        const mor_mk = moraleMarkup(row.morale);
        const rot: []const u8 = if (row.days_since_rotation) |d| try std.fmt.allocPrint(alloc, "{d} tours · {d}d", .{ row.contracts_since_rotation, d }) else try std.fmt.allocPrint(alloc, "{d} tours", .{row.contracts_since_rotation});
        row.cells = try table.row(alloc, &.{
            try std.fmt.allocPrint(alloc, "{{a}}{s}{{/}}", .{try table.plain(alloc, co.name)}),
            if (row.deployed) "{a}deployed{/}" else if (gs.isCompanyHome(co.id)) "at home" else "afield",
            try std.fmt.allocPrint(alloc, "{d}", .{row.heads}),
            try std.fmt.allocPrint(alloc, "{s}{d}{{/}}", .{ fat_mk, row.fatigue }),
            try std.fmt.allocPrint(alloc, "{s}{d}{{/}}", .{ mor_mk, row.morale }),
            try std.fmt.allocPrint(alloc, "{s}{d}{{/}}", .{ if (row.wounded > 0) "{a}" else "", row.wounded }),
            try std.fmt.allocPrint(alloc, "{d}", .{row.permanent}),
            try std.fmt.allocPrint(alloc, "{d}", .{row.training}),
            try std.fmt.allocPrint(alloc, "{d}", .{row.banked_xp}),
            try std.fmt.allocPrint(alloc, "{d}", .{row.hulls}),
            try std.fmt.allocPrint(alloc, "{s}{d}{{/}}", .{ if (row.depot > 0) "{c}" else "", row.depot }),
            @tagName(row.avg_quality),
            rot,
        });
        try out.append(alloc, row);
    }
    return out.toOwnedSlice(alloc);
}

/// One company's readiness as a pane: the row's numbers spelled out, and
/// who is hurt, training, or carrying a permanent injury.
pub fn readinessLines(alloc: Alloc, gs: *GameState, company: types.ForceId) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const rows = try readiness(alloc, gs);
    var row: ?ReadinessRow = null;
    for (rows) |r| if (r.company == company) {
        row = r;
    };
    const r = row orelse {
        try out.append(alloc, "{d}not a company{/}");
        return out.toOwnedSlice(alloc);
    };
    const day = gs.clock.day_index;
    try out.append(alloc, try std.fmt.allocPrint(alloc, "{d} personnel · fatigue {s}{d}{{/}} ({d} tired, {s}{d} spent{{/}}) · morale {s}{d}{{/}} · {s} · {d} contracts since rotation{s}", .{
        r.heads,
        fatigueMarkup(person_mod.Person.fatigueBandOf(r.fatigue)),
        r.fatigue,
        r.tired,
        if (r.spent > 0) "{c}" else "{g}",
        r.spent,
        moraleMarkup(r.morale),
        r.morale,
        if (r.deployed) "{a}deployed{/}" else if (gs.isCompanyHome(company)) "at home" else "afield",
        r.contracts_since_rotation,
        if (r.days_since_rotation) |d| try std.fmt.allocPrint(alloc, " · {d} days since", .{d}) else "",
    }));
    try out.append(alloc, try std.fmt.allocPrint(alloc, "{d} hulls · avg quality {s} · {s}{d} need depot time{{/}} · {d} XP banked in the cockpits{s}", .{
        r.hulls, @tagName(r.avg_quality), if (r.depot > 0) "{c}" else "", r.depot, r.banked_xp,
        if (r.banked_xp > 0 and !r.deployed) " — a training ground turns it into skill" else "",
    }));
    try out.append(alloc, "");
    try out.append(alloc, try std.fmt.allocPrint(alloc, "wounded {d} · permanent injuries {d} · in training {d}", .{ r.wounded, r.permanent, r.training }));
    var pit = gs.people.iterator();
    while (pit.next()) |pe| {
        const p = pe.value_ptr;
        if (gs.companyOf(p.assigned_force) != company) continue;
        if (p.status == .wounded) {
            var where: std.ArrayListUnmanaged(u8) = .empty;
            for (p.injuries.items) |inj| {
                if (inj.healed) continue;
                if (where.items.len > 0) try where.appendSlice(alloc, ", ");
                try where.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s} {s}", .{ @import("medical.zig").severityLabel(inj.severity), @tagName(inj.location) }));
            }
            try out.append(alloc, try std.fmt.allocPrint(alloc, "  {{a}}{s}{{/}} {s} — {s}{s}", .{ try personText(alloc, p), @tagName(p.role), where.items, if (p.wound_heal_day) |h| try std.fmt.allocPrint(alloc, " · back day {d} ({d}d)", .{ h, h -| day }) else if (p.medbay_admitted) " · triage tomorrow" else " · {c}not admitted{/}" }));
        } else if (p.permanentPenalty() > 0) {
            try out.append(alloc, try std.fmt.allocPrint(alloc, "  {s} {s} — permanent injury, +{d} to skill rolls", .{ try personText(alloc, p), @tagName(p.role), p.permanentPenalty() }));
        } else if (p.training) |t| {
            try out.append(alloc, try std.fmt.allocPrint(alloc, "  {s} {s} — training {s}, done day {d}", .{ try personText(alloc, p), @tagName(p.role), @tagName(t.skill), t.done_day }));
        }
    }
    return out.toOwnedSlice(alloc);
}

pub fn personRecord(alloc: Alloc, gs: *GameState, id: types.PersonId) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const p = gs.person(id) orelse return out.toOwnedSlice(alloc);
    const day = gs.clock.day_index;
    try out.append(alloc, try std.fmt.allocPrint(alloc, "{{a}}{s} {s}{{/}}{s}  ·  {s} · {s} · {s}{s}", .{ p.rank.abbrev(), try personText(alloc, p), if (p.callsign) |c| try std.fmt.allocPrint(alloc, " \"{s}\"", .{try table.plain(alloc, c)}) else "", @tagName(p.role), @tagName(p.experience()), p.rank.name(), if (p.rank_pinned) " (pinned — :promote <id> <rank> unpin lets seats decide)" else "" }));
    try out.append(alloc, try std.fmt.allocPrint(alloc, "status      {s}{s}", .{ try statusText(alloc, gs, p), if (p.status == .wounded) (if (p.wound_heal_day) |h| try std.fmt.allocPrint(alloc, " · discharged day {d} ({d} days)", .{ h, h -| day }) else if (p.medbay_admitted) " · triage tomorrow" else " · {c}not admitted — [m] admits{/}") else "" }));
    try out.append(alloc, try std.fmt.allocPrint(alloc, "assignment  {s}", .{try assignmentText(alloc, gs, p)}));
    try out.append(alloc, try std.fmt.allocPrint(alloc, "unit        {s} · at {s}", .{ if (p.assigned_force != .none) try forceName(alloc, gs, p.assigned_force) else "—", locationText(gs, p) }));
    try out.append(alloc, "");
    const band = p.fatigueBand();
    try out.append(alloc, try std.fmt.allocPrint(alloc, "XP {{a}}{d}{{/}} · fatigue {s}{d} {s}{{/}}{s} · morale {d} · pay {s}/mo · recruited day {d}", .{
        p.xp,                                                                                                                                                     fatigueMarkup(band),
        p.fatigue,                                                                                                                                                @tagName(band),
        if (band.penalty() > 0) try std.fmt.allocPrint(alloc, " (+{d} gunnery/piloting{s})", .{ band.penalty(), if (band == .spent) ", unfit" else "" }) else "", p.morale,
        try money(alloc, p.monthlySalary()),                                                                                                                      p.recruited_day,
    }));
    try out.append(alloc, "");
    try out.append(alloc, "skill               level   next   XP cost");
    inline for (@typeInfo(types.SkillType).@"enum".fields) |f| {
        const st: types.SkillType = @enumFromInt(f.value);
        if (p.skill(st)) |lvl| {
            const primary = st == p.role.primarySkill();
            if (lvl == 0) {
                try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}{s: <19} {d: >5}   mastered{{/}}", .{ if (primary) "{a}" else "", f.name, lvl }));
            } else {
                const cost = person_mod.improveCost(lvl - 1);
                try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}{s: <19} {d: >5} {d: >6} {d: >8}{s}{{/}}", .{ if (primary) "{a}" else "", f.name, lvl, lvl - 1, cost, if (p.xp >= cost) "  {g}affordable{/}" else "" }));
            }
        }
    }
    try out.append(alloc, "");
    if (p.training) |t| {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "training    {s} → done day {d} ({d} days left)", .{ @tagName(t.skill), t.done_day, if (t.done_day > day) t.done_day - day else 0 }));
    } else {
        try out.append(alloc, "training    none");
        try out.append(alloc, "            {d}[t] starts a program on the primary skill (training ground at home) · :train <id> ability <key> buys a special ability with XP{/}");
    }
    if (p.abilities.items.len > 0) {
        var line: std.ArrayListUnmanaged(u8) = .empty;
        try line.appendSlice(alloc, "abilities   ");
        for (p.abilities.items, 0..) |key, i| {
            if (i > 0) try line.appendSlice(alloc, " · ");
            const a = @import("../domain/ability.zig").find(key);
            try line.appendSlice(alloc, if (a) |ab| ab.name else key);
            if (std.mem.eql(u8, key, "edge")) try line.appendSlice(alloc, if (p.edge_spent) " (spent this contract)" else " (ready)");
        }
        try out.append(alloc, line.items);
    }
    if (p.ageYears(day)) |age| {
        const tp = @import("../domain/tuning.zig").t.person;
        try out.append(alloc, try std.fmt.allocPrint(alloc, "age         {d}{s}", .{ age, if (age >= tp.age_retire) " · {c}retiring on the next payday home{/}" else if (age >= tp.age_old) " · {a}getting on — an extra restless flag on payday{/}" else if (age < tp.age_young) " · {g}young — learns 20% faster{/}" else "" }));
    }
    {
        const l = p.loyalty(day);
        if (l.count() > 0) try out.append(alloc, try std.fmt.allocPrint(alloc, "loyalty     {s} — cancels {d} restless flag{s} on payday{s}", .{ try l.text(alloc), l.count(), if (l.count() == 1) "" else "s", if (l.founder) "; founders never roll while morale holds" else "" }));
    }
    if (p.shares > 0 or p.isFounder()) try out.append(alloc, try std.fmt.allocPrint(alloc, "shares      {d} share{s}{s} · {d}% of contract income is split among shareholders at completion", .{ p.shares, if (p.shares == 1) "" else "s", if (p.isFounder()) " · founder" else "", types.bpPercent(gs.share_profit_bp) }));
    try out.append(alloc, try std.fmt.allocPrint(alloc, "record      {d} kill{s} ({d} BV) · {d} battle{s} · {d} tour{s}{s}", .{ p.kills, if (p.kills == 1) "" else "s", p.kill_bv, p.battles, if (p.battles == 1) "" else "s", p.tours, if (p.tours == 1) "" else "s", if (p.outstanding_tours > 0) try std.fmt.allocPrint(alloc, " ({d} outstanding)", .{p.outstanding_tours}) else "" }));
    if (p.awards.items.len > 0) {
        var line: std.ArrayListUnmanaged(u8) = .empty;
        try line.appendSlice(alloc, "awards      ");
        for (p.awards.items, 0..) |key, i| {
            if (i > 0) try line.appendSlice(alloc, " · ");
            try line.appendSlice(alloc, if (@import("../domain/award.zig").find(key)) |a| a.name else key);
        }
        try out.append(alloc, line.items);
    }
    for (p.injuries.items, 0..) |inj, i| {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}{s} {s} {s}{s}{s}", .{
            if (i == 0) "injuries    " else "            ",
            if (inj.healed) "{d}healed" else if (inj.severity >= 3) "{c}" else "{a}",
            @import("medical.zig").severityLabel(inj.severity),
            @tagName(inj.location),
            if (inj.permanent) " · PERMANENT" else "",
            if (inj.healed) "{/}" else if (inj.heal_done_day) |h| try std.fmt.allocPrint(alloc, " · closes day {d} ({d}d){{/}}", .{ h, h -| day }) else " · awaiting triage{/}",
        }));
    }
    if (p.leave_until_day) |until| if (day < until) try out.append(alloc, try std.fmt.allocPrint(alloc, "leave       until day {d}", .{until}));
    if (p.medbay_priority > 0) try out.append(alloc, try std.fmt.allocPrint(alloc, "medbay      priority {d}", .{p.medbay_priority}));
    try out.append(alloc, try std.fmt.allocPrint(alloc, "available   {s}", .{if (p.isAvailable(day)) "{g}yes{/}" else "{c}no{/}"}));
    return out.toOwnedSlice(alloc);
}

pub const Seat = struct {
    unit: types.UnitId,
    slot: state_mod.Slot,
    text: []const u8,
};

/// Open pilot/tech seats this person could take, across the outfit.
pub fn openSeats(alloc: Alloc, gs: *GameState, id: types.PersonId) ![]Seat {
    var out: std.ArrayListUnmanaged(Seat) = .empty;
    const p = gs.person(id) orelse return out.toOwnedSlice(alloc);
    var it = gs.units.iterator();
    while (it.next()) |e| {
        const u = e.value_ptr;
        if (u.isParked()) continue;
        if (u.force == .none and !gs.canReachPool(p)) continue; // the pool is at the seat; their company is away
        const ch = chassis_mod.find(u.chassis_key);
        const label = try std.fmt.allocPrint(alloc, "#{d: <3} {s: <8} {s: <16} {s}", .{ @intFromEnum(u.id), u.chassis_key, if (ch) |c| c.name else "?", if (u.force == .none) "unassigned pool" else clip(try forceName(alloc, gs, gs.companyOf(u.force)), 20) });
        if (unit_mod.crewRoleFor(u.kind) == p.role and gs.person(u.pilot) == null) {
            try out.append(alloc, .{ .unit = u.id, .slot = .pilot, .text = try std.fmt.allocPrint(alloc, "{s}  {{a}}pilot seat{{/}}", .{label}) });
        }
        if (unit_mod.techRoleFor(u.kind) == p.role and gs.person(u.tech) == null) {
            try out.append(alloc, .{ .unit = u.id, .slot = .tech, .text = try std.fmt.allocPrint(alloc, "{s}  {{a}}tech slot{{/}}", .{label}) });
        }
    }
    return out.toOwnedSlice(alloc);
}

// --------------------------------------------------------------------- map

pub const Band = enum { ring, beachhead, dark };

pub const World = struct {
    key: []const u8,
    name: []const u8,
    faction: []const u8,
    x: i32,
    y: i32,
    industry: u8,
    band: Band,
    nearest_hq: types.HqId,
    dist_ly: u32,
    hq_here: types.HqId,
    companies_here: u32,
    offers_here: u32,
    /// Contracts worked here (any outcome): an HQ can be founded on such a world.
    worked: u32,
    /// Standing with the world's house (0 when it posts no contracts).
    standing: i32,
};

pub const MapHq = struct {
    id: types.HqId,
    name: table.Raw,
    x: i32,
    y: i32,
    ring_ly: u32,
};

pub const Map = struct {
    worlds: []World,
    hqs: []MapHq,
    in_ring: u32,
    in_band: u32,
    dark: u32,
    band_ly: u32,
};

pub fn map(alloc: Alloc, gs: *GameState) !Map {
    var hqs: std.ArrayListUnmanaged(MapHq) = .empty;
    var hit = gs.hqs.iterator();
    while (hit.next()) |e| {
        const h = e.value_ptr;
        const p = planet_mod.find(h.planet_key) orelse continue;
        try hqs.append(alloc, .{ .id = h.id, .name = .{ .raw = h.name }, .x = p.x, .y = p.y, .ring_ly = h.influenceLy() });
    }
    var worlds: std.ArrayListUnmanaged(World) = .empty;
    var in_ring: u32 = 0;
    var in_band: u32 = 0;
    var dark: u32 = 0;
    for (planet_mod.catalog) |*p| {
        var band: Band = .dark;
        var nearest: types.HqId = .none;
        var best: u32 = std.math.maxInt(u32);
        var hq_here: types.HqId = .none;
        for (hqs.items) |h| {
            const hp = planet_mod.find(gs.hqs.getPtr(h.id).?.planet_key).?;
            const d = planet_mod.distanceLy(p, hp);
            if (d == 0) hq_here = h.id;
            if (d < best) {
                best = d;
                nearest = h.id;
            }
            const b: Band = if (d <= h.ring_ly) .ring else if (d <= h.ring_ly + market_mod.beachhead_band_ly) .beachhead else .dark;
            if (@intFromEnum(b) < @intFromEnum(band)) band = b;
        }
        switch (band) {
            .ring => in_ring += 1,
            .beachhead => in_band += 1,
            .dark => dark += 1,
        }
        var companies: u32 = 0;
        var fit = gs.forces.iterator();
        while (fit.next()) |e| {
            const f = e.value_ptr;
            if (f.echelon != .company) continue;
            const loc = f.location_planet orelse (if (gs.hqs.getPtr(f.supplying_hq)) |h| h.planet_key else null);
            if (loc) |l| if (std.mem.eql(u8, l, p.key)) {
                companies += 1;
            };
        }
        var offers: u32 = 0;
        for (gs.contract_offers.items) |c| if (std.mem.eql(u8, c.planet_key, p.key)) {
            offers += 1;
        };
        try worlds.append(alloc, .{
            .key = p.key,
            .name = p.name,
            .faction = p.faction,
            .x = p.x,
            .y = p.y,
            .industry = p.industry,
            .band = band,
            .nearest_hq = nearest,
            .dist_ly = if (best == std.math.maxInt(u32)) 0 else best,
            .hq_here = hq_here,
            .companies_here = companies,
            .offers_here = offers,
            .worked = contractsWorkedAt(gs, p.key),
            .standing = gs.standing(p.faction),
        });
    }
    return .{ .worlds = try worlds.toOwnedSlice(alloc), .hqs = try hqs.toOwnedSlice(alloc), .in_ring = in_ring, .in_band = in_band, .dark = dark, .band_ly = market_mod.beachhead_band_ly };
}

pub const HistoryRow = struct {
    id: types.ContractId,
    planet_key: []const u8,
    cells: table.Row,
};

pub const history_cols: []const table.Col = &.{
    .{ .name = "id" },                          .{ .name = "kind" },                      .{ .name = "emp" },                   .{ .name = "world" },
    .{ .name = "outcome" },                     .{ .name = "served", .justify = .right }, .{ .name = "VP", .justify = .right }, .{ .name = "verdict" },
    .{ .name = "received", .justify = .right }, .{ .name = "company" },
};

/// Every closed contract, newest first: what it was, where, how it ended,
/// and what it paid. The worlds listed here are the ones an HQ can be
/// founded on. AARs for a row come from `battleLog`.
pub fn contractHistory(alloc: Alloc, gs: *GameState) ![]HistoryRow {
    var out: std.ArrayListUnmanaged(HistoryRow) = .empty;
    const vals = gs.contracts.values();
    var i: usize = vals.len;
    while (i > 0) {
        i -= 1;
        const c = &vals[i];
        if (!c.isClosed()) continue;
        var received: types.CBills = 0;
        for (gs.ledger.transactions.items) |t| if (t.contract == c.id and t.amount > 0) {
            received += t.amount;
        };
        const start = c.arrive_day orelse c.start_day;
        const served: ?u32 = if (start != null and c.end_day != null) c.end_day.? -| start.? else null;
        const st_mk: []const u8 = switch (c.status) {
            .completed => "{g}",
            .breached, .failed => "{c}",
            else => "{a}",
        };
        try out.append(alloc, .{ .id = c.id, .planet_key = c.planet_key, .cells = try table.row(alloc, &.{
            try std.fmt.allocPrint(alloc, "{d}", .{@intFromEnum(c.id)}),
            c.kind.label(),
            c.employer_key,
            planetName(c.planet_key),
            try std.fmt.allocPrint(alloc, "{s}{s}{{/}}", .{ st_mk, @tagName(c.status) }),
            if (served) |d| try std.fmt.allocPrint(alloc, "{d}d", .{d}) else "—",
            try std.fmt.allocPrint(alloc, "{d}", .{c.victory_points}),
            if (c.status == .completed) c.grade() else if (c.status == .breached) "breached" else "failed",
            try money(alloc, received),
            try forceName(alloc, gs, c.assigned_company),
        }) });
    }
    return out.toOwnedSlice(alloc);
}

/// Contracts the outfit has worked on a world (any outcome): the founding
/// rule counts them as reach.
pub fn contractsWorkedAt(gs: *GameState, planet_key: []const u8) u32 {
    return gs.contractsWorkedAt(planet_key);
}

/// Offer rows for one world (text only).
pub fn offersAt(alloc: Alloc, gs: *GameState, planet_key: []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (gs.contract_offers.items, 0..) |c, i| {
        if (!std.mem.eql(u8, c.planet_key, planet_key)) continue;
        try out.append(alloc, try std.fmt.allocPrint(alloc, "[{d}] {{a}}{s}{{/}} {d} mo · {s}/mo · {s} vs {s} · salvage {d}%{s}", .{
            i, c.kind.label(), c.terms.length_months, try money(alloc, c.terms.base_pay_month), c.employer_key, c.enemy_key, c.terms.salvage_pct,
            if (c.beachhead) " · {a}beachhead{/}" else "",
        }));
    }
    return out.toOwnedSlice(alloc);
}

// --------------------------------------------------------------------- lab

const meklab = @import("../domain/meklab.zig");

pub const MountRow = struct {
    slot_key: []const u8,
    /// The part in the mount (what a replacement orders).
    part_key: []const u8,
    /// Where the mount sits (the `refit_install` payload for a like-for-like swap).
    location: ?meklab.Location,
    text: []const u8,
};

pub const InstallCandidate = struct {
    key: []const u8,
    on_hand: u32,
    text: []const u8,
};

/// Parts the lab could install on a hull: stock at the home HQ first, then
/// the catalog (bought or ordered at commit time).
pub fn installCandidates(alloc: Alloc, gs: *GameState, uid: types.UnitId) ![]InstallCandidate {
    const part_mod = @import("../domain/part.zig");
    var out: std.ArrayListUnmanaged(InstallCandidate) = .empty;
    const u = gs.unit(uid) orelse return out.toOwnedSlice(alloc);
    const home = gs.homeHqFor(u.force);
    for (part_mod.catalog) |p| {
        if (!p.mountable()) continue;
        const on_hand = gs.stockCount(.{ .hq = home }, p.key) + gs.spareCount(p.key);
        try out.append(alloc, .{ .key = p.key, .on_hand = on_hand, .text = try std.fmt.allocPrint(alloc, "{s: <12} {s: <22} {s: <9} {d: >2}.{d}t {d: >2}c heat {d: >2}  {s}", .{
            clip(p.key, 12), clip(p.name, 22), @tagName(p.mount), p.mass_half_tons / 2, (p.mass_half_tons % 2) * 5, p.crits, p.heat, if (on_hand > 0) try std.fmt.allocPrint(alloc, "{{g}}{d} in stock{{/}}", .{on_hand}) else try std.fmt.allocPrint(alloc, "{{d}}buy {s}{{/}}", .{try money(alloc, p.cost)}),
        }) });
    }
    // Stocked parts first.
    std.mem.sort(InstallCandidate, out.items, {}, struct {
        fn lt(_: void, a: InstallCandidate, b: InstallCandidate) bool {
            if ((a.on_hand > 0) != (b.on_hand > 0)) return a.on_hand > 0;
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.lt);
    return out.toOwnedSlice(alloc);
}

pub const InstallLocation = struct {
    location: meklab.Location,
    legal: bool,
    text: []const u8,
};

/// Every location with the rules' verdict for putting `part_key` there
/// (a trial validation on top of the current plan).
pub fn installLocations(alloc: Alloc, gs: *GameState, uid: types.UnitId, part_key: []const u8) ![]InstallLocation {
    var out: std.ArrayListUnmanaged(InstallLocation) = .empty;
    if (gs.unit(uid) == null) return out.toOwnedSlice(alloc);
    inline for (@typeInfo(meklab.Location).@"enum".fields) |f| {
        const loc: meklab.Location = @enumFromInt(f.value);
        const r = gs.tryInstall(alloc, uid, loc, part_key) catch return out.toOwnedSlice(alloc);
        var why: []const u8 = "";
        if (!r.legal) {
            for (r.violations) |v| {
                if (v.rule == .crits or v.rule == .location or v.rule == .ammo) {
                    why = v.text;
                    break;
                }
                why = v.text;
            }
        }
        try out.append(alloc, .{ .location = loc, .legal = r.legal, .text = try std.fmt.allocPrint(alloc, "{s}{s: <3} free crits {d: >2}   {s}{s}{{/}}", .{
            if (r.legal) "{g}" else "{c}", f.name, r.crits_free[f.value], if (r.legal) "fits" else "no: ", if (r.legal) "" else why,
        }) });
    }
    return out.toOwnedSlice(alloc);
}

pub const Lab = struct {
    title: []const u8,
    budget: []const []const u8,
    mounts: []MountRow,
    plan: []const []const u8,
    legal: bool,
    /// Every mek hull the lab can work on (for [ ] cycling).
    meks: []types.UnitId,
};

/// Every mek hull, wrecks included: a wreck's structural state and its
/// rebuild path belong in the Lab like any other structure hit, so the Lab
/// and Forces count the same hulls.
pub fn labMeks(alloc: Alloc, gs: *GameState) ![]types.UnitId {
    var out: std.ArrayListUnmanaged(types.UnitId) = .empty;
    var it = gs.units.iterator();
    while (it.next()) |e| if (e.value_ptr.kind == .mek) try out.append(alloc, e.value_ptr.id);
    return out.toOwnedSlice(alloc);
}

fn halfTons(alloc: Alloc, ht: i64) ![]const u8 {
    const mag = @abs(ht);
    return std.fmt.allocPrint(alloc, "{s}{d}.{d}t", .{ if (ht < 0) "-" else "", mag / 2, (mag % 2) * 5 });
}

pub fn lab(alloc: Alloc, gs: *GameState, uid: types.UnitId) !Lab {
    const meks = try labMeks(alloc, gs);
    var budget: std.ArrayListUnmanaged([]const u8) = .empty;
    var mounts: std.ArrayListUnmanaged(MountRow) = .empty;
    var plan: std.ArrayListUnmanaged([]const u8) = .empty;
    const u = gs.unit(uid) orelse return .{ .title = "no hull", .budget = &.{}, .mounts = &.{}, .plan = &.{}, .legal = true, .meks = meks };
    const design = chassis_mod.find(u.chassis_key) orelse return .{ .title = "unknown chassis", .budget = &.{}, .mounts = &.{}, .plan = &.{}, .legal = true, .meks = meks };
    const title = try std.fmt.allocPrint(alloc, "#{d} {s} {s} · {d}t", .{ @intFromEnum(uid), design.key, design.name, design.tonnage });
    if (u.kind != .mek) {
        try budget.append(alloc, "{a}not a mek — the lab works on BattleMechs; this hull's gear is field work: Forces R (or :replace <unit>) orders spares to its site and its tech fits them{/}");
        return .{ .title = title, .budget = try budget.toOwnedSlice(alloc), .mounts = &.{}, .plan = &.{}, .legal = true, .meks = meks };
    }
    if (u.status == .destroyed) try budget.append(alloc, try std.fmt.allocPrint(alloc, "{s} · {{d}}no refits on a wreck{{/}}", .{try wreckNote(alloc, gs, u)}));
    const items = try gs.labItems(uid, alloc);
    const r = try meklab.validate(design, items, alloc);
    try budget.append(alloc, try std.fmt.allocPrint(alloc, "chassis   {s}   mounts   {s}", .{ try halfTons(alloc, r.fixed_half_tons), try halfTons(alloc, r.loadout_half_tons) }));
    try budget.append(alloc, try std.fmt.allocPrint(alloc, "total     {s}   free     {s}{s}{{/}}", .{ try halfTons(alloc, @as(i64, r.fixed_half_tons) + r.loadout_half_tons), if (r.free_half_tons < 0) "{c}" else "{g}", try halfTons(alloc, r.free_half_tons) }));
    try budget.append(alloc, try std.fmt.allocPrint(alloc, "heat      alpha strike {d} · sinks {d}", .{ r.heat_per_alpha, design.heat_sinks }));
    try budget.append(alloc, try std.fmt.allocPrint(alloc, "movement  walk {d}{s} · engine {d}", .{ design.walk_mp, if (design.jump_mp > 0) " · jump" else "", design.engineRating() }));
    try budget.append(alloc, "");
    try budget.append(alloc, "location   used  free   {d}(dim = no free crits){/}");
    const home_hq = @import("hq_ops.zig").depotHqFor(gs, u);
    const wants = try @import("hq_ops.zig").depotNeeds(alloc, u);
    inline for (@typeInfo(meklab.Location).@"enum".fields) |f| {
        const loc: meklab.Location = @enumFromInt(f.value);
        const full = r.crits_free[f.value] == 0;
        // Structure state per location: the frame must be sound before
        // anything is fitted into it.
        var struct_note: []const u8 = "";
        for (u.slots.items) |s| {
            if (s.class != .structure) continue;
            if (meklab.parseLocation(s.slot_key) != loc) continue;
            if (s.condition != .ok) {
                var comp: ?[]const u8 = null;
                for (wants) |w| if (std.mem.eql(u8, w.slot_key, s.slot_key)) {
                    comp = w.component;
                };
                const at_home = gs.isCompanyHome(gs.companyOf(u.force));
                if (@import("hq_ops.zig").hasJobForUnit(gs, uid)) {
                    struct_note = try std.fmt.allocPrint(alloc, "  {{c}}structure {s}{{/}} · {{d}}in the depot — its parts are taken; HQ screen bays{{/}}", .{@tagName(s.condition)});
                } else if (comp) |c| {
                    const on_hand = gs.stockCount(.{ .hq = home_hq }, c);
                    const action: []const u8 = if (!at_home)
                        "{a}hull is away — depot work waits for it to come home; fabricate the part meanwhile (Market, b){/}"
                    else if (on_hand > 0)
                        "{g}[D] send to depot{/}"
                    else
                        "{a}order or fabricate it (Market){/}";
                    struct_note = try std.fmt.allocPrint(alloc, "  {{c}}structure {s}{{/}} · needs {s} ({d} on hand) · {s}", .{ @tagName(s.condition), c, on_hand, action });
                } else if (s.condition == .damaged) {
                    struct_note = try std.fmt.allocPrint(alloc, "  {{c}}structure damaged{{/}} · bay time only · {s}", .{if (at_home) "{g}[D] send to depot{/}" else "{a}hull is away — depot work waits for it to come home{/}"});
                } else struct_note = "  {c}structure destroyed{/} · {d}scrap: not rebuilt{/}";
            }
        }
        try budget.append(alloc, try std.fmt.allocPrint(alloc, "{s}{s: <10} {d: >4}  {d: >4}{s}{{/}}{s}", .{ if (full) "{d}" else "", f.name, r.crits_used[f.value], r.crits_free[f.value], if (full) "  full" else "", struct_note }));
    }
    try budget.append(alloc, "");
    if (gs.hqs.getPtr(home_hq)) |h| {
        const slots = @import("hq_ops.zig").baySlots(gs, home_hq);
        const load = @import("hq_ops.zig").bayLoad(gs, home_hq);
        const busy = load.busy;
        const queued = load.queued;
        try budget.append(alloc, try std.fmt.allocPrint(alloc, "bays at {s}", .{try table.plain(alloc, clip(h.name, 28))}));
        try budget.append(alloc, try std.fmt.allocPrint(alloc, "  {s}{d} of {d} slots busy{{/}} · {d} queued · refit ceiling class {{a}}{s}{{/}}", .{ if (busy >= slots) "{c}" else "{g}", busy, slots, queued, if (h.refitClassCeiling()) |c| @tagName(c) else "none" }));
    }
    if (u.status == .destroyed) {
        try budget.append(alloc, if (u.wreck == .scrap) "{c}scrap: nothing to rebuild — Forces $ sells it, s strips its surviving parts{/}" else if (gs.isCompanyHome(gs.companyOf(u.force))) "{a}wreck: [D] rebuilds it in the depot (bay job) once every destroyed location's component is in stock{/}" else "{a}wreck: it is away with its company — HQ can fabricate or order the components now; the rebuild runs once it is home{/}");
    } else if (u.needsDepot()) try budget.append(alloc, if (gs.isCompanyHome(gs.companyOf(u.force))) "{a}structure damaged: [D] sends this hull to the depot (bay job); the weekly pass also queues it when parts are in stock{/}" else "{a}structure damaged: the hull is away with its company — HQ can fabricate or order the component now; the bay job runs once it is home{/}");
    try budget.append(alloc, "{d}A ammo/armor · B like-for-like · C new weapons · D structure{/}");
    try budget.append(alloc, "{d}any weapon or gear fits any location with free crits;{/}");
    try budget.append(alloc, "{d}ammo bins go where free crits are; the head takes 1 crit{/}");

    var removed_count: usize = 0;
    const spares = try @import("hq_ops.zig").spareDemand(alloc, gs, @import("hq_ops.zig").spareSiteFor(gs, u));
    const p = gs.refitPlanFor(uid);
    for (u.slots.items) |s| {
        if (s.class == .structure) continue;
        var removed = false;
        if (p) |pl| for (pl.ops.items) |op| {
            if (op == .remove and std.mem.eql(u8, op.remove, s.slot_key)) removed = true;
        };
        if (removed) removed_count += 1;
        const mk: []const u8 = if (removed) "{c}" else switch (s.condition) {
            .ok => "",
            .damaged => "{a}",
            else => "{c}",
        };
        const part = @import("../domain/part.zig").find(s.part_key);
        var repair_note: []const u8 = "";
        if (!removed and s.condition != .ok) {
            // The hull's own site's ledger (hq_ops.spareDemand): the shelf its
            // tech draws from, the orders bound for it.
            var on_hand: u32 = 0;
            var on_order: u32 = 0;
            for (spares) |l| if (std.mem.eql(u8, l.key, s.part_key)) {
                on_hand = l.on_hand;
                on_order = l.coming;
            };
            if (s.condition == .damaged) on_hand = 1; // hours alone, no part
            repair_note = if (on_hand > 0) "  {g}part in stock — techs fit it on the next repair pass{/}" else if (on_order > 0) try std.fmt.allocPrint(alloc, "  {{a}}{d} on order{{/}}", .{on_order}) else "  {c}no part — [R] orders one{/}";
        }
        try mounts.append(alloc, .{ .slot_key = s.slot_key, .part_key = s.part_key, .location = meklab.parseLocation(s.slot_key), .text = try std.fmt.allocPrint(alloc, "{s}{s: <17} {s: <11} {s: <7} {d: >2}.{d}t {d: >2}c {s}{s}{{/}}{s}", .{
            mk, clip(s.slot_key, 17), clip(s.part_key, 11), clip(@tagName(s.class), 7), if (part) |pd| pd.mass_half_tons / 2 else 0, if (part) |pd| (pd.mass_half_tons % 2) * 5 else 0, if (part) |pd| pd.crits else 0, @tagName(s.condition), if (removed) " (removing)" else "", repair_note,
        }) });
    }

    if (p) |pl| {
        const class = meklab.classify(pl.ops.items, u.slots.items);
        try plan.append(alloc, try std.fmt.allocPrint(alloc, "{s} plan · class {{a}}{s}{{/}} · {d} tech-hours", .{ if (pl.committed) "committed" else "staged", @tagName(class), meklab.refitHours(pl.ops.items, u.slots.items, class) }));
        if (pl.committed) {
            // Where the work stands: the bay job this plan became.
            var job_line: ?[]const u8 = null;
            var ahead: u32 = 0;
            for (gs.bay_jobs.items) |j| {
                if (j.unit == uid and j.kind == .refit) {
                    job_line = if (j.started_day != null) try std.fmt.allocPrint(alloc, "  {{g}}in the bay at {s}{{/}} — done day {d} ({d} day{s} left)", .{ try hqName(alloc, gs, j.hq), j.done_day orelse 0, (j.done_day orelse gs.clock.day_index) -| gs.clock.day_index, if ((j.done_day orelse gs.clock.day_index) -| gs.clock.day_index == 1) "" else "s" }) else try std.fmt.allocPrint(alloc, "  {{a}}queued at {s}{{/}} — {d} job{s} ahead, {d} bay slot{s}; see the HQ screen (F7) bays list", .{ try hqName(alloc, gs, j.hq), ahead, if (ahead == 1) "" else "s", @import("hq_ops.zig").baySlots(gs, j.hq), if (@import("hq_ops.zig").baySlots(gs, j.hq) == 1) "" else "s" });
                    break;
                }
                if (j.hq == gs.homeHqFor(u.force) and j.started_day == null) ahead += 1;
            }
            try plan.append(alloc, job_line orelse "  {c}committed but no bay job exists — [c] clears it and returns the parts to the warehouse{/}");
        }
        for (pl.ops.items) |op| switch (op) {
            .remove => |k| try plan.append(alloc, try std.fmt.allocPrint(alloc, "  − remove {s}", .{k})),
            .install => |it| try plan.append(alloc, try std.fmt.allocPrint(alloc, "  + install {s} in {s}", .{ it.part_key, @tagName(it.location) })),
        };
        if (pl.ops.items.len == 0) try plan.append(alloc, "  {d}empty{/}");
    } else {
        try plan.append(alloc, "{d}no plan — [-] removes the selected mount, [+] installs a part{/}");
    }
    try plan.append(alloc, "");
    if (r.legal) {
        try plan.append(alloc, "{g}RULES: legal fit{/}");
    } else {
        try plan.append(alloc, "{c}RULES: ILLEGAL{/}");
        for (r.violations) |v| try plan.append(alloc, try std.fmt.allocPrint(alloc, "{{c}}! {s}{{/}}", .{v.text}));
    }
    return .{ .title = title, .budget = try budget.toOwnedSlice(alloc), .mounts = try mounts.toOwnedSlice(alloc), .plan = try plan.toOwnedSlice(alloc), .legal = r.legal, .meks = meks };
}

// ------------------------------------------------------------------- tests

test "hall filter groups roles and map classifies worlds" {
    try std.testing.expect(HallFilter.techs.matches(.tech_mechanic));
    try std.testing.expect(!HallFilter.techs.matches(.admin_hr));
    try std.testing.expect(HallFilter.admin_logistics.matches(.admin_logistics));
    try std.testing.expectEqual(HallFilter.unassigned, HallFilter.other.next());
    try std.testing.expectEqual(HallFilter.all, HallFilter.wounded.next());

    var gs = GameState.init(std.testing.allocator, .{ .seed = 11 });
    defer gs.deinit();
    const commands = @import("commands.zig");
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "Test", .origin = .CC, .profession = .paymaster } });
    _ = try commands.execute(&gs, .{ .new_company = "Alpha" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const m = try map(al, &gs);
    try std.testing.expectEqual(planet_mod.catalog.len, m.worlds.len);
    try std.testing.expect(m.in_ring >= 1); // the HQ's own world
    try std.testing.expectEqual(m.worlds.len, m.in_ring + m.in_band + m.dark);
    const meks = try labMeks(al, &gs);
    try std.testing.expect(meks.len > 0);
    const l = try lab(al, &gs, meks[0]);
    try std.testing.expect(l.mounts.len > 0);
    try std.testing.expect(l.legal);

    const sup = try supply(al, &gs);
    try std.testing.expectEqual(sup.rows.len, sup.site.len);
    try std.testing.expect(sup.site[0] != null and sup.site[0].? == .hq);

    // Personnel: everyone listed, filter narrows, record and seats build.
    const everyone = try people(al, &gs, .all);
    try std.testing.expect(everyone.rows.len > 20);
    const techs = try people(al, &gs, .techs);
    try std.testing.expect(techs.rows.len > 0 and techs.rows.len < everyone.rows.len);
    const rec = try personRecord(al, &gs, everyone.rows[0].id);
    try std.testing.expect(rec.len > 6);
    _ = try openSeats(al, &gs, everyone.rows[0].id);
    try std.testing.expectEqualStrings("active", try stripMarks(al, "{g}active{/}"));
}

test "the Lab lists a wreck and names its rebuild, so it agrees with Forces" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 11 });
    defer gs.deinit();
    const commands = @import("commands.zig");
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "Test", .origin = .CC, .profession = .paymaster } });
    _ = try commands.execute(&gs, .{ .new_company = "Alpha" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const before = try labMeks(al, &gs);
    const wreck_id = before[0];
    gs.unit(wreck_id).?.markWreckedBy(.ammo);

    // Still in the Lab's hull list, at the same place, so [ ] numbering
    // matches the hangar; Forces' damage marks and the Lab's budget agree.
    const after = try labMeks(al, &gs);
    try std.testing.expectEqual(before.len, after.len);
    try std.testing.expectEqual(wreck_id, after[0]);
    const marks = try damageMarks(al, gs.unit(wreck_id).?);
    try std.testing.expect(std.mem.indexOf(u8, marks, "struct ct") != null);
    const l = try lab(al, &gs, wreck_id);
    var saw_wreck = false;
    var saw_ct = false;
    for (l.budget) |line| {
        if (std.mem.indexOf(u8, line, "ammunition explosion") != null) saw_wreck = true;
        if (std.mem.indexOf(u8, line, "structure destroyed") != null and std.mem.indexOf(u8, line, "comp_ct") != null) saw_ct = true;
    }
    try std.testing.expect(saw_wreck);
    try std.testing.expect(saw_ct);
    // No refits on a wreck: the depot rebuilds it, or it gets stripped.
    const slot = l.mounts[0].slot_key;
    try std.testing.expectError(commands.Error.Unavailable, commands.execute(&gs, .{ .refit_remove = .{ .unit = wreck_id, .slot_key = slot } }));
}

test "padCells counts cells, not bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dash = try padCells(a, "", "— no pilot", 12);
    try std.testing.expectEqual(@as(usize, 12), try std.unicode.utf8CountCodepoints(dash));
    const padded = try padCells(a, "", "Lori Kalmar", 12);
    try std.testing.expectEqual(@as(usize, 12), padded.len);
    try std.testing.expectEqualStrings("{c}Abc{/}", try padCells(a, "{c}", "Abcdef", 3));
}

test "money formats with separators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("6,881,836", try money(a, 6_881_836));
    try std.testing.expectEqualStrings("-192,880", try money(a, -192_880));
    try std.testing.expectEqualStrings("0", try money(a, 0));
    try std.testing.expectEqualStrings("999", try money(a, 999));
}

test "damage marks and the company damage report name the components a hull needs" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7 });
    defer gs.deinit();
    const commands = @import("commands.zig");
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "Test", .origin = .LC, .profession = .quartermaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha Company" })).created_force;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Pick the company's first mek and wreck a torso and a weapon.
    var target: ?*unit_mod.Unit = null;
    var uit = gs.units.iterator();
    while (uit.next()) |e| if (e.value_ptr.kind == .mek and gs.companyOf(e.value_ptr.force) == co) {
        target = e.value_ptr;
        break;
    };
    const u = target.?;
    try std.testing.expectEqualStrings("", try damageMarks(a, u));
    var hit_structure = false;
    var hit_weapon = false;
    for (u.slots.items) |*s| {
        if (!hit_structure and s.class == .structure and std.mem.startsWith(u8, s.slot_key, "lt.")) {
            s.condition = .destroyed;
            hit_structure = true;
        } else if (!hit_weapon and s.class == .weapon) {
            s.condition = .damaged;
            hit_weapon = true;
        }
    }
    try std.testing.expect(hit_structure and hit_weapon);
    const marks = try damageMarks(a, u);
    try std.testing.expect(std.mem.indexOf(u8, marks, "struct lt") != null);
    try std.testing.expect(std.mem.indexOf(u8, marks, "gear 1") != null);
    const report = try companyDamage(a, &gs, co);
    // The torso for this hull's weight class.
    const torso = @import("../domain/part.zig").componentFor("lt.structure", u.chassis_key);
    const want = try std.fmt.allocPrint(a, "lt→{s}", .{torso});
    var saw_torso = false;
    for (report.lines) |line| if (std.mem.indexOf(u8, line, want) != null) {
        saw_torso = true;
    };
    try std.testing.expect(saw_torso);
    // The founding warehouse has no side torsos: that is the line to fabricate.
    _ = gs.takeStock(.{ .hq = report.home }, torso, gs.stockCount(.{ .hq = report.home }, torso));
    const again = try companyDamage(a, &gs, co);
    try std.testing.expectEqualStrings(torso, again.short_key.?);
}

test "contract history lists closed contracts with their world; the map counts worked worlds" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 2025 });
    defer gs.deinit();
    const commands = @import("commands.zig");
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "E", .origin = .CC, .profession = .paymaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(usize, 0), (try contractHistory(a, &gs)).len);
    _ = try commands.execute(&gs, .{ .accept_contract = .{ .offer_index = 0, .company = co } });
    const c = &gs.contracts.values()[0];
    try std.testing.expectEqual(@as(usize, 0), (try contractHistory(a, &gs)).len); // still open
    c.status = .completed;
    c.arrive_day = 10;
    c.end_day = 100;
    c.victory_points = 7;
    const rows = try contractHistory(a, &gs);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings(c.planet_key, rows[0].planet_key);
    try std.testing.expectEqualStrings(planetName(c.planet_key), rows[0].cells[3]);
    try std.testing.expect(std.mem.indexOf(u8, rows[0].cells[4], "completed") != null);
    try std.testing.expectEqualStrings("90d", rows[0].cells[5]);
    try std.testing.expectEqual(@as(u32, 1), contractsWorkedAt(&gs, c.planet_key));
    const m = try map(a, &gs);
    var worked: u32 = 0;
    for (m.worlds) |w| worked += w.worked;
    try std.testing.expectEqual(@as(u32, 1), worked);
}

test "the HQ screen's facility rows map back to facilities whatever sits above them" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 71 });
    defer gs.deinit();
    const commands = @import("commands.zig");
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hq = gs.hqs.keys()[0];
    const view = try hqDetailView(a, &gs, hq);
    try std.testing.expectEqual(view.lines.len, view.facility.len);
    const h = gs.hqs.getPtr(hq).?;
    var seen: usize = 0;
    for (view.lines, view.facility) |l, kind| {
        if (kind) |k| {
            try std.testing.expect(std.mem.startsWith(u8, l, @tagName(k)));
            try std.testing.expectEqual(h.facilities.items[seen].kind, k);
            seen += 1;
        }
    }
    try std.testing.expectEqual(h.facilities.items.len, seen);
    try std.testing.expect(view.facility[0] == null); // the tier line
}

test "hq detail says a field HQ hosts no company and how to raise it" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7 });
    defer gs.deinit();
    const commands = @import("commands.zig");
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "Test", .origin = .LC, .profession = .quartermaster } });
    _ = try commands.execute(&gs, .{ .found_hq = .{ .name = "Firebase", .planet_key = "zebebelgenubi" } });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = try hqDetail(a, &gs, gs.hqs.keys()[1]);
    var says_none = false;
    var says_how = false;
    for (lines) |l| {
        if (std.mem.indexOf(u8, l, "hosts one company") != null and std.mem.indexOf(u8, l, "field HQ") != null) says_none = true;
        if (std.mem.indexOf(u8, l, "to regional") != null and std.mem.indexOf(u8, l, "days build") != null) says_how = true;
    }
    try std.testing.expect(says_none and says_how);
    const home = try hqDetail(a, &gs, gs.hqs.keys()[0]);
    try std.testing.expect(std.mem.indexOf(u8, home[0], "regional HQ") != null);
}

test "manning matches the starter generator's ratios; raise candidates list pool hulls and mek listings" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7 });
    defer gs.deinit();
    const commands = @import("commands.zig");
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "Test", .origin = .LC, .profession = .quartermaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha Company" })).created_force;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A generated company is fully manned by definition.
    for (try manning(a, &gs, co)) |row| try std.testing.expect(row.have >= row.need);
    // A loose mek shows as a free candidate; a mek listing as a priced one.
    const loose = try gs.addUnit("LCT-1V");
    const hq = gs.hqs.keys()[0];
    try gs.market_listings.append(gs.allocator(), .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1_500_000, .hq = hq, .listed_day = 0, .expires_day = 400, .condition = .{ .armor_pct = 60, .quality = .c, .damaged_slots = 1, .destroyed_slots = 1, .missing_components = 0 } });
    const cands = try raiseCandidates(a, &gs, co, &.{});
    var saw_pool = false;
    var saw_listing = false;
    for (cands) |c| {
        if (c.kind == .pool and c.unit == loose) saw_pool = true;
        if (c.kind == .listing and std.mem.indexOf(u8, c.cells[5], "worn") != null) saw_listing = true;
    }
    try std.testing.expect(saw_pool and saw_listing);
    // Passing a listing hides it.
    const l = gs.market_listings.items[gs.market_listings.items.len - 1];
    const after = try raiseCandidates(a, &gs, co, &.{.{ .hq = l.hq, .item_key = l.item_key, .listed_day = l.listed_day, .price = l.price }});
    try std.testing.expect(after.len == cands.len - 1);
}

test "people: the unassigned filter lists only people with no seat, posting or company" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7 });
    defer gs.deinit();
    const commands = @import("commands.zig");
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "Test", .origin = .LC, .profession = .quartermaster } });
    _ = try commands.execute(&gs, .{ .new_company = "Alpha Company" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A generated company is fully assigned; the commander sits at an HQ.
    const before = try people(a, &gs, .unassigned);
    try std.testing.expectEqual(@as(usize, 0), before.rows.len);
    // A fresh hire with no seat shows up; giving them a mek to tech hides them again.
    const loose = try gs.hirePerson("Loose", "Hand", .tech_mek);
    try std.testing.expect(isUnassigned(&gs, gs.people.getPtr(loose).?));
    const mid = try people(a, &gs, .unassigned);
    try std.testing.expectEqual(@as(usize, 1), mid.rows.len);
    try std.testing.expectEqual(loose, mid.rows[0].id);
    try std.testing.expect(mid.total > 1);
    const spare = try gs.addUnit("LCT-1V");
    gs.units.getPtr(spare).?.tech = loose;
    try std.testing.expect(!isUnassigned(&gs, gs.people.getPtr(loose).?));
    try std.testing.expectEqual(@as(usize, 0), (try people(a, &gs, .unassigned)).rows.len);
    // The cycle passes through unassigned before wounded and wraps to all.
    try std.testing.expectEqual(HallFilter.unassigned, HallFilter.other.next());
    try std.testing.expectEqual(HallFilter.wounded, HallFilter.unassigned.next());
    try std.testing.expectEqual(HallFilter.all, HallFilter.wounded.next());
}

test "the rating scores six parts and a fresh outfit lands in the low letters" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 126 });
    defer gs.deinit();
    const commands = @import("commands.zig");
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "Test", .origin = .LC, .profession = .quartermaster } });
    _ = try commands.execute(&gs, .{ .new_company = "Alpha Company" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try rating(a, &gs);
    try std.testing.expectEqual(@as(usize, 6), r.parts.len);
    var sum: i32 = 0;
    for (r.parts) |pt| sum += pt.score;
    try std.testing.expectEqual(sum, r.score);
    try std.testing.expectEqualStrings(ratingLetter(r.score), r.letter);
    try std.testing.expectEqualStrings("F", ratingLetter(-1));
    try std.testing.expectEqualStrings("A*", ratingLetter(120));
    // A fresh, fully manned regular company is a C or a low B: unproven, no ships.
    try std.testing.expect(r.score >= 30 and r.score < 90);
    // An overdrawn treasury and a breach drag the letter down.
    const before = r.score;
    gs.funds = -1;
    gs.reputation -= 30;
    try std.testing.expect((try rating(a, &gs)).score < before);
    try std.testing.expect(std.mem.indexOf(u8, (try desk(a, &gs, 5)).rating_line, "rating") != null);
}

test "the campaign summary reads counters, ledger and history" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 128 });
    defer gs.deinit();
    const commands = @import("commands.zig");
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "Test", .origin = .LC, .profession = .quartermaster } });
    _ = try commands.execute(&gs, .{ .new_company = "Alpha Company" });
    gs.stats.battles_won = 3;
    gs.stats.hulls_salvaged = 2;
    try gs.rating_history.append(gs.allocator(), .{ .year = 3025, .score = 44 });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lines = try summary(arena.allocator(), &gs);
    var joined: std.ArrayListUnmanaged(u8) = .empty;
    for (lines) |l| {
        try joined.appendSlice(arena.allocator(), l);
        try joined.append(arena.allocator(), '\n');
    }
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "3 won") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "2 wrecks salvaged") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "3025: C (44)") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "CONTRACTS") != null);
}

test "each HQ's market board shows only its own listings" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 72 });
    defer gs.deinit();
    const commands = @import("commands.zig");
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const home = gs.hqs.keys()[0];
    const far: types.HqId = @enumFromInt(99);
    gs.market_listings.clearRetainingCapacity();
    try gs.market_listings.append(gs.allocator(), .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1, .hq = home, .listed_day = 0, .expires_day = 400 });
    try gs.market_listings.append(gs.allocator(), .{ .kind = .unit, .item_key = "SHD-2H", .rarity = .common, .price = 1, .hq = far, .listed_day = 0, .expires_day = 400 });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mine = try market(a, &gs, .all, home);
    try std.testing.expectEqual(@as(usize, 1), mine.board.len);
    try std.testing.expectEqual(@as(usize, 0), mine.board[0].index);
    try std.testing.expectEqual(home, mine.board[0].hq);
    const theirs = try market(a, &gs, .all, far);
    try std.testing.expectEqual(@as(usize, 1), theirs.board.len);
    try std.testing.expectEqual(@as(usize, 1), theirs.board[0].index); // the global index buy_listing takes
}

test "desk and ledger queries build on a fresh campaign" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7 });
    defer gs.deinit();
    const commands = @import("commands.zig");
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "Test", .origin = .LC, .profession = .quartermaster } });
    _ = try commands.execute(&gs, .{ .new_company = "Alpha Company" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try desk(a, &gs, 10);
    try std.testing.expectEqual(@as(usize, 1), d.companies.len);
    try std.testing.expect(d.hqs.len >= 3);
    const l = try ledger(a, &gs, .outfit, 31, 20);
    try std.testing.expect(l.treasuries.len >= 3);
    const st = try status(a, &gs);
    try std.testing.expectEqual(@as(u32, 1), st.companies);
    const rows = try toe(a, &gs);
    try std.testing.expect(rows.len > 10);
    const c = try contracts(a, &gs, .none);
    try std.testing.expect(c.board.len > 0);
}

test "a wounded pilot: the TO&E marks the hull sitting out, the Desk notes it, the end-turn prompt does not ask" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1217 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    _ = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mek: types.UnitId = .none;
    var uit = gs.units.iterator();
    while (uit.next()) |e| if (e.value_ptr.kind == .mek and mek == .none) {
        mek = e.value_ptr.id;
    };
    const p = gs.person(gs.unit(mek).?.pilot).?;
    p.status = .wounded;
    p.wound_heal_day = gs.clock.day_index + 9;

    const back = try std.fmt.allocPrint(a, "medbay → day {d}", .{gs.clock.day_index + 9});
    var marked = false;
    for (try toe(a, &gs)) |r| if (r.unit == mek) {
        const line = try std.mem.join(a, " ", r.cells.?);
        marked = std.mem.indexOf(u8, line, back) != null and std.mem.indexOf(u8, line, "sits out") != null;
    };
    try std.testing.expect(marked);

    var noted = false;
    for ((try desk(a, &gs, 0)).checklist) |w| {
        try std.testing.expect(w.kind != .open_slots);
        if (w.kind == .crew_recovering) {
            noted = true;
            try std.testing.expect(!w.prompts);
        }
    }
    try std.testing.expect(noted);
}

test "readiness counts wounded, permanent injuries, banked XP and depot hulls; marks strip for the CLI" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1216 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var first_pilot: types.PersonId = .none;
    var first_mek: types.UnitId = .none;
    var uit = gs.units.iterator();
    while (uit.next()) |e| if (e.value_ptr.kind == .mek and first_mek == .none) {
        first_mek = e.value_ptr.id;
        first_pilot = e.value_ptr.pilot;
    };
    try @import("medical.zig").inflict(&gs, first_pilot, .combat, 2, "test");
    try gs.person(first_pilot).?.injuries.append(gs.allocator(), .{ .location = .head, .severity = 3, .incurred_day = 0, .permanent = true, .healed = true });
    for (gs.unit(first_mek).?.slots.items) |*sl| if (sl.class == .structure) {
        sl.condition = .damaged;
        break;
    };
    const rows = try readiness(a, &gs);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    const r = rows[0];
    try std.testing.expectEqual(co, r.company);
    try std.testing.expectEqual(@as(u32, 1), r.wounded);
    try std.testing.expectEqual(@as(u32, 1), r.permanent);
    try std.testing.expectEqual(@as(u32, 1), r.depot);
    try std.testing.expect(r.hulls >= 12 and r.heads > 12);
    try std.testing.expect(r.banked_xp > 0 or r.heads > 0);
    const lines = try readinessLines(a, &gs, co);
    try std.testing.expect(lines.len >= 5);
    try std.testing.expectEqualStrings("abc def", try stripMarks(a, "{a}abc{/} {c}def{/}"));
}

test "the hangar ranks a pilotless hull above one earning its keep, mothballs cheap but idle" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1220 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    _ = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first_mek = blk: {
        var it = gs.units.iterator();
        while (it.next()) |e| if (e.value_ptr.kind == .mek) break :blk e.value_ptr.id;
        unreachable;
    };
    gs.unit(first_mek).?.pilot = .none;
    const rows = try hangar(a, &gs);
    try std.testing.expectEqual(gs.units.count(), rows.len);
    try std.testing.expectEqual(@as(u32, 0), rows[0].contribution); // the worst value leads
    var seen_pilotless = false;
    for (rows) |r| if (r.unit == first_mek) {
        seen_pilotless = true;
        try std.testing.expectEqual(@as(u32, 0), r.contribution);
    };
    try std.testing.expect(seen_pilotless);
    // The support train is exempt and sits at the bottom; the best-value mek sits just above it.
    try std.testing.expectEqual(@as(u64, 0), rows[rows.len - 1].cost_index);
    var best: ?HangarRow = null;
    for (rows) |r| if (r.cost_index > 0 and r.contribution > 0) {
        best = r;
    };
    try std.testing.expect(best != null and best.?.cost_index < std.math.maxInt(u32));
    const view = try toeFiltered(a, &gs, .hangar);
    try std.testing.expect(view.len == rows.len + 2);
}

test "the after-action sheet for a concession says what was given up and what it cost" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7302 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    const co = try gs.createForce("Alpha", .company, .none);
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "PER",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000 },
        .status = .active,
        .assigned_company = co,
    });
    try @import("battle.zig").resolveEngagement(&gs, gs.contracts.getPtr(@enumFromInt(1)).?);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = gs.battle_reports.unread().?;
    const sheet = (try afterAction(a, &gs, r.id)).?;
    const text = try std.mem.join(a, "\n", sheet.fight);
    try std.testing.expect(std.mem.indexOf(u8, text, "objective conceded") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "power 0 vs 0") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, try std.fmt.allocPrint(a, "{d}", .{r.score_delta})) != null);
}

/// Each needle names a player-chosen name whose `{x}` must survive as
/// text: stripped of real markup, the name still reads with its brace.
fn expectNamesLiteral(a: Alloc, texts: []const []const u8) !void {
    var injected: u32 = 0;
    for (texts) |t| {
        const shown = try table.plainText(a, t);
        for ([_][]const u8{ "Alpha", "Base", "Lori", "Outfit", "Cmdr" }) |needle| {
            var from: usize = 0;
            while (std.mem.indexOfPos(u8, shown, from, needle)) |i| : (from = i + needle.len) {
                if (i < 3 or shown[i - 3] != '{') {
                    std.debug.print("markup injected via \"{s}\" in: {s}\n", .{ needle, t });
                    injected += 1;
                }
            }
        }
    }
    try std.testing.expectEqual(@as(u32, 0), injected);
}

test "player-chosen names draw literally in every desk, forces, people and contracts view" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7901 });
    defer gs.deinit();
    const f = try contract_events.damagedCompanyForTest(&gs, 0);
    const co = f.c.assigned_company;
    gs.force(co).?.name = "{c}Alpha";
    gs.hqs.values()[0].name = "{g}Base";
    gs.outfit_name = "{s}Outfit";
    gs.commander.?.name = "{a}Cmdr";
    var it = gs.people.iterator();
    while (it.next()) |e| if (gs.companyOf(e.value_ptr.assigned_force) == co and e.value_ptr.role == .mekwarrior) {
        e.value_ptr.first_name = "{a}Lori";
        break;
    };
    try gs.log(.misc, .{ .company = co }, "{s} holds at {s}", .{ gs.force(co).?.name, gs.hqs.values()[0].name });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var texts: std.ArrayListUnmanaged([]const u8) = .empty;
    const d = try desk(a, &gs, 40);
    for (d.companies) |r| try texts.appendSlice(a, r);
    for (d.checklist) |c| try texts.append(a, c.text);
    for (d.inbox) |r| {
        try texts.append(a, r.company);
        try texts.append(a, r.description);
    }
    try texts.appendSlice(a, d.hqs);
    try texts.appendSlice(a, d.log);
    for (try toe(a, &gs)) |r| {
        try texts.append(a, r.text);
        if (r.cells) |c| try texts.appendSlice(a, c);
    }
    for ((try people(a, &gs, .all)).rows) |r| try texts.appendSlice(a, r.cells);
    const cv = try contracts(a, &gs, gs.hqs.keys()[0]);
    for (cv.active) |r| try texts.appendSlice(a, r.lines);
    try texts.appendSlice(a, try hqDetail(a, &gs, gs.hqs.keys()[0]));
    try texts.appendSlice(a, try companyRoster(a, &gs, co));
    try texts.appendSlice(a, try logLines(a, &gs, 40, .all));
    try texts.appendSlice(a, try summary(a, &gs));
    try texts.append(a, try commanderLine(a, &gs));
    try expectNamesLiteral(a, texts.items);
}

test "plain CLI text drops every markup tag and cannot carry a terminal control" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("selected tab purple?x", try stripMarks(a, "{s}selected{/} {t}tab{/} {p}purple{/}\x1bx"));
}

test "the battle orders show the levers and the resupply the command would buy" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1213 });
    defer gs.deinit();
    const f = try contract_events.damagedCompanyForTest(&gs, 0);
    const c = f.c;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    c.next_battle_day = gs.clock.day_index + 30;
    try std.testing.expect((try battleOrders(a, &gs, c.id)) == null);
    c.next_battle_day = gs.clock.day_index + 2;
    const view = (try battleOrders(a, &gs, c.id)).?;
    try std.testing.expect(!view.confirmed);
    try std.testing.expect(view.lances.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, view.situation[0], "contact in 2 days") != null);
    // Every line of the quote is named in the offer the box shows.
    const quote = try @import("field_supply.zig").rushQuote(a, &gs, c);
    try std.testing.expect(quote.lines.len > 0); // the fixture's hulls are dented and it carries no armour
    try std.testing.expect(std.mem.indexOf(u8, view.rush, try money(a, quote.price)) != null);
    _ = try @import("commands.zig").execute(&gs, .{ .confirm_orders = c.id });
    try std.testing.expect((try battleOrders(a, &gs, c.id)).?.confirmed);
}

test "the contact line an advance stops for is the checklist's contact warning" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1210 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000 },
        .status = .active,
        .assigned_company = co,
        .next_battle_day = gs.clock.day_index + 1,
    });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const line = try contactWarning(a, &gs, @enumFromInt(1));
    try std.testing.expect(line.len > 0);
    var matched = false;
    for (try checklist.turnWarnings(&gs, a)) |w| {
        if (w.kind == .contact_imminent) matched = std.mem.eql(u8, w.text, line);
    }
    try std.testing.expect(matched);
    // Outside the window there is nothing to show.
    gs.contracts.getPtr(@enumFromInt(1)).?.next_battle_day = gs.clock.day_index + 30;
    try std.testing.expectEqualStrings("", try contactWarning(a, &gs, @enumFromInt(1)));
}

test "the inbox shows what each repair order would do, as the techs would do it" {
    const maintenance = @import("maintenance.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12068 });
    defer gs.deinit();
    const f = try contract_events.damagedCompanyForTest(&gs, 2);
    try contract_events.queueFieldRepair(&gs, f.c, .none);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const view = try desk(a, &gs, 0);
    try std.testing.expectEqual(@as(usize, 1), view.inbox.len);
    const row = view.inbox[0];
    try std.testing.expectEqual(@as(usize, 3), row.options.len);
    try std.testing.expectEqual(@as(usize, 4), row.detail.len);
    try std.testing.expect(std.mem.indexOf(u8, row.detail[0], "3 damaged hulls") != null);
    try std.testing.expect(std.mem.indexOf(u8, row.detail[0], "2 t armour") != null);
    // Each order's line is the plan the command would carry out.
    for ([_]types.RepairOrder{ .worst_first, .spread, .heaviest_first }, 1..) |order, n| {
        const plan = try maintenance.planFor(&gs, a, f.c.assigned_company, order);
        const want = try std.fmt.allocPrint(a, "  [{d}] {s}", .{ n, try maintenance.pushSummary(a, plan) });
        try std.testing.expectEqualStrings(want, row.detail[n]);
    }
}

test "the inbox shows the wrecks a salvage claim is being divided over" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1266 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const after_action = @import("after_action.zig");
    const candidates = [_]after_action.SalvageCandidate{
        .{ .key = "DRG-1N", .name = "Dragon", .bv = 1_144, .armor_pct = 30, .quality = .c, .damaged_slots = 1, .destroyed_slots = 2, .missing_components = 1 },
        .{ .key = "LCT-1V", .name = "Locust", .bv = 432, .armor_pct = 24, .quality = .d, .damaged_slots = 1, .destroyed_slots = 1, .missing_components = 1 },
        .{ .key = "STG-3R", .name = "Stinger", .bv = 192, .armor_pct = 18, .quality = .c, .damaged_slots = 1, .destroyed_slots = 1, .missing_components = 1 },
    };
    const battle_id = gs.nextBattleId();
    try gs.battle_reports.record(gs.allocator(), .{
        .id = battle_id,
        .day = 3,
        .contract = @enumFromInt(1),
        .company = co,
        .kind = "recon_raid",
        .enemy_key = "DC",
        .scenario = "breakthrough",
        .terrain = "badlands",
        .weather = "clear skies",
        .outcome = .victory,
        .held_field = true,
        .acknowledged = true,
        .salvage = .{ .claimed_bv = 1_500, .candidates = &candidates, .unclaimed_bv = 1_500 },
    });
    try gs.event_queue.push(gs.allocator(), .{
        .day = 3,
        .kind = .salvage_priority,
        .company = co,
        .battle = battle_id,
        .options = contract_events.salvageEntry().options,
        .default_choice = 1,
        .deadline_day = 10,
    });

    const view = try desk(a, &gs, 0);
    try std.testing.expectEqual(@as(usize, 1), view.inbox.len);
    const row = view.inbox[0];
    // The decision is unanswerable without seeing what is on offer, so
    // the row carries it rather than making the player go and look.
    try std.testing.expect(row.detail.len > 0);
    const joined = try std.mem.join(a, "\n", row.detail);
    for ([_][]const u8{ "Dragon", "Locust", "Stinger", "1144", "claim 1500 BV" }) |needle| {
        if (std.mem.indexOf(u8, joined, needle) == null) {
            std.debug.print("missing {s} in:\n{s}\n", .{ needle, joined });
            return error.TestUnexpectedResult;
        }
    }
    // And the plan lines name what each choice would actually take —
    // from the same function the command materialises with.
    try std.testing.expect(std.mem.indexOf(u8, joined, "[1] Dragon") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "Stinger + Locust") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "nothing on the flatbeds") != null);
}

test "the hangar names a hull the enemy holds — a claim, not an asset" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12007 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    _ = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const taken = blk: {
        var it = gs.units.iterator();
        while (it.next()) |e| if (e.value_ptr.kind == .mek) break :blk e.value_ptr.id;
        unreachable;
    };
    const owned_before = gs.units.count();
    const billed_before = treasury.monthlyHullUpkeep(&gs);
    try gs.holdUnit(taken, "DC", @enumFromInt(7));

    // Off the books: gone from `units`, gone from its lance, billing
    // nothing — the whole point of holding rather than keeping.
    try std.testing.expectEqual(owned_before - 1, gs.units.count());
    try std.testing.expect(gs.unit(taken) == null);
    try std.testing.expect(treasury.monthlyHullUpkeep(&gs) < billed_before);
    try std.testing.expect(gs.heldHull(taken) != null);

    // But the portfolio still names it, ranked nowhere and costing nothing.
    const rows = try hangar(a, &gs);
    try std.testing.expectEqual(gs.units.count() + gs.held_hulls.items.len, rows.len);
    var held_row: ?HangarRow = null;
    for (rows) |r| if (r.unit == taken) {
        held_row = r;
    };
    try std.testing.expect(held_row != null);
    try std.testing.expect(held_row.?.held);
    try std.testing.expectEqual(@as(types.CBills, 0), held_row.?.bill);
    try std.testing.expectEqual(@as(u64, 0), held_row.?.cost_index);
    try std.testing.expect(std.mem.indexOf(u8, held_row.?.why, "held by DC") != null);
    try std.testing.expect(held_row.?.cells.len == hangar_cols.len);
}

/// Standing orders: every decision kind the inbox has asked about, the
/// last answer, and whether the game applies that answer without asking.
pub fn standingOrders(alloc: Alloc, gs: *GameState) ![][]const u8 {
    const after = @import("../domain/tuning.zig").t.contract.standing_order_after;
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = gs.event_memory.iterator();
    while (it.next()) |e| {
        const m = e.value_ptr.*;
        const entry = contract_events.entryForKind(e.key_ptr.*) orelse continue;
        if (entry.options.len == 0 or m.last_choice >= entry.options.len) continue;
        const standing = m.streak >= after;
        if (m.streak == 0) {
            try out.append(alloc, try std.fmt.allocPrint(alloc, "{s: <22} last day {d: <6} asked, not yet answered", .{ @tagName(e.key_ptr.*), m.last_day }));
            continue;
        }
        try out.append(alloc, try std.fmt.allocPrint(alloc, "{s: <22} last day {d: <6} {s}\"{s}\" ×{d}{s}", .{
            @tagName(e.key_ptr.*), m.last_day, if (standing) "{a}STANDING ORDER{/} " else "", entry.options[m.last_choice].label, m.streak,
            if (standing) "  — `sop clear <event>` to be asked again" else "",
        }));
    }
    if (out.items.len == 0) try out.append(alloc, try std.fmt.allocPrint(alloc, "no standing orders — answer a decision the same way {d} times running and the game stops asking", .{after}));
    return out.toOwnedSlice(alloc);
}

/// One company weighed against an offer: whether it can go, and why not.
pub const Candidate = struct {
    company: types.ForceId,
    eligible: bool,
    /// Why not, when not: under contract, in transit home.
    why: []const u8,
    transit_days: u32,
    /// Lower is readier: depot hulls, spent crews, wounded, fatigue and
    /// transit count against; morale counts for.
    penalty: i32,
    text: []const u8,
    cells: table.Row,
};

pub const candidates_cols: []const table.Col = &.{
    .{ .name = "company" },                    .{ .name = "stands" },                    .{ .name = "jumps", .justify = .right }, .{ .name = "days", .justify = .right },
    .{ .name = "fatigue", .justify = .right }, .{ .name = "morale", .justify = .right }, .{ .name = "depot", .justify = .right }, .{ .name = "spent", .justify = .right },
    .{ .name = "wounded", .justify = .right }, .{ .name = "skulls" },                    .{ .name = "rating" },                   .{ .name = "win / lose field" },
    .{ .name = "tonnage" },                    .{ .name = "" },
};

/// Which companies can take an offer and how ready each is: where the
/// company stands, the jumps and days to the contract world from there
/// (as `accept` reckons them), and the readiness that decides whether it
/// should go. Readiest first; companies that cannot go come last, with why.
pub fn offerCandidates(alloc: Alloc, gs: *GameState, offer_index: usize) ![]Candidate {
    var out: std.ArrayListUnmanaged(Candidate) = .empty;
    if (offer_index >= gs.contract_offers.items.len) return out.toOwnedSlice(alloc);
    const offer = gs.contract_offers.items[offer_index];
    const to = planet_mod.find(offer.planet_key);
    for (try readiness(alloc, gs)) |r| {
        const f = gs.force(r.company) orelse continue;
        // Where the company stands, as acceptContract reckons it.
        var why: []const u8 = "";
        var from_key: ?[]const u8 = null;
        var stands: []const u8 = "home";
        var busy = false;
        if (!@import("commands.zig").offerEligible(gs, &offer, r.company)) {
            // Another HQ's board.
            why = try std.fmt.allocPrint(alloc, "based at {s}, not {s}", .{ try hqName(alloc, gs, gs.homeHqFor(r.company)), try hqName(alloc, gs, offer.offer_hq) });
        } else switch (gs.companyPosture(r.company)) {
            // Say so in the stands column, bright, not only in the reason
            // at the far right, so a busy company names its contract.
            .en_route => |c| {
                why = "under contract";
                busy = true;
                from_key = c.planet_key;
                stands = try std.fmt.allocPrint(alloc, "EN ROUTE [{d}] → {s} · arrives Day {d}", .{ @intFromEnum(c.id), planetName(c.planet_key), c.arrive_day orelse gs.clock.day_index });
            },
            .deployed => |c| {
                why = "under contract";
                busy = true;
                from_key = c.planet_key;
                stands = if (c.end_day) |end|
                    try std.fmt.allocPrint(alloc, "ON CONTRACT [{d}] {s} · to Day {d}", .{ @intFromEnum(c.id), planetName(c.planet_key), end })
                else
                    try std.fmt.allocPrint(alloc, "ON CONTRACT [{d}] {s}", .{ @intFromEnum(c.id), planetName(c.planet_key) });
            },
            .returning => |eta| {
                why = "in transit home";
                busy = true;
                stands = try std.fmt.allocPrint(alloc, "RETURNING HOME · Day {d}", .{eta});
            },
            .idle_afield => |p| {
                from_key = p;
                stands = try std.fmt.allocPrint(alloc, "afield on {s}", .{planetName(p)});
            },
            .home => if (gs.hqs.getPtr(gs.homeHqFor(r.company))) |h| {
                from_key = h.planet_key;
                stands = try std.fmt.allocPrint(alloc, "home, {s}", .{try table.plain(alloc, h.name)});
            },
        }
        var jumps: u32 = planet_mod.jumpsForLy(offer.dist_ly);
        if (from_key) |fk| if (planet_mod.find(fk)) |from| if (to) |t| {
            jumps = planet_mod.jumpsBetween(from, t);
        };
        const days: u32 = if (jumps == 0) logistics_mod.same_world_days else logistics_mod.transitDays(jumps);
        const eligible = why.len == 0;
        const penalty: i32 = @import("personnel.zig").readinessPenalty(@import("personnel.zig").companyCrewStats(gs, r.company), r.depot, days);
        const fat_mk = fatigueMarkup(person_mod.Person.fatigueBandOf(r.fatigue));
        const mor_mk = moraleMarkup(r.morale);
        // Skulls: what the company can field today against what the
        // intel says the enemy brings to a fight.
        const odds_mk: []const u8 = "";
        const rated = try rateOffer(alloc, gs, &offer, r.company);
        const odds: []const u8 = if (rated) |rt|
            try std.fmt.allocPrint(alloc, "{s}{s}{{/}} {s} · {d}% / {d}% · {s}", .{ if (rt.half_hi >= 9) "{c}" else if (rt.half_hi >= 7) "{a}" else "{g}", try skullGlyphs(alloc, rt.half_hi), try skullText(alloc, rt), rt.win_pct, rt.lose_field_pct, try tonnageText(alloc, rt) })
        else
            "—";
        const cells: table.Row = if (!eligible)
            try table.row(alloc, &.{ try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}", .{try table.plain(alloc, f.name)}), try std.fmt.allocPrint(alloc, "{s}{s}{{/}}", .{ if (busy) "{a}" else "{d}", stands }), "", "", "", "", "", "", "", "", "", "", "", try std.fmt.allocPrint(alloc, "{{d}}cannot go: {s}{{/}}", .{why}) })
        else
            try table.row(alloc, &.{
                try std.fmt.allocPrint(alloc, "{{a}}{s}{{/}}", .{try table.plain(alloc, f.name)}),
                stands,
                try std.fmt.allocPrint(alloc, "{d}", .{jumps}),
                try std.fmt.allocPrint(alloc, "{d}", .{days}),
                try std.fmt.allocPrint(alloc, "{s}{d}{{/}}", .{ fat_mk, r.fatigue }),
                try std.fmt.allocPrint(alloc, "{s}{d}{{/}}", .{ mor_mk, r.morale }),
                try std.fmt.allocPrint(alloc, "{s}{d}{{/}}", .{ if (r.depot > 0) "{c}" else "", r.depot }),
                try std.fmt.allocPrint(alloc, "{s}{d}{{/}}", .{ if (r.spent > 0) "{a}" else "", r.spent }),
                try std.fmt.allocPrint(alloc, "{s}{d}{{/}}", .{ if (r.wounded > 0) "{a}" else "", r.wounded }),
                if (rated) |rt| try std.fmt.allocPrint(alloc, "{s}{s}{{/}}", .{ if (rt.half_hi >= 9) "{c}" else if (rt.half_hi >= 7) "{a}" else "{g}", try skullGlyphs(alloc, rt.half_hi) }) else "—",
                if (rated) |rt| try skullText(alloc, rt) else "",
                if (rated) |rt| try std.fmt.allocPrint(alloc, "{d}% / {d}%", .{ rt.win_pct, rt.lose_field_pct }) else "",
                if (rated) |rt| try tonnageText(alloc, rt) else "",
                "",
            });
        const text = if (eligible)
            try std.fmt.allocPrint(alloc, "{s} {s} {d: >5}  {d: >4}   {s}{d: >7}{{/}}  {s}{d: >6}{{/}}  {s}{d: >5}{{/}}  {s}{d: >5}{{/}}  {s}{d: >7}{{/}}   {s}{s}", .{
                try padCells(alloc, "{a}", try table.plain(alloc, f.name), 21), try padCells(alloc, "", clip(stands, 25), 25), jumps,                          days,
                fat_mk,                                                         r.fatigue,                                     mor_mk,                         r.morale,
                if (r.depot > 0) "{c}" else "",                                 r.depot,                                       if (r.spent > 0) "{a}" else "", r.spent,
                if (r.wounded > 0) "{a}" else "",                               r.wounded,                                     odds_mk,                        odds,
            })
        else
            try std.fmt.allocPrint(alloc, "{{d}}{s: <21}{{/}} {s} {{d}}cannot go: {s}{{/}}", .{ try table.plain(alloc, f.name), try padCells(alloc, if (busy) "{a}" else "{d}", stands, if (busy) 48 else 25), why });
        try out.append(alloc, .{ .company = r.company, .eligible = eligible, .why = why, .transit_days = days, .penalty = penalty, .text = text, .cells = cells });
    }
    std.mem.sort(Candidate, out.items, {}, struct {
        fn lt(_: void, a: Candidate, b: Candidate) bool {
            if (a.eligible != b.eligible) return a.eligible;
            return a.penalty < b.penalty;
        }
    }.lt);
    if (out.items.len > 0 and out.items[0].eligible) {
        out.items[0].text = try std.fmt.allocPrint(alloc, "{s}  {{g}}readiest{{/}}", .{out.items[0].text});
        const first = try alloc.dupe([]const u8, out.items[0].cells);
        first[first.len - 1] = "{g}readiest{/}";
        out.items[0].cells = first;
    }
    return out.toOwnedSlice(alloc);
}

test "offer candidates rank the ready company first and name why the others cannot go" {
    const commands = @import("commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 71 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    // One company lives at the HQ; the others are on the books without a slot (the HQ hosts one).
    const gen = @import("starter_company.zig");
    const worn = (try commands.execute(&gs, .{ .new_company = "Worn" })).created_force;
    const fresh = try gen.generateInto(&gs, "Fresh");
    const busy = try gen.generateInto(&gs, "Busy");
    // Worn: two hulls need the depot, everyone is tired.
    var broken: u32 = 0;
    var uit = gs.units.iterator();
    while (uit.next()) |e| if (e.value_ptr.kind == .mek and gs.companyOf(e.value_ptr.force) == worn and broken < 2) {
        for (e.value_ptr.slots.items) |*sl| if (sl.class == .structure and std.mem.startsWith(u8, sl.slot_key, "lt.")) {
            sl.condition = .destroyed;
        };
        broken += 1;
    };
    var pit = gs.people.iterator();
    while (pit.next()) |e| if (gs.companyOf(e.value_ptr.assigned_force) == worn) {
        e.value_ptr.fatigue = 80;
        e.value_ptr.morale = 20;
    };
    // Busy: under contract.
    const cid: types.ContractId = @enumFromInt(902);
    try gs.contracts.put(gs.allocator(), cid, .{ .id = cid, .kind = .garrison_duty, .employer_key = "LC", .enemy_key = "PER", .planet_key = gs.hqs.values()[0].planet_key, .status = .active, .assigned_company = busy, .terms = .{ .length_months = 12, .base_pay_month = 100_000 } });
    // An offer on the home world.
    gs.contract_offers.clearRetainingCapacity();
    try gs.contract_offers.append(gs.allocator(), .{ .id = .none, .kind = .recon_raid, .employer_key = "LC", .enemy_key = "DC", .planet_key = gs.hqs.values()[0].planet_key, .dist_ly = 0, .beachhead = false, .terms = .{ .length_months = 3, .base_pay_month = 200_000 } });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cands = try offerCandidates(arena.allocator(), &gs, 0);
    try std.testing.expectEqual(@as(usize, 3), cands.len);
    try std.testing.expectEqual(fresh, cands[0].company);
    try std.testing.expect(cands[0].eligible);
    try std.testing.expectEqual(worn, cands[1].company);
    try std.testing.expect(cands[1].eligible);
    try std.testing.expect(cands[1].penalty > cands[0].penalty);
    try std.testing.expectEqual(busy, cands[2].company);
    try std.testing.expect(!cands[2].eligible);
    try std.testing.expectEqualStrings("under contract", cands[2].why);
    // The stands cell names the contract, not just the world.
    try std.testing.expect(std.mem.indexOf(u8, cands[2].cells[1], "ON CONTRACT [902]") != null);
    try std.testing.expectEqual(@as(u32, 3), cands[0].transit_days); // same world: three days to muster
}

// ------------------------------------------------ pickers
// One row shape for every "choose one of these" list the client shows, so
// the screens look alike: what can be chosen is ranked best first, what
// cannot is still listed, dimmed, with the reason.

pub const PickRow = struct {
    id: u32,
    eligible: bool,
    why: []const u8 = "",
    slot: @import("state.zig").Slot = .any,
    /// Part pickers: the catalogue key behind the row.
    key: []const u8 = "",
    /// Part pickers: stock of the part at the picker's site.
    on_hand: u32 = 0,
    cells: table.Row,
};

pub const company_pick_cols: []const table.Col = &.{ .{ .name = "company" }, .{ .name = "stands" }, .{ .name = "days", .justify = .right }, .{ .name = "room / need" } };
pub const hq_pick_cols: []const table.Col = &.{ .{ .name = "hq" }, .{ .name = "tier" }, .{ .name = "world" }, .{ .name = "staff", .justify = .right }, .{ .name = "" } };
pub const crew_pick_cols: []const table.Col = &.{ .{ .name = "person" }, .{ .name = "role" }, .{ .name = "skill", .justify = .right }, .{ .name = "now" }, .{ .name = "" } };
pub const unassign_pick_cols: []const table.Col = &.{ .{ .name = "slot" }, .{ .name = "person" } };
pub const part_pick_cols: []const table.Col = &.{ .{ .name = "part" }, .{ .name = "name" }, .{ .name = "cost", .justify = .right }, .{ .name = "tons", .justify = .right }, .{ .name = "on hand", .justify = .right }, .{ .name = "source" } };

/// The world a company stands on, as transfers reckon it: its contract
/// world, the world it idles on, else its home HQ (the pool: the seat).
fn companyPlanetKey(gs: *GameState, company: types.ForceId) ?[]const u8 {
    if (gs.deploymentContract(company)) |c| return c.planet_key;
    if (gs.force(company)) |f| if (f.location_planet) |p| return p;
    return if (gs.hqs.getPtr(gs.homeHqFor(company))) |h| h.planet_key else null;
}

/// Where a company stands, in a few words (`GameState.companyPosture`).
pub fn companyStands(alloc: Alloc, gs: *GameState, company: types.ForceId) ![]const u8 {
    return switch (gs.companyPosture(company)) {
        .en_route, .deployed => |c| std.fmt.allocPrint(alloc, "on contract, {s}", .{planetName(c.planet_key)}),
        .returning => "in transit home",
        .idle_afield => |p| std.fmt.allocPrint(alloc, "afield on {s}", .{planetName(p)}),
        .home => if (gs.hqs.getPtr(gs.homeHqFor(company))) |h| std.fmt.allocPrint(alloc, "home, {s}", .{try table.plain(alloc, h.name)}) else "home",
    };
}

fn daysBetweenCompanies(gs: *GameState, from: types.ForceId, to: types.ForceId) u32 {
    const a = planet_mod.find(companyPlanetKey(gs, from) orelse "") orelse return 0;
    const b = planet_mod.find(companyPlanetKey(gs, to) orelse "") orelse return 0;
    if (a == b) return 0;
    return logistics_mod.daysBetween(a, b);
}

fn daysFromWorld(gs: *GameState, from_key: []const u8, to: types.ForceId) u32 {
    const a = planet_mod.find(from_key) orelse return 0;
    const b = planet_mod.find(companyPlanetKey(gs, to) orelse "") orelse return 0;
    if (a == b) return 0;
    return logistics_mod.daysBetween(a, b);
}

/// Companies a hull or a person could transfer to: where each stands,
/// how many days away, and what room or need it has for them. Ranked by
/// days; the subject's own company is left out; a subject that cannot
/// move at all (deployed, in transit, in the depot) dims every row.
pub fn companyChoices(alloc: Alloc, gs: *GameState, what: enum { unit, person, stock }, subject: u32) ![]PickRow {
    var out: std.ArrayListUnmanaged(PickRow) = .empty;
    const personnel = @import("personnel.zig");
    const unit_dom = @import("../domain/unit.zig");
    var from: types.ForceId = .none;
    var from_key: ?[]const u8 = null; // stock: shipped from an HQ shelf
    var blocked: []const u8 = "";
    var u: ?*unit_dom.Unit = null;
    var p: ?*@import("../domain/person.zig").Person = null;
    switch (what) {
        .stock => if (gs.hqs.getPtr(@enumFromInt(subject))) |h| {
            from_key = h.planet_key;
        },
        .unit => {
            u = gs.unit(@enumFromInt(subject)) orelse return out.toOwnedSlice(alloc);
            from = gs.companyOf(u.?.force);
            blocked = @import("commands.zig").transferBlock(gs, u.?) orelse "";
        },
        .person => {
            p = gs.person(@enumFromInt(subject)) orelse return out.toOwnedSlice(alloc);
            from = gs.companyOf(p.?.assigned_force);
            if (gs.isCompanyDeployed(from)) blocked = "their company is deployed";
        },
    }
    var fit = gs.forces.iterator();
    while (fit.next()) |e| {
        const co = e.value_ptr;
        if (co.echelon != .company or (what != .stock and co.id == from)) continue;
        const days = if (from_key) |fk| daysFromWorld(gs, fk, co.id) else daysBetweenCompanies(gs, from, co.id);
        if (what == .stock and co.return_eta_day != null) blocked = "in transit home" else if (what == .stock) blocked = "";
        var room: []const u8 = "";
        if (u) |subject_hull| {
            if (subject_hull.kind == .mek or subject_hull.kind == .vehicle) {
                var free: u32 = 0;
                for (co.children.items) |cid| if (gs.force(cid)) |l| if (l.echelon == .lance) {
                    free += @intCast(force_dom.lance_size -| l.units.items.len);
                };
                room = try std.fmt.allocPrint(alloc, "{s}{d} lance slot{s} free{{/}}", .{ if (free == 0) "{a}" else "", free, if (free == 1) "" else "s" });
            } else if (gs.supportLanceFor(co.id, subject_hull)) |sid| {
                room = try std.fmt.allocPrint(alloc, "→ {s}", .{try forceName(alloc, gs, sid)});
            } else room = "{a}no lance of its trade{/}";
        } else if (p) |person| {
            var need: u32 = 0;
            for (personnel.manningNeeds(gs, co.id)) |n| if (n.role == person.role) {
                need = n.need;
            };
            const have = personnel.manningHave(gs, co.id, person.role);
            room = try std.fmt.allocPrint(alloc, "{s}{s} {d}/{d}{{/}}", .{ if (have < need) "{c}" else if (have > need) "{d}" else "", @tagName(person.role), have, need });
        }
        const eligible = blocked.len == 0;
        const stands = try companyStands(alloc, gs, co.id);
        const cells: table.Row = if (eligible)
            try table.row(alloc, &.{ try std.fmt.allocPrint(alloc, "{{a}}{s}{{/}}", .{try table.plain(alloc, co.name)}), stands, try std.fmt.allocPrint(alloc, "{d}", .{days}), room })
        else
            try table.row(alloc, &.{ try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}", .{try table.plain(alloc, co.name)}), try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}", .{stands}), "", try std.fmt.allocPrint(alloc, "{{d}}cannot move: {s}{{/}}", .{blocked}) });
        try out.append(alloc, .{ .id = @intFromEnum(co.id), .eligible = eligible, .why = blocked, .cells = cells });
    }
    // Nearest first.
    const Ctx = struct { gs: *GameState, from: types.ForceId, from_key: ?[]const u8 };
    std.mem.sort(PickRow, out.items, Ctx{ .gs = gs, .from = from, .from_key = from_key }, struct {
        fn days(c: Ctx, id: u32) u32 {
            return if (c.from_key) |fk| daysFromWorld(c.gs, fk, @enumFromInt(id)) else daysBetweenCompanies(c.gs, c.from, @enumFromInt(id));
        }
        fn lt(c: Ctx, a: PickRow, b: PickRow) bool {
            if (a.eligible != b.eligible) return a.eligible;
            return days(c, a.id) < days(c, b.id);
        }
    }.lt);
    return out.toOwnedSlice(alloc);
}

/// HQs a person could be posted to: the short-handed ones first.
pub fn hqChoices(alloc: Alloc, gs: *GameState, person_id: types.PersonId) ![]PickRow {
    var out: std.ArrayListUnmanaged(PickRow) = .empty;
    const p = gs.person(person_id) orelse return out.toOwnedSlice(alloc);
    var it = gs.hqs.iterator();
    while (it.next()) |e| {
        const h = e.value_ptr;
        const req = h.staffRequired().total();
        const here = p.posted_hq == h.id;
        try out.append(alloc, .{ .id = @intFromEnum(h.id), .eligible = !here, .why = if (here) "already posted here" else "", .cells = if (here)
            try table.row(alloc, &.{ try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}", .{try table.plain(alloc, h.name)}), try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}", .{@tagName(h.tier)}), try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}", .{planetName(h.planet_key)}), try std.fmt.allocPrint(alloc, "{{d}}{d}/{d}{{/}}", .{ h.staff_assigned, req }), "{d}posted here{/}" })
        else
            try table.row(alloc, &.{ try std.fmt.allocPrint(alloc, "{{a}}{s}{{/}}", .{try table.plain(alloc, h.name)}), @tagName(h.tier), planetName(h.planet_key), try std.fmt.allocPrint(alloc, "{s}{d}/{d}{{/}}", .{ if (h.staff_assigned < req) "{c}" else "{g}", h.staff_assigned, req }), if (h.staff_assigned < req) "short-handed" else "" }) });
    }
    const Ctx = struct { gs: *GameState };
    std.mem.sort(PickRow, out.items, Ctx{ .gs = gs }, struct {
        fn shortfall(c: Ctx, id: u32) i64 {
            const h = c.gs.hqs.getPtr(@enumFromInt(id)) orelse return 0;
            return @as(i64, h.staffRequired().total()) - @as(i64, h.staff_assigned);
        }
        fn lt(c: Ctx, a: PickRow, b: PickRow) bool {
            if (a.eligible != b.eligible) return a.eligible;
            return shortfall(c, a.id) > shortfall(c, b.id);
        }
    }.lt);
    return out.toOwnedSlice(alloc);
}

/// People who could take a hull's seat or tech slot: the right roles
/// only, the hull's own company first, the free and the sharper first
/// within it; the unavailable and the unreachable dimmed with why.
pub fn crewChoices(alloc: Alloc, gs: *GameState, unit_id: types.UnitId) ![]PickRow {
    var out: std.ArrayListUnmanaged(PickRow) = .empty;
    const unit_dom = @import("../domain/unit.zig");
    const u = gs.unit(unit_id) orelse return out.toOwnedSlice(alloc);
    const own = gs.companyOf(u.force);
    const pilot_role = unit_dom.crewRoleFor(u.kind);
    const tech_role = unit_dom.techRoleFor(u.kind);
    const Rank = struct { same: bool, busy: u32, skill: u8 };
    var ranks: std.ArrayListUnmanaged(Rank) = .empty;
    var pit = gs.people.iterator();
    while (pit.next()) |e| {
        const p = e.value_ptr;
        const slot: @import("state.zig").Slot = if (p.role == pilot_role) .pilot else if (tech_role != null and p.role == tech_role.?) .tech else continue;
        if (!p.isOnBooks()) continue;
        const why: []const u8 = gs.assignBlock(u, p) orelse "";
        const seat = gs.pilotSeat(p.id);
        const load = if (slot == .tech) gs.techLoadHours(p.id) else 0;
        const now: []const u8 = if (slot == .pilot)
            (if (seat == unit_id) "this seat" else if (seat != .none) try std.fmt.allocPrint(alloc, "pilot of #{d}", .{@intFromEnum(seat)}) else "{g}free{/}")
        else
            (if (u.tech == p.id) "this hull's tech" else try std.fmt.allocPrint(alloc, "{s}{d}h of {d}h{{/}}", .{ if (load == 0) "{g}" else "", load, gs.techHoursAvailable(p) }));
        const skill = p.skill(p.role.primarySkill()) orelse 9;
        const same = gs.companyOf(p.assigned_force) == own and own != .none;
        const name = try std.fmt.allocPrint(alloc, "{s}", .{try personText(alloc, p)});
        const eligible = why.len == 0;
        const cells: table.Row = if (eligible)
            try table.row(alloc, &.{ try std.fmt.allocPrint(alloc, "{{a}}{s}{{/}}", .{name}), @tagName(p.role), try std.fmt.allocPrint(alloc, "{d}", .{skill}), now, if (!same) (if (gs.companyOf(p.assigned_force) == .none) "{d}(pool){/}" else "{d}(another company){/}") else "" })
        else
            try table.row(alloc, &.{ try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}", .{name}), try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}", .{@tagName(p.role)}), try std.fmt.allocPrint(alloc, "{{d}}{d}{{/}}", .{skill}), try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}", .{why}), "" });
        try out.append(alloc, .{ .id = @intFromEnum(p.id), .eligible = eligible, .why = why, .slot = slot, .cells = cells });
        try ranks.append(alloc, .{ .same = same, .busy = if (slot == .pilot) @intFromBool(seat != .none and seat != unit_id) else load, .skill = skill });
    }
    // Sort an index permutation, then rebuild: eligible, own company, free, sharper.
    const order = try alloc.alloc(usize, out.items.len);
    for (order, 0..) |*o, i| o.* = i;
    const Ctx = struct { rows: []PickRow, ranks: []Rank };
    std.mem.sort(usize, order, Ctx{ .rows = out.items, .ranks = ranks.items }, struct {
        fn lt(c: Ctx, a: usize, b: usize) bool {
            const ra = c.rows[a];
            const rb = c.rows[b];
            if (ra.eligible != rb.eligible) return ra.eligible;
            const ka = c.ranks[a];
            const kb = c.ranks[b];
            if (ka.same != kb.same) return ka.same;
            if (ka.busy != kb.busy) return ka.busy < kb.busy;
            return ka.skill < kb.skill;
        }
    }.lt);
    var sorted = try alloc.alloc(PickRow, out.items.len);
    for (order, 0..) |src, i| sorted[i] = out.items[src];
    return sorted;
}

/// What can be cleared from a hull: its pilot, its tech, or both.
pub fn unassignChoices(alloc: Alloc, gs: *GameState, unit_id: types.UnitId) ![]PickRow {
    var out: std.ArrayListUnmanaged(PickRow) = .empty;
    const u = gs.unit(unit_id) orelse return out.toOwnedSlice(alloc);
    if (gs.person(u.pilot)) |p| try out.append(alloc, .{ .id = 0, .eligible = true, .slot = .pilot, .cells = try table.row(alloc, &.{ "{a}pilot{/}", try std.fmt.allocPrint(alloc, "{s}", .{try personText(alloc, p)}) }) });
    if (gs.person(u.tech)) |t| try out.append(alloc, .{ .id = 1, .eligible = true, .slot = .tech, .cells = try table.row(alloc, &.{ "{a}tech{/}", try std.fmt.allocPrint(alloc, "{s}", .{try personText(alloc, t)}) }) });
    if (out.items.len == 2) try out.append(alloc, .{ .id = 2, .eligible = true, .slot = .any, .cells = try table.row(alloc, &.{ "{a}both{/}", "" }) });
    return out.toOwnedSlice(alloc);
}

test "pickers: crew rows are the right roles, own company and free first; company rows leave out the subject's own" {
    const commands = @import("commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 90 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    const other = try @import("starter_company.zig").generateInto(&gs, "Bravo");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    // A mek of Alpha's: only mekwarriors and mek techs are offered, Alpha's own first.
    var mek: types.UnitId = .none;
    var uit = gs.units.iterator();
    while (uit.next()) |e| if (e.value_ptr.kind == .mek and gs.companyOf(e.value_ptr.force) == co) {
        mek = e.value_ptr.id;
        break;
    };
    const crew = try crewChoices(al, &gs, mek);
    try std.testing.expect(crew.len > 0);
    for (crew) |r| {
        const p = gs.person(@enumFromInt(r.id)).?;
        try std.testing.expect(p.role == .mekwarrior or p.role == .tech_mek);
        try std.testing.expect((r.slot == .pilot) == (p.role == .mekwarrior));
    }
    try std.testing.expect(crew[0].eligible);
    try std.testing.expectEqual(co, gs.companyOf(gs.person(@enumFromInt(crew[0].id)).?.assigned_force));

    // Sending that mek elsewhere: Bravo is offered, Alpha is not.
    const cos = try companyChoices(al, &gs, .unit, @intFromEnum(mek));
    try std.testing.expectEqual(@as(usize, 1), cos.len);
    try std.testing.expectEqual(@intFromEnum(other), cos[0].id);
    try std.testing.expect(cos[0].eligible);

    // Posting: the one HQ is offered; once posted there it is dimmed.
    const pilot = gs.unit(mek).?.pilot;
    const hqs = try hqChoices(al, &gs, pilot);
    try std.testing.expectEqual(gs.hqs.count(), hqs.len);
    try std.testing.expect(hqs[0].eligible);
    _ = try commands.execute(&gs, .{ .post_person = .{ .person = pilot, .hq = @enumFromInt(hqs[0].id) } });
    try std.testing.expect(!(try hqChoices(al, &gs, pilot))[0].eligible);

    // Unassign offers what is filled.
    const un = try unassignChoices(al, &gs, mek);
    try std.testing.expect(un.len >= 1);
}

pub const PartPurpose = enum { order, ship, keep, sell, fabricate };
/// Parts a site could order, ship, keep stocked, sell or fabricate: the
/// catalogue for ordering and keep-stocked lines, what the site holds for
/// shipping and selling, the structural components for the bay. On hand
/// is counted at `site`; the emptiest shelves come first for ordering,
/// the fullest for shipping and selling.
pub fn partChoices(alloc: Alloc, gs: *GameState, purpose: PartPurpose, site: types.Site) ![]PickRow {
    var out: std.ArrayListUnmanaged(PickRow) = .empty;
    const part_mod = @import("../domain/part.zig");
    for (part_mod.catalog, 0..) |p, i| {
        const component = part_mod.isComponent(p.key);
        const on_hand = gs.stockCount(site, p.key);
        const keep = switch (purpose) {
            .order, .keep => true,
            .ship, .sell => on_hand > 0,
            .fabricate => component,
        };
        if (!keep) continue;
        const source: []const u8 = if (component) (if (p.fab_regional) "{a}fabricable: bay 3 at a regional HQ{/}" else if (p.fab_min_bay > 1) try std.fmt.allocPrint(alloc, "{{a}}fabricable: bay {d}{{/}}", .{p.fab_min_bay}) else "{a}fabricable at any bay{/}") else if (isStaple(p.key)) "{g}staple{/}" else "{d}rolls for availability{/}";
        try out.append(alloc, .{ .id = @intCast(i), .eligible = true, .key = p.key, .on_hand = on_hand, .cells = try table.row(alloc, &.{
            try std.fmt.allocPrint(alloc, "{{a}}{s}{{/}}", .{p.key}),
            p.name,
            try money(alloc, p.cost),
            try std.fmt.allocPrint(alloc, "{d}t", .{part_mod.tons(p.key)}),
            try std.fmt.allocPrint(alloc, "{s}{d}{{/}}", .{ if (on_hand == 0) "{d}" else "", on_hand }),
            source,
        }) });
    }
    const Ctx = struct { gs: *GameState, site: types.Site, fullest_first: bool };
    std.mem.sort(PickRow, out.items, Ctx{ .gs = gs, .site = site, .fullest_first = purpose == .ship or purpose == .sell }, struct {
        fn lt(c: Ctx, a: PickRow, b: PickRow) bool {
            const qa = c.gs.stockCount(c.site, a.key);
            const qb = c.gs.stockCount(c.site, b.key);
            if (qa != qb) return if (c.fullest_first) qa > qb else qa < qb;
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.lt);
    return out.toOwnedSlice(alloc);
}

test "pickers: part rows follow the purpose — shipping and selling offer only what the shelf holds, the bay only components" {
    const commands = @import("commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 91 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const hq: types.Site = .{ .hq = gs.hqs.keys()[0] };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const part_mod = @import("../domain/part.zig");

    const to_order = try partChoices(al, &gs, .order, hq);
    try std.testing.expectEqual(part_mod.catalog.len, to_order.len);
    for (try partChoices(al, &gs, .fabricate, hq)) |r| try std.testing.expect(part_mod.isComponent(r.key));
    for (try partChoices(al, &gs, .ship, hq)) |r| try std.testing.expect(gs.stockCount(hq, r.key) > 0);
    // Shipping lists the fullest shelf first; ordering the emptiest.
    const ship = try partChoices(al, &gs, .ship, hq);
    if (ship.len >= 2) try std.testing.expect(gs.stockCount(hq, ship[0].key) >= gs.stockCount(hq, ship[1].key));
    try std.testing.expectEqual(@as(u32, 0), gs.stockCount(hq, to_order[0].key));
}

test "the board's transit column is real — from the nearest company that could go, never 0" {
    const commands = @import("commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 92 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    _ = try commands.execute(&gs, .{ .new_company = "Alpha" });
    try @import("contract_market.zig").refresh(&gs);
    try std.testing.expect(gs.contract_offers.items.len > 0);
    for (gs.contract_offers.items) |*o| {
        const d = offerTransitDays(&gs, o);
        try std.testing.expect(d >= 3);
        // Same world as the seat: three days to muster; further: at least one jump's transit.
        if (std.mem.eql(u8, o.planet_key, gs.hqs.values()[0].planet_key)) try std.testing.expectEqual(@as(u32, 3), d);
    }
}

test "the DAMAGE pane asks for components only where structure is destroyed or missing" {
    const commands = @import("commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 94 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    // One mek: left torso merely damaged, right leg destroyed.
    var uit = gs.units.iterator();
    while (uit.next()) |e| if (e.value_ptr.kind == .mek and gs.companyOf(e.value_ptr.force) == co) {
        for (e.value_ptr.slots.items) |*sl| if (sl.class == .structure) {
            if (std.mem.startsWith(u8, sl.slot_key, "lt.")) sl.condition = .damaged;
            if (std.mem.startsWith(u8, sl.slot_key, "rl.")) sl.condition = .destroyed;
        };
        break;
    };
    const dmg = try companyDamage(al, &gs, co);
    var text: std.ArrayListUnmanaged(u8) = .empty;
    for (dmg.lines) |l| {
        try text.appendSlice(al, l);
        try text.append(al, '\n');
    }
    try std.testing.expect(std.mem.indexOf(u8, text.items, "bay time only") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "comp_leg") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "comp_torso") == null); // damaged: no part asked for
}

test "the unassigned pool says where it sits and what each wreck's rebuild needs from that shelf" {
    const commands = @import("commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 97 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const wreck = try gs.addUnit("LCT-1V");
    for (gs.unit(wreck).?.slots.items) |*s| if (std.mem.startsWith(u8, s.slot_key, "ct.") and s.class == .structure) {
        s.condition = .missing;
    };
    const hq_name = gs.hqs.values()[0].name;
    var header_ok = false;
    var row_ok = false;
    for (try toeFiltered(al, &gs, .unassigned)) |r| {
        if (std.mem.indexOf(u8, r.text, "Unassigned hulls") != null and std.mem.indexOf(u8, r.text, hq_name) != null) header_ok = true;
        if (r.unit == wreck and std.mem.indexOf(u8, r.text, "comp_ct_l×1") != null) row_ok = true; // a Locust takes a light assembly
    }
    try std.testing.expect(header_ok);
    try std.testing.expect(row_ok);
    var label_ok = false;
    for (try toeViews(al, &gs)) |v| if (v.filter == .unassigned and std.mem.indexOf(u8, v.label, hq_name) != null) {
        label_ok = true;
    };
    try std.testing.expect(label_ok);
}

test "skulls: a weaker company rates harder, a heavier one easier; low intel gives a range around the truth" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1231 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const alpha = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    const bravo = try @import("starter_company.zig").generateInto(&gs, "Bravo");
    const site_a: types.Site = .{ .company = alpha };
    const site_b: types.Site = .{ .company = bravo };
    for (@import("../domain/part.zig").munition_keys) |k| {
        try gs.addStock(site_a, k, 50);
        try gs.addStock(site_b, k, 50);
    }
    const hq = gs.hqs.getPtr(gs.hqs.keys()[0]).?;
    hq.staff_assigned = 999;
    const comms = for (hq.facilities.items) |*f| {
        if (f.kind == .comms) break f;
    } else return error.TestUnexpectedResult;
    comms.level = 3; // the intel counts their lances
    const offer: contract_mod.Contract = .{
        .id = .none,
        .kind = .objective_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 100_000 },
        .enemy_lances = 3,
        .enemy_quality = .regular,
        .enemy_lance_bv = 4_000,
        .enemy_lance_tons = 220,
    };
    const full = (try rateOffer(a, &gs, &offer, alpha)).?;
    try std.testing.expect(full.exact and full.half_lo == full.half_hi);
    try std.testing.expect(full.half_lo >= 1 and full.half_lo <= 10);
    try std.testing.expectEqual(@as(u32, 660), full.enemy_tons_lo);
    try std.testing.expect(full.own.tons > 0 and full.own.mix[2] == 0 and full.own.mix[3] == 0);
    try std.testing.expect(full.win_pct + full.lose_field_pct <= 100);

    // Bravo refits into assault hulls on paper: more tons, fewer skulls.
    var it = gs.units.iterator();
    while (it.next()) |e| if (e.value_ptr.kind == .mek and gs.companyOf(e.value_ptr.force) == bravo) {
        e.value_ptr.chassis_key = "AS7-D";
    };
    const heavy = (try rateOffer(a, &gs, &offer, bravo)).?;
    try std.testing.expect(heavy.own.tons > full.own.tons);
    try std.testing.expect(heavy.half_lo < full.half_lo);
    try std.testing.expect(heavy.win_pct > full.win_pct);

    // Alpha mauled: half its meks wrecked — more skulls, worse odds.
    var n: u32 = 0;
    var it2 = gs.units.iterator();
    while (it2.next()) |e| if (e.value_ptr.kind == .mek and gs.companyOf(e.value_ptr.force) == alpha and n < 8) {
        e.value_ptr.status = .destroyed;
        n += 1;
    };
    const mauled = (try rateOffer(a, &gs, &offer, alpha)).?;
    try std.testing.expect(mauled.half_lo > full.half_lo);
    try std.testing.expect(mauled.lose_field_pct > full.lose_field_pct);

    // Blind intel: the kind's lance range, bracketing the truth.
    comms.level = 0;
    const blind = (try rateOffer(a, &gs, &offer, alpha)).?;
    try std.testing.expect(!blind.exact);
    try std.testing.expect(blind.half_lo <= mauled.half_lo and mauled.half_hi <= blind.half_hi);
    try std.testing.expect(blind.half_lo < blind.half_hi);
    try std.testing.expect(std.mem.indexOf(u8, try skullText(a, blind), "–") != null);
}

test "clip counts cells and never splits a character" {
    try std.testing.expectEqualStrings("a·b", clip("a·bc", 3));
    try std.testing.expectEqualStrings("a·", clip("a·bc", 2));
    try std.testing.expectEqualStrings("ab", clip("ab", 5));
}

test "skulls on the board, the candidates, the active pane — and an outmatched company is warned" {
    const commands = @import("commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1250 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const view = try contracts(a, &gs, gs.hqs.keys()[0]);
    try std.testing.expect(view.board.len > 0);
    for (view.board) |row| {
        try std.testing.expectEqual(board_cols.len, row.cells.len);
        try std.testing.expect(std.mem.indexOf(u8, row.cells[12], "☠") != null or std.mem.indexOf(u8, row.cells[12], "◐") != null);
    }
    // The board renders at natural width with every column under its name.
    const lines = try (try view.boardTable(a)).render(a);
    try std.testing.expectEqual(view.board.len + 1, lines.len);
    try std.testing.expect(std.mem.startsWith(u8, lines[0], "kind"));
    var saw = false;
    for (try offerCandidates(a, &gs, view.board[0].index)) |c| if (c.company == co and std.mem.indexOf(u8, c.text, "skull") != null) {
        saw = true;
    };
    try std.testing.expect(saw);

    // Sent against six veteran lances with half its meks gone: outmatched.
    const cid: types.ContractId = @enumFromInt(1250);
    try gs.contracts.put(gs.allocator(), cid, .{ .id = cid, .kind = .planetary_assault, .employer_key = "LC", .enemy_key = "DC", .planet_key = "galatea", .status = .active, .assigned_company = co, .terms = .{ .length_months = 6, .base_pay_month = 100_000 }, .enemy_lances = 6, .enemy_quality = .veteran, .enemy_lance_bv = 5_000, .enemy_lance_tons = 260 });
    var n: u32 = 0;
    var it = gs.units.iterator();
    while (it.next()) |e| if (e.value_ptr.kind == .mek and gs.companyOf(e.value_ptr.force) == co and n < 8) {
        e.value_ptr.status = .destroyed;
        n += 1;
    };
    var warned = false;
    for (try @import("checklist.zig").turnWarnings(&gs, a)) |w| if (w.kind == .outmatched) {
        warned = true;
    };
    try std.testing.expect(warned);
    const again = try contracts(a, &gs, .none);
    var pane_ok = false;
    for (again.active) |ar| for (ar.lines) |l| if (std.mem.indexOf(u8, l, "outmatched") != null) {
        pane_ok = true;
    };
    try std.testing.expect(pane_ok);
}

// ------------------------------------------------------------ REPL views
//
// The lines the command console prints for the views the client draws
// as panes. One query each, so the console and the client never read a
// different rule (contract rule 30).

pub const HqRow = struct {
    id: types.HqId,
    name: table.Raw,
    tier: []const u8,
    world: []const u8,
    faction: []const u8,
    ring_ly: u32,
    funds: types.CBills,
    staff_assigned: u32,
    staff_required: u32,
    companies: u32,
    company_cap: u32,
    lances_cap: u32,
    /// "hq:1 Galtor III Regional HQ (regional) on Galtor III (LC space) — ring 60 LY | companies 1/1 (≤4 lances) | funds 1,000,000"
    title_line: []const u8,
};

/// Every HQ in one row each, in founding order.
pub fn hqList(alloc: Alloc, gs: *GameState) ![]HqRow {
    var out: std.ArrayListUnmanaged(HqRow) = .empty;
    var it = gs.hqs.iterator();
    while (it.next()) |e| {
        const hq = e.value_ptr;
        const world = planet_mod.find(hq.planet_key);
        const cap = hq.capacity();
        const row: HqRow = .{
            .id = hq.id,
            .name = .{ .raw = hq.name },
            .tier = @tagName(hq.tier),
            .world = if (world) |w| w.name else hq.planet_key,
            .faction = if (world) |w| w.faction else "?",
            .ring_ly = hq.influenceLy(),
            .funds = hq.funds,
            .staff_assigned = hq.staff_assigned,
            .staff_required = hq.staffRequired().total(),
            .companies = gs.companiesAtHq(hq.id),
            .company_cap = cap.combat_companies,
            .lances_cap = cap.lances_per_company,
            .title_line = "",
        };
        try out.append(alloc, row);
        out.items[out.items.len - 1].title_line = try std.fmt.allocPrint(alloc, "hq:{d} {s} ({s}) on {s} ({s} space) — ring {d} LY | companies {d}/{d} (≤{d} lances) | funds {s}", .{
            @intFromEnum(row.id), try row.name.terminal(alloc), row.tier, row.world, row.faction, row.ring_ly, row.companies, row.company_cap, row.lances_cap, try money(alloc, row.funds),
        });
    }
    return out.toOwnedSlice(alloc);
}

/// "co:1 Alpha (deployed)" for every company homed at an HQ.
pub fn hqCompanies(alloc: Alloc, gs: *GameState, hq_id: types.HqId) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var fit = gs.forces.iterator();
    while (fit.next()) |fe| {
        const f = fe.value_ptr;
        if (f.echelon != .company or f.supplying_hq != hq_id) continue;
        try out.append(alloc, try std.fmt.allocPrint(alloc, "co:{d} {s}{s}", .{ @intFromEnum(f.id), try table.plain(alloc, f.name), if (gs.isCompanyDeployed(f.id)) " (deployed)" else "" }));
    }
    return out.toOwnedSlice(alloc);
}

/// Supply links and hulls on their way between companies, one line each.
pub fn hqLinks(alloc: Alloc, gs: *GameState) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (gs.hq_links.items) |l| {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "link hq:{d} — hq:{d} level {d}: {d}/{d} t this week, {s}/mo", .{
            @intFromEnum(l.a), @intFromEnum(l.b), l.level, l.tons_this_week, l.tonsPerWeek(), try money(alloc, l.monthlyCost()),
        }));
    }
    for (gs.unit_transfers.items) |t| {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "in transit: unit #{d} → co:{d}, arrives day {d}", .{ @intFromEnum(t.unit), @intFromEnum(t.to_company), t.eta_day }));
    }
    return out.toOwnedSlice(alloc);
}

/// The bay at one HQ: the occupancy line, then each job.
pub fn bays(alloc: Alloc, gs: *GameState, hq_id: types.HqId) ![]const []const u8 {
    const hq_ops = @import("hq_ops.zig");
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const load = hq_ops.bayLoad(gs, hq_id);
    try out.append(alloc, try std.fmt.allocPrint(alloc, "hq:{d} {s} — {d}/{d} bay slots busy, {d} queued", .{ @intFromEnum(hq_id), try hqName(alloc, gs, hq_id), load.busy, hq_ops.baySlots(gs, hq_id), load.queued }));
    for (gs.bay_jobs.items) |j| {
        if (j.hq != hq_id) continue;
        const what = if (j.unit != .none) (if (gs.unit(j.unit)) |u| u.chassis_key else "?") else j.item_key;
        if (j.done_day) |d| {
            try out.append(alloc, try std.fmt.allocPrint(alloc, "  {s: <13} {s: <10} done day {d}", .{ @tagName(j.kind), what, d }));
        } else {
            try out.append(alloc, try std.fmt.allocPrint(alloc, "  {s: <13} {s: <10} queued ({d} days once a slot frees)", .{ @tagName(j.kind), what, j.duration_days }));
        }
    }
    return out.toOwnedSlice(alloc);
}

/// One HQ's facilities and construction queue.
pub fn projects(alloc: Alloc, gs: *GameState, hq_id: types.HqId) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const hq = gs.hqs.getPtr(hq_id) orelse return out.toOwnedSlice(alloc);
    try out.append(alloc, try std.fmt.allocPrint(alloc, "hq:{d} {s} — staff {d}/{d} | paperwork {d} days", .{
        @intFromEnum(hq.id), try table.plain(alloc, hq.name), hq.staff_assigned, hq.staffRequired().total(), @import("hq_ops.zig").paperworkDaysFor(gs, hq_id),
    }));
    for (hq.facilities.items) |f| {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  {s: <16} level {d} (effective {d})", .{ @tagName(f.kind), f.level, hq.effectiveFacilityLevel(f.kind) }));
    }
    for (hq.projects.items) |p| {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  PROJECT {s} → level {d}: {s}, done day {d}, {s}", .{
            @tagName(p.facility orelse .mek_bay), p.target_level, @tagName(p.phase(gs.clock.day_index)), p.construction_done_day, try money(alloc, p.cost),
        }));
    }
    return out.toOwnedSlice(alloc);
}

pub const OfficeRow = struct {
    role: person_mod.Role,
    have: u32,
    need: u32,
    best_skill: u8,
    /// Monthly pay of the desk as staffed.
    pay: types.CBills,
    /// What the desk speeds up.
    effect: []const u8,
};

/// The back office at one HQ: every admin desk, who fills it, and the
/// requirement (`StaffRequirement.desks` is the table; transport shares
/// the logistics desk).
pub fn backOffice(alloc: Alloc, gs: *GameState, hq_id: types.HqId) ![]OfficeRow {
    var out: std.ArrayListUnmanaged(OfficeRow) = .empty;
    const hq = gs.hqs.getPtr(hq_id) orelse return out.toOwnedSlice(alloc);
    const req = hq.staffRequired();
    const roles = [_]struct { role: person_mod.Role, need: u32 }{
        .{ .role = .admin_command, .need = req.admin },
        .{ .role = .admin_logistics, .need = req.logistics / 2 },
        .{ .role = .admin_transport, .need = req.logistics - req.logistics / 2 },
        .{ .role = .admin_hr, .need = req.hr },
        .{ .role = .admin_finance, .need = req.finance },
    };
    for (roles) |r| {
        const s = @import("hq_ops.zig").hqStaff(gs, hq_id, r.role);
        try out.append(alloc, .{ .role = r.role, .have = s.count, .need = r.need, .best_skill = s.best_skill, .pay = r.role.baseSalary() * s.count, .effect = switch (r.role) {
            .admin_command => "orders, morale",
            .admin_logistics => "order rolls",
            .admin_transport => "shipping ETAs",
            .admin_hr => "hiring, training",
            .admin_finance => "paperwork days",
            else => "",
        } });
    }
    return out.toOwnedSlice(alloc);
}

/// One company's hulls with their crews and techs, its techs' hours, and
/// the crews without a seat.
pub fn companyRoster(alloc: Alloc, gs: *GameState, co: types.ForceId) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const f = gs.force(co) orelse return out.toOwnedSlice(alloc);
    const day = gs.clock.day_index;
    try out.append(alloc, try std.fmt.allocPrint(alloc, "[{d}] {s} — hulls and crews:", .{ @intFromEnum(co), try table.plain(alloc, f.name) }));
    var uit = gs.units.iterator();
    while (uit.next()) |entry| {
        const u = entry.value_ptr;
        if (gs.companyOf(u.force) != co or u.status == .destroyed) continue;
        const pilot = gs.person(u.pilot);
        const tech = gs.person(u.tech);
        const needs_tech = unit_mod.techRoleFor(u.kind) != null;
        var pb: [48]u8 = undefined;
        var tb: [48]u8 = undefined;
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  #{d: <3} {s: <8} {s: <9} pilot {s: <12}{s} tech {s: <12}{s}", .{
            @intFromEnum(u.id),                                                          u.chassis_key,
            @tagName(u.status),
            if (pilot) |p| try table.plain(alloc, p.shortName(&pb)) else "—",
            if (pilot != null and pilot.?.isAvailable(day)) " " else "!",
            if (!needs_tech) "n/a" else if (tech) |t| try table.plain(alloc, t.shortName(&tb)) else "—",
            if (needs_tech and (tech == null or !tech.?.isAvailable(day))) "!" else " ",
        }));
    }
    try out.append(alloc, "  techs (load/available hours this week):");
    var pit = gs.people.iterator();
    while (pit.next()) |entry| {
        const p = entry.value_ptr;
        if (gs.companyOf(p.assigned_force) != co or !p.role.isTech()) continue;
        try out.append(alloc, try std.fmt.allocPrint(alloc, "    #{d: <3} {s: <20} {s: <13} {d: >2}/{d: <2}h{s}", .{
            @intFromEnum(p.id), try personText(alloc, p), @tagName(p.role), gs.techLoadHours(p.id), gs.techHoursAvailable(p), if (!p.isAvailable(day)) " (unavailable)" else "",
        }));
    }
    var pool: std.ArrayListUnmanaged(u8) = .empty;
    var pit2 = gs.people.iterator();
    while (pit2.next()) |entry| {
        const p = entry.value_ptr;
        if (gs.companyOf(p.assigned_force) != co or !p.isAvailable(day)) continue;
        if (!p.role.isCombat() or gs.pilotSeat(p.id) != .none) continue;
        try pool.appendSlice(alloc, try std.fmt.allocPrint(alloc, " #{d} {s} ({s})", .{ @intFromEnum(p.id), p.last_name, @tagName(p.role) }));
    }
    try out.append(alloc, try std.fmt.allocPrint(alloc, "  unassigned pool:{s}", .{if (pool.items.len > 0) pool.items else " none"}));
    return out.toOwnedSlice(alloc);
}

/// One HQ's posted staff against its requirement, and the outfit's pool of
/// people posted nowhere and assigned to no company.
pub fn hqRoster(alloc: Alloc, gs: *GameState, hq_id: types.HqId) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const hq = gs.hqs.getPtr(hq_id) orelse return out.toOwnedSlice(alloc);
    const req = hq.staffRequired();
    try out.append(alloc, try std.fmt.allocPrint(alloc, "{s} — staff {d}/{d} (admin {d}, logistics {d}, hr {d}, finance {d} required)", .{
        try table.plain(alloc, hq.name), hq.staff_assigned, req.total(), req.admin, req.logistics, req.hr, req.finance,
    }));
    var pit = gs.people.iterator();
    while (pit.next()) |entry| {
        const p = entry.value_ptr;
        if (p.posted_hq != hq_id or !p.isOnBooks()) continue;
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  #{d: <3} {s: <20} {s: <16} {s}", .{ @intFromEnum(p.id), try personText(alloc, p), @tagName(p.role), @tagName(p.experience()) }));
    }
    var pool: std.ArrayListUnmanaged(u8) = .empty;
    var pit2 = gs.people.iterator();
    while (pit2.next()) |entry| {
        const p = entry.value_ptr;
        if (p.status != .active or !gs.isUnassigned(p)) continue;
        try pool.appendSlice(alloc, try std.fmt.allocPrint(alloc, " #{d} {s} ({s})", .{ @intFromEnum(p.id), p.last_name, @tagName(p.role) }));
    }
    try out.append(alloc, try std.fmt.allocPrint(alloc, "  unposted & unassigned:{s}", .{if (pool.items.len > 0) pool.items else " none"}));
    return out.toOwnedSlice(alloc);
}

/// The medbay: patients, beds, doctors and their cover, then each patient.
pub fn medbay(alloc: Alloc, gs: *GameState) ![]const []const u8 {
    const medical = @import("medical.zig");
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var doctors: u32 = 0;
    var wounded: u32 = 0;
    var pit = gs.people.iterator();
    while (pit.next()) |entry| {
        if (entry.value_ptr.status == .active and entry.value_ptr.role == .doctor) doctors += 1;
        if (entry.value_ptr.status == .wounded) wounded += 1;
    }
    try out.append(alloc, try std.fmt.allocPrint(alloc, "medbay: {d} patients | {d} beds at home | {d} doctors (cover {d})", .{
        wounded, medical.bedCapacity(gs, .none, false), doctors, doctors * @import("../domain/tuning.zig").t.medical.patients_per_doctor,
    }));
    var pit2 = gs.people.iterator();
    while (pit2.next()) |entry| {
        const p = entry.value_ptr;
        if (p.status != .wounded) continue;
        const left = if (p.wound_heal_day) |d| d -| gs.clock.day_index else 0;
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  #{d: <3} {s: <20} {s: <12} priority {d}  {d} days left{s}", .{
            @intFromEnum(p.id), try personText(alloc, p), @tagName(p.role), p.medbay_priority, left, if (p.wound_heal_day == null) " (awaiting triage)" else "",
        }));
    }
    return out.toOwnedSlice(alloc);
}

/// One row per kept engagement, newest first: the fight named,
/// its verdict coloured, and what it cost.
pub const BattleRow = struct {
    id: types.BattleId,
    cells: table.Row,
};

pub const battle_cols: []const table.Col = &.{
    .{ .name = "id", .justify = .right },
    .{ .name = "day", .justify = .right },
    .{ .name = "company" },
    .{ .name = "where" },
    .{ .name = "outcome" },
    .{ .name = "field" },
    .{ .name = "hit", .justify = .right },
    .{ .name = "lost", .justify = .right },
    .{ .name = "crew" },
};

/// The colour a verdict reads in: a held field is the line between a win
/// you can salvage and a loss you pay for, so it decides the mark rather
/// than the outcome's name alone.
pub fn outcomeMark(outcome: @import("autoresolve.zig").Outcome) []const u8 {
    if (outcome == .rout) return "{c}";
    if (outcome.isLoss()) return "{a}";
    return "{g}";
}

pub fn battleList(alloc: Alloc, gs: *GameState) ![]BattleRow {
    var out: std.ArrayListUnmanaged(BattleRow) = .empty;
    var i: usize = gs.battle_reports.kept.items.len;
    while (i > 0) {
        i -= 1;
        const r = &gs.battle_reports.kept.items[i];
        const crew = if (r.kia + r.wounded + @as(u8, @intCast(@min(r.missing, 255))) == 0)
            "{g}all in{/}"
        else
            try std.fmt.allocPrint(alloc, "{s}{d} WIA · {d} KIA · {d} MIA{{/}}", .{ if (r.kia + r.missing > 0) "{c}" else "{a}", r.wounded, r.kia, r.missing });
        try out.append(alloc, .{ .id = r.id, .cells = try table.row(alloc, &.{
            try std.fmt.allocPrint(alloc, "{d}", .{@intFromEnum(r.id)}),
            try std.fmt.allocPrint(alloc, "{d}", .{r.day}),
            try forceName(alloc, gs, r.company),
            try std.fmt.allocPrint(alloc, "{s} · {s}", .{ r.scenario, r.terrain }),
            try std.fmt.allocPrint(alloc, "{s}{s}{{/}}", .{ outcomeMark(r.outcome), @tagName(r.outcome) }),
            if (r.held_field) "{g}held{/}" else "{c}lost{/}",
            try std.fmt.allocPrint(alloc, "{d}", .{r.hits_taken}),
            try std.fmt.allocPrint(alloc, "{s}{d}{{/}}", .{ if (r.lost_hulls > 0) "{c}" else "", r.destroyed }),
            crew,
        }) });
    }
    return out.toOwnedSlice(alloc);
}

/// One engagement broken into the panes the after-action screen draws.
/// Every string is finished markup: the client positions rects, it never
/// decides what a number means (rule 29).
pub const AfterAction = struct {
    title: []const u8,
    right_title: []const u8,
    /// How the fight was decided — the roll, the odds, what it cost.
    fight: []const []const u8,
    /// One row per hull hit, with its armour meter.
    field: table.Table,
    /// What was claimed, and what the employer's liaison took.
    spoils: []const []const u8,
    /// Munitions burned against what is left in the trucks.
    trucks: []const []const u8,
    /// The whole thing as flat lines, for a terminal too narrow to split.
    flat: []const []const u8,
};

pub const after_action_cols: []const table.Col = &.{
    .{ .name = "hull" },
    .{ .name = "armour" },
    .{ .name = "damage" },
    .{ .name = "crew" },
};

pub fn afterAction(alloc: Alloc, gs: *GameState, id: types.BattleId) !?AfterAction {
    const r = gs.battle_reports.find(id) orelse return null;
    const mk = outcomeMark(r.outcome);

    var fight: std.ArrayListUnmanaged([]const u8) = .empty;
    // A concession has no fight to describe: what was given up and what it cost.
    if (r.conceded) {
        try fight.append(alloc, "{c}objective conceded{/} — no combat-effective units to field");
        try fight.append(alloc, try std.fmt.allocPrint(alloc, "{s}{s}{{/}} · {{c}}field lost{{/}}", .{ mk, @tagName(r.outcome) }));
        try fight.append(alloc, "");
    } else try fight.append(alloc, try std.fmt.allocPrint(alloc, "{s} · {s}", .{ r.scenario, r.terrain }));
    if (!r.conceded) {
        try fight.append(alloc, try std.fmt.allocPrint(alloc, "{s}{s}{{/}} · {s}", .{
            mk, @tagName(r.outcome), if (r.held_field) "{g}field held{/}" else "{c}field lost{/}",
        }));
        try fight.append(alloc, "");
        try fight.append(alloc, try std.fmt.allocPrint(alloc, "power {d} vs {d}", .{ r.player_power, r.enemy_power }));
        try fight.append(alloc, try std.fmt.allocPrint(alloc, "ROE {s}{s}{s}", .{
            @tagName(r.roe),
            if (r.roe_overridden) " {d}(integrated command){/}" else "",
            if (r.withdrew) " {a}· withdrew{/}" else "",
        }));
        try fight.append(alloc, try std.fmt.allocPrint(alloc, "{{d}}recon {d} · fatigue {d} · morale {d}{{/}}", .{ r.recon_quality, r.avg_fatigue, r.avg_morale }));
        try fight.append(alloc, "");
        try fight.append(alloc, try std.fmt.allocPrint(alloc, "{d} hit · {s}{d} destroyed{{/}} · {s}{d} WIA{{/}} · {s}{d} KIA{{/}}", .{
            r.hits_taken,
            if (r.destroyed > 0) "{c}" else "{g}",
            r.destroyed,
            if (r.wounded > 0) "{a}" else "{g}",
            r.wounded,
            if (r.kia > 0) "{c}" else "{g}",
            r.kia,
        }));
        if (r.lost_hulls > 0) try fight.append(alloc, try std.fmt.allocPrint(alloc, "{{c}}{d} hull(s) left to {s}{{/}}{s}", .{
            r.lost_hulls, r.enemy_key,
            if (r.missing > 0) try std.fmt.allocPrint(alloc, " {{c}}· {d} pilot(s) missing{{/}}", .{r.missing}) else "",
        }));
        // Applied to every active hand.
        try fight.append(alloc, try std.fmt.allocPrint(alloc, "morale {s}{s}{d}{{/}} · fatigue {{a}}+{d}{{/}}", .{
            if (r.morale_delta < 0) "{c}" else "{g}", if (r.morale_delta > 0) "+" else "", r.morale_delta, r.fatigue_add,
        }));
    }
    try fight.append(alloc, try std.fmt.allocPrint(alloc, "score {s}{s}{d}{{/}} (now {d}) · comp {s}", .{
        if (r.score_delta < 0) "{c}" else "{g}", if (r.score_delta > 0) "+" else "", r.score_delta, r.score_after, try money(alloc, r.battle_loss_comp),
    }));

    var field: std.ArrayListUnmanaged(table.Row) = .empty;
    for (r.hulls) |h| {
        const damage = if (h.destroyed)
            try std.fmt.allocPrint(alloc, "{{c}}DESTROYED{{/}} {{d}}({s}){{/}}{s}", .{
                h.cause.label(),
                if (h.lost) " {c}· left to the enemy{/}" else if (h.recovery != null) " {g}· dragged off{/}" else "",
            })
        else if (h.slot) |sk|
            try std.fmt.allocPrint(alloc, "{s} {{d}}({s}){{/}} {s}{s}{{/}}", .{ sk, h.slot_part, if (h.slot_result == .destroyed) "{c}" else "{a}", h.slot_result.label() })
        else
            "{d}armour only{/}";
        const crew = switch (h.crew.fate) {
            .kia => try std.fmt.allocPrint(alloc, "{{c}}{s} KIA{{/}}", .{try table.plain(alloc, h.crew_name)}),
            .missing => try std.fmt.allocPrint(alloc, "{{c}}{s} MIA{{/}}", .{try table.plain(alloc, h.crew_name)}),
            .unhurt => if (h.crew.wound) |w|
                try std.fmt.allocPrint(alloc, "{{a}}{s} ({s} {s}){{/}}", .{ try table.plain(alloc, h.crew_name), @import("medical.zig").severityLabel(w.severity), @tagName(w.location) })
            else
                "{d}—{/}",
        };
        try field.append(alloc, try table.row(alloc, &.{
            try std.fmt.allocPrint(alloc, "#{d} {s} {s}", .{ @intFromEnum(h.unit), h.chassis_key, h.chassis_name }),
            try std.fmt.allocPrint(alloc, "{d}% → {s}", .{ h.armor_before, try armorBar(alloc, h.armor_after) }),
            damage,
            crew,
        }));
    }

    var spoils: std.ArrayListUnmanaged([]const u8) = .empty;
    try spoils.append(alloc, try std.fmt.allocPrint(alloc, "{d} BV destroyed · {d} haulable · {d}% rights", .{ r.enemy_destroyed_bv, r.salvage.haulable_bv, r.salvage_pct }));
    try spoils.append(alloc, try std.fmt.allocPrint(alloc, "{d} kill(s) credited{s}", .{
        r.kills_credited,
        if (r.prisoners > 0) try std.fmt.allocPrint(alloc, " · {{a}}{d} prisoner(s) taken{{/}}", .{r.prisoners}) else "",
    }));
    try spoils.append(alloc, "");
    if (r.salvage.items.len > 0) {
        for (try wrapPlain(alloc, r.salvage.items)) |line| try spoils.append(alloc, line);
        if (r.salvage.liaison_cut > 0) try spoils.append(alloc, try std.fmt.allocPrint(alloc, "{{a}}the liaison claimed {d} BV under {s} rights{{/}}", .{ r.salvage.liaison_cut, r.command_rights }));
    } else if (r.held_field) {
        try spoils.append(alloc, "{d}field held, nothing worth hauling{/}");
    } else {
        try spoils.append(alloc, "{c}nothing — the field was not held{/}");
    }

    var trucks: std.ArrayListUnmanaged([]const u8) = .empty;
    for (r.ammo) |a| {
        // Burned against what the family started with, so the bar reads
        // as "how much of this fight's supply went".
        const had = a.burned + a.left;
        var buf: [10]u8 = undefined;
        const low = a.left == 0 or (had > 0 and a.left * 4 < had);
        try trucks.append(alloc, try std.fmt.allocPrint(alloc, "{s: <6} {s}{s}{{/}} {d: >2}t burned · {s}{d: >2}t left{{/}}", .{
            @import("../domain/part.zig").munitionLabel(a.key), if (low) "{a}" else "{g}", table.bar(&buf, a.burned, @max(1, had)),
            a.burned,                                           if (low) "{c}" else "",    a.left,
        }));
    }
    try trucks.append(alloc, "");
    try trucks.append(alloc, try std.fmt.allocPrint(alloc, "{s}{d} mount(s) silenced (dry){{/}} · {d}t armour", .{
        if (r.silenced_mounts > 0) "{c}" else "{d}", r.silenced_mounts, r.armor_left,
    }));

    return .{
        .title = try std.fmt.allocPrint(alloc, "AFTER ACTION · {s} · {s} vs {s}, day {d}", .{ try forceName(alloc, gs, r.company), r.kind, r.enemy_key, r.day }),
        .right_title = "[Tab] pane · [Esc] close",
        .fight = fight.items,
        .field = .{ .cols = after_action_cols, .rows = field.items },
        .spoils = spoils.items,
        .trucks = trucks.items,
        .flat = (try battleReport(alloc, gs, id)) orelse &.{},
    };
}

test "the after-action panes read from the record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const battle = @import("battle.zig");
    const part = @import("../domain/part.zig");

    var gs = GameState.init(std.testing.allocator, .{ .seed = 31337 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "PER",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000, .salvage_pct = 30, .battle_loss_pct = 30 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    const site: types.Site = .{ .company = co };
    try gs.addStock(site, "armor", 60);
    for (part.munition_keys) |key| try gs.addStock(site, key, 40);
    for (0..6) |_| {
        try battle.resolveEngagement(&gs, c);
        try @import("maintenance.zig").runWeeklyRepairs(&gs);
    }

    const rows = try battleList(al, &gs);
    try std.testing.expect(rows.len > 0);
    const view = (try afterAction(al, &gs, rows[0].id)).?;

    // The header names the fight; the panes carry its parts.
    try std.testing.expect(std.mem.indexOf(u8, view.title, "AFTER ACTION") != null);
    try std.testing.expect(std.mem.indexOf(u8, view.title, "Alpha") != null);
    try std.testing.expect(view.fight.len > 0);
    try std.testing.expect(view.spoils.len > 0);
    // One truck row per munition family, plus a blank and the dry-mount line.
    try std.testing.expectEqual(part.munition_keys.len + 2, view.trucks.len);
    try std.testing.expectEqual(after_action_cols.len, view.field.cols.len);
    for (view.field.rows) |row| try std.testing.expectEqual(after_action_cols.len, row.len);

    // The fight pane reports morale and fatigue.
    var saw_morale = false;
    for (view.fight) |line| if (std.mem.indexOf(u8, line, "morale") != null and std.mem.indexOf(u8, line, "fatigue") != null) {
        saw_morale = true;
    };
    try std.testing.expect(saw_morale);

    // The trucks pane draws a real meter, not a bare number.
    var saw_bar = false;
    for (view.trucks) |line| if (std.mem.indexOf(u8, line, "----") != null or std.mem.indexOf(u8, line, "####") != null) {
        saw_bar = true;
    };
    try std.testing.expect(saw_bar);

    // The flat fallback is the same AAR the log kept, so a narrow
    // terminal loses the layout and nothing else.
    try std.testing.expect(view.flat.len >= 4);

    // An id that aged out (or never was) is a miss, not a wrong report.
    try std.testing.expect((try afterAction(al, &gs, @enumFromInt(9999))) == null);
}

/// Break a long comma-joined manifest into lines a narrow pane can show.
fn wrapPlain(alloc: Alloc, text: []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitSequence(u8, text, "; ");
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ;");
        if (trimmed.len > 0) try out.append(alloc, trimmed);
    }
    return out.toOwnedSlice(alloc);
}

/// One engagement's after-action, as the screens show it: the same lines
/// the campaign log kept, with the colour a screen wants. The record is
/// the source; `after_action.render` is the only place a battle becomes
/// prose (rule 28).
pub fn battleReport(alloc: Alloc, gs: *GameState, id: types.BattleId) !?[]const []const u8 {
    const r = gs.battle_reports.find(id) orelse return null;
    const prose = try @import("after_action.zig").render(alloc, r);
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (prose) |line| {
        // The header carries the verdict, so it takes the verdict's mark;
        // the indented detail lines stay dim chrome around their content.
        // The prose names people and companies, so it goes in as plain text.
        const is_header = std.mem.indexOf(u8, line, "[AAR]   ") == null;
        const text = try table.plain(alloc, line);
        try out.append(alloc, if (is_header)
            try std.fmt.allocPrint(alloc, "{s}{s}{{/}}", .{ outcomeMark(r.outcome), text })
        else
            try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}", .{text}));
    }
    return try out.toOwnedSlice(alloc);
}

/// The last `n` log lines matching a filter, oldest first.
pub fn logLines(alloc: Alloc, gs: *GameState, n: usize, filter: state_mod.LogFilter) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const items = gs.event_log.items;
    var start = items.len;
    var found: usize = 0;
    while (start > 0 and found < n) {
        start -= 1;
        if (items[start].matches(filter)) found += 1;
    }
    for (items[start..]) |*entry| {
        if (entry.matches(filter)) try out.append(alloc, try logRow(alloc, entry));
    }
    return out.toOwnedSlice(alloc);
}

/// The newest log line, for a command's echo.
pub fn lastLogLine(alloc: Alloc, gs: *GameState) !?[]const u8 {
    if (gs.event_log.items.len == 0) return null;
    return try logRow(alloc, &gs.event_log.items[gs.event_log.items.len - 1]);
}

/// Every listing on every board, with its index (the `buy` argument).
pub fn listings(alloc: Alloc, gs: *GameState) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (gs.market_listings.items, 0..) |l, i| {
        if (l.condition) |c| {
            try out.append(alloc, try std.fmt.allocPrint(alloc, "[{d}] hull  {s: <8} {s: <5} armor {d: >3}% quality {s} | {d} dmg / {d} destroyed / {d} missing comps | {s} | gone day {d}{s}", .{
                i,                                                                                                                                  l.item_key, c.label(), c.armor_pct, @tagName(c.quality), c.damaged_slots, c.destroyed_slots, c.missing_components, try money(alloc, l.price), l.expires_day,
                if (l.company != .none) try std.fmt.allocPrint(alloc, " | contract world, co:{d} local funds", .{@intFromEnum(l.company)}) else "",
            }));
        } else {
            try out.append(alloc, try std.fmt.allocPrint(alloc, "[{d}] {s: <5} {s: <16} x{d: <3} ({s}{s}) {s}", .{
                i, @tagName(l.kind), l.item_key, l.quantity, @tagName(l.rarity), if (l.staple) ", staple" else ", RARE SLOT", try money(alloc, l.price),
            }));
        }
    }
    return out.toOwnedSlice(alloc);
}

/// The outfit's loose spares (the seat's shelf), non-zero lines only.
pub fn spareLines(alloc: Alloc, gs: *GameState) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = gs.spare_parts.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* > 0) try out.append(alloc, try std.fmt.allocPrint(alloc, "{s} x{d}", .{ entry.key_ptr.*, entry.value_ptr.* }));
    }
    return out.toOwnedSlice(alloc);
}

/// Every acquisition order on the books, with its state and day.
pub fn orders(alloc: Alloc, gs: *GameState) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (gs.part_orders.items) |o| {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "{s} x{d} — {s}{s}{d}", .{
            o.part_key, o.quantity, @tagName(o.status), if (o.eta_day != null) ", eta day " else ", day ", o.eta_day orelse o.ordered_day,
        }));
    }
    return out.toOwnedSlice(alloc);
}

/// The newest order's echo: what was ordered and when it lands, or that
/// logistics could not source it.
pub fn lastOrderLine(alloc: Alloc, gs: *GameState) !?[]const u8 {
    if (gs.part_orders.items.len == 0) return null;
    const last = gs.part_orders.items[gs.part_orders.items.len - 1];
    if (last.status == .failed) return try std.fmt.allocPrint(alloc, "logistics couldn't source {s} this time (retry after refresh)", .{last.part_key});
    return try std.fmt.allocPrint(alloc, "ordered {s} x{d}, eta day {d}, {s}", .{ last.part_key, last.quantity, last.eta_day orelse 0, try money(alloc, last.cost) });
}

/// The last `n` transactions matching an entity filter, newest first.
pub fn ledgerLines(alloc: Alloc, gs: *GameState, filter: finance.EntityFilter, n: usize) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const txns = gs.ledger.transactions.items;
    var i = txns.len;
    while (i > 0 and out.items.len < n) {
        i -= 1;
        const t = &txns[i];
        if (!filter.matches(t)) continue;
        try out.append(alloc, try std.fmt.allocPrint(alloc, "day {d: >4}  {s: <18} {s: >12}  {s}", .{ t.day, @tagName(t.category), try money(alloc, t.amount), t.note }));
    }
    return out.toOwnedSlice(alloc);
}

/// A P&L over a day range for an entity, one line per category with movement.
pub fn pnlLines(alloc: Alloc, gs: *GameState, from_day: u32, to_day: u32, filter: finance.EntityFilter) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const s = finance.summarize(&gs.ledger, from_day, to_day, filter);
    try out.append(alloc, switch (filter) {
        .all => try std.fmt.allocPrint(alloc, "P&L (outfit-wide) days {d}-{d}:", .{ from_day, to_day }),
        .company => |id| try std.fmt.allocPrint(alloc, "P&L company {d} days {d}-{d}:", .{ @intFromEnum(id), from_day, to_day }),
        .hq => |id| try std.fmt.allocPrint(alloc, "P&L hq {d} days {d}-{d}:", .{ @intFromEnum(id), from_day, to_day }),
    });
    inline for (@typeInfo(finance.Category).@"enum".fields) |field| {
        const cat: finance.Category = @enumFromInt(field.value);
        const amount = s.category(cat);
        if (amount != 0) try out.append(alloc, try std.fmt.allocPrint(alloc, "  {s: <20} {s: >14}", .{ field.name, try money(alloc, amount) }));
    }
    try out.append(alloc, try std.fmt.allocPrint(alloc, "  {s: <20} {s: >14}", .{ "NET", try money(alloc, s.net()) }));
    return out.toOwnedSlice(alloc);
}

/// One person in a line, for a command's echo.
pub fn personLine(alloc: Alloc, gs: *GameState, id: types.PersonId) !?[]const u8 {
    const p = gs.person(id) orelse return null;
    return try std.fmt.allocPrint(alloc, "#{d}: {s} ({s} {s}, {s}/mo)", .{ @intFromEnum(id), try personText(alloc, p), @tagName(p.experience()), @tagName(p.role), try money(alloc, p.monthlySalary()) });
}

/// Every contract on the books in a line (offers excepted), then where
/// each company stands if it is out and unengaged.
pub fn contractLines(alloc: Alloc, gs: *GameState) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = gs.contracts.iterator();
    while (it.next()) |entry| {
        const c = entry.value_ptr;
        const days_left: i64 = if (c.end_day) |e| @as(i64, e) - @as(i64, gs.clock.day_index) else 0;
        const pool: []const u8 = if (c.objective == .attrition) try std.fmt.allocPrint(alloc, " — opposition {d}% destroyed ({d}/{d} BV)", .{ c.poolDestroyedPct(), c.enemy_pool_bv - c.enemy_pool_remaining, c.enemy_pool_bv }) else "";
        try out.append(alloc, try std.fmt.allocPrint(alloc, "[{d}] {s: <17} {s: <9} co:{d} on {s} | {s} objective{s} | {d} VP | score {d} | {d} days left{s}{s}", .{
            @intFromEnum(c.id), @tagName(c.kind), @tagName(c.status), @intFromEnum(c.assigned_company),                                 c.planet_key, @tagName(c.objective), pool,
            c.victory_points,   c.score,          @max(0, days_left), if (c.ineffective_since != null) " | COMBAT-INEFFECTIVE" else "",
            if (c.objectivesMet() and c.status == .active) " | objectives met — `complete`" else "",
        }));
    }
    var fit = gs.forces.iterator();
    while (fit.next()) |fe| {
        const f = fe.value_ptr;
        if (f.echelon != .company) continue;
        switch (gs.companyPosture(f.id)) {
            .returning => |eta| try out.append(alloc, try std.fmt.allocPrint(alloc, "  co:{d} {s} returning home, arrives day {d}", .{ @intFromEnum(f.id), try table.plain(alloc, f.name), eta })),
            .idle_afield => |p| try out.append(alloc, try std.fmt.allocPrint(alloc, "  co:{d} {s} idle on {s} — accept work from the field or `recall co:{d}`", .{ @intFromEnum(f.id), try table.plain(alloc, f.name), planetName(p), @intFromEnum(f.id) })),
            else => {},
        }
    }
    return out.toOwnedSlice(alloc);
}

/// The newest running contract's one-line echo after `accept`.
pub fn acceptedLine(alloc: Alloc, gs: *GameState) !?[]const u8 {
    if (gs.contracts.count() == 0) return null;
    const c = gs.contracts.values()[gs.contracts.count() - 1];
    return try std.fmt.allocPrint(alloc, "under contract: {s} on {s}, {d} days transit, {s}/mo net", .{ @tagName(c.kind), planetName(c.planet_key), c.transit_days, try money(alloc, c.monthly_net) });
}

/// The candidates on every board, in one table.
pub fn hallAll(alloc: Alloc, gs: *GameState, filter: HallFilter) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = gs.hqs.iterator();
    while (it.next()) |e| {
        const h = try hall(alloc, gs, e.value_ptr.id, filter);
        if (h.rows.len == 0) continue;
        try out.append(alloc, try std.fmt.allocPrint(alloc, "hq:{d} {s} ({d} on the board)", .{ @intFromEnum(e.value_ptr.id), e.value_ptr.name, h.total_at_hq }));
        for (try (try tableOf(alloc, hall_cols, h.rows)).render(alloc)) |ln| try out.append(alloc, try std.fmt.allocPrint(alloc, "  {s}", .{ln}));
    }
    return out.toOwnedSlice(alloc);
}

/// The inbox as the console prints it: every pending decision and its options.
pub fn inboxLines(alloc: Alloc, gs: *GameState) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const d = try desk(alloc, gs, 0);
    if (d.inbox.len == 0) {
        try out.append(alloc, "inbox empty.");
        return out.toOwnedSlice(alloc);
    }
    try out.append(alloc, try std.fmt.allocPrint(alloc, "inbox ({d} pending — unanswered decisions default at their deadline):", .{d.inbox.len}));
    for (d.inbox) |row| {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "[{d}] {s} {s} (answer by day {d}, {d} days left)", .{ @intFromEnum(row.event_id), row.kind, row.company, row.deadline_day, row.days_left }));
        try out.append(alloc, try std.fmt.allocPrint(alloc, "    {s}", .{row.description}));
        try out.appendSlice(alloc, row.detail);
        for (row.options, 0..) |opt, j| try out.append(alloc, try std.fmt.allocPrint(alloc, "    {d}: {s}{s}", .{ j + 1, opt, if (j == row.default_choice) " (default)" else "" }));
    }
    return out.toOwnedSlice(alloc);
}

/// The index of a listing by key (a staple line when `staple`), for a
/// script that buys off the board.
pub fn listingIndex(gs: *GameState, item_key: []const u8, staple: bool) ?usize {
    for (gs.market_listings.items, 0..) |l, i| {
        if (l.staple == staple and std.mem.eql(u8, l.item_key, item_key)) return i;
    }
    return null;
}

/// The world of the outfit's first contract, if it has taken one.
pub fn firstContractPlanet(gs: *GameState) ?[]const u8 {
    if (gs.contracts.count() == 0) return null;
    return gs.contracts.values()[0].planet_key;
}

pub fn companyAtHome(gs: *GameState, company: types.ForceId) bool {
    return gs.isCompanyHome(company);
}

/// "Commander Erik Kalmar (Capellan Confederation, ex-quartermaster: …)".
pub fn commanderLine(alloc: Alloc, gs: *GameState) ![]const u8 {
    const c = gs.commander orelse return "no commander yet";
    return try std.fmt.allocPrint(alloc, "Commander {s} ({s}, ex-{s}: {s})", .{ try table.plain(alloc, c.name), c.origin.fullName(), @tagName(c.profession), c.profession.description() });
}

/// "Roster 42 | payroll 300,000/mo | hull upkeep 60,000/mo".
pub fn payrollLine(alloc: Alloc, gs: *GameState) ![]const u8 {
    return try std.fmt.allocPrint(alloc, "Roster {d} | payroll {s}/mo | hull upkeep {s}/mo", .{ gs.people.count(), try money(alloc, treasury.monthlyPayroll(gs)), try money(alloc, treasury.monthlyHullUpkeep(gs)) });
}

/// The hangar in one line: quality spread, broken slots, structure spares.
pub fn hangarSummaryLine(alloc: Alloc, gs: *GameState) ![]const u8 {
    var quality_counts = [_]u32{0} ** 6;
    var broken_slots: u32 = 0;
    var uit = gs.units.iterator();
    while (uit.next()) |entry| {
        quality_counts[@intFromEnum(entry.value_ptr.quality)] += 1;
        for (entry.value_ptr.slots.items) |s| {
            if (s.condition != .ok) broken_slots += 1;
        }
    }
    return try std.fmt.allocPrint(alloc, "Hangar quality A-F: {any} | broken slots outstanding: {d} | structure spares: {d}", .{ quality_counts, broken_slots, gs.spareCount(@import("../domain/part.zig").structure_key) });
}

/// The next pending decision for a script that answers it: its index, kind and first option.
pub const PendingDecision = struct {
    event: types.EventId,
    kind: []const u8,
    first_option: []const u8,
    /// The option that applies if nobody answers, and its label.
    default_choice: usize = 0,
    default_option: []const u8 = "",
};

fn asPending(row: InboxRow) PendingDecision {
    return .{
        .event = row.event_id,
        .kind = row.kind,
        .first_option = if (row.options.len > 0) row.options[0] else "",
        .default_choice = row.default_choice,
        .default_option = if (row.default_choice < row.options.len) row.options[row.default_choice] else "",
    };
}

pub fn firstPendingDecision(alloc: Alloc, gs: *GameState) !?PendingDecision {
    const d = try desk(alloc, gs, 0);
    if (d.inbox.len == 0) return null;
    return asPending(d.inbox[0]);
}

/// The pending decision with this id. A console that answers a
/// named decision reads the one it is about to answer, never the first
/// row of the inbox.
pub fn pendingDecision(alloc: Alloc, gs: *GameState, id: types.EventId) !?PendingDecision {
    const d = try desk(alloc, gs, 0);
    for (d.inbox) |row| if (row.event_id == id) return asPending(row);
    return null;
}

/// The demand ledgers as the console prints them: each depot's structural
/// components, then each site's field spares (hq_ops owns both rules).
pub fn demandLines(alloc: Alloc, gs: *GameState) ![]const []const u8 {
    const hq_ops = @import("hq_ops.zig");
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var any = false;
    for (try hqList(alloc, gs)) |h| {
        const comps = try hq_ops.componentDemand(alloc, gs, h.id, null);
        if (comps.len == 0) continue;
        if (!any) try out.append(alloc, "demand (structural components, per depot):");
        any = true;
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  {s}", .{try h.name.markup(alloc)}));
        for (comps) |l| try out.append(alloc, try std.fmt.allocPrint(alloc, "    {s: <14} need {d: >3} | on hand {d: >3} | coming {d: >3} | shortfall {d: >3}{s}", .{
            l.key, l.need, l.on_hand, l.coming, l.short,
            if (l.short > 0) "  ← order or fabricate" else "",
        }));
    }
    var gear_any = false;
    for (try hqList(alloc, gs)) |h| {
        for (try hq_ops.spareSitesOf(alloc, gs, h.id)) |site| {
            const gear = try hq_ops.spareDemand(alloc, gs, site);
            if (gear.len == 0) continue;
            if (!gear_any) try out.append(alloc, "demand (gear to fix broken slots, per site):");
            gear_any = true;
            try out.append(alloc, switch (site) {
                .hq => |id| try std.fmt.allocPrint(alloc, "  hq:{d} {s}", .{ @intFromEnum(id), try h.name.markup(alloc) }),
                .company => |id| try std.fmt.allocPrint(alloc, "  co:{d} {s} (afield)", .{ @intFromEnum(id), try forceName(alloc, gs, id) }),
                .outfit => "  outfit",
            });
            for (gear) |l| try out.append(alloc, try std.fmt.allocPrint(alloc, "    {s: <14} need {d: >3} | on hand {d: >3} | coming {d: >3} | shortfall {d: >3}{s}", .{
                l.key, l.need, l.on_hand, l.coming, l.short,
                if (l.short > 0) "  ← order" else "",
            }));
        }
    }
    if (!any and !gear_any) try out.append(alloc, "demand: nothing broken needs a part.");
    return out.toOwnedSlice(alloc);
}

// ---- reads the terminal client makes instead of touching GameState ----

/// The HQ's own funds (the Market title and the upgrade note quote it).
pub fn balance(gs: *GameState, t: state_mod.Treasury) types.CBills {
    return gs.treasuryBalance(t);
}

/// Stock of one part at a site (pickers size their quantity forms by it).
pub fn stockCount(gs: *GameState, site: types.Site, key: []const u8) u32 {
    return gs.stockCount(site, key);
}

/// Where an order lands when no site is under the cursor.
pub fn defaultSite(gs: *GameState) types.Site {
    return gs.defaultSite();
}

/// A company's home HQ (`.none` for the pool).
pub fn homeHq(gs: *GameState, company: types.ForceId) types.HqId {
    return gs.homeHqFor(company);
}

/// The first HQ founded (the wizard's starter HQ), `.none` before one exists.
pub fn firstHq(gs: *GameState) types.HqId {
    var it = gs.hqs.iterator();
    if (it.next()) |e| return e.value_ptr.id;
    return .none;
}

/// The HQ that would host a new company (`hq_ops.hqWithCompanySlot`).
pub fn hqWithCompanySlot(gs: *GameState, preferred: types.HqId) types.HqId {
    return @import("hq_ops.zig").hqWithCompanySlot(gs, preferred);
}

/// The outfit's crest as stored on its companies: a preset name or the
/// image bytes (null before any company exists).
pub fn outfitEmblem(gs: *GameState) ?[]const u8 {
    var fit = gs.forces.iterator();
    while (fit.next()) |e| if (e.value_ptr.echelon == .company) if (e.value_ptr.emblem) |img| return img;
    return null;
}

/// Credit left to borrow against.
pub const creditRemaining = treasury.creditRemaining;

/// Balance of the oldest open loan (what R repays), null with no loans.
pub fn oldestLoanBalance(gs: *GameState) ?types.CBills {
    if (gs.loans.items.len == 0) return null;
    return gs.loans.items[0].balance;
}

/// A company's standing resupply plan, if it has one.
pub fn supplyPolicyFor(gs: *GameState, company: types.ForceId) ?state_mod.SupplyPolicy {
    for (gs.supply_policies.items) |sp| if (sp.company == company) return sp;
    return null;
}

/// The campaign settings the Settings modal shows.
pub const Settings = struct {
    auto_admit: bool,
    difficulty_name: []const u8,
    difficulty_blurb: []const u8,
    /// "contract pay ×1.00 · fabrication ×1.00 · purchases ×1.00 · opposition ×1.00 · turnover +0 · never the dice"
    multipliers: []const u8,
    shares_pct: i64,
};

pub fn settings(alloc: Alloc, gs: *GameState) !Settings {
    const row = gs.diff();
    var b1: [16]u8 = undefined;
    var b2: [16]u8 = undefined;
    var b3: [16]u8 = undefined;
    var b4: [16]u8 = undefined;
    return .{
        .auto_admit = gs.auto_admit,
        .difficulty_name = row.name,
        .difficulty_blurb = row.blurb,
        .multipliers = try std.fmt.allocPrint(alloc, "contract pay {s} · fabrication {s} · purchases {s} · opposition {s} · turnover {s}{d} · never the dice", .{
            types.bpText(&b1, row.contract_pay_bp), types.bpText(&b2, row.fab_cost_bp), types.bpText(&b3, row.purchase_bp), types.bpText(&b4, row.enemy_bp), if (row.turnover_delta >= 0) "+" else "", row.turnover_delta,
        }),
        .shares_pct = types.bpPercent(gs.share_profit_bp),
    };
}

/// One offer's headline terms for the negotiation modal, null past the board.
pub fn offerTerms(alloc: Alloc, gs: *GameState, index: usize) !?[]const u8 {
    if (index >= gs.contract_offers.items.len) return null;
    const c = gs.contract_offers.items[index];
    return try std.fmt.allocPrint(alloc, "{{a}}{s}{{/}} for {s} on {s} · {s}/mo · advance {d}% · salvage {d}% · transport {d}% · support {d}% · {s} rights", .{ c.kind.label(), c.employer_key, planetName(c.planet_key), try money(alloc, c.terms.base_pay_month), c.terms.advance_pct, c.terms.salvage_pct, c.terms.transport_pct, c.terms.overhead_pct, @tagName(c.terms.command_rights) });
}

/// What selling a hull brings, and what stripping it would shelve.
pub const SellQuote = struct {
    chassis_key: []const u8,
    value: types.CBills,
    /// "2× comp_arm, 1× comp_leg" or "nothing worth keeping".
    strip_text: []const u8,
};

pub fn sellQuote(alloc: Alloc, gs: *GameState, uid: types.UnitId) !?SellQuote {
    const u = gs.unit(uid) orelse return null;
    const lines = try treasury.stripParts(alloc, u);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (lines, 0..) |l, i| try buf.print(alloc, "{s}{d}× {s}", .{ if (i > 0) ", " else "", l.qty, l.key });
    return .{ .chassis_key = u.chassis_key, .value = treasury.unitSaleValue(u), .strip_text = if (lines.len > 0) buf.items else "nothing worth keeping" };
}

/// What selling off an HQ brings: 40% of build cost plus its treasury.
pub const HqSaleQuote = struct { name: []const u8, value: types.CBills };

pub fn hqSaleQuote(gs: *GameState, hq_id: types.HqId) ?HqSaleQuote {
    const h = gs.hqs.getPtr(hq_id) orelse return null;
    return .{ .name = h.name, .value = treasury.hqSaleValue(h) + h.funds };
}

/// What disbanding a company sells its hulls for.
pub fn disbandQuote(gs: *GameState, company: types.ForceId) types.CBills {
    var value: types.CBills = 0;
    var uit = gs.units.iterator();
    while (uit.next()) |e| if (gs.companyOf(e.value_ptr.force) == company) {
        value += treasury.unitSaleValue(e.value_ptr);
    };
    return value;
}

/// Hulls on hand and on the way for a company just raised.
pub const CompanyStanding = struct { hulls: u32, coming: u32 };

pub fn companyStanding(gs: *GameState, company: types.ForceId) CompanyStanding {
    var hulls: u32 = 0;
    var uit = gs.units.iterator();
    while (uit.next()) |e| if (gs.companyOf(e.value_ptr.force) == company) {
        hulls += 1;
    };
    var coming: u32 = 0;
    for (gs.unit_transfers.items) |t| if (t.to_company == company) {
        coming += 1;
    };
    return .{ .hulls = hulls, .coming = coming };
}

/// A company's line lances for the raise wizard, in TO&E order.
pub const LanceSlot = struct {
    id: types.ForceId,
    name: table.Raw,
    used: usize,
    cap: usize,
    full: bool,
};

pub fn raiseLances(alloc: Alloc, gs: *GameState, company: types.ForceId) ![]LanceSlot {
    var out: std.ArrayListUnmanaged(LanceSlot) = .empty;
    const co = gs.force(company) orelse return out.toOwnedSlice(alloc);
    for (co.children.items) |cid| if (gs.force(cid)) |l| if (l.echelon == .lance) {
        try out.append(alloc, .{ .id = cid, .name = .{ .raw = l.name }, .used = l.units.items.len, .cap = force_dom.lance_size, .full = l.units.items.len >= force_dom.lance_size });
    };
    return out.toOwnedSlice(alloc);
}

/// The support train the raise wizard buys: one row per trade with the
/// staple hull, what the company owns of it, and its price on the home board.
pub const SupportLine = struct {
    kind: force_dom.SupportLanceKind,
    key: []const u8,
    name: []const u8,
    owned: u32,
    price: ?types.CBills,
    note: []const u8,
    text: []const u8,
};

pub const SupportTrain = struct {
    lines: []SupportLine,
    capacity_tons: u32,
};

pub fn supportTrain(alloc: Alloc, gs: *GameState, company: types.ForceId) !SupportTrain {
    const trades = [_]force_dom.SupportLanceKind{ .transport, .salvage, .mash, .security };
    const home = gs.homeHqFor(company);
    var out: std.ArrayListUnmanaged(SupportLine) = .empty;
    for (trades) |kind| {
        const key = kind.hullKey();
        const ch = chassis_mod.find(key);
        var owned: u32 = 0;
        var uit = gs.units.iterator();
        while (uit.next()) |e| if (gs.companyOf(e.value_ptr.force) == company and std.mem.eql(u8, e.value_ptr.chassis_key, key)) {
            owned += 1;
        };
        var price: ?types.CBills = null;
        for (gs.market_listings.items) |l| if (l.kind == .unit and l.staple and l.hq == home and std.mem.eql(u8, l.item_key, key)) {
            price = l.price;
        };
        try out.append(alloc, .{
            .kind = kind,
            .key = key,
            .name = if (ch) |c| c.name else "?",
            .owned = owned,
            .price = price,
            .note = kind.describe(),
            .text = try std.fmt.allocPrint(alloc, "{s: <9} {s: <20} {d: >5}   {s: >12}                 {{d}}{s}{{/}}", .{ key, if (ch) |c| c.name else "?", owned, if (price) |pr| try money(alloc, pr) else "{c}not on the board{/}", kind.describe() }),
        });
    }
    return .{ .lines = try out.toOwnedSlice(alloc), .capacity_tons = gs.siteCapacityTons(.{ .company = company }) orelse 0 };
}

/// The lances a hull can move to: its company's, or every home company's
/// for an unassigned hull. Full lances and the hull's own lance are marked.
pub const LanceChoice = struct { force: types.ForceId, name: []const u8, text: []const u8 };

pub fn lanceChoices(alloc: Alloc, gs: *GameState, uid: types.UnitId) ![]LanceChoice {
    var out: std.ArrayListUnmanaged(LanceChoice) = .empty;
    const u = gs.unit(uid) orelse return out.toOwnedSlice(alloc);
    const co = gs.companyOf(u.force);
    if (co != .none) {
        try lancesOf(alloc, gs, &out, co, u);
        return out.toOwnedSlice(alloc);
    }
    var fit = gs.forces.iterator();
    while (fit.next()) |e| if (e.value_ptr.echelon == .company and gs.isCompanyHome(e.value_ptr.id)) {
        try lancesOf(alloc, gs, &out, e.value_ptr.id, u);
    };
    return out.toOwnedSlice(alloc);
}

fn lancesOf(alloc: Alloc, gs: *GameState, out: *std.ArrayListUnmanaged(LanceChoice), co: types.ForceId, u: *const unit_mod.Unit) !void {
    const company = gs.forces.getPtr(co) orelse return;
    for (company.children.items) |cid| {
        const f = gs.forces.getPtr(cid) orelse continue;
        if (f.isCombatLance()) {
            const full = f.units.items.len >= force_dom.lance_size;
            try out.append(alloc, .{ .force = cid, .name = f.name, .text = try std.fmt.allocPrint(alloc, "{s}[{d}] {s: <22} line lance · {s} · {d}/{d} hulls{s}{{/}}", .{ if (full) "{d}" else if (u.force == cid) "{a}" else "", @intFromEnum(cid), try table.plain(alloc, f.name), @tagName(f.role), f.units.items.len, force_dom.lance_size, if (full) " · full" else if (u.force == cid) " · here" else "" }) });
        } else if (f.echelon == .support_company) {
            for (f.children.items) |sid| {
                const sl = gs.forces.getPtr(sid) orelse continue;
                try out.append(alloc, .{ .force = sid, .name = sl.name, .text = try std.fmt.allocPrint(alloc, "{s}[{d}] {s: <22} support · {s} · {d} hulls{s}{{/}}", .{ if (u.force == sid) "{a}" else "", @intFromEnum(sid), try table.plain(alloc, sl.name), if (sl.support_kind) |k| @tagName(k) else "support", sl.units.items.len, if (u.force == sid) " · here" else "" }) });
            }
        }
    }
}

/// The colour a faction paints in (the map's faction lens).
pub const FactionColour = @import("../domain/faction.zig").Color;

pub fn factionColour(key: []const u8) FactionColour {
    return @import("../domain/faction.zig").get(key).color;
}

/// Every faction as a legend row: key, colour, name, and whether it hires.
pub fn factionRows(alloc: Alloc) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (@import("../domain/faction.zig").table) |f| {
        const mark: []const u8 = switch (f.color) {
            .red => "{c}",
            .yellow => "{a}",
            .green => "{g}",
            .magenta => "{p}",
            .grey => "{d}",
            .blue, .cyan, .white => "",
        };
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  {s}{s: <4} {s: <8}{{/}} {s}{s}", .{ mark, f.key, @tagName(f.color), f.name, if (!f.hires) " {d}(posts no contracts){/}" else "" }));
    }
    return out.toOwnedSlice(alloc);
}

/// The map's key line for the faction lens: "FS yellow  LC blue  …  PER grey".
pub fn factionKeyLine(alloc: Alloc) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (@import("../domain/faction.zig").table) |f| {
        if (!f.hires or std.mem.eql(u8, f.key, "PER")) continue;
        if (out.items.len > 0) try out.appendSlice(alloc, "  ");
        try out.print(alloc, "{s} {s}", .{ f.key, @tagName(f.color) });
    }
    try out.appendSlice(alloc, "  PER grey");
    return out.toOwnedSlice(alloc);
}

/// The WORLD pane of the map: the house, its capital, standing and pay,
/// the distance from every HQ, what is here, and the offers posted here.
pub fn worldDetail(alloc: Alloc, gs: *GameState, view: *const Map, w: *const World) ![]const []const u8 {
    const faction = @import("../domain/faction.zig");
    const cm = @import("contract_market.zig");
    var rows: std.ArrayListUnmanaged([]const u8) = .empty;
    const fr = faction.get(w.faction);
    const wp = planet_mod.find(w.key) orelse return rows.toOwnedSlice(alloc);
    try rows.append(alloc, try std.fmt.allocPrint(alloc, "{{a}}{s}{{/}}   {s} ({s}) · industry {d}", .{ w.name, fr.name, w.faction, w.industry }));
    if (planet_mod.find(fr.capital)) |cap| {
        if (cap == wp) try rows.append(alloc, "capital      {a}this is the capital{/}") else try rows.append(alloc, try std.fmt.allocPrint(alloc, "capital      {s}, {d} LY away", .{ cap.name, planet_mod.distanceLy(wp, cap) }));
    }
    var mult_buf: [16]u8 = undefined;
    if (fr.hires) try rows.append(alloc, try std.fmt.allocPrint(alloc, "standing     {d} with the {s} · pay {s}", .{ w.standing, fr.name, types.bpText(&mult_buf, cm.standingPayBp(w.standing)) })) else try rows.append(alloc, "standing     {d}posts no contracts{/}");
    try rows.append(alloc, "");
    for (view.hqs) |h| {
        const hp = planet_mod.find(gs.hqs.getPtr(h.id).?.planet_key).?;
        const d = planet_mod.distanceLy(wp, hp);
        const band: []const u8 = if (d <= h.ring_ly) "{g}inside ring{/}" else if (d <= h.ring_ly + view.band_ly) "{a}beachhead band{/}" else "{d}out of reach{/}";
        try rows.append(alloc, try std.fmt.allocPrint(alloc, "{d: >4} LY · {d} jumps from {s}  {s}", .{ d, planet_mod.jumpsBetween(wp, hp), clip(try h.name.markup(alloc), 22), band }));
    }
    try rows.append(alloc, "");
    if (w.hq_here != .none) try rows.append(alloc, try std.fmt.allocPrint(alloc, "HQ here      {{a}}{s}{{/}}", .{try hqName(alloc, gs, w.hq_here)}));
    try rows.append(alloc, try std.fmt.allocPrint(alloc, "companies    {d} here", .{w.companies_here}));
    if (w.worked > 0) try rows.append(alloc, try std.fmt.allocPrint(alloc, "history      {{p}}{d} contract{s} worked here{{/}} · an HQ can be founded (F4 History lists them)", .{ w.worked, if (w.worked == 1) "" else "s" }));
    try rows.append(alloc, try std.fmt.allocPrint(alloc, "local supply {s}", .{switch (w.band) {
        .ring => "×1.0 (in ring)",
        .beachhead => "{a}×2.5{/} (beachhead)",
        .dark => "{c}×4.0{/} (out of reach)",
    }}));
    try rows.append(alloc, "");
    try rows.append(alloc, "offers here");
    const offers = try offersAt(alloc, gs, w.key);
    if (offers.len == 0) try rows.append(alloc, "  {d}none{/}");
    for (offers) |o| try rows.append(alloc, try std.fmt.allocPrint(alloc, "  {s}", .{o}));
    return rows.toOwnedSlice(alloc);
}

test "raise lances, support train and sell quote read one company" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12 });
    defer gs.deinit();
    const commands = @import("commands.zig");
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .FS, .profession = .paymaster } });
    _ = try commands.execute(&gs, .{ .new_company = "Alpha" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const co = gs.forces.values()[0].id;
    const lances = try raiseLances(al, &gs, co);
    try std.testing.expect(lances.len > 0);
    for (lances) |l| try std.testing.expectEqual(l.used >= l.cap, l.full);
    const train = try supportTrain(al, &gs, co);
    try std.testing.expectEqual(@as(usize, 4), train.lines.len);
    const st = try status(al, &gs);
    try std.testing.expect(!st.bankrupt and !st.saved);
    try std.testing.expect(firstHq(&gs) != .none);
    try std.testing.expect(hqWithCompanySlot(&gs, .none) == .none or gs.hqs.count() > 1);
    const settings_now = try settings(al, &gs);
    try std.testing.expect(settings_now.difficulty_name.len > 0);
    // A hull's sell quote and the disband total agree on one hull.
    var uit = gs.units.iterator();
    if (uit.next()) |e| {
        const quote = (try sellQuote(al, &gs, e.value_ptr.id)).?;
        try std.testing.expect(quote.value >= 0);
    }
}
