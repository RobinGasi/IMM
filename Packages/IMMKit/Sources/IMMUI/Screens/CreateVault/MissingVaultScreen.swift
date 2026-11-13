import IMMDesign
import SwiftUI

/// "<name> can't be found": the remembered database is gone. Locate it or create a new one.
public struct MissingVaultScreen: View {
    @Environment(AppModel.self) private var model

    public init() {}

    private var url: URL? {
        if case .missingVault(let url) = model.phase { return url }
        return nil
    }

    public var body: some View {
        VStack(spacing: 0) {
            SetupTitlebar(
                step: String(localized: "Locked", bundle: .module),
                title: "Ich mag Moneten")
            VStack(spacing: 0) {
                IMMLogoMark(width: 60, animated: true)
                Text("\(url?.lastPathComponent ?? "Moneten.imm") can't be found", bundle: .module)
                    .immFont(IMMFont(name: "missingVaultTitle", size: 22, lineHeight: 28, weight: .semibold))
                    .lineLimit(1)
                    .padding(.top, 20)
                VStack(spacing: 0) {
                    Text("IMM looked for it in", bundle: .module).immFont(.body)
                    Text(verbatim: url?.path ?? "")
                        .immFont(IMMFont.mono.withLineHeight(20))
                        .foregroundStyle(IMMColor.foreground)
                    Text("It may have been moved, renamed or deleted.", bundle: .module).immFont(.body)
                }
                .foregroundStyle(IMMColor.mutedForeground)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                HStack(spacing: 8) {
                    Button { model.showCreateVault() } label: {
                        Text("Create new database", bundle: .module)
                    }
                    .immButtonStyle(.outline)
                    Button { model.chooseDatabase() } label: {
                        Text("Locate…", bundle: .module)
                    }
                    .immButtonStyle(.default)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
        }
        .background(IMMColor.background)
        .foregroundStyle(IMMColor.foreground)
    }
}
