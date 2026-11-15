import IMMDesign
import IMMLedger
import IMMSyncCore
import SwiftUI

/// Text styles of the companion: the Mac design system's family, sized for a phone.
enum CompanionFont {
    /// 36/44, 600, tabular (net worth).
    static let hero = IMMFont(
        name: "phoneHero", size: 36, lineHeight: 44, weight: .semibold, tracking: -0.02, tabularDigits: true)
    /// 22/28, 600.
    static let title = IMMFont.titleXL
    /// 17/22, 600 (bar titles, buttons, row titles).
    static let headline = IMMFont(name: "phoneHeadline", size: 17, lineHeight: 22, weight: .semibold)
    /// 17/24, 400.
    static let body = IMMFont(name: "phoneBody", size: 17, lineHeight: 24)
    /// 15/20, 400.
    static let callout = IMMFont(name: "phoneCallout", size: 15, lineHeight: 20)
    /// 15/20, 500.
    static let calloutMedium = IMMFont(name: "phoneCalloutMedium", size: 15, lineHeight: 20, weight: .medium)
    /// 15/20, 500, tabular (amounts in rows).
    static let amount = IMMFont(
        name: "phoneAmount", size: 15, lineHeight: 20, weight: .medium, tabularDigits: true)
    /// 13/18, 400.
    static let footnote = IMMFont(name: "phoneFootnote", size: 13, lineHeight: 18)
    /// 13/18, 600 (section labels).
    static let footnoteSemibold = IMMFont(name: "phoneFootnoteSemibold", size: 13, lineHeight: 18, weight: .semibold)
    /// 11/14, 500 (badges).
    static let badge = IMMFont(name: "phoneBadge", size: 11, lineHeight: 14, weight: .medium)
    /// Geist Mono 52/60 (pairing code).
    static let code = IMMFont(name: "phoneCode", size: 52, lineHeight: 60, family: .mono)
    /// Geist Mono 14/20 (IBAN).
    static let mono = IMMFont(name: "phoneMono", size: 14, lineHeight: 20, family: .mono)
}

/// Colours the screens need beyond the plain tokens.
enum CompanionColor {
    /// The dark surface of the camera panel; the same in light and dark appearance.
    static let scannerSurface: Color = {
        guard let c = IMMColor.resolved("card", dark: true) else { return .black }
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }()

    /// Amount colour: income in `credit`, everything else in the primary text colour.
    static func amount(_ minorUnits: Int) -> Color {
        minorUnits > 0 ? IMMColor.credit : IMMColor.foreground
    }
}

/// Formatting shared by the screens (German numbers, English month names, like the Mac).
enum CompanionFormat {
    static func money(_ minorUnits: Int, currency: String = "EUR", sign: MoneyFormatter.Sign = .negativeOnly) -> String {
        MoneyFormatter.string(minorUnits, currency: currency, sign: sign)
    }

    /// `Today`, `Yesterday`, else `Thu, 12.11.2026`.
    static func dayTitle(_ date: LocalDate, today: LocalDate = LocalDate(Date())) -> String {
        switch today - date {
        case 0: return String(localized: "Today", bundle: .module)
        case 1: return String(localized: "Yesterday", bundle: .module)
        default: return DateFormats.weekdayShort(date) + ", " + DateFormats.dayMonthYear(date)
        }
    }

    /// `3 minutes ago`.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// SF Symbol of an `AccountKind` raw value.
    static func symbol(forAccountKind kind: String) -> String {
        switch kind {
        case "savings": return "banknote"
        case "credit_card": return "creditcard"
        case "depot": return "chart.line.uptrend.xyaxis"
        case "wallet": return "wallet.pass"
        default: return "building.columns"
        }
    }
}

extension CompanionSyncStatus {
    /// First line of the status.
    var title: String {
        switch self {
        case .idle: return String(localized: "Not synced yet", bundle: .module)
        case .syncing: return String(localized: "Syncing…", bundle: .module)
        case .synced(let at): return String(localized: "Synced \(CompanionFormat.relative(at))", bundle: .module)
        case .macLocked: return String(localized: "IMM is locked on your Mac", bundle: .module)
        case .unreachable: return String(localized: "Can't reach your Mac", bundle: .module)
        case .failed: return String(localized: "Sync failed", bundle: .module)
        }
    }

    /// Explanation under the title, nil when there is nothing to add.
    var detail: String? {
        switch self {
        case .idle, .syncing, .synced: return nil
        case .macLocked(let at):
            return String(
                localized: "Unlock IMM on your Mac to update. Showing data from before \(CompanionFormat.relative(at)).",
                bundle: .module)
        case .unreachable(let message):
            let hint = String(localized: "Check that Tailscale is on and your Mac is awake.", bundle: .module)
            return message.isEmpty ? hint : hint + " " + message
        case .failed(let message): return message.isEmpty ? nil : message
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "arrow.triangle.2.circlepath"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .synced: return "checkmark.circle"
        case .macLocked: return "lock"
        case .unreachable: return "wifi.slash"
        case .failed: return "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .idle, .syncing: return IMMColor.mutedForeground
        case .synced: return IMMColor.credit
        case .macLocked, .unreachable: return IMMColor.warning
        case .failed: return IMMColor.destructive
        }
    }

    /// True when the data on the phone may be out of date and the user should know.
    var needsAttention: Bool {
        switch self {
        case .macLocked, .unreachable, .failed: return true
        case .idle, .syncing, .synced: return false
        }
    }
}

/// Full-width phone button: primary, outline or destructive, 50 pt tall.
struct CompanionButtonStyle: ButtonStyle {
    enum Kind { case primary, outline, destructive }

    var kind: Kind = .primary

    func makeBody(configuration: Configuration) -> some View {
        CompanionButtonBody(configuration: configuration, kind: kind)
    }
}

private struct CompanionButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: CompanionButtonStyle.Kind
    @Environment(\.isEnabled) private var isEnabled

    private var foreground: Color {
        switch kind {
        case .primary: return IMMColor.primaryForeground
        case .outline: return IMMColor.foreground
        case .destructive: return IMMColor.destructive
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: return configuration.isPressed ? IMMColor.primaryHover : IMMColor.primary
        case .outline: return configuration.isPressed ? IMMColor.outlineButtonHover : IMMColor.outlineButtonFill
        case .destructive: return configuration.isPressed ? IMMColor.destructiveFillHover : IMMColor.destructiveFill
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: IMMRadius.md, style: .continuous)
        configuration.label
            .immFont(CompanionFont.headline)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(kind == .outline ? IMMColor.border : Color.clear, lineWidth: 1))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.5)
    }
}

extension View {
    /// Inline navigation bar title on iOS; unchanged elsewhere.
    func companionInlineTitle() -> some View {
        #if os(iOS)
        return navigationBarTitleDisplayMode(.inline)
        #else
        return self
        #endif
    }

    /// Grouped list on the design background with `muted` rows.
    func companionGroupedList() -> some View {
        #if os(iOS)
        return self
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(IMMColor.background)
        #else
        return self
            .scrollContentBackground(.hidden)
            .background(IMMColor.background)
        #endif
    }

    /// Plain list on the design background.
    func companionPlainList() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(IMMColor.background)
    }
}

/// One status line: symbol, title and optional detail. Used in Overview and Settings.
struct SyncStatusLine: View {
    let status: CompanionSyncStatus

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if status == .syncing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: status.symbol).foregroundStyle(status.tint)
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: status.title)
                    .immFont(CompanionFont.calloutMedium)
                    .foregroundStyle(IMMColor.foreground)
                if let detail = status.detail {
                    Text(verbatim: detail)
                        .immFont(CompanionFont.footnote)
                        .foregroundStyle(IMMColor.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A transaction row: counterparty, category and pending marker, signed amount.
struct TransactionRow: View {
    let transaction: CompanionTransaction

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: transaction.counterparty.isEmpty ? "—" : transaction.counterparty)
                    .immFont(CompanionFont.calloutMedium)
                    .foregroundStyle(IMMColor.foreground)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    CategoryMarker(name: transaction.categoryName, colorToken: transaction.categoryColorToken)
                    if transaction.isPending {
                        PendingBadge()
                    }
                }
            }
            Spacer(minLength: 8)
            Text(verbatim: CompanionFormat.money(transaction.amount, currency: transaction.currency, sign: .always))
                .immFont(CompanionFont.amount)
                .foregroundStyle(CompanionColor.amount(transaction.amount))
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Coloured dot and category name, or "Uncategorised" in muted text.
struct CategoryMarker: View {
    let name: String?
    let colorToken: String?

    var body: some View {
        HStack(spacing: 6) {
            if let name {
                Circle()
                    .fill(IMMColor.named(colorToken ?? "muted-foreground"))
                    .frame(width: 8, height: 8)
                Text(verbatim: name)
            } else {
                Text("Uncategorised", bundle: .module)
            }
        }
        .immFont(CompanionFont.footnote)
        .foregroundStyle(IMMColor.mutedForeground)
        .lineLimit(1)
    }
}

struct PendingBadge: View {
    var body: some View {
        Text("Pending", bundle: .module)
            .immFont(CompanionFont.badge)
            .foregroundStyle(IMMColor.warning)
            .padding(.horizontal, 6)
            .overlay(Capsule().strokeBorder(IMMColor.warning.opacity(0.6), lineWidth: 1))
    }
}
