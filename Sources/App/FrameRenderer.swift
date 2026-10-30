import AppKit
import Metal
import QuartzCore

/// Offscreen renderer for the overlay's layer stack — used by `--render` for visual tests and
/// for producing the website demo frames. Renders exactly what the overlay would show.
enum FrameRenderer {
    static func run(image: String, outDir: String, mode: DuoOverlay.Mode, frames: Int) -> Int32 {
        guard let src = NSImage(contentsOfFile: image)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("can't read \(image)"); return 1
        }
        guard let dev = MTLCreateSystemDefaultDevice() else { print("no Metal"); return 1 }
        let w = src.width, h = src.height
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .managed
        guard let tex = dev.makeTexture(descriptor: desc), let queue = dev.makeCommandQueue() else { return 1 }

        let view = DuoScene()
        view.configure(bounds: CGRect(x: 0, y: 0, width: w, height: h), mode: mode, snapshot: ScreenSnapshot.makeSnapshot(src), scale: 1)
        let renderer = CARenderer(mtlTexture: tex, options: [kCARendererMetalCommandQueue as String: queue])
        renderer.layer = view.root
        renderer.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        for i in 0..<frames {
            let p = Double(i) / Double(max(1, frames - 1))
            view.apply(mode == .fold ? .fold(p) : .glossyFade(p))
            CATransaction.flush() // no run loop here, so commit the implicit transaction by hand
            renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
            renderer.addUpdate(renderer.bounds)
            renderer.render()
            renderer.endFrame()
            if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
                blit.synchronize(resource: tex); blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            }
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            let cs = CGColorSpaceCreateDeviceRGB()
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: info.rawValue),
                  let raw = ctx.makeImage(),
                  let out = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info.rawValue)
            else { continue }
            // Core Animation draws y-up into the texture; flip so row 0 is the top of the screen.
            out.translateBy(x: 0, y: CGFloat(h)); out.scaleBy(x: 1, y: -1)
            out.draw(raw, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let img = out.makeImage() else { continue }
            let rep = NSBitmapImageRep(cgImage: img)
            let url = URL(fileURLWithPath: outDir).appendingPathComponent(String(format: "frame_%03d.png", i))
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        print("rendered \(frames) frames to \(outDir)")
        return 0
    }
}
