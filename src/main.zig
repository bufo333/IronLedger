//! CLI entry point (application layer). Scripted demo by default; pass
//! `--repl` (`zig build run -- --repl`) for an interactive command loop,
//! or `--tui` for the terminal client (Stage 12, src/tui/). The CLI stays
//! the scripting/debug interface.

test {
    _ = @import("tui/screen.zig");
    _ = @import("tui/app.zig");
    _ = @import("tui/png.zig");
    _ = @import("tui/emblem.zig");
}

const std = @import("std");
const game = @import("game");

const Command = game.commands.Command;

pub fn main(init: std.process.Init) !void {
    var gs = game.state.GameState.init(init.gpa, .{ .seed = 3025 });
    defer gs.deinit();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // exe name
    var repl = false;
    var tui = false;
    var store_path: [:0]const u8 = "campaigns.db";
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--repl")) repl = true;
        if (std.mem.eql(u8, arg, "--tui")) tui = true;
        if (std.mem.eql(u8, arg, "--store")) store_path = args.next() orelse store_path;
    }

    if (tui) {
        try @import("tui/app.zig").run(init.io, init.gpa, store_path);
    } else if (repl) {
        try runRepl(&gs, init.io, init.gpa, store_path);
    } else {
        try runDemo(&gs);
    }
}

fn printCampaigns(store: game.store.Store) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const list = store.listCampaigns(arena.allocator()) catch {
        std.debug.print("could not read the campaign registry\n", .{});
        return;
    };
    if (list.len == 0) {
        std.debug.print("no saved campaigns.\n", .{});
        return;
    }
    std.debug.print("campaigns (most recently saved first):\n", .{});
    for (list) |c| {
        std.debug.print("  [{d}] {s} — commander {s} — {s} (day {d})\n", .{ c.id, c.name, c.commander, c.date, c.day });
    }
}

fn runDemo(gs: *game.state.GameState) !void {
    std.debug.print("=== BattleTech Mercenary Command — Stage 4 demo ===\n\n", .{});

    // Character creation: a Capellan ex-quartermaster stands up shop at home.
    _ = try game.commands.execute(gs, .{ .create_commander = .{
        .name = "Erik Kalmar",
        .origin = .CC,
        .profession = .quartermaster,
    } });
    _ = try game.commands.execute(gs, .{ .rename_outfit = "Kalmar's Free Legion" });
    const co = (try game.commands.execute(gs, .{ .new_company = "Alpha Company" })).created_force;

    const cmdr = gs.commander.?;
    printHqs(gs);
    std.debug.print("Commander {s} ({s}, ex-{s}: {s})\n", .{
        cmdr.name, cmdr.origin.fullName(), @tagName(cmdr.profession), cmdr.profession.description(),
    });
    std.debug.print("Roster {d} | payroll {d}/mo | hull upkeep {d}/mo\n\n", .{
        gs.people.count(), gs.monthlyPayroll(), totalHullUpkeep(gs),
    });

    printOffers(gs);

    // Hunt the monthly boards for combat-class work (the Stage 7 demo:
    // a raid start-to-finish, battles resolved hands-off).
    var pick: ?usize = null;
    var hunts: u32 = 0;
    while (pick == null and hunts < 8) : (hunts += 1) {
        // Prefer in-ring combat work; take a beachhead raid over waiting.
        for (gs.contract_offers.items, 0..) |offer, i| {
            if (!offer.kind.isGarrisonClass() and !offer.beachhead) {
                pick = i;
                break;
            }
        }
        if (pick == null) {
            for (gs.contract_offers.items, 0..) |offer, i| {
                if (!offer.kind.isGarrisonClass()) {
                    pick = i;
                    break;
                }
            }
        }
        if (pick == null) _ = try game.commands.execute(gs, .{ .advance_days = 30 });
    }
    const idx = pick orelse 0;
    const chosen_kind = gs.contract_offers.items[idx].kind;
    const chosen_planet = gs.contract_offers.items[idx].planet_key;
    _ = try game.commands.execute(gs, .{ .accept_contract = .{ .offer_index = idx, .company = co } });
    const c = gs.contracts.values()[0];
    std.debug.print("\nAccepted: {s} on {s} — {d} months, {d}/mo net, {d} days transit\n", .{
        @tagName(chosen_kind), game.planet.find(chosen_planet).?.name,
        c.terms.length_months, c.monthly_net, c.transit_days,
    });

    // Stage 9A: fund the deployment — an initial courier plus a standing
    // top-up policy so the company can pay its suppliers in the field.
    _ = try game.commands.execute(gs, .{ .transfer = .{ .from = .outfit, .to = .{ .company = co }, .amount = 300_000 } });
    _ = try game.commands.execute(gs, .{ .set_policy = .{ .entity = .{ .company = co }, .floor = 200_000, .monthly_cap = 400_000 } });
    std.debug.print("Dispatched 300k operating funds by courier; standing policy: top up to 200k monthly.\n", .{});
    std.debug.print("\nStores at departure (Stage 9B):\n", .{});
    printSupplies(gs);

    // Stage 9C: the HQ works while the company is away — capital by
    // courier for a warehouse expansion (1.6M; the HQ opened with 1M), and
    // two side torsos fabricated for the inevitable.
    _ = try game.commands.execute(gs, .{ .transfer = .{ .from = .outfit, .to = .{ .hq = gs.hqs.keys()[0] }, .amount = 2_000_000 } });
    _ = try game.commands.execute(gs, .{ .advance_days = 3 }); // the courier's three days of paperwork
    _ = game.commands.execute(gs, .{ .upgrade_facility = .{ .hq = gs.hqs.keys()[0], .kind = .warehouse } }) catch |err| {
        std.debug.print("upgrade refused: {s}\n", .{@errorName(err)});
    };
    _ = game.commands.execute(gs, .{ .fabricate = .{ .hq = gs.hqs.keys()[0], .part_key = "comp_torso", .quantity = 2 } }) catch |err| {
        std.debug.print("fabrication refused: {s}\n", .{@errorName(err)});
    };
    std.debug.print("\nHQ operations queued:\n", .{});
    printProjects(gs);
    printBays(gs);

    // Run it month by month until completion (report capped at a year).
    // Turn-based: decisions land in the inbox; the demo answers the first
    // one by hand and lets later ones default at their deadlines.
    var answered_one = false;
    for (0..12) |month| {
        _ = try game.commands.execute(gs, .{ .advance_days = 30 });
        const status = gs.contracts.values()[0].status;
        const pending = gs.event_queue.pending.items.len;

        // Stage 9B: keep the field stores fed — monthly reload orders shipped
        // to the company (paid by the HQ, freight included), refused if the
        // trucks are already full.
        if (status == .active) {
            var ordered: u32 = 0;
            for (game.part.munition_keys) |key| {
                if (game.commands.execute(gs, .{ .order_part = .{ .part_key = key, .quantity = 3, .dest = .{ .company = co } } })) |_| {
                    ordered += 3;
                } else |_| {}
            }
            _ = game.commands.execute(gs, .{ .order_part = .{ .part_key = "provisions", .quantity = 15, .dest = .{ .company = co } } }) catch {};
            if (ordered > 0) std.debug.print("        resupply ordered: {d}t munitions + provisions to the field\n", .{ordered});
        }
        std.debug.print("  month {d:>2}: funds {d:>9} ({s}){s}\n", .{
            month + 1, gs.funds, @tagName(status),
            if (pending > 0) " — decision in inbox" else "",
        });
        if (!answered_one and pending > 0) {
            const ev = gs.event_queue.pending.items[0];
            std.debug.print("        answering [{s}] with option 0: \"{s}\"\n", .{
                @tagName(ev.kind), ev.options[0].label,
            });
            _ = try game.commands.execute(gs, .{ .resolve_decision = .{ .event_index = 0, .choice = 0 } });
            answered_one = true;
        }
        if (status == .completed) break;
    }

    // Stage 9E: the tour ended, but the company is still out there. Bring
    // it home (an idle recall is free; a mid-contract recall is a breach).
    std.debug.print("\n--- contract control ---\n", .{});
    printContracts(gs);
    _ = game.commands.execute(gs, .{ .recall_company = co }) catch |err| std.debug.print("recall refused: {s}\n", .{@errorName(err)});
    while (!gs.isCompanyHome(co)) _ = try game.commands.execute(gs, .{ .advance_days = 5 });

    // Stage 8: the rotation arc — come home worn, rest, heal, train.
    std.debug.print("\n--- tour over: readiness on return ---\n", .{});
    printReadiness(gs);
    // Stage 9C.2: the desk on return — assignments, the medbay, and what
    // the checklist would stop you on before the next turn.
    printCompanyRoster(gs, co);
    printMedbay(gs);
    if (printChecklist(gs) == 0) std.debug.print("END-TURN CHECKLIST: all clear.\n", .{});

    // Send the highest-XP healthy mekwarrior to gunnery school, then rest
    // the company for two months at home.
    var best: ?*game.person.Person = null;
    var pit2 = gs.people.iterator();
    while (pit2.next()) |entry| {
        const p = entry.value_ptr;
        if (p.role != .mekwarrior or p.status != .active) continue;
        if (best == null or p.xp > best.?.xp) best = p;
    }
    if (best) |p| {
        if (game.commands.execute(gs, .{ .train = .{ .person = p.id, .skill = .piloting_mek } })) |_| {
            std.debug.print("\n{s} {s} ({d} xp) reports to the training ground.\n", .{ p.first_name, p.last_name, p.xp });
        } else |err| {
            std.debug.print("\ntraining refused for {s} {s}: {s}\n", .{ p.first_name, p.last_name, @errorName(err) });
        }
    }
    _ = try game.commands.execute(gs, .{ .advance_days = 60 });

    std.debug.print("\n--- after two months of rest and refit ---\n", .{});
    printReadiness(gs);

    // Stage 10: into the lab. Swap the first mek's first weapon for a small
    // laser off the staples shelf — a class-B, like-for-like refit the
    // level-1 bay can do.
    std.debug.print("\n--- the MekLab ---\n", .{});
    const first_lance = gs.force(gs.force(co).?.children.items[0]).?;
    const lab_uid = first_lance.units.items[0];
    if (gs.unit(lab_uid)) |lu| {
        var slot_key: []const u8 = "";
        var loc: game.meklab.Location = .ra;
        for (lu.slots.items) |s| {
            if (s.class == .weapon) {
                slot_key = s.slot_key;
                loc = game.meklab.parseLocation(s.slot_key) orelse .ra;
                break;
            }
        }
        // The HQ buys the part off its own board — so fund the HQ first
        // (its treasury has been paying for the warehouse and the bays).
        _ = game.commands.execute(gs, .{ .transfer = .{ .from = .outfit, .to = .{ .hq = gs.hqs.keys()[0] }, .amount = 3_000_000 } }) catch {};
        _ = try game.commands.execute(gs, .{ .advance_days = 3 });
        for (gs.market_listings.items, 0..) |l, i| {
            if (l.staple and std.mem.eql(u8, l.item_key, "slas")) {
                _ = game.commands.execute(gs, .{ .buy_listing = i }) catch |err| std.debug.print("buy refused: {s}\n", .{@errorName(err)});
                break;
            }
        }
        _ = game.commands.execute(gs, .{ .refit_remove = .{ .unit = lab_uid, .slot_key = slot_key } }) catch {};
        _ = game.commands.execute(gs, .{ .refit_install = .{ .unit = lab_uid, .location = loc, .part_key = "slas" } }) catch {};
        printLab(gs, lab_uid);
        if (game.commands.execute(gs, .{ .refit_commit = lab_uid })) |_| {
            _ = try game.commands.execute(gs, .{ .advance_days = 10 });
            std.debug.print("after the bay:\n", .{});
            printLab(gs, lab_uid);
        } else |err| std.debug.print("refit refused: {s}\n", .{@errorName(err)});
    }

    // Stage 9D: the beachhead loop. The contract planet is now a place
    // we've worked — found a field HQ there, fund it, link it home, and
    // start the long project that turns a toehold into a ring.
    std.debug.print("\n--- the network: beachhead → field HQ → regional ---\n", .{});
    const worked = gs.contracts.values()[0].planet_key;
    if (game.commands.execute(gs, .{ .found_hq = .{ .name = "Firebase Kalmar", .planet_key = worked } })) |_| {
        const fb = gs.hqs.keys()[gs.hqs.count() - 1];
        _ = try game.commands.execute(gs, .{ .transfer = .{ .from = .outfit, .to = .{ .hq = fb }, .amount = 3_500_000 } });
        _ = try game.commands.execute(gs, .{ .link = .{ .a = gs.hqs.keys()[0], .b = fb, .level = 1 } });
        _ = try game.commands.execute(gs, .{ .advance_days = 30 }); // the courier arrives
        _ = game.commands.execute(gs, .{ .upgrade_tier = fb }) catch |err| std.debug.print("tier upgrade refused: {s}\n", .{@errorName(err)});
        _ = try game.commands.execute(gs, .{ .advance_days = 95 }); // unstaffed paperwork (21) + 60-day build
        _ = try game.commands.execute(gs, .{ .autostaff = fb }); // a ring needs a back office
        if (game.commands.execute(gs, .{ .new_company_at = .{ .name = "Bravo Company", .hq = fb } })) |_| {
            std.debug.print("Bravo Company stood up at the new regional HQ.\n", .{});
        } else |err| std.debug.print("second company refused: {s}\n", .{@errorName(err)});
        printHqs(gs);
        printLog(gs, 5, .{ .category = .construction });
    } else |err| std.debug.print("founding refused: {s}\n", .{@errorName(err)});

    std.debug.print("\nCampaign log (last 12):\n", .{});
    printLog(gs, 12, .all);

    // Stage 9A: money lives in places. Books per entity.
    std.debug.print("\n--- treasuries & per-entity books ---\n", .{});
    printTreasuries(gs);
    const hq_id = gs.hqs.keys()[0];
    printPnl(gs, 0, gs.clock.day_index, .{ .hq = hq_id });
    printPnl(gs, 0, gs.clock.day_index, .{ .company = co });
    std.debug.print("Battle log for company {d} only:\n", .{@intFromEnum(co)});
    printLog(gs, 6, .{ .category = .battle });
    std.debug.print("\nStores on return:\n", .{});
    printSupplies(gs);
    printDemand(gs);
    std.debug.print("\nHQ after the tour:\n", .{});
    printProjects(gs);
    printBays(gs);
    printStaff(gs);

    // Stage 5: the hangar after months in the field — quality drift, broken
    // slots, and the spares pipeline.
    var quality_counts = [_]u32{0} ** 6;
    var broken_slots: u32 = 0;
    var uit = gs.units.iterator();
    while (uit.next()) |entry| {
        quality_counts[@intFromEnum(entry.value_ptr.quality)] += 1;
        for (entry.value_ptr.slots.items) |s| {
            if (s.condition != .ok) broken_slots += 1;
        }
    }
    std.debug.print("\nHangar quality A-F: {any} | broken slots outstanding: {d} | structure spares: {d}\n", .{
        quality_counts, broken_slots, gs.spareCount("structure"),
    });

    std.debug.print("\n", .{});
    printPnl(gs, 0, gs.clock.day_index, .all);
    std.debug.print("State hash (golden master): {x}\n", .{gs.hash()});
    std.debug.print("Run with `zig build run -- --repl` for the interactive loop.\n", .{});
}

/// The MekLab view (Stage 10): tonnage budget, crits per location, every
/// mount and its state, the staged plan, and what the rules say.
fn printLab(gs: *game.state.GameState, uid: game.types.UnitId) void {
    const u = gs.unit(uid) orelse {
        std.debug.print("no such unit\n", .{});
        return;
    };
    const design = game.chassis.find(u.chassis_key) orelse return;
    if (u.kind != .mek) {
        std.debug.print("#{d} {s} is not a mek — the lab works on BattleMechs.\n", .{ @intFromEnum(uid), design.name });
        return;
    }
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const items = gs.labItems(uid, alloc) catch return;
    const r = game.meklab.validate(design, items, alloc) catch return;

    std.debug.print("LAB #{d} {s} {s} — {d}t, walk {d}{s}, {d} heat sinks, engine {d}\n", .{
        @intFromEnum(uid), design.key, design.name, design.tonnage, design.walk_mp,
        if (design.jump_mp > 0) " (jump)" else "", design.heat_sinks, design.engineRating(),
    });
    std.debug.print("  mass: chassis {d}.{d}t + mounts {d}.{d}t = {d}.{d}t | free {s}{d}.{d}t | alpha heat {d}\n", .{
        r.fixed_half_tons / 2,                    (r.fixed_half_tons % 2) * 5,
        r.loadout_half_tons / 2,                  (r.loadout_half_tons % 2) * 5,
        (r.fixed_half_tons + r.loadout_half_tons) / 2, ((r.fixed_half_tons + r.loadout_half_tons) % 2) * 5,
        if (r.free_half_tons < 0) "-" else "",     @divTrunc(@abs(r.free_half_tons), 2), (@abs(r.free_half_tons) % 2) * 5,
        r.heat_per_alpha,
    });
    std.debug.print("  crits used/free:", .{});
    inline for (@typeInfo(game.meklab.Location).@"enum".fields) |f| {
        std.debug.print(" {s} {d}/{d}", .{ f.name, r.crits_used[f.value], r.crits_free[f.value] });
    }
    std.debug.print("\n  mounts:\n", .{});
    for (u.slots.items) |s| {
        if (s.class == .structure) continue;
        std.debug.print("    {s:<18} {s:<10} {s}\n", .{ s.slot_key, s.part_key, @tagName(s.condition) });
    }
    if (gs.refitPlanFor(uid)) |plan| {
        const class = game.meklab.classify(plan.ops.items, u.slots.items);
        std.debug.print("  PLAN ({s}, class {s}, {d} tech-hours):\n", .{
            if (plan.committed) "committed" else "staged", @tagName(class), game.meklab.refitHours(plan.ops.items, u.slots.items, class),
        });
        for (plan.ops.items) |op| switch (op) {
            .remove => |k| std.debug.print("    - remove {s}\n", .{k}),
            .install => |it| std.debug.print("    + install {s} in {s}\n", .{ it.part_key, @tagName(it.location) }),
        };
    }
    if (r.legal) {
        std.debug.print("  RULES: legal fit.\n", .{});
    } else {
        std.debug.print("  RULES: ILLEGAL —\n", .{});
        for (r.violations) |v| std.debug.print("    ! {s}\n", .{v.text});
    }
    if (gs.hqs.count() > 0) {
        if (gs.hqs.getPtr(gs.homeHqFor(u.force))) |hq| {
            if (hq.refitClassCeiling()) |c| std.debug.print("  bay ceiling at {s}: class {s}\n", .{ hq.name, @tagName(c) });
        }
    }
}

/// Contracts with their win condition (Stage 9E): objective, pool, VP,
/// clock, and any breach exposure.
fn printContracts(gs: *game.state.GameState) void {
    var it = gs.contracts.iterator();
    while (it.next()) |entry| {
        const c = entry.value_ptr;
        const days_left: i64 = if (c.end_day) |e| @as(i64, e) - @as(i64, gs.clock.day_index) else 0;
        std.debug.print("[{d}] {s:<17} {s:<9} co:{d} on {s} | {s} objective", .{
            @intFromEnum(c.id), @tagName(c.kind), @tagName(c.status), @intFromEnum(c.assigned_company), c.planet_key, @tagName(c.objective),
        });
        if (c.objective == .attrition) {
            std.debug.print(" — opposition {d}% destroyed ({d}/{d} BV)", .{ c.poolDestroyedPct(), c.enemy_pool_bv - c.enemy_pool_remaining, c.enemy_pool_bv });
        }
        std.debug.print(" | {d} VP | score {d} | {d} days left{s}{s}\n", .{
            c.victory_points, c.score, @max(0, days_left),
            if (c.ineffective_since != null) " | COMBAT-INEFFECTIVE" else "",
            if (c.objectivesMet() and c.status == .active) " | objectives met — `complete`" else "",
        });
    }
    var fit = gs.forces.iterator();
    while (fit.next()) |fe| {
        const f = fe.value_ptr;
        if (f.echelon != .company) continue;
        if (f.return_eta_day) |eta| {
            std.debug.print("  co:{d} {s} returning home, arrives day {d}\n", .{ @intFromEnum(f.id), f.name, eta });
        } else if (f.location_planet) |p| {
            if (gs.deploymentContract(f.id) == null)
                std.debug.print("  co:{d} {s} idle on {s} — accept work from the field or `recall co:{d}`\n", .{ @intFromEnum(f.id), f.name, p, @intFromEnum(f.id) });
        }
    }
}

fn printHqs(gs: *game.state.GameState) void {
    var it = gs.hqs.iterator();
    while (it.next()) |entry| {
        const hq = entry.value_ptr;
        const world = game.planet.find(hq.planet_key).?;
        const cap = hq.capacity();
        std.debug.print("hq:{d} {s} ({s}) on {s} ({s} space) — ring {d} LY | companies {d}/{d} (≤{d} lances) | funds {d}\n", .{
            @intFromEnum(hq.id), hq.name, @tagName(hq.tier), world.name, world.faction, hq.influenceLy(),
            gs.companiesAtHq(hq.id), cap.combat_companies, cap.lances_per_company, hq.funds,
        });
        var fit = gs.forces.iterator();
        while (fit.next()) |fe| {
            const f = fe.value_ptr;
            if (f.echelon == .company and f.supplying_hq == hq.id)
                std.debug.print("    co:{d} {s}{s}\n", .{ @intFromEnum(f.id), f.name, if (gs.deploymentContract(f.id) != null) " (deployed)" else "" });
        }
    }
    for (gs.hq_links.items) |l| {
        std.debug.print("  link hq:{d} — hq:{d} level {d}: {d}/{d} t this week, {d}/mo\n", .{
            @intFromEnum(l.a), @intFromEnum(l.b), l.level, l.tons_this_week, l.capacityPerWeek(), l.monthlyCost(),
        });
    }
    for (gs.unit_transfers.items) |t| {
        std.debug.print("  in transit: unit #{d} → co:{d}, arrives day {d}\n", .{ @intFromEnum(t.unit), @intFromEnum(t.to_company), t.eta_day });
    }
}

fn printOffers(gs: *game.state.GameState) void {
    std.debug.print("Contract board ({d} offers):\n", .{gs.contract_offers.items.len});
    for (gs.contract_offers.items, 0..) |offer, i| {
        const world = game.planet.find(offer.planet_key).?;
        std.debug.print("  [{d}] {s:<18} {s:<16} {d:>3} LY{s}  {d:>2} mo  {d:>9}/mo  vs {s}, salvage {d}%\n", .{
            i,
            @tagName(offer.kind),
            world.name,
            offer.dist_ly,
            if (offer.beachhead) "*" else " ",
            offer.terms.length_months,
            offer.terms.base_pay_month,
            offer.enemy_key,
            offer.terms.salvage_pct,
        });
    }
    std.debug.print("  (* = beachhead: premium pay, hardship costs, slow resupply)\n", .{});
}

fn printToe(gs: *game.state.GameState) void {
    std.debug.print("\n{s} — TO&E\n", .{gs.outfit_name});
    var fit = gs.forces.iterator();
    while (fit.next()) |fentry| {
        const company = fentry.value_ptr;
        if (company.echelon != .company) continue;

        var staff_count: u32 = 0;
        var pit = gs.people.iterator();
        while (pit.next()) |pentry| {
            if (pentry.value_ptr.assigned_force == company.id) staff_count += 1;
        }

        printForce(gs, company.id, 0);
        std.debug.print("  company staff: {d} | company BV2: {d}\n", .{ staff_count, forceBv(gs, company.id) });
    }
    std.debug.print("Roster {d} | payroll {d}/mo | hull upkeep {d}/mo\n", .{
        gs.people.count(), gs.monthlyPayroll(), totalHullUpkeep(gs),
    });
}

fn printForce(gs: *game.state.GameState, force_id: game.types.ForceId, depth: u8) void {
    const f = gs.force(force_id).?;
    const indent = "                "[0 .. @as(usize, depth) * 2];
    const tag = if (f.support_kind) |k| @tagName(k) else @tagName(f.role);
    std.debug.print("{s}[{d}] {s} ({s})\n", .{ indent, @intFromEnum(force_id), f.name, tag });
    for (f.units.items) |uid| {
        const u = gs.unit(uid).?;
        const design = game.chassis.find(u.chassis_key).?;
        const pilot = gs.person(u.pilot).?;
        std.debug.print("{s}  {s:<8} {s:<16} {d:>3}t bv{d:>5}  {s} {s}{s}{s}{s} ({s})\n", .{
            indent,
            design.key,
            design.name,
            design.tonnage,
            design.bv,
            pilot.first_name,
            pilot.last_name,
            if (pilot.callsign != null) " \"" else "",
            pilot.callsign orelse "",
            if (pilot.callsign != null) "\"" else "",
            @tagName(pilot.experience()),
        });
    }
    for (f.children.items) |child| printForce(gs, child, depth + 1);
}

fn forceBv(gs: *game.state.GameState, force_id: game.types.ForceId) u64 {
    const f = gs.force(force_id).?;
    var total: u64 = 0;
    for (f.units.items) |uid| {
        total += game.chassis.find(gs.unit(uid).?.chassis_key).?.bv;
    }
    for (f.children.items) |child| total += forceBv(gs, child);
    return total;
}

/// The per-company readiness report (ARCH §9.7): the P&L's companion —
/// profit is meaningless if the force that earned it is spent.
fn printReadiness(gs: *game.state.GameState) void {
    var fit = gs.forces.iterator();
    while (fit.next()) |fentry| {
        const company = fentry.value_ptr;
        if (company.echelon != .company) continue;

        var fatigue_sum: u64 = 0;
        var morale_sum: u64 = 0;
        var wounded: u32 = 0;
        var training: u32 = 0;
        var heads: u32 = 0;
        var pit = gs.people.iterator();
        while (pit.next()) |pentry| {
            const p = pentry.value_ptr;
            if (p.status != .active and p.status != .wounded) continue;
            var walk = p.assigned_force;
            const in_company = while (walk != .none) {
                if (walk == company.id) break true;
                walk = (gs.force(walk) orelse break false).parent;
            } else false;
            if (!in_company) continue;
            heads += 1;
            fatigue_sum += p.fatigue;
            morale_sum += p.morale;
            if (p.status == .wounded) wounded += 1;
            if (p.training != null) training += 1;
        }

        var depot: u32 = 0;
        var quality_sum: u64 = 0;
        var hulls: u32 = 0;
        var uit = gs.units.iterator();
        while (uit.next()) |uentry| {
            const u = uentry.value_ptr;
            if (gs.companyOf(u.force) != company.id) continue;
            hulls += 1;
            quality_sum += @intFromEnum(u.quality);
            if (u.needsDepot()) depot += 1;
        }

        const deployed = gs.deploymentContract(company.id) != null;
        std.debug.print("[{d}] {s} — {s}\n", .{
            @intFromEnum(company.id), company.name, if (deployed) "DEPLOYED" else "at home",
        });
        if (heads > 0) {
            std.debug.print("  {d} personnel | fatigue {d} | morale {d} | {d} wounded | {d} in training\n", .{
                heads, fatigue_sum / heads, morale_sum / heads, wounded, training,
            });
        }
        if (hulls > 0) {
            const q: types_quality = @enumFromInt(quality_sum / hulls);
            std.debug.print("  {d} hulls | avg quality {s} | {d} need depot time | {d} contracts since rotation\n", .{
                hulls, @tagName(q), depot, company.contracts_since_rotation,
            });
        }
    }
}

const types_quality = game.types.Quality;

/// Stocks at every site with tonnage vs. capacity; burn & days-of-supply
/// for deployed companies (Stage 9B).
fn printSupplies(gs: *game.state.GameState) void {
    var hit = gs.hqs.iterator();
    while (hit.next()) |entry| {
        const hq = entry.value_ptr;
        const site: game.types.Site = .{ .hq = hq.id };
        std.debug.print("hq:{d} {s} warehouse — {d}t / {d}t (warehouse lv{d})\n", .{
            @intFromEnum(hq.id), hq.name, gs.siteTons(site), hq.warehouseCapacityTons(), hq.effectiveFacilityLevel(.warehouse),
        });
        printStockLines(&hq.stock);
    }
    var fit = gs.forces.iterator();
    while (fit.next()) |entry| {
        const f = entry.value_ptr;
        if (f.echelon != .company or f.stock.count() == 0) continue;
        const site: game.types.Site = .{ .company = f.id };
        const deployed = gs.deploymentContract(f.id) != null;
        std.debug.print("co:{d} {s} field stores — {d}t / {d}t truck capacity{s}\n", .{
            @intFromEnum(f.id), f.name, gs.siteTons(site), gs.siteCapacityTons(site) orelse 0,
            if (deployed) " (DEPLOYED)" else "",
        });
        printStockLines(&f.stock);
        if (deployed) {
            const heads = gs.companyHeadcount(f.id);
            const burn = std.math.divCeil(u32, heads, game.part.provisions_person_days_per_ton) catch 1;
            const days = gs.stockCount(site, "provisions") / @max(1, burn);
            std.debug.print("    provisions burn {d}t/day → {d} days of supply{s}\n", .{
                burn, days, if (f.supply_shortage_days > 0) " — HUNGRY" else "",
            });
        }
    }
    for (gs.part_orders.items) |o| {
        if (o.status == .in_transit)
            std.debug.print("  inbound: {s} x{d} → {s}, eta day {d}\n", .{ o.part_key, o.quantity, @tagName(o.dest), o.eta_day orelse 0 });
    }
}

fn printStockLines(stock: *const std.StringArrayHashMapUnmanaged(u32)) void {
    var it = stock.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == 0) continue;
        std.debug.print("    {s:<18} x{d:<4} ({d}t)\n", .{
            entry.key_ptr.*, entry.value_ptr.*, entry.value_ptr.* * game.part.tons(entry.key_ptr.*),
        });
    }
}

/// Parts needed to fix what's broken: on hand vs. on order vs. shortfall.
fn printDemand(gs: *game.state.GameState) void {
    var needed: std.StringArrayHashMapUnmanaged(u32) = .empty;
    defer needed.deinit(std.heap.page_allocator);
    var uit = gs.units.iterator();
    while (uit.next()) |entry| {
        const u = entry.value_ptr;
        if (u.status == .destroyed) continue;
        for (u.slots.items) |s| {
            if (s.condition != .destroyed and s.condition != .missing) continue;
            const key = if (s.class == .structure) game.part.componentForSlot(s.slot_key) else s.part_key;
            const e = needed.getOrPut(std.heap.page_allocator, key) catch return;
            if (!e.found_existing) e.value_ptr.* = 0;
            e.value_ptr.* += 1;
        }
    }
    if (needed.count() == 0) {
        std.debug.print("demand: nothing broken needs a part.\n", .{});
        return;
    }
    std.debug.print("demand (parts to fix broken slots):\n", .{});
    const home = gs.defaultSite();
    var it = needed.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        var on_order: u32 = 0;
        for (gs.part_orders.items) |o| {
            if (o.status == .in_transit and std.mem.eql(u8, o.part_key, key)) on_order += o.quantity;
        }
        const on_hand = gs.stockCount(home, key);
        const shortfall = entry.value_ptr.* -| (on_hand + on_order);
        std.debug.print("  {s:<14} need {d:>3} | on hand {d:>3} | on order {d:>3} | shortfall {d:>3}{s}\n", .{
            key, entry.value_ptr.*, on_hand, on_order, shortfall, if (shortfall > 0) "  ← order" else "",
        });
    }
}

fn personName(gs: *game.state.GameState, id: game.types.PersonId) []const u8 {
    return if (gs.person(id)) |p| p.last_name else "—";
}

/// Company roster as assignments (Stage 9C.2): every hull with pilot and
/// tech, every open slot, the unassigned pool, tech hours.
fn printCompanyRoster(gs: *game.state.GameState, co: game.types.ForceId) void {
    const f = gs.force(co) orelse {
        std.debug.print("no such company\n", .{});
        return;
    };
    const day = gs.clock.day_index;
    std.debug.print("[{d}] {s} — hulls and crews:\n", .{ @intFromEnum(co), f.name });
    var uit = gs.units.iterator();
    while (uit.next()) |entry| {
        const u = entry.value_ptr;
        if (gs.companyOf(u.force) != co or u.status == .destroyed) continue;
        const pilot_ok = if (gs.person(u.pilot)) |p| p.isAvailable(day) else false;
        const needs_tech = game.unit.techRoleFor(u.kind) != null;
        const tech_ok = if (gs.person(u.tech)) |t| t.isAvailable(day) else false;
        std.debug.print("  #{d:<3} {s:<8} {s:<9} pilot {s:<12}{s} tech {s:<12}{s}\n", .{
            @intFromEnum(u.id),                                    u.chassis_key,
            @tagName(u.status),                                    personName(gs, u.pilot),
            if (pilot_ok) " " else "!",                            if (needs_tech) personName(gs, u.tech) else "n/a",
            if (needs_tech and !tech_ok) "!" else " ",
        });
    }
    std.debug.print("  techs (load/available hours this week):\n", .{});
    var pit = gs.people.iterator();
    while (pit.next()) |entry| {
        const p = entry.value_ptr;
        if (gs.companyOf(p.assigned_force) != co) continue;
        if (game.unit.techRoleFor(.mek) != p.role and p.role != .tech_mechanic and p.role != .tech_aero) continue;
        std.debug.print("    #{d:<3} {s} {s:<12} {s:<13} {d:>2}/{d:<2}h{s}\n", .{
            @intFromEnum(p.id), p.first_name, p.last_name, @tagName(p.role),
            gs.techLoadHours(p.id), gs.techHoursAvailable(p),
            if (!p.isAvailable(day)) " (unavailable)" else "",
        });
    }
    std.debug.print("  unassigned pool:", .{});
    var any = false;
    var pit2 = gs.people.iterator();
    while (pit2.next()) |entry| {
        const p = entry.value_ptr;
        if (gs.companyOf(p.assigned_force) != co or !p.isAvailable(day)) continue;
        if (!p.role.isCombat() or gs.pilotSeat(p.id) != .none) continue;
        std.debug.print(" #{d} {s} ({s})", .{ @intFromEnum(p.id), p.last_name, @tagName(p.role) });
        any = true;
    }
    std.debug.print("{s}\n", .{if (any) "" else " none"});
}

/// HQ roster (Stage 9C.2): posted staff vs. requirement, plus the outfit's
/// unposted, unassigned pool.
fn printHqRoster(gs: *game.state.GameState, hq_id: game.types.HqId) void {
    const hq = gs.hqs.getPtr(hq_id) orelse {
        std.debug.print("no such HQ\n", .{});
        return;
    };
    const req = hq.staffRequired();
    std.debug.print("{s} — staff {d}/{d} (admin {d}, logistics {d}, hr {d}, finance {d} required)\n", .{
        hq.name, hq.staff_assigned, req.total(), req.admin, req.logistics, req.hr, req.finance,
    });
    var pit = gs.people.iterator();
    while (pit.next()) |entry| {
        const p = entry.value_ptr;
        if (p.posted_hq != hq_id) continue;
        std.debug.print("  #{d:<3} {s} {s:<12} {s:<16} {s}\n", .{ @intFromEnum(p.id), p.first_name, p.last_name, @tagName(p.role), @tagName(p.experience()) });
    }
    std.debug.print("  unposted & unassigned:", .{});
    var any = false;
    var pit2 = gs.people.iterator();
    while (pit2.next()) |entry| {
        const p = entry.value_ptr;
        if (p.posted_hq != .none or p.assigned_force != .none or p.status != .active) continue;
        std.debug.print(" #{d} {s} ({s})", .{ @intFromEnum(p.id), p.last_name, @tagName(p.role) });
        any = true;
    }
    std.debug.print("{s}\n", .{if (any) "" else " none"});
}

/// Medbay (Stage 9C.2): patients, days left, beds and doctors.
fn printMedbay(gs: *game.state.GameState) void {
    var doctors: u32 = 0;
    var wounded: u32 = 0;
    var pit = gs.people.iterator();
    while (pit.next()) |entry| {
        if (entry.value_ptr.status == .active and entry.value_ptr.role == .doctor) doctors += 1;
        if (entry.value_ptr.status == .wounded) wounded += 1;
    }
    std.debug.print("medbay: {d} patients | {d} beds at home | {d} doctors (cover {d})\n", .{
        wounded, game.medical.bedCapacity(gs, .none, false), doctors, doctors * 25,
    });
    var pit2 = gs.people.iterator();
    while (pit2.next()) |entry| {
        const p = entry.value_ptr;
        if (p.status != .wounded) continue;
        const left = if (p.wound_heal_day) |d| d -| gs.clock.day_index else 0;
        std.debug.print("  #{d:<3} {s} {s:<12} {s:<12} priority {d}  {d} days left{s}\n", .{
            @intFromEnum(p.id), p.first_name, p.last_name, @tagName(p.role), p.medbay_priority, left,
            if (p.wound_heal_day == null) " (awaiting triage)" else "",
        });
    }
}

fn printCandidates(gs: *game.state.GameState, filter: game.queries.HallFilter) void {
    std.debug.print("hiring hall ({d} candidates, filter {s}):\n", .{ gs.candidates.items.len, @tagName(filter) });
    for (gs.candidates.items, 0..) |c, i| {
        if (!filter.matches(c.spec.role)) continue;
        std.debug.print("  [{d}] {s} {s:<12} {s:<14} {s:<8} bonus {d}, leaves day {d}\n", .{
            i, c.spec.first, c.spec.last, @tagName(c.spec.role), @tagName(c.spec.experience), c.asking_bonus, c.expires_day,
        });
    }
}

/// The end-turn checklist (Stage 9C.2). Returns how many warnings printed.
fn printChecklist(gs: *game.state.GameState) usize {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const warnings = game.checklist.turnWarnings(gs, arena.allocator()) catch return 0;
    if (warnings.len == 0) return 0;
    std.debug.print("END-TURN CHECKLIST ({d}):\n", .{warnings.len});
    for (warnings) |w| std.debug.print("  ! {s}\n", .{w.text});
    return warnings.len;
}

/// Mek bay occupancy and queue per HQ (Stage 9C).
fn printBays(gs: *game.state.GameState) void {
    var hit = gs.hqs.iterator();
    while (hit.next()) |entry| {
        const hq = entry.value_ptr;
        std.debug.print("hq:{d} {s} — {d}/{d} bay slots busy\n", .{
            @intFromEnum(hq.id), hq.name, game.hq_ops.activeJobs(gs, hq.id), game.hq_ops.baySlots(gs, hq.id),
        });
        for (gs.bay_jobs.items) |j| {
            if (j.hq != hq.id) continue;
            const what = if (j.unit != .none) (if (gs.unit(j.unit)) |u| u.chassis_key else "?") else j.item_key;
            if (j.done_day) |d| {
                std.debug.print("    {s:<13} {s:<10} done day {d}\n", .{ @tagName(j.kind), what, d });
            } else {
                std.debug.print("    {s:<13} {s:<10} QUEUED ({d} days once a slot frees)\n", .{ @tagName(j.kind), what, j.duration_days });
            }
        }
    }
}

/// Construction queue per HQ (Stage 9C).
fn printProjects(gs: *game.state.GameState) void {
    var hit = gs.hqs.iterator();
    while (hit.next()) |entry| {
        const hq = entry.value_ptr;
        std.debug.print("hq:{d} {s} — staff {d}/{d} | paperwork {d} days\n", .{
            @intFromEnum(hq.id), hq.name, hq.staff_assigned, hq.staffRequired().total(), game.hq_ops.paperworkDaysFor(gs, hq.id),
        });
        for (hq.facilities.items) |f| {
            std.debug.print("    {s:<16} level {d} (effective {d})\n", .{ @tagName(f.kind), f.level, hq.effectiveFacilityLevel(f.kind) });
        }
        for (hq.projects.items) |p| {
            std.debug.print("    PROJECT {s} → level {d}: {s}, done day {d}, {d} c-bills\n", .{
                @tagName(p.facility orelse .mek_bay), p.target_level, @tagName(p.phase(gs.clock.day_index)), p.construction_done_day, p.cost,
            });
        }
    }
}

/// The back office: posted admins by role (Stage 9C).
fn printStaff(gs: *game.state.GameState) void {
    var hit = gs.hqs.iterator();
    while (hit.next()) |entry| {
        const hq = entry.value_ptr;
        std.debug.print("hq:{d} {s} back office:\n", .{ @intFromEnum(hq.id), hq.name });
        const roles = [_]game.person.Role{ .admin_command, .admin_logistics, .admin_transport, .admin_hr, .admin_finance };
        for (roles) |role| {
            const s = gs.hqStaff(hq.id, role);
            std.debug.print("    {s:<16} x{d:<3} best skill {d}\n", .{ @tagName(role), s.count, s.best_skill });
        }
    }
}

/// Parse a site token: "hq:<id>" | "co:<id>" (outfit = home).
fn parseSite(token: []const u8) ?game.types.Site {
    const t = parseTreasury(token) orelse return null;
    return switch (t) {
        .outfit => .outfit,
        .hq => |id| .{ .hq = id },
        .company => |id| .{ .company = id },
    };
}

fn printInbox(gs: *game.state.GameState) void {
    const pending = gs.event_queue.pending.items;
    if (pending.len == 0) {
        std.debug.print("inbox empty.\n", .{});
        return;
    }
    std.debug.print("inbox ({d} pending — unanswered decisions default at their deadline):\n", .{pending.len});
    for (pending, 0..) |ev, i| {
        std.debug.print("  [{d}] {s} (answer by day {d}, today is {d})\n", .{
            i, @tagName(ev.kind), ev.deadline_day, gs.clock.day_index,
        });
        for (ev.options, 0..) |opt, j| {
            std.debug.print("      {d}: {s}{s}\n", .{
                j, opt.label, if (j == ev.default_choice) " (default)" else "",
            });
        }
    }
}

fn printHangar(gs: *game.state.GameState) void {
    std.debug.print("hangar ({d} hulls):\n", .{gs.units.count()});
    var it = gs.units.iterator();
    while (it.next()) |entry| {
        const u = entry.value_ptr;
        var broken: u32 = 0;
        for (u.slots.items) |s| {
            if (s.condition != .ok) broken += 1;
        }
        std.debug.print("  #{d:<3} {s:<8} {s:<10} quality {s} armor {d:>3}% {s}{d} slots broken{s} bill {d}/mo\n", .{
            @intFromEnum(u.id),
            u.chassis_key,
            @tagName(u.status),
            @tagName(u.quality),
            u.armor_pct,
            if (u.needsDepot()) "DEPOT! " else "",
            broken,
            if (u.reactivation_done_day != null) " (waking)" else "",
            u.monthlyBill(),
        });
    }
}

fn totalHullUpkeep(gs: *game.state.GameState) i64 {
    var total: i64 = 0;
    var it = gs.units.iterator();
    while (it.next()) |entry| total += entry.value_ptr.monthlyBill();
    return total;
}

fn printLog(gs: *game.state.GameState, n: usize, filter: game.state.LogFilter) void {
    // Walk backwards to find the last n matching entries, then print in order.
    const items = gs.event_log.items;
    var start = items.len;
    var found: usize = 0;
    while (start > 0 and found < n) {
        start -= 1;
        if (items[start].matches(filter)) found += 1;
    }
    for (items[start..]) |entry| {
        if (entry.matches(filter)) std.debug.print("  {s}\n", .{entry.text});
    }
}

fn printTreasuries(gs: *game.state.GameState) void {
    std.debug.print("outfit treasury: {d}\n", .{gs.funds});
    var hit = gs.hqs.iterator();
    while (hit.next()) |entry| {
        std.debug.print("  hq:{d} {s}: {d}\n", .{ @intFromEnum(entry.value_ptr.id), entry.value_ptr.name, entry.value_ptr.funds });
    }
    var fit = gs.forces.iterator();
    while (fit.next()) |entry| {
        const f = entry.value_ptr;
        if (f.echelon == .company)
            std.debug.print("  co:{d} {s}: {d} local funds\n", .{ @intFromEnum(f.id), f.name, f.local_funds });
    }
    for (gs.fund_couriers.items) |c| {
        std.debug.print("  in transit: {d} c-bills, arrives day {d}\n", .{ c.amount, c.eta_day });
    }
    for (gs.policies.items) |p| {
        std.debug.print("  policy: {s} top up to {d} (cap {d}/mo)\n", .{ treasuryName(p.entity), p.floor, p.monthly_cap });
    }
}

fn treasuryName(t: game.state.Treasury) []const u8 {
    return switch (t) {
        .outfit => "outfit",
        .hq => "hq",
        .company => "company",
    };
}

/// Parse "outfit" | "hq:<id>" | "co:<id>".
fn parseTreasury(token: []const u8) ?game.state.Treasury {
    if (std.mem.eql(u8, token, "outfit")) return .outfit;
    if (std.mem.startsWith(u8, token, "hq:")) {
        const id = std.fmt.parseInt(u32, token[3..], 10) catch return null;
        return .{ .hq = @enumFromInt(id) };
    }
    if (std.mem.startsWith(u8, token, "co:")) {
        const id = std.fmt.parseInt(u32, token[3..], 10) catch return null;
        return .{ .company = @enumFromInt(id) };
    }
    return null;
}

fn printPnl(gs: *game.state.GameState, from_day: u32, to_day: u32, filter: game.finance.EntityFilter) void {
    const s = game.finance.summarize(&gs.ledger, from_day, to_day, filter);
    switch (filter) {
        .all => std.debug.print("P&L (outfit-wide) days {d}-{d}:\n", .{ from_day, to_day }),
        .company => |id| std.debug.print("P&L company {d} days {d}-{d}:\n", .{ @intFromEnum(id), from_day, to_day }),
        .hq => |id| std.debug.print("P&L hq {d} days {d}-{d}:\n", .{ @intFromEnum(id), from_day, to_day }),
    }
    inline for (@typeInfo(game.finance.Category).@"enum".fields) |field| {
        const cat: game.finance.Category = @enumFromInt(field.value);
        const amount = s.category(cat);
        if (amount != 0) std.debug.print("  {s:<20} {d:>12} c-bills\n", .{ field.name, amount });
    }
    std.debug.print("  {s:<20} {d:>12} c-bills\n", .{ "NET", s.net() });
}

fn printStatus(gs: *game.state.GameState) void {
    const d = gs.clock.date;
    std.debug.print(
        "{d}-{d:0>2}-{d:0>2} (day {d}) | funds {d} c-bills | rep {d} | roster {d} | payroll {d}/mo\n",
        .{ d.year, d.month, d.day, gs.clock.day_index, gs.funds, gs.reputation, gs.people.count(), gs.monthlyPayroll() },
    );
}

fn printRoster(gs: *game.state.GameState) void {
    var it = gs.people.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        std.debug.print("  #{d:<3} {s} {s}{s}{s}{s} — {s}, {s}, {d} c-bills/mo, {d} xp\n", .{
            @intFromEnum(p.id),
            p.first_name,
            p.last_name,
            if (p.callsign != null) " \"" else "",
            p.callsign orelse "",
            if (p.callsign != null) "\"" else "",
            @tagName(p.role),
            @tagName(p.experience()),
            p.monthlySalary(),
            p.xp,
        });
    }
}

fn runRepl(gs: *game.state.GameState, io: std.Io, gpa: std.mem.Allocator, store_path: [:0]const u8) !void {
    // The save store (Stage 11): one file, many campaigns.
    const store = game.store.Store.open(store_path) catch |err| {
        std.debug.print("could not open save store '{s}': {s}\n", .{ store_path, @errorName(err) });
        return err;
    };
    defer store.close();
    std.debug.print("save store: {s}\n", .{store_path});
    printCampaigns(store);

    std.debug.print(
        \\=== BattleTech Mercenary Command — command console ===
        \\          save | campaigns | load <id> | delete <id> | new (fresh campaign)
        \\commands: start <faction> <profession> <name> | status | toe | hqs | offers
        \\          roster [co:<id>|hq:<id>] | medbay | hall | hire <candidate#> | checklist
        \\          assign <unit> pilot|tech <person> | unassign <unit> pilot|tech | autoassign co:<id>
        \\          triage <person> <priority> | leave <person> <days>
        \\          day [n] [force] (end turn(s); the checklist gates it) | inbox | resolve <event#> <option#> | readiness
        \\          log [n] [battle|decision|delivery|...|co:<id>|hq:<id>]
        \\          pnl [co:<id>|hq:<id>] | ledger [co:<id>|hq:<id>] [n] | treasuries
        \\          transfer <from> <to> <amount> | policy <hq:<id>|co:<id>> <floor> <cap>
        \\          train <person id> <skill>
        \\          newco <name> | accept <offer#> <company id> | loan <amount> <months>
        \\          units | parts | orders | order <part> [qty] [hq:<id>|co:<id>] | shop | buy <idx>
        \\          supplies | demand | ship <part> <qty> <from site> <to site>
        \\          bays | projects | staff | upgrade hq:<id> <facility> | fabricate <comp> [qty] | post <person> hq:<id>
        \\          found <planet> <name> | tier hq:<id> | link hq:<a> hq:<b> [lvl] | assignco co:<id> hq:<id>
        \\          newco@ hq:<id> <name> | xfer unit|person <id> co:<id>
        \\          contracts | complete <contract id> | recall co:<id>
        \\          lab <unit> | refit <unit> remove <slot>|install <loc> <part>|clear|commit
        \\          mothball <unit id> | activate <unit id>
        \\          recruit <role> | hire <role> <first> <last> | fire <id>
        \\          rename outfit|<forceid> <name> | quit
        \\factions: LC DC FS CC FWL — professions: quartermaster paymaster chief_engineer line_officer
        \\
    , .{});

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
    const in = &stdin_reader.interface;

    while (true) {
        std.debug.print("> ", .{});
        const line = (try in.takeDelimiter('\n')) orelse break;
        var tokens = std.mem.tokenizeScalar(u8, line, ' ');
        const verb = tokens.next() orelse continue;

        if (std.mem.eql(u8, verb, "quit")) break;

        if (std.mem.eql(u8, verb, "save")) {
            store.save(gs) catch |err| {
                std.debug.print("save failed: {s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("saved campaign [{d}] \"{s}\" at day {d}\n", .{ gs.campaign_id, gs.outfit_name, gs.clock.day_index });
        } else if (std.mem.eql(u8, verb, "campaigns")) {
            printCampaigns(store);
        } else if (std.mem.eql(u8, verb, "load")) {
            const id = std.fmt.parseInt(i64, tokens.next() orelse "", 10) catch {
                std.debug.print("usage: load <campaign id>  (see `campaigns`)\n", .{});
                continue;
            };
            const loaded = store.load(gpa, id) catch |err| {
                std.debug.print("load failed: {s}\n", .{@errorName(err)});
                continue;
            };
            gs.deinit();
            gs.* = loaded;
            std.debug.print("loaded campaign [{d}] \"{s}\"\n", .{ gs.campaign_id, gs.outfit_name });
            printStatus(gs);
        } else if (std.mem.eql(u8, verb, "delete")) {
            const id = std.fmt.parseInt(i64, tokens.next() orelse "", 10) catch {
                std.debug.print("usage: delete <campaign id>\n", .{});
                continue;
            };
            store.deleteCampaign(id) catch |err| {
                std.debug.print("delete failed: {s}\n", .{@errorName(err)});
                continue;
            };
            if (gs.campaign_id == id) gs.campaign_id = 0; // the live game is now unsaved
            std.debug.print("deleted campaign [{d}]\n", .{id});
            printCampaigns(store);
        } else if (std.mem.eql(u8, verb, "new")) {
            const seed: u64 = @intCast(gs.clock.day_index + gs.people.count() + 1);
            gs.deinit();
            gs.* = game.state.GameState.init(gpa, .{ .seed = 3025 + seed });
            std.debug.print("fresh campaign — `start <faction> <profession> <name>` to begin\n", .{});
        } else if (std.mem.eql(u8, verb, "status")) {
            printStatus(gs);
        } else if (std.mem.eql(u8, verb, "roster")) {
            if (tokens.next()) |tok| {
                if (parseSite(tok)) |site| switch (site) {
                    .company => |id| printCompanyRoster(gs, id),
                    .hq => |id| printHqRoster(gs, id),
                    .outfit => printRoster(gs),
                } else printRoster(gs);
            } else printRoster(gs);
        } else if (std.mem.eql(u8, verb, "medbay")) {
            printMedbay(gs);
        } else if (std.mem.eql(u8, verb, "hall")) {
            const filter = if (tokens.next()) |t| std.meta.stringToEnum(game.queries.HallFilter, t) orelse {
                std.debug.print("usage: hall [all|combat|techs|medical|admin_command|admin_logistics|admin_transport|admin_hr|admin_finance|other]\n", .{});
                continue;
            } else game.queries.HallFilter.all;
            printCandidates(gs, filter);
        } else if (std.mem.eql(u8, verb, "checklist")) {
            if (printChecklist(gs) == 0) std.debug.print("all clear.\n", .{});
        } else if (std.mem.eql(u8, verb, "assign") or std.mem.eql(u8, verb, "unassign")) {
            const uid = std.fmt.parseInt(u32, tokens.next() orelse "", 10) catch 0;
            const slot = std.meta.stringToEnum(game.state.Slot, tokens.next() orelse "");
            if (uid == 0 or slot == null) {
                std.debug.print("usage: {s} <unit id> pilot|tech [person id]\n", .{verb});
                continue;
            }
            const unit_id: game.types.UnitId = @enumFromInt(uid);
            var cmd: Command = .{ .unassign = .{ .unit = unit_id, .slot = slot.? } };
            if (verb[0] == 'a') {
                const pid = std.fmt.parseInt(u32, tokens.next() orelse "", 10) catch 0;
                if (pid == 0) {
                    std.debug.print("usage: assign <unit id> pilot|tech <person id>\n", .{});
                    continue;
                }
                cmd = .{ .assign = .{ .unit = unit_id, .slot = slot.?, .person = @enumFromInt(pid) } };
            }
            _ = game.commands.execute(gs, cmd) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("done — see `roster co:<id>`\n", .{});
        } else if (std.mem.eql(u8, verb, "autoassign")) {
            const site = parseSite(tokens.next() orelse "");
            if (site == null or site.? != .company) {
                std.debug.print("usage: autoassign co:<id>\n", .{});
                continue;
            }
            _ = game.commands.execute(gs, .{ .auto_assign = site.?.company }) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            printCompanyRoster(gs, site.?.company);
        } else if (std.mem.eql(u8, verb, "triage") or std.mem.eql(u8, verb, "leave")) {
            const pid = std.fmt.parseInt(u32, tokens.next() orelse "", 10) catch 0;
            const n = std.fmt.parseInt(u16, tokens.next() orelse "", 10) catch 0;
            if (pid == 0) {
                std.debug.print("usage: triage <person> <priority> | leave <person> <days>\n", .{});
                continue;
            }
            const cmd: Command = if (verb[0] == 't')
                .{ .triage = .{ .person = @enumFromInt(pid), .priority = @intCast(@min(n, 9)) } }
            else
                .{ .leave = .{ .person = @enumFromInt(pid), .days = if (n == 0) 7 else n } };
            _ = game.commands.execute(gs, cmd) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("done.\n", .{});
        } else if (std.mem.eql(u8, verb, "toe")) {
            printToe(gs);
        } else if (std.mem.eql(u8, verb, "hqs")) {
            printHqs(gs);
        } else if (std.mem.eql(u8, verb, "offers")) {
            printOffers(gs);
        } else if (std.mem.eql(u8, verb, "readiness")) {
            printReadiness(gs);
        } else if (std.mem.eql(u8, verb, "train")) {
            const pid = std.fmt.parseInt(u32, tokens.next() orelse "", 10) catch {
                std.debug.print("usage: train <person id> <skill> (e.g. gunnery_mek)\n", .{});
                continue;
            };
            const skill = std.meta.stringToEnum(game.types.SkillType, tokens.next() orelse "") orelse {
                std.debug.print("unknown skill — try gunnery_mek, piloting_mek, tech_mek, ...\n", .{});
                continue;
            };
            _ = game.commands.execute(gs, .{ .train = .{ .person = @enumFromInt(pid), .skill = skill } }) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("training program started ({d} days)\n", .{game.medical.training_days});
        } else if (std.mem.eql(u8, verb, "inbox")) {
            printInbox(gs);
        } else if (std.mem.eql(u8, verb, "resolve")) {
            const ev_idx = std.fmt.parseInt(usize, tokens.next() orelse "", 10) catch {
                std.debug.print("usage: resolve <event#> <option#>\n", .{});
                continue;
            };
            const choice = std.fmt.parseInt(usize, tokens.next() orelse "", 10) catch {
                std.debug.print("usage: resolve <event#> <option#>\n", .{});
                continue;
            };
            _ = game.commands.execute(gs, .{ .resolve_decision = .{ .event_index = ev_idx, .choice = choice } }) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("resolved.\n", .{});
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
                } else if (parseTreasury(tok)) |t| {
                    filter = switch (t) {
                        .company => |id| .{ .company = id },
                        .hq => |id| .{ .hq = id },
                        .outfit => .all,
                    };
                } else {
                    std.debug.print("usage: log [n] [battle|decision|delivery|...|co:<id>|hq:<id>]\n", .{});
                }
            }
            printLog(gs, n, filter);
        } else if (std.mem.eql(u8, verb, "treasuries")) {
            printTreasuries(gs);
        } else if (std.mem.eql(u8, verb, "transfer")) {
            const from = parseTreasury(tokens.next() orelse "") orelse {
                std.debug.print("usage: transfer <outfit|hq:<id>|co:<id>> <outfit|hq:<id>|co:<id>> <amount>\n", .{});
                continue;
            };
            const to = parseTreasury(tokens.next() orelse "") orelse {
                std.debug.print("usage: transfer <from> <to> <amount>\n", .{});
                continue;
            };
            const amount = std.fmt.parseInt(i64, tokens.next() orelse "", 10) catch {
                std.debug.print("usage: transfer <from> <to> <amount>\n", .{});
                continue;
            };
            _ = game.commands.execute(gs, .{ .transfer = .{ .from = from, .to = to, .amount = amount } }) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("courier dispatched — see `treasuries`\n", .{});
        } else if (std.mem.eql(u8, verb, "policy")) {
            const entity = parseTreasury(tokens.next() orelse "") orelse {
                std.debug.print("usage: policy <hq:<id>|co:<id>> <floor> <monthly cap>\n", .{});
                continue;
            };
            const floor = std.fmt.parseInt(i64, tokens.next() orelse "", 10) catch {
                std.debug.print("usage: policy <entity> <floor> <monthly cap>\n", .{});
                continue;
            };
            const cap = std.fmt.parseInt(i64, tokens.next() orelse "", 10) catch floor;
            _ = game.commands.execute(gs, .{ .set_policy = .{ .entity = entity, .floor = floor, .monthly_cap = cap } }) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("policy set.\n", .{});
        } else if (std.mem.eql(u8, verb, "ledger")) {
            // ledger [co:<id>|hq:<id>] [n]
            var filter: game.finance.EntityFilter = .all;
            var n: usize = 15;
            while (tokens.next()) |tok| {
                if (parseTreasury(tok)) |t| {
                    filter = switch (t) {
                        .company => |id| .{ .company = id },
                        .hq => |id| .{ .hq = id },
                        .outfit => .all,
                    };
                } else n = std.fmt.parseInt(usize, tok, 10) catch n;
            }
            const txns = gs.ledger.transactions.items;
            var shown: usize = 0;
            var i = txns.len;
            while (i > 0 and shown < n) {
                i -= 1;
                const t = &txns[i];
                if (!filter.matches(t)) continue;
                std.debug.print("  day {d:>4}  {s:<18} {d:>10}  {s}\n", .{ t.day, @tagName(t.category), t.amount, t.note });
                shown += 1;
            }
        } else if (std.mem.eql(u8, verb, "units")) {
            printHangar(gs);
        } else if (std.mem.eql(u8, verb, "parts")) {
            var it = gs.spare_parts.iterator();
            std.debug.print("spares:\n", .{});
            while (it.next()) |entry| {
                if (entry.value_ptr.* > 0)
                    std.debug.print("  {s} x{d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        } else if (std.mem.eql(u8, verb, "orders")) {
            for (gs.part_orders.items) |o| {
                std.debug.print("  {s} x{d} — {s}{s}{d}\n", .{
                    o.part_key,                            o.quantity,
                    @tagName(o.status),                    if (o.eta_day != null) ", eta day " else ", day ",
                    o.eta_day orelse o.ordered_day,
                });
            }
        } else if (std.mem.eql(u8, verb, "lab")) {
            const uid = std.fmt.parseInt(u32, tokens.next() orelse "", 10) catch 0;
            if (uid == 0) {
                std.debug.print("usage: lab <unit id>\n", .{});
                continue;
            }
            printLab(gs, @enumFromInt(uid));
        } else if (std.mem.eql(u8, verb, "refit")) {
            const uid = std.fmt.parseInt(u32, tokens.next() orelse "", 10) catch 0;
            const sub = tokens.next() orelse "";
            if (uid == 0 or sub.len == 0) {
                std.debug.print("usage: refit <unit> remove <slot key> | install <hd|ct|lt|rt|la|ra|ll|rl> <part> | clear | commit\n", .{});
                continue;
            }
            const unit_id: game.types.UnitId = @enumFromInt(uid);
            var cmd: ?Command = null;
            if (std.mem.eql(u8, sub, "remove")) {
                const slot = tokens.next() orelse "";
                if (slot.len > 0) cmd = .{ .refit_remove = .{ .unit = unit_id, .slot_key = slot } };
            } else if (std.mem.eql(u8, sub, "install")) {
                const loc = std.meta.stringToEnum(game.meklab.Location, tokens.next() orelse "");
                const part = tokens.next() orelse "";
                if (loc != null and part.len > 0) cmd = .{ .refit_install = .{ .unit = unit_id, .location = loc.?, .part_key = part } };
            } else if (std.mem.eql(u8, sub, "clear")) {
                cmd = .{ .refit_clear = unit_id };
            } else if (std.mem.eql(u8, sub, "commit")) {
                cmd = .{ .refit_commit = unit_id };
            }
            const c = cmd orelse {
                std.debug.print("usage: refit <unit> remove <slot key> | install <loc> <part> | clear | commit\n", .{});
                continue;
            };
            _ = game.commands.execute(gs, c) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                if (err == error.IllegalFit) printLab(gs, unit_id);
                continue;
            };
            printLab(gs, unit_id);
        } else if (std.mem.eql(u8, verb, "contracts")) {
            printContracts(gs);
        } else if (std.mem.eql(u8, verb, "complete")) {
            const cid = std.fmt.parseInt(u32, tokens.next() orelse "", 10) catch 0;
            if (cid == 0) {
                std.debug.print("usage: complete <contract id>  (attrition objectives ≥75% destroyed)\n", .{});
                continue;
            }
            _ = game.commands.execute(gs, .{ .complete_contract = @enumFromInt(cid) }) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            printContracts(gs);
        } else if (std.mem.eql(u8, verb, "recall")) {
            const site = parseSite(tokens.next() orelse "");
            if (site == null or site.? != .company) {
                std.debug.print("usage: recall co:<id>  (mid-contract = breach clause)\n", .{});
                continue;
            }
            _ = game.commands.execute(gs, .{ .recall_company = site.?.company }) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            printContracts(gs);
        } else if (std.mem.eql(u8, verb, "found")) {
            const planet_key = tokens.next() orelse "";
            const name = std.mem.trim(u8, tokens.rest(), " ");
            if (planet_key.len == 0 or name.len == 0) {
                std.debug.print("usage: found <planet key> <name>  (500k from the outfit; world must be in a ring/band or a contract site)\n", .{});
                continue;
            }
            _ = game.commands.execute(gs, .{ .found_hq = .{ .name = name, .planet_key = planet_key } }) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            printHqs(gs);
        } else if (std.mem.eql(u8, verb, "autostaff")) {
            const site = parseSite(tokens.next() orelse "");
            if (site == null or site.? != .hq) {
                std.debug.print("usage: autostaff hq:<id>\n", .{});
                continue;
            }
            _ = game.commands.execute(gs, .{ .autostaff = site.?.hq }) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            printHqRoster(gs, site.?.hq);
        } else if (std.mem.eql(u8, verb, "tier")) {
            const site = parseSite(tokens.next() orelse "");
            if (site == null or site.? != .hq) {
                std.debug.print("usage: tier hq:<id>   (field → regional, {d} c-bills from the HQ, {d}+ days)\n", .{ game.hq_ops.tier_upgrade_cost, game.hq_ops.tier_upgrade_build_days });
                continue;
            }
            _ = game.commands.execute(gs, .{ .upgrade_tier = site.?.hq }) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("regional upgrade started — see `projects`\n", .{});
        } else if (std.mem.eql(u8, verb, "assignco")) {
            const co = parseSite(tokens.next() orelse "");
            const hq = parseSite(tokens.next() orelse "");
            if (co == null or co.? != .company or hq == null or hq.? != .hq) {
                std.debug.print("usage: assignco co:<id> hq:<id>\n", .{});
                continue;
            }
            _ = game.commands.execute(gs, .{ .assign_company = .{ .company = co.?.company, .hq = hq.?.hq } }) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            printHqs(gs);
        } else if (std.mem.eql(u8, verb, "link")) {
            const a = parseSite(tokens.next() orelse "");
            const b = parseSite(tokens.next() orelse "");
            const level = std.fmt.parseInt(u8, tokens.next() orelse "1", 10) catch 1;
            if (a == null or a.? != .hq or b == null or b.? != .hq) {
                std.debug.print("usage: link hq:<a> hq:<b> [level 1-3]  (cost {d}/{d}/{d})\n", .{ game.network.linkCost(1), game.network.linkCost(2), game.network.linkCost(3) });
                continue;
            }
            _ = game.commands.execute(gs, .{ .link = .{ .a = a.?.hq, .b = b.?.hq, .level = level } }) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            printHqs(gs);
        } else if (std.mem.eql(u8, verb, "newco@")) {
            const hq = parseSite(tokens.next() orelse "");
            const name = std.mem.trim(u8, tokens.rest(), " ");
            if (hq == null or hq.? != .hq or name.len == 0) {
                std.debug.print("usage: newco@ hq:<id> <name>\n", .{});
                continue;
            }
            const r = game.commands.execute(gs, .{ .new_company_at = .{ .name = name, .hq = hq.?.hq } }) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("stood up company [{d}] \"{s}\" at hq:{d}\n", .{ @intFromEnum(r.created_force), name, @intFromEnum(hq.?.hq) });
        } else if (std.mem.eql(u8, verb, "xfer")) {
            const what = tokens.next() orelse "";
            const id = std.fmt.parseInt(u32, tokens.next() orelse "", 10) catch 0;
            const dest = parseSite(tokens.next() orelse "");
            if (id == 0 or dest == null or dest.? != .company) {
                std.debug.print("usage: xfer unit|person <id> co:<id>\n", .{});
                continue;
            }
            const cmd: Command = if (std.mem.eql(u8, what, "unit"))
                .{ .transfer_unit = .{ .unit = @enumFromInt(id), .to_company = dest.?.company } }
            else
                .{ .transfer_person = .{ .person = @enumFromInt(id), .to_force = dest.?.company } };
            _ = game.commands.execute(gs, cmd) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("transfer ordered — see `hqs` / `roster`\n", .{});
        } else if (std.mem.eql(u8, verb, "bays")) {
            printBays(gs);
        } else if (std.mem.eql(u8, verb, "projects")) {
            printProjects(gs);
        } else if (std.mem.eql(u8, verb, "staff")) {
            printStaff(gs);
        } else if (std.mem.eql(u8, verb, "upgrade")) {
            const site = parseSite(tokens.next() orelse "");
            const kind = std.meta.stringToEnum(game.hq.FacilityKind, tokens.next() orelse "");
            if (site == null or site.? != .hq or kind == null) {
                std.debug.print("usage: upgrade hq:<id> <mek_bay|warehouse|hospital|mess|training_ground|hiring_hall|comms|spaceport>\n", .{});
                continue;
            }
            _ = game.commands.execute(gs, .{ .upgrade_facility = .{ .hq = site.?.hq, .kind = kind.? } }) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("project started — see `projects`\n", .{});
        } else if (std.mem.eql(u8, verb, "fabricate")) {
            const key = tokens.next() orelse "";
            const qty = std.fmt.parseInt(u32, tokens.next() orelse "1", 10) catch 1;
            if (gs.hqs.count() == 0) {
                std.debug.print("no HQ\n", .{});
                continue;
            }
            _ = game.commands.execute(gs, .{ .fabricate = .{ .hq = gs.hqs.keys()[0], .part_key = key, .quantity = qty } }) catch |err| {
                std.debug.print("error: {s} (components: comp_head comp_ct comp_torso comp_arm comp_leg comp_chassis)\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("fabrication queued — see `bays`\n", .{});
        } else if (std.mem.eql(u8, verb, "post")) {
            const pid = std.fmt.parseInt(u32, tokens.next() orelse "", 10) catch 0;
            const site = parseSite(tokens.next() orelse "");
            if (pid == 0 or site == null or site.? != .hq) {
                std.debug.print("usage: post <person id> hq:<id>\n", .{});
                continue;
            }
            _ = game.commands.execute(gs, .{ .post_person = .{ .person = @enumFromInt(pid), .hq = site.?.hq } }) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("posted — see `staff`\n", .{});
        } else if (std.mem.eql(u8, verb, "supplies")) {
            printSupplies(gs);
        } else if (std.mem.eql(u8, verb, "demand")) {
            printDemand(gs);
        } else if (std.mem.eql(u8, verb, "ship")) {
            const key = tokens.next() orelse "";
            const qty = std.fmt.parseInt(u32, tokens.next() orelse "", 10) catch 0;
            const from = parseSite(tokens.next() orelse "");
            const to = parseSite(tokens.next() orelse "");
            if (qty == 0 or from == null or to == null) {
                std.debug.print("usage: ship <part> <qty> <hq:<id>|co:<id>> <hq:<id>|co:<id>>\n", .{});
                continue;
            }
            _ = game.commands.execute(gs, .{ .ship_stock = .{ .part_key = key, .quantity = qty, .from = from.?, .to = to.? } }) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("shipment dispatched — see `supplies`\n", .{});
        } else if (std.mem.eql(u8, verb, "order")) {
            const key = tokens.next() orelse {
                std.debug.print("usage: order <part key> [qty] [hq:<id>|co:<id>]\n", .{});
                continue;
            };
            const qty = std.fmt.parseInt(u32, tokens.next() orelse "1", 10) catch 1;
            const dest = if (tokens.next()) |t| parseSite(t) else null;
            _ = game.commands.execute(gs, .{ .order_part = .{ .part_key = key, .quantity = qty, .dest = dest } }) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            const o = gs.part_orders.items[gs.part_orders.items.len - 1];
            if (o.status == .failed) {
                std.debug.print("logistics couldn't source {s} this time (retry after refresh)\n", .{key});
            } else {
                std.debug.print("ordered {s} x{d}, eta day {d}, {d} c-bills\n", .{ key, qty, o.eta_day.?, o.cost });
            }
        } else if (std.mem.eql(u8, verb, "shop")) {
            std.debug.print("site market ({d} listings):\n", .{gs.market_listings.items.len});
            for (gs.market_listings.items, 0..) |l, i| {
                if (l.condition) |c| {
                    std.debug.print("  [{d}] hull  {s:<8} {s:<5} armor {d:>3}% quality {s} | {d} dmg / {d} destroyed / {d} missing comps | {d} c-bills | gone day {d}\n", .{
                        i, l.item_key, c.label(), c.armor_pct, @tagName(c.quality), c.damaged_slots, c.destroyed_slots, c.missing_components, l.price, l.expires_day,
                    });
                } else {
                    std.debug.print("  [{d}] {s:<5} {s:<16} x{d:<3} ({s}{s}) {d} c-bills\n", .{
                        i, @tagName(l.kind), l.item_key, l.quantity, @tagName(l.rarity), if (l.staple) ", staple" else ", RARE SLOT", l.price,
                    });
                }
            }
        } else if (std.mem.eql(u8, verb, "buy")) {
            const idx = std.fmt.parseInt(usize, tokens.next() orelse "", 10) catch {
                std.debug.print("usage: buy <listing #>\n", .{});
                continue;
            };
            _ = game.commands.execute(gs, .{ .buy_listing = idx }) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("bought.\n", .{});
        } else if (std.mem.eql(u8, verb, "mothball") or std.mem.eql(u8, verb, "activate")) {
            const id = std.fmt.parseInt(u32, tokens.next() orelse "", 10) catch {
                std.debug.print("usage: {s} <unit id>\n", .{verb});
                continue;
            };
            const cmd: Command = if (verb[0] == 'm') .{ .mothball = @enumFromInt(id) } else .{ .reactivate = @enumFromInt(id) };
            _ = game.commands.execute(gs, cmd) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("done — see `units`\n", .{});
        } else if (std.mem.eql(u8, verb, "start")) {
            const faction_str = tokens.next() orelse "";
            const prof_str = tokens.next() orelse "";
            const name = std.mem.trim(u8, tokens.rest(), " ");
            const faction = std.meta.stringToEnum(game.commander.Faction, faction_str) orelse {
                std.debug.print("usage: start <LC|DC|FS|CC|FWL> <profession> <name>\n", .{});
                continue;
            };
            const prof = std.meta.stringToEnum(game.commander.Profession, prof_str) orelse {
                std.debug.print("professions: quartermaster paymaster chief_engineer line_officer\n", .{});
                continue;
            };
            _ = game.commands.execute(gs, .{ .create_commander = .{
                .name = if (name.len > 0) name else "Commander",
                .origin = faction,
                .profession = prof,
            } }) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            printHqs(gs);
            printOffers(gs);
        } else if (std.mem.eql(u8, verb, "accept")) {
            const idx_str = tokens.next() orelse "";
            const co_str = tokens.next() orelse "";
            const idx = std.fmt.parseInt(usize, idx_str, 10) catch {
                std.debug.print("usage: accept <offer#> <company force id>\n", .{});
                continue;
            };
            const co = std.fmt.parseInt(u32, co_str, 10) catch {
                std.debug.print("usage: accept <offer#> <company force id>\n", .{});
                continue;
            };
            _ = game.commands.execute(gs, .{ .accept_contract = .{ .offer_index = idx, .company = @enumFromInt(co) } }) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            const c = gs.contracts.values()[gs.contracts.count() - 1];
            std.debug.print("under contract: {s} on {s}, {d} days transit, {d}/mo net\n", .{
                @tagName(c.kind), game.planet.find(c.planet_key).?.name, c.transit_days, c.monthly_net,
            });
        } else if (std.mem.eql(u8, verb, "loan")) {
            const amt = std.fmt.parseInt(i64, tokens.next() orelse "", 10) catch {
                std.debug.print("usage: loan <amount> <months>\n", .{});
                continue;
            };
            const months = std.fmt.parseInt(u16, tokens.next() orelse "12", 10) catch 12;
            _ = try game.commands.execute(gs, .{ .take_loan = .{ .principal = amt, .term_months = months } });
            std.debug.print("drew {d} c-bills over {d} months\n", .{ amt, months });
        } else if (std.mem.eql(u8, verb, "newco")) {
            const name = std.mem.trim(u8, tokens.rest(), " ");
            if (name.len == 0) {
                std.debug.print("usage: newco <company name>\n", .{});
                continue;
            }
            const r = try game.commands.execute(gs, .{ .new_company = name });
            std.debug.print("stood up company [{d}] \"{s}\" — see `toe`\n", .{ @intFromEnum(r.created_force), name });
        } else if (std.mem.eql(u8, verb, "rename")) {
            const target = tokens.next() orelse {
                std.debug.print("usage: rename outfit|<forceid> <new name>\n", .{});
                continue;
            };
            const name = std.mem.trim(u8, tokens.rest(), " ");
            if (name.len == 0) {
                std.debug.print("usage: rename outfit|<forceid> <new name>\n", .{});
                continue;
            }
            if (std.mem.eql(u8, target, "outfit")) {
                _ = try game.commands.execute(gs, .{ .rename_outfit = name });
            } else {
                const fid = std.fmt.parseInt(u32, target, 10) catch continue;
                _ = game.commands.execute(gs, .{ .rename_force = .{ .force = @enumFromInt(fid), .name = name } }) catch |err| {
                    std.debug.print("error: {s}\n", .{@errorName(err)});
                    continue;
                };
            }
            std.debug.print("renamed to \"{s}\"\n", .{name});
        } else if (std.mem.eql(u8, verb, "pnl")) {
            // pnl [co:<id>|hq:<id>] — last 31 days for the outfit or one entity.
            const from = if (gs.clock.day_index > 31) gs.clock.day_index - 31 else 0;
            var filter: game.finance.EntityFilter = .all;
            if (tokens.next()) |tok| {
                if (parseTreasury(tok)) |t| filter = switch (t) {
                    .company => |id| .{ .company = id },
                    .hq => |id| .{ .hq = id },
                    .outfit => .all,
                };
            }
            printPnl(gs, from, gs.clock.day_index, filter);
        } else if (std.mem.eql(u8, verb, "recruit")) {
            const role_str = tokens.next() orelse {
                std.debug.print("usage: recruit <role>\n", .{});
                continue;
            };
            const role = std.meta.stringToEnum(game.person.Role, role_str) orelse {
                std.debug.print("unknown role '{s}'\n", .{role_str});
                continue;
            };
            const r = try game.commands.execute(gs, .{ .recruit = role });
            const p = gs.person(r.hired).?;
            std.debug.print("recruited #{d}: {s} {s} ({s}, {d} c-bills/mo)\n", .{
                @intFromEnum(r.hired), p.first_name, p.last_name, @tagName(p.experience()), p.monthlySalary(),
            });
        } else if (std.mem.eql(u8, verb, "day")) {
            // day [n] [force] — the end-turn checklist gates the advance
            // (Stage 9C.2): fix it, or `day force` to proceed regardless.
            var n: u32 = 1;
            var force = false;
            while (tokens.next()) |t| {
                if (std.mem.eql(u8, t, "force") or std.mem.eql(u8, t, "!")) {
                    force = true;
                } else n = std.fmt.parseInt(u32, t, 10) catch n;
            }
            if (!force and printChecklist(gs) > 0) {
                std.debug.print("turn not ended — address the checklist or `day {d} force`\n", .{n});
                continue;
            }
            const r = game.commands.execute(gs, .{ .advance_days = n }) catch |err| {
                std.debug.print("blocked: {s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("advanced {d} day(s)\n", .{r.days_advanced});
            printStatus(gs);
        } else if (std.mem.eql(u8, verb, "hire")) {
            const role_str = tokens.next() orelse {
                std.debug.print("usage: hire <candidate#> (see `hall`) | hire <role> <first> <last>\n", .{});
                continue;
            };
            if (std.fmt.parseInt(usize, role_str, 10)) |idx| {
                const r = game.commands.execute(gs, .{ .hire_candidate = idx }) catch |err| {
                    std.debug.print("error: {s}\n", .{@errorName(err)});
                    continue;
                };
                const p = gs.person(r.hired).?;
                std.debug.print("hired #{d}: {s} {s} ({s} {s})\n", .{ @intFromEnum(r.hired), p.first_name, p.last_name, @tagName(p.experience()), @tagName(p.role) });
                continue;
            } else |_| {}
            const role = std.meta.stringToEnum(game.person.Role, role_str) orelse {
                std.debug.print("unknown role '{s}'\n", .{role_str});
                continue;
            };
            const first = tokens.next() orelse "New";
            const last = tokens.next() orelse "Recruit";
            const r = try game.commands.execute(gs, .{ .hire = .{ .first = first, .last = last, .role = role } });
            std.debug.print("hired #{d}\n", .{@intFromEnum(r.hired)});
        } else if (std.mem.eql(u8, verb, "fire")) {
            const id_str = tokens.next() orelse continue;
            const id = std.fmt.parseInt(u32, id_str, 10) catch continue;
            _ = game.commands.execute(gs, .{ .fire = @enumFromInt(id) }) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("person #{d} resigned\n", .{id});
        } else {
            std.debug.print("unknown command '{s}'\n", .{verb});
        }
    }
}
