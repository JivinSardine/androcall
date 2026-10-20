# Security

androcall connects a Mac to an Android phone over Bluetooth. This document explains
what is protected, what is not, and how to report a problem.

## The threat model

androcall's job is to let a Mac see a phone's contacts and control its calls. That
makes two things worth attacking: **making a call** (an attacker could dial someone
without the user's knowledge) and **reading contacts** (an attacker could exfiltrate the
address book).

The people and systems that could plausibly do that:

| Threat | Mitigation |
|---|---|
| Another app on the phone talks to the Mac | The session is authenticated with a PIN the user enters on both devices. An app without the PIN cannot open a session. |
| A rogue Bluetooth peripheral impersonates the phone | The Mac initiates the handshake and sends an ECDH public key; the phone must return a proof derived from the PIN. A rogue peripheral without the PIN cannot produce it. |
| A rogue central impersonates the Mac | The phone sends a proof too, and both sides show a verification code the user compares. |
| Someone records the traffic | Every frame after the handshake is sealed with AES-256-GCM. The keys never touch the disk. |
| Someone replays a recorded frame | Each direction has a strictly increasing sequence number; older frames are dropped. Requests are also de-duplicated by request id. |
| Someone tampers with a frame in flight | The frame header is the GCM additional authenticated data, and the payload is authenticated. A modified frame fails to open. |
| A compromised process on the phone reads the contacts | The contacts are only exposed to an authenticated session. The companion app requests `READ_CONTACTS` and no more. |
| Data ends up on a server | There is no server. androcall makes no network connections at all. |

## The protocol

See [`protocol/PROTOCOL.md`](../protocol/PROTOCOL.md) for the normative description. In
short:

1. The user types a 6-digit PIN into the companion app and the same PIN into the Mac.
2. The phone sends a random 16-byte salt, a random 16-byte nonce and an ephemeral P-256
   public key.
3. The Mac sends its own ephemeral P-256 public key and a proof:
   `HMAC-SHA256(ikm, "androcall-proof-v1" || transcript)`.
4. `ikm` is derived from **both** the PIN (through PBKDF2-HMAC-SHA256 with 210 000
   iterations) **and** the ECDH shared secret (through HKDF-SHA256).
5. The phone returns the same proof, so both sides are authenticated.
6. Both sides display a 4-digit verification code derived from the session keys. **The
   user must confirm that the codes match.**
7. From then on, every frame is sealed with AES-256-GCM using a separate key per
   direction and a 12-byte nonce built from the direction and the frame sequence.

### Why the verification code exists

The PIN stops an attacker who does not know it. The ECDH exchange stops an attacker who
cannot act as one of the two ends. The verification code stops the remaining case: an
attacker who *relays* the handshake between the real phone and the real Mac.

A relaying attacker sees the same session key on both sides, so both devices compute the
same verification code and nothing looks wrong — unless the two ends are given a code
that only they can derive. Asking the user to compare the codes on the phone and the
Mac closes that gap: a relaying attacker cannot make the two codes agree while also
letting the user read both.

**If the codes differ, stop.** The pairing is being intercepted.

### What is deliberately not done

- No analytics, telemetry, crash reporting or usage measurement of any kind.
- No network traffic at all. The app has no HTTP client and no cloud dependency.
- No private or undocumented Apple or Android APIs.
- No accessibility-service abuse, no `TelecomManager` back doors, no attempt to make
  the phone place calls that the user did not ask for.
- The PIN, the derived keys and the ECDH private keys exist **in memory only** and are
  never written to disk, logged, or included in a diagnostic export.

## Data handling

| Data | Where it lives | Who can read it |
|---|---|---|
| Contacts | The phone's own contact provider, and a cached copy in the Mac's app container | The Mac, once the user has paired and allowed it. The user can delete the cached copy in Settings › Privacy. |
| Call history | Read from the phone only when the user asks for it, and only if the *Call log* permission was granted | The Mac, during a paired session. |
| Session keys | Memory of the two processes | The two processes. |
| The pairing PIN | Memory of the two processes | The two processes. |
| Diagnostic logs | Connection lifecycle events only — never contact names, numbers, call content or keys | The user, who can export or clear them. |

androcall does not collect analytics and does not transmit contacts, call logs, phone
numbers, recordings or any personal information. The only data that ever leaves either
device is the encrypted session between them.

## Permissions and why they are needed

The companion asks for the narrowest set of permissions that lets it work:

| Permission | Why |
|---|---|
| `BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN` | Run the Bluetooth service the Mac connects to. |
| `READ_CONTACTS` | Share the contacts the Mac displays. |
| `READ_PHONE_STATE` | Notice that a call is ringing and report its state. |
| `CALL_PHONE` | Place a call when the user asks for one. |
| `FOREGROUND_SERVICE`, `POST_NOTIFICATIONS` | Keep the Bluetooth service alive in the background so incoming calls still arrive. |
| `READ_CALL_LOG` | Show recent calls, when the user asks for them and grants it. |

The app does not request location, camera, microphone, storage or the contact-permission
group beyond `READ_CONTACTS`. `BLUETOOTH_SCAN` is declared with `neverForLocation`,
because androcall never derives your position from Bluetooth.

## Reporting a vulnerability

Please **do not** open a public issue for a security problem. Report it privately:

- Use GitHub's **"Report a vulnerability"** button on the Security tab of the
  repository (Security › Advisories › Report a vulnerability), or
- email the maintainer.

Please include what you found, how to reproduce it, and the versions affected. You can
expect an acknowledgement within a week. Fixes are released as a new version and
credited in the release notes unless you prefer otherwise.

## Verifying the implementation yourself

The cryptography is not hidden behind a dependency, so you can check it:

- The independent Python reference implementation in `tools/reference/` is verified
  against the **NIST CAVP GCM test vectors** and the **FIPS-197** AES vectors.
- The protocol's key schedule, framing and canonical JSON are pinned by
  `protocol/conformance/vectors.json`, which **three** independent implementations
  (Swift, Kotlin, Python) must all agree with.
- `python3 tools/reference/generate_vectors.py --check` proves the published vectors
  still match the reference implementation.

No private Apple API, no undocumented Android API and no network call is used anywhere
in the codebase.
