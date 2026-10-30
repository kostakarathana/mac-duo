import Foundation

/// Turns raw power-key down/up events into "the user is holding it to turn the Mac off".
/// A quick tap (sleep / lock) never triggers; only a sustained hold does.
public struct PowerHoldDetector: Sendable {
    public enum Event: Equatable, Sendable {
        /// Key went down: grab a screenshot now so the fade can start instantly.
        case pressed
        /// Held long enough: play the glossy fade-away.
        case triggered
        /// Key released before the threshold: nothing happens.
        case tapped
        /// Key released after the fade played (the Mac didn't power off).
        case releasedAfterTrigger
    }

    public var holdThreshold: TimeInterval
    public private(set) var downAt: TimeInterval?
    public private(set) var triggered = false

    public init(holdThreshold: TimeInterval = 1.2) {
        self.holdThreshold = holdThreshold
    }

    public mutating func keyDown(at t: TimeInterval) -> [Event] {
        // Auto-repeat or a duplicate report from a second source: ignore.
        guard downAt == nil else { return [] }
        downAt = t; triggered = false
        return [.pressed]
    }

    public mutating func keyUp(at t: TimeInterval) -> [Event] {
        guard let d = downAt else { return [] }
        var ev = tick(at: t)
        downAt = nil
        if triggered { ev.append(.releasedAfterTrigger) } else if t - d < holdThreshold { ev.append(.tapped) }
        triggered = false
        return ev
    }

    public mutating func tick(at t: TimeInterval) -> [Event] {
        guard let d = downAt, !triggered, t - d >= holdThreshold else { return [] }
        triggered = true
        return [.triggered]
    }
}

/// Shared easing helpers used by both animations.
public enum Ease {
    public static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    public static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = clamp((x - e0) / (e1 - e0)); return t * t * (3 - 2 * t)
    }
    public static func inOut(_ x: Double) -> Double { smoothstep(0, 1, x) }
    public static func outCubic(_ x: Double) -> Double { let t = 1 - clamp(x); return 1 - t * t * t }
    /// 0 → 1 → 0 bump peaking at `peak`.
    public static func bump(_ x: Double, peak: Double = 0.5) -> Double {
        let x = clamp(x)
        return x < peak ? smoothstep(0, peak, x) : 1 - smoothstep(peak, 1, x)
    }
}

/// Everything the renderer needs for one frame, computed purely from progress so it can be tested.
public struct FrameParams: Equatable, Sendable {
    public var rotation: Double = 0        // degrees, about the hinge (bottom edge)
    public var scale: Double = 1
    public var cornerRadius: Double = 0
    public var softBlur: Double = 0        // opacity of the lightly blurred copy
    public var heavyBlur: Double = 0       // opacity of the heavily blurred copy
    public var blurReach: Double = 0       // 0 = blur only at free edge, 1 = blur reaches the hinge
    public var frost: Double = 0           // white glass tint
    public var shade: Double = 0           // black dimming
    public var sheen: Double = 0           // specular highlight strength
    public var sheenPosition: Double = 0   // 0...1 along its sweep
    public var panelOpacity: Double = 1

    public init() {}

    /// iPhone Duo-style fold: the desktop bends toward the hinge, sharp near the hinge and
    /// increasingly frosted toward the free (top) edge, dimming until it vanishes.
    public static func fold(_ p: Double) -> FrameParams {
        let p = Ease.clamp(p)
        var f = FrameParams()
        f.rotation = 78 * Ease.smoothstep(0, 1, p * 0.85 + 0.15 * p * p)
        f.scale = 1 - 0.06 * p
        f.cornerRadius = 28 * Ease.smoothstep(0, 0.4, p)
        f.softBlur = Ease.smoothstep(0, 0.3, p)
        f.heavyBlur = Ease.smoothstep(0.15, 0.65, p)
        f.blurReach = Ease.smoothstep(0.05, 0.95, p)
        f.frost = 0.14 * Ease.bump(p, peak: 0.45)
        f.shade = Ease.smoothstep(0.1, 0.95, p) * 0.92
        f.sheen = 0.55 * Ease.bump(p, peak: 0.4)
        f.sheenPosition = p
        f.panelOpacity = 1 - Ease.smoothstep(0.78, 1, p)
        return f
    }

    /// Glossy fade-away for power-off: a specular sweep across a pane of glass that frosts,
    /// recedes, and fades to black.
    public static func glossyFade(_ t: Double) -> FrameParams {
        let t = Ease.clamp(t)
        var f = FrameParams()
        f.scale = 1 - 0.07 * Ease.inOut(t)
        f.cornerRadius = 44 * Ease.smoothstep(0, 0.5, t)
        f.softBlur = Ease.smoothstep(0.05, 0.45, t)
        f.heavyBlur = Ease.smoothstep(0.3, 0.8, t)
        f.blurReach = 1
        f.frost = 0.22 * Ease.bump(t, peak: 0.35)
        f.shade = Ease.smoothstep(0.35, 0.95, t)
        f.sheen = 0.75 * Ease.bump(Ease.clamp((t - 0.03) / 0.7), peak: 0.45)
        f.sheenPosition = Ease.clamp((t - 0.03) / 0.7)
        f.panelOpacity = 1 - Ease.smoothstep(0.8, 1, t)
        return f
    }
}
