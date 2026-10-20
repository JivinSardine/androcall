# androcall Wire Protocol — v1

**Protocol version:** `1`
**Status:** Frozen for implementation
**Conformance:** [`protocol/conformance/vectors.json`](conformance/vectors.json) is executed by **both** the Swift and Kotlin test suites. A change here that updates only one implementation fails the other side's tests.

This document is normative. `protocol/schemas/messages.schema.json` is the machine-readable
counterpart and is validated against the same conformance vectors.

---

## 1. Layering

```
┌──────────────────────────────────────────────────────────┐
│ Layer 3  Message      JSON object, UTF-8, one per logical │
│                      message (see §4)                     │
├──────────────────────────────────────────────────────────┤
│ Layer 2  Framing      binary frame header + payload      │
│                      (§3); fragmentation support          │
├──────────────────────────────────────────────────────────┤
│ Layer 1  Transport    BLE GATT write / notify             │
│                      (§2)                                 │
├──────────────────────────────────────────────────────────┤
│ Layer 0  Security     PIN + P-256 ECDH + AES-256-GCM      │
│                      (§6)                                 │
└──────────────────────────────────────────────────────────┘
```

Layers 1–3 are identical on both platforms. The implementations are independent (Swift on
macOS, Kotlin on Android) and are checked against each other only through the shared
conformance vectors.

---

## 2. Transport (Layer 1) — BLE GATT

### 2.1 Roles

| Side | Role | API |
|---|---|---|
| Mac | Central (client) | `CBCentralManager` |
| Android | Peripheral (server) | `BluetoothGattServer` in a foreground service |

### 2.2 Service

| Item | UUID (128-bit, custom) |
|---|---|
| Service | `A9D00001-1C3E-4B7A-9F21-6D2C5B8E4A10` |
| `control` characteristic (Mac → Phone) | `A9D00002-1C3E-4B7A-9F21-6D2C5B8E4A10` |
| `event` characteristic (Phone → Mac) | `A9D00003-1C3E-4B7A-9F21-6D2C5B8E4A10` |
| `bulk` characteristic (bidirectional) | `A9D00004-1C3E-4B7A-9F21-6D2C5B8E4A10` |

Properties:

| Characteristic | Properties |
|---|---|
| `control` | `write`, `writeWithoutResponse` |
| `event` | `notify` |
| `bulk` | `write`, `writeWithoutResponse`, `notify` |

**Rules**

1. Exactly **one frame per BLE write**. A frame never spans two writes.
2. Every write uses **write-with-response** for `control` and `bulk`. Write-without-response
   is reserved for `event` frames that fit in the negotiated MTU, and only when
   `canSendWriteWithoutResponse` is true.
3. A frame's total size (header + payload + tag) must not exceed the negotiated ATT MTU.
   The sender clamps its payload to `maximumWriteValueLength(for:) - headerSize - tagSize`.
   With the default 23-byte MTU that is a 0-byte payload, so **MTU negotiation to ≥ 100
   bytes is required**; the transport performs an explicit MTU request and falls back to
   23-byte MTU framing only if the peer refuses (which is a fatal handshake error, see §7.4).
4. Flow control on `bulk`: the receiver advertises a window; the sender must not have more
   than `window` unacknowledged bulk frames in flight. `window` starts at 8.

### 2.3 Characteristic semantics

* `control` carries every **request** (client → server) and every **response** (server → client
  that is not an event).
* `event` carries every unsolicited **event** (server → client): call state changes,
  device info, battery, connection quality.
* `bulk` carries **large payloads**: contact batches and recent-call lists.

A message never moves between characteristics mid-flight.

---

## 3. Framing (Layer 2)

All multi-byte integers are **little-endian**.

```
offset  size  field          notes
0       2     magic          0x41 0x43  ("AC")
2       1     version        0x01
3       1     kind           0x01 = plaintext (handshake only)
                              0x02 = encrypted
4       1     flags          bit0 MORE   (another fragment follows)
                              bit1 FIRST  (first fragment of this message)
                              bits 2-7 reserved, MUST be 0
5       4     seq            uint32, monotonically increasing per direction,
                              wraps modulo 2^32
9       8     msgId          uint64, unique per logical message per direction
17      2     fragIndex      uint16, 0-based
19      2     fragCount      uint16, total fragments for this message
21      2     length         uint16, payload byte count of THIS frame
23      N     payload        length bytes
23+N    16    tag            AES-256-GCM tag; present only when kind == 0x02
```

**Header size:** 23 bytes. **Tag size:** 16 bytes.

### 3.1 Rules

1. `length` is the payload length of *this frame*, not of the whole message.
2. A message with `fragCount == 1` has `fragIndex == 0` and the `FIRST` flag set.
3. A fragmented message sets `FIRST` on `fragIndex == 0` and `MORE` on every fragment except
   the last.
4. Fragments of one message share `msgId`, `fragCount`, and `kind`. `seq` differs per frame.
5. `seq` is strictly increasing within a direction and is used for replay detection (§6.5).
   The first frame after a session starts uses `seq = 1`.
6. Reassembly buffers are bounded: at most **64 fragments** and **1 MiB** per logical
   message. Exceeding either discards the message and raises a `protocol` error.

---

## 4. Messages (Layer 3)

Every message is a UTF-8 JSON **object** with these fields:

| Field | Type | Required | Notes |
|---|---|---|---|
| `v` | integer | yes | Protocol version, always `1` |
| `type` | string | yes | One of the types in §4.1 |
| `id` | string | yes | UUIDv4-style unique id (26 chars, base32) |
| `ts` | integer | yes | Unix epoch milliseconds, sender clock |
| `replyTo` | string \| null | yes | `id` of the message this replies to, or `null` |
| `body` | object | no | Type-specific payload; absent means `{}` |

A message whose `v` is not `1` is rejected with `session.error` / `error` and the session is
closed (protocol versions are not negotiated silently).

### 4.0 Canonical JSON

Messages are serialised to **canonical JSON** so that the Swift and Kotlin
implementations produce byte-identical bytes. All three implementations
(Swift, Kotlin, and the Python reference that generates the conformance
vectors) follow these rules exactly:

1. **Top-level field order is fixed:** `v`, `type`, `id`, `ts`, `replyTo`, `body`.
2. **Object keys inside `body` are sorted** lexicographically by their UTF-8 bytes
   (all protocol keys are ASCII, so byte order and code-point order agree).
3. **Numbers are integers only.** The protocol never carries a fractional value;
   durations are milliseconds. No exponent, no `+`, no leading zeros, no `-0`.
4. **Strings** are escaped as: `"` → `\"`, `\` → `\\`, `\b`, `\f`, `\n`, `\r`, `\t`
   for the usual control characters, any other character below U+0020 as
   `\u00XX` with **lower-case** hex digits, and every other character emitted
   literally as UTF-8. `/` is **not** escaped. The Unicode characters U+2028 and
   U+2029 are emitted literally.
5. **No insignificant whitespace.** The separator between tokens is a single `,`
   and between a key and its value a single `:`.
6. `replyTo` is `null` or a string. `body` is always present, `{}` when empty.

A conforming encoder produces exactly the same bytes as the reference
implementation for the same message. The conformance vectors pin these bytes.

### 4.1 Message types

#### Session establishment

| Type | Direction | Body |
|---|---|---|
| `session.hello` | Mac → Phone | `{ protocolVersion: 1, clientName: string, clientNonce: string(base64, 16 bytes), capabilities: string[] }` |
| `session.challenge` | Phone → Mac | `{ salt: string(base64, 16 bytes), iterations: int, serverPubKey: string(base64, X9.63 uncompressed P-256), serverNonce: string(base64, 16 bytes) }` |
| `session.response` | Mac → Phone | `{ clientPubKey: string(base64, X9.63), proof: string(base64, 32 bytes) }` |
| `session.ready` | Phone → Mac | `{ sessionId: string, verifyCode: string(4 digits), proof: string(base64, 32 bytes) }` |
| `session.error` | either | `{ code: string, message: string }` |

The handshake is symmetric: the Mac proves possession of the PIN with `session.response`
and the phone proves it with `session.ready`. Both carry the **same** `proof` value —
`HMAC-SHA256(ikm, "androcall-proof-v1" || transcript)` — because both sides compute an
identical transcript. Each side compares the received proof with its own in constant
time; a mismatch closes the session with `auth_failed`.

The Mac computes the same `verifyCode` locally and shows it. The user confirms on the Mac
that it matches the phone's. A mismatch aborts the session (§7.4).

After `session.ready` the Mac sends an encrypted `ping`; the encrypted `pong` confirms
that both directions of the encrypted channel work.

#### Capability and device information

| Type | Direction | Body |
|---|---|---|
| `device.info` | Phone → Mac | `{ deviceName, manufacturer, model, androidVersion, sdkInt, batteryLevel: int\|null, batteryCharging: bool\|null, signalStrength: int\|null, telephonyCapable: bool }` |
| `call.capabilities` | Phone → Mac | `{ canAnswer, canDecline, canEnd, canMute, canSelectAudioDevice, audioRoute: string\|null, defaultDialer: bool, reason: string\|null }` |

The union of `session.hello.capabilities` and `call.capabilities` defines what the Mac may
enable. The Mac **must not** invoke a capability the phone did not advertise.

#### Contacts

| Type | Direction | Body |
|---|---|---|
| `contacts.request` | Mac → Phone | `{ requestId, since: int\|null (epoch ms watermark), limit: int\|null, offset: int\|null }` |
| `contacts.batch` | Phone → Mac | `{ requestId, index: int, total: int, contacts: Contact[], hasMore: bool }` |
| `contacts.complete` | Phone → Mac | `{ requestId, total: int, deliveredAt: int }` |
| `contacts.error` | Phone → Mac | `{ requestId, code: string, message: string }` |
| `contact.favorite.set` | Mac → Phone | `{ contactId: string, favorite: bool }` |
| `contact.favorite.result` | Phone → Mac | `{ contactId, favorite, updated: bool, reason: string\|null }` |

`Contact` object:

```json
{
  "id": "c_8f3a...",              // stable, opaque, phone-generated
  "lookupKey": "86a1...",         // Android LOOKUP_KEY, opaque
  "displayName": "Ada Lovelace",
  "givenName": "Ada",
  "familyName": "Lovelace",
  "organization": null,
  "phoneNumbers": [
    { "label": "mobile", "number": "+15551234567", "normalized": "+15551234567", "type": "mobile" }
  ],
  "emails": [ { "label": "home", "address": "ada@example.com" } ],
  "photo": null,                  // base64 JPEG thumbnail, or null
  "photoMimeType": null,
  "starred": false,
  "sortKey": "Ada Lovelace"
}
```

Phone numbers are normalised with E.164-style rules (§5).

#### Recents (call history)

| Type | Direction | Body |
|---|---|---|
| `recents.request` | Mac → Phone | `{ requestId, limit: int\|null }` |
| `recents.batch` | Phone → Mac | `{ requestId, index, total, calls: RecentCall[] }` |
| `recents.complete` | Phone → Mac | `{ requestId, total }` |
| `recents.error` | Phone → Mac | `{ requestId, code, message }` |

`RecentCall` object: `{ id, number, displayName, type: "incoming"|"outgoing"|"missed"|"rejected"|"unknown", timestamp, durationMs: int|null }`.

Recents require `READ_CALL_LOG`. When the permission is not granted the phone replies
`recents.error` with `code = "permission_denied"` and the Mac hides the Recents view and
explains why — it never shows fabricated entries.

#### Call control

| Type | Direction | Body |
|---|---|---|
| `call.place` | Mac → Phone | `{ requestId, number: string, contactId: string\|null, displayName: string\|null }` |
| `call.place.result` | Phone → Mac | `{ requestId, callId: string\|null, accepted: bool, code: string\|null, message: string\|null }` |
| `call.cancel` | Mac → Phone | `{ requestId, callId: string\|null }` |
| `call.answer` | Mac → Phone | `{ requestId, callId: string }` |
| `call.decline` | Mac → Phone | `{ requestId, callId: string }` |
| `call.end` | Mac → Phone | `{ requestId, callId: string }` |
| `call.mute` | Mac → Phone | `{ requestId, callId: string, muted: bool }` |
| `call.result` | Phone → Mac | `{ requestId, callId: string\|null, ok: bool, code: string\|null, message: string\|null }` |
| `call.state` | Phone → Mac | `{ callId, state: CallState, number: string\|null, displayName: string\|null, startedAt: int\|null, durationMs: int\|null, capability: string\|null }` |
| `call.ended` | Phone → Mac | `{ callId, reason: string, durationMs: int\|null }` |

`CallState` enum: `dialing`, `ringing_outgoing`, `ringing_incoming`, `active`, `ending`,
`ended`, `failed`, `rejected`, `missed`, `unknown`.

`call.place` is **only** ever sent in response to an explicit user action. The phone
de-duplicates by `requestId` for **3 seconds** so a double tap cannot place two calls.

#### Diagnostics and keepalive

| Type | Direction | Body |
|---|---|---|
| `ping` | Mac → Phone | `{ nonce: int }` |
| `pong` | Phone → Mac | `{ nonce: int, ts: int }` |
| `log.request` | Mac → Phone | `{ requestId, maxLines: int }` |
| `log.batch` | Phone → Mac | `{ requestId, lines: string[] }` |
| `error` | either | `{ code: string, message: string, fatal: bool }` |

### 4.2 Error codes

| Code | Meaning |
|---|---|
| `unsupported_version` | Peer protocol version mismatch |
| `auth_failed` | PIN/handshake verification failed |
| `verify_mismatch` | Verification codes differ (possible MITM) |
| `permission_denied` | Android runtime permission not granted |
| `not_default_dialer` | Action requires the `ROLE_DIALER` role |
| `invalid_number` | Number failed validation/normalisation |
| `invalid_message` | Malformed frame or JSON |
| `too_large` | Message exceeds the size limit |
| `stale_request` | `requestId` no longer valid (e.g. call already ended) |
| `timeout` | Request timed out |
| `unsupported_capability` | The phone does not advertise the requested capability |
| `internal` | Unexpected internal error |

---

## 5. Phone-number handling

The **phone** is authoritative for normalisation; the Mac normalises only for display and
for de-duplicating user input.

1. Input is trimmed of whitespace, `-`, `(`, `)`, `.` and non-breaking spaces.
2. A leading `+` is preserved and means international format.
3. A bare `00` international prefix is rewritten to `+`.
4. Digits are kept; letters are converted to digits on a keypad map **only** when the input
   is a known vanity form and the phone accepts it — otherwise the phone rejects the number
   with `invalid_number`.
5. If the phone has a default SIM country/region, a national number is prefixed with `+<cc>`
   by the phone before dialling, using the same rule the Android dialer applies.
6. A number that fails validation is **never** dialled; the Mac shows the error.

The Mac's dial pad only permits `0-9`, `*`, `#`, `+` and a long-press `*`/`#` for `+`/`;`/
`pause`/`wait` — it never produces an arbitrary string the phone cannot interpret.

---

## 6. Security (Layer 0)

### 6.1 Threat model

| Threat | Mitigation |
|---|---|
| Unauthorised Mac issues calls | PIN is required at session establishment; no session, no calls |
| Passive eavesdropper | All post-handshake frames are AES-256-GCM encrypted |
| Active MITM | Ephemeral P-256 ECDH + proof over the full transcript + user-visible verification code |
| Replay of a captured frame | Per-direction monotonic sequence number; out-of-order/duplicate frames are dropped |
| Replay of a captured *request* | `requestId` de-duplication windows (§6.5) |
| Tampering with a captured frame | GCM authentication tag over header + payload; header is in the AAD |
| Frame injection from a rogue peripheral | The phone only accepts a session whose proof validates; the MAC initiates the handshake |

### 6.2 Key agreement

1. The Mac requests a PIN from the user (6 digits). The user types the same PIN into the
   companion app.
2. The phone sends `session.challenge` with `salt` (16 random bytes), `iterations`
   (210 000), `serverPubKey` (ephemeral P-256 public key, X9.63 uncompressed), `serverNonce`
   (16 random bytes).
3. The Mac sends `session.response` with `clientPubKey` (its ephemeral P-256 public key) and
   `proof`.
4. Both sides compute:

```
pinSecret   = PBKDF2-HMAC-SHA256(pin, salt, iterations, dkLen = 32)
shared      = ECDH-P256(ownPrivate, peerPublic)          // 32-byte x-coordinate
ikm         = HKDF-SHA256(ikm = shared || pinSecret,
                         salt = "androcall-v1" || serverNonce || clientNonce,
                         info = "androcall-session-v1", len = 32)
c2sKey      = HKDF-SHA256(ikm, salt = "", info = "androcall-c2s-v1", len = 32)
s2cKey      = HKDF-SHA256(ikm, salt = "", info = "androcall-s2c-v1", len = 32)
proof       = HMAC-SHA256(ikm, "androcall-proof-v1" || transcript, 32 bytes)
verifyCode  = decimal(HMAC-SHA256(ikm, "androcall-verify-v1")[:4]) mod 10000, zero-padded to 4
```

`transcript` is the byte-exact concatenation, in this order:

```
serverNonce (16 bytes)
clientNonce (16 bytes)
serverPubKey (65 bytes, X9.63 uncompressed: 0x04 || X(32) || Y(32))
clientPubKey (65 bytes, X9.63 uncompressed)
salt         (16 bytes)
iterations   (4 bytes, big-endian uint32)
```

`proof = HMAC-SHA256(ikm, "androcall-proof-v1" || transcript)` — the ASCII prefix
`"androcall-proof-v1"` is 18 bytes and is concatenated **without** a separator.

`verifyCode` is the first 4 bytes of `HMAC-SHA256(ikm, "androcall-verify-v1")`
(the ASCII prefix is 20 bytes) interpreted as a **big-endian uint32**, taken modulo 10000,
and rendered as a zero-padded 4-digit decimal string.

Both sides must compute these identically — the conformance vectors pin the exact byte
layout and the exact expected hex.

5. The phone verifies `proof` in constant time. On success it replies `session.ready` and
   both sides switch to encrypted frames. On failure it replies `session.error`
   (`auth_failed`) and closes the transport.
6. The Mac recomputes `verifyCode` and displays it. The user compares it with the phone's.
   A mismatch aborts the session (`verify_mismatch`).

### 6.3 Frame encryption

* Key: `c2sKey` for Mac → Phone, `s2cKey` for Phone → Mac.
* Nonce: 12 bytes = 4-byte direction constant (`0x00000001` c2s, `0x00000002` s2c)
  followed by the 8-byte big-endian `seq`.
* AAD: the 23-byte frame header, verbatim.
* Ciphertext: `payload`; the 16-byte GCM tag is appended after it.
* The `kind` byte is `0x02` for encrypted frames and MUST be `0x01` only for the four
  handshake messages (`session.hello`, `session.challenge`, `session.response`,
  `session.ready`, `session.error`).

### 6.4 Plaintext window

Only handshake messages are sent unencrypted. After `session.ready` both directions switch
to `kind = 0x02` permanently; a plaintext frame received after that is dropped and counted
as a protocol violation.

### 6.5 Replay and duplicate protection

* Frames with a `seq` lower than the highest accepted `seq` for that direction are dropped.
* `call.place` is de-duplicated by `requestId` for 3 seconds.
* `contacts.request` / `recents.request` are de-duplicated by `requestId` for 5 seconds.
* Every request has a **10 second** timeout; the Mac surfaces `timeout` in the UI.

### 6.6 Key storage

The derived session keys are held **in memory only** and are never written to disk. The
user's PIN is held in memory only as well. The Mac stores the *paired phone identity*
(device identifier, name, last-seen) and nothing sensitive; contacts are stored in the app
container's local store and can be wiped from Settings.

---

## 7. State machine

### 7.1 Session states

```
 idle ──connect──▶ discovering ──found──▶ connecting ──GATT ready──▶ handshaking
                                                                     │
                              ┌──────────────────────────────────────┘
                              ▼
                           authenticating ──proof ok──▶ ready
                                  │
                                  └──proof bad──▶ failed ──▶ idle
```

`ready` is the only state in which any message other than `ping`/`pong` is accepted.

### 7.2 Mac-side behaviour on disconnect

1. Transport reports disconnect → the Mac moves to `disconnected`, cancels in-flight
   requests (each completes with `timeout`), and shows the reconnecting state.
2. The Mac retries `discovering` with exponential backoff: 1 s, 2 s, 4 s, 8 s, capped at
   30 s, for as long as the app is running and auto-reconnect is enabled.
3. On reconnection the Mac performs a **fresh handshake** (new ephemeral keys). It never
   resumes a previous session.
4. The Mac does **not** re-issue any call-affecting message automatically. Pending
   `contacts.request` may be re-issued (it is idempotent); `call.place` is **not**.

### 7.3 Phone-side behaviour

1. The GATT server runs inside a foreground service so the phone remains reachable while
   backgrounded.
2. A new session always starts at `session.hello`. A second `session.hello` on the same
   transport closes the previous session first.
3. The phone never places a call, never re-sends a `call.place`, and never initiates a
   connection to the Mac. All call initiation originates on the Mac, and only from an
   explicit user action.

### 7.4 Error handling rules

| Condition | Behaviour |
|---|---|
| Malformed JSON in a frame | Reply `error` `invalid_message`, keep the session |
| Unknown `type` | Reply `error` `invalid_message`, keep the session |
| `v != 1` | Reply `session.error` `unsupported_version`, **close** the session |
| Fragment budget exceeded | Reply `error` `too_large`, drop the message |
| Proof mismatch | Reply `session.error` `auth_failed`, **close** the session |
| Verification codes differ | Mac closes the session, `verify_mismatch` |
| Peer stops responding | Mac times out the request after 10 s; phone-side requests have a 15 s timeout |
| BLE write fails | Retry once, then surface the error in Diagnostics |

---

## 8. Conformance vectors

`protocol/conformance/vectors.json` contains, for each vector:

* the exact **inputs** (PIN, salt, nonces, key material, messages), and
* the exact **expected outputs** (derived keys, proof, verify code, ciphertext hex, frame
  hex, and the parsed/re-serialised message).

Both test suites iterate the same file and compare byte-for-byte. The vectors were produced
by an independent reference implementation (`tools/reference/`) written from this document
only, so the file is not merely the Swift implementation asserting its own behaviour.

Regenerate and re-verify with:

```bash
python3 tools/reference/generate_vectors.py --check
```
