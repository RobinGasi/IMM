import IMMDesign
import IMMLedger
import Observation
import SwiftUI

/// Holds the Suggestions' figures and follows the open ledger with a `ValueObservation`.
@MainActor @Observable
final class SuggestionsModel {
    private(set) var snapshot: SuggestionsSnapshot?

    /// Reads once, then re-reads whenever a table behind the snapshot changes. Returns when the
    /// surrounding task is cancelled or the database is closed (a lock).
    func follow(ledger: LedgerStore) async {
        if let initial = try? await ledger.database.read(SuggestionsQueries.snapshot) { snapshot = initial }
        do {
            for try await value in SuggestionsQueries.observe(in: ledger) {
                snapshot = value
            }
        } catch {
            // Locked or closed: keep the last values; the shell leaves this screen.
        }
    }
}

/// Suggestions: IMM's proposed category for every transaction without one, what else it noticed and
/// the sources behind the reasons. Accept, Change and "Accept N sure suggestions" file the booking under
/// a category through the ledger writer (the row then leaves the list); "Review one by one" and rule
/// creation are not available yet. Rows open the transaction in its account.
public struct SuggestionsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var suggestions = SuggestionsModel()

    public init() {}

    public var body: some View {
        Group {
            if let snapshot = suggestions.snapshot {
                SuggestionsLayout(snapshot: snapshot)
            } else {
                Color.clear
            }
        }
        .task(id: model.ledger.map(ObjectIdentifier.init)) {
            guard let ledger = model.ledger else { return }
            await suggestions.follow(ledger: ledger)
        }
    }
}

/// Intro bar, table, "Also noticed" and "Sources".
struct SuggestionsLayout: View {
    let snapshot: SuggestionsSnapshot

    @Environment(AppModel.self) private var model
    @Environment(\.immWindowWidth) private var windowWidth
    @State private var selected: Set<String>

    init(snapshot: SuggestionsSnapshot) {
        self.snapshot = snapshot
        _selected = State(initialValue: Set(snapshot.rows.filter(\.preselected).map(\.id)))
    }

    private var sidePadding: CGFloat { IMMLayout.contentPadding(windowWidth: windowWidth) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            introBar
            VStack(alignment: .leading, spacing: 32) {
                SuggestionsTable(
                    snapshot: snapshot, selected: $selected,
                    onAccept: { row in accept([row]) },
                    onChange: { row, categoryID in file([row.id], under: categoryID) })
                SuggestionsNoticed(notices: snapshot.notices)
                SuggestionsSources(sources: snapshot.sources)
            }
            .padding(.horizontal, sidePadding)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func accept(_ rows: [SuggestionRow]) {
        guard let writer = model.ledger?.writer else { return }
        do {
            try SuggestionsEdits.accept(rows, writer: writer)
        } catch {
            EditFailureAlert.show(error)
        }
    }

    private func file(_ ids: [String], under categoryID: String) {
        guard let writer = model.ledger?.writer else { return }
        do {
            try SuggestionsEdits.file(ids, under: categoryID, writer: writer)
        } catch {
            EditFailureAlert.show(error)
        }
    }

    private var introBar: some View {
        let intro = Text("IMM suggests a category for each. Accept what looks right; you can change it later.", bundle: .module)
            .immFont(.body)
            .foregroundStyle(IMMColor.foreground)
        let buttons = HStack(spacing: 8) {
            Button {
                accept(snapshot.rows.filter { $0.confidence == .sure })
            } label: {
                Text("Accept \(snapshot.sureCount) sure suggestions", bundle: .module)
            }
            .immButtonStyle(.default)
            .disabled(snapshot.sureCount == 0)
            Button {
            } label: {
                Text("Review one by one", bundle: .module)
            }
            .immButtonStyle(.outline)
            .inertControl()
        }
        .fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) {
                intro.frame(minWidth: 320, maxWidth: 560, alignment: .leading)
                Spacer(minLength: 0)
                buttons
            }
            VStack(alignment: .leading, spacing: 12) {
                intro
                buttons
            }
        }
        .padding(.horizontal, sidePadding)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 1)
        .overlay(alignment: .bottom) { Rule() }
    }
}

/// The ledger edits behind Accept, Change and "Accept N sure suggestions". Each filed row leaves the
/// list because the Suggestions query only lists uncategorised bookings.
enum SuggestionsEdits {
    /// Files each row under the category IMM suggested; rows whose suggestion names no known category are skipped.
    static func accept(_ rows: [SuggestionRow], writer: LedgerWriter) throws {
        var byCategory: [String: [String]] = [:]
        for row in rows {
            if let category = row.suggestedCategoryID { byCategory[category, default: []].append(row.id) }
        }
        for (category, ids) in byCategory.sorted(by: { $0.key < $1.key }) {
            try file(ids, under: category, writer: writer)
        }
    }

    static func file(_ ids: [String], under categoryID: String, writer: LedgerWriter) throws {
        try writer.setCategory(transactionIDs: ids, categoryID: categoryID)
    }
}
