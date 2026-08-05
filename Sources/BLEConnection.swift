import Foundation
@preconcurrency import CoreBluetooth

/// Picks the GATT characteristics that carry the ELM327 byte stream.
///
/// The Vgate iCar Pro BLE (and most Vlink clones) expose service `FFF0` with
/// `FFF1` (notify, adapter→phone) and `FFF2` (write, phone→adapter). Other
/// clones move the UUIDs around, so when the known layout is absent we fall
/// back to any notify+write pair living in the same service.
enum BLECharacteristicPicker {
    static let vlinkService = CBUUID(string: "FFF0")
    static let vlinkNotify = CBUUID(string: "FFF1")
    static let vlinkWrite = CBUUID(string: "FFF2")
    /// Common BLE UART layout used by Konnwei KW903 and HM-10-based adapters.
    /// FFE1 is normally a single notify + write characteristic.
    static let konnweiService = CBUUID(string: "FFE0")
    static let konnweiData = CBUUID(string: "FFE1")

    struct Candidate: Equatable {
        var service: CBUUID
        var characteristic: CBUUID
        var canNotify: Bool
        var canWrite: Bool
    }

    static func pick(from candidates: [Candidate]) -> (notify: CBUUID, write: CBUUID)? {
        let known = candidates.filter { $0.service == vlinkService }
        if known.contains(where: { $0.characteristic == vlinkNotify && $0.canNotify }),
           known.contains(where: { $0.characteristic == vlinkWrite && $0.canWrite }) {
            return (vlinkNotify, vlinkWrite)
        }

        let konnwei = candidates.filter { $0.service == konnweiService }
        if konnwei.contains(where: {
            $0.characteristic == konnweiData && $0.canNotify && $0.canWrite
        }) {
            return (konnweiData, konnweiData)
        }

        let services = Set(candidates.map(\.service))
        for service in services.sorted(by: { $0.uuidString < $1.uuidString }) {
            let inService = candidates.filter { $0.service == service }
            guard let notify = inService.first(where: \.canNotify),
                  let write = inService.first(where: \.canWrite) else { continue }
            return (notify.characteristic, write.characteristic)
        }
        return nil
    }
}

/// Conservative advertisement filter for OBD BLE adapters. FFE0 by itself is
/// deliberately insufficient because thousands of unrelated HM-10 devices use
/// that service. A Konnwei must identify itself by brand or the confirmed BLE
/// model token KW903 before we connect and inspect its GATT characteristics.
enum BLEAdvertisementClassifier {
    static func matches(name: String?, advertisedServices: [CBUUID]) -> Bool {
        let label = (name ?? "").uppercased()
        let namedAdapter = label.contains("VLINK")
            || label.contains("OBD")
            || label.contains("KONNWEI")
            || label.contains("KW903")
        return namedAdapter
            || advertisedServices.contains(BLECharacteristicPicker.vlinkService)
    }
}

/// Bluetooth Low Energy transport for Vlink-style ELM327 dongles (e.g. the
/// Vgate iCar Pro BLE 4.0, which advertises as `IOS-VLINK`). No pairing is
/// involved: we scan, connect, subscribe to the notify characteristic, and
/// exchange the same `CMD\r` / `>` line protocol as over TCP.
actor BLEConnection: OBDTransport {
    enum State { case idle, scanning, connecting, ready, failed(Error) }

    private let engine = ELMLineEngine()
    private var central: CBCentralManager?
    private var proxy: DelegateProxy?
    private var peripheral: CBPeripheral?
    private var notifyChar: CBCharacteristic?
    private var writeChar: CBCharacteristic?
    private(set) var state: State = .idle
    private let connectionTimeout: TimeInterval
    private var readyContinuations: [CheckedContinuation<Void, Error>] = []
    /// Single ordered consumer of inbound notification packets. BLE replies
    /// can span several packets; feeding them through one stream guarantees
    /// `engine.ingest` sees bytes in arrival order (a per-packet `Task` would
    /// not — unstructured tasks have no ordering guarantee).
    private var rxDrainTask: Task<Void, Never>?
    /// A remembered adapter can be reconnected without waiting for a fresh
    /// advertisement. If it no longer exists, a short timeout falls back to
    /// the original broad scan so changing dongle remains automatic.
    private var fastReconnectTask: Task<Void, Never>?
    /// Overall deadline for scan + connect + GATT discovery + notification
    /// subscription. Without it, an absent or incompatible adapter can leave
    /// the UI in "connecting" forever.
    private var connectionTimeoutTask: Task<Void, Never>?
    private var pendingCharacteristicDiscoveries = 0
    /// True between `start()` and `stop()` — gates auto-reconnect.
    private var shouldRun = false
    private static let lastPeripheralIdentifierKey = "lastBLEOBDPeripheralIdentifier.v1"

    init(connectionTimeout: TimeInterval = 30) {
        self.connectionTimeout = connectionTimeout
    }

    func start() {
        shouldRun = true
        guard central == nil else { return }
        state = .scanning
        armConnectionTimeout()
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let proxy = DelegateProxy(owner: self, rxContinuation: continuation)
        // The continuation is yielded to synchronously from the (serial)
        // CoreBluetooth delegate queue, preserving packet order.
        self.proxy = proxy
        rxDrainTask = Task { [engine] in
            for await data in stream { await engine.ingest(data) }
        }
        OBDLog.log("BLE: starting scan")
        central = CBCentralManager(delegate: proxy, queue: DispatchQueue(label: "ble-obd"))
    }

    func stop() async {
        shouldRun = false
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        central?.stopScan()
        fastReconnectTask?.cancel()
        fastReconnectTask = nil
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        // AsyncStream continuations are thread-safe: a delegate callback that
        // was already queued simply observes `.terminated` after this finish.
        proxy?.finishRXStream()
        rxDrainTask?.cancel()
        rxDrainTask = nil
        central = nil
        proxy = nil
        peripheral = nil
        notifyChar = nil
        writeChar = nil
        pendingCharacteristicDiscoveries = 0
        await engine.reset()
        state = .idle
        resumeReadyContinuations(throwing: CancellationError())
        OBDLog.log("BLE: stopped")
    }

    func isReady() async throws {
        switch state {
        case .ready: return
        case .failed(let error): throw error
        case .idle: throw OBDError.notReady
        default:
            try await withCheckedThrowingContinuation { cont in
                readyContinuations.append(cont)
            }
        }
    }

    func send(_ command: String, header: String?, timeout: TimeInterval) async throws -> String {
        guard case .ready = state, let peripheral, let writeChar else {
            throw OBDError.notReady
        }
        // Commands are a handful of bytes, far below any BLE MTU, so no
        // chunking is needed. Prefer write-without-response when offered —
        // the ELM's reply is the real acknowledgement either way.
        let type: CBCharacteristicWriteType =
            writeChar.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        return try await engine.perform(command, header: header, timeout: timeout) { data in
            peripheral.writeValue(data, for: writeChar, type: type)
        }
    }

    // MARK: - Events from CoreBluetooth (via DelegateProxy)

    fileprivate func centralStateChanged(_ btState: CBManagerState) {
        guard shouldRun, let central else { return }
        switch btState {
        case .poweredOn:
            if peripheral == nil {
                if !connectToRememberedPeripheral(using: central) {
                    startScan(central)
                }
            }
        case .unauthorized:
            OBDLog.log("BLE: permission denied")
            failReadiness(with: OBDError.bluetoothUnauthorized)
        case .poweredOff:
            OBDLog.log("BLE: Bluetooth is off")
            failReadiness(with: OBDError.bluetoothPoweredOff)
        case .unsupported:
            OBDLog.log("BLE: unsupported on this device")
            failReadiness(with: OBDError.bluetoothUnavailable)
        default:
            break
        }
    }

    fileprivate func discovered(_ peripheral: CBPeripheral,
                                name: String?,
                                advertisedServices: [CBUUID]) {
        guard shouldRun, self.peripheral == nil else { return }
        let label = (name ?? peripheral.name ?? "").uppercased()
        guard BLEAdvertisementClassifier.matches(
            name: label,
            advertisedServices: advertisedServices
        ) else { return }

        OBDLog.log("BLE: found '\(label.isEmpty ? "?" : label)', connecting")
        connect(peripheral, using: central)
    }

    fileprivate func connected(_ peripheral: CBPeripheral) {
        guard shouldRun, peripheral === self.peripheral, let proxy else { return }
        fastReconnectTask?.cancel()
        fastReconnectTask = nil
        UserDefaults.standard.set(
            peripheral.identifier.uuidString,
            forKey: Self.lastPeripheralIdentifierKey
        )
        OBDLog.log("BLE: connected in \(connectionElapsedDescription)")
        peripheral.delegate = proxy
        peripheral.discoverServices(nil)
    }

    fileprivate func servicesDiscovered(_ peripheral: CBPeripheral, error: Error?) {
        guard shouldRun, peripheral === self.peripheral else { return }
        if let error {
            OBDLog.log("BLE: service discovery failed: \(error)")
            failReadiness(with: OBDError.connectionFailed)
            return
        }
        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            OBDLog.log("BLE: adapter exposes no GATT services")
            failReadiness(with: OBDError.incompatibleAdapter)
            return
        }
        pendingCharacteristicDiscoveries = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    fileprivate func characteristicsDiscovered(
        _ peripheral: CBPeripheral,
        service: CBService,
        error: Error?
    ) {
        guard shouldRun,
              peripheral === self.peripheral,
              notifyChar == nil || writeChar == nil
        else { return }
        pendingCharacteristicDiscoveries = max(0, pendingCharacteristicDiscoveries - 1)
        if let error {
            OBDLog.log("BLE: characteristic discovery failed for \(service.uuid): \(error)")
            failReadiness(with: OBDError.connectionFailed)
            return
        }

        let candidates = (peripheral.services ?? []).flatMap { service in
            (service.characteristics ?? []).map { chr in
                BLECharacteristicPicker.Candidate(
                    service: service.uuid,
                    characteristic: chr.uuid,
                    canNotify: chr.properties.contains(.notify) || chr.properties.contains(.indicate),
                    canWrite: chr.properties.contains(.write) || chr.properties.contains(.writeWithoutResponse)
                )
            }
        }
        guard let picked = BLECharacteristicPicker.pick(from: candidates) else {
            if pendingCharacteristicDiscoveries == 0 {
                OBDLog.log("BLE: no compatible notify/write characteristic pair")
                failReadiness(with: OBDError.incompatibleAdapter)
            }
            return
        }

        let all = (peripheral.services ?? []).flatMap { $0.characteristics ?? [] }
        notifyChar = all.first { $0.uuid == picked.notify }
        writeChar = all.first { $0.uuid == picked.write }
        if let notifyChar {
            OBDLog.log("BLE: notify \(picked.notify.uuidString) / write \(picked.write.uuidString)")
            peripheral.setNotifyValue(true, for: notifyChar)
        }
    }

    fileprivate func notificationStateChanged(_ characteristic: CBCharacteristic, error: Error?) {
        guard shouldRun, characteristic === notifyChar else { return }
        if let error {
            OBDLog.log("BLE: subscribe failed: \(error)")
            failReadiness(with: OBDError.connectionFailed)
            return
        }
        guard characteristic.isNotifying else {
            OBDLog.log("BLE: adapter did not enable notifications")
            failReadiness(with: OBDError.connectionFailed)
            return
        }
        OBDLog.log("BLE: ready")
        fastReconnectTask?.cancel()
        fastReconnectTask = nil
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        state = .ready
        resumeReadyContinuations()
    }

    fileprivate func disconnected(_ peripheral: CBPeripheral, error: Error?) async {
        guard peripheral === self.peripheral else { return }
        fastReconnectTask?.cancel()
        fastReconnectTask = nil
        OBDLog.log("BLE: disconnected\(error.map { ": \($0)" } ?? "")")
        self.peripheral = nil
        notifyChar = nil
        writeChar = nil
        pendingCharacteristicDiscoveries = 0
        await engine.failPendingRead(with: error ?? OBDError.protocolError("BLE disconnected"))
        guard shouldRun, let central else {
            if case .failed = state {
                // Preserve the useful readiness error until `stop()` resets it.
            } else {
                state = .idle
            }
            return
        }
        // Dongle went away (ignition off, out of range) — go back to
        // scanning; it reappears as a fresh discovery.
        state = .scanning
        if central.state == .poweredOn {
            startScan(central)
        }
    }

    // MARK: - Private

    private var connectionStartedAt: Date?

    private var connectionElapsedDescription: String {
        guard let connectionStartedAt else { return "unknown time" }
        return String(format: "%.2f s", Date().timeIntervalSince(connectionStartedAt))
    }

    private func connect(_ peripheral: CBPeripheral, using central: CBCentralManager?) {
        guard shouldRun, let central else { return }
        self.peripheral = peripheral
        connectionStartedAt = Date()
        state = .connecting
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    private func connectToRememberedPeripheral(using central: CBCentralManager) -> Bool {
        guard let rawIdentifier = UserDefaults.standard.string(
            forKey: Self.lastPeripheralIdentifierKey
        ),
        let identifier = UUID(uuidString: rawIdentifier),
        let remembered = central.retrievePeripherals(withIdentifiers: [identifier]).first
        else {
            return false
        }

        OBDLog.log("BLE: reconnecting remembered adapter \(identifier.uuidString)")
        connect(remembered, using: central)
        fastReconnectTask?.cancel()
        fastReconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.rememberedConnectionTimedOut(identifier: identifier)
        }
        return true
    }

    private func rememberedConnectionTimedOut(identifier: UUID) {
        guard shouldRun,
              case .connecting = state,
              peripheral?.identifier == identifier,
              let central
        else { return }

        OBDLog.log("BLE: remembered adapter did not answer; falling back to scan")
        if let stalled = peripheral {
            central.cancelPeripheralConnection(stalled)
        }
        peripheral = nil
        connectionStartedAt = nil
        notifyChar = nil
        writeChar = nil
        pendingCharacteristicDiscoveries = 0
        fastReconnectTask = nil
        startScan(central)
    }

    private func startScan(_ central: CBCentralManager) {
        state = .scanning
        connectionStartedAt = nil
        // Scan broadly: some clones don't advertise their serial service, so
        // filtering by service UUID would miss them; we match in `discovered`.
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    private func armConnectionTimeout() {
        connectionTimeoutTask?.cancel()
        let timeout = connectionTimeout
        connectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.connectionTimedOut()
        }
    }

    private func connectionTimedOut() {
        guard shouldRun else { return }
        OBDLog.log("BLE: connection timed out after \(connectionTimeout) s")
        failReadiness(with: OBDError.connectionTimeout)
    }

    private func failReadiness(with error: Error) {
        guard shouldRun else { return }
        shouldRun = false
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        fastReconnectTask?.cancel()
        fastReconnectTask = nil
        central?.stopScan()
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        state = .failed(error)
        resumeReadyContinuations(throwing: error)
    }

    private func resumeReadyContinuations(throwing error: Error? = nil) {
        if let error {
            readyContinuations.forEach { $0.resume(throwing: error) }
        } else {
            readyContinuations.forEach { $0.resume() }
        }
        readyContinuations.removeAll()
    }
}

/// CoreBluetooth wants NSObject delegates with nonisolated callbacks; this
/// proxy trampolines them onto the actor.
private final class DelegateProxy: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private weak var owner: BLEConnection?
    /// Immutable after construction; `yield` and `finish` are thread-safe.
    private let rxContinuation: AsyncStream<Data>.Continuation

    init(owner: BLEConnection, rxContinuation: AsyncStream<Data>.Continuation) {
        self.owner = owner
        self.rxContinuation = rxContinuation
    }

    func finishRXStream() {
        rxContinuation.finish()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { [owner] in await owner?.centralStateChanged(state) }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        Task { [owner] in
            await owner?.discovered(peripheral, name: name, advertisedServices: services)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { [owner] in await owner?.connected(peripheral) }
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        Task { [owner] in await owner?.disconnected(peripheral, error: error) }
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        Task { [owner] in await owner?.disconnected(peripheral, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { [owner] in await owner?.servicesDiscovered(peripheral, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        Task { [owner] in
            await owner?.characteristicsDiscovered(peripheral, service: service, error: error)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        Task { [owner] in await owner?.notificationStateChanged(characteristic, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        // Yield synchronously on the (serial) delegate queue so the ordered
        // drain task in BLEConnection sees packets in arrival order.
        if let data = characteristic.value {
            _ = rxContinuation.yield(data)
        }
    }
}
