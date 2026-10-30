import AppKit
import IOKit.hid

/// Watches the physical power button. Two independent sources, because Apple routes the
/// button differently across models/OS versions:
///  1. NX_SYSDEFINED events (aux key NX_POWER_KEY = 6, or the dedicated power-key subtype)
///     via a listen-only CGEventTap.
///  2. The consumer-control HID service (AppleM68Buttons, usage page 0x0C, usage 0x30).
/// Both need Input Monitoring permission. Duplicate downs/ups are fine — PowerHoldDetector
/// ignores repeats.
final class PowerButtonMonitor {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    private(set) var tapActive = false
    private(set) var hidActive = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var hid: IOHIDManager?
    private var isDown = false

    static var hasPermission: Bool { CGPreflightListenEventAccess() }
    static func requestPermission() { _ = CGRequestListenEventAccess() }

    func start() {
        startTap()
        startHID()
    }

    private func emit(_ down: Bool) {
        guard down != isDown else { return }
        isDown = down
        DispatchQueue.main.async { down ? self.onDown?() : self.onUp?() }
    }

    // MARK: CGEventTap

    private func startTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1) << 14 // NX_SYSDEFINED
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<PowerButtonMonitor>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
            } else if type.rawValue == 14 {
                me.handleSystemDefined(event)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: refcon)
        guard let tap else { return }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        tapActive = true
    }

    private func handleSystemDefined(_ cg: CGEvent) {
        guard let ev = NSEvent(cgEvent: cg) else { return }
        switch ev.subtype.rawValue {
        case 8: // NX_SUBTYPE_AUX_CONTROL_BUTTONS
            let keyCode = (ev.data1 & 0xFFFF0000) >> 16
            let state = (ev.data1 & 0xFF00) >> 8
            if keyCode == 6 { // NX_POWER_KEY
                if state == 0xA { emit(true) } else if state == 0xB { emit(false) }
            }
        case 1: // NX_SUBTYPE_POWER_KEY — down only on some models
            emit(true)
        default: break
        }
    }

    // MARK: HID consumer control

    private func startHID() {
        guard hid == nil else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(m, [
            [kIOHIDPrimaryUsagePageKey: 0x0C, kIOHIDPrimaryUsageKey: 0x01],
        ] as CFArray)
        IOHIDManagerSetInputValueMatching(m, [kIOHIDElementUsagePageKey: 0x0C, kIOHIDElementUsageKey: 0x30] as CFDictionary)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(m, { refcon, _, _, value in
            guard let refcon else { return }
            let me = Unmanaged<PowerButtonMonitor>.fromOpaque(refcon).takeUnretainedValue()
            let el = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(el) == 0x0C, IOHIDElementGetUsage(el) == 0x30 else { return }
            me.emit(IOHIDValueGetIntegerValue(value) != 0)
        }, refcon)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        hidActive = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        hid = m
    }

    func restart() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        if let h = hid { IOHIDManagerClose(h, IOOptionBits(kIOHIDOptionsTypeNone)) }
        tap = nil; source = nil; hid = nil; tapActive = false; hidActive = false
        start()
    }
}
