import AppKit
import ApplicationServices
import CryptoKit

/// Observes mouse clicks only to identify a completed conversation the user
/// actually opens. No click coordinates, URLs, or conversation text are stored.
@MainActor
final class AntigravityViewedMonitor {
    private weak var state: AppState?
    private var monitor: Any?

    init(state: AppState) { self.state = state }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let state = self.state, state.antigravityEnabled,
                      state.antigravityObserver.sessions.contains(where: { $0.state == .completed }),
                      AXIsProcessTrusted() else { return }
                let location = NSEvent.mouseLocation
                let clickedAt = Date()
                // The sidebar click may navigate asynchronously; inspect only
                // the window that is frontmost after the click has settled.
                try? await Task.sleep(for: .milliseconds(250))
                self.observeClick(location: location, clickedAt: clickedAt)
            }
        }
    }

    private func observeClick(location: NSPoint, clickedAt: Date) {
        guard let state, state.antigravityEnabled, AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "com.google.antigravity",
              let primary = NSScreen.screens.first else { return }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        var hit: AXUIElement?
        let y = primary.frame.maxY - location.y
        guard AXUIElementCopyElementAtPosition(root, Float(location.x), Float(y), &hit) == .success,
              var element = hit else { return }
        // Restrict to the web area containing the click. Sidebar links and
        // unrelated apps cannot supply a different conversation's identity.
        var clickedLink: String?
        for _ in 0..<30 {
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success else { return }
            if role as? String == "AXLink" {
                var link: CFTypeRef?
                let hasURL = AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &link) == .success
                if !hasURL { _ = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &link) }
                let text = (link as? URL)?.absoluteString ?? (link as? String)
                guard let target = Self.sessionID(forRawURL: text) else { return }
                clickedLink = target
            }
            if role as? String == "AXWebArea" {
                var rawURL: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &rawURL) == .success else { return }
                let text = (rawURL as? URL)?.absoluteString ?? (rawURL as? String)
                guard let id = Self.sessionID(forRawURL: text),
                      clickedLink == nil || clickedLink == id,
                      let session = state.antigravityObserver.sessions.first(where: { $0.id == id }),
                      Self.isEligible(session: session, clickedAt: clickedAt) else { return }
                state.acknowledgeAntigravitySession(id)
                return
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let value = parent, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
            element = unsafeBitCast(value, to: AXUIElement.self)
        }
    }

    static func sessionID(for url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "") else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 2, parts[0] == "c", let uuid = UUID(uuidString: String(parts[1])) else { return nil }
        let digest = SHA256.hash(data: Data(uuid.uuidString.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        return "ag:" + digest
    }

    static func sessionID(forRawURL value: String?) -> String? {
        guard let value else { return nil }
        let text: String
        if value.hasPrefix("127.0.0.1:") || value.hasPrefix("localhost:") || value.hasPrefix("[::1]:") {
            text = "http://" + value
        } else { text = value }
        return sessionID(for: URL(string: text))
    }

    static func isEligible(session: AntigravitySessionSnapshot, clickedAt: Date) -> Bool {
        guard session.state == .completed, let completedAt = session.completedAt else { return false }
        return completedAt <= clickedAt
    }
}
