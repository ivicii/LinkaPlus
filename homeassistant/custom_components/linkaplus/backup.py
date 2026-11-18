"""Decrypt a LinkaPlus key backup (.linkabackup).

Ported from KeyBackup.swift: PBKDF2-SHA256 (200 000 rounds) -> AES-GCM. The plaintext
is a JSON payload whose `keys` map holds, per lock serial (= MAC), the AccessKeys JSON
string exactly as the app stores it in the Keychain.

No Home Assistant imports. Created by Ivo Rooijackers (IvoRoo).
"""
from __future__ import annotations

import base64
import json

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

PBKDF2_ROUNDS = 200_000


class BackupError(Exception):
    """Wrong passphrase or corrupt file."""


def _derive(passphrase: str, salt: bytes) -> bytes:
    kdf = PBKDF2HMAC(algorithm=hashes.SHA256(), length=32, salt=salt, iterations=PBKDF2_ROUNDS)
    return kdf.derive(passphrase.encode("utf-8"))


def decrypt_backup(data: bytes, passphrase: str) -> dict[str, dict]:
    """Return {serial: AccessKeys-dict} from an encrypted .linkabackup blob."""
    try:
        env = json.loads(data)
        salt = base64.b64decode(env["salt"])
        combined = base64.b64decode(env["ct"])  # nonce(12) || ciphertext || tag(16)
    except (ValueError, KeyError) as exc:
        raise BackupError("not a valid LinkaPlus backup file") from exc

    key = _derive(passphrase, salt)
    nonce, ct = combined[:12], combined[12:]
    try:
        plain = AESGCM(key).decrypt(nonce, ct, None)
    except Exception as exc:  # noqa: BLE001 - InvalidTag etc.
        raise BackupError("wrong passphrase or corrupt backup") from exc

    payload = json.loads(plain)
    out: dict[str, dict] = {}
    for serial, keys_json in payload.get("keys", {}).items():
        # keys[serial] is itself a JSON string (the Keychain value).
        out[serial] = json.loads(keys_json)
    return out


def keys_for(data: bytes, passphrase: str, mac: str | None = None) -> dict:
    """Decrypt and return the AccessKeys for `mac` (case-insensitive).

    If `mac` is None and the backup holds exactly one lock, that one is returned.
    """
    everything = decrypt_backup(data, passphrase)
    if mac:
        for serial, keys in everything.items():
            if serial.replace(":", "").lower() == mac.replace(":", "").lower():
                return keys
        raise BackupError(f"no keys for {mac} in this backup")
    if len(everything) == 1:
        return next(iter(everything.values()))
    raise BackupError("backup holds several locks — specify which MAC")
