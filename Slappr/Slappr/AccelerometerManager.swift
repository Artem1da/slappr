import Foundation
import IOKit
import IOKit.hid

/// Reads the Apple Silicon MEMS accelerometer via IOKit HID
/// and detects sudden impacts (slaps) based on acceleration threshold.
final class AccelerometerManager: ObservableObject {

    @Published var isMonitoring = false
    @Published var lastMagnitude: Double = 0.0

    /// Sensitivity threshold in g-force delta. Lower = more sensitive.
    @Published var sensitivity: Double = 1.8

    /// Callback fired on main thread when a slap is detected.
    var onSlapDetected: (() -> Void)?

    private var device: IOHIDDevice?
    private var manager: IOHIDManager?
    private var pollingTimer: DispatchSourceTimer?
    private var lastSlapTime: Date = .distantPast
    private var baselineMagnitude: Double = 1.0 // ~1g from gravity

    /// Cooldown between slap detections (seconds).
    private let cooldown: TimeInterval = 0.5

    // MARK: - Report parsing constants
    // Apple Silicon accelerometer HID report layout:
    // 22 bytes total, x/y/z as Int32 at byte offsets 2, 6, 10
    // Divide by 65536.0 to get acceleration in g
    private let reportLength = 22
    private let xOffset = 2
    private let yOffset = 6
    private let zOffset = 10
    private let scaleFactor: Double = 65536.0

    deinit {
        stopMonitoring()
    }

    // MARK: - Public API

    func startMonitoring() {
        guard !isMonitoring else { return }

        if openAccelerometer() {
            startPolling()
            DispatchQueue.main.async {
                self.isMonitoring = true
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
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        // Match AppleSPUHIDDevice (Apple Silicon MEMS accelerometer)
        let matchingDict: [String: Any] = [
            kIOHIDProductKey: "Accelerometer"
        ]

        IOHIDManagerSetDeviceMatching(manager, matchingDict as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            print("[Slappr] Failed to open HID manager: \(openResult)")
            return false
        }

        // Get matching devices
        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let accelerometer = deviceSet.first else {
            print("[Slappr] No accelerometer device found. Is this an Apple Silicon Mac?")
            // Try alternative matching
            return openAccelerometerFallback()
        }

        self.device = accelerometer

        let deviceOpenResult = IOHIDDeviceOpen(accelerometer, IOOptionBits(kIOHIDOptionsTypeNone))
        guard deviceOpenResult == kIOReturnSuccess else {
            print("[Slappr] Failed to open accelerometer device: \(deviceOpenResult)")
            return false
        }

        print("[Slappr] Accelerometer connected successfully")
        return true
    }

    /// Fallback: try matching by usage page (Generic Desktop / Motion)
    private func openAccelerometerFallback() -> Bool {
        guard let manager = self.manager else { return false }

        // Usage Page 0x01 (Generic Desktop), Usage 0x00D (Portable Device Motion)
        // or try matching all HID devices and filter
        let matchingDict: [String: Any] = [
            kIOHIDDeviceUsagePageKey: 0x01,  // Generic Desktop
            kIOHIDDeviceUsageKey: 0x38       // Multi-Axis Controller
        ]

        IOHIDManagerSetDeviceMatching(manager, matchingDict as CFDictionary)

        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let accelerometer = deviceSet.first else {
            print("[Slappr] No accelerometer found via fallback matching either.")
            return false
        }

        self.device = accelerometer

        let deviceOpenResult = IOHIDDeviceOpen(accelerometer, IOOptionBits(kIOHIDOptionsTypeNone))
        guard deviceOpenResult == kIOReturnSuccess else {
            print("[Slappr] Failed to open accelerometer device (fallback): \(deviceOpenResult)")
            return false
        }

        print("[Slappr] Accelerometer connected via fallback matching")
        return true
    }

    // MARK: - Polling

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        // Poll at 60 Hz
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            self?.readAccelerometerData()
        }
        timer.resume()
        self.pollingTimer = timer
    }

    private func readAccelerometerData() {
        guard let device = device else { return }

        var report = [UInt8](repeating: 0, count: reportLength)
        var reportLength = report.count

        let result = IOHIDDeviceGetReport(
            device,
            kIOHIDReportTypeInput,
            0,  // Report ID
            &report,
            &reportLength
        )

        guard result == kIOReturnSuccess, reportLength >= self.reportLength else {
            return
        }

        // Parse x, y, z acceleration values (Int32 at known offsets)
        let x = readInt32(from: report, at: xOffset)
        let y = readInt32(from: report, at: yOffset)
        let z = readInt32(from: report, at: zOffset)

        let gX = Double(x) / scaleFactor
        let gY = Double(y) / scaleFactor
        let gZ = Double(z) / scaleFactor

        let magnitude = sqrt(gX * gX + gY * gY + gZ * gZ)

        // Update displayed magnitude on main thread
        DispatchQueue.main.async {
            self.lastMagnitude = magnitude
        }

        // Detect slap: sudden spike above baseline + threshold
        let delta = abs(magnitude - baselineMagnitude)

        if delta > sensitivity {
            let now = Date()
            if now.timeIntervalSince(lastSlapTime) > cooldown {
                lastSlapTime = now
                print("[Slappr] SLAP detected! delta=\(String(format: "%.2f", delta))g, magnitude=\(String(format: "%.2f", magnitude))g")
                DispatchQueue.main.async {
                    self.onSlapDetected?()
                }
            }
        }

        // Slowly adapt baseline using exponential moving average
        // This handles gradual orientation changes without masking impacts
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
