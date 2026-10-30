import Foundation

/// Tuning for telling a real lid close apart from an ordinary screen readjustment.
///
/// A readjustment is a small and/or slow change in angle. A close is a fast, large,
/// continuous drop. Because a started fold holds until the user touches the Mac, the
/// gate leans on speed and distance rather than waiting for a very low angle.
public struct DetectorConfig: Equatable, Sendable {
    /// The fold may only begin once the lid is below this angle (degrees).
    public var triggerAngle: Double = 85
    /// The lid must be moving shut at least this fast (degrees / second).
    public var minClosingSpeed: Double = 60
    /// The lid must have dropped at least this far from its recent peak.
    public var minDrop: Double = 22
    /// How far back "recent peak" looks (seconds).
    public var dropWindow: TimeInterval = 1.5
    /// At or below this angle the lid counts as shut.
    public var closedAngle: Double = 6
    /// If an unfold (lid reopening after a close) stops moving for this long, finish it.
    public var stallTimeout: TimeInterval = 1.0
    /// Below this speed the lid counts as "not moving".
    public var stallSpeed: Double = 6
    /// Closing faster than this means it's worth grabbing a screenshot, just in case.
    public var prearmSpeed: Double = 25
    /// Careful, slow closers: below this angle nobody is using the screen, so a
    /// steady downward motion is enough on its own.
    public var deepAngle: Double = 40
    public var deepSpeed: Double = 12

    public init() {}

    public enum Sensitivity: String, CaseIterable, Sendable {
        case relaxed, normal, strict
    }

    public static func preset(_ s: Sensitivity) -> DetectorConfig {
        var c = DetectorConfig()
        switch s {
        case .relaxed: c.triggerAngle = 95; c.minClosingSpeed = 45; c.minDrop = 18
        case .normal: break
        case .strict: c.triggerAngle = 70; c.minClosingSpeed = 80; c.minDrop = 30
        }
        return c
    }
}

public enum DetectorEvent: Equatable, Sendable {
    /// The lid started moving shut quickly; capture the screen now so it's ready.
    case prearm
    /// A real close was recognised; the fold animation starts at this angle.
    case beginFold(startAngle: Double)
    /// The lid reached the closed angle.
    case closed
    /// The lid is opening again after being closed.
    case beginUnfold
    /// Fully open again after an unfold; overlay can go away.
    case finished
}

/// Pure, clock-agnostic lid state machine. Feed it samples; it tells you what to draw.
public struct CloseDetector: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case folding(start: Double)
        case closed(start: Double)
        case unfolding(start: Double)
    }

    public private(set) var state: State = .idle
    /// 0 = fully visible desktop, 1 = fully folded away.
    public private(set) var progress: Double = 0
    public private(set) var velocity: Double = 0
    public private(set) var angle: Double = .nan

    public var config: DetectorConfig

    private var samples: [(t: TimeInterval, a: Double)] = []
    private var lastPrearm: TimeInterval = -.infinity
    private var lastAdvance: TimeInterval = 0

    public init(config: DetectorConfig = DetectorConfig()) {
        self.config = config
    }

    public var isActive: Bool { state != .idle }

    public mutating func reset() {
        state = .idle; progress = 0; samples.removeAll(); velocity = 0
    }

    /// The user touched the Mac (trackpad, click, key): drop the fold without waiting for the lid.
    public mutating func dismiss() {
        // Forget the motion that triggered it, or the same drop would re-trigger instantly.
        state = .idle; progress = 0; samples.removeAll(); velocity = 0
    }

    @discardableResult
    public mutating func update(angle a: Double, at t: TimeInterval) -> [DetectorEvent] {
        angle = a
        samples.append((t, a))
        let horizon = max(config.dropWindow, 0.2)
        while let first = samples.first, t - first.t > horizon { samples.removeFirst() }
        velocity = Self.slope(samples.filter { t - $0.t <= 0.15 })
        let recentPeak = samples.map(\.a).max() ?? a
        let drop = recentPeak - a

        var events: [DetectorEvent] = []
        let c = config

        switch state {
        case .idle:
            progress = 0
            if velocity <= -c.prearmSpeed, a < 125, t - lastPrearm > 1.0 {
                lastPrearm = t
                events.append(.prearm)
            }
            let fastEnough = velocity <= -c.minClosingSpeed
            let lowEnough = a <= c.triggerAngle
            let farEnough = drop >= c.minDrop
            // A slam can land on "closed" between two samples; still treat it as a close.
            let slammed = a <= c.closedAngle + 2 && farEnough
            let deep = a <= c.deepAngle && velocity <= -c.deepSpeed && farEnough
            if (fastEnough && lowEnough && farEnough) || deep || slammed {
                let start = a
                state = .folding(start: start)
                events.append(.beginFold(startAngle: start))
                if a <= c.closedAngle {
                    state = .closed(start: start); progress = 1
                    events.append(.closed)
                } else {
                    progress = Self.progress(a, start: start, closed: c.closedAngle)
                }
            }

        case .folding(let start):
            // Only ever moves forward: pausing or easing the lid back up holds the fold
            // where it is. The app dismisses it when the user touches the Mac.
            progress = max(progress, Self.progress(a, start: start, closed: c.closedAngle))
            if a <= c.closedAngle {
                state = .closed(start: start); progress = 1
                events.append(.closed)
            }

        case .closed(let start):
            progress = 1
            if a > c.closedAngle + 6 {
                state = .unfolding(start: start)
                lastAdvance = t
                progress = Self.progress(a, start: start, closed: c.closedAngle)
                events.append(.beginUnfold)
                if a >= start { state = .idle; progress = 0; events.append(.finished) }
            }

        case .unfolding(let start):
            progress = Self.progress(a, start: start, closed: c.closedAngle)
            if abs(velocity) > c.stallSpeed { lastAdvance = t }
            if a >= start || t - lastAdvance > c.stallTimeout * 1.5 {
                state = .idle; progress = 0
                events.append(.finished)
            } else if a <= c.closedAngle {
                state = .closed(start: start); progress = 1
                events.append(.closed)
            }
        }
        return events
    }

    static func progress(_ a: Double, start: Double, closed: Double) -> Double {
        guard start > closed else { return 1 }
        return min(1, max(0, (start - a) / (start - closed)))
    }

    /// Least-squares slope (units / second) of the samples.
    static func slope(_ s: [(t: TimeInterval, a: Double)]) -> Double {
        guard s.count >= 2 else { return 0 }
        let n = Double(s.count)
        let mt = s.map(\.t).reduce(0, +) / n
        let ma = s.map(\.a).reduce(0, +) / n
        var num = 0.0, den = 0.0
        for p in s { num += (p.t - mt) * (p.a - ma); den += (p.t - mt) * (p.t - mt) }
        return den > 0 ? num / den : 0
    }
}
