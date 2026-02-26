# Sentry-Zig: User Guide

Практическая документация по подключению SDK в приложение и использованию основных возможностей.

## 1. Подключение SDK

Добавьте зависимость:

```sh
zig fetch --save git+https://github.com/nullclaw/sentry-zig.git
```

Подключите модуль в `build.zig`:

```zig
const sentry_dep = b.dependency("sentry-zig", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("sentry-zig", sentry_dep.module("sentry-zig"));
```

Импортируйте в коде:

```zig
const sentry = @import("sentry-zig");
```

## 2. Инициализация клиента

Минимальный рабочий вариант:

```zig
const std = @import("std");
const sentry = @import("sentry-zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const client = try sentry.init(allocator, .{
        .dsn = "https://PUBLIC_KEY@o0.ingest.sentry.io/PROJECT_ID",
        .release = "my-app@1.0.0",
        .environment = "production",
    });
    defer client.deinit();

    client.captureMessage("app started", .info);
    _ = client.flush(5000);
}
```

Рекомендации:
- `release` лучше всегда задавать (нужен для release health sessions).
- `environment` задавайте явно (`production`, `staging`, `dev`).
- На завершении процесса делайте `flush(...)` или `close(...)`.

## 3. Отправка событий

Сообщение:

```zig
client.captureMessage("payment failed", .err);
```

Исключение:

```zig
client.captureException("PaymentError", "gateway timeout");
```

Получение `event_id`:

```zig
if (client.captureMessageId("checkout timeout", .warning)) |event_id| {
    std.log.info("captured event_id={s}", .{event_id});
}
```

Последний принятый ID:

```zig
if (client.lastEventId()) |id| {
    std.log.info("last event_id={s}", .{id});
}
```

## 4. Scope: user, tags, extras, breadcrumbs

```zig
client.setUser(.{
    .id = "user-42",
    .email = "user@example.com",
});
client.setTag("feature", "checkout");
client.setExtra("order_id", .{ .integer = 12345 });
client.setContext("region", .{ .string = "eu-west-1" });

client.addBreadcrumb(.{
    .category = "http",
    .message = "POST /api/checkout",
    .level = .info,
});
```

Очистка/удаление:

```zig
client.removeUser();
client.removeTag("feature");
client.removeExtra("order_id");
client.removeContext("region");
```

Дополнительно:
- `setLevel` задаёт уровень по умолчанию для событий в scope.
- `setTransaction` и `setFingerprint` позволяют переопределять группировку событий.

## 5. Attachments

Из памяти:

```zig
var attachment = try sentry.Attachment.initOwned(
    allocator,
    "debug.txt",
    "diagnostic payload",
    "text/plain",
    "event.attachment",
);
defer attachment.deinit(allocator);

client.addAttachment(attachment);
```

Из файла:

```zig
var file_attachment = try sentry.Attachment.fromPath(
    allocator,
    "/var/log/my-app.log",
    null,
    "text/plain",
    "event.attachment",
);
defer file_attachment.deinit(allocator);

client.addAttachment(file_attachment);
```

После `addAttachment` можно безопасно `deinit` локальную копию: SDK хранит собственную.

## 6. Трейсинг и транзакции

```zig
var txn = client.startTransaction(.{
    .name = "POST /checkout",
    .op = "http.server",
});
defer txn.deinit();

const span = try txn.startChild(.{
    .op = "db.query",
    .description = "INSERT INTO orders ...",
});
span.finish();

client.finishTransaction(&txn);
```

### Sampling для транзакций

Фиксированный sample rate:

```zig
const client = try sentry.init(allocator, .{
    .dsn = "...",
    .traces_sample_rate = 0.2,
});
```

Динамический sampler:

```zig
fn traceSampler(ctx: sentry.TracesSamplingContext) f64 {
    if (std.mem.eql(u8, ctx.transaction_name, "POST /checkout")) return 1.0;
    return 0.1;
}

const client = try sentry.init(allocator, .{
    .dsn = "...",
    .traces_sample_rate = 0.0,
    .traces_sampler = traceSampler,
});
```

`traces_sampler` имеет приоритет над `traces_sample_rate`.

## 7. Sessions (Release Health)

Ручное управление:

```zig
client.startSession();
// ... работа приложения ...
client.endSession(.exited);
```

Автоматическое:

```zig
const client = try sentry.init(allocator, .{
    .dsn = "...",
    .release = "my-app@1.0.0",
    .auto_session_tracking = true,
});
```

Важно:
- Без `release` сессия не стартует.
- `session_mode = .application` считает `duration`.
- `session_mode = .request` duration не отправляет (режим коротких request-сессий).

## 8. Cron Monitoring (Check-ins)

```zig
var check_in = sentry.MonitorCheckIn.init("nightly-job", .in_progress);
client.captureCheckIn(&check_in);

check_in.status = .ok;
check_in.duration = 12.3;
client.captureCheckIn(&check_in);
```

Если у check-in `environment == null`, SDK подставит `Options.environment`.

## 9. Hooks и event processors

`before_send`:

```zig
fn beforeSend(event: *sentry.Event) ?*sentry.Event {
    if (event.level == .debug) return null; // drop
    return event; // важно: вернуть тот же указатель
}
```

`before_breadcrumb`:

```zig
fn beforeBreadcrumb(crumb: sentry.Breadcrumb) ?sentry.Breadcrumb {
    if (crumb.category != null and std.mem.eql(u8, crumb.category.?, "healthcheck")) return null;
    return crumb;
}
```

`event processor` в scope (возвращает `false`, чтобы дропнуть событие):

```zig
fn processor(event: *sentry.Event) bool {
    if (event.message != null and event.message.?.formatted != null and
        std.mem.indexOf(u8, event.message.?.formatted.?, "ignore-me") != null)
    {
        return false;
    }
    return true;
}

try client.addEventProcessor(processor);
```

## 10. Crash handling (POSIX signals)

По умолчанию SDK ставит signal handlers (`SIGSEGV`, `SIGABRT`, `SIGBUS`, `SIGILL`, `SIGFPE`).

Конфигурация:
- `install_signal_handlers = true|false`
- `cache_dir` — путь для crash marker файлов.

## 11. Flush, Close, Deinit

`flush(timeout_ms)`:
- ждёт, пока очередь отправки опустеет;
- не выключает клиент.

`close(timeout_ms_or_null)`:
- завершает сессию;
- flush + shutdown worker;
- возвращает `true`, если успело дренироваться в timeout.

`deinit()`:
- безопасное завершение клиента;
- вызывает shutdown-путь автоматически.

Для обычного приложения достаточно:

```zig
defer client.deinit();
// перед выходом по желанию:
_ = client.flush(5000);
```

## 12. Проверка и отладка

Запуск всех тестов:

```sh
zig build test
```

Только интеграционные:

```sh
zig build test-integration
```

## 13. Production checklist

- Задать `release`, `environment`, `server_name`.
- Выбрать sampling: `sample_rate`, `traces_sample_rate`/`traces_sampler`.
- Настроить `before_send` для редактирования/фильтрации данных.
- Добавить breadcrumbs в критические CJM-точки.
- Проверить graceful shutdown (`flush`/`deinit`).
- Проверить доставку на staging до выката в production.
