# ShareBeacon

ShareBeacon is a macOS Tahoe (26) menu-bar application that keeps SMB shares
available over LANs, Tailscale, WireGuard, OpenVPN, and other routed networks.
It stores credentials in the login Keychain and is designed to restore Finder
sidebar favorites after a share reconnects.

## Features

- Multiple independently configured SMB shares
- Per-share automatic reconnect or on-demand mounting
- Shared Keychain credentials reused across shares
- Serialized mount operations and endpoint readiness checks
- Automatic recovery after login, network changes, sleep/wake, and disconnects
- Sleep-aware: pauses all monitoring and mount activity while the Mac sleeps
- Credentials kept out of URLs, configuration, process arguments, and logs
- User-owned mount points by default, without requiring administrator privileges; custom paths such as `/Volumes` are supported
- Settings window with Shares, General, and Log tabs (live log with level filter)
- Finder sidebar favorite repair with a safe no-op fallback
- macOS 26 or newer, Apple Silicon and Intel

## Installation

ShareBeacon requires macOS 26 or newer. Releases are signed with a Developer
ID certificate, notarized by Apple, and distributed through GitHub Releases.

### Homebrew

Install from the ShareBeacon tap:

```bash
brew install mjoe/sharebeacon/sharebeacon
```

To update later:

```bash
brew upgrade sharebeacon
```

### Manual

Download the latest `ShareBeacon-<version>.zip` and its `.sha256` checksum from
the [releases page](https://github.com/mjoe/sharebeacon/releases), verify the
checksum, unzip, and move `ShareBeacon.app` to your Applications folder.

## Requirements

- macOS Tahoe 26 or newer
- Xcode or Xcode Command Line Tools
- Access to an SMB server

New shares use a user-owned `~/Volumes/<share-name>` mount point by default, so
ShareBeacon can create it without elevated privileges. Custom mount points,
including `/Volumes/<share-name>`, can be selected when needed.

## Versioning

ShareBeacon uses a two-part product version, currently `0.8`.
Release tags use the same format, for example `v0.8`. Release titles are
`ShareBeacon <version>` (for example `ShareBeacon 0.8`). Build numbers are
separate and increase for each CI build.

## Build and Test

```bash
swift test
./scripts/build-release.sh
```

Use `./scripts/build-release.sh --clean` for a clean derived-data build,
`--skip-sign` when only an unsigned local artifact is needed, and `--notarize`
to submit the release to Apple notarization and staple the ticket. The
`--notarize` option requires `NOTARY_KEY_ID`, `NOTARY_ISSUER`, and
`NOTARY_KEY_PATH`. Release ZIPs include a SHA-256 checksum.

The release build is universal. When a Developer ID Application certificate is
installed in the login keychain, `build-release.sh` signs with it (with
Hardened Runtime) instead of ad-hoc. The application does not require Full Disk
Access.

Releases are published as GitHub releases on
[mjoe/sharebeacon](https://github.com/mjoe/sharebeacon) and distributed through
the [mjoe/homebrew-sharebeacon](https://github.com/mjoe/homebrew-sharebeacon)
tap. Publish a release with `gh release create` rather than pushing a tag, so
the CI release job does not overwrite the notarized assets with an unsigned
build.

## Security

Passwords are stored as generic-password Keychain items and passed to NetFS
directly in process memory. The SMB URL contains only the host and share name.
Share configuration is stored in UserDefaults without passwords. ShareBeacon
does not use telemetry, analytics, or external APIs.

## Finder Favorites

Finder sidebar state is managed by macOS rather than a stable public API.
ShareBeacon therefore treats favorite repair as best-effort: it preserves the
user's configured mount path, attempts a non-destructive repair after mounting,
and never makes mounting depend on sidebar manipulation.

To create a favorite initially, configure and save the share, mount it, then
choose **Add to Finder Favorites** from that share's menu. ShareBeacon also
attempts this automatically after every successful reconnect. If Finder does
not refresh immediately, relaunch Finder once.

## Sleep Mode

ShareBeacon respects the Mac's sleep mode. When the system begins sleeping it
pauses all share monitoring, cancels in-flight mount operations, and starts no
new reconnection attempts. After the Mac wakes it resumes automatically, waits
a short network grace period so the connection is ready, and then reconnects
shares that are configured to mount automatically. ShareBeacon never keeps the
Mac awake or blocks it from sleeping.

## Credits

ShareBeacon is an independent project derived from
[othyn/macos-jockey](https://github.com/othyn/macos-jockey), originally created
by Ben Tindall.

- Ben Tindall ([@othyn](https://github.com/othyn)): original Jockey for macOS author
- Valentine Ubani Mayaki ([@valmayaki](https://github.com/valmayaki)): security-focused fork and mount-manager improvements
- Joerg Mattiello ([@mjoe](https://github.com/mjoe)): ShareBeacon maintainer and further development

## License

MIT. See [LICENSE](LICENSE).
