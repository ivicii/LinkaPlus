"""Sensor platform for LinkaPlus (battery level + voltage)."""
from __future__ import annotations

from homeassistant.components.sensor import (
    SensorDeviceClass,
    SensorEntity,
    SensorStateClass,
)
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import PERCENTAGE, UnitOfElectricPotential
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
    async_add_entities(
        [LinkaBatterySensor(coordinator), LinkaVoltageSensor(coordinator)]
    )


class _Base(CoordinatorEntity[LinkaCoordinator], SensorEntity):
    _attr_has_entity_name = True

    def __init__(self, coordinator: LinkaCoordinator) -> None:
        super().__init__(coordinator)
        self._attr_device_info = DeviceInfo(identifiers={(DOMAIN, coordinator.mac)})


class LinkaBatterySensor(_Base):
    _attr_name = "Battery"
    _attr_device_class = SensorDeviceClass.BATTERY
    _attr_native_unit_of_measurement = PERCENTAGE
    _attr_state_class = SensorStateClass.MEASUREMENT

    def __init__(self, coordinator: LinkaCoordinator) -> None:
        super().__init__(coordinator)
        self._attr_unique_id = f"{coordinator.mac}_battery"

    @property
    def native_value(self) -> int | None:
        status = self.coordinator.data
        return status.battery if status else None


class LinkaVoltageSensor(_Base):
    _attr_name = "Battery voltage"
    _attr_device_class = SensorDeviceClass.VOLTAGE
    _attr_native_unit_of_measurement = UnitOfElectricPotential.VOLT
    _attr_state_class = SensorStateClass.MEASUREMENT
    _attr_entity_registry_enabled_default = False

    def __init__(self, coordinator: LinkaCoordinator) -> None:
        super().__init__(coordinator)
        self._attr_unique_id = f"{coordinator.mac}_voltage"

    @property
    def native_value(self) -> float | None:
        status = self.coordinator.data
        return status.voltage if status else None
