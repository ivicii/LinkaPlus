#!/usr/bin/env python3
"""Standalone tester for the LINKA LEO2 Bluetooth bridge.

Run this on the Home Assistant host (or any Linux box with a Bluetooth adapter in
range of the bike) to confirm the protocol works BEFORE wiring the integration into
Home Assistant. It uses the same protocol module as the integration.

    pip install bleak cryptography

    # from a LinkaPlus backup:
    python tools/linka_cli.py --mac FB:80:2B:7A:C2:EB \
        --backup ~/my.linkabackup --passphrase 'secret' status
    python tools/linka_cli.py --mac FB:80:2B:7A:C2:EB --backup ~/my.linkabackup --passphrase 'secret' unlock
    python tools/linka_cli.py --mac FB:80:2B:7A:C2:EB --backup ~/my.linkabackup --passphrase 'secret' lock

    # or with the AccessKeys JSON in a file:
    python tools/linka_cli.py --mac FB:80:2B:7A:C2:EB --keys-file keys.json status

Created by Ivo Rooijackers (IvoRoo).
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path

# Import the protocol straight from the custom component (no install needed).
_COMP = Path(__file__).resolve().parent.parent / "custom_components" / "linkaplus"
sys.path.insert(0, str(_COMP))

import backup as backup_mod  # noqa: E402
import linka  # noqa: E402


def load_keys(args) -> dict:
    if args.backup:
        data = Path(args.backup).expanduser().read_bytes()
        return backup_mod.keys_for(data, args.passphrase or "", args.mac)
    if args.keys_file:
        parsed = json.loads(Path(args.keys_file).expanduser().read_text())
        if any(k.startswith(("access_key", "v2_")) for k in parsed):
            return parsed
        # serial -> keys mapping
        for serial, ks in parsed.items():
            if serial.replace(":", "").lower() == args.mac.replace(":", "").lower():
                return ks
        return next(iter(parsed.values()))
    raise SystemExit("provide --backup (+--passphrase) or --keys-file")


async def run(args) -> int:
    keys = load_keys(args)
    print(f"Connecting to {args.mac} …")
    lock, client = await linka.connect_standalone(
        args.mac, keys, timeout=args.timeout, adapter=args.adapter
    )
    try:
        got = await lock.wait_for_counter(10.0)
        if not got:
            print("No context frame from the lock — is it awake and in range?")
            return 2
        if args.action == "unlock":
            ok = await lock.unlock()
            print("Unlock:", "OK" if ok else "not acknowledged")
        elif args.action == "lock":
            ok = await lock.lock()
            print("Lock:", "OK" if ok else "not acknowledged")
        await lock.refresh()
        s = lock.status
        print(
            f"State: {s.state_text}  |  locked={s.locked}  |  "
            f"battery={s.battery}%  |  voltage={s.voltage}  |  charging={s.charging}"
        )
        return 0
    finally:
        await client.disconnect()


def main() -> int:
    p = argparse.ArgumentParser(description="LINKA LEO2 Bluetooth tester")
    p.add_argument("action", choices=["status", "unlock", "lock"], help="what to do")
    p.add_argument("--mac", required=True, help="lock MAC, e.g. FB:80:2B:7A:C2:EB")
    p.add_argument("--backup", help="path to a .linkabackup file")
    p.add_argument("--passphrase", help="backup passphrase")
    p.add_argument("--keys-file", help="path to an AccessKeys JSON file")
    p.add_argument("--adapter", help="bluetooth adapter, e.g. hci0")
    p.add_argument("--timeout", type=float, default=20.0, help="scan timeout (s)")
    args = p.parse_args()
    try:
        return asyncio.run(run(args))
    except (linka.LinkaError, backup_mod.BackupError) as err:
        print("Error:", err)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
