const std = @import("std");

pub fn WorkQueue(comptime Task: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        tasks: std.Deque(Task) = .empty,
        mutex: std.Io.Mutex = .init,
        available: std.Io.Condition = .init,
        pending: usize = 0, // Queued plus currently executing tasks.
        closed: bool = false,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.tasks.deinit(self.allocator);
        }

        pub fn drain(self: *Self) ?Task {
            return self.tasks.popFront();
        }

        pub fn submit(self: *Self, io: std.Io, task: Task) !void {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            if (self.closed) return error.Closed;
            try self.tasks.pushBack(self.allocator, task);
            self.pending += 1;
            self.available.signal(io);
        }

        pub fn next(self: *Self, io: std.Io) !?Task {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            while (!self.closed) {
                if (self.tasks.popFront()) |task| return task;
                if (self.pending == 0) return null;
                try self.available.wait(io, &self.mutex);
            }
            return null;
        }

        pub fn done(self: *Self, io: std.Io) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            std.debug.assert(self.pending != 0);
            self.pending -= 1;
            if (self.pending == 0) self.available.broadcast(io);
        }

        pub fn close(self: *Self, io: std.Io) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.closed = true;
            self.available.broadcast(io);
        }
    };
}
