import IMMDesign
import SwiftUI

/// The Settings tabs. Only Security and Sync work; the others are drawn as designed and inert.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, accounts, security, sync, categories, export

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: "settings"
        case .accounts: "landmark"
        case .security: "lock"
        case .sync: "refresh"
        case .categories: "tag"
        case .export: "share"
        }
    }

    var title: Text {
        switch self {
        case .general: Text("General", bundle: .module)
        case .accounts: Text("Accounts", bundle: .module)
        case .security: Text("Security", bundle: .module)
        case .sync: Text("Sync", bundle: .module)
        case .categories: Text("Categories", bundle: .module)
        case .export: Text("Export", bundle: .module)
        }
    }

    var isEnabled: Bool { self == .security || self == .sync }
}

/// The Settings title bar: window-chrome background, the centred tab name and the tab strip.
/// The real window buttons sit at the left (`WindowChrome(.settings)`).
struct SettingsHeader: View {
    /// 18 top + 16 title + 6 bottom + 45 tab + 8 bottom + 1 rule.
    static let height: CGFloat = 94

    @Binding var selection: SettingsTab

    var body: some View {
        VStack(spacing: 0) {
            selection.title
                .immFont(IMMFont.bodySemibold.withLineHeight(16))
                .foregroundStyle(IMMColor.foreground)
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
                .padding(.bottom, 6)
            HStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    tabView(tab)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .background(IMMColor.windowChrome)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) {
            Rectangle().fill(IMMColor.border).frame(height: 1)
        }
    }

    @ViewBuilder
    private func tabView(_ tab: SettingsTab) -> some View {
        if tab.isEnabled {
            Button {
                selection = tab
            } label: {
                Color.clear.frame(width: 72, height: 45)
            }
            .buttonStyle(SettingsTabButtonStyle(tab: tab, selected: tab == selection))
            .focusEffectDisabled()
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(tab == selection ? .isSelected : [])
        } else {
            SettingsTabLabel(tab: tab, selected: false, hovering: false, pressed: false)
                .inertControl()
        }
    }
}

private struct SettingsTabButtonStyle: ButtonStyle {
    let tab: SettingsTab
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        HoverTab(tab: tab, selected: selected, pressed: configuration.isPressed)
    }
}

private struct HoverTab: View {
    let tab: SettingsTab
    let selected: Bool
    let pressed: Bool
    @State private var hovering = false

    var body: some View {
        SettingsTabLabel(tab: tab, selected: selected, hovering: hovering, pressed: pressed)
            .onHover { hovering = $0 }
    }
}

private struct SettingsTabLabel: View {
    let tab: SettingsTab
    let selected: Bool
    let hovering: Bool
    let pressed: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: IMMRadius.md, style: .continuous)
        let active = selected || pressed
        let fill: Color = active ? IMMColor.accent : (hovering ? IMMColor.muted : Color.clear)
        VStack(spacing: 2) {
            IMMIcon(tab.icon, size: 20, color: active ? IMMColor.accentForeground : IMMColor.mutedForeground)
            tab.title
                .immFont(IMMFont(
                    name: "tab", size: 11, lineHeight: 14, weight: selected ? .semibold : .regular))
                .foregroundStyle(active ? IMMColor.accentForeground : IMMColor.foreground)
        }
        .padding(.top, 5)
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
        .frame(width: 72)
        .background(shape.fill(fill))
        .contentShape(shape)
    }
}
