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
    /// Lifting the lid this far back up from its lowest point mid-fold counts as reopening.
    public var reopenRise: Double = 12
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
    /// The lid is coming back up (mid-fold or after a close): return to the desktop now.
    case reopened
}

/// Pure, clock-agnostic lid state machine. Feed it samples; it tells you what to draw.
public struct CloseDetector: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case folding(start: Double)
        case closed(start: Double)
    }

    public private(set) var state: State = .idle
    /// 0 = fully visible desktop, 1 = fully folded away.
    public private(set) var progress: Double = 0
    public private(set) var velocity: Double = 0
    public private(set) var angle: Double = .nan

    public var config: DetectorConfig

    private var samples: [(t: TimeInterval, a: Double)] = []
    private var lastPrearm: TimeInterval = -.infinity
    private var lowest: Double = .infinity

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
        state = .idle; progress = 0; samples.removeAll(); velocity = 0; lowest = .infinity
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
                lowest = a
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
            // Only ever moves forward: pausing holds the fold where it is (the app dismisses
            // it when the user touches the Mac). Lifting the lid back up ends it.
            lowest = min(lowest, a)
            if a >= lowest + c.reopenRise {
                reopen(&events)
                break
            }
            progress = max(progress, Self.progress(a, start: start, closed: c.closedAngle))
            if a <= c.closedAngle {
                state = .closed(start: start); progress = 1
                events.append(.closed)
            }

        case .closed:
            progress = 1
            if a > c.closedAngle + 6 { reopen(&events) }
        }
        return events
    }

    private mutating func reopen(_ events: inout [DetectorEvent]) {
        // Forget the closing motion so it can't immediately count as a new close.
        state = .idle; progress = 0; lowest = .infinity
        if let last = samples.last { samples = [last] }
        events.append(.reopened)
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
