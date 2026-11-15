import IMMDesign
import IMMSyncCore
import SwiftUI

/// Pairing step 2: compare the six-digit code with the one on the Mac.
///
/// Follows `DesignReference/screens/iphone-pair-confirm@1x.png`. While the Mac confirms (`isWaitingForMac`)
/// the card shows a progress line and the buttons are disabled.
struct PairConfirmView: View {
    @Environment(CompanionModel.self) private var model
    let code: ShortAuthCode?
    let macName: String
    let isWaitingForMac: Bool

    var body: some View {
        VStack(spacing: 0) {
            PairTitleBar(title: Text("Confirm pairing", bundle: .module), cancelsPairing: false)
            Spacer()
            VStack(spacing: 16) {
                card
                Text(verbatim: String(localized: "Check that \(macName) shows the same code.", bundle: .module))
                    .immFont(CompanionFont.body)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            .padding(.horizontal, 24)
            Spacer()
            Spacer().frame(maxHeight: 60)
            VStack(spacing: 12) {
                Button {
                    model.confirmCodesMatch()
                } label: {
                    Text("Codes match", bundle: .module)
                }
                .buttonStyle(CompanionButtonStyle(kind: .primary))
                Button {
                    model.rejectCodes()
                } label: {
                    Text("Codes don't match", bundle: .module)
                }
                .buttonStyle(CompanionButtonStyle(kind: .outline))
            }
            .disabled(isWaitingForMac)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(IMMColor.muted)
            .frame(height: 124)
            .overlay {
                if isWaitingForMac {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.regular)
                        Text("Confirm on your Mac…", bundle: .module)
                            .immFont(CompanionFont.headline)
                            .foregroundStyle(IMMColor.foreground)
                    }
                } else if let code {
                    Text(verbatim: code.formatted)
                        .immFont(CompanionFont.code)
                        .foregroundStyle(IMMColor.foreground)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .accessibilityLabel(Text(verbatim: code.digits.map(String.init).joined(separator: " ")))
                }
            }
    }
}

#Preview("Confirm") {
    CompanionRootView(model: .preview(.confirm))
}

#Preview("Waiting for Mac") {
    CompanionRootView(model: .preview(.waitingForMac))
}
