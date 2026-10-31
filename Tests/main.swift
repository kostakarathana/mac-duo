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
test("tilt down to 75° over a second (watching from above)") {
    let r = Trace(points: [(0, 110), (1.2, 75), (3, 75)]).run()
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
test("strict preset ignores a quick dip that normal folds") {
    let trace = Trace(points: [(0, 100), (0.6, 55), (3, 55)])
    check(folded(trace.run().events), "normal should fold")
    check(!folded(trace.run(.preset(.strict)).events), "strict folded")
}
test("fast nudge between working angles 125° ↔ 100°") {
    let r = Trace(points: [(0, 125), (0.25, 100), (0.6, 100), (0.85, 125), (2, 125)], jitter: 1).run()
    check(!folded(r.events), "\(r.events)")
}

// MARK: - Real closes must fold

test("normal close 110° → 0° in 0.8 s") {
    let r = Trace(points: [(0, 110), (0.1, 110), (0.9, 0), (1.5, 0)], jitter: 0.5).run()
    check(folded(r.events), "no fold: \(r.events)")
    check(r.events.contains(.closed), "never closed")
    check(r.progress.last == 1, "progress \(r.progress.last!)")
}
test("fold starts early in a normal close (above 70°)") {
    var d = CloseDetector()
    var t = 0.0, startAngle = -1.0
    for i in 0...60 {
        let a = (110 - 110 * Double(i) / 48).rounded()
        for e in d.update(angle: max(0, a), at: t) { if case .beginFold(let s) = e { startAngle = s } }
        t += 1 / 60
    }
    check(startAngle >= 70, "fold began at \(startAngle)°")
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

// MARK: - A started fold holds while paused, and ends as soon as the lid comes back up

test("start closing then lift the lid: fold ends straight away") {
    var d = CloseDetector()
    var t = 0.0, reopenedAt = -1.0
    for a in stride(from: 110.0, through: 25, by: -3) { d.update(angle: a, at: t); t += 1 / 60 }
    check(d.isActive, "should have started")
    for a in stride(from: 25.0, through: 110, by: 3) {
        if d.update(angle: a, at: t).contains(.reopened), reopenedAt < 0 { reopenedAt = a }
        t += 1 / 60
    }
    check(reopenedAt > 0 && reopenedAt <= 40, "reopened at \(reopenedAt)")
    check(d.state == .idle && d.progress == 0, "\(d.state)")
    for _ in 0..<60 { d.update(angle: 110, at: t); t += 1 / 60 }
    check(d.state == .idle, "re-folded at rest")
}
test("pause mid-way: fold holds where it is") {
    let r = Trace(points: [(0, 110), (0.6, 40), (4, 40)]).run()
    if case .folding = r.det.state {} else { check(false, "state \(r.det.state)") }
    check(r.progress.last! > 0.4, "progress \(r.progress.last!)")
}
test("progress never decreases while folding") {
    let r = Trace(points: [(0, 110), (0.4, 50), (0.6, 55), (0.9, 30), (1.2, 36), (1.5, 0)], jitter: 1.5).run()
    check(!r.events.contains(.reopened), "small wobble counted as reopening: \(r.events)")
    var ok = true
    for i in 1..<r.progress.count where r.progress[i] < r.progress[i - 1] && r.progress[i - 1] < 1 { ok = false }
    check(ok, "progress decreased")
}
test("dismiss clears the fold, and a new close folds again") {
    var d = CloseDetector()
    var t = 0.0
    for a in stride(from: 110.0, through: 40, by: -3) { d.update(angle: a, at: t); t += 1 / 60 }
    check(d.isActive, "not folding")
    d.dismiss()
    check(d.state == .idle && d.progress == 0, "\(d.state)")
    for _ in 0..<60 { d.update(angle: 40, at: t); t += 1 / 60 }
    check(d.state == .idle, "re-folded while still")
    for a in stride(from: 110.0, through: 0, by: -3) { d.update(angle: a, at: t); t += 1 / 60 }
    if case .closed = d.state {} else { check(false, "second close: \(d.state)") }
}
test("close then reopen ends the fold as soon as the lid lifts") {
    let r = Trace(points: [(0, 110), (0.8, 0), (2, 0), (2.8, 110), (3.5, 110)]).run()
    let e = r.events
    check(e.contains(.closed) && e.contains(.reopened), "\(e)")
    check(r.det.state == .idle && r.progress.last == 0, "\(r.det.state)")
    check(e.filter { $0 == .closed }.count == 1, "re-folded after reopening: \(e)")
}
test("waking with the lid already open (sensor jumped) ends immediately") {
    var d = CloseDetector()
    var t = 0.0
    for a in stride(from: 110.0, through: 0, by: -3) { d.update(angle: a, at: t); t += 1 / 60 }
    if case .closed = d.state {} else { check(false, "not closed: \(d.state)") }
    let ev = d.update(angle: 112, at: t + 30)
    check(ev.contains(.reopened) && d.state == .idle, "\(ev)")
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

test("fold frames: start clear, blur rises from the hinge, ends black, no moving box") {
    let a = FrameParams.fold(0), z = FrameParams.fold(1)
    check(a.shade == 0 && a.panelOpacity == 1 && a.blurFront == 0 && a.tint == 0, "start \(a)")
    check(z.panelOpacity == 0 && z.shade > 0.99 && z.blurFront >= FrameParams.maxBlurFront - 1e-9, "end \(z)")
    var last = FrameParams.fold(0)
    for i in 1...100 {
        let f = FrameParams.fold(Double(i) / 100)
        check(f.rotation == 0 && f.scale == 1 && f.cornerRadius == 0, "box transform at \(i)")
        check(f.shade >= last.shade && f.blurFront > last.blurFront && f.tint >= last.tint, "not monotone at \(i)")
        last = f
    }
}
test("fold is visible early and climbs gradually") {
    let early = FrameParams.fold(0.1).blurFront, mid = FrameParams.fold(0.5).blurFront
    check(early > 0.15 && early < 0.4, "early \(early)")
    check(mid > 0.8 && mid < 1.2, "mid \(mid)")
    check(FrameParams.fold(0.75).shade == 0, "dark too soon")
}
test("glossy fade: sheen peaks mid-way, ends black") {
    let mid = (0...100).map { FrameParams.glossyFade(Double($0) / 100).sheen }
    check(mid.max()! > 0.5, "sheen too weak")
    check(FrameParams.glossyFade(0).sheen == 0 && FrameParams.glossyFade(1).sheen < 0.01, "sheen edges")
    check(FrameParams.glossyFade(1).panelOpacity == 0, "not black")
}

print("\n\(passes) checks passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
