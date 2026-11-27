import SwiftUI
import MapKit
import UIKit

struct LockDetailView: View {
    let lock: Lock
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var router: AppRouter
    private let api = APIClient()

    @State private var activities: [LockActivity] = []
    @State private var busy = false
    @State private var error: String?

    @State private var sirenBusy = false
    @State private var sirenMessage: String?

    @State private var routePoints: [CLLocationCoordinate2D] = []

    @State private var showBLE = false
    @State private var showBLEControl = false

    @ObservedObject private var ble = BLEController.shared
    @State private var bleStarted = false
    @State private var bleKeyError: String?
    @State private var showFinder = false
    @State private var showStats = false
    @State private var showSharing = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var renameError: String?
    /// Name after a rename in this session (the `lock` value itself is immutable).
    @State private var customName: String?
    private var displayName: String { customName ?? lock.displayName }
    @State private var showSettings = false
    @State private var showFullMap = false
    @State private var showParkedSheet = false
    @State private var showFirmware = false
    @State private var heroLocked = true
    @State private var didInitialLoad = false
    @State private var localActs: [LockActivity] = []
    @State private var lastKnownLock: Bool?
    @State private var parked: ParkedStore.Spot?

    /// Cloud feed + locally recorded events (cloud is rarely updated now).
    private var allActivities: [LockActivity] {
        (activities + localActs).sorted {
            let d0 = DateUtils.parseAny($0.timestamp) ?? DateUtils.parseISO($0.createdAt) ?? .distantPast
            let d1 = DateUtils.parseAny($1.timestamp) ?? DateUtils.parseISO($1.createdAt) ?? .distantPast
            return d0 > d1
        }
    }

    @State private var lastStatePing = Date.distantPast
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
        return DistanceText.format(meters: a.distance(from: b))
    }

    /// When the lock's GPS location was last updated (location_update_time).
    private var lastLocationDate: Date? { DateUtils.parseAny(lock.modifiedAt) }

    /// Live BLE battery (works without cloud). There is NO cloud battery feed, so
    /// when we're not connected we show the last reading seen over Bluetooth, with
    /// its age — never a pretend "online" value.
    private var liveBattery: Int? { ble.batteryLevelBLE }
    private var lastBatterySample: (pct: Int, date: Date)? {
        LocalActivityLog.lastBattery(serial: lock.serial_no)
    }
    private var latestBattery: Int? { liveBattery ?? lastBatterySample?.pct }

    private func agoText(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "nl_NL")
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    private func batteryCaption(low: Bool) -> String {
        let prefix = ble.isChargingBLE ? "opladen · " : (low ? "laag · " : "")
        if liveBattery != nil { return prefix + "live via Bluetooth" }
        if let s = lastBatterySample { return prefix + "laatste meting · \(agoText(s.date))" }
        return prefix + "via Bluetooth"
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
        GeometryReader { geo in
            // Shrink the lock on short screens. The map always stays: the screen
            // scrolls, and the map is the only way to the full-screen map.
            let lockSize = min(230, max(140, geo.size.height - 470))
            // Fills the screen when everything fits; scrolls when it doesn't (large
            // text, landscape, small phones) — and gives pull-to-refresh.
            ScrollView {
                VStack(spacing: 0) {
                    compactMap
                    if let parked { parkedCard(parked) }
                    Spacer(minLength: 10)
                    heroControl(size: lockSize)
                    Spacer(minLength: 10)
                    mainButtons
                }
                .frame(maxWidth: 560, minHeight: geo.size.height, alignment: .top)   // iPad: no 1000 pt wide buttons
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .linkaScreen().navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Instellingen")
            }
        }
        .navigationDestination(isPresented: $showSettings) { settingsPage }
        .task {
            // Returning from a pushed settings page must not reload everything.
            if didInitialLoad { await startBLE(); return }
            didInitialLoad = true
            localActs = LocalActivityLog.load(serial: lock.serial_no)
            parked = ParkedStore.load(serial: lock.serial_no)
            ble.proximityUnlockEnabled = LockPrefs.bool("proximityUnlock", serial: lock.serial_no)
            LockNotifier.shared.requestAuth()
            // Only trust the controller's live state when it belongs to this lock.
            // Seeding lastKnownLock makes the first open/close after entering the
            // screen count as a real transition (activity log + parked spot).
            let mine = lock.serial_no.map { ble.currentSerial?.caseInsensitiveCompare($0) == .orderedSame } ?? false
            lastKnownLock = mine ? ble.liveLocked : nil
            heroLocked = lastKnownLock ?? lock.is_locked ?? true
            loc.start()
            await startBLE()
            await load()
            await syncRecoveryState()
            loadSim()
        }
        .onChange(of: ble.liveLocked) { v in
            guard let v else { return }
            heroLocked = v
            maybeAutoUnlock()   // a pending toggle was waiting for this state
            if lastKnownLock != nil, lastKnownLock != v {
                UIAccessibility.post(notification: .announcement, argument: v ? "Slot vergrendeld" : "Slot ontgrendeld")
            }
            // Record real transitions (not the first state seen after connecting).
            if let prev = lastKnownLock, prev != v {
                LocalActivityLog.record(kind: v ? "close" : "open", battery: ble.batteryLevelBLE, serial: lock.serial_no)
                localActs = LocalActivityLog.load(serial: lock.serial_no)
                // Lock just closed → remember where the bike is parked (phone's GPS).
                // Only a fresh fix: after returning to the app the last known
                // position can still be the previous place.
                if v, let here = loc.coordinate, let fix = loc.fixDate, Date().timeIntervalSince(fix) < 120 {
                    ParkedStore.save(here, accuracy: loc.accuracy, serial: lock.serial_no)
                    parked = ParkedStore.load(serial: lock.serial_no)
                }
            }
            lastKnownLock = v
            maybeAutoUnlock()
        }
        .onChange(of: ble.batteryLevelBLE) { b in
            guard let b else { return }
            let last = LocalActivityLog.lastTimestamp(kind: "battery", serial: lock.serial_no)
            if last == nil || Date().timeIntervalSince(last!) > 1800 {
                LocalActivityLog.record(kind: "battery", battery: b, serial: lock.serial_no)
                localActs = LocalActivityLog.load(serial: lock.serial_no)
            }
        }
        .onChange(of: ble.commandResult) { r in
            // Command didn't take → show the state the lock itself last reported.
            // (Never guess: with an unknown state the graphic stays as it was.)
            switch r {
            case .rejected, .blocked, .timeout:
                if let known = knownLocked { heroLocked = known }
                Haptic.warning()
                UIAccessibility.post(notification: .announcement, argument: "Niet gelukt, probeer opnieuw")
            default: break
            }
            // Don't leave a stale "gelukt" row on screen.
            if let r {
                Task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if ble.commandResult == r { ble.clearCommandResult() }
                }
            }
        }
        .onChange(of: ble.ctxCounter) { _ in maybeAutoUnlock() }
        .onChange(of: router.requestSeq) { _ in maybeAutoUnlock() }
        .refreshable {
            await load()
            await syncRecoveryState()
            loadSim()
        }
        .alert("Sirene", isPresented: Binding(get: { sirenMessage != nil },
                                                set: { if !$0 { sirenMessage = nil } })) {
            Button("OK", role: .cancel) { sirenMessage = nil }
        } message: {
            Text(sirenMessage ?? "")
        }
        .sheet(isPresented: $showFullMap) { fullMapSheet }
        .sheet(isPresented: $showParkedSheet) { parkedSheet }
        .sheet(isPresented: $showFirmware) {
            FirmwareView(ble: ble).environmentObject(session)
        }
        .sheet(isPresented: $showBLE) {
            BLEDiagnosticsView(lockName: displayName)
        }
        .sheet(isPresented: $showBLEControl) {
            if let serial = lock.serial_no {
                BLEControlView(serial: serial, lockName: displayName)
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
            StatsView(activities: allActivities, lockName: displayName)
        }
        .sheet(isPresented: $showSharing) {
            if let serial = lock.serial_no {
                SharingView(serial: serial).environmentObject(session)
            }
        }
    }

    // MARK: - Secondary sections (settings)

    /// Which flags warrant a red/orange highlight (alerts & security events).
    private func flagTint(_ f: String) -> Color {
        if f.hasPrefix("Alarm") || f == "Sirene actief" || f == "Gekanteld"
            || f == "Stoot gedetecteerd" || f == "Motor vastgelopen" { return Theme.danger }
        if f == "Batterij laag" || f == "Foute PAC ingevoerd"
            || f == "Ongeldige PAC ingesteld" || f == "Lage temperatuur" { return Theme.warn }
        return .secondary
    }

    @ViewBuilder
    private var statusFlagsSection: some View {
        if !ble.statusFlags.isEmpty {
            Section {
                ForEach(ble.statusFlags, id: \.self) { f in
                    Label(f, systemImage: flagIcon(f))
                        .foregroundStyle(flagTint(f))
                        .font(.callout)
                }
            } header: {
                Text("Slotstatus (live)")
            } footer: {
                Text("Live meldingen uit het slot — alarmen, opladen, foute PAC-pogingen en meer.")
            }
        }
    }

    private func flagIcon(_ f: String) -> String {
        switch f {
        case "Opladen": return "bolt.fill"
        case "Volgeladen": return "battery.100.bolt"
        case "Batterij laag": return "battery.25"
        case "Sirene actief": return "speaker.wave.3.fill"
        case "Gekanteld": return "gyroscope"
        case "Stoot gedetecteerd", "Alarm: hameren": return "hammer.fill"
        case "Alarm: schudden": return "waveform.path"
        case "Motor vastgelopen": return "exclamationmark.gearshape.fill"
        case "Aanraking": return "hand.tap.fill"
        case "Foute PAC ingevoerd", "Ongeldige PAC ingesteld": return "lock.trianglebadge.exclamationmark"
        case "Tracking (tether)": return "dot.radiowaves.left.and.right"
        case "Beeper aan": return "speaker.wave.1.fill"
        case "Lage temperatuur": return "thermometer.snowflake"
        case "Testmodus": return "testtube.2"
        default: return "info.circle"
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section("Slot") {
            statusRow("Status", value: statusText, systemImage: statusIcon)
            if let battery = latestBattery {
                let low = battery < Theme.batteryLowPct && !ble.isChargingBLE
                HStack {
                    Label("Batterij", systemImage: ble.isChargingBLE ? "battery.100.bolt" : batteryIcon(battery))
                        .foregroundStyle(low ? Theme.danger : .primary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        HStack(spacing: 6) {
                            Text("\(battery)%").foregroundStyle(low ? Theme.danger : .primary)
                            if let v = ble.batteryVoltageBLE {
                                Text(String(format: "%.2f V", v)).foregroundStyle(.secondary)
                            }
                        }
                        Text(batteryCaption(low: low))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            if let serial = lock.serial_no {
                statusRow("Serienummer", value: serial, systemImage: "number")
            }
            if let coordinate {
                Button { openInMaps(coordinate) } label: {
                    Label("Route naar slot", systemImage: "car.fill")
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
                            .foregroundStyle(Theme.danger)
                    }
                    Button { loadSim() } label: {
                        HStack {
                            Label("Vernieuwen", systemImage: "arrow.clockwise")
                            if simLoading { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(simLoading)
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
                    Text(simError).font(.caption).foregroundStyle(Theme.danger)
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
                        Label("Status opgehaald om \(DateUtils.timeHM(t)) · tik op Vernieuwen voor de actuele status",
                              systemImage: "clock")
                    }
                    Text("De teller kan iets achterlopen. Hier vraag je alleen de status op; betalen gaat apart.")
                }
            }
    }

    @ViewBuilder
    private var geavanceerdSection: some View {
        Section {
            actionRow("Geavanceerde bediening & auto-test", "wrench.and.screwdriver") { showBLEControl = true }
            actionRow("Bluetooth-diagnose", "dot.radiowaves.right") { showBLE = true }
            actionRow("Firmware ophalen (analyse)", "cpu") { showFirmware = true }
        } header: {
            Text("Geavanceerd")
        } footer: {
            Text("Alleen nodig als de normale Open/Sluit niet werkt: handmatige sleutel/kanaal/teller en het GATT-profiel.")
        }
    }

    private func uptimeText(_ s: UInt32) -> String {
        let t = Int(s)
        let d = t / 86400, h = (t % 86400) / 3600, m = (t % 3600) / 60
        if d > 0 { return "\(d)d \(h)u" }
        if h > 0 { return "\(h)u \(m)m" }
        return "\(m)m"
    }

    @ViewBuilder
    private var sensorsSection: some View {
        Section {
            if let a = ble.accelG {
                let tilt = atan2((a.x * a.x + a.y * a.y).squareRoot(), abs(a.z)) * 180 / .pi
                statusRow("Kanteling", value: String(format: "%.0f°", tilt), systemImage: "gyroscope")
                statusRow("Versnelling X/Y/Z",
                          value: String(format: "%.2f / %.2f / %.2f g", a.x, a.y, a.z),
                          systemImage: "move.3d")
            }
            if let u = ble.infoUptime {
                statusRow("Uptime", value: uptimeText(u), systemImage: "clock.arrow.circlepath")
            }
            if let r = ble.infoRSSIpkt {
                statusRow("Signaal (pakket)", value: "\(r) dBm", systemImage: "antenna.radiowaves.left.and.right")
            }
            if let r = ble.lockReason {
                statusRow("Laatste status-reden", value: "\(r)", systemImage: "info.circle")
            }
            if let op = ble.netOperator {
                statusRow("Mobiel netwerk", value: op + (ble.netCSQ.map { " · \($0)/31" } ?? ""),
                          systemImage: "antenna.radiowaves.left.and.right")
            }
            if let v = ble.batteryVoltageBLE {
                statusRow("Accuspanning", value: String(format: "%.2f V", v), systemImage: "bolt.fill")
            }
            if let ls = ble.lockStateText {
                statusRow("Slotstand (ruw uit frame)", value: ls, systemImage: "lock.square")
            }
            if let t = ble.infoTempC {
                statusRow("Temperatuur", value: "\(t) °C", systemImage: "thermometer.medium")
            }
            if let e = ble.infoExtra {
                statusRow("Extra (ongelabeld)", value: "\(e)", systemImage: "number")
            }
            if let raw = ble.infoRaw {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ruw statuspakket (voor kalibratie)").font(.caption).foregroundStyle(.secondary)
                    Text(raw).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                }
                Button {
                    UIPasteboard.general.string = raw
                    Haptic.tap(.light)
                } label: {
                    Label("Kopieer ruwe hex", systemImage: "doc.on.doc")
                }
            }
            if ble.infoAt == nil {
                Text(ble.ready ? "Wachten op statuspakket van het slot…"
                               : "Verbind via Bluetooth om sensordata te zien.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Sensoren (live)")
        } footer: {
            Text("Live uit het slot via Bluetooth — werkt zonder cloud. Accuspanning en batterij-% komen uit het statusframe (gedecodeerd uit de officiële app: spanning = bytes 4-5/1000, batterij = byte 6). Verschijnen kort na verbinden (automatische state-ping).")
        }
    }

    @ViewBuilder
    private var parkedSheet: some View {
        NavigationStack {
            Group {
                if let spot = parked {
                    VStack(spacing: 0) {
                        LockMapView(coordinate: spot.coordinate, title: "Geparkeerde fiets")
                            .ignoresSafeArea(edges: .bottom)
                            .overlay(alignment: .bottom) {
                                VStack(spacing: 10) {
                                    HStack(spacing: 10) {
                                        Button { navigateApple(spot.coordinate, walking: true) } label: {
                                            Label("Lopen", systemImage: "figure.walk").frame(maxWidth: .infinity)
                                        }.buttonStyle(.borderedProminent)
                                        Button { navigateGoogle(spot.coordinate) } label: {
                                            Label("Google Maps", systemImage: "map").frame(maxWidth: .infinity)
                                        }.buttonStyle(.bordered)
                                    }
                                    Text("Vastgelegd \(DateUtils.absoluteWithRelative(spot.date))"
                                         + (spot.accuracy > 0 ? String(format: " · ±%.0f m nauwkeurig", spot.accuracy) : ""))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(12)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .padding(12)
                            }
                    }
                } else {
                    ContentUnavailableViewCompat(
                        title: "Nog geen parkeerplek", systemImage: "bicycle",
                        description: "Zodra je het slot sluit terwijl je telefoon een locatie heeft, wordt die hier bewaard.")
                }
            }
            .linkaScreen().navigationTitle("Geparkeerde fiets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Gereed") { showParkedSheet = false } }
                ToolbarItem(placement: .destructiveAction) {
                    if parked != nil {
                        Button(role: .destructive) {
                            ParkedStore.clear(serial: lock.serial_no); parked = nil; showParkedSheet = false
                        } label: { Text("Wissen") }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var fullMapSheet: some View {
        NavigationStack {
            Group {
                if let coordinate {
                    LockMapView(coordinate: coordinate, title: displayName, route: routePoints)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "mappin.slash").font(.largeTitle)
                        Text("Geen locatie bekend voor dit slot").foregroundStyle(.secondary)
                    }
                }
            }
            .linkaScreen().navigationTitle(displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Gereed") { showFullMap = false } }
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
            Group {
            statusSection
            statusFlagsSection

            Section("Slot instellen") {
                NavigationLink {
                    SlotSettingsPage(kind: .security, ble: ble, serial: lock.serial_no)
                } label: { Label("Beveiliging & alarm", systemImage: "shield.lefthalf.filled") }
                NavigationLink {
                    SlotSettingsPage(kind: .behaviour, ble: ble, serial: lock.serial_no)
                } label: { Label("Gedrag & geluid", systemImage: "slider.horizontal.3") }
                NavigationLink {
                    SlotSettingsPage(kind: .sensitivity, ble: ble, serial: lock.serial_no)
                } label: { Label("Gevoeligheid", systemImage: "waveform.path") }
            }

            Section("Locatie & data") {
                if let serial = lock.serial_no {
                    NavigationLink {
                        TrackingTestView(serial: serial, lockName: displayName)
                    } label: { Label("Tracking & recovery", systemImage: "dot.radiowaves.left.and.right") }
                }
                NavigationLink {
                    List { dataplanSection }
                        .linkaScreen().navigationTitle("Dataplan").navigationBarTitleDisplayMode(.inline)
                } label: { Label("Dataplan & verbruik", systemImage: "simcard") }
                Button { showStats = true } label: {
                    HStack {
                        Label("Statistieken & activiteiten", systemImage: "chart.bar.fill")
                            .foregroundStyle(.primary)
                        Spacer()
                        if busy && activities.isEmpty { ProgressView() }
                        else { Text("\((activities + localActs).filter { !$0.isBatterySample }.count)").foregroundStyle(.secondary) }
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Section("Delen & beheer") {
                actionRow("Delen & toegang", "person.2.fill") { showSharing = true }
                actionRow("Hernoemen", "pencil") { renameText = displayName; showRename = true }
                if let serial = lock.serial_no {
                    NavigationLink {
                        OwnershipView(serial: serial, lockName: displayName)
                    } label: { Label("Eigendom wijzigen", systemImage: "person.crop.circle.badge.exclamationmark") }
                }
                NavigationLink {
                    BackupView()
                } label: { Label("Back-up & herstel", systemImage: "key.icloud") }
            }

            Section {
                NavigationLink {
                    advancedPage
                } label: { Label("Geavanceerd", systemImage: "wrench.and.screwdriver") }
            }

            Section {
                EmptyView()
            } footer: {
                VStack(spacing: 3) {
                    Text("LinkaPlus v\(appVersion)")
                    Text("Created by Ivo Rooijackers (IvoRoo)")
                }
                .font(.caption)
                .frame(maxWidth: .infinity)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            }
        }
            .listRowBackground(Theme.cardFill)
        }
        .linkaScreen().navigationTitle("Instellingen")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Slot hernoemen", isPresented: $showRename) {
            TextField("Naam", text: $renameText)
            Button("Annuleer", role: .cancel) {}
            Button("Opslaan") { renameLock() }
        } message: {
            Text("Nieuwe naam voor dit slot (in de cloud).")
        }
        .alert("Hernoemen mislukt", isPresented: Binding(get: { renameError != nil },
                                                          set: { if !$0 { renameError = nil } })) {
            Button("OK", role: .cancel) { renameError = nil }
        } message: {
            Text(renameError ?? "")
        }
    }

    /// A row that opens a sheet/dialog — same look as the push rows next to it
    /// (primary text, tinted icon, chevron), instead of an all-blue button.
    private func actionRow(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label { Text(title).foregroundStyle(.primary) } icon: { Image(systemName: icon) }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    private var advancedPage: some View {
        List {
            Group {
            Section {
                NavigationLink {
                    List { sensorsSection }
                        .linkaScreen().navigationTitle("Sensoren").navigationBarTitleDisplayMode(.inline)
                } label: { Label("Sensoren (live)", systemImage: "gauge.with.dots.needle.33percent") }
                NavigationLink {
                    SlotSettingsPage(kind: .maintenance, ble: ble, serial: lock.serial_no)
                } label: { Label("Onderhoud & uitlezen", systemImage: "wrench") }

            }
            geavanceerdSection
        }
            .listRowBackground(Theme.cardFill)
        }
        .linkaScreen().navigationTitle("Geavanceerd")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Bluetooth control card

    private var bleStatusText: String {
        if bleKeyError != nil { return "Sleutel niet geladen" }
        if ble.bluetoothOff { return "Bluetooth staat uit" }
        switch ble.state {
        case "scannen": return "Zoeken naar slot…"
        case "verbinden", "services": return "Verbinden…"
        case "klaar": return "Verbonden"
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
        if ble.bluetoothOff { return "Zet Bluetooth aan om je slot te bedienen" }
        if !ble.ready { return "Ga dichtbij je slot om het te bedienen" }
        if ble.motion == .locking { return "Vergrendelen…" }
        if ble.motion == .unlocking { return "Ontgrendelen…" }
        guard let k = knownLocked else { return "Tik op het slot om te openen of te sluiten" }
        return k ? "Tik op het slot om te openen" : "Tik op het slot om te sluiten"
    }

    /// Bar position: follows the motor while it runs, else the known state.
    private var barClosed: Bool {
        switch ble.motion {
        case .locking: return true
        case .unlocking: return false
        case nil: return heroLocked
        }
    }

    private func heroControl(size: CGFloat) -> some View {
        VStack(spacing: 14) {
            connectionPill

            // Flat lock — tap to toggle, same action as the Openen/Sluiten buttons.
            Button {
                Haptic.tap()
                let locked = heroLocked
                // No optimistic flip: the bar follows the lock's own status
                // (locking/unlocking → locked/unlocked), like the official app.
                ble.channel = 0; ble.counterOffset = 0
                if locked { ble.unlock() } else { ble.lock() }
            } label: {
                LockGraphic(locked: barClosed, color: heroColor, size: size,
                            moving: ble.motion != nil, duration: ble.motorDuration)
                    .background(
                        // State-coloured glow, like the widget's.
                        Circle()
                            .fill(RadialGradient(colors: [heroColor.opacity(0.32), heroColor.opacity(0)],
                                                 center: .center, startRadius: 0, endRadius: size * 0.8))
                            .frame(width: size * 1.7, height: size * 1.7)
                            .animation(.easeInOut(duration: 0.35), value: heroColor)
                    )
                    .accessibilityHidden(true)
            }
            .buttonStyle(PressableStyle())
            .disabled(!ble.ready)
            .opacity(ble.ready ? 1 : 0.45)
            .accessibilityLabel(knownLocked == nil ? "Slotstatus onbekend" : (heroLocked ? "Slot is dicht" : "Slot is open"))
            .accessibilityHint(heroSubtitle)

            // One fixed-height slot for hint / command result → no layout jumps.
            Group {
                if ble.commandResult != nil { commandResultRow }
                else { Text(heroSubtitle).font(.footnote).foregroundStyle(.secondary) }
            }
            .multilineTextAlignment(.center)
            .lineLimit(2).minimumScaleFactor(0.85)
            .frame(minHeight: 44)

            statCard
        }
        .frame(maxWidth: .infinity)
    }

    private var connectionPill: some View {
        let reconnectable = !ble.bluetoothOff && (ble.state == "verbroken" || ble.state == "gestopt")
        return Button {
            if reconnectable { ble.start() }
        } label: {
            HStack(spacing: 7) {
                Circle().fill(ble.ready ? Theme.success : Color.secondary).frame(width: 8, height: 8)
                Text(bleStatusText).font(.footnote.weight(.semibold))
                if reconnectable { Image(systemName: "arrow.clockwise").font(.caption.weight(.bold)) }
                else if !ble.ready && bleKeyError == nil && !ble.bluetoothOff { ProgressView().controlSize(.mini) }
            }
            .foregroundStyle(ble.ready ? Color.primary : Color.secondary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Theme.cardFill).overlay(Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1)))
            .frame(minHeight: 44).contentShape(Rectangle())   // full-size tap target
        }
        .buttonStyle(.plain)
        .allowsHitTesting(reconnectable)
        .accessibilityElement(children: .combine)
        .accessibilityHint(reconnectable ? "Tik om opnieuw te verbinden" : "")
    }

    private var statCard: some View {
        let battery = latestBattery
        let low = (battery ?? 100) < Theme.batteryLowPct && !ble.isChargingBLE
        return HStack(spacing: 0) {
            statColumn("Slot", statusText, statusIcon, knownLocked == nil ? Color.secondary : heroColor)
            Divider().frame(height: 38)
            statColumn("Batterij", battery.map { "\($0)%" } ?? "–",
                       ble.isChargingBLE ? "battery.100.bolt" : (battery.map { batteryIcon($0) } ?? "battery.50"),
                       low ? Theme.danger : Color.secondary)
            Divider().frame(height: 38)
            statColumn("Afstand", distanceText ?? "–", "location.fill", Color.secondary)
        }
        .padding(.vertical, 12)
        .background(GlassCard())
    }

    private func statColumn(_ title: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title3).foregroundStyle(color)
            Text(value).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }

    private var compactMap: some View {
        Button { showFullMap = true } label: {
            mapView
                .allowsHitTesting(false)
                .frame(height: 148)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                        .padding(7)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(8)
                }
                .overlay(alignment: .bottomLeading) {
                    if let d = lastLocationDate {
                        Label(DateUtils.relative(d), systemImage: "clock")
                            .font(.caption2)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Kaart vergroten")
    }

    @ViewBuilder
    private var mainButtons: some View {
        let sirenActive = ble.statusFlags.contains("Sirene actief")
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    Haptic.tap(.light)
                    ble.channel = 0; ble.counterOffset = 0; ble.unlock()
                } label: {
                    Label("Openen", systemImage: "lock.open.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.open)
                .disabled(knownLocked == false)   // already open
                Button {
                    Haptic.tap(.light)
                    ble.channel = 0; ble.counterOffset = 0; ble.lock()
                } label: {
                    Label("Sluiten", systemImage: "lock.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.locked)
                .disabled(knownLocked == true)    // already locked
            }
            .controlSize(.large)
            .disabled(!ble.ready)

            HStack(spacing: 12) {
                Button { showFinder = true } label: {
                    Label("Zoek slot", systemImage: "dot.radiowaves.left.and.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(Theme.accent)
                Button {
                    Haptic.tap()
                    if sirenActive { ble.sirenOff() }
                    else if ble.ready { ble.sirenOn() }
                    else { playSiren() }
                } label: {
                    Label(sirenActive ? "Sirene stoppen" : (sirenBusy ? "Bezig…" : "Sirene"),
                          systemImage: sirenActive ? "speaker.slash.fill" : "speaker.wave.3.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(Theme.danger)
                .disabled(sirenBusy)
            }
            .controlSize(.regular)

            if let e = bleKeyError {
                Text(e).font(.footnote).foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var commandResultRow: some View {
        switch ble.commandResult {
        case .success(let n):
            Label("\(n) gelukt", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success).font(.callout)
        case .rejected:
            Label("Geweigerd — probeer opnieuw", systemImage: "xmark.circle.fill").foregroundStyle(Theme.danger).font(.callout)
        case .blocked:
            Label("Geblokkeerd — houd het slot stil en probeer opnieuw.",
                  systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn).font(.callout)
        case .timeout:
            Label("Geen reactie van het slot — opnieuw proberen.", systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(.secondary).font(.callout)
        case .none:
            if ble.lastEvent != "–" {
                Text(ble.lastEvent).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Triggered by the Action button / widget / Shortcut deep link: unlock as
    /// soon as we have a live context counter from the lock.
    private func maybeAutoUnlock() {
        // A request older than AppRouter.requestLifetime is dropped, not executed.
        guard router.hasFreshRequest(), ble.ready, ble.ctxCounter != nil else { return }
        var lockIt = router.wantsLock
        if router.wantsToggle {
            // Wait until the lock has reported its real state (status frame);
            // ask for it instead of hoping one arrives on its own.
            guard let state = ble.liveLocked else {
                if Date().timeIntervalSince(lastStatePing) > 3 {
                    lastStatePing = Date()
                    ble.statePing()
                }
                return
            }
            lockIt = !state
        }
        router.cancelRequest()
        ble.channel = 0; ble.counterOffset = 0
        if lockIt { ble.lock() } else { ble.unlock() }
        Haptic.success()
    }

    private func startBLE() async {
        guard let serial = lock.serial_no else { return }
        // On reappear the view (and its keys) may be reused → just re-scan.
        if bleStarted {
            if !ble.ready { ble.start() }
            maybeAutoUnlock()   // link may already be live: no onChange will fire
            return
        }
        bleKeyError = nil
        // This screen must never operate another lock the controller still holds.
        ble.release(unless: serial)
        // 1) Connect right away with the key cached on this phone — no waiting on
        //    the network (bike shed, basement, slow 4G).
        let cached = LockCache.loadKeys(serial: serial)
        if let c = cached, c.commandKey != nil {
            bleStarted = true
            ble.configure(keys: c, serial: serial, nameHint: displayName)
            ble.start()
            maybeAutoUnlock()   // link may already be live: no onChange will fire
        }
        // 2) Refresh the key from the cloud; switch over only if it changed.
        do {
            let status = try await api.checkKeyStatus(serial: serial, auth: session.identity())
            if let k = status.key, let fresh = k.commandKey {
                LockCache.saveKeys(k, serial: serial)
                let old = cached?.commandKey
                if !bleStarted || old?.hex != fresh.hex || old?.admin != fresh.admin {
                    bleStarted = true
                    ble.configure(keys: k, serial: serial, nameHint: displayName)
                    if !ble.ready { ble.start() }
                }
            } else {
                // The server answered and gives us no key (access revoked).
                if bleStarted { ble.stop() }
                bleStarted = false
                bleKeyError = "Je hebt geen (geldige) sleutel meer voor dit slot."
            }
        } catch {
            // Cloud unavailable → keep working on the cached key, if there is one.
            if !bleStarted {
                bleKeyError = "Geen sleutel op deze telefoon. Maak verbinding met internet en open het slot opnieuw."
            }
        }
    }

    @ViewBuilder
    private var mapView: some View {
        if let coordinate {
            LockMapView(coordinate: coordinate, title: displayName, route: routePoints)
        } else {
            ZStack {
                Theme.cardFill
                VStack(spacing: 6) {
                    Image(systemName: "mappin.slash").font(.title)
                    Text("Geen locatie bekend voor dit slot").font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func parkedCard(_ spot: ParkedStore.Spot) -> some View {
        let dist: String? = loc.coordinate.map { me in
            let m = CLLocation(latitude: spot.lat, longitude: spot.lon)
                .distance(from: CLLocation(latitude: me.latitude, longitude: me.longitude))
            return DistanceText.format(meters: m)
        }
        Button { showParkedSheet = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "bicycle.circle.fill")
                    .font(.title2).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Geparkeerd").font(.subheadline.weight(.semibold))
                    Text("\(DateUtils.absoluteWithRelative(spot.date))" + (dist.map { " · \($0)" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                    .font(.title2).foregroundStyle(Theme.accent)
            }
            .padding(.vertical, 10).padding(.horizontal, 14)
            .background(GlassCard())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    private func navigateApple(_ c: CLLocationCoordinate2D, walking: Bool) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: c))
        item.name = "Geparkeerde fiets"
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey:
            walking ? MKLaunchOptionsDirectionsModeWalking : MKLaunchOptionsDirectionsModeDriving])
    }

    private func navigateGoogle(_ c: CLLocationCoordinate2D) {
        let app = URL(string: "comgooglemaps://?daddr=\(c.latitude),\(c.longitude)&directionsmode=walking")!
        let web = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(c.latitude),\(c.longitude)&travelmode=walking")!
        UIApplication.shared.open(UIApplication.shared.canOpenURL(app) ? app : web)
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
        item.name = displayName
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
                simError = (error as? LocalizedError)?.errorDescription ?? "Mislukt: \(error.localizedDescription)"
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
                simError = (error as? LocalizedError)?.errorDescription ?? "Mislukt: \(error.localizedDescription)"
            }
            cards = (try? await api.getCards(auth: session.identity())) ?? cards
            simLoading = false
        }
    }

    private func renameLock() {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let serial = lock.serial_no, !name.isEmpty, name != displayName else { return }
        Task {
            do {
                try await api.renameLock(name: name, serial: serial,
                                         isLocked: liveLocked, lockType: lock.lock_type ?? "original", auth: session.identity())
                customName = name          // title, map pin and sheets update at once
                router.locksChanged += 1   // the list reloads in the background
                Haptic.success()
            } catch {
                renameError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
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
                let raw = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if raw.localizedCaseInsensitiveContains("not currently")
                    || raw.localizedCaseInsensitiveContains("not active") {
                    sirenMessage = "Je slot is nu niet via internet bereikbaar: het slaapt om de batterij te sparen. Beweeg het slot en probeer het opnieuw. Vlakbij werkt de sirene altijd via Bluetooth."
                } else {
                    sirenMessage = "Mislukt: \(raw)"
                }
            }
            sirenBusy = false
        }
    }

    /// Reads whether tracking is currently active (current_tracking succeeds
    /// only in tracking mode) and loads the route if so.
    private func syncRecoveryState() async {
        guard lock.serial_no != nil else { return }
        routePoints = (try? await trackingCoords()) ?? []
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
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
