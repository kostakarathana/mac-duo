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
///   └ panel — the "screen" that folds about its bottom edge (the hinge) or recedes
///      ├ sharp / soft / heavy — the desktop at three blur levels, blended with gradient masks
///      ├ frost — white glass tint
///      ├ shade — dimming, darker toward the free edge
///      ├ sheen — moving specular highlight
///      └ rim — glassy edge highlight
///   └ hinge — soft glow along the hinge while folding
final class DuoScene {
    let root = CALayer()
    private let panel = CALayer()
    private let sharp = CALayer(), soft = CALayer(), heavy = CALayer()
    private let softMask = CAGradientLayer(), heavyMask = CAGradientLayer()
    private let frost = CALayer()
    private let shade = CAGradientLayer()
    private let sheen = CAGradientLayer()
    private let rim = CALayer()
    private let hinge = CAGradientLayer()
    private var mode: DuoOverlay.Mode = .fold
    private var hasImage = false
    /// Opacity for the system backdrop blur when there's no screenshot to work with.
    private(set) var fallbackBlur = 0.0

    init() {
        root.addSublayer(panel)
        root.addSublayer(hinge)
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
        frost.backgroundColor = NSColor.white.cgColor
        panel.addSublayer(frost)
        panel.addSublayer(shade)
        sheen.colors = [NSColor(white: 1, alpha: 0).cgColor, NSColor(white: 1, alpha: 0.9).cgColor, NSColor(white: 1, alpha: 0).cgColor]
        panel.addSublayer(sheen)
        rim.borderColor = NSColor.white.cgColor
        rim.borderWidth = 1.5
        panel.addSublayer(rim)
        panel.masksToBounds = true
        hinge.colors = [NSColor(white: 1, alpha: 0.5).cgColor, NSColor(white: 1, alpha: 0).cgColor]
        hinge.startPoint = CGPoint(x: 0.5, y: 0)
        hinge.endPoint = CGPoint(x: 0.5, y: 1)
    }

    func configure(bounds b: CGRect, mode: DuoOverlay.Mode, snapshot: Snapshot?, scale: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        self.mode = mode
        hasImage = snapshot != nil
        root.frame = b
        var persp = CATransform3DIdentity
        persp.m34 = -1 / (b.height * 1.9)
        root.sublayerTransform = persp
        root.backgroundColor = hasImage ? NSColor.black.cgColor : NSColor.clear.cgColor

        panel.transform = CATransform3DIdentity
        if mode == .fold {
            panel.anchorPoint = CGPoint(x: 0.5, y: 0)
            panel.bounds = CGRect(origin: .zero, size: b.size)
            panel.position = CGPoint(x: b.width / 2, y: 0)
            sheen.startPoint = CGPoint(x: 0.5, y: 0); sheen.endPoint = CGPoint(x: 0.5, y: 1)
        } else {
            panel.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            panel.bounds = CGRect(origin: .zero, size: b.size)
            panel.position = CGPoint(x: b.width / 2, y: b.height / 2)
            sheen.startPoint = CGPoint(x: 0, y: 1); sheen.endPoint = CGPoint(x: 1, y: 0)
        }
        for l in [sharp, soft, heavy, frost, shade, sheen, rim, softMask, heavyMask] { l.frame = panel.bounds }
        sharp.contents = snapshot?.sharp
        soft.contents = snapshot?.soft
        heavy.contents = snapshot?.heavy
        for l in [sharp, soft, heavy] { l.contentsScale = scale; l.isHidden = !hasImage }
        hinge.frame = CGRect(x: 0, y: 0, width: b.width, height: b.height * 0.05)
        CATransaction.commit()
    }

    func apply(_ f: FrameParams) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let foldMode = mode == .fold
        if hasImage {
            var t = CATransform3DIdentity
            if foldMode {
                // Tilt the top edge away from the viewer, folding into the hinge.
                t = CATransform3DRotate(t, CGFloat(-f.rotation * .pi / 180), 1, 0, 0)
            }
            t = CATransform3DScale(t, CGFloat(f.scale), CGFloat(f.scale), 1)
            panel.transform = t
            panel.cornerRadius = CGFloat(f.cornerRadius)
            panel.opacity = Float(f.panelOpacity)
            soft.opacity = Float(f.softBlur)
            heavy.opacity = Float(f.heavyBlur)
            let reach = foldMode ? f.blurReach : 1
            let l0 = (1 - reach) * 0.6, l1 = min(1, l0 + 0.4)
            softMask.locations = [NSNumber(value: foldMode ? l0 * 0.7 : 0), NSNumber(value: foldMode ? l1 * 0.8 : 0.001)]
            heavyMask.locations = [NSNumber(value: foldMode ? l0 + 0.15 : 0), NSNumber(value: foldMode ? min(1, l1 + 0.2) : 0.001)]
            fallbackBlur = 0
        } else {
            // No screenshot (Screen Recording not granted): frosted backdrop blur + dimming instead.
            panel.transform = CATransform3DIdentity
            panel.cornerRadius = 0
            panel.opacity = 1
            fallbackBlur = max(f.softBlur, f.heavyBlur) * (1 - Ease.smoothstep(0.85, 1, max(f.shade, 1 - f.panelOpacity)))
        }
        frost.opacity = Float(f.frost)
        let s = hasImage ? f.shade : max(f.shade, 1 - f.panelOpacity)
        shade.colors = [NSColor(white: 0, alpha: s * (foldMode ? 0.7 : 1)).cgColor,
                        NSColor(white: 0, alpha: min(1, s * (foldMode ? 1.1 : 1))).cgColor]
        shade.startPoint = CGPoint(x: 0.5, y: 0); shade.endPoint = CGPoint(x: 0.5, y: 1)
        sheen.opacity = Float(f.sheen)
        let pos = foldMode ? 0.08 + 0.85 * f.sheenPosition : -0.2 + 1.4 * f.sheenPosition
        let w = foldMode ? 0.10 : 0.16
        sheen.locations = [NSNumber(value: pos - w), NSNumber(value: pos), NSNumber(value: pos + w)]
        rim.cornerRadius = CGFloat(f.cornerRadius)
        rim.opacity = Float(min(1, f.sheen * 0.7 + f.frost))
        hinge.opacity = foldMode && hasImage ? Float(f.sheen * 0.6) : 0
        CATransaction.commit()
    }
}
