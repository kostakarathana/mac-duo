import Foundation

// Minimal test harness (no XCTest needed, runs with only the Command Line Tools).
var failures = 0, passes = 0
func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    if cond { passes += 1 } else { failures += 1; print("  ✗ line \(line): \(msg)") }
}
func test(_ name: String, _ body: () -> Void) {
    let before = failures
    body()
    print(failures == before ? "✓ \(name)" : "✗ \(name)")
}

/// Plays a piecewise-linear lid trace through a detector at 60 Hz with optional sensor jitter.
struct Trace {
    var points: [(t: Double, a: Double)]
    var jitter: Double = 0
    func run(_ cfg: DetectorConfig = DetectorConfig(), seed: UInt64 = 1) -> (events: [DetectorEvent], progress: [Double], det: CloseDetector) {
        var d = CloseDetector(config: cfg)
        var rng = seed
        var events: [DetectorEvent] = [], prog: [Double] = []
        let end = points.last!.t
        var t = 0.0
        while t <= end + 1e-9 {
            var a = interp(t)
            if jitter > 0 {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                a += (Double(rng >> 33) / Double(1 << 31) - 0.5) * 2 * jitter
            }
            a = a.rounded() // the real sensor reports whole degrees
            events += d.update(angle: a, at: t)
            prog.append(d.progress)
            t += 1.0 / 60
        }
        return (events, prog, d)
    }
    func interp(_ t: Double) -> Double {
        for i in 1..<points.count where t <= points[i].t {
            let (t0, a0) = points[i - 1], (t1, a1) = points[i]
            let u = t1 > t0 ? (t - t0) / (t1 - t0) : 1
            return a0 + (a1 - a0) * u
        }
        return points.last!.a
    }
}
func folded(_ e: [DetectorEvent]) -> Bool { e.contains { if case .beginFold = $0 { return true }; return false } }

// MARK: - Screen readjustments must never fold

test("idle at a typing angle with sensor noise") {
    let r = Trace(points: [(0, 110), (5, 110)], jitter: 1.5).run()
    check(!folded(r.events), "folded while idle: \(r.events)")
}
test("slow readjust 118° → 88°") {
    let r = Trace(points: [(0, 118), (2.5, 88), (4, 88)], jitter: 0.5).run()
    check(!folded(r.events), "\(r.events)")
}
test("quick nudge 125° → 95°") {
    let r = Trace(points: [(0, 125), (0.3, 95), (2, 95)]).run()
    check(!folded(r.events), "\(r.events)")
}
test("fast tilt down to 70° (watching from above)") {
    let r = Trace(points: [(0, 110), (0.4, 70), (3, 70)]).run()
    check(!folded(r.events), "\(r.events)")
}
test("slow lean to 60° to block glare") {
    let r = Trace(points: [(0, 105), (2.0, 60), (4, 60)]).run()
    check(!folded(r.events), "\(r.events)")
}
test("repeated small wobbles 95–110°") {
    var pts: [(Double, Double)] = []
    for i in 0..<20 { pts.append((Double(i) * 0.25, i % 2 == 0 ? 95 : 110)) }
    let r = Trace(points: pts, jitter: 1).run()
    check(!folded(r.events), "\(r.events)")
}
test("strict preset ignores a moderate dip to 50°") {
    let r = Trace(points: [(0, 100), (0.6, 50), (3, 50)]).run(.preset(.strict))
    check(!folded(r.events), "\(r.events)")
}

// MARK: - Real closes must fold

test("normal close 110° → 0° in 0.8 s") {
    let r = Trace(points: [(0, 110), (0.1, 110), (0.9, 0), (1.5, 0)], jitter: 0.5).run()
    check(folded(r.events), "no fold: \(r.events)")
    check(r.events.contains(.closed), "never closed")
    check(r.progress.last == 1, "progress \(r.progress.last!)")
    check(!r.events.contains(.cancel), "cancelled")
}
test("fold progress tracks the lid smoothly (no big jumps)") {
    let r = Trace(points: [(0, 110), (1.0, 0), (1.3, 0)]).run()
    var maxJump = 0.0
    for i in 1..<r.progress.count { maxJump = max(maxJump, r.progress[i] - r.progress[i - 1]) }
    check(maxJump < 0.12, "max per-frame jump \(maxJump)")
}
test("slam shut in 0.15 s") {
    let r = Trace(points: [(0, 110), (0.15, 0), (0.5, 0)]).run()
    check(folded(r.events) && r.events.contains(.closed), "\(r.events)")
}
test("careful slow close over 3 s") {
    let r = Trace(points: [(0, 105), (3, 0), (3.5, 0)]).run()
    check(folded(r.events) && r.events.contains(.closed), "\(r.events)")
    // The fold must start well before the very end, so it is visible.
    if let i = r.progress.firstIndex(where: { $0 > 0 }) {
        check(Double(i) / 60 < 2.8, "fold began too late at \(Double(i) / 60)s")
    }
}
test("close with a pause near the end still completes") {
    let r = Trace(points: [(0, 110), (0.5, 40), (0.8, 15), (1.3, 15), (1.5, 0), (2, 0)]).run()
    check(r.events.contains(.closed), "\(r.events)")
}
test("every preset folds a normal close") {
    for s in DetectorConfig.Sensitivity.allCases {
        let r = Trace(points: [(0, 110), (0.8, 0), (1.2, 0)], jitter: 0.5).run(.preset(s))
        check(r.events.contains(.closed), "\(s): \(r.events)")
    }
}

// MARK: - Change of mind

test("start closing then reopen cancels and returns to clear") {
    let r = Trace(points: [(0, 110), (0.5, 25), (0.9, 110), (1.5, 110)]).run()
    check(folded(r.events), "should have started")
    check(r.events.contains(.cancel), "\(r.events)")
    check(r.progress.last == 0 && r.det.state == .idle, "not cleared")
}
test("start closing then hold mid-way cancels after stall") {
    let r = Trace(points: [(0, 110), (0.6, 35), (3, 35)]).run()
    check(folded(r.events) && r.events.contains(.cancel), "\(r.events)")
    check(r.det.state == .idle, "\(r.det.state)")
}
test("close then reopen unfolds and finishes") {
    let r = Trace(points: [(0, 110), (0.8, 0), (2, 0), (2.8, 110), (3.5, 110)]).run()
    let e = r.events
    check(e.contains(.closed) && e.contains(.beginUnfold) && e.contains(.finished), "\(e)")
    check(r.det.state == .idle && r.progress.last == 0, "\(r.det.state)")
}
test("waking with the lid already open (sensor jumped) finishes immediately") {
    var d = CloseDetector()
    var t = 0.0
    for a in stride(from: 110.0, through: 0, by: -3) { d.update(angle: a, at: t); t += 1 / 60 }
    if case .closed = d.state {} else { check(false, "not closed: \(d.state)") }
    let ev = d.update(angle: 112, at: t + 30)
    check(ev.contains(.finished) && d.state == .idle, "\(ev)")
}
test("prearm fires early, before the fold, and is rate-limited") {
    let r = Trace(points: [(0, 115), (0.8, 0), (1.0, 0)]).run()
    let pre = r.events.filter { $0 == .prearm }.count
    check(pre == 1, "prearm count \(pre)")
    check(r.events.first == .prearm, "first event \(String(describing: r.events.first))")
}

// MARK: - Power button

test("tap does not trigger") {
    var p = PowerHoldDetector(holdThreshold: 1.2)
    check(p.keyDown(at: 0) == [.pressed], "")
    check(p.tick(at: 0.4).isEmpty, "")
    check(p.keyUp(at: 0.5) == [.tapped], "")
}
test("hold triggers once, release reported") {
    var p = PowerHoldDetector(holdThreshold: 1.2)
    _ = p.keyDown(at: 0)
    check(p.tick(at: 1.0).isEmpty, "early")
    check(p.tick(at: 1.21) == [.triggered], "trigger")
    check(p.tick(at: 2.0).isEmpty, "double trigger")
    check(p.keyDown(at: 2.5).isEmpty, "repeat keydown")
    check(p.keyUp(at: 3) == [.releasedAfterTrigger], "release")
}
test("hold detected on release even without ticks") {
    var p = PowerHoldDetector(holdThreshold: 1.2)
    _ = p.keyDown(at: 0)
    check(p.keyUp(at: 2) == [.triggered, .releasedAfterTrigger], "")
}
test("stray key-up ignored") {
    var p = PowerHoldDetector()
    check(p.keyUp(at: 1).isEmpty, "")
}

// MARK: - Animation curves

test("fold frames: start clear, end gone, monotone dimming") {
    let a = FrameParams.fold(0), z = FrameParams.fold(1)
    check(a.rotation == 0 && a.shade == 0 && a.panelOpacity == 1 && a.softBlur == 0, "start \(a)")
    check(z.panelOpacity == 0 && z.shade > 0.9, "end \(z)")
    var last = -1.0
    for i in 0...100 { let s = FrameParams.fold(Double(i) / 100).shade; check(s >= last, "shade dips at \(i)"); last = s }
}
test("glossy fade: sheen peaks mid-way, ends black") {
    let mid = (0...100).map { FrameParams.glossyFade(Double($0) / 100).sheen }
    check(mid.max()! > 0.5, "sheen too weak")
    check(FrameParams.glossyFade(0).sheen == 0 && FrameParams.glossyFade(1).sheen < 0.01, "sheen edges")
    check(FrameParams.glossyFade(1).panelOpacity == 0, "not black")
}

print("\n\(passes) checks passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
