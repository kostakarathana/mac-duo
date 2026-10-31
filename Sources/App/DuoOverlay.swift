import AppKit
import QuartzCore

/// Full-screen, click-through window on the built-in display that draws the fold / fade.
final class DuoOverlay {
    enum Mode { case fold, fade }

    private(set) var window: NSWindow?
    private var canvas: CanvasView?
    private(set) var mode: Mode = .fold
    private(set) var hasSnapshot = false
    var isVisible: Bool { window?.isVisible == true }

    static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { s in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(n.uint32Value) != 0
        }
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    func show(_ mode: Mode, snapshot: Snapshot?, on screen: NSScreen) {
        self.mode = mode
        if window == nil || window?.screen != screen || window?.frame != screen.frame {
            window?.orderOut(nil)
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.ignoresMouseEvents = true
            w.isOpaque = false
            w.hasShadow = false
            w.backgroundColor = .clear
            w.animationBehavior = .none
            w.isReleasedWhenClosed = false
            let c = CanvasView(frame: NSRect(origin: .zero, size: screen.frame.size))
            w.contentView = c
            window = w; canvas = c
        }
        window?.alphaValue = 1
        // During a fold the overlay swallows the click that dismisses it, so it can't land on
        // whatever was under the cursor.
        window?.ignoresMouseEvents = mode == .fade
        canvas?.configure(mode: mode, snapshot: snapshot, scale: screen.backingScaleFactor)
        hasSnapshot = snapshot != nil
        canvas?.apply(mode == .fold ? .fold(0) : .glossyFade(0))
        window?.orderFrontRegardless()
    }

    /// Late-arriving screenshot (capture finished after the fold began).
    func adopt(_ snapshot: Snapshot) {
        guard isVisible, !hasSnapshot, let w = window else { return }
        canvas?.configure(mode: mode, snapshot: snapshot, scale: w.backingScaleFactor)
        hasSnapshot = true
    }

    func render(_ f: FrameParams) { canvas?.apply(f) }

    /// Covers the screen in plain black (used across sleep so nothing flashes on wake).
    func blackout(on screen: NSScreen) {
        show(mode, snapshot: nil, on: screen)
        canvas?.apply(.fold(1))
    }

    func hide(fadeDuration: TimeInterval = 0, completion: (() -> Void)? = nil) {
        guard let w = window, w.isVisible else { completion?(); return }
        if fadeDuration <= 0 {
            w.orderOut(nil); completion?(); return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            w.animator().alphaValue = 0
        }, completionHandler: {
            w.orderOut(nil); w.alphaValue = 1; completion?()
        })
    }
}

/// Hosts a `DuoScene` plus a system backdrop blur used when there's no screenshot.
final class CanvasView: NSView {
    private let fx = NSVisualEffectView()
    let scene = DuoScene()
    private var maskStep = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fx.frame = bounds
        fx.autoresizingMask = [.width, .height]
        fx.material = .fullScreenUI
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.alphaValue = 0
        addSubview(fx)
        layer?.addSublayer(scene.root)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(mode: DuoOverlay.Mode, snapshot: Snapshot?, scale: CGFloat) {
        scene.configure(bounds: bounds, mode: mode, snapshot: snapshot, scale: scale)
        maskStep = -1
    }

    func apply(_ f: FrameParams) {
        scene.apply(f)
        fx.alphaValue = CGFloat(scene.fallbackBlur)
        // Without a screenshot the system blur can't vary in strength, so it rises from the
        // hinge behind a soft-edged mask instead.
        let step = scene.fallbackFront.map { Int(($0 * 400).rounded()) } ?? -1
        if step != maskStep {
            maskStep = step
            fx.maskImage = scene.fallbackFront.map { Self.riseMask(front: $0) }
        }
    }

    /// A tall, thin alpha ramp (stretched to fill): opaque at the hinge, clear above `front`.
    private static func riseMask(front: Double) -> NSImage {
        let h = 512.0, edge = 0.45
        let img = NSImage(size: NSSize(width: 4, height: h), flipped: false) { r in
            let ramp = (0...16).map { i -> (NSColor, CGFloat) in
                let y = Double(i) / 16
                let a = 1 - Ease.smoothstep(front - edge, front, y)
                return (NSColor(white: 0, alpha: CGFloat(a)), CGFloat(y))
            }
            NSGradient(colors: ramp.map(\.0), atLocations: ramp.map(\.1), colorSpace: .deviceGray)?
                .draw(in: r, angle: 90)
            return true
        }
        img.resizingMode = .stretch
        img.capInsets = NSEdgeInsetsZero
        return img
    }
}

/// The layer stack (pure Core Animation, so it can also be rendered offscreen):
///  root (black when we have a snapshot)
///   ├ panel — the screen image
///   │  ├ sharp — the desktop as it is
///   │  ├ levels — the desktop at five blur strengths, each revealed from the hinge up by a
///   │  │          soft gradient mask, stronger ones a little lower: a progressive blur
///   │  ├ frost — white glass tint (fade)
///   │  ├ shade — dimming (fade)
///   │  ├ sheen — specular highlight (fade)
///   │  └ rim — glassy edge (fade)
///   ├ tint — the blurred region dims slightly toward the hinge (fold)
///   └ blackout — the display going dark at the very end of a close (fold)
final class DuoScene {
    let root = CALayer()
    private let panel = CALayer()
    private let sharp = CALayer()
    private let levels = (0..<5).map { _ in CALayer() }
    private let masks = (0..<5).map { _ in CAGradientLayer() }
    private let frost = CAGradientLayer()
    private let shade = CAGradientLayer()
    private let sheen = CAGradientLayer()
    private let rim = CALayer()
    private let tint = CAGradientLayer()
    private let blackout = CALayer()
    private var mode: DuoOverlay.Mode = .fold
    private var hasImage = false
    /// Opacity for the system backdrop blur when there's no screenshot to work with.
    private(set) var fallbackBlur = 0.0
    /// Fold without a screenshot: how high the system blur has risen (nil = unmasked).
    private(set) var fallbackFront: Double?

    /// Spacing between blur steps and the softness of each step's edge (screen heights).
    private static let step = 0.075, feather = 0.3
    /// Ramp alphas for a soft edge: smoothstep sampled, so there's no visible band.
    private static let ramp: [(a: CGFloat, at: Double)] = (0...8).map { i in
        let x = Double(i) / 8
        return (CGFloat(1 - x * x * (3 - 2 * x)), x)
    }

    init() {
        root.addSublayer(panel)
        root.addSublayer(tint)
        root.addSublayer(blackout)
        panel.addSublayer(sharp)
        for (l, m) in zip(levels, masks) {
            l.mask = m
            m.startPoint = CGPoint(x: 0.5, y: 0)   // y runs from the hinge (0) to the top edge (1)
            m.endPoint = CGPoint(x: 0.5, y: 1)
            panel.addSublayer(l)
        }
        for l in [sharp] + levels { l.contentsGravity = .resize }
        frost.startPoint = CGPoint(x: 0.5, y: 0)
        frost.endPoint = CGPoint(x: 0.5, y: 1)
        panel.addSublayer(frost)
        panel.addSublayer(shade)
        panel.addSublayer(sheen)
        rim.borderColor = NSColor.white.cgColor
        rim.borderWidth = 1.5
        panel.addSublayer(rim)
        panel.masksToBounds = true
        tint.startPoint = CGPoint(x: 0.5, y: 0)
        tint.endPoint = CGPoint(x: 0.5, y: 1)
        blackout.backgroundColor = NSColor.black.cgColor
        blackout.opacity = 0
    }

    func configure(bounds b: CGRect, mode: DuoOverlay.Mode, snapshot: Snapshot?, scale: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        self.mode = mode
        hasImage = snapshot != nil
        root.frame = b
        root.backgroundColor = hasImage ? NSColor.black.cgColor : NSColor.clear.cgColor
        panel.transform = CATransform3DIdentity
        panel.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        panel.bounds = CGRect(origin: .zero, size: b.size)
        panel.position = CGPoint(x: b.width / 2, y: b.height / 2)
        sheen.startPoint = CGPoint(x: 0, y: 1); sheen.endPoint = CGPoint(x: 1, y: 0)
        for l in [sharp, frost, shade, sheen, rim] + levels + masks { l.frame = panel.bounds }
        tint.frame = b; blackout.frame = b
        sharp.contents = snapshot?.sharp
        for (i, l) in levels.enumerated() { l.contents = snapshot?.levels[i] }
        for l in [sharp] + levels { l.contentsScale = scale; l.isHidden = !hasImage }
        tint.isHidden = mode != .fold
        blackout.isHidden = mode != .fold
        CATransaction.commit()
    }

    func apply(_ f: FrameParams) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if mode == .fold { applyFold(f) } else { applyFade(f) }
        CATransaction.commit()
    }

    private static func black(_ a: CGFloat) -> CGColor { NSColor(white: 0, alpha: a).cgColor }
    private static func white(_ a: CGFloat) -> CGColor { NSColor(white: 1, alpha: a).cgColor }
    private static func nums(_ v: [Double]) -> [NSNumber] { v.map { NSNumber(value: $0) } }

    /// Opaque below `edge - feather`, clear above `edge`, with a smooth falloff between.
    private static func soften(_ m: CAGradientLayer, edge: Double) {
        m.colors = ramp.map { black($0.a) }
        m.locations = nums(ramp.map { edge - feather + feather * $0.at })
    }

    /// The screen never moves. A progressive blur climbs from the hinge: each stronger blur
    /// sits a little lower than the last, so the frosting deepens smoothly toward the hinge
    /// and its top edge has no line. Near the end the display dims away.
    private func applyFold(_ f: FrameParams) {
        panel.transform = CATransform3DIdentity
        panel.cornerRadius = 0
        panel.opacity = 1
        for l in [frost, shade, sheen, rim] { l.opacity = 0 }
        let front = f.blurFront

        if hasImage {
            for (k, (l, m)) in zip(levels, masks).enumerated() {
                l.opacity = front > 0 ? 1 : 0
                Self.soften(m, edge: front - Double(k) * Self.step)
            }
            fallbackBlur = 0; fallbackFront = nil
        } else {
            fallbackBlur = front > 0 ? 1 : 0
            fallbackFront = front
        }

        // Like Apple's materials, the blurred glass is a touch darker, most at the hinge.
        let t = CGFloat(f.tint)
        tint.colors = [Self.black(t), Self.black(t * 0.45), Self.black(0)]
        tint.locations = Self.nums([0, front * 0.5, max(front, 0.001)])
        blackout.opacity = Float(f.shade)
    }

    private func applyFade(_ f: FrameParams) {
        if hasImage {
            panel.transform = CATransform3DMakeScale(CGFloat(f.scale), CGFloat(f.scale), 1)
            panel.cornerRadius = CGFloat(f.cornerRadius)
            panel.opacity = Float(f.panelOpacity)
            for (k, (l, m)) in zip(levels, masks).enumerated() {
                m.colors = [Self.black(1), Self.black(1)]
                m.locations = Self.nums([0, 1])
                l.opacity = k == 1 ? Float(f.softBlur) : k == 3 ? Float(f.heavyBlur) : 0
            }
            fallbackBlur = 0
        } else {
            // No screenshot (Screen Recording not granted): frosted backdrop blur + dimming instead.
            panel.transform = CATransform3DIdentity
            panel.cornerRadius = 0
            panel.opacity = 1
            fallbackBlur = max(f.softBlur, f.heavyBlur) * (1 - Ease.smoothstep(0.85, 1, max(f.shade, 1 - f.panelOpacity)))
        }
        fallbackFront = nil
        frost.opacity = 1; shade.opacity = 1
        frost.colors = [Self.white(CGFloat(f.frost)), Self.white(CGFloat(f.frost))]
        frost.locations = Self.nums([0, 1])
        let s = hasImage ? f.shade : max(f.shade, 1 - f.panelOpacity)
        shade.colors = [Self.black(CGFloat(s)), Self.black(CGFloat(s))]
        shade.locations = Self.nums([0, 1])
        sheen.colors = [Self.white(0), Self.white(0.9), Self.white(0)]
        sheen.opacity = Float(f.sheen)
        let pos = -0.2 + 1.4 * f.sheenPosition
        sheen.locations = Self.nums([pos - 0.16, pos, pos + 0.16])
        rim.cornerRadius = CGFloat(f.cornerRadius)
        rim.opacity = Float(min(1, f.sheen * 0.7 + f.frost))
    }
}
