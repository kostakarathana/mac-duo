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
    }

    func apply(_ f: FrameParams) {
        scene.apply(f)
        fx.alphaValue = CGFloat(scene.fallbackBlur)
    }
}

/// The layer stack (pure Core Animation, so it can also be rendered offscreen):
///  root (black when we have a snapshot)
///   ├ panel — the screen image
///   │  ├ sharp / soft / heavy — the desktop at three blur levels, blended with gradient masks
///   │  ├ frost — white glass tint
///   │  ├ shade — dimming
///   │  ├ sheen — specular highlight
///   │  └ rim — glassy edge (fade only)
///   ├ vignette — pool of light shrinking into the hinge (fold only)
///   └ hinge — unused glow, kept hidden
final class DuoScene {
    let root = CALayer()
    private let panel = CALayer()
    private let sharp = CALayer(), soft = CALayer(), heavy = CALayer()
    private let softMask = CAGradientLayer(), heavyMask = CAGradientLayer()
    private let frost = CAGradientLayer()
    private let shade = CAGradientLayer()
    private let sheen = CAGradientLayer()
    private let rim = CALayer()
    private let hinge = CAGradientLayer()
    private let vignette = CAGradientLayer()
    private var mode: DuoOverlay.Mode = .fold
    private var hasImage = false
    private var aspect: CGFloat = 0.65
    /// Opacity for the system backdrop blur when there's no screenshot to work with.
    private(set) var fallbackBlur = 0.0

    init() {
        root.addSublayer(panel)
        root.addSublayer(vignette)
        root.addSublayer(hinge)
        vignette.type = .radial
        vignette.colors = [NSColor(white: 0, alpha: 0).cgColor, NSColor(white: 0, alpha: 0).cgColor,
                           NSColor(white: 0, alpha: 0.85).cgColor, NSColor.black.cgColor]
        vignette.locations = [0, 0.45, 0.85, 1]
        for l in [sharp, soft, heavy] {
            l.contentsGravity = .resize
            panel.addSublayer(l)
        }
        soft.mask = softMask
        heavy.mask = heavyMask
        for m in [softMask, heavyMask] {
            m.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
            m.startPoint = CGPoint(x: 0.5, y: 0)
            m.endPoint = CGPoint(x: 0.5, y: 1)
        }
        frost.startPoint = CGPoint(x: 0.5, y: 0)
        frost.endPoint = CGPoint(x: 0.5, y: 1)
        panel.addSublayer(frost)
        panel.addSublayer(shade)
        panel.addSublayer(sheen)
        rim.borderColor = NSColor.white.cgColor
        rim.borderWidth = 1.5
        panel.addSublayer(rim)
        panel.masksToBounds = true
        hinge.isHidden = true
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
        if mode == .fold {
            sheen.startPoint = CGPoint(x: 0.5, y: 0); sheen.endPoint = CGPoint(x: 0.5, y: 1)
        } else {
            sheen.startPoint = CGPoint(x: 0, y: 1); sheen.endPoint = CGPoint(x: 1, y: 0)
        }
        for l in [sharp, soft, heavy, frost, shade, sheen, rim, softMask, heavyMask] { l.frame = panel.bounds }
        sharp.contents = snapshot?.sharp
        soft.contents = snapshot?.soft
        heavy.contents = snapshot?.heavy
        for l in [sharp, soft, heavy] { l.contentsScale = scale; l.isHidden = !hasImage }
        vignette.frame = CGRect(origin: .zero, size: b.size)
        vignette.isHidden = mode != .fold
        aspect = b.height / max(1, b.width)
        CATransaction.commit()
    }


    func apply(_ f: FrameParams) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if mode == .fold { applyFold(f) } else { applyFade(f) }
        CATransaction.commit()
    }

    private static func clear(_ a: CGFloat = 0) -> CGColor { NSColor(white: 0, alpha: a).cgColor }
    private static func white(_ a: CGFloat) -> CGColor { NSColor(white: 1, alpha: a).cgColor }
    private static func nums(_ v: [Double]) -> [NSNumber] { v.map { NSNumber(value: $0) } }

    /// The screen never moves; blur, frost and darkness roll down from the top edge into the
    /// hinge as soft gradients, and the light pools toward the hinge until it's gone.
    private func applyFold(_ f: FrameParams) {
        panel.transform = CATransform3DIdentity
        panel.cornerRadius = 0
        rim.opacity = 0
        hinge.opacity = 0
        let front = f.blurFront, dark = f.darkFront

        if hasImage {
            panel.opacity = Float(f.panelOpacity)
            soft.opacity = Float(f.softBlur)
            heavy.opacity = Float(f.heavyBlur)
            // Gradient y runs 0 (hinge, bottom) → 1 (top edge). Blur is opaque above the front.
            softMask.locations = Self.nums([front - 0.28, front + 0.04])
            heavyMask.locations = Self.nums([front - 0.02, front + 0.32])
            fallbackBlur = 0
        } else {
            panel.opacity = 1
            fallbackBlur = f.softBlur * (1 - Ease.smoothstep(0.8, 1, f.shade))
        }

        frost.colors = [Self.white(0), Self.white(CGFloat(f.frost))]
        frost.locations = Self.nums([front - 0.3, front + 0.1])
        frost.opacity = 1

        // Darkness: light veil everywhere that deepens, fully black above the dark front.
        let veil = CGFloat(0.3 * f.shade)
        shade.colors = [Self.clear(veil), Self.clear(1)]
        shade.locations = Self.nums([dark - 0.5, dark])
        shade.startPoint = CGPoint(x: 0.5, y: 0); shade.endPoint = CGPoint(x: 0.5, y: 1)

        // Pool of light centred on the hinge that shrinks into it.
        let r = CGFloat(f.vignette)
        vignette.startPoint = CGPoint(x: 0.5, y: 0)
        vignette.endPoint = CGPoint(x: 0.5 + r * aspect * 1.25, y: r)
        vignette.opacity = hasImage || f.shade > 0 ? 1 : 0

        // A faint glassy glow riding just ahead of the frost.
        sheen.colors = [Self.white(0), Self.white(0.9), Self.white(0)]
        sheen.opacity = Float(f.sheen)
        sheen.locations = Self.nums([front - 0.1, front - 0.02, front + 0.06])
    }

    private func applyFade(_ f: FrameParams) {
        if hasImage {
            panel.transform = CATransform3DMakeScale(CGFloat(f.scale), CGFloat(f.scale), 1)
            panel.cornerRadius = CGFloat(f.cornerRadius)
            panel.opacity = Float(f.panelOpacity)
            soft.opacity = Float(f.softBlur)
            heavy.opacity = Float(f.heavyBlur)
            softMask.locations = Self.nums([0, 0.001])
            heavyMask.locations = Self.nums([0, 0.001])
            fallbackBlur = 0
        } else {
            // No screenshot (Screen Recording not granted): frosted backdrop blur + dimming instead.
            panel.transform = CATransform3DIdentity
            panel.cornerRadius = 0
            panel.opacity = 1
            fallbackBlur = max(f.softBlur, f.heavyBlur) * (1 - Ease.smoothstep(0.85, 1, max(f.shade, 1 - f.panelOpacity)))
        }
        frost.colors = [Self.white(CGFloat(f.frost)), Self.white(CGFloat(f.frost))]
        frost.locations = Self.nums([0, 1])
        let s = hasImage ? f.shade : max(f.shade, 1 - f.panelOpacity)
        shade.colors = [Self.clear(CGFloat(s)), Self.clear(CGFloat(s))]
        shade.locations = Self.nums([0, 1])
        sheen.colors = [Self.white(0), Self.white(0.9), Self.white(0)]
        sheen.opacity = Float(f.sheen)
        let pos = -0.2 + 1.4 * f.sheenPosition
        sheen.locations = Self.nums([pos - 0.16, pos, pos + 0.16])
        rim.cornerRadius = CGFloat(f.cornerRadius)
        rim.opacity = Float(min(1, f.sheen * 0.7 + f.frost))
        hinge.opacity = 0
    }
}
