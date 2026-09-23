//! Layout constants for the terminal client (docs/coding-contract.md rule
//! 21): the width tiers that decide how many panes a screen shows, the
//! split ratios every screen shares, and the size of each modal. Nothing
//! else in `src/tui` carries a column threshold or a ratio literal.
//! No MekHQ counterpart.

const std = @import("std");

/// Below this many columns side panes drop (docs/tui.md "Size tiers").
pub const narrow_cols: u16 = 120;
/// Above this many columns the widest layouts add a third pane.
pub const wide_cols: u16 = 150;
/// Above this many columns the Desk shows the crest beside the checklist.
pub const emblem_cols: u16 = 160;

pub fn narrow(cols: u16) bool {
    return cols < narrow_cols;
}

pub fn wide(cols: u16) bool {
    return cols > narrow_cols;
}

pub fn extraWide(cols: u16) bool {
    return cols > wide_cols;
}

/// A share of a width or height, kept rational so splits stay exact.
pub const Ratio = struct {
    num: u16,
    den: u16,

    pub fn of(self: Ratio, x: u16) u16 {
        return @intCast(@as(u32, x) * self.num / self.den);
    }
};

/// The main pane of a two-way split (list beside detail, log beside companies).
pub const major: Ratio = .{ .num = 3, .den = 5 };
/// The lesser pane of a two-way split (a top band, the treasuries column).
pub const minor: Ratio = .{ .num = 2, .den = 5 };
/// A list that leaves a little more than a third to its detail pane.
pub const list: Ratio = .{ .num = 55, .den = 100 };
pub const half: Ratio = .{ .num = 1, .den = 2 };
pub const quarter: Ratio = .{ .num = 1, .den = 4 };
pub const two_thirds: Ratio = .{ .num = 2, .den = 3 };
pub const three_quarters: Ratio = .{ .num = 3, .den = 4 };
/// Screen-specific shares (named by the pane they size).
pub const people_list: Ratio = .{ .num = 62, .den = 100 };
pub const hq_detail: Ratio = .{ .num = 45, .den = 100 };
pub const lab_hulls: Ratio = .{ .num = 3, .den = 10 };
pub const lab_mounts: Ratio = .{ .num = 7, .den = 20 };
pub const ledger_pnl: Ratio = .{ .num = 3, .den = 10 };

/// Modal widths and fixed heights (the row-dependent heights are computed
/// at the call site from the rows shown).
pub const modal = struct {
    pub const help_w: u16 = 134;
    pub const help_h: u16 = 34;
    pub const end_turn_w: u16 = 100;
    pub const end_turn_max_h: u16 = 40;
    pub const quit_w: u16 = 60;
    pub const quit_h: u16 = 9;
    pub const decision_w: u16 = 90;
    pub const decision_max_h: u16 = 30;
    pub const raise_hulls_w: u16 = 160;
    pub const raise_support_w: u16 = 150;
    pub const music_w: u16 = 110;
    pub const summary_w: u16 = 150;
    pub const readiness_w: u16 = 150;
    pub const raise_crews_w: u16 = 120;
    pub const negotiate_w: u16 = 110;
    pub const amount_w: u16 = 64;
    pub const accept_pick_w: u16 = 140;
    pub const lance_pick_w: u16 = 84;
    pub const upgrade_w: u16 = 140;
    pub const settings_w: u16 = 104;
    pub const install_part_w: u16 = 100;
    pub const install_loc_w: u16 = 90;
    pub const game_over_w: u16 = 100;
    pub const game_over_h: u16 = 10;
    pub const confirm_w: u16 = 100;
    pub const confirm_wide_w: u16 = 110;
    pub const seat_w: u16 = 80;
    pub const seat_max_h: u16 = 30;
    pub const emblem_w: u16 = 80;
    pub const emblem_max_h: u16 = 30;
    pub const emblem_editor_w: u16 = 78;
    pub const hull_w: u16 = 100;
    pub const record_w: u16 = 100;
    pub const input_w: u16 = 80;
    pub const input_h: u16 = 8;
    pub const picker_w: u16 = 120;
};

test "ratios split exactly and the tiers nest" {
    try std.testing.expectEqual(@as(u16, 60), major.of(100));
    try std.testing.expectEqual(@as(u16, 55), list.of(100));
    try std.testing.expect(narrow_cols < wide_cols and wide_cols < emblem_cols);
    try std.testing.expect(narrow(119) and !narrow(120) and !wide(120) and wide(121));
}
