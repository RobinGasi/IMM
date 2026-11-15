import Foundation
import IMMLedger

/// Why a camt document could not be turned into entries.
public enum CamtParserError: Error, Sendable, Equatable {
    /// The data is not well-formed XML.
    case notXML
    /// Well-formed XML, but neither a `BkToCstmrStmt` (camt.053) nor a `BkToCstmrAcctRpt` (camt.052) element.
    case notCamt
    /// An `Ntry` lacks something the entry cannot do without (`index` is zero-based, in document order).
    case invalidEntry(index: Int, reason: String)
}

/// Parses ISO 20022 account reports and statements (`camt.052.001.02/.08`, `camt.053.001.02/.08`) as German banks
/// deliver them over `HKCAZ` into `StatementEntry` values.
///
/// Elements are matched by local name only, so namespace URIs and prefixes (`<ns2:Ntry>`) do not matter. Versions
/// differ in small ways (`Sts` text vs `Sts/Cd`, `Nm` vs `Pty/Nm`, `BIC` vs `BICFI`); the parser accepts both forms.
public enum CamtParser {
    /// Parses one camt.052 or camt.053 document and returns one entry per `Ntry`, in document order.
    ///
    /// - Throws: `CamtParserError.notXML` for malformed XML, `.notCamt` when the document carries neither
    ///   `BkToCstmrStmt` nor `BkToCstmrAcctRpt`, `.invalidEntry` when an entry has no usable amount, currency or date.
    public static func parse(_ data: Data) throws -> [StatementEntry] {
        guard let root = XMLTreeBuilder.build(data) else { throw CamtParserError.notXML }
        guard let container = root.firstDescendant("BkToCstmrStmt") ?? root.firstDescendant("BkToCstmrAcctRpt") else {
            throw CamtParserError.notCamt
        }
        var entries: [StatementEntry] = []
        for (index, node) in container.descendants("Ntry").enumerated() {
            entries.append(try entry(from: node, index: index))
        }
        return entries
    }

    // MARK: - Entry

    private static func entry(from ntry: CamtElement, index: Int) throws -> StatementEntry {
        func invalid(_ reason: String) -> CamtParserError { .invalidEntry(index: index, reason: reason) }

        guard let amtNode = ntry.child("Amt"), let rawAmount = amtNode.trimmedText else { throw invalid("missing Amt") }
        guard let currency = amtNode.attributes["Ccy"], !currency.isEmpty else { throw invalid("missing Amt/@Ccy") }
        guard let magnitude = minorUnits(rawAmount, currency: currency) else { throw invalid("bad amount '\(rawAmount)'") }
        let isDebit = ntry.child("CdtDbtInd")?.trimmedText?.uppercased() == "DBIT"
        let amount = isDebit ? -magnitude : magnitude

        let booking = date(ntry.child("BookgDt"))
        let value = date(ntry.child("ValDt"))
        guard let bookingDate = booking ?? value else { throw invalid("missing BookgDt and ValDt") }
        let valueDate = value ?? bookingDate

        let isReversal = ntry.child("RvslInd")?.trimmedText.map { $0.lowercased() == "true" || $0 == "1" } ?? false
        let status = ntry.child("Sts").flatMap { $0.child("Cd")?.trimmedText ?? $0.trimmedText }
        let isPending = status?.uppercased() == "PDNG"

        let details = ntry.child("NtryDtls")?.children("TxDtls") ?? []
        let first = details.first

        // The counterparty is the other side of the booking: the debtor pays us, we pay the creditor.
        let side = isDebit ? "Cdtr" : "Dbtr"
        let parties = first?.child("RltdPties")
        let agents = first?.child("RltdAgts")

        let remittance = details.flatMap { $0.descendants("Ustrd") }.compactMap(\.singleLineText)
        let purpose: String
        if !remittance.isEmpty {
            purpose = remittance.joined(separator: " ")
        } else {
            purpose = details.lazy.compactMap { $0.child("AddtlTxInf")?.singleLineText }.first
                ?? ntry.child("AddtlTxInf")?.singleLineText ?? ""
        }

        return StatementEntry(
            bookingDate: bookingDate,
            valueDate: valueDate,
            amount: amount,
            currency: currency,
            isReversal: isReversal,
            isPending: isPending,
            counterpartyName: parties?.child(side)?.partyName,
            counterpartyIBAN: parties?.child(side + "Acct")?.path("Id", "IBAN")?.trimmedText,
            counterpartyBIC: agents?.child(side + "Agt")?.child("FinInstnId").flatMap {
                $0.child("BICFI")?.trimmedText ?? $0.child("BIC")?.trimmedText
            },
            purpose: purpose,
            bookingText: ntry.child("AddtlNtryInf")?.trimmedText,
            transactionCode: ntry.path("BkTxCd", "Prtry", "Cd")?.trimmedText.flatMap(germanTransactionCode),
            endToEndID: usable(first?.path("Refs", "EndToEndId")?.trimmedText, dropping: "NOTPROVIDED"),
            mandateID: first?.path("Refs", "MndtId")?.trimmedText,
            creditorID: creditorID(in: first),
            bankReference: usable(ntry.child("AcctSvcrRef")?.trimmedText, dropping: "NONREF")
        )
    }

    /// `Cdtr/Id` (or `Cdtr/Pty/Id`) private identification first, then a `CdtrSchmeId` anywhere in the transaction.
    private static func creditorID(in details: CamtElement?) -> String? {
        guard let details else { return nil }
        let creditor = details.child("RltdPties")?.child("Cdtr")
        let viaParty = [creditor, creditor?.child("Pty")].lazy.compactMap {
            $0?.path("Id", "PrvtId", "Othr", "Id")?.trimmedText
        }.first
        if let viaParty { return viaParty }
        return details.firstDescendant("CdtrSchmeId")?.path("Id", "PrvtId", "Othr", "Id")?.trimmedText
    }

    private static func usable(_ value: String?, dropping placeholder: String) -> String? {
        guard let value, value.uppercased() != placeholder else { return nil }
        return value
    }

    /// `NMSC+201+9310` → `201`: the second `+`-separated part when it is exactly three digits.
    private static func germanTransactionCode(_ raw: String) -> String? {
        let parts = raw.split(separator: "+", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let code = parts[1]
        guard code.count == 3, code.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return String(code)
    }

    /// `Dt` (`2026-03-02`) or `DtTm` (`2026-03-02T10:15:30+01:00`): the date part as written, no time zone shifting.
    private static func date(_ node: CamtElement?) -> LocalDate? {
        guard let node, let text = (node.child("Dt") ?? node.child("DtTm"))?.trimmedText else { return nil }
        return LocalDate(iso: String(text.prefix(10)))
    }

    // MARK: - Amounts

    /// Decimal digits after the point for currencies that deviate from ISO 4217's default of 2.
    private static let zeroExponent: Set<String> = [
        "JPY", "KRW", "VND", "CLP", "ISK", "UGX", "PYG", "XOF", "XAF", "XPF", "RWF", "KMF", "GNF", "DJF", "BIF", "VUV",
    ]
    private static let threeExponent: Set<String> = ["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"]

    static func exponent(of currency: String) -> Int {
        let code = currency.uppercased()
        if zeroExponent.contains(code) { return 0 }
        if threeExponent.contains(code) { return 3 }
        return 2
    }

    /// Converts a camt decimal (`12.5`, `1234.56`, `0.01`) to non-negative minor units without floating point.
    /// Returns nil for anything but digits with an optional single point, for fractions longer than the currency's
    /// exponent unless the surplus digits are zeros, and for values that overflow `Int`.
    static func minorUnits(_ text: String, currency: String) -> Int? {
        let exponent = exponent(of: currency)
        let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let wholePart = parts.first else { return nil }
        let fractionPart = parts.count > 1 ? parts[1] : ""
        guard !(wholePart.isEmpty && fractionPart.isEmpty) else { return nil }
        let isDigit: (UInt8) -> Bool = { $0 >= 0x30 && $0 <= 0x39 }
        guard wholePart.utf8.allSatisfy(isDigit), fractionPart.utf8.allSatisfy(isDigit) else { return nil }

        var fraction = Substring(fractionPart)
        if fraction.count > exponent {
            guard fraction.dropFirst(exponent).allSatisfy({ $0 == "0" }) else { return nil }
            fraction = fraction.prefix(exponent)
        }
        let digits = String(wholePart) + fraction + String(repeating: "0", count: exponent - fraction.count)
        return Int(digits)
    }
}

// MARK: - XML tree

/// A parsed XML element with local (prefix-free) name, attributes, text and children.
private final class CamtElement {
    let name: String
    let attributes: [String: String]
    var children: [CamtElement] = []
    var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// The element's own text without surrounding whitespace; nil when empty.
    var trimmedText: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The text with line breaks and the indentation around them collapsed into single spaces; nil when empty.
    var singleLineText: String? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let joined = lines.filter { !$0.isEmpty }.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    /// `Nm` or, in camt v08, `Pty/Nm`.
    var partyName: String? {
        child("Nm")?.trimmedText ?? path("Pty", "Nm")?.trimmedText
    }

    func child(_ name: String) -> CamtElement? { children.first { $0.name == name } }

    func children(_ name: String) -> [CamtElement] { children.filter { $0.name == name } }

    func path(_ names: String...) -> CamtElement? {
        var node: CamtElement? = self
        for name in names { node = node?.child(name) }
        return node
    }

    /// All descendants named `name` in document order; does not descend into a match.
    func descendants(_ name: String) -> [CamtElement] {
        var result: [CamtElement] = []
        for child in children {
            if child.name == name { result.append(child) } else { result += child.descendants(name) }
        }
        return result
    }

    func firstDescendant(_ name: String) -> CamtElement? {
        for child in children {
            if child.name == name { return child }
            if let found = child.firstDescendant(name) { return found }
        }
        return nil
    }
}

/// Builds an `CamtElement` tree with `XMLParser`. External entities are not resolved.
private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    private var stack: [CamtElement] = []
    private var root: CamtElement?

    static func build(_ data: Data) -> CamtElement? {
        let builder = XMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }

    private static func localName(_ qualified: String) -> String {
        guard let colon = qualified.lastIndex(of: ":") else { return qualified }
        return String(qualified[qualified.index(after: colon)...])
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let node = CamtElement(name: Self.localName(elementName), attributes: attributeDict)
        if let parent = stack.last {
            parent.children.append(node)
        } else if root == nil {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }
}
