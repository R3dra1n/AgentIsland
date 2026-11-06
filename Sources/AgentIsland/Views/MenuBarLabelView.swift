import SwiftUI
import AppKit

public struct MenuBarLabelView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        Image(nsImage: Self.generateMenuBarImage(appState: appState))
    }

    public static func generateMenuBarImage(appState: AppState, isDark: Bool? = nil) -> NSImage {
        struct Item {
            let id: String
            let state: AIState
        }
        var items: [Item] = []
        for obs in appState.displayedObservers {
            // Keep one aggregate Antigravity icon in the narrow menu bar;
            // the HUD itself shows its sessions as separate rows.
            if obs.icon == "antigravity", let index = items.firstIndex(where: { $0.id == "antigravity" }) {
                items[index] = Item(id: "antigravity", state: max(items[index].state, obs.state))
            } else {
                items.append(Item(id: obs.icon == "antigravity" ? "antigravity" : obs.id, state: obs.state))
            }
        }
        
        if items.isEmpty {
            items.append(Item(id: "agentisland_fallback", state: .idle))
        }

        let effectiveIsDark: Bool = {
            if let isDark = isDark { return isDark }
            if let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") {
                return style.caseInsensitiveCompare("Dark") == .orderedSame
            }
            if let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
                return match == .darkAqua
            }
            return false // Default is Light Mode!
        }()
        let labelColor: NSColor = effectiveIsDark ? .white : NSColor(white: 0.12, alpha: 1.0)
        let dimColor: NSColor = effectiveIsDark ? NSColor(white: 0.65, alpha: 1.0) : NSColor(white: 0.45, alpha: 1.0)

        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let height: CGFloat = 22
        let iconSize: CGFloat = 20
        let itemSpacing: CGFloat = 9
        let innerSpacing: CGFloat = 3.5

        var showIcon = appState.showMenuBarIcon
        var showDot = appState.showMenuBarDot
        var showText = appState.showMenuBarText
        let minimalFallback = !showIcon && !showDot && !showText
        
        if minimalFallback {
            items = [Item(id: "agentisland_fallback", state: .idle)]
            showIcon = true
            showDot = false
            showText = false
        }

        var measurements: [(iconW: CGFloat, dotW: CGFloat, textW: CGFloat, text: String, dotColor: NSColor)] = []
        var totalWidth: CGFloat = 0

        for (index, item) in items.enumerated() {
            let iconW: CGFloat = showIcon ? iconSize : 0
            let dotW: CGFloat = showDot ? 6 : 0
            let textStr = statusText(for: item.state)
            let textW: CGFloat = showText ? (textStr as NSString).size(withAttributes: [.font: font]).width : 0

            let dotColor: NSColor
            switch item.state {
            case .awaitingInput: dotColor = .systemRed
            case .running: dotColor = .systemYellow
            case .completed: dotColor = .systemGreen
            case .failed: dotColor = .systemOrange
            default: dotColor = dimColor
            }

            measurements.append((iconW, dotW, textW, textStr, dotColor))

            var w = iconW + dotW + textW
            if iconW > 0 && (dotW > 0 || textW > 0) { w += innerSpacing }
            if dotW > 0 && textW > 0 { w += innerSpacing }
            totalWidth += w
            if index < items.count - 1 { totalWidth += itemSpacing }
        }

        if totalWidth == 0 { totalWidth = 24 }
        totalWidth = ceil(totalWidth)

        let size = NSSize(width: totalWidth, height: height)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(totalWidth * 2),
            pixelsHigh: Int(height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return NSImage() }

        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        var currentX: CGFloat = 0
        for (index, m) in measurements.enumerated() {
            let item = items[index]




            // 1. Icon
            if m.iconW > 0 {
                let iconRect = NSRect(x: currentX, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
                
                let sourceImage: NSImage
                if item.id == "agentisland_fallback" {
                    let fallbackImg = NSImage(size: NSSize(width: iconSize, height: iconSize))
                    fallbackImg.lockFocus()
                    let str = "AI" as NSString
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                        .foregroundColor: NSColor.white
                    ]
                    let strSize = str.size(withAttributes: attrs)
                    str.draw(at: NSPoint(x: (iconSize - strSize.width)/2, y: (iconSize - strSize.height)/2), withAttributes: attrs)
                    fallbackImg.unlockFocus()
                    fallbackImg.isTemplate = true
                    sourceImage = fallbackImg
                } else {
                    sourceImage = AIIconProvider.shared.image(for: item.id, size: iconSize)
                }
                
                let tinted = NSImage(size: iconRect.size)
                tinted.lockFocus()
                sourceImage.draw(in: NSRect(origin: .zero, size: iconRect.size))
                labelColor.set()
                NSRect(origin: .zero, size: iconRect.size).fill(using: .sourceAtop)
                tinted.unlockFocus()
                tinted.draw(in: iconRect)
                
                currentX += m.iconW
                if m.dotW > 0 || m.textW > 0 { currentX += innerSpacing }
            }

            // 2. Dot
            if m.dotW > 0 {
                let dotRect = NSRect(x: currentX, y: (height - 6) / 2, width: 6, height: 6)
                m.dotColor.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
                currentX += m.dotW
                if m.textW > 0 { currentX += innerSpacing }
            }

            // 3. Text
            if m.textW > 0 {
                let textRect = NSRect(x: currentX, y: (height - 14) / 2 - 1, width: m.textW + 2, height: 16)
                (m.text as NSString).draw(in: textRect, withAttributes: [
                    .font: font,
                    .foregroundColor: labelColor
                ])
                currentX += m.textW
            }

            if index < items.count - 1 {
                currentX += itemSpacing
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: size)
        out.addRepresentation(rep)
        return out
    }

    public static func statusText(for state: AIState) -> String {
        switch state {
        case .awaitingInput: return "需操作"
        case .running: return "执行中"
        case .completed: return "已完成"
        case .interrupted: return "已中断"
        case .failed: return "失败"
        case .idle, .unknown: return "待命"
        }
    }

}
