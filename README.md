# LinkaPlus

Een eigen iOS-client voor je LINKA-slot, met de functie die de officiële app mist:
**de locatie van je slot op een kaart**. Gebouwd met SwiftUI, praat met de bestaande
LINKA-cloud (`https://app3.linkalock.com`) via je eigen account.

> Created by Ivo Rooijackers (IvoRoo)

## Wat zit erin (Fase 1)

- Inloggen met je bestaande LINKA-account (e-mail + logincode, net als de echte app).
- Overzicht van je sloten met vergrendeld/ontgrendeld-status.
- **Slotlocatie op een kaart** + knop "Open in Kaarten" voor een routebeschrijving.
- Batterijpercentage en activiteitenhistorie per slot.
- Veilige opslag van je token in de iOS Keychain.

Bluetooth openen/sluiten (Fase 2) zit er nog **niet** in — de CoreBluetooth-basis
(`Sources/BLEManager.swift`) staat al klaar met `TODO`-haken.

---

## Zonder Mac bouwen en op je iPhone zetten

Je hebt **geen Mac** nodig. GitHub bouwt de app voor je in de cloud; daarna zet je
'm met **Sideloadly** op je Windows-PC op je iPhone (gratis Apple-ID).

### Stap 1 — Zet de code op GitHub

1. Maak een gratis account op https://github.com en maak een **nieuwe (private) repository** aan, bijv. `LinkaPlus`.
2. Upload de inhoud van deze map naar die repo (via de website: *Add file → Upload files*,
   of met `git`). Let op dat de map `.github/workflows/build.yml` meekomt.

### Stap 2 — Laat GitHub de IPA bouwen

1. Ga in je repo naar het tabblad **Actions**.
2. Kies de workflow **"Build unsigned IPA"** → **Run workflow** (of hij start vanzelf bij een push naar `main`).
3. Wacht ~3–5 min. Open de voltooide run en download onderaan het artifact
   **`LinkaPlus-unsigned-ipa`**. Pak de zip uit → je hebt `LinkaPlus.ipa`.

Deze IPA is **niet ondertekend** — dat doet Sideloadly in de volgende stap met jouw Apple-ID.

### Stap 3 — Installeren met Sideloadly (Windows)

1. Installeer **iTunes** (van apple.com, niet de Microsoft Store-versie) en **Sideloadly** (https://sideloadly.io).
2. Verbind je iPhone met een USB-kabel en vertrouw de computer.
3. Open Sideloadly, sleep `LinkaPlus.ipa` erin, vul je **Apple-ID** in, klik **Start**.
   Vul het Apple-ID-wachtwoord in (gebruik evt. een app-specifiek wachtwoord).
4. Op je iPhone: **Instellingen → Algemeen → VPN en apparaatbeheer** → vertrouw je
   ontwikkelaarsprofiel. Start daarna LinkaPlus.

> **Gratis Apple-ID:** de app werkt **7 dagen**, daarna herhaal je stap 3 (opnieuw
> installeren ververst de termijn; je gegevens blijven in de Keychain staan).
> Een Apple Developer-account (€99/jr) verlengt dit naar een jaar.

### Lokaal bouwen (optioneel, mét Mac)

```bash
brew install xcodegen
xcodegen generate
open LinkaPlus.xcodeproj
```

## Projectstructuur

```
project.yml                 XcodeGen-projectdefinitie (plist-keys, bundle-id, scheme)
.github/workflows/build.yml GitHub Actions: bouwt de unsigned IPA
Sources/
  LinkaPlusApp.swift        App-entry + routing login ↔ sloten
  Models.swift              API-datamodellen (Lock, LockActivity, login)
  APIClient.swift           Alle LINKA-cloudcalls (async/await)
  SessionStore.swift        Auth-state + device-identiteit
  Keychain.swift            Veilige tokenopslag
  BLEManager.swift          CoreBluetooth-basis (Fase 2)
  Views/                    Login, slotlijst, slotdetail (kaart/batterij/activiteiten)
```

## Opmerkingen

- Dit is een persoonlijke client voor je **eigen** account en slot; er zit geen LINKA-
  servercode in, alleen de publieke app-API die je telefoon toch al gebruikt.
- De bundle-identifier is `com.ivoroo.linkaplus`. Pas 'm in `project.yml` aan als je wilt.
