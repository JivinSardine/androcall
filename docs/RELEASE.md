# Building and publishing a release

This document describes how the release artefacts are produced and published.

## What gets published

| Asset | Built by |
|---|---|
| `androcall-macOS-Intel-x86_64.dmg` | `scripts/build_macos.py --arch x86_64 --dmg` |
| `androcall-macOS-Apple-Silicon-arm64.dmg` | `scripts/build_macos.py --arch arm64 --dmg` |
| `androcall-macOS-Universal.dmg` | `scripts/build_macos.py --arch both --dmg` |
| `androcall-Android.apk` | `cd android && ./gradlew assembleRelease` |
| `SHA256SUMS.txt` | `shasum -a 256` over the assets |

## Building by hand

```bash
# 1. The icon (regenerate it if the design changes)
python3 scripts/make_icon.py

# 2. The macOS installers
python3 scripts/build_macos.py --arch both --dmg

# 3. The Android APK
cd android
ANDROCALL_REPO_ROOT="$(cd .. && pwd)" ./gradlew testDebugUnitTest assembleRelease
cd ..

# 4. Collect and checksum the assets
mkdir -p /tmp/androcall-release
cp dist/androcall-macOS-*.dmg /tmp/androcall-release/
cp android/app/build/outputs/apk/release/app-release.apk /tmp/androcall-release/androcall-Android.apk
cd /tmp/androcall-release
for f in *.dmg *.apk; do shasum -a 256 "$f"; done > SHA256SUMS.txt
```

## Signing

### macOS

The build is currently **ad-hoc signed**. `scripts/build_macos.py` writes the
entitlements (`com.apple.security.device.bluetooth`) and signs the bundle with
`codesign --sign -`, which makes it run on the build machine but is not a Developer ID
signature and is not notarised.

To sign properly you need a Developer ID Application certificate and an Apple
Developer account. With the certificate in the keychain:

```bash
codesign --force --options runtime \
  --entitlements build/macos/androcall-<arch>.entitlements.plist \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  build/macos/androcall-<arch>.app

xcrun notarytool submit build/macos/androcall-<arch>.app.zip \
  --apple-id you@example.com --team-id TEAMID --password APP-SPECIFIC-PASSWORD
xcrun stapler staple build/macos/androcall-<arch>.app
```

**Never** commit a certificate, a `.p12`, a notarisation profile or an Apple ID
password. The CI workflow must not contain signing credentials either — the release
job builds unsigned artefacts, and signing happens on a trusted machine.

### Android

The release APK is signed with the debug key so that a downloadable APK can always be
produced without any secrets in the repository. To sign it properly, create a keystore
and add a `signingConfigs.release` block reading the credentials from
`keystore.properties` (which is in `.gitignore`) or from environment variables:

```kotlin
signingConfigs {
    create("release") {
        storeFile = file(System.getenv("ANDROCALL_KEYSTORE") ?: "release.jks")
        storePassword = System.getenv("ANDROCALL_KEYSTORE_PASSWORD")
        keyAlias = System.getenv("ANDROCALL_KEY_ALIAS")
        keyPassword = System.getenv("ANDROCALL_KEY_PASSWORD")
    }
}
```

The keystore and its passwords must never be committed.

## Publishing

```bash
git tag -a v0.1.0 -m "androcall 0.1.0"
git push origin v0.1.0

gh release create v0.1.0 \
  --title "androcall 0.1.0" \
  --notes-file RELEASE_NOTES.md \
  --prerelease \
  /tmp/androcall-release/*.dmg /tmp/androcall-release/*.apk /tmp/androcall-release/SHA256SUMS.txt
```

Pushing the tag also triggers `.github/workflows/release.yml`, which rebuilds the
artefacts on a clean runner and publishes them. Use the manual path above when the
artefacts must be signed on a trusted machine.

## Before publishing

1. `python3 scripts/run_tests_macos.py` — all tests pass.
2. `cd android && ./gradlew testDebugUnitTest` — all tests pass.
3. `python3 tools/reference/generate_vectors.py --check` — the vectors are current.
4. The installers build and `hdiutil verify` succeeds on each `.dmg`.
5. `docs/TESTING.md` reflects what was actually tested.
6. `docs/PROJECT_STATUS.md` is up to date.
7. The version is bumped in `scripts/build_macos.py` (`MARKETING_VERSION`) and in
   `android/app/build.gradle.kts` (`versionName`).
8. `CHANGELOG.md` has an entry for the release.

Mark the release as a **prerelease** while the physical-device tests in
`docs/TESTING.md` are still outstanding.
