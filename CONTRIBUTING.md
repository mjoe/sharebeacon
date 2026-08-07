# Contributing

ShareBeacon accepts focused pull requests against `main`.

## Development Transparency

ShareBeacon may be developed with AI-assisted tools. All generated or
AI-assisted changes are reviewed, tested, and ultimately maintained by Joerg
Mattiello. AI tools are not copyright holders or project authors.

Before opening a pull request:

```bash
swift test
swiftlint --strict
./scripts/build-release.sh
```

Security requirements:

- Never add passwords to configuration, logs, URLs, process arguments, or tests.
- Keep credentials in macOS Keychain and pass them to NetFS only in memory.
- Do not add telemetry or external network calls without explicit documentation.
- Pin GitHub Actions and source dependencies to immutable revisions.
- Support macOS 26 and newer only.

Use short conventional commit subjects such as:

```text
feat: add per-share mount options
fix: serialize reconnect attempts
docs: clarify Keychain setup
```
