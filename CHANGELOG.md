# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing yet.

## [0.1.0] — 2026-10-20

The first release. A working Android-to-Mac calling experience, with the parts that
need physical hardware still to be confirmed on real devices.

### Added

**macOS application (Swift 5 / SwiftUI)**

- Dashboard showing the connected phone, its Android version, battery level and audio
  route, with shortcuts to Contacts and Dial.
- Contacts browser with search, favourites, multiple numbers per contact, profile
  photos, and a detail screen with per-number call actions.
- Numeric dial pad with international prefix handling and number sanitisation.
- Incoming-call sheet and active-call bar with caller identity, live duration, mute
  and end-call controls, and keyboard shortcuts.
- Settings for the paired device, automatic reconnection, contact synchronisation,
  notifications, launch at login, appearance (System / Light / Dark), audio devices,
  diagnostics and log export, and deleting the local contact data.
- Diagnostics screen with the live connection state, the phone's reported capabilities,
  troubleshooting guidance and an exportable log.
- Native macOS notifications for incoming calls, with Answer and Decline actions.

**Android companion (Kotlin)**

- Bluetooth Low Energy GATT server, hosted in a foreground service so that it stays
  reachable while the app is in the background.
- Contact synchronisation through `ContactsContract`, sent in batches with progress.
- Incoming-call detection through `TelephonyCallback` (API 31+) with the call state
  and the caller number where the platform provides it.
- Outgoing calls through `TelecomManager.placeCall`, with a fallback to the system
  dialer when the *Make calls* permission is not granted.
- Call control (answer, decline, end, mute) when the companion is the phone's default
  phone app, with a clear explanation when it is not.
- An onboarding screen that requests each permission with its reason, and offers to
  become the default phone app.

**Protocol**

- A versioned, documented wire protocol (`protocol/PROTOCOL.md`) with explicit
  message types, capability negotiation, framing with fragmentation, and replay
  protection.
- A PIN-authenticated session: PBKDF2-HMAC-SHA256 over a 6-digit PIN combined with
  an ephemeral P-256 ECDH exchange, proven with an HMAC over the full handshake
  transcript, and confirmed visually with a 4-digit verification code on both screens.
- All post-handshake traffic sealed with AES-256-GCM using a separate key per
  direction and a sequence-number-derived nonce.
- Canonical JSON with a fixed envelope order and sorted body keys, so the two
  implementations produce byte-identical messages.

**Engineering**

- The protocol is implemented three times — Swift, Kotlin and an independent Python
  reference — and all three are pinned by shared conformance vectors. A protocol
  change that updates only one platform fails the other platform's test suite.
- The Python reference's cryptography is verified against the FIPS-197 AES vectors
  and the NIST CAVP GCM test vectors (7872 of 7872 exact matches).
- A build that needs no Xcode: `swiftc` compiles the app and `scripts/build_macos.py`
  assembles the bundle, the icon and the `.dmg`. The macOS 12 deployment target is
  enforced by the compiler.
- GitHub Actions for continuous integration and for building the release artefacts.
- 40 macOS tests and 7 Android tests, all passing.

### Known limitations

- **Call audio stays on the phone.** androcall is a control surface; it does not
  capture or redirect call audio.
- **Answering, declining, ending and muting need the default-phone-app role.**
  Everything else works without it, and the Mac disables those controls rather than
  presenting buttons that do nothing.
- **The builds are ad-hoc signed, not notarised.** macOS asks you to confirm the first
  time you open them.
- **Background reliability depends on the phone's manufacturer.** androcall uses a
  foreground service, which is the most Android allows, but some OEM firmware still
  suspends it. The troubleshooting documentation lists the per-manufacturer steps.
- **No physical-device test has been performed yet.** The protocol is verified from
  both ends, but the Bluetooth transport and the Android telephony paths have not been
  exercised against a real phone. See the unverified table in `docs/TESTING.md`.
- The Android companion requires **Android 12 (API 31) or later**, because Android 12
  introduced both the modern Bluetooth permission model and the current GATT server
  callback API.

[Unreleased]: https://github.com/JivinSardine/androcall/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/JivinSardine/androcall/releases/tag/v0.1.0
