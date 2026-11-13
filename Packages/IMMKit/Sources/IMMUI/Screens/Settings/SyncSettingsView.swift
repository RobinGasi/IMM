import AppKit
import IMMDesign
import IMMSync
import SwiftUI

/// Settings › Sync: the switch, the status, the paired devices.
///
/// States (artboards "Settings — Sync …"): off; on with Tailscale not running; on and listening without devices; on with
/// devices. The pairing and confirm-code panels are drawn by `SyncPairingPanel`; while one is open the rows are hidden and
/// only the rules stay, as on the artboards. "Open Login Items…" (the helper needs approval) and the error line have no
/// artboard; they reuse the Tailscale-not-running row.
struct SyncSettingsContent: View {
    let actions: SyncSettingsActions

    @Environment(\.settingsNow) private var settingsNow

    private var sync: any SyncControlling { actions.sync }

    var body: some View {
        let panelOpen = sync.pairing != .idle
        VStack(alignment: .leading, spacing: 0) {
            switchRow.modifier(HiddenWhile(panelOpen))
            if sync.isEnabled {
                SettingsDivider()
                statusRow.modifier(HiddenWhile(panelOpen))
                if case .listening = sync.status {
                    SettingsDivider()
                    devicesRow.modifier(HiddenWhile(panelOpen))
                }
            }
        }
    }

    // MARK: Rows

    private var switchBinding: Binding<Bool> {
        Binding(
            get: { sync.isEnabled },
            set: { on in
                let actions = actions
                Task { await actions.setEnabled(on) }
            })
    }

    private var switchRow: some View {
        SettingsRow(Text("Sync:", bundle: .module), alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    IMMSwitch(isOn: switchBinding)
                    SettingsText(Text("Sync over Tailscale", bundle: .module))
                }
                Text("Sync your ledger with your other devices over Tailscale. IMM never listens on your Wi-Fi.", bundle: .module)
                    .immFont(.small)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .frame(width: sync.isEnabled ? 400 : 448, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch sync.status {
        case .listening(let host):
            SettingsRow(Text("Status:", bundle: .module)) {
                HStack(spacing: 8) {
                    IMMIcon("circle-check", size: 16, color: IMMColor.credit)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        SettingsText(Text("Listening on", bundle: .module))
                        Text(verbatim: host).immFont(.mono).foregroundStyle(IMMColor.foreground)
                    }
                }
            }
        case .noTailscale:
            warningRow(
                Text("Tailscale isn't connected on this Mac.", bundle: .module),
                detail: Text("Open Tailscale and sign in, then IMM starts listening on your tailnet.", bundle: .module))
        case .needsApproval:
            warningRow(
                Text("IMM's sync helper needs your approval.", bundle: .module),
                detail: Text("Allow IMM in System Settings › Login Items, then sync starts.", bundle: .module),
                action: (Text("Open Login Items…", bundle: .module), { actions.openLoginItems() }))
        case .error(let message):
            warningRow(Text(verbatim: message), detail: nil)
        case .off:
            // The switch is on and the service is still starting.
            SettingsRow(Text("Status:", bundle: .module)) {
                HStack(spacing: 8) {
                    IMMIcon("clock", size: 16, color: IMMColor.mutedForeground)
                    SettingsText(Text("Starting…", bundle: .module), muted: true)
                }
            }
        }
    }

    private func warningRow(_ title: Text, detail: Text?, action: (label: Text, run: () -> Void)? = nil) -> some View {
        SettingsRow(Text("Status:", bundle: .module), alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    IMMIcon("triangle-alert", size: 16, color: IMMColor.warning)
                    SettingsText(title)
                }
                if let detail {
                    detail
                        .immFont(.small)
                        .foregroundStyle(IMMColor.mutedForeground)
                        .frame(width: 400, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 24)
                }
                if let action {
                    Button(action: action.run) { action.label }
                        .immButtonStyle(.outline)
                        .padding(.leading, 24)
                        .padding(.top, 4)
                }
            }
        }
    }

    private var devicesRow: some View {
        let devices = sync.devices
        return SettingsRow(Text("Devices:", bundle: .module), alignment: .top) {
            VStack(alignment: .leading, spacing: 12) {
                if devices.isEmpty {
                    SettingsText(Text("No other devices yet.", bundle: .module), muted: true)
                } else {
                    deviceList(devices)
                }
                Button {
                    let actions = actions
                    Task { await actions.beginPairing() }
                } label: {
                    Text("Pair another device…", bundle: .module)
                }
                .immButtonStyle(.outline)
            }
        }
    }

    private func deviceList(_ devices: [SyncDeviceInfo]) -> some View {
        let shape = RoundedRectangle(cornerRadius: IMMRadius.lg, style: .continuous)
        return TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = settingsNow?() ?? context.date
            VStack(spacing: 0) {
                ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { Rule() }
                    deviceRow(device, now: now)
                }
            }
        }
        .frame(width: 448)
        .clipShape(shape)
        .overlay(shape.strokeBorder(IMMColor.border, lineWidth: 1))
    }

    private func deviceRow(_ device: SyncDeviceInfo, now: Date) -> some View {
        HStack(spacing: 12) {
            Image(systemName: SyncSettingsText.deviceSymbol(name: device.name))
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(IMMColor.mutedForeground)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: device.name)
                    .immFont(.bodyMedium)
                    .foregroundStyle(IMMColor.foreground)
                Text(verbatim: SyncSettingsText.deviceLine(device, now: now))
                    .immFont(.small)
                    .foregroundStyle(IMMColor.mutedForeground)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                let actions = actions
                Task { await actions.remove(device) }
            } label: {
                Text("Remove…", bundle: .module)
            }
            .immButtonStyle(.ghost)
            .accessibilityLabel(Text("Remove \(device.name)", bundle: .module))
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 8))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Panels

/// The in-window dialogs of the pairing: the offer (QR, code, countdown) and the code confirmation.
struct SyncPairingPanel: View {
    let actions: SyncSettingsActions

    private var sync: any SyncControlling { actions.sync }

    var body: some View {
        switch sync.pairing {
        case .idle:
            EmptyView()
        case .offering(let offer):
            SettingsPanelLayer(top: 96, width: 420) {
                OfferPanel(offer: offer, cancel: { Task { await actions.cancelPairing() } })
            }
        case .confirming(let deviceName, let code):
            SettingsPanelLayer(top: 120, width: 400) {
                ConfirmPanel(
                    deviceName: deviceName, code: code.formatted,
                    reject: { Task { await actions.rejectCodes() } },
                    confirm: { Task { await actions.confirmCodes() } })
            }
        }
    }

    /// Esc: abandons the pairing, like Cancel and "Codes don't match".
    func dismiss() async {
        switch sync.pairing {
        case .idle: break
        case .offering: await actions.cancelPairing()
        case .confirming: await actions.rejectCodes()
        }
    }
}

/// Scrim over the whole window and a 400/420-wide card under the title bar (`shadow 0 18 40 rgba(0,0,0,.16)`).
struct SettingsPanelLayer<Content: View>: View {
    let top: CGFloat
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .top) {
            IMMColor.scrim(0.18)
                .contentShape(Rectangle())
                .immFadeIn(duration: 0.2)
                .accessibilityHidden(true)
            let shape = RoundedRectangle(cornerRadius: IMMRadius.lg, style: .continuous)
            content
                .frame(width: width)
                .background(IMMColor.background)
                .clipShape(shape)
                .background(shape.fill(IMMColor.background).shadow(color: .black.opacity(0.16), radius: 20, x: 0, y: 18))
                .padding(.top, top)
                .immPopIn(duration: 0.2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct OfferPanel: View {
    let offer: PairingOffer
    let cancel: () -> Void

    @Environment(\.settingsNow) private var settingsNow

    private static let codeFont = IMMFont(
        name: "pairingCode", size: 15, lineHeight: 20, weight: .medium, family: .mono, tracking: 0.04)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pair another device", bundle: .module)
                .immFont(.titleMD)
                .foregroundStyle(IMMColor.foreground)
            QRCodeBox(offer: offer)
                .frame(maxWidth: .infinity)
            Text("Scan this code with IMM on your iPhone, or enter the pairing code on another Mac.", bundle: .module)
                .immFont(.body)
                .foregroundStyle(IMMColor.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            codeBox
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(action: cancel) { Text("Cancel", bundle: .module) }
                    .immButtonStyle(.outline)
            }
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 24)
    }

    private var codeBox: some View {
        let shape = RoundedRectangle(cornerRadius: IMMRadius.md, style: .continuous)
        return HStack(spacing: 12) {
            Text(verbatim: offer.code)
                .immFont(Self.codeFont)
                .foregroundStyle(IMMColor.foreground)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = settingsNow?() ?? context.date
                Text("Expires in \(SyncSettingsText.countdown(until: offer.expiry, now: now))", bundle: .module)
                    .immFont(.small)
                    .foregroundStyle(IMMColor.mutedForeground)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(shape.fill(IMMColor.input.opacity(0.2)))
        .overlay(shape.strokeBorder(IMMColor.input, lineWidth: 1))
    }
}

/// The QR code in a white box (10 px padding, 1 px border). It stays black on white in dark mode too: scanners expect it.
private struct QRCodeBox: View {
    static let side: CGFloat = 148
    private let image: CGImage?

    init(offer: PairingOffer) {
        // Size 1 yields one pixel per module, so the view scales it without smoothing.
        self.image = offer.qrImage(size: 1)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: IMMRadius.md, style: .continuous)
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
            } else {
                Color.clear
            }
        }
        .frame(width: Self.side, height: Self.side)
        .padding(10)
        .background(shape.fill(Color.white))
        .overlay(shape.strokeBorder(IMMColor.border, lineWidth: 1))
        .accessibilityElement()
        .accessibilityLabel(Text("Pairing QR code", bundle: .module))
    }
}

private struct ConfirmPanel: View {
    let deviceName: String?
    let code: String
    let reject: () -> Void
    let confirm: () -> Void

    private static let codeFont = IMMFont(
        name: "confirmationCode", size: 40, lineHeight: 44, weight: .medium, family: .mono, tracking: 0.06,
        tabularDigits: true)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Confirm pairing", bundle: .module)
                .immFont(.titleMD)
                .foregroundStyle(IMMColor.foreground)
            Text(verbatim: code)
                .immFont(Self.codeFont)
                .foregroundStyle(IMMColor.foreground)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .padding(.vertical, 20)
                .background(
                    RoundedRectangle(cornerRadius: IMMRadius.md, style: .continuous).fill(IMMColor.muted))
                .accessibilityLabel(Text("Confirmation code \(code)", bundle: .module))
            Group {
                if let deviceName {
                    Text("Check that \(deviceName) shows the same code.", bundle: .module)
                } else {
                    Text("Check that the other device shows the same code.", bundle: .module)
                }
            }
            .immFont(.body)
            .foregroundStyle(IMMColor.mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(action: reject) { Text("Codes don't match", bundle: .module) }
                    .immButtonStyle(.outline)
                Button(action: confirm) { Text("Codes match", bundle: .module) }
                    .immButtonStyle(.default)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 24)
    }
}
