# ShareBeacon Agent Guide

ShareBeacon is a macOS menu-bar application for keeping SMB shares available
and restoring Finder sidebar favorites after reconnects.

## Working Rules

- Support macOS 26 and later only, including macOS 27. Keep the deployment
  target at macOS 26.0 so the app still runs on Tahoe; build against the newest
  SDK the installed Xcode provides.
- Prefer APIs available in macOS 26.0. Guard anything newer (for example
  `GlassButtonStyle(_:)`) with `#available` or `#if compiler`.
- The package manifest uses `swift-tools-version: 6.3`, which is the lowest
  version that pairs with a macOS 27 capable toolchain while still building on
  the `macos-26` CI runner.
- Preserve the MIT license and credit Ben Tindall and Valentine Ubani Mayaki.
- Never store passwords in configuration, URLs, process arguments, or logs.
- Prefer small, isolated changes with focused tests.
- Run `swift test` after core changes and `git diff --check` before every commit.
- Use commit-often: commit one coherent change as soon as it is verified.
- Finder sidebar repair is best-effort and must never block mounting.
- Keep the product version in `VERSION` using two numeric components.
- Use `GITHUB_RUN_NUMBER` as the CI build number; local builds use the commit count unless `BUILD_NUMBER` is provided.

## Priorities

1. Reconcile existing mounts safely when shares are edited, disabled, or removed.
2. Make reconnect behavior deterministic across network and sleep/wake events.
3. Restore configured Finder sidebar favorites after a successful mount.
4. Improve diagnostics and prepare signed/notarized distribution.

## Verification

- `swift test` (this machine needs the Xcode toolchain + SDK; see below)
- `swiftlint --strict` when SwiftLint is installed
- `xcodebuild -project ShareBeacon.xcodeproj -scheme ShareBeacon -configuration Debug build`
- `git diff --check`

### Running tests on this machine

`xcode-select` points at CommandLineTools. Point `DEVELOPER_DIR` at Xcode so
`swift` and `xcodebuild` pick up the macOS 27 toolchain and `Testing` module:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
```

Homebrew SwiftLint builds on macOS 27 look for `sourcekitdInProc.framework`
inside `usr/lib/swift-6.2`, which Xcode 27 no longer ships. Add the toolchain
library directory so linting works:

```bash
DYLD_FRAMEWORK_PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib \
  swiftlint --strict
```
