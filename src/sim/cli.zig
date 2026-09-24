//! The command line shared by both frontends (Stage 12.18): one parser
//! from verb + tokens to `commands.Command`, the verb list the TUI
//! completes and the REPL prints, one-line usage strings, and the
//! human-readable refusal text for every `commands.Error`. The terminal
//! client's own verbs (day, save, screens) parse here too, as a
//! `ClientVerb`; the REPL's print views stay in the REPL.
//! No MekHQ counterpart — MekHQ has no scripting console.

const std = @import("std");
const person_mod = @import("../domain/person.zig");
const force_mod = @import("../domain/force.zig");
const game = @import("../root.zig");
const types = game.types;
const Command = game.commands.Command;
const Treasury = game.state.Treasury;

pub const ParseError = error{ BadArguments, BadSite, BadNumber };

/// The longest advance one `day` asks for: a year. An advance still stops
/// on every hold and contact inside it.
pub const max_advance_days: u32 = 365;

/// `day [n] [force]`: how many days, and whether to skip the end-turn
/// checklist.
pub const Day = struct { days: u32 = 1, force: bool = false };

/// Both frontends' `day`. Every word is used: a count from 1 to
/// `max_advance_days` at most once, `force` (or `!`) at most once;
/// anything else refuses rather than advancing a default.
pub fn parseDay(tokens: *std.mem.TokenIterator(u8, .scalar)) ParseError!Day {
    var d: Day = .{};
    var counted = false;
    while (tokens.next()) |t| {
        if (std.mem.eql(u8, t, "force") or std.mem.eql(u8, t, "!")) {
            if (d.force) return error.BadArguments;
            d.force = true;
        } else {
            if (counted) return error.BadArguments;
            d.days = std.fmt.parseInt(u32, t, 10) catch return error.BadNumber;
            if (d.days == 0 or d.days > max_advance_days) return error.BadNumber;
            counted = true;
        }
    }
    return d;
}

/// The terminal client's own verbs: time, saving and the screens a
/// command opens. Parsed as strictly as a command.
pub const ClientVerb = union(enum) {
    day: Day,
    save,
    quit,
    help,
    settings,
    emblem,
    manning: types.ForceId,
    readiness,
    summary,
    music,
};

pub const client_verbs = std.meta.fieldNames(ClientVerb);

/// A client verb and its tokens → the verb, or null when `verb` is not
/// one. Nothing may follow a verb that takes no arguments.
pub fn parseClientVerb(verb: []const u8, tokens: *std.mem.TokenIterator(u8, .scalar)) ParseError!?ClientVerb {
    const tag = std.meta.stringToEnum(std.meta.Tag(ClientVerb), verb) orelse return null;
    const cv: ClientVerb = switch (tag) {
        .day => .{ .day = try parseDay(tokens) },
        .manning => blk: {
            const site = try parseSite(try need(tokens.next()));
            if (site != .company) return error.BadSite;
            break :blk .{ .manning = site.company };
        },
        inline else => |t| @unionInit(ClientVerb, @tagName(t), {}),
    };
    if (tokens.next() != null) return error.BadArguments;
    return cv;
}

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

/// The rest of the line as one argument (a name), consumed, so the
/// trailing-token check sees nothing left.
fn takeRest(tokens: *std.mem.TokenIterator(u8, .scalar)) []const u8 {
    const rest = std.mem.trim(u8, tokens.rest(), " ");
    tokens.index = tokens.buffer.len;
    return rest;
}

/// A verb and its tokens → a command, or null when the verb is not a
/// command verb. Every token must be used: anything left over after a
/// complete command is `BadArguments`, never silently dropped.
pub fn parseCommand(verb: []const u8, tokens: *std.mem.TokenIterator(u8, .scalar)) ParseError!?Command {
    const cmd = try parseVerb(verb, tokens) orelse return null;
    if (tokens.next() != null) return error.BadArguments;
    return cmd;
}

fn parseVerb(verb: []const u8, tokens: *std.mem.TokenIterator(u8, .scalar)) ParseError!?Command {
    const eq = std.mem.eql;
    if (eq(u8, verb, "transfer")) {
        return .{ .transfer = .{ .from = try parseTreasury(try need(tokens.next())), .to = try parseTreasury(try need(tokens.next())), .amount = try num(i64, tokens.next()) } };
    }
    if (eq(u8, verb, "admit")) return .{ .admit = @enumFromInt(try num(u32, tokens.next())) };
    if (eq(u8, verb, "depot")) return .{ .depot = @enumFromInt(try num(u32, tokens.next())) };
    if (eq(u8, verb, "replace")) return .{ .replace_gear = @enumFromInt(try num(u32, tokens.next())) };
    if (eq(u8, verb, "sop")) {
        // sop clear <event> — bare `sop` is the REPL's listing view.
        if (!eq(u8, try need(tokens.next()), "clear")) return error.BadArguments;
        return .{ .clear_standing_order = try need(tokens.next()) };
    }
    if (eq(u8, verb, "move")) return .{ .move_unit = .{ .unit = @enumFromInt(try num(u32, tokens.next())), .force = @enumFromInt(try num(u32, tokens.next())) } };
    if (eq(u8, verb, "newlance")) {
        // newlance co:N [line|air|mash|mess|salvage|security|transport] <name>
        const site = try parseSite(try need(tokens.next()));
        if (site != .company) return error.BadSite;
        var kind: game.force.NewLanceKind = .line;
        var name = takeRest(tokens);
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
    if (eq(u8, verb, "roe")) {
        const site = try parseSite(try need(tokens.next()));
        if (site != .company) return error.BadSite;
        const roe = std.meta.stringToEnum(game.force.Roe, try need(tokens.next())) orelse return error.BadArguments;
        return .{ .set_roe = .{ .company = site.company, .roe = roe } };
    }
    if (eq(u8, verb, "role")) {
        const fid: types.ForceId = @enumFromInt(try num(u32, tokens.next()));
        const role = std.meta.stringToEnum(game.force.LanceRole, try need(tokens.next())) orelse return error.BadArguments;
        return .{ .set_role = .{ .force = fid, .role = role } };
    }
    if (eq(u8, verb, "repay")) return .{ .repay_loan = .{ .index = try num(usize, tokens.next()), .amount = try num(i64, tokens.next()) } };
    if (eq(u8, verb, "sell")) return .{ .sell_unit = @enumFromInt(try num(u32, tokens.next())) };
    if (eq(u8, verb, "strip")) return .{ .strip_unit = @enumFromInt(try num(u32, tokens.next())) };
    if (eq(u8, verb, "raise")) {
        const site = try parseSite(try need(tokens.next()));
        if (site != .hq) return error.BadSite;
        const name = takeRest(tokens);
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
        // No target: twice the minimum. An explicit 0 removes the line.
        const target = if (tokens.next()) |t| std.fmt.parseInt(u32, t, 10) catch return error.BadNumber else min * 2;
        return .{ .set_stock_policy = .{ .hq = site.hq, .part_key = part, .min = min, .target = target } };
    }
    if (eq(u8, verb, "difficulty")) {
        const level = game.difficulty.parse(try need(tokens.next())) orelse return error.BadArguments;
        return .{ .set_difficulty = level };
    }
    if (eq(u8, verb, "loan")) {
        return .{ .take_loan = .{ .principal = try num(i64, tokens.next()), .term_months = if (tokens.next()) |t| (std.fmt.parseInt(u16, t, 10) catch return error.BadNumber) else 12 } };
    }
    if (eq(u8, verb, "promote")) {
        // promote <person> <rank> [unpin]
        const pid: types.PersonId = @enumFromInt(try num(u32, tokens.next()));
        const r = std.meta.stringToEnum(game.rank.Rank, try need(tokens.next())) orelse return error.BadArguments;
        const pin = if (tokens.next()) |t| (if (eq(u8, t, "unpin")) false else return error.BadArguments) else true;
        return .{ .promote = .{ .person = pid, .rank = r, .pin = pin } };
    }
    if (eq(u8, verb, "negotiate")) {
        // negotiate <offer#> advance|salvage|transport|support|rights|pay
        const idx = try num(usize, tokens.next());
        const term = std.meta.stringToEnum(game.contract.NegotiableTerm, try need(tokens.next())) orelse return error.BadArguments;
        return .{ .negotiate = .{ .offer_index = idx, .term = term } };
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
    if (eq(u8, verb, "read")) return .{ .read_report = @enumFromInt(try num(u32, tokens.next())) };
    if (eq(u8, verb, "resolve")) {
        return .{ .resolve_decision = .{ .event = @enumFromInt(try num(u32, tokens.next())), .choice = (try num(usize, tokens.next())) -| 1 } };
    }
    if (eq(u8, verb, "order")) {
        // A failed sourcing roll is reported by the frontends via Result.sourced.
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
        // [year]: an optional trailing 4-digit word of the name is the start year.
        var name = takeRest(tokens);
        var year: u16 = 3025;
        if (std.mem.lastIndexOfScalar(u8, name, ' ')) |sp| {
            if (std.fmt.parseInt(u16, name[sp + 1 ..], 10)) |y| {
                year = y;
                name = std.mem.trim(u8, name[0..sp], " ");
            } else |_| {}
        } else if (std.fmt.parseInt(u16, name, 10)) |y| {
            year = y;
            name = "";
        } else |_| {}
        return .{ .create_commander = .{ .name = if (name.len > 0) name else "Commander", .origin = origin, .profession = profession, .start_year = year } };
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
        // train <person> <skill> | train <person> ability <key> | train co:N [skill]
        const first = try need(tokens.next());
        if (std.mem.startsWith(u8, first, "co:")) {
            const site = try parseSite(first);
            if (site != .company) return error.BadSite;
            const skill: ?types.SkillType = if (tokens.next()) |t| (std.meta.stringToEnum(types.SkillType, t) orelse return error.BadArguments) else null;
            return .{ .train_company = .{ .company = site.company, .skill = skill } };
        }
        const pid: types.PersonId = @enumFromInt(std.fmt.parseInt(u32, first, 10) catch return error.BadNumber);
        const what = try need(tokens.next());
        if (eq(u8, what, "ability")) return .{ .train_ability = .{ .person = pid, .key = try need(tokens.next()) } };
        const skill = std.meta.stringToEnum(types.SkillType, what) orelse return error.BadArguments;
        return .{ .train = .{ .person = pid, .skill = skill } };
    }
    if (eq(u8, verb, "triage")) return .{ .triage = .{ .person = @enumFromInt(try num(u32, tokens.next())), .priority = try num(u8, tokens.next()) } };
    if (eq(u8, verb, "leave")) return .{ .leave = .{ .person = @enumFromInt(try num(u32, tokens.next())), .days = if (tokens.next()) |t| (std.fmt.parseInt(u16, t, 10) catch return error.BadNumber) else 7 } };
    if (eq(u8, verb, "mothball")) return .{ .mothball = @enumFromInt(try num(u32, tokens.next())) };
    if (eq(u8, verb, "activate")) return .{ .reactivate = @enumFromInt(try num(u32, tokens.next())) };
    if (eq(u8, verb, "complete")) return .{ .complete_contract = @enumFromInt(try num(u32, tokens.next())) };
    if (eq(u8, verb, "confirm")) return .{ .confirm_orders = @enumFromInt(try num(u32, tokens.next())) };
    if (eq(u8, verb, "rush")) return .{ .emergency_resupply = @enumFromInt(try num(u32, tokens.next())) };
    if (eq(u8, verb, "recall")) {
        const site = try parseSite(try need(tokens.next()));
        if (site != .company) return error.BadSite;
        return .{ .recall_company = site.company };
    }
    if (eq(u8, verb, "found")) {
        const planet = try need(tokens.next());
        const name = takeRest(tokens);
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
        const name = takeRest(tokens);
        if (name.len == 0) return error.BadArguments;
        return .{ .new_company = name };
    }
    if (eq(u8, verb, "newco@")) {
        const site = try parseSite(try need(tokens.next()));
        if (site != .hq) return error.BadSite;
        const name = takeRest(tokens);
        if (name.len == 0) return error.BadArguments;
        return .{ .new_company_at = .{ .name = name, .hq = site.hq } };
    }
    if (eq(u8, verb, "xfer")) {
        const what = try need(tokens.next());
        const id = try num(u32, tokens.next());
        const site = try parseSite(try need(tokens.next()));
        if (site != .company) return error.BadSite;
        if (eq(u8, what, "unit")) return .{ .transfer_unit = .{ .unit = @enumFromInt(id), .to_company = site.company } };
        if (eq(u8, what, "person")) return .{ .transfer_person = .{ .person = @enumFromInt(id), .to_force = site.company } };
        return error.BadArguments;
    }
    if (eq(u8, verb, "rename")) {
        const what = try need(tokens.next());
        const name = takeRest(tokens);
        if (name.len == 0) return error.BadArguments;
        if (eq(u8, what, "outfit")) return .{ .rename_outfit = name };
        const fid = std.fmt.parseInt(u32, what, 10) catch return error.BadNumber;
        return .{ .rename_force = .{ .force = @enumFromInt(fid), .name = name } };
    }
    if (eq(u8, verb, "buysupport")) {
        const site = try parseSite(try need(tokens.next()));
        if (site != .company) return error.BadSite;
        const kind = std.meta.stringToEnum(force_mod.SupportLanceKind, try need(tokens.next())) orelse return error.BadArguments;
        return .{ .buy_support_hull = .{ .company = site.company, .kind = kind } };
    }
    if (eq(u8, verb, "crest")) return .{ .set_outfit_emblem = try need(tokens.next()) };
    if (eq(u8, verb, "office")) {
        const site = try parseSite(try need(tokens.next()));
        if (site != .hq) return error.BadSite;
        const role = std.meta.stringToEnum(person_mod.Role, try need(tokens.next())) orelse return error.BadArguments;
        const dir = try need(tokens.next());
        const delta: i8 = if (eq(u8, dir, "+")) 1 else if (eq(u8, dir, "-")) -1 else return error.BadArguments;
        return .{ .set_office_staff = .{ .hq = site.hq, .role = role, .delta = delta } };
    }
    if (eq(u8, verb, "shiphome")) {
        const site = try parseSite(try need(tokens.next()));
        if (site != .company) return error.BadSite;
        return .{ .ship_components_home = site.company };
    }
    if (eq(u8, verb, "replacemount")) {
        const unit: types.UnitId = @enumFromInt(try num(u32, tokens.next()));
        return .{ .replace_mount = .{ .unit = unit, .slot_key = try need(tokens.next()) } };
    }
    if (eq(u8, verb, "cover")) {
        const site = try parseSite(try need(tokens.next()));
        if (site != .hq) return error.BadSite;
        const key = try need(tokens.next());
        return .{ .cover_shortfall = .{ .hq = site.hq, .part_key = key, .quantity = try num(u32, tokens.next() orelse "1") } };
    }
    if (eq(u8, verb, "togglemothball")) return .{ .toggle_mothball = @enumFromInt(try num(u32, tokens.next())) };
    if (eq(u8, verb, "cycleroe")) {
        const site = try parseSite(try need(tokens.next()));
        if (site != .company) return error.BadSite;
        return .{ .cycle_roe = site.company };
    }
    if (eq(u8, verb, "cyclerole")) return .{ .cycle_role = @enumFromInt(try num(u32, tokens.next())) };
    if (eq(u8, verb, "cycledifficulty")) {
        const t = tokens.next() orelse "+";
        if (eq(u8, t, "+")) return .{ .cycle_difficulty = 1 };
        if (eq(u8, t, "-")) return .{ .cycle_difficulty = -1 };
        return error.BadArguments;
    }
    if (eq(u8, verb, "shares")) {
        const t = try need(tokens.next());
        if (eq(u8, t, "+")) return .{ .adjust_shares_pct = 5 };
        if (eq(u8, t, "-")) return .{ .adjust_shares_pct = -5 };
        return .{ .set_shares_pct = try num(u8, t) };
    }
    if (eq(u8, verb, "autoadmit")) {
        const arg = tokens.next() orelse return .{ .toggle_auto_admit = {} };
        if (eq(u8, arg, "on") or eq(u8, arg, "yes") or eq(u8, arg, "1")) return .{ .set_auto_admit = true };
        if (eq(u8, arg, "off") or eq(u8, arg, "no") or eq(u8, arg, "0")) return .{ .set_auto_admit = false };
        return error.BadArguments;
    }
    if (eq(u8, verb, "recallidle")) {
        const site = try parseSite(try need(tokens.next()));
        if (site != .company) return error.BadSite;
        return .{ .recall_idle = site.company };
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

/// What both frontends say when a black-market hull purchase is a fraud:
/// the money is gone and no hull exists.
pub const hull_fraud_text = "the black-market fence vanished with the money — no hull";

pub fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.NoSuchCampaign => "no saved campaign has that id — `campaigns` lists them",
        error.SaveNewerThanGame, error.StoreNewerThanGame => "that save was written by a newer version of the game",
        error.UnknownForce => "no force has that id",
        error.UnknownChassis => "no design by that key in the catalogue",
        error.NoSuchChoice => "that decision has no option with that number",
        error.NotADecision => "that event is not a decision",
        error.CommanderExists => "the campaign already has a commander",
        error.NoHomeWorld => "that house has no capital on the map to start from",
        error.UnknownPlanet => "no world by that key on the map",
        error.UnknownPart => "no part by that key in the catalogue",
        error.NotMothballed => "that hull is not in mothballs",
        error.AlreadyMothballed => "that hull is already in mothballs",
        error.NoHq => "the outfit has no HQ for that yet",
        error.PersonUnavailable => "that person is not available: wounded, on leave, away or gone",
        error.AlreadyTraining => "that person is already training",
        error.NotTrained => "that person does not have the skill to build on",
        error.InsufficientXp => "not enough banked XP for that",
        error.AlreadyMastered => "that skill is already as good as it gets",
        error.UnknownTreasury => "no treasury by that name: outfit, hq:N or co:N",
        error.InsufficientStock => "not enough of that part in stock there",
        error.UnknownSite => "no site by that id",
        error.UnknownHq => "no HQ has that id",
        error.NotAComponent => "that part is not a structural component (comp_*)",
        error.NoSuchCandidate => "no hall candidate with that number",
        error.NoRoute => "no supply route links those sites",
        error.ThroughputExceeded => "the supply line cannot carry that many tons this week",
        error.BadLevel => "that level is out of range",
        error.CompanyInTransit => "that company is in transit",
        error.NoPlan => "that hull has no refit plan",
        error.NotAMek => "only meks go through the MekLab",
        error.NoSuchSlot => "that hull has no slot by that key",
        error.BadArguments => "those arguments do not fit the verb",
        error.BadSite => "that is not a site: outfit, hq:N or co:N",
        error.BadNumber => "that is not a number the verb takes",
        error.OutOfMemory => "out of memory — nothing was changed",
        error.NotPng => "that file is not a PNG picture",
        error.Unsupported => "that PNG uses a format the emblem loader does not read (8-bit, non-interlaced only)",
        error.Corrupt => "that picture is damaged",
        error.FileNotFound => "no file by that name",
        error.AccessDenied => "the file could not be opened: permission denied",
        error.StreamTooLong, error.FileTooBig => "that file is too large",
        error.CorruptSave => "that save is damaged and cannot be loaded",
        error.InsufficientTreasury => "not enough money in that treasury — transfer funds first",
        error.AlreadyHome => "that company is already home",
        error.UnderContract => "that company is under contract — recall from the Contracts screen (R there) to accept the breach clause",
        error.HqTreasuryShort => "the board's HQ treasury cannot cover that listing — Ledger t couriers funds there",
        error.UnknownContract => "no contract has that id — `contracts` lists them",
        error.NoContact => "no engagement on that contract is close enough to give orders for",
        error.NothingToRush => "the company's stores already cover the next fight",
        error.CompanyFundsShort => "the company's local funds cannot cover that hull — Ledger t couriers funds to the company (days in transit)",
        error.NothingToShip => "no structural components in those field stores",
        error.MountIsFine => "that mount is fine — a replacement is for damaged or destroyed gear",
        error.MaxLevel => "already at the top: this HQ is regional (or the facility is maxed)",
        error.ProjectInProgress => "a project is already running here — watch PROJECTS",
        error.BadPercent => "a percentage between 0 and 100",
        error.BadYear => "the campaign starts between 3000 and 3060",
        error.KeepStocked => "that would drop the line under its keep-stocked minimum — lower the policy first (K)",
        error.StorageFull => "the destination cannot hold that tonnage",
        error.CompanyDeployed => "that company is deployed — hire at an HQ hall and `xfer person <id> co:N` to send people out to it",
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
        error.Unavailable => "unavailable — that person is busy, or that hull is a wreck / in the bay and takes no refit",
        error.Insolvent => "the outfit treasury is negative — take a loan (Ledger, L) or sell assets (Forces $, X · HQ $) before the day can end",
        error.Bankrupt => "the outfit is bankrupt",
        error.CreditExceeded => "that exceeds the remaining credit line (see the Ledger)",
        error.LastHq => "you cannot sell your only HQ",
        error.HqInUse => "reassign the companies at that HQ first (:assignco co:N hq:M)",
        error.NotWounded => "that person is not wounded",
        error.NoSuchLoan => "no such loan (or nothing to repay)",
        error.NoSuchBattle => "no engagement on record with that id — `battles` lists them",
        error.ReportUnread => "an after-action report is waiting — read it (`battles` lists them, `read <id>` clears one; the Desk opens the sheet on [b])",
        error.DecisionPending => "a battle decision is waiting — answer it (`inbox` lists them, `resolve <id> <n>` answers one; the Desk opens it on [i])",
        error.NoSuchDecision => "no pending decision with that id — `inbox` lists them, each with the id to answer it by",
        error.NoSuchEvent => "no such event — kinds read as the log names them, e.g. smuggler_offer (`sop` lists the ones with a history)",
        error.NoSuchListing => "that listing is gone",
        error.TooManyLances => "that lance is full (4 hulls), or the HQ allows no more lances — :newlance co:N <name> raises one",
        error.SameForce => "that hull belongs to another company — x moves it between companies",
        error.OutOfRange => "that offer is on another HQ's board — only companies based at the HQ that posted it can take it (Contracts [ ] switches boards; `assignco co:N hq:M` rebases a company)",
        error.BayTooSmall => "this bay cannot build that assembly — heavy (_h) needs a mek bay at level 2, assault (_a) level 3 at a regional or brigade HQ; order it instead (a rarity roll) or watch the boards",
        error.WrittenOff => "that wreck is scrap — nothing left to rebuild; `strip <unit>` (Forces $, then s) crates its surviving parts into the home warehouse",
        error.NothingToRepair => "that hull has no structural damage — gear is field work on any hull: its tech fits spares from the hull's site on the weekly pass; `replace <unit>` (Forces R) orders what's destroyed",
        error.NothingToReplace => "no destroyed or missing gear on that hull — damaged gear is fixed by its tech's hours alone, and structure goes to the depot (`depot <unit>`)",
        error.MissingComponents => "structural components missing at the home HQ — order or fabricate them on the Market screen first",
        error.NoBay => "no mek bay that can do structural work — a regional HQ with a mek_bay is needed",
        error.UnitAway => "that hull is away from home — depot work happens at the home HQ",
        error.UnitDeployed => "that hull is with a deployed company — bring the company home first (HQ work like fabrication and orders is unaffected)",
        error.PersonDeployed => "that person is deployed with their company",
        error.PersonAway => "pool hulls sit at the outfit's seat — that person's company is not home there",
        error.AlreadyNegotiated => "that offer has had its negotiation round — take it or leave it",
        error.UnknownAbility => "no such ability — gunnery_specialist, piloting_specialist, dodge, toughness, iron_man, cool_under_fire, tactical_genius, edge",
        error.AlreadyLearned => "they already have that ability",
        error.TermAtCap => "that term is already the best the employer will give",
        error.NoAirSlot => "no air wing slot: the home HQ needs a spaceport at level 3 (brigade HQs host one from the start), and a company has one wing",
        error.NoSupportSlot => "the support company is full for this HQ, or its facilities can't stand up that lance (mess needs a mess hall ≥ 2, MASH a hospital, logistics a warehouse)",
        error.NoBerth => "no free berth at that HQ — spaceport levels add dropship berths; a jumpship berth needs spaceport 4 and comms 3",
        error.NoJumpship => "a dedicated line (level 3) needs a crewed jumpship berthed at one end",
        error.WrongHullKind => "fighters fly in air lances, meks walk in line lances, and ships hold berths",
        else => "an unexpected failure — nothing was changed",
    };
}

/// The words the `:` line completes after a verb: sites, roles, skills,
/// facilities, part and world keys.
pub fn completionPool(alloc: std.mem.Allocator, gs: *game.state.GameState) ![]const []const u8 {
    var pool: std.ArrayListUnmanaged([]const u8) = .empty;
    try pool.append(alloc, "outfit");
    try pool.append(alloc, "pilot");
    try pool.append(alloc, "tech");
    var hit = gs.hqs.iterator();
    while (hit.next()) |e| try pool.append(alloc, try std.fmt.allocPrint(alloc, "hq:{d}", .{@intFromEnum(e.value_ptr.id)}));
    var fit = gs.forces.iterator();
    while (fit.next()) |e| if (e.value_ptr.echelon == .company) try pool.append(alloc, try std.fmt.allocPrint(alloc, "co:{d}", .{@intFromEnum(e.value_ptr.id)}));
    inline for (@typeInfo(game.hq.FacilityKind).@"enum".fields) |f| try pool.append(alloc, f.name);
    inline for (@typeInfo(person_mod.Role).@"enum".fields) |f| try pool.append(alloc, f.name);
    inline for (@typeInfo(types.SkillType).@"enum".fields) |f| try pool.append(alloc, f.name);
    for (game.part.catalog) |p| try pool.append(alloc, p.key);
    for (game.planet.catalog) |p| try pool.append(alloc, p.key);
    return pool.toOwnedSlice(alloc);
}

pub const verbs = [_][]const u8{
    "buysupport",
    "crest",
    "office",
    "shiphome",
    "replacemount",
    "cover",
    "togglemothball",
    "cycleroe",
    "cyclerole",
    "cycledifficulty",
    "shares",
    "recallidle",
    "admit",
    "repay",
    "sell",
    "strip",
    "sellhq",
    "disband",
    "depot",
    "replace",
    "sop",
    "role",
    "roe",
    "supplypolicy",
    "move",
    "newlance",
    "stockpolicy",
    "autoadmit",
    "difficulty",
    "sellstock",
    "trim",
    "raise",
    "crew",
    "transfer",
    "policy",
    "loan",
    "accept",
    "negotiate",
    "promote",
    "read",
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
    "confirm",
    "rush",
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
        .{ "buysupport", "buysupport co:N <mash|security|mess|salvage|transport>" },
        .{ "crest", "crest <preset name or 3x8 art>" },
        .{ "office", "office hq:N <admin role> +|-" },
        .{ "shiphome", "shiphome co:N" },
        .{ "replacemount", "replacemount <unit> <slot key>" },
        .{ "cover", "cover hq:N <comp_key> [qty]" },
        .{ "togglemothball", "togglemothball <unit>" },
        .{ "cycleroe", "cycleroe co:N" },
        .{ "cyclerole", "cyclerole <lance id>" },
        .{ "cycledifficulty", "cycledifficulty [+|-]" },
        .{ "shares", "shares <percent>|+|-  (share of contract income paid to shareholders at completion)" },
        .{ "day", "day [n] [force]  (1-365 days; force skips the end-turn checklist)" },
        .{ "manning", "manning co:N" },
        .{ "recallidle", "recallidle co:N" },
        .{ "admit", "admit <person>" },
        .{ "repay", "repay <loan#> <amount>" },
        .{ "sell", "sell <unit>" },
        .{ "strip", "strip <unit>" },
        .{ "sellhq", "sellhq hq:N" },
        .{ "disband", "disband co:N" },
        .{ "depot", "depot <unit>" },
        .{ "replace", "replace <unit>" },
        .{ "sop", "sop clear <event>   (standing orders; `sop` lists them)" },
        .{ "role", "role <lance id> fighting|defense|scouting|training|unassigned" },
        .{ "roe", "roe co:N hold|standard|cautious" },
        .{ "supplypolicy", "supplypolicy co:N <days> <max tons> [battles]  (0 days removes)" },
        .{ "move", "move <unit> <lance id>" },
        .{ "newlance", "newlance co:N [line|air|mash|mess|salvage|security|transport] <name>" },
        .{ "stockpolicy", "stockpolicy hq:N <part> <min> [target]  (0 target removes)" },
        .{ "autoadmit", "autoadmit [on|off]  (bare: toggle)" },
        .{ "difficulty", "difficulty green|regular|veteran|elite  (Settings [d]; economy and opposition, never the dice)" },
        .{ "sellstock", "sellstock hq:N <part> [qty]" },
        .{ "trim", "trim co:N" },
        .{ "raise", "raise hq:N <name>" },
        .{ "crew", "crew co:N" },
        .{ "transfer", "transfer <outfit|hq:N|co:N> <outfit|hq:N|co:N> <amount>" },
        .{ "policy", "policy <hq:N|co:N> <floor> <monthly cap>  (0 removes)" },
        .{ "loan", "loan <amount> [months]" },
        .{ "accept", "accept <offer#> <co:N|N>" },
        .{ "negotiate", "negotiate <offer#> advance|salvage|transport|support|rights|pay  (one round per offer)" },
        .{ "promote", "promote <person> recruit|private|corporal|sergeant|master_sergeant|lieutenant|captain|major|colonel [unpin]" },
        .{ "read", "read <battle-id> (clears the after-action that holds the turn)" },
        .{ "resolve", "resolve <event-id> <option#> (the id the inbox prints, not the row)" },
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
        .{ "train", "train <person> <skill> | train <person> ability gunnery_specialist|piloting_specialist|dodge|toughness|iron_man|cool_under_fire|tactical_genius|edge | train co:N [skill]  (the whole company, at their trades)" },
        .{ "triage", "triage <person> <priority>" },
        .{ "leave", "leave <person> [days]" },
        .{ "mothball", "mothball <unit>" },
        .{ "activate", "activate <unit>" },
        .{ "complete", "complete <contract id>" },
        .{ "confirm", "confirm <contract id>   (battle orders given; see `briefing <contract id>`)" },
        .{ "rush", "rush <contract id>   (emergency resupply on the contract world before contact)" },
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
        .{ "start", "start <LC|DC|FS|CC|FWL> <profession> <name> [year 3000–3060]" },
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
    // REPL forms: hire by role and name, start with a spaced name.
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

fn parseLine(line: []const u8) ParseError!?Command {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const verb = it.next() orelse return null;
    return parseCommand(verb, &it);
}

test "a token left over after a complete command is refused, not dropped" {
    try std.testing.expectError(error.BadArguments, parseLine("sell 3 4"));
    try std.testing.expectError(error.BadArguments, parseLine("roe co:1 cautious now"));
    try std.testing.expectError(error.BadArguments, parseLine("confirm 1 2"));
    // A name takes the rest of the line, spaces and all.
    try std.testing.expectEqualStrings("Bravo Company", (try parseLine("raise hq:1 Bravo Company")).?.raise_company.name);
    try std.testing.expectEqualStrings("Sky Lance", (try parseLine("newlance co:1 air Sky Lance")).?.new_lance.name);
    try std.testing.expectEqualStrings("Forward Base", (try parseLine("found galatea Forward Base")).?.found_hq.name);
}

test "day parses strictly: a count once, force once, nothing else" {
    const t = std.testing;
    const parse = struct {
        fn f(line: []const u8) ParseError!Day {
            var it = std.mem.tokenizeScalar(u8, line, ' ');
            return parseDay(&it);
        }
    }.f;
    try t.expectEqual(Day{}, try parse(""));
    try t.expectEqual(Day{ .days = 3 }, try parse("3"));
    try t.expectEqual(Day{ .days = 7, .force = true }, try parse("7 force"));
    try t.expectEqual(Day{ .days = 2, .force = true }, try parse("! 2"));
    try t.expectError(error.BadNumber, parse("nonsense"));
    try t.expectError(error.BadNumber, parse("-1"));
    try t.expectError(error.BadNumber, parse("0"));
    try t.expectError(error.BadNumber, parse("366"));
    try t.expectError(error.BadArguments, parse("1 2"));
    try t.expectError(error.BadArguments, parse("force force"));
}

test "client verbs refuse trailing words; manning takes a company" {
    const t = std.testing;
    const parse = struct {
        fn f(line: []const u8) ParseError!?ClientVerb {
            var it = std.mem.tokenizeScalar(u8, line, ' ');
            return parseClientVerb(it.next().?, &it);
        }
    }.f;
    try t.expect((try parse("save")).? == .save);
    try t.expectError(error.BadArguments, parse("save now"));
    try t.expectError(error.BadArguments, parse("quit please"));
    try t.expectError(error.BadNumber, parse("day junk"));
    try t.expectEqual(@as(u32, 3), (try parse("day 3")).?.day.days);
    try t.expectEqual(@as(types.ForceId, @enumFromInt(2)), (try parse("manning co:2")).?.manning);
    try t.expectError(error.BadArguments, parse("manning co:2 x"));
    try t.expectError(error.BadSite, parse("manning hq:1"));
    try t.expect((try parse("accept")) == null);
    try t.expect(usage("day") != null and usage("manning") != null);
}

test "stockpolicy: no target is twice the minimum, an explicit 0 removes" {
    const t = std.testing;
    const parse = struct {
        fn f(line: []const u8) !Command {
            var it = std.mem.tokenizeScalar(u8, line, ' ');
            return (try parseCommand(it.next().?, &it)).?;
        }
    }.f;
    try t.expectEqual(@as(u32, 10), (try parse("stockpolicy hq:1 armor 5")).set_stock_policy.target);
    try t.expectEqual(@as(u32, 0), (try parse("stockpolicy hq:1 armor 5 0")).set_stock_policy.target);
    try t.expectEqual(@as(u32, 8), (try parse("stockpolicy hq:1 armor 5 8")).set_stock_policy.target);
}

test "shares and autoadmit each parse in one place, every form they document" {
    try std.testing.expectEqual(@as(i8, 5), (try parseLine("shares +")).?.adjust_shares_pct);
    try std.testing.expectEqual(@as(i8, -5), (try parseLine("shares -")).?.adjust_shares_pct);
    try std.testing.expectEqual(@as(u8, 20), (try parseLine("shares 20")).?.set_shares_pct);
    try std.testing.expect((try parseLine("autoadmit")).? == .toggle_auto_admit);
    try std.testing.expect((try parseLine("autoadmit on")).?.set_auto_admit);
    try std.testing.expect(!(try parseLine("autoadmit off")).?.set_auto_admit);
    try std.testing.expectError(error.BadArguments, parseLine("autoadmit maybe"));
}

test "a word that names a choice must be one of the choices" {
    try std.testing.expectError(error.BadArguments, parseLine("xfer hull 3 co:1"));
    try std.testing.expect((try parseLine("xfer person 3 co:1")).? == .transfer_person);
    try std.testing.expect((try parseLine("xfer unit 3 co:1")).? == .transfer_unit);
    try std.testing.expectError(error.BadArguments, parseLine("office hq:1 admin_command up"));
    try std.testing.expectEqual(@as(i8, -1), (try parseLine("office hq:1 admin_command -")).?.set_office_staff.delta);
    try std.testing.expectError(error.BadArguments, parseLine("promote 3 captain pinned"));
    try std.testing.expect(!(try parseLine("promote 3 captain unpin")).?.promote.pin);
    try std.testing.expectError(error.BadArguments, parseLine("cycledifficulty down"));
}

test "every verb is listed once" {
    for (verbs, 0..) |v, i| {
        for (verbs[i + 1 ..]) |w| try std.testing.expect(!std.mem.eql(u8, v, w));
    }
}

test "every command refusal and parse error has a sentence, never an error name" {
    inline for (@typeInfo(game.commands.Error).error_set.?) |e| {
        const text = errorText(@field(anyerror, e.name));
        try std.testing.expect(!std.mem.eql(u8, text, "an unexpected failure — nothing was changed"));
        try std.testing.expect(!std.mem.eql(u8, text, e.name));
    }
    inline for (@typeInfo(ParseError).error_set.?) |e| {
        try std.testing.expect(!std.mem.eql(u8, errorText(@field(anyerror, e.name)), "an unexpected failure — nothing was changed"));
    }
}
