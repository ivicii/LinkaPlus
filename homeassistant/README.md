# LinkaPlus voor Home Assistant

Een **lokale Bluetooth-integratie** voor het LINKA LEO2-slot. Home Assistant praat
rechtstreeks met het slot via Bluetooth — met exact hetzelfde protocol als de
LinkaPlus-app (AES-128-CBC, CRC-16, de live teller uit het `0x12`-contextframe).
**Geen LINKA-cloud, geen internet** nodig.

Je krijgt in HA:

- `lock.<naam>` — openen / sluiten en de status (op slot / open)
- `sensor.<naam>_battery` — batterijpercentage
- `sensor.<naam>_battery_voltage` — accuspanning (standaard uit)

---

## Wat je nodig hebt

1. **Home Assistant met de Bluetooth-integratie actief**, en een Bluetooth-bron
   **binnen bereik van de fiets**: de ingebouwde adapter van de HA-host, een USB-
   dongle, of een **ESPHome Bluetooth-proxy** bij de plek waar de fiets staat. De
   proxy is vaak de handigste: zet een ESP32 bij de voordeur/schuur.
2. **De toegangssleutels van je slot.** Die haal je uit de LinkaPlus-app:
   - App → je slot → **Back-up & herstel** → **Exporteer versleutelde back-up**.
   - Kies een wachtwoord en bewaar het `.linkabackup`-bestand.
   - Zet dat bestand op je HA-host, bijv. in `/config/` (`/config/linka.linkabackup`).

> Het slot is alleen via Bluetooth bereikbaar. Staat de fiets te ver weg, dan kan
> HA hem niet bedienen — net als de app. Voor tracking op afstand blijf je op de
> (cellulaire) recovery-functie in de app aangewezen; die zit hier bewust niet in.

---

## Installeren

**Handmatig**

1. Kopieer de map `custom_components/linkaplus` naar `…/config/custom_components/`
   (dus je krijgt `…/config/custom_components/linkaplus/__init__.py`).
2. Herstart Home Assistant.
3. **Instellingen → Apparaten & diensten → Integratie toevoegen → “LinkaPlus”.**
4. Vul in:
   - **MAC** van je slot, bijv. `FB:80:2B:7A:C2:EB`
   - **Pad naar het back-upbestand**, bijv. `/config/linka.linkabackup`
   - **Back-upwachtwoord**
   - (of plak in plaats daarvan de AccessKeys-JSON)

Daarna verschijnt het apparaat met de lock- en batterij-entiteiten.

**Via HACS** (optioneel): voeg deze repo toe als *custom repository* (categorie
*Integration*), installeer, herstart, en ga verder bij stap 3.

---

## Eerst testen (aanrader)

Test het protocol los van HA, op de HA-host of een Linux-machine met Bluetooth in de
buurt van de fiets:

```bash
pip install bleak cryptography
python tools/linka_cli.py --mac FB:80:2B:7A:C2:EB \
    --backup ~/linka.linkabackup --passphrase 'jouwwachtwoord' status
python tools/linka_cli.py --mac FB:80:2B:7A:C2:EB --backup ~/linka.linkabackup --passphrase 'jouwwachtwoord' unlock
python tools/linka_cli.py --mac FB:80:2B:7A:C2:EB --backup ~/linka.linkabackup --passphrase 'jouwwachtwoord' lock
```

Werkt dit, dan werkt de integratie ook.

---

## Voorbeeld-automatiseringen

Automatisch op slot als je wegrijdt (phone-tracker verlaat de zone):

```yaml
automation:
  - alias: Fiets automatisch op slot
    trigger:
      - platform: zone
        entity_id: person.ivo
        zone: zone.home
        event: leave
    action:
      - service: lock.lock
        target: { entity_id: lock.linka }
```

Melding bij lege accu:

```yaml
  - alias: Slot bijna leeg
    trigger:
      - platform: numeric_state
        entity_id: sensor.linka_battery
        below: 15
    action:
      - service: notify.mobile_app_ivo
        data: { message: "LINKA-slot nog {{ states('sensor.linka_battery') }}%." }
```

---

## Hoe het werkt (kort)

- **Connect-per-actie.** Elke opdracht of status-poll opent een korte BLE-verbinding
  via de HA-Bluetooth-stack (werkt dus ook via een ESPHome-proxy), stuurt het frame,
  en verbreekt weer. Reken op enkele seconden latency — prima voor een fietsslot.
- **Teller/anti-replay.** De AES-IV bevat de teller uit het `0x12`-contextframe van
  het slot. Elke teller wordt maar één keer gebruikt; de brug wacht op een verse
  teller voordat hij stuurt (net als de app), zodat de firmware niet in een
  bad-enc-lockout loopt.
- **Sleutelkeuze** volgt exact de volgorde van de app
  (`v2_access_key_admin_2` → … → `access_key_master`).

## Aandachtspunten

- **Één verbinding tegelijk.** Het slot accepteert één BLE-link. Houd de telefoon-app
  niet actief verbonden op het moment dat HA een commando stuurt. Door connect-per-actie
  is kort naast elkaar gebruiken meestal geen probleem.
- **Powermode.** De powermode die je in de app instelt bepaalt hoe lang het slot na
  gebruik Bluetooth-zichtbaar blijft. Een slot in diepe slaap reageert pas als het
  weer wakker is (beweging/knop).
- **Sleutels in HA.** De toegangssleutels staan na het instellen in de config-entry
  van HA (`.storage`). Dat is normaal voor HA-integraties; bescherm je HA-toegang.

---

*Created by Ivo Rooijackers (IvoRoo). Reverse-engineered protocol, voor je eigen slot.*
