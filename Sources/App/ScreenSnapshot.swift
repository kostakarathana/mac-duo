import AppKit
import CoreImage
import ScreenCaptureKit

/// A captured frame of the built-in display plus progressively stronger blurred copies.
struct Snapshot {
    let sharp: CGImage
    /// Increasing blur radius; each step is a little more saturated, like Apple's materials.
    let levels: [CGImage]
    let takenAt: Date
    var soft: CGImage { levels[1] }
    var heavy: CGImage { levels[3] }
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

    static let blurRadii: [Double] = [6, 16, 32, 56, 90]   // Gaussian sigma, in pixels

    static func makeSnapshot(_ img: CGImage) -> Snapshot {
        let levels = blurRadii.enumerated().map { k, r in
            blurred(img, radius: r, saturation: 1 + 0.1 * Double(k + 1)) ?? img
        }
        return Snapshot(sharp: img, levels: levels, takenAt: Date())
    }

    /// Blur at reduced resolution — cheap, and the result is soft anyway. Light blurs keep
    /// half resolution so they don't look smeared.
    static func blurred(_ img: CGImage, radius: Double, saturation: Double) -> CGImage? {
        let input = CIImage(cgImage: img)
        let s = radius < 12 ? 0.5 : 0.25
        let small = input.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let out = small.clampedToExtent()
            .applyingGaussianBlur(sigma: radius * s)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: saturation])
            .cropped(to: small.extent)
        return ci.createCGImage(out, from: small.extent)
    }
}
