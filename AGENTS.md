# ShareBeacon Agent Guide

## Project

ShareBeacon is a macOS 26 menu-bar application for keeping SMB shares available
and restoring Finder sidebar favorites after reconnects.

## Working Rules

- Support macOS 26 and later only. Keep the deployment target at macOS 26.0.
- Preserve the MIT license and credit the original authors in `LICENSE` and `README.md`.
- Never store passwords in configuration, URLs, process arguments, or logs.
- Prefer small, isolated changes with focused tests.
- Run `swift test` after core changes and `xcodebuild` or the release script after app/build changes.
- Use the commit-often pattern: commit one coherent change as soon as it is verified.
- Do not rewrite or squash history unless explicitly requested.
- Treat Finder sidebar preferences as an implementation detail. Use defensive checks,
  avoid destructive edits, and keep mounting functional if sidebar repair is unavailable.

## Current Priorities

1. Make share add/edit/disable/remove operations reconcile existing mounts safely.
2. Make reconnect behavior deterministic across network changes, sleep/wake, and stale mounts.
3. Restore configured Finder sidebar favorites after a successful mount without losing user data.
4. Improve diagnostics and prepare signed/notarized distribution.

## Verification

- `swift test`
- `swiftlint --strict` when SwiftLint is installed
- `xcodebuild -project jockey.xcodeproj -scheme jockey -configuration Debug build`
- `git diff --check`
