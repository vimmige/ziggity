//! Per-conflict merge resolution: parse a conflicted working-tree file into its
//! `<<<<<<< / ||||||| / ======= / >>>>>>>` blocks, navigate between them, and
//! pick ours / theirs / both for each — rewriting the file in place. A per-file
//! undo stack lets each pick be reverted. Free functions over `*App`; the state
//! (parsed conflicts, content, undo stack) lives on App.
const std = @import("std");

const app_mod = @import("app.zig");
const vaxis = @import("vaxis");

const App = app_mod.App;

/// One conflict block, addressed by 0-based line index. `ancestor` is the
/// `|||||||` base line (diff3 mode) or null.
pub const Conflict = struct {
    start: usize, // `<<<<<<<`
    ancestor: ?usize, // `|||||||` (diff3) or null
    target: usize, // `=======`
    end: usize, // `>>>>>>>`
};

/// Which side(s) of a conflict to keep. `both_ours_first` keeps ours then
/// theirs, `both_theirs_first` keeps theirs then ours; both drop the diff3 base
/// region and all markers. `ours`/`theirs` keep just that one side.
pub const Choice = enum { ours, theirs, both_ours_first, both_theirs_first };

fn isStart(l: []const u8) bool {
    return std.mem.startsWith(u8, l, "<<<<<<<");
}
fn isAncestor(l: []const u8) bool {
    return std.mem.startsWith(u8, l, "|||||||");
}
fn isTarget(l: []const u8) bool {
    return std.mem.startsWith(u8, l, "=======");
}
fn isEnd(l: []const u8) bool {
    return std.mem.startsWith(u8, l, ">>>>>>>");
}

/// True for any of the four conflict marker lines — used by the renderer to
/// colour them.
pub fn isMarkerLine(l: []const u8) bool {
    return isStart(l) or isAncestor(l) or isTarget(l) or isEnd(l);
}

/// Byte range [start, end) of each line — `end` is *after* the trailing `\n`,
/// so concatenating kept ranges reproduces the file byte-for-byte.
const LineRange = struct { start: usize, end: usize };

fn lineRanges(allocator: std.mem.Allocator, content: []const u8) ![]LineRange {
    var ranges: std.ArrayList(LineRange) = .empty;
    errdefer ranges.deinit(allocator);
    var i: usize = 0;
    while (i < content.len) {
        const nl = std.mem.indexOfScalarPos(u8, content, i, '\n');
        const end = if (nl) |n| n + 1 else content.len;
        try ranges.append(allocator, .{ .start = i, .end = end });
        i = end;
    }
    return ranges.toOwnedSlice(allocator);
}

/// The text of line `r` with its trailing newline (and CR) stripped, for marker
/// detection.
fn lineText(content: []const u8, r: LineRange) []const u8 {
    var e = r.end;
    if (e > r.start and content[e - 1] == '\n') e -= 1;
    if (e > r.start and content[e - 1] == '\r') e -= 1;
    return content[r.start..e];
}

/// Parse every conflict block in `content`. Malformed/nested blocks are skipped.
pub fn parse(allocator: std.mem.Allocator, content: []const u8) ![]Conflict {
    const ranges = try lineRanges(allocator, content);
    defer allocator.free(ranges);

    var conflicts: std.ArrayList(Conflict) = .empty;
    errdefer conflicts.deinit(allocator);

    var i: usize = 0;
    while (i < ranges.len) : (i += 1) {
        if (!isStart(lineText(content, ranges[i]))) continue;
        const start = i;
        var ancestor: ?usize = null;
        var target: ?usize = null;
        var end: ?usize = null;
        var j = start + 1;
        while (j < ranges.len) : (j += 1) {
            const t = lineText(content, ranges[j]);
            if (isStart(t)) break; // another start before we closed — malformed
            if (target == null and ancestor == null and isAncestor(t)) {
                ancestor = j;
            } else if (target == null and isTarget(t)) {
                target = j;
            } else if (target != null and isEnd(t)) {
                end = j;
                break;
            }
        }
        if (target != null and end != null) {
            try conflicts.append(allocator, .{ .start = start, .ancestor = ancestor, .target = target.?, .end = end.? });
            i = end.?; // resume after this conflict
        }
    }
    return conflicts.toOwnedSlice(allocator);
}

/// Append file lines `[from, to)` (0-based, `to` exclusive) verbatim to `out`.
fn appendLines(out: *std.ArrayList(u8), allocator: std.mem.Allocator, content: []const u8, ranges: []const LineRange, from: usize, to: usize) !void {
    var i = from;
    while (i < to) : (i += 1) try out.appendSlice(allocator, content[ranges[i].start..ranges[i].end]);
}

/// New file content after resolving conflict `c` with `choice` (owned). Other
/// conflicts are left untouched. The conflict's marker lines (and the diff3 base
/// region between `|||||||` and `=======`) are dropped; the `both_*` choices
/// keep both sides, in the order the choice names.
pub fn resolveContent(allocator: std.mem.Allocator, content: []const u8, c: Conflict, choice: Choice) ![]u8 {
    const ranges = try lineRanges(allocator, content);
    defer allocator.free(ranges);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Marker-excluded body ranges: ours = (start, ancestor|target), theirs =
    // (target, end). The diff3 base region (ancestor, target) is never kept.
    const ours_from = c.start + 1;
    const ours_to = c.ancestor orelse c.target;
    const theirs_from = c.target + 1;
    const theirs_to = c.end;

    var idx: usize = 0;
    while (idx < ranges.len) : (idx += 1) {
        if (idx < c.start or idx > c.end) {
            try out.appendSlice(allocator, content[ranges[idx].start..ranges[idx].end]);
            continue;
        }
        // Emit the whole resolved block once, at the opening marker, in the
        // chosen side order; every other line inside the conflict is skipped.
        if (idx == c.start) switch (choice) {
            .ours => try appendLines(&out, allocator, content, ranges, ours_from, ours_to),
            .theirs => try appendLines(&out, allocator, content, ranges, theirs_from, theirs_to),
            .both_ours_first => {
                try appendLines(&out, allocator, content, ranges, ours_from, ours_to);
                try appendLines(&out, allocator, content, ranges, theirs_from, theirs_to);
            },
            .both_theirs_first => {
                try appendLines(&out, allocator, content, ranges, theirs_from, theirs_to);
                try appendLines(&out, allocator, content, ranges, ours_from, ours_to);
            },
        };
    }
    return out.toOwnedSlice(allocator);
}

// --- App-facing interactive layer ---

/// `enter` on a conflicted file: read it, parse its conflicts, and open the
/// resolution view, or the diff when no inline markers remain.
pub fn open(app: *App, path: []const u8) !void {
    const content = app.git.readWorkingFile(path) catch {
        try app.setMessage("could not read {s}", .{path});
        return;
    };
    const parsed = parse(app.allocator, content) catch {
        app.allocator.free(content);
        try app.setMessage("could not parse conflicts", .{});
        return;
    };
    if (parsed.len == 0) {
        app.allocator.free(content);
        app.allocator.free(parsed);
        try app.enterMain();
        return app.setMessage("no conflict markers in {s}; mark resolved explicitly from Files (space)", .{path});
    }
    const owned_path = app.allocator.dupe(u8, path) catch |err| {
        app.allocator.free(content);
        app.allocator.free(parsed);
        return err;
    };
    close(app);
    app.conflict_path = owned_path;
    app.conflict_content = content;
    app.conflicts = parsed;
    app.conflict_index = 0;
    app.mode = .conflict_resolve;
    try app.setMessage("resolving {s}: o ours / t theirs / b both (ours first) / B both (theirs first) / u undo / esc back", .{path});
}

/// Free the conflict session state (safe when none is active).
pub fn close(app: *App) void {
    app.allocator.free(app.conflict_path);
    app.conflict_path = &.{};
    app.allocator.free(app.conflict_content);
    app.conflict_content = &.{};
    app.allocator.free(app.conflicts);
    app.conflicts = &.{};
    clearUndo(app);
    app.conflict_index = 0;
}

fn clearUndo(app: *App) void {
    for (app.conflict_undo.items) |c| {
        app.allocator.free(c);
    }
    app.conflict_undo.clearRetainingCapacity();
}

pub fn cancel(app: *App) !void {
    close(app);
    app.mode = .normal;
    try app.updatePreview();
}

/// Move the current-conflict cursor between conflicts.
pub fn move(app: *App, down: bool) void {
    if (app.conflicts.len == 0) return;
    if (down) {
        if (app.conflict_index + 1 < app.conflicts.len) app.conflict_index += 1;
    } else {
        app.conflict_index -|= 1;
    }
}

/// Return false after refreshing a stale session, leaving the new file alone.
fn checkCurrentContent(app: *App) !bool {
    const content = app.git.readWorkingFile(app.conflict_path) catch {
        try app.setMessage("could not read {s}", .{app.conflict_path});
        return false;
    };
    if (std.mem.eql(u8, content, app.conflict_content)) {
        app.allocator.free(content);
        return true;
    }

    const parsed = parse(app.allocator, content) catch |err| {
        app.allocator.free(content);
        return err;
    };
    app.allocator.free(app.conflict_content);
    setContent(app, content, parsed);
    clearUndo(app);
    if (parsed.len == 0) {
        try cancel(app);
        try app.setMessage("file changed outside ziggity. Mark resolved from Files (space)", .{});
    } else {
        try app.setMessage("file changed outside ziggity. Conflicts reloaded", .{});
    }
    return false;
}

fn writeReplacement(app: *App, content: []const u8) !bool {
    const io = app.git.io;
    const path = try std.fmt.allocPrint(app.allocator, "{s}/{s}", .{ app.git.root, app.conflict_path });
    defer app.allocator.free(path);
    const dir = std.Io.Dir.cwd();
    const original = try dir.openFile(io, path, .{ .mode = .read_write, .follow_symlinks = false, .allow_directory = false });
    defer original.close(io);
    const stat = try original.stat(io);
    if (stat.kind != .file) return error.NotRegularFile;

    var replacement = try dir.createFileAtomic(io, path, .{ .replace = true });
    defer replacement.deinit(io);
    try replacement.file.writeStreamingAll(io, content);
    try replacement.file.setPermissions(io, stat.permissions);
    if (!try checkCurrentContent(app)) return false;
    const current = try dir.statFile(io, path, .{ .follow_symlinks = false });
    if (current.kind != .file or current.inode != stat.inode) return error.FileReplaced;
    try replacement.replace(io);
    return true;
}

/// Resolve the current conflict with `choice` and stage after the last pick.
pub fn pick(app: *App, choice: Choice) !void {
    if (!try checkCurrentContent(app) or app.conflicts.len == 0) return;
    const idx = @min(app.conflict_index, app.conflicts.len - 1);
    const content = try resolveContent(app.allocator, app.conflict_content, app.conflicts[idx], choice);
    var installed = false;
    defer if (!installed) app.allocator.free(content);
    const parsed = try parse(app.allocator, content);
    defer if (!installed) app.allocator.free(parsed);
    try app.conflict_undo.ensureUnusedCapacity(app.allocator, 1);
    const written = writeReplacement(app, content) catch {
        return app.setMessage("could not write {s}", .{app.conflict_path});
    };
    if (!written) return;

    app.conflict_undo.appendAssumeCapacity(app.conflict_content);
    setContent(app, content, parsed);
    installed = true;
    if (app.conflicts.len == 0) return finish(app);
    try app.setMessage("{d} conflict(s) left in {s}", .{ app.conflicts.len, app.conflict_path });
}

pub fn undo(app: *App) !void {
    if (!try checkCurrentContent(app)) return;
    const prev = app.conflict_undo.getLastOrNull() orelse {
        return app.setMessage("nothing to undo", .{});
    };
    const parsed = try parse(app.allocator, prev);
    var installed = false;
    defer if (!installed) app.allocator.free(parsed);
    const written = writeReplacement(app, prev) catch {
        return app.setMessage("could not undo pick in {s}", .{app.conflict_path});
    };
    if (!written) return;

    _ = app.conflict_undo.pop();
    app.allocator.free(app.conflict_content);
    setContent(app, prev, parsed);
    installed = true;
    try app.setMessage("undid pick — {d} conflict(s) left", .{app.conflicts.len});
}

fn setContent(app: *App, content: []u8, parsed: []Conflict) void {
    app.conflict_content = content;
    app.allocator.free(app.conflicts);
    app.conflicts = parsed;
    app.conflict_index = @min(app.conflict_index, parsed.len -| 1);
}

/// All conflicts resolved: stage the file and leave the view.
fn finish(app: *App) !void {
    const path = try app.allocator.dupe(u8, app.conflict_path);
    defer app.allocator.free(path);
    close(app);
    app.mode = .normal;
    return app.runMutationFiles(try app.git.stagePaths(&.{path}), "resolved {s}", .{path});
}

pub fn handleKey(app: *App, key: vaxis.Key) !void {
    const km = app.config.keymap;
    if (app.isDialogCloseKey(key)) return cancel(app);
    if (km.up.matches(key) or key.matches(vaxis.Key.up, .{})) return move(app, false);
    if (km.down.matches(key) or key.matches(vaxis.Key.down, .{})) return move(app, true);
    if (matchesChar(key, 'o')) return pick(app, .ours);
    if (matchesChar(key, 't')) return pick(app, .theirs);
    if (matchesChar(key, 'b')) return pick(app, .both_ours_first);
    if (matchesChar(key, 'B')) return pick(app, .both_theirs_first);
    if (matchesChar(key, 'u')) return undo(app);
}

fn matchesChar(key: vaxis.Key, c: u21) bool {
    return key.matches(c, .{});
}

const testing = std.testing;

const sample_2way =
    "line 1\n" ++
    "<<<<<<< HEAD\n" ++
    "ours a\n" ++
    "ours b\n" ++
    "=======\n" ++
    "theirs a\n" ++
    ">>>>>>> branch\n" ++
    "line 8\n";

test "parse finds a single 2-way conflict" {
    const c = try parse(testing.allocator, sample_2way);
    defer testing.allocator.free(c);
    try testing.expectEqual(@as(usize, 1), c.len);
    try testing.expectEqual(@as(usize, 1), c[0].start);
    try testing.expectEqual(@as(?usize, null), c[0].ancestor);
    try testing.expectEqual(@as(usize, 4), c[0].target);
    try testing.expectEqual(@as(usize, 6), c[0].end);
}

test "resolveContent ours/theirs/both (ours-first and theirs-first)" {
    const c = try parse(testing.allocator, sample_2way);
    defer testing.allocator.free(c);

    const ours = try resolveContent(testing.allocator, sample_2way, c[0], .ours);
    defer testing.allocator.free(ours);
    try testing.expectEqualStrings("line 1\nours a\nours b\nline 8\n", ours);

    const theirs = try resolveContent(testing.allocator, sample_2way, c[0], .theirs);
    defer testing.allocator.free(theirs);
    try testing.expectEqualStrings("line 1\ntheirs a\nline 8\n", theirs);

    const both_ours = try resolveContent(testing.allocator, sample_2way, c[0], .both_ours_first);
    defer testing.allocator.free(both_ours);
    try testing.expectEqualStrings("line 1\nours a\nours b\ntheirs a\nline 8\n", both_ours);

    // theirs-first keeps both sides but flips the order within the block.
    const both_theirs = try resolveContent(testing.allocator, sample_2way, c[0], .both_theirs_first);
    defer testing.allocator.free(both_theirs);
    try testing.expectEqualStrings("line 1\ntheirs a\nours a\nours b\nline 8\n", both_theirs);
}

test "parse handles diff3 ancestor and multiple conflicts" {
    const src =
        "<<<<<<< HEAD\n" ++
        "ours\n" ++
        "||||||| base\n" ++
        "orig\n" ++
        "=======\n" ++
        "theirs\n" ++
        ">>>>>>> b\n" ++
        "mid\n" ++
        "<<<<<<< HEAD\n" ++
        "x\n" ++
        "=======\n" ++
        "y\n" ++
        ">>>>>>> b\n";
    const c = try parse(testing.allocator, src);
    defer testing.allocator.free(c);
    try testing.expectEqual(@as(usize, 2), c.len);
    try testing.expectEqual(@as(?usize, 2), c[0].ancestor);
    // ours drops the diff3 base region.
    const ours = try resolveContent(testing.allocator, src, c[0], .ours);
    defer testing.allocator.free(ours);
    try testing.expectEqualStrings("ours\nmid\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> b\n", ours);
}

test "parse ignores content without markers" {
    const c = try parse(testing.allocator, "just\nplain\ntext\n");
    defer testing.allocator.free(c);
    try testing.expectEqual(@as(usize, 0), c.len);
}
