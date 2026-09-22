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
const table = @import("table.zig");
pub const Table = table.Table;
pub const Col = table.Col;

/// A table from rows that carry their cells beside their ids (12F).
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
    const shown = clip(text, width);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(alloc, mk);
    try out.appendSlice(alloc, shown);
    var i: usize = std.unicode.utf8CountCodepoints(shown) catch shown.len;
    while (i < width) : (i += 1) try out.append(alloc, ' ');
    if (mk.len > 0) try out.appendSlice(alloc, "{/}");
    return out.toOwnedSlice(alloc);
}

/// Clip plain text to `width` cells (no padding), never inside a
/// multi-byte character.
pub fn clip(text: []const u8, width: usize) []const u8 {
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    var cells: usize = 0;
    while (cells < width) : (cells += 1) _ = it.nextCodepointSlice() orelse return text;
    return text[0..it.i];
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
    /// The outfit's Dragoons rating in a line (12C.6).
    rating_line: []const u8,
    checklist: []ChecklistRow,
    inbox: []InboxRow,
    companies: []const table.Row,
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
        .untreated_wounded, .restless_crew, .retiring_soon => 8,
        .manning_short, .unfit_crew => 2,
        .unrebuildable_hulls => 6,
        .outmatched => 3,
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
            .description = if (ev.person != .none) (if (gs.person(ev.person)) |p| (if (p.status == .pow) try std.fmt.allocPrint(alloc, "{s} {s} of {s} ({s} {s}, gunnery {d}) {s}", .{ p.first_name, p.last_name, p.faction, @tagName(p.experience()), @tagName(p.role), p.skill(p.role.primarySkill()) orelse 7, if (entry) |e| e.log else "" }) else if (p.status == .mia) try std.fmt.allocPrint(alloc, "{s} {s} ({s} {s}, held by {s}) {s} · ransom {s}{s}", .{ p.first_name, p.last_name, @tagName(p.experience()), @tagName(p.role), p.faction, if (entry) |e| e.log else "", try money(alloc, missingRansom(p)), if (holdsPrisonerOf(gs, p.faction)) " · you hold a prisoner of theirs" else " · you hold no prisoner of theirs" }) else try std.fmt.allocPrint(alloc, "{s} {s} ({s}, {s}, {s}/mo, morale {d}, fatigue {d}) {s}{s}", .{ p.first_name, p.last_name, @tagName(p.role), @tagName(p.experience()), try money(alloc, p.monthlySalary()), p.morale, p.fatigue, if (entry) |e| e.log else "", if (ev.kind == .notice_given) try std.fmt.allocPrint(alloc, " · letting go owes {s} severance{s}", .{ try money(alloc, severanceOwed(gs, p.id, false)), try loyaltyNote(alloc, p, day) }) else "" })) else "") else if (entry) |e| e.log else "",
            .options = try opts.toOwnedSlice(alloc),
            .default_choice = ev.default_choice,
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
    return std.fmt.allocPrint(alloc, "{{d}}d{d: <4}{{/}} {s}{s}{{/}}", .{ e.day, mk, e.text });
}

pub const company_cols: []const table.Col = &.{
    .{ .name = "co", .justify = .right }, .{ .name = "name" },                   .{ .name = "hq" },                        .{ .name = "posture" },
    .{ .name = "contract" },              .{ .name = "location" },               .{ .name = "fat", .justify = .right },    .{ .name = "mor", .justify = .right },
    .{ .name = "hulls", .justify = .right }, .{ .name = "ready", .justify = .right }, .{ .name = "supply" },               .{ .name = "local funds", .justify = .right },
};

fn companyRow(alloc: Alloc, gs: *GameState, id: types.ForceId) !table.Row {
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
        (if (c.status == .transit) try std.fmt.allocPrint(alloc, "{{a}}IN TRANSIT · arrive d{d}{{/}}", .{c.arrive_day orelse day}) else try std.fmt.allocPrint(alloc, "{{a}}DEPLOYED · {s}{{/}}", .{c.kind.label()}))
    else if (f.return_eta_day) |eta|
        try std.fmt.allocPrint(alloc, "{{a}}RETURNING · home d{d}{{/}}", .{eta})
    else if (f.location_planet != null)
        "{a}afield, idle{/}"
    else
        "{g}at home{/}";
    const contract_s: []const u8 = if (contract) |c| try std.fmt.allocPrint(alloc, "[{d}] {s}", .{ @intFromEnum(c.id), c.kind.label() }) else "—";
    const location: []const u8 = if (f.location_planet) |p| planetName(p) else if (gs.hqs.getPtr(f.supplying_hq)) |h| planetName(h.planet_key) else "—";
    const site: types.Site = .{ .company = id };
    const tons = gs.siteTons(site);
    const cap = gs.siteCapacityTons(site) orelse 0;
    const cap_mk: []const u8 = if (cap > 0 and tons * 4 < cap) "{a}" else "{g}";
    return table.row(alloc, &.{
        try std.fmt.allocPrint(alloc, "{d}", .{@intFromEnum(id)}),
        f.name,
        hqName(gs, f.supplying_hq),
        posture,
        contract_s,
        location,
        try std.fmt.allocPrint(alloc, "{d}", .{fat / n}),
        try std.fmt.allocPrint(alloc, "{d}", .{mor / n}),
        try std.fmt.allocPrint(alloc, "{d}", .{hulls}),
        try std.fmt.allocPrint(alloc, "{d}", .{ready}),
        try std.fmt.allocPrint(alloc, "{s}{d}t / {d}t{{/}}", .{ cap_mk, tons, cap }),
        try money(alloc, f.local_funds),
    });
}

// --------------------------------------------------------------- contracts

pub const OfferRow = struct {
    index: usize,
    cells: table.Row,
};

pub const board_cols: []const table.Col = &.{
    .{ .name = "kind" },       .{ .name = "world" },                    .{ .name = "emp" },                     .{ .name = "LY", .justify = .right },
    .{ .name = "band" },       .{ .name = "mo", .justify = .right },      .{ .name = "pay/mo", .justify = .right }, .{ .name = "total", .justify = .right },
    .{ .name = "enemy" },      .{ .name = "salv", .justify = .right },    .{ .name = "rights" },                  .{ .name = "transit", .justify = .right },
    .{ .name = "skulls" },     .{ .name = "rating" },                   .{ .name = "readiest co." },            .{ .name = "tons", .justify = .right },
    .{ .name = "weight mix" }, .{ .name = "enemy tons" },               .{ .name = "opposition" },              .{ .name = "" },
};

pub const ActiveRow = struct {
    id: types.ContractId,
    company: types.ForceId,
    lines: []const []const u8,
    objectives_met: bool,
};

pub const Contracts = struct {
    board: []OfferRow,

    active: []ActiveRow,
    notes: []const u8,
    /// Standing with every house (Stage 12.21), one line each.
    standings: []const []const u8,

    pub fn boardTable(self: Contracts, alloc: Alloc) !table.Table {
        return tableOf(alloc, board_cols, self.board);
    }
};

/// Standing with each house: the number, what it does to pay, and whether
/// the house is cooling or shunning you.
pub fn standings(alloc: Alloc, gs: *GameState) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const cm = @import("../econ/contract_market.zig");
    const t = @import("../domain/tuning.zig").t.contract;
    for (@import("../domain/faction.zig").table) |fr| {
        if (!fr.hires) continue;
        const f = .{ .name = fr.key };
        const s = gs.standing(f.name);
        if (s == 0 and !@import("../domain/commander.zig").Faction.isHouse(fr.key)) continue; // periphery rows appear once they matter
        const bp = cm.standingPayBp(s);
        const mk: []const u8 = if (s <= -t.standing_shun_depth) "{c}" else if (s < 0) "{a}" else if (s >= 25) "{g}" else "";
        const note: []const u8 = if (gs.factionCooling(f.name)) " · {c}cooling after a breach{/}" else if (s <= -t.standing_shun_depth) " · {c}shunned: half their offers{/}" else if (s >= 25) " · {g}favoured{/}" else "";
        const whole: u32 = @intCast(@divTrunc(bp, 10_000));
        const frac: u32 = @intCast(@divTrunc(@mod(bp, 10_000), 100));
        const mag: u32 = @intCast(@abs(s));
        const num = try std.fmt.allocPrint(alloc, "{c}{d}", .{ @as(u8, if (s < 0) '-' else if (s > 0) '+' else ' '), mag });
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  {s: <4} {s}{s: >5}{{/}}  pay ×{d}.{d:0>2}{s}", .{ f.name, mk, num, whole, frac, note }));
    }
    return out.toOwnedSlice(alloc);
}

/// Days to an offer's world as `accept` will reckon them: from the nearest
/// company that could go (not under contract, not in transit), else from
/// the outfit's seat. An offer carries no transit of its own until it is
/// accepted (play feedback: the board showed 0 for every offer).
pub fn offerTransitDays(gs: *GameState, offer: *const contract_mod.Contract) u32 {
    const to = planet_mod.find(offer.planet_key) orelse return 0;
    var best: ?u32 = null;
    var fit = gs.forces.iterator();
    while (fit.next()) |e| {
        const co = e.value_ptr;
        if (co.echelon != .company or gs.deploymentContract(co.id) != null or co.return_eta_day != null) continue;
        const from = planet_mod.find(companyPlanetKey(gs, co.id) orelse continue) orelse continue;
        const jumps = planet_mod.jumpsBetween(from, to);
        const days: u32 = if (jumps == 0) 3 else logistics_mod.transitDays(jumps);
        if (best == null or days < best.?) best = days;
    }
    if (best) |b| return b;
    const seat = if (gs.hqs.count() > 0) planet_mod.find(gs.hqs.values()[0].planet_key) else null;
    const jumps = if (seat) |s| planet_mod.jumpsBetween(s, to) else std.math.divCeil(u32, offer.dist_ly, 30) catch 0;
    return if (jumps == 0) 3 else logistics_mod.transitDays(jumps);
}

/// How well the outfit reads an offer's opposition (12D.5): the best HQ
/// comms level, one more for a B-or-better rating (employers share).
pub fn intelLevel(gs: *GameState) u8 {
    var comms: u8 = 0;
    var it = gs.hqs.iterator();
    while (it.next()) |e| comms = @max(comms, e.value_ptr.effectiveFacilityLevel(.comms));
    return comms + @intFromBool(ratingIndex(ratingScore(gs)) >= 3);
}

/// The opposition as the intel reads it (12D.5): exact from comms 3,
/// the lance range and skill from comms 1, the range alone below that.
/// The enemy's lance count as the intel reads it (12E.3): exact from comms
/// 3, within a lance either way from comms 1, the kind's whole range blind.
pub const LanceIntel = struct { lo: u8, hi: u8, mid: u8, exact: bool };

pub fn lanceIntel(gs: *GameState, c: *const contract_mod.Contract) LanceIntel {
    const intel = intelLevel(gs);
    const row = @import("../domain/opfor.zig").rowFor(c.kind);
    if (intel >= 3) return .{ .lo = c.enemy_lances, .hi = c.enemy_lances, .mid = c.enemy_lances, .exact = true };
    if (intel >= 1) {
        const lo = @max(row.lances_min, c.enemy_lances -| 1);
        const hi = @min(row.lances_max, c.enemy_lances + 1);
        return .{ .lo = lo, .hi = hi, .mid = (lo + hi + 1) / 2, .exact = lo == hi };
    }
    return .{ .lo = row.lances_min, .hi = row.lances_max, .mid = (row.lances_min + row.lances_max + 1) / 2, .exact = row.lances_min == row.lances_max };
}

pub fn opforText(alloc: Alloc, gs: *GameState, c: *const contract_mod.Contract) ![]const u8 {
    if (!c.hasOpfor()) return "opposition sized to the company";
    const intel = intelLevel(gs);
    const li = lanceIntel(gs, c);
    if (intel >= 3) return try std.fmt.allocPrint(alloc, "{d} lance{s} of {s} {s} ≈{s} BV a fight", .{ c.enemy_lances, if (c.enemy_lances == 1) "" else "s", @tagName(c.enemy_quality), c.enemy_key, try money(alloc, types.applyBp(c.opforBv(), gs.diff().enemy_bp)) });
    if (intel >= 1) return try std.fmt.allocPrint(alloc, "{d}–{d} lances of {s} {s}", .{ li.lo, li.hi, @tagName(c.enemy_quality), c.enemy_key });
    return try std.fmt.allocPrint(alloc, "{d}–{d} lances of {s}, quality unknown (comms)", .{ li.lo, li.hi, c.enemy_key });
}

/// How one company would fare on one contract (12E.3): skulls (a range
/// when the intel cannot count the enemy's lances), the tonnage on both
/// sides, and the chance of winning a fight or losing the field.
pub const OfferRating = struct {
    company: types.ForceId,
    /// Half skulls against the fewest and the most lances the intel allows
    /// (equal when the count is known).
    half_lo: u8,
    half_hi: u8,
    /// Power ratio (own ÷ enemy, bp) at the intel's best estimate.
    ratio_bp: types.Bp,
    outmatched: bool,
    own: @import("battle.zig").Estimate,
    enemy_tons_lo: u32,
    enemy_tons_hi: u32,
    /// Chance to win a fight (victory or better) and to give up the field
    /// (defeat or rout; a draw too under cautious ROE), averaged exactly
    /// over the contract kind's scenario table.
    win_pct: u32,
    lose_field_pct: u32,
    exact: bool,
};

pub fn rateOffer(alloc: Alloc, gs: *GameState, c: *const contract_mod.Contract, company: types.ForceId) !?OfferRating {
    if (!c.hasOpfor()) return null;
    const battle = @import("battle.zig");
    const opfor = @import("../domain/opfor.zig");
    const skulls = @import("../domain/skulls.zig");
    const scenario = @import("../domain/scenario.zig");
    const tuning = @import("../domain/tuning.zig").t;
    const own = try battle.estimatePower(gs, alloc, c, company);
    const intel = intelLevel(gs);
    // Garrison work meets a probe, not the whole force (12D.6).
    const probe: ?u8 = if (c.kind.isGarrisonClass()) @min(tuning.battle.garrison_probe_lances, c.enemy_lances) else null;
    const li = lanceIntel(gs, c);
    const exact = li.exact or probe != null;
    const lo: i64 = probe orelse li.lo;
    const hi: i64 = probe orelse li.hi;
    const mid: i64 = probe orelse li.mid;
    const sk = opfor.skills(if (intel >= 1) c.enemy_quality else .regular);
    const faces = scenario.faces(c.kind);
    var mean_bp: i64 = 0;
    for (faces) |f| mean_bp += f.enemy_bp;
    mean_bp = @divTrunc(mean_bp, faces.len);
    const Power = struct {
        fn at(gs_: *GameState, lance_bv: i64, lances: i64, scen_bp: i64, g: u8, p: u8) i64 {
            const elem: @import("autoresolve.zig").Element = .{ .base_strength = types.applyBp(types.applyBp(lance_bv * lances, gs_.diff().enemy_bp), @intCast(scen_bp)), .avg_gunnery = g, .avg_piloting = p };
            return elem.effectivePower(.{});
        }
    };
    const ratio_lo = skulls.ratioBp(own.power, Power.at(gs, c.enemy_lance_bv, lo, mean_bp, sk[0], sk[1]));
    const ratio_hi = skulls.ratioBp(own.power, Power.at(gs, c.enemy_lance_bv, hi, mean_bp, sk[0], sk[1]));
    const ratio_mid = skulls.ratioBp(own.power, Power.at(gs, c.enemy_lance_bv, mid, mean_bp, sk[0], sk[1]));
    // The dice, face by face: ratio bonus (capped in close terrain),
    // the scenario's tilt, scouts, and the company's rules of engagement.
    const close = if (planet_mod.find(c.planet_key)) |w| (@import("../domain/terrain.zig").Environment{ .terrain = @import("../domain/terrain.zig").terrainOf(w) }).close() else false;
    const roe: @import("../domain/force.zig").Roe = if (c.terms.command_rights.overridesRoe()) .hold else if (gs.force(company)) |f| f.roe else .standard;
    const roe_roll: i32 = switch (roe) {
        .hold => tuning.loss.roe.hold_roll,
        .standard => 0,
        .cautious => tuning.loss.roe.cautious_roll,
    };
    var win: u32 = 0;
    var lose: u32 = 0;
    for (faces) |f| {
        var bonus = battle.ratioBonus(own.power, Power.at(gs, c.enemy_lance_bv, mid, f.enemy_bp, sk[0], sk[1]));
        if (close) bonus = @min(bonus, 2);
        const mods: i32 = bonus + f.roll_mod + (if (own.recon) @as(i32, f.scout_bonus) else 0) + roe_roll;
        win += skulls.chanceAtLeast(8, mods);
        lose += 100 - skulls.chanceAtLeast(if (roe == .cautious) 8 else 6, mods);
    }
    return .{
        .company = company,
        .half_lo = skulls.fromRatioBp(ratio_lo),
        .half_hi = skulls.fromRatioBp(ratio_hi),
        .ratio_bp = ratio_mid,
        .outmatched = skulls.outmatched(ratio_mid),
        .own = own,
        .enemy_tons_lo = c.enemy_lance_tons * @as(u32, @intCast(lo)),
        .enemy_tons_hi = c.enemy_lance_tons * @as(u32, @intCast(hi)),
        .win_pct = win / @as(u32, faces.len),
        .lose_field_pct = lose / @as(u32, faces.len),
        .exact = exact,
    };
}

/// The rating for the company best placed to take an offer (12E.5): the
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
/// by difficulty (12E.5).
pub fn boardSkulls(alloc: Alloc, gs: *GameState, offer_index: usize) ![]const u8 {
    const r = (try bestRating(alloc, gs, offer_index)) orelse return "{d}no company in range{/}";
    return try ratingLine(alloc, gs, r);
}

/// One rating on a line: glyphs, the number, whose, and the weights.
pub fn ratingLine(alloc: Alloc, gs: *GameState, r: OfferRating) ![]const u8 {
    const mk: []const u8 = if (r.half_hi >= 9) "{c}" else if (r.half_hi >= 7) "{a}" else "{g}";
    return try std.fmt.allocPrint(alloc, "{s}{s}{{/}} {s} {s} · {s}", .{ mk, try skullGlyphs(alloc, r.half_hi), try skullText(alloc, r), forceName(gs, r.company), try tonnageText(alloc, r) });
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

/// The board's rating cells (12E.5): skulls · rating · company · own
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
        forceName(gs, r.company),
        try std.fmt.allocPrint(alloc, "{d}t", .{r.own.tons}),
        try std.fmt.allocPrint(alloc, "L{d} M{d} H{d} A{d}", .{ m[0], m[1], m[2], m[3] }),
        if (r.enemy_tons_lo == r.enemy_tons_hi) try std.fmt.allocPrint(alloc, "~{d}t", .{r.enemy_tons_lo}) else try std.fmt.allocPrint(alloc, "~{d}–{d}t", .{ r.enemy_tons_lo, r.enemy_tons_hi }),
    };
}

/// "2–3 lances, green" — the opposition for a board cell (`opforText`
/// says it in full).
pub fn opforShort(alloc: Alloc, gs: *GameState, c: *const contract_mod.Contract) ![]const u8 {
    if (!c.hasOpfor()) return "sized to the company";
    const intel = intelLevel(gs);
    const li = lanceIntel(gs, c);
    if (intel >= 3) return try std.fmt.allocPrint(alloc, "{d} lance{s}, {s}, ≈{s} BV/fight", .{ c.enemy_lances, if (c.enemy_lances == 1) "" else "s", @tagName(c.enemy_quality), try moneyShort(alloc, types.applyBp(c.opforBv(), gs.diff().enemy_bp)) });
    if (intel >= 1) return try std.fmt.allocPrint(alloc, "{d}–{d} lances, {s}", .{ li.lo, li.hi, @tagName(c.enemy_quality) });
    return try std.fmt.allocPrint(alloc, "{d}–{d} lances, quality unknown", .{ li.lo, li.hi });
}

/// "3.5 skulls" / "2.5–3.5 skulls".
pub fn skullText(alloc: Alloc, r: OfferRating) ![]const u8 {
    const skulls = @import("../domain/skulls.zig");
    var a: [8]u8 = undefined;
    var b: [8]u8 = undefined;
    const lo = skulls.number(&a, r.half_lo);
    if (r.half_lo == r.half_hi) return try std.fmt.allocPrint(alloc, "{s} skull{s}{s}", .{ lo, if (r.half_lo == 2) "" else "s", if (r.outmatched) " (outmatched)" else "" });
    return try std.fmt.allocPrint(alloc, "{s}–{s} skulls", .{ lo, skulls.number(&b, r.half_hi) });
}

/// "610t (L4 M8) vs ~720t" — tonnage beside the skulls.
pub fn tonnageText(alloc: Alloc, r: OfferRating) ![]const u8 {
    const m = r.own.mix;
    const theirs = if (r.enemy_tons_lo == r.enemy_tons_hi) try std.fmt.allocPrint(alloc, "~{d}t", .{r.enemy_tons_lo}) else try std.fmt.allocPrint(alloc, "~{d}–{d}t", .{ r.enemy_tons_lo, r.enemy_tons_hi });
    return try std.fmt.allocPrint(alloc, "{d}t (L{d} M{d} H{d} A{d}) vs {s}", .{ r.own.tons, m[0], m[1], m[2], m[3], theirs });
}

/// The contract screen. `board_hq` picks one HQ's board (12E.4; `.none`
/// shows every board).
pub fn contracts(alloc: Alloc, gs: *GameState, board_hq: types.HqId) !Contracts {
    const day = gs.clock.day_index;
    var board: std.ArrayListUnmanaged(OfferRow) = .empty;
    for (gs.contract_offers.items, 0..) |c, i| {
        if (board_hq != .none and c.offer_hq != .none and c.offer_hq != board_hq) continue;
        const rt = try boardRatingCells(alloc, gs, i);
        try board.append(alloc, .{ .index = i, .cells = try table.row(alloc, &.{
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
        if (c.status != .transit and c.status != .active) continue;
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        try lines.append(alloc, try std.fmt.allocPrint(alloc, "[{d}] {{a}}{s}{{/}}  {s}  co:{d} {s} on {s}  ·  employer {s} · vs {s}  ·  {s} objective", .{
            @intFromEnum(c.id),               c.kind.label(),                  @tagName(c.status),
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
        try lines.append(alloc, try std.fmt.allocPrint(alloc, "    rights      {s}", .{c.terms.command_rights.describe()}));
        {
            // Rules of engagement (12D.4): the company's order, or the employer's.
            const roe: @import("../domain/force.zig").Roe = if (c.terms.command_rights.overridesRoe()) .hold else if (gs.force(c.assigned_company)) |f| f.roe else .standard;
            try lines.append(alloc, try std.fmt.allocPrint(alloc, "    ROE         {s}{s}", .{ roe.describe(), if (c.terms.command_rights.overridesRoe()) " {d}(set by integrated command){/}" else " {d}(Forces o on the company row){/}" }));
        }
        // Live skulls (12E.5): what the company can field today against the
        // opposition — a mauled company's odds fall as it wears down.
        if (try rateOffer(alloc, gs, c, c.assigned_company)) |rt| {
            try lines.append(alloc, try std.fmt.allocPrint(alloc, "    skulls      {s} · wins {d}% of fights, loses the field {d}%{s}", .{
                try ratingLine(alloc, gs, rt), rt.win_pct, rt.lose_field_pct, if (rt.half_hi >= @import("../domain/skulls.zig").table.warn_half_skulls) " {c}— outmatched: consider cautious ROE or recall{/}" else "",
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
        const pct_mk: []const u8 = if (pct < 50) "{c}" else if (pct < 75) "{a}" else "{g}";
        try lines.append(alloc, try std.fmt.allocPrint(alloc, "    committed   {d} BV · fieldable {d} BV {s}({d}%){{/}} · ineffective below 50%{s}", .{
            c.committed_bv, fieldable, pct_mk, pct,
            if (c.ineffective_since) |since| try std.fmt.allocPrint(alloc, " · {{c}}grace since day {d}{{/}}", .{since}) else "",
        }));
        try lines.append(alloc, try std.fmt.allocPrint(alloc, "    pay         {s} / month · advance {s} · salvage {d}%{s} · {s} rights", .{
            try money(alloc, c.terms.base_pay_month), try money(alloc, c.terms.advanceAmount()), c.terms.salvage_pct, if (c.terms.salvage_exchange) " {a}(exchange: employer keeps the wrecks, pays cash){/}" else "", @tagName(c.terms.command_rights),
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
            const tb = @import("../domain/tuning.zig").t.battle;
            const haul_bv: i64 = if (trucks > 0) trucks * tb.salvage_bv_per_truck else tb.salvage_bv_by_hand;
            var claim: i64 = @divTrunc(haul_bv * c.terms.salvage_pct, 100);
            if (salvage_lance) claim = types.applyBp(claim, tb.salvage_lance_bonus_bp);
            try lines.append(alloc, try std.fmt.allocPrint(alloc, "    salvage     {d} SVT-1 truck{s} haul up to {d} BV per won battle → your {d}% is ≈{d} BV of wrecks and parts shipped to the home depot{s}", .{
                trucks, if (trucks == 1) "" else "s", haul_bv, c.terms.salvage_pct, claim,
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
        .board = try board.toOwnedSlice(alloc),
        .active = try active.toOwnedSlice(alloc),
        .notes = try std.fmt.allocPrint(alloc, "{s}  ·  {{d}}beachhead: ×1.3 pay · +15% hardship · local supplies ×2.5 · resupply via link only  ·  rights: integrated = more fights, salvage ×0.5, defeats −2, no training lances, pay +10% · house = ×0.75, +5% · liaison = ×0.9 · independent = fewer fights, full salvage, −5% · salv cash = salvage exchange (paid in cash, no wrecks)  ·  board refreshes on the 1st{{/}}", .{(try rating(alloc, gs)).line}),
    .standings = try standings(alloc, gs), };
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
        try rows.append(alloc, .{ .treasury = t, .cells = try table.row(alloc, &.{ try treasuryLabel(alloc, gs, t), try std.fmt.allocPrint(alloc, "{s}{s}{{/}}", .{ mk, try money(alloc, bal) }) }) });
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
    const pnl_cols = try alloc.dupe(table.Col, &.{ .{ .name = "category" }, .{ .name = try std.fmt.allocPrint(alloc, "{d} days", .{period_days}), .justify = .right }, .{ .name = "campaign", .justify = .right } });
    var pnl: std.ArrayListUnmanaged(table.Row) = .empty;
    inline for (@typeInfo(finance.Category).@"enum".fields) |f| {
        const cat: finance.Category = @enumFromInt(f.value);
        const a = sum.category(cat);
        const b = all.category(cat);
        if (a != 0 or b != 0) {
            try pnl.append(alloc, try table.row(alloc, &.{ f.name, try money(alloc, a), try money(alloc, b) }));
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
    /// Hull rows (12F): the indent and the cells; `finishToe` pads them to
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
        try out.append(alloc, .{ .filter = .{ .company = f.id }, .label = f.name });
    }
    try out.append(alloc, .{ .filter = .unassigned, .label = try std.fmt.allocPrint(alloc, "unassigned hulls — at {s}", .{if (gs.hqs.getPtr(gs.homeHqFor(.none))) |h| h.name else "the seat"}) });
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
    cells: table.Row,
};

pub const hangar_cols: []const table.Col = &.{
    .{ .name = "#" },                             .{ .name = "hull" },                        .{ .name = "name" },   .{ .name = "bill/mo", .justify = .right },
    .{ .name = "contributes", .justify = .right }, .{ .name = "cost index", .justify = .right }, .{ .name = "company" }, .{ .name = "why" },
};

/// The hangar as a portfolio (GAMEPLAY "the roster ranks meks by what
/// they cost against what they contribute"): every owned hull, worst
/// value first. A mothballed hull bills a fifth and contributes nothing; a
/// pilotless or wrecked one bills in full for nothing.
/// What a house asks for one of yours (12D.3; the 12B.7 ransom table).
pub fn missingRansom(p: *const @import("../domain/person.zig").Person) types.CBills {
    const t = @import("../domain/tuning.zig").t.contract;
    return switch (p.experience()) {
        .green => t.ransom_green,
        .regular => t.ransom_regular,
        .veteran => t.ransom_veteran,
        .elite => t.ransom_elite,
    };
}

/// Does the outfit hold a prisoner of this house (a trade is possible)?
pub fn holdsPrisonerOf(gs: *GameState, faction: []const u8) bool {
    var it = gs.people.iterator();
    while (it.next()) |e| if (e.value_ptr.status == .pow and std.mem.eql(u8, e.value_ptr.faction, faction)) return true;
    return false;
}

/// A wreck's line (12D.2): how it died, what the rebuild costs against a
/// new hull, and whether it is worth doing at all.
pub fn wreckNote(alloc: std.mem.Allocator, gs: *GameState, u: *const @import("../domain/unit.zig").Unit) ![]const u8 {
    const hq_ops = @import("hq_ops.zig");
    const cause = if (u.wreck == .none) "wreck" else u.wreck.label();
    const est = hq_ops.rebuildEstimate(gs, u) orelse return try std.fmt.allocPrint(alloc, "{{c}}{s} — strip it (Forces $, s) or sell for {s}{{/}}", .{ cause, try money(alloc, gs.unitSaleValue(u)) });
    const new_cost: types.CBills = if (chassis_mod.find(u.chassis_key)) |c| c.cost else 0;
    return try std.fmt.allocPrint(alloc, "{{c}}{s} — rebuild ≈{s} vs new {s}{s}{{/}}", .{
        cause, try money(alloc, est), try money(alloc, new_cost), if (hq_ops.beyondEconomicalRepair(gs, u)) " · beyond economical repair: strip or sell" else "",
    });
}

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
                if (gear_bad + gear_gone > 0) why = try std.fmt.allocPrint(alloc, "{{a}}gear: {d} destroyed, {d} damaged — its tech fixes it weekly (R orders spares){{/}}", .{ gear_gone, gear_bad }) else if (u.conditionPct() < 70) why = "{a}shot up — repairs{/}";
            }
        }
        const bill = u.monthlyBill();
        // Support and transport hulls are judged by what they enable, not
        // BV: they sit at the bottom unless wrecked.
        const exempt = u.status != .destroyed and (u.kind.isTransport() or !u.kind.isCombat());
        const cost_index: u64 = if (exempt) 0 else if (contribution == 0) std.math.maxInt(u32) else @as(u64, @intCast(bill)) * 100 / contribution;
        try out.append(alloc, .{ .unit = u.id, .bill = bill, .contribution = contribution, .cost_index = cost_index, .cells = &.{} });
    }
    std.mem.sort(HangarRow, out.items, {}, struct {
        fn lt(_: void, a: HangarRow, b: HangarRow) bool {
            if (a.cost_index != b.cost_index) return a.cost_index > b.cost_index;
            return a.bill > b.bill;
        }
    }.lt);
    for (out.items) |*row| {
        const u = gs.unit(row.unit).?;
        const ch = chassis_mod.find(u.chassis_key);
        const pilot = gs.person(u.pilot);
        const fit = pilot != null and pilot.?.isAvailable(day);
        const why: []const u8 = if (u.status == .destroyed) try wreckNote(alloc, gs, u) else if (u.status == .mothballed) "{d}cold storage{/}" else if (u.kind.isTransport()) "transport (lifts the company)" else if (!u.kind.isCombat()) "support train" else if (!fit) "{a}no fit pilot — hire or assign{/}" else if (u.needsDepot()) "{a}structural damage — depot{/}" else if (u.conditionPct() < 70) "{a}shot up — repairs{/}" else "{g}earning its keep{/}";
        const idx_text: []const u8 = if (row.cost_index == 0) "—" else if (row.contribution == 0) "{c}∞{/}" else try std.fmt.allocPrint(alloc, "{d}", .{row.cost_index});
        row.cells = try table.row(alloc, &.{
            try std.fmt.allocPrint(alloc, "#{d}", .{@intFromEnum(u.id)}),
            u.chassis_key,
            if (ch) |c| c.name else "?",
            try money(alloc, row.bill),
            try std.fmt.allocPrint(alloc, "{d} BV", .{row.contribution}),
            idx_text,
            forceName(gs, gs.companyOf(u.force)),
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
        try out.append(alloc, .{ .force = .none, .unit = .none, .text = try std.fmt.allocPrint(alloc, "{{a}}[—] Unassigned hulls{{/}}  at {s} (their depot and shelf)  {d} · {s}/mo upkeep · {{d}}no tech: they degrade; [x] place in a company, [m] mothball{{/}}", .{ if (gs.hqs.getPtr(gs.homeHqFor(.none))) |h| h.name else "the seat", loose, try money(alloc, upkeep) }) });
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
            // What the depot at the seat will want for it (play feedback: the
            // pool never said where the hulls were or which base to stock).
            const seat = gs.homeHqFor(.none);
            var needs: std.ArrayListUnmanaged(u8) = .empty;
            for (u.slots.items) |sl| {
                if (sl.class != .structure or (sl.condition != .destroyed and sl.condition != .missing)) continue;
                const comp = @import("../domain/part.zig").componentFor(sl.slot_key, u.chassis_key);
                if (std.mem.indexOf(u8, needs.items, comp) != null) continue;
                var n: u32 = 0;
                for (u.slots.items) |o| if (o.class == .structure and (o.condition == .destroyed or o.condition == .missing) and std.mem.eql(u8, @import("../domain/part.zig").componentFor(o.slot_key, u.chassis_key), comp)) {
                    n += 1;
                };
                const have = gs.stockCount(.{ .hq = seat }, comp);
                // "comp_ct×2 (2)": the count wanted, and what the shelf holds.
                try needs.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s}{s}{s}×{d}({d}){{/}}", .{ if (needs.items.len == 0) "" else " ", if (have >= n) "{g}" else "{c}", comp, n, have }));
            }
            // The pilot/tech columns are always empty in the pool: they carry
            // the depot's shopping list instead.
            try out.append(alloc, .{ .force = .none, .unit = u.id, .text = try std.fmt.allocPrint(alloc, "    #{d: <3} {s: <8} {s} {d: >3}t  {s} {s} armor {d}%{s} · {s}/mo", .{
                @intFromEnum(u.id),
                u.chassis_key,
                try padCells(alloc, "", if (ch) |c| c.name else "?", 14),
                if (ch) |c| c.tonnage else 0,
                try padCells(alloc, "", if (needs.items.len > 0) needs.items else "—", 36),
                try padCells(alloc, st_mk, @tagName(u.status), 9),
                u.armor_pct,
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
        try out.append(alloc, .{ .force = id, .unit = uid, .text = "", .prefix = try std.fmt.allocPrint(alloc, "{s}    ", .{indent}), .cells = try table.row(alloc, &.{
            try std.fmt.allocPrint(alloc, "#{d}", .{@intFromEnum(uid)}),
            u.chassis_key,
            if (ch) |c| c.name else "?",
            try std.fmt.allocPrint(alloc, "{d}t", .{if (ch) |c| c.tonnage else 0}),
            if (pilot) |p| try std.fmt.allocPrint(alloc, "{s} {s}", .{ p.first_name, p.last_name }) else "{c}— no pilot{/}",
            if (tech) |t| try std.fmt.allocPrint(alloc, "{s} {s}", .{ t.first_name, t.last_name }) else if (needs_tech) "{c}— no tech{/}" else "—",
            try std.fmt.allocPrint(alloc, "{s}{s}{{/}}", .{ st_mk, @tagName(u.status) }),
            try std.fmt.allocPrint(alloc, "armor {d}%{s}", .{ u.armor_pct, try damageMarks(alloc, u) }),
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
                // Damaged structure is bay time alone; only destroyed or
                // missing structure consumes a component (hq_ops.queueDepotRepair).
                // Play feedback: the list went red for parts the depot never used.
                if (structure.items.len > 0) try structure.appendSlice(alloc, ", ");
                if (s.condition == .damaged) {
                    try structure.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s} (bay time only)", .{slotLocation(s.slot_key)}));
                } else {
                    const comp = part_mod.componentFor(s.slot_key, u.chassis_key);
                    const g = try need.getOrPut(alloc, comp);
                    if (!g.found_existing) g.value_ptr.* = 0;
                    g.value_ptr.* += 1;
                    try structure.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s}→{s}", .{ slotLocation(s.slot_key), comp }));
                }
            } else if (s.condition == .damaged) gear_damaged += 1 else gear_destroyed += 1;
        }
        if (structure.items.len == 0 and gear_damaged + gear_destroyed == 0) continue;
        hulls += 1;
        const ch = chassis_mod.find(u.chassis_key);
        try lines.append(alloc, try std.fmt.allocPrint(alloc, "{{a}}#{d} {s} {s}{{/}}  armor {d}% · {s}", .{ @intFromEnum(u.id), u.chassis_key, if (ch) |c| clip(c.name, 14) else "?", u.armor_pct, @tagName(u.status) }));
        if (structure.items.len > 0) try lines.append(alloc, try std.fmt.allocPrint(alloc, "    {{c}}structure{{/}}  {s}  {{d}}depot work at home{{/}}", .{structure.items}));
        if (gear_damaged + gear_destroyed > 0) try lines.append(alloc, try std.fmt.allocPrint(alloc, "    {{a}}gear{{/}}       {d} damaged, {d} destroyed  {{d}}field work: techs + spares (Forces R / :replace orders what's destroyed){{/}}", .{ gear_damaged, gear_destroyed }));
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
        const transit = gs.courierEtaDays(.{ .company = site.company });
        const p = try field_supply.plan(alloc, gs, site.company, transit, if (policy) |sp| sp.min_days else 14, if (policy) |sp| sp.ammo_battles else 0);
        try out.append(alloc, "");
        try out.append(alloc, try std.fmt.allocPrint(alloc, "field plan · {d}t trucks · {d}-day line{s}", .{ p.capacity, transit, if (policy != null) "" else " · {c}no resupply policy — P sets one{/}" }));
        const plan_cols: []const table.Col = &.{ .{ .name = "line" }, .{ .name = "floor", .justify = .right }, .{ .name = "target", .justify = .right }, .{ .name = "on hand", .justify = .right }, .{ .name = "inbound", .justify = .right }, .{ .name = "" } };
        var prows: std.ArrayListUnmanaged(table.Row) = .empty;
        for (p.lines) |l| {
            const have = gs.stockCount(site, l.key);
            const coming = field_supply.inboundQty(gs, site.company, l.key);
            const mk: []const u8 = if (have + coming < l.floor) "{c}" else if (have < l.floor) "{a}" else "{g}";
            try prows.append(alloc, try table.row(alloc, &.{ l.key, try std.fmt.allocPrint(alloc, "{d}", .{l.floor}), try std.fmt.allocPrint(alloc, "{d}", .{l.target}), try std.fmt.allocPrint(alloc, "{s}{d}{{/}}", .{ mk, have }), try std.fmt.allocPrint(alloc, "{d}", .{coming}), try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}", .{l.note}) }));
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
/// HQ (12C.14), or nothing when the world and the part are ordinary.
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
        try rows.append(alloc, .{ .eta = t.eta_day, .cells = try table.row(alloc, &.{ try std.fmt.allocPrint(alloc, "hull #{d}", .{@intFromEnum(t.unit)}), "", forceName(gs, t.to_company), "in transit", try std.fmt.allocPrint(alloc, "d{d} ({d} days)", .{ t.eta_day, t.eta_day -| day }), "" }) });
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
        .hq => |id| try std.fmt.allocPrint(alloc, "hq:{d} {s}", .{ @intFromEnum(id), hqName(gs, id) }),
        .company => |id| try std.fmt.allocPrint(alloc, "co:{d} {s}", .{ @intFromEnum(id), forceName(gs, id) }),
    };
}

fn siteLines(alloc: Alloc, gs: *GameState, out: *std.ArrayListUnmanaged([]const u8), site: types.Site, title: []const u8) !void {
    const tons = gs.siteTons(site);
    const cap = gs.siteCapacityTons(site) orelse 0;
    var bar_buf: [20]u8 = undefined;
    const mk: []const u8 = if (cap > 0 and tons * 4 < cap) "{a}" else "{g}";
    try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}  {s}{s}{{/}} {d}t / {d}t", .{ title, mk, barText(&bar_buf, tons, cap), tons, cap }));
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

/// Which facility a row of `hqDetail` names, or null. The tier section
/// above the facility table varies in length (field HQs explain how to
/// become regional), so the HQ screen's `u` reads the cursor through this
/// rather than by position.
pub fn hqFacilityAtRow(alloc: Alloc, gs: *GameState, id: types.HqId, row: usize) !?@import("../domain/hq.zig").FacilityKind {
    const lines = try hqDetail(alloc, gs, id);
    if (row >= lines.len) return null;
    // The table runs from the "facility" header to the next blank line.
    var header: ?usize = null;
    for (lines, 0..) |l, i| if (std.mem.startsWith(u8, try stripMarks(alloc, l), "facility ")) {
        header = i;
        break;
    };
    const start = (header orelse return null) + 1;
    if (row < start) return null;
    for (lines[start..row + 1]) |l| if (l.len == 0) return null;
    var it = std.mem.tokenizeScalar(u8, lines[row], ' ');
    const tag = it.next() orelse return null;
    return std.meta.stringToEnum(@import("../domain/hq.zig").FacilityKind, tag);
}

pub fn hqDetail(alloc: Alloc, gs: *GameState, id: types.HqId) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const h = gs.hqs.getPtr(id) orelse return out.toOwnedSlice(alloc);
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
    for (try (table.Table{ .cols = fac_cols, .rows = frows.items }).render(alloc), 0..) |ln, i| try out.append(alloc, if (i == 0) try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}", .{ln}) else ln);
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
        const s = gs.hqStaff(id, r.role);
        const mk: []const u8 = if (s.count < r.need) "{c}" else "";
        try orows.append(alloc, try table.row(alloc, &.{ @tagName(r.role), try std.fmt.allocPrint(alloc, "{s}{d}{{/}}", .{ mk, s.count }), try std.fmt.allocPrint(alloc, "{s}{d}{{/}}", .{ mk, r.need }) }));
    }
    for (try (table.Table{ .cols = office_cols, .rows = orows.items }).render(alloc), 0..) |ln, i| try out.append(alloc, if (i == 0) try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}", .{ln}) else ln);
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
    unassigned, // personnel screen only: no seat, no HQ posting, no company
    wounded, // personnel screen only: anyone hurt, in the medbay or waiting

    pub fn matches(self: HallFilter, role: person_mod.Role) bool {
        return switch (self) {
            .all, .unassigned, .wounded => true,
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
    cells: table.Row,
};

pub const Hall = struct {
    rows: []CandidateRow,
    total_at_hq: usize,
};

pub const hall_cols: []const table.Col = &.{
    .{ .name = "idx" },                  .{ .name = "name" },                   .{ .name = "role" },                    .{ .name = "exp" },
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
                const have = gs.hqStaff(hq_id, c.spec.role).count;
                note = if (have < n) try std.fmt.allocPrint(alloc, "{{g}}fills {s} {d}→{d} of {d}{{/}}", .{ @tagName(c.spec.role), have, have + 1, n }) else "{d}desk already staffed{/}";
            }
        }
        const name = try std.fmt.allocPrint(alloc, "{s} {s}", .{ c.spec.first, c.spec.last });
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
        try out.append(alloc, .{ .kind = kind, .possible = !in_progress and !maxed and affordable, .reason = reason, .cells = try table.row(alloc, &.{
            f.name,
            try std.fmt.allocPrint(alloc, "lv {d} → {d}", .{ lvl, if (maxed) lvl else next }),
            if (maxed) "—" else try money(alloc, cost),
            try std.fmt.allocPrint(alloc, "{d} + {d} days", .{ paperwork, if (maxed) 0 else 14 * @as(u32, next) }),
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
    /// A contract world's listing (12D.7): this company's local funds pay.
    company: types.ForceId = .none,
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
    .{ .name = "idx" },                    .{ .name = "kind" },   .{ .name = "key" },                       .{ .name = "name" },
    .{ .name = "price", .justify = .right }, .{ .name = "qty" },  .{ .name = "rarity" },                    .{ .name = "staple" },
    .{ .name = "expires" },                .{ .name = "condition" },
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
        var coming: u32 = 0;
        for (gs.part_orders.items) |o| if (std.mem.eql(u8, o.part_key, sp.part_key) and o.dest == .hq and o.dest.hq == hq and (o.status == .sourcing or o.status == .in_transit)) {
            coming += o.quantity;
        };
        for (gs.bay_jobs.items) |j| if (j.hq == hq and j.kind == .fabrication and j.done_day == null and std.mem.eql(u8, j.item_key, sp.part_key)) {
            coming += 1;
        };
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
        const cond_base: []const u8 = if (l.condition) |c| try std.fmt.allocPrint(alloc, "{{a}}{s}{{/}} armor {d}% · {d} dmg · {d} missing", .{ c.label(), c.armor_pct, c.damaged_slots, c.missing_components }) else if (l.kind == .unit) "{g}new{/}" else "";
        // A hull this HQ's bay could not rebuild says so (12E.2).
        const hq_ops = @import("hq_ops.zig");
        const cond: []const u8 = if (l.kind == .unit and chassis_mod.find(l.item_key) != null and chassis_mod.find(l.item_key).?.kind == .mek and !hq_ops.bayCanRebuild(gs, if (l.hq != .none) l.hq else hq, l.item_key))
            try std.fmt.allocPrint(alloc, "{s} · {{c}}{s}{{/}}", .{ cond_base, hq_ops.rebuildNeed(l.item_key) })
        else
            cond_base;
        const name: []const u8 = if (l.kind == .unit) (if (chassis_mod.find(l.item_key)) |c| c.name else l.item_key) else (if (@import("../domain/part.zig").find(l.item_key)) |p| p.name else l.item_key);
        if (l.company != .none) {
            // A contract world's hull (12D.7).
            const world: []const u8 = if (gs.deploymentContract(l.company)) |c| planetName(c.planet_key) else "?";
            try board.append(alloc, .{ .index = i, .hq = l.hq, .company = l.company, .cells = try table.row(alloc, &.{
                try std.fmt.allocPrint(alloc, "{d}", .{i}),
                try std.fmt.allocPrint(alloc, "{{a}}@{s}{{/}}", .{world}),
                l.item_key,
                name,
                try money(alloc, types.applyBp(l.price, gs.diff().purchase_bp)),
                "",
                "",
                "",
                "",
                try std.fmt.allocPrint(alloc, "{s} local funds {s} · {s}", .{ forceName(gs, l.company), try money(alloc, gs.treasuryBalance(.{ .company = l.company })), cond }),
            }) });
            continue;
        }
        try board.append(alloc, .{ .index = i, .hq = l.hq, .cells = try table.row(alloc, &.{
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
    // Demand: damaged / destroyed / missing slots by part.
    var need: std.StringArrayHashMapUnmanaged(u32) = .empty;
    var uit = gs.units.iterator();
    while (uit.next()) |e| {
        const u = e.value_ptr;
        if (u.status == .destroyed) continue;
        for (u.slots.items) |s| {
            if (s.condition == .ok) continue;
            const key: []const u8 = if (s.class == .structure) part_mod.componentFor(s.slot_key, u.chassis_key) else s.part_key;
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
        try demand.append(alloc, .{ .key = key, .short = short, .cells = try table.row(alloc, &.{
            key,
            try std.fmt.allocPrint(alloc, "{d}", .{n}),
            try std.fmt.allocPrint(alloc, "{d}", .{on_hand}),
            try std.fmt.allocPrint(alloc, "{d}", .{on_order}),
            try std.fmt.allocPrint(alloc, "{s}{d}{{/}}", .{ if (short > 0) "{c}" else "{g}", short }),
        }) });
    }
    return .{
        .board = try board.toOwnedSlice(alloc),
        .catalog = try catalog.toOwnedSlice(alloc),
        .demand = try demand.toOwnedSlice(alloc),
    };
}

fn isStaple(key: []const u8) bool {
    for (market_mod.staple_keys) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

// ------------------------------------------------------- raising a company

pub const ManningRow = struct {
    role: person_mod.Role,
    have: u32,
    need: u32,
    cells: table.Row,
};

pub const manning_cols: []const table.Col = &.{ .{ .name = "role" }, .{ .name = "have", .justify = .right }, .{ .name = "need", .justify = .right }, .{ .name = "open", .justify = .right }, .{ .name = "why" } };

/// What a well-run company of this shape needs on the payroll, by role,
/// against who is on it now — the same ratios the starter generator
/// uses (`company_gen.supportStaffFor`), so a raised company can be
/// crewed by hand to the starter company's standard.
pub fn manning(alloc: Alloc, gs: *GameState, company: types.ForceId) ![]ManningRow {
    const personnel = @import("personnel.zig");
    const needs = personnel.manningNeeds(gs, company);
    var out: std.ArrayListUnmanaged(ManningRow) = .empty;
    // Hours (12C.15): what the company's hulls want per week against what
    // its techs, at their skill and with their astech teams, can give.
    var hours_needed: u32 = 0;
    var hours_have: u32 = 0;
    {
        var uit2 = gs.units.iterator();
        while (uit2.next()) |e| {
            const u = e.value_ptr;
            if (u.status == .destroyed or u.status == .mothballed or u.kind == .infantry or gs.companyOf(u.force) != company) continue;
            hours_needed += if (gs.person(u.tech)) |t| gs.techHoursFor(t, u) else gs.hullHours(u);
        }
        var pit2 = gs.people.iterator();
        while (pit2.next()) |e| {
            const p = e.value_ptr;
            if (!p.role.isTech() or !p.isAvailable(gs.clock.day_index) or gs.companyOf(p.assigned_force) != company) continue;
            hours_have += gs.techHoursAvailable(p);
        }
    }
    for (needs) |n| {
        const have = personnel.manningHave(gs, company, n.role);
        const open = n.need -| have;
        const why = if (n.role == .astech or n.role == .tech_mek) try std.fmt.allocPrint(alloc, "{s} · {s}{d} of {d} tech-hours/week covered{{/}}", .{ n.why, if (hours_have >= hours_needed) "{g}" else "{c}", hours_have, hours_needed }) else n.why;
        try out.append(alloc, .{ .role = n.role, .have = have, .need = n.need, .cells = try table.row(alloc, &.{
            @tagName(n.role),
            try std.fmt.allocPrint(alloc, "{d}", .{have}),
            try std.fmt.allocPrint(alloc, "{d}", .{n.need}),
            try std.fmt.allocPrint(alloc, "{s}{d}{{/}}", .{ if (open > 0) "{c}" else "{g}", open }),
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
    cells: table.Row,
};

pub const raise_cols: []const table.Col = &.{
    .{ .name = "source" },    .{ .name = "#" },                        .{ .name = "hull" },     .{ .name = "name" },
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
            try out.append(alloc, .{ .kind = .mothballed, .unit = u.id, .cells = try table.row(alloc, &.{ "{d}mothballed{/}", try std.fmt.allocPrint(alloc, "#{d}", .{@intFromEnum(u.id)}), u.chassis_key, if (ch) |c| c.name else "?", try std.fmt.allocPrint(alloc, "{d}t", .{if (ch) |c| c.tonnage else 0}), try std.fmt.allocPrint(alloc, "quality {s} · armor {d}%{s}", .{ @tagName(u.quality), u.armor_pct, marks }), "{g}free{/}", try std.fmt.allocPrint(alloc, "{d} days to reactivate", .{unit_mod.reactivationDays(u.quality)}), "" }) });
        } else {
            try out.append(alloc, .{ .kind = .pool, .unit = u.id, .cells = try table.row(alloc, &.{ "{g}on hand{/}", try std.fmt.allocPrint(alloc, "#{d}", .{@intFromEnum(u.id)}), u.chassis_key, if (ch) |c| c.name else "?", try std.fmt.allocPrint(alloc, "{d}t", .{if (ch) |c| c.tonnage else 0}), try std.fmt.allocPrint(alloc, "quality {s} · armor {d}%{s}", .{ @tagName(u.quality), u.armor_pct, marks }), "{g}free{/}", "now", "" }) });
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
        const days: u32 = if (home_world != null and board_world != null and home_world.? != board_world.?) logistics.transitDays(planetMod().jumpsBetween(board_world.?, home_world.?)) else 0;
        var cond_text: []const u8 = "{g}new{/}";
        if (l.condition) |c| {
            const repair: types.CBills = @as(types.CBills, c.destroyed_slots) * 40_000 + @as(types.CBills, c.damaged_slots) * 5_000 + @as(types.CBills, c.missing_components) * 150_000 + @as(types.CBills, (100 - @as(u32, c.armor_pct)) / 15) * 10_000; // TUNE rough repair bill
            const mk: []const u8 = if (c.missing_components > 0) "{c}" else if (c.destroyed_slots > 0) "{c}" else if (c.armor_pct < 100 or c.damaged_slots > 0) "{a}" else "{g}";
            cond_text = try std.fmt.allocPrint(alloc, "{s}{s}{{/}} armor {d}% · {d} dmg {d} dest {d} missing · ≈{s} to fix{s}", .{ mk, c.label(), c.armor_pct, c.damaged_slots, c.destroyed_slots, c.missing_components, try money(alloc, repair), if (c.missing_components > 0) " (depot)" else "" });
        }
        // The company's home bay must be able to rebuild what it buys (12E.2).
        const need_note: []const u8 = if (@import("hq_ops.zig").bayCanRebuild(gs, home, l.item_key)) "" else try std.fmt.allocPrint(alloc, "  {{c}}{s}{{/}}", .{@import("hq_ops.zig").rebuildNeed(l.item_key)});
        try out.append(alloc, .{ .kind = .listing, .listing = i, .cells = try table.row(alloc, &.{ try std.fmt.allocPrint(alloc, "{{a}}{s}{{/}}", .{if (board) |h| h.name else "board"}), try std.fmt.allocPrint(alloc, "#{d}", .{i}), l.item_key, ch.name, try std.fmt.allocPrint(alloc, "{d}t", .{ch.tonnage}), cond_text, try money(alloc, l.price), if (days == 0) "now" else try std.fmt.allocPrint(alloc, "{d} days", .{days}), std.mem.trimStart(u8, need_note, " ") }) });
    }
    return out.toOwnedSlice(alloc);
}

/// The ships holding berths at an HQ: crew, status, and which company
/// they are away with (Stage 12.15).
pub fn berths(alloc: Alloc, gs: *GameState, hq_id: types.HqId) ![][]const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = gs.units.iterator();
    while (it.next()) |e| {
        const u = e.value_ptr;
        if (!u.kind.isTransport() or u.berth_hq != hq_id) continue;
        const ch = chassis_mod.find(u.chassis_key);
        const crew = gs.person(u.pilot);
        const lift_text = if (ch) |c| (if (c.kind == .dropship) try std.fmt.allocPrint(alloc, "{d} mek · {d} fighter · {d}t cargo", .{ c.mek_bays, c.asf_bays, c.cargo_tons }) else try std.fmt.allocPrint(alloc, "{d} collar{s}", .{ c.collars, if (c.collars == 1) "" else "s" })) else "";
        const where: []const u8 = if (u.force != .none) try std.fmt.allocPrint(alloc, "{{a}}away with {s}{{/}}", .{forceName(gs, u.force)}) else if (u.status != .ready) try std.fmt.allocPrint(alloc, "{{c}}{s}{{/}}", .{@tagName(u.status)}) else "{g}at berth{/}";
        try out.append(alloc, try std.fmt.allocPrint(alloc, "  #{d: <3} {s: <9} {s: <9} {s}  {s}  {s}", .{
            @intFromEnum(u.id), u.chassis_key, if (ch) |c| c.name else "?", try padCells(alloc, "", lift_text, 30),
            if (crew) |c| try padCells(alloc, "", try std.fmt.allocPrint(alloc, "{s} {s}", .{ c.first_name, c.last_name }), 18) else try padCells(alloc, "{c}", "— no crew", 18),
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
    const bp: u32 = @intCast(@import("../econ/logistics.zig").transitFreightBp(plan.covered_bp, plan.own_jumpship));
    return try std.fmt.allocPrint(alloc, "lift: {d} of {d} hulls on {d} own dropship{s}{s} — charter ×{d}.{d:0>2}", .{
        plan.carried, plan.needed, plan.ships, if (plan.ships == 1) "" else "s", if (plan.own_jumpship) " + own jumpship" else "",
        bp / 10_000,                                                                                          (bp % 10_000) / 100,
    });
}

fn planetMod() type {
    return @import("../domain/planet.zig");
}

// --------------------------------------------------------------- personnel

pub const PersonRow = struct {
    id: types.PersonId,
    cells: table.Row,
};

pub const people_cols: []const table.Col = &.{
    .{ .name = "id", .justify = .right }, .{ .name = "name" },       .{ .name = "role" },                  .{ .name = "exp" },
    .{ .name = "skill" },                 .{ .name = "XP", .justify = .right }, .{ .name = "status" },       .{ .name = "assignment" },
    .{ .name = "where" },                 .{ .name = "fat", .justify = .right }, .{ .name = "mor", .justify = .right }, .{ .name = "pay", .justify = .right },
};

pub const People = struct {
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

// ------------------------------------------------------------------ summary (12C.8)

/// The campaign in aggregate: contracts by grade, battles, kills and
/// losses, money by category, people and hulls, the rating year by year.
pub fn summary(alloc: Alloc, gs: *GameState) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const day = gs.clock.day_index;
    const d = gs.clock.date;
    try out.append(alloc, try std.fmt.allocPrint(alloc, "{{a}}{s}{{/}} · {d}-{d:0>2}-{d:0>2} · day {d} · year {d} of the campaign", .{ gs.outfit_name, d.year, d.month, d.day, day, day / 365 + 1 }));
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

// ------------------------------------------------------------------ rating (12C.6)

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

/// Letter index 0…5 (F, D, C, B, A, A*) — what the board reads (12C.7).
pub fn ratingIndex(score: i32) u8 {
    const t = @import("../domain/tuning.zig").t.rating;
    if (score >= t.letter_a_star) return 5;
    if (score >= t.letter_a) return 4;
    if (score >= t.letter_b) return 3;
    if (score >= t.letter_c) return 2;
    if (score >= t.letter_d) return 1;
    return 0;
}

/// The score alone, for callers without an arena (the market, negotiation).
pub fn ratingScore(gs: *GameState) i32 {
    var arena = std.heap.ArenaAllocator.init(gs.allocator());
    defer arena.deinit();
    const r = rating(arena.allocator(), gs) catch return 0;
    return r.score;
}

/// Pay multiplier the letter earns (12C.7).
pub fn ratingPayBp(index: u8) types.Bp {
    const t = @import("../domain/tuning.zig").t.rating;
    return switch (index) {
        0 => t.pay_bp_f,
        1 => t.pay_bp_d,
        2 => t.pay_bp_c,
        3 => t.pay_bp_b,
        4 => t.pay_bp_a,
        else => t.pay_bp_a_star,
    };
}

pub fn ratingLetter(score: i32) []const u8 {
    const t = @import("../domain/tuning.zig").t.rating;
    if (score >= t.letter_a_star) return "A*";
    if (score >= t.letter_a) return "A";
    if (score >= t.letter_b) return "B";
    if (score >= t.letter_c) return "C";
    if (score >= t.letter_d) return "D";
    return "F";
}

pub fn rating(alloc: Alloc, gs: *GameState) !Rating {
    const t = @import("../domain/tuning.zig").t.rating;
    const personnel = @import("personnel.zig");
    var parts: std.ArrayListUnmanaged(RatingPart) = .empty;
    const day = gs.clock.day_index;

    // Experience: average primary+secondary skill of the active combat crews.
    {
        var sum: u32 = 0;
        var n: u32 = 0;
        var pit = gs.people.iterator();
        while (pit.next()) |e| {
            const p = e.value_ptr;
            if (p.status != .active or !p.role.isCombat()) continue;
            const prim = p.skill(p.role.primarySkill()) orelse 7;
            sum += prim;
            n += 1;
        }
        const avg_x10: u32 = if (n > 0) sum * 10 / n else 70;
        const score: i32 = if (avg_x10 <= 30) 40 else if (avg_x10 <= 35) 30 else if (avg_x10 <= 40) 20 else if (avg_x10 <= 50) 10 else 0;
        try parts.append(alloc, .{ .name = "experience", .score = score, .note = try std.fmt.allocPrint(alloc, "{d} combat crew, average skill {d}.{d}", .{ n, avg_x10 / 10, avg_x10 % 10 }) });
    }
    // Command: desks staffed at every HQ, officers on the books.
    {
        var need: u32 = 0;
        var have: u32 = 0;
        var hit = gs.hqs.iterator();
        while (hit.next()) |e| {
            const hq = e.value_ptr;
            const req = hq.staffRequired();
            const desks = [_]struct { person_mod.Role, u32 }{ .{ .admin_command, req.admin }, .{ .admin_logistics, req.logistics }, .{ .admin_hr, req.hr }, .{ .admin_finance, req.finance } };
            for (desks) |d| {
                need += d[1];
                have += @min(d[1], gs.hqStaff(hq.id, d[0]).count);
            }
        }
        var officers: u32 = 0;
        var pit = gs.people.iterator();
        while (pit.next()) |e| if (e.value_ptr.status == .active and e.value_ptr.rank.isOfficer()) {
            officers += 1;
        };
        const desk_score: i32 = if (need == 0) 10 else @intCast(have * 10 / need);
        const officer_score: i32 = @intCast(@min(10, officers * 2));
        try parts.append(alloc, .{ .name = "command", .score = desk_score + officer_score, .note = try std.fmt.allocPrint(alloc, "{d} of {d} desks staffed, {d} officer{s}", .{ have, need, officers, if (officers == 1) "" else "s" }) });
    }
    // Combat record: every contract's outcome, plus what events did to the name.
    {
        var pts: i32 = 0;
        var done: u32 = 0;
        for (gs.contracts.values()) |c| {
            switch (c.status) {
                .completed => {
                    done += 1;
                    pts += if (c.victory_points >= 50) t.record_outstanding else if (c.victory_points >= 25) t.record_strong else if (c.victory_points >= 0) t.record_satisfactory else t.record_poor;
                },
                .failed => {
                    done += 1;
                    pts += t.record_failed;
                },
                .breached => {
                    done += 1;
                    pts += t.record_breached;
                },
                else => {},
            }
        }
        pts += gs.reputation;
        if (done == 0) pts += t.record_unproven; // nobody has seen you fight
        const score = std.math.clamp(pts, -t.record_cap, t.record_cap);
        try parts.append(alloc, .{ .name = "combat record", .score = score, .note = try std.fmt.allocPrint(alloc, "{d} contract{s} closed{s}, reputation {d}", .{ done, if (done == 1) "" else "s", if (done == 0) " (unproven)" else "", gs.reputation }) });
    }
    // Transport: own lift for the companies at home, own jumpship.
    {
        const commands = @import("commands.zig");
        var covered_sum: i64 = 0;
        var companies: u32 = 0;
        var jumpship = false;
        var fit = gs.forces.iterator();
        while (fit.next()) |e| {
            const f = e.value_ptr;
            if (f.echelon != .company) continue;
            companies += 1;
            const plan = commands.planLift(gs, f.id, false) catch continue;
            covered_sum += plan.covered_bp;
            if (plan.own_jumpship) jumpship = true;
        }
        const covered_bp: i64 = if (companies > 0) @divTrunc(covered_sum, companies) else 0;
        var score: i32 = @intCast(@divTrunc(covered_bp * 20, 10_000));
        if (jumpship) score += 10;
        try parts.append(alloc, .{ .name = "transport", .score = score, .note = try std.fmt.allocPrint(alloc, "own ships lift {d}% of the line{s}", .{ @divTrunc(covered_bp, 100), if (jumpship) ", own jumpship" else "" }) });
    }
    // Support: techs, astechs and medical against the manning tables.
    {
        var need: u32 = 0;
        var have: u32 = 0;
        var fit = gs.forces.iterator();
        while (fit.next()) |e| {
            const f = e.value_ptr;
            if (f.echelon != .company) continue;
            for (personnel.manningNeeds(gs, f.id)) |n| {
                if (!(n.role.isTech() or n.role == .astech or n.role == .doctor or n.role == .medic)) continue;
                need += n.need;
                have += @min(n.need, personnel.manningHave(gs, f.id, n.role));
            }
        }
        const score: i32 = if (need == 0) 10 else @intCast(have * 20 / need);
        try parts.append(alloc, .{ .name = "support", .score = score, .note = try std.fmt.allocPrint(alloc, "{d} of {d} tech and medical posts filled", .{ have, need }) });
    }
    // Finances: debt against payroll, and the colour of the treasury.
    {
        var debt: types.CBills = 0;
        for (gs.loans.items) |l| debt += l.balance;
        const payroll = gs.monthlyPayroll();
        var score: i32 = 10;
        var note: []const u8 = "no debt";
        if (debt > 0) {
            const months = if (payroll > 0) @divTrunc(debt, payroll) else 99;
            score = if (months <= 6) 0 else -10;
            note = try std.fmt.allocPrint(alloc, "{s} owed ({d} months of payroll)", .{ try money(alloc, debt), months });
        }
        if (gs.funds < 0) {
            score -= 20;
            note = try std.fmt.allocPrint(alloc, "{s}, treasury overdrawn", .{note});
        }
        try parts.append(alloc, .{ .name = "finances", .score = score, .note = note });
    }

    var total: i32 = 0;
    for (parts.items) |pt| total += pt.score;
    var line: std.ArrayListUnmanaged(u8) = .empty;
    try line.appendSlice(alloc, try std.fmt.allocPrint(alloc, "rating {{a}}{s}{{/}} ({d})", .{ ratingLetter(total), total }));
    for (parts.items) |pt| try line.appendSlice(alloc, try std.fmt.allocPrint(alloc, " · {s} {d}", .{ pt.name, pt.score }));
    _ = day;
    return .{ .score = total, .letter = ratingLetter(total), .parts = try parts.toOwnedSlice(alloc), .line = try line.toOwnedSlice(alloc) };
}

/// " · loyal: founder, veteran" or nothing (12C.5).
fn loyaltyNote(alloc: Alloc, p: *const person_mod.Person, day: u32) ![]const u8 {
    const l = p.loyalty(day);
    if (l.count() == 0) return "";
    return std.fmt.allocPrint(alloc, " · loyal: {s}", .{try l.text(alloc)});
}

/// What letting this person go would cost today (12C.2); `fired` halves it.
pub fn severanceOwed(gs: *GameState, id: types.PersonId, fired: bool) types.CBills {
    const p = gs.person(id) orelse return 0;
    const full = p.severance(gs.clock.day_index);
    return if (fired) types.applyBp(full, @import("../domain/tuning.zig").t.person.fire_severance_bp) else full;
}

/// Nobody's pilot, nobody's tech, not posted to an HQ, not on a company's
/// books: the people the assignment column shows as "unassigned".
pub fn isUnassigned(gs: *GameState, p: *const person_mod.Person) bool {
    if (p.posted_hq != .none or p.assigned_force != .none) return false;
    if (gs.pilotSeat(p.id) != .none) return false;
    var uit = gs.units.iterator();
    while (uit.next()) |e| if (e.value_ptr.tech == p.id) return false;
    return true;
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
        if (p.status == .kia or p.status == .retired or p.status == .resigned or p.status == .released) continue;
        total += 1;
        if (!filter.matches(p.role)) continue;
        if (filter == .wounded and p.status != .wounded) continue;
        if (filter == .unassigned and !isUnassigned(gs, p)) continue;
        const name = try p.rankedName(alloc);
        try rows.append(alloc, .{ .id = p.id, .cells = try table.row(alloc, &.{
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
/// Plain text for the CLI: drop the `{a}…{/}` markup the TUI colours.
pub fn stripMarks(alloc: Alloc, text: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '{' and i + 2 < text.len and text[i + 2] == '}' and (text[i + 1] == 'a' or text[i + 1] == 'g' or text[i + 1] == 'c' or text[i + 1] == 'd' or text[i + 1] == '/')) {
            i += 3;
            continue;
        }
        try out.append(alloc, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

// --------------------------------------------------------------- readiness

pub const ReadinessRow = struct {
    company: types.ForceId,
    deployed: bool,
    heads: u32,
    fatigue: u32,
    /// Heads in the tired-or-worse bands and in the spent band (12C.1).
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
    .{ .name = "company" },                    .{ .name = "posture" },                  .{ .name = "heads", .justify = .right },   .{ .name = "fatigue", .justify = .right },
    .{ .name = "morale", .justify = .right },  .{ .name = "wounded", .justify = .right }, .{ .name = "perm", .justify = .right },  .{ .name = "training", .justify = .right },
    .{ .name = "banked XP", .justify = .right }, .{ .name = "hulls", .justify = .right }, .{ .name = "depot", .justify = .right }, .{ .name = "quality" },
    .{ .name = "rotation" },
};

/// The per-company readiness report (ARCH §9.7, Stage 12.16): the P&L's
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
            .deployed = gs.deploymentContract(co.id) != null,
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
        var fat: u64 = 0;
        var mor: u64 = 0;
        var pit = gs.people.iterator();
        while (pit.next()) |pe| {
            const p = pe.value_ptr;
            if (p.status != .active and p.status != .wounded) continue;
            if (gs.companyOf(p.assigned_force) != co.id) continue;
            row.heads += 1;
            fat += p.fatigue;
            mor += p.morale;
            if (p.fatigueBand() != .fresh) row.tired += 1;
            if (p.isUnfit()) row.spent += 1;
            if (p.status == .wounded) row.wounded += 1;
            if (p.permanentPenalty() > 0) row.permanent += 1;
            if (p.training != null) row.training += 1;
            if (p.role.isCombat()) row.banked_xp += p.xp;
        }
        if (row.heads > 0) {
            row.fatigue = @intCast(fat / row.heads);
            row.morale = @intCast(mor / row.heads);
        }
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
        const tpb = @import("../domain/tuning.zig").t.person;
        const fat_mk: []const u8 = if (row.fatigue >= tpb.exhausted_fatigue) "{c}" else if (row.fatigue >= tpb.fatigue_tired) "{a}" else "{g}";
        const mor_mk: []const u8 = if (row.morale < 30) "{c}" else if (row.morale < 50) "{a}" else "{g}";
        const rot: []const u8 = if (row.days_since_rotation) |d| try std.fmt.allocPrint(alloc, "{d} tours · {d}d", .{ row.contracts_since_rotation, d }) else try std.fmt.allocPrint(alloc, "{d} tours", .{row.contracts_since_rotation});
        row.cells = try table.row(alloc, &.{
            try std.fmt.allocPrint(alloc, "{{a}}{s}{{/}}", .{co.name}),
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
    const tp = @import("../domain/tuning.zig").t.person;
    try out.append(alloc, try std.fmt.allocPrint(alloc, "{d} personnel · fatigue {s}{d}{{/}} ({d} tired, {s}{d} spent{{/}}) · morale {s}{d}{{/}} · {s} · {d} contracts since rotation{s}", .{
        r.heads,
        if (r.fatigue >= tp.exhausted_fatigue) "{c}" else if (r.fatigue >= tp.fatigue_tired) "{a}" else "{g}",
        r.fatigue,
        r.tired,
        if (r.spent > 0) "{c}" else "{g}",
        r.spent,
        if (r.morale < 30) "{c}" else if (r.morale < 50) "{a}" else "{g}",
        r.morale,
        if (r.deployed) "{a}deployed{/}" else if (gs.isCompanyHome(company)) "at home" else "afield",
        r.contracts_since_rotation,
        if (r.days_since_rotation) |d| try std.fmt.allocPrint(alloc, " · {d} days since", .{d}) else "",
    }));
    try out.append(alloc, try std.fmt.allocPrint(alloc, "{d} hulls · avg quality {s} · {s}{d} need depot time{{/}} · {d} XP banked in the cockpits{s}", .{
        r.hulls, @tagName(r.avg_quality), if (r.depot > 0) "{c}" else "", r.depot, r.banked_xp, if (r.banked_xp > 0 and !r.deployed) " — a training ground turns it into skill" else "",
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
            try out.append(alloc, try std.fmt.allocPrint(alloc, "  {{a}}{s} {s}{{/}} {s} — {s}{s}", .{ p.first_name, p.last_name, @tagName(p.role), where.items, if (p.wound_heal_day) |h| try std.fmt.allocPrint(alloc, " · back day {d} ({d}d)", .{ h, h -| day }) else if (p.medbay_admitted) " · triage tomorrow" else " · {c}not admitted{/}" }));
        } else if (p.permanentPenalty() > 0) {
            try out.append(alloc, try std.fmt.allocPrint(alloc, "  {s} {s} {s} — permanent injury, +{d} to skill rolls", .{ p.first_name, p.last_name, @tagName(p.role), p.permanentPenalty() }));
        } else if (p.training) |t| {
            try out.append(alloc, try std.fmt.allocPrint(alloc, "  {s} {s} {s} — training {s}, done day {d}", .{ p.first_name, p.last_name, @tagName(p.role), @tagName(t.skill), t.done_day }));
        }
    }
    return out.toOwnedSlice(alloc);
}

pub fn personRecord(alloc: Alloc, gs: *GameState, id: types.PersonId) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const p = gs.person(id) orelse return out.toOwnedSlice(alloc);
    const day = gs.clock.day_index;
    try out.append(alloc, try std.fmt.allocPrint(alloc, "{{a}}{s} {s} {s}{{/}}{s}  ·  {s} · {s} · {s}{s}", .{ p.rank.abbrev(), p.first_name, p.last_name, if (p.callsign) |c| try std.fmt.allocPrint(alloc, " \"{s}\"", .{c}) else "", @tagName(p.role), @tagName(p.experience()), p.rank.name(), if (p.rank_pinned) " (pinned — :promote <id> <rank> unpin lets seats decide)" else "" }));
    try out.append(alloc, try std.fmt.allocPrint(alloc, "status      {s}{s}", .{ try statusText(alloc, gs, p), if (p.status == .wounded) (if (p.wound_heal_day) |h| try std.fmt.allocPrint(alloc, " · discharged day {d} ({d} days)", .{ h, h -| day }) else if (p.medbay_admitted) " · triage tomorrow" else " · {c}not admitted — [m] admits{/}") else "" }));
    try out.append(alloc, try std.fmt.allocPrint(alloc, "assignment  {s}", .{try assignmentText(alloc, gs, p)}));
    try out.append(alloc, try std.fmt.allocPrint(alloc, "unit        {s} · at {s}", .{ if (p.assigned_force != .none) forceName(gs, p.assigned_force) else "—", locationText(gs, p) }));
    try out.append(alloc, "");
    const band = p.fatigueBand();
    try out.append(alloc, try std.fmt.allocPrint(alloc, "XP {{a}}{d}{{/}} · fatigue {s}{d} {s}{{/}}{s} · morale {d} · pay {s}/mo · recruited day {d}", .{
        p.xp,                                                                                                     band.markup(),
        p.fatigue,                                                                                                @tagName(band),
        if (band.penalty() > 0) try std.fmt.allocPrint(alloc, " (+{d} gunnery/piloting{s})", .{ band.penalty(), if (band == .spent) ", unfit" else "" }) else "",
        p.morale,                                                                                                 try money(alloc, p.monthlySalary()),
        p.recruited_day,
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
    if (p.shares > 0 or p.isFounder()) try out.append(alloc, try std.fmt.allocPrint(alloc, "shares      {d} share{s}{s} · {d}% of contract income is split among shareholders at completion", .{ p.shares, if (p.shares == 1) "" else "s", if (p.isFounder()) " · founder" else "", @divTrunc(gs.share_profit_bp, 100) }));
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
        if (u.status == .destroyed or u.status == .mothballed) continue;
        if (u.force == .none and !gs.canReachPool(p)) continue; // the pool is at the seat; their company is away
        const ch = chassis_mod.find(u.chassis_key);
        const label = try std.fmt.allocPrint(alloc, "#{d: <3} {s: <8} {s: <16} {s}", .{ @intFromEnum(u.id), u.chassis_key, if (ch) |c| c.name else "?", if (u.force == .none) "unassigned pool" else clip(forceName(gs, gs.companyOf(u.force)), 20) });
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
    cells: table.Row,
};

pub const history_cols: []const table.Col = &.{
    .{ .name = "id" },      .{ .name = "kind" },                  .{ .name = "emp" },     .{ .name = "world" },
    .{ .name = "outcome" }, .{ .name = "served", .justify = .right }, .{ .name = "VP", .justify = .right }, .{ .name = "verdict" },
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
        if (c.status != .completed and c.status != .breached and c.status != .failed) continue;
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
            forceName(gs, c.assigned_company),
        }) });
    }
    return out.toOwnedSlice(alloc);
}


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
        try budget.append(alloc, "{a}not a mek — the lab works on BattleMechs; this hull's gear is field work: Forces R (or :replace <unit>) orders spares to its site and its tech fits them{/}");
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
                const comp = @import("../domain/part.zig").componentFor(s.slot_key, u.chassis_key);
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
        if (pl.committed) {
            // Where the work stands (12.27): the bay job this plan became.
            var job_line: ?[]const u8 = null;
            var ahead: u32 = 0;
            for (gs.bay_jobs.items) |j| {
                if (j.unit == uid and j.kind == .refit) {
                    job_line = if (j.started_day != null) try std.fmt.allocPrint(alloc, "  {{g}}in the bay at {s}{{/}} — done day {d} ({d} day{s} left)", .{ hqName(gs, j.hq), j.done_day orelse 0, (j.done_day orelse gs.clock.day_index) -| gs.clock.day_index, if ((j.done_day orelse gs.clock.day_index) -| gs.clock.day_index == 1) "" else "s" }) else try std.fmt.allocPrint(alloc, "  {{a}}queued at {s}{{/}} — {d} job{s} ahead, {d} bay slot{s}; see the HQ screen (F7) bays list", .{ hqName(gs, j.hq), ahead, if (ahead == 1) "" else "s", @import("hq_ops.zig").baySlots(gs, j.hq), if (@import("hq_ops.zig").baySlots(gs, j.hq) == 1) "" else "s" });
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
    // The torso for this hull's weight class (12D.8).
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
    const lines = try hqDetail(a, &gs, hq);
    const h = gs.hqs.getPtr(hq).?;
    var seen: usize = 0;
    for (lines, 0..) |l, i| {
        const kind = try hqFacilityAtRow(a, &gs, hq, i);
        if (kind) |k| {
            try std.testing.expect(std.mem.startsWith(u8, l, @tagName(k)));
            try std.testing.expectEqual(h.facilities.items[seen].kind, k);
            seen += 1;
        }
    }
    try std.testing.expectEqual(h.facilities.items.len, seen);
    try std.testing.expect((try hqFacilityAtRow(a, &gs, hq, 0)) == null); // the header
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

test "12C.6: the rating scores six parts and a fresh outfit lands in the low letters" {
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

test "12C.8: the campaign summary reads counters, ledger and history" {
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

test "12.16: readiness counts wounded, permanent injuries, banked XP and depot hulls; marks strip for the CLI" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1216 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    const co = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha");
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

test "12.20: the hangar ranks a pilotless hull above one earning its keep, mothballs cheap but idle" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1220 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    _ = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha");
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

/// Standing orders (play feedback): every decision kind the inbox has
/// asked about, the last answer, and whether the game now applies that
/// answer without asking.
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

/// One company weighed against an offer (play feedback: the board never
/// said who could go, and the one-company shortcut sent whoever was home).
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
    .{ .name = "company" },                .{ .name = "stands" },                .{ .name = "jumps", .justify = .right },   .{ .name = "days", .justify = .right },
    .{ .name = "fatigue", .justify = .right }, .{ .name = "morale", .justify = .right }, .{ .name = "depot", .justify = .right }, .{ .name = "spent", .justify = .right },
    .{ .name = "wounded", .justify = .right }, .{ .name = "skulls" },                .{ .name = "rating" },                   .{ .name = "win / lose field" },
    .{ .name = "tonnage" },                .{ .name = "" },
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
    const tpb = @import("../domain/tuning.zig").t.person;
    for (try readiness(alloc, gs)) |r| {
        const f = gs.force(r.company) orelse continue;
        // Where the company stands, as acceptContract reckons it.
        var why: []const u8 = "";
        var from_key: ?[]const u8 = null;
        var stands: []const u8 = "home";
        if (!@import("commands.zig").offerEligible(gs, &offer, r.company)) {
            // Another HQ's board (12E.4).
            why = try std.fmt.allocPrint(alloc, "based at {s}, not {s}", .{ hqName(gs, gs.homeHqFor(r.company)), hqName(gs, offer.offer_hq) });
        } else if (gs.deploymentContract(r.company)) |c| {
            why = "under contract";
            from_key = c.planet_key;
            stands = try std.fmt.allocPrint(alloc, "on {s}", .{planetName(c.planet_key)});
        } else if (f.return_eta_day != null) {
            why = "in transit home";
        } else if (f.location_planet) |p| {
            from_key = p;
            stands = try std.fmt.allocPrint(alloc, "afield on {s}", .{planetName(p)});
        } else if (gs.hqs.getPtr(gs.homeHqFor(r.company))) |h| {
            from_key = h.planet_key;
            stands = try std.fmt.allocPrint(alloc, "home, {s}", .{h.name});
        }
        var jumps: u32 = std.math.divCeil(u32, offer.dist_ly, 30) catch unreachable;
        if (from_key) |fk| if (planet_mod.find(fk)) |from| if (to) |t| {
            jumps = planet_mod.jumpsBetween(from, t);
        };
        const days: u32 = if (jumps == 0) 3 else logistics_mod.transitDays(jumps);
        const eligible = why.len == 0;
        const penalty: i32 = @as(i32, @intCast(r.depot)) * 10 + @as(i32, @intCast(r.spent)) * 5 + @as(i32, @intCast(r.wounded)) * 3 +
            @as(i32, @intCast(r.fatigue / 4)) + @as(i32, @intCast(days / 4)) - @as(i32, @intCast(r.morale / 4));
        const fat_mk: []const u8 = if (r.fatigue >= tpb.exhausted_fatigue) "{c}" else if (r.fatigue >= tpb.fatigue_tired) "{a}" else "{g}";
        const mor_mk: []const u8 = if (r.morale < 30) "{c}" else if (r.morale < 50) "{a}" else "{g}";
        // Skulls (12E.5): what the company can field today against what the
        // intel says the enemy brings to a fight.
        const odds_mk: []const u8 = "";
        const rated = try rateOffer(alloc, gs, &offer, r.company);
        const odds: []const u8 = if (rated) |rt|
            try std.fmt.allocPrint(alloc, "{s}{s}{{/}} {s} · {d}% / {d}% · {s}", .{ if (rt.half_hi >= 9) "{c}" else if (rt.half_hi >= 7) "{a}" else "{g}", try skullGlyphs(alloc, rt.half_hi), try skullText(alloc, rt), rt.win_pct, rt.lose_field_pct, try tonnageText(alloc, rt) })
        else
            "—";
        const cells: table.Row = if (!eligible)
            try table.row(alloc, &.{ try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}", .{f.name}), try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}", .{stands}), "", "", "", "", "", "", "", "", "", "", "", try std.fmt.allocPrint(alloc, "{{d}}cannot go: {s}{{/}}", .{why}) })
        else
            try table.row(alloc, &.{
                try std.fmt.allocPrint(alloc, "{{a}}{s}{{/}}", .{f.name}),
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
                try padCells(alloc, "{a}", f.name, 21), try padCells(alloc, "", clip(stands, 25), 25), jumps,                          days,
                fat_mk,                                 r.fatigue,                                     mor_mk,                         r.morale,
                if (r.depot > 0) "{c}" else "",         r.depot,                                       if (r.spent > 0) "{a}" else "", r.spent,
                if (r.wounded > 0) "{a}" else "",       r.wounded,                                     odds_mk,                        odds,
            })
        else
            try std.fmt.allocPrint(alloc, "{{d}}{s: <21} {s: <25} cannot go: {s}{{/}}", .{ f.name, clip(stands, 25), why });
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

test "play feedback: offer candidates rank the ready company first and name why the others cannot go" {
    const commands = @import("commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 71 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    // One company lives at the HQ; the others are on the books without a slot (the HQ hosts one).
    const gen = @import("../gen/company_gen.zig");
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
    try std.testing.expectEqual(@as(u32, 3), cands[0].transit_days); // same world: three days to muster
}

// ------------------------------------------------ pickers (12.30, play feedback)
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

fn companyStands(alloc: Alloc, gs: *GameState, company: types.ForceId) ![]const u8 {
    if (gs.deploymentContract(company)) |c| return std.fmt.allocPrint(alloc, "on contract, {s}", .{planetName(c.planet_key)});
    const f = gs.force(company) orelse return "";
    if (f.return_eta_day != null) return "in transit home";
    if (f.location_planet) |p| return std.fmt.allocPrint(alloc, "afield on {s}", .{planetName(p)});
    return if (gs.hqs.getPtr(gs.homeHqFor(company))) |h| std.fmt.allocPrint(alloc, "home, {s}", .{h.name}) else "home";
}

fn daysBetweenCompanies(gs: *GameState, from: types.ForceId, to: types.ForceId) u32 {
    const a = planet_mod.find(companyPlanetKey(gs, from) orelse "") orelse return 0;
    const b = planet_mod.find(companyPlanetKey(gs, to) orelse "") orelse return 0;
    if (a == b) return 0;
    return logistics_mod.transitDays(planet_mod.jumpsBetween(a, b));
}

fn daysFromWorld(gs: *GameState, from_key: []const u8, to: types.ForceId) u32 {
    const a = planet_mod.find(from_key) orelse return 0;
    const b = planet_mod.find(companyPlanetKey(gs, to) orelse "") orelse return 0;
    if (a == b) return 0;
    return logistics_mod.transitDays(planet_mod.jumpsBetween(a, b));
}

/// Companies a hull or a person could transfer to: where each stands,
/// how many days away, and what room or need it has for them. Ranked by
/// days; the subject's own company is left out; a subject that cannot
/// move at all (deployed, in transit, in the depot) dims every row.
pub fn companyChoices(alloc: Alloc, gs: *GameState, what: enum { unit, person, stock }, subject: u32) ![]PickRow {
    var out: std.ArrayListUnmanaged(PickRow) = .empty;
    const personnel = @import("personnel.zig");
    const unit_dom = @import("../domain/unit.zig");
    const force_dom = @import("../domain/force.zig");
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
            if (gs.deploymentContract(from) != null) blocked = "its company is deployed";
            if (u.?.status == .in_transit) blocked = "it is in transit";
            if (u.?.status == .repairing) blocked = "it is in the depot";
        },
        .person => {
            p = gs.person(@enumFromInt(subject)) orelse return out.toOwnedSlice(alloc);
            from = gs.companyOf(p.?.assigned_force);
            if (gs.deploymentContract(from) != null) blocked = "their company is deployed";
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
                room = try std.fmt.allocPrint(alloc, "→ {s}", .{forceName(gs, sid)});
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
            try table.row(alloc, &.{ try std.fmt.allocPrint(alloc, "{{a}}{s}{{/}}", .{co.name}), stands, try std.fmt.allocPrint(alloc, "{d}", .{days}), room })
        else
            try table.row(alloc, &.{ try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}", .{co.name}), try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}", .{stands}), "", try std.fmt.allocPrint(alloc, "{{d}}cannot move: {s}{{/}}", .{blocked}) });
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
            try table.row(alloc, &.{ try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}", .{h.name}), try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}", .{@tagName(h.tier)}), try std.fmt.allocPrint(alloc, "{{d}}{s}{{/}}", .{planetName(h.planet_key)}), try std.fmt.allocPrint(alloc, "{{d}}{d}/{d}{{/}}", .{ h.staff_assigned, req }), "{d}posted here{/}" })
        else
            try table.row(alloc, &.{ try std.fmt.allocPrint(alloc, "{{a}}{s}{{/}}", .{h.name}), @tagName(h.tier), planetName(h.planet_key), try std.fmt.allocPrint(alloc, "{s}{d}/{d}{{/}}", .{ if (h.staff_assigned < req) "{c}" else "{g}", h.staff_assigned, req }), if (h.staff_assigned < req) "short-handed" else "" }) });
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
    const day = gs.clock.day_index;
    const own = gs.companyOf(u.force);
    const pilot_role = unit_dom.crewRoleFor(u.kind);
    const tech_role = unit_dom.techRoleFor(u.kind);
    const Rank = struct { same: bool, busy: u32, skill: u8 };
    var ranks: std.ArrayListUnmanaged(Rank) = .empty;
    var pit = gs.people.iterator();
    while (pit.next()) |e| {
        const p = e.value_ptr;
        const slot: @import("state.zig").Slot = if (p.role == pilot_role) .pilot else if (tech_role != null and p.role == tech_role.?) .tech else continue;
        if (p.status != .active and p.status != .wounded) continue;
        var why: []const u8 = "";
        if (!p.isAvailable(day)) why = if (p.status == .wounded) "wounded" else "unavailable";
        if (why.len == 0 and u.force == .none and !gs.canReachPool(p)) why = "away with their company";
        const seat = gs.pilotSeat(p.id);
        const load = if (slot == .tech) gs.techLoadHours(p.id) else 0;
        const now: []const u8 = if (slot == .pilot)
            (if (seat == unit_id) "this seat" else if (seat != .none) try std.fmt.allocPrint(alloc, "pilot of #{d}", .{@intFromEnum(seat)}) else "{g}free{/}")
        else
            (if (u.tech == p.id) "this hull's tech" else try std.fmt.allocPrint(alloc, "{s}{d}h of {d}h{{/}}", .{ if (load == 0) "{g}" else "", load, gs.techHoursAvailable(p) }));
        const skill = p.skill(p.role.primarySkill()) orelse 9;
        const same = gs.companyOf(p.assigned_force) == own and own != .none;
        const name = try std.fmt.allocPrint(alloc, "{s} {s}", .{ p.first_name, p.last_name });
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
    if (gs.person(u.pilot)) |p| try out.append(alloc, .{ .id = 0, .eligible = true, .slot = .pilot, .cells = try table.row(alloc, &.{ "{a}pilot{/}", try std.fmt.allocPrint(alloc, "{s} {s}", .{ p.first_name, p.last_name }) }) });
    if (gs.person(u.tech)) |t| try out.append(alloc, .{ .id = 1, .eligible = true, .slot = .tech, .cells = try table.row(alloc, &.{ "{a}tech{/}", try std.fmt.allocPrint(alloc, "{s} {s}", .{ t.first_name, t.last_name }) }) });
    if (out.items.len == 2) try out.append(alloc, .{ .id = 2, .eligible = true, .slot = .any, .cells = try table.row(alloc, &.{ "{a}both{/}", "" }) });
    return out.toOwnedSlice(alloc);
}

test "pickers: crew rows are the right roles, own company and free first; company rows leave out the subject's own" {
    const commands = @import("commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 90 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    const other = try @import("../gen/company_gen.zig").generateInto(&gs, "Bravo");
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
        try out.append(alloc, .{ .id = @intCast(i), .eligible = true, .key = p.key, .cells = try table.row(alloc, &.{
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

test "play feedback: the board's transit column is real — from the nearest company that could go, never 0" {
    const commands = @import("commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 92 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    _ = try commands.execute(&gs, .{ .new_company = "Alpha" });
    try @import("../econ/contract_market.zig").refresh(&gs);
    try std.testing.expect(gs.contract_offers.items.len > 0);
    for (gs.contract_offers.items) |*o| {
        const d = offerTransitDays(&gs, o);
        try std.testing.expect(d >= 3);
        // Same world as the seat: three days to muster; further: at least one jump's transit.
        if (std.mem.eql(u8, o.planet_key, gs.hqs.values()[0].planet_key)) try std.testing.expectEqual(@as(u32, 3), d);
    }
}

test "play feedback: the DAMAGE pane asks for components only where structure is destroyed or missing" {
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

test "play feedback: the unassigned pool says where it sits and what each wreck's rebuild needs from that shelf" {
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
        if (r.unit == wreck and std.mem.indexOf(u8, r.text, "comp_ct_l×1") != null) row_ok = true; // a Locust takes a light assembly (12D.8)
    }
    try std.testing.expect(header_ok);
    try std.testing.expect(row_ok);
    var label_ok = false;
    for (try toeViews(al, &gs)) |v| if (v.filter == .unassigned and std.mem.indexOf(u8, v.label, hq_name) != null) {
        label_ok = true;
    };
    try std.testing.expect(label_ok);
}

test "12E.3: skulls — a weaker company rates harder, a heavier one easier; low intel gives a range around the truth" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1231 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const alpha = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha");
    const bravo = try @import("../gen/company_gen.zig").generateInto(&gs, "Bravo");
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

test "12E.5: skulls on the board, the candidates, the active pane — and an outmatched company is warned" {
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
