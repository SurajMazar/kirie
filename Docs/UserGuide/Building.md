# Building, testing and packaging

## Requirements

- macOS 14 or later, Apple Silicon.
- Swift 6 toolchain: the Xcode Command Line Tools are enough (`xcode-select --install`). Full Xcode works too.

## Build and test

```bash
swift build
```

```bash
Scripts/test.sh
```

`Scripts/test.sh` runs `swift test`. When only the Command Line Tools are installed it adds the search paths for the Swift Testing framework, which the tools ship but do not put on the default paths.

Run one suite:

```bash
Scripts/test.sh --filter AcceptanceTests
```

Forced-termination test (kills the CLI with `kill -9` while it is saving, then checks the project is valid):

```bash
Scripts/crash-recovery-test.sh 25
```

## Run

```bash
swift run KirieApp
```

or build the app bundle:

```bash
Scripts/build-app.sh
```

```bash
open dist/Kirie.app
```

To build and install into `/Applications` in one step:

```bash
Scripts/install.sh
```

The build script builds a release binary, creates `dist/Kirie.app` with its `Info.plist`, icon and document type, places the CLI in `Contents/Helpers`, and signs ad-hoc.

Developer screenshot tool (renders each workspace to PNG and quits):

```bash
dist/Kirie.app/Contents/MacOS/Kirie "/path/Project.kirie" --capture /tmp/shots --capture-screen
```

## Signing and notarising for distribution

Ad-hoc signing lets the app run on the Mac that built it. To distribute it you need an Apple Developer account. These steps are scripted but have not been run, because they need the owner's credentials:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/build-app.sh
```

```bash
ditto -c -k --keepParent dist/Kirie.app dist/Kirie.zip
```

```bash
xcrun notarytool submit dist/Kirie.zip --keychain-profile "kirie-notary" --wait
```

```bash
xcrun stapler staple dist/Kirie.app
```

The app requests no entitlements and is not sandboxed. With the hardened runtime it needs none for its current features. Mac App Store distribution would need sandboxing and security-scoped bookmarks, which are not implemented.

## Continuous integration

- `.github/workflows/ci.yml`: on every push and pull request, builds, runs the tests and the forced-termination test, builds the app bundle, runs a demo export end to end, and uploads the app as an artifact.
- `.github/workflows/release.yml`: on a `v*` tag, builds the app, zips it and attaches it to a GitHub release. If the signing secrets are configured it signs with Developer ID and notarises; otherwise the build is ad-hoc signed and the release notes say so.

Secrets for signed releases: `MACOS_CERTIFICATE_P12` (base64), `MACOS_CERTIFICATE_PASSWORD`, `MACOS_SIGN_IDENTITY`, `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD`.
