//! The terminal client (Stage 12, docs/tui.md): a lobby (players →
//! campaigns → new-campaign wizard) and the in-game frame — tab bar,
//! status strip, panes, modals and a `:` command line. Strict boundary:
//! every mutation goes through `game.commands.execute`; every read goes
//! through `game.queries`. The screen is rebuilt from queries on each
//! event into a per-frame arena, so no view state can drift from the sim.
//! No MekHQ counterpart (MekHQ is Swing) (docs/mekhq-map.md).

const std = @import("std");
pub const game = @import("game");
const term_mod = @import("term.zig");
pub const keys = @import("keys.zig");
pub const screen_mod = @import("screen.zig");
pub const emblem_mod = @import("emblem.zig");
pub const png = @import("png.zig");
const music_mod = @import("music.zig");
const paths = @import("paths.zig");
const splash = @import("splash.zig");
pub const layout = @import("layout.zig");

pub const Term = term_mod.Term;
pub const Key = term_mod.Key;
pub const Screen = screen_mod.Screen;
pub const Rect = screen_mod.Rect;
pub const Style = screen_mod.Style;
pub const Table = screen_mod.Table;
pub const q = game.queries;
pub const types = game.types;
pub const Command = game.commands.Command;
const operations_mod = game.operations;
const Lobby = game.lobby.Lobby;
/// The session handle the lobby hands out; the client passes it to
/// `commands.execute` and `queries` and never looks inside.
pub const GameState = game.state.GameState;
pub const Treasury = game.state.Treasury;

pub const Tab = enum(u8) { desk, map, forces, contracts, ledger, supply, hq, lab, people, market };

/// The tab-strip label for a tab ("F1 Desk", …), read from the registry.
pub fn tabName(tab: Tab) []const u8 {
    return App.screen_table[@intFromEnum(tab)].name;
}

const Mode = enum { welcome, wizard, game };
const WizardStep = enum(u8) { commander, outfit, company, review };
/// Campaign start years on offer: the catalogue gates on it.
const start_years = [_]u16{ 3015, 3020, 3025, 3028, 3030 };

const InputKind = enum { command, new_player, delete_campaign, delete_player, raise_name };

const RaiseState = struct {
    company: types.ForceId = .none,
    hq: types.HqId = .none,
    /// Which line lance the hull picker fills.
    lance_idx: usize = 0,
    /// Listings passed on (hidden for the rest of the session).
    passed: [64]q.PassedKey = undefined,
    passed_len: usize = 0,
};

const Modal = union(enum) {
    none,
    /// Raise-a-company wizard: hulls per lance, support train, crews.
    raise_hulls,
    raise_support,
    raise_crews,
    end_turn,
    quit,
    decision: types.EventId,
    /// Battle orders for the engagement in view: the levers that can still
    /// change the fight, and confirming them.
    battle_orders: types.ContractId,
    input: InputKind,
    help,
    /// One command behind a yes/no (rule 36): the body quotes the stakes,
    /// y runs it through `execSay`, so the refusal guard lives once.
    confirm: Confirm,
    /// Pick an open pilot/tech seat for a person.
    seat: types.PersonId,
    /// Change the outfit's emblem: presets, then pictures from the logo dirs.
    emblem,
    /// Draw a 3 × 8 text crest cell by cell.
    emblem_editor,
    /// Hull detail as a modal (narrow terminals have no side pane).
    hull: types.UnitId,
    /// A person's record as a modal.
    record: types.PersonId,
    /// The outfit folded; the final save succeeded.
    game_over_saved,
    /// The outfit folded; the final save failed. Carries the error text
    /// (a static string from `cli.errorText`, safe across frames).
    game_over_failed: []const u8,
    /// Lab install: pick a part, then a location with the rules' verdict.
    install_part: types.UnitId,
    install_loc: struct { unit: types.UnitId, part: []const u8 },
    /// Lab install: location-scoped part picker (Enter on a free slot in the
    /// crit layout; shows only parts that legally fit the chosen location).
    install_at: struct { unit: types.UnitId, location: game.meklab.Location },
    /// Client settings (music).
    settings,
    /// HQ facility upgrade picker.
    upgrade: types.HqId,
    /// Lance picker for a hull.
    lance_pick: types.UnitId,
    /// Company picker for an offer (typed ContractId): readiest first.
    accept_pick: types.ContractId,
    /// The engagements still on record: pick one to read.
    battle_list,
    /// One engagement as a sheet — the fight, the field, the spoils, the
    /// trucks — rather than forty columns of log prose.
    after_action: types.BattleId,
    /// A contract's whole log, full screen and scrollable; the side pane
    /// clips it.
    contract_log: types.ContractId,
    /// One campaign-log entry, word-wrapped; the Desk's LOG pane clips
    /// long lines. The index is into `queries.desk().log`,
    /// revalidated against the query every frame (rule 40).
    log_entry: usize,
    /// Generic pickers: one look for every "choose one of these".
    pick_company: struct { what: enum { unit, person, stock }, id: u32, key_buf: [32]u8 = undefined, key_len: u8 = 0 },
    pick_hq: types.PersonId,
    pick_crew: types.UnitId,
    pick_unassign: types.UnitId,
    /// Part picker: picks the part, then the amount form asks the quantity.
    pick_part: struct { purpose: q.PartPurpose, site: types.Site, ship_to: ?types.ForceId = null },
    /// Amount form: every number the client asks for goes
    /// through one modal — fields with a default, a range and a step.
    amount: AmountForm,
    /// Negotiation term picker for an offer (typed ContractId).
    negotiate: types.ContractId,
    /// Every company's readiness report (fatigue, morale, wounded, banked XP, depot).
    readiness,
    /// The campaign in aggregate.
    summary,
    /// Browse the soundtracks and tracks; pick what plays.
    music,
    /// Pick commit/decline for an arc-contract operation.
    operation_pick: types.ContractId,
    /// Pick the mission intent for a specific operation before committing it.
    intent_pick: struct { contract: types.ContractId, operation: types.OperationId },
    /// Assign or clear lance tasks for a committed combat operation (P4e).
    task_pick: struct { contract: types.ContractId, operation: types.OperationId },
    /// Set the tempo posture for an available operation (P4f).
    tempo_pick: struct { contract: types.ContractId, operation: types.OperationId },
    /// Apply a command intervention to a committed combat operation (P4g).
    intervention_pick: struct { contract: types.ContractId, operation: types.OperationId },
    /// Read-only operation report for an arc contract: decided ops, decision costs, consequences (P4i.3).
    operation_report: types.ContractId,
    /// Hull lifecycle record: combat history, maintenance log, ownership chain (P3c.6).
    mech: MechRef,
    /// Read-only leaderboard of all NPC merc companies (Desk Reports hub).
    leaderboard,
    /// Detail sheet for one NPC merc company, entered from the leaderboard.
    leaderboard_detail: types.MercCompanyId,
};

const MechView = enum { summary, combat, maintenance, ownership };
const MechRef = struct { id: types.HullInstanceId, view: MechView = .summary };

/// Sub-view key/label table for the mech-detail modal.
/// One source for both the view rows and the listExtra dispatch (rule 20).
const mech_view_keys = [_]struct { view: MechView, key: u8, label: []const u8 }{
    .{ .view = .combat, .key = 'c', .label = "combat history" },
    .{ .view = .maintenance, .key = 'm', .label = "maintenance log" },
    .{ .view = .ownership, .key = 'o', .label = "ownership chain" },
};

/// A yes/no over one command. `id` is the subject the kind names.
const Confirm = struct {
    kind: enum { fire, sell_unit, sell_hq, disband, recall_breach },
    id: u32,
};

/// What a confirm shows and runs.
const ConfirmSpec = struct {
    title: []const u8,
    rows: []const []const u8,
    w: u16,
    h: u16,
    /// The command y runs and the past-tense line it earns.
    cmd: Command,
    done: []const u8,
    /// A second verb (s: strip instead of sell), if the dialog has one.
    alt: ?struct { cmd: Command, done: []const u8 } = null,
};

/// One number the amount form asks for.
pub const AmountField = struct {
    label: []const u8,
    value: i64,
    min: i64,
    max: i64,
    step: i64,
    /// Digits typed since the field was entered replace the default.
    typed: bool = false,
};

/// What an amount form runs when it is confirmed; every case becomes a
/// command line for the shared parser (sim/cli.zig), like a typed one.
pub const AmountAction = union(enum) {
    loan,
    repay: usize,
    transfer_to: Treasury,
    transfer_back: Treasury,
    policy: Treasury,
    supply_policy: types.ForceId,
    leave: types.PersonId,
    triage: types.PersonId,
    stock_policy: struct { hq: u32, key: []const u8 },
    fabricate: struct { hq: u32, key: []const u8 },
    order: struct { site: types.Site, key: []const u8 },
    ship: struct { from: u32, to: types.ForceId, key: []const u8 },
    sell: struct { hq: u32, key: []const u8 },
    shares,
};

pub const AmountForm = struct {
    /// Owned copies: the form outlives the frame arena the strings came from.
    title_buf: [96]u8 = undefined,
    title_len: u8 = 0,
    key_buf: [32]u8 = undefined,
    key_len: u8 = 0,
    action: AmountAction,
    fields: [3]AmountField,
    n: u8,
    cur: u8 = 0,

    pub fn title(self: *const AmountForm) []const u8 {
        return self.title_buf[0..self.title_len];
    }
    /// The part key behind order/ship/keep/sell/fabricate, owned here.
    pub fn key(self: *const AmountForm) []const u8 {
        return self.key_buf[0..self.key_len];
    }
};

/// Size tiers (docs/tui.md): the largest that fits decides how many panes
/// a screen shows. Narrow (< 120 cols) drops side panes; short (< 30
/// rows) drops the third band.
/// Completion's verbs: the client's own, then every command verb.
const verbs = game.cli.client_verbs.* ++ game.cli.verbs;

pub const Emblem = struct { name: []const u8, art: [3][]const u8 };
pub const emblems = [_]Emblem{
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

    pub fn slice(self: *const TextBuf) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set(self: *TextBuf, s: []const u8) void {
        const n = @min(s.len, self.buf.len);
        @memcpy(self.buf[0..n], s[0..n]);
        self.len = n;
    }

    fn push(self: *TextBuf, cp: u21) void {
        var tmp: [4]u8 = undefined;
        // best-effort: a code point that cannot be encoded is not typed.
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

const Placement = struct { x: u16, y: u16, cols: u16, rows: u16, kitty_id: u32 = 0, bytes: []const u8 = &.{} };

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    screen: Screen,
    store: Lobby,
    frame: std.heap.ArenaAllocator,
    lobby: std.heap.ArenaAllocator,
    /// The open campaign, owned by the lobby's `Session`; the client reaches
    /// it only through `state()` to hand to queries and commands.
    session: ?game.lobby.Session = null,
    running: bool = true,

    /// Where the loose runtime files were found (paths.zig); the wizard
    /// imports pictures from `asset_roots.logos`.
    asset_roots: paths.Roots = .{},

    // soundtrack and title screen
    music: ?music_mod.Player = null,
    /// Why there is no soundtrack when `music` is null (the files, or the player program).
    music_note: []const u8 = "no soundtrack loaded — start without --no-music and keep tracks in data/music/ or $IRON_LEDGER_DATA/music (one sub-directory per soundtrack)",
    /// The track announced last, so a change is said once.
    last_track: ?usize = null,
    show_splash: bool = true,
    // emblem display
    graphics: emblem_mod.Graphics = .none,
    emblem: ?emblem_mod.Emblem = null,
    placements: [64]Placement = undefined,
    n_placements: usize = 0,
    /// The cell editor's canvas, cursor and undo snapshot.
    ed_art: [3][8]u8 = @splat(@splat(' ')),
    ed_undo: [3][8]u8 = @splat(@splat(' ')),
    ed_x: u8 = 0,
    ed_y: u8 = 0,
    // wizard catalog grid
    logos: []const []const u8 = &.{},
    w_logo: usize = 0,
    /// Decoded thumbnails, one per entry in `logos`, each with a unique kitty
    /// id in the range 100..100+logos.len so they don't collide with the
    /// in-game emblem (id 1).  Allocated from `gpa`; freed in `deinit`.
    w_thumbs: []?emblem_mod.Emblem = &.{},
    /// First visible grid row (in units of 5-logo rows); updated by gridMove
    /// so the selected row stays inside the visible window.
    w_logo_top: usize = 0,
    /// When true the outfit name auto-fills from the selected catalog logo;
    /// set false once the player types to prevent clobbering a manual edit.
    w_outfit_auto: bool = true,

    mode: Mode = .welcome,
    step: WizardStep = .commander,
    tab: Tab = .desk,
    modal: Modal = .none,
    focus: u8 = 0,
    /// Cursor per tab per pane (welcome uses tab 0, wizard tab 1).
    cursor: [10][4]usize = [_][4]usize{[_]usize{0} ** 4} ** 10,
    /// Columns scrolled off a table pane's left, per screen and pane, like `cursor`.
    colscroll: [10][4]usize = [_][4]usize{[_]usize{0} ** 4} ** 10,
    /// The same for a modal's table.
    modal_colscroll: usize = 0,
    /// The after-action sheet returns to the list when it was opened from
    /// one, and to the screen when the turn dropped the player into it.
    battles_from_list: bool = false,
    /// The column scroll of the table drawn focused this frame, if any —
    /// what ←/→ move (a pane's cursor index and its focus index differ on
    /// some screens).
    /// The pane whose table columns ←/→ scroll this frame (set by the draw).
    focus_scroll: ?u8 = null,
    /// Bit mask of pane indices drawn this frame; set by `paneFocused`.
    panes_drawn: u16 = 0,
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
    /// Index into `start_years`.
    w_year: usize = 2,
    w_seed: u64 = 0,
    /// `--seed`: replaces the wall-clock entropy in the generated campaign's
    /// seed so scripted runs (docs/tui_smoke.py) are reproducible.
    seed_override: ?u64 = null,
    // screens
    ledger_sel: usize = 0,
    hq_sel: types.HqId = .none,
    hall_filter: q.HallFilter = .all,
    people_filter: q.HallFilter = .all,
    market_filter: q.MarketFilter = .all,
    map_cursor: usize = 0,
    /// Forces screen view: index into queries.toeViews (all, each company, unassigned).
    forces_view: usize = 0,
    /// Settings form: the highlighted row.
    settings_cursor: usize = 0,
    /// Forces side pane on a company row: DAMAGE, READINESS or MANNING (r cycles).
    forces_pane: enum { damage, readiness, manning } = .damage,
    /// The raise-a-company wizard's state.
    raise: RaiseState = .{},
    /// Days the open end-turn prompt ends on `n` (`N`, `:day 7`: a week).
    end_turn_days: u32 = 1,
    /// Star map zoom: 1 = every world fitted into the pane; 2/4/8 = that
    /// many times closer, centred on the cursor world.
    map_zoom: u8 = 1,
    /// Star-map colouring: by faction, industry, standing, or activity.
    map_color: enum { faction, industry, standing, activity } = .faction,
    lab_sel: usize = 0,
    modal_cursor: usize = 0,
    w_office: usize = 0,

    // ------------------------------------------------------------------ lifecycle

    pub fn init(gpa: std.mem.Allocator, io: std.Io, term: *Term, store: Lobby) !App {
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
        if (self.session) |*session| session.close();
        if (self.emblem) |*e| e.deinit(self.gpa);
        for (self.w_thumbs) |*slot| if (slot.*) |*e| e.deinit(self.gpa);
        if (self.w_thumbs.len > 0) self.gpa.free(self.w_thumbs);
        self.screen.deinit();
        self.frame.deinit();
        self.lobby.deinit();
    }

    /// Ask the terminal whether it speaks the kitty graphics protocol, and
    /// whether 24-bit colour is safe. Runs once, before the first frame.
    fn probeTerminal(self: *App) void {
        var buf: [256]u8 = undefined;
        const n = self.term.probe(emblem_mod.kitty_query, &buf, 250);
        if (emblem_mod.kittyReplyOk(buf[0..n])) self.graphics = .kitty else if (emblem_mod.detectIterm2()) self.graphics = .iterm2;
        self.screen.truecolor = emblem_mod.detectTruecolor() or self.graphics != .none;
    }

    pub fn run(self: *App) !void {
        self.w_name.set("Erik Kalmar");
        self.w_outfit.set("The Unforgiven");
        self.w_company.set("Alpha Company");
        try self.pickDefaultPlayer();
        self.probeTerminal();
        if (self.music) |*m| {
            m.setEnabled(self.store.getSetting("music", 1) != 0);
            m.setVolume(@intCast(std.math.clamp(self.store.getSetting("music_volume", 60), 0, 100)));
            const set = self.store.getSetting("music_set", -1);
            if (set >= 0 and set < m.sets.len) m.selectSet(@intCast(set));
            m.poll(); // the soundtrack starts with the title screen
        }
        if (self.show_splash) try self.runSplash();
        while (self.running) {
            if (self.term.tookResize()) {
                const size = self.term.size();
                try self.screen.resize(size.cols, size.rows);
                self.clampFocus();
            }
            try self.draw();
            const key = self.term.readKey(500);
            if (self.music) |*m| {
                m.poll();
                // A new track is worth a line in the status strip.
                if (m.enabled and m.current != null and m.current != self.last_track and m.child != null) {
                    self.last_track = m.current;
                    if (self.msg.len == 0) self.say(.dim, "♪ {s} — {s}   (M music · :music browse)", .{
                        q.plain(self.a(), m.nowPlaying() orelse "") catch "", // best-effort: OOM keeps the raw name out of markup
                        q.plain(self.a(), m.nowPlayingSet() orelse "") catch "", // best-effort: OOM keeps the raw name out of markup
                    });
                }
            }
            if (key == .none) continue;
            _ = self.frame.reset(.retain_capacity);
            self.handleKey(key) catch |err| self.say(.crit, "error: {s}", .{game.cli.errorText(err)});
        }
    }

    /// The open campaign, for queries and commands (a campaign is open).
    pub fn state(self: *App) *GameState {
        return self.session.?.state();
    }

    pub fn stateOrNull(self: *App) ?*GameState {
        return if (self.session) |session| session.state() else null;
    }

    pub fn a(self: *App) std.mem.Allocator {
        return self.frame.allocator();
    }

    /// Title screen: five seconds, or any key.
    fn runSplash(self: *App) !void {
        // std.Thread.getCurrentId() returns Thread.Id (u32/u64 by platform;
        // std/Thread.zig:279) — cross-platform replacement for getpid.
        var seed: u64 = @intCast(std.Thread.getCurrentId());
        const now = std.Io.Clock.now(.real, self.io);
        seed ^= @as(u64, @truncate(@as(u96, @bitCast(now.nanoseconds))));
        var prng = std.Random.DefaultPrng.init(seed);
        const idx = prng.random().uintLessThan(usize, splash.mechs.len);
        splash.draw(&self.screen, self.screen.ascii, idx);
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

    /// "♪ Track — soundtrack" for status strips, or "".
    fn nowPlayingLine(self: *App) ![]const u8 {
        const m = &(self.music orelse return "");
        if (!m.enabled) return "♪ off";
        const name = m.nowPlaying() orelse return "";
        return std.fmt.allocPrint(self.a(), "♪ {s} — {s}", .{ try q.plain(self.a(), name), try q.plain(self.a(), m.nowPlayingSet() orelse "") });
    }

    pub fn say(self: *App, style: Style, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.msg.buf, fmt, args) catch self.msg.buf[0..];
        self.msg.len = s.len;
        self.msg_style = style;
    }

    pub fn cur(self: *App, pane: u8) *usize {
        const t: usize = switch (self.mode) {
            .welcome => 8,
            .wizard => 9,
            .game => @intFromEnum(self.tab),
        };
        return &self.cursor[t][pane];
    }

    pub fn colScroll(self: *App, pane: u8) *usize {
        const t: usize = switch (self.mode) {
            .welcome => 8,
            .wizard => 9,
            .game => @intFromEnum(self.tab),
        };
        return &self.colscroll[t][pane];
    }

    fn pickDefaultPlayer(self: *App) !void {
        const players = try self.store.players(self.a());
        if (players.len > 0) self.player_id = players[0].id;
    }

    // ------------------------------------------------------------------ drawing

    fn draw(self: *App) !void {
        _ = self.frame.reset(.retain_capacity);
        self.screen.clear();
        self.n_placements = 0;
        self.focus_scroll = null;
        self.panes_drawn = 0;
        if (self.modal == .none) self.modal_colscroll = 0;
        const too_small = self.screen.cols < 80 or self.screen.rows < 24;
        if (too_small) {
            // Too small to lay out: say so instead of drawing fragments.
            var buf: [96]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "terminal {d}x{d} — IRON LEDGER needs at least 80x24 (100x30 plays well)", .{ self.screen.cols, self.screen.rows }) catch "terminal too small";
            self.screen.textPad(0, 0, self.screen.cols, msg, .amber);
        } else switch (self.mode) {
            .welcome => try self.drawWelcome(),
            .wizard => try self.drawWizard(),
            .game => try self.drawGame(),
        }
        const modal_open = self.modal != .none and !(self.modal == .input and self.modal.input == .command);
        if (!too_small) try self.drawModal();
        try self.screen.flush(self.term.out);
        if (self.graphics == .kitty) {
            try emblem_mod.kittyDeleteAll(self.term.out);
            // Pictures sit above text; keep them off while a modal is up.
            if (!modal_open) {
                for (self.placements[0..self.n_placements]) |p| {
                    if (p.kitty_id == 0) continue;
                    try emblem_mod.kittyPlace(self.term.out, p.kitty_id, p.x, p.y, p.cols, p.rows);
                }
            }
            try self.term.out.flush();
        } else if (self.graphics == .iterm2) {
            // iTerm2: the frame's text already cleared the cells; the
            // picture is re-sent with every frame it is visible in.
            if (!modal_open) {
                for (self.placements[0..self.n_placements]) |p| {
                    if (p.bytes.len == 0) continue;
                    try emblem_mod.itermPlace(self.term.out, self.gpa, p.bytes, p.x, p.y, p.cols, p.rows);
                }
            }
            try self.term.out.flush();
        }
    }

    fn currentEmblem(self: *App) ?*emblem_mod.Emblem {
        if (self.mode == .wizard) {
            if (self.w_logo < self.w_thumbs.len) {
                if (self.w_thumbs[self.w_logo] != null) return &self.w_thumbs[self.w_logo].?;
            }
            return null;
        }
        return if (self.emblem) |*e| e else null;
    }

    /// Draw the outfit's picture into a rect: a kitty placement (cells left
    /// blank) or half-block colour. Returns false when there is no picture.
    pub fn drawEmblem(self: *App, r: Rect) bool {
        const e = self.currentEmblem() orelse return false;
        if (r.w < 2 or r.h < 1) return false;
        if (self.graphics != .none) {
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
                    .kitty_id = e.kitty_id,
                    .bytes = e.bytes,
                };
                self.n_placements += 1;
            }
        } else {
            self.screen.blit(r, &e.img);
        }
        return true;
    }

    /// Load the campaign's emblem (a PNG stored on one of its forces).
    /// Decodes the new emblem before freeing the old; on failure the current
    /// emblem stays valid (rule 63). When there is no valid emblem to show
    /// (no live state, no outfit emblem, or non-PNG bytes) the current emblem
    /// is cleared so it does not bleed into a new campaign.
    fn refreshEmblem(self: *App) void {
        const g = self.stateOrNull() orelse {
            if (self.emblem) |*e| {
                // best-effort: freeing an optional graphics image.
                if (self.graphics == .kitty) emblem_mod.kittyForget(self.term.out, e.kitty_id) catch {};
                e.deinit(self.gpa);
                self.emblem = null;
            }
            return;
        };
        const bytes = q.outfitEmblem(g) orelse {
            if (self.emblem) |*e| {
                // best-effort: freeing an optional graphics image.
                if (self.graphics == .kitty) emblem_mod.kittyForget(self.term.out, e.kitty_id) catch {};
                e.deinit(self.gpa);
                self.emblem = null;
            }
            return;
        };
        if (!png.isPng(bytes)) {
            if (self.emblem) |*e| {
                // best-effort: freeing an optional graphics image.
                if (self.graphics == .kitty) emblem_mod.kittyForget(self.term.out, e.kitty_id) catch {};
                e.deinit(self.gpa);
                self.emblem = null;
            }
            return;
        }
        // Decode the replacement first; only on success replace the current emblem.
        // best-effort: without a decodable picture the preset emblem stays.
        const new_emblem = emblem_mod.Emblem.load(self.gpa, bytes, 1) catch return;
        if (self.emblem) |*e| {
            // best-effort: freeing an optional graphics image.
            if (self.graphics == .kitty) emblem_mod.kittyForget(self.term.out, e.kitty_id) catch {};
            e.deinit(self.gpa);
        }
        self.emblem = new_emblem;
        // best-effort: an optional graphics image; the half-block emblem still draws.
        if (self.graphics == .kitty) emblem_mod.kittyTransmit(self.term.out, self.gpa, 1, bytes) catch {};
    }

    pub fn body(self: *App) Rect {
        const s = &self.screen;
        return .{ .x = 0, .y = 2, .w = s.cols, .h = if (s.rows > 3) s.rows - 3 else 0 };
    }

    /// Side panes are dropped below this width.
    pub fn narrow(self: *App) bool {
        return layout.narrow(self.screen.cols);
    }

    /// Record that pane `idx` was drawn this frame and return whether it is
    /// focused.  Every screen draws its focusable panes through this call so
    /// that the structural test can verify panes_drawn == (1<<paneCount)-1.
    pub fn paneFocused(self: *App, idx: u8) bool {
        self.panes_drawn |= (@as(u16, 1) << @intCast(idx));
        return self.focus == idx;
    }

    /// Clamp `focus` to the panes actually rendered at the current terminal
    /// width.  Called in the resize handler and at the top of `drawGame`.
    fn clampFocus(self: *App) void {
        if (self.mode == .game) {
            const pc = self.paneCount();
            if (pc > 0 and self.focus >= pc) self.focus = pc - 1;
        }
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
    pub fn firstRow(cursor: usize, h: u16) usize {
        if (h == 0) return 0;
        return if (cursor >= h) cursor - h + 1 else 0;
    }

    pub fn listPane(self: *App, r: Rect, title: []const u8, items: []const []const u8, pane: u8, focused: bool, with_cursor: bool) void {
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
        const players = try self.store.players(al);
        const campaigns = try self.store.campaigns(al, self.player_id);
        const np_raw = self.nowPlaying();
        const np = if (np_raw.len > 0) q.plain(al, np_raw) catch np_raw else np_raw;
        // best-effort: a status label in a fixed buffer; too long leaves it blank.
        const right = std.fmt.bufPrint(&right_buf, "{s}{s}{d} players · {d} campaigns · schema v{d}", .{ if (np.len > 0) "♪ " else "", if (np.len > 0) np else "", players.len, campaigns.len, game.lobby.schema_version }) catch "";
        // (the separator between track and counts)
        var title_buf: [64]u8 = undefined;
        self.titleBar(std.fmt.bufPrint(&title_buf, "{s} · MERCENARY COMMAND CONSOLE", .{splash.game_name}) catch splash.game_name, right);

        const b = self.body();
        const pw: u16 = @min(30, b.w / 4);
        const top_h: u16 = if (b.h > 12) layout.two_thirds.of(b.h) else b.h;
        var prow: std.ArrayListUnmanaged([]const u8) = .empty;
        for (players) |p| {
            const mk: []const u8 = if (p.id == self.player_id) "{a}" else "";
            try prow.append(al, try std.fmt.allocPrint(al, "{s}{s}{{/}}  {d} campaign{s}", .{ mk, try p.name.markup(al), p.campaigns, if (p.campaigns == 1) "" else "s" }));
        }
        if (players.len == 0) try prow.append(al, try std.fmt.allocPrint(al, "{{d}}no players yet — {s}{{/}}", .{try keyHint(WelcomeAction, al, &welcome_bindings, .new_player, "creates one")}));
        self.listPane(.{ .x = b.x, .y = b.y, .w = pw, .h = top_h }, "PLAYERS", prow.items, 0, self.focus == 0, true);

        var crow: std.ArrayListUnmanaged([]const u8) = .empty;
        for (campaigns) |c| {
            try crow.append(al, try std.fmt.allocPrint(al, "{{a}}{s}{{/}}  ·  {s}  ·  day {d} ({s})  ·  save #{d}", .{ try c.name.markup(al), try c.commander.markup(al), c.day, c.date, c.save_seq }));
        }
        if (campaigns.len == 0) try crow.append(al, try std.fmt.allocPrint(al, "{{d}}no campaigns for this player — {s}{{/}}", .{try keyHint(WelcomeAction, al, &welcome_bindings, .new_campaign, "starts one")}));
        const cw: u16 = b.w - pw - 1;
        self.listPane(.{ .x = b.x + pw + 1, .y = b.y, .w = cw, .h = top_h }, "CAMPAIGNS", crow.items, 1, self.focus == 1, true);

        if (b.h > top_h + 3) {
            var snap: std.ArrayListUnmanaged([]const u8) = .empty;
            const ci = self.cur(1).*;
            if (campaigns.len > 0 and ci < campaigns.len) {
                const c = campaigns[ci];
                try snap.append(al, try std.fmt.allocPrint(al, "{{a}}{s}{{/}} — commander {s}", .{ try c.name.markup(al), try c.commander.markup(al) }));
                try snap.append(al, try std.fmt.allocPrint(al, "saved at day {d} · {s} · registry id {d}", .{ c.day, c.date, c.id }));
                try snap.append(al, "");
                try snap.append(al, try std.fmt.allocPrint(al, "{{d}}{s}{{/}}", .{try keyHint(WelcomeAction, al, &welcome_bindings, .open, "continue this campaign")}));
            } else {
                try snap.append(al, try std.fmt.allocPrint(al, "{{d}}select a campaign, or {s}{{/}}", .{try keyHint(WelcomeAction, al, &welcome_bindings, .new_campaign, "starts a new one")}));
            }
            self.listPane(.{ .x = b.x, .y = b.y + top_h, .w = b.w, .h = b.h - top_h }, "SNAPSHOT", snap.items, 2, false, false);
        }
        self.footer(try keys.footer(al, &.{&welcome_legend}));
    }

    fn drawWizard(self: *App) !void {
        var tbuf: [96]u8 = undefined;
        const title = std.fmt.bufPrint(&tbuf, "NEW CAMPAIGN · step {d} of 4 · {s}", .{ @intFromEnum(self.step) + 1, switch (self.step) {
            .commander => "Commander",
            .outfit => "Outfit & emblem",
            .company => "Company & back office",
            .review => "Review",
        } }) catch "NEW CAMPAIGN";
        self.titleBar(title, "");
        switch (self.step) {
            .commander => try self.drawWizardCommander(),
            .outfit => try self.drawWizardOutfit(),
            .company => try self.drawWizardCompany(),
            .review => try self.drawWizardReview(),
        }
    }

    fn drawWizardCommander(self: *App) !void {
        const al = self.a();
        const b = self.body();
        var rows: std.ArrayListUnmanaged([]const u8) = .empty;
        try rows.append(al, try std.fmt.allocPrint(al, "name        {s}{s}{s}{{/}}", .{ if (self.w_field == 0) "{s}" else "", try q.plain(al, self.w_name.slice()), if (self.w_field == 0) "_" else "" }));
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
        try rows.append(al, "");
        try rows.append(al, "start year");
        for (start_years, 0..) |y, i| {
            const sel = self.w_field == 3 and i == self.w_year;
            try rows.append(al, try std.fmt.allocPrint(al, "  {s}{s} {d}{s}{{/}}", .{ if (sel) "{s}" else if (i == self.w_year) "{a}" else "", if (i == self.w_year) ">" else " ", y, if (y == 3025) "  (the Succession Wars, TRO:3025)" else "" }));
        }
        const lw: u16 = @min(70, layout.minor.of(b.w));
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
        try info.append(al, try std.fmt.allocPrint(al, "{{a}}{d}{{/}}", .{start_years[self.w_year]}));
        try info.append(al, "The market, the house tables and the salvage field only what is in");
        try info.append(al, "service by this year; new designs are announced on New Year's Day.");
        try info.append(al, "");
        try info.append(al, "{d}the faction, profession and start year are permanent; names can change later{/}");
        _ = self.listPane(.{ .x = lw + 1, .y = b.y, .w = b.w - lw - 1, .h = b.h }, "WHAT THIS MEANS", info.items, 1, false, false);
        self.footer(try keys.footer(al, &.{&commander_legend}));
    }

    fn drawWizardOutfit(self: *App) !void {
        const al = self.a();
        const b = self.body();

        // Top pane: outfit name + company name fields (4 rows: border + 2 content + border).
        const top_h: u16 = 4;
        var top_rows: std.ArrayListUnmanaged([]const u8) = .empty;
        try top_rows.append(al, try std.fmt.allocPrint(al, "outfit name      {s}{s}{s}{{/}}", .{ if (self.w_field == 0) "{s}" else "", try q.plain(al, self.w_outfit.slice()), if (self.w_field == 0) "_" else "" }));
        try top_rows.append(al, try std.fmt.allocPrint(al, "first company    {s}{s}{s}{{/}}", .{ if (self.w_field == 1) "{s}" else "", try q.plain(al, self.w_company.slice()), if (self.w_field == 1) "_" else "" }));
        _ = self.listPane(.{ .x = 0, .y = b.y, .w = b.w, .h = top_h }, "OUTFIT", top_rows.items, 0, self.w_field < 2, false);

        // Grid pane: 5-column catalog thumbnail grid.
        const grid_y: u16 = b.y + top_h;
        const grid_h: u16 = b.h -| top_h;
        if (grid_h < 3) {
            self.footer(try keys.footer(al, &.{&outfit_legend}));
            return;
        }
        const grid_rect: Rect = .{ .x = 0, .y = grid_y, .w = b.w, .h = grid_h };
        const grid_inner = self.screen.pane(grid_rect, .{ .title = "CATALOG", .focused = self.w_field == 2 });

        if (self.logos.len == 0) {
            const hint = [_][]const u8{"{d}no logos found — drop a .png into a logos/ directory{/}"};
            self.screen.lines(grid_inner, &hint, 0, null);
            self.footer(try keys.footer(al, &.{&outfit_legend}));
            return;
        }

        // Grid geometry: fixed 5 columns; cell height capped at 9 terminal rows.
        const cols: u16 = 5;
        const cell_w: u16 = @max(1, grid_inner.w / cols);
        const cell_h: u16 = @max(3, @min(9, grid_inner.h));
        const visible_rows: usize = if (cell_h > 0) grid_inner.h / cell_h else 0;
        if (visible_rows == 0) {
            self.footer(try keys.footer(al, &.{&outfit_legend}));
            return;
        }

        // Keep selected row in the visible window.
        const selected_row: usize = self.w_logo / cols;
        if (selected_row < self.w_logo_top) self.w_logo_top = selected_row;
        if (selected_row >= self.w_logo_top + visible_rows) self.w_logo_top = selected_row - visible_rows + 1;

        // Lazy thumbnail loading: decode every unloaded visible logo per draw call
        // so the visible window fills in a single draw.
        outer: for (0..visible_rows) |vr| {
            const row = self.w_logo_top + vr;
            for (0..@as(usize, cols)) |col| {
                const idx = row * cols + col;
                if (idx >= self.w_thumbs.len) break :outer;
                if (self.w_thumbs[idx] == null) {
                    self.loadThumbAt(idx);
                }
            }
        }

        // Draw each visible cell.
        for (0..visible_rows) |vr| {
            const row = self.w_logo_top + vr;
            for (0..@as(usize, cols)) |col| {
                const idx = row * cols + col;
                if (idx >= self.logos.len) break;
                const cx: u16 = grid_inner.x + @as(u16, @intCast(col)) * cell_w;
                const cy: u16 = grid_inner.y + @as(u16, @intCast(vr)) * cell_h;
                const selected = idx == self.w_logo;

                // Name label: last row of the cell, centered within the cell width.
                const name_y: i32 = @as(i32, cy) + @as(i32, cell_h) - 1;
                var name_buf: [128]u8 = undefined;
                const title_name = game.logo_name.titleCaseLogoKey(self.logos[idx], &name_buf);
                const display_name = title_name[0..@min(title_name.len, cell_w)];
                const lbl: Style = if (selected) .sel else .dim;
                // Center: pad leading spaces so the name sits in the middle of the cell.
                // padding = (cell_cols - name_display_width) / 2, clamped to 0.
                const padding: usize = @as(usize, (cell_w -| @as(u16, @truncate(display_name.len))) / 2);
                var center_buf: [256]u8 = undefined;
                const safe_padding: usize = @min(padding, center_buf.len - display_name.len);
                @memset(center_buf[0..safe_padding], ' ');
                @memcpy(center_buf[safe_padding..][0..display_name.len], display_name);
                self.screen.textPad(@intCast(cx), name_y, cell_w, center_buf[0 .. safe_padding + display_name.len], lbl);

                // Thumbnail image: rows above the name label.
                const img_h: u16 = cell_h - 1;
                if (img_h > 0) {
                    const img_rect: Rect = .{ .x = cx, .y = cy, .w = cell_w, .h = img_h };
                    if (idx < self.w_thumbs.len) {
                        if (self.w_thumbs[idx]) |*e| {
                            if (self.graphics != .none) {
                                var irows: u32 = img_h;
                                var icols: u32 = @min(@as(u32, cell_w), irows * 2 * e.img.width / @max(1, e.img.height));
                                if (icols == 0) icols = 1;
                                irows = @min(irows, @max(1, icols * e.img.height / @max(1, 2 * e.img.width)));
                                if (self.n_placements < self.placements.len) {
                                    self.placements[self.n_placements] = .{
                                        .x = cx + @as(u16, @intCast((cell_w - icols) / 2)),
                                        .y = cy + @as(u16, @intCast((img_h - irows) / 2)),
                                        .cols = @intCast(icols),
                                        .rows = @intCast(irows),
                                        .kitty_id = e.kitty_id,
                                        .bytes = e.bytes,
                                    };
                                    self.n_placements += 1;
                                }
                            } else {
                                self.screen.blit(img_rect, &e.img);
                            }
                        }
                    }
                }
            }
        }

        self.footer(try keys.footer(al, &.{&outfit_legend}));
    }

    fn drawWizardCompany(self: *App) !void {
        const al = self.a();
        const b = self.body();
        if (self.stateOrNull()) |g| {
            const rows = try q.toe(al, g);
            var texts: std.ArrayListUnmanaged([]const u8) = .empty;
            for (rows) |r| try texts.append(al, r.text);
            // Wide: the office sits beside the TO&E. Narrow: it takes
            // the bottom band, so +/- are never blind.
            const wide = layout.wide(b.w);
            const lw: u16 = if (wide) layout.major.of(b.w) else b.w;
            const oh: u16 = @min(b.h, 12);
            const toe_h: u16 = if (wide) b.h else b.h -| oh;
            self.listPane(.{ .x = 0, .y = b.y, .w = lw, .h = toe_h }, "GENERATED COMPANY", texts.items, 0, self.w_field == 0, true);
            {
                const hq_id = q.firstHq(g);
                var office: std.ArrayListUnmanaged([]const u8) = .empty;
                try office.append(al, "role               have   need   payroll/mo   effect");
                for (try q.backOffice(al, g, hq_id), 0..) |desk, i| {
                    const short = desk.have < desk.need;
                    try office.append(al, try std.fmt.allocPrint(al, "{s}{s: <18} {d: >4}   {d: >4}   {s: >10}   {s}{{/}}", .{
                        if (self.w_field == 1 and i == self.w_office) "{s}" else if (short) "{c}" else "",
                        @tagName(desk.role),
                        desk.have,
                        desk.need,
                        try q.money(al, desk.pay),
                        desk.effect,
                    }));
                }
                const st = try q.status(al, g);
                const hqs = try q.hqList(al, g);
                try office.append(al, "");
                try office.append(al, try std.fmt.allocPrint(al, "staff {d} / {d} required · payroll {s}/mo · treasury {{a}}{s}{{/}} C", .{ if (hqs.len > 0) hqs[0].staff_assigned else 0, if (hqs.len > 0) hqs[0].staff_required else 0, st.payroll, st.funds }));
                try office.append(al, "{d}under-hiring is allowed: facilities run a level lower and paperwork slows{/}");
                try office.append(al, try std.fmt.allocPrint(al, "{{d}}{s} · {s} · {s}{{/}}", .{ try keyHint(CompanyAction, al, &company_bindings, .switch_pane, "focus"), try keyHint(CompanyAction, al, &company_bindings, .down, "role"), try keyHint(CompanyAction, al, &company_bindings, .more, "fewer / more") }));
                const office_rect: Rect = if (wide) .{ .x = lw + 1, .y = b.y, .w = b.w - lw - 1, .h = oh } else .{ .x = 0, .y = b.y + toe_h, .w = b.w, .h = oh };
                self.listPane(office_rect, "BACK OFFICE", office.items, 1, self.w_field == 1, false);
                if (wide and b.h > oh + 3) {
                    const detail = try q.hqDetail(al, g, hq_id);
                    self.listPane(.{ .x = lw + 1, .y = b.y + oh, .w = b.w - lw - 1, .h = b.h - oh }, try std.fmt.allocPrint(al, "starter HQ · {s}", .{try q.hqName(self.a(), g, hq_id)}), detail, 2, false, false);
                }
            }
        }
        self.footer(try keys.footer(al, &.{&company_legend}));
    }

    fn drawWizardReview(self: *App) !void {
        const al = self.a();
        const b = self.body();
        var rows: std.ArrayListUnmanaged([]const u8) = .empty;
        const has_picture = self.w_thumbs.len > 0 and self.w_logo < self.w_thumbs.len and self.w_thumbs[self.w_logo] != null;
        if (self.stateOrNull()) |g| {
            const st = try q.status(al, g);
            const pad_art = "        ";
            try rows.append(al, try std.fmt.allocPrint(al, "{s}   {{a}}{s}{{/}}", .{ pad_art, try q.plain(al, self.w_outfit.slice()) }));
            try rows.append(al, try std.fmt.allocPrint(al, "{s}   {s} · {s} · {s} ({s})", .{ pad_art, try q.plain(al, self.w_name.slice()), factions[self.w_faction].fullName(), @tagName(professions[self.w_profession]), professions[self.w_profession].description() }));
            try rows.append(al, try std.fmt.allocPrint(al, "{s}   {{d}}{s} · day 0{{/}}", .{ pad_art, st.date }));
            try rows.append(al, "");
            for (try q.hqList(al, g)) |h| {
                try rows.append(al, try std.fmt.allocPrint(al, "starter HQ    {{a}}{s}{{/}} on {s} · {s} · ring {d} LY · staff {d}/{d}", .{ try h.name.markup(al), h.world, h.tier, h.ring_ly, h.staff_assigned, h.staff_required }));
            }
            try rows.append(al, try std.fmt.allocPrint(al, "company       {s} · {d} hulls · {d} people", .{ try q.plain(al, self.w_company.slice()), st.hulls, st.people }));
            {
                // The back office as sized in step 3.
                var line: std.ArrayListUnmanaged(u8) = .empty;
                var pay: types.CBills = 0;
                try line.appendSlice(al, "back office   ");
                for (try q.backOffice(al, g, q.firstHq(g)), 0..) |desk, i| {
                    pay += desk.pay;
                    if (i > 0) try line.appendSlice(al, " · ");
                    try line.appendSlice(al, try std.fmt.allocPrint(al, "{d} {s}", .{ desk.have, @tagName(desk.role)[6..] }));
                }
                try line.appendSlice(al, try std.fmt.allocPrint(al, " · {s}/mo", .{try q.money(al, pay)}));
                try rows.append(al, line.items);
            }
            try rows.append(al, try std.fmt.allocPrint(al, "treasury      outfit {{a}}{s}{{/}} C", .{st.funds}));
            try rows.append(al, try std.fmt.allocPrint(al, "first board   {d} offers within the ring on day 1", .{st.offers}));
            try rows.append(al, "");
            try rows.append(al, try std.fmt.allocPrint(al, "{{s}} {s} {{/}}   {{d}}saves under the current player and opens the Desk on day 0{{/}}", .{try keyHint(ReviewAction, al, &review_bindings, .begin, "begin campaign")}));
        }
        const rw: u16 = if (has_picture and layout.wide(b.w)) layout.two_thirds.of(b.w) else b.w;
        _ = self.listPane(.{ .x = 0, .y = b.y, .w = rw, .h = b.h }, "REVIEW", rows.items, 0, true, false);
        if (rw < b.w) {
            const inner = self.screen.pane(.{ .x = rw, .y = b.y, .w = b.w - rw, .h = b.h }, .{ .title = "EMBLEM" });
            _ = self.drawEmblem(inner);
        }
        self.footer(try keys.footer(al, &.{&review_legend}));
    }

    // ---- game ----

    fn drawChrome(self: *App) !void {
        const al = self.a();
        const s = &self.screen;
        const g = self.state();
        s.textPad(0, 0, s.cols, "", .normal);
        var x: i32 = 0;
        for (screen_table, 0..) |spec, i| {
            const name = spec.name;
            var buf: [24]u8 = undefined;
            const t = std.fmt.bufPrint(&buf, " {s} ", .{name}) catch name;
            const st: Style = if (i == @intFromEnum(self.tab)) .tab else .dim;
            x += s.text(x, 0, @intCast(t.len), t, st);
        }
        const st = try q.status(al, g);
        const right = try st.outfit_name.markup(al);
        var mark_w: u16 = 0;
        if (self.emblem != null and layout.wide(s.cols)) {
            mark_w = 8;
            _ = self.drawEmblem(.{ .x = s.cols - 7, .y = 0, .w = 6, .h = 3 });
        }
        _ = s.text(@as(i32, s.cols) - @as(i32, @intCast(right.len)) - 1 - mark_w, 0, @intCast(right.len), right, .dim);
        if (self.narrow()) {
            const short = try std.fmt.allocPrint(al, "{{a}}{s}{{/}} d{d} · {{a}}{s}{{/}} C · rep {d} · inbox {s}{d}{{/}} · chk {s}{d}{{/}} · urgent {s}{d}{{/}}", .{
                st.date, st.day, st.funds, st.reputation, if (st.inbox > 0) "{c}" else "{g}", st.inbox, if (st.urgent > 0) "{c}" else if (st.checklist > 0) "{a}" else "{g}", st.checklist, if (st.urgent > 0) "{c}" else "{g}", st.urgent,
            });
            s.textPad(0, 1, s.cols, short, .normal);
            return;
        }
        const line = try std.fmt.allocPrint(al, "{{a}}{s}{{/}}  day {d}  ·  outfit {{a}}{s}{{/}} C  ·  rep {s}{d}{{/}}  ·  {d} companies · {d} HQs · {d} hulls · {d} people  ·  inbox {s}{d}{{/}}  ·  checklist {s}{d}{{/}}  ·  urgent {s}{d}{{/}}", .{
            st.date,       st.day,
            st.funds,      if (st.reputation < 0) "{c}" else "{g}",
            st.reputation, st.companies,
            st.hqs,        st.hulls,
            st.people,     if (st.inbox > 0) "{c}" else "{g}",
            st.inbox,      if (st.urgent > 0) "{c}" else if (st.checklist > 0) "{a}" else "{g}",
            st.checklist,  if (st.urgent > 0) "{c}" else "{g}",
            st.urgent,
        });
        const np = try self.nowPlayingLine();
        s.textPad(0, 1, s.cols, if (np.len > 0 and layout.extraWide(s.cols)) try std.fmt.allocPrint(al, "{s}  ·  {{d}}{s}{{/}}", .{ line, np }) else line, .normal);
    }

    fn drawGame(self: *App) !void {
        self.clampFocus();
        try self.drawChrome();
        const spec = screenSpec(self.tab);
        try spec.draw(self);
        self.footer(try keys.footer(self.a(), &.{ spec.legend, &global_legend }));
    }

    // ---- market ----

    /// A table pane, or a note when it has no rows.
    pub fn tableOrNote(self: *App, inner: Rect, t: Table, pane_idx: u8, focused: bool, note: []const u8) !void {
        if (t.rows.len == 0) {
            self.screen.lines(inner, &.{note}, 0, null);
            return;
        }
        try self.tablePane(inner, t, pane_idx, focused);
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

    /// A table with its header pinned, the cursor row kept in view
    /// and ←/→ scrolling its columns behind the first.
    pub fn tablePane(self: *App, inner: Rect, t: Table, pane_idx: u8, focused: bool) !void {
        if (inner.h == 0) return;
        const c = self.cur(pane_idx);
        clampIdx(c, t.rows.len);
        const scroll = self.colScroll(pane_idx);
        if (focused) self.focus_scroll = pane_idx;
        _ = try self.screen.table(self.a(), inner, t, firstRow(c.*, inner.h -| 1), if (focused and t.rows.len > 0) c.* else null, scroll);
    }

    // ---- people ----

    pub fn selectedPerson(self: *App) !?types.PersonId {
        return if (try self.selectedPersonRow()) |r| r.id else null;
    }

    pub fn selectedPersonRow(self: *App) !?q.PersonRow {
        const view = try q.people(self.a(), self.state(), self.people_filter);
        if (view.rows.len == 0) return null;
        return view.rows[@min(self.cur(0).*, view.rows.len - 1)];
    }

    /// Re-export for use by the People screen and the person-detail modal.
    pub const PersonAction = q.PersonAction; // seat, transfer, post, train, leave, triage, admit, fire

    /// Single dispatch owner for person actions; shared by the People screen
    /// letter keys and the person-detail modal hotkeys (rule 20).
    pub fn personAct(self: *App, id: types.PersonId, action: PersonAction) !void {
        const al = self.a();
        const g = self.state();
        var buf: [96]u8 = undefined;
        switch (action) {
            .train => {
                const pa = try q.personActions(al, g, id);
                self.openCommand(std.fmt.bufPrint(&buf, "train {d} {s}", .{ @intFromEnum(id), @tagName(pa.primary_skill) }) catch "train ");
            },
            .seat => self.openModal(.{ .seat = id }),
            .post => self.openModal(.{ .pick_hq = id }),
            .transfer => self.openModal(.{ .pick_company = .{ .what = .person, .id = @intFromEnum(id) } }),
            .leave => self.openAmount(
                try std.fmt.allocPrint(al, "LEAVE · {s}", .{try q.personName(al, g, id)}),
                .{ .leave = id },
                &.{.{ .label = "days", .value = 7, .min = 1, .max = 90, .step = 1 }},
            ),
            .triage => self.openAmount(
                try std.fmt.allocPrint(al, "TRIAGE · {s} (higher heals first)", .{try q.personName(al, g, id)}),
                .{ .triage = id },
                &.{.{ .label = "priority", .value = 1, .min = 0, .max = 9, .step = 1 }},
            ),
            .fire => self.modal = .{ .confirm = .{ .kind = .fire, .id = @intFromEnum(id) } },
            .admit => {
                _ = try self.execSay(.{ .admit = id }, .good, "{s} admitted to the medbay — healing starts tomorrow", .{try q.personName(al, g, id)});
            },
        }
    }

    /// Change the emblem on every company (the crest is outfit-wide).
    fn applyEmblem(self: *App, image: []const u8) !void {
        if (try self.exec(.{ .set_outfit_emblem = image })) self.refreshEmblem();
    }

    // ---- map ----

    pub const MapGeom = struct {
        inner: Rect,
        min_x: i32,
        max_y: i32,
        sx: f64, // LY per column
        sy: f64, // LY per row

        pub fn cell(self: MapGeom, x: i32, y: i32) [2]i32 {
            const cx = @as(f64, @floatFromInt(self.inner.x)) + @as(f64, @floatFromInt(x - self.min_x)) / self.sx;
            const cy = @as(f64, @floatFromInt(self.inner.y)) + @as(f64, @floatFromInt(self.max_y - y)) / self.sy;
            return .{ @intFromFloat(@floor(cx)), @intFromFloat(@floor(cy)) };
        }

        pub fn inside(self: MapGeom, c: [2]i32) bool {
            return c[0] >= self.inner.x and c[0] < self.inner.x + self.inner.w and c[1] >= self.inner.y and c[1] < self.inner.y + self.inner.h;
        }
    };

    pub fn mapGeom(view: q.Map, inner: Rect, zoom: u8, center: ?[2]i32) MapGeom {
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
        if (zoom > 1) {
            // Closer in: the same aspect, `zoom` times fewer LY per cell,
            // and the cursor world sits in the middle of the pane.
            const z: f64 = @floatFromInt(zoom);
            sx /= z;
            sy /= z;
            const c = center orelse .{ @divTrunc(min_x + max_x, 2), @divTrunc(min_y + max_y, 2) };
            min_x = c[0] - @as(i32, @intFromFloat(usable_w * sx / 2));
            max_y = c[1] + @as(i32, @intFromFloat(usable_h * sy / 2));
        }
        return .{ .inner = inner, .min_x = min_x, .max_y = max_y, .sx = sx, .sy = sy };
    }

    pub fn factionStyle(key: []const u8) Style {
        return switch (q.factionColour(key)) {
            .blue => .blue,
            .red => .red,
            .yellow => .yellow,
            .green => .green,
            .magenta => .magenta,
            .cyan => .cyan,
            .white => .white,
            .grey => .grey,
        };
    }

    /// Move the map cursor to the nearest world in a direction.
    pub fn mapPan(self: *App, dx: i32, dy: i32) !void {
        const view = try q.map(self.a(), self.state());
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

    pub fn labUnit(self: *App) !?types.UnitId {
        const meks = try q.labMeks(self.a(), self.state());
        if (meks.len == 0) return null;
        clampIdx(&self.lab_sel, meks.len);
        return meks[self.lab_sel];
    }

    /// Custom text art travels as force.emblem bytes: "ART1\n" then three
    /// lines of eight cells.
    const art_magic = "ART1\n";

    fn parseArt(bytes: []const u8) ?Emblem {
        if (!std.mem.startsWith(u8, bytes, art_magic)) return null;
        var lines = std.mem.splitScalar(u8, bytes[art_magic.len..], '\n');
        var art: [3][]const u8 = .{ "", "", "" };
        for (&art) |*row| row.* = lines.next() orelse return null;
        return .{ .name = "your own", .art = art };
    }

    pub fn emblemFor(self: *App, g: *GameState) Emblem {
        _ = self;
        if (q.outfitEmblem(g)) |img| {
            if (parseArt(img)) |custom| return custom;
            for (emblems) |em| if (std.mem.eql(u8, em.name, img)) return em;
        }
        return emblems[0];
    }

    /// Open the cell editor seeded with the current crest.
    fn openEmblemEditor(self: *App) void {
        const g = (self.stateOrNull() orelse return);
        const crest = self.emblemFor(g);
        for (0..3) |r| for (0..8) |c| {
            self.ed_art[r][c] = if (c < crest.art[r].len) crest.art[r][c] else ' ';
        };
        self.ed_undo = self.ed_art;
        self.ed_x = 0;
        self.ed_y = 0;
        self.modal = .emblem_editor;
    }

    /// The site under the Supply cursor, if the row belongs to one.
    pub fn supplySite(self: *App) !?types.Site {
        const view = try q.supply(self.a(), self.state());
        const c = self.cur(0).*;
        if (c >= view.site.len) return null;
        return view.site[c];
    }

    /// The raise wizard's company line lances (in TO&E order).
    pub fn raiseLances(self: *App) ![]q.LanceSlot {
        return q.raiseLances(self.a(), self.state(), self.raise.company);
    }

    /// Take or buy the highlighted candidate into the current lance.
    fn raiseTake(self: *App) !void {
        const al = self.a();
        const g = self.state();
        const lances = try self.raiseLances();
        if (lances.len == 0) return;
        const lance = lances[@min(self.raise.lance_idx, lances.len - 1)];
        const cands = try q.raiseCandidates(al, g, self.raise.company, self.raise.passed[0..self.raise.passed_len]);
        if (cands.len == 0) return;
        const c = cands[@min(self.modal_cursor, cands.len - 1)];
        switch (c.kind) {
            .pool => {
                _ = try self.execSay(.{ .move_unit = .{ .unit = c.unit, .force = lance.id } }, .good, "#{d} joins {s}", .{ @intFromEnum(c.unit), try lance.name.markup(self.a()) });
            },
            .mothballed => {
                if (!try self.exec(.{ .reactivate = c.unit })) return;
                _ = try self.execSay(.{ .move_unit = .{ .unit = c.unit, .force = lance.id } }, .good, "#{d} reactivating and assigned to {s}", .{ @intFromEnum(c.unit), try lance.name.markup(self.a()) });
            },
            .listing => {
                const r = self.execResult(.{ .buy_hull_for = .{ .listing = c.listing, .company = self.raise.company, .lance = lance.id } }) orelse return;
                if (r.unit == .none) {
                    self.say(.crit, "{s}", .{game.cli.hull_fraud_text});
                } else if (r.eta_days == 0) {
                    self.say(.good, "#{d} bought and placed in {s}", .{ @intFromEnum(r.unit), try lance.name.markup(self.a()) });
                } else {
                    self.say(.good, "#{d} bought — {d} days in transit, it joins the first lance with room on arrival", .{ @intFromEnum(r.unit), r.eta_days });
                }
            },
        }
    }

    /// Buy one hull of the highlighted support line into its lance.
    fn raiseBuySupport(self: *App) !void {
        const g = self.state();
        const train = try q.supportTrain(self.a(), g, self.raise.company);
        if (train.lines.len == 0) return;
        const line = train.lines[@min(self.modal_cursor, train.lines.len - 1)];
        const r = self.execResult(.{ .buy_support_hull = .{ .company = self.raise.company, .kind = line.kind } }) orelse return;
        self.say(.good, "{s} #{d} bought into the {s} lance", .{ line.key, @intFromEnum(r.unit), @tagName(line.kind) });
    }

    /// The TO&E rows for the current Forces view.
    pub fn toeRows(self: *App) ![]q.ToeRow {
        const g = self.state();
        const views = try q.toeViews(self.a(), g);
        clampIdx(&self.forces_view, views.len);
        return q.toeFiltered(self.a(), g, views[self.forces_view].filter);
    }

    pub fn homeHqOf(self: *App, company: types.ForceId) !u32 {
        const g = self.state();
        const id = q.homeHq(g, company);
        return if (id != .none) @intFromEnum(id) else try self.hqSelId(g);
    }

    // ---- modals ----

    fn modalRect(self: *App, w: u16, h: u16) Rect {
        const s = &self.screen;
        const ww = @min(w, s.cols -| 2);
        const hh = @min(h, s.rows -| 1);
        return .{ .x = (s.cols - ww) / 2, .y = (s.rows - hh) / 2, .w = ww, .h = hh };
    }

    /// The text columns inside a modal of this width: the one place the
    /// border padding comes off, so wrapped text matches what is drawn.
    fn modalTextWidth(self: *App, w: u16) u16 {
        return self.modalRect(w, self.screen.rows).inner().w;
    }

    /// The after-action sheet: four panes over one engagement.
    /// The only modal that carves its own layout — `market.zig`'s split is
    /// the template, with `modalRect` standing in for the screen body.
    /// Too narrow to split, it falls back to the scrolling flat form, the
    /// way the Forces detail pane degrades to a modal.
    fn drawAfterAction(self: *App, al: std.mem.Allocator, id: types.BattleId) !void {
        const view = (try q.afterAction(al, self.state(), id)) orelse {
            self.dialog("AFTER ACTION", &.{ "", "  {d}that engagement is no longer on record{/}", "", "  {d}any key closes{/}" }, layout.modal.log_entry_w, 6);
            return;
        };
        const r = self.modalRect(layout.modal.after_action_w, self.screen.rows -| 1);
        const b = self.screen.pane(r, .{ .title = view.title, .double = true, .right_title = view.right_title });
        if (b.w < layout.modal.after_action_stack_cols) {
            // One column: the AAR as it reads in the log, wrapped to the
            // width there is and scrollable. Clipping it would hide the
            // losses line's tail, which is the part worth reading.
            var flat: std.ArrayListUnmanaged([]const u8) = .empty;
            for (view.flat) |line| for (try screen_mod.wrap(al, line, b.w)) |w| try flat.append(al, w);
            const max_first = flat.items.len -| b.h;
            if (self.modal_cursor > max_first) self.modal_cursor = max_first;
            self.screen.lines(b, flat.items, self.modal_cursor, null);
            return;
        }

        const left_w: u16 = @max(30, layout.aar_fight.of(b.w));
        const right_w: u16 = b.w - left_w;
        const field_h: u16 = layout.aar_field.of(b.h);

        const fight = self.screen.pane(.{ .x = b.x, .y = b.y, .w = left_w, .h = b.h }, .{ .title = "THE FIGHT" });
        self.screen.lines(fight, view.fight, 0, null);

        const field = self.screen.pane(.{ .x = b.x + left_w, .y = b.y, .w = right_w, .h = field_h }, .{ .title = "THE FIELD", .right_title = try keyHint(AfterActionAction, al, &after_action_bindings, .scroll_left, "columns") });
        try self.tableOrNote(field, view.field, 2, true, "{d}not a scratch{/}");

        const rest_h: u16 = b.h - field_h;
        const spoils_w: u16 = right_w / 2;
        const spoils = self.screen.pane(.{ .x = b.x + left_w, .y = b.y + field_h, .w = spoils_w, .h = rest_h }, .{ .title = "THE SPOILS" });
        self.screen.lines(spoils, view.spoils, 0, null);
        const trucks = self.screen.pane(.{ .x = b.x + left_w + spoils_w, .y = b.y + field_h, .w = right_w - spoils_w, .h = rest_h }, .{ .title = "THE TRUCKS" });
        self.screen.lines(trucks, view.trucks, 0, null);
    }

    /// A titled box of text lines (the flow dialogs: end turn, quit, game over).
    fn dialog(self: *App, title: []const u8, rows: []const []const u8, w: u16, h: u16) void {
        const inner = self.screen.pane(self.modalRect(w, h), .{ .title = title, .double = true });
        self.screen.lines(inner, rows, 0, null);
    }

    fn drawModal(self: *App) !void {
        const al = self.a();
        switch (self.modal) {
            .none => {},
            .help, .decision, .raise_hulls, .raise_support, .music, .summary, .readiness, .raise_crews, .negotiate, .pick_company, .pick_hq, .pick_crew, .pick_unassign, .pick_part, .accept_pick, .lance_pick, .upgrade, .install_part, .install_loc, .install_at, .seat, .emblem, .hull, .contract_log, .log_entry, .battle_list, .record, .operation_pick, .intent_pick, .task_pick, .tempo_pick, .intervention_pick, .operation_report, .mech, .leaderboard, .leaderboard_detail => try self.drawList(al),
            .after_action => |id| try self.drawAfterAction(al, id),
            .end_turn => {
                const g = self.state();
                const asks = try endTurnRows(al, (try q.desk(al, g, 0)).checklist);
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                try rows.append(al, "");
                try rows.append(al, try std.fmt.allocPrint(al, "  {d} things on your desk before day {d}:", .{ asks.len, (try q.status(al, g)).day + 1 }));
                try rows.append(al, "");
                for (asks, 0..) |w, i| {
                    try rows.append(al, try std.fmt.allocPrint(al, "  {s} {s}   {{d}}→ [{d}] {s}{{/}}", .{ if (w.urgent) "{c}!{/}" else "{a}·{/}", w.text, i + 1, tabName(@enumFromInt(w.jump)) }));
                }
                try rows.append(al, "");
                try rows.append(al, try std.fmt.allocPrint(al, "  {{s}} {s} {{/}}    {{d}}{s} · {s}{{/}}", .{ try keyHint(EndTurnAction, al, &end_turn_bindings, .day, "end the turn anyway"), try keyHint(EndTurnAction, al, &end_turn_bindings, .week, "end 7 turns"), try keyHint(EndTurnAction, al, &end_turn_bindings, .cancel, "back") }));
                self.dialog(try std.fmt.allocPrint(al, "END TURN? · {s} · {s} · {s}", .{ try keyHint(EndTurnAction, al, &end_turn_bindings, .day, if (self.end_turn_days == 1) "a day" else try std.fmt.allocPrint(al, "{d} days", .{self.end_turn_days})), try keyHint(EndTurnAction, al, &end_turn_bindings, .week, "a week"), try keyHint(EndTurnAction, al, &end_turn_bindings, .cancel, "not yet") }), rows.items, layout.modal.end_turn_w, @intCast(@min(rows.items.len + 3, layout.modal.end_turn_max_h)));
            },
            .quit => {
                const g = self.state();
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                try rows.append(al, "");
                const st = try q.status(al, g);
                try rows.append(al, try std.fmt.allocPrint(al, "  campaign {{a}}{s}{{/}} · day {d}{s}", .{ try st.outfit_name.markup(al), st.day, if (!st.saved) " · {c}never saved{/}" else "" }));
                try rows.append(al, "");
                try rows.append(al, try std.fmt.allocPrint(al, "  {{s}} {s} {{/}}", .{try keyHint(QuitAction, al, &quit_bindings, .save, "save and return")}));
                try rows.append(al, try std.fmt.allocPrint(al, "    {s}", .{try keyHint(QuitAction, al, &quit_bindings, .discard, "return without saving")}));
                try rows.append(al, try std.fmt.allocPrint(al, "    {s}", .{try keyHint(QuitAction, al, &quit_bindings, .stay, "stay in the campaign")}));
                self.dialog("RETURN TO WELCOME?", rows.items, layout.modal.quit_w, layout.modal.quit_h);
            },
            .amount => |form| {
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                try rows.append(al, "");
                for (form.fields[0..form.n], 0..) |f, i| {
                    const on = i == form.cur;
                    try rows.append(al, try std.fmt.allocPrint(al, "  {s} {s: <18} {s}{d}{s}{{/}}", .{ if (on) "{a}▶{/}" else " ", f.label, if (on) "{a}" else "", f.value, if (on) "_" else "" }));
                }
                try rows.append(al, "");
                try rows.append(al, try std.fmt.allocPrint(al, "  {{d}}{s}{{/}}", .{try keys.title(al, "", &amount_legend)}));
                const r = self.modalRect(layout.modal.amount_w, @intCast(@min(rows.items.len + 2, self.screen.rows -| 1)));
                const inner = self.screen.pane(r, .{ .title = form.title(), .double = true });
                self.screen.lines(inner, rows.items, 0, null);
            },
            .battle_orders => |id| {
                const form = (try self.ordersRows(al, id)) orelse {
                    self.modal = .none;
                    return;
                };
                self.ordersSnap(form, 1);
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                for (form.rows, 0..) |row, i| try rows.append(al, if (i == self.modal_cursor and row.active) try std.fmt.allocPrint(al, "{{a}}▶{{/}}{s}", .{row.text[1..]}) else row.text);
                const r = self.modalRect(layout.modal.settings_w, @intCast(@min(rows.items.len + 2, self.screen.rows -| 1)));
                const inner = self.screen.pane(r, .{ .title = try formTitle(al, form.title, "later"), .double = true });
                self.screen.lines(inner, rows.items, 0, self.modal_cursor);
            },
            .settings => {
                const form = try self.settingsRows(al);
                if (form.selectable > 0 and !form.rows[self.settings_cursor].active) try self.settingsMove(1);
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                for (form.rows, 0..) |row, i| try rows.append(al, if (i == self.settings_cursor and row.active) try std.fmt.allocPrint(al, "{{a}}▶{{/}}{s}", .{row.text[1..]}) else row.text);
                const r = self.modalRect(layout.modal.settings_w, @intCast(@min(rows.items.len + 2, self.screen.rows -| 1)));
                const inner = self.screen.pane(r, .{ .title = try formTitle(al, "SETTINGS", "close"), .double = true });
                self.screen.lines(inner, rows.items, 0, if (form.selectable > 0) self.settings_cursor else null);
            },
            .game_over_saved => {
                const g = self.state();
                const rows = [_][]const u8{
                    "",
                    try std.fmt.allocPrint(al, "  {{c}}{s}{{/}} could not cover its debts on day {d}.", .{ try (try q.status(al, g)).outfit_name.markup(al), (try q.status(al, g)).day }),
                    "  Loans are exhausted and nothing left to sell would close the gap. The creditors take the rest.",
                    "",
                    "  The campaign is saved as it ended; delete it from the welcome screen, or keep it as a record.",
                    "",
                    try std.fmt.allocPrint(al, "  {{s}} {s} {{/}}", .{try keyHint(GameOverAction, al, &game_over_bindings, .leave, "return to the welcome screen")}),
                };
                self.dialog("BANKRUPT — GAME OVER", &rows, layout.modal.game_over_w, layout.modal.game_over_h);
            },
            .game_over_failed => |err_text| {
                const g = self.state();
                const rows = [_][]const u8{
                    "",
                    try std.fmt.allocPrint(al, "  {{c}}{s}{{/}} could not cover its debts on day {d}.", .{ try (try q.status(al, g)).outfit_name.markup(al), (try q.status(al, g)).day }),
                    "  Loans are exhausted and nothing left to sell would close the gap. The creditors take the rest.",
                    "",
                    try std.fmt.allocPrint(al, "  The final save failed: {s}", .{err_text}),
                    "",
                    try std.fmt.allocPrint(al, "  {{s}} {s} {{/}}   {{s}} {s} {{/}}", .{
                        try keyHint(GameOverAction, al, &game_over_bindings, .retry, "retry the save"),
                        try keyHint(GameOverAction, al, &game_over_bindings, .leave, "return without saving"),
                    }),
                };
                self.dialog("BANKRUPT — GAME OVER", &rows, layout.modal.game_over_w, layout.modal.game_over_h);
            },
            .confirm => |c| {
                const spec = try self.confirmSpec(c);
                self.dialog(spec.title, spec.rows, spec.w, spec.h);
            },
            .emblem_editor => {
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                try rows.append(al, "");
                for (0..3) |r| {
                    var line: std.ArrayListUnmanaged(u8) = .empty;
                    try line.appendSlice(al, "      ");
                    for (0..8) |c| {
                        const here = r == self.ed_y and c == self.ed_x;
                        if (here) try line.appendSlice(al, "{s}");
                        try line.append(al, self.ed_art[r][c]);
                        if (here) try line.appendSlice(al, "{/}");
                    }
                    try line.appendSlice(al, "      ");
                    for (0..8) |c| try line.append(al, self.ed_art[r][c]);
                    try rows.append(al, line.items);
                }
                try rows.append(al, "");
                try rows.append(al, "  type a character to paint the cell and step right · arrows move · Space blanks");
                try rows.append(al, "  Backspace steps back and blanks · u undoes everything since the editor opened");
                try rows.append(al, try std.fmt.allocPrint(al, "  {{d}}{s}{{/}}", .{try keys.title(al, "", &editor_legend)}));
                const r = self.modalRect(layout.modal.emblem_editor_w, @intCast(rows.items.len + 2));
                const inner = self.screen.pane(r, .{ .title = "EMBLEM EDITOR · cells", .double = true, .right_title = "left: editing · right: as shown" });
                self.screen.lines(inner, rows.items, 0, null);
            },
            .input => |kind| {
                if (kind == .command) return; // drawn in the footer
                const prompt: []const u8 = switch (kind) {
                    .new_player => "name of the new player",
                    .delete_campaign => "type the outfit name to confirm deletion",
                    .delete_player => "type the player name to confirm deletion (all their campaigns go too)",
                    .raise_name => "name of the new company (it starts empty: you pick every hull and crew)",
                    .command => "",
                };
                const rows = [_][]const u8{
                    "",
                    try std.fmt.allocPrint(al, "  {s}", .{prompt}),
                    "",
                    try std.fmt.allocPrint(al, "  > {{s}}{s}_{{/}}", .{try q.plain(al, self.input.slice())}),
                    "",
                    try std.fmt.allocPrint(al, "  {{d}}{s}{{/}}", .{try keys.title(al, "", &input_legend)}),
                };
                const r = self.modalRect(layout.modal.input_w, layout.modal.input_h);
                const inner = self.screen.pane(r, .{ .title = switch (kind) {
                    .new_player => "NEW PLAYER",
                    .delete_campaign => "DELETE CAMPAIGN?",
                    .delete_player => "DELETE PLAYER?",
                    .raise_name => "RAISE A COMPANY",
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

    /// Keep an index inside a list that was rebuilt this frame (rule 40):
    /// past the end lands on the last row, an empty list on 0.
    pub fn clampIdx(i: *usize, len: usize) void {
        if (len == 0) i.* = 0 else if (i.* >= len) i.* = len - 1;
    }

    /// Open a modal with its cursor at the top.
    pub fn openModal(self: *App, m: Modal) void {
        self.modal_cursor = 0;
        self.modal = m;
    }

    pub fn moveCursor(self: *App, pane: u8, delta: i32, len: usize) void {
        const c = self.cur(pane);
        if (len == 0) {
            c.* = 0;
            return;
        }
        const v: i32 = @as(i32, @intCast(c.*)) + delta;
        c.* = @intCast(@max(0, @min(@as(i32, @intCast(len - 1)), v)));
    }

    // ---- welcome and wizard keys ----

    const WelcomeAction = enum { switch_pane, down, up, open, new_campaign, new_player, delete_campaign, delete_player, settings, music, help, quit };
    pub const welcome_bindings = [_]keys.Binding(WelcomeAction){
        .{ .match = .{ .key = .tab }, .action = .switch_pane, .label = "players / campaigns", .group = .navigate, .show_footer = false },
        .{ .match = .{ .key = .backtab }, .action = .switch_pane, .label = "players / campaigns", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('j'), .action = .down, .label = "choose", .group = .navigate, .shown = "j/k", .show_footer = false },
        .{ .match = .{ .key = .down }, .action = .down, .label = "down", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('k'), .action = .up, .label = "up", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .up }, .action = .up, .label = "up", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .enter }, .action = .open, .label = "campaigns", .group = .navigate, .pane = 0 },
        .{ .match = .{ .key = .enter }, .action = .open, .label = "continue", .group = .act, .pane = 1 },
        .{ .match = keys.Match.char('n'), .action = .new_campaign, .label = "new campaign", .group = .act },
        .{ .match = keys.Match.char('d'), .action = .delete_campaign, .label = "delete campaign", .group = .act },
        .{ .match = keys.Match.char('p'), .action = .new_player, .label = "new player", .group = .act },
        .{ .match = keys.Match.char('D'), .action = .delete_player, .label = "delete player", .group = .act },
        .{ .match = keys.Match.char('s'), .action = .settings, .label = "settings", .group = .misc },
        .{ .match = keys.Match.char('M'), .action = .music, .label = "music on/off", .group = .misc },
        .{ .match = keys.Match.char('?'), .action = .help, .label = "help", .group = .misc, .show_footer = false },
        .{ .match = keys.Match.char('q'), .action = .quit, .label = "quit", .group = .misc },
    };
    pub const welcome_legend = keys.entries(WelcomeAction, &welcome_bindings);

    fn handleWelcomeKey(self: *App, key: Key) !void {
        const al = self.a();
        const players = try self.store.players(al);
        const campaigns = try self.store.campaigns(al, self.player_id);
        const hit = keys.lookup(WelcomeAction, &welcome_bindings, self.focus, key) orelse return;
        switch (hit.action) {
            .switch_pane => self.focus = if (self.focus == 0) 1 else 0,
            .down => self.welcomeMove(1, players, campaigns),
            .up => self.welcomeMove(-1, players, campaigns),
            .open => {
                if (self.focus == 0) {
                    self.focus = 1;
                } else if (campaigns.len > 0) {
                    try self.loadCampaign(campaigns[self.cur(1).*].id);
                }
            },
            .quit => self.running = false,
            .new_campaign => {
                if (self.player_id == 0) {
                    self.say(.amber, "create a player first", .{});
                } else {
                    self.mode = .wizard;
                    self.step = .commander;
                    self.w_field = 0;
                }
            },
            .new_player => {
                self.input.len = 0;
                self.modal = .{ .input = .new_player };
            },
            .delete_campaign => {
                if (campaigns.len == 0) return;
                self.input.len = 0;
                self.modal = .{ .input = .delete_campaign };
            },
            .delete_player => {
                if (self.player_id == 0) return;
                self.input.len = 0;
                self.modal = .{ .input = .delete_player };
            },
            .settings => self.modal = .settings,
            .music => try self.toggleMusic(),
            .help => self.openModal(.help),
        }
    }

    fn toggleMusic(self: *App) !void {
        const m = &(self.music orelse {
            self.say(.dim, "no soundtrack: put tracks in data/music/ (or $IRON_LEDGER_DATA/music) and have afplay, mpv, ffplay or aplay on PATH", .{});
            return;
        });
        m.setEnabled(!m.enabled);
        self.store.setSetting("music", @intFromBool(m.enabled)) catch |err|
            self.say(.crit, "music preference not saved: {s}", .{game.cli.errorText(err)});
        if (m.enabled) m.poll();
        self.last_track = m.current;
        if (m.enabled) {
            const esc_name = try q.plain(self.a(), m.nowPlaying() orelse "starting");
            const esc_set = try q.plain(self.a(), m.nowPlayingSet() orelse "");
            self.say(.dim, "♪ music on — {s} ({s}) · :music browses, F12 has the controls", .{ esc_name, esc_set });
        } else self.say(.dim, "♪ music off (M turns it back on)", .{});
    }

    fn adjustVolume(self: *App, delta: i32) !void {
        const m = &(self.music orelse return);
        const v: i32 = std.math.clamp(@as(i32, m.volume) + delta, 0, 100);
        m.setVolume(@intCast(v));
        self.store.setSetting("music_volume", v) catch |err|
            self.say(.crit, "music preference not saved: {s}", .{game.cli.errorText(err)});
        m.skip(); // restart the current track at the new level
    }

    fn welcomeMove(self: *App, delta: i32, players: []game.lobby.PlayerInfo, campaigns: []game.lobby.CampaignInfo) void {
        if (self.focus == 0) {
            self.moveCursor(0, delta, players.len);
            if (players.len > 0) {
                self.player_id = players[self.cur(0).*].id;
                self.cur(1).* = 0;
            }
        } else self.moveCursor(1, delta, campaigns.len);
    }

    fn loadCampaign(self: *App, id: i64) !void {
        const loaded = game.lobby.Session.load(self.store, self.gpa, id) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                self.say(.crit, "load failed: {s}", .{game.cli.errorText(err)});
                return;
            },
        };
        if (self.session) |*session| session.close();
        self.session = loaded;
        self.mode = .game;
        self.tab = .desk;
        self.focus = 0;
        self.refreshEmblem();
        const st = try q.status(self.a(), self.state());
        self.say(.good, "loaded \"{s}\" at day {d}", .{ try st.outfit_name.markup(self.a()), st.day });
    }

    /// The wizard's steps: the field index is the focus, so a text field
    /// takes every character while it has it.
    const CommanderAction = enum { back, next_field, prev_field, next, erase, down, up, type };
    pub const commander_bindings = [_]keys.Binding(CommanderAction){
        .{ .match = .{ .key = .tab }, .action = .next_field, .label = "next field", .group = .navigate },
        .{ .match = .{ .key = .backtab }, .action = .prev_field, .label = "previous field", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('j'), .action = .down, .label = "choose", .group = .navigate, .shown = "j/k" },
        .{ .match = .{ .key = .down }, .action = .down, .label = "down", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('k'), .action = .up, .label = "up", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .up }, .action = .up, .label = "up", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .text, .action = .type, .label = "type the name", .group = .act, .pane = 0, .show_footer = false },
        .{ .match = .{ .key = .backspace }, .action = .erase, .label = "erase", .group = .act, .pane = 0, .show_footer = false },
        .{ .match = .{ .key = .enter }, .action = .next, .label = "next step", .group = .act },
        .{ .match = .{ .key = .escape }, .action = .back, .label = "back to welcome", .group = .misc },
    };
    const OutfitAction = enum { back, next_field, prev_field, next, erase, left, right, down, up, type };
    pub const outfit_bindings = [_]keys.Binding(OutfitAction){
        .{ .match = .{ .key = .tab }, .action = .next_field, .label = "next field", .group = .navigate },
        .{ .match = .{ .key = .backtab }, .action = .prev_field, .label = "previous field", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('h'), .action = .left, .label = "logo", .group = .navigate, .shown = "h/j/k/l" },
        .{ .match = .{ .key = .left }, .action = .left, .label = "logo left", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('l'), .action = .right, .label = "logo right", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .right }, .action = .right, .label = "logo right", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('j'), .action = .down, .label = "logo down", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .down }, .action = .down, .label = "logo down", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('k'), .action = .up, .label = "logo up", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .up }, .action = .up, .label = "logo up", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .text, .action = .type, .label = "type the outfit's name", .group = .act, .pane = 0, .show_footer = false },
        .{ .match = .text, .action = .type, .label = "type the company's name", .group = .act, .pane = 1, .show_footer = false },
        .{ .match = .{ .key = .backspace }, .action = .erase, .label = "erase", .group = .act, .pane = 0, .show_footer = false },
        .{ .match = .{ .key = .backspace }, .action = .erase, .label = "erase", .group = .act, .pane = 1, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .enter }, .action = .next, .label = "next step", .group = .act },
        .{ .match = .{ .key = .escape }, .action = .back, .label = "back", .group = .misc },
    };
    const CompanyAction = enum { back, next, switch_pane, down, up, reroll, more, less };
    pub const company_bindings = [_]keys.Binding(CompanyAction){
        .{ .match = keys.Match.char('r'), .action = .reroll, .label = "reroll (new seed)", .group = .act },
        .{ .match = .{ .key = .tab }, .action = .switch_pane, .label = "company / back office", .group = .navigate },
        .{ .match = .{ .key = .backtab }, .action = .switch_pane, .label = "company / back office", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('j'), .action = .down, .label = "row", .group = .navigate, .shown = "j/k", .show_footer = false },
        .{ .match = .{ .key = .down }, .action = .down, .label = "down", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('k'), .action = .up, .label = "up", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .up }, .action = .up, .label = "up", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('+'), .action = .more, .label = "adjust headcount", .group = .act, .shown = "-/+" },
        .{ .match = keys.Match.char('='), .action = .more, .label = "more", .group = .act, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('-'), .action = .less, .label = "fewer", .group = .act, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .enter }, .action = .next, .label = "next step", .group = .act },
        .{ .match = .{ .key = .escape }, .action = .back, .label = "back", .group = .misc },
    };
    const ReviewAction = enum { begin, step, discard };
    pub const review_bindings = [_]keys.Binding(ReviewAction){
        .{ .match = .{ .key = .enter }, .action = .begin, .label = "begin campaign", .group = .act },
        .{ .match = .{ .chars = .{ '1', '3' } }, .action = .step, .label = "back to a step", .group = .navigate },
        .{ .match = .{ .key = .escape }, .action = .discard, .label = "discard", .group = .misc },
    };
    const commander_legend = keys.entries(CommanderAction, &commander_bindings);
    const outfit_legend = keys.entries(OutfitAction, &outfit_bindings);
    const company_legend = keys.entries(CompanyAction, &company_bindings);
    const review_legend = keys.entries(ReviewAction, &review_bindings);

    fn handleWizardKey(self: *App, key: Key) !void {
        switch (self.step) {
            .commander => {
                const hit = keys.lookup(CommanderAction, &commander_bindings, self.w_field, key) orelse return;
                switch (hit.action) {
                    .back => self.mode = .welcome,
                    .next_field => self.w_field = (self.w_field + 1) % 4,
                    .prev_field => self.w_field = (self.w_field + 3) % 4,
                    .next => {
                        if (self.w_name.len == 0) {
                            self.say(.amber, "the commander needs a name", .{});
                            return;
                        }
                        self.step = .outfit;
                        self.w_field = 0;
                        // Load catalog logo names the first time the outfit step is entered.
                        // Thumbnails are decoded lazily (one per draw call) to avoid blocking.
                        if (self.logos.len == 0) {
                            try self.loadLogoList();
                            if (self.logos.len > 0) {
                                const thumbs = try self.gpa.alloc(?emblem_mod.Emblem, self.logos.len);
                                @memset(thumbs, null);
                                self.w_thumbs = thumbs;
                            }
                        }
                        self.adoptLogoName();
                    },
                    .erase => self.w_name.pop(),
                    .down => self.wizardList(1),
                    .up => self.wizardList(-1),
                    .type => self.w_name.push(key.char),
                }
            },
            .outfit => {
                const hit = keys.lookup(OutfitAction, &outfit_bindings, self.w_field, key) orelse return;
                switch (hit.action) {
                    .back => {
                        self.step = .commander;
                        self.w_field = 0;
                    },
                    .next_field => self.w_field = (self.w_field + 1) % 3,
                    .prev_field => self.w_field = (self.w_field + 2) % 3,
                    .next => {
                        if (self.w_outfit.len == 0 or self.w_company.len == 0) {
                            self.say(.amber, "the outfit and its first company need names", .{});
                            return;
                        }
                        try self.generateCampaign();
                        self.step = .company;
                    },
                    .erase => if (self.w_field == 0) {
                        self.w_outfit_auto = false;
                        self.w_outfit.pop();
                    } else self.w_company.pop(),
                    .left => self.gridMove(-1),
                    .right => self.gridMove(1),
                    .down => self.gridMove(5),
                    .up => self.gridMove(-5),
                    .type => if (self.w_field == 0) {
                        self.w_outfit_auto = false;
                        self.w_outfit.push(key.char);
                    } else self.w_company.push(key.char),
                }
            },
            .company => {
                const hit = keys.lookup(CompanyAction, &company_bindings, self.w_field, key) orelse return;
                switch (hit.action) {
                    .back => self.step = .outfit,
                    .next => self.step = .review,
                    .switch_pane => self.w_field = if (self.w_field == 0) 1 else 0,
                    .down => try self.companyMove(1),
                    .up => try self.companyMove(-1),
                    .reroll => {
                        self.w_seed += 1;
                        try self.generateCampaign();
                    },
                    .more => try self.officeAdjust(1),
                    .less => try self.officeAdjust(-1),
                }
            },
            .review => {
                const hit = keys.lookup(ReviewAction, &review_bindings, 0, key) orelse return;
                switch (hit.action) {
                    .discard => {
                        if (self.session) |*session| session.close();
                        self.session = null;
                        self.mode = .welcome;
                    },
                    .begin => try self.beginCampaign(),
                    .step => self.step = @enumFromInt(hit.offset),
                }
            },
        }
    }

    fn companyMove(self: *App, delta: i32) !void {
        if (self.w_field == 0) {
            self.moveCursor(0, delta, 1000);
        } else {
            const g = (self.stateOrNull() orelse return);
            const desks = (try q.backOffice(self.a(), g, q.firstHq(g))).len;
            if (desks == 0) return;
            self.w_office = @intCast(@max(0, @min(@as(i32, @intCast(desks - 1)), @as(i32, @intCast(self.w_office)) + delta)));
        }
    }

    /// Hire (recruit + post) or release one admin of the selected desk in
    /// the generated campaign — the wizard's back-office sizing.
    fn officeAdjust(self: *App, delta: i32) !void {
        const g = (self.stateOrNull() orelse return);
        self.w_field = 1;
        const hq_id = q.firstHq(g);
        const desks = try q.backOffice(self.a(), g, hq_id);
        if (desks.len == 0) return;
        const role = desks[@min(self.w_office, desks.len - 1)].role;
        _ = self.execResult(.{ .set_office_staff = .{ .hq = hq_id, .role = role, .delta = if (delta > 0) 1 else -1 } }) orelse return;
        if (delta > 0) self.say(.good, "hired one {s}", .{@tagName(role)}) else self.say(.amber, "released one {s}", .{@tagName(role)});
    }

    pub fn loadLogoList(self: *App) !void {
        _ = self.lobby.reset(.retain_capacity);
        var all: std.ArrayListUnmanaged([]const u8) = .empty;
        const la = self.lobby.allocator();
        for (self.asset_roots.logos) |d| {
            const names = try emblem_mod.listPngs(self.io, la, d);
            for (names) |n| try all.append(la, try std.fmt.allocPrint(la, "{s}/{s}", .{ d, n }));
        }
        self.logos = try all.toOwnedSlice(la);
    }

    /// Auto-fill the outfit name from the selected catalog logo, unless the
    /// player has manually edited the name (w_outfit_auto == false).
    fn adoptLogoName(self: *App) void {
        if (!self.w_outfit_auto) return;
        if (self.logos.len == 0) return;
        const path = self.logos[@min(self.w_logo, self.logos.len - 1)];
        var buf: [128]u8 = undefined;
        self.w_outfit.set(game.logo_name.titleCaseLogoKey(path, &buf));
        self.w_outfit_auto = true;
    }

    /// Move the grid cursor by `delta` steps (±1 for left/right, ±5 for up/down).
    /// Clamped to [0, logos.len). Adopts the logo name on every move.
    fn gridMove(self: *App, delta: i32) void {
        if (self.logos.len == 0) return;
        const new_idx = @max(0, @min(@as(i32, @intCast(self.logos.len - 1)), @as(i32, @intCast(self.w_logo)) + delta));
        self.w_logo = @intCast(new_idx);
        self.adoptLogoName();
    }

    /// Decode one catalog logo into `w_thumbs[idx]` if not already loaded.
    /// Silently skips logos that cannot be read or decoded (stores null).
    /// Transmits decoded bytes to kitty once on first load.
    /// Called lazily from the draw path for each unloaded visible cell;
    /// idempotent — returns immediately if already loaded.
    fn loadThumbAt(self: *App, idx: usize) void {
        if (idx >= self.w_thumbs.len) return;
        if (self.w_thumbs[idx] != null) return; // already loaded
        const kitty_id: u32 = @intCast(100 + idx);
        // best-effort: a missing or unreadable logo is skipped; others still load.
        const file_bytes = emblem_mod.readFile(self.io, self.gpa, self.logos[idx]) catch return;
        const e = emblem_mod.Emblem.load(self.gpa, file_bytes, kitty_id) catch {
            self.gpa.free(file_bytes);
            return;
        };
        self.gpa.free(file_bytes); // Emblem.load dups; original no longer needed.
        self.w_thumbs[idx] = e;
        // best-effort: an optional graphics image; the half-block fallback or name label still draws.
        if (self.graphics == .kitty) emblem_mod.kittyTransmit(self.term.out, self.gpa, kitty_id, self.w_thumbs[idx].?.bytes) catch {};
    }

    fn wizardList(self: *App, delta: i32) void {
        switch (self.w_field) {
            1 => self.w_faction = @intCast(@max(0, @min(@as(i32, factions.len - 1), @as(i32, @intCast(self.w_faction)) + delta))),
            2 => self.w_profession = @intCast(@max(0, @min(@as(i32, professions.len - 1), @as(i32, @intCast(self.w_profession)) + delta))),
            3 => self.w_year = @intCast(@max(0, @min(@as(i32, start_years.len - 1), @as(i32, @intCast(self.w_year)) + delta))),
            else => {},
        }
    }

    fn generateCampaign(self: *App) !void {
        // Build the replacement session fully before touching the current one
        // (rule 63): on failure the open session stays valid.
        const now = std.Io.Clock.now(.real, self.io);
        const entropy: u64 = self.seed_override orelse @truncate(@as(u96, @bitCast(now.nanoseconds)));
        const seed: u64 = entropy ^ (self.w_seed *% 7919) ^ (@as(u64, @intCast(self.w_faction)) *% 13);
        // Use the selected catalog thumbnail's bytes as the campaign emblem image.
        // Force-load the selected cell before reading its bytes: the draw loop decodes
        // lazily (one cell per frame) so navigating down and immediately pressing next
        // can leave the selected cell null. loadThumbAt is idempotent and best-effort.
        self.loadThumbAt(self.w_logo);
        const image: []const u8 = if (self.w_logo < self.w_thumbs.len)
            if (self.w_thumbs[self.w_logo]) |e| e.bytes else &.{}
        else
            &.{};
        const logo_key: []const u8 = if (self.logos.len > 0)
            std.fs.path.stem(self.logos[@min(self.w_logo, self.logos.len - 1)])
        else
            "";
        var new_session = try game.lobby.Session.freshCampaign(self.gpa, seed, .{
            .commander_name = self.w_name.slice(),
            .origin = factions[self.w_faction],
            .profession = professions[self.w_profession],
            .start_year = start_years[self.w_year],
            .outfit_name = self.w_outfit.slice(),
            .company_name = self.w_company.slice(),
            .emblem_image = image,
            .logo_key = logo_key,
        });
        errdefer new_session.close();
        // Replacement is ready; close the old session and install the new one (rule 63).
        if (self.session) |*session| session.close();
        self.session = new_session;
        self.cur(0).* = 0;
    }

    fn beginCampaign(self: *App) !void {
        if (self.session == null) return;
        self.store.save(&self.session.?, self.player_id) catch |err| {
            self.say(.crit, "save failed: {s}", .{game.cli.errorText(err)});
            return;
        };
        self.mode = .game;
        self.tab = .desk;
        self.focus = 0;
        self.refreshEmblem();
        self.say(.good, "campaign \"{s}\" begins — day 0. Press ? for help.", .{try (try q.status(self.a(), self.state())).outfit_name.markup(self.a())});
    }

    fn handleGameKey(self: *App, key: Key) !void {
        if (keys.lookup(GlobalAction, &global_bindings, self.focus, key)) |hit| return self.runGlobal(hit);
        _ = try screenSpec(self.tab).handle(self, key);
    }

    /// Keys every game screen shares. No screen binds one of these (a test
    /// checks), so the order `handleGameKey` asks in never matters.
    pub const GlobalAction = enum { screen, screen_digit, screen_market, settings, next_pane, prev_pane, cursor_down, cursor_up, page_down, page_up, scroll_left, scroll_right, clear_message, command, end_turn, end_week, quit, music, help };

    pub const global_bindings = [_]keys.Binding(GlobalAction){
        .{ .match = .{ .fkeys = .{ 1, 10 } }, .action = .screen, .label = "screens", .group = .navigate, .shown = "F1-F10 / 1-0", .show_footer = false, .help = "switch screens: Desk, Map, Forces, Contracts, Ledger, Supply, HQ, Lab, People, Market" },
        .{ .match = .{ .chars = .{ '1', '9' } }, .action = .screen_digit, .label = "screens 1-9", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('0'), .action = .screen_market, .label = "market", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .{ .f = 12 } }, .action = .settings, .label = "settings", .group = .misc, .show_footer = false },
        .{ .match = .{ .key = .tab }, .action = .next_pane, .label = "pane", .group = .navigate, .show_footer = false, .help = "next pane (F8: next location; Shift-Tab: previous)" },
        .{ .match = .{ .key = .backtab }, .action = .prev_pane, .label = "previous pane", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('j'), .action = .cursor_down, .label = "cursor", .group = .navigate, .shown = "j/k ↑/↓", .show_footer = false, .help = "move the cursor (PgUp/PgDn ten rows)" },
        .{ .match = .{ .key = .down }, .action = .cursor_down, .label = "down", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('k'), .action = .cursor_up, .label = "up", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .up }, .action = .cursor_up, .label = "up", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .pgdn }, .action = .page_down, .label = "page down", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .pgup }, .action = .page_up, .label = "page up", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .left }, .action = .scroll_left, .label = "columns", .group = .navigate, .shown = "← →", .show_footer = false, .help = "scroll a wide table's columns (◀ 2 · 3 ▶ = hidden); pan the star map" },
        .{ .match = .{ .key = .right }, .action = .scroll_right, .label = "columns", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .escape }, .action = .clear_message, .label = "clear the status line", .group = .misc, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char(':'), .action = .command, .label = "command", .group = .misc, .help = "the command line: every CLI verb works (day, transfer, order, accept, …)" },
        .{ .match = keys.Match.char('n'), .action = .end_turn, .label = "end turn", .group = .misc, .help = "end the turn (the checklist opens first)" },
        .{ .match = keys.Match.char('N'), .action = .end_week, .label = "end 7 turns", .group = .misc, .show_footer = false, .help = "end 7 turns (the checklist opens first)" },
        .{ .match = keys.Match.char('M'), .action = .music, .label = "music on/off", .group = .misc, .show_footer = false },
        .{ .match = keys.Match.char('?'), .action = .help, .label = "help", .group = .misc },
        .{ .match = keys.Match.char('q'), .action = .quit, .label = "welcome", .group = .misc, .help = "back to the welcome screen (save / discard / stay)" },
    };
    pub const global_legend = keys.entries(GlobalAction, &global_bindings);

    fn appendHelpLegendRows(rows: *std.ArrayListUnmanaged([]const u8), al: std.mem.Allocator, title: []const u8, legend: []const keys.Entry) !void {
        try rows.append(al, try std.fmt.allocPrint(al, "  {{t}}{s}{{/}}", .{title}));
        var key_width: usize = 0;
        for (legend) |entry| {
            if (!entry.show_help) continue;
            var key_buf: [16]u8 = undefined;
            key_width = @max(key_width, screen_mod.visibleLen(keys.keyText(&key_buf, entry)));
        }
        const groups = [_]keys.Group{ .navigate, .act, .money, .misc };
        for (groups) |group| {
            var any = false;
            for (legend) |entry| if (entry.group == group and entry.show_help) {
                any = true;
            };
            if (!any) continue;
            if (rows.items.len > 1 and rows.items[rows.items.len - 1].len > 0) try rows.append(al, "");
            for (legend) |entry| {
                if (entry.group != group or !entry.show_help) continue;
                var key_buf: [16]u8 = undefined;
                const key = keys.keyText(&key_buf, entry);
                var line: std.ArrayListUnmanaged(u8) = .empty;
                try line.appendSlice(al, "    ");
                try line.appendSlice(al, key);
                try line.appendNTimes(al, ' ', key_width - screen_mod.visibleLen(key) + 2);
                try line.appendSlice(al, entry.help orelse entry.label);
                try rows.append(al, try line.toOwnedSlice(al));
            }
        }
    }

    /// The help modal's key reference, filtered to the active context.
    fn keyHelpRows(self: *App, al: std.mem.Allocator) ![]const []const u8 {
        var rows: std.ArrayListUnmanaged([]const u8) = .empty;
        switch (self.mode) {
            .game => {
                try appendHelpLegendRows(&rows, al, "everywhere", &global_legend);
                const spec = screenSpec(self.tab);
                try rows.append(al, "");
                try appendHelpLegendRows(&rows, al, spec.name, spec.legend);
            },
            .welcome => {
                try appendHelpLegendRows(&rows, al, "Welcome", &welcome_legend);
            },
            .wizard => {
                const step_legend: []const keys.Entry = switch (self.step) {
                    .commander => &commander_legend,
                    .outfit => &outfit_legend,
                    .company => &company_legend,
                    .review => &review_legend,
                };
                const step_name = switch (self.step) {
                    .commander => "New campaign · commander",
                    .outfit => "New campaign · outfit and emblem",
                    .company => "New campaign · company and back office",
                    .review => "New campaign · review",
                };
                try appendHelpLegendRows(&rows, al, step_name, step_legend);
            },
        }
        return rows.toOwnedSlice(al);
    }

    /// The key reference block in docs/tui.md, generated from the tables;
    /// `game --keys-markdown` prints it and a test compares the doc to it.
    pub fn keysMarkdown(al: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.appendSlice(al, keys_begin ++ "\n\n### Every screen\n\n| Key | Does |\n|---|---|\n");
        for (global_legend) |e| if (e.show_help) {
            var buf: [16]u8 = undefined;
            try out.print(al, "| `{s}` | {s} |\n", .{ keys.keyText(&buf, e), e.help orelse e.label });
        };
        for (screen_table) |spec| {
            try out.print(al, "\n### {s}\n\n| Key | Pane | Does |\n|---|---|---|\n", .{spec.name});
            for (spec.legend) |e| if (e.show_help) {
                var buf: [16]u8 = undefined;
                const pane = if (e.pane) |p| spec.pane_names[p] else "any";
                try out.print(al, "| `{s}` | {s} | {s} |\n", .{ keys.keyText(&buf, e), pane, e.help orelse e.label });
            };
        }
        for (other_tables) |t| {
            try out.print(al, "\n### {s}\n\n| Key | Does |\n|---|---|\n", .{t.name});
            for (t.legend) |e| if (e.show_help) {
                var buf: [16]u8 = undefined;
                try out.print(al, "| `{s}` | {s} |\n", .{ keys.keyText(&buf, e), e.help orelse e.label });
            };
            for (t.extra_legend) |e| if (e.show_help) {
                var buf: [16]u8 = undefined;
                try out.print(al, "| `{s}` | {s} |\n", .{ keys.keyText(&buf, e), e.help orelse e.label });
            };
        }
        try out.appendSlice(al, "\n" ++ keys_end);
        return out.toOwnedSlice(al);
    }

    /// The tables outside the game screens, as the key reference lists them.
    const other_tables = [_]struct { name: []const u8, legend: []const keys.Entry, extra_legend: []const keys.Entry = &.{} }{
        .{ .name = "Welcome", .legend = &welcome_legend },
        .{ .name = "New campaign · commander", .legend = &commander_legend },
        .{ .name = "New campaign · outfit and emblem", .legend = &outfit_legend },
        .{ .name = "New campaign · company and back office", .legend = &company_legend },
        .{ .name = "New campaign · review", .legend = &review_legend },
        .{ .name = "Lists (pick a company, a part, a seat, …)", .legend = &list_legend },
        .{ .name = "Sheets (hull, summary, …)", .legend = &sheet_legend },
        .{ .name = "Help", .legend = &help_navigation_legend, .extra_legend = &help_legend },
        .{ .name = "Raise a company · hulls", .legend = &raise_hulls_legend },
        .{ .name = "Raise a company · support train", .legend = &raise_support_legend },
        .{ .name = "Raise a company · crews", .legend = &raise_crews_legend },
        .{ .name = "Soundtrack", .legend = &music_legend },
        .{ .name = "Decision", .legend = &decision_legend },
        .{ .name = "Contract log", .legend = &log_legend },
        .{ .name = "After-action report", .legend = &after_action_legend },
        .{ .name = "Emblem editor", .legend = &editor_legend },
        .{ .name = "Number form", .legend = &amount_legend },
        .{ .name = "Battle orders and settings", .legend = &form_legend },
        .{ .name = "Settings shortcuts", .legend = &settings_legend },
        .{ .name = "End turn", .legend = &end_turn_legend },
        .{ .name = "Leave the campaign", .legend = &quit_legend },
        .{ .name = "Game over", .legend = &game_over_legend },
        .{ .name = "Confirm (fire, sell, disband, recall)", .legend = &confirm_legend },
        .{ .name = "Text prompts and the command line", .legend = &input_legend },
    };

    pub const keys_begin = "<!-- keys: generated from the binding tables by `game --keys-markdown`; a test compares this block -->";
    pub const keys_end = "<!-- /keys -->";

    fn runGlobal(self: *App, hit: keys.Hit(GlobalAction)) !void {
        switch (hit.action) {
            .screen => self.switchTab(@enumFromInt(hit.offset)),
            .screen_digit => self.switchTab(@enumFromInt(hit.offset)),
            .screen_market => self.switchTab(.market),
            .settings => self.modal = .settings,
            .next_pane => {
                if (self.tab == .lab) try screens.lab.navigateLocation(self, 1) else self.focus = (self.focus + 1) % self.paneCount();
            },
            .prev_pane => {
                if (self.tab == .lab) try screens.lab.navigateLocation(self, -1) else self.focus = (self.focus + self.paneCount() - 1) % self.paneCount();
            },
            .cursor_down => try self.screenMove(1),
            .cursor_up => try self.screenMove(-1),
            .page_down => try self.screenMove(10),
            .page_up => try self.screenMove(-10),
            .scroll_left => if (screenSpec(self.tab).scroll_h) |f| try f(self, -1) else if (self.focus_scroll) |pane| {
                self.colScroll(pane).* -|= 1;
            },
            .scroll_right => if (screenSpec(self.tab).scroll_h) |f| try f(self, 1) else if (self.focus_scroll) |pane| {
                self.colScroll(pane).* += 1;
            },
            .clear_message => self.msg.len = 0,
            .command => {
                self.input.set(self.cmd_prefill.slice());
                self.cmd_prefill.len = 0;
                self.modal = .{ .input = .command };
            },
            .end_turn => try self.endTurnRequest(1),
            .end_week => try self.endTurnRequest(7),
            .quit => self.modal = .quit,
            .music => try self.toggleMusic(),
            .help => self.openModal(.help),
        }
    }

    pub fn switchTab(self: *App, tab: Tab) void {
        self.tab = tab;
        self.focus = 0;
    }

    fn paneCount(self: *App) u8 {
        const spec = screenSpec(self.tab);
        return if (self.narrow()) spec.narrow_panes else spec.panes;
    }

    fn screenMove(self: *App, delta: i32) !void {
        return screenSpec(self.tab).move(self, delta);
    }

    /// One screen, one row (rule 35): adding a screen adds a row here and
    /// the five functions it names — no switch anywhere else grows.
    const ScreenSpec = struct {
        tab: Tab,
        /// The tab-strip label ("F1 Desk", …).
        name: []const u8,
        draw: *const fn (*App) anyerror!void,
        move: *const fn (*App, i32) anyerror!void,
        /// Resolve a key through the screen's bindings and run its action;
        /// false when the screen has no binding for it.
        handle: *const fn (*App, Key) anyerror!bool,
        /// The screen's bindings, for the footer, pane titles and help.
        legend: []const keys.Entry,
        /// What each pane (focus index) is called in the key reference.
        pane_names: []const []const u8,
        /// Panes Tab cycles through, and the count on a narrow terminal.
        panes: u8,
        narrow_panes: u8,
        /// Optional horizontal-scroll handler for ←/→ in `runGlobal`.
        scroll_h: ?*const fn (*App, i32) anyerror!void = null,
    };

    const screens = struct {
        const desk = @import("screens/desk.zig");
        const map = @import("screens/map.zig");
        const forces = @import("screens/forces.zig");
        const contracts = @import("screens/contracts.zig");
        const ledger = @import("screens/ledger.zig");
        const supply = @import("screens/supply.zig");
        const hq = @import("screens/hq.zig");
        const lab = @import("screens/lab.zig");
        const people = @import("screens/people.zig");
        const market = @import("screens/market.zig");
    };

    const screen_table = [_]ScreenSpec{
        .{ .tab = .desk, .name = "F1 Desk", .draw = screens.desk.draw, .move = screens.desk.move, .handle = screens.desk.handle, .legend = &screens.desk.legend, .pane_names = &.{ "checklist", "inbox", "log", "reports" }, .panes = 4, .narrow_panes = 4 },
        .{ .tab = .map, .name = "F2 Map", .draw = screens.map.draw, .move = screens.map.move, .handle = screens.map.handle, .legend = &screens.map.legend, .pane_names = &.{"star map"}, .panes = 1, .narrow_panes = 1, .scroll_h = screens.map.scrollH },
        .{ .tab = .forces, .name = "F3 Forces", .draw = screens.forces.draw, .move = screens.forces.move, .handle = screens.forces.handle, .legend = &screens.forces.legend, .pane_names = &.{ "TO&E", "side pane" }, .panes = 2, .narrow_panes = 1 },
        .{ .tab = .contracts, .name = "F4 Contracts", .draw = screens.contracts.draw, .move = screens.contracts.move, .handle = screens.contracts.handle, .legend = &screens.contracts.legend, .pane_names = &.{ "board", "active", "history" }, .panes = 3, .narrow_panes = 3 },
        .{ .tab = .ledger, .name = "F5 Ledger", .draw = screens.ledger.draw, .move = screens.ledger.move, .handle = screens.ledger.handle, .legend = &screens.ledger.legend, .pane_names = &.{ "treasuries", "ledger" }, .panes = 2, .narrow_panes = 2 },
        .{ .tab = .supply, .name = "F6 Supply", .draw = screens.supply.draw, .move = screens.supply.move, .handle = screens.supply.handle, .legend = &screens.supply.legend, .pane_names = &.{"sites"}, .panes = 1, .narrow_panes = 1 },
        .{ .tab = .hq, .name = "F7 HQ", .draw = screens.hq.draw, .move = screens.hq.move, .handle = screens.hq.handle, .legend = &screens.hq.legend, .pane_names = &.{ "HQ", "hiring hall" }, .panes = 2, .narrow_panes = 2 },
        .{ .tab = .lab, .name = "F8 Lab", .draw = screens.lab.draw, .move = screens.lab.move, .handle = screens.lab.handle, .legend = &screens.lab.legend, .pane_names = &.{"mounts"}, .panes = 1, .narrow_panes = 1 },
        .{ .tab = .people, .name = "F9 People", .draw = screens.people.draw, .move = screens.people.move, .handle = screens.people.handle, .legend = &screens.people.legend, .pane_names = &.{"roster"}, .panes = 1, .narrow_panes = 1 },
        .{ .tab = .market, .name = "F10 Market", .draw = screens.market.draw, .move = screens.market.move, .handle = screens.market.handle, .legend = &screens.market.legend, .pane_names = &.{ "board", "catalog", "demand", "keep stocked" }, .panes = 4, .narrow_panes = 2 },
    };

    comptime {
        for (screen_table, 0..) |spec, i| if (spec.tab != @as(Tab, @enumFromInt(i))) @compileError("screen_table is in Tab order");
    }

    fn screenSpec(tab: Tab) *const ScreenSpec {
        return &screen_table[@intFromEnum(tab)];
    }

    // ---- battle orders: the levers that can still change the fight ----

    const OrdersRow = struct {
        kind: enum { info, roe, lance, rush, recall, confirm },
        force: types.ForceId = .none,
        active: bool = false,
        text: []const u8,
    };
    const OrdersForm = struct { title: []const u8, rows: []OrdersRow, company: types.ForceId };

    /// The box's rows from `queries.battleOrders`; null once the engagement
    /// is no longer in view.
    fn ordersRows(self: *App, al: std.mem.Allocator, id: types.ContractId) !?OrdersForm {
        const v = (try q.battleOrders(al, self.state(), id)) orelse return null;
        var rows: std.ArrayListUnmanaged(OrdersRow) = .empty;
        try rows.append(al, .{ .kind = .info, .text = "" });
        for (v.situation) |line| try rows.append(al, .{ .kind = .info, .text = try std.fmt.allocPrint(al, "  {s}", .{line}) });
        try rows.append(al, .{ .kind = .info, .text = "" });
        try rows.append(al, .{ .kind = .roe, .active = !v.roe_locked, .text = try std.fmt.allocPrint(al, "  rules of engagement  {{a}}{s}{{/}}  {s}", .{
            @tagName(v.roe), if (v.roe_locked) "{d}(set by the employer's integrated command){/}" else try std.fmt.allocPrint(al, "{{d}}{s}{{/}}", .{v.roe.describe()}),
        }) });
        for (v.lances) |l| try rows.append(al, .{ .kind = .lance, .force = l.force, .active = true, .text = try std.fmt.allocPrint(al, "  lance  {s}  {{d}}{s}{{/}}", .{ l.text, l.role.describe() }) });
        try rows.append(al, .{ .kind = .info, .text = "" });
        try rows.append(al, .{ .kind = .rush, .active = v.rush.len > 0, .text = if (v.rush.len > 0)
            try std.fmt.allocPrint(al, "  emergency resupply  {s}  {{d}}{s}{{/}}", .{ v.rush, try keyHint(FormAction, al, &form_bindings, .act, "buy") })
        else
            "  emergency resupply  {d}the stores cover the next fight{/}" });
        try rows.append(al, .{ .kind = .recall, .active = true, .text = try std.fmt.allocPrint(al, "  recall the company  {{c}}breaches the contract{{/}}  {{d}}{s}{{/}}", .{try keyHint(FormAction, al, &form_bindings, .act, "asks first")}) });
        try rows.append(al, .{ .kind = .confirm, .active = true, .text = if (v.confirmed) try std.fmt.allocPrint(al, "  {{g}}orders given{{/}}  {{d}}{s} · {s}{{/}}", .{ try keyHint(FormAction, al, &form_bindings, .act, "close"), try keyHint(FormAction, al, &form_bindings, .close, "close") }) else try std.fmt.allocPrint(al, "  {{g}}confirm these orders{{/}}  {{d}}{s} — the contact warning clears{{/}}", .{try keyHint(FormAction, al, &form_bindings, .act, "confirm")}) });
        return .{ .title = v.title, .rows = try rows.toOwnedSlice(al), .company = v.company };
    }

    /// Keep the cursor on an active row, stepping in `dir` from where it is.
    fn ordersSnap(self: *App, form: OrdersForm, dir: i32) void {
        clampIdx(&self.modal_cursor, form.rows.len);
        var steps: usize = 0;
        while (!form.rows[self.modal_cursor].active and steps < form.rows.len) : (steps += 1) {
            const n: i32 = @intCast(form.rows.len);
            self.modal_cursor = @intCast(@mod(@as(i32, @intCast(self.modal_cursor)) + dir, n));
        }
    }

    fn ordersMove(self: *App, id: types.ContractId, dir: i32) !void {
        const form = (try self.ordersRows(self.a(), id)) orelse return;
        const n: i32 = @intCast(form.rows.len);
        self.modal_cursor = @intCast(@mod(@as(i32, @intCast(self.modal_cursor)) + dir, n));
        self.ordersSnap(form, dir);
    }

    fn ordersAdjust(self: *App, id: types.ContractId, dir: i32) !void {
        const form = (try self.ordersRows(self.a(), id)) orelse return;
        const row = form.rows[@min(self.modal_cursor, form.rows.len - 1)];
        switch (row.kind) {
            .roe => {
                const view = (try q.battleOrders(self.a(), self.state(), id)) orelse return;
                const next = if (dir > 0) view.roe.next() else view.roe.prev();
                _ = try self.execSay(.{ .set_roe = .{ .company = form.company, .roe = next } }, .good, "ROE → {s}: {s}", .{ @tagName(next), next.describe() });
            },
            .lance => {
                const view = (try q.battleOrders(self.a(), self.state(), id)) orelse return;
                for (view.lances) |l| if (l.force == row.force) {
                    const next = if (dir > 0) l.role.next() else l.role.prev();
                    _ = try self.execSay(.{ .set_role = .{ .force = l.force, .role = next } }, .good, "lance → {s}: {s}", .{ @tagName(next), next.describe() });
                };
            },
            else => {},
        }
    }

    fn ordersEnter(self: *App, id: types.ContractId) !void {
        const form = (try self.ordersRows(self.a(), id)) orelse return;
        const row = form.rows[@min(self.modal_cursor, form.rows.len - 1)];
        switch (row.kind) {
            .roe, .lance => try self.ordersAdjust(id, 1),
            .rush => _ = try self.execSay(.{ .emergency_resupply = id }, .good, "emergency resupply bought on the contract world — in the field stores now", .{}),
            .recall => self.modal = .{ .confirm = .{ .kind = .recall_breach, .id = @intFromEnum(form.company) } },
            .confirm => {
                if (try self.execSay(.{ .confirm_orders = id }, .good, "battle orders given — the contact warning is cleared", .{})) self.modal = .none;
            },
            .info => {},
        }
    }

    /// Open the battle orders for a contract, cursor on the first lever.
    pub fn openOrders(self: *App, id: types.ContractId) void {
        self.openModal(.{ .battle_orders = id });
    }

    // ---- settings form: one look with the pickers and the amount form ----

    pub const SettingKey = enum { music, volume, track, soundtrack, auto_admit, difficulty, shares, info };
    const SettingRow = struct { key: SettingKey, active: bool, text: []const u8 };
    const SettingsForm = struct { rows: []SettingRow, selectable: usize };

    fn settingsRows(self: *App, al: std.mem.Allocator) !SettingsForm {
        var rows: std.ArrayListUnmanaged(SettingRow) = .empty;
        var selectable: usize = 0;
        const info = struct {
            fn add(list: *std.ArrayListUnmanaged(SettingRow), alloc: std.mem.Allocator, text: []const u8) !void {
                try list.append(alloc, .{ .key = .info, .active = false, .text = text });
            }
        };
        try info.add(&rows, al, "");
        if (self.music) |*m| {
            try rows.append(al, .{ .key = .music, .active = true, .text = try std.fmt.allocPrint(al, "  music        {s}", .{if (m.enabled) "{g}on{/}" else "{c}off{/}"}) });
            try rows.append(al, .{ .key = .volume, .active = true, .text = try std.fmt.allocPrint(al, "  volume       {d: >3}      {{d}}restarts the track{{/}}", .{m.volume}) });
            try rows.append(al, .{ .key = .track, .active = true, .text = try std.fmt.allocPrint(al, "  track        {s}{s}", .{ try q.plain(al, m.nowPlaying() orelse "—"), if (m.nowPlayingSet()) |set| try std.fmt.allocPrint(al, "  {{d}}({s}){{/}}", .{try q.plain(al, set)}) else "" }) });
            try rows.append(al, .{ .key = .soundtrack, .active = true, .text = try std.fmt.allocPrint(al, "  soundtrack   {{a}}{s}{{/}}      {{d}}{s} (also :music){{/}}", .{ try keyHint(FormAction, al, &form_bindings, .act, "browse soundtracks and tracks"), try q.plain(al, m.setName(m.selected_set)) }) });
            try info.add(&rows, al, try std.fmt.allocPrint(al, "  {{d}}tracks       {d} in {d} soundtrack{s} under {s} · player: {s}{{/}}", .{ m.tracks.len, m.sets.len, if (m.sets.len == 1) "" else "s", m.root, m.player_cmd orelse "{c}none found{/}" }));
            selectable += 4;
        } else {
            try info.add(&rows, al, try std.fmt.allocPrint(al, "  {{d}}{s}{{/}}", .{self.music_note}));
        }
        try info.add(&rows, al, "");
        if (self.stateOrNull()) |gs| {
            const cfg = try q.settings(al, gs);
            try rows.append(al, .{ .key = .auto_admit, .active = true, .text = try std.fmt.allocPrint(al, "  medbay       auto-admit the wounded {s}      {{d}}off: you admit each casualty (m on People) and the turn waits{{/}}", .{if (cfg.auto_admit) "{g}on{/}" else "{c}off{/}"}) });
            try rows.append(al, .{ .key = .difficulty, .active = true, .text = try std.fmt.allocPrint(al, "  difficulty   {{a}}{s}{{/}} — {s}", .{ cfg.difficulty_name, cfg.difficulty_blurb }) });
            try info.add(&rows, al, try std.fmt.allocPrint(al, "  {{d}}             {s}{{/}}", .{cfg.multipliers}));
            try rows.append(al, .{ .key = .shares, .active = true, .text = try std.fmt.allocPrint(al, "  shares       {{a}}{d}%{{/}} of contract income to shareholders at completion      {{d}}{s} · {s} · founders, veterans and officers hold shares{{/}}", .{ cfg.shares_pct, try keyHint(FormAction, al, &form_bindings, .less, "±5"), try keyHint(FormAction, al, &form_bindings, .act, "type a figure") }) });
            try info.add(&rows, al, "");
            selectable += 3;
        }
        try info.add(&rows, al, try std.fmt.allocPrint(al, "  {{d}}graphics     {s} · colour {s} · glyphs {s}{{/}}", .{ switch (self.graphics) {
            .kitty => "kitty protocol",
            .iterm2 => "iTerm2 inline images",
            .none => "half-block",
        }, if (self.screen.truecolor) "24-bit" else "256", if (self.screen.ascii) "ascii" else "box-drawing" }));
        try info.add(&rows, al, try std.fmt.allocPrint(al, "  {{d}}data         {s} · `zig build -Ddata=<dir>` overlays data/*.zon — docs/modding.md{{/}}", .{try game.lobby.dataProvenance(al)}));
        clampIdx(&self.settings_cursor, rows.items.len);
        return .{ .rows = try rows.toOwnedSlice(al), .selectable = selectable };
    }

    /// Move the highlight to the next selectable row in `dir`.
    fn settingsMove(self: *App, dir: i32) !void {
        const form = try self.settingsRows(self.a());
        if (form.selectable == 0) return;
        var i = self.settings_cursor;
        var steps: usize = 0;
        while (steps < form.rows.len) : (steps += 1) {
            i = if (dir > 0) (i + 1) % form.rows.len else (i + form.rows.len - 1) % form.rows.len;
            if (form.rows[i].active) break;
        }
        self.settings_cursor = i;
    }

    fn settingsAdjust(self: *App, dir: i32) !void {
        const form = try self.settingsRows(self.a());
        if (form.selectable == 0) return;
        switch (form.rows[self.settings_cursor].key) {
            .music => try self.toggleMusic(),
            .volume => try self.adjustVolume(if (dir > 0) 10 else -10),
            .track => if (self.music) |*m| {
                if (dir > 0) m.skip() else m.back();
            },
            .soundtrack => {
                self.openModal(.music);
            },
            .auto_admit => try self.toggleAutoAdmit(),
            .difficulty => try self.cycleDifficulty(if (dir > 0) 1 else -1),
            .shares => if (self.session != null) {
                const res = self.execResult(.{ .adjust_shares_pct = if (dir > 0) 5 else -5 }) orelse return;
                self.say(.good, "shareholders take {d}% of contract income at completion", .{res.shares_pct});
            },
            .info => {},
        }
    }

    fn settingsEnter(self: *App) !void {
        const form = try self.settingsRows(self.a());
        if (form.selectable == 0) {
            self.modal = .none;
            return;
        }
        switch (form.rows[self.settings_cursor].key) {
            .shares => if (self.stateOrNull()) |gs| self.openAmount("SHAREHOLDERS' CUT OF CONTRACT INCOME", .shares, &.{
                .{ .label = "percent", .value = (try q.settings(self.a(), gs)).shares_pct, .min = 0, .max = 100, .step = 5 },
            }),
            .volume => try self.adjustVolume(10),
            .track => if (self.music) |*m| m.skip(),
            else => try self.settingsAdjust(1),
        }
    }

    fn cycleDifficulty(self: *App, dir: i8) !void {
        if (self.session != null) {
            const res = self.execResult(.{ .cycle_difficulty = dir }) orelse return;
            self.say(.good, "difficulty: {s} — {s}", .{ res.difficulty_name, res.difficulty_blurb });
        }
    }

    fn toggleAutoAdmit(self: *App) !void {
        if (self.session != null) {
            const res = self.execResult(.toggle_auto_admit) orelse return;
            self.say(.good, "medbay auto-admit {s}", .{if (res.auto_admit orelse false) "on — casualties are admitted each morning" else "off — admit casualties yourself (m on People); the turn waits for it"});
        }
    }

    /// Open the amount form: one to three numbers with defaults, ranges and steps.
    pub fn openAmount(self: *App, title: []const u8, action: AmountAction, fields: []const AmountField) void {
        var form: AmountForm = .{ .action = action, .fields = undefined, .n = @intCast(@min(fields.len, 3)) };
        const tn = @min(title.len, form.title_buf.len);
        @memcpy(form.title_buf[0..tn], title[0..tn]);
        form.title_len = @intCast(tn);
        const k: []const u8 = switch (action) {
            .stock_policy => |x| x.key,
            .fabricate => |x| x.key,
            .order => |x| x.key,
            .ship => |x| x.key,
            .sell => |x| x.key,
            else => "",
        };
        const kn = @min(k.len, form.key_buf.len);
        @memcpy(form.key_buf[0..kn], k[0..kn]);
        form.key_len = @intCast(kn);
        for (fields[0..form.n], 0..) |f, i| {
            form.fields[i] = f;
            form.fields[i].value = std.math.clamp(f.value, f.min, f.max);
        }
        self.modal = .{ .amount = form };
    }

    fn treasuryTok(buf: []u8, t: Treasury) []const u8 {
        return switch (t) {
            .outfit => "outfit",
            .hq => |id| std.fmt.bufPrint(buf, "hq:{d}", .{@intFromEnum(id)}) catch "outfit",
            .company => |id| std.fmt.bufPrint(buf, "co:{d}", .{@intFromEnum(id)}) catch "outfit",
        };
    }

    /// Confirm the amount form: build the verb line and run it through the
    /// shared parser, exactly as if it had been typed.
    fn amountRun(self: *App) !void {
        var form = self.modal.amount;
        self.modal = .none;
        // The range applies on submit, not while editing.
        for (form.fields[0..form.n]) |*f| f.value = std.math.clamp(f.value, f.min, f.max);
        const v = form.fields;
        var buf: [160]u8 = undefined;
        var tok_buf: [24]u8 = undefined;
        const line: []const u8 = switch (form.action) {
            .loan => try std.fmt.bufPrint(&buf, "loan {d} {d}", .{ v[0].value, v[1].value }),
            .repay => |idx| try std.fmt.bufPrint(&buf, "repay {d} {d}", .{ idx, v[0].value }),
            .transfer_to => |t| try std.fmt.bufPrint(&buf, "transfer outfit {s} {d}", .{ treasuryTok(&tok_buf, t), v[0].value }),
            .transfer_back => |t| try std.fmt.bufPrint(&buf, "transfer {s} outfit {d}", .{ treasuryTok(&tok_buf, t), v[0].value }),
            .policy => |t| try std.fmt.bufPrint(&buf, "policy {s} {d} {d}", .{ treasuryTok(&tok_buf, t), v[0].value, v[1].value }),
            .supply_policy => |co| try std.fmt.bufPrint(&buf, "supplypolicy co:{d} {d} {d} {d}", .{ @intFromEnum(co), v[0].value, v[1].value, v[2].value }),
            .leave => |pid| try std.fmt.bufPrint(&buf, "leave {d} {d}", .{ @intFromEnum(pid), v[0].value }),
            .triage => |pid| try std.fmt.bufPrint(&buf, "triage {d} {d}", .{ @intFromEnum(pid), v[0].value }),
            .stock_policy => |sp| try std.fmt.bufPrint(&buf, "stockpolicy hq:{d} {s} {d} {d}", .{ sp.hq, form.key(), v[0].value, v[1].value }),
            .fabricate => |fb| try std.fmt.bufPrint(&buf, "fabricate hq:{d} {s} {d}", .{ fb.hq, form.key(), v[0].value }),
            .order => |o| switch (o.site) {
                .company => |id| try std.fmt.bufPrint(&buf, "order {s} {d} co:{d}", .{ form.key(), v[0].value, @intFromEnum(id) }),
                .hq => |id| try std.fmt.bufPrint(&buf, "order {s} {d} hq:{d}", .{ form.key(), v[0].value, @intFromEnum(id) }),
                .outfit => try std.fmt.bufPrint(&buf, "order {s} {d}", .{ form.key(), v[0].value }),
            },
            .ship => |sh| try std.fmt.bufPrint(&buf, "ship {s} {d} hq:{d} co:{d}", .{ form.key(), v[0].value, sh.from, @intFromEnum(sh.to) }),
            .sell => |se| try std.fmt.bufPrint(&buf, "sellstock hq:{d} {s} {d}", .{ se.hq, form.key(), v[0].value }),
            .shares => try std.fmt.bufPrint(&buf, "shares {d}", .{v[0].value}),
        };
        try self.runCommandLine(line);
    }

    /// The generic picker's rows, title and header for whichever pick modal is up.
    const PickView = struct { title: []const u8, cols: []const q.Col, rows: []q.PickRow, empty: []const u8 };

    fn pickView(self: *App, al: std.mem.Allocator) !PickView {
        const g = self.state();
        return switch (self.modal) {
            .pick_company => |pc| .{
                .title = try listTitle(al, try std.fmt.allocPrint(al, "SEND {s} TO", .{switch (pc.what) {
                    .unit => try std.fmt.allocPrint(al, "#{d}", .{pc.id}),
                    .person => try q.personName(al, g, @enumFromInt(pc.id)),
                    .stock => pc.key_buf[0..pc.key_len],
                }}), "choose", "cancel", false),
                .cols = q.company_pick_cols,
                .rows = try q.companyChoices(al, g, switch (pc.what) {
                    .unit => .unit,
                    .person => .person,
                    .stock => .stock,
                }, pc.id),
                .empty = "no company to send to — raise one (Forces +)",
            },
            .pick_hq => |pid| .{
                .title = try listTitle(al, try std.fmt.allocPrint(al, "POST {s} AT", .{try q.personName(al, g, pid)}), "choose", "cancel", false),
                .cols = q.hq_pick_cols,
                .rows = try q.hqChoices(al, g, pid),
                .empty = "no HQ",
            },
            .pick_crew => |uid| .{
                .title = try listTitle(al, try std.fmt.allocPrint(al, "CREW #{d}", .{@intFromEnum(uid)}), "assign", "cancel", false),
                .cols = q.crew_pick_cols,
                .rows = try q.crewChoices(al, g, uid),
                .empty = "nobody of the right role on the books — hire from a hall (HQ screen)",
            },
            .pick_unassign => |uid| .{
                .title = try listTitle(al, try std.fmt.allocPrint(al, "UNASSIGN FROM #{d}", .{@intFromEnum(uid)}), "clear", "cancel", false),
                .cols = q.unassign_pick_cols,
                .rows = try q.unassignChoices(al, g, uid),
                .empty = "nobody is assigned to this hull",
            },
            .pick_part => |pp| .{
                .title = try listTitle(al, switch (pp.purpose) {
                    .order => "ORDER WHICH PART",
                    .ship => "SHIP WHICH PART",
                    .keep => "KEEP WHICH PART STOCKED",
                    .sell => "SELL WHICH PART",
                    .fabricate => "FABRICATE WHICH COMPONENT",
                }, "pick, then the quantity", "cancel", false),
                .cols = q.part_pick_cols,
                .rows = try q.partChoices(al, g, pp.purpose, pp.site),
                .empty = switch (pp.purpose) {
                    .ship, .sell => "nothing on this shelf",
                    else => "nothing in the catalogue",
                },
            },
            else => unreachable,
        };
    }

    fn pickEnter(self: *App) !void {
        const al = self.a();
        const g = self.state();
        const v = try self.pickView(al);
        if (v.rows.len == 0) return;
        const row = v.rows[@min(self.modal_cursor, v.rows.len - 1)];
        const modal = self.modal;
        self.modal = .none;
        switch (modal) {
            .pick_company => |pc| {
                const co: types.ForceId = row.sel.company;
                if (pc.what == .stock) {
                    const pkey = pc.key_buf[0..pc.key_len];
                    const on_hand: i64 = q.stockCount(g, .{ .hq = @enumFromInt(pc.id) }, pkey);
                    self.openAmount(try std.fmt.allocPrint(al, "SHIP {s} TO {s}", .{ pkey, try q.forceName(self.a(), g, co) }), .{ .ship = .{ .from = pc.id, .to = co, .key = pkey } }, &.{
                        .{ .label = "quantity", .value = @min(on_hand, 10), .min = 1, .max = on_hand, .step = 5 },
                    });
                    return;
                }
                if (pc.what == .unit) {
                    const res = self.execResult(.{ .transfer_unit = .{ .unit = @enumFromInt(pc.id), .to_company = co } }) orelse return;
                    self.say(.good, "#{d} sent to {s}{s}", .{ pc.id, try q.forceName(self.a(), g, co), if (res.in_transit) " — in transit" else " — placed" });
                } else {
                    _ = try self.execSay(.{ .transfer_person = .{ .person = @enumFromInt(pc.id), .to_force = co } }, .good, "{s} transferred to {s}", .{ try q.personName(al, g, @enumFromInt(pc.id)), try q.forceName(self.a(), g, co) });
                }
            },
            .pick_hq => |pid| {
                _ = try self.execSay(.{ .post_person = .{ .person = pid, .hq = row.sel.hq } }, .good, "{s} posted to {s}", .{ try q.personName(al, g, pid), try q.hqName(self.a(), g, row.sel.hq) });
            },
            .pick_crew => |uid| {
                _ = try self.execSay(.{ .assign = .{ .unit = uid, .slot = row.slot, .person = row.sel.person } }, .good, "{s} assigned as {s} of #{d}", .{ try q.personName(al, g, row.sel.person), @tagName(row.slot), @intFromEnum(uid) });
            },
            .pick_unassign => |uid| {
                _ = try self.execSay(.{ .unassign = .{ .unit = uid, .slot = row.slot } }, .good, "#{d}: {s} cleared", .{ @intFromEnum(uid), if (row.slot == .any) "pilot and tech" else @tagName(row.slot) });
            },
            .pick_part => |pp| {
                const on_hand: i64 = row.on_hand;
                const key = try al.dupe(u8, row.key);
                switch (pp.purpose) {
                    .order => self.openAmount(try std.fmt.allocPrint(al, "ORDER {s}", .{key}), .{ .order = .{ .site = pp.site, .key = key } }, &.{
                        .{ .label = "quantity", .value = 10, .min = 1, .max = 999, .step = 5 },
                    }),
                    .ship => switch (pp.site) {
                        .hq => |hid| {
                            // Where to: a company row already said; an HQ row asks.
                            if (pp.ship_to) |co| {
                                self.openAmount(try std.fmt.allocPrint(al, "SHIP {s} TO {s}", .{ key, try q.forceName(self.a(), g, co) }), .{ .ship = .{ .from = @intFromEnum(hid), .to = co, .key = key } }, &.{
                                    .{ .label = "quantity", .value = @min(on_hand, 10), .min = 1, .max = on_hand, .step = 5 },
                                });
                            } else {
                                var pc: @TypeOf(self.modal.pick_company) = .{ .what = .stock, .id = @intFromEnum(hid) };
                                const kn = @min(key.len, pc.key_buf.len);
                                @memcpy(pc.key_buf[0..kn], key[0..kn]);
                                pc.key_len = @intCast(kn);
                                self.openModal(.{ .pick_company = pc });
                            }
                        },
                        else => self.say(.amber, "ship from an HQ shelf: put the cursor on an HQ or a company row", .{}),
                    },
                    .keep => switch (pp.site) {
                        .hq => |hid| self.openAmount(try std.fmt.allocPrint(al, "KEEP {s} STOCKED", .{key}), .{ .stock_policy = .{ .hq = @intFromEnum(hid), .key = key } }, &.{
                            .{ .label = "minimum", .value = 5, .min = 0, .max = 999, .step = 1 },
                            .{ .label = "target", .value = 10, .min = 0, .max = 999, .step = 1 },
                        }),
                        else => self.say(.amber, "keep-stocked lines belong to an HQ shelf", .{}),
                    },
                    .sell => switch (pp.site) {
                        .hq => |hid| self.openAmount(try std.fmt.allocPrint(al, "SELL {s}", .{key}), .{ .sell = .{ .hq = @intFromEnum(hid), .key = key } }, &.{
                            .{ .label = "quantity", .value = on_hand, .min = 1, .max = on_hand, .step = 1 },
                        }),
                        else => self.say(.amber, "stock is sold from an HQ shelf", .{}),
                    },
                    .fabricate => switch (pp.site) {
                        .hq => |hid| self.openAmount(try std.fmt.allocPrint(al, "FABRICATE {s}", .{key}), .{ .fabricate = .{ .hq = @intFromEnum(hid), .key = key } }, &.{
                            .{ .label = "quantity", .value = 1, .min = 1, .max = q.fab_max_qty, .step = 1 },
                        }),
                        else => self.say(.amber, "components are fabricated in an HQ bay", .{}),
                    },
                }
            },
            else => unreachable,
        }
    }

    pub fn lanceChoices(self: *App, uid: types.UnitId) ![]q.LanceChoice {
        return q.lanceChoices(self.a(), self.state(), uid);
    }

    /// Return the currently selected HQ's id as a u32.
    /// If no HQ is selected or the selection is stale, fall back to the first HQ.
    /// Revalidated each frame (rule 40).
    pub fn hqSelId(self: *App, g: *GameState) !u32 {
        const hqs = try q.hqList(self.a(), g);
        if (hqs.len == 0) return 0;
        if (self.hq_sel != .none) {
            for (hqs) |row| if (row.id == self.hq_sel) return @intFromEnum(self.hq_sel);
        }
        self.hq_sel = hqs[0].id;
        return @intFromEnum(hqs[0].id);
    }

    pub fn openCommand(self: *App, prefill: []const u8) void {
        self.input.set(prefill);
        self.modal = .{ .input = .command };
    }

    fn endTurnRequest(self: *App, days: u32) !void {
        const al = self.a();
        const g = self.state();
        const view = try q.desk(al, g, 0);
        // Every length of advance asks while a warning prompts.
        if ((try endTurnRows(al, view.checklist)).len > 0) {
            self.end_turn_days = days;
            self.modal = .end_turn;
            return;
        }
        try self.advance(days);
    }

    fn advance(self: *App, days: u32) !void {
        const g = self.state();
        const res = self.execResult(if (days == 1) .advance_day else .{ .advance_days = days }) orelse {
            // A zero-day refusal can be bankruptcy (the outfit entered the turn
            // already bankrupt): save and show the GAME OVER screen.
            try self.handleGameOver();
            return;
        };
        if (res.days_advanced == 0) return; // refused — the message says why
        // A multi-day advance may reach insolvency or bankruptcy after at least
        // one day has committed (C5p).  Bankruptcy gets the save path; insolvent
        // gets the reason sentence.
        if (res.stopped == .bankrupt) {
            try self.handleGameOver();
            return;
        }
        if (res.stopped == .insolvent) {
            const st = try q.status(self.a(), g);
            self.say(.amber, "day {d} · {s} — {s}", .{ st.day, st.date, game.cli.advanceStopText(.insolvent) });
            return;
        }
        const st = try q.status(self.a(), g);
        // A battle stopped the advance short: open what the
        // turn is waiting on rather than make the player go and find it.
        switch (q.turnHold(g)) {
            .after_action => |id| {
                self.say(.crit, "day {d} · {s} — contact: the after-action is on your desk", .{ st.day, st.date });
                self.battles_from_list = false;
                self.openModal(.{ .after_action = id });
                return;
            },
            .decision => |id| {
                self.say(.crit, "day {d} · {s} — a battle decision is waiting on your desk", .{ st.day, st.date });
                self.openModal(.{ .decision = id });
                return;
            },
            .none => {},
        }
        if (res.contact != .none) {
            self.say(.amber, "day {d} · {s} — contact ahead: battle orders", .{ st.day, st.date });
            self.openOrders(res.contact);
            return;
        }
        self.say(.good, "day {d} · {s}", .{ st.day, st.date });
    }

    /// Save the campaign and show GAME OVER (or save-failed) when the outfit
    /// goes bankrupt.  Shared by the zero-day bankrupt error path and the
    /// mid-advance stopped-bankrupt path (C5p).
    fn handleGameOver(self: *App) !void {
        const g = self.state();
        if (!(try q.status(self.a(), g)).bankrupt) return;
        if (self.store.save(&self.session.?, self.player_id)) |_|
            self.modal = .game_over_saved
        else |save_err|
            self.modal = .{ .game_over_failed = game.cli.errorText(save_err) };
    }

    /// Run a command and hand back its result, or report the canonical refusal
    /// sentence (`cli.errorText`, the one sentence per error) and return null.
    pub fn execResult(self: *App, cmd: Command) ?game.commands.Result {
        const g = self.state();
        return game.commands.execute(g, cmd) catch |err| { // direct: the one wrapper
            self.say(.crit, "refused: {s}", .{game.cli.errorText(err)});
            return null;
        };
    }

    pub fn exec(self: *App, cmd: Command) !bool {
        return self.execResult(cmd) != null;
    }

    /// Run a command and report it: the refusal sentence on failure, `fmt`
    /// on success (rule 37: the guard lives here, not at the call sites).
    pub fn execSay(self: *App, cmd: Command, style: Style, comptime fmt: []const u8, args: anytype) !bool {
        if (!try self.exec(cmd)) return false;
        self.say(style, fmt, args);
        return true;
    }

    /// The body, size and command of a confirm dialog.
    fn confirmSpec(self: *App, c: Confirm) !ConfirmSpec {
        const al = self.a();
        const g = self.state();
        switch (c.kind) {
            .fire => {
                const id: types.PersonId = @enumFromInt(c.id);
                const name = try q.personName(al, g, id);
                return .{
                    .title = try confirmTitle(al, "FIRE?", "fire", null, "keep"),
                    .rows = try al.dupe([]const u8, &.{
                        "",
                        try std.fmt.allocPrint(al, "  Fire {{c}}{s}{{/}}? They leave the outfit today; their seat opens.", .{name}),
                        try std.fmt.allocPrint(al, "  Severance owed: {{a}}{d}{{/}} c-bills (half of a month per year served).", .{q.severanceOwed(g, id, true)}),
                        "",
                        try confirmButtons(al, "fire", null, "keep"),
                    }),
                    .w = layout.modal.confirm_w,
                    .h = 8,
                    .cmd = .{ .fire = id },
                    .done = try std.fmt.allocPrint(al, "{s} has left the outfit", .{name}),
                };
            },
            .sell_unit => {
                const uid: types.UnitId = @enumFromInt(c.id);
                // Strip for parts: what the warehouse would get.
                const quote = try q.sellQuote(al, g, uid);
                return .{
                    .title = try confirmTitle(al, "SELL OR STRIP HULL?", "sell", "strip", "keep"),
                    .rows = try al.dupe([]const u8, &.{
                        "",
                        if (quote) |qq| try std.fmt.allocPrint(al, "  Sell {{a}}#{d} {s}{{/}} for {{g}}{s}{{/}} C? Half value scaled by condition; the crew goes to the pool.", .{ c.id, qq.chassis_key, try q.money(al, qq.value) }) else "  no such hull",
                        try std.fmt.allocPrint(al, "  Or strip it for parts into the home warehouse: {{a}}{s}{{/}}", .{if (quote) |qq| qq.strip_text else "nothing worth keeping"}),
                        "",
                        try confirmButtons(al, "sell", "strip", "keep"),
                    }),
                    .w = layout.modal.confirm_wide_w,
                    .h = 8,
                    .cmd = .{ .sell_unit = uid },
                    .done = try std.fmt.allocPrint(al, "hull #{d} sold", .{c.id}),
                    .alt = .{ .cmd = .{ .strip_unit = uid }, .done = try std.fmt.allocPrint(al, "hull #{d} stripped for parts — the Supply screen shows the crates", .{c.id}) },
                };
            },
            .sell_hq => {
                const hid: types.HqId = @enumFromInt(c.id);
                const quote = q.hqSaleQuote(g, hid);
                return .{
                    .title = try confirmTitle(al, "SELL HQ?", "sell", null, "keep"),
                    .rows = try al.dupe([]const u8, &.{
                        "",
                        if (quote) |qq| try std.fmt.allocPrint(al, "  Sell off {{a}}{s}{{/}} for {{g}}{s}{{/}} C ({d}% of build cost + its treasury)?", .{ try q.plain(al, qq.name), try q.money(al, qq.value), q.hq_sale_pct }) else "  no such HQ",
                        "  Staff posted there become unassigned; its stock, board, bay work and links are lost.",
                        "  Companies must be assigned elsewhere first (:assignco co:N hq:M).",
                        "",
                        try confirmButtons(al, "sell", null, "keep"),
                    }),
                    .w = layout.modal.confirm_w,
                    .h = 9,
                    .cmd = .{ .sell_hq = hid },
                    .done = "HQ sold off",
                };
            },
            .disband => {
                const fid: types.ForceId = @enumFromInt(c.id);
                return .{
                    .title = try confirmTitle(al, "DISBAND COMPANY?", "disband", null, "keep"),
                    .rows = try al.dupe([]const u8, &.{
                        "",
                        try std.fmt.allocPrint(al, "  Disband {{a}}{s}{{/}}? Hull sales plus company funds raise about {{g}}{s}{{/}} C and everyone in it is released.", .{ try q.forceName(self.a(), g, fid), try q.money(al, try q.disbandQuote(al, g, fid)) }),
                        "  This cannot be undone.",
                        "",
                        try confirmButtons(al, "disband", null, "keep"),
                    }),
                    .w = layout.modal.confirm_w,
                    .h = 8,
                    .cmd = .{ .disband_company = fid },
                    .done = "company disbanded",
                };
            },
            .recall_breach => {
                const co: types.ForceId = @enumFromInt(c.id);
                return .{
                    .title = try confirmTitle(al, "RECALL UNDER CONTRACT?", "recall", null, "keep"),
                    .rows = try al.dupe([]const u8, &.{
                        "",
                        try std.fmt.allocPrint(al, "  Recall {{a}}{s}{{/}} from its contract? That is a breach: the employer keeps the balance and standing falls.", .{try q.forceName(self.a(), g, co)}),
                        "",
                        try confirmButtons(al, "recall", null, "keep"),
                    }),
                    .w = layout.modal.confirm_w,
                    .h = 7,
                    .cmd = .{ .recall_company = co },
                    .done = try std.fmt.allocPrint(al, "{s} recalled — breach clause applies", .{try q.forceName(self.a(), g, co)}),
                };
            },
        }
    }

    /// Client state a confirmed command invalidates.
    fn afterConfirm(self: *App, c: Confirm) void {
        switch (c.kind) {
            .sell_hq => self.hq_sel = .none,
            .disband => self.cur(0).* = 0,
            else => {},
        }
    }

    // ---- the list widget (rule 36): every "pick one of these" and every
    // read-only sheet is one ListView, drawn by drawList and driven by listKey ----

    const ListView = struct {
        title: []const u8,
        right_title: []const u8 = "",
        /// Fixed rows above the list (a lance strip, an intro line).
        head: []const []const u8 = &.{},
        /// The rows the cursor walks (text)…
        rows: []const []const u8 = &.{},
        /// …or a table the cursor walks, with ←/→ column scroll.
        table: ?Table = null,
        /// Fixed rows under the list.
        foot: []const []const u8 = &.{},
        /// How many rows can be picked; 0 = nothing to pick.
        n: usize = 0,
        /// Rows of `rows` before the first pickable one.
        offset: usize = 0,
        /// A sheet: no cursor, any key closes (←/→ still scroll a table).
        read_only: bool = false,
        /// The cursor is a scroll offset over `rows` (long logs), not a pick.
        scroll: bool = false,
        /// Shown alone when the list is empty.
        empty: []const u8 = "",
        w: u16,
        max_h: u16,
    };

    /// Action key/label table for the person-detail modal.
    /// One source for both the view rows and the listExtra dispatch (rule 20).
    const person_action_keys = [_]struct { action: PersonAction, key: u8, label: []const u8 }{
        .{ .action = .seat, .key = 'a', .label = "seat (assign to an open slot)" },
        .{ .action = .transfer, .key = 'x', .label = "transfer to another company" },
        .{ .action = .post, .key = 'P', .label = "post to an HQ" },
        .{ .action = .train, .key = 't', .label = "train primary skill" },
        .{ .action = .leave, .key = 'L', .label = "send on leave" },
        .{ .action = .triage, .key = 'T', .label = "set triage priority (higher heals first)" },
        .{ .action = .admit, .key = 'm', .label = "admit to the medbay" },
        .{ .action = .fire, .key = 'D', .label = "dismiss (asks first)" },
    };

    /// What the open list modal shows.
    fn listView(self: *App, al: std.mem.Allocator) !ListView {
        const full_h = self.screen.rows -| 2;
        switch (self.modal) {
            .help => {
                // The keys come from the binding tables; these rows explain
                // what the keys are for.
                const concepts_a = [_][]const u8{
                    "  {a}gear{/}        destroyed weapons and equipment are field work on every hull kind (trucks, MASH, tanks, fighters too): spares ordered to the hull's site are fitted by its tech on the weekly pass — no Lab needed",
                    "  {a}structure{/}   not fitted in the Lab: the hull goes to a depot, and the bay consumes comp_* parts from the home HQ",
                    "  {a}companies{/}   a raised company starts empty and walks a wizard: meks per lance from the pool, mothballs and every board (buy or pass; damaged listings show the repair bill and delivery days), the support train, then crews",
                    "               :crew co:N fills open seats from the halls · :manning co:N shows how many of each role a company of that shape needs · :assignco co:N hq:M — each regional HQ hosts one combat company",
                    "  {a}field cash{/}  couriers carry cash out to a company and back; a policy keeps a treasury above a floor, checked daily, capped per month (`:policy co:N 0 0` clears one)",
                    "  {a}resupply{/}    `supplypolicy co:N days [max_tons] [battles]` — every line (provisions, medical, armor, each ammo family) kept to a field plan sized to the transit and the trucks; days = safety days past the transit; 0 days removes",
                    "  {a}trim{/}        trimming a company's stores (`:trim co:N`) returns everything over the field plan — and consumables it has no line for — to the home HQ, free",
                    comptime std.fmt.comptimePrint("  {{a}}sell stock{{/}}  `sellstock hq:N part qty` — {d}% catalogue value ({d}% for comp_*) into the HQ treasury; never under a keep-stocked minimum", .{ q.stock_resale_bp / 100, q.component_resale_bp / 100 }),
                    "  {a}warehouse{/}   `stockpolicy hq:N part min [target]` — under min → order/fabricate to target, daily",
                    "  {a}medbay{/}      Settings: auto-admit the wounded every morning, or `:autoadmit on|off`",
                    "  {a}turn rules{/}  wounded must be admitted and a negative treasury covered before the day can end; bankruptcy ends the game",
                };
                const concepts_b = [_][]const u8{
                    "               difficulty for the readiest company: ● one pip per skull, green easy → amber → red; the number beside it is the exact rating (0.5–5), a range when intel cannot count the enemy, ! outmatched",
                    "               tons your company's mek tonnage · weight mix L light M medium H heavy A assault meks · enemy tons ~ estimated opposing tonnage · opposition lances, quality, faction (≈BV a fight at good intel)",
                };
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                try rows.append(al, "");
                try rows.appendSlice(al, try self.keyHelpRows(al));
                if (self.mode == .game) {
                    try rows.append(al, "");
                    try rows.appendSlice(al, &concepts_a);
                    var bp_lo: [16]u8 = undefined;
                    var bp_hi: [16]u8 = undefined;
                    var bp_bb: [16]u8 = undefined;
                    try rows.append(al, try std.fmt.allocPrint(al, "  {{a}}reputation{{/}}  Dragoons rating letter sets pay (F={s} … A*={s}); letter rises with combat record · complete +1 (+VP) · breach −2 · decisions show their rep effect", .{ types.bpText(&bp_lo, q.rating_pay_lo_bp), types.bpText(&bp_hi, q.rating_pay_hi_bp) }));
                    try rows.append(al, try std.fmt.allocPrint(al, "  {{a}}board cols{{/}}  emp employer · LY light-years off · band in ring / beachhead (pay {s}, hardship, slow resupply) · mo months · salv salvage % (cash = salvage exchange: paid in cash, no wrecks) · rights command rights · transit days out", .{types.bpText(&bp_bb, q.beachhead_pay_bp)}));
                    try rows.appendSlice(al, &concepts_b);
                    try rows.append(al, try std.fmt.allocPrint(al, "               factions {s}", .{try q.factionLegend(al)}));
                }
                const hint = try std.fmt.allocPrint(al, "  {{d}}{s} · {s} · {s} · {s}{{/}}", .{
                    try keyHint(ListAction, al, &list_bindings, .down, "scroll"),
                    try keyHint(ListAction, al, &list_bindings, .page_down, "page"),
                    try keyHint(ListAction, al, &list_bindings, .close, "close"),
                    try keyHint(HelpAction, al, &help_bindings, .close, "close"),
                });
                return .{ .title = "HELP", .rows = rows.items, .foot = try al.dupe([]const u8, &.{hint}), .scroll = true, .w = layout.modal.help_w, .max_h = full_h };
            },
            .decision => |idx| {
                const view = try q.desk(al, self.state(), 0);
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                var found = false;
                for (view.inbox) |it| {
                    if (it.event_id != idx) continue;
                    found = true;
                    try rows.append(al, "");
                    try rows.append(al, try std.fmt.allocPrint(al, "  {{a}}{s}{{/}} · {s} · defaults on day {d} ({d} days)", .{ it.kind, it.company, it.deadline_day, it.days_left }));
                    try rows.append(al, "");
                    try rows.append(al, try std.fmt.allocPrint(al, "  {s}", .{it.description}));
                    try rows.append(al, "");
                    // What the decision is actually about, when one line
                    // cannot carry it (the wrecks on offer).
                    if (it.detail.len > 0) {
                        try rows.appendSlice(al, it.detail);
                        try rows.append(al, "");
                    }
                    for (it.options, 0..) |o, oi| {
                        try rows.append(al, try std.fmt.allocPrint(al, "    [{d}] {s}{s}", .{ oi + 1, o, if (oi == it.default_choice) "   {d}default{/}" else "" }));
                    }
                    try rows.append(al, "");
                    try rows.append(al, try std.fmt.allocPrint(al, "  {{d}}{s} · {s}{{/}}", .{ try keyHint(DecisionAction, al, &decision_bindings, .choose, "choose that option"), try keyHint(SheetAction, al, &sheet_bindings, .close, "decide later") }));
                }
                if (!found) try rows.append(al, "  {d}this decision has been resolved{/}");
                return .{ .title = try keys.title(al, try listTitle(al, "DECISION", null, "later", false), &decision_legend), .rows = rows.items, .read_only = true, .w = layout.modal.decision_w, .max_h = layout.modal.decision_max_h };
            },
            .raise_hulls => {
                const g = self.state();
                const lances = try self.raiseLances();
                clampIdx(&self.raise.lance_idx, lances.len);
                const cands = try q.raiseCandidates(al, g, self.raise.company, self.raise.passed[0..self.raise.passed_len]);
                var lance_line: std.ArrayListUnmanaged(u8) = .empty;
                for (lances, 0..) |l, i| {
                    try lance_line.appendSlice(al, try std.fmt.allocPrint(al, "{s}{s} {d}/{d}{s}  ", .{ if (i == self.raise.lance_idx) "{a}▶ " else "{d}", try l.name.markup(al), l.used, l.cap, "{/}" }));
                }
                return .{
                    .title = try listTitleWith(al, try std.fmt.allocPrint(al, "RAISE {s} · HULLS", .{try q.forceName(self.a(), g, self.raise.company)}), &raise_hulls_legend, "take or buy", "leave (the company keeps what it has)", true),
                    .head = try al.dupe([]const u8, &.{ lance_line.items, "" }),
                    .table = try q.tableOf(al, q.raise_cols, cands),
                    .n = cands.len,
                    .empty = "{d}nothing left to pick — no loose meks and no mek listings on any board (boards refresh on the 1st){/}",
                    .w = layout.modal.raise_hulls_w,
                    .max_h = full_h,
                };
            },
            .raise_support => {
                const g = self.state();
                const train = try q.supportTrain(al, g, self.raise.company);
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                for (train.lines) |line| try rows.append(al, line.text);
                return .{
                    .title = try listTitleWith(al, try std.fmt.allocPrint(al, "RAISE {s} · SUPPORT TRAIN", .{try q.forceName(self.a(), g, self.raise.company)}), &raise_support_legend, "buy one", "leave", false),
                    .head = &.{"hull      name                  owned   price (staple line at home)   what it does"},
                    .rows = rows.items,
                    .n = train.lines.len,
                    .foot = try al.dupe([]const u8, &.{ "", try std.fmt.allocPrint(al, "field capacity {d}t  ·  a generated company carries 4 of each", .{train.capacity_tons}) }),
                    .w = layout.modal.raise_support_w,
                    .max_h = full_h,
                };
            },
            .music => {
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                if (self.music) |*m| {
                    // Row 0: the mix; rows 1..sets: one soundtrack each; then the tracks of the selection.
                    try rows.append(al, try std.fmt.allocPrint(al, "{s}{s} all soundtracks, mixed and shuffled{{/}}   {{d}}{d} tracks{{/}}", .{ if (m.selected_set == null) "{a}" else "", if (m.selected_set == null) ">" else " ", m.tracks.len }));
                    for (m.sets, 0..) |name, i| {
                        const sel = m.selected_set != null and m.selected_set.? == i;
                        const esc_name = try q.plain(al, name);
                        try rows.append(al, try std.fmt.allocPrint(al, "{s}{s} {s: <28}{{/}}   {{d}}{d} tracks · {s}/{s}{{/}}", .{ if (sel) "{a}" else "", if (sel) ">" else " ", esc_name, m.setCount(i), m.root, if (std.mem.eql(u8, name, "default")) "" else esc_name }));
                    }
                    try rows.append(al, "");
                    try rows.append(al, try std.fmt.allocPrint(al, "{{d}}playing {s} · {s} · volume {d}{{/}}", .{ try q.plain(al, m.setName(m.selected_set)), if (m.enabled) "on" else "off", m.volume }));
                    for (m.order) |ti| {
                        const t = m.tracks[ti];
                        const now = m.current != null and m.current.? == ti and m.child != null;
                        try rows.append(al, try std.fmt.allocPrint(al, "  {s}{s} {s: <40} {s}{{/}}", .{ if (now) "{g}" else "", if (now) "♪" else " ", try q.plain(al, t.name), try q.plain(al, m.sets[t.set]) }));
                    }
                    try rows.append(al, "");
                    try rows.append(al, try std.fmt.allocPrint(al, "  {{d}}{s}: a soundtrack selects it (the playlist reshuffles), a track plays it · {s}{{/}}", .{ try keyHint(ListAction, al, &list_bindings, .pick, "on a row"), try keys.title(al, "", &music_legend) }));
                } else {
                    try rows.append(al, "");
                    try rows.append(al, try std.fmt.allocPrint(al, "  {{d}}{s}{{/}}", .{self.music_note}));
                    try rows.append(al, "");
                    try rows.append(al, try std.fmt.allocPrint(al, "  {{d}}{s}{{/}}", .{try keyHint(ListAction, al, &list_bindings, .close, "close")}));
                }
                return .{ .title = try listTitleWith(al, "SOUNDTRACK", &music_legend, "select / play", "close", false), .rows = rows.items, .n = if (self.music != null) rows.items.len else 0, .w = layout.modal.music_w, .max_h = full_h };
            },
            .summary => return .{ .title = "CAMPAIGN SUMMARY", .right_title = "any key closes · also :summary", .rows = try q.summary(al, self.state()), .read_only = true, .w = layout.modal.summary_w, .max_h = full_h },
            .readiness => {
                const g = self.state();
                const rr = try q.readiness(al, g);
                return .{
                    .title = "READINESS · every company",
                    .right_title = try keys.title(al, "", &sheet_legend),
                    .table = try q.tableOf(al, q.readiness_cols, rr),
                    .empty = "{d}no companies{/}",
                    .foot = &.{ "", "{d}fatigue falls only at a regional HQ; banked XP becomes skill at a training ground; depot hulls wait on a mek bay · Forces r shows one company in detail{/}" },
                    .read_only = true,
                    .w = layout.modal.readiness_w,
                    .max_h = full_h,
                };
            },
            .raise_crews => {
                const g = self.state();
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                const mq = try q.manning(al, g, self.raise.company);
                for (try (try q.tableOf(al, q.manning_cols, mq)).render(al), 0..) |ln, i| try rows.append(al, if (i == 0) try std.fmt.allocPrint(al, "{{d}}{s}{{/}}", .{ln}) else ln);
                var open_total: u32 = 0;
                for (mq) |m| open_total += m.open;
                try rows.append(al, "");
                try rows.append(al, try std.fmt.allocPrint(al, "{d} open · the counts match a generated starter company of this shape", .{open_total}));
                try rows.append(al, try std.fmt.allocPrint(al, "  {{a}}{s}{{/}} now: a pilot per crewless hull and a tech where none has hours (signing bonuses from the outfit)", .{try keyHint(RaiseCrewsAction, al, &raise_crews_bindings, .crew, "hire from the halls")}));
                try rows.append(al, "  {d}or hire by hand later from an HQ's hiring hall or the People screen · this table is also :manning co:N{/}");
                try rows.append(al, try std.fmt.allocPrint(al, "  {{a}}{s}{{/}}", .{try keyHint(SheetAction, al, &sheet_bindings, .close, "finish")}));
                return .{ .title = try std.fmt.allocPrint(al, "RAISE {s} · CREWS", .{try q.forceName(self.a(), g, self.raise.company)}), .rows = rows.items, .read_only = true, .w = layout.modal.raise_crews_w, .max_h = full_h };
            },
            .negotiate => |idx| {
                var head: std.ArrayListUnmanaged([]const u8) = .empty;
                if (try q.offerTerms(al, self.state(), idx)) |terms_line| {
                    try head.append(al, try std.fmt.allocPrint(al, "  {s}", .{terms_line}));
                    try head.append(al, "  {d}one round: 2d6 + reputation + your command office vs a target eased by standing with the employer · a miss shaves the pay 5% · a natural 2 and they walk{/}");
                    try head.append(al, "");
                }
                return .{
                    .title = try listTitle(al, "NEGOTIATE", "press the term", "cancel", false),
                    .right_title = ":negotiate <offer#> <term>",
                    .head = head.items,
                    .rows = &negotiable_terms,
                    .n = negotiable_terms.len,
                    .w = layout.modal.negotiate_w,
                    .max_h = full_h,
                };
            },
            .pick_company, .pick_hq, .pick_crew, .pick_unassign, .pick_part => {
                const v = try self.pickView(al);
                return .{ .title = v.title, .right_title = "best first · dimmed rows say why not", .table = try q.tableOf(al, v.cols, v.rows), .n = v.rows.len, .empty = try std.fmt.allocPrint(al, "{{d}}{s}{{/}}", .{v.empty}), .w = layout.modal.picker_w, .max_h = full_h };
            },
            .accept_pick => |oi| {
                const cands = try q.offerCandidates(al, self.state(), oi);
                return .{ .title = try listTitle(al, "SEND WHICH COMPANY", "choose", "cancel", true), .right_title = "readiest first", .table = try q.tableOf(al, q.candidates_cols, cands), .n = cands.len, .empty = "{d}no companies to send{/}", .w = layout.modal.accept_pick_w, .max_h = full_h };
            },
            .lance_pick => |uid| {
                const lances = try self.lanceChoices(uid);
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                for (lances) |lc| try rows.append(al, lc.text);
                return .{ .title = try listTitle(al, try std.fmt.allocPrint(al, "MOVE #{d} TO", .{@intFromEnum(uid)}), "choose", "cancel", false), .right_title = ":newlance co:N <name> adds a lance", .rows = rows.items, .n = lances.len, .empty = "{d}no lances — the hull must belong to a company that is home{/}", .w = layout.modal.lance_pick_w, .max_h = full_h };
            },
            .upgrade => |hid| {
                const rows_v = try q.upgrades(al, self.state(), hid);
                return .{
                    .title = try listTitle(al, try std.fmt.allocPrint(al, "UPGRADE · {s}", .{try q.hqName(self.a(), self.state(), hid)}), "start", "cancel", true),
                    .right_title = "one project per facility at a time",
                    .table = try q.tableOf(al, q.upgrade_cols, rows_v),
                    .n = rows_v.len,
                    .empty = "{d}nothing to upgrade{/}",
                    .foot = try al.dupe([]const u8, &.{
                        "",
                        try std.fmt.allocPrint(al, "{{d}}paid from the HQ treasury ({s} C) when the project starts · paperwork: {d}d base, −{d}d per command-admin level, floor {d}d{{/}}", .{ try q.money(al, q.balance(self.state(), .{ .hq = hid })), q.paperwork_base_days, q.paperwork_days_per_admin_level, q.paperwork_min_days }),
                        "{d}every level raises the staff the HQ must keep on payroll; understaffed HQs run a level lower{/}",
                    }),
                    .w = layout.modal.upgrade_w,
                    .max_h = full_h,
                };
            },
            .install_part => |uid| {
                const cands = try q.installCandidates(al, self.state(), uid);
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                for (cands) |c| try rows.append(al, c.text);
                return .{ .title = try listTitle(al, "INSTALL · pick a part", "choose location", "cancel", false), .right_title = "stock at the home HQ first", .rows = rows.items, .n = cands.len, .empty = "{d}nothing in stock to install{/}", .w = layout.modal.install_part_w, .max_h = full_h };
            },
            .install_loc => |il| {
                const locs = try q.installLocations(al, self.state(), il.unit, il.part);
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                for (locs) |l| try rows.append(al, l.text);
                return .{ .title = try listTitle(al, "INSTALL · pick a location", "stage", "cancel", false), .head = try al.dupe([]const u8, &.{ try std.fmt.allocPrint(al, "  {{a}}{s}{{/}} — where does it go?", .{il.part}), "" }), .rows = rows.items, .n = locs.len, .empty = "{d}no location takes it{/}", .w = layout.modal.install_loc_w, .max_h = full_h };
            },
            .install_at => |ia| {
                const cands = try q.partsFittingLocation(al, self.state(), ia.unit, ia.location);
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                for (cands) |c| try rows.append(al, c.text);
                return .{ .title = try listTitle(al, try std.fmt.allocPrint(al, "INSTALL · {s} · pick a part", .{@tagName(ia.location)}), "stage", "cancel", false), .right_title = "parts that fit this location", .rows = rows.items, .n = cands.len, .empty = "{d}nothing fits this location{/}", .w = layout.modal.install_part_w, .max_h = full_h };
            },
            .seat => |id| {
                const seats = try q.openSeats(al, self.state(), id);
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                for (seats) |st| try rows.append(al, st.text);
                return .{ .title = try listTitle(al, try std.fmt.allocPrint(al, "ASSIGN {s}", .{try q.personName(al, self.state(), id)}), "take seat", "cancel", false), .right_title = "open seats for their role", .rows = rows.items, .n = seats.len, .empty = "{d}no open seat for this role{/}", .w = layout.modal.seat_w, .max_h = layout.modal.seat_max_h };
            },
            .emblem => {
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                for (emblems) |e| try rows.append(al, try std.fmt.allocPrint(al, "preset   {s}", .{e.name}));
                for (self.logos) |l| try rows.append(al, try std.fmt.allocPrint(al, "picture  {s}", .{l}));
                try rows.append(al, "editor   {a}draw your own{/} — a 3 × 8 text crest, cell by cell");
                return .{ .title = try listTitle(al, "EMBLEM", "use", "cancel", false), .right_title = try std.fmt.allocPrint(al, "pictures from {s}", .{try std.mem.join(al, ", ", self.asset_roots.logos)}), .rows = rows.items, .n = rows.items.len, .w = layout.modal.emblem_w, .max_h = layout.modal.emblem_max_h };
            },
            .hull => |uid| return .{ .title = try listTitle(al, "HULL", null, "close", false), .rows = try q.hull(al, self.state(), uid), .read_only = true, .w = layout.modal.hull_w, .max_h = full_h },
            .record => |pid| {
                const g = self.state();
                const pa = try q.personActions(al, g, pid);
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                try rows.appendSlice(al, try q.personRecord(al, g, pid));
                try rows.append(al, "");
                try rows.append(al, "{a}ACTIONS{/}");
                for (person_action_keys) |entry| {
                    const eligible = switch (entry.action) {
                        .seat => pa.can_seat,
                        .transfer => pa.can_transfer,
                        .post => pa.can_post,
                        .train => pa.can_train,
                        .leave => pa.can_leave,
                        .triage => pa.can_triage,
                        .admit => pa.can_admit,
                        .fire => pa.can_fire,
                    };
                    if (!eligible) continue;
                    const suffix = if (entry.action == .leave and pa.restless) " {a}← resolves restless{/}" else "";
                    try rows.append(al, try std.fmt.allocPrint(al, "  [{c}] {s}{s}", .{ entry.key, entry.label, suffix }));
                }
                const head: []const []const u8 = if (pa.restless) try al.dupe([]const u8, &.{
                    "{c}RESTLESS{/} — rolls to quit on payday: grant leave, rotate home, feed and rest",
                    "",
                }) else &.{};
                return .{
                    .title = try listTitle(al, "RECORD", null, "close", false),
                    .head = head,
                    .rows = rows.items,
                    .scroll = true,
                    .w = layout.modal.record_w,
                    .max_h = full_h,
                };
            },
            .battle_list => {
                const rows = try q.battleList(al, self.state());
                return .{
                    .title = try listTitle(al, "AFTER-ACTION REPORTS", "read", "close", false),
                    .right_title = "newest first",
                    .table = try q.tableOf(al, q.battle_cols, rows),
                    .n = rows.len,
                    .empty = "{d}no engagements on record yet — take a combat contract{/}",
                    .w = layout.modal.battle_list_w,
                    .max_h = full_h,
                };
            },
            .leaderboard => {
                const rows = try q.leaderboard(al, self.state());
                return .{
                    .title = try listTitle(al, "MERC COMPANIES", "read", "close", false),
                    .right_title = "most funds first",
                    .table = try q.tableOf(al, q.leaderboard_cols, rows),
                    .n = rows.len,
                    .empty = "{d}no merc companies on record yet{/}",
                    .w = layout.modal.battle_list_w,
                    .max_h = full_h,
                };
            },
            .leaderboard_detail => |id| {
                const rows = try q.mercCompanyDetail(al, self.state(), id);
                return .{
                    .title = try listTitle(al, "MERC COMPANY", null, "close", false),
                    .rows = rows,
                    .scroll = true,
                    .read_only = true,
                    .w = layout.modal.battle_list_w,
                    .max_h = full_h,
                };
            },
            .log_entry => |idx| {
                const view = try q.desk(al, self.state(), q.desk_log_rows);
                const w = layout.modal.log_entry_w;
                const rows = if (view.log.len == 0) &[_][]const u8{"{d}nothing logged yet{/}"} else try screen_mod.wrap(al, view.log[@min(idx, view.log.len - 1)], self.modalTextWidth(w));
                return .{ .title = "LOG ENTRY · any key closes", .rows = rows, .read_only = true, .w = w, .max_h = full_h };
            },
            .contract_log => |cid| {
                const all = try q.battleLog(al, self.state(), cid, std.math.maxInt(usize));
                // battleLog is newest first; read it top-down like a diary.
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                var i: usize = all.len;
                while (i > 0) : (i -= 1) try rows.append(al, all[i - 1]);
                if (rows.items.len == 0) try rows.append(al, "{d}nothing logged for this contract yet{/}");
                return .{
                    .title = try listTitleWith(al, try std.fmt.allocPrint(al, "CONTRACT [{d}] LOG", .{@intFromEnum(cid)}), &log_legend, null, "close", false),
                    .right_title = try std.fmt.allocPrint(al, "{d} lines · oldest first", .{rows.items.len}),
                    .rows = rows.items,
                    .scroll = true,
                    .w = self.screen.cols,
                    .max_h = full_h,
                };
            },
            .operation_pick => |cid| {
                const ops = try q.contractOperations(al, self.state(), cid);
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                for (ops.rows) |r| {
                    const state_tag = @tagName(r.state);
                    const combat_tag: []const u8 = if (r.combat) "combat" else "non-combat";
                    const intel_note: []const u8 = if (r.intel.confidence > 0)
                        try std.fmt.allocPrint(al, "  intel:{d}/10", .{r.intel.confidence})
                    else
                        "";
                    try rows.append(al, try std.fmt.allocPrint(al, "{s}  {s}  {s}  {d}d  {s}  tempo:{s}{s}", .{ r.name, r.objective, combat_tag, r.expected_days, state_tag, r.tempo.label(), intel_note }));
                }
                const hint: []const u8 = if (ops.briefing.len > 0) blk: {
                    const esc_note: []const u8 = if (ops.collapse_threshold > 0)
                        try std.fmt.allocPrint(al, "  esc:{d}/{d}", .{ ops.escalation_clock, ops.collapse_threshold })
                    else
                        try std.fmt.allocPrint(al, "  esc:{d}", .{ops.escalation_clock});
                    break :blk try std.fmt.allocPrint(al, "{s}{s}", .{ ops.briefing, esc_note });
                } else "(no arc)";
                // Build a read-only actors block (P4i): one line per attached actor.
                var head_lines: std.ArrayListUnmanaged([]const u8) = .empty;
                try head_lines.append(al, hint);
                if (ops.actors.len > 0) {
                    try head_lines.append(al, "");
                    for (ops.actors) |ar| {
                        const name_text = try ar.name.markup(al);
                        const cause_text = if (ar.last_cause.raw.len > 0) try ar.last_cause.markup(al) else @as([]const u8, "");
                        const recurring_tag: []const u8 = if (ar.recurring) " {a}(returning){/}" else "";
                        const cause_note: []const u8 = if (cause_text.len > 0)
                            try std.fmt.allocPrint(al, "  last:{s}", .{cause_text})
                        else
                            "";
                        try head_lines.append(al, try std.fmt.allocPrint(al, "{s}  [{s}] {s}  tr:{d} dt:{d} re:{d} ho:{d}{s}{s}", .{
                            name_text,    ar.archetype, ar.agenda,
                            ar.trust,     ar.debt,      ar.respect,
                            ar.hostility, cause_note,   recurring_tag,
                        }));
                    }
                }
                if (ops.rivals.len > 0) {
                    try head_lines.append(al, "");
                    for (ops.rivals) |rr| {
                        const unit_text = try rr.unit_name.markup(al);
                        const cause_text = if (rr.last_cause.raw.len > 0) try rr.last_cause.markup(al) else @as([]const u8, "");
                        const recurring_tag: []const u8 = if (rr.recurring) " {a}(returning){/}" else "";
                        const insolvent_tag: []const u8 = if (rr.insolvent) " {c}(insolvent){/}" else "";
                        const cause_note: []const u8 = if (cause_text.len > 0)
                            try std.fmt.allocPrint(al, "  last:{s}", .{cause_text})
                        else
                            "";
                        try head_lines.append(al, try std.fmt.allocPrint(al, "{s}  [{s}] {s}  standing:{d}  {s}{s}{s}{s}", .{
                            unit_text,     rr.doctrine,    rr.status,
                            rr.standing,   rr.faction_key, cause_note,
                            recurring_tag, insolvent_tag,
                        }));
                    }
                }
                if (ops.officers.len > 0) {
                    try head_lines.append(al, "");
                    for (ops.officers) |or_row| {
                        const name_text = try or_row.name.markup(al);
                        const recurring_tag: []const u8 = if (or_row.recurring) " {a}(returning){/}" else "";
                        try head_lines.append(al, try std.fmt.allocPrint(al, "{s}  [{s}] {s}  perf:{d} ({s}){s}", .{
                            name_text,
                            or_row.seat,
                            or_row.rank,
                            or_row.performance,
                            or_row.band,
                            recurring_tag,
                        }));
                    }
                }
                if (ops.world_state_summary.len > 0) {
                    try head_lines.append(al, "");
                    try head_lines.append(al, try std.fmt.allocPrint(al, "{{d}}world{{/}}  {s}", .{ops.world_state_summary}));
                }
                try head_lines.append(al, "");
                return .{
                    .title = try listTitle(al, try std.fmt.allocPrint(al, "OPERATIONS · [{d}]", .{@intFromEnum(cid)}), "Enter pick intent · r tempo · x decline · w withdraw · e exploit · o consolidate", "cancel", false),
                    .head = head_lines.items,
                    .rows = rows.items,
                    .n = ops.rows.len,
                    .empty = "{d}no operations on this contract{/}",
                    .w = layout.modal.picker_w,
                    .max_h = full_h,
                };
            },
            .intent_pick => |ip| {
                const choices = try q.intentChoices(al, self.state(), ip.contract, ip.operation);
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                for (choices) |intent| {
                    try rows.append(al, try std.fmt.allocPrint(al, "{s}", .{intent.label()}));
                }
                return .{
                    .title = try listTitle(al, "MISSION INTENT", "Enter commit", "cancel", false),
                    .head = try al.dupe([]const u8, &.{ "choose the commander's intent for this operation", "" }),
                    .rows = rows.items,
                    .n = choices.len,
                    .empty = "{d}no intents available{/}",
                    .w = layout.modal.picker_w,
                    .max_h = full_h,
                };
            },
            .task_pick => |tp| {
                // List the company's eligible lances with their current task.
                const gs = self.state();
                const ops = try q.contractOperations(al, gs, tp.contract);
                var op_row: ?q.OperationRow = null;
                for (ops.rows) |row| if (row.id == tp.operation) {
                    op_row = row;
                    break;
                };
                const op = op_row orelse return .{
                    .title = try listTitle(al, "LANCE TASKS", "Enter set", "cancel", false),
                    .head = try al.dupe([]const u8, &.{"operation not found"}),
                    .rows = &.{},
                    .n = 0,
                    .empty = "{d}no lances{/}",
                    .w = layout.modal.picker_w,
                    .max_h = full_h,
                };
                const c = gs.contracts.getPtr(tp.contract) orelse return .{
                    .title = try listTitle(al, "LANCE TASKS", "Enter set", "cancel", false),
                    .head = &.{},
                    .rows = &.{},
                    .n = 0,
                    .empty = "{d}no contract{/}",
                    .w = layout.modal.picker_w,
                    .max_h = full_h,
                };
                const lance_ids = try q.combatLances(al, gs, c.assigned_company);
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                for (lance_ids) |child_id| {
                    const lance_name = try q.forceName(al, gs, child_id);
                    var task_label: []const u8 = "none";
                    for (op.tasks) |lt| if (lt.lance == child_id) {
                        task_label = lt.task.label();
                        break;
                    };
                    try rows.append(al, try std.fmt.allocPrint(al, "{s}  [{s}]", .{ lance_name, task_label }));
                }
                return .{
                    .title = try listTitle(al, "LANCE TASKS", "Enter cycle", "cancel", false),
                    .head = try al.dupe([]const u8, &.{
                        try std.fmt.allocPrint(al, "operation: {s} | {d} legal tasks", .{ op.name, op.legal_tasks.len }),
                        "Enter cycles the task; x clears",
                    }),
                    .rows = rows.items,
                    .n = rows.items.len,
                    .empty = "{d}no eligible lances{/}",
                    .w = layout.modal.picker_w,
                    .max_h = full_h,
                };
            },
            .tempo_pick => |tp| {
                const choices = try q.tempoChoices(al, self.state(), tp.contract, tp.operation);
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                for (choices) |posture| {
                    try rows.append(al, try std.fmt.allocPrint(al, "{s}", .{posture.label()}));
                }
                return .{
                    .title = try listTitle(al, "TEMPO POSTURE", "Enter set", "cancel", false),
                    .head = try al.dupe([]const u8, &.{ "set the operation's tactical tempo posture", "" }),
                    .rows = rows.items,
                    .n = choices.len,
                    .empty = "{d}no postures available{/}",
                    .w = layout.modal.picker_w,
                    .max_h = full_h,
                };
            },
            .intervention_pick => |ip| {
                const gs = self.state();
                const ops = try q.contractOperations(al, gs, ip.contract);
                var op_row: ?q.OperationRow = null;
                for (ops.rows) |row| if (row.id == ip.operation) {
                    op_row = row;
                    break;
                };
                const op = op_row orelse return .{
                    .title = try listTitle(al, "COMMAND INTERVENTION", "Enter apply", "cancel", false),
                    .head = try al.dupe([]const u8, &.{"operation not found"}),
                    .rows = &.{},
                    .n = 0,
                    .empty = "{d}no interventions available{/}",
                    .w = layout.modal.picker_w,
                    .max_h = full_h,
                };
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                for (op.affordable_interventions) |iv| {
                    try rows.append(al, try std.fmt.allocPrint(al, "{s}  (cost: {d})", .{ iv.label(), operations_mod.interventionCost(iv) }));
                }
                const cap_line = try std.fmt.allocPrint(al, "command capacity: {d} / {d} (reserved: {d})", .{ op.command_capacity, op.command_capacity_cap, op.command_capacity_reserved });
                return .{
                    .title = try listTitle(al, "COMMAND INTERVENTION", "Enter apply", "cancel", false),
                    .head = try al.dupe([]const u8, &.{ cap_line, "" }),
                    .rows = rows.items,
                    .n = op.affordable_interventions.len,
                    .empty = "{d}no interventions available{/}",
                    .w = layout.modal.picker_w,
                    .max_h = full_h,
                };
            },
            .operation_report => |cid| {
                const rpt = try q.operationReport(al, self.state(), cid);
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                for (rpt.rows) |r| {
                    const combat_tag: []const u8 = if (r.combat) "{c}combat{/}" else "{d}non-combat{/}";
                    const outcome_tag: []const u8 = if (r.outcome != .none)
                        @tagName(r.outcome)
                    else
                        "-";
                    const succeeded_tag: []const u8 = if (r.succeeded) |s| (if (s) " {g}ok{/}" else " {d}miss{/}") else "";
                    try rows.append(al, try std.fmt.allocPrint(al, "{s}  {s}  {s}  {s}{s}  intent:{s}  tempo:{s}  Δclk:{d}", .{
                        r.name,
                        combat_tag,
                        @tagName(r.state),
                        outcome_tag,
                        succeeded_tag,
                        r.intent.label(),
                        r.tempo.label(),
                        r.consequence.clock_delta,
                    }));
                    // Decision costs line.
                    var iv_buf: std.ArrayListUnmanaged(u8) = .empty;
                    for (r.interventions, 0..) |iv, i| {
                        if (i > 0) try iv_buf.appendSlice(al, ", ");
                        try iv_buf.appendSlice(al, @tagName(iv));
                    }
                    const iv_text: []const u8 = if (iv_buf.items.len > 0) iv_buf.items else "-";
                    try rows.append(al, try std.fmt.allocPrint(al, "   {{d}}cost: cap {d} ({s}) · delay {d}d{{/}}", .{
                        r.capacity_spent,
                        iv_text,
                        r.delay_days,
                    }));
                    // Campaign-state consequence detail for non-combat resolved ops.
                    if (r.consequence.applies_campaign_deltas) {
                        const wd = r.consequence.world_delta;
                        const rd = r.consequence.relationship_delta;
                        try rows.append(al, try std.fmt.allocPrint(al, "   {{d}}world sec{d} civ{d} infra{d} ctrl{d} enemy{d} · rel tr{d}/re{d}/de{d}/ho{d} ×{d} · rival{d}×{d} · officer{d}×{d}{{/}}", .{
                            wd.security,
                            wd.civilian_support,
                            wd.infrastructure_strain,
                            wd.employer_control,
                            wd.enemy_influence,
                            rd.trust,
                            rd.respect,
                            rd.debt,
                            rd.hostility,
                            r.consequence.actors_affected,
                            r.consequence.rival_standing_delta,
                            r.consequence.rivals_affected,
                            r.consequence.officer_delta,
                            r.consequence.officers_affected,
                        }));
                    }
                }
                // Summary head.
                const esc_note: []const u8 = if (rpt.collapse_threshold > 0)
                    try std.fmt.allocPrint(al, "esc:{d}/{d}", .{ rpt.escalation_clock, rpt.collapse_threshold })
                else
                    try std.fmt.allocPrint(al, "esc:{d}", .{rpt.escalation_clock});
                const cap_available = rpt.command_capacity -| rpt.command_capacity_reserved;
                var head_lines: std.ArrayListUnmanaged([]const u8) = .empty;
                if (rpt.briefing.len > 0) {
                    try head_lines.append(al, try std.fmt.allocPrint(al, "{s}  {s}", .{ rpt.briefing, esc_note }));
                } else {
                    try head_lines.append(al, esc_note);
                }
                try head_lines.append(al, try std.fmt.allocPrint(al, "capacity {d}/{d} (reserved {d})  score {d} · VP {d}", .{
                    cap_available,
                    rpt.command_capacity_cap,
                    rpt.command_capacity_reserved,
                    rpt.contract_score,
                    rpt.victory_points,
                }));
                if (rpt.world_state_summary.len > 0) {
                    try head_lines.append(al, try std.fmt.allocPrint(al, "{{d}}world{{/}}  {s}", .{rpt.world_state_summary}));
                }
                try head_lines.append(al, "");
                return .{
                    .title = try listTitle(al, try std.fmt.allocPrint(al, "OPERATION REPORT · [{d}]", .{@intFromEnum(cid)}), null, "cancel", false),
                    .head = head_lines.items,
                    .rows = rows.items,
                    .read_only = true,
                    .w = layout.modal.picker_w,
                    .max_h = full_h,
                    .empty = "{d}no decided operations yet{/}",
                };
            },
            .mech => |m| {
                var rows: std.ArrayListUnmanaged([]const u8) = .empty;
                switch (m.view) {
                    .summary => {
                        const lines = try q.hullRecord(al, self.state(), m.id);
                        try rows.appendSlice(al, lines);
                        if (lines.len > 0) {
                            try rows.append(al, "");
                            try rows.append(al, "  sub-views:");
                            for (mech_view_keys) |mk| {
                                try rows.append(al, try std.fmt.allocPrint(al, "  [{c}] {s}", .{ mk.key, mk.label }));
                            }
                        }
                    },
                    .combat => {
                        const lines = try q.hullCombatHistory(al, self.state(), m.id);
                        if (lines.len == 0) {
                            try rows.append(al, "{d}no combat records{/}");
                        } else {
                            try rows.appendSlice(al, lines);
                        }
                    },
                    .maintenance => {
                        const lines = try q.hullMaintenanceLog(al, self.state(), m.id);
                        if (lines.len == 0) {
                            try rows.append(al, "{d}no maintenance entries{/}");
                        } else {
                            try rows.appendSlice(al, lines);
                        }
                    },
                    .ownership => {
                        const lines = try q.hullOwnershipChain(al, self.state(), m.id);
                        if (lines.len == 0) {
                            try rows.append(al, "{d}no ownership records{/}");
                        } else {
                            try rows.appendSlice(al, lines);
                        }
                    },
                }
                const sub: []const u8 = switch (m.view) {
                    .summary => "MECH",
                    .combat => "MECH \xc2\xb7 COMBAT",
                    .maintenance => "MECH \xc2\xb7 MAINTENANCE",
                    .ownership => "MECH \xc2\xb7 OWNERSHIP",
                };
                return .{
                    .title = try listTitle(al, sub, null, "close", false),
                    .rows = rows.items,
                    .read_only = true,
                    .scroll = true,
                    .w = layout.modal.hull_w,
                    .max_h = full_h,
                };
            },
            else => unreachable,
        }
    }

    // advance/salvage/transport steps source from board-roll pip constants (contract_market.zig); re-source from contract.zig:181-206 named literals when C13-time-quotes-limits lands.
    /// The negotiation terms in `NegotiableTerm` order (the cursor is the enum value).
    const negotiable_terms = [_][]const u8{
        std.fmt.comptimePrint("advance     {d}% → {d}% of the total up front", .{ q.advance_pct, q.advance_pct * 2 }),
        std.fmt.comptimePrint("salvage     +{d} points of salvage rights", .{q.salvage_pct_per_pip * 2}),
        std.fmt.comptimePrint("transport   +{d} points of transport paid", .{q.transport_pct_per_pip * 2}),
        "support     +25 points of straight support (monthly employer convoys)",
        "rights      one step toward independent command",
        std.fmt.comptimePrint("pay         +{d}% monthly pay", .{(q.negotiation_pay_step_bp - 10_000) / 100}),
    };

    fn drawList(self: *App, al: std.mem.Allocator) !void {
        const v = try self.listView(al);
        const body_rows: usize = if (v.table) |t| (if (t.rows.len == 0) 1 else t.rows.len + 1) else if (v.rows.len == 0) 1 else v.rows.len;
        const want: usize = v.head.len + body_rows + v.foot.len + 2;
        const r = self.modalRect(v.w, @intCast(@min(want, v.max_h)));
        const inner = self.screen.pane(r, .{ .title = v.title, .double = true, .right_title = v.right_title });
        var y: u16 = inner.y;
        var left: u16 = inner.h;
        if (v.head.len > 0) {
            const hh: u16 = @intCast(@min(v.head.len, left));
            self.screen.lines(.{ .x = inner.x, .y = y, .w = inner.w, .h = hh }, v.head, 0, null);
            y += hh;
            left -= hh;
        }
        const foot_h: u16 = @intCast(@min(v.foot.len, left));
        const body_h: u16 = left - foot_h;
        const area: Rect = .{ .x = inner.x, .y = y, .w = inner.w, .h = body_h };
        if (v.scroll) {
            const max_first = v.rows.len -| body_h;
            if (self.modal_cursor > max_first) self.modal_cursor = max_first;
            self.screen.lines(area, v.rows, self.modal_cursor, null);
        } else if (v.table) |t| {
            if (!v.read_only) clampIdx(&self.modal_cursor, v.n);
            if (t.rows.len == 0) self.screen.lines(area, &.{v.empty}, 0, null) else _ = try self.screen.table(al, area, t, if (v.read_only) 0 else firstRow(self.modal_cursor, body_h -| 1), if (v.read_only or v.n == 0) null else self.modal_cursor, &self.modal_colscroll);
        } else if (v.rows.len == 0) {
            self.screen.lines(area, &.{v.empty}, 0, null);
        } else {
            if (!v.read_only) clampIdx(&self.modal_cursor, v.n);
            const hi: ?usize = if (v.read_only or v.n == 0) null else v.offset + self.modal_cursor;
            self.screen.lines(area, v.rows, if (hi) |h| firstRow(h, body_h) else 0, hi);
        }
        if (foot_h > 0) self.screen.lines(.{ .x = inner.x, .y = y + body_h, .w = inner.w, .h = foot_h }, v.foot, 0, null);
    }

    /// Keys every list modal shares; the kind-specific ones go to `listEnter`,
    /// `listEscape` and `listExtra`.
    // ---- list modals: one table for walking a list, one per modal's own keys ----

    const ListAction = enum { down, up, page_down, page_up, top, bottom, scroll_left, scroll_right, pick, close };
    pub const list_bindings = [_]keys.Binding(ListAction){
        .{ .match = keys.Match.char('j'), .action = .down, .label = "row", .group = .navigate, .shown = "j/k ↑/↓" },
        .{ .match = .{ .key = .down }, .action = .down, .label = "down", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('k'), .action = .up, .label = "up", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .up }, .action = .up, .label = "up", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .pgdn }, .action = .page_down, .label = "page", .group = .navigate, .shown = "PgUp/PgDn", .show_footer = false },
        .{ .match = .{ .key = .pgup }, .action = .page_up, .label = "page up", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .home }, .action = .top, .label = "top", .group = .navigate, .show_footer = false },
        .{ .match = .{ .key = .end }, .action = .bottom, .label = "end", .group = .navigate, .show_footer = false },
        .{ .match = .{ .key = .left }, .action = .scroll_left, .label = "columns", .group = .navigate, .shown = "←/→" },
        .{ .match = .{ .key = .right }, .action = .scroll_right, .label = "columns", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .enter }, .action = .pick, .label = "choose", .group = .act },
        .{ .match = .{ .key = .escape }, .action = .close, .label = "cancel / close", .group = .misc },
    };

    /// A read-only sheet: ←/→ scroll a table, any other key closes it.
    const SheetAction = enum { scroll_left, scroll_right, close };
    pub const sheet_bindings = [_]keys.Binding(SheetAction){
        .{ .match = .{ .key = .left }, .action = .scroll_left, .label = "columns", .group = .navigate, .shown = "←/→" },
        .{ .match = .{ .key = .right }, .action = .scroll_right, .label = "columns", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .escape }, .action = .close, .label = "close", .group = .misc },
        .{ .match = .{ .key = .enter }, .action = .close, .label = "close", .group = .misc, .show_footer = false, .show_help = false },
        .{ .match = .text, .action = .close, .label = "any other key closes", .group = .misc, .show_footer = false },
    };
    const HelpAction = enum { close };
    pub const help_bindings = [_]keys.Binding(HelpAction){
        .{ .match = keys.Match.char('?'), .action = .close, .label = "close", .group = .misc },
    };

    const RaiseHullsAction = enum { take, pass, prev_lance, next_lance, support_train };
    pub const raise_hulls_bindings = [_]keys.Binding(RaiseHullsAction){
        .{ .match = keys.Match.char('['), .action = .prev_lance, .label = "lance", .group = .navigate, .shown = "[ ]" },
        .{ .match = keys.Match.char(']'), .action = .next_lance, .label = "next lance", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('b'), .action = .take, .label = "take or buy", .group = .act, .help = "take the hull under the cursor (Enter does the same)" },
        .{ .match = keys.Match.char('p'), .action = .pass, .label = "pass", .group = .act, .help = "pass on a board listing" },
        .{ .match = keys.Match.char('n'), .action = .support_train, .label = "support train", .group = .act },
    };
    const RaiseSupportAction = enum { buy, crews };
    pub const raise_support_bindings = [_]keys.Binding(RaiseSupportAction){
        .{ .match = keys.Match.char('b'), .action = .buy, .label = "buy one", .group = .act, .help = "buy a support hull (Enter does the same)" },
        .{ .match = keys.Match.char('n'), .action = .crews, .label = "crews", .group = .act },
    };
    const RaiseCrewsAction = enum { crew };
    pub const raise_crews_bindings = [_]keys.Binding(RaiseCrewsAction){
        .{ .match = keys.Match.char('a'), .action = .crew, .label = "crew from the halls", .group = .act },
        .{ .match = keys.Match.char('A'), .action = .crew, .label = "crew", .group = .act, .show_footer = false, .show_help = false },
    };
    const MusicAction = enum { toggle, skip, back, louder, quieter, close };
    pub const music_bindings = [_]keys.Binding(MusicAction){
        .{ .match = keys.Match.char('m'), .action = .toggle, .label = "music on/off", .group = .act },
        .{ .match = keys.Match.char('M'), .action = .toggle, .label = "music", .group = .act, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('>'), .action = .skip, .label = "next track", .group = .act, .shown = "< >", .help = "previous / next track" },
        .{ .match = keys.Match.char('<'), .action = .back, .label = "previous track", .group = .act, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('+'), .action = .louder, .label = "volume", .group = .act, .shown = "+ -", .help = "louder / quieter" },
        .{ .match = keys.Match.char('='), .action = .louder, .label = "louder", .group = .act, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('-'), .action = .quieter, .label = "quieter", .group = .act, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('q'), .action = .close, .label = "close", .group = .misc, .show_footer = false },
    };
    const DecisionAction = enum { choose };
    pub const decision_bindings = [_]keys.Binding(DecisionAction){
        .{ .match = .{ .chars = .{ '1', '9' } }, .action = .choose, .label = "choose", .group = .act },
    };
    const LogAction = enum { top, bottom, close };
    pub const log_bindings = [_]keys.Binding(LogAction){
        .{ .match = keys.Match.char('g'), .action = .top, .label = "start", .group = .navigate, .show_footer = false },
        .{ .match = keys.Match.char('G'), .action = .bottom, .label = "end", .group = .navigate },
        .{ .match = keys.Match.char('q'), .action = .close, .label = "close", .group = .misc, .show_footer = false },
    };

    const raise_hulls_legend = keys.entries(RaiseHullsAction, &raise_hulls_bindings);
    const raise_support_legend = keys.entries(RaiseSupportAction, &raise_support_bindings);
    const music_legend = keys.entries(MusicAction, &music_bindings);
    const decision_legend = keys.entries(DecisionAction, &decision_bindings);
    const log_legend = keys.entries(LogAction, &log_bindings);
    const sheet_legend = keys.entries(SheetAction, &sheet_bindings);
    const help_legend = keys.entries(HelpAction, &help_bindings);
    const help_navigation_legend = [_]keys.Entry{
        list_legend[0],
        list_legend[1],
        list_legend[2],
        list_legend[3],
        list_legend[4],
        list_legend[5],
        list_legend[6],
        list_legend[7],
        list_legend[11],
    };

    /// A list modal's title: its name, then the list keys with the verbs
    /// this modal gives them ("choose", "assign", "cancel").
    fn listTitle(al: std.mem.Allocator, name: []const u8, pick: ?[]const u8, close: []const u8, columns: bool) ![]const u8 {
        return listTitleWith(al, name, &.{}, pick, close, columns);
    }

    /// `listTitle` with a modal's own keys between its name and the list's.
    fn listTitleWith(al: std.mem.Allocator, name: []const u8, extras: []const keys.Entry, pick: ?[]const u8, close: []const u8, columns: bool) ![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.appendSlice(al, try keys.title(al, name, extras));
        var buf: [16]u8 = undefined;
        if (pick) |verb| try out.print(al, " · [{s}] {s}", .{ keys.keyFor(ListAction, &buf, &list_bindings, .pick), verb });
        if (columns) try out.print(al, " · [{s}] columns", .{keys.keyFor(ListAction, &buf, &list_bindings, .scroll_left)});
        try out.print(al, " · [{s}] {s}", .{ keys.keyFor(ListAction, &buf, &list_bindings, .close), close });
        return out.toOwnedSlice(al);
    }

    fn listKey(self: *App, key: Key) !void {
        if (try self.listExtra(key)) return;
        const v = try self.listView(self.a());
        if (v.read_only) {
            const hit = keys.lookup(SheetAction, &sheet_bindings, 0, key) orelse return;
            switch (hit.action) {
                .scroll_left => if (v.table != null) {
                    self.modal_colscroll -|= 1;
                } else {
                    self.modal = .none;
                },
                .scroll_right => if (v.table != null) {
                    self.modal_colscroll += 1;
                } else {
                    self.modal = .none;
                },
                .close => self.modal = .none,
            }
            return;
        }
        const hit = keys.lookup(ListAction, &list_bindings, 0, key) orelse return;
        switch (hit.action) {
            .close => try self.listEscape(),
            .down => self.modal_cursor +|= 1,
            .up => self.modal_cursor -|= 1,
            .page_down => if (v.scroll) {
                self.modal_cursor +|= 10;
            },
            .page_up => if (v.scroll) {
                self.modal_cursor -|= 10;
            },
            .top => if (v.scroll) {
                self.modal_cursor = 0;
            },
            .bottom => if (v.scroll) {
                self.modal_cursor = std.math.maxInt(usize) / 2;
            },
            .scroll_left => self.modal_colscroll -|= 1,
            .scroll_right => self.modal_colscroll += 1,
            .pick => try self.listEnter(),
        }
    }

    fn listEscape(self: *App) !void {
        switch (self.modal) {
            .raise_hulls => {
                self.modal = .none;
                self.say(.dim, "wizard closed — the company keeps its hulls; Market/Forces l fill the rest, :manning co:N shows the crews it needs", .{});
            },
            .install_loc => |il| self.openModal(.{ .install_part = il.unit }),
            else => self.modal = .none,
        }
    }

    /// Enter on the highlighted row.
    fn listEnter(self: *App) !void {
        const al = self.a();
        switch (self.modal) {
            .battle_list => {
                const rows = try q.battleList(al, self.state());
                if (rows.len == 0) return;
                self.battles_from_list = true;
                self.openModal(.{ .after_action = rows[@min(self.modal_cursor, rows.len - 1)].id });
            },
            .leaderboard => {
                const rows = try q.leaderboard(al, self.state());
                if (rows.len == 0) return;
                self.openModal(.{ .leaderboard_detail = rows[@min(self.modal_cursor, rows.len - 1)].id });
            },
            .raise_hulls => try self.raiseTake(),
            .raise_support => try self.raiseBuySupport(),
            .music => if (self.music) |*m| {
                const c = self.modal_cursor;
                if (c == 0) {
                    m.selectSet(null);
                    self.store.setSetting("music_set", -1) catch |err|
                        self.say(.crit, "music preference not saved: {s}", .{game.cli.errorText(err)});
                    self.say(.dim, "♪ all soundtracks, mixed and reshuffled", .{});
                } else if (c <= m.sets.len) {
                    m.selectSet(c - 1);
                    self.store.setSetting("music_set", @intCast(c - 1)) catch |err|
                        self.say(.crit, "music preference not saved: {s}", .{game.cli.errorText(err)});
                    self.say(.dim, "♪ soundtrack {s}", .{try q.plain(self.a(), m.sets[c - 1])});
                } else {
                    // Header rows: sets + blank + "playing" line, then the tracks in playlist order.
                    const first_track = m.sets.len + 3;
                    if (c >= first_track and c - first_track < m.order.len) {
                        const ti = m.order[c - first_track];
                        m.play(ti);
                        self.store.setSetting("music", 1) catch |err|
                            self.say(.crit, "music preference not saved: {s}", .{game.cli.errorText(err)});
                        self.say(.dim, "♪ {s} — {s}", .{ try q.plain(self.a(), m.tracks[ti].name), try q.plain(self.a(), m.sets[m.tracks[ti].set]) });
                    }
                }
            } else {
                self.modal = .none;
            },
            .negotiate => |offer_id| {
                const term: game.contract.NegotiableTerm = @enumFromInt(@min(self.modal_cursor, negotiable_terms.len - 1));
                self.modal = .none;
                const r = self.execResult(.{ .negotiate = .{ .offer = offer_id, .term = term } }) orelse return;
                switch (r.negotiation) {
                    .improved => self.say(.good, "{s} improved — the offer row shows the new terms", .{@tagName(term)}),
                    .hardened => self.say(.amber, "they hold firm on {s} and shave the pay 5%", .{@tagName(term)}),
                    .withdrawn => self.say(.crit, "the employer walks away — offer withdrawn", .{}),
                    .none => {},
                }
            },
            .pick_company, .pick_hq, .pick_crew, .pick_unassign, .pick_part => try self.pickEnter(),
            .accept_pick => |offer_id| {
                const cands = try q.offerCandidates(al, self.state(), offer_id);
                if (cands.len == 0) return;
                const c = cands[@min(self.modal_cursor, cands.len - 1)];
                self.modal = .none;
                const lift = try q.liftText(al, self.state(), c.company);
                _ = try self.execSay(.{ .accept_contract = .{ .offer = offer_id, .company = c.company } }, .good, "accepted — {s} is on its way, {d} days out{s}{s}", .{ try q.forceName(self.a(), self.state(), c.company), c.transit_days, if (lift.len > 0) " · " else "", lift });
            },
            .operation_pick => |cid| {
                const ops = try q.contractOperations(al, self.state(), cid);
                if (ops.rows.len == 0) return;
                const row = ops.rows[@min(self.modal_cursor, ops.rows.len - 1)];
                // Open the intent picker for this operation; commit happens there.
                self.openModal(.{ .intent_pick = .{ .contract = cid, .operation = row.id } });
            },
            .intent_pick => |ip| {
                const choices = try q.intentChoices(al, self.state(), ip.contract, ip.operation);
                if (choices.len == 0) return;
                const intent = choices[@min(self.modal_cursor, choices.len - 1)];
                self.modal = .none;
                _ = try self.execSay(
                    .{ .commit_operation = .{ .contract = ip.contract, .operation = ip.operation, .intent = intent } },
                    .good,
                    "committed operation with intent: {s}",
                    .{intent.label()},
                );
            },
            .task_pick => |tp| {
                // Enter cycles the task for the highlighted lance through the legal set.
                const gs = self.state();
                const c = gs.contracts.getPtr(tp.contract) orelse return;
                var op_ptr: ?*game.operation.Operation = null;
                for (c.operations.items) |*op| if (op.id == tp.operation) {
                    op_ptr = op;
                    break;
                };
                const op = op_ptr orelse return;
                const ops = try q.contractOperations(al, gs, tp.contract);
                var op_row: ?q.OperationRow = null;
                for (ops.rows) |row| if (row.id == tp.operation) {
                    op_row = row;
                    break;
                };
                const or_data = op_row orelse return;
                // Enumerate eligible lances.
                const lance_ids = try q.combatLances(al, gs, c.assigned_company);
                if (lance_ids.len == 0) return;
                const idx = @min(self.modal_cursor, lance_ids.len - 1);
                const lid = lance_ids[idx];
                // Find current task for this lance.
                var current_idx: ?usize = null;
                for (op.tasks.items, 0..) |lt, i| if (lt.lance == lid) {
                    current_idx = i;
                    break;
                };
                const current_task: ?game.operation.LanceTask = if (current_idx) |i|
                    op.tasks.items[i].task
                else
                    null;
                // Cycle to the next legal task, wrapping through null (clear).
                const legal = or_data.legal_tasks;
                if (legal.len == 0) {
                    self.say(.amber, "no legal tasks for this operation", .{});
                    return;
                }
                const next_task: ?game.operation.LanceTask = blk: {
                    if (current_task) |ct| {
                        for (legal, 0..) |t, i| if (t == ct) {
                            // Next in cycle; after the last task cycle to null (clear).
                            if (i + 1 < legal.len) break :blk legal[i + 1];
                            break :blk null; // wrap to clear
                        };
                    }
                    // null → first legal task.
                    break :blk legal[0];
                };
                if (next_task) |task| {
                    _ = try self.execSay(
                        .{ .task_lance = .{ .contract = tp.contract, .operation = tp.operation, .lance = lid, .task = task } },
                        .good,
                        "tasked lance: {s}",
                        .{task.label()},
                    );
                } else {
                    _ = try self.execSay(
                        .{ .clear_lance_task = .{ .contract = tp.contract, .operation = tp.operation, .lance = lid } },
                        .good,
                        "cleared task",
                        .{},
                    );
                }
                // Keep the modal open (cycling, not closing on Enter).
            },
            .tempo_pick => |tp| {
                const choices = try q.tempoChoices(al, self.state(), tp.contract, tp.operation);
                if (choices.len == 0) return;
                const posture = choices[@min(self.modal_cursor, choices.len - 1)];
                self.modal = .none;
                _ = try self.execSay(
                    .{ .set_operation_tempo = .{ .contract = tp.contract, .operation = tp.operation, .tempo = posture } },
                    .good,
                    "operation tempo set: {s}",
                    .{posture.label()},
                );
            },
            .intervention_pick => |ip| {
                const ops = try q.contractOperations(al, self.state(), ip.contract);
                var op_row: ?q.OperationRow = null;
                for (ops.rows) |row| if (row.id == ip.operation) {
                    op_row = row;
                    break;
                };
                const op = op_row orelse return;
                if (op.affordable_interventions.len == 0) return;
                const iv = op.affordable_interventions[@min(self.modal_cursor, op.affordable_interventions.len - 1)];
                self.modal = .none;
                _ = try self.execSay(
                    .{ .apply_intervention = .{ .contract = ip.contract, .operation = ip.operation, .intervention = iv } },
                    .good,
                    "intervention applied: {s}",
                    .{iv.label()},
                );
            },
            .lance_pick => |uid| {
                const lances = try self.lanceChoices(uid);
                if (lances.len == 0) return;
                const lc = lances[@min(self.modal_cursor, lances.len - 1)];
                self.modal = .none;
                _ = try self.execSay(.{ .move_unit = .{ .unit = uid, .force = lc.force } }, .good, "#{d} moved to {s}", .{ @intFromEnum(uid), try q.plain(self.a(), lc.name) });
            },
            .upgrade => |hid| {
                const rows = try q.upgrades(al, self.state(), hid);
                if (rows.len == 0) return;
                const r = rows[@min(self.modal_cursor, rows.len - 1)];
                self.modal = .none;
                _ = try self.execSay(.{ .upgrade_facility = .{ .hq = hid, .kind = r.kind } }, .good, "{s} upgrade started — paperwork first, then construction; watch PROJECTS", .{@tagName(r.kind)});
            },
            .install_part => |uid| {
                const cands = try q.installCandidates(al, self.state(), uid);
                if (cands.len == 0) return;
                const c = cands[@min(self.modal_cursor, cands.len - 1)];
                self.openModal(.{ .install_loc = .{ .unit = uid, .part = c.key } });
            },
            .install_loc => |il| {
                const locs = try q.installLocations(al, self.state(), il.unit, il.part);
                if (locs.len == 0) return;
                const l = locs[@min(self.modal_cursor, locs.len - 1)];
                if (!l.legal) {
                    self.say(.amber, "the rules refuse {s} in {s} — pick a green location", .{ il.part, @tagName(l.location) });
                    return;
                }
                self.modal = .none;
                _ = try self.execSay(.{ .refit_install = .{ .unit = il.unit, .location = l.location, .part_key = il.part } }, .good, "staged: install {s} in {s} — [m] in the Lab commits it to a bay", .{ il.part, @tagName(l.location) });
            },
            .install_at => |ia| {
                const cands = try q.partsFittingLocation(al, self.state(), ia.unit, ia.location);
                if (cands.len == 0) return;
                const c = cands[@min(self.modal_cursor, cands.len - 1)];
                self.modal = .none;
                const res = self.execResult(.{ .refit_install = .{ .unit = ia.unit, .location = ia.location, .part_key = c.key } });
                if (res != null) {
                    self.say(.good, "staged: install {s} in {s} — [m] commits it to a bay", .{ c.key, @tagName(ia.location) });
                }
            },
            .seat => |id| {
                const seats = try q.openSeats(al, self.state(), id);
                self.modal = .none;
                if (seats.len == 0) return;
                const st = seats[@min(self.modal_cursor, seats.len - 1)];
                _ = try self.execSay(.{ .assign = .{ .unit = st.unit, .slot = st.slot, .person = id } }, .good, "assigned as {s} of #{d}", .{ @tagName(st.slot), @intFromEnum(st.unit) });
            },
            .emblem => {
                self.modal = .none;
                const i = self.modal_cursor;
                if (i < emblems.len) {
                    try self.applyEmblem(emblems[i].name);
                    self.say(.good, "emblem set to preset {s}", .{emblems[i].name});
                } else if (i == emblems.len + self.logos.len) {
                    self.openEmblemEditor();
                } else if (i - emblems.len < self.logos.len) {
                    const path = self.logos[i - emblems.len];
                    const bytes = emblem_mod.readFile(self.io, self.gpa, path) catch |err| {
                        self.say(.crit, "could not read {s}: {s}", .{ try q.plain(self.a(), path), game.cli.errorText(err) });
                        return;
                    };
                    defer self.gpa.free(bytes);
                    if (!png.isPng(bytes)) {
                        self.say(.crit, "{s} is not a PNG", .{try q.plain(self.a(), path)});
                        return;
                    }
                    try self.applyEmblem(bytes);
                    self.say(.good, "emblem set from {s}{s}", .{ try q.plain(self.a(), path), if (self.emblem == null) " (could not decode it — 8-bit non-interlaced PNG only)" else "" });
                }
            },
            .contract_log => self.modal = .none,
            else => {},
        }
    }

    /// A list modal's own letter keys. Returns whether the key was taken.
    /// The keys one list modal adds to walking and picking; true when the
    /// key was one of them.
    fn listExtra(self: *App, key: Key) !bool {
        switch (self.modal) {
            .help => {
                const hit = keys.lookup(HelpAction, &help_bindings, 0, key) orelse return false;
                switch (hit.action) {
                    .close => self.modal = .none,
                }
            },
            .raise_hulls => {
                const hit = keys.lookup(RaiseHullsAction, &raise_hulls_bindings, 0, key) orelse return false;
                switch (hit.action) {
                    .take => try self.raiseTake(),
                    .pass => {
                        const g = self.state();
                        const cands = try q.raiseCandidates(self.a(), g, self.raise.company, self.raise.passed[0..self.raise.passed_len]);
                        if (cands.len == 0) return true;
                        const c = cands[@min(self.modal_cursor, cands.len - 1)];
                        if (c.kind != .listing) {
                            self.say(.dim, "only board listings can be passed — hulls on hand just stay in the pool", .{});
                            return true;
                        }
                        if (self.raise.passed_len >= self.raise.passed.len) return true;
                        self.raise.passed[self.raise.passed_len] = c.key;
                        self.raise.passed_len += 1;
                    },
                    .prev_lance, .next_lance => {
                        const lances = try self.raiseLances();
                        if (lances.len == 0) return true;
                        self.raise.lance_idx = if (hit.action == .next_lance) (self.raise.lance_idx + 1) % lances.len else (self.raise.lance_idx + lances.len - 1) % lances.len;
                    },
                    .support_train => self.openModal(.raise_support),
                }
            },
            .raise_support => {
                const hit = keys.lookup(RaiseSupportAction, &raise_support_bindings, 0, key) orelse return false;
                switch (hit.action) {
                    .buy => try self.raiseBuySupport(),
                    .crews => self.modal = .raise_crews,
                }
            },
            .raise_crews => {
                const hit = keys.lookup(RaiseCrewsAction, &raise_crews_bindings, 0, key) orelse return false;
                switch (hit.action) {
                    .crew => {
                        const r = self.execResult(.{ .crew_company = self.raise.company }) orelse return true;
                        self.say(if (r.still_open == 0) .good else .amber, "{d} hired and seated · {d} lines still open — the halls had nobody of that trade yet", .{ r.hired_count, r.still_open });
                    },
                }
            },
            .music => {
                const hit = keys.lookup(MusicAction, &music_bindings, 0, key) orelse return false;
                switch (hit.action) {
                    .toggle => try self.toggleMusic(),
                    .skip => if (self.music) |*m| m.skip(),
                    .back => if (self.music) |*m| m.back(),
                    .louder => try self.adjustVolume(10),
                    .quieter => try self.adjustVolume(-10),
                    .close => self.modal = .none,
                }
            },
            .decision => |idx| {
                const hit = keys.lookup(DecisionAction, &decision_bindings, 0, key) orelse return false;
                switch (hit.action) {
                    .choose => {
                        self.modal = .none;
                        _ = try self.execSay(.{ .resolve_decision = .{ .event = idx, .choice = hit.offset } }, .good, "decision recorded", .{});
                    },
                }
            },
            .contract_log => {
                const hit = keys.lookup(LogAction, &log_bindings, 0, key) orelse return false;
                switch (hit.action) {
                    .top => self.modal_cursor = 0,
                    .bottom => self.modal_cursor = std.math.maxInt(usize) / 2,
                    .close => self.modal = .none,
                }
            },
            .operation_pick => |cid| {
                if (key != .char) return false;
                const al = self.a();
                const ops = try q.contractOperations(al, self.state(), cid);
                if (ops.rows.len == 0) return true;
                const idx = @min(self.modal_cursor, ops.rows.len - 1);
                const row = ops.rows[idx];
                if (key.char == 'x') {
                    // `x` declines the highlighted operation.
                    _ = try self.execSay(.{ .decline_operation = .{ .contract = cid, .operation = row.id } }, .amber, "declined operation: {s}", .{row.name});
                    self.modal = .none;
                    return true;
                }
                if (key.char == 'r') {
                    // `r` opens the tempo picker for the highlighted operation.
                    self.openModal(.{ .tempo_pick = .{ .contract = cid, .operation = row.id } });
                    return true;
                }
                if (key.char == 'i') {
                    // `i` opens the intervention picker for committed combat ops.
                    if (row.state == .committed and row.combat) {
                        self.openModal(.{ .intervention_pick = .{ .contract = cid, .operation = row.id } });
                    } else {
                        self.say(.amber, "interventions are only available for committed combat operations", .{});
                    }
                    return true;
                }
                if (key.char == 'w') {
                    // `w` operationally withdraws the highlighted operation.
                    _ = try self.execSay(.{ .withdraw_operation = .{ .contract = cid, .operation = row.id } }, .amber, "withdrawn: {s}", .{row.name});
                    self.modal = .none;
                    return true;
                }
                if (key.char == 'e') {
                    // `e` exploits a resolved successful combat operation.
                    _ = try self.execSay(.{ .exploit_operation = .{ .contract = cid, .operation = row.id } }, .good, "exploiting success: {s}", .{row.name});
                    self.modal = .none;
                    return true;
                }
                if (key.char == 'o') {
                    // `o` consolidates a resolved operation.
                    _ = try self.execSay(.{ .consolidate_operation = .{ .contract = cid, .operation = row.id } }, .good, "consolidated: {s}", .{row.name});
                    self.modal = .none;
                    return true;
                }
                return false;
            },
            .record => |pid| {
                // Person-detail modal: action keys from the person_action_keys table.
                if (key != .char) return false;
                const al = self.a();
                const g = self.state();
                const pa = try q.personActions(al, g, pid);
                for (person_action_keys) |entry| {
                    if (key.char != entry.key) continue;
                    const eligible = switch (entry.action) {
                        .seat => pa.can_seat,
                        .transfer => pa.can_transfer,
                        .post => pa.can_post,
                        .train => pa.can_train,
                        .leave => pa.can_leave,
                        .triage => pa.can_triage,
                        .admit => pa.can_admit,
                        .fire => pa.can_fire,
                    };
                    if (!eligible) return false;
                    try self.personAct(pid, entry.action);
                    return true;
                }
                return false;
            },
            .intent_pick => return false, // only Enter (listEnter) is handled for intent_pick
            .task_pick => |tp| {
                // 'x' clears the current task for the highlighted lance.
                if (key != .char or key.char != 'x') return false;
                const al = self.a();
                const gs = self.state();
                const c = gs.contracts.getPtr(tp.contract) orelse return false;
                const lance_ids = try q.combatLances(al, gs, c.assigned_company);
                if (lance_ids.len == 0) return true;
                const idx = @min(self.modal_cursor, lance_ids.len - 1);
                const lid = lance_ids[idx];
                _ = try self.execSay(
                    .{ .clear_lance_task = .{ .contract = tp.contract, .operation = tp.operation, .lance = lid } },
                    .good,
                    "cleared task",
                    .{},
                );
                return true;
            },
            .mech => |m| {
                // Sub-view letter keys switch the view.
                if (key == .char) {
                    for (mech_view_keys) |mk| {
                        if (key.char == mk.key) {
                            self.modal.mech.view = mk.view;
                            self.modal_cursor = 0;
                            return true;
                        }
                    }
                    return false;
                }
                // Esc from a sub-view steps back to summary rather than closing.
                if (key == .escape and m.view != .summary) {
                    self.modal.mech.view = .summary;
                    self.modal_cursor = 0;
                    return true;
                }
                return false;
            },
            else => return false,
        }
        return true;
    }

    // ---- modal keys: one table per modal, the handler switches on the action ----

    const AfterActionAction = enum { scroll_left, scroll_right, close };
    pub const after_action_bindings = [_]keys.Binding(AfterActionAction){
        .{ .match = .{ .key = .left }, .action = .scroll_left, .label = "columns", .group = .navigate, .shown = "←/→" },
        .{ .match = .{ .key = .right }, .action = .scroll_right, .label = "columns", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .escape }, .action = .close, .label = "read", .group = .misc },
        .{ .match = .text, .action = .close, .label = "read", .group = .misc, .show_footer = false, .show_help = false },
    };
    const EditorAction = enum { left, right, up, down, erase, save, undo, cancel, paint };
    pub const editor_bindings = [_]keys.Binding(EditorAction){
        .{ .match = .{ .key = .left }, .action = .left, .label = "move", .group = .navigate, .shown = "arrows" },
        .{ .match = .{ .key = .right }, .action = .right, .label = "right", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .up }, .action = .up, .label = "up", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .down }, .action = .down, .label = "down", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .backspace }, .action = .erase, .label = "erase", .group = .act },
        .{ .match = keys.Match.char('u'), .action = .undo, .label = "undo", .group = .act },
        .{ .match = .text, .action = .paint, .label = "paint", .group = .act, .help = "paint the cell with the character typed" },
        .{ .match = .{ .key = .enter }, .action = .save, .label = "save as the outfit's crest", .group = .act },
        .{ .match = .{ .key = .escape }, .action = .cancel, .label = "cancel", .group = .misc },
    };
    const AmountKey = enum { next, prev, erase, more, less, digit, run, cancel };
    pub const amount_bindings = [_]keys.Binding(AmountKey){
        .{ .match = .{ .key = .tab }, .action = .next, .label = "field", .group = .navigate, .shown = "Tab j/k" },
        .{ .match = .{ .key = .down }, .action = .next, .label = "next", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('j'), .action = .next, .label = "next", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .backtab }, .action = .prev, .label = "previous", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .up }, .action = .prev, .label = "previous", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('k'), .action = .prev, .label = "previous", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('+'), .action = .more, .label = "step", .group = .act, .shown = "+ -" },
        .{ .match = keys.Match.char('='), .action = .more, .label = "more", .group = .act, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('-'), .action = .less, .label = "less", .group = .act, .show_footer = false, .show_help = false },
        .{ .match = .{ .chars = .{ '0', '9' } }, .action = .digit, .label = "type", .group = .act },
        .{ .match = .{ .key = .backspace }, .action = .erase, .label = "erase", .group = .act, .show_footer = false },
        .{ .match = .{ .key = .enter }, .action = .run, .label = "finish", .group = .act },
        .{ .match = .{ .key = .escape }, .action = .cancel, .label = "cancel", .group = .misc },
    };
    /// Battle orders and settings walk rows and step the one under the cursor.
    const FormAction = enum { down, up, less, more, act, close };
    pub const form_bindings = [_]keys.Binding(FormAction){
        .{ .match = keys.Match.char('j'), .action = .down, .label = "row", .group = .navigate, .shown = "j/k" },
        .{ .match = .{ .key = .down }, .action = .down, .label = "down", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('k'), .action = .up, .label = "up", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .up }, .action = .up, .label = "up", .group = .navigate, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .left }, .action = .less, .label = "change", .group = .act, .shown = "← →" },
        .{ .match = keys.Match.char('h'), .action = .less, .label = "less", .group = .act, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .right }, .action = .more, .label = "more", .group = .act, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('l'), .action = .more, .label = "more", .group = .act, .show_footer = false, .show_help = false },
        .{ .match = .{ .key = .enter }, .action = .act, .label = "act", .group = .act },
        .{ .match = .{ .key = .escape }, .action = .close, .label = "close", .group = .misc },
        .{ .match = keys.Match.char('q'), .action = .close, .label = "close", .group = .misc, .show_footer = false, .show_help = false },
    };
    /// The settings form's shortcuts, on top of walking its rows.
    const SettingsShortcut = enum { music, louder, quieter, skip, back, tracks, difficulty, auto_admit };
    pub const settings_bindings = [_]keys.Binding(SettingsShortcut){
        .{ .match = keys.Match.char('m'), .action = .music, .label = "music", .group = .act },
        .{ .match = keys.Match.char('M'), .action = .music, .label = "music", .group = .act, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('+'), .action = .louder, .label = "volume", .group = .act, .shown = "+ -" },
        .{ .match = keys.Match.char('='), .action = .louder, .label = "louder", .group = .act, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('-'), .action = .quieter, .label = "quieter", .group = .act, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('>'), .action = .skip, .label = "track", .group = .act, .shown = "< >" },
        .{ .match = keys.Match.char('<'), .action = .back, .label = "previous track", .group = .act, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('t'), .action = .tracks, .label = "soundtracks", .group = .act },
        .{ .match = keys.Match.char('T'), .action = .tracks, .label = "soundtracks", .group = .act, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('d'), .action = .difficulty, .label = "difficulty", .group = .act },
        .{ .match = keys.Match.char('D'), .action = .difficulty, .label = "difficulty", .group = .act, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('a'), .action = .auto_admit, .label = "auto-admit", .group = .act },
        .{ .match = keys.Match.char('A'), .action = .auto_admit, .label = "auto-admit", .group = .act, .show_footer = false, .show_help = false },
    };
    /// The warnings the end-turn prompt asks about, in Desk order; the
    /// modal's rows, its number keys and whether it opens all read this.
    fn endTurnRows(al: std.mem.Allocator, checklist: []const q.ChecklistRow) ![]const q.ChecklistRow {
        var asks: std.ArrayListUnmanaged(q.ChecklistRow) = .empty;
        for (checklist) |w| if (w.prompts) try asks.append(al, w);
        return asks.toOwnedSlice(al);
    }
    const EndTurnAction = enum { day, week, jump, cancel };
    pub const end_turn_bindings = [_]keys.Binding(EndTurnAction){
        .{ .match = keys.Match.char('n'), .action = .day, .label = "end the turn anyway", .group = .act },
        .{ .match = keys.Match.char('y'), .action = .day, .label = "a day", .group = .act, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('N'), .action = .week, .label = "end 7 turns", .group = .act },
        .{ .match = .{ .chars = .{ '1', '9' } }, .action = .jump, .label = "go to that warning", .group = .navigate },
        .{ .match = .{ .key = .escape }, .action = .cancel, .label = "not yet", .group = .misc },
    };
    const QuitAction = enum { save, discard, stay };
    pub const quit_bindings = [_]keys.Binding(QuitAction){
        .{ .match = keys.Match.char('s'), .action = .save, .label = "save and return", .group = .act },
        .{ .match = keys.Match.char('r'), .action = .discard, .label = "return without saving", .group = .act },
        .{ .match = .{ .key = .escape }, .action = .stay, .label = "stay in the campaign", .group = .misc },
    };
    const GameOverAction = enum { leave, retry };
    pub const game_over_bindings = [_]keys.Binding(GameOverAction){
        .{ .match = .{ .key = .enter }, .action = .leave, .label = "return to the welcome screen", .group = .act },
        .{ .match = .{ .key = .escape }, .action = .leave, .label = "return to the welcome screen", .group = .act, .show_footer = false, .show_help = false },
        .{ .match = keys.Match.char('r'), .action = .retry, .label = "retry the save", .group = .act },
    };
    /// Every confirm dialog: the dialog names the verbs, the table owns the keys.
    const ConfirmAction = enum { confirm, alternative, cancel };
    pub const confirm_bindings = [_]keys.Binding(ConfirmAction){
        .{ .match = keys.Match.char('y'), .action = .confirm, .label = "confirm", .group = .act },
        .{ .match = keys.Match.char('s'), .action = .alternative, .label = "the second choice", .group = .act },
        .{ .match = .{ .key = .escape }, .action = .cancel, .label = "keep", .group = .misc },
    };
    const InputAction = enum { submit, erase, complete, cancel, type };
    pub const input_bindings = [_]keys.Binding(InputAction){
        .{ .match = .text, .action = .type, .label = "type", .group = .act, .show_footer = false },
        .{ .match = .{ .key = .backspace }, .action = .erase, .label = "erase", .group = .act, .show_footer = false },
        .{ .match = .{ .key = .tab }, .action = .complete, .label = "complete", .group = .act, .show_footer = false, .help = "complete a verb or an id (the command line)" },
        .{ .match = .{ .key = .enter }, .action = .submit, .label = "confirm", .group = .act },
        .{ .match = .{ .key = .escape }, .action = .cancel, .label = "cancel", .group = .misc },
    };

    const editor_legend = keys.entries(EditorAction, &editor_bindings);
    const list_legend = keys.entries(ListAction, &list_bindings);
    const raise_crews_legend = keys.entries(RaiseCrewsAction, &raise_crews_bindings);
    const after_action_legend = keys.entries(AfterActionAction, &after_action_bindings);
    const form_legend = keys.entries(FormAction, &form_bindings);
    const settings_legend = keys.entries(SettingsShortcut, &settings_bindings);
    const end_turn_legend = keys.entries(EndTurnAction, &end_turn_bindings);
    const quit_legend = keys.entries(QuitAction, &quit_bindings);
    const game_over_legend = keys.entries(GameOverAction, &game_over_bindings);
    const confirm_legend = keys.entries(ConfirmAction, &confirm_bindings);
    const amount_legend = keys.entries(AmountKey, &amount_bindings);
    const input_legend = keys.entries(InputAction, &input_bindings);

    /// A form modal's title: its name, the row and change keys, and its
    /// act and close verbs.
    fn formTitle(al: std.mem.Allocator, name: []const u8, close: []const u8) ![]const u8 {
        return std.fmt.allocPrint(al, "{s} · {s} · {s} · {s} · {s}", .{
            name,
            try keyHint(FormAction, al, &form_bindings, .down, "row"),
            try keyHint(FormAction, al, &form_bindings, .less, "change"),
            try keyHint(FormAction, al, &form_bindings, .act, "act"),
            try keyHint(FormAction, al, &form_bindings, .close, close),
        });
    }

    /// `[key] verb` for a hint in a modal's text, the key from its table.
    fn keyHint(comptime A: type, al: std.mem.Allocator, bindings: []const keys.Binding(A), action: A, verb: []const u8) ![]const u8 {
        var buf: [16]u8 = undefined;
        return std.fmt.allocPrint(al, "[{s}] {s}", .{ keys.keyFor(A, &buf, bindings, action), verb });
    }

    /// A confirm dialog's title: the question, then its verbs on the table's keys.
    fn confirmTitle(al: std.mem.Allocator, question: []const u8, verb: []const u8, alt: ?[]const u8, keep: []const u8) ![]const u8 {
        return std.fmt.allocPrint(al, "{s} · {s}{s}{s} · {s}", .{
            question,
            try keyHint(ConfirmAction, al, &confirm_bindings, .confirm, verb),
            if (alt != null) " · " else "",
            if (alt) |alt_verb| try keyHint(ConfirmAction, al, &confirm_bindings, .alternative, alt_verb) else "",
            try keyHint(ConfirmAction, al, &confirm_bindings, .cancel, keep),
        });
    }

    /// A confirm dialog's button row.
    fn confirmButtons(al: std.mem.Allocator, verb: []const u8, alt: ?[]const u8, keep: []const u8) ![]const u8 {
        return std.fmt.allocPrint(al, "  {{s}} {s} {{/}}   {s}{s}{s}{{d}}{s}{{/}}", .{
            try keyHint(ConfirmAction, al, &confirm_bindings, .confirm, verb),
            if (alt != null) "{s} " else "",
            if (alt) |alt_verb| try keyHint(ConfirmAction, al, &confirm_bindings, .alternative, alt_verb) else "",
            if (alt != null) " {/}   " else "",
            try keyHint(ConfirmAction, al, &confirm_bindings, .cancel, keep),
        });
    }

    fn handleModalKey(self: *App, key: Key) !void {
        switch (self.modal) {
            .none => {},
            .help, .decision, .raise_hulls, .raise_support, .music, .summary, .readiness, .raise_crews, .negotiate, .pick_company, .pick_hq, .pick_crew, .pick_unassign, .pick_part, .accept_pick, .lance_pick, .upgrade, .install_part, .install_loc, .install_at, .seat, .emblem, .hull, .contract_log, .log_entry, .battle_list, .record, .operation_pick, .intent_pick, .task_pick, .tempo_pick, .intervention_pick, .operation_report, .mech, .leaderboard, .leaderboard_detail => try self.listKey(key),
            .after_action => |id| {
                const hit = keys.lookup(AfterActionAction, &after_action_bindings, 0, key) orelse return;
                switch (hit.action) {
                    .scroll_left => self.colScroll(2).* -|= 1,
                    .scroll_right => self.colScroll(2).* += 1,
                    .close => {
                        // Closing the sheet is reading it — the command
                        // does the marking, the client never touches the record.
                        _ = try self.execSay(.{ .read_report = id }, .good, "after-action read", .{});
                        // A fight the company won asks for the tempo next:
                        // hand it over rather than drop the player
                        // on a screen that refuses to advance.
                        self.modal = switch (q.turnHold(self.state())) {
                            .decision => |ev| .{ .decision = ev },
                            else => if (self.battles_from_list) .{ .battle_list = {} } else .none,
                        };
                    },
                }
            },
            .emblem_editor => {
                const hit = keys.lookup(EditorAction, &editor_bindings, 0, key) orelse return;
                switch (hit.action) {
                    .cancel => self.modal = .none,
                    .left => self.ed_x -|= 1,
                    .right => self.ed_x = @min(7, self.ed_x + 1),
                    .up => self.ed_y -|= 1,
                    .down => self.ed_y = @min(2, self.ed_y + 1),
                    .erase => {
                        self.ed_x -|= 1;
                        self.ed_art[self.ed_y][self.ed_x] = ' ';
                    },
                    .save => {
                        var bytes: std.ArrayListUnmanaged(u8) = .empty;
                        try bytes.appendSlice(self.a(), art_magic);
                        for (0..3) |r| {
                            try bytes.appendSlice(self.a(), &self.ed_art[r]);
                            if (r < 2) try bytes.append(self.a(), '\n');
                        }
                        self.modal = .none;
                        try self.applyEmblem(bytes.items);
                        self.say(.good, "emblem set to your own crest", .{});
                    },
                    .undo => self.ed_art = self.ed_undo,
                    .paint => {
                        const ch = key.char;
                        if (ch < 0x7f) {
                            self.ed_art[self.ed_y][self.ed_x] = @intCast(ch);
                            self.ed_x = @min(7, self.ed_x + 1);
                        }
                    },
                }
            },
            .amount => |*form| {
                const hit = keys.lookup(AmountKey, &amount_bindings, 0, key) orelse return;
                const f = &form.fields[form.cur];
                switch (hit.action) {
                    .cancel => self.modal = .none,
                    .next => form.cur = @intCast((form.cur + 1) % form.n),
                    .prev => form.cur = @intCast((form.cur + form.n - 1) % form.n),
                    .erase => {
                        // Editing may pass through 0 so a last digit can always be
                        // deleted; the range applies when the form runs.
                        f.value = @divTrunc(f.value, 10);
                        f.typed = true;
                    },
                    .run => try self.amountRun(),
                    .more => f.value = @min(f.max, f.value + f.step),
                    .less => f.value = @max(f.min, f.value - f.step),
                    .digit => {
                        const d: i64 = hit.offset;
                        f.value = if (f.typed and f.value != 0) @min(f.max, f.value *| 10 +| d) else d;
                        f.typed = true;
                    },
                }
            },
            .battle_orders => |id| {
                const hit = keys.lookup(FormAction, &form_bindings, 0, key) orelse return;
                switch (hit.action) {
                    .close => self.modal = .none,
                    .down => try self.ordersMove(id, 1),
                    .up => try self.ordersMove(id, -1),
                    .less => try self.ordersAdjust(id, -1),
                    .more => try self.ordersAdjust(id, 1),
                    .act => try self.ordersEnter(id),
                }
            },
            .settings => {
                if (keys.lookup(SettingsShortcut, &settings_bindings, 0, key)) |hit| {
                    switch (hit.action) {
                        .music => try self.toggleMusic(),
                        .louder => try self.adjustVolume(10),
                        .quieter => try self.adjustVolume(-10),
                        .skip => if (self.music) |*m| m.skip(),
                        .back => if (self.music) |*m| m.back(),
                        .tracks => self.openModal(.music),
                        .difficulty => try self.cycleDifficulty(1),
                        .auto_admit => try self.toggleAutoAdmit(),
                    }
                    return;
                }
                const hit = keys.lookup(FormAction, &form_bindings, 0, key) orelse return;
                switch (hit.action) {
                    .close => self.modal = .none,
                    .down => try self.settingsMove(1),
                    .up => try self.settingsMove(-1),
                    .less => try self.settingsAdjust(-1),
                    .more => try self.settingsAdjust(1),
                    .act => try self.settingsEnter(),
                }
            },
            .end_turn => {
                const hit = keys.lookup(EndTurnAction, &end_turn_bindings, 0, key) orelse return;
                switch (hit.action) {
                    .cancel => self.modal = .none,
                    .day => {
                        self.modal = .none;
                        try self.advance(self.end_turn_days);
                    },
                    .week => {
                        self.modal = .none;
                        try self.advance(7);
                    },
                    .jump => {
                        const asks = try endTurnRows(self.a(), (try q.desk(self.a(), self.state(), 0)).checklist);
                        if (hit.offset < asks.len) {
                            const row = asks[hit.offset];
                            self.modal = .none;
                            self.switchTab(@enumFromInt(row.jump));
                            // Open the specific entity the warning is about (rule 32).
                            if (row.contract != .none) self.modal = .{ .contract_log = row.contract };
                        }
                    },
                }
            },
            .quit => {
                const hit = keys.lookup(QuitAction, &quit_bindings, 0, key) orelse return;
                switch (hit.action) {
                    .stay => self.modal = .none,
                    .save => {
                        self.modal = .none;
                        self.store.save(&self.session.?, self.player_id) catch |err| {
                            self.say(.crit, "save failed: {s}", .{game.cli.errorText(err)});
                            return;
                        };
                        self.leaveGame();
                    },
                    .discard => {
                        self.modal = .none;
                        self.leaveGame();
                    },
                }
            },
            .game_over_saved => {
                const hit = keys.lookup(GameOverAction, &game_over_bindings, 0, key) orelse return;
                switch (hit.action) {
                    .leave => {
                        self.modal = .none;
                        self.leaveGame();
                    },
                    .retry => {}, // already saved — no-op
                }
            },
            .game_over_failed => {
                const hit = keys.lookup(GameOverAction, &game_over_bindings, 0, key) orelse return;
                switch (hit.action) {
                    .leave => {
                        self.modal = .none;
                        self.leaveGame();
                    },
                    .retry => {
                        if (self.store.save(&self.session.?, self.player_id)) |_|
                            self.modal = .game_over_saved
                        else |save_err|
                            self.modal = .{ .game_over_failed = game.cli.errorText(save_err) };
                    },
                }
            },
            .confirm => |c| {
                const hit = keys.lookup(ConfirmAction, &confirm_bindings, 0, key) orelse return;
                const spec = try self.confirmSpec(c);
                switch (hit.action) {
                    .cancel => self.modal = .none,
                    .confirm => {
                        self.modal = .none;
                        if (try self.execSay(spec.cmd, .amber, "{s}", .{spec.done})) self.afterConfirm(c);
                    },
                    .alternative => if (spec.alt) |alt| {
                        self.modal = .none;
                        if (try self.execSay(alt.cmd, .amber, "{s}", .{alt.done})) self.afterConfirm(c);
                    },
                }
            },
            .input => |kind| {
                const hit = keys.lookup(InputAction, &input_bindings, 0, key) orelse return;
                switch (hit.action) {
                    .cancel => self.modal = .none,
                    .erase => self.input.pop(),
                    .complete => if (kind == .command) try self.completeCommand(),
                    .submit => {
                        self.modal = .none;
                        try self.submitInput(kind);
                    },
                    .type => self.input.push(key.char),
                }
            },
        }
    }

    fn leaveGame(self: *App) void {
        if (self.session) |*session| session.close();
        self.session = null;
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
                const players = try self.store.players(al);
                for (players, 0..) |p, i| if (p.id == id) {
                    self.cur(0).* = i;
                };
                self.say(.good, "player \"{s}\" created", .{try q.plain(self.a(), text)});
            },
            .delete_campaign => {
                const campaigns = try self.store.campaigns(al, self.player_id);
                if (campaigns.len == 0) return;
                const c = campaigns[@min(self.cur(1).*, campaigns.len - 1)];
                // raw: the typed name must match the stored one exactly.
                if (!std.mem.eql(u8, text, c.name.raw)) {
                    self.say(.amber, "name did not match — nothing deleted", .{});
                    return;
                }
                try self.store.deleteCampaign(c.id, if (self.session) |*session| session else null);
                self.say(.good, "deleted \"{s}\"", .{try c.name.markup(self.a())});
            },
            .delete_player => {
                const players = try self.store.players(al);
                for (players) |p| {
                    if (p.id == self.player_id) {
                        // raw: the typed name must match the stored one exactly.
                        if (!std.mem.eql(u8, text, p.name.raw)) {
                            self.say(.amber, "name did not match — nothing deleted", .{});
                            return;
                        }
                        try self.store.deletePlayer(p.id, if (self.session) |*s| s else null);
                        self.say(.good, "deleted player \"{s}\" and their campaigns", .{try p.name.markup(self.a())});
                        self.player_id = 0;
                        self.cur(0).* = 0;
                        try self.pickDefaultPlayer();
                        return;
                    }
                }
            },
            .raise_name => {
                if (text.len == 0) return;
                const g = self.state();
                const r = self.execResult(.{ .raise_company = .{ .name = text, .hq = self.raise.hq } }) orelse return;
                self.raise.company = r.created_force;
                self.raise.lance_idx = 0;
                self.raise.passed_len = 0;
                self.openModal(.raise_hulls);
                self.say(.good, "{s} raised at {s} — empty lances: pick hulls from the pool and every board", .{ try q.plain(self.a(), text), try q.hqName(self.a(), g, self.raise.hq) });
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
            for (try q.completionCandidates(al, self.state())) |c| if (std.mem.startsWith(u8, c, prefix)) try cands.append(al, c);
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
        const g = self.state();

        const client = game.cli.parseClientVerb(verb, &tokens) catch |err| {
            self.say(.amber, "{s} — usage: {s}", .{ game.cli.errorText(err), game.cli.usage(verb) orelse verb });
            return;
        };
        if (client) |cv| {
            switch (cv) {
                // The checklist asks first, as for `n`, unless forced.
                .day => |d| if (d.force) try self.advance(d.days) else try self.endTurnRequest(d.days),
                .save => {
                    self.store.save(&self.session.?, self.player_id) catch |err| {
                        self.say(.crit, "save failed: {s}", .{game.cli.errorText(err)});
                        return;
                    };
                    self.say(.good, "saved at day {d}", .{(try q.status(self.a(), g)).day});
                },
                .quit => self.modal = .quit,
                .help => self.openModal(.help),
                .settings => self.modal = .settings,
                .summary => self.modal = .summary,
                .music => self.openModal(.music),
                .readiness => self.modal = .readiness,
                .manning => |co| {
                    self.raise.company = co;
                    self.modal = .raise_crews;
                },
                .emblem => {
                    try self.loadLogoList();
                    self.openModal(.emblem);
                },
            }
            return;
        }
        const cmd = game.cli.parseCommand(verb, &tokens) catch |err| {
            self.say(.amber, "{s} — usage: {s}", .{ game.cli.errorText(err), game.cli.usage(verb) orelse verb });
            return;
        };
        if (cmd) |c| {
            const res = self.execResult(c) orelse return;
            self.say(.good, "{s}", .{try q.resultText(self.a(), self.state(), c, res)});
        } else {
            self.say(.amber, "unknown verb '{s}' — see ? for the list, or use the CLI (--repl) for the rest", .{try q.plain(self.a(), verb)});
        }
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
    /// Asset root overriding the search in paths.zig (`--data`).
    data_dir: ?[]const u8 = null,
    /// Fixed base for the wizard's campaign seed (`--seed`); null keeps the
    /// wall-clock entropy.
    seed: ?u64 = null,
};

/// Entry point from main: open the store, take the terminal, run the app.
pub fn run(io: std.Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map, store_path: [:0]const u8, options: Options) !void {
    const store = Lobby.open(store_path) catch |err| {
        std.debug.print("could not open save store '{s}': {s}\n", .{ store_path, game.cli.errorText(err) });
        return err;
    };
    defer store.close();

    // Outlives `app`: the asset paths are borrowed, not copied.
    var roots_arena = std.heap.ArenaAllocator.init(gpa);
    defer roots_arena.deinit();
    const roots = paths.resolve(io, roots_arena.allocator(), env, options.data_dir);

    var out_buf: [1 << 16]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var term = try Term.init(&stdout.interface);
    defer term.deinit();

    var app = try App.init(gpa, io, &term, store);
    defer app.deinit();
    app.screen.ascii = options.ascii;
    app.show_splash = !options.no_splash;
    app.seed_override = options.seed;
    app.asset_roots = roots;
    if (options.no_music) {
        app.music_note = "music off (--no-music)";
    } else if (roots.music) |dir| {
        var player = music_mod.Player.init(io, gpa, dir);
        if (player.available()) {
            app.music = player;
        } else {
            // Say which half is missing: the files, or the program that plays them.
            app.music_note = if (player.tracks.len == 0)
                try std.fmt.allocPrint(roots_arena.allocator(), "no audio files under {s} — one sub-directory per soundtrack (.aac .m4a .mp3 .wav .flac .ogg)", .{dir})
            else
                try std.fmt.allocPrint(roots_arena.allocator(), "{d} tracks found under {s}, but no audio player on PATH — install mpv, ffplay (ffmpeg) or aplay (alsa-utils); afplay on macOS", .{ player.tracks.len, dir });
            player.deinit();
        }
    } else {
        app.music_note = "no music directory found — keep tracks in data/music/ or $IRON_LEDGER_DATA/music, or pass --data <dir>";
    }
    try app.run();
}

/// A headless client over a generated campaign, for the screen tests: the
/// frames go to a discarding writer, saves to an in-memory store, and the
/// screen is 200x50. Heap-allocated because `App` keeps a pointer to its
/// `Term`; `deinitForTest` frees it.
pub const ClientForTest = struct {
    sink: std.Io.Writer.Discarding,
    term: Term,
    app: App,
};

pub fn clientForTest(gpa: std.mem.Allocator) !*ClientForTest {
    const c = try gpa.create(ClientForTest);
    errdefer gpa.destroy(c);
    c.sink = std.Io.Writer.Discarding.init(&.{});
    c.term = .{ .in_fd = -1, .orig = undefined, .out = &c.sink.writer };
    const store = try game.lobby.Lobby.open(":memory:");
    c.app = try App.init(gpa, std.testing.io, &c.term, store);
    try c.app.screen.resize(200, 50);
    c.app.player_id = try store.createPlayer("Test");
    c.app.w_name.set("Erik Kalmar");
    c.app.w_outfit.set("The Unforgiven");
    c.app.w_company.set("Alpha Company");
    try c.app.generateCampaign();
    try c.app.beginCampaign();
    return c;
}

pub fn deinitForTest(c: *ClientForTest, gpa: std.mem.Allocator) void {
    const store = c.app.store;
    c.app.deinit();
    store.close();
    gpa.destroy(c);
}

/// One key through the client's handler, then a frame, as the run loop does.
pub fn pressForTest(c: *ClientForTest, key: Key) !void {
    _ = c.app.frame.reset(.retain_capacity);
    try c.app.handleKey(key);
    try c.app.draw();
}

test "every screen draws at full size and at 80x24, and the cursor clamps after a resize" {
    const c = try clientForTest(std.testing.allocator);
    defer deinitForTest(c, std.testing.allocator);
    for (0..10) |t| {
        try pressForTest(c, .{ .f = @intCast(t + 1) });
        try std.testing.expectEqual(@as(Tab, @enumFromInt(t)), c.app.tab);
        // Run the cursor far past any list, then shrink: every pane still draws.
        for (0..60) |_| try pressForTest(c, .{ .char = 'j' });
    }
    try c.app.screen.resize(80, 24);
    for (0..10) |t| {
        try pressForTest(c, .{ .f = @intCast(t + 1) });
        for (0..3) |_| try pressForTest(c, .tab);
        try pressForTest(c, .{ .char = 'k' });
    }
    try c.app.screen.resize(200, 50);
    try c.app.draw();
}

test "the end-turn key moves the calendar, and Esc closes whatever modal it opened" {
    const c = try clientForTest(std.testing.allocator);
    defer deinitForTest(c, std.testing.allocator);
    const day0 = (try q.status(c.app.a(), c.app.state())).day;
    try pressForTest(c, .{ .char = 'n' });
    // With warnings standing the checklist asks first; `n` again confirms.
    if (c.app.modal != .none) try pressForTest(c, .{ .char = 'n' });
    try std.testing.expect((try q.status(c.app.a(), c.app.state())).day > day0);
    try pressForTest(c, .{ .char = '?' });
    try std.testing.expect(c.app.modal != .none);
    try pressForTest(c, .escape);
    try std.testing.expect(c.app.modal == .none);
}

test "a malformed :day moves no time; N asks first like n, and n there ends the week" {
    const c = try clientForTest(std.testing.allocator);
    defer deinitForTest(c, std.testing.allocator);
    const al = c.app.a();
    const day0 = (try q.status(al, c.app.state())).day;
    for ([_][]const u8{ "day junk", "day -1", "day 1 extra", "day 0", "save now" }) |line| {
        try c.app.runCommandLine(line);
        try std.testing.expectEqual(day0, (try q.status(al, c.app.state())).day);
    }
    // An empty seat is a warning the prompt asks about.
    for (try q.toe(al, c.app.state())) |r| if (r.unit != .none) {
        try c.app.runCommandLine(try std.fmt.allocPrint(al, "unassign {d} pilot", .{@intFromEnum(r.unit)}));
        break;
    };
    c.app.modal = .none;
    try pressForTest(c, .{ .char = 'N' });
    try std.testing.expect(c.app.modal == .end_turn);
    try std.testing.expectEqual(day0, (try q.status(al, c.app.state())).day);
    try pressForTest(c, .{ .char = 'n' });
    try std.testing.expect((try q.status(al, c.app.state())).day > day0);
}

test "the end-turn prompt asks only about warnings that prompt; Desk notes stay out" {
    const rows = [_]q.ChecklistRow{
        .{ .kind = .crew_recovering, .urgent = false, .prompts = false, .text = "heals", .jump = 2 },
        .{ .kind = .restless_crew, .urgent = false, .prompts = false, .text = "restless", .jump = 8 },
        .{ .kind = .open_slots, .urgent = false, .prompts = true, .text = "empty seat", .jump = 2 },
    };
    const asks = try App.endTurnRows(std.testing.allocator, &rows);
    defer std.testing.allocator.free(asks);
    try std.testing.expectEqual(@as(usize, 1), asks.len);
    try std.testing.expectEqual(game.checklist.WarningKind.open_slots, asks[0].kind);
    const none = try App.endTurnRows(std.testing.allocator, rows[0..2]);
    defer std.testing.allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "no screen binds a key the whole client already answers" {
    for (App.screen_table) |spec| for (spec.legend) |e| for (App.global_legend) |g| {
        if (e.match.overlaps(g.match)) {
            std.debug.print("{s}: \"{s}\" shadows the global \"{s}\"\n", .{ spec.name, e.label, g.label });
            return error.TestUnexpectedResult;
        }
    };
    try keys.expectWellFormed(App.GlobalAction, &App.global_bindings);
}

test "docs/tui.md carries the generated key reference, exactly" {
    const al = std.testing.allocator;
    const doc = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "docs/tui.md", al, .limited(1 << 20));
    defer al.free(doc);
    const want = try App.keysMarkdown(al);
    defer al.free(want);
    const b = std.mem.indexOf(u8, doc, App.keys_begin) orelse return error.KeyBlockMissing;
    const e = std.mem.indexOf(u8, doc, App.keys_end) orelse return error.KeyBlockMissing;
    // Regenerate with `zig-out/bin/game --keys-markdown` and paste between the markers.
    try std.testing.expectEqualStrings(want, doc[b .. e + App.keys_end.len]);
}

test "every modal, welcome and wizard table is well formed" {
    const K = keys;
    try K.expectWellFormed(App.ListAction, &App.list_bindings);
    try K.expectWellFormed(App.SheetAction, &App.sheet_bindings);
    try K.expectWellFormed(App.HelpAction, &App.help_bindings);
    try K.expectWellFormed(App.RaiseHullsAction, &App.raise_hulls_bindings);
    try K.expectWellFormed(App.RaiseSupportAction, &App.raise_support_bindings);
    try K.expectWellFormed(App.RaiseCrewsAction, &App.raise_crews_bindings);
    try K.expectWellFormed(App.MusicAction, &App.music_bindings);
    try K.expectWellFormed(App.DecisionAction, &App.decision_bindings);
    try K.expectWellFormed(App.LogAction, &App.log_bindings);
    try K.expectWellFormed(App.AfterActionAction, &App.after_action_bindings);
    try K.expectWellFormed(App.EditorAction, &App.editor_bindings);
    try K.expectWellFormed(App.AmountKey, &App.amount_bindings);
    try K.expectWellFormed(App.FormAction, &App.form_bindings);
    try K.expectWellFormed(App.SettingsShortcut, &App.settings_bindings);
    try K.expectWellFormed(App.EndTurnAction, &App.end_turn_bindings);
    try K.expectWellFormed(App.QuitAction, &App.quit_bindings);
    try K.expectWellFormed(App.GameOverAction, &App.game_over_bindings);
    try K.expectWellFormed(App.ConfirmAction, &App.confirm_bindings);
    try K.expectWellFormed(App.InputAction, &App.input_bindings);
    try K.expectWellFormed(App.WelcomeAction, &App.welcome_bindings);
    try K.expectWellFormed(App.CommanderAction, &App.commander_bindings);
    try K.expectWellFormed(App.OutfitAction, &App.outfit_bindings);
    try K.expectWellFormed(App.CompanyAction, &App.company_bindings);
    try K.expectWellFormed(App.ReviewAction, &App.review_bindings);
    // The settings shortcuts sit on top of the form's own keys.
    for (App.settings_legend) |a| for (App.form_legend) |b| try std.testing.expect(!a.match.overlaps(b.match));
}

test "a confirm dialog names its verbs on the table's keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    try std.testing.expectEqualStrings("SELL OR STRIP HULL? · [y] sell · [s] strip · [Esc] keep", try App.confirmTitle(al, "SELL OR STRIP HULL?", "sell", "strip", "keep"));
    try std.testing.expectEqualStrings("FIRE? · [y] fire · [Esc] keep", try App.confirmTitle(al, "FIRE?", "fire", null, "keep"));
}

test "modalRect never covers the footer row" {
    const c = try clientForTest(std.testing.allocator);
    defer deinitForTest(c, std.testing.allocator);
    for ([_]u16{ 24, 30, 40, 50 }) |rows| {
        try c.app.screen.resize(80, rows);
        // A modal requesting the full terminal height must not touch the footer.
        const r = c.app.modalRect(60, rows);
        try std.testing.expect(r.y + r.h < rows);
    }
}

test "hqSelId propagates a query error instead of returning zero" {
    // Compile-time proof: hqSelId returns an error union, not a plain u32.
    const info = @typeInfo(@TypeOf(App.hqSelId));
    const ret = info.@"fn".return_type.?;
    comptime std.debug.assert(@typeInfo(ret) == .error_union);
}

test "game-over modal distinguishes save success from save failure" {
    // The Modal enum must carry the save result as distinct variants.
    const saved: Modal = .game_over_saved;
    const failed: Modal = .{ .game_over_failed = "test" };
    try std.testing.expect(@as(std.meta.Tag(Modal), saved) != @as(std.meta.Tag(Modal), failed));
    try std.testing.expect(@as(std.meta.Tag(Modal), saved) == .game_over_saved);
    try std.testing.expect(@as(std.meta.Tag(Modal), failed) == .game_over_failed);

    // The binding table must include a retry action.
    const has_retry = for (App.game_over_bindings) |b| {
        if (b.action == .retry) break true;
    } else false;
    try std.testing.expect(has_retry);
}

test "handleGameOver saves and shows the correct modal (rule 44)" {
    const al = std.testing.allocator;
    // Success path: a bankrupt campaign is saved and shows game_over_saved.
    {
        const c = try clientForTest(al);
        defer deinitForTest(c, al);
        c.app.state().bankrupt = true;
        try c.app.handleGameOver();
        try std.testing.expect(c.app.modal == .game_over_saved);
    }
    // Failure path: save fails → game_over_failed with a truthful sentence.
    // Point campaign_id at a non-existent row so the save returns NoSuchCampaign.
    {
        const c = try clientForTest(al);
        defer deinitForTest(c, al);
        c.app.state().bankrupt = true;
        c.app.state().campaign_id = 99999; // no campaign row with this id
        try c.app.handleGameOver();
        switch (c.app.modal) {
            .game_over_failed => |text| try std.testing.expect(text.len > 0),
            else => return error.ExpectedGameOverFailed,
        }
        c.app.state().campaign_id = 0; // reset so deinit is clean
    }
    // Non-bankrupt: handleGameOver is a no-op (modal stays .none).
    {
        const c = try clientForTest(al);
        defer deinitForTest(c, al);
        c.app.state().bankrupt = false;
        try c.app.handleGameOver();
        try std.testing.expect(c.app.modal == .none);
    }
}

test "every focusable pane is drawn at each width tier" {
    // Rule 38 / rule 67 / audit A19: for every screen and every tier width,
    // the set of drawn panes must be exactly {0 .. paneCount()-1} (rule 38:
    // "focus follows visibility").  This fails on the base for Forces at
    // narrow widths when narrow_panes == 2 but the side pane is not drawn.
    const c = try clientForTest(std.testing.allocator);
    defer deinitForTest(c, std.testing.allocator);
    const widths = [_]u16{ 80, 100, 119, 120, 121, 150, 151, 200 };
    for (App.screen_table) |spec| {
        for (widths) |w| {
            try c.app.screen.resize(w, 50);
            c.app.switchTab(spec.tab);
            c.app.focus = 0;
            try c.app.draw();
            const pc = c.app.paneCount();
            const want: u16 = (@as(u16, 1) << @intCast(pc)) - 1;
            try std.testing.expectEqual(want, c.app.panes_drawn);
        }
    }
}

test "a wide-only focus clamps into the narrow panes on resize" {
    // Rule 38: after a resize that reduces the pane count, focus must not
    // remain on an undrawn pane.
    const c = try clientForTest(std.testing.allocator);
    defer deinitForTest(c, std.testing.allocator);
    // Forces: wide has 2 panes, narrow has 1.
    try c.app.screen.resize(200, 50);
    c.app.switchTab(.forces);
    const forces_wide_pc = c.app.paneCount();
    c.app.focus = forces_wide_pc - 1;
    try c.app.screen.resize(100, 50);
    try c.app.draw();
    try std.testing.expect(c.app.focus < c.app.paneCount());
    // Market: wide has 4 panes, narrow has 2.
    try c.app.screen.resize(200, 50);
    c.app.switchTab(.market);
    const market_wide_pc = c.app.paneCount();
    c.app.focus = market_wide_pc - 1;
    try c.app.screen.resize(100, 50);
    try c.app.draw();
    try std.testing.expect(c.app.focus < c.app.paneCount());
}

test "person-detail modal: pressing m on a wounded un-admitted person admits them (rule 34/86)" {
    // Open the detail modal on a wounded person, press `m`, verify the command ran.
    const c = try clientForTest(std.testing.allocator);
    defer deinitForTest(c, std.testing.allocator);
    c.app.switchTab(.people);
    // Grab the first person on the roster and wound them.
    const id = (try c.app.selectedPerson()) orelse return error.NoPerson;
    c.app.state().person(id).?.status = .wounded;
    c.app.state().person(id).?.medbay_admitted = false;
    // Open the record modal via pressing `r`.
    try pressForTest(c, .{ .char = 'r' });
    try std.testing.expect(c.app.modal == .record);
    // Press `m` — should dispatch admit through the existing command path.
    try pressForTest(c, .{ .char = 'm' });
    try std.testing.expect(c.app.state().person(id).?.medbay_admitted);
}

test "mech-detail modal: pressing h on a hull opens the mech modal and sub-views browse correctly (P3c.6)" {
    const c = try clientForTest(std.testing.allocator);
    defer deinitForTest(c, std.testing.allocator);
    // Navigate to Forces (F3).
    c.app.switchTab(.forces);
    // Find the first hull row in the TO&E.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = try c.app.toeRows();
    // Locate a hull row (unit != .none) and position the cursor there.
    var hull_row_idx: ?usize = null;
    for (rows, 0..) |r, i| if (r.unit != .none and q.hullInstanceForUnit(c.app.state(), r.unit) != .none) {
        hull_row_idx = i;
        break;
    };
    const idx = hull_row_idx orelse return error.NoHullRow;
    c.app.cur(0).* = idx;
    // Press `h` — should open the mech-detail modal.
    try pressForTest(c, .{ .char = 'h' });
    try std.testing.expect(c.app.modal == .mech);
    try std.testing.expectEqual(MechView.summary, c.app.modal.mech.view);
    // Press `c` — should switch to combat sub-view.
    try pressForTest(c, .{ .char = 'c' });
    try std.testing.expectEqual(MechView.combat, c.app.modal.mech.view);
    // Press Esc — should step back to summary.
    try pressForTest(c, .escape);
    try std.testing.expectEqual(MechView.summary, c.app.modal.mech.view);
    // Press Esc again — should close the modal.
    try pressForTest(c, .escape);
    try std.testing.expect(c.app.modal == .none);
}

test "wizard grid navigation moves w_logo correctly and clamps at bounds" {
    const c = try clientForTest(std.testing.allocator);
    defer deinitForTest(c, std.testing.allocator);

    // Seed the wizard with a 7-logo catalog (two full rows + 2 extra).
    c.app.logos = &.{
        "data/logos/ashfall_lancers.png",
        "data/logos/balance_point_mercenaries.png",
        "data/logos/c.png",
        "data/logos/d.png",
        "data/logos/e.png",
        "data/logos/f.png",
        "data/logos/g.png",
    };
    c.app.w_logo = 0;
    c.app.w_outfit_auto = true;

    // Auto-fill from first logo.
    c.app.adoptLogoName();
    try std.testing.expectEqualStrings("Ashfall Lancers", c.app.w_outfit.slice());
    try std.testing.expect(c.app.w_outfit_auto);

    // Right: 0 → 1.
    c.app.gridMove(1);
    try std.testing.expectEqual(@as(usize, 1), c.app.w_logo);
    try std.testing.expectEqualStrings("Balance Point Mercenaries", c.app.w_outfit.slice());

    // Down (5 steps): 1 → 6.
    c.app.gridMove(5);
    try std.testing.expectEqual(@as(usize, 6), c.app.w_logo);

    // Right past end: clamps at 6 (logos.len - 1).
    c.app.gridMove(1);
    try std.testing.expectEqual(@as(usize, 6), c.app.w_logo);

    // Left: 6 → 5.
    c.app.gridMove(-1);
    try std.testing.expectEqual(@as(usize, 5), c.app.w_logo);

    // Up (−5): 5 → 0.
    c.app.gridMove(-5);
    try std.testing.expectEqual(@as(usize, 0), c.app.w_logo);

    // Left past beginning: clamps at 0.
    c.app.gridMove(-1);
    try std.testing.expectEqual(@as(usize, 0), c.app.w_logo);

    // Freeze auto-fill; move should not change the name.
    c.app.w_outfit_auto = false;
    c.app.gridMove(1);
    try std.testing.expectEqualStrings("Ashfall Lancers", c.app.w_outfit.slice());
    try std.testing.expect(!c.app.w_outfit_auto);
}

test "generateCampaign force-loads selected thumbnail before reading its bytes (down-then-generate)" {
    // Regression for the lazy-load gap: if the user navigates down to a cell
    // that the draw loop has not yet decoded and immediately presses next,
    // generateCampaign must still produce a non-empty emblem image.
    const gpa = std.testing.allocator;
    var sink = std.Io.Writer.Discarding.init(&.{});
    var term: Term = .{ .in_fd = -1, .orig = undefined, .out = &sink.writer };
    const store = try game.lobby.Lobby.open(":memory:");
    defer store.close();
    var app = try App.init(gpa, std.testing.io, &term, store);
    defer app.deinit();
    app.player_id = try store.createPlayer("Test");
    app.w_name.set("Erik Kalmar");
    app.w_outfit.set("Down Then Generate");
    app.w_company.set("Alpha Company");

    // Seed the catalog with real on-disk logos (6 entries: two rows at 5 cols each,
    // so index 5 sits in the second row and is never in the initial visible window).
    const logos = [_][]const u8{
        "data/logos/ashfall_lancers.png",
        "data/logos/balance_point_mercenaries.png",
        "data/logos/blackstar_company.png",
        "data/logos/broken_sky_company.png",
        "data/logos/cerberus_contracting.png",
        "data/logos/dawnbreak_mercenaries.png", // idx 5 — second row, not lazily loaded yet
    };
    app.logos = &logos;
    const thumbs = try gpa.alloc(?emblem_mod.Emblem, logos.len);
    @memset(thumbs, null);
    app.w_thumbs = thumbs;

    // Navigate down one row (5 steps right) to select index 5.
    app.w_logo = 5;
    // w_thumbs[5] is null — it has never been drawn (simulates the bug path).
    try std.testing.expect(app.w_thumbs[5] == null);

    // generateCampaign must force-load index 5 before reading its bytes.
    try app.generateCampaign();

    // After generateCampaign the thumbnail should be decoded (PNG is on disk).
    try std.testing.expect(app.w_thumbs[5] != null);
    try std.testing.expect(app.w_thumbs[5].?.bytes.len > 0);
}

test "help overlay is context-aware: game shows focused screen only; switching tabs changes it" {
    const c = try clientForTest(std.testing.allocator);
    defer deinitForTest(c, std.testing.allocator);
    // clientForTest starts in game mode on the Desk screen.
    try std.testing.expectEqual(Mode.game, c.app.mode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    // On Desk: help rows must contain "F1 Desk" and must NOT contain "F8 Lab".
    const desk_rows = try c.app.keyHelpRows(al);
    var found_desk = false;
    var found_lab = false;
    var desk_header: ?usize = null;
    for (desk_rows, 0..) |row, i| {
        if (std.mem.indexOf(u8, row, "F1 Desk") != null) {
            found_desk = true;
            desk_header = i;
        }
        if (std.mem.indexOf(u8, row, "F8 Lab") != null) found_lab = true;
    }
    try std.testing.expect(found_desk);
    try std.testing.expect(!found_lab);
    try std.testing.expect(desk_header != null and desk_header.? > 0);
    try std.testing.expectEqualStrings("", desk_rows[desk_header.? - 1]);

    // Switch to Lab (F8); help rows must now contain "F8 Lab" and not "F1 Desk".
    try pressForTest(c, .{ .f = 8 });
    try std.testing.expectEqual(Tab.lab, c.app.tab);
    const lab_rows = try c.app.keyHelpRows(al);
    var found_lab2 = false;
    var found_desk2 = false;
    for (lab_rows) |row| {
        if (std.mem.indexOf(u8, row, "F8 Lab") != null) found_lab2 = true;
        if (std.mem.indexOf(u8, row, "F1 Desk") != null) found_desk2 = true;
    }
    try std.testing.expect(found_lab2);
    try std.testing.expect(!found_desk2);
}

test "help overlay scrolls and question mark closes it" {
    const c = try clientForTest(std.testing.allocator);
    defer deinitForTest(c, std.testing.allocator);
    try c.app.screen.resize(80, 24);

    try pressForTest(c, .{ .char = '?' });
    try std.testing.expectEqual(Modal.help, c.app.modal);
    const view = try c.app.listView(c.app.a());
    try std.testing.expect(view.scroll);
    try std.testing.expectEqual(c.app.screen.rows -| 2, view.max_h);

    try pressForTest(c, .{ .char = 'j' });
    try std.testing.expectEqual(Modal.help, c.app.modal);
    try std.testing.expect(c.app.modal_cursor > 0);

    try pressForTest(c, .{ .char = 'x' });
    try std.testing.expectEqual(Modal.help, c.app.modal);

    try pressForTest(c, .escape);
    try std.testing.expectEqual(Modal.none, c.app.modal);

    try pressForTest(c, .{ .char = '?' });
    try pressForTest(c, .{ .char = '?' });
    try std.testing.expectEqual(Modal.none, c.app.modal);
}
