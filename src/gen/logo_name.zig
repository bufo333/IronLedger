//! Title-case a logo filename stem into a display name. Pure, no I/O, no
//! allocation (ARCH rule 2). No MekHQ counterpart (docs/mekhq-map.md).

const std = @import("std");

/// Convert a logo filename stem to a display name.
///
/// Algorithm: strip a directory prefix (everything up to and including the
/// last '/'), strip a trailing ".png" suffix if present, then copy into `buf`
/// replacing each '_' with a space and upper-casing the first ASCII byte of
/// each word (the first byte and each byte immediately after a '_' separator).
/// Non-ASCII bytes are passed through unchanged. Returns the filled slice
/// `buf[0..n]`; a `buf` of `key.len` bytes always suffices because the output
/// length equals the stripped-input length.
///
/// Worked cases (owner-confirmed):
///   "vipers_due"                   → "Vipers Due"
///   "red_bull_company"             → "Red Bull Company"
///   "ironledger_mercenary_company" → "Ironledger Mercenary Company"
///
/// Note: apostrophes absent from filenames are NOT recovered.
/// "vipers_due" yields "Vipers Due", not "Viper's Due".
pub fn titleCaseLogoKey(key: []const u8, buf: []u8) []u8 {
    // Strip directory prefix: everything up to and including the last '/'.
    var stem = key;
    if (std.mem.lastIndexOfScalar(u8, stem, '/')) |slash| {
        stem = stem[slash + 1 ..];
    }
    // Strip trailing ".png" suffix.
    if (std.mem.endsWith(u8, stem, ".png")) {
        stem = stem[0 .. stem.len - 4];
    }

    var out: usize = 0;
    var at_word_start = true;
    for (stem) |c| {
        if (c == '_') {
            buf[out] = ' ';
            out += 1;
            at_word_start = true;
        } else if (at_word_start and c >= 'a' and c <= 'z') {
            buf[out] = c - 32; // ASCII upper-case
            out += 1;
            at_word_start = false;
        } else {
            buf[out] = c;
            out += 1;
            at_word_start = false;
        }
    }
    return buf[0..out];
}

// ---- Tests -----------------------------------------------------------------

test "titleCaseLogoKey: owner-confirmed worked examples and path/suffix stripping" {
    const cases = [_]struct { input: []const u8, want: []const u8 }{
        .{ .input = "vipers_due", .want = "Vipers Due" },
        .{ .input = "red_bull_company", .want = "Red Bull Company" },
        .{ .input = "ironledger_mercenary_company", .want = "Ironledger Mercenary Company" },
        // Path prefix + .png suffix stripping:
        .{ .input = "data/logos/vipers_due.png", .want = "Vipers Due" },
        // Already upper-cased first letter passes through:
        .{ .input = "Alpha_company", .want = "Alpha Company" },
    };
    for (cases) |c| {
        var buf: [256]u8 = undefined;
        const got = titleCaseLogoKey(c.input, &buf);
        try std.testing.expectEqualStrings(c.want, got);
    }
}
