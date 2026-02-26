const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const MAX_QUEUE_SIZE: usize = 100;

pub const WorkItem = struct {
    data: []u8,
};

pub const SendOutcome = struct {
    retry_after_secs: ?u64 = null,
};

pub const SendFn = *const fn ([]const u8, ?*anyopaque) SendOutcome;

/// Background worker thread that consumes work items from a thread-safe queue.
pub const Worker = struct {
    allocator: Allocator,
    queue: std.ArrayListUnmanaged(WorkItem) = .{},
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    flush_condition: std.Thread.Condition = .{},
    shutdown_flag: bool = false,
    in_flight: usize = 0,
    rate_limited_until_ns: ?i128 = null,
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

                var should_send = true;
                if (self.rate_limited_until_ns) |until| {
                    const now = std.time.nanoTimestamp();
                    if (now < until) {
                        should_send = false;
                    } else {
                        self.rate_limited_until_ns = null;
                    }
                }

                if (should_send) {
                    const outcome = self.send_fn(work.data, self.send_ctx);
                    if (outcome.retry_after_secs) |retry_after_secs| {
                        self.rate_limited_until_ns = std.time.nanoTimestamp() + @as(i128, @intCast(retry_after_secs)) * std.time.ns_per_s;
                    }
                }

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

fn testSendFn(_: []const u8, _: ?*anyopaque) SendOutcome {
    test_send_count += 1;
    return .{};
}

fn noopSendFn(_: []const u8, _: ?*anyopaque) SendOutcome {
    return .{};
}

fn rateLimitingSendFn(_: []const u8, ctx: ?*anyopaque) SendOutcome {
    const counter: *usize = @ptrCast(@alignCast(ctx.?));
    counter.* += 1;
    if (counter.* == 1) {
        return .{ .retry_after_secs = 1 };
    }
    return .{};
}

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

test "Worker drops queued items while rate limited" {
    var send_count: usize = 0;

    var worker = Worker.init(testing.allocator, rateLimitingSendFn, @ptrCast(&send_count));
    defer worker.deinit();

    try worker.start();

    const first = try testing.allocator.dupe(u8, "first");
    try worker.submit(first);

    const second = try testing.allocator.dupe(u8, "second");
    try worker.submit(second);

    _ = worker.flush(1000);
    worker.shutdown();

    // First send triggers retry-after; second should be dropped by rate limit.
    try testing.expectEqual(@as(usize, 1), send_count);
}
