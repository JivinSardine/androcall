"""Pure-Python reference implementation of the androcall v1 protocol core.

This module is deliberately dependency-free (standard library only) so that the
conformance vectors in ``protocol/conformance/vectors.json`` can be regenerated
on any machine, in CI, without installing anything.

It is an *independent* implementation: it was written from ``protocol/PROTOCOL.md``
alone, so the Swift and Kotlin implementations can be checked against it rather
than against each other.

Contents
--------
* SHA-256 / HMAC / PBKDF2 / HKDF
* AES-256-GCM (encrypt-only; decrypt is implemented for round-trip vectors)
* NIST P-256 ECDH
* androcall frame encoding/decoding
* androcall message model
* androcall session key schedule (PIN + ECDH + transcript proof)
"""

from __future__ import annotations

import hashlib
import hmac
import os
import struct
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Tuple

PROTOCOL_VERSION = 1
FRAME_VERSION = 1
KIND_PLAINTEXT = 0x01
KIND_ENCRYPTED = 0x02
FLAG_MORE = 0x01
FLAG_FIRST = 0x02
HEADER_SIZE = 23
TAG_SIZE = 16
MAGIC = b"AC"

PROOF_PREFIX = b"androcall-proof-v1"
VERIFY_PREFIX = b"androcall-verify-v1"
SESSION_SALT_PREFIX = b"androcall-v1"
SESSION_INFO = b"androcall-session-v1"
C2S_INFO = b"androcall-c2s-v1"
S2C_INFO = b"androcall-s2c-v1"

DEFAULT_PBKDF2_ITERATIONS = 210_000

# ---------------------------------------------------------------------------
# Hashing helpers
# ---------------------------------------------------------------------------


def sha256(data: bytes) -> bytes:
    return hashlib.sha256(data).digest()


def hmac_sha256(key: bytes, data: bytes) -> bytes:
    return hmac.new(key, data, hashlib.sha256).digest()


def pbkdf2_sha256(password: bytes, salt: bytes, iterations: int, dklen: int = 32) -> bytes:
    """PBKDF2-HMAC-SHA256 (RFC 8018)."""
    return hashlib.pbkdf2_hmac("sha256", password, salt, iterations, dklen)


def hkdf_sha256(ikm: bytes, salt: bytes, info: bytes, length: int) -> bytes:
    """HKDF-SHA256 (RFC 5869).

    When no salt is supplied, RFC 5869 §2.2 says to use a string of HashLen
    zero bytes as the salt; the extract step is still an HMAC over the IKM.
    """
    effective_salt = salt if salt else b"\x00" * 32
    prk = hmac_sha256(effective_salt, ikm)
    okm = b""
    block = b""
    counter = 1
    while len(okm) < length:
        block = hmac_sha256(prk, block + info + bytes([counter]))
        okm += block
        counter += 1
    return okm[:length]


# ---------------------------------------------------------------------------
# AES-256-GCM (pure Python)
# ---------------------------------------------------------------------------

_SBOX: List[int] = []
_RCON = [0x01]


def _init_aes_tables() -> None:
    global _SBOX
    if _SBOX:
        return
    p = 1
    q = 1
    sbox = [0] * 256
    while True:
        # multiply p by 3
        p = p ^ ((p << 1) & 0xFF) ^ (0x1B if p & 0x80 else 0)
        # divide q by 3
        q ^= (q << 1) & 0xFF
        q ^= (q << 2) & 0xFF
        q ^= (q << 4) & 0xFF
        q &= 0xFF
        if q & 0x80:
            q ^= 0x09
        x = q ^ ((q << 1) | (q >> 7)) ^ ((q << 2) | (q >> 6)) ^ ((q << 3) | (q >> 5)) ^ ((q << 4) | (q >> 4))
        sbox[p] = (x ^ 0x63) & 0xFF
        if p == 1:
            break
    sbox[0] = 0x63
    _SBOX = sbox
    r = 1
    for _ in range(1, 14):
        r = ((r << 1) ^ (0x1B if r & 0x80 else 0)) & 0xFF
        _RCON.append(r)


_init_aes_tables()


def _xtime(a: int) -> int:
    a <<= 1
    if a & 0x100:
        a = (a ^ 0x1B) & 0xFF
    return a


def _gmul(a: int, b: int) -> int:
    """Multiply in GF(2^8) with the AES polynomial."""
    r = 0
    for _ in range(8):
        if b & 1:
            r ^= a
        b >>= 1
        a = _xtime(a)
    return r


class AES:
    """AES block cipher, encrypt-only (all that GCM needs)."""

    def __init__(self, key: bytes) -> None:
        assert len(key) in (16, 24, 32), "AES key must be 16/24/32 bytes"
        self.nk = len(key) // 4
        self.nr = self.nk + 6
        self.round_keys = self._expand(key)

    def _expand(self, key: bytes) -> List[List[int]]:
        w = [list(key[4 * i: 4 * i + 4]) for i in range(self.nk)]
        for i in range(self.nk, 4 * (self.nr + 1)):
            temp = list(w[i - 1])
            if i % self.nk == 0:
                temp = temp[1:] + temp[:1]
                temp = [_SBOX[b] for b in temp]
                temp[0] ^= _RCON[i // self.nk - 1]
            elif self.nk > 6 and i % self.nk == 4:
                temp = [_SBOX[b] for b in temp]
            # FIPS-197 §5.2: w[i] = w[i - Nk] XOR (g(w[i-1]) or w[i-1]).
            # The step back is Nk words, which only coincides with 4 for AES-128.
            w.append([w[i - self.nk][j] ^ temp[j] for j in range(4)])
        return w

    def encrypt_block(self, block: bytes) -> bytes:
        s = [[block[r + 4 * c] for c in range(4)] for r in range(4)]
        self._add_round_key(s, 0)
        for rnd in range(1, self.nr):
            self._sub_bytes(s)
            self._shift_rows(s)
            self._mix_columns(s)
            self._add_round_key(s, rnd)
        self._sub_bytes(s)
        self._shift_rows(s)
        self._add_round_key(s, self.nr)
        return bytes(s[r][c] for c in range(4) for r in range(4))

    def _add_round_key(self, s: List[List[int]], rnd: int) -> None:
        for c in range(4):
            word = self.round_keys[rnd * 4 + c]
            for r in range(4):
                s[r][c] ^= word[r]

    @staticmethod
    def _sub_bytes(s: List[List[int]]) -> None:
        for r in range(4):
            for c in range(4):
                s[r][c] = _SBOX[s[r][c]]

    @staticmethod
    def _shift_rows(s: List[List[int]]) -> None:
        for r in range(1, 4):
            row = s[r][:]
            for c in range(4):
                s[r][c] = row[(c + r) % 4]

    @staticmethod
    def _mix_columns(s: List[List[int]]) -> None:
        for c in range(4):
            a = [s[r][c] for r in range(4)]
            s[0][c] = _gmul(a[0], 2) ^ _gmul(a[1], 3) ^ a[2] ^ a[3]
            s[1][c] = a[0] ^ _gmul(a[1], 2) ^ _gmul(a[2], 3) ^ a[3]
            s[2][c] = a[0] ^ a[1] ^ _gmul(a[2], 2) ^ _gmul(a[3], 3)
            s[3][c] = _gmul(a[0], 3) ^ a[1] ^ a[2] ^ _gmul(a[3], 2)


def _ghash_mul(x: bytes, y: bytes) -> bytes:
    """Carry-less multiply in GF(2^128) using the GCM convention.

    The block is read as a big-endian integer; the "multiply by x" step tests
    the **least** significant bit and folds in the reduction constant
    R = 11100001 || 0^120 = 0xE1 << 120.
    """
    z = 0
    v = int.from_bytes(y, "big")
    for i in range(128):
        if (x[i // 8] >> (7 - (i % 8))) & 1:
            z ^= v
        if v & 1:
            v = (v >> 1) ^ (0xE1 << 120)
        else:
            v >>= 1
    return z.to_bytes(16, "big")


def _ghash(h: bytes, aad: bytes, ciphertext: bytes) -> bytes:
    """GHASH over A || pad(A) || C || pad(C) || [len(A)]64 || [len(C)]64."""
    def pad(data: bytes) -> bytes:
        return data + b"\x00" * ((-len(data)) % 16)

    data = pad(aad) + pad(ciphertext)
    data += struct.pack(">Q", len(aad) * 8)
    data += struct.pack(">Q", len(ciphertext) * 8)
    y = b"\x00" * 16
    for i in range(0, len(data), 16):
        block = data[i:i + 16].ljust(16, b"\x00")
        y = _ghash_mul(bytes(a ^ b for a, b in zip(y, block)), h)
    return y


def _ctr(cipher: AES, counter_block: bytes, length: int) -> bytes:
    prefix = counter_block[:12]
    counter = int.from_bytes(counter_block[12:], "big")
    out = bytearray()
    while len(out) < length:
        counter = (counter + 1) & 0xFFFFFFFF
        out += cipher.encrypt_block(prefix + counter.to_bytes(4, "big"))
    return bytes(out[:length])


def aes_gcm_encrypt(key: bytes, nonce: bytes, plaintext: bytes, aad: bytes = b"") -> Tuple[bytes, bytes]:
    """AES-GCM encryption. Returns (ciphertext, tag)."""
    assert len(nonce) == 12, "only 96-bit nonces are used by androcall"
    cipher = AES(key)
    h = cipher.encrypt_block(b"\x00" * 16)
    j0 = nonce + b"\x00\x00\x00\x01"
    ciphertext = bytes(a ^ b for a, b in zip(plaintext, _ctr(cipher, j0, len(plaintext))))
    s = _ghash(h, aad, ciphertext)
    tag = bytes(a ^ b for a, b in zip(s, cipher.encrypt_block(j0)))
    return ciphertext, tag


def aes_gcm_decrypt(key: bytes, nonce: bytes, ciphertext: bytes, tag: bytes, aad: bytes = b"") -> bytes:
    cipher = AES(key)
    h = cipher.encrypt_block(b"\x00" * 16)
    j0 = nonce + b"\x00\x00\x00\x01"
    s = _ghash(h, aad, ciphertext)
    expected = bytes(a ^ b for a, b in zip(s, cipher.encrypt_block(j0)))
    if not hmac.compare_digest(expected, tag):
        raise ValueError("AES-GCM authentication failed")
    return bytes(a ^ b for a, b in zip(ciphertext, _ctr(cipher, j0, len(ciphertext))))


# ---------------------------------------------------------------------------
# NIST P-256
# ---------------------------------------------------------------------------

_P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
_A = _P - 3
_B = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
_GX = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296
_GY = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5


def _point_add(p: Optional[Tuple[int, int]], q: Optional[Tuple[int, int]]) -> Optional[Tuple[int, int]]:
    if p is None:
        return q
    if q is None:
        return p
    x1, y1 = p
    x2, y2 = q
    if x1 == x2 and (y1 + y2) % _P == 0:
        return None
    if p == q:
        lam = (3 * x1 * x1 + _A) * pow(2 * y1, _P - 2, _P) % _P
    else:
        lam = (y2 - y1) * pow(x2 - x1, _P - 2, _P) % _P
    x3 = (lam * lam - x1 - x2) % _P
    y3 = (lam * (x1 - x3) - y1) % _P
    return (x3, y3)


def _point_mul(k: int, point: Tuple[int, int]) -> Optional[Tuple[int, int]]:
    result: Optional[Tuple[int, int]] = None
    addend: Optional[Tuple[int, int]] = point
    while k:
        if k & 1:
            result = _point_add(result, addend)
        addend = _point_add(addend, addend)
        k >>= 1
    return result


def p256_public_from_private(private: bytes) -> bytes:
    """Return the 65-byte X9.63 uncompressed public point for a 32-byte private key."""
    d = int.from_bytes(private, "big")
    if not (1 <= d < _N):
        raise ValueError("private scalar out of range")
    x, y = _point_mul(d, (_GX, _GY))  # type: ignore[misc]
    return b"\x04" + x.to_bytes(32, "big") + y.to_bytes(32, "big")


def p256_ecdh(private: bytes, peer_public_x963: bytes) -> bytes:
    """Return the 32-byte shared secret (X coordinate) for an ECDH exchange."""
    if len(peer_public_x963) != 65 or peer_public_x963[0] != 0x04:
        raise ValueError("peer public key must be a 65-byte X9.63 uncompressed point")
    px = int.from_bytes(peer_public_x963[1:33], "big")
    py = int.from_bytes(peer_public_x963[33:65], "big")
    if (py * py - (px * px * px + _A * px + _B)) % _P != 0:
        raise ValueError("peer public key is not on the curve")
    d = int.from_bytes(private, "big")
    shared = _point_mul(d, (px, py))
    if shared is None:
        raise ValueError("degenerate ECDH result")
    return shared[0].to_bytes(32, "big")


# ---------------------------------------------------------------------------
# androcall session key schedule
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class SessionKeys:
    ikm: bytes
    c2s: bytes
    s2c: bytes
    proof: bytes
    verify_code: str


def build_transcript(
    server_nonce: bytes,
    client_nonce: bytes,
    server_pubkey: bytes,
    client_pubkey: bytes,
    salt: bytes,
    iterations: int,
) -> bytes:
    return (
        server_nonce
        + client_nonce
        + server_pubkey
        + client_pubkey
        + salt
        + struct.pack(">I", iterations)
    )


def derive_session_keys(
    pin: str,
    salt: bytes,
    iterations: int,
    server_nonce: bytes,
    client_nonce: bytes,
    server_pubkey: bytes,
    client_pubkey: bytes,
    ecdh_shared: bytes,
) -> SessionKeys:
    pin_secret = pbkdf2_sha256(pin.encode("utf-8"), salt, iterations, 32)
    ikm = hkdf_sha256(
        ecdh_shared + pin_secret,
        SESSION_SALT_PREFIX + server_nonce + client_nonce,
        SESSION_INFO,
        32,
    )
    c2s = hkdf_sha256(ikm, b"", C2S_INFO, 32)
    s2c = hkdf_sha256(ikm, b"", S2C_INFO, 32)
    transcript = build_transcript(
        server_nonce, client_nonce, server_pubkey, client_pubkey, salt, iterations
    )
    proof = hmac_sha256(ikm, PROOF_PREFIX + transcript)
    code_int = int.from_bytes(hmac_sha256(ikm, VERIFY_PREFIX)[:4], "big") % 10000
    return SessionKeys(
        ikm=ikm,
        c2s=c2s,
        s2c=s2c,
        proof=proof,
        verify_code=f"{code_int:04d}",
    )


def nonce_for(direction: int, seq: int) -> bytes:
    """12-byte GCM nonce: 4-byte direction constant + 8-byte big-endian sequence."""
    return struct.pack(">I", direction) + struct.pack(">Q", seq)


DIRECTION_C2S = 0x00000001
DIRECTION_S2C = 0x00000002


# ---------------------------------------------------------------------------
# Frames
# ---------------------------------------------------------------------------


@dataclass
class Frame:
    kind: int
    flags: int
    seq: int
    msg_id: int
    frag_index: int
    frag_count: int
    payload: bytes
    tag: Optional[bytes] = None

    def header(self) -> bytes:
        return (
            MAGIC
            + bytes([FRAME_VERSION, self.kind, self.flags])
            + struct.pack("<I", self.seq & 0xFFFFFFFF)
            + struct.pack("<Q", self.msg_id & 0xFFFFFFFFFFFFFFFF)
            + struct.pack("<H", self.frag_index)
            + struct.pack("<H", self.frag_count)
            + struct.pack("<H", len(self.payload))
        )

    def encode(self) -> bytes:
        out = self.header() + self.payload
        if self.tag is not None:
            out += self.tag
        return out

    @staticmethod
    def decode(data: bytes) -> "Frame":
        if len(data) < HEADER_SIZE:
            raise ValueError("frame shorter than header")
        if data[0:2] != MAGIC:
            raise ValueError("bad magic")
        if data[2] != FRAME_VERSION:
            raise ValueError("unsupported frame version")
        kind = data[3]
        flags = data[4]
        seq = struct.unpack_from("<I", data, 5)[0]
        msg_id = struct.unpack_from("<Q", data, 9)[0]
        frag_index = struct.unpack_from("<H", data, 17)[0]
        frag_count = struct.unpack_from("<H", data, 19)[0]
        length = struct.unpack_from("<H", data, 21)[0]
        if len(data) < HEADER_SIZE + length:
            raise ValueError("frame payload truncated")
        payload = data[HEADER_SIZE:HEADER_SIZE + length]
        tag = None
        if kind == KIND_ENCRYPTED:
            if len(data) < HEADER_SIZE + length + TAG_SIZE:
                raise ValueError("frame tag truncated")
            tag = data[HEADER_SIZE + length:HEADER_SIZE + length + TAG_SIZE]
        return Frame(kind, flags, seq, msg_id, frag_index, frag_count, payload, tag)


def encrypt_frame(frame: Frame, key: bytes, direction: int) -> Frame:
    """Return a new encrypted frame carrying the same logical message.

    The additional authenticated data is the header of the *sealed* frame, so
    the receiver authenticates exactly the bytes it received.
    """
    sealed_frame = Frame(
        kind=KIND_ENCRYPTED,
        flags=frame.flags,
        seq=frame.seq,
        msg_id=frame.msg_id,
        frag_index=frame.frag_index,
        frag_count=frame.frag_count,
        payload=frame.payload,
    )
    header = sealed_frame.header()
    nonce = nonce_for(direction, frame.seq)
    ciphertext, tag = aes_gcm_encrypt(key, nonce, frame.payload, header)
    sealed_frame.payload = ciphertext
    sealed_frame.tag = tag
    return sealed_frame


def decrypt_frame(frame: Frame, key: bytes, direction: int) -> bytes:
    if frame.tag is None:
        raise ValueError("encrypted frame without tag")
    header = frame.header()
    nonce = nonce_for(direction, frame.seq)
    return aes_gcm_decrypt(key, nonce, frame.payload, frame.tag, header)


# ---------------------------------------------------------------------------
# Messages
# ---------------------------------------------------------------------------


@dataclass
class Message:
    type: str
    id: str
    ts: int
    body: Dict = field(default_factory=dict)
    reply_to: Optional[str] = None
    version: int = PROTOCOL_VERSION

    def to_json(self) -> bytes:
        """Canonical JSON serialisation (PROTOCOL.md §4.0).

        Top-level field order is fixed as v, type, id, ts, replyTo, body;
        keys inside ``body`` are sorted lexicographically by their UTF-8 bytes.
        """
        parts = [
            '"v":' + canonical_json(self.version),
            '"type":' + canonical_json(self.type),
            '"id":' + canonical_json(self.id),
            '"ts":' + canonical_json(self.ts),
            '"replyTo":' + ("null" if self.reply_to is None else canonical_json(self.reply_to)),
            '"body":' + canonical_json(self.body),
        ]
        return ("{" + ",".join(parts) + "}").encode("utf-8")

    @staticmethod
    def from_json(data: bytes) -> "Message":
        import json

        obj = json.loads(data.decode("utf-8"))
        if not isinstance(obj, dict):
            raise ValueError("message must be a JSON object")
        for required in ("v", "type", "id", "ts"):
            if required not in obj:
                raise ValueError(f"message missing field '{required}'")
        if obj["v"] != PROTOCOL_VERSION:
            raise ValueError(f"unsupported protocol version {obj['v']}")
        body = obj.get("body") or {}
        if not isinstance(body, dict):
            raise ValueError("message body must be an object")
        reply_to = obj.get("replyTo")
        if reply_to is not None and not isinstance(reply_to, str):
            raise ValueError("replyTo must be a string or null")
        return Message(
            type=obj["type"],
            id=obj["id"],
            ts=int(obj["ts"]),
            body=body,
            reply_to=reply_to,
            version=int(obj["v"]),
        )


_JSON_ESCAPES = {
    '"': '\\"',
    "\\": "\\\\",
    "\b": "\\b",
    "\f": "\\f",
    "\n": "\\n",
    "\r": "\\r",
    "\t": "\\t",
}


def canonical_json(value) -> str:
    """Serialise a JSON value using the canonical rules of PROTOCOL.md §4.0."""
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        if value != int(value):
            raise ValueError("the protocol does not carry fractional numbers")
        return str(int(value))
    if isinstance(value, str):
        return _canonical_string(value)
    if isinstance(value, (list, tuple)):
        return "[" + ",".join(canonical_json(v) for v in value) + "]"
    if isinstance(value, dict):
        items = []
        for key in sorted(value.keys(), key=lambda k: k.encode("utf-8")):
            items.append(_canonical_string(key) + ":" + canonical_json(value[key]))
        return "{" + ",".join(items) + "}"
    raise ValueError(f"cannot serialise {type(value).__name__}")


def _canonical_string(text: str) -> str:
    out = ['"']
    for ch in text:
        escaped = _JSON_ESCAPES.get(ch)
        if escaped is not None:
            out.append(escaped)
        elif ord(ch) < 0x20:
            out.append("\\u%04x" % ord(ch))
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def fragment_message(msg_bytes: bytes, msg_id: int, seq_start: int, max_payload: int) -> List[Frame]:
    """Split a serialised message into frames no larger than ``max_payload``."""
    if max_payload <= 0:
        raise ValueError("max_payload must be positive")
    chunks = [msg_bytes[i:i + max_payload] for i in range(0, len(msg_bytes), max_payload)] or [b""]
    frames: List[Frame] = []
    for index, chunk in enumerate(chunks):
        flags = 0
        if index == 0:
            flags |= FLAG_FIRST
        if index != len(chunks) - 1:
            flags |= FLAG_MORE
        frames.append(
            Frame(
                kind=KIND_PLAINTEXT,
                flags=flags,
                seq=seq_start + index,
                msg_id=msg_id,
                frag_index=index,
                frag_count=len(chunks),
                payload=chunk,
            )
        )
    return frames


# ---------------------------------------------------------------------------
# Self-test against published vectors
# ---------------------------------------------------------------------------


# --- NIST CAVP GCM vectors (96-bit IV, AES-128) ---------------------------
# Source: NIST CAVP "GCM Encrypt with keysize 128" (gcmEncryptExtIV128.rsp),
# [IVlen = 96] section. These are the pinned known answers for the self-test.
CAVP_GCM_VECTORS = [
    {
        "key": "c939cc13397c1d37de6ae0e1cb7c423c",
        "iv": "b3d8cc017cbb89b39e0f67e2",
        "pt": "c3b3c41f113a31b73d9a5cd432103069",
        "aad": "24825602bd12a984e0092d3e448eda5f",
        "ct": "93fe7d9e9bfd10348a5606e5cafa7354",
        "tag": "0032a1dc85f1c9786925a2e71d8272dd",
    },
    {
        "key": "599eb65e6b2a2a7fcc40e51c4f6e3257",
        "iv": "d407301cfa29af8525981c17",
        "pt": "a6c9e0f248f07a3046ece12125666921",
        "aad": "10e72efe048648d40139477a2016f8ce",
        "ct": "1be9359a543fd7ec3c4bc6f3c9395e89",
        "tag": "e2e9c07d4c3c10a6137ca433da42f9a8",
    },
    {
        "key": "1fd1e536a1c39c75fd583bc8e3372029",
        "iv": "281f2552f8c34fb9b3ec85aa",
        "pt": "f801e0839619d2c1465f0245869360da",
        "aad": "bf12a140d86727f67b860bcf6f34e55f",
        "ct": "35371f2779f4140dfdb1afe79d563ed9",
        "tag": "cc2b0b0f1f8b3db5dc1b41ce73f5c221",
    },
]


def _self_test() -> None:
    """Known-answer tests against published vectors.

    * AES block cipher: FIPS-197 Appendix B/C (AES-128 and AES-256).
    * AES-GCM: NIST CAVP GCM vectors (96-bit IV, AES-128) - see
      ``CAVP_GCM_VECTORS`` above.
    * HKDF: RFC 5869 appendix A test case 1.
    * PBKDF2-HMAC-SHA256: published test vector.
    * P-256: a key pair generated with OpenSSL 3.x; the public point was
      cross-checked against ``openssl ec -pubout -outform DER``.
    """
    # --- FIPS-197 AES-128 / AES-256 block cipher --------------------------
    pt = bytes.fromhex("00112233445566778899aabbccddeeff")
    key128 = bytes.fromhex("000102030405060708090a0b0c0d0e0f")
    assert AES(key128).encrypt_block(pt).hex() == "69c4e0d86a7b0430d8cdb78070b4c55a"
    key256 = bytes.fromhex(
        "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    )
    assert AES(key256).encrypt_block(pt).hex() == "8ea2b7ca516745bfeafc49904b496089"
    # AES-192 (FIPS-197 Appendix C.2)
    key192 = bytes.fromhex("000102030405060708090a0b0c0d0e0f1011121314151617")
    assert AES(key192).encrypt_block(pt).hex() == "dda97ca4864cdfe06eaf70a0ec0d7191"

    # --- NIST CAVP AES-GCM vectors ----------------------------------------
    for v in CAVP_GCM_VECTORS:
        ct, tag = aes_gcm_encrypt(
            bytes.fromhex(v["key"]),
            bytes.fromhex(v["iv"]),
            bytes.fromhex(v["pt"]),
            bytes.fromhex(v["aad"]),
        )
        assert ct.hex() == v["ct"], (v["key"], ct.hex())
        assert tag.hex() == v["tag"], (v["key"], tag.hex())
        assert aes_gcm_decrypt(
            bytes.fromhex(v["key"]),
            bytes.fromhex(v["iv"]),
            bytes.fromhex(v["ct"]),
            bytes.fromhex(v["tag"]),
            bytes.fromhex(v["aad"]),
        ) == bytes.fromhex(v["pt"])

    # --- HKDF RFC 5869 test case 1 -----------------------------------------
    okm = hkdf_sha256(
        bytes.fromhex("0b" * 22),
        bytes.fromhex("000102030405060708090a0b0c"),
        bytes.fromhex("f0f1f2f3f4f5f6f7f8f9"),
        42,
    )
    assert okm.hex() == (
        "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf"
        "34007208d5b887185865"
    ), okm.hex()

    # --- PBKDF2-HMAC-SHA256 published vector --------------------------------
    derived = pbkdf2_sha256(b"password", b"salt", 1, 32)
    assert derived.hex() == (
        "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"
    ), derived.hex()

    # --- P-256 known answer (OpenSSL 3.x generated) -------------------------
    private_hex = "338cd8de8624bcf186adb79f855e2c74d018351daf9196993a4aa71d42caa767"
    public_hex = (
        "047622d8d3066edc228f53b2a01adad8d36184fb042ffd20e8ef8930911ba0f58"
        "670d315703de103d4dab950ae05fd2b4773ee6fb5cb014acef2c9f564578d2388"
    )
    private = bytes.fromhex(private_hex)
    assert p256_public_from_private(private).hex() == public_hex
    # ECDH symmetry: both sides derive the same secret.
    other_private = bytes.fromhex("01" * 32)
    other_public = p256_public_from_private(other_private)
    assert p256_ecdh(private, other_public) == p256_ecdh(other_private, bytes.fromhex(public_hex))
    # The generator is on the curve and scalar multiplication is consistent.
    d = 0x1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF
    pub = p256_public_from_private(d.to_bytes(32, "big"))
    x = int.from_bytes(pub[1:33], "big")
    y = int.from_bytes(pub[33:65], "big")
    assert (y * y - (x * x * x + _A * x + _B)) % _P == 0
    two_g = p256_public_from_private((2).to_bytes(32, "big"))
    d_times_two_g = _point_mul(
        d, (int.from_bytes(two_g[1:33], "big"), int.from_bytes(two_g[33:65], "big"))
    )
    expected = p256_public_from_private((2 * d).to_bytes(32, "big"))
    assert d_times_two_g[0].to_bytes(32, "big") == expected[1:33]
    assert d_times_two_g[1].to_bytes(32, "big") == expected[33:65]


if __name__ == "__main__":
    _self_test()
    print("androcall reference self-test: OK")
