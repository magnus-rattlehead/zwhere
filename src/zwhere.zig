const std = @import("std");
const search = @import("search");

const chunk_size = 1 << 20;
const max_needle_len = 128;
const PathQueue = std.Io.Queue([]const u8);

const Output = struct {
    mutex: std.Io.Mutex = .init,
    writer: std.Io.File.Writer,
    failed: bool = false,
    had_errors: bool = false,

    fn print(output: *Output, io: std.Io, comptime format: []const u8, args: anytype) !void {
        try output.mutex.lock(io);
        defer output.mutex.unlock(io);
        try output.printLocked(format, args);
    }

    fn report(output: *Output, io: std.Io, comptime format: []const u8, args: anytype) !void {
        try output.mutex.lock(io);
        defer output.mutex.unlock(io);
        output.had_errors = true;
        try output.printLocked(format, args);
    }

    fn printLocked(output: *Output, comptime format: []const u8, args: anytype) !void {
        if (output.failed) return error.WriteFailed;
        output.writer.interface.print(format, args) catch |err| {
            output.failed = true;
            return err;
        };
    }
};

fn searchFile(
    io: std.Io,
    queue: *PathQueue,
    allocator: std.mem.Allocator,
    needle: []const u8,
    buffer: []u8,
    output: *Output,
) std.Io.Cancelable!void {
    const cwd = std.Io.Dir.cwd();
    const overlap = needle.len - 1;

    while (true) {
        const file_path = queue.getOne(io) catch |err| switch (err) {
            error.Closed => return,
            error.Canceled => return error.Canceled,
        };
        defer allocator.free(file_path);

        const file = cwd.openFile(io, file_path, .{
            .mode = .read_only,
        }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                output.report(io, "Error: cannot open file '{s}': {s}\n", .{ file_path, @errorName(err) }) catch {
                    queue.close(io);
                    return;
                };
                continue;
            },
        };
        defer file.close(io);

        var carry: usize = 0;
        while (true) {
            const n = file.readStreaming(io, &.{buffer[carry .. carry + chunk_size]}) catch |err| switch (err) {
                error.EndOfStream => break,
                error.Canceled => return error.Canceled,
                else => {
                    output.report(io, "Error: cannot read file '{s}': {s}\n", .{ file_path, @errorName(err) }) catch {
                        queue.close(io);
                        return;
                    };
                    break;
                },
            };
            if (n == 0) continue;

            const haystack = buffer[0 .. carry + n];
            if (search.contains(needle, haystack)) {
                output.print(io, "{s}\n", .{file_path}) catch {
                    queue.close(io);
                    return;
                };
                break;
            }

            carry = @min(overlap, haystack.len);
            std.mem.copyForwards(u8, buffer[0..carry], haystack[haystack.len - carry ..]);
        }
    }
}

fn beginWalk(
    io: std.Io,
    queue: *PathQueue,
    allocator: std.mem.Allocator,
    directories: []const [:0]const u8,
    output: *Output,
) !void {
    defer queue.close(io);
    const cwd = std.Io.Dir.cwd();

    for (directories) |dir_path| {
        var dir = cwd.openDir(io, dir_path, .{
            .iterate = true,
        }) catch |err| switch (err) {
            error.Canceled => return err,
            else => {
                try output.report(io, "Error: cannot open directory '{s}': {s}\n", .{ dir_path, @errorName(err) });
                continue;
            },
        };
        defer dir.close(io);

        var iterator = try dir.walkSelectively(allocator);
        defer {
            while (iterator.stack.items.len != 0) iterator.leave(io);
            iterator.deinit();
        }

        while (true) {
            const entry = (iterator.next(io) catch |err| switch (err) {
                error.Canceled, error.OutOfMemory => return err,
                else => {
                    try output.report(io, "Error: cannot walk directory '{s}': {s}\n", .{ dir_path, @errorName(err) });
                    continue;
                },
            }) orelse break;
            if (entry.kind == .directory) {
                iterator.enter(io, entry) catch |err| switch (err) {
                    error.Canceled, error.OutOfMemory => return err,
                    else => try output.report(io, "Error: cannot enter directory '{s}' under '{s}': {s}\n", .{ entry.path, dir_path, @errorName(err) }),
                };
                continue;
            }
            if (entry.kind != .file) continue;

            const full_path = try std.Io.Dir.path.join(allocator, &.{ dir_path, entry.path });
            queue.putOne(io, full_path) catch |err| {
                allocator.free(full_path);
                switch (err) {
                    error.Closed => return error.WriteFailed,
                    error.Canceled => return err,
                }
            };
        }
    }
}

fn runSearch(
    io: std.Io,
    allocator: std.mem.Allocator,
    needle: []const u8,
    directories: []const [:0]const u8,
    jobs: usize,
    output: *Output,
) !void {
    if (needle.len == 0) return;

    const buffer_size = chunk_size + max_needle_len - 1;
    const buffers = try allocator.alloc(u8, jobs * buffer_size);
    defer allocator.free(buffers);

    var qbuf: [128][]const u8 = undefined;
    var queue: PathQueue = .init(&qbuf);
    defer {
        queue.close(io);
        while (queue.getOneUncancelable(io)) |path| {
            allocator.free(path);
        } else |_| {}
    }

    var workers: std.Io.Group = .init;
    defer workers.cancel(io);

    for (0..jobs) |i| {
        try workers.concurrent(io, searchFile, .{
            io,
            &queue,
            allocator,
            needle,
            buffers[i * buffer_size ..][0..buffer_size],
            output,
        });
    }

    try beginWalk(io, &queue, allocator, directories, output);
    try workers.await(io);
    if (output.failed) return error.WriteFailed;
}

fn run(init: std.process.Init, output: *Output) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var arg_idx: usize = 1;
    var jobs: usize = 4;
    if (args.len > 1 and std.mem.eql(u8, args[1], "-j")) {
        if (args.len < 3) return error.MissingWorkerCount;
        jobs = std.fmt.parseInt(usize, args[2], 10) catch return error.InvalidWorkerCount;
        if (jobs == 0 or jobs > 256) return error.InvalidWorkerCount;
        arg_idx = 3;
    }
    if (args.len > arg_idx and std.mem.eql(u8, args[arg_idx], "--")) arg_idx += 1;

    if (args.len < arg_idx + 2) {
        try output.report(init.io, "Usage: {s} [-j <1..256>] [--] <needle> <dir1> [dir2 ...]\n", .{if (args.len > 0) args[0] else "zwhere"});
        return;
    }
    const needle = args[arg_idx];
    if (needle.len > max_needle_len) {
        return error.NeedleTooLong;
    }

    try runSearch(init.io, init.gpa, needle, args[arg_idx + 1 ..], jobs, output);
}

pub fn main(init: std.process.Init) void {
    var output_buffer: [1 << 16]u8 = undefined;
    var output: Output = .{
        .writer = std.Io.File.stdout().writerStreaming(init.io, &output_buffer),
    };
    run(init, &output) catch |err| {
        output.had_errors = true;
        const message = switch (err) {
            error.MissingWorkerCount => "missing worker count after -j (expected 1..256)",
            error.InvalidWorkerCount => "invalid worker count (expected 1..256)",
            error.NeedleTooLong => "needle is too long (max 128 bytes)",
            error.OutOfMemory => "not enough memory to complete the search",
            error.ConcurrencyUnavailable => "cannot start search workers",
            error.Canceled => "search canceled",
            else => @errorName(err),
        };
        if (!output.failed) output.report(init.io, "Error: {s}\n", .{message}) catch {};
    };
    if (!output.failed) output.writer.interface.flush() catch {
        output.failed = true;
    };
    if (output.had_errors or output.failed) std.process.exit(1);
}
