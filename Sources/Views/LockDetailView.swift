import SwiftUI
import MapKit

struct LockDetailView: View {
    let lock: Lock
    @EnvironmentObject var session: SessionStore
    private let api = APIClient()

    @State private var activities: [LockActivity] = []
    @State private var busy = false
    @State private var error: String?

    @State private var sirenBusy = false
    @State private var sirenMessage: String?

    @State private var recoveryOn = false
    @State private var recoveryBusy = false
    @State private var recoveryMessage: String?
    @State private var confirmEnable = false
    @State private var routePoints: [CLLocationCoordinate2D] = []

    @State private var showBLE = false
    @State private var showBLEControl = false

    @StateObject private var ble = BLEController()
    @State private var bleStarted = false
    @State private var bleKeyError: String?
    @State private var showFinder = false
    @State private var movementAlarmOn = false
    @State private var pacCode = ""
    @State private var showStats = false
    @State private var showSharing = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showSettings = false
    @State private var showFullMap = false

    private var liveLocked: Bool { ble.liveLocked ?? lock.is_locked ?? true }

    /// The lock state we actually know from Bluetooth (nil = not yet known).
    private var knownLocked: Bool? { ble.liveLocked }

    private var statusText: String {
        guard let k = knownLocked else { return "Onbekend" }
        return k ? "Vergrendeld" : "Ontgrendeld"
    }
    private var statusIcon: String {
        guard let k = knownLocked else { return "questionmark.circle" }
        return k ? "lock.fill" : "lock.open.fill"
    }

    @State private var sim: SimStatus?
    @State private var simLoading = false
    @State private var simError: String?
    @State private var showRenew = false
    @State private var cards: [SavedCard] = []
    @State private var simFetchedAt: Date?

    @StateObject private var loc = LocationProvider()

    private var distanceText: String? {
        guard let c = coordinate, let me = loc.coordinate else { return nil }
        let a = CLLocation(latitude: c.latitude, longitude: c.longitude)
        let b = CLLocation(latitude: me.latitude, longitude: me.longitude)
        let meters = a.distance(from: b)
        if meters < 1000 { return String(format: "%.0f m", meters) }
        return String(format: "%.1f km", meters / 1000)
    }

    /// When the lock's GPS location was last updated (location_update_time).
    private var lastLocationDate: Date? { DateUtils.parseAny(lock.modifiedAt) }

    private var latestBattery: Int? {
        activities.compactMap { $0.batteryPercent }.first { $0 > 0 }
    }

    /// Best known coordinate: the lock's own, else the most recent located activity.
    private var coordinate: CLLocationCoordinate2D? {
        if lock.hasLocation, let lat = lock.latitude, let lon = lock.longitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        if let a = activities.first(where: { $0.hasLocation }), let lat = a.latitude, let lon = a.longitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return nil
    }

    var body: some View {
        List {
            mapSection

            bleControlSection

            soundSection
        }
        .navigationTitle(lock.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
        }
        .navigationDestination(isPresented: $showSettings) { settingsPage }
        .task {
            movementAlarmOn = LockPrefs.movementAlarm(serial: lock.serial_no)
            loc.start()
            await startBLE()
            await load()
            await syncRecoveryState()
            loadSim()
        }
        .onDisappear { ble.stop() }
        .refreshable {
            await load()
            await syncRecoveryState()
            loadSim()
        }
        .alert("Tracking-/recovery-modus aanzetten?", isPresented: $confirmEnable) {
            Button("Annuleer", role: .cancel) {}
            Button("Aanzetten", role: .destructive) { setRecovery(true) }
        } message: {
            Text("Dit is de anti-diefstalstand. Je slot gaat continu zijn GPS-positie doorsturen (meer batterij- en dataverbruik). Je kunt het weer uitzetten.")
        }
        .sheet(isPresented: $showFullMap) { fullMapSheet }
        .sheet(isPresented: $showBLE) {
            BLEDiagnosticsView(lockName: lock.displayName)
        }
        .sheet(isPresented: $showBLEControl) {
            if let serial = lock.serial_no {
                BLEControlView(serial: serial, lockName: lock.displayName)
                    .environmentObject(session)
            }
        }
        .sheet(isPresented: $showRenew) {
            if let serial = lock.serial_no {
                RenewDataPlanView(serial: serial, onActivated: { loadSim() })
                    .environmentObject(session)
            }
        }
        .sheet(isPresented: $showFinder) {
            FindLockView(ble: ble, onSiren: { if ble.ready { ble.sirenOn() } else { playSiren() } })
        }
        .sheet(isPresented: $showStats) {
            StatsView(activities: activities, lockName: lock.displayName)
        }
        .sheet(isPresented: $showSharing) {
            if let serial = lock.serial_no {
                SharingView(serial: serial).environmentObject(session)
            }
        }
        .alert("Slot hernoemen", isPresented: $showRename) {
            TextField("Naam", text: $renameText)
            Button("Annuleer", role: .cancel) {}
            Button("Opslaan") { renameLock() }
        } message: {
            Text("Nieuwe naam voor dit slot (in de cloud).")
        }
    }

    // MARK: - Secondary sections (settings)

    @ViewBuilder
    private var statusSection: some View {
        Section("Status") {
            statusRow(
                "Slot",
                value: statusText,
                systemImage: statusIcon
            )
            if let battery = latestBattery {
                HStack {
                    Label("Batterij", systemImage: batteryIcon(battery))
                    Spacer()
                    Text("\(battery)%" + (battery < 20 ? "  ⚠︎ laag" : ""))
                        .foregroundStyle(battery < 20 ? .red : .secondary)
                }
            }
            if let distanceText {
                statusRow("Afstand tot slot", value: distanceText, systemImage: "location.fill")
            }
            if let serial = lock.serial_no {
                statusRow("Serienummer", value: serial, systemImage: "number")
            }
            if let coordinate {
                statusRow(
                    "Coördinaten",
                    value: String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude),
                    systemImage: "mappin.and.ellipse"
                )
                Button {
                    openInMaps(coordinate)
                } label: {
                    Label("Open in Kaarten / routebeschrijving", systemImage: "car.fill")
                }
            }
        }
    }

    @ViewBuilder
    private var dataplanSection: some View {
            Section {
                if let sim {
                    statusRow("Verbonden", value: boolText(sim.connected),
                              systemImage: sim.connected == true ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    statusRow("Dataplan actief", value: boolText(sim.data_plan_enabled), systemImage: "simcard")
                    if let exp = DateUtils.parseAny(sim.activation_expiry) {
                        statusRow(sim.data_plan_enabled == true ? "Verlengt op" : "Verloopt op",
                                  value: DateUtils.absolute(exp), systemImage: "calendar")
                    }
                    if let used = sim.usage?.bytes {
                        statusRow("Verbruikt", value: mb(used), systemImage: "arrow.up.arrow.down")
                    }
                    if let incl = sim.initial_data {
                        statusRow("Inbegrepen", value: mb(incl), systemImage: "externaldrive")
                        statusRow("Resterend", value: mb(max(0, incl - (sim.usage?.bytes ?? 0))), systemImage: "gauge.medium")
                    }
                    if let c = sim.country, !c.isEmpty {
                        statusRow("Land", value: c, systemImage: "globe.europe.africa")
                    }
                    if let card = cards.first?.card {
                        statusRow("Kaart", value: cardText(card), systemImage: "creditcard")
                    }
                    if sim.payment_requires_attention == true {
                        Label("Betaling vereist", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    Button { loadSim() } label: {
                        Label("Vernieuwen", systemImage: "arrow.clockwise")
                    }
                } else {
                    Button(action: loadSim) {
                        HStack {
                            if simLoading { ProgressView() }
                            Label("Dataplan-status ophalen", systemImage: "simcard")
                        }
                    }
                    .disabled(simLoading || lock.serial_no == nil)
                }
                if let simError {
                    Text(simError).font(.caption).foregroundStyle(.secondary)
                }
                if let sim {
                    if sim.data_plan_enabled == true {
                        Button(role: .destructive) { setDataPlan(false) } label: {
                            Label("Auto-verlengen uitzetten", systemImage: "xmark.circle")
                        }
                    } else {
                        Button { setDataPlan(true) } label: {
                            Label("Auto-verlengen aanzetten (opgeslagen kaart)", systemImage: "checkmark.circle")
                        }
                    }
                }
                if lock.serial_no != nil {
                    Button { showRenew = true } label: {
                        Label("Dataplan verlengen / kaart wijzigen", systemImage: "creditcard")
                    }
                }
            } header: {
                Text("Dataplan & verbruik")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let t = simFetchedAt {
                        Label("Status opgehaald om \(DateUtils.timeHM(t)) · tik Vernieuwen voor live",
                              systemImage: "clock")
                    }
                    Text("Haalt de cellulaire status op (zelfde call als de officiële app gebruikt). De teller kan iets achterlopen op de provider. Betalen gebeurt apart; dit vraagt alleen de status op.")
                }
            }
    }

    @ViewBuilder
    private var slotinstellingenSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { movementAlarmOn },
                set: { on in
                    movementAlarmOn = on
                    LockPrefs.setMovementAlarm(on, serial: lock.serial_no)
                    if ble.ready { ble.setMovementAlarm(on) }
                }
            )) {
                Label("Beweeg-alarm", systemImage: "bell.badge")
            }
            .disabled(!ble.ready)

            HStack {
                Label("PAC-code", systemImage: "number.square")
                Spacer()
                TextField("4 cijfers", text: $pacCode)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
            }
            Button {
                if let code = Int(pacCode) { ble.setPAC(code) }
            } label: { Label("PAC-code instellen", systemImage: "checkmark.circle") }
                .disabled(pacCode.count < 4)
        } header: {
            Text("Slotinstellingen (Bluetooth)")
        } footer: {
            Text("Beweeg-alarm laat het slot waarschuwen bij beweging. De PAC-code is de tapcode om zonder telefoon te openen.")
        }
    }

    @ViewBuilder
    private var trackingSection: some View {
        Section {
            if recoveryOn {
                Button(role: .destructive) { setRecovery(false) } label: {
                    HStack {
                        if recoveryBusy { ProgressView() }
                        Label("Stop tracking (recovery)", systemImage: "stop.circle.fill")
                    }
                }
                .disabled(recoveryBusy)
                Button {
                    Task { await refreshRoute() }
                } label: {
                    Label("Route verversen (\(routePoints.count) punten)", systemImage: "arrow.clockwise")
                }
            } else {
                Button { confirmEnable = true } label: {
                    HStack {
                        if recoveryBusy { ProgressView() }
                        Label("Zet in tracking-/recovery-modus", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
                .disabled(recoveryBusy || lock.serial_no == nil)
            }
            if let recoveryMessage {
                Text(recoveryMessage).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Live tracking")
        } footer: {
            Text("Op de LEO armt de anti-diefstal/tracking meestal vanzelf: sluit het slot, dan houdt het bij beweging zelf de GPS bij en mailt je. Handmatig starten kan \"not currently active\" geven als er geen actieve trackingsessie is. Vereist resterende data in je dataplan.")
        }
    }

    @ViewBuilder
    private var beheerSection: some View {
        Section("Beheer") {
            Button { showStats = true } label: { Label("Statistieken", systemImage: "chart.bar.fill") }
            Button { showSharing = true } label: { Label("Delen & toegang", systemImage: "person.2.fill") }
            Button { renameText = lock.displayName; showRename = true } label: { Label("Hernoemen", systemImage: "pencil") }
        }
    }

    @ViewBuilder
    private var geavanceerdSection: some View {
        Section {
            Button {
                showBLEControl = true
            } label: {
                Label("Geavanceerde bediening & auto-test", systemImage: "slider.horizontal.3")
            }
            Button {
                showBLE = true
            } label: {
                Label("Bluetooth-diagnose", systemImage: "dot.radiowaves.right")
            }
        } header: {
            Text("Geavanceerd")
        } footer: {
            Text("Alleen nodig als de normale Open/Sluit niet werkt: handmatige sleutel/kanaal/teller en het GATT-profiel.")
        }
    }

    @ViewBuilder
    private var activiteitenSection: some View {
        Section("Activiteiten") {
            if busy && activities.isEmpty {
                HStack { ProgressView(); Text("Laden…").foregroundStyle(.secondary) }
            } else if activities.isEmpty {
                Text(error ?? "Nog geen activiteiten.").foregroundStyle(.secondary)
            } else {
                ForEach(activities) { ActivityRow(activity: $0) }
            }
        }
    }

    // MARK: - Main sections

    @ViewBuilder
    private var mapSection: some View {
        Section {
            Button { showFullMap = true } label: {
                mapView
                    .frame(height: 220)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.primary)
                            .padding(8)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(10)
                    }
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets())
        } footer: {
            if let d = lastLocationDate {
                Label("Locatie bijgewerkt: \(DateUtils.absoluteWithRelative(d)) · tik om te vergroten",
                      systemImage: "clock.arrow.circlepath")
            } else {
                Text("Tijd van laatste locatie onbekend. Tik op de kaart om te vergroten.")
            }
        }
    }

    @ViewBuilder
    private var soundSection: some View {
        Section {
            if ble.ready {
                Button { Haptic.tap(); ble.sirenOn() } label: {
                    Label("Geluid afspelen", systemImage: "speaker.wave.3.fill")
                }
                Button(role: .destructive) { ble.sirenOff() } label: {
                    Label("Geluid uit", systemImage: "speaker.slash.fill")
                }
            } else {
                Label("Wacht op Bluetooth-verbinding…", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(.secondary)
                if ble.state == "verbroken" || ble.state == "gestopt" {
                    Button { ble.start() } label: {
                        Label("Opnieuw verbinden", systemImage: "arrow.clockwise")
                    }
                }
                Button(action: playSiren) {
                    HStack {
                        if sirenBusy { ProgressView() }
                        Label("Toch via cloud proberen", systemImage: "cloud")
                    }
                }
                .disabled(sirenBusy || lock.serial_no == nil)
                if let sirenMessage { Text(sirenMessage).font(.caption).foregroundStyle(.secondary) }
            }
        } header: {
            Text("Geluid")
        } footer: {
            Text(ble.ready
                 ? "Via Bluetooth — werkt lokaal, ook zonder dataplan."
                 : "Geluid afspelen werkt betrouwbaar via Bluetooth (dichtbij het slot). De cloud-variant lukt alleen als het slot net online is, anders geeft de server \"not currently active\".")
        }
    }

    @ViewBuilder
    private var fullMapSheet: some View {
        NavigationStack {
            Group {
                if let coordinate {
                    LockMapView(coordinate: coordinate, title: lock.displayName, route: routePoints)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "mappin.slash").font(.largeTitle)
                        Text("Geen locatie bekend voor dit slot").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(lock.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Sluit") { showFullMap = false } }
                ToolbarItem(placement: .confirmationAction) {
                    if let coordinate {
                        Button { openInMaps(coordinate) } label: { Label("Route", systemImage: "car.fill") }
                    }
                }
            }
        }
    }

    // MARK: - Settings page

    private var settingsPage: some View {
        List {
            statusSection
            dataplanSection
            if ble.ready { slotinstellingenSection }
            trackingSection
            beheerSection
            geavanceerdSection
            activiteitenSection
            Section {
                EmptyView()
            } footer: {
                VStack(spacing: 3) {
                    Text("LinkaPlus v1.0")
                    Text("Created by Ivo Rooijackers (IvoRoo)")
                }
                .font(.caption)
                .frame(maxWidth: .infinity)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            }
        }
        .navigationTitle("Instellingen")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Bluetooth control card

    private var bleStatusText: String {
        if bleKeyError != nil { return "Sleutel niet geladen" }
        switch ble.state {
        case "scannen": return "Zoeken naar slot…"
        case "verbinden", "services": return "Verbinden…"
        case "klaar": return ble.ready ? "Verbonden" : "Verbonden"
        case "verbroken", "gestopt": return "Niet verbonden"
        default: return ble.ready ? "Verbonden" : "Verbinden…"
        }
    }

    // MARK: Hero control

    /// Colour reflects the KNOWN state: green = vergrendeld, orange = ontgrendeld,
    /// blue = nog onbekend (tot het slot of een actie de stand bevestigt).
    private var heroColor: Color {
        guard let k = knownLocked else { return Theme.accent }
        return k ? Theme.locked : Theme.open
    }

    private var heroIcon: String {
        guard let k = knownLocked else { return "questionmark" }
        return k ? "lock.fill" : "lock.open.fill"
    }

    private var heroSubtitle: String {
        if !ble.ready { return bleStatusText }
        guard let k = knownLocked else { return "Status onbekend" }
        return k ? "Tik om te openen" : "Tik om te sluiten"
    }

    private var heroControl: some View {
        VStack(spacing: 18) {
            // Connection pill
            HStack(spacing: 7) {
                Circle()
                    .fill(ble.ready ? Theme.locked : Color.orange)
                    .frame(width: 9, height: 9)
                Text(bleStatusText)
                    .font(.subheadline.weight(.semibold))
                if !ble.ready && bleKeyError == nil {
                    ProgressView().scaleEffect(0.7)
                }
            }
            .foregroundStyle(.secondary)

            // Big tactile lock button
            Button {
                Haptic.tap()
                guard let locked = knownLocked else {
                    // State unknown → nudge the user to the explicit buttons.
                    Haptic.warning()
                    return
                }
                ble.channel = 0; ble.counterOffset = 0
                if locked { ble.unlock() } else { ble.lock() }
            } label: {
                ZStack {
                    Circle()
                        .fill(Theme.grad(heroColor))
                        .frame(width: 184, height: 184)
                        .shadow(color: heroColor.opacity(0.45), radius: 22, y: 10)
                    Circle()
                        .stroke(Color.white.opacity(0.22), lineWidth: 2)
                        .frame(width: 184, height: 184)
                    VStack(spacing: 10) {
                        Image(systemName: heroIcon)
                            .font(.system(size: 58, weight: .bold))
                        Text(heroSubtitle)
                            .font(.footnote.weight(.semibold))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white)
                }
            }
            .buttonStyle(PressableStyle())
            .disabled(!ble.ready)
            .opacity(ble.ready ? 1 : 0.55)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: knownLocked)

            // Quick stats
            HStack(spacing: 22) {
                heroStat(statusText, statusIcon, heroColor)
                if let b = latestBattery {
                    heroStat("\(b)%", batteryIcon(b), b < 20 ? Theme.danger : .secondary)
                }
                if let d = distanceText {
                    heroStat(d, "location.fill", .secondary)
                }
            }
            .font(.caption)

            if knownLocked == nil && ble.ready {
                Text("Kies hieronder Openen of Sluiten — de stand wordt daarna automatisch bijgehouden.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            commandResultRow
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private func heroStat(_ text: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.title3).foregroundStyle(color)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 56)
    }

    @ViewBuilder
    private var bleControlSection: some View {
        Section {
            heroControl
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            HStack(spacing: 12) {
                Button { Haptic.tap(.light); ble.channel = 0; ble.counterOffset = 0; ble.unlock() } label: {
                    Label("Openen", systemImage: "lock.open.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.open)
                Button { Haptic.tap(.light); ble.channel = 0; ble.counterOffset = 0; ble.lock() } label: {
                    Label("Sluiten", systemImage: "lock.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.locked)
            }
            .controlSize(.large)
            .disabled(!ble.ready)

            if ble.ready {
                Button { showFinder = true } label: {
                    Label("Zoek je slot (signaalsterkte)", systemImage: "dot.radiowaves.left.and.right")
                }
            }
            if ble.state == "verbroken" || ble.state == "gestopt" {
                Button { ble.start() } label: {
                    Label("Opnieuw verbinden", systemImage: "arrow.clockwise")
                }
            }
            if let e = bleKeyError {
                Text(e).font(.caption).foregroundStyle(.red)
            }
        } footer: {
            Text("Verbindt automatisch als je dichtbij bent. Houd het slot stil bij het sluiten.")
        }
    }

    @ViewBuilder
    private var commandResultRow: some View {
        switch ble.commandResult {
        case .success(let n):
            Label("\(n) gelukt", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
        case .rejected:
            Label("Geweigerd — probeer opnieuw", systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.callout)
        case .blocked:
            Label("⚠︎ Niet gelukt — beweging of blokkade gedetecteerd. Houd het slot stil en probeer opnieuw.",
                  systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
        case .timeout:
            Label("Geen reactie van het slot — opnieuw proberen.", systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(.secondary).font(.callout)
        case .none:
            if ble.lastEvent != "–" {
                Text(ble.lastEvent).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func startBLE() async {
        guard let serial = lock.serial_no else { return }
        // On reappear the view (and its keys) may be reused → just re-scan.
        if bleStarted {
            if !ble.ready { ble.start() }
            return
        }
        bleStarted = true
        bleKeyError = nil
        var keys: AccessKeys?
        do {
            // Fresh from the cloud, and cache it for offline use.
            let status = try await api.checkKeyStatus(serial: serial, auth: session.identity())
            keys = status.key
            if let k = keys, k.commandKey != nil { LockCache.saveKeys(k, serial: serial) }
        } catch {
            // Cloud unavailable → use the cached key so Bluetooth still works.
            keys = LockCache.loadKeys(serial: serial)
        }
        guard let k = keys, k.commandKey != nil else {
            bleKeyError = "Geen sleutel gevonden (cloud onbereikbaar en geen offline cache)."
            return
        }
        ble.configure(keys: k, serial: serial, nameHint: lock.displayName)
        ble.start()
    }

    @ViewBuilder
    private var mapView: some View {
        if let coordinate {
            LockMapView(coordinate: coordinate, title: lock.displayName, route: routePoints)
        } else {
            ZStack {
                Color(.secondarySystemBackground)
                VStack(spacing: 6) {
                    Image(systemName: "mappin.slash").font(.title)
                    Text("Geen locatie bekend voor dit slot").font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statusRow(_ title: String, value: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func batteryIcon(_ pct: Int) -> String {
        switch pct {
        case ..<15: return "battery.0"
        case ..<40: return "battery.25"
        case ..<70: return "battery.50"
        case ..<90: return "battery.75"
        default: return "battery.100"
        }
    }

    private func openInMaps(_ c: CLLocationCoordinate2D) {
        let place = MKPlacemark(coordinate: c)
        let item = MKMapItem(placemark: place)
        item.name = lock.displayName
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    private func boolText(_ b: Bool?) -> String { b == true ? "Ja" : (b == false ? "Nee" : "–") }

    private func cardText(_ c: SavedCard.Card) -> String {
        let brand = (c.brand ?? "Kaart").capitalized
        let last4 = c.last4 ?? "----"
        var s = "\(brand) •••• \(last4)"
        if let m = c.exp_month, let y = c.exp_year {
            s += String(format: "  %02d/%02d", m, y % 100)
        }
        return s
    }

    private func mb(_ bytes: Int) -> String {
        let m = Double(bytes) / 1_000_000
        if m >= 1 { return String(format: "%.1f MB", m) }
        return String(format: "%.0f KB", Double(bytes) / 1000)
    }

    /// Turn the data-plan auto-renew on/off (enable_data_plan). "Off" is the
    /// equivalent of the official app's "Cancel Renewal".
    private func setDataPlan(_ enabled: Bool) {
        guard let serial = lock.serial_no else { return }
        simLoading = true; simError = nil
        Task {
            do {
                try await api.enableDataPlan(serial: serial, enabled: enabled, auth: session.identity())
            } catch {
                simError = (error as? LocalizedError)?.errorDescription ?? "Mislukt: \(error)"
            }
            loadSim()   // refresh status (manages simLoading)
        }
    }

    private func loadSim() {
        guard let serial = lock.serial_no else { return }
        simLoading = true; simError = nil
        Task {
            // Prefer the phone's location; fall back to the lock's own.
            let c = loc.coordinate ?? coordinate
            let lat = c?.latitude ?? 0
            let lng = c?.longitude ?? 0
            do {
                sim = try await api.simStatus(serial: serial, lat: lat, lng: lng, auth: session.identity())
                simFetchedAt = Date()
            } catch {
                simError = (error as? LocalizedError)?.errorDescription ?? "Mislukt: \(error)"
            }
            cards = (try? await api.getCards(auth: session.identity())) ?? cards
            simLoading = false
        }
    }

    private func renameLock() {
        guard let serial = lock.serial_no, !renameText.isEmpty else { return }
        Task {
            try? await api.renameLock(name: renameText, serial: serial,
                                      isLocked: liveLocked, lockType: "original", auth: session.identity())
        }
    }

    private func playSiren() {
        guard let serial = lock.serial_no else { return }
        sirenBusy = true
        sirenMessage = nil
        Task {
            do {
                try await api.activateSiren(serial: serial, auth: session.identity())
                sirenMessage = "Sirene geactiveerd — luister naar je slot."
            } catch {
                let raw = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                if raw.localizedCaseInsensitiveContains("not currently")
                    || raw.localizedCaseInsensitiveContains("not active") {
                    sirenMessage = "Het slot heeft nu geen actieve sessie met de server (\"\(raw)\"). De LEO slaapt om batterij te sparen en meldt zich maar af en toe — probeer het zo nog eens, of wek het slot door het te bewegen. Vlakbij werkt de Bluetooth-sirene altijd."
                } else {
                    sirenMessage = "Mislukt: \(raw)"
                }
            }
            sirenBusy = false
        }
    }

    private func setRecovery(_ enable: Bool) {
        guard let serial = lock.serial_no else { return }
        recoveryBusy = true; recoveryMessage = nil
        Task {
            do {
                try await api.setRecoveryMode(serial: serial, enabled: enable, auth: session.identity())
                recoveryOn = enable
                if enable {
                    recoveryMessage = "Tracking gestart. Het kan even duren voor de eerste GPS-punten binnen zijn — tik op 'Route verversen'."
                    await refreshRoute()
                } else {
                    recoveryMessage = "Tracking gestopt."
                    routePoints = []
                }
            } catch {
                let raw = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                if raw.localizedCaseInsensitiveContains("not currently")
                    || raw.localizedCaseInsensitiveContains("not active") {
                    recoveryMessage = "De server kan tracking nu niet handmatig starten (\"\(raw)\"). Op de LEO armt tracking vanzelf: sluit het slot, dan houdt het bij beweging zelf de GPS bij en mailt je. Zorg dat er nog data over is in je dataplan."
                } else {
                    recoveryMessage = "Mislukt: \(raw)"
                }
            }
            recoveryBusy = false
        }
    }

    /// Reads whether tracking is currently active (current_tracking succeeds
    /// only in tracking mode) and loads the route if so.
    private func syncRecoveryState() async {
        guard lock.serial_no != nil else { return }
        if let pts = try? await trackingCoords() {
            routePoints = pts
            recoveryOn = true
        } else {
            recoveryOn = false
        }
    }

    private func refreshRoute() async {
        if let pts = try? await trackingCoords() { routePoints = pts }
    }

    private func trackingCoords() async throws -> [CLLocationCoordinate2D] {
        guard let serial = lock.serial_no else { return [] }
        let pts = try await api.currentTracking(serial: serial, auth: session.identity())
        return pts
            .filter { $0.hasLocation }
            .sorted { (DateUtils.parseAny($0.timestamp) ?? .distantPast) < (DateUtils.parseAny($1.timestamp) ?? .distantPast) }
            .compactMap { a in
                guard let la = a.latitude, let lo = a.longitude else { return nil }
                return CLLocationCoordinate2D(latitude: la, longitude: lo)
            }
    }

    private func load() async {
        guard let serial = lock.serial_no else { return }
        busy = true; error = nil
        do {
            let result = try await api.fetchActivities(serial: serial, auth: session.identity())
            activities = result.sorted {
                let d0 = DateUtils.parseAny($0.timestamp) ?? DateUtils.parseISO($0.createdAt) ?? .distantPast
                let d1 = DateUtils.parseAny($1.timestamp) ?? DateUtils.parseISO($1.createdAt) ?? .distantPast
                return d0 > d1
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        busy = false
    }
}

struct ActivityRow: View {
    let activity: LockActivity

    private var timeText: String? {
        if let d = DateUtils.parseAny(activity.timestamp) ?? DateUtils.parseISO(activity.createdAt) {
            return DateUtils.absolute(d)
        }
        return activity.timestamp ?? activity.createdAt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(activity.msg_title ?? "Activiteit").font(.subheadline.bold())
                Spacer()
                if let b = activity.batteryPercent, b > 0 {
                    Text("\(b)%").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let desc = activity.msg_desc, !desc.isEmpty {
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
            if let timeText {
                Text(timeText).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
