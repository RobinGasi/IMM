import SwiftUI

/// Maps a route to its screen. Each screen has a no-argument `init()` and reads `AppModel` itself.
struct RouteView: View {
    let route: MainRoute

    var body: some View {
        switch route {
        case .overview: OverviewScreen()
        case .transactions: TransactionsScreen()
        case .suggestions: SuggestionsScreen()
        case .monthReview: MonthReviewScreen()
        case .depot: DepotScreen()
        case .budgets: BudgetsScreen()
        case .standingOrders: StandingOrdersScreen()
        case .contracts: ContractsScreen()
        case .categories: CategoriesScreen()
        case .taxReturn: TaxReturnScreen()
        case .payInvoice: PayInvoiceScreen()
        }
    }
}
