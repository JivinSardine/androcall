# Project status

**Last updated:** 2026-10-20
**Version:** 0.1.0 (prerelease)

## What exists right now

androcall is a working macOS application and a working Android companion that speak a
versioned, authenticated, encrypted protocol to each other over Bluetooth Low Energy.

| Component | State |
|---|---|
| macOS app (Swift/SwiftUI) | **Built and verified running.** All eleven screens implemented; the app launches, renders and requests Bluetooth permission correctly. |
| Android companion (Kotlin) | **Built.** A release APK is produced (6.4 MB). |
| Wire protocol v1 | **Specified, implemented three times, pinned by shared conformance vectors.** |
| Build system | **Works without Xcode.** `swiftc` + a Python assembler produce the `.app` and the `.dmg` for Intel and Apple Silicon. |
| Automated tests | **47 passing** — 40 on macOS, 7 on Android — plus the reference implementation's NIST vector checks. |
| CI and release workflows | **Written.** |
| Public repository and release | **Created.** |

## Decisions that shape the project

1. **An Android companion is mandatory.** macOS exposes no public API for PBAP, HFP
   call control or MAP. The phone must expose the functionality itself.
2. **BLE GATT, with the phone as the server.** macOS's CoreBluetooth peripheral role is
   not usable in practice, and the deprecated `IOBluetooth` API is not worth the App
   Store risk for a public project.
3. **Two tiers of call control.** Android only lets an app answer, decline and end
   calls when it is the phone's default phone app. Everything else works without that
   role; the Mac disables the controls it cannot honour instead of shipping dead
   buttons.
4. **Call audio stays on the phone.** androcall is a control surface, not an audio
   device.
5. **No Xcode.** The build uses `swiftc` and a hand-assembled bundle, which works on any
   Mac with the Command Line Tools and makes the macOS 12 deployment target a
   compile-time constraint.
6. **The protocol is verified by three implementations.** Swift, Kotlin and an
   independent Python reference all have to agree on the golden vectors.

The reasoning is written up in
[`docs/architecture/ADR-0001-transport-and-architecture.md`](architecture/ADR-0001-transport-and-architecture.md)
and the vendor research is in
[`docs/TECHNICAL_FEASIBILITY.md`](TECHNICAL_FEASIBILITY.md).

## What is verified

| Check | Result |
|---|---|
| The reference implementation against FIPS-197 and the NIST CAVP GCM vectors | **Pass** (7872/7872 GCM vectors) |
| The conformance vectors against the reference | **Pass** (`generate_vectors.py --check`) |
| The macOS test suite | **Pass** — 40/40 |
| The Android test suite | **Pass** — 7/7 |
| The macOS app builds for Intel and Apple Silicon | **Pass** |
| The macOS app launches and renders | **Pass** — verified by launching the built bundle |
| The `.dmg` installers build and verify | **Pass** |
| The release APK builds | **Pass** |

## What is not verified

**No physical-device test has been performed.** The build environment has no Android
phone attached, and Android's emulator cannot expose a Bluetooth Low Energy peripheral,
so the GATT link cannot be closed against an emulator either.

The outstanding hardware tests are listed precisely in
[`docs/TESTING.md`](TESTING.md#unverified-results-hardware-required). In short:
pairing, contact synchronisation, an outgoing call, an incoming call, answering,
ending, call audio, reconnection, and the man-in-the-middle check.

Because the protocol is verified from both ends and the transport is a thin layer over
it, the residual risk is concentrated in two places:

1. **The BLE transport** — MTU negotiation, the GATT server's write handling, and
   reconnection behaviour on real hardware.
2. **The Android telephony paths** — particularly the default-phone-app role, where
   `TelecomManager.acceptRingingCall` and `endCall` behave differently across
   manufacturers.

## Next steps, in order

1. **Test against a real phone.** Install the APK, pair, sync contacts, place and
   receive a call. Record the results in `docs/TESTING.md`, replacing the unverified
   rows with real outcomes.
2. **Verify the default-phone-app path** on at least one Android 12 and one Android 15
   device.
3. **Add the GATT reconnection hardening** — currently the Mac retries the scan with a
   fixed two-second delay; a backoff would be gentler on the phone's battery.
4. **Resolve the incoming-caller number on API 31–32.** The public
   `TelephonyCallback.CallStateListener` only carries the state there, so the number
   must come from the call log. The companion has the plumbing but the lookup is not
   finished.
5. **Sign and notarise the macOS build** once Developer ID credentials exist.
   `scripts/build_macos.py` already applies the entitlements and an ad-hoc signature;
   a Developer ID identity and a notarisation profile are the only missing pieces.
6. **Add instrumentation tests** once there is hardware that can act as a BLE
   peripheral (or an in-process fake at the transport boundary).

## Build and test commands

```bash
python3 scripts/build_macos.py --dmg --arch both     # the installers
python3 scripts/run_tests_macos.py                    # the macOS suite
cd android && ANDROCALL_REPO_ROOT=.. ./gradlew testDebugUnitTest assembleRelease
python3 tools/reference/generate_vectors.py --check   # the vectors are current
```

## Known limitations

- The macOS builds are ad-hoc signed, not notarised.
- Call audio is not routed to the Mac.
- Answering and ending calls need the default-phone-app role.
- The Android companion requires Android 12 (API 31) or later.
- Background reliability depends on the phone's manufacturer.
- The macOS test suite is a self-contained runner rather than XCTest, because XCTest
  ships only with Xcode.
