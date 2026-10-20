#!/usr/bin/env python3
"""Generate (or verify) the androcall cross-platform conformance vectors.

The vectors are produced by ``androcall_ref`` — an independent pure-Python
implementation of the protocol written from ``protocol/PROTOCOL.md`` alone.
Both the Swift and the Kotlin test suites execute the same file, so a protocol
change that only updates one platform fails the other platform's suite.

Usage:
    python3 tools/reference/generate_vectors.py            # write the vectors
    python3 tools/reference/generate_vectors.py --check    # verify, do not write
"""

from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import androcall_ref as ref  # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
OUT = os.path.join(REPO, "protocol", "conformance", "vectors.json")

# Deterministic material: fixed hex strings, never random, so regenerating the
# file is byte-stable and reviewable in a diff.
PIN = "042739"
SALT = bytes.fromhex("5f1c9a2e7b3d80461ac5e2f19d37b60c")
SERVER_NONCE = bytes.fromhex("1a2b3c4d5e6f708192a3b4c5d6e7f809")
CLIENT_NONCE = bytes.fromhex("8f7e6d5c4b3a29180716253443526170")
SERVER_PRIVATE = bytes.fromhex(
    "c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721"
)
CLIENT_PRIVATE = bytes.fromhex(
    "a1b2c3d4e5f60718293a4b5c6d7e8f90123456789abcdef0123456789abcdef0"
)
ITERATIONS = ref.DEFAULT_PBKDF2_ITERATIONS


def hexs(b: bytes) -> str:
    return b.hex()


def build_vectors() -> dict:
    server_pub = ref.p256_public_from_private(SERVER_PRIVATE)
    client_pub = ref.p256_public_from_private(CLIENT_PRIVATE)
    shared = ref.p256_ecdh(CLIENT_PRIVATE, server_pub)
    assert shared == ref.p256_ecdh(SERVER_PRIVATE, client_pub)

    keys = ref.derive_session_keys(
        PIN,
        SALT,
        ITERATIONS,
        SERVER_NONCE,
        CLIENT_NONCE,
        server_pub,
        client_pub,
        shared,
    )

    # --- key schedule -----------------------------------------------------
    key_schedule = {
        "description": "PIN + P-256 ECDH session key schedule (PROTOCOL.md §6.2)",
        "pin": PIN,
        "salt": hexs(SALT),
        "iterations": ITERATIONS,
        "serverNonce": hexs(SERVER_NONCE),
        "clientNonce": hexs(CLIENT_NONCE),
        "serverPrivate": hexs(SERVER_PRIVATE),
        "clientPrivate": hexs(CLIENT_PRIVATE),
        "serverPublicKey": hexs(server_pub),
        "clientPublicKey": hexs(client_pub),
        "ecdhSharedSecret": hexs(shared),
        "transcript": hexs(
            ref.build_transcript(
                SERVER_NONCE, CLIENT_NONCE, server_pub, client_pub, SALT, ITERATIONS
            )
        ),
        "ikm": hexs(keys.ikm),
        "c2sKey": hexs(keys.c2s),
        "s2cKey": hexs(keys.s2c),
        "proof": hexs(keys.proof),
        "verifyCode": keys.verify_code,
    }

    # --- framing ----------------------------------------------------------
    plaintext_frame = ref.Frame(
        kind=ref.KIND_PLAINTEXT,
        flags=ref.FLAG_FIRST,
        seq=1,
        msg_id=0x0123456789ABCDEF,
        frag_index=0,
        frag_count=1,
        payload=b"\x01\x02\x03\x04",
    )
    framing = {
        "description": "Frame encoding and AES-256-GCM sealing (PROTOCOL.md §3, §6.3)",
        "plaintextFrameHex": hexs(plaintext_frame.encode()),
        "plaintextFrameDecoded": {
            "kind": plaintext_frame.kind,
            "flags": plaintext_frame.flags,
            "seq": plaintext_frame.seq,
            "msgId": plaintext_frame.msg_id,
            "fragIndex": plaintext_frame.frag_index,
            "fragCount": plaintext_frame.frag_count,
            "payloadHex": hexs(plaintext_frame.payload),
        },
        "nonceC2SSeq1": hexs(ref.nonce_for(ref.DIRECTION_C2S, 1)),
        "nonceS2CSeq1": hexs(ref.nonce_for(ref.DIRECTION_S2C, 1)),
        "encryptedFrameHex": hexs(
            ref.encrypt_frame(plaintext_frame, keys.c2s, ref.DIRECTION_C2S).encode()
        ),
        "encryptedFrameS2CHex": hexs(
            ref.encrypt_frame(plaintext_frame, keys.s2c, ref.DIRECTION_S2C).encode()
        ),
    }

    # --- fragmented message ----------------------------------------------
    payload = bytes(range(40))
    frames = ref.fragment_message(payload, 0xFEEDFACE, 7, 16)
    fragmentation = {
        "description": "Fragmentation of one logical message (PROTOCOL.md §3.1)",
        "messageHex": hexs(payload),
        "frames": [hexs(f.encode()) for f in frames],
        "frameCount": len(frames),
    }

    # --- canonical JSON messages -----------------------------------------
    message = ref.Message(
        type="call.place",
        id="01HZX8K9Q0M3N4P5R6S7T8V9W",
        ts=1767225600000,
        reply_to=None,
        body={
            "requestId": "01HZX8K9Q0M3N4P5R6S7T8V9W",
            "number": "+15551234567",
            "displayName": "Ada Lovelace",
            "contactId": "c_8f3a2b1c",
        },
    )
    hello = ref.Message(
        type="session.hello",
        id="01HZX8K9Q0M3N4P5R6S7T8V9X",
        ts=1767225600001,
        reply_to=None,
        body={
            "protocolVersion": 1,
            "clientName": "Test Mac",
            "clientNonce": hexs(CLIENT_NONCE),
            "capabilities": ["contacts", "call.place", "call.state"],
        },
    )
    canonical = {
        "description": "Canonical JSON serialisation (PROTOCOL.md §4.0)",
        "messages": [
            {
                "name": "call.place",
                "json": message.to_json().decode("utf-8"),
                "jsonHex": hexs(message.to_json()),
                "parsed": {
                    "v": 1,
                    "type": message.type,
                    "id": message.id,
                    "ts": message.ts,
                    "replyTo": None,
                    "body": message.body,
                },
            },
            {
                "name": "session.hello",
                "json": hello.to_json().decode("utf-8"),
                "jsonHex": hexs(hello.to_json()),
                "parsed": {
                    "v": 1,
                    "type": hello.type,
                    "id": hello.id,
                    "ts": hello.ts,
                    "replyTo": None,
                    "body": hello.body,
                },
            },
        ],
    }

    # --- phone-number normalisation --------------------------------------
    numbers = {
        "description": "Dial-pad sanitisation (PROTOCOL.md §5)",
        "cases": [
            {"input": "+1 (555) 123-4567", "expected": "+15551234567"},
            {"input": "00 44 20 7946 0958", "expected": "+442079460958"},
            {"input": " 555-123-4567 ", "expected": "5551234567"},
            {"input": "+1.555.123.4567", "expected": "+15551234567"},
            {"input": "*123#", "expected": "*123#"},
        ],
    }

    return {
        "protocolVersion": ref.PROTOCOL_VERSION,
        "generatedBy": "tools/reference/generate_vectors.py (independent Python reference)",
        "note": (
            "Executed by the Swift suite (macos/AndroCallTests) and the Kotlin suite "
            "(android/app/src/test). Regenerate with: python3 tools/reference/generate_vectors.py"
        ),
        "keySchedule": key_schedule,
        "framing": framing,
        "fragmentation": fragmentation,
        "canonicalJson": canonical,
        "phoneNumbers": numbers,
    }


def main() -> int:
    check = "--check" in sys.argv
    vectors = build_vectors()
    text = json.dumps(vectors, indent=2, sort_keys=False) + "\n"

    if check:
        if not os.path.exists(OUT):
            print(f"FAIL: {OUT} does not exist", file=sys.stderr)
            return 1
        with open(OUT, encoding="utf-8") as fh:
            current = fh.read()
        if current != text:
            print("FAIL: conformance vectors are out of date", file=sys.stderr)
            return 1
        print("conformance vectors are up to date")
        return 0

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write(text)
    print(f"wrote {OUT} ({len(text)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
