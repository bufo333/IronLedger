//! NPC merc-company identity: campaign-unique company names and catalog logos
//! that go to at most one company (P5d.2, docs/p3f-faction-loop-design.md §5.3).
//! Seeding (`roster_seed.seedMercCompanies`) and replacement spawn
//! (`merc_lifecycle`) both take names and replacement logos from here.
//! No MekHQ counterpart (docs/mekhq-map.md).
//! Pure: no I/O, no RNG, no GameState.

const std = @import("std");
const logo = @import("../domain/logo.zig");

/// Single owner of the NPC company-name rule (rule 20): `"{last} {noun}"`, or,
/// when that name is taken, the first free `"{last} {noun} {numeral}"` with
/// Roman numerals II, III, IV, …. `taken` is every name already assigned in
/// the campaign, dissolved companies included, plus names assigned earlier in
/// the same operation; the comparison ignores ASCII case. Draws no RNG and
/// always finds a name, since `taken` is finite. The suffix adds only ASCII
/// letters and a space, so a markup-safe base stays markup-safe. The result is
/// owned by `alloc`; the only failure is `OutOfMemory`.
pub fn unitName(alloc: std.mem.Allocator, taken: []const []const u8, last: []const u8, noun: []const u8) ![]const u8 {
    var name: std.ArrayListUnmanaged(u8) = .empty;
    errdefer name.deinit(alloc);
    try name.appendSlice(alloc, last);
    try name.append(alloc, ' ');
    try name.appendSlice(alloc, noun);
    const base_len = name.items.len;
    var ordinal: usize = 2;
    while (isTaken(taken, name.items)) : (ordinal += 1) {
        name.shrinkRetainingCapacity(base_len);
        try name.append(alloc, ' ');
        try appendRoman(alloc, &name, ordinal);
    }
    return name.toOwnedSlice(alloc);
}

fn isTaken(taken: []const []const u8, name: []const u8) bool {
    for (taken) |existing| if (std.ascii.eqlIgnoreCase(existing, name)) return true;
    return false;
}

/// Append `n` (n >= 1) in Roman numerals; thousands repeat `M`.
fn appendRoman(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), n: usize) !void {
    const numerals = [_]struct { value: usize, text: []const u8 }{
        .{ .value = 1000, .text = "M" }, .{ .value = 900, .text = "CM" },
        .{ .value = 500, .text = "D" },  .{ .value = 400, .text = "CD" },
        .{ .value = 100, .text = "C" },  .{ .value = 90, .text = "XC" },
        .{ .value = 50, .text = "L" },   .{ .value = 40, .text = "XL" },
        .{ .value = 10, .text = "X" },   .{ .value = 9, .text = "IX" },
        .{ .value = 5, .text = "V" },    .{ .value = 4, .text = "IV" },
        .{ .value = 1, .text = "I" },
    };
    var rest = n;
    for (numerals) |numeral| while (rest >= numeral.value) {
        try out.appendSlice(alloc, numeral.text);
        rest -= numeral.value;
    };
}

/// Single owner of the replacement-logo rule (rule 20): the first key in
/// `logo.all_keys` order that is neither `player_logo_key` nor in `held`, or
/// `""` once the catalog is used up. `held` is the `logo_key` of every
/// company, dissolved ones included, plus keys planned earlier in the same
/// pass, so each catalog key goes to at most one company over the campaign.
/// Returns static catalog memory. Pure, no RNG.
pub fn firstUnusedLogo(player_logo_key: []const u8, held: []const []const u8) []const u8 {
    candidates: for (logo.all_keys) |key| {
        if (std.mem.eql(u8, key, player_logo_key)) continue;
        for (held) |held_key| if (std.mem.eql(u8, held_key, key)) continue :candidates;
        return key;
    }
    return "";
}

// ---- Tests ----

const table = @import("table.zig");

test "unitName returns a free base name unchanged" {
    const a = std.testing.allocator;
    const name = try unitName(a, &.{"Other Raiders"}, "Baxter", "Guard");
    defer a.free(name);
    try std.testing.expectEqualStrings("Baxter Guard", name);
}

test "unitName suffixes a taken name with the first free Roman numeral" {
    const a = std.testing.allocator;
    const second = try unitName(a, &.{"Baxter Guard"}, "Baxter", "Guard");
    defer a.free(second);
    try std.testing.expectEqualStrings("Baxter Guard II", second);
    const third = try unitName(a, &.{ "Baxter Guard", "Baxter Guard II" }, "Baxter", "Guard");
    defer a.free(third);
    try std.testing.expectEqualStrings("Baxter Guard III", third);
    var taken: [9][]const u8 = .{ "Baxter Guard", "Baxter Guard II", "Baxter Guard III", "Baxter Guard IV", "Baxter Guard V", "Baxter Guard VI", "Baxter Guard VII", "Baxter Guard VIII", "Baxter Guard IX" };
    const tenth = try unitName(a, &taken, "Baxter", "Guard");
    defer a.free(tenth);
    try std.testing.expectEqualStrings("Baxter Guard X", tenth);
    taken[3] = "Unrelated Co";
    const fourth = try unitName(a, &taken, "Baxter", "Guard");
    defer a.free(fourth);
    try std.testing.expectEqualStrings("Baxter Guard IV", fourth);
}

test "unitName treats a name differing only in ASCII case as taken" {
    const a = std.testing.allocator;
    const name = try unitName(a, &.{"BAXTER guard"}, "Baxter", "Guard");
    defer a.free(name);
    try std.testing.expectEqualStrings("Baxter Guard II", name);
}

test "unitName keeps a suffixed name markup-safe" {
    const a = std.testing.allocator;
    const name = try unitName(a, &.{ "Baxter Guard", "Baxter Guard II", "Baxter Guard III" }, "Baxter", "Guard");
    defer a.free(name);
    try std.testing.expect(table.markupSafe(name));
}

test "unitName releases its partial name on every allocation failure" {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (unitName(failing.allocator(), &.{ "Baxter Guard", "Baxter Guard II" }, "Baxter", "Guard")) |name| {
            defer failing.allocator().free(name);
            try std.testing.expectEqualStrings("Baxter Guard III", name);
            break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
}

test "firstUnusedLogo skips the player's key and every held key, dissolved holders included" {
    // `held` lists active and dissolved holders alike; neither key returns.
    try std.testing.expectEqualStrings(logo.all_keys[3], firstUnusedLogo(logo.all_keys[0], &.{ logo.all_keys[2], logo.all_keys[1] }));
}

test "firstUnusedLogo returns the first catalog key when nothing is held or reserved" {
    try std.testing.expectEqualStrings(logo.all_keys[0], firstUnusedLogo("", &.{}));
}

test "firstUnusedLogo returns an empty key once the catalog is used up" {
    try std.testing.expectEqualStrings("", firstUnusedLogo(logo.all_keys[0], logo.all_keys[1..]));
    try std.testing.expectEqualStrings("", firstUnusedLogo("", logo.all_keys));
}
