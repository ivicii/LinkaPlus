import Foundation
import CoreLocation
import UIKit
import AudioToolbox

/// One fix from the lock's own cellular GPS (via LINKA's current_tracking).
struct TrackFix {
    let time: Date
    let coord: CLLocationCoordinate2D
    let speed: Double   // m/s, -1 = unknown
    let dir: Double     // raw direction (×10 = degrees), -1 = unknown
    let unc: Double     // accuracy radius in metres, -1 = unknown

    var speedKmh: Int? { speed >= 0 ? Int((speed * 3.6).rounded()) : nil }
    var headingDegrees: Double? { dir >= 0 ? dir * 10 : nil }
    var accuracy: Int? { unc >= 0 ? Int(unc.rounded()) : nil }
}

/// Live "follow the thief" mode. Runs independently of any screen: polls the
/// lock's cellular GPS every 5 s, tracks your own position (continuous location,
/// which also keeps the app alive in the background), computes distance and
/// bearing to the bike, buzzes on every new fix (harder when you're closing in)
/// and keeps the Live Activity / Dynamic Island current.
final class FollowEngine: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = FollowEngine()

    @Published private(set) var active = false
    @Published private(set) var serial: String?
    @Published private(set) var fixes: [TrackFix] = []
    @Published private(set) var me: CLLocation?
    @Published private(set) var heading: Double?          // device heading (degrees, true north)
    @Published private(set) var lastPoll: Date?
    @Published private(set) var lastNewFixAt: Date?
    @Published private(set) var error: String?
    @Published private(set) var locationDenied = false
    private(set) var reportCount = 0

    private var lockName = "LINKA-slot"
    private var auth: Identity?
    private let api = APIClient()
    private let lm = CLLocationManager()
    private var loop: Task<Void, Never>?
    private var startedAt = Date()
    private var lastDistance: CLLocationDistance?
    private var nearAlerted: Set<Int> = []

    private static let pollInterval: UInt64 = 5          // seconds
    private static let idleStop: TimeInterval = 30 * 60  // stop after 30 min without a new fix
    private static let nearThresholds = [500, 200, 50]   // metres

    override init() {
        super.init()
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyBest
        lm.activityType = .otherNavigation
        lm.distanceFilter = 5
        lm.headingFilter = 5
    }

    // MARK: Derived values

    var latest: TrackFix? { fixes.last }

    var distance: CLLocationDistance? {
        guard let me, let f = latest else { return nil }
        return me.distance(from: CLLocation(latitude: f.coord.latitude, longitude: f.coord.longitude))
    }

    /// Bearing from you to the bike, degrees from true north.
    var bearing: Double? {
        guard let me, let f = latest else { return nil }
        return Self.bearing(from: me.coordinate, to: f.coord)
    }

    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dl = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    static func distanceText(_ d: CLLocationDistance?) -> String {
        guard let d else { return "–" }
        if d < 1000 { return "\(Int(d.rounded())) m" }
        return String(format: "%.1f km", d / 1000).replacingOccurrences(of: ".", with: ",")
    }

    static func compass(_ deg: Double) -> String {
        let dirs = ["N", "NO", "O", "ZO", "Z", "ZW", "W", "NW"]
        let i = ((Int((deg / 45).rounded()) % 8) + 8) % 8
        return dirs[i]
    }

    // MARK: Control

    func start(serial: String, lockName: String, auth: Identity) {
        if active && self.serial == serial { return }
        stop()
        self.serial = serial
        self.lockName = lockName
        self.auth = auth
        startedAt = Date()
        lastDistance = nil
        nearAlerted = []
        error = nil
        fixes = []
        active = true

        switch lm.authorizationStatus {
        case .notDetermined: lm.requestWhenInUseAuthorization()
        case .denied, .restricted: locationDenied = true
        default: break
        }
        // Background location keeps the app (and this poll loop) running while
        // the phone is in your pocket — that's what makes following practical.
        lm.allowsBackgroundLocationUpdates = true
        lm.pausesLocationUpdatesAutomatically = false
        lm.showsBackgroundLocationIndicator = true
        lm.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { lm.startUpdatingHeading() }

        if #available(iOS 16.1, *) { LiveActivityManager.ensure(lockName: lockName, state: liveState()) }

        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.active else { return }
                await self.poll()
                try? await Task.sleep(nanoseconds: Self.pollInterval * 1_000_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel(); loop = nil
        guard active else { return }
        active = false
        lm.stopUpdatingLocation()
        lm.stopUpdatingHeading()
        lm.allowsBackgroundLocationUpdates = false
    }

    // MARK: Polling

    private func poll() async {
        guard let serial, let auth else { return }
        do {
            let acts = try await api.currentTracking(serial: serial, auth: auth)
            let new = acts.compactMap { a -> TrackFix? in
                guard a.hasLocation, let lat = a.latitude, let lon = a.longitude else { return nil }
                let t = DateUtils.parseAny(a.timestamp) ?? DateUtils.parseISO(a.createdAt) ?? Date.distantPast
                return TrackFix(time: t, coord: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                speed: Double(a.speed ?? -1), dir: Double(a.direction ?? -1),
                                unc: Double(a.uncertainty ?? -1))
            }.sorted { $0.time < $1.time }
            await MainActor.run { self.apply(new, reports: acts.count) }
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await MainActor.run { self.error = msg; self.lastPoll = Date() }
        }
    }

    @MainActor
    private func apply(_ new: [TrackFix], reports: Int) {
        lastPoll = Date()
        error = nil
        reportCount = reports
        let grew = new.count > fixes.count
        if new.count != fixes.count {
            fixes = new
            persist()
        }
        if grew {
            lastNewFixAt = Date()
            let d = distance
            let closer: Bool = {
                guard let d, let prev = lastDistance else { return false }
                return d < prev - 20
            }()
            if let d { lastDistance = d }
            cue(closer: closer)
            checkNear()
        }
        updateLiveActivity()

        // Battery safety: give up after a long time without any new position.
        let since = lastNewFixAt ?? startedAt
        if Date().timeIntervalSince(since) > Self.idleStop {
            stop()
            LockNotifier.shared.notify(title: "Volgen gestopt",
                                       body: "\(lockName): 30 minuten geen nieuwe positie, volgen is uitgezet om accu te sparen.",
                                       id: "followIdle")
        }
    }

    @MainActor
    private func cue(closer: Bool) {
        if UIApplication.shared.applicationState == .active {
            if closer {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                AudioServicesPlaySystemSound(1007)
            } else {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                AudioServicesPlaySystemSound(1057)
            }
        } else {
            // In the pocket: a short buzz per fix, the long alert-buzz when closer.
            if closer { AudioServicesPlayAlertSound(SystemSoundID(kSystemSoundID_Vibrate)) }
            else { AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate)) }
        }
    }

    @MainActor
    private func checkNear() {
        guard let d = distance else { return }
        for t in Self.nearThresholds where d < Double(t) && !nearAlerted.contains(t) {
            nearAlerted.insert(t)
            if UIApplication.shared.applicationState != .active {
                LockNotifier.shared.notify(title: "Dichtbij je fiets",
                                           body: "\(lockName) is nog \(Self.distanceText(d)) bij je vandaan.",
                                           id: "followNear_\(t)")
            }
        }
    }

    // MARK: Persistence (same keys as the tracking screen / history)

    private func persist() {
        guard let serial else { return }
        let arr = fixes.map { [$0.coord.latitude, $0.coord.longitude] }
        if let d = try? JSONSerialization.data(withJSONObject: arr) {
            UserDefaults.standard.set(d, forKey: "recoveryPoints_\(serial)")
        }
        let startedT = UserDefaults.standard.double(forKey: "recoveryStarted_\(serial)")
        guard startedT > 0, !fixes.isEmpty else { return }
        let s = TrackingSession(id: "s\(Int(startedT))",
                                start: Date(timeIntervalSince1970: startedT),
                                end: nil,
                                coords: arr,
                                times: fixes.map { $0.time.timeIntervalSince1970 },
                                speeds: fixes.map { $0.speed },
                                headings: fixes.map { $0.dir },
                                uncerts: fixes.map { $0.unc },
                                reports: reportCount > 0 ? reportCount : nil)
        TrackingHistory.upsert(s, serial: serial)
    }

    // MARK: Live Activity

    @available(iOS 16.1, *)
    private func liveState() -> TrackingActivityAttributes.ContentState {
        var status = "Volgen actief"
        if let f = latest {
            var parts: [String] = []
            if let k = f.speedKmh { parts.append(k <= 2 ? "stilstaand" : "\(k) km/u") }
            if let h = f.headingDegrees, (f.speedKmh ?? 0) > 2 { parts.append("richting \(Self.compass(h))") }
            if !parts.isEmpty { status = "Fiets " + parts.joined(separator: " ") }
        }
        let pos = latest.map { String(format: "%.5f, %.5f", $0.coord.latitude, $0.coord.longitude) }
        return .init(statusText: status, pointCount: fixes.count, lastUpdate: lastNewFixAt ?? Date(),
                     positionText: pos,
                     distanceText: distance.map { Self.distanceText($0) })
    }

    @MainActor
    private func updateLiveActivity() {
        if #available(iOS 16.1, *) { LiveActivityManager.update(liveState()) }
    }

    // MARK: CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0 else { return }
        Task { @MainActor in
            self.me = loc
            guard self.active else { return }
            // Your own movement can also bring you within range between fixes.
            self.checkNear()
            if let d = self.distance, let prev = self.lastDistance, abs(d - prev) > 25 {
                self.lastDistance = d
                self.updateLiveActivity()
            } else if self.lastDistance == nil, let d = self.distance {
                self.lastDistance = d
                self.updateLiveActivity()
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        DispatchQueue.main.async { self.heading = h }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        DispatchQueue.main.async {
            self.locationDenied = (s == .denied || s == .restricted)
        }
    }
}
