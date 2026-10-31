import AppKit

// Command-line helpers for testing:
//   MacDuo --trace [seconds]   print lid angle + detector state at 60 Hz
//   MacDuo --demo fold|fade    play one preview, then quit
let args = CommandLine.arguments

if let i = args.firstIndex(of: "--trace") {
    let secs = args.count > i + 1 ? Double(args[i + 1]) ?? 10 : 10
    let sensor = LidSensor()
    guard sensor.isAvailable else { print("no lid sensor"); exit(1) }
    var det = CloseDetector(config: .preset(Prefs.sensitivity))
    let t0 = Date()
    setvbuf(stdout, nil, _IOLBF, 0)
    while Date().timeIntervalSince(t0) < secs {
        let t = Date().timeIntervalSince(t0)
        if let a = sensor.read() {
            let ev = det.update(angle: a, at: t)
            print(String(format: "%6.3f  %5.1f°  v=%7.1f°/s  p=%.2f  %@ %@", t, a, det.velocity, det.progress,
                         "\(det.state)", ev.isEmpty ? "" : "\(ev)"))
        }
        usleep(16_667)
    }
    exit(0)
}

//   MacDuo --render fold|fade <image> <outdir> [frames]   offscreen frames of the animation
if let i = args.firstIndex(of: "--render"), args.count > i + 3 {
    _ = NSApplication.shared
    let frames = args.count > i + 4 ? Int(args[i + 4]) ?? 9 : 9
    exit(FrameRenderer.run(image: args[i + 2], outDir: args[i + 3], mode: args[i + 1] == "fade" ? .fade : .fold, frames: frames))
}

let app = NSApplication.shared
let delegate = AppDelegate()
if let i = args.firstIndex(of: "--demo"), args.count > i + 1 {
    delegate.demo = args[i + 1] == "fade" ? .fade : .fold
}
//   MacDuo --simulate close|hold|dismiss|adjust|reopen|lift    scripted lid motion through the real app
if let i = args.firstIndex(of: "--simulate"), args.count > i + 1 {
    let traces: [String: [(t: Double, a: Double)]] = [
        "close": [(0, 110), (0.3, 110), (1.1, 0), (1.6, 0)],
        "lift": [(0, 110), (0.3, 110), (0.7, 45), (1.2, 45), (1.5, 110), (2.2, 110)],
        "hold": [(0, 110), (0.3, 110), (0.7, 45), (2.5, 45)],
        "dismiss": [(0, 110), (0.3, 110), (0.7, 45), (2.5, 45)],
        "adjust": [(0, 120), (0.3, 120), (0.6, 90), (1.5, 90), (1.9, 125), (2.5, 125)],
        "reopen": [(0, 110), (0.3, 110), (1.1, 0), (1.8, 0), (2.6, 110), (3.0, 110)],
    ]
    guard let trace = traces[args[i + 1]] else {
        print("unknown scenario; use one of: \(traces.keys.sorted().joined(separator: ", "))"); exit(2)
    }
    delegate.simulated = trace
    // Only "dismiss" scripts a touch; the others ignore real input so results are repeatable.
    delegate.simulatedInputAt = args[i + 1] == "dismiss" ? 1.4 : .infinity
}
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
