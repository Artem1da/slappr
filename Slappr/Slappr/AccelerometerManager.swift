import Foundation
import IOKit
import IOKit.hid

/// Reads the Apple Silicon MEMS accelerometer via IOKit
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
    private var pollingTimer: DispatchSourceTimer?
    private var lastSlapTime: Date = .distantPast
    private var baselineMagnitude: Double = 1.0

    private let cooldown: TimeInterval = 0.5
    private let scaleFactor: Double = 65536.0

    // Report layout - determined at runtime
    private var reportSize = 0
    private var xOffset = 0
    private var yOffset = 0
    private var zOffset = 0
    private var valueSize = 4 // bytes per axis: 4 = Int32, 2 = Int16
    private var valueScale: Double = 65536.0

    deinit {
        stopMonitoring()
    }

    // MARK: - Public API

    func startMonitoring() {
        guard !isMonitoring else { return }

        updateStatus("Поиск акселерометра...")

        if findAccelerometer() {
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

    // MARK: - Accelerometer Discovery

    private func findAccelerometer() -> Bool {
        // Strategy 1: Direct IOService matching (most reliable for Apple Silicon)
        if let dev = findViaIOService("AppleSPUHIDDevice") {
            self.device = dev
            return true
        }

        // Strategy 2: Try other known service names
        for serviceName in ["AppleEmbeddedAccelerometer", "SMCMotionSensor", "IOAccelerator"] {
            if let dev = findViaIOService(serviceName) {
                self.device = dev
                return true
            }
        }

        // Strategy 3: HID manager — enumerate ALL and find by probing
        if let dev = findViaHIDManagerProbing() {
            self.device = dev
            return true
        }

        updateStatus("Акселерометр не найден")
        return false
    }

    /// Find accelerometer by IOService class matching and create HIDDevice from it
    private func findViaIOService(_ className: String) -> IOHIDDevice? {
        print("[Slappr] Searching IOService for '\(className)'...")

        guard let matching = IOServiceMatching(className) else {
            print("[Slappr]   Could not create matching dict")
            return nil
        }

        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else {
            print("[Slappr]   No services found (kr=\(kr))")
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        var serviceIndex = 0

        while service != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
                serviceIndex += 1
            }

            // Get service info for logging
            var className = [CChar](repeating: 0, count: 256)
            IOObjectGetClass(service, &className)
            let classStr = String(cString: className)
            print("[Slappr]   Service[\(serviceIndex)]: class=\(classStr)")

            // Create an IOHIDDevice from this service
            let hidDevice = IOHIDDeviceCreate(kCFAllocatorDefault, service)
            guard let dev = hidDevice else {
                print("[Slappr]   Could not create HID device from service")
                continue
            }

            let device = dev as IOHIDDevice
            let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
            let maxReport = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0

            print("[Slappr]   Product: \"\(product)\", maxReportSize: \(maxReport)")

            let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard openResult == kIOReturnSuccess else {
                print("[Slappr]   Failed to open: \(String(format: "0x%08x", openResult))")
                continue
            }

            // Try to read a report and validate it looks like accelerometer data
            if validateAccelerometerDevice(device, maxReportSize: maxReport) {
                print("[Slappr]   Accelerometer found and validated!")
                return device
            } else {
                print("[Slappr]   Device opened but doesn't produce accelerometer data")
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            }
        }

        print("[Slappr]   No accelerometer found via IOService '\(className)'")
        return nil
    }

    /// Enumerate all HID devices and probe each one for accelerometer-like data
    private func findViaHIDManagerProbing() -> IOHIDDevice? {
        print("[Slappr] Probing all HID devices...")

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(mgr, nil)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        guard IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            print("[Slappr]   Failed to open HID manager")
            return nil
        }

        guard let deviceSet = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else {
            print("[Slappr]   No HID devices")
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            return nil
        }

        print("[Slappr]   Total HID devices: \(deviceSet.count)")

        // Filter to reasonable accelerometer candidates
        let candidates = deviceSet.filter { dev in
            let product = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? ""
            let maxReport = IOHIDDeviceGetProperty(dev, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
            let usagePage = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0

            let nameMatch = product.lowercased().contains("accel")
                || product.lowercased().contains("motion")
                || product.lowercased().contains("spu")
            let sensorPage = usagePage == 0x20
            let sizeOk = maxReport >= 4

            return (nameMatch || sensorPage) && sizeOk
        }

        print("[Slappr]   Candidates after filter: \(candidates.count)")

        for dev in candidates {
            let product = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "unknown"
            let maxReport = IOHIDDeviceGetProperty(dev, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
            print("[Slappr]   Probing: \"\(product)\" reportSize=\(maxReport)")

            let openResult = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
            guard openResult == kIOReturnSuccess else {
                print("[Slappr]     Failed to open")
                continue
            }

            if validateAccelerometerDevice(dev, maxReportSize: maxReport) {
                print("[Slappr]     Valid accelerometer!")
                // Keep the manager alive since the device belongs to it
                return dev
            }

            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        print("[Slappr]   No valid accelerometer found via probing")
        return nil
    }

    /// Try reading from device and check if data looks like accelerometer output (~1g magnitude)
    private func validateAccelerometerDevice(_ device: IOHIDDevice, maxReportSize: Int) -> Bool {
        // Try different report layouts
        let layouts: [(size: Int, xOff: Int, yOff: Int, zOff: Int, valSize: Int, scale: Double, name: String)] = [
            (22, 2, 6, 10, 4, 65536.0, "22b/Int32@2,6,10"),
            (16, 0, 4, 8, 4, 65536.0, "16b/Int32@0,4,8"),
            (12, 0, 4, 8, 4, 65536.0, "12b/Int32@0,4,8"),
            (8, 0, 2, 4, 2, 256.0, "8b/Int16@0,2,4"),
            (8, 2, 4, 6, 2, 256.0, "8b/Int16@2,4,6"),
            (6, 0, 2, 4, 2, 256.0, "6b/Int16@0,2,4"),
        ]

        let readSize = max(maxReportSize, 22)

        for layout in layouts {
            if layout.size > readSize { continue }

            var report = [UInt8](repeating: 0, count: readSize)
            var length = readSize

            let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, 0, &report, &length)

            guard result == kIOReturnSuccess, length >= layout.xOff + layout.valSize else {
                continue
            }

            var gX: Double = 0
            var gY: Double = 0
            var gZ: Double = 0

            if layout.valSize == 4 {
                let x = readInt32(from: report, at: layout.xOff)
                let y = readInt32(from: report, at: layout.yOff)
                let z = readInt32(from: report, at: layout.zOff)
                gX = Double(x) / layout.scale
                gY = Double(y) / layout.scale
                gZ = Double(z) / layout.scale
            } else if layout.valSize == 2 {
                let x = readInt16(from: report, at: layout.xOff)
                let y = readInt16(from: report, at: layout.yOff)
                let z = readInt16(from: report, at: layout.zOff)
                gX = Double(x) / layout.scale
                gY = Double(y) / layout.scale
                gZ = Double(z) / layout.scale
            }

            let magnitude = sqrt(gX * gX + gY * gY + gZ * gZ)

            print("[Slappr]     Layout \(layout.name): x=\(String(format: "%.3f", gX)) y=\(String(format: "%.3f", gY)) z=\(String(format: "%.3f", gZ)) mag=\(String(format: "%.3f", magnitude))g")

            // A device at rest should read roughly 1g (0.7 - 1.5g is reasonable)
            if magnitude > 0.7 && magnitude < 1.5 {
                print("[Slappr]     ✓ Looks like valid accelerometer data!")
                self.reportSize = readSize
                self.xOffset = layout.xOff
                self.yOffset = layout.yOff
                self.zOffset = layout.zOff
                self.valueSize = layout.valSize
                self.valueScale = layout.scale
                self.baselineMagnitude = magnitude
                return true
            }
        }

        // Also dump raw bytes for debugging
        var report = [UInt8](repeating: 0, count: max(maxReportSize, 22))
        var length = report.count
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, 0, &report, &length)
        if result == kIOReturnSuccess {
            let hex = report.prefix(min(length, 32)).map { String(format: "%02x", $0) }.joined(separator: " ")
            print("[Slappr]     Raw bytes (\(length)): \(hex)")
        }

        return false
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

        var report = [UInt8](repeating: 0, count: reportSize)
        var length = reportSize

        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, 0, &report, &length)
        guard result == kIOReturnSuccess else { return }

        var gX: Double = 0
        var gY: Double = 0
        var gZ: Double = 0

        if valueSize == 4 {
            let x = readInt32(from: report, at: xOffset)
            let y = readInt32(from: report, at: yOffset)
            let z = readInt32(from: report, at: zOffset)
            gX = Double(x) / valueScale
            gY = Double(y) / valueScale
            gZ = Double(z) / valueScale
        } else if valueSize == 2 {
            let x = readInt16(from: report, at: xOffset)
            let y = readInt16(from: report, at: yOffset)
            let z = readInt16(from: report, at: zOffset)
            gX = Double(x) / valueScale
            gY = Double(y) / valueScale
            gZ = Double(z) / valueScale
        }

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

    private func readInt16(from data: [UInt8], at offset: Int) -> Int16 {
        guard offset + 2 <= data.count else { return 0 }
        return data.withUnsafeBufferPointer { buffer in
            let raw = UnsafeRawPointer(buffer.baseAddress! + offset)
            return raw.loadUnaligned(as: Int16.self)
        }
    }
}
