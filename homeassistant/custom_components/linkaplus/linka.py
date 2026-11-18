"""LINKA LEO2 Bluetooth protocol.

Ported 1:1 from the LinkaPlus iOS app (LinkaCrypto.swift / BLEController.swift):
AES-128-CBC command frames, CRC-16/CCITT-FALSE, the live counter from the lock's
0x12 context frame, status-frame decoding and the access-key selection order.

This module has NO Home Assistant imports, so it can be exercised standalone from a
shell (see tools/linka_cli.py) and is also imported by the Home Assistant integration.

Created by Ivo Rooijackers (IvoRoo).
"""
from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from typing import Optional

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

_LOGGER = logging.getLogger(__name__)

# ---- BLE UUIDs (LinkaBLE in the app) ---------------------------------------
SERVICE_UUID = "d31e0470-416b-499b-95aa-5db239a0bfbe"
CHAR_RX = "d31e0002-416b-499b-95aa-5db239a0bfbe"   # app -> lock  (write)
CHAR_TX = "d31e0003-416b-499b-95aa-5db239a0bfbe"   # lock -> app  (notify/indicate)
CHAR_LOG = "d31e0014-416b-499b-95aa-5db239a0bfbe"  # lock -> app  (ascii debug log)

# ---- Command payloads (opcode, param) --------------------------------------
CMD_UNLOCK = [0, 0]
CMD_LOCK = [1, 0]
CMD_STATE = [27, 7]      # ask the lock for a status frame (battery + lock state)
CMD_SIREN_ON = [14, 60]
CMD_SIREN_OFF = [20, 0]


class LinkaError(Exception):
    """Any protocol / connection problem."""


# ---- CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, MSB-first) — pc/k.a ------
def crc16(data: bytes, length: int) -> int:
    crc = 0xFFFF
    for i in range(length):
        for bit in range(8):
            b = ((data[i] >> (7 - bit)) & 1) == 1
            c = ((crc >> 15) & 1) == 1
            crc = (crc << 1) & 0xFFFFFFFF
            if b != c:
                crc ^= 4129
    return crc & 0xFFFF


def apply_crc(buf: bytearray) -> None:
    """CRC over all but the last two bytes, stored big-endian in the last two."""
    c = crc16(bytes(buf), len(buf) - 2)
    buf[-1] = c & 0xFF
    buf[-2] = (c >> 8) & 0xFF


def crc_ok(d: bytes) -> bool:
    if len(d) < 4:
        return False
    c = crc16(d, len(d) - 2)
    return d[-2] == ((c >> 8) & 0xFF) and d[-1] == (c & 0xFF)


# ---- AES-128-CBC, no padding ----------------------------------------------
def aes_cbc_encrypt(key: bytes, iv: bytes, data: bytes) -> bytes:
    cipher = Cipher(algorithms.AES(key), modes.CBC(iv))
    enc = cipher.encryptor()
    return enc.update(data) + enc.finalize()


def mac_bytes(mac: str) -> bytes:
    parts = mac.split(":")
    if len(parts) != 6:
        raise ValueError(f"invalid MAC: {mac!r}")
    return bytes(int(p, 16) for p in parts)


# ---- Access-key selection (mirrors AccessKeys.commandKey in the app) --------
# Order and privilege exactly as Models.swift chooses them.
_KEY_ORDER = [
    ("v2_access_key_admin_2", True),
    ("v2_access_key_user_2", False),
    ("access_key_admin_2", True),
    ("access_key_user_2", False),
    ("access_key_master_2", True),
    ("access_key_master", True),
]


def select_command_key(keys: dict) -> tuple[bytes, bool]:
    """Return (16-byte subkey, admin?) from an AccessKeys dict, like the app does."""
    for name, admin in _KEY_ORDER:
        val = keys.get(name)
        if val:
            kb = bytes.fromhex(val)
            if len(kb) != 16:
                raise ValueError(f"{name} is {len(kb)} bytes, expected 16")
            return kb, admin
    raise ValueError("no usable command key in AccessKeys")


# ---- 20-byte encrypted command frame (pc/g.g, setSubkey path) --------------
def command_frame(mac: bytes, payload: list[int], subkey: bytes, admin: bool, counter: int) -> bytes:
    rev = mac[::-1]  # bArr7[5-i] = mac[i]

    # payload block (16 bytes): [0x10, payload..., CRC(2)]
    block = bytearray(16)
    block[0] = 0x10
    for i, b in enumerate(payload):
        block[1 + i] = b & 0xFF
    apply_crc(block)

    # IV = revMAC(6) + counter LE(4) + zeros
    iv = bytearray(16)
    iv[0:6] = rev
    iv[6] = counter & 0xFF
    iv[7] = (counter >> 8) & 0xFF
    iv[8] = (counter >> 16) & 0xFF
    iv[9] = (counter >> 24) & 0xFF

    enc = aes_cbc_encrypt(subkey, bytes(iv), bytes(block))

    frame = bytearray(20)
    frame[0] = 20
    flag = 0x80 | 0x40          # f36009f == 1 (slot 1, used directly)
    if not admin:
        flag |= 0x10            # user privilege
    frame[1] = flag
    frame[2:18] = enc[:16]
    apply_crc(frame)
    return bytes(frame)


@dataclass
class LockStatus:
    locked: Optional[bool] = None
    battery: Optional[int] = None
    voltage: Optional[float] = None
    state_code: Optional[int] = None
    charging: bool = False

    STATE_TEXT = {
        0: "startup", 1: "locking", 2: "unlocking", 3: "locked", 4: "unlocked",
        5: "error", 6: "stalled", 7: "locked (PAC)", 8: "unlocked (PAC)",
    }

    @property
    def state_text(self) -> str:
        return self.STATE_TEXT.get(self.state_code, "unknown")


class LinkaLock:
    """Drives one LINKA LEO2 lock over an already-connected BLE client.

    The `client` is any object with the bleak async API (`start_notify`,
    `write_gatt_char`, `disconnect`). For Home Assistant it comes from
    bleak-retry-connector; for the CLI tester it is a plain BleakClient.
    """

    def __init__(self, mac: str, keys: dict, *, name: str = "LINKA"):
        self.mac = mac
        self._mac_b = mac_bytes(mac)
        self._subkey, self._admin = select_command_key(keys)
        self.name = name
        self.status = LockStatus()
        self._client = None
        self._counter: Optional[int] = None
        self._last_used: Optional[int] = None
        self._last_ack: Optional[tuple[str, int]] = None
        self._ack_event = asyncio.Event()
        self._ctx_event = asyncio.Event()

    # -- notifications -------------------------------------------------------
    def _on_notify(self, _char, data: bytearray) -> None:
        d = bytes(data)
        if len(d) < 2:
            return

        # 0x12 context frame (encVer 2) -> live counter.
        if len(d) >= 7 and d[0] == 0x12 and d[1] == 0x0B and crc_ok(d):
            self._counter = d[3] | (d[4] << 8) | (d[5] << 16) | (d[6] << 24)
            self._ctx_event.set()
            return

        # Status frame: [0x14, 0x02, state, _, mvLo, mvHi, battery, ...]
        if len(d) >= 7 and d[0] == 0x14 and d[1] == 0x02:
            code = d[2]
            self.status.state_code = code
            if code in (3, 7, 4, 8):
                self.status.locked = code in (3, 7)
            pct = d[6]
            if 0 <= pct <= 100:
                self.status.battery = pct
            mv = d[4] | (d[5] << 8)
            if 1000 < mv < 6000:
                self.status.voltage = mv / 1000.0
            if len(d) >= 16:
                flags = d[12] | (d[13] << 8) | (d[14] << 16) | (d[15] << 24)
                self.status.charging = bool(flags & 0x04)
            return

        # ACK (6) / NAK (7): next counter in bytes[7..10].
        if len(d) >= 12 and d[0] == len(d) and d[1] in (6, 7) and crc_ok(d):
            c = d[7] | (d[8] << 8) | (d[9] << 16) | (d[10] << 24)
            if c:
                self._counter = c
            self._last_ack = ("ack" if d[1] == 6 else "nak", d[2])
            self._ack_event.set()
            return

        # Setting reply (3/4): next counter in bytes[11..14].
        if len(d) >= 15 and d[0] == len(d) and d[1] in (3, 4) and crc_ok(d):
            c = d[11] | (d[12] << 8) | (d[13] << 16) | (d[14] << 24)
            if c:
                self._counter = c
            return

    # -- lifecycle -----------------------------------------------------------
    async def attach(self, client) -> None:
        """Bind to a connected client and subscribe to notifications."""
        self._client = client
        await client.start_notify(CHAR_TX, self._on_notify)
        # Some firmwares also push frames on the debug-log characteristic.
        try:
            await client.start_notify(CHAR_LOG, self._on_notify)
        except Exception:  # noqa: BLE001 - best effort, char may be absent
            pass

    async def wait_for_counter(self, timeout: float = 8.0) -> bool:
        """Wait for the lock to hand out its 0x12 context counter."""
        if self._counter is not None:
            return True
        try:
            await asyncio.wait_for(self._ctx_event.wait(), timeout)
            return True
        except asyncio.TimeoutError:
            return False

    # -- commands ------------------------------------------------------------
    async def _send(self, payload: list[int], *, expect_ack: bool = True, timeout: float = 5.0) -> bool:
        if self._client is None:
            raise LinkaError("not attached to a BLE client")
        if not await self.wait_for_counter(timeout):
            raise LinkaError("no context counter from lock (no 0x12 frame — lock asleep or out of range?)")

        # Anti-replay: the counter IS the AES IV. Never reuse one — wait (up to ~3 s)
        # for the lock to hand out a fresh counter via a new 0x12 / ACK frame.
        counter = self._counter
        for _ in range(16):
            if counter != self._last_used:
                break
            await asyncio.sleep(0.2)
            counter = self._counter
        if counter == self._last_used:
            raise LinkaError("no fresh counter from lock — command not sent")

        frame = command_frame(self._mac_b, payload, self._subkey, self._admin, counter)
        self._last_used = counter
        self._ack_event.clear()
        _LOGGER.debug("-> %s (ctr %s): %s", payload, counter, frame.hex())
        await self._client.write_gatt_char(CHAR_RX, frame, response=True)

        if not expect_ack:
            return True
        try:
            await asyncio.wait_for(self._ack_event.wait(), timeout)
        except asyncio.TimeoutError:
            return False
        kind, _cmd = self._last_ack or ("nak", 0)
        return kind == "ack"

    async def unlock(self) -> bool:
        ok = await self._send(CMD_UNLOCK)
        if ok:
            self.status.locked = False
        return ok

    async def lock(self) -> bool:
        ok = await self._send(CMD_LOCK)
        if ok:
            self.status.locked = True
        return ok

    async def refresh(self, settle: float = 1.0) -> LockStatus:
        """Ask the lock for its status; the frame arrives via notification."""
        await self._send(CMD_STATE, expect_ack=False)
        await asyncio.sleep(settle)
        return self.status

    async def siren_on(self) -> bool:
        return await self._send(CMD_SIREN_ON, expect_ack=False)

    async def siren_off(self) -> bool:
        return await self._send(CMD_SIREN_OFF, expect_ack=False)


async def connect_standalone(mac: str, keys: dict, *, name: str = "LINKA",
                             timeout: float = 20.0, adapter: str | None = None):
    """CLI helper: scan, connect with a plain BleakClient, attach. Returns (lock, client)."""
    from bleak import BleakClient, BleakScanner

    kw = {"timeout": timeout}
    if adapter:
        kw["adapter"] = adapter
    device = await BleakScanner.find_device_by_address(mac, **kw)
    if device is None:
        raise LinkaError(f"lock {mac} not found (awake? in range? right power mode?)")
    client = BleakClient(device)
    await client.connect()
    lock = LinkaLock(mac, keys, name=name)
    await lock.attach(client)
    return lock, client
