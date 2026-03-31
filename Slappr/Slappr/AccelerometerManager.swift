import Foundation
import IOKit
import IOKit.hid

/// Reads the Apple Silicon MEMS accelerometer via IOKit HID callbacks.
final class AccelerometerManager: ObservableObject {

    @Published var isMonitoring = false
    @Published var lastMagnitude: Double = 0.0
    @Published var statusMessage: String = "Готов к запуску"

    @Published var sensitivity: Double = 1.8

    var onSlapDetected: (() -> Void)?

    private var device: IOHIDDevice?
    private var lastSlapTime: Date = .distantPast
    private var baselineMagnitude: Double = 1.0
    private var reportBuffer = [UInt8](repeating: 0, count: 256)

    private let cooldown: TimeInterval = 0.5
    private var reportCount: Int = 0

    // Layout determined at runtime
    private var xOffset = 0
    private var yOffset = 0
    private var zOffset = 0
    private var valueSize = 4
    private var valueScale: Double = 65536.0

    deinit {
        stopMonitoring()
    }

    // MARK: - Public API

    func startMonitoring() {
        guard !isMonitoring else { return }
        updateStatus("Поиск акселерометра...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.findAndConnect()
        }
    }

    func stopMonitoring() {
        if let device = device {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            self.device = nil
        }
        DispatchQueue.main.async {
            self.isMonitoring = false
            self.statusMessage = "Мониторинг выключен"
        }
    }

    func toggleMonitoring() {
        if isMonitoring { stopMonitoring() } else { startMonitoring() }
    }

    // MARK: - Discovery

    private func findAndConnect() {
        // Try all AppleSPUHIDDevice services, pick the one with maxReportSize == 22
        if let dev = findSPUDevice() {
            DispatchQueue.main.async {
                self.device = dev
                self.registerCallback(on: dev)
                self.isMonitoring = true
                self.statusMessage = "Мониторинг активен"
            }
        } else {
            updateStatus("Акселерометр не найден")
        }
    }

    private func findSPUDevice() -> IOHIDDevice? {
        guard let matching = IOServiceMatching("AppleSPUHIDDevice") else { return nil }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        // Collect all services first so we can pick the best candidate
        var candidates: [(device: IOHIDDevice, reportSize: Int)] = []

        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            guard let hidDevice = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { continue }
            let dev = hidDevice as IOHIDDevice
            let maxReport = IOHIDDeviceGetProperty(dev, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0

            print("[Slappr] SPU service: maxReportSize=\(maxReport)")
            candidates.append((dev, maxReport))
        }

        // The real accelerometer on Apple Silicon has reportSize=22.
        // Prefer exactly 22, then 14, then others in ascending order.
        let filtered = candidates.filter { $0.reportSize >= 6 }
        let sorted = filtered.sorted { a, b in
            // Priority: 22 > 14 > everything else (smaller first)
            func priority(_ size: Int) -> Int {
                if size == 22 { return 0 }
                if size == 14 { return 1 }
                return 2 + size  // deprioritize large unknown devices
            }
            return priority(a.reportSize) < priority(b.reportSize)
        }

        print("[Slappr] Candidates (reportSize >= 6): \(sorted.map { $0.reportSize })")

        for candidate in sorted {
            let dev = candidate.device
            let size = candidate.reportSize

            let openResult = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
            guard openResult == kIOReturnSuccess else {
                print("[Slappr]   Failed to open device with reportSize=\(size): \(String(format: "0x%08x", openResult))")
                continue
            }

            // Schedule on main run loop so callbacks fire
            IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

            // Determine report layout based on size
            configureLayout(reportSize: size)

            print("[Slappr]   Opened device with reportSize=\(size). Layout: x=\(xOffset) y=\(yOffset) z=\(zOffset) valSize=\(valueSize) scale=\(valueScale)")
            return dev
        }

        return nil
    }

    private func configureLayout(reportSize: Int) {
        // Apple Silicon MacBook accelerometer: 22-byte report
        // Bytes 0-1: report ID / padding
        // Bytes 2-5: x (Int32 LE)
        // Bytes 6-9: y (Int32 LE)
        // Bytes 10-13: z (Int32 LE)
        // Scale: divide by 65536 to get g
        if reportSize >= 14 {
            xOffset = 2; yOffset = 6; zOffset = 10
            valueSize = 4; valueScale = 65536.0
        } else {
            // Smaller report: try Int16
            xOffset = 0; yOffset = 2; zOffset = 4
            valueSize = 2; valueScale = 256.0
        }
    }

    // MARK: - Callback

    private func registerCallback(on device: IOHIDDevice) {
        // reportBuffer must stay alive — it's a property on self
        reportBuffer = [UInt8](repeating: 0, count: 256)

        // We pass `self` as context via an unretained pointer
        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDDeviceRegisterInputReportCallback(
            device,
            &reportBuffer,
            reportBuffer.count,
            { context, result, sender, type, reportID, report, reportLength in
                guard let ctx = context else { return }
                let manager = Unmanaged<AccelerometerManager>.fromOpaque(ctx).takeUnretainedValue()
                manager.handleReport(report: report, length: reportLength)
            },
            context
        )

        print("[Slappr] Input report callback registered")
    }

    private func handleReport(report: UnsafePointer<UInt8>, length: CFIndex) {
        guard length >= xOffset + valueSize else { return }

        let bytes = UnsafeBufferPointer(start: report, count: length)
        let arr = Array(bytes)

        var gX: Double = 0, gY: Double = 0, gZ: Double = 0

        if valueSize == 4 {
            gX = Double(readInt32(from: arr, at: xOffset)) / valueScale
            gY = Double(readInt32(from: arr, at: yOffset)) / valueScale
            gZ = Double(readInt32(from: arr, at: zOffset)) / valueScale
        } else {
            gX = Double(readInt16(from: arr, at: xOffset)) / valueScale
            gY = Double(readInt16(from: arr, at: yOffset)) / valueScale
            gZ = Double(readInt16(from: arr, at: zOffset)) / valueScale
        }

        let magnitude = sqrt(gX * gX + gY * gY + gZ * gZ)

        // Debug: log first 5 reports to verify data parsing
        reportCount += 1
        if reportCount <= 5 {
            let hexBytes = arr.prefix(min(24, arr.count)).map { String(format: "%02x", $0) }.joined(separator: " ")
            print("[Slappr] Report #\(reportCount) len=\(length) raw: \(hexBytes)")
            print("[Slappr]   x=\(String(format: "%.4f", gX))g y=\(String(format: "%.4f", gY))g z=\(String(format: "%.4f", gZ))g mag=\(String(format: "%.4f", magnitude))g")
        }

        DispatchQueue.main.async {
            self.lastMagnitude = magnitude
        }

        let delta = abs(magnitude - baselineMagnitude)
        if delta > sensitivity {
            let now = Date()
            if now.timeIntervalSince(lastSlapTime) > cooldown {
                lastSlapTime = now
                print("[Slappr] SLAP! Δ\(String(format: "%.2f", delta))g mag=\(String(format: "%.2f", magnitude))g")
                DispatchQueue.main.async { self.onSlapDetected?() }
            }
        }

        baselineMagnitude = baselineMagnitude * 0.999 + magnitude * 0.001
    }

    // MARK: - Helpers

    private func updateStatus(_ msg: String) {
        print("[Slappr] \(msg)")
        DispatchQueue.main.async { self.statusMessage = msg }
    }

    private func readInt32(from data: [UInt8], at offset: Int) -> Int32 {
        guard offset + 4 <= data.count else { return 0 }
        return data.withUnsafeBufferPointer { buf in
            UnsafeRawPointer(buf.baseAddress! + offset).loadUnaligned(as: Int32.self)
        }
    }

    private func readInt16(from data: [UInt8], at offset: Int) -> Int16 {
        guard offset + 2 <= data.count else { return 0 }
        return data.withUnsafeBufferPointer { buf in
            UnsafeRawPointer(buf.baseAddress! + offset).loadUnaligned(as: Int16.self)
        }
    }
}
