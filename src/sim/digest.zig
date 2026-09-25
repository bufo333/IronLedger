//! A canonical digest of any plain value: every field, every element, every
//! map entry. `stateHash` feeds each persisted field of a campaign through
//! it, so a change to any saved number moves the golden master. MekHQ has
//! no counterpart (it has no determinism harness).
//!
//! Canonical means independent of how the value was built: a slice or list
//! digests its length and then each element in order; a map (array hash
//! map or hash map) digests its length and the wrapping sum of one
//! sub-digest per entry, so a map rebuilt in another insertion order (as a
//! load does) digests the same. Pointers other than slices, allocators and untagged unions are
//! refused at compile time: none of them has a canonical value.

const std = @import("std");
const GameState = @import("state.zig").GameState;

const Hasher = std.hash.Wyhash;

/// A field the golden master covers: persisted or derived
/// (`GameState.field_persistence`); session and scratch fields cannot move it.
fn hashed(comptime name: []const u8) bool {
    @setEvalBranchQuota(20_000);
    return switch (GameState.persistenceOf(name)) {
        .persisted, .derived => true,
        .session, .scratch => false,
    };
}

/// The golden master: a digest of every persisted and derived field of a
/// campaign, RNG words and `next_*_id` counters included. Two runs with the
/// same seed and command script produce the same hash, and a save loads
/// back to the hash it was saved at (ARCH §13).
pub fn stateHash(gs: *const GameState) u64 {
    var h = Hasher.init(0x42544d43); // "BTMC"
    inline for (@typeInfo(GameState).@"struct".fields) |f| {
        if (comptime hashed(f.name)) {
            update(&h, f.name);
            update(&h, @field(gs, f.name));
        }
    }
    return h.final();
}

/// The path to the first hashed value that differs between two campaigns
/// ("candidates[2].skills"), for a round-trip test to name what did not
/// survive; null when nothing does.
pub fn firstStateDifference(a: *const GameState, b: *const GameState, buf: []u8) ?[]const u8 {
    inline for (@typeInfo(GameState).@"struct".fields) |f| {
        if (comptime hashed(f.name)) {
            const name_len = @min(f.name.len, buf.len);
            @memcpy(buf[0..name_len], f.name[0..name_len]);
            if (firstDifference(buf[name_len..], @field(a, f.name), @field(b, f.name))) |rest| return buf[0 .. name_len + rest.len];
        }
    }
    return null;
}

pub fn update(h: *Hasher, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .void => {},
        .bool => h.update(&[_]u8{@intFromBool(value)}),
        .int, .float => {
            const v = value;
            h.update(std.mem.asBytes(&v));
        },
        .@"enum" => update(h, @intFromEnum(value)),
        .optional => if (value) |v| {
            h.update(&[_]u8{1});
            update(h, v);
        } else h.update(&[_]u8{0}),
        .array => for (value) |e| update(h, e),
        .pointer => |p| switch (p.size) {
            .slice => {
                update(h, @as(u64, value.len));
                if (p.child == u8) h.update(value) else for (value) |e| update(h, e);
            },
            else => @compileError("digest: no canonical value for pointer type " ++ @typeName(T)),
        },
        .@"union" => |u| {
            if (u.tag_type == null) @compileError("digest: untagged union " ++ @typeName(T));
            update(h, std.meta.activeTag(value));
            switch (value) {
                inline else => |payload| update(h, payload),
            }
        },
        .@"struct" => |s| {
            if (comptime isMap(T)) return updateMap(h, value);
            if (comptime isArrayList(T)) return update(h, value.items);
            if (T == std.mem.Allocator) @compileError("digest: an allocator is not state");
            inline for (s.fields) |f| update(h, @field(value, f.name));
        },
        else => @compileError("digest: unsupported type " ++ @typeName(T)),
    }
}

fn updateMap(h: *Hasher, map: anytype) void {
    update(h, @as(u64, map.count()));
    var sum: u64 = 0;
    var it = map.iterator();
    while (it.next()) |entry| {
        var e = Hasher.init(0);
        update(&e, entry.key_ptr.*);
        update(&e, entry.value_ptr.*);
        sum +%= e.final();
    }
    update(h, sum);
}

/// `std` array hash maps (`entries`) and hash maps (`metadata`), managed
/// or not: all of them iterate entries with `key_ptr` and `value_ptr`.
fn isMap(comptime T: type) bool {
    return @hasDecl(T, "KV") and @hasDecl(T, "iterator") and (@hasField(T, "entries") or @hasField(T, "metadata") or @hasField(T, "unmanaged"));
}

fn isArrayList(comptime T: type) bool {
    return @hasField(T, "items") and @hasField(T, "capacity") and @typeInfo(T).@"struct".fields.len == 2;
}

/// The path to the first place two values of one type differ ("[3].name",
/// ".skills"), written into `buf`; null when they digest the same. It
/// descends structs, unions, optionals and equal-length slices, lists and
/// arrays, and stops at a map or at a length that differs.
pub fn firstDifference(buf: []u8, a: anytype, b: @TypeOf(a)) ?[]const u8 {
    if (of(a) == of(b)) return null;
    var w: std.Io.Writer = .fixed(buf);
    descend(&w, a, b);
    return w.buffered();
}

fn descend(w: *std.Io.Writer, a: anytype, b: @TypeOf(a)) void {
    const T = @TypeOf(a);
    switch (@typeInfo(T)) {
        .optional => if (a != null and b != null) descend(w, a.?, b.?),
        .array => for (a, b, 0..) |x, y, i| if (of(x) != of(y)) {
            // best-effort: a diagnostic path in a fixed buffer truncates.
            w.print("[{d}]", .{i}) catch {};
            return descend(w, x, y);
        },
        .pointer => |p| if (p.size == .slice and p.child != u8 and a.len == b.len) {
            for (a, b, 0..) |x, y, i| if (of(x) != of(y)) {
                // best-effort: a diagnostic path in a fixed buffer truncates.
                w.print("[{d}]", .{i}) catch {};
                return descend(w, x, y);
            };
        },
        .@"union" => if (std.meta.activeTag(a) == std.meta.activeTag(b)) switch (a) {
            inline else => |x, tag| {
                // best-effort: a diagnostic path in a fixed buffer truncates.
                w.print(".{s}", .{@tagName(tag)}) catch {};
                descend(w, x, @field(b, @tagName(tag)));
            },
        },
        .@"struct" => |s| {
            if (comptime isMap(T)) return;
            if (comptime isArrayList(T)) return descend(w, a.items, b.items);
            inline for (s.fields) |f| if (of(@field(a, f.name)) != of(@field(b, f.name))) {
                // best-effort: a diagnostic path in a fixed buffer truncates.
                w.print(".{s}", .{f.name}) catch {};
                return descend(w, @field(a, f.name), @field(b, f.name));
            };
        },
        else => {},
    }
}

fn of(value: anytype) u64 {
    var h = Hasher.init(0);
    update(&h, value);
    return h.final();
}

test "a session field cannot move the golden master; a persisted one does" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 45 });
    defer gs.deinit();
    const before = stateHash(&gs);
    gs.campaign_id = 99; // session: the store's row
    try std.testing.expectEqual(before, stateHash(&gs));
    gs.reputation += 1; // persisted
    try std.testing.expect(stateHash(&gs) != before);
    try std.testing.expectEqual(GameState.Persistence.session, comptime GameState.persistenceOf("campaign_id"));
}

test "a map digests the same whatever order its entries went in" {
    const a = std.testing.allocator;
    var one: std.AutoArrayHashMapUnmanaged(u32, []const u8) = .empty;
    defer one.deinit(a);
    var two: std.AutoArrayHashMapUnmanaged(u32, []const u8) = .empty;
    defer two.deinit(a);
    try one.put(a, 1, "alpha");
    try one.put(a, 2, "bravo");
    try two.put(a, 2, "bravo");
    try two.put(a, 1, "alpha");
    try std.testing.expectEqual(of(one), of(two));
    try two.put(a, 2, "charlie");
    try std.testing.expect(of(one) != of(two));
}

test "every field, element and string byte moves the digest" {
    const a = std.testing.allocator;
    const Row = struct { id: u16, name: []const u8, tag: ?enum { x, y }, pay: union(enum) { none, amount: i64 } };
    var list: std.ArrayListUnmanaged(Row) = .empty;
    defer list.deinit(a);
    try list.append(a, .{ .id = 1, .name = "Kell", .tag = .x, .pay = .{ .amount = 5 } });
    const base = of(list);
    list.items[0].name = "Kelm";
    try std.testing.expect(of(list) != base);
    list.items[0].name = "Kell";
    list.items[0].pay = .{ .amount = 6 };
    try std.testing.expect(of(list) != base);
    list.items[0].pay = .{ .amount = 5 };
    list.items[0].tag = null;
    try std.testing.expect(of(list) != base);
    list.items[0].tag = .x;
    try std.testing.expectEqual(base, of(list));
    var buf: [64]u8 = undefined;
    const other = [_]Row{ list.items[0], .{ .id = 2, .name = "Ryn", .tag = null, .pay = .none } };
    var changed = other;
    changed[1].name = "Rin";
    try std.testing.expectEqualStrings("[1].name", firstDifference(&buf, @as([]const Row, &other), @as([]const Row, &changed)).?);
    try std.testing.expectEqual(@as(?[]const u8, null), firstDifference(&buf, @as([]const Row, &other), @as([]const Row, &other)));
    // Splitting one string into two is not the same value.
    try std.testing.expect(of([_][]const u8{ "ab", "c" }) != of([_][]const u8{ "a", "bc" }));
}
