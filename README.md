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
- Credentials kept out of URLs, configuration, process arguments, and logs
- User-owned or `/Volumes` mount points
- Settings window with Shares, General, and Log tabs (live log with level filter)
- Finder sidebar favorite repair with a safe no-op fallback
- macOS 26 or newer, Apple Silicon and Intel

## Requirements

- macOS Tahoe 26 or newer
- Xcode or Xcode Command Line Tools
- Access to an SMB server

## Versioning

ShareBeacon currently uses a two-part product version, starting at `0.1`.
Release tags use the same format, for example `v0.1`. Build numbers are
separate and increase for each CI build.

## Build and Test

```bash
swift test
./scripts/build-release.sh
```

Use `./scripts/build-release.sh --clean` for a clean derived-data build or
`./scripts/build-release.sh --skip-sign` when only an unsigned local artifact
is needed. Release ZIPs include a SHA-256 checksum.

The release build is universal and currently ad-hoc signed. Notarized
distribution is planned. The application does not require Full Disk Access.

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

## Credits

ShareBeacon is an independent project derived from
[othyn/macos-jockey](https://github.com/othyn/macos-jockey), originally created
by Ben Tindall.

- Ben Tindall ([@othyn](https://github.com/othyn)): original Jockey for macOS author
- Valentine Ubani Mayaki ([@valmayaki](https://github.com/valmayaki)): security-focused fork and mount-manager improvements
- Joerg Mattiello ([@mjoe](https://github.com/mjoe)): ShareBeacon maintainer and further development

## License

MIT. See [LICENSE](LICENSE).
