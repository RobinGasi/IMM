import IMMDesign
import SwiftUI

/// The right half of Create vault: a static illustration of the ledger with the drawn sample values.
/// It never reads data; it only shows what the app looks like once a bank is connected.
struct CreateVaultPreviewPane: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            IMMColor.muted
            CreateVaultPreviewCard()
                .padding(.leading, 36)
                .padding(.top, 56)
                .immFadeIn(duration: 0.6, delay: 0.3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// The card: header, column titles, two month groups and a closing balance. It runs off the bottom
/// and right edge of the window, as drawn.
private struct CreateVaultPreviewCard: View {
    private struct Row: Identifiable {
        let id: Int
        let date: String
        let payee: String
        let category: String
        let marker: Color
        let amount: String
        var isCredit = false
    }

    private let october: [Row] = [
        Row(id: 1, date: "01.10.", payee: "Miete Wohnbau Ehrenfeld eG", category: "Housing", marker: IMMColor.chart1, amount: "−1.120,00"),
        Row(id: 2, date: "15.10.", payee: "Telekom Deutschland", category: "Insurance & contracts", marker: IMMColor.chart4, amount: "−44,95"),
        Row(id: 3, date: "24.10.", payee: "REWE Venloer Straße", category: "Groceries", marker: IMMColor.chart5, amount: "−52,16"),
        Row(id: 4, date: "27.10.", payee: "Gehalt Rheinwerk Design GmbH", category: "Income", marker: IMMColor.credit, amount: "+3.840,00", isCredit: true),
    ]

    private let november: [Row] = [
        Row(id: 5, date: "01.11.", payee: "Miete Wohnbau Ehrenfeld eG", category: "Housing", marker: IMMColor.chart1, amount: "−1.120,00"),
        Row(id: 6, date: "01.11.", payee: "KVB Deutschlandticket", category: "Mobility", marker: IMMColor.chart3, amount: "−58,00"),
    ]

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: IMMRadius.lg, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(IMMColor.border)
            shape.fill(IMMColor.card).padding(.top, 1).padding(.leading, 1)
            VStack(alignment: .leading, spacing: 0) {
                header
                columnTitles
                groupTitle("October 2026", top: 14)
                ForEach(october) { row($0) }
                closingBalance
                groupTitle("November 2026", top: 20)
                ForEach(november) { row($0) }
                Spacer(minLength: 0)
            }
            .padding(.top, 1)
            .padding(.leading, 1)
            .font(IMMFont.body.font)
            .foregroundStyle(IMMColor.foreground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipShape(shape)
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Girokonto", bundle: .module).immFont(IMMFont.titleMD.withLineHeight(22.5))
                HStack(spacing: 0) {
                    Text(verbatim: "Sparkasse KölnBonn · ").immFont(IMMFont.small.withLineHeight(20))
                    Text(verbatim: "DE80 3705 0198 1934 0827 51").immFont(IMMFont.mono.withLineHeight(20))
                }
                .foregroundStyle(IMMColor.mutedForeground)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: "2.418,36 €")
                .immFont(IMMFont.titleMD.withLineHeight(22.5).tabular)
        }
        .padding(.top, 18)
        .padding(.leading, 20)
        .padding(.trailing, 40)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) { Rule() }
    }

    private var columnTitles: some View {
        HStack(spacing: 12) {
            Text("Date", bundle: .module).frame(width: 44, alignment: .leading)
            Text("Payee", bundle: .module).frame(maxWidth: .infinity, alignment: .leading)
            Text("Amount", bundle: .module).frame(width: 84, alignment: .trailing)
        }
        .immFont(IMMFont.captionSemibold)
        .foregroundStyle(IMMColor.mutedForeground)
        .padding(.leading, 20)
        .padding(.trailing, 40)
        .frame(height: 32)
        .overlay(alignment: .bottom) { Rule() }
    }

    private func groupTitle(_ title: String, top: CGFloat) -> some View {
        Text(verbatim: title)
            .immFont(IMMFont.captionSemibold)
            .foregroundStyle(IMMColor.mutedForeground)
            .padding(.top, top)
            .padding(.bottom, 4)
            .padding(.leading, 20)
            .padding(.trailing, 40)
    }

    private func row(_ row: Row) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: row.date)
                .immFont(IMMFont.body.tabular)
                .foregroundStyle(IMMColor.mutedForeground)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: row.payee)
                    .immFont(IMMFont.body.withLineHeight(18))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(row.marker).frame(width: 8, height: 8)
                    Text(verbatim: row.category).immFont(IMMFont.small)
                }
                .foregroundStyle(IMMColor.mutedForeground)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: row.amount)
                .immFont(IMMFont.body.tabular)
                .foregroundStyle(row.isCredit ? IMMColor.credit : IMMColor.foreground)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.leading, 20)
        .padding(.trailing, 40)
        .frame(height: 46)
    }

    private var closingBalance: some View {
        VStack(spacing: 0) {
            Rule()
            HStack(spacing: 12) {
                Text("Closing balance 31.10.2026", bundle: .module)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                Text(verbatim: "3.944,79 €")
                    .immFont(IMMFont.bodySemibold.tabular)
                    .frame(width: 96, alignment: .trailing)
            }
            .immFont(IMMFont.bodySemibold)
            .frame(height: 34)
            DoubleRule()
        }
        .frame(height: 38)
        .padding(.top, 4)
        .padding(.leading, 20)
        .padding(.trailing, 40)
    }
}
