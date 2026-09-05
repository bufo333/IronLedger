//! The command line shared by both frontends (Stage 12.18): one parser
//! from verb + tokens to `commands.Command`, the verb list the TUI
//! completes and the REPL prints, one-line usage strings, and the
//! human-readable refusal text for every `commands.Error`. Frontend-only
//! verbs (day, save, quit, screens, print views) stay in their frontends.
//! No MekHQ counterpart — MekHQ has no scripting console.

const std = @import("std");
const game = @import("../root.zig");
const types = game.types;
const Command = game.commands.Command;
const Treasury = game.state.Treasury;

pub const ParseError = error{ BadArguments, BadSite, BadNumber };

pub fn parseSite(tok: []const u8) ParseError!types.Site {
    if (std.mem.eql(u8, tok, "outfit")) return .outfit;
    if (std.mem.startsWith(u8, tok, "co:")) return .{ .company = @enumFromInt(std.fmt.parseInt(u32, tok[3..], 10) catch return error.BadSite) };
    if (std.mem.startsWith(u8, tok, "hq:")) return .{ .hq = @enumFromInt(std.fmt.parseInt(u32, tok[3..], 10) catch return error.BadSite) };
    return error.BadSite;
}

pub fn parseTreasury(tok: []const u8) ParseError!Treasury {
    return switch (try parseSite(tok)) {
        .outfit => .outfit,
        .hq => |id| .{ .hq = id },
        .company => |id| .{ .company = id },
    };
}

pub fn num(comptime T: type, tok: ?[]const u8) ParseError!T {
    return std.fmt.parseInt(T, tok orelse return error.BadArguments, 10) catch return error.BadNumber;
}

pub fn need(tok: ?[]const u8) ParseError![]const u8 {
    return tok orelse error.BadArguments;
}

pub fn parseCommand(verb: []const u8, tokens: *std.mem.TokenIterator(u8, .scalar)) ParseError!?Command {
    const eq = std.mem.eql;
    if (eq(u8, verb, "transfer")) {
        return .{ .transfer = .{ .from = try parseTreasury(try need(tokens.next())), .to = try parseTreasury(try need(tokens.next())), .amount = try num(i64, tokens.next()) } };
    }
    if (eq(u8, verb, "admit")) return .{ .admit = @enumFromInt(try num(u32, tokens.next())) };
    if (eq(u8, verb, "depot")) return .{ .depot = @enumFromInt(try num(u32, tokens.next())) };
    if (eq(u8, verb, "move")) return .{ .move_unit = .{ .unit = @enumFromInt(try num(u32, tokens.next())), .force = @enumFromInt(try num(u32, tokens.next())) } };
    if (eq(u8, verb, "newlance")) {
        // newlance co:N [line|air|mash|mess|salvage|security|transport] <name>
        const site = try parseSite(try need(tokens.next()));
        if (site != .company) return error.BadSite;
        var kind: game.force.NewLanceKind = .line;
        var name = std.mem.trim(u8, tokens.rest(), " ");
        var words = std.mem.tokenizeScalar(u8, name, ' ');
        if (words.next()) |first| {
            if (eq(u8, first, "line")) {
                name = std.mem.trim(u8, words.rest(), " ");
            } else if (eq(u8, first, "air")) {
                kind = .air;
                name = std.mem.trim(u8, words.rest(), " ");
            } else if (std.meta.stringToEnum(game.force.SupportLanceKind, first)) |sk| {
                kind = .{ .support = sk };
                name = std.mem.trim(u8, words.rest(), " ");
            }
        }
        if (name.len == 0) return error.BadArguments;
        return .{ .new_lance = .{ .company = site.company, .name = name, .kind = kind } };
    }
    if (eq(u8, verb, "wing")) {
        const site = try parseSite(try need(tokens.next()));
        if (site != .company) return error.BadSite;
        return .{ .raise_air_company = site.company };
    }
    if (eq(u8, verb, "role")) {
        const fid: types.ForceId = @enumFromInt(try num(u32, tokens.next()));
        const role = std.meta.stringToEnum(game.force.LanceRole, try need(tokens.next())) orelse return error.BadArguments;
        return .{ .set_role = .{ .force = fid, .role = role } };
    }
    if (eq(u8, verb, "repay")) return .{ .repay_loan = .{ .index = try num(usize, tokens.next()), .amount = try num(i64, tokens.next()) } };
    if (eq(u8, verb, "sell")) return .{ .sell_unit = @enumFromInt(try num(u32, tokens.next())) };
    if (eq(u8, verb, "raise")) {
        const site = try parseSite(try need(tokens.next()));
        if (site != .hq) return error.BadSite;
        const name = std.mem.trim(u8, tokens.rest(), " ");
        if (name.len == 0) return error.BadArguments;
        return .{ .raise_company = .{ .name = name, .hq = site.hq } };
    }
    if (eq(u8, verb, "crew")) {
        const site = try parseSite(try need(tokens.next()));
        if (site != .company) return error.BadSite;
        return .{ .crew_company = site.company };
    }
    if (eq(u8, verb, "trim")) {
        const site = try parseSite(try need(tokens.next()));
        if (site != .company) return error.BadSite;
        return .{ .trim_stock = site.company };
    }
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
        return .{ .take_loan = .{ .principal = try num(i64, tokens.next()), .term_months = if (tokens.next()) |t| (std.fmt.parseInt(u16, t, 10) catch return error.BadNumber) else 12 } };
    }
    if (eq(u8, verb, "accept")) {
        // accept <offer#> <co:N | N>
        const idx = try num(usize, tokens.next());
        const tok = try need(tokens.next());
        const company: types.ForceId = if (std.fmt.parseInt(u32, tok, 10)) |n| @enumFromInt(n) else |_| blk: {
            const site = try parseSite(tok);
            if (site != .company) return error.BadSite;
            break :blk site.company;
        };
        return .{ .accept_contract = .{ .offer_index = idx, .company = company } };
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
        // assign <unit> [pilot|tech] <person> — no slot word: the person's
        // role decides. unassign <unit> [pilot|tech] — no slot word: both.
        const unit: types.UnitId = @enumFromInt(try num(u32, tokens.next()));
        var slot: game.state.Slot = .any;
        var person_tok: ?[]const u8 = null;
        if (tokens.next()) |second| {
            if (std.meta.stringToEnum(game.state.Slot, second)) |s| slot = s else person_tok = second;
        }
        if (verb[0] == 'u') return .{ .unassign = .{ .unit = unit, .slot = slot } };
        const pid = if (person_tok) |t| (std.fmt.parseInt(u32, t, 10) catch return error.BadNumber) else try num(u32, tokens.next());
        return .{ .assign = .{ .unit = unit, .slot = slot, .person = @enumFromInt(pid) } };
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
        // fabricate [hq:N] <comp_*> [qty] — no HQ named = the outfit's seat
        var tok = try need(tokens.next());
        var hq_id: types.HqId = .none;
        if (std.mem.startsWith(u8, tok, "hq:")) {
            const site = try parseSite(tok);
            hq_id = site.hq;
            tok = try need(tokens.next());
        }
        const qty = std.fmt.parseInt(u32, tokens.next() orelse "1", 10) catch return error.BadNumber;
        return .{ .fabricate = .{ .hq = hq_id, .part_key = tok, .quantity = qty } };
    }
    if (eq(u8, verb, "hire")) {
        // hire <candidate#> (from the hall) | hire <role> <first> <last>
        const first_tok = try need(tokens.next());
        if (std.fmt.parseInt(usize, first_tok, 10)) |idx| return .{ .hire_candidate = idx } else |_| {}
        const role = std.meta.stringToEnum(game.person.Role, first_tok) orelse return error.BadArguments;
        return .{ .hire = .{ .first = tokens.next() orelse "New", .last = tokens.next() orelse "Recruit", .role = role } };
    }
    if (eq(u8, verb, "start")) {
        // start <LC|DC|FS|CC|FWL> <profession> <name>
        const origin = std.meta.stringToEnum(game.commander.Faction, try need(tokens.next())) orelse return error.BadArguments;
        const profession = std.meta.stringToEnum(game.commander.Profession, try need(tokens.next())) orelse return error.BadArguments;
        const name = std.mem.trim(u8, tokens.rest(), " ");
        return .{ .create_commander = .{ .name = if (name.len > 0) name else "Commander", .origin = origin, .profession = profession } };
    }
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
    if (eq(u8, verb, "leave")) return .{ .leave = .{ .person = @enumFromInt(try num(u32, tokens.next())), .days = if (tokens.next()) |t| (std.fmt.parseInt(u16, t, 10) catch return error.BadNumber) else 7 } };
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


pub fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.InsufficientTreasury => "not enough money in that treasury — transfer funds first",
        error.KeepStocked => "that would drop the line under its keep-stocked minimum — lower the policy first (K)",
        error.StorageFull => "the destination cannot hold that tonnage",
        error.CompanyDeployed => "that company is deployed",
        error.NotReachable => "outside your influence rings and beachhead bands",
        error.CapacityFull => "that HQ has no free company slot — a field HQ hosts none (HQ screen: T raises it to regional); a regional HQ hosts one",
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
        error.PersonAway => "pool hulls sit at the outfit's seat — that person's company is not home there",
        error.NoAirSlot => "no air wing slot: the home HQ needs a spaceport at level 3 (brigade HQs host one from the start), and a company has one wing",
        error.NoSupportSlot => "the support company is full for this HQ, or its facilities can't stand up that lance (mess needs a mess hall ≥ 2, MASH a hospital, logistics a warehouse)",
        error.NoBerth => "no free berth at that HQ — spaceport levels add dropship berths; a jumpship berth needs spaceport 4 and comms 3",
        error.NoJumpship => "a dedicated line (level 3) needs a crewed jumpship berthed at one end",
        error.WrongHullKind => "fighters fly in air lances, meks walk in line lances, and ships hold berths",
        else => @errorName(err),
    };
}

pub const verbs = [_][]const u8{
    "admit",
    "repay",
    "sell",
    "sellhq",
    "disband",
    "depot",
    "role",
    "supplypolicy",
    "move",
    "newlance",
    "stockpolicy",
    "autoadmit",
    "sellstock",
    "trim",
    "raise",
    "crew",
    "transfer",
    "policy",
    "loan",
    "accept",
    "resolve",
    "order",
    "ship",
    "buy",
    "assign",
    "unassign",
    "autoassign",
    "autostaff",
    "upgrade",
    "tier",
    "fabricate",
    "hire",
    "recruit",
    "fire",
    "post",
    "train",
    "triage",
    "leave",
    "mothball",
    "activate",
    "complete",
    "recall",
    "found",
    "link",
    "assignco",
    "newco",
    "newco@",
    "xfer",
    "rename",
    "refit",
    "wing",
    "start",
};

/// One-line usage for a verb (null: not a command verb).
pub fn usage(verb: []const u8) ?[]const u8 {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "admit", "admit <person>" },
        .{ "repay", "repay <loan#> <amount>" },
        .{ "sell", "sell <unit>" },
        .{ "sellhq", "sellhq hq:N" },
        .{ "disband", "disband co:N" },
        .{ "depot", "depot <unit>" },
        .{ "role", "role <lance id> fighting|defense|scouting|training|unassigned" },
        .{ "supplypolicy", "supplypolicy co:N <days> <max tons> [battles]  (0 days removes)" },
        .{ "move", "move <unit> <lance id>" },
        .{ "newlance", "newlance co:N [line|air|mash|mess|salvage|security|transport] <name>" },
        .{ "stockpolicy", "stockpolicy hq:N <part> <min> [target]  (0 target removes)" },
        .{ "autoadmit", "autoadmit on|off" },
        .{ "sellstock", "sellstock hq:N <part> [qty]" },
        .{ "trim", "trim co:N" },
        .{ "raise", "raise hq:N <name>" },
        .{ "crew", "crew co:N" },
        .{ "transfer", "transfer <outfit|hq:N|co:N> <outfit|hq:N|co:N> <amount>" },
        .{ "policy", "policy <hq:N|co:N> <floor> <monthly cap>  (0 removes)" },
        .{ "loan", "loan <amount> [months]" },
        .{ "accept", "accept <offer#> <co:N|N>" },
        .{ "resolve", "resolve <event#> <option#>" },
        .{ "order", "order <part> [qty] [hq:N|co:N]" },
        .{ "ship", "ship <part> <qty> <from site> <to site>" },
        .{ "buy", "buy <listing#>" },
        .{ "assign", "assign <unit> [pilot|tech] <person>  (no slot word: the role decides)" },
        .{ "unassign", "unassign <unit> [pilot|tech]  (no slot word: both)" },
        .{ "autoassign", "autoassign co:N" },
        .{ "autostaff", "autostaff hq:N" },
        .{ "upgrade", "upgrade hq:N <mek_bay|warehouse|hospital|mess|training_ground|hiring_hall|comms|spaceport>" },
        .{ "tier", "tier hq:N  (field → regional)" },
        .{ "fabricate", "fabricate [hq:N] <comp_*> [qty]" },
        .{ "hire", "hire <candidate#> | hire <role> <first> <last>" },
        .{ "recruit", "recruit <role>" },
        .{ "fire", "fire <person>" },
        .{ "post", "post <person> hq:N" },
        .{ "train", "train <person> <skill>" },
        .{ "triage", "triage <person> <priority>" },
        .{ "leave", "leave <person> [days]" },
        .{ "mothball", "mothball <unit>" },
        .{ "activate", "activate <unit>" },
        .{ "complete", "complete <contract id>" },
        .{ "recall", "recall co:N" },
        .{ "found", "found <planet key> <name>" },
        .{ "link", "link hq:A hq:B [level 1-3]" },
        .{ "assignco", "assignco co:N hq:M" },
        .{ "newco", "newco <name>" },
        .{ "newco@", "newco@ hq:N <name>" },
        .{ "xfer", "xfer unit|person <id> co:N" },
        .{ "rename", "rename outfit|<force id> <name>" },
        .{ "refit", "refit <unit> remove <slot>|install <loc> <part>|clear|commit" },
        .{ "wing", "wing co:N" },
        .{ "start", "start <LC|DC|FS|CC|FWL> <profession> <name>" },
    };
    for (table) |row| if (std.mem.eql(u8, row[0], verb)) return row[1];
    return null;
}

test "command line parses the common verbs" {
    var it = std.mem.tokenizeScalar(u8, "outfit hq:1 500000", ' ');
    const cmd = (try parseCommand("transfer", &it)).?;
    try std.testing.expectEqual(@as(i64, 500000), cmd.transfer.amount);
    try std.testing.expect(cmd.transfer.to == .hq);
    var it2 = std.mem.tokenizeScalar(u8, "3 tech 67", ' ');
    const cmd2 = (try parseCommand("assign", &it2)).?;
    try std.testing.expectEqual(@as(u32, 67), @intFromEnum(cmd2.assign.person));
    var it2b = std.mem.tokenizeScalar(u8, "3 67", ' ');
    const cmd2b = (try parseCommand("assign", &it2b)).?;
    try std.testing.expect(cmd2b.assign.slot == .any and @intFromEnum(cmd2b.assign.person) == 67);
    var it3 = std.mem.tokenizeScalar(u8, "galatea Forward Base", ' ');
    const cmd3 = (try parseCommand("found", &it3)).?;
    try std.testing.expectEqualStrings("Forward Base", cmd3.found_hq.name);
    var it4 = std.mem.tokenizeScalar(u8, "", ' ');
    try std.testing.expectEqual(@as(?Command, null), try parseCommand("frobnicate", &it4));
    var it5 = std.mem.tokenizeScalar(u8, "x", ' ');
    try std.testing.expectError(error.BadArguments, parseCommand("hire", &it5));
    // REPL forms the parser learned in 12.18.
    var it6 = std.mem.tokenizeScalar(u8, "mekwarrior Grayson Carlyle", ' ');
    const cmd6 = (try parseCommand("hire", &it6)).?;
    try std.testing.expectEqualStrings("Carlyle", cmd6.hire.last);
    var it7 = std.mem.tokenizeScalar(u8, "LC quartermaster Erik Kalmar", ' ');
    const cmd7 = (try parseCommand("start", &it7)).?;
    try std.testing.expectEqualStrings("Erik Kalmar", cmd7.create_commander.name);
    var it8 = std.mem.tokenizeScalar(u8, "0 1", ' ');
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum((try parseCommand("accept", &it8)).?.accept_contract.company));
    var it9 = std.mem.tokenizeScalar(u8, "comp_arm 2", ' ');
    const cmd9 = (try parseCommand("fabricate", &it9)).?;
    try std.testing.expectEqual(types.HqId.none, cmd9.fabricate.hq);
    var it10 = std.mem.tokenizeScalar(u8, "co:1 air Sky Lance", ' ');
    try std.testing.expect((try parseCommand("newlance", &it10)).?.new_lance.kind == .air);
}

test "every listed verb parses or fails on arguments — never falls through as unknown" {
    // A verb in `verbs` with no parser branch would tab-complete and then
    // report itself unknown; this catches it.
    for (verbs) |v| {
        try std.testing.expect(usage(v) != null);
        var it = std.mem.tokenizeScalar(u8, "", ' ');
        const r = parseCommand(v, &it) catch continue; // BadArguments etc. is fine
        if (r == null) {
            std.debug.print("verb '{s}' has no parser branch\n", .{v});
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(usage("frobnicate") == null);
}
