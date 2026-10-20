# Testing

This document records what androcall's tests actually cover, how to run them, and —
importantly — **which results are verified and which are still unverified because they
need physical hardware**.

Nothing in this repository claims a physical-device test that was not performed. Where
a test needs an Android phone and a Mac together, it is marked **unverified** with the
reason.

## Running the tests

```bash
# The macOS suite: protocol conformance + unit tests
python3 scripts/run_tests_macos.py

# The Android suite: protocol conformance + unit tests
cd android
ANDROCALL_REPO_ROOT="$(cd .. && pwd)" ./gradlew testDebugUnitTest

# The independent protocol reference, checked against the published NIST vectors
python3 tools/reference/androcall_ref.py

# Confirm the published conformance vectors still match the reference
python3 tools/reference/generate_vectors.py --check
```

## What the suites cover

### Protocol conformance (both platforms)

The protocol is implemented three times: Swift (the Mac), Kotlin (the phone) and Python
(an independent reference). All three are checked against the same golden vectors in
`protocol/conformance/vectors.json`:

| Vector group | What it pins down |
|---|---|
| `keySchedule` | The PIN + P-256 ECDH key schedule: the shared secret, the transcript, the HKDF outputs, the proof and the verification code |
| `framing` | The 23-byte frame header, the little-endian fields, the GCM nonce layout, and the exact ciphertext and tag of a sealed frame |
| `fragmentation` | How a message larger than one BLE write is split and reassembled |
| `canonicalJson` | The byte-exact canonical JSON of a message, in both the envelope and the body |
| `phoneNumbers` | Dialling input sanitisation |

A change to the protocol that updates only one platform **fails the other platform's
suite**. This is the main guard against the two implementations drifting apart.

### The reference implementation's own correctness

`tools/reference/androcall_ref.py` is not trusted because it agrees with itself. It is
checked against published vectors:

- **AES-128 / AES-192 / AES-256** — FIPS-197 Appendix B and C known answers.
- **AES-GCM** — the **NIST CAVP GCM test vectors** (`gcmEncryptExtIV{128,192,256}.rsp`),
  including the truncated-tag cases. 7872 of 7872 96-bit-IV vectors match exactly.
- **HKDF** — RFC 5869 appendix A test case 1.
- **PBKDF2-HMAC-SHA256** — the published test vector.
- **P-256** — a key pair generated with OpenSSL 3.x, cross-checked against
  `openssl ec -pubout`.

### macOS unit tests

40 checks covering:

- Frame encoding and decoding, including rejection of a bad magic, a truncated frame and
  an unknown version.
- Authentication: a tampered payload and a frame sealed for the wrong direction both
  fail to open.
- Reassembly: too many fragments, an oversized message, and fragments that arrive out of
  order.
- Canonical JSON: key ordering, the escape rules, the fixed envelope order, and the
  rejection of fractional numbers.
- Phone numbers: international prefixes, rejection of letters, and dial-pad filtering.
- Capability round-tripping.
- Session behaviour: a request before the session is ready, a malformed frame, and a
  transport disconnect.

### Android unit tests

7 checks: the same conformance groups, plus the guarantee that a wrong PIN produces a
different proof and a different session key.

### What is **not** covered by automated tests

- Anything involving a real Bluetooth radio, a real phone and a real call.
- The Android telephony paths that need the default-dialer role.
- The macOS notification UI (its delivery is driven by the system, not by the app).
- Rendering and layout on every macOS version and display scale.

Those need hardware, and they are listed below.

---

## Verified results

Everything in this section was executed in this repository and the output was checked.

| # | Check | Result |
|---|---|---|
| 1 | `python3 tools/reference/androcall_ref.py` | **PASS** — the AES, GCM, HKDF, PBKDF2 and P-256 known answers all match |
| 2 | NIST CAVP GCM vectors (96-bit IV, AES-128/192/256, including truncated tags) | **PASS** — 7872 / 7872 exact matches |
| 3 | `python3 tools/generate_vectors.py --check` | **PASS** — the published vectors match the reference |
| 4 | `python3 scripts/run_tests_macos.py` | **PASS** — 40 passed, 0 failed |
| 5 | `cd android && ./gradlew testDebugUnitTest` | **PASS** — 7 passed, 0 failed |
| 6 | `python3 scripts/build_macos.py --arch x86_64` | **PASS** — the app bundle builds and is ad-hoc signed with the Bluetooth entitlement |
| 7 | `python3 scripts/build_macos.py --arch arm64` | **PASS** — the Apple Silicon bundle builds |
| 8 | The built app launches | **PASS** — the macOS Bluetooth permission prompt appeared with androcall's usage description, and the app window rendered the dashboard, contacts, dial, settings and diagnostics screens |
| 9 | `cd android && ./gradlew assembleRelease` | **PASS** — a 6.4 MB release APK is produced |
| 10 | `scripts/build_macos.py --dmg` | **PASS** — a `.dmg` installer is produced for each architecture |

### Build environment used

| | |
|---|---|
| macOS | 12.7.6 (21H1320), x86_64 (Intel) |
| Swift | 5.7.2 (Xcode 14.2 Command Line Tools) |
| Deployment target | `macos12.0`, enforced by the compiler |
| JDK | Temurin 21.0.10 |
| Android SDK | platform 35, build-tools 35.0.1 |
| Gradle | 8.14.3, AGP 8.11.0, Kotlin 2.1.20 |

---

## Unverified results (hardware required)

These are the checks the brief asks for that **cannot be automated** and were **not
performed**, because no Android phone and Mac pair was available to this build
environment. They are listed so that nobody mistakes an untested claim for a tested one.

| # | Check | Status | Why |
|---|---|---|---|
| U1 | Pairing over Bluetooth with a real phone | **Unverified** | No Android phone was attached to the build machine |
| U2 | Contacts synchronise to the Mac | **Unverified** | Needs U1 |
| U3 | An outgoing call placed from the Mac reaches the phone | **Unverified** | Needs U1 and a telephony-capable phone |
| U4 | An incoming call shows a notification on the Mac | **Unverified** | Needs U1 |
| U5 | Answering from the Mac (Tier 2, default phone app) | **Unverified** | Needs U1 and a default-dialer role on a real phone |
| U6 | Ending a call from the Mac | **Unverified** | Needs U5 |
| U7 | Two-way call audio | **Unverified** | Needs U1 and a live call |
| U8 | Reconnection after the phone leaves Bluetooth range | **Unverified** | Needs U1 |
| U9 | The verification code detects a man-in-the-middle | **Unverified** | Needs a second Bluetooth device to intercept the link |
| U10 | Apple Silicon on real hardware | **Unverified** | The arm64 build compiles, but the build machine is Intel |
| U11 | macOS 12 Monterey on real hardware | **Unverified** | The build machine *is* macOS 12.7.6, so the deployment target is exercised; other macOS versions are not |
| U12 | OEM battery-optimisation exemptions (Xiaomi, Huawei, Oppo, …) | **Unverified** | Needs the specific OEM's firmware |

The emulator cannot stand in for U1–U9: Android's emulator does not expose a usable
Bluetooth Low Energy peripheral, so the GATT server cannot be connected to from a Mac.

**These are the next things to do.** The protocol is verified from both ends and the
transport is a thin layer over it, so the remaining risk is concentrated in the BLE
transport and the Android telephony paths — not in the protocol.

---

## Test case reference

### macOS

| Area | Case | Expected |
|---|---|---|
| Launch | Open the app on macOS 12 | The window appears; the Bluetooth prompt is shown once |
| Contacts | Search for a contact | Only matching contacts are listed |
| Contacts | Open a contact with several numbers | Every number is listed with its own Call button |
| Dial pad | Enter `+1 (555) 123-4567` | The dial pad keeps `+15551234567`; the sanitised form is shown below |
| Dial pad | Enter a letter | The letter is rejected; the dial button stays disabled |
| Call state | The phone reports `ringing_incoming` | The incoming-call sheet appears |
| Call state | The phone reports `active` | The active-call bar appears with a running duration |
| Notifications | An incoming call arrives while the app is in the background | A banner appears with Answer and Decline actions |
| Bluetooth | The phone goes out of range | The status becomes *Disconnected*, then *Looking for your phone…* while reconnecting |
| Permissions | The user denies Bluetooth | The diagnostics screen explains the permission and how to grant it |
| Settings | The user changes the theme | The window follows System / Light / Dark |
| Settings | The user deletes the local contact data | The contact list is emptied and nothing is left on disk |
| Protocol | A malformed frame arrives | The frame is dropped and logged; the session survives |
| Protocol | A request is never answered | It fails with `timeout` after ten seconds |
| Build | Both architectures compile | `swiftc -target x86_64-apple-macos12.0` and `-target arm64-apple-macos12.0` both succeed |

### Android

| Area | Case | Expected |
|---|---|---|
| Pairing | The user enters a PIN and starts the service | The foreground-service notification appears |
| Permissions | Each permission is denied | The screen explains what is lost and offers the request again |
| Contacts | Contacts are synchronised | The batches arrive and the Mac shows the contact list |
| Contacts | The permission is revoked | The phone answers `permission_denied` and the Mac stops syncing |
| Incoming calls | A call arrives | The phone reports `ringing_incoming` to the Mac |
| Outgoing calls | The Mac asks for a call | The phone places it and confirms with `call.place.result` |
| Call control | Answer / decline / end | They work only with the default-phone-app role; without it the phone replies `not_default_dialer` and the Mac disables the buttons |
| Background | The screen is locked | The foreground service keeps the GATT server reachable |
| Revocation | The user revokes a permission in Settings | The next request answers with `permission_denied` |
| Protocol | An invalid message arrives | The phone replies `invalid_message` and keeps the session |

## Known limitations

- The macOS test suite is a self-contained executable rather than XCTest, because XCTest
  ships only with Xcode and the project deliberately builds with the Command Line Tools.
- The Android suite is unit tests only; there is no instrumentation test, because the
  emulator cannot provide a Bluetooth Low Energy peripheral.
- The protocol reference in Python is not packaged as a library; it is a development
  tool that lives in `tools/`.
