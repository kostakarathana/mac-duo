import Foundation
import IOKit.hid

/// Reads the MacBook hinge angle from the built-in "lid angle sensor" HID device
/// (Apple SPU, usage page 0x20 / usage 0x8A). No permissions required.
final class LidSensor {
    private let manager: IOHIDManager
    private var device: IOHIDDevice?

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDProductIDKey: 0x8104,
            kIOHIDPrimaryUsagePageKey: 0x20,
            kIOHIDPrimaryUsageKey: 0x8A,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        connect()
    }

    var isAvailable: Bool { device != nil || connect() }

    @discardableResult
    private func connect() -> Bool {
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return false }
        for d in set where IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
            device = d
            if read() != nil { return true }
        }
        device = nil
        return false
    }

    /// Current hinge angle in degrees (0 = shut), or nil if the sensor can't be read.
    func read() -> Double? {
        guard let d = device else { return nil }
        var buf = [UInt8](repeating: 0, count: 8)
        var len = CFIndex(buf.count)
        let r = IOHIDDeviceGetReport(d, kIOHIDReportTypeFeature, 1, &buf, &len)
        guard r == kIOReturnSuccess, len >= 3 else {
            device = nil // re-acquire after sleep / transient failure
            return nil
        }
        let raw = Int(buf[1]) | (Int(buf[2]) << 8)
        guard raw >= 0, raw <= 360 else { return nil }
        return Double(raw)
    }

    func readOrReconnect() -> Double? {
        if let a = read() { return a }
        return connect() ? read() : nil
    }
}
