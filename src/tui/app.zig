//! The terminal client (Stage 12, docs/tui.md): a lobby (players →
//! campaigns → new-campaign wizard) and the in-game frame — tab bar,
//! status strip, panes, modals and a `:` command line. Strict boundary:
//! every mutation goes through `game.commands.execute`; every read goes
//! through `game.queries`. The screen is rebuilt from queries on each
//! event into a per-frame arena, so no view state can drift from the sim.
//! No MekHQ counterpart (MekHQ is Swing).

const std = @import("std");
const game = @import("game");
const term_mod = @import("term.zig");
const screen_mod = @import("screen.zig");
const emblem_mod = @import("emblem.zig");
const png = @import("png.zig");
const music_mod = @import("music.zig");
const splash = @import("splash.zig");

const Term = term_mod.Term;
const Key = term_mod.Key;
const Screen = screen_mod.Screen;
const Rect = screen_mod.Rect;
const Style = screen_mod.Style;
const q = game.queries;
const types = game.types;
const Command = game.commands.Command;
const GameState = game.state.GameState;
const Treasury = game.state.Treasury;

const Tab = enum(u8) { desk, map, forces, contracts, ledger, supply, hq, lab, people, market };
const tab_names = [_][]const u8{ "F1 Desk", "F2 Map", "F3 Forces", "F4 Contracts", "F5 Ledger", "F6 Supply", "F7 HQ", "F8 Lab", "F9 People", "F10 Market" };

const Mode = enum { welcome, wizard, game };
const WizardStep = enum(u8) { commander, outfit, company, review };

const InputKind = enum { command, new_player, delete_campaign, delete_player, accept_company };

const Modal = union(enum) {
    none,
    end_turn,
    quit,
    decision: usize,
    input: InputKind,
    help,
    /// Confirm firing a person.
    fire: types.PersonId,
    /// Pick an open pilot/tech seat for a person.
    seat: types.PersonId,
    /// Change the outfit's emblem: presets, then pictures from the logo dirs.
    emblem,
    /// Hull detail as a modal (narrow terminals have no side pane).
    hull: types.UnitId,
    /// A person's record as a modal.
    record: types.PersonId,
    /// Liquidation confirmations.
    sell_unit: types.UnitId,
    sell_hq: types.HqId,
    disband: types.ForceId,
    /// The outfit folded.
    game_over,
    /// Lab install: pick a part, then a location with the rules' verdict.
    install_part: types.UnitId,
    install_loc: struct { unit: types.UnitId, part: []const u8 },
    /// Client settings (music).
    settings,
    /// HQ facility upgrade picker.
    upgrade: types.HqId,
    /// Lance picker for a hull.
    lance_pick: types.UnitId,
};

/// Size tiers (docs/tui.md): the largest that fits decides how many panes
/// a screen shows. Narrow (< 120 cols) drops side panes; short (< 30
/// rows) drops the third band.
const Tier = enum { minimum, compact, wide, full };

fn tierFor(cols: u16, rows: u16) Tier {
    if (cols >= 200 and rows >= 50) return .full;
    if (cols >= 160 and rows >= 45) return .wide;
    if (cols >= 118 and rows >= 36) return .compact;
    return .minimum;
}

const office_roles = [_]game.person.Role{ .admin_command, .admin_logistics, .admin_transport, .admin_hr, .admin_finance };

const verbs = [_][]const u8{
    "admit",       "repay",     "sell",     "sellhq",    "disband", "depot",   "role", "supplypolicy", "move",     "newlance",
    "stockpolicy", "autoadmit", "settings", "sellstock", "day",     "save",    "quit", "help",         "emblem",   "transfer",
    "policy",      "loan",      "accept",   "resolve",   "order",   "ship",    "buy",  "assign",       "unassign", "autoassign",
    "autostaff",   "upgrade",   "tier",     "fabricate", "hire",    "recruit", "fire", "post",         "train",    "triage",
    "leave",       "mothball",  "activate", "complete",  "recall",  "found",   "link", "assignco",     "newco",    "newco@",
    "xfer",        "rename",    "refit",
};

const Emblem = struct { name: []const u8, art: [3][]const u8 };
const emblems = [_]Emblem{
    .{ .name = "Wolf's Head", .art = .{ " /\\  /\\ ", " \\ \\/ / ", "  \\__/  " } },
    .{ .name = "Death's Head", .art = .{ " .---.  ", " |o o|  ", " \\_^_/  " } },
    .{ .name = "Hammer", .art = .{ " [===]  ", "   ||   ", "   ||   " } },
    .{ .name = "Star", .art = .{ "   *    ", " * * *  ", "   *    " } },
};

const factions = [_]game.commander.Faction{ .LC, .DC, .FS, .CC, .FWL };
const professions = [_]game.commander.Profession{ .quartermaster, .paymaster, .chief_engineer, .line_officer };

const TextBuf = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const TextBuf) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *TextBuf, s: []const u8) void {
        const n = @min(s.len, self.buf.len);
        @memcpy(self.buf[0..n], s[0..n]);
        self.len = n;
    }

    fn push(self: *TextBuf, cp: u21) void {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch return;
        if (self.len + n > self.buf.len) return;
        @memcpy(self.buf[self.len .. self.len + n], tmp[0..n]);
        self.len += n;
    }

    fn pop(self: *TextBuf) void {
        while (self.len > 0) {
            self.len -= 1;
            if ((self.buf[self.len] & 0xC0) != 0x80) break;
        }
    }
};

const Placement = struct { x: u16, y: u16, cols: u16, rows: u16 };

/// Where the wizard looks for pictures to import.
const logo_dirs = [_][]const u8{ ".", "logos", "docs/logos" };

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    screen: Screen,
    store: game.store.Store,
    frame: std.heap.ArenaAllocator,
    lobby: std.heap.ArenaAllocator,
    gs: ?GameState = null,
    running: bool = true,

    // soundtrack and title screen
    music: ?music_mod.Player = null,
    show_splash: bool = true,
    // emblem display
    graphics: emblem_mod.Graphics = .none,
    emblem: ?emblem_mod.Emblem = null,
    placements: [8]Placement = undefined,
    n_placements: usize = 0,
    // wizard import
    w_src: u8 = 0, // 0 presets · 1 import
    logos: []const []const u8 = &.{},
    w_logo: usize = 0,
    w_png: ?[]u8 = null,
    w_preview: ?emblem_mod.Emblem = null,

    mode: Mode = .welcome,
    step: WizardStep = .commander,
    tab: Tab = .desk,
    modal: Modal = .none,
    focus: u8 = 0,
    /// Cursor per tab per pane (welcome uses tab 0, wizard tab 1).
    cursor: [10][4]usize = [_][4]usize{[_]usize{0} ** 4} ** 10,
    msg: TextBuf = .{},
    msg_style: Style = .dim,
    input: TextBuf = .{},
    cmd_prefill: TextBuf = .{},

    // lobby
    player_id: i64 = 0,
    // wizard
    w_name: TextBuf = .{},
    w_outfit: TextBuf = .{},
    w_company: TextBuf = .{},
    w_field: u8 = 0,
    w_faction: usize = 0,
    w_profession: usize = 0,
    w_emblem: usize = 0,
    w_seed: u64 = 0,
    // screens
    ledger_sel: usize = 0,
    hq_sel: usize = 0,
    hall_filter: q.HallFilter = .all,
    people_filter: q.HallFilter = .all,
    market_filter: q.MarketFilter = .all,
    map_cursor: usize = 0,
    lab_sel: usize = 0,
    modal_cursor: usize = 0,
    w_office: usize = 0,

    // ------------------------------------------------------------------ lifecycle

    pub fn init(gpa: std.mem.Allocator, io: std.Io, term: *Term, store: game.store.Store) !App {
        const size = term.size();
        return .{
            .gpa = gpa,
            .io = io,
            .term = term,
            .screen = try Screen.init(gpa, size.cols, size.rows),
            .store = store,
            .frame = std.heap.ArenaAllocator.init(gpa),
            .lobby = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *App) void {
        if (self.music) |*m| m.deinit();
        if (self.gs) |*g| g.deinit();
        if (self.emblem) |*e| e.deinit(self.gpa);
        if (self.w_preview) |*e| e.deinit(self.gpa);
        if (self.w_png) |p| self.gpa.free(p);
        self.screen.deinit();
        self.frame.deinit();
        self.lobby.deinit();
    }

    /// Ask the terminal whether it speaks the kitty graphics protocol, and
    /// whether 24-bit colour is safe. Runs once, before the first frame.
    fn probeTerminal(self: *App) void {
        var buf: [256]u8 = undefined;
        const n = self.term.probe(emblem_mod.kitty_query, &buf, 250);
        if (emblem_mod.kittyReplyOk(buf[0..n])) self.graphics = .kitty;
        self.screen.truecolor = emblem_mod.detectTruecolor() or self.graphics == .kitty;
    }

    pub fn run(self: *App) !void {
        self.w_name.set("Erik Kalmar");
        self.w_outfit.set("The Unforgiven");
        self.w_company.set("Alpha Company");
        self.pickDefaultPlayer();
        self.probeTerminal();
        if (self.music) |*m| {
            m.setEnabled(self.store.getSetting("music", 1) != 0);
            m.setVolume(@intCast(std.math.clamp(self.store.getSetting("music_volume", 60), 0, 100)));
            m.poll(); // the soundtrack starts with the title screen
        }
        if (self.show_splash) try self.runSplash();
        while (self.running) {
            if (self.term.tookResize()) {
                const size = self.term.size();
                try self.screen.resize(size.cols, size.rows);
            }
            try self.draw();
            const key = self.term.readKey(500);
            if (self.music) |*m| m.poll();
            if (key == .none) continue;
            _ = self.frame.reset(.retain_capacity);
            self.handleKey(key) catch |err| self.say(.crit, "error: {s}", .{@errorName(err)});
        }
    }

    fn a(self: *App) std.mem.Allocator {
        return self.frame.allocator();
    }

    /// Title screen: five seconds, or any key.
    fn runSplash(self: *App) !void {
        splash.draw(&self.screen, self.screen.ascii);
        try self.screen.flush(self.term.out);
        var ticks: u32 = 0;
        while (ticks < 50) : (ticks += 1) {
            if (self.term.readKey(100) != .none) break;
            if (self.music) |*m| m.poll();
        }
    }

    fn nowPlaying(self: *App) []const u8 {
        const m = &(self.music orelse return "");
        if (!m.enabled) return "♪ off";
        return m.nowPlaying() orelse "";
    }

    fn say(self: *App, style: Style, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.msg.buf, fmt, args) catch self.msg.buf[0..];
        self.msg.len = s.len;
        self.msg_style = style;
    }

    fn cur(self: *App, pane: u8) *usize {
        const t: usize = switch (self.mode) {
            .welcome => 8,
            .wizard => 9,
            .game => @intFromEnum(self.tab),
        };
        return &self.cursor[t][pane];
    }

    fn pickDefaultPlayer(self: *App) void {
        const players = self.store.listPlayers(self.a()) catch return;
        if (players.len > 0) self.player_id = players[0].id;
    }

    // ------------------------------------------------------------------ drawing

    fn draw(self: *App) !void {
        _ = self.frame.reset(.retain_capacity);
        self.screen.clear();
        self.n_placements = 0;
        switch (self.mode) {
            .welcome => try self.drawWelcome(),
            .wizard => try self.drawWizard(),
            .game => try self.drawGame(),
        }
        const modal_open = self.modal != .none and !(self.modal == .input and self.modal.input == .command);
        try self.drawModal();
        try self.screen.flush(self.term.out);
        if (self.graphics == .kitty) {
            try emblem_mod.kittyDeleteAll(self.term.out);
            // Pictures sit above text; keep them off while a modal is up.
            if (!modal_open) {
                for (self.placements[0..self.n_placements]) |p| {
                    const e = self.currentEmblem() orelse break;
                    try emblem_mod.kittyPlace(self.term.out, e.kitty_id, p.x, p.y, p.cols, p.rows);
                }
            }
            try self.term.out.flush();
        }
    }

    fn currentEmblem(self: *App) ?*emblem_mod.Emblem {
        if (self.mode == .wizard) return if (self.w_preview) |*e| e else null;
        return if (self.emblem) |*e| e else null;
    }

    /// Draw the outfit's picture into a rect: a kitty placement (cells left
    /// blank) or half-block colour. Returns false when there is no picture.
    fn drawEmblem(self: *App, r: Rect) bool {
        const e = self.currentEmblem() orelse return false;
        if (r.w < 2 or r.h < 1) return false;
        if (self.graphics == .kitty) {
            // keep the picture's aspect: cells are ~1:2, so cols ≈ 2 × rows for a square
            var rows: u32 = r.h;
            var cols: u32 = @min(@as(u32, r.w), rows * 2 * e.img.width / @max(1, e.img.height));
            if (cols == 0) cols = 1;
            rows = @min(rows, @max(1, cols * e.img.height / @max(1, 2 * e.img.width)));
            if (self.n_placements < self.placements.len) {
                self.placements[self.n_placements] = .{
                    .x = r.x + @as(u16, @intCast((r.w - cols) / 2)),
                    .y = r.y + @as(u16, @intCast((r.h - rows) / 2)),
                    .cols = @intCast(cols),
                    .rows = @intCast(rows),
                };
                self.n_placements += 1;
            }
        } else {
            self.screen.blit(r, &e.img);
        }
        return true;
    }

    /// Load the campaign's emblem (a PNG stored on one of its forces).
    fn refreshEmblem(self: *App) void {
        if (self.emblem) |*e| {
            if (self.graphics == .kitty) emblem_mod.kittyForget(self.term.out, e.kitty_id) catch {};
            e.deinit(self.gpa);
            self.emblem = null;
        }
        const g = &(self.gs orelse return);
        var fit = g.forces.iterator();
        while (fit.next()) |fe| {
            const bytes = fe.value_ptr.emblem orelse continue;
            if (!png.isPng(bytes)) continue;
            self.emblem = emblem_mod.Emblem.load(self.gpa, bytes, 1) catch continue;
            if (self.graphics == .kitty) emblem_mod.kittyTransmit(self.term.out, self.gpa, 1, bytes) catch {};
            return;
        }
    }

    fn body(self: *App) Rect {
        const s = &self.screen;
        return .{ .x = 0, .y = 2, .w = s.cols, .h = if (s.rows > 3) s.rows - 3 else 0 };
    }

    fn tier(self: *App) Tier {
        return tierFor(self.screen.cols, self.screen.rows);
    }

    /// Side panes are dropped below this width.
    fn narrow(self: *App) bool {
        return self.screen.cols < 120;
    }

    fn titleBar(self: *App, title: []const u8, right: []const u8) void {
        const s = &self.screen;
        s.textPad(0, 0, s.cols, "", .normal);
        var buf: [128]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, " {s} ", .{title}) catch title;
        _ = s.text(0, 0, s.cols, t, .tab);
        const rl: i32 = @intCast(screen_mod.visibleLen(right));
        _ = s.text(@as(i32, s.cols) - rl, 0, @intCast(rl), right, .dim);
    }

    fn footer(self: *App, hint: []const u8) void {
        const s = &self.screen;
        const y: i32 = @as(i32, s.rows) - 1;
        if (self.modal == .input and self.modal.input == .command) {
            var buf: [160]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, ":{s}_", .{self.input.slice()}) catch ":";
            s.textPad(0, y, s.cols, line, .normal);
            // completion candidates / parse errors sit to the right of the prompt
            if (self.msg.len > 0) {
                const used: i32 = @intCast(screen_mod.visibleLen(line) + 3);
                if (used < s.cols) _ = s.text(used, y, @intCast(s.cols - @as(u16, @intCast(used))), self.msg.slice(), self.msg_style);
            }
            return;
        }
        if (self.msg.len > 0) {
            s.textPad(0, y, s.cols, self.msg.slice(), self.msg_style);
            const hl: i32 = @intCast(screen_mod.visibleLen(hint));
            if (hl + @as(i32, @intCast(self.msg.len)) + 4 < s.cols) _ = s.text(@as(i32, s.cols) - hl, y, @intCast(hl), hint, .dim);
        } else {
            s.textPad(0, y, s.cols, "", .normal);
            const hl: i32 = @intCast(screen_mod.visibleLen(hint));
            _ = s.text(@max(0, @as(i32, s.cols) - hl), y, @intCast(@min(hl, s.cols)), hint, .dim);
        }
    }

    /// Scroll offset that keeps `cursor` visible in `h` rows.
    fn firstRow(cursor: usize, h: u16) usize {
        if (h == 0) return 0;
        return if (cursor >= h) cursor - h + 1 else 0;
    }

    fn listPane(self: *App, r: Rect, title: []const u8, items: []const []const u8, pane: u8, focused: bool, with_cursor: bool) void {
        const inner = self.screen.pane(r, .{ .title = title, .focused = focused });
        const c = self.cur(pane);
        if (items.len > 0 and c.* >= items.len) c.* = items.len - 1;
        const cursor: ?usize = if (with_cursor and focused and items.len > 0) c.* else null;
        self.screen.lines(inner, items, firstRow(if (with_cursor) c.* else 0, inner.h), cursor);
    }

    // ---- lobby ----

    fn drawWelcome(self: *App) !void {
        const al = self.a();
        var right_buf: [96]u8 = undefined;
        const players = try self.store.listPlayers(al);
        const campaigns = try self.store.listCampaignsOf(al, self.player_id);
        const np = self.nowPlaying();
        const right = std.fmt.bufPrint(&right_buf, "{s}{s}{d} players · {d} campaigns · schema v{d}", .{ if (np.len > 0) "♪ " else "", if (np.len > 0) np else "", players.len, campaigns.len, game.store.schema_version }) catch "";
        // (the separator between track and counts)
        var title_buf: [64]u8 = undefined;
        self.titleBar(std.fmt.bufPrint(&title_buf, "{s} · MERCENARY COMMAND CONSOLE", .{splash.game_name}) catch splash.game_name, right);

        const b = self.body();
        const pw: u16 = @min(30, b.w / 4);
        const top_h: u16 = if (b.h > 12) b.h * 2 / 3 else b.h;
        var prow: std.ArrayListUnmanaged([]const u8) = .empty;
        for (players) |p| {
            const mk: []const u8 = if (p.id == self.player_id) "{a}" else "";
            try prow.append(al, try std.fmt.allocPrint(al, "{s}{s}{{/}}  {d} campaign{s}", .{ mk, p.name, p.campaigns, if (p.campaigns == 1) "" else "s" }));
        }
        if (players.len == 0) try prow.append(al, "{d}no players yet — [p] creates one{/}");
        self.listPane(.{ .x = b.x, .y = b.y, .w = pw, .h = top_h }, "PLAYERS", prow.items, 0, self.focus == 0, true);

        var crow: std.ArrayListUnmanaged([]const u8) = .empty;
        for (campaigns) |c| {
            try crow.append(al, try std.fmt.allocPrint(al, "{{a}}{s}{{/}}  ·  {s}  ·  day {d} ({s})  ·  save #{d}", .{ c.name, c.commander, c.day, c.date, c.save_seq }));
        }
        if (campaigns.len == 0) try crow.append(al, "{d}no campaigns for this player — [n] starts one{/}");
        const cw: u16 = b.w - pw - 1;
        self.listPane(.{ .x = b.x + pw + 1, .y = b.y, .w = cw, .h = top_h }, "CAMPAIGNS", crow.items, 1, self.focus == 1, true);

        if (b.h > top_h + 3) {
            var snap: std.ArrayListUnmanaged([]const u8) = .empty;
            const ci = self.cur(1).*;
            if (campaigns.len > 0 and ci < campaigns.len) {
                const c = campaigns[ci];
                try snap.append(al, try std.fmt.allocPrint(al, "{{a}}{s}{{/}} — commander {s}", .{ c.name, c.commander }));
                try snap.append(al, try std.fmt.allocPrint(al, "saved at day {d} · {s} · registry id {d}", .{ c.day, c.date, c.id }));
                try snap.append(al, "");
                try snap.append(al, "{d}[Enter] continue this campaign{/}");
            } else {
                try snap.append(al, "{d}select a campaign, or press [n] to start a new one{/}");
            }
            self.listPane(.{ .x = b.x, .y = b.y + top_h, .w = b.w, .h = b.h - top_h }, "SNAPSHOT", snap.items, 2, false, false);
        }
        self.footer("[Enter] continue  [n] new campaign  [d] delete campaign  [p] new player  [D] delete player  [s] settings  [M] music  [q] quit");
    }

    fn drawWizard(self: *App) !void {
        const al = self.a();
        const s = &self.screen;
        var tbuf: [96]u8 = undefined;
        const title = std.fmt.bufPrint(&tbuf, "NEW CAMPAIGN · step {d} of 4 · {s}", .{ @intFromEnum(self.step) + 1, switch (self.step) {
            .commander => "Commander",
            .outfit => "Outfit & emblem",
            .company => "Company & back office",
            .review => "Review",
        } }) catch "NEW CAMPAIGN";
        self.titleBar(title, "");
        const b = self.body();
        switch (self.step) {
            .commander => {
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                try rows.append(al, try std.fmt.allocPrint(al, "name        {s}{s}{s}{{/}}", .{ if (self.w_field == 0) "{s}" else "", self.w_name.slice(), if (self.w_field == 0) "_" else "" }));
                try rows.append(al, "");
                try rows.append(al, "faction of origin");
                for (factions, 0..) |f, i| {
                    const sel = self.w_field == 1 and i == self.w_faction;
                    try rows.append(al, try std.fmt.allocPrint(al, "  {s}{s} {s: <24} {s}{{/}}", .{ if (sel) "{s}" else if (i == self.w_faction) "{a}" else "", if (i == self.w_faction) ">" else " ", f.fullName(), f.key() }));
                }
                try rows.append(al, "");
                try rows.append(al, "profession");
                for (professions, 0..) |p, i| {
                    const sel = self.w_field == 2 and i == self.w_profession;
                    try rows.append(al, try std.fmt.allocPrint(al, "  {s}{s} {s: <16} {s}{{/}}", .{ if (sel) "{s}" else if (i == self.w_profession) "{a}" else "", if (i == self.w_profession) ">" else " ", @tagName(p), p.description() }));
                }
                const lw: u16 = @min(70, b.w * 2 / 5);
                _ = self.listPane(.{ .x = 0, .y = b.y, .w = lw, .h = b.h }, "COMMANDER", rows.items, 0, true, false);
                var info: std.ArrayListUnmanaged([]const u8) = .empty;
                try info.append(al, try std.fmt.allocPrint(al, "{{a}}{s}{{/}}", .{factions[self.w_faction].fullName()}));
                try info.append(al, "Your starter HQ is placed on a world in this faction's space,");
                try info.append(al, "weighted toward the marches where the work is. The first contract");
                try info.append(al, "board leans to this faction's employers.");
                try info.append(al, "");
                try info.append(al, try std.fmt.allocPrint(al, "{{a}}{s}{{/}}", .{@tagName(professions[self.w_profession])}));
                try info.append(al, try std.fmt.allocPrint(al, "{s} — for the life of the campaign.", .{professions[self.w_profession].description()}));
                try info.append(al, "The edge is small by design: it tilts, it never carries.");
                try info.append(al, "");
                try info.append(al, "{d}the faction and profession are permanent; names can change later{/}");
                _ = self.listPane(.{ .x = lw + 1, .y = b.y, .w = b.w - lw - 1, .h = b.h }, "WHAT THIS MEANS", info.items, 1, false, false);
                self.footer("[Tab] next field  [j/k] choose  [Enter] next step  [Esc] back to welcome");
            },
            .outfit => {
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                try rows.append(al, try std.fmt.allocPrint(al, "outfit name      {s}{s}{s}{{/}}", .{ if (self.w_field == 0) "{s}" else "", self.w_outfit.slice(), if (self.w_field == 0) "_" else "" }));
                try rows.append(al, try std.fmt.allocPrint(al, "first company    {s}{s}{s}{{/}}", .{ if (self.w_field == 1) "{s}" else "", self.w_company.slice(), if (self.w_field == 1) "_" else "" }));
                try rows.append(al, "");
                try rows.append(al, try std.fmt.allocPrint(al, "emblem source    {s}[h] presets{{/}}   {s}[l] import a picture{{/}}", .{ if (self.w_src == 0) (if (self.w_field == 2) "{s}" else "{a}") else "{d}", if (self.w_src == 1) (if (self.w_field == 2) "{s}" else "{a}") else "{d}" }));
                try rows.append(al, "");
                if (self.w_src == 1) {
                    try rows.append(al, try std.fmt.allocPrint(al, "PNG files in {s}", .{try std.mem.join(al, ", ", &logo_dirs)}));
                    if (self.logos.len == 0) try rows.append(al, "  {d}none found — drop a .png in the project root or a logos/ directory{/}");
                    for (self.logos, 0..) |name, i| {
                        const sel = i == self.w_logo;
                        try rows.append(al, try std.fmt.allocPrint(al, "  {s}{s} {s}{{/}}", .{ if (sel and self.w_field == 2) "{s}" else if (sel) "{a}" else "", if (sel) ">" else " ", name }));
                    }
                    try rows.append(al, "");
                    try rows.append(al, try std.fmt.allocPrint(al, "display          {s}", .{switch (self.graphics) {
                        .kitty => "{g}graphics protocol{/} — the picture itself, placed over cells",
                        .none => if (self.screen.truecolor) "{a}half-block colour{/} — two pixels per cell (no graphics protocol detected)" else "{a}256-colour half-blocks{/}",
                    }}));
                    if (self.w_preview) |*e| {
                        try rows.append(al, try std.fmt.allocPrint(al, "loaded           {d} × {d} px · {d} KB", .{ e.img.width, e.img.height, e.bytes.len / 1024 }));
                    } else if (self.logos.len > 0) {
                        try rows.append(al, "{d}[j/k] pick a file · it previews on the right and is stored with the campaign{/}");
                    }
                }
                for (0..3) |r| {
                    if (self.w_src == 1) break;
                    var line: std.ArrayListUnmanaged(u8) = .empty;
                    try line.appendSlice(al, "  ");
                    for (emblems, 0..) |e, i| {
                        if (i == self.w_emblem) try line.appendSlice(al, "{a}");
                        try line.appendSlice(al, e.art[r]);
                        if (i == self.w_emblem) try line.appendSlice(al, "{/}");
                        try line.appendSlice(al, "   ");
                    }
                    try rows.append(al, try line.toOwnedSlice(al));
                }
                if (self.w_src == 0) {
                    var names: std.ArrayListUnmanaged(u8) = .empty;
                    try names.appendSlice(al, "  ");
                    for (emblems, 0..) |e, i| {
                        try names.appendSlice(al, if (i == self.w_emblem) "{a}" else "{d}");
                        try names.appendSlice(al, try std.fmt.allocPrint(al, "{s: <11}", .{e.name}));
                        try names.appendSlice(al, "{/}");
                    }
                    try rows.append(al, try names.toOwnedSlice(al));
                    try rows.append(al, "  {d}[j/k] choose a preset{/}");
                }
                const lw: u16 = if (b.w > 120) b.w / 2 else b.w;
                _ = self.listPane(.{ .x = 0, .y = b.y, .w = lw, .h = b.h }, "OUTFIT", rows.items, 0, true, false);
                if (lw < b.w) {
                    const inner = self.screen.pane(.{ .x = lw, .y = b.y, .w = b.w - lw, .h = b.h }, .{ .title = "PREVIEW" });
                    if (!self.drawEmblem(inner)) {
                        const hint = [_][]const u8{ "", "  {d}pick a picture to preview it here{/}" };
                        self.screen.lines(inner, &hint, 0, null);
                    }
                }
                self.footer("[Tab] next field  [h/l] source  [j/k] choose  [Enter] next step  [Esc] back");
            },
            .company => {
                if (self.gs) |*g| {
                    const rows = try q.toe(al, g);
                    var texts: std.ArrayListUnmanaged([]const u8) = .empty;
                    for (rows) |r| try texts.append(al, r.text);
                    const lw: u16 = if (b.w > 120) b.w * 3 / 5 else b.w;
                    self.listPane(.{ .x = 0, .y = b.y, .w = lw, .h = b.h }, "GENERATED COMPANY", texts.items, 0, self.w_field == 0, true);
                    if (lw < b.w) {
                        const hq_id = self.firstHq(g);
                        const h = g.hqs.getPtr(hq_id);
                        const req = if (h) |hh| hh.staffRequired() else null;
                        var office: std.ArrayListUnmanaged([]const u8) = .empty;
                        try office.append(al, "role               have   need   payroll/mo   effect");
                        for (office_roles, 0..) |role, i| {
                            const have = g.hqStaff(hq_id, role).count;
                            const required: ?u32 = if (req) |r| switch (role) {
                                .admin_command => r.admin,
                                .admin_logistics => r.logistics,
                                .admin_hr => r.hr,
                                .admin_finance => r.finance,
                                else => null,
                            } else null;
                            const pay = role.baseSalary() * have;
                            const short = required != null and have < required.?;
                            try office.append(al, try std.fmt.allocPrint(al, "{s}{s: <18} {d: >4}   {s: >4}   {s: >10}   {s}{{/}}", .{
                                if (self.w_field == 1 and i == self.w_office) "{s}" else if (short) "{c}" else "",
                                @tagName(role),
                                have,
                                if (required) |n| try std.fmt.allocPrint(al, "{d}", .{n}) else "—",
                                try q.money(al, pay),
                                switch (role) {
                                    .admin_command => "orders, morale",
                                    .admin_logistics => "order rolls",
                                    .admin_transport => "shipping ETAs",
                                    .admin_hr => "hiring, training",
                                    .admin_finance => "paperwork days",
                                    else => "",
                                },
                            }));
                        }
                        const st = try q.status(al, g);
                        try office.append(al, "");
                        try office.append(al, try std.fmt.allocPrint(al, "staff {d} / {d} required · payroll {s}/mo · treasury {{a}}{s}{{/}} C", .{ if (h) |hh| hh.staff_assigned else 0, if (req) |r| r.total() else 0, try q.money(al, g.monthlyPayroll()), st.funds }));
                        try office.append(al, "{d}under-hiring is allowed: facilities run a level lower and paperwork slows{/}");
                        try office.append(al, "{d}[Tab] focus · [j/k] role · [-] fewer · [+] more{/}");
                        const oh: u16 = @min(b.h, 12);
                        self.listPane(.{ .x = lw + 1, .y = b.y, .w = b.w - lw - 1, .h = oh }, "BACK OFFICE", office.items, 1, self.w_field == 1, false);
                        if (b.h > oh + 3) {
                            const detail = try q.hqDetail(al, g, hq_id);
                            self.listPane(.{ .x = lw + 1, .y = b.y + oh, .w = b.w - lw - 1, .h = b.h - oh }, try std.fmt.allocPrint(al, "starter HQ · {s}", .{q.hqName(g, hq_id)}), detail, 2, false, false);
                        }
                    }
                }
                self.footer("[r] reroll (new seed)  [Tab] company / back office  [-/+] adjust headcount  [Enter] next step  [Esc] back");
            },
            .review => {
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                const has_picture = self.w_src == 1 and self.w_preview != null;
                if (self.gs) |*g| {
                    const st = try q.status(al, g);
                    const e = emblems[self.w_emblem];
                    const pad_art = "        ";
                    try rows.append(al, try std.fmt.allocPrint(al, "{s}   {{a}}{s}{{/}}", .{ if (has_picture) pad_art else e.art[0], self.w_outfit.slice() }));
                    try rows.append(al, try std.fmt.allocPrint(al, "{s}   {s} · {s} · {s} ({s})", .{ if (has_picture) pad_art else e.art[1], self.w_name.slice(), factions[self.w_faction].fullName(), @tagName(professions[self.w_profession]), professions[self.w_profession].description() }));
                    try rows.append(al, try std.fmt.allocPrint(al, "{s}   {{d}}{s} · day 0{{/}}", .{ if (has_picture) pad_art else e.art[2], st.date }));
                    try rows.append(al, "");
                    var hit = g.hqs.iterator();
                    while (hit.next()) |he| {
                        const h = he.value_ptr;
                        try rows.append(al, try std.fmt.allocPrint(al, "starter HQ    {{a}}{s}{{/}} on {s} · {s} · ring {d} LY · staff {d}/{d}", .{ h.name, q.planetName(h.planet_key), @tagName(h.tier), h.influenceLy(), h.staff_assigned, h.staffRequired().total() }));
                    }
                    try rows.append(al, try std.fmt.allocPrint(al, "company       {s} · {d} hulls · {d} people", .{ self.w_company.slice(), st.hulls, st.people }));
                    try rows.append(al, try std.fmt.allocPrint(al, "treasury      outfit {{a}}{s}{{/}} C", .{st.funds}));
                    try rows.append(al, try std.fmt.allocPrint(al, "first board   {d} offers within the ring on day 1", .{g.contract_offers.items.len}));
                    try rows.append(al, "");
                    try rows.append(al, "{s} [Enter] begin campaign {/}   {d}saves under the current player and opens the Desk on day 0{/}");
                }
                const rw: u16 = if (has_picture and b.w > 120) b.w * 2 / 3 else b.w;
                _ = self.listPane(.{ .x = 0, .y = b.y, .w = rw, .h = b.h }, "REVIEW", rows.items, 0, true, false);
                if (rw < b.w) {
                    const inner = self.screen.pane(.{ .x = rw, .y = b.y, .w = b.w - rw, .h = b.h }, .{ .title = "EMBLEM" });
                    _ = self.drawEmblem(inner);
                }
                self.footer("[Enter] begin campaign  [1-3] back to a step  [Esc] discard");
            },
        }
        _ = s;
    }

    // ---- game ----

    fn drawChrome(self: *App) !void {
        const al = self.a();
        const s = &self.screen;
        const g = &self.gs.?;
        s.textPad(0, 0, s.cols, "", .normal);
        var x: i32 = 0;
        for (tab_names, 0..) |name, i| {
            var buf: [24]u8 = undefined;
            const t = std.fmt.bufPrint(&buf, " {s} ", .{name}) catch name;
            const st: Style = if (i == @intFromEnum(self.tab)) .tab else .dim;
            x += s.text(x, 0, @intCast(t.len), t, st);
        }
        const right = g.outfit_name;
        var mark_w: u16 = 0;
        if (self.emblem != null and s.cols > 120) {
            mark_w = 8;
            _ = self.drawEmblem(.{ .x = s.cols - 7, .y = 0, .w = 6, .h = 3 });
        }
        _ = s.text(@as(i32, s.cols) - @as(i32, @intCast(right.len)) - 1 - mark_w, 0, @intCast(right.len), right, .dim);
        const st = try q.status(al, g);
        if (self.narrow()) {
            const short = try std.fmt.allocPrint(al, "{{a}}{s}{{/}} d{d} · {{a}}{s}{{/}} C · rep {d} · inbox {s}{d}{{/}} · chk {s}{d}{{/}} · ready {s}", .{
                st.date, st.day, st.funds, st.reputation, if (st.inbox > 0) "{c}" else "{g}", st.inbox, if (st.blocking > 0) "{c}" else "{g}", st.checklist, if (st.blocking > 0) "{c}NO{/}" else "{g}YES{/}",
            });
            s.textPad(0, 1, s.cols, short, .normal);
            return;
        }
        const line = try std.fmt.allocPrint(al, "{{a}}{s}{{/}}  day {d}  ·  outfit {{a}}{s}{{/}} C  ·  rep {s}{d}{{/}}  ·  {d} companies · {d} HQs · {d} hulls · {d} people  ·  inbox {s}{d}{{/}}  ·  checklist {s}{d}{{/}}  ·  turn ready: {s}", .{
            st.date,       st.day,
            st.funds,      if (st.reputation < 0) "{c}" else "{g}",
            st.reputation, st.companies,
            st.hqs,        st.hulls,
            st.people,     if (st.inbox > 0) "{c}" else "{g}",
            st.inbox,      if (st.blocking > 0) "{c}" else if (st.checklist > 0) "{a}" else "{g}",
            st.checklist,  if (st.blocking > 0) "{c}NO{/}" else "{g}YES{/}",
        });
        s.textPad(0, 1, s.cols, line, .normal);
    }

    fn drawGame(self: *App) !void {
        try self.drawChrome();
        switch (self.tab) {
            .desk => try self.drawDesk(),
            .contracts => try self.drawContracts(),
            .ledger => try self.drawLedger(),
            .forces => try self.drawForces(),
            .supply => try self.drawSupply(),
            .hq => try self.drawHq(),
            .map => try self.drawMap(),
            .lab => try self.drawLab(),
            .people => try self.drawPeople(),
            .market => try self.drawMarket(),
        }
        self.footer(switch (self.tab) {
            .desk => "? help · F1-F10 / 1-0 screens · Tab pane · Enter act · e emblem · F12 settings · : command · n end turn · q welcome",
            .people => "/ , filter (…, wounded) · m admit to medbay · t train · a seat · P post · x transfer · L leave · D fire · r record",
            .market => "Tab pane · Enter buy / order / order shortfall · b fabricate component · K keep stocked · [ ] HQ board · q welcome",
            .ledger => "j/k treasury · t send cash to it · T pull cash back to the outfit · p top-up policy · L loan · R repay",
            .supply => "company: t/T cash out/home · p cash policy · P resupply policy · s ship · o order · H structural parts home · HQ: K keep stocked · $ sell stock",
            .forces => "Enter assign · a/u seat · A auto · l lance · o role · d depot · m mothball · x company · b fabricate short comp · R recall · $ sell · X disband",
            .map => "h j k l move between worlds · f found HQ here · o offers here · n end turn · q welcome",
            .lab => "[ ] hull · j/k mount · - remove · + install · R order replacement · D send to depot (structure) · c clear · Enter commit",
            .hq => "[ ] switch HQ · u upgrade the highlighted facility (picker elsewhere) · T tier · S autostaff · Tab hall · f/F filter · Enter hire",
            else => "? help · F1-F8 screens · Tab pane · j/k cursor · Enter act · : command · n end turn · q welcome",
        });
    }

    // ---- market ----

    fn drawMarket(self: *App) !void {
        const al = self.a();
        const g = &self.gs.?;
        const b = self.body();
        const view = try q.market(al, g, self.market_filter);
        const top_h: u16 = @max(6, b.h * 2 / 5);
        var board: std.ArrayListUnmanaged([]const u8) = .empty;
        for (view.board) |r| try board.append(al, r.text);
        if (view.board.len == 0) try board.append(al, "{d}nothing on the boards — they refresh on the 1st, staples restock as they sell{/}");
        const hq_id: types.HqId = @enumFromInt(self.hqSelId(g));
        const inner = self.screen.pane(.{ .x = b.x, .y = b.y, .w = b.w, .h = top_h }, .{ .title = try std.fmt.allocPrint(al, "MARKET BOARDS · filter {{a}}{s}{{/}} · {d} listings · buyer {s}", .{ @tagName(self.market_filter), view.board.len, q.hqName(g, hq_id) }), .focused = self.focus == 0, .right_title = "[/] next filter  [,] previous  [Enter] buy" });
        self.stickyList(inner, view.board_header, board.items, 0, self.focus == 0);

        const cw: u16 = if (self.narrow()) b.w else b.w * 55 / 100;
        var cat: std.ArrayListUnmanaged([]const u8) = .empty;
        for (view.catalog) |r| try cat.append(al, r.text);
        const inner2 = self.screen.pane(.{ .x = b.x, .y = b.y + top_h, .w = cw, .h = b.h - top_h }, .{ .title = try std.fmt.allocPrint(al, "ORDER CATALOG · delivered to {s}", .{q.hqName(g, hq_id)}), .focused = self.focus == 1, .right_title = "[Enter] order  [b] fabricate" });
        self.stickyList(inner2, view.catalog_header, cat.items, 1, self.focus == 1);
        if (cw < b.w) {
            var dem: std.ArrayListUnmanaged([]const u8) = .empty;
            for (view.demand) |r| try dem.append(al, r.text);
            if (view.demand.len == 0) try dem.append(al, "{g}nothing damaged{/}");
            const inner3 = self.screen.pane(.{ .x = b.x + cw, .y = b.y + top_h, .w = b.w - cw, .h = b.h - top_h }, .{ .title = "DEMAND · damaged slots", .focused = self.focus == 2, .right_title = "[Enter] order shortfall" });
            self.stickyList(inner3, view.demand_header, dem.items, 2, self.focus == 2);
        }
    }

    /// A list with its header row pinned above the scrolling rows.
    fn stickyList(self: *App, inner: Rect, header: []const u8, items: []const []const u8, pane_idx: u8, focused: bool) void {
        if (inner.h == 0) return;
        self.screen.textPad(inner.x, inner.y, inner.w, header, .dim);
        const body_r: Rect = .{ .x = inner.x, .y = inner.y + 1, .w = inner.w, .h = inner.h - 1 };
        const c = self.cur(pane_idx);
        if (items.len > 0 and c.* >= items.len) c.* = items.len - 1;
        self.screen.lines(body_r, items, firstRow(c.*, body_r.h), if (focused and items.len > 0) c.* else null);
    }

    // ---- people ----

    fn drawPeople(self: *App) !void {
        const al = self.a();
        const g = &self.gs.?;
        const b = self.body();
        const view = try q.people(al, g, self.people_filter);
        var rows: std.ArrayListUnmanaged([]const u8) = .empty;
        for (view.rows) |r| try rows.append(al, r.text);
        if (view.rows.len == 0) try rows.append(al, "{d}nobody matches this filter{/}");
        const lw: u16 = if (b.w > 150) @max(b.w * 62 / 100, @min(b.w - 60, 128)) else b.w;
        const title = try std.fmt.allocPrint(al, "PERSONNEL · filter {{a}}{s}{{/}} · {d} of {d}", .{ @tagName(self.people_filter), view.rows.len, view.total });
        const inner = self.screen.pane(.{ .x = b.x, .y = b.y, .w = lw, .h = b.h }, .{ .title = title, .focused = true, .right_title = "[/] next filter  [?] previous" });
        const c = self.cur(0);
        self.stickyList(inner, view.header, rows.items, 0, view.rows.len > 0);
        if (lw < b.w and view.rows.len > 0) {
            const id = view.rows[c.*].id;
            const rec = try q.personRecord(al, g, id);
            const rec_h: u16 = b.h * 3 / 5;
            self.listPane(.{ .x = b.x + lw, .y = b.y, .w = b.w - lw, .h = rec_h }, "RECORD", rec, 1, false, false);
            const seats = try q.openSeats(al, g, id);
            var st: std.ArrayListUnmanaged([]const u8) = .empty;
            for (seats) |s| try st.append(al, s.text);
            if (seats.len == 0) try st.append(al, "{d}no open seat for this role right now{/}");
            try st.append(al, "");
            try st.append(al, "{d}[a] assign to a seat  [t] train  [P] post to HQ  [x] transfer  [L] leave  [D] fire{/}");
            self.listPane(.{ .x = b.x + lw, .y = b.y + rec_h, .w = b.w - lw, .h = b.h - rec_h }, "OPEN SEATS", st.items, 2, false, false);
        }
    }

    fn selectedPerson(self: *App) !?types.PersonId {
        const view = try q.people(self.a(), &self.gs.?, self.people_filter);
        if (view.rows.len == 0) return null;
        return view.rows[@min(self.cur(0).*, view.rows.len - 1)].id;
    }

    /// Change the emblem on every company (the crest is outfit-wide).
    fn applyEmblem(self: *App, image: []const u8) !void {
        const g = &self.gs.?;
        var ids: std.ArrayListUnmanaged(types.ForceId) = .empty;
        var fit = g.forces.iterator();
        while (fit.next()) |e| if (e.value_ptr.echelon == .company) try ids.append(self.a(), e.value_ptr.id);
        for (ids.items) |id| try self.exec(.{ .set_emblem = .{ .force = id, .image = image } });
        self.refreshEmblem();
    }

    // ---- map ----

    const MapGeom = struct {
        inner: Rect,
        min_x: i32,
        max_y: i32,
        sx: f64, // LY per column
        sy: f64, // LY per row

        fn cell(self: MapGeom, x: i32, y: i32) [2]i32 {
            const cx = @as(f64, @floatFromInt(self.inner.x)) + @as(f64, @floatFromInt(x - self.min_x)) / self.sx;
            const cy = @as(f64, @floatFromInt(self.inner.y)) + @as(f64, @floatFromInt(self.max_y - y)) / self.sy;
            return .{ @intFromFloat(@floor(cx)), @intFromFloat(@floor(cy)) };
        }

        fn inside(self: MapGeom, c: [2]i32) bool {
            return c[0] >= self.inner.x and c[0] < self.inner.x + self.inner.w and c[1] >= self.inner.y and c[1] < self.inner.y + self.inner.h;
        }
    };

    fn mapGeom(view: q.Map, inner: Rect) MapGeom {
        var min_x: i32 = std.math.maxInt(i32);
        var max_x: i32 = std.math.minInt(i32);
        var min_y: i32 = std.math.maxInt(i32);
        var max_y: i32 = std.math.minInt(i32);
        for (view.worlds) |w| {
            min_x = @min(min_x, w.x);
            max_x = @max(max_x, w.x);
            min_y = @min(min_y, w.y);
            max_y = @max(max_y, w.y);
        }
        min_x -= 6;
        max_x += 6;
        min_y -= 6;
        max_y += 6;
        const usable_w: f64 = @floatFromInt(@max(20, @as(i32, inner.w) - 16)); // room for names
        const usable_h: f64 = @floatFromInt(@max(6, @as(i32, inner.h) - 2));
        var sx: f64 = @as(f64, @floatFromInt(max_x - min_x)) / usable_w;
        var sy: f64 = @as(f64, @floatFromInt(max_y - min_y)) / usable_h;
        // keep the 2:1 cell aspect so rings stay round
        if (sy < 2 * sx) sy = 2 * sx else sx = sy / 2;
        return .{ .inner = inner, .min_x = min_x, .max_y = max_y, .sx = sx, .sy = sy };
    }

    fn drawMap(self: *App) !void {
        const al = self.a();
        const g = &self.gs.?;
        const s = &self.screen;
        const b = self.body();
        const view = try q.map(al, g);
        if (view.worlds.len == 0) return;
        if (self.map_cursor >= view.worlds.len) self.map_cursor = 0;
        const mw: u16 = if (b.w > 120) b.w * 3 / 4 else b.w;
        const inner = s.pane(.{ .x = b.x, .y = b.y, .w = mw, .h = b.h }, .{ .title = "STAR MAP", .focused = true, .right_title = try std.fmt.allocPrint(al, "{d} worlds · {d} in ring · {d} beachhead · {d} dark", .{ view.worlds.len, view.in_ring, view.in_band, view.dark }) });
        const geom = mapGeom(view, inner);
        // rings and beachhead bands
        for (view.hqs) |h| {
            var k: usize = 0;
            while (k < 720) : (k += 1) {
                const ang = @as(f64, @floatFromInt(k)) * std.math.pi / 360.0;
                const rr: f64 = @floatFromInt(h.ring_ly);
                const bb: f64 = @floatFromInt(h.ring_ly + view.band_ly);
                const c1 = geom.cell(h.x + @as(i32, @intFromFloat(rr * @cos(ang))), h.y + @as(i32, @intFromFloat(rr * @sin(ang))));
                if (geom.inside(c1)) s.put(c1[0], c1[1], '.', .dim);
                const c2 = geom.cell(h.x + @as(i32, @intFromFloat(bb * @cos(ang))), h.y + @as(i32, @intFromFloat(bb * @sin(ang))));
                if (geom.inside(c2)) s.put(c2[0], c2[1], ',', .dim);
            }
        }
        for (view.worlds, 0..) |w, i| {
            const c = geom.cell(w.x, w.y);
            if (!geom.inside(c)) continue;
            const is_cursor = i == self.map_cursor;
            const mark: u21 = if (w.hq_here != .none) '@' else if (is_cursor) '*' else 'o';
            const mst: Style = if (is_cursor) .sel else if (w.hq_here != .none) .amber else if (w.band == .dark) .dim else .normal;
            s.put(c[0], c[1], mark, mst);
            const nst: Style = if (is_cursor) .sel else if (w.band == .dark) .dim else .normal;
            const nw: u16 = @intCast(@max(0, @min(@as(i32, @intCast(w.name.len)), inner.x + inner.w - c[0] - 2)));
            _ = s.text(c[0] + 2, c[1], nw, w.name, nst);
            if (w.worked > 0 and w.hq_here == .none) s.put(c[0] + 3 + @as(i32, nw), c[1], '=', .purple);
            if (w.offers_here > 0) s.put(c[0] + 3 + @as(i32, nw), c[1], '^', .amber);
            if (w.companies_here > 0 and w.hq_here == .none) s.put(c[0] + 3 + @as(i32, nw), c[1], '+', .good);
        }
        if (mw < b.w) {
            s.textPad(inner.x, inner.y + inner.h - 1, inner.w, "{d}@ HQ   * cursor   ^ offers   + company   = worked (HQ can be founded)   . influence ring   , beachhead band   dim = out of reach{/}", .normal);
        } else {
            const w = view.worlds[self.map_cursor];
            s.textPad(inner.x, inner.y + inner.h - 1, inner.w, try std.fmt.allocPrint(al, "{{a}}{s}{{/}} {s} · ind {d} · {d} LY · {s} · {d} offers  {{d}}[f] found [o] board{{/}}", .{
                w.name,        w.faction, w.industry, w.dist_ly,
                switch (w.band) {
                    .ring => "{g}in ring{/}",
                    .beachhead => "{a}beachhead{/}",
                    .dark => "{d}out of reach{/}",
                },
                w.offers_here,
            }), .normal);
        }

        if (mw < b.w) {
            const w = view.worlds[self.map_cursor];
            var rows: std.ArrayListUnmanaged([]const u8) = .empty;
            try rows.append(al, try std.fmt.allocPrint(al, "{{a}}{s}{{/}}   {s} · industry {d}", .{ w.name, w.faction, w.industry }));
            try rows.append(al, "");
            for (view.hqs) |h| {
                const hp = game.planet.find(g.hqs.getPtr(h.id).?.planet_key).?;
                const wp = game.planet.find(w.key).?;
                const d = game.planet.distanceLy(wp, hp);
                const band: []const u8 = if (d <= h.ring_ly) "{g}inside ring{/}" else if (d <= h.ring_ly + view.band_ly) "{a}beachhead band{/}" else "{d}out of reach{/}";
                try rows.append(al, try std.fmt.allocPrint(al, "{d: >4} LY · {d} jumps from {s}  {s}", .{ d, game.planet.jumpsBetween(wp, hp), q.clip(h.name, 22), band }));
            }
            try rows.append(al, "");
            if (w.hq_here != .none) try rows.append(al, try std.fmt.allocPrint(al, "HQ here      {{a}}{s}{{/}}", .{q.hqName(g, w.hq_here)}));
            try rows.append(al, try std.fmt.allocPrint(al, "companies    {d} here", .{w.companies_here}));
            if (w.worked > 0) try rows.append(al, try std.fmt.allocPrint(al, "history      {{p}}{d} contract{s} worked here{{/}} · an HQ can be founded (F4 History lists them)", .{ w.worked, if (w.worked == 1) "" else "s" }));
            try rows.append(al, try std.fmt.allocPrint(al, "local supply {s}", .{switch (w.band) {
                .ring => "×1.0 (in ring)",
                .beachhead => "{a}×2.5{/} (beachhead)",
                .dark => "{c}×4.0{/} (out of reach)",
            }}));
            try rows.append(al, "");
            try rows.append(al, "offers here");
            const offers = try q.offersAt(al, g, w.key);
            if (offers.len == 0) try rows.append(al, "  {d}none{/}");
            for (offers) |o| try rows.append(al, try std.fmt.allocPrint(al, "  {s}", .{o}));
            try rows.append(al, "");
            try rows.append(al, "{d}[f] found HQ here  [o] contract board{/}");
            const side_h: u16 = b.h * 3 / 5;
            self.listPane(.{ .x = b.x + mw, .y = b.y, .w = b.w - mw, .h = side_h }, "WORLD", rows.items, 1, false, false);
            var reach: std.ArrayListUnmanaged([]const u8) = .empty;
            try reach.append(al, try std.fmt.allocPrint(al, "in ring         {d} worlds", .{view.in_ring}));
            try reach.append(al, try std.fmt.allocPrint(al, "beachhead band  {d} worlds  {{a}}×1.3 pay{{/}}", .{view.in_band}));
            try reach.append(al, try std.fmt.allocPrint(al, "out of reach    {d} worlds", .{view.dark}));
            try reach.append(al, "");
            for (view.hqs) |h| try reach.append(al, try std.fmt.allocPrint(al, "{s}  ring {d} LY (+{d} band)", .{ q.clip(h.name, 24), h.ring_ly, view.band_ly }));
            try reach.append(al, "");
            try reach.append(al, "{d}rings grow with comms and spaceport levels{/}");
            self.listPane(.{ .x = b.x + mw, .y = b.y + side_h, .w = b.w - mw, .h = b.h - side_h }, "REACH", reach.items, 2, false, false);
        }
    }

    /// Move the map cursor to the nearest world in a direction.
    fn mapMove(self: *App, dx: i32, dy: i32) !void {
        const view = try q.map(self.a(), &self.gs.?);
        if (view.worlds.len == 0) return;
        const cur_w = view.worlds[@min(self.map_cursor, view.worlds.len - 1)];
        var best: ?usize = null;
        var best_score: i64 = std.math.maxInt(i64);
        for (view.worlds, 0..) |w, i| {
            if (i == self.map_cursor) continue;
            const ddx: i64 = w.x - cur_w.x;
            const ddy: i64 = w.y - cur_w.y;
            const along: i64 = ddx * dx + ddy * dy;
            if (along <= 0) continue;
            const across: i64 = if (dx != 0) ddy else ddx;
            const score = along * along + 4 * across * across;
            if (score < best_score) {
                best_score = score;
                best = i;
            }
        }
        if (best) |i| self.map_cursor = i;
    }

    // ---- lab ----

    fn drawLab(self: *App) !void {
        const al = self.a();
        const g = &self.gs.?;
        const b = self.body();
        const meks = try q.labMeks(al, g);
        if (meks.len == 0) {
            const rows = [_][]const u8{"{d}no meks to work on{/}"};
            self.listPane(b, "LAB", &rows, 0, false, false);
            return;
        }
        if (self.lab_sel >= meks.len) self.lab_sel = 0;
        const view = try q.lab(al, g, meks[self.lab_sel]);
        const lw: u16 = if (self.narrow()) 0 else @max(30, b.w * 3 / 10);
        const mw: u16 = if (self.narrow()) b.w * 3 / 5 else @max(40, b.w * 7 / 20);
        if (lw > 0) self.listPane(.{ .x = b.x, .y = b.y, .w = lw, .h = b.h }, view.title, view.budget, 1, false, false);
        var mounts: std.ArrayListUnmanaged([]const u8) = .empty;
        for (view.mounts) |m| try mounts.append(al, m.text);
        if (view.mounts.len == 0) try mounts.append(al, "{d}no mounts{/}");
        self.listPane(.{ .x = b.x + lw, .y = b.y, .w = mw, .h = b.h }, try std.fmt.allocPrint(al, "MOUNTS · hull {d} of {d}", .{ self.lab_sel + 1, meks.len }), mounts.items, 0, true, true);
        self.listPane(.{ .x = b.x + lw + mw, .y = b.y, .w = b.w - lw - mw, .h = b.h }, if (view.legal) "PLAN" else "PLAN · {c}illegal{/}", view.plan, 2, false, false);
    }

    fn labUnit(self: *App) !?types.UnitId {
        const meks = try q.labMeks(self.a(), &self.gs.?);
        if (meks.len == 0) return null;
        if (self.lab_sel >= meks.len) self.lab_sel = 0;
        return meks[self.lab_sel];
    }

    fn drawDesk(self: *App) !void {
        const al = self.a();
        const g = &self.gs.?;
        const b = self.body();
        const view = try q.desk(al, g, 40);

        const top_h: u16 = @max(8, b.h * 2 / 5);
        const emblem_w: u16 = if (b.w >= 160) 44 else 0;
        const rest_w: u16 = b.w - emblem_w;
        const cl_w: u16 = rest_w / 2;
        const ib_w: u16 = rest_w - cl_w;
        var x: u16 = b.x;
        if (emblem_w > 0) {
            const inner = self.screen.pane(.{ .x = x, .y = b.y, .w = emblem_w, .h = top_h }, .{ .title = q.clip(g.outfit_name, 36) });
            if (!self.drawEmblem(inner)) {
                var art: std.ArrayListUnmanaged([]const u8) = .empty;
                try art.append(al, "");
                const e = self.emblemFor(g);
                for (e.art) |line| try art.append(al, try std.fmt.allocPrint(al, "        {{p}}{s}{{/}}", .{line}));
                try art.append(al, "");
                try art.append(al, try std.fmt.allocPrint(al, "  {{d}}{s}{{/}}", .{e.name}));
                try art.append(al, "");
                try art.append(al, "  {d}import a picture in the wizard's{/}");
                try art.append(al, "  {d}emblem step to show a crest here{/}");
                self.screen.lines(inner, art.items, 0, null);
            }
            x += emblem_w;
        }
        var cl: std.ArrayListUnmanaged([]const u8) = .empty;
        for (view.checklist) |w| {
            try cl.append(al, try std.fmt.allocPrint(al, "{s} {s}   {{d}}→ {s}{{/}}", .{ if (w.blocking) "{c}!{/}" else "{a}·{/}", w.text, tab_names[w.jump] }));
        }
        if (view.checklist.len == 0) try cl.append(al, "{g}all clear{/} — nothing blocks the turn");
        self.listPane(.{ .x = x, .y = b.y, .w = cl_w, .h = top_h }, "END-TURN CHECKLIST", cl.items, 0, self.focus == 0, true);
        x += cl_w;
        var ib: std.ArrayListUnmanaged([]const u8) = .empty;
        var ib_index: std.ArrayListUnmanaged(usize) = .empty;
        for (view.inbox, 0..) |it, i| {
            const mk: []const u8 = if (it.days_left <= 1) "{c}" else "{a}";
            try ib.append(al, try std.fmt.allocPrint(al, "> {{a}}{s}{{/}} · {s} · {s}{d} days left{{/}}", .{ it.kind, it.company, mk, it.days_left }));
            try ib_index.append(al, i);
            for (it.options, 0..) |o, oi| {
                try ib.append(al, try std.fmt.allocPrint(al, "    {d}  {s}{s}", .{ oi + 1, o, if (oi == it.default_choice) "   {d}default{/}" else "" }));
                try ib_index.append(al, i);
            }
            try ib.append(al, "");
            try ib_index.append(al, i);
        }
        if (view.inbox.len == 0) try ib.append(al, "{d}nothing pending{/}");
        self.listPane(.{ .x = x, .y = b.y, .w = ib_w, .h = top_h }, "INBOX", ib.items, 1, self.focus == 1, true);

        const co_h: u16 = @min(b.h - top_h, @as(u16, @intCast(view.companies.len + 3)));
        var co: std.ArrayListUnmanaged([]const u8) = .empty;
        try co.append(al, view.company_header);
        for (view.companies) |c| try co.append(al, c);
        self.listPane(.{ .x = b.x, .y = b.y + top_h, .w = b.w, .h = co_h }, "COMPANIES", co.items, 2, false, false);

        const rest_h: u16 = b.h - top_h - co_h;
        if (rest_h >= 3) {
            const log_w: u16 = if (self.narrow()) b.w else b.w * 3 / 5;
            self.listPane(.{ .x = b.x, .y = b.y + top_h + co_h, .w = log_w, .h = rest_h }, "LOG", view.log, 2, self.focus == 2, true);
            if (log_w < b.w) self.listPane(.{ .x = b.x + log_w, .y = b.y + top_h + co_h, .w = b.w - log_w, .h = rest_h }, "HQs", view.hqs, 3, false, false);
        }
    }

    fn emblemFor(self: *App, g: *GameState) Emblem {
        _ = self;
        var fit = g.forces.iterator();
        while (fit.next()) |e| {
            if (e.value_ptr.emblem) |img| {
                for (emblems) |em| if (std.mem.eql(u8, em.name, img)) return em;
            }
        }
        return emblems[0];
    }

    fn drawContracts(self: *App) !void {
        const al = self.a();
        const g = &self.gs.?;
        const b = self.body();
        const view = try q.contracts(al, g);
        const board_h: u16 = @max(6, b.h * 2 / 5);
        var rows: std.ArrayListUnmanaged([]const u8) = .empty;
        try rows.append(al, view.board_header);
        for (view.board) |o| try rows.append(al, o.text);
        if (view.board.len == 0) try rows.append(al, "{d}no offers — the board refreshes on the 1st{/}");
        try rows.append(al, "");
        try rows.append(al, view.notes);
        const inner = self.screen.pane(.{ .x = b.x, .y = b.y, .w = b.w, .h = board_h }, .{ .title = "CONTRACT BOARD", .focused = self.focus == 0, .right_title = "[Enter] accept with a company" });
        const c = self.cur(0);
        if (view.board.len > 0 and c.* >= view.board.len) c.* = view.board.len - 1;
        self.screen.lines(inner, rows.items, 0, if (self.focus == 0 and view.board.len > 0) c.* + 1 else null);

        var act: std.ArrayListUnmanaged([]const u8) = .empty;
        var act_index: std.ArrayListUnmanaged(usize) = .empty;
        for (view.active, 0..) |ar, i| {
            for (ar.lines) |l| {
                try act.append(al, l);
                try act_index.append(al, i);
            }
        }
        if (view.active.len == 0) try act.append(al, "{d}no active contracts{/}");
        const wide = b.w > 140;
        const act_w: u16 = if (wide) b.w * 3 / 5 else b.w;
        const history = try q.contractHistory(al, g);
        const c2 = self.cur(2);
        if (history.len > 0 and c2.* >= history.len) c2.* = history.len - 1;
        // Narrow: the active list gives up its lower part to the history.
        const act_h: u16 = if (wide) b.h - board_h else (b.h - board_h) * 3 / 5;
        const c1 = self.cur(1);
        if (view.active.len > 0 and c1.* >= view.active.len) c1.* = view.active.len - 1;
        const inner2 = self.screen.pane(.{ .x = b.x, .y = b.y + board_h, .w = act_w, .h = act_h }, .{ .title = "ACTIVE", .focused = self.focus == 1, .right_title = "[c] complete  [R] recall" });
        var first: usize = 0;
        for (act_index.items, 0..) |ai, li| if (ai == c1.* and first == 0 and li > 0) {
            first = li;
        };
        self.screen.lines(inner2, act.items, if (first + inner2.h > act.items.len and act.items.len > inner2.h) act.items.len - inner2.h else first, if (self.focus == 1 and view.active.len > 0) first else null);

        var hist: std.ArrayListUnmanaged([]const u8) = .empty;
        try hist.append(al, q.history_header);
        for (history) |h| try hist.append(al, h.text);
        if (history.len == 0) try hist.append(al, "{d}no closed contracts yet — completed, breached and failed contracts land here, and an HQ can be founded on any world worked{/}");
        const hist_rect: screen_mod.Rect = if (wide)
            .{ .x = b.x + act_w, .y = b.y + board_h, .w = b.w - act_w, .h = (b.h - board_h) / 2 }
        else
            .{ .x = b.x, .y = b.y + board_h + act_h, .w = b.w, .h = b.h - board_h - act_h };
        const hist_inner = self.screen.pane(hist_rect, .{ .title = "HISTORY", .focused = self.focus == 2, .right_title = "Tab here · log follows the cursor" });
        self.screen.lines(hist_inner, hist.items, if (c2.* + 2 > hist_inner.h and hist_inner.h > 1) c2.* + 2 - hist_inner.h else 0, if (self.focus == 2 and history.len > 0) c2.* + 1 else null);

        if (wide) {
            // The log follows whichever contract the cursor is on: an active one, or a closed one in the history.
            const log_id: types.ContractId = if (self.focus == 2 and history.len > 0) history[c2.*].id else if (view.active.len > 0) view.active[c1.*].id else .none;
            const log = if (log_id != .none) try q.battleLog(al, g, log_id, 40) else &[_][]const u8{"{d}no contract under the cursor{/}"};
            self.listPane(.{ .x = b.x + act_w, .y = b.y + board_h + hist_rect.h, .w = b.w - act_w, .h = b.h - board_h - hist_rect.h }, "CONTRACT LOG", log, 3, false, false);
        }
    }

    fn drawLedger(self: *App) !void {
        const al = self.a();
        const g = &self.gs.?;
        const b = self.body();
        const all = try q.allTreasuries(al, g);
        if (self.ledger_sel >= all.len) self.ledger_sel = 0;
        const view = try q.ledger(al, g, all[self.ledger_sel], 31, 200);
        const tw: u16 = if (self.narrow()) b.w * 2 / 5 else @max(30, b.w / 4);
        const pw: u16 = if (self.narrow()) 0 else @max(30, b.w * 3 / 10);
        var rows: std.ArrayListUnmanaged([]const u8) = .empty;
        for (view.treasuries) |t| try rows.append(al, t.text);
        try rows.append(al, "");
        for (view.extras) |e| try rows.append(al, e);
        const inner = self.screen.pane(.{ .x = b.x, .y = b.y, .w = tw, .h = b.h }, .{ .title = "TREASURIES", .focused = self.focus == 0, .right_title = "[t] transfer [p] policy" });
        self.screen.lines(inner, rows.items, 0, if (self.focus == 0) self.ledger_sel else null);
        if (pw > 0) self.listPane(.{ .x = b.x + tw, .y = b.y, .w = pw, .h = b.h }, view.pnl_title, view.pnl, 1, false, false);
        var led: std.ArrayListUnmanaged([]const u8) = .empty;
        try led.append(al, view.ledger_header);
        for (view.ledger) |l| try led.append(al, l);
        self.listPane(.{ .x = b.x + tw + pw, .y = b.y, .w = b.w - tw - pw, .h = b.h }, "LEDGER", led.items, 2, self.focus == 1, true);
    }

    fn drawForces(self: *App) !void {
        const al = self.a();
        const g = &self.gs.?;
        const b = self.body();
        const rows = try q.toe(al, g);
        var texts: std.ArrayListUnmanaged([]const u8) = .empty;
        for (rows) |r| try texts.append(al, r.text);
        const lw: u16 = if (b.w > 120) b.w * 45 / 100 else b.w;
        self.listPane(.{ .x = b.x, .y = b.y, .w = lw, .h = b.h }, "TO&E", texts.items, 0, self.focus == 0, true);
        if (lw < b.w) {
            const c = self.cur(0).*;
            const detail_h: u16 = b.h * 3 / 5;
            if (rows.len > 0 and c < rows.len and rows[c].unit != .none) {
                const detail = try q.hull(al, g, rows[c].unit);
                self.listPane(.{ .x = b.x + lw, .y = b.y, .w = b.w - lw, .h = detail_h }, "HULL", detail, 1, false, false);
            } else if (rows.len > 0 and c < rows.len and rows[c].force != .none and g.companyOf(rows[c].force) != .none) {
                const co = g.companyOf(rows[c].force);
                const dmg = try q.companyDamage(al, g, co);
                self.listPane(.{ .x = b.x + lw, .y = b.y, .w = b.w - lw, .h = detail_h }, try std.fmt.allocPrint(al, "DAMAGE · {s}", .{q.forceName(g, co)}), dmg.lines, 1, false, false);
            } else {
                const empty = [_][]const u8{"{d}select a hull in the TO&E{/}"};
                self.listPane(.{ .x = b.x + lw, .y = b.y, .w = b.w - lw, .h = detail_h }, "HULL", &empty, 1, false, false);
            }
            const pool = try q.unassigned(al, g);
            self.listPane(.{ .x = b.x + lw, .y = b.y + detail_h, .w = b.w - lw, .h = b.h - detail_h }, "UNASSIGNED POOL", pool, 2, self.focus == 1, true);
        }
    }

    fn drawSupply(self: *App) !void {
        const al = self.a();
        const g = &self.gs.?;
        const b = self.body();
        const view = try q.supply(al, g);
        const lw: u16 = if (self.narrow()) b.w else b.w * 55 / 100;
        self.listPane(.{ .x = b.x, .y = b.y, .w = lw, .h = b.h }, "SITES", view.rows, 0, true, true);
        if (lw < b.w) {
            const c = self.cur(0).*;
            const site: ?types.Site = if (c < view.site.len) view.site[c] else null;
            const top_h: u16 = b.h / 2;
            if (site) |s| {
                const table = try q.stockTable(al, g, s);
                self.listPane(.{ .x = b.x + lw, .y = b.y, .w = b.w - lw, .h = top_h }, try std.fmt.allocPrint(al, "STOCK · {s}", .{try q.siteLabel(al, g, s)}), table, 1, false, false);
            } else {
                const hint = [_][]const u8{"{d}move the cursor onto a site to see its stock{/}"};
                self.listPane(.{ .x = b.x + lw, .y = b.y, .w = b.w - lw, .h = top_h }, "STOCK", &hint, 1, false, false);
            }
            const inb = try q.inbound(al, g);
            self.listPane(.{ .x = b.x + lw, .y = b.y + top_h, .w = b.w - lw, .h = b.h - top_h }, "INBOUND · soonest first", inb, 2, false, false);
        }
    }

    /// The site under the Supply cursor, if the row belongs to one.
    fn supplySite(self: *App) !?types.Site {
        const view = try q.supply(self.a(), &self.gs.?);
        const c = self.cur(0).*;
        if (c >= view.site.len) return null;
        return view.site[c];
    }

    fn homeHqOf(self: *App, company: types.ForceId) u32 {
        const g = &self.gs.?;
        const id = g.homeHqFor(company);
        return if (id != .none) @intFromEnum(id) else self.hqSelId(g);
    }

    fn drawHq(self: *App) !void {
        const al = self.a();
        const g = &self.gs.?;
        const b = self.body();
        var ids: std.ArrayListUnmanaged(types.HqId) = .empty;
        var hit = g.hqs.iterator();
        while (hit.next()) |e| try ids.append(al, e.value_ptr.id);
        if (ids.items.len == 0) return;
        if (self.hq_sel >= ids.items.len) self.hq_sel = 0;
        const id = ids.items[self.hq_sel];
        const h = g.hqs.getPtr(id).?;
        const detail = try q.hqDetail(al, g, id);
        const title = try std.fmt.allocPrint(al, "hq:{d} {s} · {s} · ring {d} LY · funds {s} · staff {d}/{d}", .{ @intFromEnum(id), h.name, @tagName(h.tier), h.influenceLy(), try q.money(al, h.funds), h.staff_assigned, h.staffRequired().total() });
        const lw: u16 = if (b.w > 150) b.w * 45 / 100 else b.w;
        const top_h: u16 = if (lw < b.w) b.h else b.h * 3 / 5;
        const inner = self.screen.pane(.{ .x = b.x, .y = b.y, .w = lw, .h = top_h }, .{ .title = title, .focused = self.focus == 0, .right_title = "[ ] switch HQ  [u] upgrade  [S] autostaff" });
        self.screen.lines(inner, detail, firstRow(self.cur(0).*, inner.h), if (self.focus == 0) self.cur(0).* else null);

        const hallv = try q.hall(al, g, id, self.hall_filter);
        var rows: std.ArrayListUnmanaged([]const u8) = .empty;
        try rows.append(al, hallv.header);
        for (hallv.rows) |r| try rows.append(al, r.text);
        if (hallv.rows.len == 0) try rows.append(al, if (hallv.total_at_hq == 0) "{d}no candidates today — the hall churns daily{/}" else "{d}no candidates match this filter{/}");
        const hall_title = try std.fmt.allocPrint(al, "HIRING HALL · filter {{a}}{s}{{/}} · {d} of {d}", .{ @tagName(self.hall_filter), hallv.rows.len, hallv.total_at_hq });
        const hr: Rect = if (lw < b.w) .{ .x = b.x + lw, .y = b.y, .w = b.w - lw, .h = b.h } else .{ .x = b.x, .y = b.y + top_h, .w = b.w, .h = b.h - top_h };
        const hinner = self.screen.pane(hr, .{ .title = hall_title, .focused = self.focus == 1, .right_title = "[f] next filter  [F] previous  [Enter] hire" });
        const c = self.cur(1);
        if (hallv.rows.len > 0 and c.* >= hallv.rows.len) c.* = hallv.rows.len - 1;
        self.screen.lines(hinner, rows.items, firstRow(c.* + 1, hinner.h), if (self.focus == 1 and hallv.rows.len > 0) c.* + 1 else null);
    }

    // ---- modals ----

    fn modalRect(self: *App, w: u16, h: u16) Rect {
        const s = &self.screen;
        const ww = @min(w, s.cols);
        const hh = @min(h, s.rows);
        return .{ .x = (s.cols - ww) / 2, .y = (s.rows - hh) / 2, .w = ww, .h = hh };
    }

    fn drawModal(self: *App) !void {
        const al = self.a();
        switch (self.modal) {
            .none => {},
            .help => {
                const rows = [_][]const u8{
                    "",
                    "  {a}screens{/}     F1-F8 or 1-8 · Tab / Shift-Tab cycles panes · j/k or arrows move the cursor",
                    "  {a}turn{/}        n ends the turn (the checklist opens first) · N ends 7 turns",
                    "  {a}desk{/}        Enter on an inbox row opens the decision · Enter on a checklist row jumps to its screen",
                    "  {a}contracts{/}   Enter accepts the offer under the cursor · c completes · R recalls",
                    "  {a}ledger{/}      j/k picks the treasury · t transfer · p policy · L loan",
                    "  {a}forces{/}      a assign · u unassign · A auto-assign the company · t train · cursor on a company = DAMAGE pane (struct = depot, gear = field) · b fabricates the shortest comp_*",
                    "  {a}hq{/}          [ ] switch HQ · u upgrade · S autostaff · h hire · f/F hall filter",
                    "  {a}people{/}      / filter · m admit wounded · t train · a assign seat · P post · x transfer · L leave · D fire",
                    "  {a}market{/}      F10/0: / , filter (mechs, vehicles, aero, dropships, jumpships, weapons, ammo, equipment, components, supplies)",
                    "               boards (Enter buys) · catalog (Enter orders, b fabricates comp_*) · demand (Enter orders shortfall)",
                    "  {a}lab{/}         + picks a part then a location (green = rules allow) · R orders a replacement for damaged gear · dim rows = full",
                    "  {a}structure{/}   not fitted in the Lab: D (Lab) or d (Forces) sends the hull to the depot; the bay consumes comp_* parts from the home HQ",
                    "  {a}companies{/}   :newco <name> at the first HQ · :newco@ hq:N <name> · :assignco co:N hq:M — each regional HQ hosts one combat company",
                    "  {a}money{/}       Ledger: L loan (simple interest) · R repay · Forces: $ sell hull · X disband company · HQ: $ sell HQ",
                    "  {a}field cash{/}  t courier cash out · T courier cash back to the outfit · p policy = keep above a floor, checked daily, cap per month",
                    "  {a}resupply{/}    P policy `supplypolicy co:N days tons [battles]` — provisions under D days → ship N t; ammo per family sized to the link (or [battles])",
                    "  {a}sell stock{/}  $ on a Supply HQ row → `sellstock hq:N part qty` — half catalogue value (40% for comp_*) into the HQ treasury; never under a keep-stocked minimum",
                    "  {a}warehouse{/}   K `stockpolicy hq:N part min [target]` (Supply on an HQ, Market on a catalogue row) — under min → order/fabricate to target, daily · target 0 removes",
                    "  {a}medbay{/}      Settings (F12 or :settings) → a: auto-admit the wounded every morning, or `:autoadmit on|off`",
                    "  {a}turn rules{/}  wounded must be admitted (m) and a negative treasury covered before the day can end; bankruptcy ends the game",
                    "  {a}reputation{/}  every offer's pay × (1 + rep × 0.5%), clamped 0.8–1.3, and more offers per board · complete +1 (+VP) · breach −2 · decisions show their rep effect",
                    "  {a}emblem{/}      e on the Desk (or :emblem) changes the crest: presets or a PNG from ./, logos/, docs/logos/",
                    "  {a}command{/}     : opens the command line — every CLI verb works: day, transfer, order, accept, …",
                    "  {a}leave{/}       q returns to the welcome screen (save / discard / stay)",
                    "",
                    "  {d}[Esc] close{/}",
                };
                const r = self.modalRect(134, 28);
                const inner = self.screen.pane(r, .{ .title = "HELP", .double = true });
                self.screen.lines(inner, &rows, 0, null);
            },
            .end_turn => {
                const g = &self.gs.?;
                const view = try q.desk(al, g, 0);
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                try rows.append(al, "");
                try rows.append(al, try std.fmt.allocPrint(al, "  {d} things on your desk before day {d}:", .{ view.checklist.len, g.clock.day_index + 1 }));
                try rows.append(al, "");
                for (view.checklist, 0..) |w, i| {
                    try rows.append(al, try std.fmt.allocPrint(al, "  {s} {s}   {{d}}→ [{d}] {s}{{/}}", .{ if (w.blocking) "{c}!{/}" else "{a}·{/}", w.text, i + 1, tab_names[w.jump] }));
                }
                try rows.append(al, "");
                try rows.append(al, "  {s} [n] end the turn anyway {/}    {d}[N] end 7 turns · [Esc] back{/}");
                const r = self.modalRect(100, @intCast(@min(rows.items.len + 3, 40)));
                const inner = self.screen.pane(r, .{ .title = "END TURN?", .double = true });
                self.screen.lines(inner, rows.items, 0, null);
            },
            .quit => {
                const g = &self.gs.?;
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                try rows.append(al, "");
                try rows.append(al, try std.fmt.allocPrint(al, "  campaign {{a}}{s}{{/}} · day {d}{s}", .{ g.outfit_name, g.clock.day_index, if (g.campaign_id == 0) " · {c}never saved{/}" else "" }));
                try rows.append(al, "");
                try rows.append(al, "  {s} [s] save and return {/}");
                try rows.append(al, "    [r] return without saving");
                try rows.append(al, "    [Esc] stay in the campaign");
                const r = self.modalRect(60, 9);
                const inner = self.screen.pane(r, .{ .title = "RETURN TO WELCOME?", .double = true });
                self.screen.lines(inner, rows.items, 0, null);
            },
            .decision => |idx| {
                const g = &self.gs.?;
                const view = try q.desk(al, g, 0);
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                var found = false;
                for (view.inbox) |it| {
                    if (it.event_index != idx) continue;
                    found = true;
                    try rows.append(al, "");
                    try rows.append(al, try std.fmt.allocPrint(al, "  {{a}}{s}{{/}} · {s} · defaults on day {d} ({d} days)", .{ it.kind, it.company, it.deadline_day, it.days_left }));
                    try rows.append(al, "");
                    try rows.append(al, try std.fmt.allocPrint(al, "  {s}", .{it.description}));
                    try rows.append(al, "");
                    for (it.options, 0..) |o, oi| {
                        try rows.append(al, try std.fmt.allocPrint(al, "    [{d}] {s}{s}", .{ oi + 1, o, if (oi == it.default_choice) "   {d}default{/}" else "" }));
                    }
                    try rows.append(al, "");
                    try rows.append(al, "  {d}press the option number · [Esc] decide later{/}");
                }
                if (!found) try rows.append(al, "  {d}this decision has been resolved{/}");
                const r = self.modalRect(90, @intCast(@min(rows.items.len + 2, 30)));
                const inner = self.screen.pane(r, .{ .title = "DECISION", .double = true });
                self.screen.lines(inner, rows.items, 0, null);
            },
            .lance_pick => |uid| {
                const lances = try self.lanceChoices(uid);
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                for (lances) |lc| try rows.append(al, lc.text);
                if (lances.len == 0) try rows.append(al, "{d}no lances — the hull must belong to a company that is home{/}");
                if (self.modal_cursor >= lances.len and lances.len > 0) self.modal_cursor = lances.len - 1;
                const r = self.modalRect(84, @intCast(@min(rows.items.len + 3, self.screen.rows)));
                const inner = self.screen.pane(r, .{ .title = try std.fmt.allocPrint(al, "MOVE #{d} TO · [Enter] choose · [Esc] cancel", .{@intFromEnum(uid)}), .double = true, .right_title = ":newlance co:N <name> adds a lance" });
                self.screen.lines(inner, rows.items, firstRow(self.modal_cursor, inner.h), if (lances.len > 0) self.modal_cursor else null);
            },
            .upgrade => |hid| {
                const g = &self.gs.?;
                const rows_v = try q.upgrades(al, g, hid);
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                try rows.append(al, "facility         level        cost       paperwork + build   next level buys                              status");
                for (rows_v) |r| try rows.append(al, r.text);
                try rows.append(al, "");
                try rows.append(al, try std.fmt.allocPrint(al, "{{d}}paid from the HQ treasury ({s} C) when the project starts · paperwork is admin_command staffing, +2 days per missing finance admin{{/}}", .{try q.money(al, if (g.hqs.getPtr(hid)) |h| h.funds else 0)}));
                try rows.append(al, "{d}every level raises the staff the HQ must keep on payroll; understaffed HQs run a level lower{/}");
                if (self.modal_cursor >= rows_v.len and rows_v.len > 0) self.modal_cursor = rows_v.len - 1;
                const r = self.modalRect(@min(self.screen.cols, 130), @intCast(@min(rows.items.len + 3, self.screen.rows)));
                const inner = self.screen.pane(r, .{ .title = try std.fmt.allocPrint(al, "UPGRADE · {s} · [Enter] start · [Esc] cancel", .{q.hqName(g, hid)}), .double = true });
                self.screen.lines(inner, rows.items, 0, self.modal_cursor + 1);
            },
            .settings => {
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                try rows.append(al, "");
                if (self.music) |*m| {
                    try rows.append(al, try std.fmt.allocPrint(al, "  music        {s}     {{d}}[m] toggle{{/}}", .{if (m.enabled) "{g}on{/}" else "{c}off{/}"}));
                    try rows.append(al, try std.fmt.allocPrint(al, "  volume       {d: >3}      {{d}}[-] [+] (restarts the track){{/}}", .{m.volume}));
                    try rows.append(al, try std.fmt.allocPrint(al, "  now playing  {s}     {{d}}[>] next track{{/}}", .{m.nowPlaying() orelse "—"}));
                    try rows.append(al, try std.fmt.allocPrint(al, "  tracks       {d} in data/music · player: {s}", .{ m.tracks.len, m.player_cmd orelse "{c}none found (afplay, mpv, ffplay, aplay){/}" }));
                } else {
                    try rows.append(al, "  {d}no soundtrack loaded — start without --no-music and keep tracks in data/music/{/}");
                }
                try rows.append(al, "");
                if (self.gs) |*gs| {
                    try rows.append(al, try std.fmt.allocPrint(al, "  medbay       auto-admit the wounded {s}     {{d}}[a] toggle — off: you admit each casualty (m on People) and the turn waits{{/}}", .{if (gs.auto_admit) "{g}on{/} " else "{c}off{/}"}));
                    try rows.append(al, "");
                }
                try rows.append(al, try std.fmt.allocPrint(al, "  graphics     {s} · colour {s} · glyphs {s}", .{ if (self.graphics == .kitty) "kitty protocol" else "half-block", if (self.screen.truecolor) "24-bit" else "256", if (self.screen.ascii) "ascii" else "box-drawing" }));
                try rows.append(al, "");
                try rows.append(al, "  {d}[Esc] close{/}");
                const r = self.modalRect(84, @intCast(rows.items.len + 2));
                const inner = self.screen.pane(r, .{ .title = "SETTINGS", .double = true });
                self.screen.lines(inner, rows.items, 0, null);
            },
            .install_part => |uid| {
                const cands = try q.installCandidates(al, &self.gs.?, uid);
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                for (cands) |c| try rows.append(al, c.text);
                if (self.modal_cursor >= cands.len and cands.len > 0) self.modal_cursor = cands.len - 1;
                const r = self.modalRect(100, @intCast(@min(cands.len + 3, self.screen.rows)));
                const inner = self.screen.pane(r, .{ .title = "INSTALL · pick a part · [Enter] choose location · [Esc] cancel", .double = true, .right_title = "stock at the home HQ first" });
                self.screen.lines(inner, rows.items, firstRow(self.modal_cursor, inner.h), if (cands.len > 0) self.modal_cursor else null);
            },
            .install_loc => |il| {
                const locs = try q.installLocations(al, &self.gs.?, il.unit, il.part);
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                try rows.append(al, try std.fmt.allocPrint(al, "  {{a}}{s}{{/}} — where does it go?", .{il.part}));
                try rows.append(al, "");
                for (locs) |l| try rows.append(al, l.text);
                if (self.modal_cursor >= locs.len and locs.len > 0) self.modal_cursor = locs.len - 1;
                const r = self.modalRect(90, @intCast(@min(rows.items.len + 3, self.screen.rows)));
                const inner = self.screen.pane(r, .{ .title = "INSTALL · pick a location · [Enter] stage · [Esc] back", .double = true });
                self.screen.lines(inner, rows.items, 0, if (locs.len > 0) self.modal_cursor + 2 else null);
            },
            .sell_unit => |uid| {
                const g = &self.gs.?;
                const u = g.unit(uid);
                const rows = [_][]const u8{
                    "",
                    if (u) |uu| try std.fmt.allocPrint(al, "  Sell {{a}}#{d} {s}{{/}} for {{g}}{s}{{/}} C? Half value scaled by condition; the crew goes to the pool.", .{ @intFromEnum(uid), uu.chassis_key, try q.money(al, g.unitSaleValue(uu)) }) else "  no such hull",
                    "",
                    "  {s} [y] sell {/}   {d}[Esc] keep{/}",
                };
                const inner = self.screen.pane(self.modalRect(96, 7), .{ .title = "SELL HULL?", .double = true });
                self.screen.lines(inner, &rows, 0, null);
            },
            .sell_hq => |hid| {
                const g = &self.gs.?;
                const h = g.hqs.getPtr(hid);
                const rows = [_][]const u8{
                    "",
                    if (h) |hh| try std.fmt.allocPrint(al, "  Sell off {{a}}{s}{{/}} for {{g}}{s}{{/}} C (40% of build cost + its treasury)?", .{ hh.name, try q.money(al, g.hqSaleValue(hh) + hh.funds) }) else "  no such HQ",
                    "  Staff posted there become unassigned; its stock, board, bay work and links are lost.",
                    "  Companies must be assigned elsewhere first (:assignco co:N hq:M).",
                    "",
                    "  {s} [y] sell {/}   {d}[Esc] keep{/}",
                };
                const inner = self.screen.pane(self.modalRect(96, 9), .{ .title = "SELL HQ?", .double = true });
                self.screen.lines(inner, &rows, 0, null);
            },
            .disband => |fid| {
                const g = &self.gs.?;
                var value: types.CBills = 0;
                var uit = g.units.iterator();
                while (uit.next()) |e| if (g.companyOf(e.value_ptr.force) == fid) {
                    value += g.unitSaleValue(e.value_ptr);
                };
                const rows = [_][]const u8{
                    "",
                    try std.fmt.allocPrint(al, "  Disband {{a}}{s}{{/}}? Every hull under it sells for about {{g}}{s}{{/}} C and everyone in it is released.", .{ q.forceName(g, fid), try q.money(al, value) }),
                    "  This cannot be undone.",
                    "",
                    "  {s} [y] disband {/}   {d}[Esc] keep{/}",
                };
                const inner = self.screen.pane(self.modalRect(100, 8), .{ .title = "DISBAND COMPANY?", .double = true });
                self.screen.lines(inner, &rows, 0, null);
            },
            .game_over => {
                const g = &self.gs.?;
                const rows = [_][]const u8{
                    "",
                    try std.fmt.allocPrint(al, "  {{c}}{s}{{/}} could not cover its debts on day {d}.", .{ g.outfit_name, g.clock.day_index }),
                    "  Loans are exhausted and nothing left to sell would close the gap. The creditors take the rest.",
                    "",
                    "  The campaign is saved as it ended; delete it from the welcome screen, or keep it as a record.",
                    "",
                    "  {s} [Enter] return to the welcome screen {/}",
                };
                const inner = self.screen.pane(self.modalRect(100, 10), .{ .title = "BANKRUPT — GAME OVER", .double = true });
                self.screen.lines(inner, &rows, 0, null);
            },
            .fire => |id| {
                const g = &self.gs.?;
                const name = try q.personName(al, g, id);
                const rows = [_][]const u8{
                    "",
                    try std.fmt.allocPrint(al, "  Fire {{c}}{s}{{/}}? They leave the outfit today; their seat opens.", .{name}),
                    "",
                    "  {s} [y] fire {/}   {d}[Esc] keep{/}",
                };
                const r = self.modalRect(70, 7);
                const inner = self.screen.pane(r, .{ .title = "FIRE?", .double = true });
                self.screen.lines(inner, &rows, 0, null);
            },
            .seat => |id| {
                const g = &self.gs.?;
                const seats = try q.openSeats(al, g, id);
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                for (seats) |s| try rows.append(al, s.text);
                if (seats.len == 0) try rows.append(al, "{d}no open seat for this role{/}");
                if (self.modal_cursor >= seats.len and seats.len > 0) self.modal_cursor = seats.len - 1;
                const r = self.modalRect(80, @intCast(@min(seats.len + 4, 30)));
                const inner = self.screen.pane(r, .{ .title = try std.fmt.allocPrint(al, "ASSIGN {s} · [Enter] take seat · [Esc] cancel", .{try q.personName(al, g, id)}), .double = true });
                self.screen.lines(inner, rows.items, firstRow(self.modal_cursor, inner.h), if (seats.len > 0) self.modal_cursor else null);
            },
            .emblem => {
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                for (emblems) |e| try rows.append(al, try std.fmt.allocPrint(al, "preset   {s}", .{e.name}));
                for (self.logos) |l| try rows.append(al, try std.fmt.allocPrint(al, "picture  {s}", .{l}));
                const n = rows.items.len;
                if (self.modal_cursor >= n) self.modal_cursor = n - 1;
                const r = self.modalRect(80, @intCast(@min(n + 4, 30)));
                const inner = self.screen.pane(r, .{ .title = "EMBLEM · [Enter] use · [Esc] cancel", .double = true, .right_title = "pictures from ., logos/, docs/logos/" });
                self.screen.lines(inner, rows.items, firstRow(self.modal_cursor, inner.h), self.modal_cursor);
            },
            .hull => |uid| {
                const detail = try q.hull(al, &self.gs.?, uid);
                const r = self.modalRect(@min(self.screen.cols, 100), @intCast(@min(detail.len + 3, self.screen.rows)));
                const inner = self.screen.pane(r, .{ .title = "HULL · [Esc] close", .double = true });
                self.screen.lines(inner, detail, 0, null);
            },
            .record => |pid| {
                const rec = try q.personRecord(al, &self.gs.?, pid);
                const r = self.modalRect(@min(self.screen.cols, 100), @intCast(@min(rec.len + 3, self.screen.rows)));
                const inner = self.screen.pane(r, .{ .title = "RECORD · [Esc] close", .double = true });
                self.screen.lines(inner, rec, 0, null);
            },
            .input => |kind| {
                if (kind == .command) return; // drawn in the footer
                const prompt: []const u8 = switch (kind) {
                    .new_player => "name of the new player",
                    .delete_campaign => "type the outfit name to confirm deletion",
                    .delete_player => "type the player name to confirm deletion (all their campaigns go too)",
                    .accept_company => "company id to send (e.g. 1)",
                    .command => "",
                };
                const rows = [_][]const u8{
                    "",
                    try std.fmt.allocPrint(al, "  {s}", .{prompt}),
                    "",
                    try std.fmt.allocPrint(al, "  > {{s}}{s}_{{/}}", .{self.input.slice()}),
                    "",
                    "  {d}[Enter] confirm · [Esc] cancel{/}",
                };
                const r = self.modalRect(80, 8);
                const inner = self.screen.pane(r, .{ .title = switch (kind) {
                    .new_player => "NEW PLAYER",
                    .delete_campaign => "DELETE CAMPAIGN?",
                    .delete_player => "DELETE PLAYER?",
                    .accept_company => "ACCEPT CONTRACT",
                    .command => "",
                }, .double = true });
                self.screen.lines(inner, &rows, 0, null);
            },
        }
    }

    // ------------------------------------------------------------------ input

    fn handleKey(self: *App, key: Key) !void {
        if (self.modal != .none) return self.handleModalKey(key);
        switch (self.mode) {
            .welcome => try self.handleWelcomeKey(key),
            .wizard => try self.handleWizardKey(key),
            .game => try self.handleGameKey(key),
        }
    }

    fn moveCursor(self: *App, pane: u8, delta: i32, len: usize) void {
        const c = self.cur(pane);
        if (len == 0) {
            c.* = 0;
            return;
        }
        const v: i32 = @as(i32, @intCast(c.*)) + delta;
        c.* = @intCast(@max(0, @min(@as(i32, @intCast(len - 1)), v)));
    }

    fn handleWelcomeKey(self: *App, key: Key) !void {
        const al = self.a();
        const players = try self.store.listPlayers(al);
        const campaigns = try self.store.listCampaignsOf(al, self.player_id);
        switch (key) {
            .tab, .backtab => self.focus = if (self.focus == 0) 1 else 0,
            .down => self.welcomeMove(1, players, campaigns),
            .up => self.welcomeMove(-1, players, campaigns),
            .enter => {
                if (self.focus == 0) {
                    self.focus = 1;
                } else if (campaigns.len > 0) {
                    try self.loadCampaign(campaigns[self.cur(1).*].id);
                }
            },
            .char => |ch| switch (ch) {
                'j' => self.welcomeMove(1, players, campaigns),
                'k' => self.welcomeMove(-1, players, campaigns),
                'q' => self.running = false,
                'n' => {
                    if (self.player_id == 0) {
                        self.say(.amber, "create a player first ([p])", .{});
                    } else {
                        self.mode = .wizard;
                        self.step = .commander;
                        self.w_field = 0;
                    }
                },
                'p' => {
                    self.input.len = 0;
                    self.modal = .{ .input = .new_player };
                },
                'd' => {
                    if (campaigns.len == 0) return;
                    self.input.len = 0;
                    self.modal = .{ .input = .delete_campaign };
                },
                'D' => {
                    if (self.player_id == 0) return;
                    self.input.len = 0;
                    self.modal = .{ .input = .delete_player };
                },
                's' => self.modal = .settings,
                'M' => try self.toggleMusic(),
                '?' => self.modal = .help,
                else => {},
            },
            else => {},
        }
    }

    fn toggleMusic(self: *App) !void {
        const m = &(self.music orelse {
            self.say(.dim, "no soundtrack: put tracks in data/music/ and have afplay, mpv, ffplay or aplay on PATH", .{});
            return;
        });
        m.setEnabled(!m.enabled);
        try self.store.setSetting("music", @intFromBool(m.enabled));
        if (m.enabled) m.poll();
        self.say(.dim, "music {s}", .{if (m.enabled) "on" else "off"});
    }

    fn adjustVolume(self: *App, delta: i32) !void {
        const m = &(self.music orelse return);
        const v: i32 = std.math.clamp(@as(i32, m.volume) + delta, 0, 100);
        m.setVolume(@intCast(v));
        try self.store.setSetting("music_volume", v);
        m.skip(); // restart the current track at the new level
    }

    fn welcomeMove(self: *App, delta: i32, players: []game.store.Store.PlayerInfo, campaigns: []game.store.Store.CampaignInfo) void {
        if (self.focus == 0) {
            self.moveCursor(0, delta, players.len);
            if (players.len > 0) {
                self.player_id = players[self.cur(0).*].id;
                self.cur(1).* = 0;
            }
        } else self.moveCursor(1, delta, campaigns.len);
    }

    fn loadCampaign(self: *App, id: i64) !void {
        const loaded = try self.store.load(self.gpa, id);
        if (self.gs) |*g| g.deinit();
        self.gs = loaded;
        self.mode = .game;
        self.tab = .desk;
        self.focus = 0;
        self.refreshEmblem();
        self.say(.good, "loaded \"{s}\" at day {d}", .{ loaded.outfit_name, loaded.clock.day_index });
    }

    fn handleWizardKey(self: *App, key: Key) !void {
        switch (self.step) {
            .commander => switch (key) {
                .escape => self.mode = .welcome,
                .tab => self.w_field = (self.w_field + 1) % 3,
                .backtab => self.w_field = (self.w_field + 2) % 3,
                .enter => {
                    if (self.w_name.len == 0) {
                        self.say(.amber, "the commander needs a name", .{});
                        return;
                    }
                    self.step = .outfit;
                    self.w_field = 0;
                },
                .backspace => if (self.w_field == 0) self.w_name.pop(),
                .down => self.wizardList(1),
                .up => self.wizardList(-1),
                .char => |ch| {
                    if (self.w_field == 0) {
                        self.w_name.push(ch);
                    } else switch (ch) {
                        'j' => self.wizardList(1),
                        'k' => self.wizardList(-1),
                        else => {},
                    }
                },
                else => {},
            },
            .outfit => switch (key) {
                .escape => {
                    self.step = .commander;
                    self.w_field = 0;
                },
                .tab => self.w_field = (self.w_field + 1) % 3,
                .backtab => self.w_field = (self.w_field + 2) % 3,
                .enter => {
                    if (self.w_outfit.len == 0 or self.w_company.len == 0) {
                        self.say(.amber, "the outfit and its first company need names", .{});
                        return;
                    }
                    try self.generateCampaign();
                    self.step = .company;
                },
                .backspace => switch (self.w_field) {
                    0 => self.w_outfit.pop(),
                    1 => self.w_company.pop(),
                    else => {},
                },
                .left => try self.setEmblemSource(0),
                .right => try self.setEmblemSource(1),
                .down => try self.emblemMove(1),
                .up => try self.emblemMove(-1),
                .char => |ch| switch (self.w_field) {
                    0 => self.w_outfit.push(ch),
                    1 => self.w_company.push(ch),
                    else => switch (ch) {
                        'h' => try self.setEmblemSource(0),
                        'l' => try self.setEmblemSource(1),
                        'j' => try self.emblemMove(1),
                        'k' => try self.emblemMove(-1),
                        else => {},
                    },
                },
                else => {},
            },
            .company => switch (key) {
                .escape => self.step = .outfit,
                .enter => self.step = .review,
                .tab, .backtab => self.w_field = if (self.w_field == 0) 1 else 0,
                .down => self.companyMove(1),
                .up => self.companyMove(-1),
                .char => |ch| switch (ch) {
                    'r' => {
                        self.w_seed += 1;
                        try self.generateCampaign();
                    },
                    'j' => self.companyMove(1),
                    'k' => self.companyMove(-1),
                    '+', '=' => try self.officeAdjust(1),
                    '-' => try self.officeAdjust(-1),
                    else => {},
                },
                else => {},
            },
            .review => switch (key) {
                .escape => {
                    if (self.gs) |*g| g.deinit();
                    self.gs = null;
                    self.mode = .welcome;
                },
                .enter => try self.beginCampaign(),
                .char => |ch| switch (ch) {
                    '1' => self.step = .commander,
                    '2' => self.step = .outfit,
                    '3' => self.step = .company,
                    else => {},
                },
                else => {},
            },
        }
    }

    fn firstHq(self: *App, g: *GameState) types.HqId {
        _ = self;
        var it = g.hqs.iterator();
        if (it.next()) |e| return e.value_ptr.id;
        return .none;
    }

    fn companyMove(self: *App, delta: i32) void {
        if (self.w_field == 0) {
            self.moveCursor(0, delta, 1000);
        } else {
            self.w_office = @intCast(@max(0, @min(@as(i32, office_roles.len - 1), @as(i32, @intCast(self.w_office)) + delta)));
        }
    }

    /// Hire (recruit + post) or release one admin of the selected desk in
    /// the generated campaign — the wizard's back-office sizing.
    fn officeAdjust(self: *App, delta: i32) !void {
        const g = &(self.gs orelse return);
        self.w_field = 1;
        const hq_id = self.firstHq(g);
        const role = office_roles[self.w_office];
        if (delta > 0) {
            const res = try game.commands.execute(g, .{ .recruit = role });
            _ = try game.commands.execute(g, .{ .post_person = .{ .person = res.hired, .hq = hq_id } });
            self.say(.good, "hired one {s}", .{@tagName(role)});
        } else {
            var last: types.PersonId = .none;
            var it = g.people.iterator();
            while (it.next()) |e| {
                const p = e.value_ptr;
                if (p.status == .active and p.role == role and p.posted_hq == hq_id) last = p.id;
            }
            if (last == .none) {
                self.say(.amber, "no {s} to release", .{@tagName(role)});
                return;
            }
            _ = try game.commands.execute(g, .{ .fire = last });
            g.refreshHqStaffing();
            self.say(.amber, "released one {s}", .{@tagName(role)});
        }
    }

    fn loadLogoList(self: *App) !void {
        _ = self.lobby.reset(.retain_capacity);
        var all: std.ArrayListUnmanaged([]const u8) = .empty;
        const la = self.lobby.allocator();
        for (logo_dirs) |d| {
            const names = try emblem_mod.listPngs(self.io, la, d);
            for (names) |n| try all.append(la, try std.fmt.allocPrint(la, "{s}/{s}", .{ d, n }));
        }
        self.logos = try all.toOwnedSlice(la);
    }

    fn setEmblemSource(self: *App, src: u8) !void {
        self.w_src = src;
        if (src == 1 and self.logos.len == 0) {
            try self.loadLogoList();
            self.w_logo = 0;
            try self.loadPreview();
        }
    }

    fn emblemMove(self: *App, delta: i32) !void {
        if (self.w_src == 0) {
            self.w_emblem = @intCast(@mod(@as(i32, @intCast(self.w_emblem)) + delta, @as(i32, emblems.len)));
            return;
        }
        if (self.logos.len == 0) return;
        self.w_logo = @intCast(@mod(@as(i32, @intCast(self.w_logo)) + delta, @as(i32, @intCast(self.logos.len))));
        try self.loadPreview();
    }

    /// Read and decode the selected picture; keep the bytes for the campaign.
    fn loadPreview(self: *App) !void {
        if (self.w_preview) |*e| {
            if (self.graphics == .kitty) emblem_mod.kittyForget(self.term.out, e.kitty_id) catch {};
            e.deinit(self.gpa);
            self.w_preview = null;
        }
        if (self.w_png) |p| {
            self.gpa.free(p);
            self.w_png = null;
        }
        if (self.logos.len == 0) return;
        const path = self.logos[@min(self.w_logo, self.logos.len - 1)];
        const bytes = emblem_mod.readFile(self.io, self.gpa, path) catch |err| {
            self.say(.crit, "could not read {s}: {s}", .{ path, @errorName(err) });
            return;
        };
        const e = emblem_mod.Emblem.load(self.gpa, bytes, 2) catch |err| {
            self.gpa.free(bytes);
            self.say(.crit, "{s}: {s} (8-bit non-interlaced PNG only)", .{ path, @errorName(err) });
            return;
        };
        self.w_png = bytes;
        self.w_preview = e;
        if (self.graphics == .kitty) emblem_mod.kittyTransmit(self.term.out, self.gpa, 2, bytes) catch {};
        self.say(.good, "{s}: {d}×{d}", .{ path, e.img.width, e.img.height });
    }

    fn wizardList(self: *App, delta: i32) void {
        switch (self.w_field) {
            1 => self.w_faction = @intCast(@max(0, @min(@as(i32, factions.len - 1), @as(i32, @intCast(self.w_faction)) + delta))),
            2 => self.w_profession = @intCast(@max(0, @min(@as(i32, professions.len - 1), @as(i32, @intCast(self.w_profession)) + delta))),
            else => {},
        }
    }

    fn generateCampaign(self: *App) !void {
        if (self.gs) |*g| g.deinit();
        self.gs = null;
        var gs = GameState.init(self.gpa, .{ .seed = 3025 + self.w_seed * 7919 + @as(u64, @intCast(self.w_faction)) * 13 });
        errdefer gs.deinit();
        _ = try game.commands.execute(&gs, .{ .create_commander = .{ .name = self.w_name.slice(), .origin = factions[self.w_faction], .profession = professions[self.w_profession] } });
        _ = try game.commands.execute(&gs, .{ .rename_outfit = self.w_outfit.slice() });
        const res = try game.commands.execute(&gs, .{ .new_company = self.w_company.slice() });
        if (res.created_force != .none) {
            const image: []const u8 = if (self.w_src == 1 and self.w_png != null) self.w_png.? else emblems[self.w_emblem].name;
            _ = try game.commands.execute(&gs, .{ .set_emblem = .{ .force = res.created_force, .image = image } });
        }
        self.gs = gs;
        self.cur(0).* = 0;
    }

    fn beginCampaign(self: *App) !void {
        if (self.gs == null) return;
        self.store.player_id = self.player_id;
        self.store.save(&self.gs.?) catch |err| {
            self.say(.crit, "save failed: {s}", .{@errorName(err)});
            return;
        };
        self.mode = .game;
        self.tab = .desk;
        self.focus = 0;
        self.refreshEmblem();
        self.say(.good, "campaign \"{s}\" begins — day 0. Press ? for help.", .{self.gs.?.outfit_name});
    }

    fn handleGameKey(self: *App, key: Key) !void {
        switch (key) {
            .f => |n| if (n >= 1 and n <= 10) self.switchTab(@enumFromInt(n - 1)) else if (n == 12) {
                self.modal = .settings;
            },
            .tab => self.focus = (self.focus + 1) % self.paneCount(),
            .backtab => self.focus = (self.focus + self.paneCount() - 1) % self.paneCount(),
            .down => try self.screenMove(1),
            .up => try self.screenMove(-1),
            .left => if (self.tab == .map) try self.mapMove(-1, 0),
            .right => if (self.tab == .map) try self.mapMove(1, 0),
            .pgdn => try self.screenMove(10),
            .pgup => try self.screenMove(-10),
            .enter => try self.screenEnter(),
            .escape => self.msg.len = 0,
            .char => |ch| switch (ch) {
                '1'...'9' => self.switchTab(@enumFromInt(ch - '1')),
                '0' => self.switchTab(.market),
                'j' => try self.screenMove(1),
                'k' => try self.screenMove(-1),
                ':' => {
                    self.input.set(self.cmd_prefill.slice());
                    self.cmd_prefill.len = 0;
                    self.modal = .{ .input = .command };
                },
                'n' => try self.endTurnRequest(1),
                'N' => try self.endTurnRequest(7),
                'q' => self.modal = .quit,
                'M' => try self.toggleMusic(),
                '?' => self.modal = .help,
                else => try self.screenKey(ch),
            },
            else => {},
        }
    }

    fn switchTab(self: *App, tab: Tab) void {
        self.tab = tab;
        self.focus = 0;
    }

    fn paneCount(self: *App) u8 {
        return switch (self.tab) {
            .desk => 3,
            .contracts => 3,
            .ledger => 2,
            .forces => 2,
            .hq => 2,
            .market => if (self.narrow()) 2 else 3,
            else => 1,
        };
    }

    fn screenMove(self: *App, delta: i32) !void {
        const al = self.a();
        const g = &self.gs.?;
        switch (self.tab) {
            .desk => {
                const view = try q.desk(al, g, 40);
                switch (self.focus) {
                    0 => self.moveCursor(0, delta, view.checklist.len),
                    1 => self.moveCursor(1, delta, self.inboxRowCount(view)),
                    else => self.moveCursor(2, delta, view.log.len),
                }
            },
            .contracts => {
                const view = try q.contracts(al, g);
                if (self.focus == 0) self.moveCursor(0, delta, view.board.len) else if (self.focus == 1) self.moveCursor(1, delta, view.active.len) else self.moveCursor(2, delta, (try q.contractHistory(al, g)).len);
            },
            .ledger => {
                if (self.focus == 0) {
                    const all = try q.allTreasuries(al, g);
                    const v: i32 = @as(i32, @intCast(self.ledger_sel)) + delta;
                    self.ledger_sel = @intCast(@max(0, @min(@as(i32, @intCast(all.len)) - 1, v)));
                } else {
                    const view = try q.ledger(al, g, .outfit, 31, 200);
                    self.moveCursor(2, delta, view.ledger.len + 1);
                }
            },
            .forces => {
                if (self.focus == 0) {
                    const rows = try q.toe(al, g);
                    self.moveCursor(0, delta, rows.len);
                } else {
                    const pool = try q.unassigned(al, g);
                    self.moveCursor(2, delta, pool.len);
                }
            },
            .supply => {
                const view = try q.supply(al, g);
                self.moveCursor(0, delta, view.rows.len);
            },
            .hq => {
                const id: types.HqId = @enumFromInt(self.hqSelId(g));
                if (self.focus == 0) {
                    const detail = try q.hqDetail(al, g, id);
                    self.moveCursor(0, delta, detail.len);
                } else {
                    const hallv = try q.hall(al, g, id, self.hall_filter);
                    self.moveCursor(1, delta, hallv.rows.len);
                }
            },
            .map => try self.mapMove(0, if (delta > 0) -1 else 1),
            .lab => {
                const uid = (try self.labUnit()) orelse return;
                const view = try q.lab(al, g, uid);
                self.moveCursor(0, delta, view.mounts.len);
            },
            .people => {
                const view = try q.people(al, g, self.people_filter);
                self.moveCursor(0, delta, view.rows.len);
            },
            .market => {
                const view = try q.market(al, g, self.market_filter);
                switch (self.focus) {
                    0 => self.moveCursor(0, delta, view.board.len),
                    1 => self.moveCursor(1, delta, view.catalog.len),
                    else => self.moveCursor(2, delta, view.demand.len),
                }
            },
        }
    }

    fn inboxRowCount(self: *App, view: q.Desk) usize {
        _ = self;
        var n: usize = 0;
        for (view.inbox) |it| n += 2 + it.options.len;
        return n;
    }

    fn inboxEventAtCursor(self: *App, view: q.Desk) ?usize {
        var n: usize = 0;
        const c = self.cur(1).*;
        for (view.inbox) |it| {
            const span = 2 + it.options.len;
            if (c < n + span) return it.event_index;
            n += span;
        }
        return null;
    }

    fn screenEnter(self: *App) !void {
        const al = self.a();
        const g = &self.gs.?;
        switch (self.tab) {
            .desk => {
                const view = try q.desk(al, g, 40);
                if (self.focus == 0 and view.checklist.len > 0) {
                    const w = view.checklist[@min(self.cur(0).*, view.checklist.len - 1)];
                    self.switchTab(@enumFromInt(w.jump));
                } else if (self.focus == 1) {
                    if (self.inboxEventAtCursor(view)) |idx| self.modal = .{ .decision = idx };
                }
            },
            .contracts => {
                const view = try q.contracts(al, g);
                if (self.focus == 0 and view.board.len > 0) {
                    // One company at home → send it; otherwise ask.
                    var home: ?types.ForceId = null;
                    var count: usize = 0;
                    var fit = g.forces.iterator();
                    while (fit.next()) |e| {
                        const f = e.value_ptr;
                        if (f.echelon == .company and g.isCompanyHome(f.id)) {
                            home = f.id;
                            count += 1;
                        }
                    }
                    if (count == 1) {
                        try self.exec(.{ .accept_contract = .{ .offer_index = view.board[self.cur(0).*].index, .company = home.? } });
                        self.say(.good, "accepted — {s} is on its way", .{q.forceName(g, home.?)});
                    } else {
                        self.input.len = 0;
                        self.modal = .{ .input = .accept_company };
                    }
                }
            },
            .ledger => {
                self.cmd_prefill.set("transfer outfit ");
                self.input.set(self.cmd_prefill.slice());
                self.cmd_prefill.len = 0;
                self.modal = .{ .input = .command };
            },
            .forces => {
                const rows = try q.toe(al, g);
                const c = self.cur(0).*;
                if (self.focus == 0 and c < rows.len and rows[c].unit != .none) {
                    if (self.narrow()) {
                        self.modal = .{ .hull = rows[c].unit };
                        return;
                    }
                    var buf: [64]u8 = undefined;
                    self.input.set(std.fmt.bufPrint(&buf, "assign {d} ", .{@intFromEnum(rows[c].unit)}) catch "assign ");
                    self.modal = .{ .input = .command };
                }
            },
            .hq => {
                if (self.focus != 1) return;
                const id: types.HqId = @enumFromInt(self.hqSelId(g));
                const hallv = try q.hall(al, g, id, self.hall_filter);
                if (hallv.rows.len == 0) return;
                const row = hallv.rows[@min(self.cur(1).*, hallv.rows.len - 1)];
                try self.exec(.{ .hire_candidate = row.index });
                self.say(.good, "hired candidate [{d}]", .{row.index});
            },
            .map => self.switchTab(.contracts),
            .lab => {
                const uid = (try self.labUnit()) orelse return;
                try self.exec(.{ .refit_commit = uid });
                self.say(.good, "refit committed to the bay queue", .{});
            },
            .people => {
                const id = (try self.selectedPerson()) orelse return;
                self.modal_cursor = 0;
                self.modal = .{ .seat = id };
            },
            .market => {
                const view = try q.market(al, g, self.market_filter);
                const hq_id: types.HqId = @enumFromInt(self.hqSelId(g));
                switch (self.focus) {
                    0 => if (view.board.len > 0) {
                        const l = view.board[@min(self.cur(0).*, view.board.len - 1)];
                        try self.exec(.{ .buy_listing = l.index });
                        self.say(.good, "bought listing [{d}]", .{l.index});
                    },
                    1 => if (view.catalog.len > 0) {
                        const r = view.catalog[@min(self.cur(1).*, view.catalog.len - 1)];
                        var buf: [96]u8 = undefined;
                        self.openCommand(std.fmt.bufPrint(&buf, "order {s} 1 hq:{d}", .{ r.key, @intFromEnum(hq_id) }) catch "order ");
                    },
                    else => if (view.demand.len > 0) {
                        const d = view.demand[@min(self.cur(2).*, view.demand.len - 1)];
                        if (d.short == 0) {
                            self.say(.dim, "{s}: nothing short — on hand or already on order", .{d.key});
                            return;
                        }
                        try self.exec(.{ .order_part = .{ .part_key = d.key, .quantity = d.short, .dest = .{ .hq = hq_id } } });
                        self.say(.good, "ordered {d} × {s} to {s}", .{ d.short, d.key, q.hqName(g, hq_id) });
                    },
                }
            },
            else => {},
        }
    }

    fn screenKey(self: *App, ch: u21) !void {
        const al = self.a();
        const g = &self.gs.?;
        switch (self.tab) {
            .desk => switch (ch) {
                'e' => {
                    self.logos = &.{};
                    try self.loadLogoList();
                    self.modal_cursor = 0;
                    self.modal = .emblem;
                },
                else => {},
            },
            .people => {
                if (ch == '/' or ch == ',') {
                    self.people_filter = if (ch == '/') self.people_filter.next() else self.people_filter.prev();
                    self.cur(0).* = 0;
                    return;
                }
                const id = (try self.selectedPerson()) orelse return;
                var buf: [96]u8 = undefined;
                switch (ch) {
                    't' => {
                        const p = g.person(id).?;
                        self.openCommand(std.fmt.bufPrint(&buf, "train {d} {s}", .{ @intFromEnum(id), @tagName(p.role.primarySkill()) }) catch "train ");
                    },
                    'a' => {
                        self.modal_cursor = 0;
                        self.modal = .{ .seat = id };
                    },
                    'P' => self.openCommand(std.fmt.bufPrint(&buf, "post {d} hq:", .{@intFromEnum(id)}) catch "post "),
                    'x' => self.openCommand(std.fmt.bufPrint(&buf, "xfer person {d} co:", .{@intFromEnum(id)}) catch "xfer person "),
                    'L' => self.openCommand(std.fmt.bufPrint(&buf, "leave {d} 7", .{@intFromEnum(id)}) catch "leave "),
                    'T' => self.openCommand(std.fmt.bufPrint(&buf, "triage {d} 1", .{@intFromEnum(id)}) catch "triage "),
                    'D' => self.modal = .{ .fire = id },
                    'r' => self.modal = .{ .record = id },
                    'm' => {
                        try self.exec(.{ .admit = id });
                        self.say(.good, "{s} admitted to the medbay — healing starts tomorrow", .{try q.personName(al, g, id)});
                    },
                    else => {},
                }
            },
            .market => switch (ch) {
                '/' => {
                    self.market_filter = self.market_filter.next();
                    self.cur(0).* = 0;
                    self.cur(1).* = 0;
                },
                ',' => {
                    self.market_filter = self.market_filter.prev();
                    self.cur(0).* = 0;
                    self.cur(1).* = 0;
                },
                'b' => {
                    const view = try q.market(al, g, self.market_filter);
                    if (self.focus == 1 and view.catalog.len > 0) {
                        const r = view.catalog[@min(self.cur(1).*, view.catalog.len - 1)];
                        if (!r.component) {
                            self.say(.amber, "only structural components (comp_*) are fabricated; order the rest", .{});
                            return;
                        }
                        var buf: [96]u8 = undefined;
                        self.openCommand(std.fmt.bufPrint(&buf, "fabricate hq:{d} {s} 1", .{ self.hqSelId(g), r.key }) catch "fabricate ");
                    } else self.say(.dim, "select a comp_* row in the catalog, then b", .{});
                },
                'K' => {
                    const view = try q.market(al, g, self.market_filter);
                    if (self.focus == 1 and view.catalog.len > 0) {
                        const r = view.catalog[@min(self.cur(1).*, view.catalog.len - 1)];
                        var buf: [96]u8 = undefined;
                        self.openCommand(std.fmt.bufPrint(&buf, "stockpolicy hq:{d} {s} 5 10", .{ self.hqSelId(g), r.key }) catch "stockpolicy ");
                    } else self.say(.dim, "select a catalogue row (Tab), then K to keep it stocked at the HQ", .{});
                },
                ']', '[' => {
                    var n: usize = 0;
                    var hit = g.hqs.iterator();
                    while (hit.next()) |_| n += 1;
                    if (n > 0) self.hq_sel = if (ch == ']') (self.hq_sel + 1) % n else (self.hq_sel + n - 1) % n;
                },
                else => {},
            },
            .contracts => {
                if (self.focus == 2) return; // history is read-only: the log pane follows the cursor
                const view = try q.contracts(al, g);
                if (view.active.len == 0) return;
                const sel = view.active[@min(self.cur(1).*, view.active.len - 1)];
                switch (ch) {
                    'c' => {
                        if (sel.id == .none) {
                            self.say(.dim, "no contract to complete — [R] recalls the company", .{});
                            return;
                        }
                        try self.exec(.{ .complete_contract = sel.id });
                        self.say(.good, "contract [{d}] closed out", .{@intFromEnum(sel.id)});
                    },
                    'R' => {
                        const under_contract = sel.id != .none;
                        try self.exec(.{ .recall_company = sel.company });
                        if (self.msg_style == .crit) return;
                        if (under_contract) {
                            self.say(.amber, "{s} recalled under the breach clause: advance clawed back, remaining pay forfeited, reputation −2", .{q.forceName(g, sel.company)});
                        } else {
                            self.say(.good, "{s} is coming home", .{q.forceName(g, sel.company)});
                        }
                    },
                    else => {},
                }
            },
            .ledger => switch (ch) {
                't', 'T', 'p' => {
                    const all = try q.allTreasuries(al, g);
                    const sel: Treasury = if (self.ledger_sel < all.len) all[self.ledger_sel] else .outfit;
                    const label = try q.treasuryLabel(al, g, sel);
                    const tok = if (std.mem.indexOfScalar(u8, label, ' ')) |i| label[0..i] else label;
                    var buf: [128]u8 = undefined;
                    if (ch == 't') {
                        self.openCommand(if (sel == .outfit) "transfer outfit " else std.fmt.bufPrint(&buf, "transfer outfit {s} 250000", .{tok}) catch "transfer outfit ");
                    } else if (ch == 'T') {
                        if (sel == .outfit) {
                            self.say(.dim, "select the HQ or company row to pull money back from", .{});
                            return;
                        }
                        const bal = g.treasuryBalance(sel);
                        self.openCommand(std.fmt.bufPrint(&buf, "transfer {s} outfit {d}", .{ tok, @max(0, @divTrunc(bal, 2)) }) catch "transfer ");
                    } else {
                        if (sel == .outfit) {
                            self.say(.dim, "select an HQ or company row first — policies top up from the outfit treasury", .{});
                            return;
                        }
                        const existing = q.policyFor(g, sel);
                        self.openCommand(std.fmt.bufPrint(&buf, "policy {s} {d} {d}", .{ tok, if (existing) |p| p.floor else 250_000, if (existing) |p| p.monthly_cap else 500_000 }) catch "policy ");
                    }
                },
                'L' => {
                    var buf: [96]u8 = undefined;
                    self.openCommand(std.fmt.bufPrint(&buf, "loan {d} 12", .{@min(g.creditRemaining(), 1_000_000)}) catch "loan ");
                },
                'R' => {
                    if (g.loans.items.len == 0) {
                        self.say(.dim, "no loans to repay", .{});
                        return;
                    }
                    var buf: [96]u8 = undefined;
                    self.openCommand(std.fmt.bufPrint(&buf, "repay 0 {d}", .{@min(g.loans.items[0].balance, @max(0, g.funds))}) catch "repay ");
                },
                else => {},
            },
            .forces => {
                const rows = try q.toe(al, g);
                const c = self.cur(0).*;
                const row: ?q.ToeRow = if (c < rows.len) rows[c] else null;
                switch (ch) {
                    'a' => if (row) |r| {
                        if (r.unit != .none) {
                            var buf: [64]u8 = undefined;
                            self.openCommand(std.fmt.bufPrint(&buf, "assign {d} ", .{@intFromEnum(r.unit)}) catch "assign ");
                        }
                    },
                    'u' => if (row) |r| {
                        if (r.unit != .none) {
                            var buf: [64]u8 = undefined;
                            self.openCommand(std.fmt.bufPrint(&buf, "unassign {d} ", .{@intFromEnum(r.unit)}) catch "unassign ");
                        }
                    },
                    'A' => if (row) |r| {
                        const co = g.companyOf(r.force);
                        if (co != .none) {
                            try self.exec(.{ .auto_assign = co });
                            self.say(.good, "auto-assigned {s}", .{q.forceName(g, co)});
                        }
                    },
                    't' => self.openCommand("train "),
                    'x' => if (row) |r| {
                        var buf: [64]u8 = undefined;
                        self.openCommand(if (r.unit != .none) std.fmt.bufPrint(&buf, "xfer unit {d} co:", .{@intFromEnum(r.unit)}) catch "xfer unit " else "xfer unit ");
                    },
                    'l' => if (row) |r| {
                        if (r.unit == .none) {
                            self.say(.dim, "put the cursor on a hull to move it into a lance", .{});
                            return;
                        }
                        self.modal_cursor = 0;
                        self.modal = .{ .lance_pick = r.unit };
                    },
                    'b' => if (row) |r| {
                        const co = g.companyOf(r.force);
                        if (co == .none) {
                            self.say(.dim, "put the cursor on a company or one of its hulls", .{});
                            return;
                        }
                        const dmg = try q.companyDamage(al, g, co);
                        if (dmg.short_key) |key| {
                            var buf: [96]u8 = undefined;
                            self.openCommand(std.fmt.bufPrint(&buf, "fabricate hq:{d} {s} 1", .{ self.homeHqOf(co), key }) catch "fabricate ");
                        } else self.say(.good, "{s} needs no structural components the home HQ lacks", .{q.forceName(g, co)});
                    },
                    'm' => if (row) |r| {
                        if (r.unit == .none) return;
                        const u = g.unit(r.unit) orelse return;
                        if (u.status == .mothballed) {
                            try self.exec(.{ .reactivate = r.unit });
                            if (self.msg_style != .crit) self.say(.good, "#{d} reactivating — tech-days before it can fight or move", .{@intFromEnum(r.unit)});
                        } else {
                            try self.exec(.{ .mothball = r.unit });
                            if (self.msg_style != .crit) self.say(.good, "#{d} mothballed — 20% upkeep, no maintenance wear, no crew needed", .{@intFromEnum(r.unit)});
                        }
                    },
                    '$' => if (row) |r| {
                        if (r.unit != .none) self.modal = .{ .sell_unit = r.unit };
                    },
                    'd' => if (row) |r| {
                        if (r.unit != .none) {
                            try self.exec(.{ .depot = r.unit });
                            if (self.msg_style != .crit) self.say(.good, "#{d} queued for depot repair", .{@intFromEnum(r.unit)});
                        }
                    },
                    'o' => if (row) |r| {
                        const f = g.force(r.force) orelse return;
                        if (f.echelon != .lance and f.echelon != .air_lance) {
                            self.say(.dim, "roles are set on lances — move the cursor onto a lance row", .{});
                            return;
                        }
                        const roles = [_]game.force.LanceRole{ .fighting, .defense, .scouting, .training };
                        var next: game.force.LanceRole = roles[0];
                        for (roles, 0..) |ro, i| if (ro == f.role) {
                            next = roles[(i + 1) % roles.len];
                        };
                        try self.exec(.{ .set_role = .{ .force = r.force, .role = next } });
                        self.say(.good, "{s} → {s}: {s}", .{ f.name, @tagName(next), switch (next) {
                            .fighting => "fights in every engagement",
                            .defense => "+10% power on garrison-class contracts",
                            .scouting => "recon: better intel before battles",
                            .training => "held out of battles; crews gain XP weekly at home",
                            .unassigned => "",
                        } });
                    },
                    'X' => if (row) |r| {
                        const co = g.companyOf(r.force);
                        if (co != .none) self.modal = .{ .disband = co };
                    },
                    'R' => if (row) |r| {
                        const co = g.companyOf(r.force);
                        if (co == .none) return;
                        if (g.isCompanyHome(co)) {
                            self.say(.dim, "{s} is already home", .{q.forceName(g, co)});
                            return;
                        }
                        if (g.deploymentContract(co) != null) {
                            self.say(.amber, "{s} is under contract — recall from the Contracts screen (R there) to accept the breach clause", .{q.forceName(g, co)});
                            return;
                        }
                        try self.exec(.{ .recall_company = co });
                        if (self.msg_style != .crit) self.say(.good, "{s} is coming home", .{q.forceName(g, co)});
                    },
                    else => {},
                }
            },
            .supply => {
                const site = try self.supplySite();
                var buf: [128]u8 = undefined;
                switch (ch) {
                    'o' => self.openCommand(if (site) |s| switch (s) {
                        .company => |id| std.fmt.bufPrint(&buf, "order provisions 10 co:{d}", .{@intFromEnum(id)}) catch "order ",
                        .hq => |id| std.fmt.bufPrint(&buf, "order provisions 10 hq:{d}", .{@intFromEnum(id)}) catch "order ",
                        .outfit => "order ",
                    } else "order "),
                    's' => self.openCommand(if (site) |s| switch (s) {
                        .company => |id| std.fmt.bufPrint(&buf, "ship provisions 10 hq:{d} co:{d}", .{ self.homeHqOf(id), @intFromEnum(id) }) catch "ship ",
                        else => "ship provisions 10 ",
                    } else "ship provisions 10 "),
                    't' => self.openCommand(if (site) |s| switch (s) {
                        .company => |id| std.fmt.bufPrint(&buf, "transfer outfit co:{d} 250000", .{@intFromEnum(id)}) catch "transfer outfit ",
                        .hq => |id| std.fmt.bufPrint(&buf, "transfer outfit hq:{d} 500000", .{@intFromEnum(id)}) catch "transfer outfit ",
                        .outfit => "transfer outfit ",
                    } else "transfer outfit "),
                    'p' => self.openCommand(if (site) |s| switch (s) {
                        .company => |id| std.fmt.bufPrint(&buf, "policy co:{d} 250000 500000", .{@intFromEnum(id)}) catch "policy ",
                        .hq => |id| std.fmt.bufPrint(&buf, "policy hq:{d} 500000 1000000", .{@intFromEnum(id)}) catch "policy ",
                        .outfit => "policy ",
                    } else "policy "),
                    'P' => self.openCommand(if (site) |s| switch (s) {
                        .company => |id| std.fmt.bufPrint(&buf, "supplypolicy co:{d} 14 20", .{@intFromEnum(id)}) catch "supplypolicy ",
                        else => "supplypolicy co:",
                    } else "supplypolicy co:"),
                    'K' => self.openCommand(if (site) |s| switch (s) {
                        .hq => |id| std.fmt.bufPrint(&buf, "stockpolicy hq:{d} ", .{@intFromEnum(id)}) catch "stockpolicy ",
                        else => "stockpolicy hq:",
                    } else "stockpolicy hq:"),
                    '$' => self.openCommand(if (site) |s| switch (s) {
                        .hq => |id| std.fmt.bufPrint(&buf, "sellstock hq:{d} ", .{@intFromEnum(id)}) catch "sellstock ",
                        else => "sellstock hq:",
                    } else "sellstock hq:"),
                    'H' => {
                        // Send every structural component in the field stores home.
                        const co: types.ForceId = if (site) |s| (if (s == .company) s.company else .none) else .none;
                        if (co == .none) {
                            self.say(.dim, "move the cursor onto a company's field stores", .{});
                            return;
                        }
                        const home = g.homeHqFor(co);
                        const f = g.forces.getPtr(co) orelse return;
                        var keys: std.ArrayListUnmanaged([]const u8) = .empty;
                        var qtys: std.ArrayListUnmanaged(u32) = .empty;
                        var it = f.stock.iterator();
                        while (it.next()) |e| if (game.part.isComponent(e.key_ptr.*) and e.value_ptr.* > 0) {
                            try keys.append(al, e.key_ptr.*);
                            try qtys.append(al, e.value_ptr.*);
                        };
                        if (keys.items.len == 0) {
                            self.say(.dim, "no structural components in {s}'s field stores", .{f.name});
                            return;
                        }
                        var sent: u32 = 0;
                        for (keys.items, qtys.items) |k, n| {
                            _ = game.commands.execute(g, .{ .ship_stock = .{ .part_key = k, .quantity = n, .from = .{ .company = co }, .to = .{ .hq = home } } }) catch |err| {
                                self.say(.crit, "{s}: {s}", .{ k, App.errorText(err) });
                                return;
                            };
                            sent += n;
                        }
                        self.say(.good, "{d} component{s} shipped from {s} to {s} (freight from local funds)", .{ sent, if (sent == 1) "" else "s", f.name, q.hqName(g, home) });
                    },
                    'T' => self.openCommand(if (site) |s| switch (s) {
                        .company => |id| std.fmt.bufPrint(&buf, "transfer co:{d} outfit {d}", .{ @intFromEnum(id), @max(0, @divTrunc(g.treasuryBalance(.{ .company = id }), 2)) }) catch "transfer ",
                        .hq => |id| std.fmt.bufPrint(&buf, "transfer hq:{d} outfit {d}", .{ @intFromEnum(id), @max(0, @divTrunc(g.treasuryBalance(.{ .hq = id }), 2)) }) catch "transfer ",
                        .outfit => "transfer ",
                    } else "transfer "),
                    else => {},
                }
            },
            .hq => {
                var n: usize = 0;
                var hit = g.hqs.iterator();
                while (hit.next()) |_| n += 1;
                switch (ch) {
                    ']' => if (n > 0) {
                        self.hq_sel = (self.hq_sel + 1) % n;
                    },
                    '[' => if (n > 0) {
                        self.hq_sel = (self.hq_sel + n - 1) % n;
                    },
                    'u' => {
                        // The facility rows sit right under the header in the
                        // HQ pane: with the cursor on one, upgrade it directly.
                        const hid: types.HqId = @enumFromInt(self.hqSelId(g));
                        const c = self.cur(0).*;
                        if (self.focus == 0 and g.hqs.getPtr(hid) != null and c >= 1 and c <= g.hqs.getPtr(hid).?.facilities.items.len) {
                            const kind = g.hqs.getPtr(hid).?.facilities.items[c - 1].kind;
                            const rows = try q.upgrades(al, g, hid);
                            for (rows) |r| if (r.kind == kind) {
                                if (!r.possible) {
                                    self.say(.amber, "{s}: {s}", .{ @tagName(kind), r.reason });
                                    return;
                                }
                            };
                            try self.exec(.{ .upgrade_facility = .{ .hq = hid, .kind = kind } });
                            if (self.msg_style != .crit) self.say(.good, "{s} upgrade started — paperwork first, then construction; watch PROJECTS", .{@tagName(kind)});
                            return;
                        }
                        self.modal_cursor = 0;
                        self.modal = .{ .upgrade = hid };
                    },
                    'S' => {
                        try self.exec(.{ .autostaff = @enumFromInt(self.hqSelId(g)) });
                        self.say(.good, "back office staffed to requirement", .{});
                    },
                    'h' => {
                        self.focus = 1;
                        self.say(.dim, "hiring hall: j/k pick, Enter hires, f/F changes the filter", .{});
                    },
                    'f' => {
                        self.hall_filter = self.hall_filter.next();
                        self.focus = 1;
                        self.cur(1).* = 0;
                    },
                    'F' => {
                        self.hall_filter = self.hall_filter.prev();
                        self.focus = 1;
                        self.cur(1).* = 0;
                    },
                    'b' => {
                        var buf: [64]u8 = undefined;
                        self.openCommand(std.fmt.bufPrint(&buf, "fabricate hq:{d} ", .{self.hqSelId(g)}) catch "fabricate ");
                    },
                    '$' => self.modal = .{ .sell_hq = @enumFromInt(self.hqSelId(g)) },
                    else => {},
                }
            },
            .map => switch (ch) {
                'h' => try self.mapMove(-1, 0),
                'l' => try self.mapMove(1, 0),
                'f' => {
                    const view = try q.map(al, g);
                    if (view.worlds.len == 0) return;
                    var buf: [96]u8 = undefined;
                    self.openCommand(std.fmt.bufPrint(&buf, "found {s} ", .{view.worlds[@min(self.map_cursor, view.worlds.len - 1)].key}) catch "found ");
                },
                'o' => self.switchTab(.contracts),
                else => {},
            },
            .lab => {
                const uid = (try self.labUnit()) orelse return;
                const view = try q.lab(al, g, uid);
                const meks = view.meks;
                switch (ch) {
                    ']' => self.lab_sel = (self.lab_sel + 1) % meks.len,
                    '[' => self.lab_sel = (self.lab_sel + meks.len - 1) % meks.len,
                    '-' => if (view.mounts.len > 0) {
                        const m = view.mounts[@min(self.cur(0).*, view.mounts.len - 1)];
                        try self.exec(.{ .refit_remove = .{ .unit = uid, .slot_key = m.slot_key } });
                    },
                    '+' => {
                        self.modal_cursor = 0;
                        self.modal = .{ .install_part = uid };
                    },
                    'R' => if (view.mounts.len > 0) {
                        const m = view.mounts[@min(self.cur(0).*, view.mounts.len - 1)];
                        const u = g.unit(uid).?;
                        for (u.slots.items) |s| {
                            if (!std.mem.eql(u8, s.slot_key, m.slot_key)) continue;
                            if (s.condition == .ok) {
                                self.say(.dim, "{s} is fine — [R] orders a replacement for damaged or destroyed gear", .{s.slot_key});
                                return;
                            }
                            const home = g.homeHqFor(u.force);
                            try self.exec(.{ .order_part = .{ .part_key = s.part_key, .quantity = 1, .dest = .{ .hq = home } } });
                            self.say(.good, "ordered 1 × {s} to {s}; techs fit it on the next repair pass once it lands", .{ s.part_key, q.hqName(g, home) });
                            return;
                        }
                    },
                    'c' => try self.exec(.{ .refit_clear = uid }),
                    'D' => {
                        try self.exec(.{ .depot = uid });
                        if (self.msg.len == 0 or self.msg_style != .crit) self.say(.good, "#{d} queued for depot repair — see the HQ screen's bays", .{@intFromEnum(uid)});
                    },
                    else => {},
                }
            },
        }
    }

    const LanceChoice = struct { force: types.ForceId, name: []const u8, text: []const u8 };

    /// The lances (line and support) of the hull's company, with room noted.
    fn lanceChoices(self: *App, uid: types.UnitId) ![]LanceChoice {
        const al = self.a();
        const g = &self.gs.?;
        var out: std.ArrayListUnmanaged(LanceChoice) = .empty;
        const u = g.unit(uid) orelse return out.toOwnedSlice(al);
        var co = g.companyOf(u.force);
        if (co == .none) {
            // an unassigned hull: offer every company's lances
            var fit = g.forces.iterator();
            while (fit.next()) |e| if (e.value_ptr.echelon == .company and g.isCompanyHome(e.value_ptr.id)) {
                co = e.value_ptr.id;
                try self.lancesOf(&out, co, u);
            };
            return out.toOwnedSlice(al);
        }
        try self.lancesOf(&out, co, u);
        return out.toOwnedSlice(al);
    }

    fn lancesOf(self: *App, out: *std.ArrayListUnmanaged(LanceChoice), co: types.ForceId, u: *const game.unit.Unit) !void {
        const al = self.a();
        const g = &self.gs.?;
        const company = g.forces.getPtr(co) orelse return;
        for (company.children.items) |cid| {
            const f = g.forces.getPtr(cid) orelse continue;
            if (f.echelon == .lance or f.echelon == .air_lance) {
                const full = f.units.items.len >= game.force.lance_size;
                try out.append(al, .{ .force = cid, .name = f.name, .text = try std.fmt.allocPrint(al, "{s}[{d}] {s: <22} line lance · {s} · {d}/{d} hulls{s}{{/}}", .{ if (full) "{d}" else if (u.force == cid) "{a}" else "", @intFromEnum(cid), f.name, @tagName(f.role), f.units.items.len, game.force.lance_size, if (full) " · full" else if (u.force == cid) " · here" else "" }) });
            } else if (f.echelon == .support_company) {
                for (f.children.items) |sid| {
                    const sl = g.forces.getPtr(sid) orelse continue;
                    try out.append(al, .{ .force = sid, .name = sl.name, .text = try std.fmt.allocPrint(al, "{s}[{d}] {s: <22} support · {s} · {d} hulls{s}{{/}}", .{ if (u.force == sid) "{a}" else "", @intFromEnum(sid), sl.name, if (sl.support_kind) |k| @tagName(k) else "support", sl.units.items.len, if (u.force == sid) " · here" else "" }) });
                }
            }
        }
    }

    fn hqSelId(self: *App, g: *GameState) u32 {
        var i: usize = 0;
        var it = g.hqs.iterator();
        while (it.next()) |e| : (i += 1) if (i == self.hq_sel) return @intFromEnum(e.value_ptr.id);
        return 0;
    }

    fn openCommand(self: *App, prefill: []const u8) void {
        self.input.set(prefill);
        self.modal = .{ .input = .command };
    }

    fn endTurnRequest(self: *App, days: u32) !void {
        const al = self.a();
        const g = &self.gs.?;
        const view = try q.desk(al, g, 0);
        if (view.checklist.len > 0 and days == 1) {
            self.modal = .end_turn;
            return;
        }
        try self.advance(days);
    }

    fn advance(self: *App, days: u32) !void {
        const g = &self.gs.?;
        const before = g.clock.day_index;
        try self.exec(if (days == 1) .advance_day else .{ .advance_days = days });
        if (g.bankrupt) {
            self.store.player_id = self.player_id;
            self.store.save(g) catch {};
            self.modal = .game_over;
            return;
        }
        if (g.clock.day_index == before) return; // refused — the message says why
        self.say(.good, "day {d} · {d}-{d:0>2}-{d:0>2}", .{ g.clock.day_index, g.clock.date.year, g.clock.date.month, g.clock.date.day });
    }

    fn exec(self: *App, cmd: Command) !void {
        const g = &self.gs.?;
        _ = game.commands.execute(g, cmd) catch |err| {
            self.say(.crit, "refused: {s}", .{errorText(err)});
            return;
        };
    }

    fn handleModalKey(self: *App, key: Key) !void {
        switch (self.modal) {
            .none => {},
            .help, .hull, .record => self.modal = .none,
            .lance_pick => |uid| switch (key) {
                .escape => self.modal = .none,
                .down => self.modal_cursor +|= 1,
                .up => self.modal_cursor -|= 1,
                .enter => {
                    const lances = try self.lanceChoices(uid);
                    if (lances.len == 0) return;
                    const lc = lances[@min(self.modal_cursor, lances.len - 1)];
                    self.modal = .none;
                    try self.exec(.{ .move_unit = .{ .unit = uid, .force = lc.force } });
                    if (self.msg_style != .crit) self.say(.good, "#{d} moved to {s}", .{ @intFromEnum(uid), lc.name });
                },
                .char => |ch| switch (ch) {
                    'j' => self.modal_cursor +|= 1,
                    'k' => self.modal_cursor -|= 1,
                    else => {},
                },
                else => {},
            },
            .upgrade => |hid| switch (key) {
                .escape => self.modal = .none,
                .down => self.modal_cursor +|= 1,
                .up => self.modal_cursor -|= 1,
                .enter => {
                    const rows = try q.upgrades(self.a(), &self.gs.?, hid);
                    if (rows.len == 0) return;
                    const r = rows[@min(self.modal_cursor, rows.len - 1)];
                    if (!r.possible) {
                        self.say(.amber, "{s}: {s}", .{ @tagName(r.kind), r.reason });
                        return;
                    }
                    self.modal = .none;
                    try self.exec(.{ .upgrade_facility = .{ .hq = hid, .kind = r.kind } });
                    if (self.msg_style != .crit) self.say(.good, "{s} upgrade started — paperwork first, then construction; watch PROJECTS", .{@tagName(r.kind)});
                },
                .char => |ch| switch (ch) {
                    'j' => self.modal_cursor +|= 1,
                    'k' => self.modal_cursor -|= 1,
                    else => {},
                },
                else => {},
            },
            .settings => switch (key) {
                .escape, .enter => self.modal = .none,
                .char => |ch| switch (ch) {
                    'm', 'M' => try self.toggleMusic(),
                    '+', '=' => try self.adjustVolume(10),
                    '-' => try self.adjustVolume(-10),
                    '>' => if (self.music) |*m| m.skip(),
                    'a', 'A' => if (self.gs) |*gs| {
                        const on = !gs.auto_admit;
                        try self.exec(.{ .set_auto_admit = on });
                        self.say(.good, "medbay auto-admit {s}", .{if (on) "on — casualties are admitted each morning" else "off — admit casualties yourself (m on People)"});
                    },
                    'q' => self.modal = .none,
                    else => {},
                },
                else => {},
            },
            .end_turn => switch (key) {
                .escape => self.modal = .none,
                .char => |ch| switch (ch) {
                    'n', 'y' => {
                        self.modal = .none;
                        try self.advance(1);
                    },
                    'N' => {
                        self.modal = .none;
                        try self.advance(7);
                    },
                    '1'...'9' => {
                        const view = try q.desk(self.a(), &self.gs.?, 0);
                        const i: usize = ch - '1';
                        if (i < view.checklist.len) {
                            self.modal = .none;
                            self.switchTab(@enumFromInt(view.checklist[i].jump));
                        }
                    },
                    else => {},
                },
                else => {},
            },
            .quit => switch (key) {
                .escape => self.modal = .none,
                .char => |ch| switch (ch) {
                    's' => {
                        self.modal = .none;
                        self.store.player_id = self.player_id;
                        self.store.save(&self.gs.?) catch |err| {
                            self.say(.crit, "save failed: {s}", .{@errorName(err)});
                            return;
                        };
                        self.leaveGame();
                    },
                    'r' => {
                        self.modal = .none;
                        self.leaveGame();
                    },
                    else => {},
                },
                else => {},
            },
            .game_over => switch (key) {
                .enter, .escape => {
                    self.modal = .none;
                    self.leaveGame();
                },
                else => {},
            },
            .install_part => |uid| switch (key) {
                .escape => self.modal = .none,
                .down => self.modal_cursor +|= 1,
                .up => self.modal_cursor -|= 1,
                .enter => {
                    const cands = try q.installCandidates(self.a(), &self.gs.?, uid);
                    if (cands.len == 0) return;
                    const c = cands[@min(self.modal_cursor, cands.len - 1)];
                    self.modal = .{ .install_loc = .{ .unit = uid, .part = c.key } };
                    self.modal_cursor = 0;
                },
                .char => |ch| switch (ch) {
                    'j' => self.modal_cursor +|= 1,
                    'k' => self.modal_cursor -|= 1,
                    else => {},
                },
                else => {},
            },
            .install_loc => |il| switch (key) {
                .escape => {
                    self.modal = .{ .install_part = il.unit };
                    self.modal_cursor = 0;
                },
                .down => self.modal_cursor +|= 1,
                .up => self.modal_cursor -|= 1,
                .enter => {
                    const locs = try q.installLocations(self.a(), &self.gs.?, il.unit, il.part);
                    if (locs.len == 0) return;
                    const l = locs[@min(self.modal_cursor, locs.len - 1)];
                    if (!l.legal) {
                        self.say(.amber, "the rules refuse {s} in {s} — pick a green location", .{ il.part, @tagName(l.location) });
                        return;
                    }
                    self.modal = .none;
                    try self.exec(.{ .refit_install = .{ .unit = il.unit, .location = l.location, .part_key = il.part } });
                    self.say(.good, "staged: install {s} in {s} — Enter in the Lab commits it to a bay", .{ il.part, @tagName(l.location) });
                },
                .char => |ch| switch (ch) {
                    'j' => self.modal_cursor +|= 1,
                    'k' => self.modal_cursor -|= 1,
                    else => {},
                },
                else => {},
            },
            .sell_unit => |uid| switch (key) {
                .escape => self.modal = .none,
                .char => |ch| if (ch == 'y') {
                    self.modal = .none;
                    try self.exec(.{ .sell_unit = uid });
                    self.say(.amber, "hull #{d} sold", .{@intFromEnum(uid)});
                },
                else => {},
            },
            .sell_hq => |hid| switch (key) {
                .escape => self.modal = .none,
                .char => |ch| if (ch == 'y') {
                    self.modal = .none;
                    try self.exec(.{ .sell_hq = hid });
                    self.hq_sel = 0;
                    self.say(.amber, "HQ sold off", .{});
                },
                else => {},
            },
            .disband => |fid| switch (key) {
                .escape => self.modal = .none,
                .char => |ch| if (ch == 'y') {
                    self.modal = .none;
                    try self.exec(.{ .disband_company = fid });
                    self.cur(0).* = 0;
                    self.say(.amber, "company disbanded", .{});
                },
                else => {},
            },
            .fire => |id| switch (key) {
                .escape => self.modal = .none,
                .char => |ch| if (ch == 'y') {
                    self.modal = .none;
                    const name = try q.personName(self.a(), &self.gs.?, id);
                    try self.exec(.{ .fire = id });
                    self.say(.amber, "{s} has left the outfit", .{name});
                },
                else => {},
            },
            .seat => |id| switch (key) {
                .escape => self.modal = .none,
                .down => self.modal_cursor +|= 1,
                .up => self.modal_cursor -|= 1,
                .enter => {
                    const seats = try q.openSeats(self.a(), &self.gs.?, id);
                    self.modal = .none;
                    if (seats.len == 0) return;
                    const s = seats[@min(self.modal_cursor, seats.len - 1)];
                    try self.exec(.{ .assign = .{ .unit = s.unit, .slot = s.slot, .person = id } });
                    self.say(.good, "assigned as {s} of #{d}", .{ @tagName(s.slot), @intFromEnum(s.unit) });
                },
                .char => |ch| switch (ch) {
                    'j' => self.modal_cursor +|= 1,
                    'k' => self.modal_cursor -|= 1,
                    else => {},
                },
                else => {},
            },
            .emblem => switch (key) {
                .escape => self.modal = .none,
                .down => self.modal_cursor +|= 1,
                .up => self.modal_cursor -|= 1,
                .enter => {
                    self.modal = .none;
                    const i = self.modal_cursor;
                    if (i < emblems.len) {
                        try self.applyEmblem(emblems[i].name);
                        self.say(.good, "emblem set to preset {s}", .{emblems[i].name});
                    } else if (i - emblems.len < self.logos.len) {
                        const path = self.logos[i - emblems.len];
                        const bytes = emblem_mod.readFile(self.io, self.gpa, path) catch |err| {
                            self.say(.crit, "could not read {s}: {s}", .{ path, @errorName(err) });
                            return;
                        };
                        defer self.gpa.free(bytes);
                        if (!png.isPng(bytes)) {
                            self.say(.crit, "{s} is not a PNG", .{path});
                            return;
                        }
                        try self.applyEmblem(bytes);
                        self.say(.good, "emblem set from {s}{s}", .{ path, if (self.emblem == null) " (could not decode it — 8-bit non-interlaced PNG only)" else "" });
                    }
                },
                .char => |ch| switch (ch) {
                    'j' => self.modal_cursor +|= 1,
                    'k' => self.modal_cursor -|= 1,
                    else => {},
                },
                else => {},
            },
            .decision => |idx| switch (key) {
                .escape => self.modal = .none,
                .char => |ch| if (ch >= '1' and ch <= '9') {
                    const choice: usize = ch - '1';
                    self.modal = .none;
                    try self.exec(.{ .resolve_decision = .{ .event_index = idx, .choice = choice } });
                    self.say(.good, "decision recorded", .{});
                },
                else => {},
            },
            .input => |kind| switch (key) {
                .escape => self.modal = .none,
                .backspace => self.input.pop(),
                .tab => if (kind == .command) try self.completeCommand(),
                .enter => {
                    self.modal = .none;
                    try self.submitInput(kind);
                },
                .char => |ch| self.input.push(ch),
                else => {},
            },
        }
    }

    fn leaveGame(self: *App) void {
        if (self.gs) |*g| g.deinit();
        self.gs = null;
        self.refreshEmblem();
        self.mode = .welcome;
        self.focus = 1;
        self.say(.dim, "back at the welcome screen", .{});
    }

    fn submitInput(self: *App, kind: InputKind) !void {
        const al = self.a();
        const text = std.mem.trim(u8, self.input.slice(), " ");
        switch (kind) {
            .new_player => {
                if (text.len == 0) return;
                const id = try self.store.createPlayer(text);
                self.player_id = id;
                const players = try self.store.listPlayers(al);
                for (players, 0..) |p, i| if (p.id == id) {
                    self.cur(0).* = i;
                };
                self.say(.good, "player \"{s}\" created", .{text});
            },
            .delete_campaign => {
                const campaigns = try self.store.listCampaignsOf(al, self.player_id);
                if (campaigns.len == 0) return;
                const c = campaigns[@min(self.cur(1).*, campaigns.len - 1)];
                if (!std.mem.eql(u8, text, c.name)) {
                    self.say(.amber, "name did not match — nothing deleted", .{});
                    return;
                }
                try self.store.deleteCampaign(c.id);
                self.say(.good, "deleted \"{s}\"", .{c.name});
            },
            .delete_player => {
                const players = try self.store.listPlayers(al);
                for (players) |p| {
                    if (p.id == self.player_id) {
                        if (!std.mem.eql(u8, text, p.name)) {
                            self.say(.amber, "name did not match — nothing deleted", .{});
                            return;
                        }
                        try self.store.deletePlayer(p.id);
                        self.say(.good, "deleted player \"{s}\" and their campaigns", .{p.name});
                        self.player_id = 0;
                        self.cur(0).* = 0;
                        self.pickDefaultPlayer();
                        return;
                    }
                }
            },
            .accept_company => {
                const g = &self.gs.?;
                const view = try q.contracts(al, g);
                if (view.board.len == 0) return;
                const id = std.fmt.parseInt(u32, text, 10) catch {
                    self.say(.amber, "enter a company id", .{});
                    return;
                };
                try self.exec(.{ .accept_contract = .{ .offer_index = view.board[@min(self.cur(0).*, view.board.len - 1)].index, .company = @enumFromInt(id) } });
                self.say(.good, "accepted", .{});
            },
            .command => try self.runCommandLine(text),
        }
    }

    // --------------------------------------------------------------- commands

    /// Tab completion on the command line: verbs first, then ids and names
    /// the sim knows (sites, facilities, roles, skills, parts, worlds).
    fn completeCommand(self: *App) !void {
        const al = self.a();
        const line = self.input.slice();
        const start: usize = if (std.mem.lastIndexOfScalar(u8, line, ' ')) |i| i + 1 else 0;
        const prefix = line[start..];
        var cands: std.ArrayListUnmanaged([]const u8) = .empty;
        if (start == 0) {
            for (verbs) |v| if (std.mem.startsWith(u8, v, prefix)) try cands.append(al, v);
        } else {
            const g = &self.gs.?;
            var pool: std.ArrayListUnmanaged([]const u8) = .empty;
            try pool.append(al, "outfit");
            try pool.append(al, "pilot");
            try pool.append(al, "tech");
            var hit = g.hqs.iterator();
            while (hit.next()) |e| try pool.append(al, try std.fmt.allocPrint(al, "hq:{d}", .{@intFromEnum(e.value_ptr.id)}));
            var fit = g.forces.iterator();
            while (fit.next()) |e| if (e.value_ptr.echelon == .company) try pool.append(al, try std.fmt.allocPrint(al, "co:{d}", .{@intFromEnum(e.value_ptr.id)}));
            inline for (@typeInfo(game.hq.FacilityKind).@"enum".fields) |f| try pool.append(al, f.name);
            inline for (@typeInfo(game.person.Role).@"enum".fields) |f| try pool.append(al, f.name);
            inline for (@typeInfo(types.SkillType).@"enum".fields) |f| try pool.append(al, f.name);
            for (game.part.catalog) |p| try pool.append(al, p.key);
            for (game.planet.catalog) |p| try pool.append(al, p.key);
            for (pool.items) |c| if (std.mem.startsWith(u8, c, prefix)) try cands.append(al, c);
        }
        if (cands.items.len == 0) {
            self.say(.dim, "no completion for '{s}'", .{prefix});
            return;
        }
        var common = cands.items[0];
        for (cands.items[1..]) |c| {
            var n: usize = 0;
            while (n < common.len and n < c.len and common[n] == c[n]) : (n += 1) {}
            common = common[0..n];
        }
        if (common.len > prefix.len or cands.items.len == 1) {
            const rebuilt = try std.fmt.allocPrint(al, "{s}{s}{s}", .{ line[0..start], common, if (cands.items.len == 1) " " else "" });
            self.input.set(rebuilt);
        }
        if (cands.items.len > 1) {
            var shown: std.ArrayListUnmanaged(u8) = .empty;
            for (cands.items[0..@min(cands.items.len, 14)], 0..) |c, i| {
                if (i > 0) try shown.appendSlice(al, "  ");
                try shown.appendSlice(al, c);
            }
            if (cands.items.len > 14) try shown.appendSlice(al, "  …");
            self.say(.dim, "{s}", .{shown.items});
        } else {
            self.msg.len = 0;
        }
    }

    fn runCommandLine(self: *App, line: []const u8) !void {
        if (line.len == 0) return;
        var tokens = std.mem.tokenizeScalar(u8, line, ' ');
        const verb = tokens.next() orelse return;
        const g = &self.gs.?;
        const eq = std.mem.eql;

        if (eq(u8, verb, "day")) {
            const n = std.fmt.parseInt(u32, tokens.next() orelse "1", 10) catch 1;
            return self.advance(n);
        }
        if (eq(u8, verb, "save")) {
            self.store.player_id = self.player_id;
            self.store.save(g) catch |err| {
                self.say(.crit, "save failed: {s}", .{@errorName(err)});
                return;
            };
            self.say(.good, "saved campaign [{d}] at day {d}", .{ g.campaign_id, g.clock.day_index });
            return;
        }
        if (eq(u8, verb, "quit")) {
            self.modal = .quit;
            return;
        }
        if (eq(u8, verb, "help")) {
            self.modal = .help;
            return;
        }
        if (eq(u8, verb, "settings")) {
            self.modal = .settings;
            return;
        }
        if (eq(u8, verb, "emblem")) {
            try self.loadLogoList();
            self.modal_cursor = 0;
            self.modal = .emblem;
            return;
        }
        const cmd = parseCommand(verb, &tokens) catch |err| {
            self.say(.amber, "{s}", .{@errorName(err)});
            return;
        };
        if (cmd) |c| {
            const before = self.msg.len;
            try self.exec(c);
            if (self.msg.len == before) self.say(.good, "done: {s}", .{verb});
        } else {
            self.say(.amber, "unknown verb '{s}' — see ? for the list, or use the CLI (--repl) for the rest", .{verb});
        }
    }

    const ParseError = error{ BadArguments, BadSite, BadNumber };

    fn parseSite(tok: []const u8) ParseError!types.Site {
        if (std.mem.eql(u8, tok, "outfit")) return .outfit;
        if (std.mem.startsWith(u8, tok, "co:")) return .{ .company = @enumFromInt(std.fmt.parseInt(u32, tok[3..], 10) catch return error.BadSite) };
        if (std.mem.startsWith(u8, tok, "hq:")) return .{ .hq = @enumFromInt(std.fmt.parseInt(u32, tok[3..], 10) catch return error.BadSite) };
        return error.BadSite;
    }

    fn parseTreasury(tok: []const u8) ParseError!Treasury {
        return switch (try parseSite(tok)) {
            .outfit => .outfit,
            .hq => |id| .{ .hq = id },
            .company => |id| .{ .company = id },
        };
    }

    fn num(comptime T: type, tok: ?[]const u8) ParseError!T {
        return std.fmt.parseInt(T, tok orelse return error.BadArguments, 10) catch return error.BadNumber;
    }

    fn need(tok: ?[]const u8) ParseError![]const u8 {
        return tok orelse error.BadArguments;
    }

    fn parseCommand(verb: []const u8, tokens: *std.mem.TokenIterator(u8, .scalar)) ParseError!?Command {
        const eq = std.mem.eql;
        if (eq(u8, verb, "transfer")) {
            return .{ .transfer = .{ .from = try parseTreasury(try need(tokens.next())), .to = try parseTreasury(try need(tokens.next())), .amount = try num(i64, tokens.next()) } };
        }
        if (eq(u8, verb, "admit")) return .{ .admit = @enumFromInt(try num(u32, tokens.next())) };
        if (eq(u8, verb, "depot")) return .{ .depot = @enumFromInt(try num(u32, tokens.next())) };
        if (eq(u8, verb, "move")) return .{ .move_unit = .{ .unit = @enumFromInt(try num(u32, tokens.next())), .force = @enumFromInt(try num(u32, tokens.next())) } };
        if (eq(u8, verb, "newlance")) {
            const site = try parseSite(try need(tokens.next()));
            if (site != .company) return error.BadSite;
            const name = tokens.rest();
            if (name.len == 0) return error.BadArguments;
            return .{ .new_lance = .{ .company = site.company, .name = name } };
        }
        if (eq(u8, verb, "role")) {
            const fid: types.ForceId = @enumFromInt(try num(u32, tokens.next()));
            const role = std.meta.stringToEnum(game.force.LanceRole, try need(tokens.next())) orelse return error.BadArguments;
            return .{ .set_role = .{ .force = fid, .role = role } };
        }
        if (eq(u8, verb, "repay")) return .{ .repay_loan = .{ .index = try num(usize, tokens.next()), .amount = try num(i64, tokens.next()) } };
        if (eq(u8, verb, "sell")) return .{ .sell_unit = @enumFromInt(try num(u32, tokens.next())) };
        if (eq(u8, verb, "sellstock")) {
            const site = try parseSite(try need(tokens.next()));
            if (site != .hq) return error.BadSite;
            const part = try need(tokens.next());
            const qty = std.fmt.parseInt(u32, tokens.next() orelse "1", 10) catch return error.BadNumber;
            return .{ .sell_stock = .{ .hq = site.hq, .part_key = part, .quantity = qty } };
        }
        if (eq(u8, verb, "sellhq")) {
            const site = try parseSite(try need(tokens.next()));
            if (site != .hq) return error.BadSite;
            return .{ .sell_hq = site.hq };
        }
        if (eq(u8, verb, "disband")) {
            const site = try parseSite(try need(tokens.next()));
            if (site != .company) return error.BadSite;
            return .{ .disband_company = site.company };
        }
        if (eq(u8, verb, "policy")) {
            return .{ .set_policy = .{ .entity = try parseTreasury(try need(tokens.next())), .floor = try num(i64, tokens.next()), .monthly_cap = try num(i64, tokens.next()) } };
        }
        if (eq(u8, verb, "supplypolicy")) {
            const site = try parseSite(try need(tokens.next()));
            if (site != .company) return error.BadSite;
            const min_days = try num(u16, tokens.next());
            const tons = try num(u32, tokens.next());
            const battles: u8 = if (tokens.next()) |t| (std.fmt.parseInt(u8, t, 10) catch return error.BadNumber) else 0;
            return .{ .set_supply_policy = .{ .company = site.company, .min_days = min_days, .tons = tons, .ammo_battles = battles } };
        }
        if (eq(u8, verb, "stockpolicy")) {
            const site = try parseSite(try need(tokens.next()));
            if (site != .hq) return error.BadSite;
            const part = try need(tokens.next());
            const min = try num(u32, tokens.next());
            const target = std.fmt.parseInt(u32, tokens.next() orelse "0", 10) catch return error.BadNumber;
            return .{ .set_stock_policy = .{ .hq = site.hq, .part_key = part, .min = min, .target = if (target == 0 and min > 0) min * 2 else target } };
        }
        if (eq(u8, verb, "autoadmit")) {
            const arg = tokens.next() orelse "on";
            return .{ .set_auto_admit = eq(u8, arg, "on") or eq(u8, arg, "1") or eq(u8, arg, "yes") };
        }
        if (eq(u8, verb, "loan")) {
            return .{ .take_loan = .{ .principal = try num(i64, tokens.next()), .term_months = try num(u16, tokens.next()) } };
        }
        if (eq(u8, verb, "accept")) {
            const idx = try num(usize, tokens.next());
            const site = try parseSite(try need(tokens.next()));
            if (site != .company) return error.BadSite;
            return .{ .accept_contract = .{ .offer_index = idx, .company = site.company } };
        }
        if (eq(u8, verb, "resolve")) {
            return .{ .resolve_decision = .{ .event_index = try num(usize, tokens.next()), .choice = (try num(usize, tokens.next())) -| 1 } };
        }
        if (eq(u8, verb, "order")) {
            const part = try need(tokens.next());
            const qty = std.fmt.parseInt(u32, tokens.next() orelse "1", 10) catch return error.BadNumber;
            const dest: ?types.Site = if (tokens.next()) |t| try parseSite(t) else null;
            return .{ .order_part = .{ .part_key = part, .quantity = qty, .dest = dest } };
        }
        if (eq(u8, verb, "ship")) {
            return .{ .ship_stock = .{ .part_key = try need(tokens.next()), .quantity = try num(u32, tokens.next()), .from = try parseSite(try need(tokens.next())), .to = try parseSite(try need(tokens.next())) } };
        }
        if (eq(u8, verb, "buy")) return .{ .buy_listing = try num(usize, tokens.next()) };
        if (eq(u8, verb, "assign") or eq(u8, verb, "unassign")) {
            const unit: types.UnitId = @enumFromInt(try num(u32, tokens.next()));
            const slot = std.meta.stringToEnum(game.state.Slot, try need(tokens.next())) orelse return error.BadArguments;
            if (verb[0] == 'u') return .{ .unassign = .{ .unit = unit, .slot = slot } };
            return .{ .assign = .{ .unit = unit, .slot = slot, .person = @enumFromInt(try num(u32, tokens.next())) } };
        }
        if (eq(u8, verb, "autoassign")) {
            const site = try parseSite(try need(tokens.next()));
            if (site != .company) return error.BadSite;
            return .{ .auto_assign = site.company };
        }
        if (eq(u8, verb, "autostaff")) {
            const site = try parseSite(try need(tokens.next()));
            if (site != .hq) return error.BadSite;
            return .{ .autostaff = site.hq };
        }
        if (eq(u8, verb, "upgrade")) {
            const site = try parseSite(try need(tokens.next()));
            if (site != .hq) return error.BadSite;
            const kind = std.meta.stringToEnum(game.hq.FacilityKind, try need(tokens.next())) orelse return error.BadArguments;
            return .{ .upgrade_facility = .{ .hq = site.hq, .kind = kind } };
        }
        if (eq(u8, verb, "tier")) {
            const site = try parseSite(try need(tokens.next()));
            if (site != .hq) return error.BadSite;
            return .{ .upgrade_tier = site.hq };
        }
        if (eq(u8, verb, "fabricate")) {
            const site = try parseSite(try need(tokens.next()));
            if (site != .hq) return error.BadSite;
            const part = try need(tokens.next());
            const qty = std.fmt.parseInt(u32, tokens.next() orelse "1", 10) catch return error.BadNumber;
            return .{ .fabricate = .{ .hq = site.hq, .part_key = part, .quantity = qty } };
        }
        if (eq(u8, verb, "hire")) return .{ .hire_candidate = try num(usize, tokens.next()) };
        if (eq(u8, verb, "recruit")) {
            const role = std.meta.stringToEnum(game.person.Role, try need(tokens.next())) orelse return error.BadArguments;
            return .{ .recruit = role };
        }
        if (eq(u8, verb, "fire")) return .{ .fire = @enumFromInt(try num(u32, tokens.next())) };
        if (eq(u8, verb, "post")) {
            const pid: types.PersonId = @enumFromInt(try num(u32, tokens.next()));
            const site = try parseSite(try need(tokens.next()));
            if (site != .hq) return error.BadSite;
            return .{ .post_person = .{ .person = pid, .hq = site.hq } };
        }
        if (eq(u8, verb, "train")) {
            const pid: types.PersonId = @enumFromInt(try num(u32, tokens.next()));
            const skill = std.meta.stringToEnum(types.SkillType, try need(tokens.next())) orelse return error.BadArguments;
            return .{ .train = .{ .person = pid, .skill = skill } };
        }
        if (eq(u8, verb, "triage")) return .{ .triage = .{ .person = @enumFromInt(try num(u32, tokens.next())), .priority = try num(u8, tokens.next()) } };
        if (eq(u8, verb, "leave")) return .{ .leave = .{ .person = @enumFromInt(try num(u32, tokens.next())), .days = try num(u16, tokens.next()) } };
        if (eq(u8, verb, "mothball")) return .{ .mothball = @enumFromInt(try num(u32, tokens.next())) };
        if (eq(u8, verb, "activate")) return .{ .reactivate = @enumFromInt(try num(u32, tokens.next())) };
        if (eq(u8, verb, "complete")) return .{ .complete_contract = @enumFromInt(try num(u32, tokens.next())) };
        if (eq(u8, verb, "recall")) {
            const site = try parseSite(try need(tokens.next()));
            if (site != .company) return error.BadSite;
            return .{ .recall_company = site.company };
        }
        if (eq(u8, verb, "found")) {
            const planet = try need(tokens.next());
            const name = tokens.rest();
            if (name.len == 0) return error.BadArguments;
            return .{ .found_hq = .{ .name = name, .planet_key = planet } };
        }
        if (eq(u8, verb, "link")) {
            const a_site = try parseSite(try need(tokens.next()));
            const b_site = try parseSite(try need(tokens.next()));
            if (a_site != .hq or b_site != .hq) return error.BadSite;
            const lvl = std.fmt.parseInt(u8, tokens.next() orelse "1", 10) catch return error.BadNumber;
            return .{ .link = .{ .a = a_site.hq, .b = b_site.hq, .level = lvl } };
        }
        if (eq(u8, verb, "assignco")) {
            const co = try parseSite(try need(tokens.next()));
            const hq_site = try parseSite(try need(tokens.next()));
            if (co != .company or hq_site != .hq) return error.BadSite;
            return .{ .assign_company = .{ .company = co.company, .hq = hq_site.hq } };
        }
        if (eq(u8, verb, "newco")) {
            const name = tokens.rest();
            if (name.len == 0) return error.BadArguments;
            return .{ .new_company = name };
        }
        if (eq(u8, verb, "newco@")) {
            const site = try parseSite(try need(tokens.next()));
            if (site != .hq) return error.BadSite;
            const name = tokens.rest();
            if (name.len == 0) return error.BadArguments;
            return .{ .new_company_at = .{ .name = name, .hq = site.hq } };
        }
        if (eq(u8, verb, "xfer")) {
            const what = try need(tokens.next());
            const id = try num(u32, tokens.next());
            const site = try parseSite(try need(tokens.next()));
            if (site != .company) return error.BadSite;
            if (eq(u8, what, "unit")) return .{ .transfer_unit = .{ .unit = @enumFromInt(id), .to_company = site.company } };
            return .{ .transfer_person = .{ .person = @enumFromInt(id), .to_force = site.company } };
        }
        if (eq(u8, verb, "rename")) {
            const what = try need(tokens.next());
            const name = tokens.rest();
            if (name.len == 0) return error.BadArguments;
            if (eq(u8, what, "outfit")) return .{ .rename_outfit = name };
            const fid = std.fmt.parseInt(u32, what, 10) catch return error.BadNumber;
            return .{ .rename_force = .{ .force = @enumFromInt(fid), .name = name } };
        }
        if (eq(u8, verb, "refit")) {
            const unit: types.UnitId = @enumFromInt(try num(u32, tokens.next()));
            const op = try need(tokens.next());
            if (eq(u8, op, "remove")) return .{ .refit_remove = .{ .unit = unit, .slot_key = try need(tokens.next()) } };
            if (eq(u8, op, "install")) {
                const loc = game.meklab.parseLocation(try need(tokens.next())) orelse return error.BadArguments;
                return .{ .refit_install = .{ .unit = unit, .location = loc, .part_key = try need(tokens.next()) } };
            }
            if (eq(u8, op, "clear")) return .{ .refit_clear = unit };
            if (eq(u8, op, "commit")) return .{ .refit_commit = unit };
            return error.BadArguments;
        }
        return null;
    }

    fn errorText(err: anyerror) []const u8 {
        return switch (err) {
            error.InsufficientTreasury => "not enough money in that treasury — transfer funds first",
            error.KeepStocked => "that would drop the line under its keep-stocked minimum — lower the policy first (K)",
            error.StorageFull => "the destination cannot hold that tonnage",
            error.CompanyDeployed => "that company is deployed",
            error.NotReachable => "outside your influence rings and beachhead bands",
            error.CapacityFull => "that HQ is at capacity",
            error.NoTrainingGround => "training needs a training ground at the home HQ",
            error.ObjectivesNotMet => "objectives are not met yet",
            error.IllegalFit => "the refit plan breaks the construction rules",
            error.RefitClassTooHigh => "the refit class exceeds this HQ's bay ceiling",
            error.MissingParts => "parts missing — order or fabricate them first",
            error.NoSuchOffer => "no such offer on the board",
            error.NotACompany => "that force is not a company",
            error.UnknownUnit => "no such hull",
            error.UnknownPerson => "no such person",
            error.NoTechSlot => "that hull takes no tech",
            error.WrongRole => "wrong role for that seat",
            error.Unavailable => "that person is unavailable",
            error.Insolvent => "the outfit treasury is negative — take a loan (Ledger, L) or sell assets (Forces $, X · HQ $) before the day can end",
            error.Bankrupt => "the outfit is bankrupt",
            error.CreditExceeded => "that exceeds the remaining credit line (see the Ledger)",
            error.LastHq => "you cannot sell your only HQ",
            error.HqInUse => "reassign the companies at that HQ first (:assignco co:N hq:M)",
            error.NotWounded => "that person is not wounded",
            error.NoSuchLoan => "no such loan (or nothing to repay)",
            error.NoSuchListing => "that listing is gone",
            error.TooManyLances => "that lance is full (4 hulls), or the HQ allows no more lances — :newlance co:N <name> raises one",
            error.SameForce => "that hull belongs to another company — x moves it between companies",
            error.NothingToRepair => "that hull has no structural damage — the Lab handles gear, the depot handles structure",
            error.MissingComponents => "structural components missing at the home HQ — order or fabricate them on the Market screen first",
            error.NoBay => "no mek bay that can do structural work — a regional HQ with a mek_bay is needed",
            error.UnitAway => "that hull is away from home — depot work happens at the home HQ",
            error.UnitDeployed => "that hull is with a deployed company — bring the company home first (HQ work like fabrication and orders is unaffected)",
            error.PersonDeployed => "that person is deployed with their company",
            else => @errorName(err),
        };
    }
};

pub const Options = struct {
    /// Box-drawing and block glyphs replaced by ASCII (terminals that draw
    /// them double-width).
    ascii: bool = false,
    /// Skip the title screen (tests, scripts).
    no_splash: bool = false,
    /// Don't start the soundtrack at all.
    no_music: bool = false,
};

/// Entry point from main: open the store, take the terminal, run the app.
pub fn run(io: std.Io, gpa: std.mem.Allocator, store_path: [:0]const u8, options: Options) !void {
    const store = game.store.Store.open(store_path) catch |err| {
        std.debug.print("could not open save store '{s}': {s}\n", .{ store_path, @errorName(err) });
        return err;
    };
    defer store.close();

    var out_buf: [1 << 16]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var term = try Term.init(&stdout.interface);
    defer term.deinit();

    var app = try App.init(gpa, io, &term, store);
    defer app.deinit();
    app.screen.ascii = options.ascii;
    app.show_splash = !options.no_splash;
    if (!options.no_music) {
        const player = music_mod.Player.init(io, gpa, "data/music");
        if (player.available()) app.music = player else {
            var p = player;
            p.deinit();
        }
    }
    try app.run();
}

test "size tiers follow the documented thresholds" {
    try std.testing.expectEqual(Tier.full, tierFor(200, 50));
    try std.testing.expectEqual(Tier.wide, tierFor(170, 45));
    try std.testing.expectEqual(Tier.compact, tierFor(118, 36));
    try std.testing.expectEqual(Tier.minimum, tierFor(80, 24));
}

test "command line parses the common verbs" {
    var it = std.mem.tokenizeScalar(u8, "outfit hq:1 500000", ' ');
    const cmd = (try App.parseCommand("transfer", &it)).?;
    try std.testing.expectEqual(@as(i64, 500000), cmd.transfer.amount);
    try std.testing.expect(cmd.transfer.to == .hq);
    var it2 = std.mem.tokenizeScalar(u8, "3 tech 67", ' ');
    const cmd2 = (try App.parseCommand("assign", &it2)).?;
    try std.testing.expectEqual(@as(u32, 67), @intFromEnum(cmd2.assign.person));
    var it3 = std.mem.tokenizeScalar(u8, "galatea Forward Base", ' ');
    const cmd3 = (try App.parseCommand("found", &it3)).?;
    try std.testing.expectEqualStrings("Forward Base", cmd3.found_hq.name);
    var it4 = std.mem.tokenizeScalar(u8, "", ' ');
    try std.testing.expectEqual(@as(?Command, null), try App.parseCommand("frobnicate", &it4));
    var it5 = std.mem.tokenizeScalar(u8, "x", ' ');
    try std.testing.expectError(error.BadNumber, App.parseCommand("hire", &it5));
}
