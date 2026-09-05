//! Module root for the simulation core. See ARCHITECTURE.md.
//! The core is pure and deterministic: no I/O, no wall clock, no globals.

const std = @import("std");

// domain/ — entities
pub const types = @import("domain/types.zig");
pub const person = @import("domain/person.zig");
pub const unit = @import("domain/unit.zig");
pub const chassis = @import("domain/chassis.zig");
pub const tuning = @import("domain/tuning.zig");
pub const rank = @import("domain/rank.zig");
pub const award = @import("domain/award.zig");
pub const ability = @import("domain/ability.zig");
pub const rat = @import("domain/rat.zig");
pub const faction = @import("domain/faction.zig");
pub const scenario = @import("domain/scenario.zig");
pub const terrain = @import("domain/terrain.zig");
/// Build-time facts (12C.18): the data directory overlaid with `-Ddata=`,
/// and which files it replaced. Constants, not state.
pub const build_info = @import("build_options");

/// "stock tables" or "mod <dir>: 3 files (chassis.zon, …)" for settings
/// screens and banners.
pub fn dataProvenance(alloc: std.mem.Allocator) ![]const u8 {
    if (build_info.data_dir) |dir| {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "mod {s}: {d} file{s} overlaid", .{ dir, build_info.data_overlays.len, if (build_info.data_overlays.len == 1) "" else "s" }));
        for (build_info.data_overlays, 0..) |f, i| try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s}{s}", .{ if (i == 0) " (" else ", ", f }));
        if (build_info.data_overlays.len > 0) try out.append(alloc, ')');
        return out.toOwnedSlice(alloc);
    }
    return "stock tables (data/)";
}
pub const personnel = @import("sim/personnel.zig");
pub const planet = @import("domain/planet.zig");
pub const meklab = @import("domain/meklab.zig");
pub const commander = @import("domain/commander.zig");
pub const part = @import("domain/part.zig");
pub const force = @import("domain/force.zig");
pub const contract = @import("domain/contract.zig");
pub const hq = @import("domain/hq.zig");

// sim/ — state, time, randomness, events, battle resolution
pub const state = @import("sim/state.zig");
pub const tick = @import("sim/tick.zig");
pub const field_supply = @import("sim/field_supply.zig");
pub const maintenance = @import("sim/maintenance.zig");
pub const medical = @import("sim/medical.zig");
pub const hq_ops = @import("sim/hq_ops.zig");
pub const checklist = @import("sim/checklist.zig");
pub const network = @import("sim/network.zig");
pub const contract_control = @import("sim/contract_control.zig");
pub const queries = @import("sim/queries.zig");

// persist/ — SQLite save files (Stage 11)
pub const sqlite = @import("persist/sqlite.zig");
pub const store = @import("persist/store.zig");
pub const commands = @import("sim/commands.zig");
pub const cli = @import("sim/cli.zig");
pub const rng = @import("sim/rng.zig");
pub const clock = @import("sim/clock.zig");
pub const events = @import("sim/events.zig");
pub const contract_events = @import("sim/contract_events.zig");
pub const autoresolve = @import("sim/autoresolve.zig");
pub const battle = @import("sim/battle.zig");

// econ/ — money, markets, supply network
pub const finance = @import("econ/finance.zig");
pub const logistics = @import("econ/logistics.zig");
pub const market = @import("econ/market.zig");
pub const contract_market = @import("econ/contract_market.zig");

// gen/ — procedural generation
pub const company_gen = @import("gen/company_gen.zig");
pub const person_gen = @import("gen/person_gen.zig");

test {
    std.testing.refAllDecls(@This());
}
