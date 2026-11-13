import IMMDesign
import SwiftUI

/// The 56 px toolbar of the main window: title and subtitle, search field (opens Ask), Sync, New transfer.
struct ToolbarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let text = ShellText.toolbar(route: model.route, snapshot: model.sidebar.snapshot, state: model.bank.syncState)
        HStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: text.title)
                    .immFont(IMMFont.titleMDTight)
                    .foregroundStyle(IMMColor.foreground)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                Text(verbatim: text.subtitle)
                    .immFont(.small)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()

            ToolbarSearchField { model.openAsk() }
                .frame(minWidth: 132, idealWidth: 240, maxWidth: 240)

            Button {
                model.bank.sync()
            } label: {
                SpinningIcon(name: "refresh", size: 14, spinning: model.bank.syncState.isSyncing)
            }
            .immButtonStyle(.ghost, size: .icon)
            .accessibilityLabel(Text("Sync all accounts", bundle: .module))
            .accessibilityValue(Text(verbatim: model.bank.syncState.isSyncing ? String(localized: "Syncing…", bundle: .module) : ""))

            Button {
                model.openNewTransfer()
            } label: {
                HStack(spacing: 4) {
                    IMMIcon("arrow-up-right", size: IMMButtonStyle.Size.default.iconSize)
                    Text("New transfer", bundle: .module)
                }
            }
            .immButtonStyle(.default, leadingIcon: true)
        }
        .padding(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 16))
        .frame(height: IMMLayout.toolbarHeight)
        .background(IMMColor.windowChrome)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) {
            Rectangle().fill(IMMColor.border).frame(height: 1)
        }
    }
}

/// 28 px field look-alike: border `input`, hover `muted-foreground`, 140 ms.
private struct ToolbarSearchField: View {
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.immDisableMotion) private var disableMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                IMMIcon("search", size: 14)
                Text("Ask or search", bundle: .module)
                    .immFont(.controlRegular)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("⌘K")
                    .immFont(.caption)
            }
            .foregroundStyle(IMMColor.mutedForeground)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: IMMRadius.md, style: .continuous).fill(IMMColor.background))
            .overlay(
                RoundedRectangle(cornerRadius: IMMRadius.md, style: .continuous)
                    .strokeBorder(hovering ? IMMColor.mutedForeground : IMMColor.input, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: IMMRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .animation(disableMotion ? nil : Motion.ease(0.14), value: hovering)
        .accessibilityLabel(Text("Search transactions", bundle: .module))
    }
}
