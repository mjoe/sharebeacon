# ShareBeacon Agent Guide

ShareBeacon is a macOS 26 menu-bar application for keeping SMB shares available
and restoring Finder sidebar favorites after reconnects.

## Working Rules

- Support macOS 26 and later only. Keep the deployment target at macOS 26.0.
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

`xcode-select` points at CommandLineTools, whose toolchain has no `Testing`
module. Run the package tests with the Xcode toolchain and SDK instead:

```bash
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.sdk \
DYLD_FRAMEWORK_PATH=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks
```
