import AppKit
import SwiftUI

/// Bundled LobeHub vector icons; see Resources/NOTICES.md.
public final class AIIconProvider: @unchecked Sendable {
    public static let shared = AIIconProvider()

    private var cache: [String: NSImage] = [:]
    private let lock = NSLock()

    public init() {}

    /// Returns a crisp template NSImage that renders beautifully in both Menu Bar and Dynamic Island
    public func image(for provider: String, size: CGFloat = 13) -> NSImage {
        let key = "\(provider)_\(Int(size * 10))"
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let img = generateImage(for: provider, size: size)

        lock.lock()
        cache[key] = img
        lock.unlock()
        return img
    }

    private func generateImage(for provider: String, size: CGFloat) -> NSImage {
        // For Codex (ChatGPT), Claude, or others, look for official SVG
        var svgPath: String?
        let resources: Bundle
        if Bundle.main.bundleURL.pathExtension == "app" {
            let url = Bundle.main.resourceURL?.appendingPathComponent("AgentIsland_AgentIsland.bundle")
            resources = url.flatMap { Bundle(url: $0) } ?? Bundle.main
        } else {
            // Running from a build directory rather than an app bundle: SwiftPM
            // puts the resource bundle next to the executable. Not `Bundle.module`:
            // its generated accessor writes the absolute build path into the
            // binary, which carries the builder's account name and project
            // location into anything that is distributed.
            let beside = Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("AgentIsland_AgentIsland.bundle")
            resources = beside.flatMap { Bundle(url: $0) } ?? Bundle.main
        }
        let possiblePaths = [
            resources.url(forResource: provider, withExtension: "svg")?.path,
            Bundle.main.url(forResource: provider, withExtension: "svg")?.path
        ].compactMap { $0 }

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                svgPath = path
                break
            }
        }

        if let svgPath = svgPath, let src = NSImage(contentsOfFile: svgPath) {
            return rasterize(src: src, size: size)
        }

        // Fallback: rounded badge with dot
        let fallback = NSImage(size: NSSize(width: size, height: size))
        fallback.lockFocus()
        NSColor.white.set()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: size - 2, height: size - 2)).fill()
        fallback.unlockFocus()
        fallback.isTemplate = true
        return fallback
    }

    private func rasterize(src: NSImage, size: CGFloat) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size * 2),
            pixelsHigh: Int(size * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep = rep else {
            let copy = src.copy() as! NSImage
            copy.size = NSSize(width: size, height: size)
            copy.isTemplate = true
            return copy
        }

        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        src.draw(
            in: NSRect(x: 0, y: 0, width: size, height: size),
            from: NSRect(origin: .zero, size: src.size),
            operation: .sourceOver,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: NSSize(width: size, height: size))
        out.addRepresentation(rep)
        out.isTemplate = true
        return out
    }


}

/// Dynamic vector icon view for SwiftUI
public struct AIIconView: View {
    public let provider: String
    public let size: CGFloat
    public var color: Color?

    public init(provider: String, size: CGFloat = 14, color: Color? = nil) {
        self.provider = provider
        self.size = size
        self.color = color
    }

    public var body: some View {
        let nsImg = AIIconProvider.shared.image(for: provider, size: size)
        Image(nsImage: nsImg)
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .foregroundColor(color ?? Color.primary)
            .frame(width: size, height: size)
    }
}
