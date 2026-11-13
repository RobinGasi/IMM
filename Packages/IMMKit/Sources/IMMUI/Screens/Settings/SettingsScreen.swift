import AppKit
import IMMDesign
import IMMVault
import SwiftUI

/// The Settings window content (760 × 560): title and tab strip, then the Security tab.
///
/// Security and Sync work. General, Accounts, Categories, Export and "Hide balances in the menu bar"
/// are drawn as designed and inert. The change-password dialog is an in-window panel over the whole window.
public struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: ChangePasswordSheet.Draft?
    @State private var touchIDBusy = false
    @State private var tab: SettingsTab = .security
    private let syncActions: SyncSettingsActions?

    public init() {
        self.syncActions = nil
    }

    /// Starts with the change-password dialog open (tests render the designed dialog states).
    init(sheet: ChangePasswordSheet.Draft?) {
        self._sheet = State(initialValue: sheet)
        self.syncActions = nil
    }

    /// Starts on `tab` with sync driven by `sync` (tests render the Sync artboards with a fake).
    init(tab: SettingsTab, sync: SyncSettingsActions) {
        self._tab = State(initialValue: tab)
        self.syncActions = sync
    }

    private var actions: SyncSettingsActions { syncActions ?? SyncSettingsActions(sync: model.sync) }

    public var body: some View {
        let actions = actions
        return VStack(spacing: 0) {
            SettingsHeader(selection: $tab)
            switch tab {
            case .sync:
                SyncSettingsContent(actions: actions)
                    .padding(.top, 24)
                    .padding(.leading, 32)
                    .padding(.trailing, 48)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .immFadeIn(duration: 0.16)
            default:
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(IMMColor.background)
        .overlay {
            if sheet != nil {
                changePasswordPanel
            }
        }
        .overlay { SyncPairingPanel(actions: actions) }
        .onExitCommand {
            if sheet != nil {
                sheet = nil
            } else {
                Task { await SyncPairingPanel(actions: actions).dismiss() }
            }
        }
    }

    // MARK: Security tab

    /// The designed Touch ID caption, shown under the switch when it cannot be turned on.
    private var touchIDCaption: String? {
        guard !model.touchIDEnabled else { return nil }
        switch model.biometry {
        case .available: return nil
        case .missingEntitlement: return String(localized: "Touch ID needs a signed build of IMM.", bundle: .module)
        case .noSensor: return String(localized: "This Mac has no Touch ID.", bundle: .module)
        case .notEnrolled:
            return String(localized: "Add a fingerprint in System Settings to use Touch ID.", bundle: .module)
        }
    }

    private var content: some View {
        let caption = touchIDCaption
        return VStack(alignment: .leading, spacing: 0) {
            // While the dialog is open the designed screen keeps only the rules; the rows are hidden.
            databaseAndEncryption.modifier(HiddenWhile(sheet != nil))
            SettingsDivider()
            unlockAndLock(caption: caption).modifier(HiddenWhile(sheet != nil))
            SettingsDivider()
            bankingPINs.modifier(HiddenWhile(sheet != nil))
        }
        .padding(.top, caption == nil ? 24 : 16)
        .padding(.leading, 32)
        .padding(.trailing, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .immFadeIn(duration: 0.16)
    }

    private var databaseAndEncryption: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsRow(Text("Database:", bundle: .module), alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: model.vaultURL?.lastPathComponent ?? "")
                            .immFont(.bodyMedium)
                            .foregroundStyle(IMMColor.foreground)
                        Text(verbatim: model.vaultURL.map(SettingsPaths.displayPath) ?? "")
                            .immFont(.mono)
                            .foregroundStyle(IMMColor.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button {
                        if let url = model.vaultURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    } label: {
                        Text("Show in Finder", bundle: .module)
                    }
                    .immButtonStyle(.outline)
                }
            }
            SettingsRow(Text("Encryption:", bundle: .module), alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsText(Text("Encrypted with your database password", bundle: .module))
                    Button {
                        sheet = ChangePasswordSheet.Draft()
                    } label: {
                        Text("Change password…", bundle: .module)
                    }
                    .immButtonStyle(.outline)
                }
            }
        }
    }

    private func unlockAndLock(caption: String?) -> some View {
        @Bindable var model = model
        let touchIDDisabled = !model.touchIDEnabled && model.biometry != .available
        return VStack(alignment: .leading, spacing: 12) {
            SettingsRow(Text("Unlock:", bundle: .module), alignment: caption == nil ? .center : .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        IMMSwitch(isOn: touchIDBinding)
                            .disabled(touchIDDisabled || touchIDBusy)
                        SettingsText(Text("Touch ID", bundle: .module), muted: touchIDDisabled)
                    }
                    if let caption {
                        Text(verbatim: caption)
                            .immFont(.small)
                            .foregroundStyle(IMMColor.mutedForeground)
                            .padding(.leading, 36)
                    }
                }
            }
            SettingsRow(Text("Lock automatically:", bundle: .module)) {
                SelectTrigger(selection: $model.autoLockMinutes, options: Self.autoLockOptions, width: 248)
            }
            SettingsRow(nil) {
                IMMCheckbox(isOn: $model.lockOnSleep) {
                    SettingsText(Text("Lock when the Mac goes to sleep", bundle: .module))
                }
            }
            SettingsRow(nil) {
                IMMCheckbox(isOn: .constant(false)) {
                    SettingsText(Text("Hide balances in the menu bar", bundle: .module))
                }
                .inertControl()
            }
        }
    }

    /// "Never" is stored as 0 minutes.
    static let autoLockOptions: [IMMOption<Int>] = [
        IMMOption(1, Text("After 1 minute of inactivity", bundle: .module)),
        IMMOption(5, Text("After 5 minutes of inactivity", bundle: .module)),
        IMMOption(15, Text("After 15 minutes of inactivity", bundle: .module)),
        IMMOption(60, Text("After 1 hour of inactivity", bundle: .module)),
        IMMOption(0, Text("Never", bundle: .module)),
    ]

    private var bankingPINs: some View {
        let count = model.storedPINCount
        return SettingsRow(Text("Banking PINs:", bundle: .module), alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                SettingsText(Self.pinCountText(count))
                if count > 0 {
                    Button {
                        Task { await confirmPINRemoval(count: count) }
                    } label: {
                        Text("Remove stored PINs…", bundle: .module)
                    }
                    .immButtonStyle(.outline)
                } else {
                    Button {} label: {
                        Text("Remove stored PINs…", bundle: .module)
                    }
                    .buttonStyle(DisabledOutlineButtonStyle())
                    .disabled(true)
                }
            }
        }
    }

    static func pinCountText(_ count: Int) -> Text {
        switch count {
        case 0: Text("No PINs stored in macOS Keychain", bundle: .module)
        case 1: Text("1 PIN stored in macOS Keychain", bundle: .module)
        default: Text("\(count) PINs stored in macOS Keychain", bundle: .module)
        }
    }

    // MARK: Actions

    private var touchIDBinding: Binding<Bool> {
        Binding(
            get: { model.touchIDEnabled },
            set: { on in
                guard !touchIDBusy else { return }
                touchIDBusy = true
                Task {
                    defer { touchIDBusy = false }
                    do {
                        try await model.setTouchID(on)
                    } catch BiometryError.cancelled {
                        // The user dismissed the prompt: nothing to report.
                    } catch {
                        SettingsAlerts.show(
                            title: String(localized: "Touch ID couldn't be changed.", bundle: .module),
                            detail: String(describing: error))
                    }
                }
            })
    }

    private func confirmPINRemoval(count: Int) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count == 1
            ? String(localized: "Remove 1 stored PIN?", bundle: .module)
            : String(localized: "Remove \(count) stored PINs?", bundle: .module)
        alert.informativeText = String(
            localized: "IMM will ask for your online-banking PIN the next time it syncs.", bundle: .module)
        let remove = alert.addButton(withTitle: String(localized: "Remove", bundle: .module))
        remove.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel", bundle: .module))
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        if response == .alertFirstButtonReturn { model.removeStoredPINs() }
    }

    // MARK: Change-password panel

    private var changePasswordPanel: some View {
        ZStack(alignment: .top) {
            IMMColor.scrim(0.18)
                .contentShape(Rectangle())
                .immFadeIn(duration: 0.2)
                .accessibilityHidden(true)
            let shape = RoundedRectangle(cornerRadius: IMMRadius.lg, style: .continuous)
            ChangePasswordSheet(draft: sheet ?? ChangePasswordSheet.Draft()) { sheet = nil }
                .frame(width: 400)
                .background(IMMColor.background)
                .clipShape(shape)
                .background(shape.fill(IMMColor.background).shadow(color: .black.opacity(0.16), radius: 20, x: 0, y: 18))
                .padding(.top, SettingsHeader.height)
                .immPopIn(duration: 0.2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Pieces

/// One `grid-cols-[220px_auto]` row: right-aligned label in a 220 px column, 12 px gap, then the control.
struct SettingsRow<Content: View>: View {
    private let label: Text?
    private let alignment: VerticalAlignment
    private let content: Content

    init(_ label: Text?, alignment: VerticalAlignment = .center, @ViewBuilder content: () -> Content) {
        self.label = label
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        HStack(alignment: alignment, spacing: 12) {
            Group {
                if let label {
                    label.immFont(.body).foregroundStyle(IMMColor.foreground)
                } else {
                    Color.clear.frame(height: 20)
                }
            }
            .frame(width: 220, alignment: .trailing)
            content
        }
    }
}

struct HiddenWhile: ViewModifier {
    let hidden: Bool

    init(_ hidden: Bool) {
        self.hidden = hidden
    }

    func body(content: Content) -> some View {
        content.opacity(hidden ? 0 : 1).allowsHitTesting(!hidden).accessibilityHidden(hidden)
    }
}

struct SettingsText: View {
    let text: Text
    var muted = false

    init(_ text: Text, muted: Bool = false) {
        self.text = text
        self.muted = muted
    }

    var body: some View {
        text.immFont(.body).foregroundStyle(muted ? IMMColor.mutedForeground : IMMColor.foreground)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(IMMColor.border).frame(height: 1).padding(.vertical, 20)
    }
}

/// The disabled outline button of the "No PINs" artboard: `muted` fill, `muted-foreground` text, full opacity.
private struct DisabledOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: IMMRadius.md, style: .continuous)
        configuration.label
            .immFont(.control)
            .foregroundStyle(IMMColor.mutedForeground)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(shape.fill(IMMColor.muted))
            .overlay(shape.strokeBorder(IMMColor.border, lineWidth: 1))
    }
}

enum SettingsPaths {
    /// The package path with the user's home folder written as `~` (the sandbox container is not "home").
    static func displayPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let home = homeDirectory
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private static var homeDirectory: String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir)).standardizedFileURL.path
        }
        return NSHomeDirectory()
    }
}

enum SettingsAlerts {
    @MainActor
    static func show(title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: String(localized: "OK", bundle: .module))
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
