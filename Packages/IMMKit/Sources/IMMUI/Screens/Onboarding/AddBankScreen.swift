import IMMBanking
import IMMDesign
import SwiftUI

/// Setup step 2: "Add your first account". Only the Bank tab works; the search filters the connector's
/// directory live (name, city and bank code); Continue opens the sign-in for the chosen bank.
///
/// `Onboarding2AddBankSetup.tsx`.
public struct AddBankScreen: View {
    @Environment(AppModel.self) private var model

    @State private var query: String
    @State private var banks: [BankDirectoryEntry]
    @State private var selection: BankDirectoryEntry?
    /// Results to show instead of the first live search (screenshot tests of the designed list).
    @State private var presetBanks: [BankDirectoryEntry]?
    @FocusState private var searchFocused: Bool

    public init() {
        self.init(query: "", banks: nil, selection: nil)
    }

    /// - Parameters:
    ///   - banks: when set, shown as the first result list instead of searching `query` (tests).
    init(query: String, banks: [BankDirectoryEntry]?, selection: BankDirectoryEntry?) {
        _query = State(initialValue: query)
        _banks = State(initialValue: banks ?? [])
        _presetBanks = State(initialValue: banks)
        _selection = State(initialValue: selection)
    }

    public var body: some View {
        VStack(spacing: 0) {
            SetupTitlebar(step: String(localized: "Step 2 of 3", bundle: .module), title: String(localized: "Set up IMM", bundle: .module))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .immSlideInRight(duration: 0.28)
            footer
        }
        .background(IMMColor.background)
        .task(id: query) { await search() }
    }

    // MARK: Content

    private var content: some View {
        VStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add your first account", bundle: .module)
                    .immFont(IMMFont.titleXL.sized(24, lineHeight: 30))
                    .foregroundStyle(IMMColor.foreground)
                Text("IMM talks to your bank directly via FinTS, with no third party in between.", bundle: .module)
                    .immFont(.body)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .frame(maxWidth: 520, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 640, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                tabs
                searchField
            }
            .frame(maxWidth: 640, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                bankList
                Text("Can't find your bank? Search by BLZ or BIC.", bundle: .module)
                    .immFont(.small)
                    .foregroundStyle(IMMColor.mutedForeground)
            }
            .frame(maxWidth: 640, alignment: .leading)
        }
        .padding(.horizontal, 32)
        .padding(.top, 40)
    }

    /// Bank, Credit card, PayPal & wallets, Manual account: only Bank has a connector here.
    private var tabs: some View {
        SegmentedTabs(
            selection: .constant(Tab.bank),
            options: [
                IMMOption(Tab.bank, Text("Bank", bundle: .module)),
                IMMOption(Tab.creditCard, Text("Credit card", bundle: .module)),
                IMMOption(Tab.paypalWallets, Text("PayPal & wallets", bundle: .module)),
                IMMOption(Tab.manualAccount, Text("Manual account", bundle: .module)),
            ]
        )
        .inertControl()
    }

    private enum Tab: Hashable { case bank, creditCard, paypalWallets, manualAccount }

    private var searchField: some View {
        InputGroup(
            text: $query,
            prompt: Text("Bank name, city, BLZ or BIC", bundle: .module),
            focused: $searchFocused,
            leading: { IMMIcon("search", size: 14) },
            trailing: { countLabel }
        )
        .onSubmit {
            // Keyboard path: Return picks the first match, Return again continues with it.
            if let selection {
                model.bank.selectedBank = selection
            } else {
                selection = banks.first
            }
        }
        .initialFocus($searchFocused)
    }

    private var countLabel: Text {
        banks.count == 1
            ? Text("1 bank", bundle: .module)
            : Text("\(banks.count) banks", bundle: .module)
    }

    private var bankList: some View {
        VStack(spacing: 2) {
            if banks.isEmpty {
                Text("No bank matches your search.", bundle: .module)
                    .immFont(.body)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .frame(maxWidth: .infinity, minHeight: 48)
            } else {
                ForEach(Array(banks.enumerated()), id: \.element.id) { index, bank in
                    BankRow(bank: bank, selected: bank == selection) {
                        selection = bank
                    }
                    .immRiseIn(duration: 0.3, delay: 0.08 + 0.04 * Double(index))
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: IMMRadius.lg, style: .continuous).strokeBorder(IMMColor.border, lineWidth: 1))
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            // The database already exists at this step, so there is no earlier screen to return to.
            Button { } label: { Text("Back", bundle: .module) }
                .immButtonStyle(.ghost)
                .inertControl()
                .padding(.leading, -8)
            Spacer()
            OnboardingPrimaryButton(title: Text("Continue", bundle: .module), enabled: selection != nil) {
                model.bank.selectedBank = selection
            }
        }
        .padding(.horizontal, 160)
        .frame(height: 56)
        .overlay(alignment: .top) { Rule() }
    }

    // MARK: Search

    private func search() async {
        if let preset = presetBanks {
            presetBanks = nil
            banks = preset
            return
        }
        let found = await model.bank.searchBanks(query)
        guard !Task.isCancelled else { return }
        banks = found
        if let current = selection, !found.contains(current) { selection = nil }
    }
}

/// One directory row: name and city, formatted bank code, protocol badge and the selection check.
private struct BankRow: View {
    let bank: BankDirectoryEntry
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: bank.name)
                        .immFont(IMMFont.bodyMedium.weighted(selected ? .semibold : .medium).withLineHeight(18))
                        .lineLimit(1)
                    Text(verbatim: bank.city)
                        .immFont(.small)
                        .foregroundStyle(IMMColor.mutedForeground)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: bank.bankCode.isEmpty ? "" : "BLZ \(bank.bankCodeFormatted)")
                    .immFont(.mono)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .lineLimit(1)
                    .frame(width: 128, alignment: .leading)
                Badge(verbatim: bank.protocolLabel, variant: .outline)
                    .frame(width: 56, alignment: .leading)
                ZStack {
                    if selected {
                        IMMIcon("check", size: 16, color: IMMColor.primary)
                            .immPopIn(duration: 0.16)
                    }
                }
                .frame(width: 16)
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(BankRowStyle(selected: selected))
        .focusEffectDisabled()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct BankRowStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        BankRowBody(configuration: configuration, selected: selected)
    }
}

private struct BankRowBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool

    @Environment(\.immDisableMotion) private var disableMotion
    @State private var hovering = false

    var body: some View {
        let highlighted = selected || configuration.isPressed
        configuration.label
            .foregroundStyle(highlighted ? IMMColor.accentForeground : IMMColor.foreground)
            .background(
                RoundedRectangle(cornerRadius: IMMRadius.md, style: .continuous)
                    .fill(highlighted ? IMMColor.accent : (hovering ? IMMColor.muted : Color.clear))
            )
            .animation(disableMotion ? nil : Motion.ease(0.12), value: hovering)
            .animation(disableMotion ? nil : Motion.ease(0.12), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}
