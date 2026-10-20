# androcall

**Use your Android phone's calls and contacts from your Mac.**

androcall is a native macOS app plus a small Android companion. The Mac can browse your
phone's contacts, place calls, see incoming calls and control a call in progress — over
Bluetooth, with no account, no server and no analytics.

- **macOS app:** Swift 5 / SwiftUI, built without Xcode, deployment target **macOS 12 Monterey**
- **Android companion:** Kotlin, **Android 12 (API 31) and later**
- **Transport:** Bluetooth Low Energy GATT, with an authenticated, encrypted session
- **Licence:** MIT

> androcall is an independent, open-source project. It is not affiliated with, endorsed by
> or sponsored by Apple, Google or any phone manufacturer.

---

## Why there is an Android app at all

macOS does not expose any public API that lets a third-party app read a paired phone's
contacts or control its calls. Apple's system implements the Bluetooth Phone Book Access,
Hands-Free and Message Access profiles privately; there is no public macOS API for a
PBAP client or for HFP call control. On top of that, macOS only lets you pair a
Bluetooth device from its own System Settings, so no app can pair for you.

So androcall ships an Android companion. The phone exposes the needed functionality over
a private channel that androcall itself defines, and the Mac talks to that channel
instead of to the system's private telephony stack. The full investigation, with links to
the vendor documentation and the API levels verified against the SDKs, is in
[`docs/TECHNICAL_FEASIBILITY.md`](docs/TECHNICAL_FEASIBILITY.md).

---

## What works, and what depends on Android's rules

| Feature | Status |
|---|---|
| Browse, search and favourite contacts | ✅ Works |
| Place an outgoing call from the Mac | ✅ Works (needs the *Make calls* permission on the phone) |
| See an incoming call on the Mac | ✅ Works (needs the *Phone state* permission) |
| Answer / decline / end a call from the Mac | ⚠️ **Requires androcall to be the phone's default phone app** |
| Mute the microphone from the Mac | ⚠️ Same requirement |
| Call audio | ❌ Stays on the phone — see below |

### Call audio

The phone remains the Bluetooth headset's counterpart: call audio follows the phone's own
route (earpiece, or a headset paired with the phone). androcall is a *control* surface,
not an audio device — it cannot capture or redirect call audio, and it does not try to.
The Active Call screen reports the audio route the phone reports.

### Answering and ending calls

Android only lets an app answer, decline and end calls when that app is the phone's
**default phone app** (the `ROLE_DIALER` role). androcall therefore works in two tiers:

- **Tier 1 — observer (default).** Incoming calls, caller identity, outgoing calls, live
  call state and duration all work on any supported phone, with no special role. The
  answer and decline buttons are **disabled with an explanation** rather than silently
  broken.
- **Tier 2 — default phone app (optional).** If you make androcall your default phone app
  on the phone, answering, declining, ending and muting become available from the Mac.
  The companion's onboarding screen offers this in one tap and explains what it changes.

### Background reliability

Android puts background apps to sleep, and some manufacturers add their own restrictions
on top. androcall runs its Bluetooth server in a foreground service with a permanent
notification, which is the most Android allows — but no app can promise reliable
background operation on every OEM's firmware. The companion's troubleshooting screen and
[`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) explain the per-manufacturer steps.

---

## Install

### macOS

1. Download the `.dmg` for your Mac from the [releases page](https://github.com/JivinSardine/androcall/releases).
2. Open it and drag **androcall** into Applications.
3. Launch it. The build is currently **ad-hoc signed**, not notarised — macOS will ask you
   to confirm the first time you open it (right-click › *Open*). See
   [`docs/SETUP.md`](docs/SETUP.md).

### Android

1. Download `androcall-Android.apk` from the [releases page](https://github.com/JivinSardine/androcall/releases).
2. Open it on the phone and allow installing from your file manager.
3. Grant the permissions, each with an explanation of why it is needed.

### Pairing

1. Pair the phone with the Mac in **System Settings › Bluetooth**.
2. Open the companion on the phone, enter a 6-digit code of your choosing, and press
   **Start androcall**.
3. In androcall on the Mac, choose **Get started**, pick your phone, and type the same
   6-digit code.
4. **Compare the verification code** shown on the Mac with the one on the phone. They
   must be identical — if they are not, stop and read
   [`docs/SECURITY.md`](docs/SECURITY.md).

---

## How it is built

androcall deliberately avoids Xcode project files so that the whole project builds on any
macOS machine that has the Command Line Tools, on both Intel and Apple Silicon, and in
CI.

```bash
# Build the macOS app (add --dmg for an installer, --arch both for a universal build)
python3 scripts/build_macos.py --dmg

# Run the macOS test suite (protocol conformance + unit tests)
python3 scripts/run_tests_macos.py

# Build and test the Android companion
cd android && ./gradlew testDebugUnitTest assembleRelease
```

The macOS deployment target is enforced by the compiler: `-target x86_64-apple-macos12.0`
means that an accidental use of an API introduced after macOS 12 is a **build error**, not
a crash on an old Mac.

### The protocol is tested across three implementations

The wire protocol is implemented three times — in Swift for the Mac, in Kotlin for the
phone, and in Python as an independent reference — and all three are checked against the
same golden vectors:

- [`protocol/PROTOCOL.md`](protocol/PROTOCOL.md) — the normative specification
- [`protocol/conformance/vectors.json`](protocol/conformance/vectors.json) — the vectors
- `tools/reference/` — the independent Python implementation and the vector generator

Both platform test suites execute the same vectors, so a protocol change that updates
only one side fails the other side's suite. The Python reference's own cryptography is
verified against the published NIST vectors (FIPS-197 for AES and the NIST CAVP GCM test
vectors).

---

## Repository layout

```
macos/          the macOS application (SwiftUI) and its protocol core
android/        the Android companion (Kotlin)
protocol/       the wire protocol specification, schemas and conformance vectors
docs/           architecture, feasibility, setup, security, testing, troubleshooting
scripts/        reproducible build, test and packaging scripts
tools/          the independent protocol reference implementation and research helpers
.github/        CI and release workflows
```

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Bugs and feature requests are welcome as
issues.

## Security

androcall holds an authenticated, encrypted session with your phone. The PIN is the
authorisation factor and the traffic is sealed with AES-256-GCM. Nothing is uploaded
anywhere. Report a security problem privately — see [`docs/SECURITY.md`](docs/SECURITY.md).

## Licence

MIT — see [`LICENSE`](LICENSE).
