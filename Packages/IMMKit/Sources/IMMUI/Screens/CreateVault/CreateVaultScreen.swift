import AppKit
import IMMDesign
import IMMVault
import SwiftUI
import UniformTypeIdentifiers

/// Everything the Create vault form holds. Tests start the screen from a draft to show each state.
struct CreateVaultDraft: Equatable {
    var password = ""
    var confirm = ""
    var touchID = true
    /// Set by the first press on Create; from then on the two errors follow the fields.
    var attempted = false
    var creating = false
    /// The chosen package location while the synced-folder warning is open.
    var pendingSyncedLocation: URL?
    /// Why creating failed (shown under the buttons).
    var failure: String?
}

/// Onboarding step 1: choose the database password, choose where the database lives, create it.
public struct CreateVaultScreen: View {
    @Environment(AppModel.self) private var model
    @State private var draft: CreateVaultDraft
    @FocusState private var passwordFocused: Bool
    @FocusState private var confirmFocused: Bool

    public init() {
        _draft = State(initialValue: CreateVaultDraft())
    }

    init(draft: CreateVaultDraft) {
        _draft = State(initialValue: draft)
    }

    // MARK: Derived state

    private var tooShortError: Bool {
        draft.attempted && CreateVaultRules.isTooShort(draft.password)
    }

    private var mismatchError: Bool {
        draft.attempted && CreateVaultRules.isMismatch(password: draft.password, confirm: draft.confirm)
    }

    private var canSubmit: Bool {
        CreateVaultRules.canSubmit(password: draft.password, confirm: draft.confirm) && !draft.creating
    }

    private var touchIDCaption: String? { CreateVaultTouchID.caption(for: model.biometry) }
    private var touchIDAvailable: Bool { model.biometry == .available }

    private var touchIDBinding: Binding<Bool> {
        Binding(get: { touchIDAvailable && draft.touchID }, set: { draft.touchID = $0 })
    }

    private let headlineFont = IMMFont.titleXL.sized(26, lineHeight: 31.2)

    private var showsWarning: Bool { draft.pendingSyncedLocation != nil }

    // MARK: Body

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                SetupTitlebar(step: String(localized: "Step 1 of 3", bundle: .module), title: String(localized: "Set up IMM", bundle: .module))
                HStack(spacing: 0) {
                    leftColumn
                        .frame(width: 440)
                        .overlay(alignment: .trailing) { Rectangle().fill(IMMColor.border).frame(width: 1) }
                    if showsWarning {
                        IMMColor.muted.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        CreateVaultPreviewPane()
                    }
                }
            }
            .environment(\.immInert, showsWarning)
            .disabled(showsWarning)
            if showsWarning { syncedFolderWarning }
        }
        .background(IMMColor.background)
        .foregroundStyle(IMMColor.foreground)
    }

    // MARK: Left column

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    IMMLogoMark(width: 40, animated: true)
                    Text(verbatim: "Ich mag Moneten").immFont(IMMFont.titleMDTight)
                }
                VStack(alignment: .leading, spacing: 10) {
                    // line-height 1.2 is below the font's natural height, so each line is fixed to 31.2.
                    VStack(alignment: .leading, spacing: 0) {
                        Text("All your accounts.", bundle: .module).frame(height: 31.2)
                        Text("One ledger on your Mac.", bundle: .module).frame(height: 31.2)
                    }
                    .font(headlineFont.font)
                    .tracking(headlineFont.trackingPoints)
                    .immRiseIn(duration: 0.5, delay: 0.08)
                    Text("IMM talks to your banks directly via FinTS. Your data stays in an encrypted file on this Mac — no cloud account, no tracking.", bundle: .module)
                        .immFont(.body)
                        .foregroundStyle(IMMColor.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                        .immRiseIn(duration: 0.46, delay: 0.16)
                }
            }
            form
                .immRiseIn(duration: 0.44, delay: 0.24)
        }
        .frame(width: 344, alignment: .leading)
        .padding(.top, 48)
        .padding(.bottom, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                field(
                    label: Text("Database password", bundle: .module),
                    prompt: Text("At least 8 characters", bundle: .module),
                    text: $draft.password, isError: tooShortError,
                    message: Text("Use at least 8 characters.", bundle: .module),
                    focused: $passwordFocused, onSubmit: { confirmFocused = true })
                field(
                    label: Text("Confirm password", bundle: .module),
                    prompt: Text("Type the password again", bundle: .module),
                    text: $draft.confirm, isError: mismatchError,
                    message: Text("The passwords don't match.", bundle: .module),
                    focused: $confirmFocused, onSubmit: { submit() })
            }
            touchIDRow
            VStack(alignment: .leading, spacing: 6) {
                createButton
                openButton
                if let failure = draft.failure {
                    Text(verbatim: failure)
                        .immFont(.small)
                        .foregroundStyle(IMMColor.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .padding(.top, 4)
        }
        .initialFocus($passwordFocused, isEnabled: !draft.creating)
    }

    private func field(
        label: Text, prompt: Text, text: Binding<String>, isError: Bool, message: Text,
        focused: FocusState<Bool>.Binding, onSubmit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            label
                .immFont(.label)
                .foregroundStyle(draft.creating ? IMMColor.mutedForeground : IMMColor.foreground)
            IMMSecureField(text: text, prompt: prompt, isError: isError, focused: focused)
                .onSubmit(onSubmit)
                .accessibilityLabel(label)
                .disabled(draft.creating)
            if isError {
                message
                    .immFont(.small)
                    .foregroundStyle(IMMColor.destructive)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
    }

    private var touchIDRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                IMMSwitch(isOn: touchIDBinding)
                    .disabled(!touchIDAvailable || draft.creating)
                Text("Unlock with Touch ID", bundle: .module)
                    .immFont(.label)
                    .foregroundStyle(touchIDAvailable && !draft.creating ? IMMColor.foreground : IMMColor.mutedForeground)
            }
            if let caption = touchIDCaption {
                Text(verbatim: caption)
                    .immFont(.small)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .padding(.leading, 36)
            }
        }
    }

    @ViewBuilder
    private var createButton: some View {
        if draft.creating {
            Button {} label: {
                HStack(spacing: 4) {
                    VaultSpinner()
                    Text("Creating database…", bundle: .module)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(VaultMutedButtonStyle())
            .disabled(true)
        } else if canSubmit {
            Button { submit() } label: {
                Text("Create database", bundle: .module).frame(maxWidth: .infinity)
            }
            .immButtonStyle(.default)
        } else {
            Button {} label: {
                Text("Create database", bundle: .module).frame(maxWidth: .infinity)
            }
            .buttonStyle(VaultMutedButtonStyle())
            .disabled(true)
        }
    }

    @ViewBuilder
    private var openButton: some View {
        if draft.creating {
            Text("Open existing database…", bundle: .module)
                .immFont(.control)
                .foregroundStyle(IMMColor.mutedForeground)
                .frame(maxWidth: .infinity, minHeight: 28)
        } else {
            Button { model.chooseDatabase() } label: {
                Text("Open existing database…", bundle: .module).frame(maxWidth: .infinity)
            }
            .immButtonStyle(.ghost)
        }
    }

    // MARK: Synced-folder warning

    private var syncedFolderWarning: some View {
        SyncedFolderWarning(
            leadingInset: 440, useFolder: useSyncedFolder, chooseAnother: chooseAnotherFolder,
            dismiss: { draft.pendingSyncedLocation = nil })
    }

    // MARK: Actions

    private func submit() {
        guard canSubmit, !showsWarning else { return }
        draft.attempted = true
        guard CreateVaultRules.isValid(password: draft.password, confirm: draft.confirm) else { return }
        chooseLocation()
    }

    private func chooseLocation() {
        guard let url = VaultSavePanel.chooseNewLocation() else { return }
        if SyncedFolderDetector.isSynced(url.deletingLastPathComponent()) {
            draft.pendingSyncedLocation = url
        } else {
            create(at: url)
        }
    }

    private func chooseAnotherFolder() {
        draft.pendingSyncedLocation = nil
        chooseLocation()
    }

    private func useSyncedFolder() {
        guard let url = draft.pendingSyncedLocation else { return }
        draft.pendingSyncedLocation = nil
        create(at: url)
    }

    private func create(at url: URL) {
        draft.creating = true
        draft.failure = nil
        let password = draft.password
        let enableTouchID = touchIDAvailable && draft.touchID
        Task { @MainActor in
            do {
                try await model.createVault(at: url, password: password, enableTouchID: enableTouchID)
                draft.password = ""
                draft.confirm = ""
            } catch {
                draft.creating = false
                draft.failure = Self.message(for: error)
            }
        }
    }

    static func message(for error: Error) -> String {
        switch error as? VaultError {
        case .alreadyExists:
            return String(localized: "A database with this name already exists. Choose another name.", bundle: .module)
        case .io(let detail):
            return String(localized: "The database couldn't be created: \(detail)", bundle: .module)
        default:
            return String(localized: "The database couldn't be created: \(error.localizedDescription)", bundle: .module)
        }
    }
}

// MARK: - Save panel

/// The standard save panel for a new `.imm` package, suggesting `~/Documents/Moneten.imm`.
@MainActor
enum VaultSavePanel {
    static func chooseNewLocation() -> URL? {
        let panel = NSSavePanel()
        panel.title = String(localized: "Create Database", bundle: .module)
        panel.message = String(localized: "Choose where to keep your encrypted database.", bundle: .module)
        panel.prompt = String(localized: "Create", bundle: .module)
        panel.nameFieldStringValue = "Moneten.imm"
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let type = UTType("dev.gasi.imm.vault") { panel.allowedContentTypes = [type] }
        let delegate = NewVaultPanelDelegate()
        panel.delegate = delegate
        guard withExtendedLifetime(delegate, { panel.runModal() }) == .OK, var url = panel.url else { return nil }
        if url.pathExtension.lowercased() != "imm" { url.appendPathExtension("imm") }
        return url
    }
}

/// A database is never replaced: a name that is taken is refused inside the panel.
private final class NewVaultPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, validate url: URL) throws {
        var target = url
        if target.pathExtension.lowercased() != "imm" { target.appendPathExtension("imm") }
        if FileManager.default.fileExists(atPath: target.path) {
            throw NSError(
                domain: "dev.gasi.imm.createvault", code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "A database with this name already exists. Choose another name.", bundle: .module)])
        }
    }
}

// MARK: - Pieces

/// The disabled primary button as drawn: muted fill, border rule, muted text at full opacity.
struct VaultMutedButtonStyle: ButtonStyle {
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

/// The 14 px spinner of a busy button (Lucide `loader-circle`): a 3/4 ring that turns once a second.
struct VaultSpinner: View {
    @Environment(\.immDisableMotion) private var disableMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if disableMotion || reduceMotion {
            ring(angle: 0)
        } else {
            TimelineView(.animation) { context in
                let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
                ring(angle: turn * 360)
            }
        }
    }

    private func ring(angle: Double) -> some View {
        Circle()
            .trim(from: 0, to: 0.8)
            .stroke(style: StrokeStyle(lineWidth: 1.17, lineCap: .round))
            .frame(width: 10.5, height: 10.5)
            .rotationEffect(.degrees(angle))
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)
    }
}
