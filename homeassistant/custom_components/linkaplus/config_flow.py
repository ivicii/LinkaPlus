"""Config flow for LinkaPlus.

The lock's access keys come from a LinkaPlus app backup (.linkabackup) plus its
passphrase, or by pasting the AccessKeys JSON directly. Keys are resolved once here
and stored in the config entry, so the passphrase is not kept.
"""
from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Any

import voluptuous as vol

from homeassistant.config_entries import ConfigFlow, ConfigFlowResult
from homeassistant.helpers import config_validation as cv

from .backup import BackupError, keys_for
from .const import (
    CONF_BACKUP_PATH,
    CONF_KEYS,
    CONF_KEYS_JSON,
    CONF_MAC,
    CONF_NAME,
    CONF_PASSPHRASE,
    DOMAIN,
)
from .linka import select_command_key

_LOGGER = logging.getLogger(__name__)


def _normalise_mac(mac: str) -> str:
    mac = mac.strip().upper().replace("-", ":")
    parts = mac.split(":")
    if len(parts) != 6 or any(len(p) != 2 for p in parts):
        raise ValueError("MAC must look like FB:80:2B:7A:C2:EB")
    int(mac.replace(":", ""), 16)  # raises if non-hex
    return mac


class LinkaConfigFlow(ConfigFlow, domain=DOMAIN):
    """Handle a config flow for LinkaPlus."""

    VERSION = 1

    async def async_step_user(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        errors: dict[str, str] = {}

        if user_input is not None:
            try:
                mac = _normalise_mac(user_input[CONF_MAC])
            except ValueError:
                errors[CONF_MAC] = "invalid_mac"
            else:
                try:
                    keys = await self.hass.async_add_executor_job(
                        self._resolve_keys, user_input, mac
                    )
                    select_command_key(keys)  # validate a usable key exists
                except BackupError:
                    errors["base"] = "bad_backup"
                except (ValueError, KeyError, json.JSONDecodeError):
                    errors["base"] = "invalid_keys"
                except FileNotFoundError:
                    errors[CONF_BACKUP_PATH] = "file_not_found"
                else:
                    await self.async_set_unique_id(mac)
                    self._abort_if_unique_id_configured()
                    name = user_input.get(CONF_NAME) or "LINKA"
                    return self.async_create_entry(
                        title=name,
                        data={CONF_MAC: mac, CONF_NAME: name, CONF_KEYS: keys},
                    )

        schema = vol.Schema(
            {
                vol.Required(CONF_MAC): cv.string,
                vol.Optional(CONF_NAME, default="LINKA"): cv.string,
                vol.Optional(CONF_BACKUP_PATH): cv.string,
                vol.Optional(CONF_PASSPHRASE): cv.string,
                vol.Optional(CONF_KEYS_JSON): cv.string,
            }
        )
        return self.async_show_form(
            step_id="user", data_schema=schema, errors=errors
        )

    @staticmethod
    def _resolve_keys(user_input: dict[str, Any], mac: str) -> dict:
        """Blocking: read/decrypt the backup or parse pasted JSON -> AccessKeys dict."""
        backup_path = (user_input.get(CONF_BACKUP_PATH) or "").strip()
        keys_json = (user_input.get(CONF_KEYS_JSON) or "").strip()

        if backup_path:
            data = Path(backup_path).expanduser().read_bytes()
            return keys_for(data, user_input.get(CONF_PASSPHRASE) or "", mac)

        if keys_json:
            parsed = json.loads(keys_json)
            # Accept either a bare AccessKeys object or {serial: AccessKeys}.
            if any(k.startswith("access_key") or k.startswith("v2_") for k in parsed):
                return parsed
            # Mapping of serial -> keys: pick this MAC (or the only entry).
            for serial, ks in parsed.items():
                if serial.replace(":", "").lower() == mac.replace(":", "").lower():
                    return ks
            if len(parsed) == 1:
                return next(iter(parsed.values()))
            raise ValueError("keys JSON has no entry for this MAC")

        raise ValueError("provide a backup file or paste the keys JSON")
