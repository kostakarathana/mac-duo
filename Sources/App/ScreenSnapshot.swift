import AppKit
import CoreImage
import ScreenCaptureKit

/// A captured frame of the built-in display plus pre-blurred copies for the glass effect.
struct Snapshot {
    let sharp: CGImage
    let soft: CGImage
    let heavy: CGImage
    let takenAt: Date
}

enum ScreenSnapshot {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    private static let ci = CIContext(options: [.cacheIntermediates: false])

    /// Captures the given display (excluding our own overlay windows) and prepares blur levels.
    static func capture(displayID: CGDirectDisplayID) async -> Snapshot? {
        guard hasPermission else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            cfg.width = Int(CGFloat(display.width) * scale)
            cfg.height = Int(CGFloat(display.height) * scale)
            cfg.showsCursor = false
            cfg.captureResolution = .best
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            return makeSnapshot(img)
        } catch {
            NSLog("MacDuo: capture failed: \(error)")
            return nil
        }
    }

    static func makeSnapshot(_ img: CGImage) -> Snapshot {
        Snapshot(sharp: img, soft: blurred(img, radius: 10) ?? img, heavy: blurred(img, radius: 34) ?? img, takenAt: Date())
    }

    /// Blur at quarter resolution — cheap, and the result is soft anyway.
    static func blurred(_ img: CGImage, radius: Double) -> CGImage? {
        let input = CIImage(cgImage: img)
        let s = 0.25
        let small = input.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let out = small.clampedToExtent()
            .applyingGaussianBlur(sigma: radius * s * 2)
            .cropped(to: small.extent)
        return ci.createCGImage(out, from: small.extent)
    }
}
