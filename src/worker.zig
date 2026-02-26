const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const MAX_QUEUE_SIZE: usize = 100;

pub const WorkItem = struct {
    data: []u8,
};

pub const SendFn = *const fn ([]const u8, ?*anyopaque) void;

/// Background worker thread that consumes work items from a thread-safe queue.
pub const Worker = struct {
    allocator: Allocator,
    queue: std.ArrayListUnmanaged(WorkItem) = .{},
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    flush_condition: std.Thread.Condition = .{},
    shutdown_flag: bool = false,
    in_flight: usize = 0,
    thread: ?std.Thread = null,
    send_fn: SendFn,
    send_ctx: ?*anyopaque = null,

    pub fn init(allocator: Allocator, send_fn: SendFn, send_ctx: ?*anyopaque) Worker {
        return .{
            .allocator = allocator,
            .send_fn = send_fn,
            .send_ctx = send_ctx,
        };
    }

    pub fn deinit(self: *Worker) void {
        for (self.queue.items) |item| {
            self.allocator.free(item.data);
        }
        self.queue.deinit(self.allocator);
    }

    /// Spawn the background worker thread.
    pub fn start(self: *Worker) !void {
        self.thread = try std.Thread.spawn(.{}, workerLoop, .{self});
    }

    /// Submit a work item to the queue. The worker takes ownership of data.
    /// If the queue is full, the oldest item is dropped.
    /// If shutdown has been requested, the data is freed immediately.
    pub fn submit(self: *Worker, data: []u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.shutdown_flag) {
            self.allocator.free(data);
            return;
        }

        if (self.queue.items.len >= MAX_QUEUE_SIZE) {
            const old = self.queue.orderedRemove(0);
            self.allocator.free(old.data);
        }

        try self.queue.append(self.allocator, .{ .data = data });
        self.condition.signal();
    }

    /// Flush the queue, waiting up to timeout_ms for it to drain.
    /// Returns true if the queue is empty after flush.
    pub fn flush(self: *Worker, timeout_ms: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const timeout_ns: i128 = @as(i128, @intCast(timeout_ms)) * std.time.ns_per_ms;
        const deadline = std.time.nanoTimestamp() + timeout_ns;

        while (self.queue.items.len > 0 or self.in_flight > 0) {
            // Wake the worker to process queued items.
            self.condition.signal();

            const now = std.time.nanoTimestamp();
            if (now >= deadline) return false;

            const remaining: u64 = @intCast(deadline - now);
            self.flush_condition.timedWait(&self.mutex, remaining) catch {};
        }

        return true;
    }

    /// Signal shutdown and wait for the worker thread to finish.
    pub fn shutdown(self: *Worker) void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.shutdown_flag = true;
            self.condition.signal();
        }

        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// Return the current queue length (thread-safe).
    pub fn queueLen(self: *Worker) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.queue.items.len;
    }

    fn workerLoop(self: *Worker) void {
        while (true) {
            var item: ?WorkItem = null;

            {
                self.mutex.lock();
                defer self.mutex.unlock();

                while (self.queue.items.len == 0 and !self.shutdown_flag) {
                    self.condition.wait(&self.mutex);
                }

                if (self.shutdown_flag and self.queue.items.len == 0 and self.in_flight == 0) {
                    self.flush_condition.signal();
                    return;
                }

                if (self.queue.items.len > 0) {
                    item = self.queue.orderedRemove(0);
                    self.in_flight += 1;
                }

                if (self.queue.items.len == 0 and self.in_flight == 0) {
                    self.flush_condition.signal();
                }
            }

            if (item) |work| {
                defer self.allocator.free(work.data);
                self.send_fn(work.data, self.send_ctx);

                self.mutex.lock();
                self.in_flight -= 1;
                if (self.queue.items.len == 0 and self.in_flight == 0) {
                    self.flush_condition.signal();
                }
                self.mutex.unlock();
            }
        }
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

var test_send_count: usize = 0;

fn testSendFn(_: []const u8, _: ?*anyopaque) void {
    test_send_count += 1;
}

fn noopSendFn(_: []const u8, _: ?*anyopaque) void {}

test "Worker submit and process via background thread" {
    test_send_count = 0;

    var worker = Worker.init(testing.allocator, testSendFn, null);
    defer worker.deinit();

    try worker.start();

    // Submit a work item
    const data1 = try testing.allocator.dupe(u8, "item-1");
    try worker.submit(data1);

    const data2 = try testing.allocator.dupe(u8, "item-2");
    try worker.submit(data2);

    // Flush to wait for processing
    _ = worker.flush(1000);

    worker.shutdown();

    try testing.expectEqual(@as(usize, 2), test_send_count);
}

test "Worker drops oldest when queue full" {
    var worker = Worker.init(testing.allocator, noopSendFn, null);
    defer worker.deinit();

    // Don't start the thread so items accumulate
    // Submit MAX_QUEUE_SIZE + 5 items
    var i: usize = 0;
    while (i < MAX_QUEUE_SIZE + 5) : (i += 1) {
        const data = try testing.allocator.dupe(u8, "item");
        try worker.submit(data);
    }

    try testing.expectEqual(MAX_QUEUE_SIZE, worker.queueLen());
}

test "Worker shutdown drains remaining items" {
    test_send_count = 0;

    var worker = Worker.init(testing.allocator, testSendFn, null);
    defer worker.deinit();

    try worker.start();

    const data = try testing.allocator.dupe(u8, "final-item");
    try worker.submit(data);

    // Shutdown should process remaining items
    worker.shutdown();

    // The item should have been processed or freed
    try testing.expectEqual(@as(usize, 0), worker.queueLen());
}

test "Worker flush returns true when queue is empty" {
    var worker = Worker.init(testing.allocator, noopSendFn, null);
    defer worker.deinit();

    // Empty queue => flush should return true immediately
    try testing.expect(worker.flush(100));
}
