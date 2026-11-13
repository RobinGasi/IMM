import IMMDesign
import SwiftUI

/// Overlays the open panel with its dim, per the design geometry:
///
/// | Panel | width | top | dim | covers | motion |
/// |---|---|---|---|---|---|
/// | New transfer | min(560, W − 48) | 52 | 18 % | window | dim fade 200 ms, sheet-down 280 ms |
/// | Ask | min(720, W − 48) | 72 | 16 % | window | dim fade 180 ms, pop-in 200 ms |
/// | TAN sheet | min(520, pane − 48) | under toolbar | 16 % | content pane | dim fade 180 ms, sheet-down 260 ms |
/// | PIN sheet | min(480, pane − 48) | under toolbar | 20 % | content pane | dim fade 180 ms, sheet-down 260 ms |
///
/// The panel views (`AskPanel`, `NewTransferPanel`, `TANSheet`, `PINSheet`) provide only their content:
/// this host adds the background, the corner radius (7.2 for Ask and New transfer, bottom corners only
/// for the sheets), the shadow `0 18 40 rgba(0,0,0,.16)`, the width and the entrance motion. Esc and a
/// click on the dim close the panel.
struct PanelHost: View {
    @Environment(AppModel.self) private var model
    let windowSize: CGSize
    let sidebarWidth: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let panel = model.panel {
                content(for: panel)
                    .accessibilityAddTraits(.isModal)
                // Esc closes whichever panel is open.
                Button("") { model.closePanel() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: windowSize.width, height: windowSize.height, alignment: .topLeading)
    }

    private var paneWidth: CGFloat { windowSize.width - sidebarWidth }
    private var paneHeight: CGFloat { windowSize.height - IMMLayout.toolbarHeight }

    @ViewBuilder
    private func content(for panel: Panel) -> some View {
        switch panel {
        case .newTransfer:
            windowPanel(dim: 0.18, dimDuration: 0.2, top: 52, width: 560, maxHeight: nil, popIn: false) {
                NewTransferPanel()
            }
        case .ask:
            windowPanel(dim: 0.16, dimDuration: 0.18, top: 72, width: 720, maxHeight: windowSize.height - 96, popIn: true) {
                AskPanel()
            }
        case .tan:
            sheet(dim: 0.16, width: 520) { TANSheet() }
        case .pin:
            sheet(dim: 0.20, width: 480) { PINSheet() }
        }
    }

    private func dimView(_ opacity: Double, duration: Double) -> some View {
        IMMColor.scrim(opacity)
            .contentShape(Rectangle())
            .onTapGesture { model.closePanel() }
            .immFadeIn(duration: duration)
            .accessibilityHidden(true)
    }

    /// New transfer and Ask: dim over the whole window, panel with all corners rounded.
    private func windowPanel<Content: View>(
        dim: Double, dimDuration: Double, top: CGFloat, width: CGFloat, maxHeight: CGFloat?, popIn: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack(alignment: .top) {
            dimView(dim, duration: dimDuration)
            let panelWidth = min(width, windowSize.width - 48)
            let shape = RoundedRectangle(cornerRadius: IMMRadius.lg, style: .continuous)
            let panelView = content()
                .frame(width: panelWidth)
                .modifier(CappedHeight(maxHeight: maxHeight))
                .background(IMMColor.background)
                .clipShape(shape)
                .background(shape.fill(IMMColor.background).shadow(color: .black.opacity(0.16), radius: 20, x: 0, y: 18))
                .padding(.top, top)
            if popIn {
                panelView.immPopIn(duration: 0.2)
            } else {
                panelView.immSheetDown(duration: 0.28)
            }
        }
        .frame(width: windowSize.width, height: windowSize.height, alignment: .top)
    }

    /// TAN and PIN sheets: dim over the content pane, sheet hanging from the toolbar with square top corners.
    private func sheet<Content: View>(
        dim: Double, width: CGFloat, @ViewBuilder content: () -> Content
    ) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0, bottomLeadingRadius: IMMRadius.lg, bottomTrailingRadius: IMMRadius.lg,
            topTrailingRadius: 0, style: .continuous)
        return ZStack(alignment: .top) {
            dimView(dim, duration: 0.18)
            content()
                .frame(width: min(width, paneWidth - 48))
                .fixedSize(horizontal: false, vertical: true)
                .background(IMMColor.background)
                .clipShape(shape)
                .background(shape.fill(IMMColor.background).shadow(color: .black.opacity(0.16), radius: 20, x: 0, y: 18))
                .immSheetDown(duration: 0.26)
        }
        .frame(width: paneWidth, height: paneHeight, alignment: .top)
        .padding(.leading, sidebarWidth)
        .padding(.top, IMMLayout.toolbarHeight)
        .frame(width: windowSize.width, height: windowSize.height, alignment: .topLeading)
    }
}

/// Sizes a panel to its ideal height, capped at `maxHeight`. A plain `.frame(maxHeight:)` would take the
/// whole proposed height and centre the panel's content in it.
private struct CappedHeight: ViewModifier {
    let maxHeight: CGFloat?

    func body(content: Content) -> some View {
        CappedHeightLayout(maxHeight: maxHeight ?? .infinity) { content }
    }
}

private struct CappedHeightLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: ideal.width, height: min(ideal.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
