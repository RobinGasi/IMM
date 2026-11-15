import IMMDesign
import SwiftUI

/// The companion's root: switches on `CompanionModel.phase`.
///
/// The camera scanner is injected by the app target (VisionKit is iOS-only and lives there);
/// `init(model:)` uses a placeholder for macOS hosts and tests.
public struct CompanionRootView<Scanner: View>: View {
    private let model: CompanionModel
    private let scanner: Scanner

    public init(model: CompanionModel, @ViewBuilder scanner: () -> Scanner) {
        self.model = model
        self.scanner = scanner()
    }

    public var body: some View {
        content
            .environment(model)
            .background(IMMColor.background.ignoresSafeArea())
            .tint(IMMColor.primary)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .welcome:
            WelcomeView()
        case .pairing(let step):
            pairing(step)
        case .locked:
            LockedView()
        case .ready:
            CompanionTabView()
        }
    }

    @ViewBuilder
    private func pairing(_ step: CompanionPairingStep) -> some View {
        switch step {
        case .scanning:
            PairScanView(scanner: scanner)
        case .connecting(let macName):
            PairScanView(scanner: scanner, isConnecting: true, macName: macName)
        case .confirm(let code, let macName):
            PairConfirmView(code: code, macName: macName, isWaitingForMac: false)
        case .waitingForMac(let macName):
            PairConfirmView(code: nil, macName: macName, isWaitingForMac: true)
        case .importing:
            PairingProgressView()
        case .failed(let message):
            PairingFailedView(message: message)
        }
    }
}

extension CompanionRootView where Scanner == CompanionScannerPlaceholder {
    public init(model: CompanionModel) {
        self.init(model: model) { CompanionScannerPlaceholder() }
    }
}

/// Stand-in for the camera on hosts without one (macOS, previews, tests).
public struct CompanionScannerPlaceholder: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 64, weight: .light))
            Text("Camera preview", bundle: .module)
                .immFont(CompanionFont.callout)
        }
        .foregroundStyle(Color.white.opacity(0.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The four tabs of a paired phone.
struct CompanionTabView: View {
    var body: some View {
        TabView {
            NavigationStack { OverviewView() }
                .tabItem { Label { Text("Overview", bundle: .module) } icon: { Image(systemName: "chart.pie") } }
            NavigationStack { AccountsView() }
                .tabItem { Label { Text("Accounts", bundle: .module) } icon: { Image(systemName: "building.columns") } }
            NavigationStack { TransactionsView() }
                .tabItem { Label { Text("Transactions", bundle: .module) } icon: { Image(systemName: "list.bullet") } }
            NavigationStack { CompanionSettingsView() }
                .tabItem { Label { Text("Settings", bundle: .module) } icon: { Image(systemName: "gearshape") } }
        }
    }
}

/// First screen of an unpaired phone.
struct WelcomeView: View {
    @Environment(CompanionModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 20) {
                IMMLogoMark(width: 60)
                Text("IMM", bundle: .module)
                    .immFont(CompanionFont.hero)
                    .foregroundStyle(IMMColor.foreground)
                Text(
                    "See your balances and bookings from IMM on your Mac, and sort transactions into categories on the go.",
                    bundle: .module
                )
                .immFont(CompanionFont.body)
                .foregroundStyle(IMMColor.mutedForeground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            Spacer()
            VStack(spacing: 14) {
                Button {
                    model.startPairing()
                } label: {
                    Text("Pair with your Mac", bundle: .module)
                }
                .buttonStyle(CompanionButtonStyle(kind: .primary))
                Text(
                    "Bank access stays on your Mac. Turn on Tailscale on both devices before you pair.",
                    bundle: .module
                )
                .immFont(CompanionFont.footnote)
                .foregroundStyle(IMMColor.mutedForeground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}

/// Shown while the vault is closed; asks for Face ID / passcode once per activation.
struct LockedView: View {
    @Environment(CompanionModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var prompted = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            IMMLogoMark(width: 60)
            Text("IMM is locked", bundle: .module)
                .immFont(CompanionFont.title)
                .foregroundStyle(IMMColor.foreground)
            Spacer()
            Button {
                Task { await model.unlock() }
            } label: {
                Text("Unlock", bundle: .module)
            }
            .buttonStyle(CompanionButtonStyle(kind: .primary))
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                guard !prompted else { return }
                prompted = true
                Task { await model.unlock() }
            case .background:
                prompted = false
            default:
                break
            }
        }
    }
}

/// The grant arrived and the ledger copy is being applied.
struct PairingProgressView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Importing your ledger…", bundle: .module)
                .immFont(CompanionFont.headline)
                .foregroundStyle(IMMColor.foreground)
            Text("This can take a moment.", bundle: .module)
                .immFont(CompanionFont.callout)
                .foregroundStyle(IMMColor.mutedForeground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Pairing stopped with an error.
struct PairingFailedView: View {
    @Environment(CompanionModel.self) private var model
    let message: String

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(IMMColor.destructive)
                Text("Pairing failed", bundle: .module)
                    .immFont(CompanionFont.title)
                    .foregroundStyle(IMMColor.foreground)
                Text(verbatim: message)
                    .immFont(CompanionFont.body)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            Spacer()
            VStack(spacing: 10) {
                Button {
                    model.startPairing()
                } label: {
                    Text("Try again", bundle: .module)
                }
                .buttonStyle(CompanionButtonStyle(kind: .primary))
                Button {
                    model.cancelPairing()
                } label: {
                    Text("Cancel", bundle: .module)
                }
                .buttonStyle(CompanionButtonStyle(kind: .outline))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}

#Preview("Welcome") {
    CompanionRootView(model: .preview(.welcome))
}

#Preview("Locked") {
    CompanionRootView(model: .preview(.locked))
}

#Preview("Importing") {
    CompanionRootView(model: .preview(.importing))
}

#Preview("Failed") {
    CompanionRootView(model: .preview(.failed))
}

#Preview("Ready") {
    CompanionRootView(model: .preview(.ready))
}
