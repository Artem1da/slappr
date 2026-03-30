import Foundation
import IOKit
import IOKit.hid

/// Reads the Apple Silicon MEMS accelerometer via IOKit HID
/// and detects sudden impacts (slaps) based on acceleration threshold.
final class AccelerometerManager: ObservableObject {

    @Published var isMonitoring = false
    @Published var lastMagnitude: Double = 0.0
    @Published var statusMessage: String = "Готов к запуску"

    /// Sensitivity threshold in g-force delta. Lower = more sensitive.
    @Published var sensitivity: Double = 1.8

    /// Callback fired on main thread when a slap is detected.
    var onSlapDetected: (() -> Void)?

    private var device: IOHIDDevice?
    private var manager: IOHIDManager?
    private var pollingTimer: DispatchSourceTimer?
    private var lastSlapTime: Date = .distantPast
    private var baselineMagnitude: Double = 1.0

    private let cooldown: TimeInterval = 0.5

    // Report parsing: Apple Silicon accelerometer sends reports with
    // x/y/z as little-endian Int32 values. The exact offsets and report
    // size may vary by model, so we try common layouts.
    private var reportSize = 0
    private var xOffset = 0
    private var yOffset = 0
    private var zOffset = 0
    private let scaleFactor: Double = 65536.0

    deinit {
        stopMonitoring()
    }

    // MARK: - Public API

    func startMonitoring() {
        guard !isMonitoring else { return }

        updateStatus("Поиск акселерометра...")
        if openAccelerometer() {
            startPolling()
            DispatchQueue.main.async {
                self.isMonitoring = true
                self.statusMessage = "Мониторинг активен"
            }
        }
    }

    func stopMonitoring() {
        pollingTimer?.cancel()
        pollingTimer = nil

        if let device = device {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            self.device = nil
        }

        if let manager = manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = nil
        }

        DispatchQueue.main.async {
            self.isMonitoring = false
            self.statusMessage = "Мониторинг выключен"
        }
    }

    func toggleMonitoring() {
        if isMonitoring {
            stopMonitoring()
        } else {
            startMonitoring()
        }
    }

    // MARK: - IOKit HID Setup

    private func openAccelerometer() -> Bool {
        // Try multiple matching strategies
        let strategies: [() -> Bool] = [
            matchByProductName,
            matchByUsagePage,
            matchAllAndFilter
        ]

        for strategy in strategies {
            if strategy() {
                return true
            }
        }

        updateStatus("Акселерометр не найден")
        return false
    }

    /// Strategy 1: Match by product name "Accelerometer"
    private func matchByProductName() -> Bool {
        print("[Slappr] Trying match by product name 'Accelerometer'...")
        let matchingDict: [String: Any] = [
            kIOHIDProductKey: "Accelerometer"
        ]
        return tryOpenWithMatching(matchingDict)
    }

    /// Strategy 2: Match by HID usage page (Sensor / Motion)
    private func matchByUsagePage() -> Bool {
        // Try several usage page / usage combinations
        let combos: [(Int, Int, String)] = [
            (0x20, 0x73, "Sensor/Motion3D"),        // Sensor page, Accelerometer 3D
            (0x01, 0x38, "GenericDesktop/MultiAxis"), // Generic Desktop, Multi-Axis
            (0x01, 0x08, "GenericDesktop/MultiAxis2"),
        ]
        for (page, usage, name) in combos {
            print("[Slappr] Trying match by usage page: \(name) (0x\(String(page, radix: 16))/0x\(String(usage, radix: 16)))...")
            let matchingDict: [String: Any] = [
                kIOHIDDeviceUsagePageKey: page,
                kIOHIDDeviceUsageKey: usage
            ]
            if tryOpenWithMatching(matchingDict) {
                return true
            }
        }
        return false
    }

    /// Strategy 3: Open all HID devices and find one that looks like an accelerometer
    private func matchAllAndFilter() -> Bool {
        print("[Slappr] Trying to enumerate all HID devices...")

        cleanup()
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = mgr

        // Match all HID devices
        IOHIDManagerSetDeviceMatching(mgr, nil)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let openResult = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            print("[Slappr] Failed to open HID manager for enumeration: \(String(format: "0x%08x", openResult))")
            cleanup()
            return false
        }

        guard let deviceSet = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else {
            print("[Slappr] No HID devices found at all")
            cleanup()
            return false
        }

        print("[Slappr] Found \(deviceSet.count) HID devices total:")

        for dev in deviceSet {
            let product = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "unknown"
            let vendor = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int ?? 0
            let usagePage = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
            let usage = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
            let maxReportSize = IOHIDDeviceGetProperty(dev, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0

            print("[Slappr]   - \"\(product)\" vendor=0x\(String(vendor, radix: 16)) usagePage=0x\(String(usagePage, radix: 16)) usage=0x\(String(usage, radix: 16)) reportSize=\(maxReportSize)")

            // Check if this looks like an accelerometer
            let isAccelerometer = product.lowercased().contains("accel")
                || product.lowercased().contains("motion")
                || product.lowercased().contains("spu")
                || (usagePage == 0x20 && usage == 0x73)  // Sensor page, Accelerometer 3D
                || (usagePage == 0x20 && usage == 0x01)  // Sensor page, Sensor

            if isAccelerometer {
                print("[Slappr] >>> Found accelerometer candidate: \"\(product)\"")
                let devOpenResult = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
                if devOpenResult == kIOReturnSuccess {
                    self.device = dev
                    configureReportLayout(for: dev)
                    print("[Slappr] Accelerometer opened successfully!")
                    return true
                } else {
                    print("[Slappr] Failed to open device: \(String(format: "0x%08x", devOpenResult))")
                }
            }
        }

        print("[Slappr] No accelerometer found among HID devices")
        cleanup()
        return false
    }

    private func tryOpenWithMatching(_ matchingDict: [String: Any]) -> Bool {
        cleanup()
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = mgr

        IOHIDManagerSetDeviceMatching(mgr, matchingDict as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let openResult = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            print("[Slappr]   HID manager open failed: \(String(format: "0x%08x", openResult))")
            cleanup()
            return false
        }

        guard let deviceSet = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>,
              !deviceSet.isEmpty else {
            print("[Slappr]   No devices matched")
            cleanup()
            return false
        }

        print("[Slappr]   Found \(deviceSet.count) matching device(s)")

        for dev in deviceSet {
            let product = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "unknown"
            print("[Slappr]   Trying to open: \"\(product)\"")

            let devOpenResult = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
            if devOpenResult == kIOReturnSuccess {
                self.device = dev
                configureReportLayout(for: dev)
                print("[Slappr]   Opened successfully!")
                return true
            } else {
                print("[Slappr]   Failed to open: \(String(format: "0x%08x", devOpenResult))")
            }
        }

        cleanup()
        return false
    }

    private func configureReportLayout(for device: IOHIDDevice) {
        let maxReport = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
        print("[Slappr] Device max report size: \(maxReport) bytes")

        // Common layouts for Apple Silicon accelerometers
        if maxReport >= 22 {
            reportSize = 22
            xOffset = 2
            yOffset = 6
            zOffset = 10
        } else if maxReport >= 12 {
            reportSize = maxReport
            xOffset = 0
            yOffset = 4
            zOffset = 8
        } else {
            // Use whatever size we get
            reportSize = max(maxReport, 22)
            xOffset = 2
            yOffset = 6
            zOffset = 10
        }

        print("[Slappr] Using report layout: size=\(reportSize) x=\(xOffset) y=\(yOffset) z=\(zOffset)")
    }

    private func cleanup() {
        if let device = device {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            self.device = nil
        }
        if let manager = manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = nil
        }
    }

    private func updateStatus(_ msg: String) {
        print("[Slappr] \(msg)")
        DispatchQueue.main.async {
            self.statusMessage = msg
        }
    }

    // MARK: - Polling

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            self?.readAccelerometerData()
        }
        timer.resume()
        self.pollingTimer = timer
    }

    private func readAccelerometerData() {
        guard let device = device else { return }

        var report = [UInt8](repeating: 0, count: max(reportSize, 22))
        var length = report.count

        let result = IOHIDDeviceGetReport(
            device,
            kIOHIDReportTypeInput,
            0,
            &report,
            &length
        )

        guard result == kIOReturnSuccess, length >= 12 else {
            return
        }

        let x = readInt32(from: report, at: xOffset)
        let y = readInt32(from: report, at: yOffset)
        let z = readInt32(from: report, at: zOffset)

        let gX = Double(x) / scaleFactor
        let gY = Double(y) / scaleFactor
        let gZ = Double(z) / scaleFactor

        let magnitude = sqrt(gX * gX + gY * gY + gZ * gZ)

        DispatchQueue.main.async {
            self.lastMagnitude = magnitude
        }

        let delta = abs(magnitude - baselineMagnitude)

        if delta > sensitivity {
            let now = Date()
            if now.timeIntervalSince(lastSlapTime) > cooldown {
                lastSlapTime = now
                print("[Slappr] SLAP! delta=\(String(format: "%.2f", delta))g mag=\(String(format: "%.2f", magnitude))g")
                DispatchQueue.main.async {
                    self.onSlapDetected?()
                }
            }
        }

        baselineMagnitude = baselineMagnitude * 0.999 + magnitude * 0.001
    }

    // MARK: - Helpers

    private func readInt32(from data: [UInt8], at offset: Int) -> Int32 {
        guard offset + 4 <= data.count else { return 0 }
        return data.withUnsafeBufferPointer { buffer in
            let raw = UnsafeRawPointer(buffer.baseAddress! + offset)
            return raw.loadUnaligned(as: Int32.self)
        }
    }
}
