//! One engagement's isolated resolution and prepared publication.
//! No MekHQ counterpart: atomic engagement policy (docs/p2-artillery-battle-design.md).

const std = @import("std");
const GameState = @import("state.zig").GameState;
const storage = @import("battle_prepared_storage.zig");

/// Operation-owned view of the explicit battle mutation footprint. Its arena and
/// lifecycle arenas are isolated; discarding it cannot release campaign storage.
pub const Engagement = struct {
    view: GameState,

    pub fn init(live: *GameState, backing: std.mem.Allocator) !Engagement {
        var view = live.*;
        view.arena = std.heap.ArenaAllocator.init(backing);
        errdefer view.arena.deinit();
        try storage.isolate(&view, live);
        return .{ .view = view };
    }

    pub fn deinit(self: *Engagement) void {
        self.view.deinit();
    }

    /// Reserve live destinations and promote retained payloads before the first
    /// live gameplay mutation. Failure leaves RNG, identities and gameplay intact.
    pub fn prepare(self: *Engagement, live: *GameState) !storage.Publication {
        return storage.Publication.prepare(live, &self.view, self.view.allocator());
    }
};

test "discarded engagement preserves live scalars streams and identities" {
    const digest = @import("digest.zig");
    var live = GameState.init(std.testing.allocator, .{});
    defer live.deinit();
    const before = digest.stateHash(&live);
    var work = try Engagement.init(&live, live.scratch());
    _ = work.view.rng.roll2d6(.battle);
    work.view.funds = 0;
    _ = try work.view.hirePerson("Discarded", "Crew", .vehicle_crew);
    work.deinit();
    try std.testing.expectEqual(before, digest.stateHash(&live));
}
