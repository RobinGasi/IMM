import Foundation
import IMMBanking

/// One bank's FinTS PIN/TAN access as listed in the Deutsche Kreditwirtschaft institute list.
public struct FinTSBankInfo: Sendable, Hashable, Codable {
    /// Bank code (BLZ), eight digits without spaces, for example `37050198`.
    public var bankCode: String
    /// BIC of the bank's head office when the list gives one.
    public var bic: String?
    public var name: String
    public var city: String
    /// HTTPS endpoint of the bank's FinTS PIN/TAN service.
    public var pinTanURL: URL
    /// FinTS version the list states for the endpoint, for example `3.0`; `nil` when the column is empty.
    public var fintsVersion: String?

    public init(bankCode: String, bic: String? = nil, name: String, city: String, pinTanURL: URL, fintsVersion: String? = nil) {
        self.bankCode = bankCode
        self.bic = bic
        self.name = name
        self.city = city
        self.pinTanURL = pinTanURL
        self.fintsVersion = fintsVersion
    }
}

extension FinTSBankInfo {
    /// The row shown in the bank picker, labelled `FinTS`.
    public var directoryEntry: BankDirectoryEntry {
        BankDirectoryEntry(name: name, city: city, bankCode: bankCode, protocolLabel: "FinTS")
    }
}

/// Searchable list of banks that offer FinTS PIN/TAN access, loaded from `FinTSBanks.json`.
///
/// The bundled list stays empty until the product is registered with the Deutsche Kreditwirtschaft; see
/// `Tools/import-fints-banks.swift` for how it is generated.
public struct FinTSBankDirectory: Sendable {
    private struct Row: Sendable {
        var bank: FinTSBankInfo
        var foldedName: String
        var foldedCity: String
        var foldedBIC: String
    }

    /// Rows sorted by folded name, then bank code, so equal ranks come out alphabetically.
    private let rows: [Row]
    private let rowIndexByCode: [String: Int]

    /// Builds a directory with one entry per bank code (the first of duplicates wins). Spaces in codes are removed.
    public init(banks: [FinTSBankInfo]) {
        var seen = Set<String>()
        var built: [Row] = []
        built.reserveCapacity(banks.count)
        for var bank in banks {
            bank.bankCode = Self.compact(bank.bankCode)
            guard seen.insert(bank.bankCode).inserted else { continue }
            built.append(Row(bank: bank,
                             foldedName: Self.fold(bank.name),
                             foldedCity: Self.fold(bank.city),
                             foldedBIC: Self.compact(Self.fold(bank.bic ?? ""))))
        }
        built.sort { lhs, rhs in
            lhs.foldedName != rhs.foldedName ? lhs.foldedName < rhs.foldedName : lhs.bank.bankCode < rhs.bank.bankCode
        }
        rows = built
        rowIndexByCode = Dictionary(uniqueKeysWithValues: built.enumerated().map { ($1.bank.bankCode, $0) })
    }

    /// Loads `FinTSBanks.json` from the module bundle. Throws when the resource is missing or not a valid list.
    public static func bundled() throws -> FinTSBankDirectory {
        guard let url = Bundle.module.url(forResource: "FinTSBanks", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let banks = try JSONDecoder().decode([FinTSBankInfo].self, from: Data(contentsOf: url))
        return FinTSBankDirectory(banks: banks)
    }

    public var isEmpty: Bool { rows.isEmpty }

    /// The bank for a code written with or without spaces (`370 501 98`, `37050198`).
    public func bank(code: String) -> FinTSBankInfo? {
        rowIndexByCode[Self.compact(code)].map { rows[$0].bank }
    }

    /// Banks matching `query` in name, city, bank code or BIC, best match first, at most `limit`.
    ///
    /// Case, diacritics and `ß` are ignored. Rank: exact bank code or BIC; then name, bank-code or BIC prefix; then
    /// name, city or bank-code containing the text. Equal ranks are ordered by name, then bank code. An empty
    /// (or whitespace-only) query yields no results.
    public func search(_ query: String, limit: Int = 50) -> [FinTSBankInfo] {
        let needle = Self.collapseSpaces(Self.fold(query))
        guard !needle.isEmpty, limit > 0 else { return [] }
        let compactNeedle = Self.compact(needle)
        let isNumeric = compactNeedle.allSatisfy(\.isASCIIDigit)

        var ranked: [(rank: Int, index: Int)] = []
        for (index, row) in rows.enumerated() {
            let code = row.bank.bankCode
            let rank: Int?
            if (isNumeric && code == compactNeedle) || row.foldedBIC == compactNeedle {
                rank = 0
            } else if row.foldedName.hasPrefix(needle)
                        || (isNumeric && code.hasPrefix(compactNeedle))
                        || (!row.foldedBIC.isEmpty && row.foldedBIC.hasPrefix(compactNeedle)) {
                rank = 1
            } else if row.foldedName.contains(needle) || row.foldedCity.contains(needle)
                        || (isNumeric && code.contains(compactNeedle)) {
                rank = 2
            } else {
                rank = nil
            }
            if let rank { ranked.append((rank, index)) }
        }
        // `rows` is already alphabetical, so a stable sort on rank keeps the tie-break.
        ranked = stableSorted(ranked)
        return ranked.prefix(limit).map { rows[$0.index].bank }
    }

    // MARK: - Helpers

    private func stableSorted(_ items: [(rank: Int, index: Int)]) -> [(rank: Int, index: Int)] {
        items.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.index < $1.index }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
            .replacingOccurrences(of: "ß", with: "ss")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapseSpaces(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func compact(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
