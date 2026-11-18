"""Lock platform for LinkaPlus."""
from __future__ import annotations

from homeassistant.components.lock import LockEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.helpers.update_coordinator import CoordinatorEntity

from .const import DOMAIN
from .coordinator import LinkaCoordinator


async def async_setup_entry(
    hass: HomeAssistant, entry: ConfigEntry, async_add_entities: AddEntitiesCallback
) -> None:
    coordinator: LinkaCoordinator = hass.data[DOMAIN][entry.entry_id]
    async_add_entities([LinkaLockEntity(coordinator)])


class LinkaLockEntity(CoordinatorEntity[LinkaCoordinator], LockEntity):
    """The LINKA LEO2 as a Home Assistant lock."""

    _attr_has_entity_name = True
    _attr_name = None  # use the device name

    def __init__(self, coordinator: LinkaCoordinator) -> None:
        super().__init__(coordinator)
        self._attr_unique_id = f"{coordinator.mac}_lock"
        self._attr_device_info = DeviceInfo(
            identifiers={(DOMAIN, coordinator.mac)},
            name=coordinator.lock_name,
            manufacturer="LINKA",
            model="LEO2",
        )

    @property
    def is_locked(self) -> bool | None:
        status = self.coordinator.data
        return status.locked if status else None

    async def async_lock(self, **kwargs) -> None:
        await self.coordinator.async_do_lock()

    async def async_unlock(self, **kwargs) -> None:
        await self.coordinator.async_do_unlock()
