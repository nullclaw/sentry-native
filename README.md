# Sentry-Zig

Pure Zig Sentry SDK -- zero external dependencies. Captures errors, exceptions,
transactions, and sessions, then delivers them to [Sentry](https://sentry.io)
via the envelope protocol over HTTPS.

Detailed usage guide: [docs/USER_GUIDE.md](docs/USER_GUIDE.md)

## Requirements

- Zig >= 0.15.0

## Installation

Add the dependency with `zig fetch`:

```sh
zig fetch --save git+https://github.com/nullclaw/sentry-zig.git
```

Then import the module in your `build.zig`:

```zig
const sentry_dep = b.dependency("sentry-zig", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("sentry-zig", sentry_dep.module("sentry-zig"));
```

## Usage

```zig
const std = @import("std");
const sentry = @import("sentry-zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Initialize the Sentry client (heap-allocated, returns *Client)
    const client = try sentry.init(allocator, .{
        .dsn = "https://examplePublicKey@o0.ingest.sentry.io/0",
        .release = "my-app@1.0.0",
        .environment = "production",
        .traces_sample_rate = 1.0,
    });
    defer client.deinit();

    // Set user context
    client.setUser(.{
        .id = "user-42",
        .email = "user@example.com",
    });

    // Add a breadcrumb
    client.addBreadcrumb(.{
        .message = "Application started",
        .category = "lifecycle",
        .level = .info,
    });

    // Capture a message
    client.captureMessage("Something noteworthy happened", .info);

    // Capture an exception
    client.captureException("RuntimeError", "division by zero");

    // Attach additional binary/text payloads to upcoming events
    var attachment = try sentry.Attachment.initOwned(
        allocator,
        "debug.txt",
        "diagnostic payload",
        "text/plain",
        "event.attachment",
    );
    defer attachment.deinit(allocator);
    client.addAttachment(attachment);

    // Start a transaction for performance monitoring
    var txn = client.startTransaction(.{
        .name = "GET /api/users",
        .op = "http.server",
    });
    defer txn.deinit();

    // Add a child span
    const span = try txn.startChild(.{
        .op = "db.query",
        .description = "SELECT * FROM users",
    });
    span.finish();

    // Finish the transaction (serializes and enqueues for sending)
    client.finishTransaction(&txn);

    // Start a session for release health
    client.startSession();

    // ... application logic ...

    // End the session
    client.endSession(.exited);

    // Send a monitor check-in
    var check_in = sentry.MonitorCheckIn.init("nightly-job", .ok);
    client.captureCheckIn(&check_in);

    // Flush pending events before shutdown (5 second timeout)
    _ = client.flush(5000);
}
```

## Features

- **Error Capture** -- `captureMessage` and `captureException` with automatic
  enrichment from the scope (user, tags, breadcrumbs, extras, contexts).
- **Performance Monitoring** -- Distributed tracing with `Transaction` and `Span`
  types, including parent-child span relationships and trace context propagation.
- **Release Health** -- Session tracking with `startSession` / `endSession` and
  automatic error-counting.
- **Attachments** -- Attach arbitrary binary/text payloads to captured events.
- **Cron Monitoring** -- `captureCheckIn` support for monitor check-ins (`check_in` envelopes).
- **Crash Reporting** -- POSIX signal handlers (SIGSEGV, SIGABRT, SIGBUS, SIGILL,
  SIGFPE) write crash markers to disk, which are picked up on next startup.
- **Scope Management** -- Thread-safe scope with user context, tags, extras,
  contexts, and a ring-buffer breadcrumb store.
- **Background Worker** -- Events are serialized to the Sentry envelope format
  and sent asynchronously via a background thread with a bounded queue.
- **HTTP Transport** -- Envelopes are delivered via `std.http.Client` POST to
  the Sentry envelope endpoint. `Retry-After` and `X-Sentry-Rate-Limits`
  headers are parsed, with category-aware backoff in the worker.
- **Sampling** -- Configurable `sample_rate` for events and `traces_sample_rate`
  for transactions.
- **Before-Send Hook** -- Optional `before_send` callback to inspect or drop
  events before they are enqueued.
- **Before-Breadcrumb Hook** -- Optional `before_breadcrumb` callback to inspect
  or drop breadcrumbs before they enter the scope buffer.
- **Scope Event Processors** -- Per-scope processors can mutate or drop events
  before final envelope serialization.
- **Pure Zig** -- No libc, no C dependencies, no allocations outside the
  standard library allocator you provide.

## Configuration

All options are set via the `Options` struct passed to `sentry.init`:

| Option                    | Type                              | Default              | Description                              |
|---------------------------|-----------------------------------|----------------------|------------------------------------------|
| `dsn`                     | `[]const u8`                      | (required)           | Sentry DSN string                        |
| `debug`                   | `bool`                            | `false`              | Enable SDK debug mode flag               |
| `release`                 | `?[]const u8`                     | `null`               | Release identifier                       |
| `environment`             | `?[]const u8`                     | `null`               | Environment name                         |
| `server_name`             | `?[]const u8`                     | `null`               | Server / host name                       |
| `sample_rate`             | `f64`                             | `1.0`                | Event sample rate (0.0 -- 1.0)           |
| `traces_sample_rate`      | `f64`                             | `0.0`                | Transaction sample rate (0.0 -- 1.0)     |
| `traces_sampler`          | `?TracesSampler`                  | `null`               | Per-transaction sampler callback         |
| `max_breadcrumbs`         | `u32`                             | `100`                | Maximum breadcrumbs kept in scope        |
| `attach_stacktrace`       | `bool`                            | `false`              | Stacktrace capture flag (reserved)       |
| `send_default_pii`        | `bool`                            | `false`              | PII capture flag (reserved)              |
| `before_send`             | `?*const fn (*Event) ?*Event`     | `null`               | Pre-send hook (return same ptr or null to drop) |
| `before_breadcrumb`       | `?*const fn (Breadcrumb) ?Breadcrumb` | `null`           | Pre-breadcrumb hook (return null to drop)|
| `cache_dir`               | `[]const u8`                      | `"/tmp/sentry-zig"`  | Directory for crash marker files         |
| `user_agent`              | `[]const u8`                      | `"sentry-zig/0.1.0"` | User-Agent header for outbound requests  |
| `install_signal_handlers` | `bool`                            | `true`               | Install POSIX crash signal handlers      |
| `auto_session_tracking`   | `bool`                            | `false`              | Start a release-health session on init   |
| `session_mode`            | `SessionMode`                     | `.application`       | Session mode: application or request     |
| `shutdown_timeout_ms`     | `u64`                             | `2000`               | Flush timeout used during `deinit`       |

## Testing

Run all tests (unit + integration):

```sh
zig build test
```

Run only integration tests:

```sh
zig build test-integration
```

## License

MIT
