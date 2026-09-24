//! CLI entry point (application layer). Scripted demo by default; pass
//! `--repl` (`zig build run -- --repl`) for an interactive command loop,
//! or `--tui` for the terminal client (Stage 12, src/tui/). The CLI stays
//! the scripting/debug interface.
//! No MekHQ counterpart: the scripted demo and the REPL (docs/mekhq-map.md).

test {
    _ = @import("tui/screen.zig");
    _ = @import("tui/layout.zig");
    _ = @import("tui/term.zig");
    _ = @import("tui/app.zig");
    _ = @import("tui/screens/desk.zig");
    _ = @import("tui/screens/map.zig");
    _ = @import("tui/screens/forces.zig");
    _ = @import("tui/screens/contracts.zig");
    _ = @import("tui/screens/ledger.zig");
    _ = @import("tui/screens/supply.zig");
    _ = @import("tui/screens/hq.zig");
    _ = @import("tui/screens/lab.zig");
    _ = @import("tui/screens/people.zig");
    _ = @import("tui/screens/market.zig");
    _ = @import("tui/png.zig");
    _ = @import("tui/emblem.zig");
    _ = @import("tui/splash.zig");
    _ = @import("tui/music.zig");
    _ = @import("tui/paths.zig");
}

const std = @import("std");
const game = @import("game");
const paths = @import("tui/paths.zig");

const Command = game.commands.Command;

pub fn main(init: std.process.Init) !void {
    var gs = game.state.GameState.init(init.gpa, .{ .seed = 3025 });
    defer gs.deinit();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // exe name
    var repl = false;
    var tui = false;
    var ascii = false;
    var no_splash = false;
    var no_music = false;
    var data_dir: ?[]const u8 = null;
    var store_arg: ?[:0]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--keys-markdown")) {
            // The key reference block for docs/tui.md, from the binding tables.
            std.debug.print("{s}\n", .{try @import("tui/app.zig").App.keysMarkdown(init.arena.allocator())});
            return;
        }
        if (std.mem.eql(u8, arg, "--repl")) repl = true;
        if (std.mem.eql(u8, arg, "--tui")) tui = true;
        if (std.mem.eql(u8, arg, "--ascii")) ascii = true;
        if (std.mem.eql(u8, arg, "--no-splash")) no_splash = true;
        if (std.mem.eql(u8, arg, "--no-music")) no_music = true;
        if (std.mem.eql(u8, arg, "--store")) store_arg = args.next() orelse store_arg;
        if (std.mem.eql(u8, arg, "--data")) data_dir = args.next() orelse data_dir;
    }

    // Without --store the save lives beside the binary in a source tree and
    // in the per-user data directory for an installed copy (tui/paths.zig).
    const store_path = store_arg orelse
        try paths.defaultStore(init.io, init.arena.allocator(), init.environ_map);

    if (tui) {
        try @import("tui/app.zig").run(init.io, init.gpa, init.environ_map, store_path, .{ .ascii = ascii, .no_splash = no_splash, .no_music = no_music, .data_dir = data_dir });
    } else if (repl) {
        try runRepl(&gs, init.io, init.gpa, store_path);
    } else {
        try runDemo(&gs, init.gpa);
    }
}

fn printCampaigns(lobby: game.lobby.Lobby, al: std.mem.Allocator) !void {
    const list = lobby.allCampaigns(al) catch {
        std.debug.print("could not read the campaign registry\n", .{});
        return;
    };
    if (list.len == 0) {
        std.debug.print("no saved campaigns.\n", .{});
        return;
    }
    std.debug.print("campaigns (most recently saved first):\n", .{});
    for (list) |c| {
        std.debug.print("  [{d}] {s} — commander {s} — {s} (day {d})\n", .{ c.id, c.name.terminal(al) catch "?", c.commander.terminal(al) catch "?", c.date, c.day });
    }
}

const q = game.queries;

/// Print a query's lines, markup stripped (the console has no colour).
fn printLines(al: std.mem.Allocator, lines: []const []const u8, indent: []const u8) !void {
    for (lines) |l| std.debug.print("{s}{s}\n", .{ indent, q.stripMarks(al, l) catch l });
}

/// Print a query's table, markup stripped.
fn printTable(al: std.mem.Allocator, cols: []const game.table.Col, rows: anytype, indent: []const u8) !void {
    const t = try q.tableOf(al, cols, rows);
    printLines(al, t.render(al) catch return, indent) catch |err| showError(err);
}

/// Clear whatever is holding the turn: read the
/// after-action, answer the battle decision with its default. The demo
/// is an unattended run, so it takes the default every time — the point
/// is that it never advances past a fight without acknowledging it.
fn clearTurnHolds(gs: *game.state.GameState, al: std.mem.Allocator) !void {
    while (true) switch (q.turnHold(gs)) {
        .none => return,
        .after_action => |id| {
            if (try q.battleReport(al, gs, id)) |lines| {
                if (lines.len > 0) std.debug.print("        after-action: {s}\n", .{lines[0]});
            }
            _ = try game.commands.execute(gs, .{ .read_report = id });
        },
        .decision => |id| {
            const ev = try q.pendingDecision(al, gs, id) orelse return;
            std.debug.print("        battle decision: taking the default — \"{s}\"\n", .{ev.default_option});
            _ = try game.commands.execute(gs, .{ .resolve_decision = .{ .event = id, .choice = ev.default_choice } });
        },
    };
}

fn runDemo(gs: *game.state.GameState, gpa: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    std.debug.print("=== IRON LEDGER — scripted demo ===\n\n", .{});

    // Character creation: a Capellan ex-quartermaster stands up shop at home.
    _ = try game.commands.execute(gs, .{ .create_commander = .{
        .name = "Erik Kalmar",
        .origin = .CC,
        .profession = .quartermaster,
    } });
    _ = try game.commands.execute(gs, .{ .rename_outfit = "Kalmar's Free Legion" });
    const co = (try game.commands.execute(gs, .{ .new_company = "Alpha Company" })).created_force;

    printHqs(gs, al) catch |err| showError(err);
    std.debug.print("{s}\n{s}\n\n", .{ try q.commanderLine(al, gs), try q.payrollLine(al, gs) });
    printOffers(gs, al) catch |err| showError(err);

    // Hunt the monthly boards for combat-class work: a raid
    // start-to-finish, battles resolved hands-off.
    var pick: ?usize = null;
    var hunts: u32 = 0;
    while (pick == null and hunts < 8) : (hunts += 1) {
        const board = (try q.contracts(al, gs, .none)).board;
        // Prefer in-ring combat work; take a beachhead raid over waiting.
        for (board) |offer| if (!offer.kind.isGarrisonClass() and !offer.beachhead) {
            pick = offer.index;
            break;
        };
        if (pick == null) for (board) |offer| if (!offer.kind.isGarrisonClass()) {
            pick = offer.index;
            break;
        };
        if (pick == null) _ = try game.commands.execute(gs, .{ .advance_days = 30 });
    }
    _ = try game.commands.execute(gs, .{ .accept_contract = .{ .offer_index = pick orelse 0, .company = co } });
    std.debug.print("\nAccepted — {s}\n", .{(try q.acceptedLine(al, gs)) orelse ""});

    // Fund the deployment — an initial courier plus a standing
    // top-up policy so the company can pay its suppliers in the field.
    _ = try game.commands.execute(gs, .{ .transfer = .{ .from = .outfit, .to = .{ .company = co }, .amount = 300_000 } });
    _ = try game.commands.execute(gs, .{ .set_policy = .{ .entity = .{ .company = co }, .floor = 200_000, .monthly_cap = 400_000 } });
    std.debug.print("Dispatched 300k operating funds by courier; standing policy: top up to 200k monthly.\n", .{});
    std.debug.print("\nStores at departure:\n", .{});
    printSupplies(gs, al) catch |err| showError(err);

    // The HQ works while the company is away — capital by
    // courier for a warehouse expansion, and two side torsos fabricated for
    // the inevitable.
    const seat = (try q.hqList(al, gs))[0].id;
    _ = try game.commands.execute(gs, .{ .transfer = .{ .from = .outfit, .to = .{ .hq = seat }, .amount = 2_000_000 } });
    _ = try game.commands.execute(gs, .{ .advance_days = 3 }); // the courier's three days of paperwork
    _ = game.commands.execute(gs, .{ .upgrade_facility = .{ .hq = seat, .kind = .warehouse } }) catch |err| {
        std.debug.print("upgrade refused: {s}\n", .{game.cli.errorText(err)});
    };
    _ = game.commands.execute(gs, .{ .fabricate = .{ .hq = seat, .part_key = "comp_torso", .quantity = 2 } }) catch |err| {
        std.debug.print("fabrication refused: {s}\n", .{game.cli.errorText(err)});
    };
    std.debug.print("\nHQ operations queued:\n", .{});
    printProjects(gs, al) catch |err| showError(err);
    printBays(gs, al) catch |err| showError(err);

    // Run it month by month until completion (report capped at a year).
    // Turn-based: decisions land in the inbox; the demo answers the first
    // one by hand and lets later ones default at their deadlines. A
    // battle is different — the turn stops on the day it
    // lands and waits, so the demo plays the month out in whatever pieces
    // the fighting leaves it, reading and answering as it goes.
    var answered_one = false;
    for (0..12) |month| {
        var left: u32 = 30;
        while (left > 0) {
            try clearTurnHolds(gs, al);
            const r = try game.commands.execute(gs, .{ .advance_days = left });
            if (r.days_advanced == 0) break; // refused for a reason of its own
            left -= @intCast(r.days_advanced);
        }
        try clearTurnHolds(gs, al);
        const st = try q.status(al, gs);
        const active = (try q.contracts(al, gs, .none)).active;
        const running = active.len > 0;
        var on_station = false;
        for (active) |row| if (row.status) |cs| if (cs == .active) {
            on_station = true;
        };

        // Keep the field stores fed — monthly reload orders shipped
        // to the company (paid by the HQ, freight included), refused if the
        // trucks are already full.
        if (on_station) {
            var ordered: u32 = 0;
            for (game.part.munition_keys) |key| {
                if (game.commands.execute(gs, .{ .order_part = .{ .part_key = key, .quantity = 3, .dest = .{ .company = co } } })) |_| {
                    ordered += 3;
                } else |_| {}
            }
            _ = game.commands.execute(gs, .{ .order_part = .{ .part_key = "provisions", .quantity = 15, .dest = .{ .company = co } } }) catch |err| std.debug.print("order part refused: {s}\n", .{game.cli.errorText(err)});
            if (ordered > 0) std.debug.print("        resupply ordered: {d}t munitions + provisions to the field\n", .{ordered});
        }
        std.debug.print("  month {d:>2}: funds {s} ({s}){s}\n", .{
            month + 1, st.funds, if (running) "running" else "over",
            if (st.inbox > 0) " — decision in inbox" else "",
        });
        if (!answered_one) if (try q.firstPendingDecision(al, gs)) |ev| {
            std.debug.print("        answering [{s}] with option 0: \"{s}\"\n", .{ ev.kind, ev.first_option });
            _ = try game.commands.execute(gs, .{ .resolve_decision = .{ .event = ev.event, .choice = 0 } });
            answered_one = true;
        };
        if (!running) break;
    }

    // The tour ended, but the company is still out there. Bring
    // it home (an idle recall is free; a mid-contract recall is a breach).
    std.debug.print("\n--- contract control ---\n", .{});
    printContracts(gs, al) catch |err| showError(err);
    _ = game.commands.execute(gs, .{ .recall_company = co }) catch |err| std.debug.print("recall refused: {s}\n", .{game.cli.errorText(err)});
    while (!q.companyAtHome(gs, co)) _ = try game.commands.execute(gs, .{ .advance_days = 5 });

    // The rotation arc — come home worn, rest, heal, train.
    std.debug.print("\n--- tour over: readiness on return ---\n", .{});
    printReadiness(gs, al) catch |err| showError(err);
    // The desk on return — assignments, the medbay, and what
    // the checklist would stop you on before the next turn.
    printLines(al, try q.companyRoster(al, gs, co), "") catch |err| showError(err);
    printLines(al, try q.medbay(al, gs), "") catch |err| showError(err);
    if (printChecklist(gs, al) == 0) std.debug.print("END-TURN CHECKLIST: all clear.\n", .{});

    // Send the highest-XP healthy mekwarrior to gunnery school, then rest
    // the company for two months at home.
    var best: ?q.PersonRow = null;
    for ((try q.people(al, gs, .combat)).rows) |row| {
        if (row.role != .mekwarrior or !row.active) continue;
        if (best == null or row.xp > best.?.xp) best = row;
    }
    if (best) |row| {
        const who = (try q.personLine(al, gs, row.id)) orelse "";
        if (game.commands.execute(gs, .{ .train = .{ .person = row.id, .skill = .piloting_mek } })) |_| {
            std.debug.print("\n{s} ({d} xp) reports to the training ground.\n", .{ who, row.xp });
        } else |err| {
            std.debug.print("\ntraining refused for {s}: {s}\n", .{ who, game.cli.errorText(err) });
        }
    }
    _ = try game.commands.execute(gs, .{ .advance_days = 60 });

    std.debug.print("\n--- after two months of rest and refit ---\n", .{});
    printReadiness(gs, al) catch |err| showError(err);

    // Into the lab. Swap the first mek's first weapon for a small
    // laser off the staples shelf — a class-B, like-for-like refit the
    // level-1 bay can do.
    std.debug.print("\n--- the MekLab ---\n", .{});
    var lab_uid: game.types.UnitId = .none;
    for (try q.toeFiltered(al, gs, .{ .company = co })) |row| if (row.unit != .none) {
        lab_uid = row.unit;
        break;
    };
    if (lab_uid != .none) {
        const lab = try q.lab(al, gs, lab_uid);
        // The HQ buys the part off its own board — so fund the HQ first
        // (its treasury has been paying for the warehouse and the bays).
        _ = game.commands.execute(gs, .{ .transfer = .{ .from = .outfit, .to = .{ .hq = seat }, .amount = 3_000_000 } }) catch |err| std.debug.print("transfer refused: {s}\n", .{game.cli.errorText(err)});
        _ = try game.commands.execute(gs, .{ .advance_days = 3 });
        if (q.listingIndex(gs, "slas", true)) |i| {
            _ = game.commands.execute(gs, .{ .buy_listing = i }) catch |err| std.debug.print("buy refused: {s}\n", .{game.cli.errorText(err)});
        }
        if (lab.mounts.len > 0) {
            const m = lab.mounts[0];
            _ = game.commands.execute(gs, .{ .refit_remove = .{ .unit = lab_uid, .slot_key = m.slot_key } }) catch |err| std.debug.print("refit remove refused: {s}\n", .{game.cli.errorText(err)});
            _ = game.commands.execute(gs, .{ .refit_install = .{ .unit = lab_uid, .location = m.location orelse .ra, .part_key = "slas" } }) catch |err| std.debug.print("refit install refused: {s}\n", .{game.cli.errorText(err)});
        }
        printLab(gs, al, lab_uid) catch |err| showError(err);
        if (game.commands.execute(gs, .{ .refit_commit = lab_uid })) |_| {
            _ = try game.commands.execute(gs, .{ .advance_days = 10 });
            std.debug.print("after the bay:\n", .{});
            printLab(gs, al, lab_uid) catch |err| showError(err);
        } else |err| std.debug.print("refit refused: {s}\n", .{game.cli.errorText(err)});
    }

    // The beachhead loop. The contract planet is a place the
    // outfit has worked — found a field HQ there, fund it, link it home, and
    // start the long project that turns a toehold into a ring.
    std.debug.print("\n--- the network: beachhead → field HQ → regional ---\n", .{});
    const worked = q.firstContractPlanet(gs) orelse "";
    if (game.commands.execute(gs, .{ .found_hq = .{ .name = "Firebase Kalmar", .planet_key = worked } })) |_| {
        const hqs = try q.hqList(al, gs);
        const fb = hqs[hqs.len - 1].id;
        // The upgrade is only worth waiting on once its money is on the
        // road: without the courier the outfit would sit out a quarter's
        // payroll for a build it cannot pay for.
        if (game.commands.execute(gs, .{ .transfer = .{ .from = .outfit, .to = .{ .hq = fb }, .amount = 3_500_000 } })) |_| {
            _ = try game.commands.execute(gs, .{ .link = .{ .a = seat, .b = fb, .level = 1 } });
            _ = try game.commands.execute(gs, .{ .advance_days = 30 }); // the courier arrives
            _ = game.commands.execute(gs, .{ .upgrade_tier = fb }) catch |err| std.debug.print("tier upgrade refused: {s}\n", .{game.cli.errorText(err)});
            _ = try game.commands.execute(gs, .{ .advance_days = 95 }); // unstaffed paperwork (21) + 60-day build
            _ = try game.commands.execute(gs, .{ .autostaff = fb }); // a ring needs a back office
            if (game.commands.execute(gs, .{ .new_company_at = .{ .name = "Bravo Company", .hq = fb } })) |_| {
                std.debug.print("Bravo Company stood up at the new regional HQ.\n", .{});
            } else |err| std.debug.print("second company refused: {s}\n", .{game.cli.errorText(err)});
        } else |err| std.debug.print("courier refused: {s} — the firebase stays a toehold\n", .{game.cli.errorText(err)});
        printHqs(gs, al) catch |err| showError(err);
        printLines(al, try q.logLines(al, gs, 5, .{ .category = .construction }), "  ") catch |err| showError(err);
    } else |err| std.debug.print("founding refused: {s}\n", .{game.cli.errorText(err)});

    std.debug.print("\nCampaign log (last 12):\n", .{});
    printLines(al, try q.logLines(al, gs, 12, .all), "  ") catch |err| showError(err);

    // Money lives in places. Books per entity.
    std.debug.print("\n--- treasuries & per-entity books ---\n", .{});
    printTreasuries(gs, al) catch |err| showError(err);
    const st = try q.status(al, gs);
    printLines(al, try q.pnlLines(al, gs, 0, st.day, .{ .hq = seat }), "") catch |err| showError(err);
    printLines(al, try q.pnlLines(al, gs, 0, st.day, .{ .company = co }), "") catch |err| showError(err);
    std.debug.print("Battle log for company {d} only:\n", .{@intFromEnum(co)});
    printLines(al, try q.logLines(al, gs, 6, .{ .category = .battle }), "  ") catch |err| showError(err);
    std.debug.print("\nStores on return:\n", .{});
    printSupplies(gs, al) catch |err| showError(err);
    printDemand(gs, al) catch |err| showError(err);
    std.debug.print("\nHQ after the tour:\n", .{});
    printProjects(gs, al) catch |err| showError(err);
    printBays(gs, al) catch |err| showError(err);
    printStaff(gs, al) catch |err| showError(err);

    // The hangar after months in the field — quality drift, broken
    // slots, and the spares pipeline.
    std.debug.print("\n{s}\n", .{try q.hangarSummaryLine(al, gs)});

    std.debug.print("\n", .{});
    printLines(al, try q.pnlLines(al, gs, 0, st.day, .all), "") catch |err| showError(err);
    std.debug.print("State hash (golden master): {x}\n", .{gs.hash()});
    std.debug.print("Run with `zig build run -- --repl` for the interactive loop.\n", .{});
}

/// The MekLab view: the same query the client's Lab screen draws.
fn printLab(gs: *game.state.GameState, al: std.mem.Allocator, uid: game.types.UnitId) !void {
    const view = try q.lab(al, gs, uid);
    std.debug.print("LAB {s}\n", .{q.stripMarks(al, view.title) catch view.title});
    printLines(al, view.budget, "  ") catch |err| showError(err);
    std.debug.print("  mounts:\n", .{});
    for (view.mounts) |m| std.debug.print("    {s}\n", .{q.stripMarks(al, m.text) catch m.text});
    printLines(al, view.plan, "  ") catch |err| showError(err);
    std.debug.print("  RULES: {s}\n", .{if (view.legal) "legal fit." else "ILLEGAL"});
}

/// Contracts with their win condition and where the companies stand.
fn printContracts(gs: *game.state.GameState, al: std.mem.Allocator) !void {
    printLines(al, q.contractLines(al, gs) catch return, "") catch |err| showError(err);
}

fn printHqs(gs: *game.state.GameState, al: std.mem.Allocator) !void {
    for (try q.hqList(al, gs)) |row| {
        std.debug.print("{s}\n", .{row.title_line});
        printLines(al, q.hqCompanies(al, gs, row.id) catch continue, "    ") catch |err| showError(err);
    }
    printLines(al, q.hqLinks(al, gs) catch return, "  ") catch |err| showError(err);
}

fn printOffers(gs: *game.state.GameState, al: std.mem.Allocator) !void {
    const c = try q.contracts(al, gs, .none);
    std.debug.print("Contract board ({d} offers):\n", .{c.board.len});
    printTable(al, q.board_cols, c.board, "  ") catch |err| showError(err);
    std.debug.print("  (* = beachhead: premium pay, hardship costs, slow resupply · `candidates <offer#>` ranks the companies that could go)\n", .{});
}

fn printToe(gs: *game.state.GameState, al: std.mem.Allocator) !void {
    const st = try q.status(al, gs);
    _ = st;
    for (try q.toe(al, gs)) |row| std.debug.print("{s}\n", .{q.stripMarks(al, row.text) catch row.text});
    std.debug.print("{s}\n", .{try q.payrollLine(al, gs)});
}

/// The per-company readiness report (ARCH §9.7): the P&L's companion —
/// profit is meaningless if the force that earned it is spent.
fn printReadiness(gs: *game.state.GameState, al: std.mem.Allocator) !void {
    const rows = try q.readiness(al, gs);
    printTable(al, q.readiness_cols, rows, "") catch |err| showError(err);
    for (rows) |r| {
        const name = q.forceName(al, gs, r.company) catch "—";
        std.debug.print("\n[{d}] {s}\n", .{ @intFromEnum(r.company), q.stripMarks(al, name) catch name });
        printLines(al, q.readinessLines(al, gs, r.company) catch continue, "  ") catch |err| showError(err);
    }
}

/// The Dragoons rating with its parts.
fn printRating(gs: *game.state.GameState, al: std.mem.Allocator) !void {
    const r = try q.rating(al, gs);
    std.debug.print("Dragoons rating {s} ({d})\n", .{ r.letter, r.score });
    for (r.parts) |p| std.debug.print("  {s: <14} {d: >4}   {s}\n", .{ p.name, p.score, p.note });
}

/// Stocks at every site with tonnage vs. capacity; burn & days-of-supply
/// for deployed companies: the Supply screen's rows.
fn printSupplies(gs: *game.state.GameState, al: std.mem.Allocator) !void {
    printLines(al, (try q.supply(al, gs)).rows, "") catch |err| showError(err);
}

/// Parts needed to fix what's broken: the depot's and the sites' ledgers.
fn printDemand(gs: *game.state.GameState, al: std.mem.Allocator) !void {
    printLines(al, q.demandLines(al, gs) catch return, "") catch |err| showError(err);
}

/// The end-turn checklist. Returns how many warnings printed.
fn printChecklist(gs: *game.state.GameState, al: std.mem.Allocator) usize {
    const d = q.desk(al, gs, 0) catch return 0;
    if (d.checklist.len == 0) return 0;
    std.debug.print("END-TURN CHECKLIST ({d}):\n", .{d.checklist.len});
    for (d.checklist) |w| std.debug.print("  {s} {s}\n", .{ if (w.blocking) "!" else "·", q.stripMarks(al, w.text) catch w.text });
    return d.checklist.len;
}

fn printBays(gs: *game.state.GameState, al: std.mem.Allocator) !void {
    for (try q.hqList(al, gs)) |h| printLines(al, q.bays(al, gs, h.id) catch continue, "") catch |err| showError(err);
}

fn printProjects(gs: *game.state.GameState, al: std.mem.Allocator) !void {
    for (try q.hqList(al, gs)) |h| printLines(al, q.projects(al, gs, h.id) catch continue, "") catch |err| showError(err);
}

/// The back office: posted admins by role.
fn printStaff(gs: *game.state.GameState, al: std.mem.Allocator) !void {
    for (try q.hqList(al, gs)) |h| {
        std.debug.print("hq:{d} {s} back office:\n", .{ @intFromEnum(h.id), h.name.terminal(al) catch "?" });
        for (q.backOffice(al, gs, h.id) catch continue) |row| {
            std.debug.print("    {s:<16} x{d:<3} of {d} best skill {d}\n", .{ @tagName(row.role), row.have, row.need, row.best_skill });
        }
    }
}

fn printTreasuries(gs: *game.state.GameState, al: std.mem.Allocator) !void {
    const led = try q.ledger(al, gs, .outfit, 31, 0);
    printTable(al, q.treasury_cols, led.treasuries, "") catch |err| showError(err);
    printLines(al, led.extras, "") catch |err| showError(err);
}

fn printStatus(gs: *game.state.GameState, al: std.mem.Allocator) !void {
    const st = try q.status(al, gs);
    std.debug.print("{s} (day {d}) | funds {s} | rep {d} | people {d} | hulls {d} | inbox {d} | checklist {d} ({d} blocking)\n", .{
        st.date, st.day, st.funds, st.reputation, st.people, st.hulls, st.inbox, st.checklist, st.blocking,
    });
}

fn runRepl(gs: *game.state.GameState, io: std.Io, gpa: std.mem.Allocator, store_path: [:0]const u8) !void {
    // The save store: one file, many campaigns.
    var lobby = game.lobby.Lobby.open(store_path) catch |err| {
        std.debug.print("could not open save store '{s}': {s}\n", .{ store_path, game.cli.errorText(err) });
        return err;
    };
    defer lobby.close();
    std.debug.print("save store: {s}\n", .{store_path});
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        printCampaigns(lobby, arena.allocator()) catch |err| showError(err);
        std.debug.print(
            \\=== IRON LEDGER — command console ===
            \\          save | campaigns | load <id> | delete <id> | new (fresh campaign) | quit
            \\views:    status | toe | hqs | offers | contracts | roster [co:<id>|hq:<id>] | medbay | hall [filter]
            \\          checklist | inbox | battles [id] | log [n] [filter] | pnl | ledger | treasuries | units | parts | orders | sop | candidates <offer#>
            \\          shop | supplies | demand | bays | projects | staff | lab <unit> | readiness | rating | summary | manning co:<id>
            \\          briefing <contract id>   (battle orders before contact: `confirm`, `rush`, `roe`, `role`)
            \\turn:     day [n] [force]   (the checklist gates it)
            \\commands: `help` lists every verb with its usage — the same verbs the TUI's `:` line takes
            \\factions: LC DC FS CC FWL — professions: quartermaster paymaster chief_engineer line_officer
            \\data:     {s}
            \\
        , .{game.dataProvenance(arena.allocator()) catch "stock tables (data/)"});
    }

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
    const in = &stdin_reader.interface;

    while (true) {
        std.debug.print("> ", .{});
        const line = (try in.takeDelimiter('\n')) orelse break;
        var tokens = std.mem.tokenizeScalar(u8, line, ' ');
        const verb = tokens.next() orelse continue;

        if (std.mem.eql(u8, verb, "quit")) break;

        // Every view is drawn from a per-line arena: the queries fill it,
        // the console prints it, the line ends, it is gone.
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const al = arena.allocator();

        if (std.mem.eql(u8, verb, "save")) {
            lobby.save(gs, 0) catch |err| {
                std.debug.print("save failed: {s}\n", .{game.cli.errorText(err)});
                continue;
            };
            const st = try q.status(al, gs);
            std.debug.print("saved campaign \"{s}\" at day {d}\n", .{ st.outfit_name.terminal(al) catch "?", st.day });
        } else if (std.mem.eql(u8, verb, "campaigns")) {
            printCampaigns(lobby, al) catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "load")) {
            const id = std.fmt.parseInt(i64, tokens.next() orelse "", 10) catch {
                std.debug.print("usage: load <campaign id>  (see `campaigns`)\n", .{});
                continue;
            };
            const loaded = lobby.load(gpa, id) catch |err| {
                std.debug.print("load failed: {s}\n", .{game.cli.errorText(err)});
                continue;
            };
            game.lobby.discard(gs);
            gs.* = loaded;
            std.debug.print("loaded campaign [{d}] \"{s}\"\n", .{ id, try (try q.status(al, gs)).outfit_name.terminal(al) });
            printStatus(gs, al) catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "delete")) {
            const id = std.fmt.parseInt(i64, tokens.next() orelse "", 10) catch {
                std.debug.print("usage: delete <campaign id>\n", .{});
                continue;
            };
            lobby.deleteCampaign(id, gs) catch |err| {
                std.debug.print("delete failed: {s}\n", .{game.cli.errorText(err)});
                continue;
            };
            std.debug.print("deleted campaign [{d}]\n", .{id});
            printCampaigns(lobby, al) catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "new")) {
            const st = try q.status(al, gs);
            const seed: u64 = @as(u64, st.day) + st.people + 1;
            gs.deinit();
            gs.* = game.state.GameState.init(gpa, .{ .seed = 3025 + seed });
            std.debug.print("fresh campaign — `start <faction> <profession> <name>` to begin\n", .{});
        } else if (std.mem.eql(u8, verb, "status")) {
            printStatus(gs, al) catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "roster")) {
            const site: ?game.types.Site = if (tokens.next()) |tok| (game.cli.parseSite(tok) catch null) else null;
            if (site) |s| switch (s) {
                .company => |id| printLines(al, try q.companyRoster(al, gs, id), "") catch |err| showError(err),
                .hq => |id| printLines(al, try q.hqRoster(al, gs, id), "") catch |err| showError(err),
                .outfit => printTable(al, q.people_cols, (try q.people(al, gs, .all)).rows, "") catch |err| showError(err),
            } else printTable(al, q.people_cols, (try q.people(al, gs, .all)).rows, "") catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "medbay")) {
            printLines(al, try q.medbay(al, gs), "") catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "hall")) {
            const filter = if (tokens.next()) |t| std.meta.stringToEnum(q.HallFilter, t) orelse {
                std.debug.print("usage: hall [all|combat|techs|medical|admin_command|admin_logistics|admin_transport|admin_hr|admin_finance|other]\n", .{});
                continue;
            } else q.HallFilter.all;
            const lines = try q.hallAll(al, gs, filter);
            if (lines.len == 0) std.debug.print("no candidates on any board.\n", .{}) else printLines(al, lines, "") catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "checklist")) {
            if (printChecklist(gs, al) == 0) std.debug.print("all clear.\n", .{});
        } else if (std.mem.eql(u8, verb, "toe")) {
            printToe(gs, al) catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "hqs")) {
            printHqs(gs, al) catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "offers")) {
            printOffers(gs, al) catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "candidates")) {
            const idx = std.fmt.parseInt(usize, tokens.next() orelse "0", 10) catch 0;
            printTable(al, q.candidates_cols, try q.offerCandidates(al, gs, idx), "") catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "readiness")) {
            printReadiness(gs, al) catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "rating")) {
            printRating(gs, al) catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "summary")) {
            printLines(al, try q.summary(al, gs), "") catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "inbox")) {
            printLines(al, try q.inboxLines(al, gs), "") catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "battles")) {
            // battles           — the engagements still on record
            // battles <id>      — that one's after-action, in full
            if (tokens.next()) |tok| {
                const id: game.types.BattleId = @enumFromInt(std.fmt.parseInt(u32, tok, 10) catch 0);
                if (try q.battleReport(al, gs, id)) |lines| {
                    printLines(al, lines, "") catch |err| showError(err);
                } else {
                    std.debug.print("no engagement on record with that id — `battles` lists them\n", .{});
                }
            } else {
                const rows = try q.battleList(al, gs);
                if (rows.len == 0) {
                    std.debug.print("no engagements on record yet.\n", .{});
                } else {
                    std.debug.print("AFTER-ACTION REPORTS ({d} on record, newest first — `battles <id>` reads one):\n", .{rows.len});
                    printTable(al, q.battle_cols, rows, "  ") catch |err| showError(err);
                }
            }
        } else if (std.mem.eql(u8, verb, "log")) {
            // log [n] [filter] — filter: outfit-wide default, a category name,
            // or co:<id> / hq:<id> for one entity's full history.
            var n: usize = 10;
            var filter: game.state.LogFilter = .all;
            while (tokens.next()) |tok| {
                if (std.fmt.parseInt(usize, tok, 10)) |v| {
                    n = v;
                } else |_| if (std.meta.stringToEnum(game.state.LogCategory, tok)) |cat| {
                    filter = .{ .category = cat };
                } else if (std.mem.startsWith(u8, tok, "contract:")) {
                    // Every AAR and event of one contract, past or present.
                    filter = .{ .contract = @enumFromInt(std.fmt.parseInt(u32, tok[9..], 10) catch 0) };
                } else if (game.cli.parseTreasury(tok)) |t| {
                    filter = switch (t) {
                        .company => |id| .{ .company = id },
                        .hq => |id| .{ .hq = id },
                        .outfit => .all,
                    };
                } else |_| {
                    std.debug.print("usage: log [n] [battle|decision|delivery|...|co:<id>|hq:<id>|contract:<id>]\n", .{});
                }
            }
            printLines(al, try q.logLines(al, gs, n, filter), "  ") catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "sop") and tokens.peek() == null) {
            printLines(al, try q.standingOrders(al, gs), "") catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "treasuries")) {
            printTreasuries(gs, al) catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "ledger")) {
            // ledger [co:<id>|hq:<id>] [n]
            var filter: game.finance.EntityFilter = .all;
            var n: usize = 15;
            while (tokens.next()) |tok| {
                if (game.cli.parseTreasury(tok)) |t| {
                    filter = switch (t) {
                        .company => |id| .{ .company = id },
                        .hq => |id| .{ .hq = id },
                        .outfit => .all,
                    };
                } else |_| n = std.fmt.parseInt(usize, tok, 10) catch n;
            }
            printLines(al, try q.ledgerLines(al, gs, filter, n), "  ") catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "units")) {
            const rows = try q.hangar(al, gs);
            std.debug.print("hangar ({d} hulls, worst value first — bill per point of contribution):\n", .{rows.len});
            printTable(al, q.hangar_cols, rows, "  ") catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "parts")) {
            std.debug.print("spares:\n", .{});
            printLines(al, try q.spareLines(al, gs), "  ") catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "orders")) {
            printLines(al, try q.orders(al, gs), "  ") catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "lab")) {
            const uid = std.fmt.parseInt(u32, tokens.next() orelse "", 10) catch 0;
            if (uid == 0) {
                std.debug.print("usage: lab <unit id>\n", .{});
                continue;
            }
            printLab(gs, al, @enumFromInt(uid)) catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "contracts")) {
            printContracts(gs, al) catch |err| showError(err);
            std.debug.print("standing:\n", .{});
            printLines(al, try q.standings(al, gs), "") catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "bays")) {
            printBays(gs, al) catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "projects")) {
            printProjects(gs, al) catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "staff")) {
            printStaff(gs, al) catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "supplies")) {
            printSupplies(gs, al) catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "demand")) {
            printDemand(gs, al) catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "shop")) {
            const lines = try q.listings(al, gs);
            std.debug.print("site market ({d} listings):\n", .{lines.len});
            printLines(al, lines, "  ") catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "pnl")) {
            // pnl [co:<id>|hq:<id>] — last 31 days for the outfit or one entity.
            const st = try q.status(al, gs);
            const from = if (st.day > 31) st.day - 31 else 0;
            var filter: game.finance.EntityFilter = .all;
            if (tokens.next()) |tok| {
                if (game.cli.parseTreasury(tok)) |t| {
                    filter = switch (t) {
                        .company => |id| .{ .company = id },
                        .hq => |id| .{ .hq = id },
                        .outfit => .all,
                    };
                } else |_| {}
            }
            printLines(al, try q.pnlLines(al, gs, from, st.day, filter), "") catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "day")) {
            // day [n] [force] — the end-turn checklist gates the advance:
            // fix it, or `day force` to proceed regardless.
            var n: u32 = 1;
            var force = false;
            while (tokens.next()) |t| {
                if (std.mem.eql(u8, t, "force") or std.mem.eql(u8, t, "!")) {
                    force = true;
                } else n = std.fmt.parseInt(u32, t, 10) catch n;
            }
            if (!force and printChecklist(gs, al) > 0) {
                std.debug.print("turn not ended — address the checklist or `day {d} force`\n", .{n});
                continue;
            }
            const r = game.commands.execute(gs, .{ .advance_days = n }) catch |err| {
                // The one error→sentence table (rule 6), not the enum name.
                std.debug.print("blocked: {s}\n", .{game.cli.errorText(err)});
                continue;
            };
            std.debug.print("advanced {d} day(s)\n", .{r.days_advanced});
            if (r.contact != .none) std.debug.print("stopped for the contact warning: {s}\n", .{try q.contactWarning(al, gs, r.contact)});
            printStatus(gs, al) catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "manning")) {
            const site = game.cli.parseSite(tokens.next() orelse "") catch null;
            if (site == null or site.? != .company) {
                std.debug.print("usage: manning co:<id>\n", .{});
                continue;
            }
            printTable(al, q.manning_cols, try q.manning(al, gs, site.?.company), "") catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "briefing")) {
            const id = std.fmt.parseInt(u32, tokens.next() orelse "", 10) catch {
                std.debug.print("usage: briefing <contract id>\n", .{});
                continue;
            };
            const view = (try q.battleOrders(al, gs, @enumFromInt(id))) orelse {
                std.debug.print("{s}\n", .{game.cli.errorText(error.NoContact)});
                continue;
            };
            printBattleOrders(al, view) catch |err| showError(err);
        } else if (std.mem.eql(u8, verb, "help") or std.mem.eql(u8, verb, "?")) {
            for (game.cli.verbs) |v| std.debug.print("  {s}\n", .{game.cli.usage(v) orelse v});
        } else {
            // Every command verb goes through the parser both frontends share.
            const parsed = game.cli.parseCommand(verb, &tokens) catch |err| {
                std.debug.print("{s} — usage: {s}\n", .{ game.cli.errorText(err), game.cli.usage(verb) orelse verb });
                continue;
            };
            const cmd = parsed orelse {
                std.debug.print("unknown command '{s}' — `help` lists the verbs\n", .{verb});
                continue;
            };
            const r = game.commands.execute(gs, cmd) catch |err| {
                std.debug.print("refused: {s}\n", .{game.cli.errorText(err)});
                if (err == error.IllegalFit) if (refitUnit(cmd)) |u| printLab(gs, al, u) catch |print_err| showError(print_err);
                continue;
            };
            printResult(gs, al, cmd, r) catch |err| showError(err);
        }
    }
}

fn refitUnit(cmd: Command) ?game.types.UnitId {
    return switch (cmd) {
        .refit_install => |x| x.unit,
        .refit_remove => |x| x.unit,
        .refit_clear => |u| u,
        .refit_commit => |u| u,
        else => null,
    };
}

/// What the REPL says after a command lands: ids created, hires, hulls
/// bought, and the screen the verb naturally leads to.
/// The battle orders as console lines (the TUI's box reads the same query).
fn printBattleOrders(al: std.mem.Allocator, view: q.BattleOrders) !void {
    std.debug.print("{s}{s}\n", .{ q.stripMarks(al, view.title) catch view.title, if (view.confirmed) " — orders given" else "" });
    printLines(al, view.situation, "  ") catch |err| showError(err);
    std.debug.print("  ROE {s}{s}\n", .{ @tagName(view.roe), if (view.roe_locked) " (set by integrated command)" else "" });
    for (view.lances) |l| std.debug.print("  lance {d}: {s}\n", .{ @intFromEnum(l.force), q.stripMarks(al, l.text) catch l.text });
    if (view.rush.len > 0) std.debug.print("  emergency resupply: {s}\n", .{q.stripMarks(al, view.rush) catch view.rush});
}

fn printResult(gs: *game.state.GameState, al: std.mem.Allocator, cmd: Command, r: game.commands.Result) !void {
    switch (cmd) {
        .create_commander => {
            printHqs(gs, al) catch |err| showError(err);
            printOffers(gs, al) catch |err| showError(err);
        },
        .accept_contract => std.debug.print("{s}\n", .{(q.acceptedLine(al, gs) catch null) orelse "under contract"}),
        .new_company, .new_company_at, .raise_company, .new_lance, .raise_air_company => std.debug.print("created force [{d}] — see `toe`\n", .{@intFromEnum(r.created_force)}),
        .hire, .hire_candidate, .recruit => std.debug.print("hired {s}\n", .{(q.personLine(al, gs, r.hired) catch null) orelse "—"}),
        .crew_company => std.debug.print("{d} hired to fill the manning table, {d} lines still open (no candidates)\n", .{ r.hired_count, r.still_open }),
        .buy_hull_for => if (r.unit == .none) std.debug.print("{s}\n", .{game.cli.hull_fraud_text}) else std.debug.print("hull #{d}, {d} days out\n", .{ @intFromEnum(r.unit), r.eta_days }),
        .trim_stock => std.debug.print("{d} tons sent home\n", .{r.tons_moved}),
        .refit_install, .refit_remove, .refit_clear, .refit_commit => printLab(gs, al, refitUnit(cmd).?) catch |err| showError(err),
        .complete_contract, .recall_company => printContracts(gs, al) catch |err| showError(err),
        .found_hq, .link, .assign_company => printHqs(gs, al) catch |err| showError(err),
        .auto_assign => |co| printLines(al, q.companyRoster(al, gs, co) catch &.{}, "") catch |err| showError(err),
        .autostaff => |hq| printLines(al, q.hqRoster(al, gs, hq) catch &.{}, "") catch |err| showError(err),
        .order_part => std.debug.print("{s}\n", .{(q.lastOrderLine(al, gs) catch null) orelse "ordered"}),
        .take_loan => |l| std.debug.print("drew {d} c-bills over {d} months\n", .{ l.principal, l.term_months }),
        .strip_unit => std.debug.print("{s}\n", .{q.stripMarks(al, (q.lastLogLine(al, gs) catch null) orelse "stripped") catch "stripped"}),
        .confirm_orders => std.debug.print("battle orders given — the contact warning is cleared\n", .{}),
        .emergency_resupply => std.debug.print("emergency resupply: {d}t delivered to the field stores\n", .{r.tons_moved}),
        else => std.debug.print("done.\n", .{}),
    }
}

/// A REPL view that could not be printed says why instead of stopping short.
fn showError(err: anyerror) void {
    std.debug.print("could not show that: {s}\n", .{game.cli.errorText(err)});
}
