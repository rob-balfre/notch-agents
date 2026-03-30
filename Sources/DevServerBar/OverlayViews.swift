import AppKit
import NotchAgentsCore
import SwiftUI

struct SideOverlayView: View {
    let side: AgentSide
    let summaries: [AgentSummary]
    let showsPlaceholder: Bool
    let isCollapsed: Bool
    let panelWidth: CGFloat
    let collapsedWidth: CGFloat
    let onAgentTap: (AgentSummary) -> Void
    let onOpenPanel: () -> Void
    let onRefresh: () -> Void
    let onRevealStatusFile: () -> Void
    let onSampleData: () -> Void
    let onClearData: () -> Void
    let onQuit: () -> Void

    var body: some View {
        ZStack(alignment: horizontalAlignment) {
            NotchWingShape(side: side)
                .fill(Color.black)
                .frame(width: isCollapsed ? collapsedWidth : panelWidth)
                .frame(maxWidth: .infinity, alignment: horizontalAlignment)
                .animation(wingAnimation, value: isCollapsed)

            HStack(spacing: 8) {
                if side == .leading {
                    Spacer(minLength: 0)
                    items
                } else {
                    items
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .opacity(isCollapsed ? 0 : 1)
            .offset(x: isCollapsed ? collapseOffset : 0)
            .animation(contentAnimation, value: isCollapsed)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onOpenPanel()
        }
        .contextMenu {
            Button("Open Monitor") {
                onOpenPanel()
            }

            Button("Refresh") {
                onRefresh()
            }

            Button("Reveal Status File") {
                onRevealStatusFile()
            }

            Divider()

            Button("Write Sample Data") {
                onSampleData()
            }

            Button("Clear Data") {
                onClearData()
            }

            Divider()

            Button("Quit") {
                onQuit()
            }
        }
    }

    @ViewBuilder
    private var items: some View {
        if summaries.isEmpty {
            if showsPlaceholder {
                Circle()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 6, height: 6)
            }
        } else {
            ForEach(summaries) { summary in
                AgentStatusGlyph(summary: summary) {
                    onAgentTap(summary)
                }
            }
        }
    }

    private var horizontalAlignment: Alignment {
        side == .leading ? .trailing : .leading
    }

    private var collapseOffset: CGFloat {
        side == .leading ? 12 : -12
    }

    private var wingAnimation: Animation {
        .timingCurve(0.2, 0.9, 0.18, 1, duration: 0.24)
    }

    private var contentAnimation: Animation {
        .timingCurve(0.32, 0, 0.12, 1, duration: 0.18)
    }
}

struct NotchBridgeView: View {
    let isCollapsed: Bool
    let roundsLeadingEdge: Bool
    let roundsTrailingEdge: Bool

    var body: some View {
        NotchBridgeShape(
            roundsLeadingEdge: roundsLeadingEdge,
            roundsTrailingEdge: roundsTrailingEdge
        )
            .fill(Color.black)
            .opacity(isCollapsed ? 0 : 1)
            .animation(.timingCurve(0.3, 0, 0.18, 1, duration: 0.16), value: isCollapsed)
            .ignoresSafeArea()
    }
}

private struct NotchBridgeShape: Shape {
    let roundsLeadingEdge: Bool
    let roundsTrailingEdge: Bool

    func path(in rect: CGRect) -> Path {
        let topRadius = min(rect.height * 0.18, 6)
        let bottomRadius = min(rect.height * 0.48, 12)

        return roundedRectPath(
            in: rect,
            topLeft: roundsLeadingEdge ? topRadius : 0,
            topRight: roundsTrailingEdge ? topRadius : 0,
            bottomRight: roundsTrailingEdge ? bottomRadius : 0,
            bottomLeft: roundsLeadingEdge ? bottomRadius : 0
        )
    }
}

private struct AgentStatusGlyph: View {
    let summary: AgentSummary
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                AgentIconView(agent: summary.agent)
                statusView

                if summary.count > 1 {
                    CountBadge(count: summary.count)
                }
            }
            .padding(.horizontal, 3)
            .frame(height: 20)
        }
        .buttonStyle(.plain)
        .help(summary.helpText)
    }

    @ViewBuilder
    private var statusView: some View {
        switch summary.status {
        case .running:
            SpinnerView(color: summary.agent.tintNSColor)
        case .needsInput:
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(summary.tintColor)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(summary.tintColor)
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(summary.tintColor)
        case .idle:
            EmptyView()
        }
    }
}

private struct AgentIconView: View {
    let agent: AgentKind

    var body: some View {
        Group {
            if let icon = AppIconCache.shared.icon(for: agent) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            Circle()
                                .stroke(agent.tintColor.opacity(0.7), lineWidth: 1)
                        )

                    Text(agent.fallbackMonogram)
                        .font(.system(size: agent == .claude ? 7.5 : 8.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 14, height: 14)
    }
}

private struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(minWidth: 16)
            .frame(height: 14)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.14))
            )
            .fixedSize()
    }
}

private struct SpinnerView: View {
    let color: NSColor

    var body: some View {
        SpinnerLayerRepresentable(color: color)
            .frame(width: 10, height: 10)
    }
}

private struct SpinnerLayerRepresentable: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> SpinnerLayerView {
        SpinnerLayerView(color: color)
    }

    func updateNSView(_ nsView: SpinnerLayerView, context: Context) {
        nsView.update(color: color)
    }
}

private final class SpinnerLayerView: NSView {
    private let shapeLayer = CAShapeLayer()

    init(color: NSColor) {
        super.init(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        wantsLayer = true
        layer = CALayer()
        layer?.isOpaque = false
        shapeLayer.fillColor = nil
        shapeLayer.lineWidth = 1.8
        shapeLayer.lineCap = .round
        shapeLayer.strokeStart = 0.18
        shapeLayer.strokeEnd = 0.96
        layer?.addSublayer(shapeLayer)
        update(color: color)
        ensureAnimation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 10, height: 10)
    }

    override func layout() {
        super.layout()
        shapeLayer.frame = bounds

        let inset = shapeLayer.lineWidth / 2
        let pathRect = bounds.insetBy(dx: inset, dy: inset)
        shapeLayer.path = CGPath(ellipseIn: pathRect, transform: nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window == nil {
            shapeLayer.removeAnimation(forKey: "rotation")
        } else {
            ensureAnimation()
        }
    }

    func update(color: NSColor) {
        shapeLayer.strokeColor = color.cgColor
        needsLayout = true
    }

    private func ensureAnimation() {
        guard shapeLayer.animation(forKey: "rotation") == nil else {
            return
        }

        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = Double.pi * 2
        animation.duration = 0.9
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        shapeLayer.add(animation, forKey: "rotation")
    }
}

private struct NotchWingShape: InsettableShape {
    let side: AgentSide
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let localRect = CGRect(origin: .zero, size: rect.size)
        var path = leadingWingPath(in: localRect)

        if side == .trailing {
            path = path.applying(
                CGAffineTransform(
                    a: -1,
                    b: 0,
                    c: 0,
                    d: 1,
                    tx: localRect.width,
                    ty: 0
                )
            )
        }

        return path.applying(
            CGAffineTransform(
                translationX: rect.minX,
                y: rect.minY
            )
        )
    }

    private func leadingWingPath(in rect: CGRect) -> Path {
        let topCornerRadius = min(rect.height * 0.18, 6)
        let bottomCornerRadius = min(rect.height * 0.42, 14)

        return Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(
                    x: rect.minX + topCornerRadius,
                    y: rect.minY + topCornerRadius
                ),
                control: CGPoint(
                    x: rect.minX + topCornerRadius,
                    y: rect.minY
                )
            )
            path.addLine(
                to: CGPoint(
                    x: rect.minX + topCornerRadius,
                    y: rect.maxY - bottomCornerRadius
                )
            )
            path.addQuadCurve(
                to: CGPoint(
                    x: rect.minX + topCornerRadius + bottomCornerRadius,
                    y: rect.maxY
                ),
                control: CGPoint(
                    x: rect.minX + topCornerRadius,
                    y: rect.maxY
                )
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
        }
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

private func roundedRectPath(
    in rect: CGRect,
    topLeft: CGFloat,
    topRight: CGFloat,
    bottomRight: CGFloat,
    bottomLeft: CGFloat
) -> Path {
    Path { path in
        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + topRight),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - bottomLeft),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topLeft, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
    }
}

private extension AgentKind {
    var fallbackMonogram: String {
        switch self {
        case .codex:
            return "C"
        case .claude:
            return "Cl"
        }
    }

    var tintColor: Color {
        switch self {
        case .codex:
            return Color(red: 0.25, green: 0.82, blue: 0.62)
        case .claude:
            return Color(red: 0.96, green: 0.64, blue: 0.28)
        }
    }

    var tintNSColor: NSColor {
        switch self {
        case .codex:
            return NSColor(calibratedRed: 0.25, green: 0.82, blue: 0.62, alpha: 1)
        case .claude:
            return NSColor(calibratedRed: 0.96, green: 0.64, blue: 0.28, alpha: 1)
        }
    }
}

@MainActor
private final class AppIconCache {
    static let shared = AppIconCache()

    private var icons: [AgentKind: NSImage] = [:]

    func icon(for agent: AgentKind) -> NSImage? {
        if let icon = icons[agent] {
            return icon
        }

        if agent == .codex, let codexLogo = codexLogoImage() {
            icons[agent] = codexLogo
            return codexLogo
        }

        guard FileManager.default.fileExists(atPath: agent.appBundlePath) else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: agent.appBundlePath)
        icons[agent] = icon
        return icon
    }

    private func codexLogoImage() -> NSImage? {
        if let bundledURL = Bundle.main.url(
            forResource: "OpenAI-white-monoblossom",
            withExtension: "png"
        ), let image = NSImage(contentsOf: bundledURL) {
            return image
        }

        let workspaceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/OpenAI-white-monoblossom.png")

        if let image = NSImage(contentsOf: workspaceURL) {
            return image
        }

        return nil
    }
}

private extension AgentSummary {
    var tintColor: Color {
        agent.tintColor
    }

    var helpText: String {
        let headline = "\(agent.displayName): \(statusLabel)"

        guard let primaryTask else {
            if isInferredFromProcess {
                return "\(headline)\nDetected from a running process."
            }

            return headline
        }

        let detail = primaryTask.question ?? primaryTask.detail ?? primaryTask.title
        return "\(headline)\n\(detail)"
    }

    private var statusLabel: String {
        switch status {
        case .running:
            return count > 1 ? "running \(count) tasks" : "running"
        case .needsInput:
            return count > 1 ? "needs input on \(count) tasks" : "needs input"
        case .success:
            return count > 1 ? "finished \(count) tasks" : "finished"
        case .failure:
            return count > 1 ? "failed \(count) tasks" : "failed"
        case .idle:
            return "idle"
        }
    }
}
