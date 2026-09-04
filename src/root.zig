//! Module root for the simulation core. See ARCHITECTURE.md.
//! The core is pure and deterministic: no I/O, no wall clock, no globals.

const std = @import("std");

// domain/ — entities
pub const types = @import("domain/types.zig");
pub const person = @import("domain/person.zig");
pub const unit = @import("domain/unit.zig");
pub const chassis = @import("domain/chassis.zig");
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
