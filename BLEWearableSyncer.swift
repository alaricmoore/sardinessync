//
//  BLEWearableSyncer.swift
//  healthsync
//
//  iOS-side relay for the UV wearable.
//
//  Protocol is documented in uv-wearable/notes/BLE_PROTOCOL.md and locked at
//  the UUIDs below. Flow per sync session:
//
//    1. Scan for the service UUID, connect to the first UVW-* peripheral
//    2. Write the wearable token to AUTH. CoreBluetooth raises the iOS
//       Just-Works pairing prompt on first encrypted access; the write
//       completes only once the bond is established and the firmware
//       has accepted the token. From this point the link is encrypted.
//    3. Read STATUS (16B): boot_id, log_size, sync_pos, device_ms
//    4. Loop: read CHUNK → POST to /api/uv/ingest with same headers a
//       WiFi-direct sync would use → write ACK with the new cursor
//    5. Disconnect
//
//  A token mismatch does NOT fail the AUTH write — the firmware just
//  leaves g_authed=false and the next CHUNK read returns empty. We
//  detect that as "first chunk empty but logSize > syncPos" → auth
//  rejected; see the drain loop below.
//
//  CoreBluetooth's delegate callbacks are bridged to async/await with
//  one-at-a-time continuations stored on the class. Safe because the sync
//  flow is strictly serial: one read/write outstanding at any moment.
//

import Foundation
import CoreBluetooth

@MainActor
final class BLEWearableSyncer: NSObject, ObservableObject {

    // MARK: - UUIDs (must match firmware/notes/BLE_PROTOCOL.md exactly)
    static let serviceUUID = CBUUID(string: "50fe0ee3-3c3a-4fdf-805a-916c3ad37a2f")
    static let statusUUID  = CBUUID(string: "4427d05e-3b7b-40b4-9920-925d9902f161")
    static let chunkUUID   = CBUUID(string: "c33d16e5-f660-4b38-ae13-6b47d8e08534")
    static let ackUUID     = CBUUID(string: "dac3d6a1-1cf1-468c-9bf1-9f45d04c6d9d")
    static let authUUID    = CBUUID(string: "6f1d8e23-9a4f-4a1c-bc18-3e9d52c7f4ab")

    // MARK: - Published state for the UI
    @Published var statusMessage = ""
    @Published var lastResult    = ""
    @Published var isSyncing     = false
    @Published var bytesUploaded: UInt32 = 0
    @Published var bytesPending:  UInt32 = 0
    @Published var deviceName: String?

    // MARK: - CoreBluetooth state
    private var central:    CBCentralManager!
    private var peripheral: CBPeripheral?
    private var chars: [CBUUID: CBCharacteristic] = [:]

    // One outstanding continuation per delegate-event class. The flow only
    // ever has one of these live at a time; if that ever changes, gate them
    // explicitly to avoid resuming the wrong one.
    private var poweredOnCont:  CheckedContinuation<Void, Error>?
    private var scanCont:       CheckedContinuation<CBPeripheral, Error>?
    private var connectCont:    CheckedContinuation<Void, Error>?
    private var discoverCont:   CheckedContinuation<Void, Error>?
    private var readCont:       CheckedContinuation<Data, Error>?
    private var writeCont:      CheckedContinuation<Void, Error>?

    private var scanTimeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        // Defer CBCentralManager init until the first sync attempt so the
        // OS permission prompt only appears when the user actually taps Sync.
    }

    // MARK: - Public entry point

    /// Run one sync session. Returns the number of CSV bytes uploaded.
    /// Throws on any BLE / HTTP error; partial progress is durable on the
    /// device side because the firmware only advances sync_pos on ACK.
    func sync(baseURL: String, bearerToken: String) async throws -> UInt32 {
        guard !bearerToken.isEmpty else { throw BLEError.missingToken }
        guard let ingestURL = URL(string: baseURL + "/api/uv/ingest") else {
            throw BLEError.badURL
        }

        isSyncing  = true
        bytesUploaded = 0
        bytesPending  = 0
        deviceName  = nil
        lastResult = ""
        defer { isSyncing = false }

        if central == nil {
            statusMessage = "Initializing Bluetooth..."
            central = CBCentralManager(delegate: self, queue: nil)
        }

        statusMessage = "Waiting for Bluetooth..."
        try await waitPoweredOn()

        statusMessage = "Scanning for wearable..."
        let p = try await scanForWearable(timeout: 12)
        peripheral = p
        deviceName = p.name

        statusMessage = "Connecting..."
        try await connect(p)

        statusMessage = "Discovering services..."
        try await discover(p)

        guard let statusChar = chars[Self.statusUUID],
              let chunkChar  = chars[Self.chunkUUID],
              let ackChar    = chars[Self.ackUUID],
              let authChar   = chars[Self.authUUID]
        else { throw BLEError.missingChar }

        // AUTH first. This is the write that triggers Just-Works pairing on
        // first contact, so it may take a second or two while iOS shows the
        // pairing prompt. After the bond exists, subsequent connections skip
        // the prompt and this write returns immediately.
        guard let tokenData = bearerToken.data(using: .utf8) else {
            throw BLEError.missingToken
        }
        statusMessage = "Authenticating (may show pairing prompt)..."
        try await write(p, characteristic: authChar, value: tokenData)

        statusMessage = "Reading status..."
        let statusData = try await read(p, characteristic: statusChar)
        let s = parseStatus(statusData)
        bytesPending = (s.logSize > s.syncPos) ? (s.logSize - s.syncPos) : 0
        statusMessage = "\(bytesPending) B pending"

        // Drain loop. Empty CHUNK read = device is at EOF. But an empty FIRST
        // chunk when STATUS said there's pending data means the firmware's
        // g_authed flag is false — i.e. the token we wrote didn't match.
        var cursor = s.syncPos
        var total: UInt32 = 0
        var chunkIdx = 0
        while true {
            let chunk = try await read(p, characteristic: chunkChar)
            if chunk.isEmpty {
                if chunkIdx == 0 && s.logSize > s.syncPos {
                    throw BLEError.authRejected
                }
                break
            }

            try await upload(
                chunk,
                to: ingestURL,
                token: bearerToken,
                bootId: s.bootId,
                deviceMs: s.deviceMs
            )

            cursor += UInt32(chunk.count)
            total  += UInt32(chunk.count)
            bytesUploaded = total
            chunkIdx += 1
            statusMessage = "Uploaded chunk \(chunkIdx) (\(total)/\(bytesPending) B)"

            try await write(p, characteristic: ackChar, value: u32le(cursor))
        }

        central.cancelPeripheralConnection(p)
        peripheral = nil
        chars.removeAll()

        lastResult = total > 0
            ? "Synced \(total) B in \(chunkIdx) chunk\(chunkIdx == 1 ? "" : "s")"
            : "Nothing to sync — device is up to date"
        statusMessage = lastResult
        return total
    }

    // MARK: - Async wrappers around CoreBluetooth delegate callbacks

    private func waitPoweredOn() async throws {
        if central.state == .poweredOn { return }
        if central.state == .unauthorized { throw BLEError.unauthorized }
        if central.state == .unsupported  { throw BLEError.unsupported }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            poweredOnCont = c
        }
    }

    private func scanForWearable(timeout: TimeInterval) async throws -> CBPeripheral {
        // Filter by service UUID so we don't pick up unrelated peripherals
        // and so iOS can keep scanning more efficiently.
        central.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        scanTimeoutTask?.cancel()
        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self else { return }
            if let cont = self.scanCont {
                self.scanCont = nil
                self.central.stopScan()
                cont.resume(throwing: BLEError.scanTimeout)
            }
        }

        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<CBPeripheral, Error>) in
            scanCont = c
        }
    }

    private func connect(_ p: CBPeripheral) async throws {
        p.delegate = self
        central.connect(p, options: nil)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connectCont = c
        }
    }

    private func discover(_ p: CBPeripheral) async throws {
        p.discoverServices([Self.serviceUUID])
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            discoverCont = c
        }
    }

    private func read(_ p: CBPeripheral, characteristic: CBCharacteristic) async throws -> Data {
        p.readValue(for: characteristic)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            readCont = c
        }
    }

    private func write(_ p: CBPeripheral, characteristic: CBCharacteristic, value: Data) async throws {
        p.writeValue(value, for: characteristic, type: .withResponse)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            writeCont = c
        }
    }

    // MARK: - Parsing / encoding

    private struct DeviceStatus {
        let bootId: UInt32
        let logSize: UInt32
        let syncPos: UInt32
        let deviceMs: UInt32
    }

    private func parseStatus(_ data: Data) -> DeviceStatus {
        // 16 B, little-endian. Layout is fixed in BLE_PROTOCOL.md.
        precondition(data.count >= 16, "STATUS payload too short: \(data.count)")
        func u32(_ off: Int) -> UInt32 {
            data.subdata(in: off..<(off+4)).withUnsafeBytes { $0.load(as: UInt32.self) }
        }
        return DeviceStatus(bootId: u32(0), logSize: u32(4), syncPos: u32(8), deviceMs: u32(12))
    }

    private func u32le(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 4)
    }

    // MARK: - HTTPS relay to the Pi

    private func upload(
        _ chunk: Data, to url: URL, token: String,
        bootId: UInt32, deviceMs: UInt32
    ) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("text/csv",                 forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)",          forHTTPHeaderField: "Authorization")
        req.setValue(String(bootId),             forHTTPHeaderField: "X-Boot-Id")
        req.setValue(String(deviceMs),           forHTTPHeaderField: "X-Device-Ms")
        req.httpBody = chunk
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw BLEError.uploadFailed(code)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEWearableSyncer: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                if let c = poweredOnCont { poweredOnCont = nil; c.resume() }
            case .unauthorized:
                if let c = poweredOnCont { poweredOnCont = nil; c.resume(throwing: BLEError.unauthorized) }
            case .unsupported:
                if let c = poweredOnCont { poweredOnCont = nil; c.resume(throwing: BLEError.unsupported) }
            default:
                break  // .poweredOff / .resetting / .unknown — wait
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            // First hit wins — the service UUID filter already narrows this to
            // our wearable.
            guard let c = scanCont else { return }
            scanCont = nil
            scanTimeoutTask?.cancel()
            central.stopScan()
            c.resume(returning: peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            if let c = connectCont { connectCont = nil; c.resume() }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            let err = error ?? BLEError.connectFailed
            if let c = connectCont { connectCont = nil; c.resume(throwing: err) }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        // Disconnect in the middle of a read/write fails the outstanding op
        // so the UI sees a real error instead of hanging on a continuation.
        Task { @MainActor in
            let err = error ?? BLEError.disconnected
            if let c = readCont    { readCont    = nil; c.resume(throwing: err) }
            if let c = writeCont   { writeCont   = nil; c.resume(throwing: err) }
            if let c = connectCont { connectCont = nil; c.resume(throwing: err) }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEWearableSyncer: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let e = error {
                if let c = discoverCont { discoverCont = nil; c.resume(throwing: e) }
                return
            }
            guard let svc = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
                if let c = discoverCont { discoverCont = nil; c.resume(throwing: BLEError.missingService) }
                return
            }
            peripheral.discoverCharacteristics(
                [Self.statusUUID, Self.chunkUUID, Self.ackUUID, Self.authUUID], for: svc
            )
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            if let e = error {
                if let c = discoverCont { discoverCont = nil; c.resume(throwing: e) }
                return
            }
            chars.removeAll()
            for ch in service.characteristics ?? [] {
                chars[ch.uuid] = ch
            }
            if let c = discoverCont { discoverCont = nil; c.resume() }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if let e = error {
                if let c = readCont { readCont = nil; c.resume(throwing: e) }
                return
            }
            // value can be nil (empty read) which we treat as drained-EOF.
            let data = characteristic.value ?? Data()
            if let c = readCont { readCont = nil; c.resume(returning: data) }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if let e = error {
                if let c = writeCont { writeCont = nil; c.resume(throwing: e) }
                return
            }
            if let c = writeCont { writeCont = nil; c.resume() }
        }
    }
}

// MARK: - Errors

enum BLEError: LocalizedError {
    case unauthorized
    case unsupported
    case scanTimeout
    case connectFailed
    case disconnected
    case missingService
    case missingChar
    case missingToken
    case authRejected
    case badURL
    case uploadFailed(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized:      return "Bluetooth permission denied. Enable in Settings → healthsync."
        case .unsupported:       return "Bluetooth not supported on this device."
        case .scanTimeout:       return "Couldn't find the wearable. Make sure it's advertising (hold the button 1.5s) and within range."
        case .connectFailed:     return "Connection failed."
        case .disconnected:      return "Disconnected mid-sync. Try again."
        case .missingService:    return "Wearable found but advertised the wrong service. Firmware/UUID mismatch?"
        case .missingChar:       return "Wearable missing expected characteristics. Firmware/UUID mismatch?"
        case .missingToken:      return "Wearable API token is empty. Set it in the Wearable tab."
        case .authRejected:      return "Wearable rejected the token. Check that the value in Settings matches wearable_token in the Pi's config.json."
        case .badURL:            return "Server URL is malformed."
        case .uploadFailed(let code): return "Server rejected chunk (HTTP \(code))."
        }
    }
}
