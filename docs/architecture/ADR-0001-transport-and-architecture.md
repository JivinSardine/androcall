# ADR-0001: Transport and architecture for androcall

- **Status:** Accepted
- **Date:** 2026-10-20
- **Deciders:** androcall engineering
- **Supersedes:** —
- **Related:** [`docs/TECHNICAL_FEASIBILITY.md`](../TECHNICAL_FEASIBILITY.md)

## Context

androcall must let a Mac browse an Android phone's contacts, place calls, see incoming
calls, and control an active call. The brief forbids iOS support, forbids private/undocumented
Apple APIs, forbids faking behaviour, and forbids substituting a cloud or Wi‑Fi primary
transport for Bluetooth.

The feasibility investigation ([`TECHNICAL_FEASIBILITY.md`](../TECHNICAL_FEASIBILITY.md))
established the binding constraints:

1. macOS exposes **no public API** for HFP call control, PBAP contact access, or MAP.
   Apple's system telephony stack implements those profiles privately.
2. `CoreBluetooth` on macOS provides the **central** role only (BLE); `IOBluetooth`
   (classic Bluetooth, incl. RFCOMM) exists but is **deprecated since macOS 10.13**.
3. Android exposes telephony through `TelecomManager` (API 23+), `TelephonyCallback`
   (API 31+), and `ConnectionService` (API 23+). **Answering / rejecting / ending a call
   requires the default-dialer role** (`ROLE_DIALER`).
4. Android's `BluetoothGattServer` (API 18+) makes the phone a viable BLE **server**;
   macOS's CoreBluetooth peripheral role is not practically usable, so the phone must be
   the server and the Mac the client.

## Decision

### 1. Two applications, with the Android companion as the mandatory intermediary

androcall ships a **Swift/SwiftUI macOS app** and a **Kotlin Android companion**. The Mac
app never talks to the phone's Bluetooth profiles directly; it talks to the companion over
an app-to-app channel that androcall owns. This is forced by constraint 1 and is exactly
the fallback the brief prescribes.

### 2. Primary transport: Bluetooth Low Energy GATT

- **Android = GATT server (peripheral)**, hosting a custom service in a foreground service.
- **macOS = GATT client (central)** using `CBCentralManager`.

Rejected alternatives:

| Option | Why rejected |
|---|---|
| HFP / PBAP / MAP | No public client API on macOS. Impossible. |
| Classic BT SPP via `IOBluetooth` | Apple-deprecated API; App Store and future-macOS risk. Higher throughput, but not worth the platform risk for a public repo. |
| L2CAP | Requires a paired Classic-BT channel; no advantage for our workload. |
| Local network / cloud | The brief forbids silently replacing Bluetooth as primary. |

An **optional** LAN transport may be added later as a documented extra, but it is not
part of this ADR and is not implemented now.

### 3. Transport-agnostic protocol layer

All message semantics live in a `Transport` abstraction:

- Swift: `protocol Transport { send(_ frame: Frame) async throws; var events: AsyncStream<Frame> }`
- Kotlin: `interface Transport { suspend fun send(frame: Frame); val frames: Flow<Frame> }`

`BleTransport` is the only implementation shipped now. This keeps the door open for the
optional LAN transport without touching the message layer or the UI.

### 4. Two-tier call control

- **Tier 1 — Observer.** Works on every supported Android version with no special role:
  incoming-call detection, caller identity, outgoing calls, live call state and duration.
- **Tier 2 — Default dialer.** With the user-consented `ROLE_DIALER` grant, the companion
  registers a `PhoneAccount` + `ConnectionService` and gains answer / reject / end / mute.

The Mac negotiates capabilities at connect time and **disables** controls the phone cannot
honour, with an explanatory label. Non-functional buttons are never shipped.

### 5. Call audio is not routed through the Mac

The phone remains the HFP handset; call audio follows the phone's own route. androcall
reports route *information* the phone legitimately supplies but does not intercept or
redirect call audio. This is documented as a product limitation rather than papered over.

### 6. Security: PIN-authenticated, ECDH-bound, AES-256-GCM

See [`protocol/PROTOCOL.md`](../../protocol/PROTOCOL.md) §6. A 6-digit PIN is the
authorisation factor; ephemeral P-256 ECDH binds the session and defeats relay/MITM
(a 4-digit verification code is shown on both screens); all post-handshake traffic is
AES-256-GCM sealed with per-direction keys and monotonic sequence numbers.

### 7. Build system: `swiftc` + hand-assembled bundle (no Xcode required)

The build must run on any macOS host with Command Line Tools, on both architectures,
including CI. Xcode project files would tie the build to Xcode; instead a Python-driven
`scripts/build_macos.py` compiles the Swift sources with `swiftc -target
{arch}-apple-macos12.0` and assembles a genuine `.app` bundle, then `hdiutil` produces the
`.dmg`. The macOS 12 deployment target is enforced by the compiler, so any accidental use
of a post-12 API is a build error.

### 8. Cross-platform protocol conformance is tested, not asserted

Because Swift and Kotlin implement the protocol independently, the repository ships
**shared conformance vectors** (`protocol/conformance/`) — canonical inputs and expected
outputs — that *both* test suites execute. A change to the protocol that updates only one
side breaks the other side's suite.

## Consequences

**Positive**

- Works entirely on public APIs; no App Store rejection risk from private telephony access.
- Honest, verifiable capability negotiation instead of dead buttons.
- Protocol correctness is enforced by two independent implementations.
- Builds on any macOS host with CLT only; universal binary without Xcode.

**Negative / accepted trade-offs**

- Contact sync over BLE is slower than SPP; contacts arrive in batches with a visible
  progress indicator and incremental sync.
- Answer/end from the Mac needs the user to make androcall the default dialer. Onboarding
  explains this; Tier 1 still delivers the core experience.
- Call audio stays on the phone. androcall is a *control* surface, not an audio device.
- OEM battery optimisation can suspend the Android foreground service; documented and
  surfaced in the troubleshooting UI.
- No macOS `XCTest`: the macOS test suite is a small self-contained runner built with
  `swiftc`, since XCTest ships only with Xcode.

## Validation

This ADR is validated by:

- `docs/TECHNICAL_FEASIBILITY.md` — every API-level claim machine-verified against the
  Android SDK's `api-versions.xml` and Apple DocC metadata (`tools/apiver.py`,
  `tools/appledoc.py`).
- `protocol/conformance/vectors.json` — executed by both the Swift and Kotlin suites.
- `docs/TESTING.md` — separates automatically verified results from results that require
  physical hardware and are therefore marked **unverified**.
