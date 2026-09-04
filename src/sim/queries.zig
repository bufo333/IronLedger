//! Query layer (Stage 12, docs/tui.md "Queries the core must expose"):
//! structured, display-ready views over GameState shared by the CLI and
//! the TUI. Pure — every function takes an allocator (the frontends hand
//! in a per-frame arena) and mutates nothing. Row text carries the same
//! `{a}…{/}` emphasis markup the mockups use; frontends strip or render it.
//! MekHQ counterpart: none (its Swing panels read the campaign directly).

const std = @import("std");
const types = @import("../domain/types.zig");
const planet_mod = @import("../domain/planet.zig");
const person_mod = @import("../domain/person.zig");
const unit_mod = @import("../domain/unit.zig");
const contract_mod = @import("../domain/contract.zig");
const chassis_mod = @import("../domain/chassis.zig");
const finance = @import("../econ/finance.zig");
const checklist = @import("checklist.zig");
const contract_events = @import("contract_events.zig");
const contract_control = @import("contract_control.zig");
const state_mod = @import("state.zig");
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

/// Pad plain `text` to `width` cells, then wrap it in markup — so the
/// markup never counts toward a column's width.
/// Pad to `width` terminal cells, counting code points rather than bytes
/// (an em dash is one cell, three bytes), so columns line up.
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

pub fn padMk(alloc: Alloc, mk: []const u8, text: []const u8, width: usize) ![]const u8 {
    const shown = if (text.len > width) text[0..width] else text;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(alloc, mk);
    try out.appendSlice(alloc, shown);
    var i: usize = shown.len;
    while (i < width) : (i += 1) try out.append(alloc, ' ');
    if (mk.len > 0) try out.appendSlice(alloc, "{/}");
    return out.toOwnedSlice(alloc);
}

/// Clip plain text to `width` cells (no padding).
pub fn clip(text: []const u8, width: usize) []const u8 {
    return if (text.len > width) text[0..width] else text;
}

pub fn planetName(key: ?[]const u8) []const u8 {
    const k = key orelse return "—";
    return if (planet_mod.find(k)) |p| p.name else k;
}

pub fn personName(alloc: Alloc, gs: *GameState, id: types.PersonId) ![]const u8 {
    const p = gs.person(id) orelse return "—";
    return std.fmt.allocPrint(alloc, "{s} {s}", .{ p.first_name, p.last_name });
}

pub fn hqName(gs: *GameState, id: types.HqId) []const u8 {
    return if (gs.hqs.getPtr(id)) |h| h.name else "—";
}

pub fn forceName(gs: *GameState, id: types.ForceId) []const u8 {
    return if (gs.forces.getPtr(id)) |f| f.name else "—";
}

// ------------------------------------------------------------------ status

pub const Status = struct {
    date: []const u8,
    day: u32,
    funds: []const u8,
    reputation: i32,
    companies: u32,
    hqs: u32,
    hulls: u32,
    people: u32,
    inbox: usize,
    checklist: usize,
    blocking: usize,
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
    while (pit.next()) |e| if (e.value_ptr.status == .active or e.value_ptr.status == .wounded) {
        headcount += 1;
    };
    const warnings = try checklist.turnWarnings(gs, alloc);
    var blocking: usize = 0;
    for (warnings) |w| if (isBlocking(w.kind)) {
        blocking += 1;
    };
    return .{
        .date = try std.fmt.allocPrint(alloc, "{d}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day }),
        .day = gs.clock.day_index,
        .funds = try money(alloc, gs.funds),
        .reputation = gs.reputation,
        .companies = companies,
        .hqs = @intCast(gs.hqs.count()),
        .hulls = hulls,
        .people = headcount,
        .inbox = gs.event_queue.unresolvedCount(),
        .checklist = warnings.len,
        .blocking = blocking,
    };
}

/// Warnings that should stop a turn until acknowledged (the rest are notices).
pub fn isBlocking(kind: checklist.WarningKind) bool {
    return switch (kind) {
        .decision_due, .understaffed_hq, .overdrawn, .combat_ineffective, .dry_ammo, .hungry, .untreated_wounded, .insolvent => true,
        else => false,
    };
}

// -------------------------------------------------------------------- desk

pub const ChecklistRow = struct {
    kind: checklist.WarningKind,
    blocking: bool,
    text: []const u8,
    /// Tab that fixes it: 0 desk … 7 lab (docs/tui.md screen order).
    jump: u8,
};

pub const InboxRow = struct {
    event_index: usize,
    kind: []const u8,
    company: []const u8,
    deadline_day: u32,
    days_left: i64,
    description: []const u8,
    options: []const []const u8,
    default_choice: usize,
};

pub const Desk = struct {
    checklist: []ChecklistRow,
    inbox: []InboxRow,
    company_header: []const u8,
    companies: []const []const u8,
    hqs: []const []const u8,
    log: []const []const u8,
};

fn jumpFor(kind: checklist.WarningKind) u8 {
    return switch (kind) {
        .decision_due => 0,
        .open_slots, .tech_overloaded, .medbay_over_capacity => 2,
        .combat_ineffective, .objectives_met, .company_idle_afield => 3,
        .overdrawn, .insolvent => 4,
        .hungry, .dry_ammo => 5,
        .understaffed_hq, .depot_backlog => 6,
        .untreated_wounded => 8,
    };
}

pub fn desk(alloc: Alloc, gs: *GameState, log_rows: usize) !Desk {
    const day = gs.clock.day_index;
    const warnings = try checklist.turnWarnings(gs, alloc);
    var cl: std.ArrayListUnmanaged(ChecklistRow) = .empty;
    for (warnings) |w| {
        try cl.append(alloc, .{ .kind = w.kind, .blocking = isBlocking(w.kind), .text = w.text, .jump = jumpFor(w.kind) });
    }

    var inbox: std.ArrayListUnmanaged(InboxRow) = .empty;
    for (gs.event_queue.pending.items, 0..) |ev, i| {
        if (!ev.needsDecision()) continue;
        var opts: std.ArrayListUnmanaged([]const u8) = .empty;
        for (ev.options) |o| try opts.append(alloc, try std.fmt.allocPrint(alloc, "{s}   {s}", .{ o.label, try effectsText(alloc, o.effects) }));
        const entry = contract_events.entryForKind(ev.kind);
        try inbox.append(alloc, .{
            .event_index = i,
            .kind = @tagName(ev.kind),
            .company = forceName(gs, ev.company),
            .deadline_day = ev.deadline_day,
            .days_left = @as(i64, ev.deadline_day) - @as(i64, day),
            .description = if (entry) |e| e.log else "",
            .options = try opts.toOwnedSlice(alloc),
            .default_choice = ev.default_choice,
        });
    }

    var companies: std.ArrayListUnmanaged([]const u8) = .empty;
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
        var busy: u32 = 0;
        var queued: u32 = 0;
        for (gs.bay_jobs.items) |j| if (j.hq == h.id) {
            if (j.started_day != null) busy += 1 else queued += 1;
        };
        try hqs.append(alloc, try std.fmt.allocPrint(alloc, "hq:{d} {{a}}{s}{{/}}  {s} · ring {d} LY · {s}", .{ @intFromEnum(h.id), h.name, @tagName(h.tier), h.influenceLy(), planetName(h.planet_key) }));
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
        .checklist = try cl.toOwnedSlice(alloc),
        .inbox = try inbox.toOwnedSlice(alloc),
        .company_header = "co   name              hq                       posture                    contract           location        fat  mor  hulls   ready  supply            local funds",
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
        .xp_all => |x| try appendTag(alloc, &out, true, try std.fmt.allocPrint(alloc, "XP +{d} all", .{x})),
        .score => |s| try appendTag(alloc, &out, s >= 0, try std.fmt.allocPrint(alloc, "contract score {s}{d}", .{ if (s >= 0) "+" else "", s })),
        .damage_random_units => |n| try appendTag(alloc, &out, false, try std.fmt.allocPrint(alloc, "{d} line hull{s} damaged", .{ n, if (n == 1) "" else "s" })),
        .damage_convoy_units => |n| try appendTag(alloc, &out, false, try std.fmt.allocPrint(alloc, "{d} support vehicle{s} damaged", .{ n, if (n == 1) "" else "s" })),
        .parts_windfall => |n| try appendTag(alloc, &out, true, try std.fmt.allocPrint(alloc, "parts windfall ×{d}", .{n})),
        .supply_loss => |c| try appendTag(alloc, &out, false, try std.fmt.allocPrint(alloc, "supplies −{s} C", .{try money(alloc, c)})),
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
    return std.fmt.allocPrint(alloc, "{{d}}d{d: <4}{{/}} {s}{s}{{/}}", .{ e.day, mk, e.text });
}

fn companyRow(alloc: Alloc, gs: *GameState, id: types.ForceId) ![]const u8 {
    const f = gs.forces.getPtr(id).?;
    const day = gs.clock.day_index;
    var hulls: u32 = 0;
    var ready: u32 = 0;
    var uit = gs.units.iterator();
    while (uit.next()) |e| {
        const u = e.value_ptr;
        if (gs.companyOf(u.force) != id or u.status == .destroyed or u.status == .mothballed) continue;
        hulls += 1;
        if (u.status == .ready) ready += 1;
    }
    var fat: u32 = 0;
    var mor: u32 = 0;
    var n: u32 = 0;
    var pit = gs.people.iterator();
    while (pit.next()) |e| {
        const p = e.value_ptr;
        if (p.status != .active or gs.companyOf(p.assigned_force) != id) continue;
        fat += p.fatigue;
        mor += p.morale;
        n += 1;
    }
    if (n == 0) n = 1;
    const contract = gs.deploymentContract(id);
    const posture: []const u8 = if (contract) |c|
        (if (c.status == .transit) try padMk(alloc, "{a}", try std.fmt.allocPrint(alloc, "IN TRANSIT · arrive d{d}", .{c.arrive_day orelse day}), 26) else try padMk(alloc, "{a}", try std.fmt.allocPrint(alloc, "DEPLOYED · {s}", .{@tagName(c.kind)}), 26))
    else if (f.return_eta_day) |eta|
        try padMk(alloc, "{a}", try std.fmt.allocPrint(alloc, "RETURNING · home d{d}", .{eta}), 26)
    else if (f.location_planet != null)
        try padMk(alloc, "{a}", "afield, idle", 26)
    else
        try padMk(alloc, "{g}", "at home", 26);
    const contract_s: []const u8 = if (contract) |c| try std.fmt.allocPrint(alloc, "[{d}] {s}", .{ @intFromEnum(c.id), @tagName(c.kind) }) else "—";
    const location: []const u8 = if (f.location_planet) |p| planetName(p) else if (gs.hqs.getPtr(f.supplying_hq)) |h| planetName(h.planet_key) else "—";
    const site: types.Site = .{ .company = id };
    const tons = gs.siteTons(site);
    const cap = gs.siteCapacityTons(site) orelse 0;
    const cap_mk: []const u8 = if (cap > 0 and tons * 4 < cap) "{a}" else "{g}";
    const supply_s = try padMk(alloc, cap_mk, try std.fmt.allocPrint(alloc, "{d}t / {d}t", .{ tons, cap }), 13);
    return std.fmt.allocPrint(alloc, "{d: <4} {s: <17} {s: <24} {s} {s: <18} {s: <15} {d: >3}  {d: >3}  {d: >5}   {d: >5}  {s}  {s: >14}", .{
        @intFromEnum(id),                     clip(f.name, 17),
        clip(hqName(gs, f.supplying_hq), 24), posture,
        clip(contract_s, 18),                 clip(location, 15),
        fat / n,                              mor / n,
        hulls,                                ready,
        supply_s,                             try money(alloc, f.local_funds),
    });
}

// --------------------------------------------------------------- contracts

pub const OfferRow = struct {
    index: usize,
    text: []const u8,
};

pub const ActiveRow = struct {
    id: types.ContractId,
    company: types.ForceId,
    lines: []const []const u8,
    objectives_met: bool,
};

pub const Contracts = struct {
    board_header: []const u8,
    board: []OfferRow,
    active: []ActiveRow,
    notes: []const u8,
};

pub fn contracts(alloc: Alloc, gs: *GameState) !Contracts {
    const day = gs.clock.day_index;
    var board: std.ArrayListUnmanaged(OfferRow) = .empty;
    for (gs.contract_offers.items, 0..) |c, i| {
        const total = c.terms.totalBasePay();
        try board.append(alloc, .{ .index = i, .text = try std.fmt.allocPrint(alloc, "{s: <18} {s: <16} {s: <4} {d: >4}  {s} {d: >3}  {s: >12}  {s: >13}  {s: <5} {d: >3}%  {s: <11} {d: >4} days", .{
            @tagName(c.kind),                                                                                  clip(planetName(c.planet_key), 16),
            c.employer_key,                                                                                    c.dist_ly,
            try padMk(alloc, if (c.beachhead) "{a}" else "", if (c.beachhead) "beachhead" else "in ring", 10), c.terms.length_months,
            try money(alloc, c.terms.base_pay_month),                                                          try money(alloc, total),
            c.enemy_key,                                                                                       c.terms.salvage_pct,
            @tagName(c.terms.command_rights),                                                                  c.transit_days,
        }) });
    }

    var active: std.ArrayListUnmanaged(ActiveRow) = .empty;
    var it = gs.contracts.iterator();
    while (it.next()) |e| {
        const c = e.value_ptr;
        if (c.status != .transit and c.status != .active) continue;
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        try lines.append(alloc, try std.fmt.allocPrint(alloc, "[{d}] {{a}}{s}{{/}}  {s}  co:{d} {s} on {s}  ·  employer {s} · vs {s}  ·  {s} objective", .{
            @intFromEnum(c.id),               @tagName(c.kind),                  @tagName(c.status),
            @intFromEnum(c.assigned_company), forceName(gs, c.assigned_company), planetName(c.planet_key),
            c.employer_key,                   c.enemy_key,                       @tagName(c.objective),
        }));
        var bar_buf: [30]u8 = undefined;
        if (c.objective == .attrition) {
            const destroyed = c.enemy_pool_bv - c.enemy_pool_remaining;
            try lines.append(alloc, try std.fmt.allocPrint(alloc, "    opposition  {{a}}{s}{{/}}  {d}% destroyed  {d} / {d} BV", .{ barText(&bar_buf, destroyed, c.enemy_pool_bv), c.poolDestroyedPct(), destroyed, c.enemy_pool_bv }));
        }
        if (c.end_day) |end| {
            const start = c.arrive_day orelse c.start_day orelse day;
            const total: i64 = @as(i64, end) - @as(i64, start);
            const done: i64 = @as(i64, day) - @as(i64, start);
            try lines.append(alloc, try std.fmt.allocPrint(alloc, "    duration    {{d}}{s}{{/}}  day {d} of {d} · {d} days left", .{ barText(&bar_buf, done, total), @max(0, done), @max(0, total), @max(0, total - done) }));
        }
        try lines.append(alloc, try std.fmt.allocPrint(alloc, "    victory pts {{g}}{d}{{/}} · score {d} · battles {d} · casualties {d} · next engagement {s}", .{
            c.victory_points, c.score, c.battles_fought, c.casualties,
            if (c.next_battle_day) |nb| try std.fmt.allocPrint(alloc, "~day {d}", .{nb}) else "—",
        }));
        const fieldable = contract_control.fieldableBv(gs, c.assigned_company);
        const pct: i64 = if (c.committed_bv > 0) @divTrunc(fieldable * 100, c.committed_bv) else 0;
        const pct_mk: []const u8 = if (pct < 50) "{c}" else if (pct < 75) "{a}" else "{g}";
        try lines.append(alloc, try std.fmt.allocPrint(alloc, "    committed   {d} BV · fieldable {d} BV {s}({d}%){{/}} · ineffective below 50%{s}", .{
            c.committed_bv, fieldable, pct_mk, pct,
            if (c.ineffective_since) |since| try std.fmt.allocPrint(alloc, " · {{c}}grace since day {d}{{/}}", .{since}) else "",
        }));
        try lines.append(alloc, try std.fmt.allocPrint(alloc, "    pay         {s} / month · advance {s} · salvage {d}% · {s} rights", .{
            try money(alloc, c.terms.base_pay_month), try money(alloc, c.terms.advanceAmount()), c.terms.salvage_pct, @tagName(c.terms.command_rights),
        }));
        {
            // Salvage capacity (battle.zig): what the trucks can haul off a won field. // TUNE mirrors battle.zig
            var trucks: i64 = 0;
            var salvage_lance = false;
            var uit = gs.units.iterator();
            while (uit.next()) |ue| {
                const u = ue.value_ptr;
                if (u.status == .destroyed or gs.companyOf(u.force) != c.assigned_company) continue;
                if (std.mem.eql(u8, u.chassis_key, "SVT-1")) trucks += 1;
            }
            var fit = gs.forces.iterator();
            while (fit.next()) |fe| {
                const f = fe.value_ptr;
                if (f.echelon == .support_lance and f.support_kind == .salvage and f.units.items.len > 0 and gs.companyOf(f.id) == c.assigned_company) salvage_lance = true;
            }
            const haul_bv: i64 = if (trucks > 0) trucks * 300 else 150;
            var per_battle: types.CBills = @divTrunc(haul_bv * 2_000 * c.terms.salvage_pct, 100);
            if (salvage_lance) per_battle = types.applyBp(per_battle, 12_500);
            try lines.append(alloc, try std.fmt.allocPrint(alloc, "    salvage     {d} SVT-1 truck{s} haul up to {d} BV per won battle → up to {s} at {d}%{s}", .{
                trucks, if (trucks == 1) "" else "s", haul_bv, try money(alloc, per_battle), c.terms.salvage_pct,
                if (salvage_lance) " (+25% crewed salvage lance)" else " (no salvage lance: −25%)",
            }));
        }
        if (c.objectivesMet()) try lines.append(alloc, "    {g}objectives met{/} — [c] complete closes out (remainder forfeited)");
        try lines.append(alloc, "");
        try active.append(alloc, .{ .id = c.id, .company = c.assigned_company, .lines = try lines.toOwnedSlice(alloc), .objectives_met = c.objectivesMet() });
    }
    // Companies whose contract is over but who are still out there: they
    // idle on that world (eating from their trucks) until recalled.
    var fit = gs.forces.iterator();
    while (fit.next()) |e| {
        const f = e.value_ptr;
        if (f.echelon != .company or gs.isCompanyHome(f.id) or gs.deploymentContract(f.id) != null) continue;
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        if (f.return_eta_day) |eta| {
            try lines.append(alloc, try std.fmt.allocPrint(alloc, "[—] {{a}}returning{{/}}  co:{d} {s} on the way home from {s}  ·  arrives day {d} ({d} days)", .{ @intFromEnum(f.id), f.name, planetName(f.location_planet), eta, eta -| day }));
        } else {
            try lines.append(alloc, try std.fmt.allocPrint(alloc, "[—] {{a}}idle afield{{/}}  co:{d} {s} on {s}  ·  contract over, no orders", .{ @intFromEnum(f.id), f.name, planetName(f.location_planet) }));
            try lines.append(alloc, "    {d}eats from its trucks and pays field prices until it moves · [R] recall home (free) · or accept a new offer with it from here{/}");
        }
        try lines.append(alloc, "");
        try active.append(alloc, .{ .id = .none, .company = f.id, .lines = try lines.toOwnedSlice(alloc), .objectives_met = false });
    }

    return .{
        .board_header = "kind               world            emp    LY  band        mo     pay/month          total  enemy  salv  rights      transit",
        .board = try board.toOwnedSlice(alloc),
        .active = try active.toOwnedSlice(alloc),
        .notes = "{d}beachhead: ×1.3 pay · +15% hardship · local supplies ×2.5 · resupply via link only  ·  board refreshes on the 1st{/}",
    };
}

fn barText(buf: []u8, num: i64, den: i64) []const u8 {
    const width = buf.len;
    const filled: usize = if (den <= 0) 0 else @intCast(@min(@as(i64, @intCast(width)), @divTrunc(@max(0, num) * @as(i64, @intCast(width)), den)));
    @memset(buf[0..filled], '#');
    @memset(buf[filled..], '-');
    return buf;
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
    text: []const u8,
};

pub const Ledger = struct {
    treasuries: []TreasuryRow,
    extras: []const []const u8, // couriers, policies, loans, forecast
    pnl_title: []const u8,
    pnl: []const []const u8,
    ledger_header: []const u8,
    ledger: []const []const u8,
};

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
        .hq => |id| try std.fmt.allocPrint(alloc, "hq:{d} {s}", .{ @intFromEnum(id), hqName(gs, id) }),
        .company => |id| try std.fmt.allocPrint(alloc, "co:{d} {s}", .{ @intFromEnum(id), forceName(gs, id) }),
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
        try rows.append(alloc, .{ .treasury = t, .text = try std.fmt.allocPrint(alloc, "{s: <20} {s}{s: >14}{{/}}", .{ clip(try treasuryLabel(alloc, gs, t), 20), mk, try money(alloc, bal) }) });
    }

    var extras: std.ArrayListUnmanaged([]const u8) = .empty;
    try extras.append(alloc, try std.fmt.allocPrint(alloc, "{s: <20} {{a}}{s: >14}{{/}}", .{ "total", try money(alloc, total) }));
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
        try extras.append(alloc, try std.fmt.allocPrint(alloc, "  co:{d} {s}  resupply every line to its field plan · {d} safety days past the transit · ammo target {s}{s}", .{ @intFromEnum(sp.company), clip(forceName(gs, sp.company), 16), sp.min_days, if (sp.ammo_battles > 0) try std.fmt.allocPrint(alloc, "{d} battles", .{sp.ammo_battles}) else "auto", if (sp.tons > 0) try std.fmt.allocPrint(alloc, " · max {d}t per shipment", .{sp.tons}) else "" }));
    }
    if (gs.policies.items.len + gs.supply_policies.items.len > 0) try extras.append(alloc, "  {d}x on a treasury row clears its policy · keep-stocked lines live on the Market screen{/}");
    try extras.append(alloc, "");
    try extras.append(alloc, try std.fmt.allocPrint(alloc, "loans · credit {s} of {s}", .{ try money(alloc, gs.creditRemaining()), try money(alloc, gs.creditLimit()) }));
    if (gs.loans.items.len == 0) try extras.append(alloc, "  none · [L] take one (12%/yr simple interest)");
    for (gs.loans.items, 0..) |l, i| {
        try extras.append(alloc, try std.fmt.allocPrint(alloc, "  [{d}] owe {s} of {s} · {s}/mo · next d{d}", .{ i, try money(alloc, l.balance), try money(alloc, l.principal), try money(alloc, l.payment), l.next_pay_day }));
    }
    try extras.append(alloc, "");
    try extras.append(alloc, try std.fmt.allocPrint(alloc, "liquidation value    {s}", .{try money(alloc, gs.liquidationValue())}));
    try extras.append(alloc, "  {d}hulls at half value × condition · HQs at 40% of build cost{/}");
    try extras.append(alloc, "");
    try extras.append(alloc, "next 30 days (estimate)");
    const payroll = gs.monthlyPayroll();
    try extras.append(alloc, try std.fmt.allocPrint(alloc, "  payroll        {s: >14}", .{try money(alloc, -payroll)}));
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
    const net = income - payroll - upkeep;
    try extras.append(alloc, try std.fmt.allocPrint(alloc, "  net            {s}{s: >14}{{/}}", .{ if (net < 0) "{c}" else "{g}", try money(alloc, net) }));

    const filter: finance.EntityFilter = switch (selected) {
        .outfit => .all,
        .hq => |id| .{ .hq = id },
        .company => |id| .{ .company = id },
    };
    const from: u32 = if (day > period_days) day - period_days else 0;
    const sum = finance.summarize(&gs.ledger, from, day, filter);
    const all = finance.summarize(&gs.ledger, 0, day, filter);
    var pnl: std.ArrayListUnmanaged([]const u8) = .empty;
    try pnl.append(alloc, try std.fmt.allocPrint(alloc, "{s: <17} {s: >13} {s: >13}", .{ "category", try std.fmt.allocPrint(alloc, "{d} days", .{period_days}), "campaign" }));
    inline for (@typeInfo(finance.Category).@"enum".fields) |f| {
        const cat: finance.Category = @enumFromInt(f.value);
        const a = sum.category(cat);
        const b = all.category(cat);
        if (a != 0 or b != 0) {
            try pnl.append(alloc, try std.fmt.allocPrint(alloc, "{s: <17} {s: >13} {s: >13}", .{ clip(f.name, 17), try money(alloc, a), try money(alloc, b) }));
        }
    }
    try pnl.append(alloc, "");
    try pnl.append(alloc, try std.fmt.allocPrint(alloc, "{s: <17} {s}{s: >13}{{/}} {s}{s: >13}{{/}}", .{ "NET", if (sum.net() < 0) "{c}" else "{g}", try money(alloc, sum.net()), if (all.net() < 0) "{c}" else "{g}", try money(alloc, all.net()) }));

    var led: std.ArrayListUnmanaged([]const u8) = .empty;
    const txns = gs.ledger.transactions.items;
    var i: usize = txns.len;
    while (i > 0 and led.items.len < max_rows) {
        i -= 1;
        const t = &txns[i];
        if (!filter.matches(t)) continue;
        const mk: []const u8 = if (t.amount < 0) "" else "{g}";
        try led.append(alloc, try std.fmt.allocPrint(alloc, "d{d: <5} {s: <18} {s}{s: >14}{{/}}  {s}", .{ t.day, @tagName(t.category), mk, try money(alloc, t.amount), t.note }));
    }

    return .{
        .treasuries = try rows.toOwnedSlice(alloc),
        .extras = try extras.toOwnedSlice(alloc),
        .pnl_title = try std.fmt.allocPrint(alloc, "P&L · {s}", .{try treasuryLabel(alloc, gs, selected)}),
        .pnl = try pnl.toOwnedSlice(alloc),
        .ledger_header = "day    category                   amount  note",
        .ledger = try led.toOwnedSlice(alloc),
    };
}

// ------------------------------------------------------------------ forces

pub const ToeRow = struct {
    force: types.ForceId,
    unit: types.UnitId,
    text: []const u8,
};

/// The TO&E as an indented tree, one row per force and hull, followed by
/// the hulls that belong to no force (bought, salvaged, or pulled out).
pub fn toe(alloc: Alloc, gs: *GameState) ![]ToeRow {
    var out: std.ArrayListUnmanaged(ToeRow) = .empty;
    var fit = gs.forces.iterator();
    while (fit.next()) |e| {
        const f = e.value_ptr;
        if (f.parent != .none) continue;
        try toeInto(alloc, gs, &out, f.id, 0);
    }
    var loose: u32 = 0;
    var upkeep: types.CBills = 0;
    var uit = gs.units.iterator();
    while (uit.next()) |e| if (e.value_ptr.force == .none and e.value_ptr.status != .destroyed) {
        loose += 1;
        upkeep += e.value_ptr.monthlyBill();
    };
    if (loose > 0) {
        try out.append(alloc, .{ .force = .none, .unit = .none, .text = try std.fmt.allocPrint(alloc, "{{a}}[—] Unassigned hulls{{/}}  {d} · {s}/mo upkeep · {{d}}no tech: they degrade; [x] place in a company, [m] mothball{{/}}", .{ loose, try money(alloc, upkeep) }) });
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
            try out.append(alloc, .{ .force = .none, .unit = u.id, .text = try std.fmt.allocPrint(alloc, "    #{d: <3} {s: <8} {s} {d: >3}t  {s} {s} {s} armor {d}%{s} · {s}/mo", .{
                @intFromEnum(u.id),
                u.chassis_key,
                try padCells(alloc, "", if (ch) |c| c.name else "?", 14),
                if (ch) |c| c.tonnage else 0,
                try padCells(alloc, "", "—", 16),
                try padCells(alloc, "", "—", 16),
                try padCells(alloc, st_mk, @tagName(u.status), 9),
                u.armor_pct,
                try damageMarks(alloc, u),
                try money(alloc, u.monthlyBill()),
            }) });
        }
    }
    return out.toOwnedSlice(alloc);
}

fn toeInto(alloc: Alloc, gs: *GameState, out: *std.ArrayListUnmanaged(ToeRow), id: types.ForceId, depth: usize) !void {
    const f = gs.forces.getPtr(id) orelse return;
    const indent = try alloc.alloc(u8, depth * 2);
    @memset(indent, ' ');
    const posture: []const u8 = if (f.echelon == .company) (if (gs.isCompanyHome(id)) "at home" else "{a}afield{/}") else if (f.echelon == .support_lance) (if (f.support_kind) |k| @tagName(k) else "support") else @tagName(f.role);
    try out.append(alloc, .{ .force = id, .unit = .none, .text = try std.fmt.allocPrint(alloc, "{s}{{a}}[{d}] {s}{{/}}  {s} · {s} · {d} hulls", .{ indent, @intFromEnum(id), f.name, @tagName(f.echelon), posture, f.units.items.len }) });
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
        try out.append(alloc, .{ .force = id, .unit = uid, .text = try std.fmt.allocPrint(alloc, "{s}    #{d: <3} {s: <8} {s} {d: >3}t  {s} {s} {s} armor {d}%{s}", .{
            indent,
            @intFromEnum(uid),
            u.chassis_key,
            try padCells(alloc, "", if (ch) |c| c.name else "?", 14),
            if (ch) |c| c.tonnage else 0,
            if (pilot) |p| try padCells(alloc, "", try std.fmt.allocPrint(alloc, "{s} {s}", .{ p.first_name, p.last_name }), 16) else try padCells(alloc, "{c}", "— no pilot", 16),
            if (tech) |t| try padCells(alloc, "", try std.fmt.allocPrint(alloc, "{s} {s}", .{ t.first_name, t.last_name }), 16) else if (needs_tech) try padCells(alloc, "{c}", "— no tech", 16) else try padCells(alloc, "", "—", 16),
            try padCells(alloc, st_mk, @tagName(u.status), 9),
            u.armor_pct,
            try damageMarks(alloc, u),
        }) });
    }
    for (f.children.items) |cid| try toeInto(alloc, gs, out, cid, depth + 1);
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
    const part_mod = @import("../domain/part.zig");
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    const home = gs.homeHqFor(company);
    var need: std.StringArrayHashMapUnmanaged(u32) = .empty;
    var hulls: u32 = 0;
    var uit = gs.units.iterator();
    while (uit.next()) |e| {
        const u = e.value_ptr;
        if (u.status == .destroyed or gs.companyOf(u.force) != company) continue;
        var structure: std.ArrayListUnmanaged(u8) = .empty;
        var gear_damaged: u32 = 0;
        var gear_destroyed: u32 = 0;
        for (u.slots.items) |s| {
            if (s.condition == .ok) continue;
            if (s.class == .structure) {
                const comp = part_mod.componentForSlot(s.slot_key);
                const g = try need.getOrPut(alloc, comp);
                if (!g.found_existing) g.value_ptr.* = 0;
                g.value_ptr.* += 1;
                if (structure.items.len > 0) try structure.appendSlice(alloc, ", ");
                try structure.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s}→{s}", .{ slotLocation(s.slot_key), comp }));
            } else if (s.condition == .damaged) gear_damaged += 1 else gear_destroyed += 1;
        }
        if (structure.items.len == 0 and gear_damaged + gear_destroyed == 0) continue;
        hulls += 1;
        const ch = chassis_mod.find(u.chassis_key);
        try lines.append(alloc, try std.fmt.allocPrint(alloc, "{{a}}#{d} {s} {s}{{/}}  armor {d}% · {s}", .{ @intFromEnum(u.id), u.chassis_key, if (ch) |c| clip(c.name, 14) else "?", u.armor_pct, @tagName(u.status) }));
        if (structure.items.len > 0) try lines.append(alloc, try std.fmt.allocPrint(alloc, "    {{c}}structure{{/}}  {s}  {{d}}depot work at home{{/}}", .{structure.items}));
        if (gear_damaged + gear_destroyed > 0) try lines.append(alloc, try std.fmt.allocPrint(alloc, "    {{a}}gear{{/}}       {d} damaged, {d} destroyed  {{d}}field work: techs + spares (Lab R orders replacements){{/}}", .{ gear_damaged, gear_destroyed }));
    }
    if (hulls == 0) try lines.append(alloc, "{g}every hull is whole{/}");
    var short_key: ?[]const u8 = null;
    var short_most: u32 = 0;
    if (need.count() > 0) {
        try lines.append(alloc, "");
        try lines.append(alloc, try std.fmt.allocPrint(alloc, "components to have ready at {s}", .{if (gs.hqs.getPtr(home)) |h| h.name else "the home HQ"}));
        try lines.append(alloc, "  part          need  at home  coming  short");
        var it = need.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            const n = e.value_ptr.*;
            const on_hand: u32 = if (home != .none) gs.stockCount(.{ .hq = home }, key) else 0;
            var coming: u32 = 0;
            for (gs.part_orders.items) |o| if (std.mem.eql(u8, o.part_key, key) and o.dest == .hq and o.dest.hq == home and (o.status == .sourcing or o.status == .in_transit)) {
                coming += o.quantity;
            };
            for (gs.bay_jobs.items) |j| if (j.hq == home and j.kind == .fabrication and j.done_day == null and std.mem.eql(u8, j.item_key, key)) {
                coming += 1;
            };
            const short: u32 = n -| (on_hand + coming);
            if (short > short_most) {
                short_most = short;
                short_key = key;
            }
            try lines.append(alloc, try std.fmt.allocPrint(alloc, "  {s: <12} {d: >5} {d: >8} {d: >7}  {s}{d: >5}{{/}}", .{ clip(key, 12), n, on_hand, coming, if (short > 0) "{c}" else "{g}", short }));
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
    try out.append(alloc, try std.fmt.allocPrint(alloc, "{{a}}#{d} {s} {s}{{/}}  {d}t · quality {s} · armor {d}% · status {s} · value {s}", .{
        @intFromEnum(uid), u.chassis_key, if (ch) |c| c.name else "?", if (ch) |c| c.tonnage else 0, @tagName(u.quality), u.armor_pct, @tagName(u.status), try money(alloc, u.purchase_price),
    }));
    if (gs.person(u.pilot)) |p| {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "pilot   {{g}}{s} {s}{{/}}  {s}  {s}  fatigue {d} · morale {d}", .{ p.first_name, p.last_name, @tagName(p.role), @tagName(p.experience()), p.fatigue, p.morale }));
    } else try out.append(alloc, "pilot   {c}none{/}");
    if (gs.person(u.tech)) |t| {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "tech    {{g}}{s} {s}{{/}}  {s}  {s}  {d}/{d} h this week", .{ t.first_name, t.last_name, @tagName(t.role), @tagName(t.experience()), gs.techLoadHours(t.id), t.weekly_hours }));
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
    try out.append(alloc, try std.fmt.allocPrint(alloc, "upkeep {s}/mo · maintenance {d} h/week · depot needed: {s}", .{ try money(alloc, u.monthlyBill()), unit_mod.maintenanceHours(u.kind, if (ch) |c| c.tonnage else 0), if (u.needsDepot()) "{c}yes{/}" else "no" }));
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
        try out.append(alloc, try std.fmt.allocPrint(alloc, "{d: <6} {s: <23} {s: <14} {s: <10} {s}", .{ @intFromEnum(p.id), try std.fmt.allocPrint(alloc, "{s} {s}", .{ p.first_name, p.last_name }), @tagName(p.role), @tagName(p.experience()), if (p.isAvailable(day)) "" else "{a}unavailable{/}" }));
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
        try siteLines(alloc, gs, &out, .{ .hq = h.id }, try std.fmt.allocPrint(alloc, "hq:{d} {{a}}{s}{{/}} warehouse lv{d}", .{ @intFromEnum(h.id), h.name, h.effectiveFacilityLevel(.warehouse) }));
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
            const per_day = @max(1, heads / 200); // provisions_person_days_per_ton = 200
            break :blk tons / per_day;
        } else null;
        var resupply: []const u8 = "";
        for (gs.supply_policies.items) |sp| if (sp.company == f.id) {
            resupply = try std.fmt.allocPrint(alloc, " · resupply plan on ({d} safety days, ammo {s})", .{ sp.min_days, if (sp.ammo_battles > 0) try std.fmt.allocPrint(alloc, "{d} battles", .{sp.ammo_battles}) else "auto" });
        };
        const title = try std.fmt.allocPrint(alloc, "co:{d} {{a}}{s}{{/}} field stores{s}{s} · funds {s}{s}", .{
            @intFromEnum(f.id),              f.name,
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

/// The munition families a company's weapons fire (keys, deduplicated).
pub fn neededMunitions(alloc: Alloc, gs: *GameState, company: types.ForceId) ![]const []const u8 {
    const part_mod = @import("../domain/part.zig");
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var uit = gs.units.iterator();
    while (uit.next()) |e| {
        const u = e.value_ptr;
        if (u.status == .destroyed or gs.companyOf(u.force) != company) continue;
        for (u.slots.items) |s| {
            if (s.class != .weapon) continue;
            const key = part_mod.munitionFor(s.part_key) orelse continue;
            var seen = false;
            for (out.items) |k| if (std.mem.eql(u8, k, key)) {
                seen = true;
            };
            if (!seen) try out.append(alloc, key);
        }
    }
    return out.toOwnedSlice(alloc);
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
    try out.append(alloc, "part                     qty     tons  kind");
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
            try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}{s: <22} {d: >6} {d: >7}t  {s}{{/}}", .{ if (qty == 0) "{c}" else "", clip(key, 22), qty, tons, kind }));
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
        try out.append(alloc, try std.fmt.allocPrint(alloc, "{{c}}{s: <22} {d: >6} {d: >7}t  {s} · none{{/}}", .{ clip(key, 22), 0, 0, kind }));
    }
    if (out.items.len == 1) try out.append(alloc, "{d}empty{/}");
    if (site == .company) {
        var policy: ?state_mod.SupplyPolicy = null;
        for (gs.supply_policies.items) |sp| if (sp.company == site.company) {
            policy = sp;
        };
        const field_supply = @import("field_supply.zig");
        const transit = gs.courierEtaDays(.{ .company = site.company });
        const p = try field_supply.plan(alloc, gs, site.company, transit, if (policy) |sp| sp.min_days else 14, if (policy) |sp| sp.ammo_battles else 0);
        try out.append(alloc, "");
        try out.append(alloc, try std.fmt.allocPrint(alloc, "field plan · {d}t trucks · {d}-day line{s}", .{ p.capacity, transit, if (policy != null) "" else " · {c}no resupply policy — P sets one{/}" }));
        try out.append(alloc, "  line                  floor  target  on hand  inbound");
        for (p.lines) |l| {
            const have = gs.stockCount(site, l.key);
            const coming = field_supply.inboundQty(gs, site.company, l.key);
            const mk: []const u8 = if (have + coming < l.floor) "{c}" else if (have < l.floor) "{a}" else "{g}";
            try out.append(alloc, try std.fmt.allocPrint(alloc, "  {s: <20} {d: >6} {d: >7} {s}{d: >8}{{/}} {d: >8}  {{d}}{s}{{/}}", .{ clip(l.key, 20), l.floor, l.target, mk, have, coming, l.note }));
        }
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

/// Orders and shipments still on their way, soonest first.
pub fn inbound(alloc: Alloc, gs: *GameState) ![]const []const u8 {
    const day = gs.clock.day_index;
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    try out.append(alloc, "part               qty  to                      status      eta          cost");
    const Row = struct { eta: u32, text: []const u8 };
    var rows: std.ArrayListUnmanaged(Row) = .empty;
    for (gs.part_orders.items) |o| {
        if (o.status == .delivered or o.status == .cancelled) continue;
        const eta = o.eta_day orelse std.math.maxInt(u32);
        const eta_s: []const u8 = if (o.eta_day) |e| (if (e > day) try std.fmt.allocPrint(alloc, "d{d} ({d} days)", .{ e, e - day }) else "today") else if (o.status == .failed) "{c}not found{/}" else "{a}sourcing{/}";
        try rows.append(alloc, .{ .eta = eta, .text = try std.fmt.allocPrint(alloc, "{s: <18} {d: >4}  {s: <22}  {s: <10}  {s: <12} {s: >10}", .{
            clip(o.part_key, 18), o.quantity, clip(try siteLabel(alloc, gs, o.dest), 22), @tagName(o.status), eta_s, try money(alloc, o.cost),
        }) });
    }
    for (gs.fund_couriers.items) |c| {
        try rows.append(alloc, .{ .eta = c.eta_day, .text = try std.fmt.allocPrint(alloc, "{s: <18} {s: >4}  {s: <22}  {s: <10}  d{d} ({d} days)", .{ "cash courier", "", clip(try treasuryLabel(alloc, gs, c.to), 22), "in transit", c.eta_day, c.eta_day -| day }) });
    }
    for (gs.unit_transfers.items) |t| {
        try rows.append(alloc, .{ .eta = t.eta_day, .text = try std.fmt.allocPrint(alloc, "{s: <18} {s: >4}  {s: <22}  {s: <10}  d{d} ({d} days)", .{ try std.fmt.allocPrint(alloc, "hull #{d}", .{@intFromEnum(t.unit)}), "", clip(forceName(gs, t.to_company), 22), "in transit", t.eta_day, t.eta_day -| day }) });
    }
    std.mem.sort(Row, rows.items, {}, struct {
        fn lt(_: void, a: Row, b: Row) bool {
            return a.eta < b.eta;
        }
    }.lt);
    for (rows.items) |r| try out.append(alloc, r.text);
    if (rows.items.len == 0) try out.append(alloc, "{d}nothing on the way{/}");
    return out.toOwnedSlice(alloc);
}

/// The standing policy for a treasury, if any.
pub fn policyFor(gs: *GameState, t: state_mod.Treasury) ?state_mod.StandingPolicy {
    for (gs.policies.items) |p| if (std.meta.eql(p.entity, t)) return p;
    return null;
}

pub fn siteLabel(alloc: Alloc, gs: *GameState, site: types.Site) ![]const u8 {
    return switch (site) {
        .outfit => "outfit",
        .hq => |id| try std.fmt.allocPrint(alloc, "hq:{d} {s}", .{ @intFromEnum(id), hqName(gs, id) }),
        .company => |id| try std.fmt.allocPrint(alloc, "co:{d} {s}", .{ @intFromEnum(id), forceName(gs, id) }),
    };
}

fn siteLines(alloc: Alloc, gs: *GameState, out: *std.ArrayListUnmanaged([]const u8), site: types.Site, title: []const u8) !void {
    const tons = gs.siteTons(site);
    const cap = gs.siteCapacityTons(site) orelse 0;
    var bar_buf: [30]u8 = undefined;
    const mk: []const u8 = if (cap > 0 and tons * 4 < cap) "{a}" else "{g}";
    try out.append(alloc, try std.fmt.allocPrint(alloc, "{s: <44} {s}{s}{{/}}  {d}t / {d}t", .{ title, mk, barText(&bar_buf, tons, cap), tons, cap }));
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

pub fn hqDetail(alloc: Alloc, gs: *GameState, id: types.HqId) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const h = gs.hqs.getPtr(id) orelse return out.toOwnedSlice(alloc);
    try out.append(alloc, "facility           built  effective  next level cost");
    for (h.facilities.items) |f| {
        const eff = h.effectiveFacilityLevel(f.kind);
        const mk: []const u8 = if (eff < f.level) "{c}" else "";
        try out.append(alloc, try std.fmt.allocPrint(alloc, "{s: <18} {d: >5}  {s}{d: >9}{{/}}  {s}", .{ @tagName(f.kind), f.level, mk, eff, if (f.level < 5) try money(alloc, @import("../domain/hq.zig").upgradeCost(f.kind, f.level + 1)) else "max" }));
    }
    try out.append(alloc, "");
    const cap = h.capacity();
    try out.append(alloc, try std.fmt.allocPrint(alloc, "capacity   {d} companies · ≤{d} lances each · {d} support · {d} berths · {d}t storage", .{ cap.combat_companies, cap.lances_per_company, cap.support_companies, cap.dropship_berths, h.warehouseCapacityTons() }));
    try out.append(alloc, try std.fmt.allocPrint(alloc, "upkeep     {s} / month · funds {s}", .{ try money(alloc, h.monthly_upkeep), try money(alloc, h.funds) }));
    try out.append(alloc, "");
    try out.append(alloc, "projects");
    if (h.projects.items.len == 0) try out.append(alloc, "  none");
    for (h.projects.items) |p| {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  {s} {s} → lv{d}   paperwork done d{d} · construction done d{d} · {s}", .{ @tagName(p.kind), if (p.facility) |f| @tagName(f) else "", p.target_level, p.paperwork_done_day, p.construction_done_day, try money(alloc, p.cost) }));
    }
    try out.append(alloc, "");
    try out.append(alloc, "back office        have  need");
    const req = h.staffRequired();
    const rows = [_]struct { role: person_mod.Role, need: u32 }{
        .{ .role = .admin_command, .need = req.admin },
        .{ .role = .admin_logistics, .need = req.logistics },
        .{ .role = .admin_hr, .need = req.hr },
        .{ .role = .admin_finance, .need = req.finance },
    };
    for (rows) |r| {
        const s = gs.hqStaff(id, r.role);
        const mk: []const u8 = if (s.count < r.need) "{c}" else "";
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  {s: <16} {s}{d: >4}  {d: >4}{{/}}", .{ @tagName(r.role), mk, s.count, r.need }));
    }
    try out.append(alloc, "");
    {
        const slots = @import("hq_ops.zig").baySlots(gs, id);
        var busy: u32 = 0;
        var queued: u32 = 0;
        for (gs.bay_jobs.items) |j| if (j.hq == id) {
            if (j.started_day != null) busy += 1 else queued += 1;
        };
        try out.append(alloc, try std.fmt.allocPrint(alloc, "bays   {s}{d} of {d} slots busy{{/}} · {d} queued · {d} free", .{ if (busy >= slots) "{c}" else "{g}", busy, slots, queued, slots -| busy }));
    }
    var any = false;
    for (gs.bay_jobs.items) |j| {
        if (j.hq != id) continue;
        any = true;
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  {s: <13} {s}{s}  {s}", .{ @tagName(j.kind), if (j.unit != .none) try std.fmt.allocPrint(alloc, "#{d} ", .{@intFromEnum(j.unit)}) else "", j.item_key, if (j.started_day != null) try std.fmt.allocPrint(alloc, "done day {d}", .{j.done_day orelse 0}) else "queued" }));
    }
    if (!any) try out.append(alloc, "  idle");
    try out.append(alloc, "");
    try out.append(alloc, "hiring hall");
    any = false;
    for (gs.candidates.items, 0..) |c, i| {
        if (c.hq != id) continue;
        any = true;
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  [{d}] {s} {s}  {s} {s}  bonus {s}  expires day {d}", .{ i, c.spec.first, c.spec.last, @tagName(c.spec.role), @tagName(c.spec.experience), try money(alloc, c.asking_bonus), c.expires_day }));
    }
    if (!any) try out.append(alloc, "  no candidates");
    return out.toOwnedSlice(alloc);
}

// ------------------------------------------------------------- hiring hall

/// Hiring-hall filter: a role group or one admin desk (Stage 12 request:
/// "mechanics vs hr and admin_logistics").
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
    wounded, // personnel screen only: anyone hurt, in the medbay or waiting

    pub fn matches(self: HallFilter, role: person_mod.Role) bool {
        return switch (self) {
            .all, .wounded => true,
            .combat => role == .mekwarrior or role == .vehicle_crew or role == .aero_pilot,
            .techs => role == .tech_mek or role == .tech_mechanic or role == .tech_aero or role == .tech_ba or role == .astech,
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
    text: []const u8,
};

pub const Hall = struct {
    header: []const u8,
    rows: []CandidateRow,
    total_at_hq: usize,
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
                const have = gs.hqStaff(hq_id, c.spec.role).count;
                note = if (have < n) try std.fmt.allocPrint(alloc, "{{g}}fills {s} {d}→{d} of {d}{{/}}", .{ @tagName(c.spec.role), have, have + 1, n }) else "{d}desk already staffed{/}";
            }
        }
        const name = try std.fmt.allocPrint(alloc, "{s} {s}", .{ c.spec.first, c.spec.last });
        try rows.append(alloc, .{ .index = i, .text = try std.fmt.allocPrint(alloc, "[{d: <3}] {s: <22} {s: <15} {s: <8} {d: >2} {s: >9}  d{d: <4} {s}", .{
            i, clip(name, 22), @tagName(c.spec.role), @tagName(c.spec.experience), c.spec.primary_skill, try money(alloc, c.asking_bonus), c.expires_day, note,
        }) });
    }
    return .{
        .header = "idx   name                   role            exp      sk     bonus  leaves note",
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
    text: []const u8,
};

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
        var in_progress = false;
        for (h.projects.items) |p| if (p.facility == kind and p.phase(gs.clock.day_index) != .complete) {
            in_progress = true;
        };
        const maxed = next > hq_mod.max_facility_level;
        const cost = if (maxed) 0 else hq_mod.upgradeCost(kind, next);
        const affordable = h.funds >= cost;
        const buys: []const u8 = if (maxed) "at maximum" else switch (kind) {
            .mek_bay => try std.fmt.allocPrint(alloc, "{d} bay slots · refit class ceiling rises", .{2 * @as(u32, next)}),
            .warehouse => try std.fmt.allocPrint(alloc, "{d}t storage", .{200 * @as(u32, next) * @as(u32, next)}),
            .hospital => try std.fmt.allocPrint(alloc, "{d} beds · shorter stays", .{10 * @as(u32, next)}),
            .mess => "faster fatigue recovery, morale",
            .training_ground => "training available · shorter programs",
            .hiring_hall => "more and better candidates",
            .comms => try std.fmt.allocPrint(alloc, "ring +10 LY → {d} LY · more offers", .{h.influenceLy() + 10}),
            .spaceport => try std.fmt.allocPrint(alloc, "ring +5 LY · berths · cheaper freight", .{}),
        };
        const state: []const u8 = if (in_progress) "{a}project running{/}" else if (maxed) "{d}max{/}" else if (!affordable) "{c}HQ funds short{/}" else "{g}ready{/}";
        const reason: []const u8 = if (in_progress) "a project is already running" else if (maxed) "already at maximum level" else if (!affordable) try std.fmt.allocPrint(alloc, "HQ funds short: needs {s} C, has {s} C", .{ try money(alloc, cost), try money(alloc, h.funds) }) else "ready";
        try out.append(alloc, .{ .kind = kind, .possible = !in_progress and !maxed and affordable, .reason = reason, .text = try std.fmt.allocPrint(alloc, "{s: <16} lv {d} → {d}   {s: >11} C   {d: >2} + {d: >2} days   {s: <44} {s}", .{
            f.name,    lvl,                                   if (maxed) lvl else next,
            if (maxed) "—" else try money(alloc, cost),
            paperwork, if (maxed) 0 else 14 * @as(u32, next), buys,
            state,
        }) });
    }
    return out.toOwnedSlice(alloc);
}

// ------------------------------------------------------------------ market

pub const ListingRow = struct {
    index: usize,
    text: []const u8,
};

pub const CatalogRow = struct {
    key: []const u8,
    component: bool,
    text: []const u8,
};

pub const DemandRow = struct {
    key: []const u8,
    short: u32,
    text: []const u8,
};

pub const StockPolicyRow = struct {
    key: []const u8,
    min: u32,
    target: u32,
    text: []const u8,
};

pub const stock_policy_header = "part                  min  target  on hand  state";

/// The keep-stocked lines of one HQ (Market screen): reorder point,
/// target, what is on hand and whether a restock is under way.
pub fn stockPolicies(alloc: Alloc, gs: *GameState, hq: types.HqId) ![]StockPolicyRow {
    var out: std.ArrayListUnmanaged(StockPolicyRow) = .empty;
    for (gs.stock_policies.items) |sp| {
        if (sp.hq != hq) continue;
        const have = gs.stockCount(.{ .hq = hq }, sp.part_key);
        var coming: u32 = 0;
        for (gs.part_orders.items) |o| if (std.mem.eql(u8, o.part_key, sp.part_key) and o.dest == .hq and o.dest.hq == hq and (o.status == .sourcing or o.status == .in_transit)) {
            coming += o.quantity;
        };
        for (gs.bay_jobs.items) |j| if (j.hq == hq and j.kind == .fabrication and j.done_day == null and std.mem.eql(u8, j.item_key, sp.part_key)) {
            coming += 1;
        };
        const state: []const u8 = if (coming > 0) try std.fmt.allocPrint(alloc, "{{a}}{d} coming{{/}}", .{coming}) else if (have < sp.min) "{c}short — reorders tomorrow{/}" else "{g}stocked{/}";
        try out.append(alloc, .{ .key = sp.part_key, .min = sp.min, .target = sp.target, .text = try std.fmt.allocPrint(alloc, "{s: <20} {d: >5} {d: >7} {d: >8}  {s}", .{ clip(sp.part_key, 20), sp.min, sp.target, have, state }) });
    }
    return out.toOwnedSlice(alloc);
}

pub const Market = struct {
    board_header: []const u8,
    board: []ListingRow,
    catalog_header: []const u8,
    catalog: []CatalogRow,
    demand_header: []const u8,
    demand: []DemandRow,
};

const market_mod = @import("../econ/market.zig");

/// Market filter (Stage 12): hull kinds and part categories.
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
            .vehicles => kind == .vehicle or kind == .mash or kind == .cargo or kind == .mobile_field_base,
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
pub fn market(alloc: Alloc, gs: *GameState, filter: MarketFilter) !Market {
    var board: std.ArrayListUnmanaged(ListingRow) = .empty;
    for (gs.market_listings.items, 0..) |l, i| {
        const keep = switch (l.kind) {
            .unit => filter.matchesUnit(if (chassis_mod.find(l.item_key)) |c| c.kind else .mek),
            .part => filter.matchesPart(l.item_key),
        };
        if (!keep) continue;
        const cond: []const u8 = if (l.condition) |c| try std.fmt.allocPrint(alloc, "{{a}}{s}{{/}} armor {d}% · {d} dmg · {d} missing", .{ c.label(), c.armor_pct, c.damaged_slots, c.missing_components }) else if (l.kind == .unit) "{g}new{/}" else "";
        const name: []const u8 = if (l.kind == .unit) (if (chassis_mod.find(l.item_key)) |c| c.name else l.item_key) else (if (@import("../domain/part.zig").find(l.item_key)) |p| p.name else l.item_key);
        try board.append(alloc, .{ .index = i, .text = try std.fmt.allocPrint(alloc, "[{d: <3}] {s: <5} {s: <10} {s: <20} {s: >13}  x{d: <3} {s: <8} {s: <6} d{d: <5} {s}", .{
            i, @tagName(l.kind), clip(l.item_key, 10), clip(name, 20), try money(alloc, l.price), l.quantity, @tagName(l.rarity), if (l.staple) "staple" else "", l.expires_day, cond,
        }) });
    }
    var catalog: std.ArrayListUnmanaged(CatalogRow) = .empty;
    const part_mod = @import("../domain/part.zig");
    for (part_mod.catalog) |p| {
        if (!filter.matchesPart(p.key)) continue;
        const component = part_mod.isComponent(p.key);
        try catalog.append(alloc, .{ .key = p.key, .component = component, .text = try std.fmt.allocPrint(alloc, "{s: <16} {s: <22} {s: >12}  {d: >3}t  {s}", .{
            clip(p.key, 16), clip(p.name, 22), try money(alloc, p.cost), part_mod.tons(p.key), if (component) "{a}fabricable at a regional HQ{/}" else if (isStaple(p.key)) "{g}staple{/}" else "{d}rolls vs rarity{/}",
        }) });
    }
    // Demand: damaged / destroyed / missing slots by part.
    var need: std.StringArrayHashMapUnmanaged(u32) = .empty;
    var uit = gs.units.iterator();
    while (uit.next()) |e| {
        const u = e.value_ptr;
        if (u.status == .destroyed) continue;
        for (u.slots.items) |s| {
            if (s.condition == .ok) continue;
            const key: []const u8 = if (s.class == .structure) part_mod.componentForSlot(s.slot_key) else s.part_key;
            const g = try need.getOrPut(alloc, key);
            if (!g.found_existing) g.value_ptr.* = 0;
            g.value_ptr.* += 1;
        }
    }
    var demand: std.ArrayListUnmanaged(DemandRow) = .empty;
    var dit = need.iterator();
    while (dit.next()) |e| {
        const key = e.key_ptr.*;
        const n = e.value_ptr.*;
        var on_hand: u32 = gs.spareCount(key);
        var hit = gs.hqs.iterator();
        while (hit.next()) |h| on_hand += gs.stockCount(.{ .hq = h.value_ptr.id }, key);
        var on_order: u32 = 0;
        for (gs.part_orders.items) |o| if (std.mem.eql(u8, o.part_key, key) and (o.status == .sourcing or o.status == .in_transit)) {
            on_order += o.quantity;
        };
        const short: u32 = if (n > on_hand + on_order) n - on_hand - on_order else 0;
        try demand.append(alloc, .{ .key = key, .short = short, .text = try std.fmt.allocPrint(alloc, "{s: <16} {d: >4} {d: >8} {d: >9} {s}{d: >6}{{/}}", .{ clip(key, 16), n, on_hand, on_order, if (short > 0) "{c}" else "{g}", short }) });
    }
    return .{
        .board_header = "idx   kind  key        name                         price  qty  rarity   staple expires  condition",
        .board = try board.toOwnedSlice(alloc),
        .catalog_header = "part             name                           cost  tons  source",
        .catalog = try catalog.toOwnedSlice(alloc),
        .demand_header = "part             need  on hand  on order  short",
        .demand = try demand.toOwnedSlice(alloc),
    };
}

fn isStaple(key: []const u8) bool {
    for (market_mod.staple_keys) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

// --------------------------------------------------------------- personnel

pub const PersonRow = struct {
    id: types.PersonId,
    text: []const u8,
};

pub const People = struct {
    header: []const u8,
    rows: []PersonRow,
    total: usize,
};

fn skillsText(alloc: Alloc, p: *const person_mod.Person) ![]const u8 {
    const primary = p.role.primarySkill();
    const second: ?types.SkillType = switch (p.role) {
        .mekwarrior => .piloting_mek,
        .vehicle_crew => .driving_vee,
        .aero_pilot => .piloting_aero,
        else => null,
    };
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
    if (p.posted_hq != .none) return std.fmt.allocPrint(alloc, "HQ · {s}", .{clip(hqName(gs, p.posted_hq), 16)});
    if (p.assigned_force != .none) return std.fmt.allocPrint(alloc, "{s} (no seat)", .{clip(forceName(gs, p.assigned_force), 12)});
    return "{a}unassigned{/}";
}

pub fn statusText(alloc: Alloc, gs: *GameState, p: *const person_mod.Person) ![]const u8 {
    const day = gs.clock.day_index;
    if (p.status == .wounded) return if (p.medbay_admitted) "{a}medbay{/}" else "{c}wounded{/}";
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
        if (p.status == .kia or p.status == .retired or p.status == .resigned) continue;
        total += 1;
        if (!filter.matches(p.role)) continue;
        if (filter == .wounded and p.status != .wounded) continue;
        const name = try std.fmt.allocPrint(alloc, "{s} {s}", .{ p.first_name, p.last_name });
        try rows.append(alloc, .{ .id = p.id, .text = try std.fmt.allocPrint(alloc, "{d: <4} {s: <20} {s: <15} {s: <7} {s: <5} {d: >3} {s} {s} {s: <11} {d: >3} {d: >3} {s: >7}", .{
            @intFromEnum(p.id),                                                             clip(name, 20),
            @tagName(p.role),                                                               @tagName(p.experience()),
            try skillsText(alloc, p),                                                       p.xp,
            try padMk(alloc, "", try stripMarkup(alloc, try statusText(alloc, gs, p)), 18), try padMk(alloc, "", try stripMarkup(alloc, try assignmentText(alloc, gs, p)), 22),
            clip(locationText(gs, p), 11),                                                  p.fatigue,
            p.morale,                                                                       try money(alloc, p.monthlySalary()),
        }) });
    }
    return .{
        .header = "id   name                 role            exp     skill  XP status             assignment             where       fat mor     pay",
        .rows = try rows.toOwnedSlice(alloc),
        .total = total,
    };
}

/// Remove `{x}` markup tokens (for fixed-width columns).
pub fn stripMarkup(alloc: Alloc, s: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '{' and i + 2 < s.len and s[i + 2] == '}' and std.mem.indexOfScalar(u8, "agcsdtp/", s[i + 1]) != null) {
            i += 2;
            continue;
        }
        try out.append(alloc, s[i]);
    }
    return out.toOwnedSlice(alloc);
}

/// One person's full record.
pub fn personRecord(alloc: Alloc, gs: *GameState, id: types.PersonId) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const p = gs.person(id) orelse return out.toOwnedSlice(alloc);
    const day = gs.clock.day_index;
    try out.append(alloc, try std.fmt.allocPrint(alloc, "{{a}}{s} {s}{{/}}{s}  ·  {s} · {s}", .{ p.first_name, p.last_name, if (p.callsign) |c| try std.fmt.allocPrint(alloc, " \"{s}\"", .{c}) else "", @tagName(p.role), @tagName(p.experience()) }));
    try out.append(alloc, try std.fmt.allocPrint(alloc, "status      {s}{s}", .{ try statusText(alloc, gs, p), if (p.status == .wounded) (if (p.wound_heal_day) |h| try std.fmt.allocPrint(alloc, " · discharged day {d} ({d} days)", .{ h, h -| day }) else if (p.medbay_admitted) " · triage tomorrow" else " · {c}not admitted — [m] admits{/}") else "" }));
    try out.append(alloc, try std.fmt.allocPrint(alloc, "assignment  {s}", .{try assignmentText(alloc, gs, p)}));
    try out.append(alloc, try std.fmt.allocPrint(alloc, "unit        {s} · at {s}", .{ if (p.assigned_force != .none) forceName(gs, p.assigned_force) else "—", locationText(gs, p) }));
    try out.append(alloc, "");
    try out.append(alloc, try std.fmt.allocPrint(alloc, "XP {{a}}{d}{{/}} · fatigue {d} · morale {d} · pay {s}/mo · recruited day {d}", .{ p.xp, p.fatigue, p.morale, try money(alloc, p.monthlySalary()), p.recruited_day }));
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
        try out.append(alloc, "            {d}[t] starts a program on the primary skill (training ground at home){/}");
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
        if (u.status == .destroyed or u.status == .mothballed or u.force == .none) continue;
        const ch = chassis_mod.find(u.chassis_key);
        const label = try std.fmt.allocPrint(alloc, "#{d: <3} {s: <8} {s: <16} {s}", .{ @intFromEnum(u.id), u.chassis_key, if (ch) |c| c.name else "?", clip(forceName(gs, gs.companyOf(u.force)), 20) });
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
};

pub const MapHq = struct {
    id: types.HqId,
    name: []const u8,
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
        try hqs.append(alloc, .{ .id = h.id, .name = h.name, .x = p.x, .y = p.y, .ring_ly = h.influenceLy() });
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
        });
    }
    return .{ .worlds = try worlds.toOwnedSlice(alloc), .hqs = try hqs.toOwnedSlice(alloc), .in_ring = in_ring, .in_band = in_band, .dark = dark, .band_ly = market_mod.beachhead_band_ly };
}

pub const HistoryRow = struct {
    id: types.ContractId,
    planet_key: []const u8,
    text: []const u8,
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
        if (c.status != .completed and c.status != .breached and c.status != .failed) continue;
        var received: types.CBills = 0;
        for (gs.ledger.transactions.items) |t| if (t.contract == c.id and t.amount > 0) {
            received += t.amount;
        };
        const start = c.arrive_day orelse c.start_day;
        const served: ?u32 = if (start != null and c.end_day != null) c.end_day.? -| start.? else null;
        const st_mk: []const u8 = switch (c.status) {
            .completed => "{g}",
            .breached => "{c}",
            else => "{a}",
        };
        try out.append(alloc, .{ .id = c.id, .planet_key = c.planet_key, .text = try std.fmt.allocPrint(alloc, "[{d: <3}] {s: <14} {s: <4} {s: <16} {s}{s: <9}{{/}} {s: >5}  {d: >3} VP  {s: >13}  co:{d} {s}", .{
            @intFromEnum(c.id),
            @tagName(c.kind),
            c.employer_key,
            clip(planetName(c.planet_key), 16),
            st_mk,
            @tagName(c.status),
            if (served) |d| try std.fmt.allocPrint(alloc, "{d}d", .{d}) else "—",
            c.victory_points,
            try money(alloc, received),
            @intFromEnum(c.assigned_company),
            clip(forceName(gs, c.assigned_company), 14),
        }) });
    }
    return out.toOwnedSlice(alloc);
}

pub const history_header = "id    kind           emp  world            outcome    served   VP        received  company";

/// Contracts the outfit has worked on a world (any outcome): the founding
/// rule counts them as reach.
pub fn contractsWorkedAt(gs: *GameState, planet_key: []const u8) u32 {
    var n: u32 = 0;
    for (gs.contracts.values()) |c| if (std.mem.eql(u8, c.planet_key, planet_key) and c.status != .offer) {
        n += 1;
    };
    return n;
}

/// Offer rows for one world (text only).
pub fn offersAt(alloc: Alloc, gs: *GameState, planet_key: []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (gs.contract_offers.items, 0..) |c, i| {
        if (!std.mem.eql(u8, c.planet_key, planet_key)) continue;
        try out.append(alloc, try std.fmt.allocPrint(alloc, "[{d}] {{a}}{s}{{/}} {d} mo · {s}/mo · {s} vs {s} · salvage {d}%{s}", .{
            i, @tagName(c.kind), c.terms.length_months, try money(alloc, c.terms.base_pay_month), c.employer_key, c.enemy_key, c.terms.salvage_pct,
            if (c.beachhead) " · {a}beachhead{/}" else "",
        }));
    }
    return out.toOwnedSlice(alloc);
}

// --------------------------------------------------------------------- lab

const meklab = @import("../domain/meklab.zig");

pub const MountRow = struct {
    slot_key: []const u8,
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
    const u = gs.unit(uid) orelse return out.toOwnedSlice(alloc);
    const design = chassis_mod.find(u.chassis_key) orelse return out.toOwnedSlice(alloc);
    const base = try gs.labItems(uid, alloc);
    inline for (@typeInfo(meklab.Location).@"enum".fields) |f| {
        const loc: meklab.Location = @enumFromInt(f.value);
        var items = try alloc.alloc(meklab.Item, base.len + 1);
        @memcpy(items[0..base.len], base);
        items[base.len] = .{ .location = loc, .part_key = part_key };
        const r = try meklab.validate(design, items, alloc);
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

pub fn labMeks(alloc: Alloc, gs: *GameState) ![]types.UnitId {
    var out: std.ArrayListUnmanaged(types.UnitId) = .empty;
    var it = gs.units.iterator();
    while (it.next()) |e| if (e.value_ptr.kind == .mek and e.value_ptr.status != .destroyed) try out.append(alloc, e.value_ptr.id);
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
        try budget.append(alloc, "{a}not a mek — the lab works on BattleMechs{/}");
        return .{ .title = title, .budget = try budget.toOwnedSlice(alloc), .mounts = &.{}, .plan = &.{}, .legal = true, .meks = meks };
    }
    const items = try gs.labItems(uid, alloc);
    const r = try meklab.validate(design, items, alloc);
    try budget.append(alloc, try std.fmt.allocPrint(alloc, "chassis   {s}   mounts   {s}", .{ try halfTons(alloc, r.fixed_half_tons), try halfTons(alloc, r.loadout_half_tons) }));
    try budget.append(alloc, try std.fmt.allocPrint(alloc, "total     {s}   free     {s}{s}{{/}}", .{ try halfTons(alloc, @as(i64, r.fixed_half_tons) + r.loadout_half_tons), if (r.free_half_tons < 0) "{c}" else "{g}", try halfTons(alloc, r.free_half_tons) }));
    try budget.append(alloc, try std.fmt.allocPrint(alloc, "heat      alpha strike {d} · sinks {d}", .{ r.heat_per_alpha, design.heat_sinks }));
    try budget.append(alloc, try std.fmt.allocPrint(alloc, "movement  walk {d}{s} · engine {d}", .{ design.walk_mp, if (design.jump_mp > 0) " · jump" else "", design.engineRating() }));
    try budget.append(alloc, "");
    try budget.append(alloc, "location   used  free   {d}(dim = no free crits){/}");
    const home_hq = gs.homeHqFor(u.force);
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
                const comp = @import("../domain/part.zig").componentForSlot(s.slot_key);
                const on_hand = gs.stockCount(.{ .hq = home_hq }, comp);
                const at_home = gs.isCompanyHome(gs.companyOf(u.force));
                const action: []const u8 = if (!at_home)
                    "{a}hull is away — depot work waits for it to come home; fabricate the part meanwhile (Market, b){/}"
                else if (on_hand > 0 or s.condition == .damaged)
                    "{g}[D] send to depot{/}"
                else
                    "{a}order or fabricate it (Market){/}";
                struct_note = try std.fmt.allocPrint(alloc, "  {{c}}structure {s}{{/}} · needs {s} ({d} on hand) · {s}", .{ @tagName(s.condition), comp, on_hand, action });
            }
        }
        try budget.append(alloc, try std.fmt.allocPrint(alloc, "{s}{s: <10} {d: >4}  {d: >4}{s}{{/}}{s}", .{ if (full) "{d}" else "", f.name, r.crits_used[f.value], r.crits_free[f.value], if (full) "  full" else "", struct_note }));
    }
    try budget.append(alloc, "");
    if (gs.hqs.getPtr(home_hq)) |h| {
        const slots = @import("hq_ops.zig").baySlots(gs, home_hq);
        var busy: u32 = 0;
        var queued: u32 = 0;
        for (gs.bay_jobs.items) |j| if (j.hq == home_hq) {
            if (j.started_day != null) busy += 1 else queued += 1;
        };
        try budget.append(alloc, try std.fmt.allocPrint(alloc, "bays at {s}", .{clip(h.name, 28)}));
        try budget.append(alloc, try std.fmt.allocPrint(alloc, "  {s}{d} of {d} slots busy{{/}} · {d} queued · refit ceiling class {{a}}{s}{{/}}", .{ if (busy >= slots) "{c}" else "{g}", busy, slots, queued, if (h.refitClassCeiling()) |c| @tagName(c) else "none" }));
    }
    if (u.needsDepot()) try budget.append(alloc, if (gs.isCompanyHome(gs.companyOf(u.force))) "{a}structure damaged: [D] sends this hull to the depot (bay job); the weekly pass also queues it when parts are in stock{/}" else "{a}structure damaged: the hull is away with its company — HQ can fabricate or order the component now; the bay job runs once it is home{/}");
    try budget.append(alloc, "{d}A ammo/armor · B like-for-like · C new weapons · D structure{/}");
    try budget.append(alloc, "{d}any weapon or gear fits any location with free crits;{/}");
    try budget.append(alloc, "{d}ammo bins go where free crits are; the head takes 1 crit{/}");

    var removed_count: usize = 0;
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
            const on_hand = gs.stockCount(.{ .hq = home_hq }, s.part_key) + gs.spareCount(s.part_key);
            var on_order: u32 = 0;
            for (gs.part_orders.items) |o| if (std.mem.eql(u8, o.part_key, s.part_key) and (o.status == .sourcing or o.status == .in_transit)) {
                on_order += o.quantity;
            };
            repair_note = if (on_hand > 0) "  {g}part in stock — techs fit it on the next repair pass{/}" else if (on_order > 0) try std.fmt.allocPrint(alloc, "  {{a}}{d} on order{{/}}", .{on_order}) else "  {c}no part — [R] orders one{/}";
        }
        try mounts.append(alloc, .{ .slot_key = s.slot_key, .text = try std.fmt.allocPrint(alloc, "{s}{s: <17} {s: <11} {s: <7} {d: >2}.{d}t {d: >2}c {s}{s}{{/}}{s}", .{
            mk, clip(s.slot_key, 17), clip(s.part_key, 11), clip(@tagName(s.class), 7), if (part) |pd| pd.mass_half_tons / 2 else 0, if (part) |pd| (pd.mass_half_tons % 2) * 5 else 0, if (part) |pd| pd.crits else 0, @tagName(s.condition), if (removed) " (removing)" else "", repair_note,
        }) });
    }

    if (p) |pl| {
        const class = meklab.classify(pl.ops.items, u.slots.items);
        try plan.append(alloc, try std.fmt.allocPrint(alloc, "{s} plan · class {{a}}{s}{{/}} · {d} tech-hours", .{ if (pl.committed) "committed" else "staged", @tagName(class), meklab.refitHours(pl.ops.items, u.slots.items, class) }));
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
    try std.testing.expectEqual(HallFilter.wounded, HallFilter.other.next());
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
    try std.testing.expectEqualStrings("active", try stripMarkup(al, "{g}active{/}"));
}

test "padCells counts cells, not bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dash = try padCells(a, "", "— no pilot", 12);
    try std.testing.expectEqual(@as(usize, 12), try std.unicode.utf8CountCodepoints(dash));
    const plain = try padCells(a, "", "Lori Kalmar", 12);
    try std.testing.expectEqual(@as(usize, 12), plain.len);
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
    var saw_torso = false;
    for (report.lines) |line| if (std.mem.indexOf(u8, line, "lt→comp_torso") != null) {
        saw_torso = true;
    };
    try std.testing.expect(saw_torso);
    // The founding warehouse has no side torsos: that is the line to fabricate.
    _ = gs.takeStock(.{ .hq = report.home }, "comp_torso", gs.stockCount(.{ .hq = report.home }, "comp_torso"));
    const again = try companyDamage(a, &gs, co);
    try std.testing.expectEqualStrings("comp_torso", again.short_key.?);
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
    try std.testing.expect(std.mem.indexOf(u8, rows[0].text, planetName(c.planet_key)) != null);
    try std.testing.expect(std.mem.indexOf(u8, rows[0].text, "completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, rows[0].text, "90d") != null);
    try std.testing.expectEqual(@as(u32, 1), contractsWorkedAt(&gs, c.planet_key));
    const m = try map(a, &gs);
    var worked: u32 = 0;
    for (m.worlds) |w| worked += w.worked;
    try std.testing.expectEqual(@as(u32, 1), worked);
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
    const c = try contracts(a, &gs);
    try std.testing.expect(c.board.len > 0);
}
