# androcall 0.1.0

The first release of androcall: use your Android phone's calls and contacts from your Mac
over Bluetooth.

## What you get

- **Browse your contacts** on the Mac, with search, favourites and profile photos.
- **Place calls** from the Mac, with a proper dial pad and international numbers.
- **See incoming calls** on the Mac, with the caller's name and number.
- **Answer, decline and end** calls from the Mac — when you make androcall your
  phone's default phone app.
- **No account, no server, no analytics.** Everything stays between your phone and
  your Mac.

## Downloads

| File | For |
|---|---|
| `androcall-macOS-Apple-Silicon-arm64.dmg` | M-series Macs |
| `androcall-macOS-Intel-x86_64.dmg` | Intel Macs |
| `androcall-macOS-Universal.dmg` | Either |
| `androcall-Android.apk` | The phone companion (Android 12 or later) |
| `SHA256SUMS.txt` | Checksums for all of the above |

## Getting started

1. Install the macOS app and the Android companion.
2. Pair the phone with your Mac in **System Settings › Bluetooth**.
3. Open the companion on the phone, enter a 6-digit code, and press **Start androcall**.
4. In androcall on the Mac, pick your phone and enter the same code.
5. **Check that the verification codes match** on both screens.

Full instructions: [`docs/SETUP.md`](docs/SETUP.md).

## Things worth knowing before you start

- **Call audio stays on the phone.** androcall controls the call; it does not route the
  audio to your Mac. Pair a headset with the *phone* if you want the call in your ears.
- **Answering and ending calls need the default-phone-app role.** Everything else works
  without it. The Mac shows the call and disables the two buttons it cannot honour,
  rather than pretending they work.
- **The macOS build is ad-hoc signed, not notarised.** macOS asks you to confirm the
  first time you open it — right-click › *Open*. The checksums are published with the
  release.
- **Background reliability depends on your phone's manufacturer.** androcall uses a
  foreground service, which is the most Android allows, but some OEM firmware suspends
  apps anyway. [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) lists the steps for
  each manufacturer.

## This is a prerelease

The protocol is verified by three independent implementations and covered by
automated tests, but **androcall has not yet been tested against a physical Android
phone**. The list of what has and has not been verified is in
[`docs/TESTING.md`](docs/TESTING.md). Please report anything that does not work — the
issues page is the right place.

## Licence

MIT.
