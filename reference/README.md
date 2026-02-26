# Sentry Upstream References

This folder is used for local, disposable checkouts of official Sentry SDKs.
It is intentionally ignored by git (except this file and `fetch-sources.sh`).

## Included SDKs

- sentry-native (C/C++)
- sentry-rust (Rust)
- sentry-python (Python)
- sentry-javascript (JavaScript / TypeScript)
- sentry-java (Java / Kotlin)
- sentry-cocoa (Swift / Objective-C)
- sentry-dotnet (.NET / C#)
- sentry-go (Go)

## Refresh

```sh
./reference/fetch-sources.sh
```
