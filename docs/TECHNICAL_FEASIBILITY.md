# Technical Feasibility Investigation

**Project:** androcall — Android Bluetooth calling & contacts for macOS
**Status:** Complete (Phase 1 gate)
**Investigated against:** macOS 12.7.6 (21H1320, x86_64), Android SDK platform 36 (android.jar + `data/api-versions.xml`)
**Method:** Official vendor documentation only — Apple DocC (`developer.apple.com/tutorials/data/documentation/…`) for Apple symbols, and the Android SDK's own `platforms/android-36/data/api-versions.xml` manifest for Android API levels. Every API-level claim below is machine-verified against that manifest, not recalled.

---

## 0. Executive summary

| # | Question | Verdict |
|---|---|---|
| 1 | macOS Bluetooth discovery / pairing | **Partially available.** `IOBluetooth` (classic, deprecated) for generic device discovery; `CoreBluetooth` (BLE) for scanning/connecting. Pairing itself must be done in macOS System Settings. |
| 2 | HFP control from a third-party macOS app | **Not available.** No public macOS API exposes HFP AT commands or the system's HFP state machine. |
| 3 | PBAP (phone book) from a third-party macOS app | **Not available.** Apple ships a PBAP client internally; there is no public API. |
| 4 | MAP (message access) | **Not available / not useful.** No public macOS client API; no message-bearing payloads in this product's scope. |
| 5 | Android HFP/HF roles | Android is the HFP **Handset (HF)**. It can be controlled by a headset; but for *our* purposes the phone is the telephony endpoint and our Mac is not a headset. |
| 6 | Android contacts access | **Available.** `ContactsContract` (API 5) + `READ_CONTACTS` runtime permission. |
| 7 | Android incoming-call detection | **Available.** `TelephonyCallback.CallStateListener` (API 31) / `PhoneStateListener` (API 1, deprecated). |
| 8 | Android outgoing call | **Available.** `TelecomManager.placeCall` (API 23) or `Intent.ACTION_CALL`. |
| 9 | Android call control (answer / reject / end) | **Available only as default dialer.** `TelecomManager.acceptRingingCall` (API 26), `endCall` (API 28), `ConnectionService` (API 23) all require the `ROLE_DIALER` / default-dialer grant. |
| 10 | macOS 12 API floor | **Achievable.** All required Apple APIs are macOS ≤ 12.0; enforced by `-target x86_64-apple-macos12.0` / `arm64-apple-macos12.0`. |
| 11 | Intel + Apple Silicon | **Achievable** — fat/universal Mach-O via `lipo`. |
| 12 | Background execution | **Constrained on Android.** Foreground service is mandatory for the GATT server; OEM battery optimisation can still break reliability, and must be documented honestly. |

### The decisive finding

Items 2, 3 and 4 mean **no macOS-only implementation is possible**. macOS exposes no public API for HFP call control, no PBAP client, and no call-state events from a paired phone. Apple's own frameworks handle telephony internally and give third-party apps no visibility.

Therefore, per the architectural rule in the project brief, androcall **must** ship an Android companion app and communicate over a private, authenticated channel. The channel we can build with public APIs on both ends is **Bluetooth Low Energy GATT**, with the **Android phone acting as GATT server (peripheral)** and the **Mac as GATT client (central)**.

---

## 1. macOS Bluetooth pairing and device discovery

### Available mechanisms

| API | Availability | Role | Usable here |
|---|---|---|---|
| `CBCentralManager` | macOS **10.7**+ | Central (scan/connect to BLE peripherals) | **Yes — primary** |
| `CBPeripheral` | macOS **10.7**+ | Remote peripheral handle | Yes |
| `CBCharacteristic` | macOS **10.7**+ | GATT characteristic | Yes |
| `IOBluetoothDevice` | macOS (present, **deprecated since 10.13**) | Classic BT device (BR/EDR) | Legacy fallback only |
| `CBPeripheralManager` | macOS **10.9**+ | GATT server (peripheral role) | **No — macOS does not implement the peripheral role in practice** |

> Source: Apple DocC symbol metadata, `corebluetooth/cbcentralmanager`, `corebluetooth/cbperipheral`, `corebluetooth/cbcharacteristic`, `iobluetooth/iobluetoothdevice`, `corebluetooth/cbperipheralmanager`.

`CBCentralManager` exposes exactly the operations androcall needs: `scanForPeripherals(withServices:options:)`, `connect(_:options:)`, `retrieveConnectedPeripherals(withServices:)`, `retrievePeripherals(withIdentifiers:)`, `cancelPeripheralConnection(_:)`, plus `registerForConnectionEvents(options:)` (macOS 11.0+) for automatic reconnection to a known peripheral.

### Pairing

macOS has **no public API to programmatically create or complete an OS-level Bluetooth pairing** for BLE peripherals. CoreBluetooth surfaces the pairing UX only in the sense that a successful connection implies the system-level bond exists.

**Implementation consequence:** androcall instructs the user to pair the phone in **System Settings → Bluetooth** (and the Android side via the companion app's own pairing sheet), then discovers the already-paired phone by scanning for our service UUID. This matches the brief's requirement to *"provide clear instructions for pairing through macOS Bluetooth settings when operating-system restrictions require it."*

### Permissions

* `NSBluetoothAlwaysUsageDescription` in `Info.plist` — required at runtime.
* `com.apple.security.device.bluetooth` entitlement — *"A Boolean value indicating whether your app may interact with Bluetooth devices."*, **macOS 10.7**+.
  (Source: `bundleresources/entitlements/com.apple.security.device.bluetooth`.)
* `CBManager.authorization` (macOS 10.13+) reports whether Bluetooth access was granted, so the app can show precise, actionable guidance instead of failing silently.

**Conclusion:** Feasible with public API, with OS-settings pairing. BLE GATT is the transport.

---

## 2 & 3. HFP and PBAP on macOS — why the companion app is mandatory

macOS ships `HandsFree`/`PhoneBook` profile *client* implementations inside the system (used for Continuity and iPhone hand-off), but:

* There is **no public macOS API** to send HFP AT commands (`+ATA`, `+CHUP`, `+CLCC`) or to read the system's HFP call state.
* There is **no public macOS API** to act as a **PBAP client** and pull the phone's contacts over Bluetooth Object Push.
* `IOBluetoothDevice` exposes only *service record* discovery (`getServiceRecord(for:)`) and RFCOMM/L2CAP channel opening — it does **not** implement the Phone Book Access profile's OBEX object push.

Both profiles are implemented in Apple's private telephony stack, which the project brief explicitly forbids relying on (*"Do not use private APIs, undocumented framework hacks, or assumptions about Apple's internal telephony integration."*).

**Conclusion:** The Mac must obtain contacts and call control *through* the phone, over an app-to-app channel it owns. This is the single most important feasibility result and it dictates the entire architecture.

---

## 4. MAP (Message Access Profile)

No public macOS client API exists for MAP either. MAP also carries SMS/MMS, which is outside androcall's scope (the brief requires contacts and calls only), and processing SMS on a Mac would widen the privacy surface for no product benefit.

**Conclusion:** Out of scope. Not implemented, and documented as such.

---

## 5. Android HFP/HF roles

Android's Bluetooth stack implements the **Handset (HF)** role of HFP. The consequences for androcall:

* The phone is the HFP handset; the phone's *own* telephony engine owns the call. androcall's Mac is **not** an HFP headset and does not try to be.
* androcall therefore does **not** rely on HFP for call control at all. Call control is done in-process on Android through `TelecomManager`/`ConnectionService`, and the *result* is relayed to the Mac over BLE.
* Call **audio** therefore continues to flow phone ⇄ phone-earpiece or phone ⇄ a separately paired Bluetooth headset, exactly as the phone normally behaves. androcall does not attempt to intercept or route call audio on the Mac. This is an honest, documented limitation (see §9).

---

## 6. Android contacts access

| API | Level | Notes |
|---|---|---|
| `android.provider.ContactsContract` | **5** | Contact provider |
| `ContactsContract.CommonDataKinds.Phone` | **5** | Phone-number rows |
| `ContactsContract.Contacts` / `Data` | **5** | Contacts + raw rows |
| `READ_CONTACTS` | runtime | Dangerous permission; must be requested with rationale |

*(levels machine-verified in `platforms/android-36/data/api-versions.xml`)*

Contacts are read with a `ContentResolver` projection query. Profile photos are read as `Photo`/`DISPLAY_PHOTO` rows (API 5+ `Photo.CONTENT_DIRECTORY_NAME`, `Photo.PHOTO` blob) and are transferred as thumbnails.

---

## 7. Android incoming-call detection

| API | Level | Verdict |
|---|---|---|
| `android.telephony.TelephonyCallback` | **31** | **Primary path** |
| `TelephonyCallback.CallStateListener` | **31** | `onCallStateChanged(int state, PhoneNumber)` — gives the number on API 31+ |
| `android.telephony.PhoneStateListener` | **1** (deprecated) | **Fallback for API < 31** |
| `PhoneStateListener.onCallStateChanged(int, String)` | deprecated | Legacy path, no `since` in the API manifest ⇒ deprecated |

Both paths require `READ_PHONE_STATE` (runtime, API 23+ granularity). On API 31+, `TelephonyCallback.CallStateListener` also delivers the incoming `PhoneNumber`, which is what lets the Mac show *"caller name and number"*.

The protected `android.intent.action.PHONE_STATE` broadcast is **not** available to ordinary apps on modern Android, so the app does not rely on it.

---

## 8. Android outgoing call

| API | Level | Requirements |
|---|---|---|
| `android.telecom.TelecomManager.placeCall(Uri, Bundle)` | **23** | `CALL_PHONE` permission. Does **not** require default-dialer. |
| `Intent.ACTION_CALL` with `tel:` URI | 1 | `CALL_PHONE` permission. |
| `Intent.ACTION_DIAL` | 1 | No permission, but only opens the dialer — user must press call. Used as a permission-free fallback. |

`TelecomManager.placeCall` is the primary path: it places the call without the user touching the phone, which is the entire point of the product.

---

## 9. Android call control — answer / reject / end

| API | Level | Requires default dialer? |
|---|---|---|
| `TelecomManager.acceptRingingCall(int)` | **26** | **Yes** |
| `TelecomManager.endCall()` | **28** | **Yes** |
| `TelecomManager.addNewIncomingCall(PhoneAccountHandle, Bundle)` | **23** | Yes (self-managed accounts still need the role) |
| `android.telecom.ConnectionService` | **23** | Yes (`ROLE_DIALER`) |
| `android.app.role.RoleManager` | **29** | Role request API |
| `ConnectionService.onCreateIncomingConnection` / `onCreateOutgoingConnection` | **23** | Yes |

*(levels machine-verified; `TelecomManager` lives in `android.telecom`, **not** `android.telephony`)*

**This is the single hardest constraint in the product.** Answering, rejecting and ending a call from the Mac is only possible if the companion app holds the **default-dialer role** (`ROLE_DIALER`). The brief anticipates exactly this and requires it to be *evaluated explicitly and explained during onboarding*.

### Adopted two-tier design

**Tier 1 — Observer (no special role).** Always available. The companion detects incoming calls via §7, relays them to the Mac, places outgoing calls via §8, and reports call state. The Mac shows a full incoming-call screen and active-call screen with duration and caller identity. Answer/decline buttons are **present but explicitly disabled with an explanation** rather than silently non-functional.

**Tier 2 — Default dialer (`ROLE_DIALER`, user-consented in onboarding).** The companion registers a `PhoneAccount` + `ConnectionService`, so it can accept, reject, and end calls (`acceptRingingCall`, `endCall`, `Connection` lifecycle) and the Mac's buttons become live.

Both tiers are implemented; the Mac asks the phone for its capability set at connect time and only enables controls the phone actually supports — satisfying *"Clearly communicate unsupported features instead of presenting nonfunctional buttons."*

### Call audio

Because the phone remains the HFP handset, **call audio is not routed through androcall**. The call's audio path is the phone's own. androcall cannot capture call audio on the Mac without unsupported/illegal interception, and it does not attempt to. The Active Call screen reports audio route *information* the phone can legitimately supply (e.g. whether a Bluetooth headset is active on the phone) rather than claiming to route it. Mute is exposed in Tier 2 only, where `Connection`/`ConnectionService` can legitimately set the phone-side mute state.

---

## 10. macOS 12 API floor

Every Apple API androcall uses is at or below macOS 12.0:

| API | Introduced | ≤ 12.0 |
|---|---|---|
| `CBCentralManager`, `CBPeripheral`, `CBCharacteristic` | 10.7 | ✅ |
| `CBManager.authorization` | 10.13 | ✅ |
| `CBManager.state` | 10.13 | ✅ |
| `CBPeripheral.readRSSI()` | 10.7 | ✅ |
| `CBPeripheral.maximumWriteValueLength(for:)` | 10.7 | ✅ |
| `registerForConnectionEvents(options:)` | 11.0 | ✅ |
| `UserNotifications` (`UNUserNotificationCenter`, actionable categories) | 10.14 | ✅ |
| `SwiftUI` lifecycle (`App`, `Scene`, `Settings`) | 11.0 | ✅ |
| `CryptoKit` (`P256.KeyAgreement`, `AES.GCM`, `HKDF`) | 10.15 | ✅ |
| `ServiceManagement` (`SMAppService` launch at login) | 13.0 | ❌ → **use the `SMAppService` API when available, and `SMLoginItemSetEnabled` (10.11+) as the macOS 12 path** |
| `UserNotifications` notification *actions* | 10.14 | ✅ |

`SMAppService` is macOS 13+. For a macOS 12 floor, launch-at-login is implemented with `SMLoginItemSetEnabled` (deprecated but available from macOS 10.11) guarded by `#available(macOS 13.0, *)` so the app prefers the modern API on newer systems and still works on Monterey.

The build compiles with `-target x86_64-apple-macos12.0` and `-target arm64-apple-macos12.0`, which makes any accidental use of a post-12 API a **compile error** rather than a runtime crash. That is the enforcement mechanism for this requirement.

---

## 11. Intel and Apple Silicon

Both slices build from the same sources with `swiftc` against the macOS SDK; `lipo` merges them into a universal binary. Verified toolchain on the build host:

* Swift 5.7.2 (Xcode 14.2 / Command Line Tools), `x86_64-apple-macos21.6.0`
* Deployment target enforced at compile time (see §10)

The build script produces separate `x86_64` and `arm64` binaries plus a universal `lipo` merge, and the release pipeline ships Intel, Apple Silicon, and Universal DMGs.

---

## 12. Background execution and battery optimisation

**macOS side.** `UserNotifications` delivers incoming-call notifications while the app is backgrounded or minimised. The app runs as a normal (non-sandboxed-first-party) AppKit/SwiftUI application with a menu-bar presence; `NSApp` continues running when windows are closed, so BLE reconnection and event delivery continue. macOS may still terminate apps under memory pressure — the app treats every disconnect as recoverable and re-scans on launch.

**Android side.** This is where the real constraint is:

* Android 8.0+ **doze** and **App Standby** can suspend the app and drop the BLE link.
* Android 12+ requires a **foreground service** with a visible notification for the GATT server to remain reliably reachable. androcall runs the GATT server inside a `foregroundServiceType="connectedDevice"` service, with a persistent notification showing connection state.
* Android 13+ requires `POST_NOTIFICATIONS` runtime permission for the foreground-service notification to be visible.
* **OEM battery optimisation** (Xiaomi/MIUI, Huawei, Oppo, Vivo, Samsung, OnePlus) can still kill the service. The companion's troubleshooting screen detects the app in a restricted battery state and walks the user through the OEM-specific settings path.
* The brief forbids claiming guaranteed background operation. androcall states the limitation plainly in the UI and in `docs/TROUBLESHOOTING.md`.

---

## 13. Transport evaluation

| Candidate | Public API both ends? | Throughput | Security model | Verdict |
|---|---|---|---|---|
| **BLE GATT** | ✅ CoreBluetooth / BluetoothGattServer | 10–60 KB/s (MTU 517, write-with-response) | OS pairing + app-layer AES-256-GCM | **Adopted** |
| Classic BT SPP (RFCOMM) | ⚠️ `IOBluetooth` is deprecated; Android `BluetoothSocket` is public | ~100 KB/s+ | OS pairing + app layer | Rejected — deprecated Apple API, App Store risk |
| L2CAP | ✅ `CBPeripheral.openL2CAPChannel` | high | OS pairing | Rejected — not usable without a paired Classic-BT channel; adds complexity for no gain |
| HFP / PBAP | ❌ no public client API | n/a | n/a | Rejected — impossible |
| Local network (Wi-Fi) | ✅ | high | TLS | **Rejected as primary**; the brief forbids silently substituting Wi-Fi for Bluetooth. Could be an *optional* extra transport later. |

BLE GATT is adopted. The protocol layer is written **transport-agnostically** (a `Transport` protocol with a `BleTransport` implementation) so that an optional LAN transport can be added later without touching the message layer.

### BLE design decisions

* **Role:** Android = GATT **server** (peripheral); Mac = GATT **client** (central). macOS's CoreBluetooth peripheral role is not practically usable, and the phone is already the more capable BLE host with a foreground service.
* **Service:** one custom 128-bit service UUID `A9D0…` with three characteristics:
  * `control` — Mac → Phone, write (commands).
  * `event` — Phone → Mac, notify/indicate (call events, state changes).
  * `bulk` — bidirectional, write-with-response + notify, used for chunked contact payloads with an explicit flow-control window.
* **Flow control:** the sender advertises a window of outstanding chunks; the receiver ACKs. This prevents the well-known Android GATT server queue overflow that silently drops writes.
* **MTU:** negotiated; payload chunking clamps to `maximumWriteValueLength(for:)` minus overhead, so the same code works with the 20-byte default MTU and the 517-byte negotiated MTU.

---

## 14. Security design

* **Authentication:** the Mac displays a 6-digit PIN; the user enters the same PIN in the companion app. Both sides derive a key with **PBKDF2-HMAC-SHA256** (210 000 iterations, per-device random 16-byte salt) over the PIN. A wrong PIN produces a different key, so the session fails to authenticate — the PIN is the authorisation factor, and nothing else may trigger a call.
* **Transport security:** all protocol messages after the handshake are sealed with **AES-256-GCM** using a key derived from the PIN-derived secret via **HKDF-SHA256**, with a monotonic sequence number per frame for replay protection and a per-frame nonce.
* **Transport binding:** the ECDH handshake is layered on top: the Mac and phone each contribute an ephemeral **P-256** public key (CryptoKit on macOS, `javax.crypto` EC on Android), the shared secret is mixed with the PIN-derived secret, and both peers confirm the session with an HMAC over a transcript. A man-in-the-middle who does not know the PIN cannot derive the session key, and a wrong PIN fails the confirmation.
* **Least privilege:** the Mac requires no contacts/telephony permissions of its own — everything is mediated by the phone. No analytics, no telemetry, no third-party servers. Contact payloads are stored only in the Mac's local app container.
* **No call without intent:** the protocol has no message that can place a call as a side effect of connecting, re-syncing, or reconnecting. `placeCall` requires an explicit, user-initiated request carrying a `requestId` that the phone de-duplicates within a 3-second window, which prevents double-tap double-dial.

---

## 15. Acceptance-criteria impact

The brief's §13 "definition of done" is achievable **except** for the parts that depend on physical hardware and vendor-specific Android behaviour. androcall therefore ships:

1. A **Tier 1 (observer)** experience that works on every supported Android version with no special role.
2. A **Tier 2 (default dialer)** experience that enables answer/reject/end, with the requirement explained during onboarding.
3. Honest documentation of **call audio** (not routed through the Mac) and **OEM background restrictions**.
4. A `docs/TESTING.md` that separates **automatically verified** results from **unverified (no hardware)** results. No physical-device result will be fabricated.

---

## Appendix A — Evidence index

| Claim | Source |
|---|---|
| `CBCentralManager` macOS 10.7 | Apple DocC `corebluetooth/cbcentralmanager` |
| `CBPeripheral` macOS 10.7, `readRSSI`, `maximumWriteValueLength` | Apple DocC `corebluetooth/cbperipheral` |
| `CBManager.authorization` macOS 10.13 | Apple DocC `corebluetooth/cbmanager` |
| `CBPeripheralManager` macOS 10.9 | Apple DocC `corebluetooth/cbperipheralmanager` |
| `IOBluetoothDevice` present, RFCOMM channel opening | Apple DocC `iobluetooth/iobluetoothdevice` |
| `com.apple.security.device.bluetooth` macOS 10.7 | Apple DocC `bundleresources/entitlements/com.apple.security.device.bluetooth` |
| Android API levels for telephony/BLE/contacts | `~/Library/Android/sdk/platforms/android-36/data/api-versions.xml` (SDK-shipped, authoritative) |
| `TelecomManager` package is `android.telecom` | same manifest (`android/telecom/TelecomManager` since 21) |

### Reproducing the verification

```bash
python3 tools/apiver.py android.telecom.TelecomManager
python3 tools/apiver.py android.telephony.TelephonyCallback
python3 tools/appledoc.py corebluetooth/cbcentralmanager
```

(`tools/apiver.py` and `tools/appledoc.py` are checked in under `tools/` so any reviewer can re-run the verification.)
