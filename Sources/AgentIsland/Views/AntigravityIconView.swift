import SwiftUI

/// Uses the attributed bundled SVG without changing the provider's behavior.
public struct AntigravityIconView: View {
    public let size: CGFloat
    public var color: Color?

    public init(size: CGFloat = 16, color: Color? = nil) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        AIIconView(provider: "antigravity", size: size, color: color)
    }
}
