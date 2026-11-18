"""Connection coordinator for a LINKA LEO2 lock.

Connect-per-operation: each command or poll opens a short BLE connection through Home
Assistant's own Bluetooth stack (so it works with a local adapter or an ESPHome
Bluetooth proxy in range of the bike), runs, then disconnects. Operations are
serialised so the app-style single-link assumption holds.
"""
from __future__ import annotations

import asyncio
import logging
from datetime import timedelta

from bleak_retry_connector import BleakClientWithServiceCache, establish_connection

from homeassistant.components import bluetooth
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.update_coordinator import DataUpdateCoordinator, UpdateFailed

from .const import CONF_KEYS, CONF_MAC, CONF_NAME, UPDATE_INTERVAL
from .linka import LinkaError, LinkaLock, LockStatus

_LOGGER = logging.getLogger(__name__)


class LinkaCoordinator(DataUpdateCoordinator[LockStatus]):
    """Owns the lock's keys and brokers every BLE operation."""

    def __init__(self, hass: HomeAssistant, entry: ConfigEntry) -> None:
        self.entry = entry
        self.mac: str = entry.data[CONF_MAC]
        self.keys: dict = entry.data[CONF_KEYS]
        self.lock_name: str = entry.data.get(CONF_NAME) or "LINKA"
        super().__init__(
            hass,
            _LOGGER,
            name=self.lock_name,
            update_interval=timedelta(seconds=UPDATE_INTERVAL),
        )

    async def _run(self, action, *, connect_timeout: float = 25.0):
        """Open a connection, attach the protocol, run `action(lock)`, disconnect."""
        device = bluetooth.async_ble_device_from_address(
            self.hass, self.mac.upper(), connectable=True
        )
        if device is None:
            raise UpdateFailed(
                f"{self.mac} not in range of any Bluetooth adapter/proxy "
                "(is the bike nearby and awake?)"
            )

        client = await establish_connection(
            BleakClientWithServiceCache, device, self.mac
        )
        try:
            lock = LinkaLock(self.mac, self.keys, name=self.lock_name)
            await lock.attach(client)
            async with asyncio.timeout(connect_timeout):
                if not await lock.wait_for_counter(10.0):
                    raise UpdateFailed("lock did not send its context frame")
                result = await action(lock)
            return result, lock.status
        finally:
            await client.disconnect()

    async def _async_update_data(self) -> LockStatus:
        async def act(lock: LinkaLock) -> None:
            await lock.refresh()

        try:
            _, status = await self._run(act)
        except UpdateFailed:
            raise
        except Exception as err:  # noqa: BLE001
            raise UpdateFailed(str(err)) from err
        return status

    async def async_do_lock(self) -> None:
        async def act(lock: LinkaLock) -> bool:
            return await lock.lock()

        ok, status = await self._run(act)
        self.async_set_updated_data(status)
        if not ok:
            raise LinkaError("lock command was not acknowledged")

    async def async_do_unlock(self) -> None:
        async def act(lock: LinkaLock) -> bool:
            return await lock.unlock()

        ok, status = await self._run(act)
        self.async_set_updated_data(status)
        if not ok:
            raise LinkaError("unlock command was not acknowledged")
