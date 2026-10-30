import AppKit
import ServiceManagement

enum Prefs {
    static let d = UserDefaults.standard
    static func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }

    static var foldEnabled: Bool { get { bool("foldEnabled", true) } set { d.set(newValue, forKey: "foldEnabled") } }
    static var powerFadeEnabled: Bool { get { bool("powerFadeEnabled", true) } set { d.set(newValue, forKey: "powerFadeEnabled") } }
    static var shutdownFadeEnabled: Bool { get { bool("shutdownFadeEnabled", true) } set { d.set(newValue, forKey: "shutdownFadeEnabled") } }
    static var sensitivity: DetectorConfig.Sensitivity {
        get { DetectorConfig.Sensitivity(rawValue: d.string(forKey: "sensitivity") ?? "") ?? .normal }
        set { d.set(newValue.rawValue, forKey: "sensitivity") }
    }
    static var holdSeconds: Double {
        get { d.object(forKey: "holdSeconds") == nil ? 1.2 : d.double(forKey: "holdSeconds") }
        set { d.set(newValue, forKey: "holdSeconds") }
    }
    static var onboarded: Bool { get { bool("onboarded", false) } set { d.set(newValue, forKey: "onboarded") } }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    static let website = URL(string: "https://kostakarathana.github.io/mac-duo/")!

    private var statusItem: NSStatusItem!
    private let sensor = LidSensor()
    private let power = PowerButtonMonitor()
    private let overlay = DuoOverlay()
    private var detector = CloseDetector(config: .preset(Prefs.sensitivity))
    private var hold = PowerHoldDetector(holdThreshold: Prefs.holdSeconds)
    private var timer: Timer?
    private var lastTick = CACurrentMediaTime()

    // Fold state
    private var snapshot: Snapshot?
    private var capturing = false
    private var shown = 0.0
    private var lastGoodRead = CACurrentMediaTime()
    private var asleep = false

    // Fade state
    private enum Fade { case none, playing(start: CFTimeInterval), holding(since: CFTimeInterval) }
    private var fade: Fade = .none
    private var fadeDone: (() -> Void)?
    private var poweringOff = false

    // Preview state
    private var preview: (start: CFTimeInterval, kind: DuoOverlay.Mode)?

    private var angleItem: NSMenuItem?
    private var shownAngle = -1
    private var idleSkip = 0
    var demo: DuoOverlay.Mode?
    /// Scripted lid motion (time, angle) used instead of the sensor by `--simulate`.
    var simulated: [(t: Double, a: Double)]?
    private var simStart: CFTimeInterval = 0
    private var wasVisible = false
    private var log: [String] = []

    private func currentAngle(_ now: CFTimeInterval) -> Double? {
        guard let sim = simulated else { return sensor.readOrReconnect() }
        let t = now - simStart
        for i in 1..<sim.count where t <= sim[i].t {
            let u = (t - sim[i - 1].t) / max(0.0001, sim[i].t - sim[i - 1].t)
            return (sim[i - 1].a + (sim[i].a - sim[i - 1].a) * u).rounded()
        }
        return sim.last?.a
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        power.onDown = { [weak self] in self?.powerDown() }
        power.onUp = { [weak self] in self?.powerUp() }
        if Prefs.powerFadeEnabled, PowerButtonMonitor.hasPermission { power.start() }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(willPowerOff), name: NSWorkspace.willPowerOffNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        if let sim = simulated {
            simStart = CACurrentMediaTime()
            Prefs.foldEnabled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (sim.last?.t ?? 0) + 0.8) {
                print(self.log.joined(separator: " → "))
                print("final: visible=\(self.overlay.isVisible) state=\(self.detector.state) shown=\(String(format: "%.3f", self.shown))")
                exit(0)
            }
        } else if let demo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.startPreview(demo) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { NSApp.terminate(nil) }
        } else if !Prefs.onboarded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.onboard() }
        }
    }

    // MARK: - Main loop

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.1, now - lastTick)
        lastTick = now

        for e in hold.tick(at: now) { handle(e) }

        if let p = preview { tickPreview(p, now: now); return }
        if case .none = fade {} else { tickFade(now: now); return }

        guard Prefs.foldEnabled, !asleep else { return }
        // Save power: while the lid sits still at a working angle, sample at 15 Hz instead of 60.
        idleSkip = (idleSkip + 1) % 4
        let calm = !detector.isActive && !overlay.isVisible && abs(detector.velocity) < 8 && detector.angle > 75
        if calm, idleSkip != 0 { return }
        guard let angle = currentAngle(now) else {
            if overlay.isVisible, now - lastGoodRead > 1 { resetFold() }
            return
        }
        lastGoodRead = now
        if let angleItem, Int(angle) != shownAngle {
            shownAngle = Int(angle)
            angleItem.title = "Lid angle: \(shownAngle)°"
        }

        for e in detector.update(angle: angle, at: now) {
            if simulated != nil { log.append("\(e)") }
            handle(e, angle: angle)
        }

        let target = detector.progress
        // Critically-damped follow so the sensor's 1° steps never look jittery.
        let k = 1 - exp(-dt / 0.035)
        shown += (target - shown) * k
        if abs(target - shown) < 0.002 { shown = target }

        if overlay.isVisible, overlay.mode == .fold {
            overlay.render(.fold(shown))
            if !detector.isActive, shown <= 0.001 { overlay.hide() }
        }
        if simulated != nil, overlay.isVisible != wasVisible {
            wasVisible = overlay.isVisible
            log.append(wasVisible ? "overlay-shown" : "overlay-hidden")
        }
    }

    private func handle(_ e: DetectorEvent, angle: Double) {
        switch e {
        case .prearm:
            captureSnapshot()
        case .beginFold:
            guard let screen = DuoOverlay.builtInScreen() else { return }
            let fresh = snapshot.flatMap { Date().timeIntervalSince($0.takenAt) < 4 ? $0 : nil }
            shown = 0
            overlay.show(.fold, snapshot: fresh, on: screen)
            if fresh == nil { captureSnapshot() }
        case .cancel, .finished:
            break // `shown` eases back to 0, then the overlay hides itself
        case .closed, .beginUnfold:
            if !overlay.isVisible, let s = DuoOverlay.builtInScreen() { overlay.show(.fold, snapshot: snapshot, on: s) }
        }
    }

    private func resetFold() {
        detector.reset(); shown = 0
        if overlay.mode == .fold { overlay.hide() }
    }

    private func captureSnapshot(then: ((Snapshot?) -> Void)? = nil) {
        guard !capturing, let screen = DuoOverlay.builtInScreen(), let id = DuoOverlay.displayID(of: screen) else {
            then?(snapshot); return
        }
        capturing = true
        Task {
            let s = await ScreenSnapshot.capture(displayID: id)
            await MainActor.run {
                self.capturing = false
                if let s { self.snapshot = s; self.overlay.adopt(s) }
                then?(s)
            }
        }
    }

    // MARK: - Power button glossy fade

    private func powerDown() {
        guard Prefs.powerFadeEnabled else { return }
        for e in hold.keyDown(at: CACurrentMediaTime()) { handle(e) }
    }

    private func powerUp() {
        for e in hold.keyUp(at: CACurrentMediaTime()) { handle(e) }
    }

    private func handle(_ e: PowerHoldDetector.Event) {
        switch e {
        case .pressed:
            captureSnapshot() // ready by the time the hold threshold passes
        case .triggered:
            startFade(snapshot: freshSnapshot(within: 3))
        case .tapped:
            break
        case .releasedAfterTrigger:
            // Still running? The Mac didn't power off (or a dialog appeared) — bring the screen back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, !self.poweringOff, case .holding = self.fade else { return }
                self.endFade()
            }
        }
    }

    private func freshSnapshot(within s: TimeInterval) -> Snapshot? {
        snapshot.flatMap { Date().timeIntervalSince($0.takenAt) < s ? $0 : nil }
    }

    private func startFade(snapshot: Snapshot?, completion: (() -> Void)? = nil) {
        guard let screen = DuoOverlay.builtInScreen() ?? NSScreen.main else { completion?(); return }
        if case .none = fade {} else { fadeDone = completion ?? fadeDone; return }
        detector.reset(); shown = 0
        overlay.show(.fade, snapshot: snapshot, on: screen)
        fade = .playing(start: CACurrentMediaTime())
        fadeDone = completion
    }

    private static let fadeDuration = 1.35

    private func tickFade(now: CFTimeInterval) {
        switch fade {
        case .playing(let start):
            let t = (now - start) / Self.fadeDuration
            overlay.render(.glossyFade(t))
            if t >= 1 {
                fade = .holding(since: now)
                let done = fadeDone; fadeDone = nil; done?()
            }
        case .holding(let since):
            // Safety net: never leave the screen black for long if nothing turned the Mac off.
            if !poweringOff, now - since > 12 { endFade() }
        case .none: break
        }
    }

    private func endFade() {
        fade = .none
        overlay.hide(fadeDuration: 0.45)
    }

    @objc private func willPowerOff(_ n: Notification) {
        guard Prefs.shutdownFadeEnabled else { return }
        poweringOff = true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard poweringOff, Prefs.shutdownFadeEnabled else { return .terminateNow }
        // Play the fade before the system finishes shutting down; never block it for long.
        var replied = false
        let reply = { if !replied { replied = true; NSApp.reply(toApplicationShouldTerminate: true) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: reply)
        if let s = freshSnapshot(within: 2) {
            startFade(snapshot: s, completion: reply)
        } else {
            captureSnapshot { [weak self] s in self?.startFade(snapshot: s, completion: reply) }
        }
        return .terminateLater
    }

    // MARK: - Sleep / wake / displays

    @objc private func willSleep() {
        asleep = true
        // If the lid went down mid-fold, make sure the panel is fully gone, not half-folded on wake.
        if overlay.isVisible, overlay.mode == .fold { shown = 1; overlay.render(.fold(1)) }
    }

    @objc private func didWake() {
        asleep = false
        lastGoodRead = CACurrentMediaTime()
        // The detector sees the opened lid on the next tick and unfolds back to the desktop.
    }

    @objc private func screensChanged() {
        if overlay.isVisible, DuoOverlay.builtInScreen() == nil { overlay.hide() }
    }

    // MARK: - Preview

    func startPreview(_ kind: DuoOverlay.Mode) {
        guard let screen = DuoOverlay.builtInScreen() ?? NSScreen.main else { return }
        detector.reset(); shown = 0
        captureSnapshot { [weak self] s in
            guard let self else { return }
            self.overlay.show(kind, snapshot: s, on: screen)
            self.preview = (CACurrentMediaTime(), kind)
        }
    }

    private func tickPreview(_ p: (start: CFTimeInterval, kind: DuoOverlay.Mode), now: CFTimeInterval) {
        let t = now - p.start
        switch p.kind {
        case .fold:
            // Close over 0.9 s, pause shut, then open again.
            let v: Double = t < 0.9 ? Ease.inOut(t / 0.9) : t < 1.6 ? 1 : 1 - Ease.inOut((t - 1.6) / 0.9)
            overlay.render(.fold(v))
            if t > 2.5 { preview = nil; overlay.hide() }
        case .fade:
            overlay.render(.glossyFade(t / Self.fadeDuration))
            if t > Self.fadeDuration + 0.7 { preview = nil; overlay.hide(fadeDuration: 0.45) }
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "Mac Duo")
            b.image?.isTemplate = true
        }
        let m = NSMenu()
        m.delegate = self
        statusItem.menu = m
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        let title = NSMenuItem(title: "Mac Duo \(Self.version)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        m.addItem(title)
        let ai = NSMenuItem(title: sensor.isAvailable ? "Lid angle: \(Int(sensor.read() ?? 0))°" : "Lid sensor not found on this Mac", action: nil, keyEquivalent: "")
        ai.isEnabled = false
        m.addItem(ai)
        angleItem = ai; shownAngle = -1
        m.addItem(.separator())

        m.addItem(toggle("Fold when closing the lid", Prefs.foldEnabled, #selector(toggleFold)))
        m.addItem(toggle("Glossy fade when holding power", Prefs.powerFadeEnabled, #selector(togglePower)))
        m.addItem(toggle("Glossy fade on Shut Down / Restart", Prefs.shutdownFadeEnabled, #selector(toggleShutdown)))

        let sens = NSMenu()
        for (s, label) in [(DetectorConfig.Sensitivity.relaxed, "Relaxed — folds a bit earlier"),
                           (.normal, "Normal"),
                           (.strict, "Strict — only fast, deliberate closes")] {
            let i = NSMenuItem(title: label, action: #selector(setSensitivity(_:)), keyEquivalent: "")
            i.representedObject = s.rawValue; i.target = self
            i.state = Prefs.sensitivity == s ? .on : .off
            sens.addItem(i)
        }
        let sensItem = NSMenuItem(title: "Close Detection", action: nil, keyEquivalent: ""); sensItem.submenu = sens
        m.addItem(sensItem)

        let holdMenu = NSMenu()
        for s in [0.8, 1.2, 2.0, 3.0] {
            let i = NSMenuItem(title: String(format: "%.1f seconds", s), action: #selector(setHold(_:)), keyEquivalent: "")
            i.representedObject = s; i.target = self
            i.state = abs(Prefs.holdSeconds - s) < 0.01 ? .on : .off
            holdMenu.addItem(i)
        }
        let holdItem = NSMenuItem(title: "Power Hold Time", action: nil, keyEquivalent: ""); holdItem.submenu = holdMenu
        m.addItem(holdItem)

        m.addItem(.separator())
        m.addItem(item("Preview Fold", #selector(previewFold), key: "f"))
        m.addItem(item("Preview Glossy Fade", #selector(previewFade), key: "g"))

        m.addItem(.separator())
        let perms = NSMenu()
        perms.addItem(item(ScreenSnapshot.hasPermission ? "✓ Screen Recording" : "Grant Screen Recording…  (for the real desktop in the fold)", #selector(grantScreen)))
        perms.addItem(item(PowerButtonMonitor.hasPermission ? "✓ Input Monitoring" : "Grant Input Monitoring…  (to see the power button)", #selector(grantInput)))
        let permItem = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: ""); permItem.submenu = perms
        m.addItem(permItem)
        m.addItem(toggle("Open at Login", SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        m.addItem(item("Website & Updates…", #selector(openSite)))
        m.addItem(.separator())
        m.addItem(item("Quit Mac Duo", #selector(quit), key: "q"))
    }

    private func item(_ t: String, _ a: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: t, action: a, keyEquivalent: key); i.target = self; return i
    }
    private func toggle(_ t: String, _ on: Bool, _ a: Selector) -> NSMenuItem {
        let i = item(t, a); i.state = on ? .on : .off; return i
    }

    @objc private func toggleFold() { Prefs.foldEnabled.toggle(); if !Prefs.foldEnabled { resetFold() } }
    @objc private func togglePower() {
        Prefs.powerFadeEnabled.toggle()
        if Prefs.powerFadeEnabled { ensureInputMonitoring() }
    }
    @objc private func toggleShutdown() { Prefs.shutdownFadeEnabled.toggle() }
    @objc private func setSensitivity(_ i: NSMenuItem) {
        guard let raw = i.representedObject as? String, let s = DetectorConfig.Sensitivity(rawValue: raw) else { return }
        Prefs.sensitivity = s
        detector.config = .preset(s)
    }
    @objc private func setHold(_ i: NSMenuItem) {
        guard let s = i.representedObject as? Double else { return }
        Prefs.holdSeconds = s; hold.holdThreshold = s
    }
    @objc private func previewFold() { startPreview(.fold) }
    @objc private func previewFade() { startPreview(.fade) }
    @objc private func grantScreen() {
        ScreenSnapshot.requestPermission()
        openPrivacy("Privacy_ScreenCapture")
    }
    @objc private func grantInput() { ensureInputMonitoring(); openPrivacy("Privacy_ListenEvent") }
    private func ensureInputMonitoring() {
        if PowerButtonMonitor.hasPermission { power.restart() } else { PowerButtonMonitor.requestPermission() }
        // Permission takes effect without relaunch once granted; poll briefly.
        for d in [3.0, 8, 15, 30] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in
                if PowerButtonMonitor.hasPermission, self?.power.tapActive == false { self?.power.restart() }
            }
        }
    }
    private func openPrivacy(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert(); a.messageText = "Couldn't change Open at Login"
            a.informativeText = "Move Mac Duo to your Applications folder and try again.\n\n\(error.localizedDescription)"
            a.runModal()
        }
    }
    @objc private func openSite() { NSWorkspace.shared.open(Self.website) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func onboard() {
        Prefs.onboarded = true
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Mac Duo is running"
        a.informativeText = """
        Look for the laptop icon in your menu bar.

        • Close your lid and the screen folds away like iPhone Duo. Normal screen adjustments are ignored.
        • Hold the power button and the screen fades away with a glossy sheen.

        Two optional permissions make it look its best:
        Screen Recording — so the fold shows your actual desktop bending away (nothing is saved or sent anywhere).
        Input Monitoring — so Mac Duo can notice the power button being held.
        """
        a.addButton(withTitle: "Grant Permissions")
        a.addButton(withTitle: "Preview the Fold")
        a.addButton(withTitle: "Later")
        if !sensor.isAvailable {
            a.informativeText += "\n\n⚠️ This Mac doesn't expose a lid angle sensor, so the fold can't follow your lid. The power-button fade still works."
        }
        switch a.runModal() {
        case .alertFirstButtonReturn:
            ScreenSnapshot.requestPermission()
            ensureInputMonitoring()
        case .alertSecondButtonReturn:
            startPreview(.fold)
        default: break
        }
    }
}
