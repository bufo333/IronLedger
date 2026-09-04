//! Minimal hand-bound SQLite3 surface (Stage 11): open/close, exec,
//! prepared statements with typed bind/column helpers. Just enough for
//! save/load; no ORM ambitions.

const std = @import("std");

pub const Handle = opaque {};
pub const StmtHandle = opaque {};

extern fn sqlite3_open(filename: [*:0]const u8, db: *?*Handle) c_int;
extern fn sqlite3_close(db: *Handle) c_int;
extern fn sqlite3_exec(db: *Handle, sql: [*:0]const u8, cb: ?*anyopaque, arg: ?*anyopaque, errmsg: ?*?[*:0]u8) c_int;
extern fn sqlite3_free(p: ?*anyopaque) void;
extern fn sqlite3_prepare_v2(db: *Handle, sql: [*]const u8, nbyte: c_int, stmt: *?*StmtHandle, tail: ?*?[*]const u8) c_int;
extern fn sqlite3_step(stmt: *StmtHandle) c_int;
extern fn sqlite3_reset(stmt: *StmtHandle) c_int;
extern fn sqlite3_finalize(stmt: *StmtHandle) c_int;
extern fn sqlite3_bind_int64(stmt: *StmtHandle, idx: c_int, v: i64) c_int;
extern fn sqlite3_bind_null(stmt: *StmtHandle, idx: c_int) c_int;
extern fn sqlite3_bind_text(stmt: *StmtHandle, idx: c_int, text: [*]const u8, n: c_int, destructor: ?*const anyopaque) c_int;
extern fn sqlite3_bind_blob(stmt: *StmtHandle, idx: c_int, data: [*]const u8, n: c_int, destructor: ?*const anyopaque) c_int;
extern fn sqlite3_column_int64(stmt: *StmtHandle, col: c_int) i64;
extern fn sqlite3_column_text(stmt: *StmtHandle, col: c_int) ?[*:0]const u8;
extern fn sqlite3_column_blob(stmt: *StmtHandle, col: c_int) ?*const anyopaque;
extern fn sqlite3_column_bytes(stmt: *StmtHandle, col: c_int) c_int;
extern fn sqlite3_column_type(stmt: *StmtHandle, col: c_int) c_int;
extern fn sqlite3_errmsg(db: *Handle) [*:0]const u8;

const SQLITE_OK = 0;
const SQLITE_ROW = 100;
const SQLITE_DONE = 101;
const SQLITE_NULL = 5;
/// SQLITE_TRANSIENT: "copy the data, the caller's buffer won't outlive
/// the call" — encoded by SQLite as the destructor pointer (void*)-1.
const transient: ?*const anyopaque = @ptrFromInt(std.math.maxInt(usize));

pub const Error = error{ SqliteError, NoRow };

pub const Db = struct {
    h: *Handle,

    pub fn open(path: [*:0]const u8) Error!Db {
        var h: ?*Handle = null;
        if (sqlite3_open(path, &h) != SQLITE_OK or h == null) return error.SqliteError;
        return .{ .h = h.? };
    }

    pub fn close(self: Db) void {
        _ = sqlite3_close(self.h);
    }

    pub fn exec(self: Db, sql: [*:0]const u8) Error!void {
        var err: ?[*:0]u8 = null;
        const rc = sqlite3_exec(self.h, sql, null, null, &err);
        if (rc != SQLITE_OK) {
            if (err) |e| {
                std.log.err("sqlite exec: {s}", .{e});
                sqlite3_free(e);
            }
            return error.SqliteError;
        }
    }

    pub fn prepare(self: Db, sql: []const u8) Error!Stmt {
        var s: ?*StmtHandle = null;
        if (sqlite3_prepare_v2(self.h, sql.ptr, @intCast(sql.len), &s, null) != SQLITE_OK or s == null) {
            std.log.err("sqlite prepare: {s} — {s}", .{ sqlite3_errmsg(self.h), sql });
            return error.SqliteError;
        }
        return .{ .h = s.?, .db = self.h };
    }
};

pub const Stmt = struct {
    h: *StmtHandle,
    db: *Handle,

    pub fn finalize(self: Stmt) void {
        _ = sqlite3_finalize(self.h);
    }

    pub fn reset(self: Stmt) void {
        _ = sqlite3_reset(self.h);
    }

    /// Bind a tuple of values to ?1..?N. Ints, bools, enums (as their tag
    /// name), strings, and optionals of those (null → NULL).
    pub fn bindAll(self: Stmt, args: anytype) Error!void {
        inline for (args, 1..) |arg, i| try self.bind(@intCast(i), arg);
    }

    pub fn bind(self: Stmt, idx: c_int, value: anytype) Error!void {
        const T = @TypeOf(value);
        const rc = switch (@typeInfo(T)) {
            .int, .comptime_int => sqlite3_bind_int64(self.h, idx, @intCast(value)),
            .bool => sqlite3_bind_int64(self.h, idx, @intFromBool(value)),
            .@"enum" => blk: {
                if (@typeInfo(T).@"enum".is_exhaustive) {
                    const name = @tagName(value);
                    break :blk sqlite3_bind_text(self.h, idx, name.ptr, @intCast(name.len), transient);
                }
                break :blk sqlite3_bind_int64(self.h, idx, @intCast(@intFromEnum(value)));
            },
            .optional => if (value) |v| return self.bind(idx, v) else sqlite3_bind_null(self.h, idx),
            .pointer => |p| blk: {
                const s: []const u8 = value;
                _ = p;
                break :blk sqlite3_bind_text(self.h, idx, s.ptr, @intCast(s.len), transient);
            },
            .null => sqlite3_bind_null(self.h, idx),
            else => @compileError("unsupported bind type " ++ @typeName(T)),
        };
        if (rc != SQLITE_OK) return error.SqliteError;
    }

    pub fn bindBlob(self: Stmt, idx: c_int, data: []const u8) Error!void {
        if (sqlite3_bind_blob(self.h, idx, data.ptr, @intCast(data.len), transient) != SQLITE_OK) return error.SqliteError;
    }

    /// Run to completion (INSERT/UPDATE) and reset for reuse.
    pub fn run(self: Stmt) Error!void {
        const rc = sqlite3_step(self.h);
        if (rc != SQLITE_DONE and rc != SQLITE_ROW) {
            std.log.err("sqlite step: {s}", .{sqlite3_errmsg(self.db)});
            return error.SqliteError;
        }
        _ = sqlite3_reset(self.h);
    }

    /// Advance a SELECT: true while rows remain.
    pub fn next(self: Stmt) Error!bool {
        const rc = sqlite3_step(self.h);
        if (rc == SQLITE_ROW) return true;
        if (rc == SQLITE_DONE) return false;
        std.log.err("sqlite step: {s}", .{sqlite3_errmsg(self.db)});
        return error.SqliteError;
    }

    pub fn isNull(self: Stmt, col: c_int) bool {
        return sqlite3_column_type(self.h, col) == SQLITE_NULL;
    }

    pub fn int(self: Stmt, col: c_int) i64 {
        return sqlite3_column_int64(self.h, col);
    }

    pub fn optInt(self: Stmt, col: c_int) ?i64 {
        return if (self.isNull(col)) null else self.int(col);
    }

    /// Column text copied into `alloc` (SQLite's buffer dies on step).
    pub fn text(self: Stmt, col: c_int, alloc: std.mem.Allocator) ![]const u8 {
        const p = sqlite3_column_text(self.h, col) orelse return try alloc.dupe(u8, "");
        const n: usize = @intCast(sqlite3_column_bytes(self.h, col));
        return try alloc.dupe(u8, p[0..n]);
    }

    pub fn optText(self: Stmt, col: c_int, alloc: std.mem.Allocator) !?[]const u8 {
        return if (self.isNull(col)) null else try self.text(col, alloc);
    }

    pub fn blob(self: Stmt, col: c_int, alloc: std.mem.Allocator) ![]const u8 {
        const p = sqlite3_column_blob(self.h, col) orelse return try alloc.dupe(u8, "");
        const n: usize = @intCast(sqlite3_column_bytes(self.h, col));
        const bytes: [*]const u8 = @ptrCast(p);
        return try alloc.dupe(u8, bytes[0..n]);
    }

    pub fn enumValue(self: Stmt, comptime E: type, col: c_int) ?E {
        const p = sqlite3_column_text(self.h, col) orelse return null;
        return std.meta.stringToEnum(E, std.mem.span(p));
    }
};

test "sqlite links, round-trips a row" {
    const db = try Db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE t (id INTEGER, name TEXT, opt INTEGER)");
    const ins = try db.prepare("INSERT INTO t VALUES (?1, ?2, ?3)");
    defer ins.finalize();
    try ins.bindAll(.{ @as(i64, 7), "seven", @as(?i64, null) });
    try ins.run();

    const sel = try db.prepare("SELECT id, name, opt FROM t");
    defer sel.finalize();
    try std.testing.expect(try sel.next());
    try std.testing.expectEqual(@as(i64, 7), sel.int(0));
    const name = try sel.text(1, std.testing.allocator);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("seven", name);
    try std.testing.expect(sel.isNull(2));
    try std.testing.expect(!(try sel.next()));
}
