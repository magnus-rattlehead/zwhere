const std = @import("std");
const search = @import("search");
const workqueue = @import("work_queue");

const chunk_size = 1 << 20;
const max_needle_len = 128;
const paths_per_batch = 8;
const queued_batches = 64;
const DirectoryQueue = workqueue.WorkQueue([]const u8);
const FileQueue = std.Io.Queue(PathBatch);

const PathBatch = struct {
    paths: [paths_per_batch][]const u8 = undefined,
    len: usize = 0,

    fn deinit(self: *const PathBatch, allocator: std.mem.Allocator) void {
        for (self.paths[0..self.len]) |path| allocator.free(path);
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    directories: *DirectoryQueue,
    files: *FileQueue,
    stopped: std.atomic.Value(bool) = .init(false),
    failure_mutex: std.Io.Mutex = .init,
    failure: ?anyerror = null,

    fn fail(self: *State, io: std.Io, err: anyerror) void {
        self.failure_mutex.lockUncancelable(io);
        if (self.failure == null) self.failure = err;
        self.stopped.store(true, .release);
        self.failure_mutex.unlock(io);
        self.directories.close(io);
        self.files.close(io);
    }
};

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
        errdefer output.failed = true;
        try output.writer.interface.print(format, args);
        try output.writer.interface.flush();
    }
};

const SearchWorker = struct {
    io: std.Io,
    searcher: *const search.Searcher,
    buffer: []u8,
    output: *Output,
    state: *State,

    fn run(self: SearchWorker) std.Io.Cancelable!void {
        self.runTasks() catch |err| {
            self.state.fail(self.io, err);
            if (err == error.Canceled) return error.Canceled;
        };
    }

    fn runTasks(self: SearchWorker) !void {
        while (!self.state.stopped.load(.acquire)) {
            const batch = self.state.files.getOne(self.io) catch |err| switch (err) {
                error.Closed => return,
                else => return err,
            };
            defer batch.deinit(self.state.allocator);
            for (batch.paths[0..batch.len]) |path| {
                if (self.state.stopped.load(.acquire)) return;
                try self.searchFile(path);
            }
        }
    }

    fn searchFile(self: SearchWorker, file_path: []const u8) !void {
        const io = self.io;
        const overlap = self.searcher.needle.len - 1;
        const file = std.Io.Dir.cwd().openFile(io, file_path, .{
            .mode = .read_only,
        }) catch |err| switch (err) {
            error.Canceled => return err,
            else => {
                try self.output.report(io, "Error: cannot open file '{s}': {s}\n", .{ file_path, @errorName(err) });
                return;
            },
        };
        defer file.close(io);

        var carry: usize = 0;
        while (!self.state.stopped.load(.acquire)) {
            const n = file.readStreaming(io, &.{self.buffer[carry .. carry + chunk_size]}) catch |err| switch (err) {
                error.EndOfStream => return,
                error.Canceled => return err,
                else => {
                    try self.output.report(io, "Error: cannot read file '{s}': {s}\n", .{ file_path, @errorName(err) });
                    return;
                },
            };
            if (n == 0) continue;

            const haystack = self.buffer[0 .. carry + n];
            if (self.searcher.contains(haystack)) {
                try self.output.print(io, "{s}\n", .{file_path});
                return;
            }

            carry = @min(overlap, haystack.len);
            std.mem.copyForwards(u8, self.buffer[0..carry], haystack[haystack.len - carry ..]);
        }
    }
};

const TraversalWorker = struct {
    io: std.Io,
    state: *State,
    output: *Output,

    fn run(self: TraversalWorker) std.Io.Cancelable!void {
        self.runTasks() catch |err| {
            self.state.fail(self.io, err);
            if (err == error.Canceled) return error.Canceled;
        };
    }

    fn runTasks(self: TraversalWorker) !void {
        while (try self.state.directories.next(self.io)) |path| {
            defer self.state.directories.done(self.io);
            defer self.state.allocator.free(path);
            try self.walkDirectory(path);
        }
    }

    fn flush(self: TraversalWorker, batch: *PathBatch) !void {
        if (batch.len == 0) return;
        try self.state.files.putOne(self.io, batch.*);
        batch.len = 0;
    }

    fn walkDirectory(self: TraversalWorker, dir_path: []const u8) !void {
        const io = self.io;
        const allocator = self.state.allocator;
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{
            .iterate = true,
        }) catch |err| switch (err) {
            error.Canceled => return err,
            else => {
                try self.output.report(io, "Error: cannot open directory '{s}': {s}\n", .{ dir_path, @errorName(err) });
                return;
            },
        };
        defer dir.close(io);

        var iterator = dir.iterateAssumeFirstIteration();

        var batch: PathBatch = .{};
        defer batch.deinit(allocator);
        while (!self.state.stopped.load(.acquire)) {
            const entry = (iterator.next(io) catch |err| switch (err) {
                error.Canceled => return err,
                else => {
                    try self.output.report(io, "Error: cannot walk directory '{s}': {s}\n", .{ dir_path, @errorName(err) });
                    break;
                },
            }) orelse break;
            if (entry.kind != .directory and entry.kind != .file) continue;

            const full_path = try std.Io.Dir.path.join(allocator, &.{ dir_path, entry.name });
            if (entry.kind == .directory) {
                errdefer allocator.free(full_path);
                try self.state.directories.submit(io, full_path);
            } else {
                batch.paths[batch.len] = full_path;
                batch.len += 1;
                if (batch.len == paths_per_batch) try self.flush(&batch);
            }
        }
        if (!self.state.stopped.load(.acquire)) try self.flush(&batch);
    }
};

fn runSearch(
    io: std.Io,
    allocator: std.mem.Allocator,
    needle: []const u8,
    directories: []const [:0]const u8,
    jobs: usize,
    output: *Output,
) !void {
    if (needle.len == 0) return;

    const searcher = search.Searcher.init(needle);
    const buffer_size = chunk_size + max_needle_len - 1;
    const buffers = try allocator.alloc(u8, jobs * buffer_size);
    defer allocator.free(buffers);

    var directory_queue = DirectoryQueue.init(allocator);
    defer {
        while (directory_queue.drain()) |path| allocator.free(path);
        directory_queue.deinit();
    }
    const file_storage = try allocator.alloc(PathBatch, queued_batches);
    defer allocator.free(file_storage);
    var file_queue: FileQueue = .init(file_storage);
    defer {
        file_queue.close(io);
        while (file_queue.getOneUncancelable(io)) |batch| {
            batch.deinit(allocator);
        } else |_| {}
    }
    var state: State = .{
        .allocator = allocator,
        .directories = &directory_queue,
        .files = &file_queue,
    };
    for (directories) |directory| {
        const path = try allocator.dupe(u8, directory);
        errdefer allocator.free(path);
        try directory_queue.submit(io, path);
    }

    var search_workers: std.Io.Group = .init;
    defer search_workers.cancel(io);
    {
        defer file_queue.close(io);
        var traversal_workers: std.Io.Group = .init;
        defer traversal_workers.cancel(io);
        for (0..jobs) |i| {
            try search_workers.concurrent(io, SearchWorker.run, .{SearchWorker{
                .io = io,
                .state = &state,
                .searcher = &searcher,
                .buffer = buffers[i * buffer_size ..][0..buffer_size],
                .output = output,
            }});
        }
        for (0..jobs) |_| {
            try traversal_workers.concurrent(io, TraversalWorker.run, .{TraversalWorker{
                .io = io,
                .state = &state,
                .output = output,
            }});
        }
        try traversal_workers.await(io);
    }
    try search_workers.await(io);
    if (state.failure) |err| return err;
    if (output.failed) return error.WriteFailed;
}

fn containsRoot(parent: []const u8, child: []const u8) bool {
    if (!std.mem.startsWith(u8, child, parent)) return false;
    return child.len == parent.len or
        std.Io.Dir.path.isSep(parent[parent.len - 1]) or
        std.Io.Dir.path.isSep(child[parent.len]);
}

fn validateRoots(io: std.Io, allocator: std.mem.Allocator, directories: []const [:0]const u8, output: *Output) !bool {
    if (directories.len < 2) return true;
    const Root = struct {
        buffer: [std.Io.Dir.max_path_bytes]u8,
        len: usize,
    };
    const roots = try allocator.alloc(Root, directories.len);
    defer allocator.free(roots);
    for (directories, 0..) |directory, i| {
        roots[i].len = std.Io.Dir.cwd().realPathFile(io, directory, &roots[i].buffer) catch |err| switch (err) {
            error.Canceled => return err,
            else => {
                try output.report(io, "Error: cannot resolve root '{s}': {s}\n", .{ directory, @errorName(err) });
                return false;
            },
        };
        const current = roots[i].buffer[0..roots[i].len];
        for (roots[0..i], 0..) |*previous, j| {
            const path = previous.buffer[0..previous.len];
            if (containsRoot(path, current) or containsRoot(current, path)) {
                try output.report(io, "Error: overlapping roots '{s}' and '{s}'; pass each directory tree only once\n", .{ directories[j], directory });
                return false;
            }
        }
    }
    return true;
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

    const directories = args[arg_idx + 1 ..];
    if (!try validateRoots(init.io, init.gpa, directories, output)) return;
    try runSearch(init.io, init.gpa, needle, directories, jobs, output);
}

pub fn main(init: std.process.Init) void {
    var output_buffer: [1 << 12]u8 = undefined;
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
