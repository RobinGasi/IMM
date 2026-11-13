import IMMDesign
import IMMLedger
import SwiftUI

/// "Coming up": expected Girokonto bookings until the first of next month and the projected balance.
struct OverviewComingUpSection: View {
    let snapshot: OverviewSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(
                Text("Coming up", bundle: .module),
                detail: Text("\(snapshot.upcomingAccountName), until \(DateFormats.dayMonth(snapshot.upcomingUntil))", bundle: .module))
            VStack(spacing: 0) {
                ForEach(Array(snapshot.upcoming.enumerated()), id: \.element.id) { index, item in
                    row(item, isLast: index == snapshot.upcoming.count - 1)
                }
                TotalRow(
                    Text("\(snapshot.upcomingAccountName) on \(DateFormats.dayMonth(snapshot.upcomingUntil))", bundle: .module),
                    amount: MoneyFormatter.string(snapshot.projectedBalance), amountWidth: 88)
            }
            .padding(.top, 8)
        }
    }

    private func row(_ item: OverviewUpcoming, isLast: Bool) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: DateFormats.dayMonth(item.date))
                .immFont(IMMFont.small.tabular)
                .foregroundStyle(IMMColor.mutedForeground)
                .frame(width: 44, alignment: .leading)
            Text(verbatim: item.label)
                .immFont(.body)
                .foregroundStyle(IMMColor.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            OverviewAmount(
                text: MoneyFormatter.string(item.amount, sign: .always), width: 88,
                color: item.amount > 0 ? IMMColor.credit : IMMColor.foreground)
        }
        .frame(height: 40)
        .overviewRowRule(!isLast)
        .overviewHoverSurface()
    }
}
