import Foundation
import CoreBluetooth

/// Phase-1 CoreBluetooth scaffold.
///
/// This connects to the lock over Bluetooth and discovers its services so we
/// can see it nearby and read live state. The actual lock/unlock command
/// exchange is implemented in Phase 2 — the hooks are marked with TODO.
@MainActor
final class BLEManager: NSObject, ObservableObject {

    enum State: Equatable {
        case poweredOff
        case unauthorized
        case idle
        case scanning
        case connecting
        case connected
        case disconnected
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var discoveredName: String?
    @Published private(set) var rssi: Int?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?

    /// Serial number / name fragment to match while scanning (set from the selected lock).
    private var targetNameFragment: String?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan(matching nameFragment: String?) {
        targetNameFragment = nameFragment
        guard central.state == .poweredOn else { return }
        state = .scanning
        // LINKA advertises as a BLE peripheral; scan broadly and filter by name.
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    func stopScan() {
        central.stopScan()
        if state == .scanning { state = .idle }
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    // MARK: Phase 2 hooks

    func sendUnlock() {
        // TODO (Fase 2): schrijf het open-commando naar de data-characteristic.
    }

    func sendLock() {
        // TODO (Fase 2): schrijf het sluit-commando naar de data-characteristic.
    }
}

extension BLEManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn: break // ready; scanning starts on demand
            case .poweredOff: state = .poweredOff
            case .unauthorized: state = .unauthorized
            default: break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        Task { @MainActor in
            guard let name = name else { return }
            if let fragment = targetNameFragment, !fragment.isEmpty,
               !name.lowercased().contains(fragment.lowercased()) {
                return
            }
            self.discoveredName = name
            self.rssi = RSSI.intValue
            self.peripheral = peripheral
            peripheral.delegate = self
            self.state = .connecting
            central.stopScan()
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.state = .connected
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in self.state = .disconnected }
    }
}

extension BLEManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        // Phase 2: locate the LINKA data/UART characteristics here and wire up
        // notifications + the authenticated command exchange.
    }
}
