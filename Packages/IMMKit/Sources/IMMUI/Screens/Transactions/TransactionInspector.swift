import IMMDesign
import IMMLedger
import SwiftUI

/// The inspector beside the list: payee and amount, the facts of the booking, category, notes,
/// split and receipt actions and the "always file under" rule. Category, notes and the rule checkbox edit
/// the ledger through the callbacks; Split and Attach have no design behind them yet and stay inert.
struct TransactionInspector: View {
    let item: TransactionItem
    let category: TransactionCategory?
    let categories: [TransactionCategory]
    let rule: TransactionRuleInfo?
    let windowWidth: CGFloat
    let onClose: () -> Void
    /// Files the transaction under a category (nil = without category).
    let onCategory: (String?) -> Void
    /// Stores the note (nil = no note).
    let onNote: (String?) -> Void
    /// Turns the "always file under" rule on or off.
    let onRule: (Bool) -> Void

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                header
                facts
                editing
                if let category, let rule {
                    ruleRow(category: category, rule: rule)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(IMMColor.windowChrome)
        .overlay(alignment: .leading) { VerticalRule(height: 100_000) }
        .clipped()
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(verbatim: item.counterpartyName.isEmpty ? item.payee : item.counterpartyName)
                    .immFont(.titleMD)
                    .foregroundStyle(IMMColor.foreground)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onClose) {
                    IMMIcon("x", size: IMMButtonStyle.Size.iconSm.iconSize)
                }
                .immButtonStyle(.ghost, size: .iconSm)
                .accessibilityLabel(Text("Close inspector", bundle: .module))
            }
            .frame(height: 28)
            Text(verbatim: MoneyFormatter.string(item.amount, currency: item.currency))
                .immFont(IMMFont.amountHero.sized(IMMLayout.heroFontSize(windowWidth: windowWidth)))
                .foregroundStyle(IMMColor.foreground)
                .lineLimit(1)
            Text(verbatim: TransactionText.detailSubtitle(item))
                .immFont(IMMFont.small.withLineHeight(18))
                .foregroundStyle(IMMColor.mutedForeground)
                .lineLimit(1)
        }
        .padding(EdgeInsets(top: 16, leading: 20, bottom: 20, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rule() }
    }

    // MARK: Facts

    private var facts: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let text = item.bookingText, !text.isEmpty {
                fact(Text("Booking text", bundle: .module)) { plain(text) }
            }
            if let purpose = item.purpose, !purpose.isEmpty {
                fact(Text("Purpose", bundle: .module)) { mono(purpose) }
            }
            if let creditor = item.creditorID, !creditor.isEmpty {
                fact(Text("Creditor ID", bundle: .module)) { mono(creditor, lineHeight: 18) }
            }
            fact(Text("Booked", bundle: .module)) {
                Text(verbatim: DateFormats.dayMonthYear(item.bookingDate))
                    .immFont(IMMFont.small.withLineHeight(18).tabular)
                    .foregroundStyle(IMMColor.foreground)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rule() }
    }

    private func fact<Value: View>(_ label: Text, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .top, spacing: 12) {
            label
                .immFont(IMMFont.small.withLineHeight(18))
                .foregroundStyle(IMMColor.mutedForeground)
                .frame(width: 96, alignment: .leading)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func plain(_ text: String) -> some View {
        Text(verbatim: text)
            .immFont(IMMFont.small.withLineHeight(18))
            .foregroundStyle(IMMColor.foreground)
    }

    private func mono(_ text: String, lineHeight: CGFloat = 18) -> some View {
        Text(verbatim: text)
            .immFont(IMMFont.mono.withLineHeight(lineHeight))
            .foregroundStyle(IMMColor.foreground)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Category, notes, actions

    private var editing: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel(Text("Category", bundle: .module))
                categoryMenu
            }
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel(Text("Notes", bundle: .module))
                InspectorNoteField(note: item.note, onCommit: onNote)
                    .id(item.id)
            }
            HStack(spacing: 8) {
                actionButton(icon: "split", title: Text("Split transaction", bundle: .module))
                actionButton(icon: "attach", title: Text("Attach receipt", bundle: .module))
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionLabel(_ text: Text) -> some View {
        text
            .immFont(.captionSemibold)
            .foregroundStyle(IMMColor.mutedForeground)
    }

    /// The select trigger with the category's dot opening a standard menu of the categories and
    /// "Without category"; the current choice is checked.
    private var categoryMenu: some View {
        Menu {
            Picker(selection: Binding<String?>(get: { item.categoryID }, set: { onCategory($0) })) {
                ForEach(categories) { option in
                    Text(verbatim: option.name).tag(Optional(option.id))
                }
                Text("Without category", bundle: .module).tag(String?.none)
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            categoryField
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .focusEffectDisabled()
        .accessibilityLabel(Text("Category", bundle: .module))
    }

    /// The select trigger look with the category's dot.
    private var categoryField: some View {
        HStack(spacing: 6) {
            if let category {
                LegendDot(IMMColor.named(category.colorToken))
                Text(verbatim: category.name)
                    .immFont(.controlRegular)
                    .foregroundStyle(IMMColor.foreground)
                    .lineLimit(1)
            } else {
                Text("Without category", bundle: .module)
                    .immFont(.controlRegular)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            IMMIcon("chevron-down", size: 14, color: IMMColor.mutedForeground)
        }
        .modifier(InspectorFieldChrome(height: 28, verticalPadding: 0))
    }

    private func actionButton(icon: String, title: Text) -> some View {
        Button {} label: {
            HStack(spacing: 4) {
                IMMIcon(icon, size: IMMButtonStyle.Size.default.iconSize)
                title
            }
        }
        .immButtonStyle(.outline, leadingIcon: true)
        .inertControl()
    }

    // MARK: Rule

    private func ruleRow(category: TransactionCategory, rule: TransactionRuleInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            IMMCheckbox(isOn: Binding(get: { rule.ruleExists }, set: { onRule($0) }))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Always file \(item.payee) under \(category.name)", bundle: .module)
                    .immFont(IMMFont.bodyMedium.withLineHeight(18))
                    .foregroundStyle(IMMColor.foreground)
                    .lineLimit(2)
                Text(verbatim: Self.earlierText(rule.earlierCount))
                    .immFont(.small)
                    .foregroundStyle(IMMColor.mutedForeground)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .contentShape(Rectangle())
        .onTapGesture { onRule(!rule.ruleExists) }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .overlay(alignment: .top) { Rule().padding(.horizontal, 20) }
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    static func earlierText(_ count: Int) -> String {
        switch count {
        case 0: return String(localized: "No earlier transactions", bundle: .module)
        case 1: return String(localized: "Applies to 1 earlier transaction", bundle: .module)
        default: return String(localized: "Applies to \(count) earlier transactions", bundle: .module)
        }
    }
}

/// Border, fill and padding of the inspector's select and textarea look-alikes.
private struct InspectorFieldChrome: ViewModifier {
    let height: CGFloat?
    let verticalPadding: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: IMMRadius.md, style: .continuous)
        content
            .padding(.horizontal, 8)
            .padding(.vertical, verticalPadding)
            .frame(height: height)
            .frame(minHeight: height == nil ? 64 : nil, alignment: .topLeading)
            .background(shape.fill(IMMColor.inputFill))
            .overlay(shape.strokeBorder(IMMColor.input, lineWidth: 1))
    }
}

/// The notes textarea: shows the stored note, edits a draft, stores it on Return or when focus leaves
/// (also when the inspector moves to another transaction); Esc puts the stored note back.
private struct InspectorNoteField: View {
    let note: String?
    let onCommit: (String?) -> Void

    @State private var draft: String
    @FocusState private var focused: Bool

    init(note: String?, onCommit: @escaping (String?) -> Void) {
        self.note = note
        self.onCommit = onCommit
        _draft = State(initialValue: note ?? "")
    }

    var body: some View {
        TextField(text: $draft, prompt: Text("Add a note", bundle: .module).foregroundStyle(IMMColor.mutedForeground), axis: .vertical) {
            EmptyView()
        }
        .textFieldStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .immFont(.controlRegular)
        .foregroundStyle(IMMColor.foreground)
        .tint(IMMColor.primary)
        .lineLimit(1...8)
        .accessibilityLabel(Text("Notes", bundle: .module))
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
        .modifier(InspectorFieldChrome(height: nil, verticalPadding: 8))
        .onSubmit { commit() }
        .onExitCommand { revert() }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
        .onChange(of: note) { _, stored in
            if !focused { draft = stored ?? "" }
        }
        .onDisappear { commit() }
    }

    private func commit() {
        let stored = note ?? ""
        guard draft != stored else { return }
        onCommit(draft.isEmpty ? nil : draft)
    }

    private func revert() {
        draft = note ?? ""
        focused = false
    }
}
