import SwiftUI

// MARK: - Model

struct TooltipInfo: Equatable {
    var title: String
    var subtitle: String?
    /// Frame of the hovered control, in the `TooltipModel.space` coordinate space.
    var anchor: CGRect
}

/// Tracks which control is hovered and shows its card after a short delay, the
/// way Paint's own tooltips behave. One instance is shared by the whole window.
final class TooltipModel: ObservableObject {
    static let space = "iPaintRoot"

    /// Wait before the first card appears. Windows uses 500ms; a little longer
    /// suits a dense ribbon, where a stray pointer crosses several icons.
    static let delay: TimeInterval = 0.6
    /// Wait before a *replacement* card appears, once one is already up. Short,
    /// so a deliberate move to the next control still feels responsive, but not
    /// zero — at zero, one sweep along the ribbon fires a card under every icon.
    static let reshowDelay: TimeInterval = 0.15

    @Published var info: TooltipInfo?

    private var pending: DispatchWorkItem?
    private var isShowing = false
    /// True while a dropdown is open, or just after a click. A card must never
    /// sit on top of an open menu, and the pointer is still over the button that
    /// opened it, so hover alone cannot tell us to get out of the way.
    private var suppressed = false
    private var observers: [NSObjectProtocol] = []
    private var clickMonitor: Any?

    init() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification,
                               object: nil, queue: .main) { [weak self] _ in
                self?.suppress()
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification,
                               object: nil, queue: .main) { [weak self] _ in
                self?.suppressed = false
            },
        ]
        // Clicking anything dismisses the card, as it does elsewhere on the Mac;
        // this also covers menus opened in ways that post no tracking notification.
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            self?.dismiss()
            return event
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    /// Hide now and make the next hover wait the full delay again.
    func dismiss() {
        pending?.cancel()
        pending = nil
        isShowing = false
        info = nil
    }

    private func suppress() {
        dismiss()
        suppressed = true
    }

    func schedule(title: String, subtitle: String?, anchor: CGRect) {
        guard !suppressed else { return }
        pending?.cancel()
        let next = TooltipInfo(title: title, subtitle: subtitle, anchor: anchor)

        // A visible card describes the control just left behind, so drop it at
        // once rather than letting stale text sit under the new one.
        let replacing = isShowing
        if replacing, info != next { info = nil }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isShowing = true
            withAnimation(.easeOut(duration: 0.12)) { self.info = next }
        }
        pending = work
        let wait = replacing ? Self.reshowDelay : Self.delay
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        guard !suppressed else { return }
        // A small grace period keeps the card steady while the pointer crosses
        // the gap between two adjacent buttons.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isShowing = false
            self.info = nil
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
}

// MARK: - The card

struct TooltipCard: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12, weight: .semibold))
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: 260, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.22), radius: 7, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.primary.opacity(0.14), lineWidth: 0.5)
        )
        .fixedSize()
    }
}

/// Positions the card near its control, nudged to stay inside the window.
struct TooltipOverlay: View {
    let info: TooltipInfo
    let container: CGSize
    @State private var size: CGSize = .zero

    var body: some View {
        TooltipCard(title: info.title, subtitle: info.subtitle)
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { size = g.size }
                        .onChange(of: g.size) { _, s in size = s }
                }
            )
            .offset(x: origin.x, y: origin.y)
            .allowsHitTesting(false)
    }

    private var origin: CGPoint {
        Self.position(anchor: info.anchor, card: size, container: container)
    }

    /// Centres the card under its control, then nudges it to stay inside the
    /// window, flipping above when there is no room below.
    static func position(anchor: CGRect, card: CGSize, container: CGSize) -> CGPoint {
        let margin: CGFloat = 8, gap: CGFloat = 7
        let idealX = anchor.midX - card.width / 2
        let maxX = max(margin, container.width - card.width - margin)
        let x = min(max(margin, idealX), maxX)

        let below = anchor.maxY + gap
        // Status-bar controls sit at the bottom edge, where a card placed below
        // would be clipped, so those flip to sit above the control instead.
        let fitsBelow = below + card.height <= container.height - 4
        let y = fitsBelow ? below : max(4, anchor.minY - card.height - gap)
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Attaching a tooltip

private struct PaintTooltipModifier: ViewModifier {
    let title: String
    let subtitle: String?
    @EnvironmentObject private var tips: TooltipModel
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { frame = geo.frame(in: .named(TooltipModel.space)) }
                        .onChange(of: geo.frame(in: .named(TooltipModel.space))) { _, f in
                            frame = f
                        }
                }
                .allowsHitTesting(false)   // must not steal clicks from the control
            )
            .onHover { inside in
                if inside {
                    tips.schedule(title: title, subtitle: subtitle, anchor: frame)
                } else {
                    tips.cancel()
                }
            }
    }
}

extension View {
    /// Shows a Paint-style hover card describing this control.
    func paintTip(_ title: String, _ subtitle: String? = nil) -> some View {
        modifier(PaintTooltipModifier(title: title, subtitle: subtitle))
    }
}
