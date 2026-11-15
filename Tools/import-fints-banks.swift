#!/usr/bin/env swift
// Converts the Deutsche Kreditwirtschaft "FinTS-Bankenliste" (fints_institute.csv) into the bundled bank directory.
//
//   swift Tools/import-fints-banks.swift <fints_institute.csv> > Packages/IMMKit/Sources/IMMFinTS/Resources/FinTSBanks.json
//
// Run from the repository root. A summary goes to stderr, the JSON to stdout, so a failed run never leaves a
// half-written file if you redirect to a temporary file first.
//
// Input: semicolon separated, one header row, Windows-1252 (UTF-8 and ISO-8859-1 are detected as well), fields may be
// quoted with "...". Columns are found by header name, ignoring case, spacing and punctuation: `BLZ`, `BIC`,
// `Institut`, `Ort`, `PIN/TAN-Zugang URL` and the first `Version` column to the right of it. `BIC` and `Version`
// are optional; the others are required.
//
// Output: a JSON array of `FinTSBankInfo` (see FinTSBankDirectory.swift), sorted by bank code, pretty-printed with
// sorted keys. Only rows with an https PIN/TAN URL and an eight-digit BLZ are kept; the first row per BLZ wins.
//
// Licensing: the CSV is distributed by the Deutsche Kreditwirtschaft to registered FinTS products only. Check its
// terms before committing it or the generated JSON; whether the data may be redistributed in this repository is the
// maintainer's decision. The script itself contains no bank data.

import Foundation

struct BankInfo: Codable {
    var bankCode: String
    var bic: String?
    var name: String
    var city: String
    var pinTanURL: URL
    var fintsVersion: String?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("import-fints-banks: \(message)\n".utf8))
    exit(1)
}

// MARK: - Decoding

/// UTF-8 when the bytes are valid UTF-8 (a Windows-1252 file with umlauts is practically never valid UTF-8),
/// otherwise Windows-1252, otherwise ISO-8859-1, which accepts every byte.
func decode(_ data: Data) -> String {
    if let text = String(data: data, encoding: .utf8) { return text }
    if let text = String(data: data, encoding: .windowsCP1252) { return text }
    return String(data: data, encoding: .isoLatin1) ?? ""
}

// MARK: - CSV

/// Splits semicolon separated text into rows of fields. Quoted fields may contain `;`, line breaks and `""` quotes.
func parseCSV(_ text: String) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var inQuotes = false
    var fieldWasQuoted = false
    var chars = Array(text.unicodeScalars)
    if chars.first == "\u{FEFF}" { chars.removeFirst() }

    func endField() {
        row.append(fieldWasQuoted ? field : field.trimmingCharacters(in: .whitespaces))
        field = ""
        fieldWasQuoted = false
    }
    func endRow() {
        endField()
        if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
        row = []
    }

    var i = 0
    while i < chars.count {
        let c = chars[i]
        if inQuotes {
            if c == "\"" {
                if i + 1 < chars.count, chars[i + 1] == "\"" {
                    field.unicodeScalars.append("\"")
                    i += 1
                } else {
                    inQuotes = false
                }
            } else {
                field.unicodeScalars.append(c)
            }
        } else {
            switch c {
            case "\"" where field.trimmingCharacters(in: .whitespaces).isEmpty:
                inQuotes = true
                fieldWasQuoted = true
                field = ""
            case ";":
                endField()
            case "\r":
                if i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                endRow()
            case "\n":
                endRow()
            default:
                field.unicodeScalars.append(c)
            }
        }
        i += 1
    }
    if !field.isEmpty || !row.isEmpty { endRow() }
    return rows
}

/// Lowercased header with everything but letters and digits removed: `PIN/TAN-Zugang URL` → `pintanzugangurl`.
func normalizeHeader(_ header: String) -> String {
    String(header.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
}

// MARK: - Conversion

struct Summary {
    var rows = 0
    var kept = 0
    var withoutHTTPS = 0
    var invalidBankCode = 0
    var duplicates = 0
}

func convert(_ rows: [[String]]) -> (banks: [BankInfo], summary: Summary) {
    guard let header = rows.first else { fail("the CSV is empty") }
    let names = header.map(normalizeHeader)

    func column(_ name: String) -> Int? { names.firstIndex(of: name) }
    func require(_ name: String, _ label: String) -> Int {
        guard let index = column(name) else {
            fail("column \(label) not found; header is: \(header.joined(separator: ";"))")
        }
        return index
    }
    let blzColumn = require("blz", "BLZ")
    let nameColumn = require("institut", "Institut")
    let cityColumn = require("ort", "Ort")
    let urlColumn = require("pintanzugangurl", "PIN/TAN-Zugang URL")
    let bicColumn = column("bic")
    let versionColumn = names.indices.first { $0 > urlColumn && names[$0] == "version" }

    func field(_ row: [String], _ index: Int?) -> String {
        guard let index, index < row.count else { return "" }
        return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var summary = Summary()
    var seen = Set<String>()
    var banks: [BankInfo] = []

    for row in rows.dropFirst() {
        summary.rows += 1
        let code = field(row, blzColumn).filter { !$0.isWhitespace }
        guard code.count == 8, code.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            summary.invalidBankCode += 1
            continue
        }
        guard let url = URL(string: field(row, urlColumn)), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
            summary.withoutHTTPS += 1
            continue
        }
        guard seen.insert(code).inserted else {
            summary.duplicates += 1
            continue
        }
        let bic = field(row, bicColumn).filter { !$0.isWhitespace }.uppercased()
        let version = field(row, versionColumn)
        banks.append(BankInfo(bankCode: code,
                              bic: bic.isEmpty ? nil : bic,
                              name: field(row, nameColumn),
                              city: field(row, cityColumn),
                              pinTanURL: url,
                              fintsVersion: version.isEmpty ? nil : version))
    }
    banks.sort { $0.bankCode < $1.bankCode }
    summary.kept = banks.count
    return (banks, summary)
}

// MARK: - Main

let arguments = CommandLine.arguments
guard arguments.count == 2, !arguments[1].hasPrefix("-") else {
    fail("usage: swift Tools/import-fints-banks.swift <fints_institute.csv> > FinTSBanks.json")
}
guard let data = FileManager.default.contents(atPath: arguments[1]) else {
    fail("cannot read \(arguments[1])")
}

let (banks, summary) = convert(parseCSV(decode(data)))

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let json = banks.isEmpty ? Data("[]".utf8) : (try encoder.encode(banks))
FileHandle.standardOutput.write(json + Data("\n".utf8))

FileHandle.standardError.write(Data("""
    import-fints-banks: \(summary.rows) rows, \(summary.kept) banks kept, \
    \(summary.withoutHTTPS) without https PIN/TAN URL, \(summary.invalidBankCode) with invalid BLZ, \
    \(summary.duplicates) duplicate BLZ skipped

    """.utf8))
