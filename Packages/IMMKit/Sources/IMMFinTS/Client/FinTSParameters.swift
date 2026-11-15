import Foundation
import IMMLedger

// Bank parameter data (BPD), user parameter data (UPD) and the system id as they arrive in dialog answers.

// MARK: - TAN methods

/// One two-step TAN method from `HITANS` (version 6 or 7).
///
/// `HITANS` carries the methods as one flat data element group: three general components (one-step allowed,
/// several TAN-bound jobs per message, job hash type) followed by one block per method. The block layout is
/// (0-based): 0 security function, 1 TAN process variant, 2 technical id, 3 DK-TAN procedure id (*ZKA-Verfahren*),
/// 4 its version, 5 name, 6 max TAN input length, 7 TAN format, 8 return value text, 9 max return value length,
/// 10 several TANs allowed, 11 TAN time/dialog binding, 12 TAN list number required, 13 cancel allowed,
/// 14 SMS account required, 15 principal account required, 16 challenge class required, 17 challenge structured,
/// 18 initialisation mode, 19 TAN medium name required (0 no, 1 optional, 2 required), 20 HHD_UC response required,
/// 21 number of active media. Version 7 appends 22 maximum status requests, 23 wait before the first status
/// request, 24 wait between status requests (seconds), 25 manual confirmation allowed, 26 automated polling allowed.
struct FinTSTANMethod: Sendable, Hashable {
    /// Security function code (`HNSHK` function, for example `923`).
    var securityFunction: String
    /// TAN process variant announced by the bank: `2` means `HKTAN` process 4 is supported.
    var process: Int
    var technicalID: String
    /// DK-TAN procedure id (v7 `Decoupled` / `DecoupledPush` for app approval).
    var procedureID: String?
    var name: String
    /// Maximum length of a TAN the user types; nil or 0 when the method needs no input.
    var maxInputLength: Int?
    /// 0 not required, 1 optional, 2 required.
    var mediumRequirement: Int
    /// The user approves in a bank app; the client only polls.
    ///
    /// Rule implemented: a method is decoupled when its DK-TAN procedure id or technical id contains `decoupled`
    /// (case-insensitive; covers `Decoupled` and `DecoupledPush`), or when it uses process variant 2 and takes no
    /// TAN input (`maxInputLength` absent or 0) — the way version 6 banks announce app approval.
    var isDecoupled: Bool
    var maxStatusRequests: Int?
    var secondsBeforeFirstStatus: Int?
    var secondsBetweenStatus: Int?

    /// `HKTAN` process 4 is available for this method.
    var supportsProcess4: Bool { process == 2 }
}

/// One account from `HIUPD`.
struct FinTSUserAccount: Sendable, Hashable {
    var accountNumber: String
    var subaccount: String?
    var bankCode: String?
    var iban: String?
    var customerID: String?
    /// *Kontoart* 1…99.
    var accountType: Int?
    var currency: String?
    var ownerName: String?
    var productName: String?
    /// Segment types of the business transactions the user may send for this account (`HKSAL`, `HKKAZ`, …).
    var allowedTransactions: Set<String>
}

// MARK: - Parameters

/// Everything the client learns from the bank's answers: BPD, UPD, system id and allowed security functions.
/// ``absorb(_:)`` merges one answer; the newest data wins.
struct FinTSParameters: Sendable {
    // MARK: BPD
    var bpdVersion: Int?
    var bankName: String?
    /// Version of the `HITANS` segment the methods come from (6 or 7); nil when the bank sent none we understand.
    var tanVersion: Int?
    var tanMethods: [FinTSTANMethod] = []
    /// `HIPINS`: business segment type → a TAN is required.
    var tanRequired: [String: Bool] = [:]
    /// `HISPAS`: national account numbers allowed in `HKSPA`.
    var nationalAccountsAllowed = false
    /// Versions the bank announces per parameter segment type (`HISPAS`, `HISALS`, `HICAZS`, `HIKAZS`, `HITABS`).
    var jobVersions: [String: Set<Int>] = [:]
    /// `HICAZS`: camt format URNs the bank delivers, in the bank's order.
    var camtFormats: [String] = []
    /// `HICAZS` / `HIKAZS`: how many days back statements reach; nil when unknown.
    var camtMaxDays: Int?
    var statementMaxDays: Int?

    // MARK: UPD
    var updVersion: Int?
    var userAccounts: [FinTSUserAccount] = []

    // MARK: Dialog
    var systemID: String?
    /// Security functions from return code 3920, in the bank's order.
    var allowedSecurityFunctions: [String] = []

    /// Highest version of parameter segment `type` that is in `supported`; nil when the bank lacks the segment.
    func version(of type: String, supported: [Int]) -> Int? {
        guard let offered = jobVersions[type] else { return nil }
        return supported.filter(offered.contains).max()
    }

    /// Whether the bank lists the parameter segment at all.
    func offers(_ type: String) -> Bool {
        !(jobVersions[type] ?? []).isEmpty
    }

    func requiresTAN(for jobSegment: String) -> Bool {
        tanRequired[jobSegment] ?? false
    }

    func tanMethod(code: String) -> FinTSTANMethod? {
        tanMethods.first { $0.securityFunction == code }
    }

    /// Merges the parameter segments and return codes of one bank answer.
    mutating func absorb(_ response: FinTSResponse) {
        if !response.allowedSecurityFunctions.isEmpty {
            allowedSecurityFunctions = response.allowedSecurityFunctions
        }

        var tanSegment: FinTSSegment?
        var accounts: [FinTSUserAccount] = []
        for segment in response.segments {
            switch segment.type {
            case "HIBPA":
                bpdVersion = segment.element(0)?.int ?? bpdVersion
                bankName = segment.string(2) ?? bankName
            case "HITANS":
                guard (6...7).contains(segment.version) else { break }
                if segment.version > (tanSegment?.version ?? 0) { tanSegment = segment }
            case "HIPINS":
                for (job, required) in Self.tanRequirements(in: segment) { tanRequired[job] = required }
            case "HISPAS":
                jobVersions["HISPAS", default: []].insert(segment.version)
                nationalAccountsAllowed = segment.element(3)?.component(1) == "J"
            case "HISALS", "HITABS":
                jobVersions[segment.type, default: []].insert(segment.version)
            case "HICAZS":
                jobVersions["HICAZS", default: []].insert(segment.version)
                for urn in Self.camtURNs(in: segment) where !camtFormats.contains(urn) { camtFormats.append(urn) }
                camtMaxDays = segment.element(3)?.component(0).flatMap { Int($0) } ?? camtMaxDays
            case "HIKAZS":
                jobVersions["HIKAZS", default: []].insert(segment.version)
                statementMaxDays = segment.element(3)?.component(0).flatMap { Int($0) } ?? statementMaxDays
            case "HIUPA":
                updVersion = segment.element(1)?.int ?? updVersion
            case "HIUPD":
                accounts.append(Self.userAccount(from: segment))
            case "HISYN":
                systemID = segment.string(0) ?? systemID
            default:
                break
            }
        }
        if let tanSegment {
            tanVersion = tanSegment.version
            tanMethods = Self.tanMethods(in: tanSegment)
        }
        if !accounts.isEmpty { userAccounts = accounts }
    }

    // MARK: HITANS

    static func tanMethods(in segment: FinTSSegment) -> [FinTSTANMethod] {
        guard let group = segment.element(3) else { return [] }
        let components = group.components.map { $0.string ?? "" }
        let blockSize = segment.version >= 7 ? 27 : 22

        func isStart(_ index: Int) -> Bool {
            guard index + 2 < components.count else { return false }
            let function = components[index]
            return function.count == 3 && function.allSatisfy(\.isASCIINumber)
                && (components[index + 1] == "1" || components[index + 1] == "2") && !components[index + 2].isEmpty
        }

        var methods: [FinTSTANMethod] = []
        var index = 0
        while index < components.count {
            guard isStart(index) else {
                index += 1
                continue
            }
            // The announced layout is the first guess for the block end; when the next block does not start
            // there, scan for it so a bank with a slightly different field count still parses.
            var end = min(index + blockSize, components.count)
            if end < components.count, !isStart(end) {
                end = (index + 1..<components.count).first(where: isStart) ?? components.count
            }
            methods.append(tanMethod(from: Array(components[index..<end]), version: segment.version))
            index = end
        }
        return methods
    }

    private static func tanMethod(from block: [String], version: Int) -> FinTSTANMethod {
        func field(_ index: Int) -> String? {
            index < block.count && !block[index].isEmpty ? block[index] : nil
        }
        let process = field(1).flatMap { Int($0) } ?? 1
        let maxInput = field(6).flatMap { Int($0) }
        let procedureID = field(3)
        let technicalID = field(2) ?? ""
        let marked = [procedureID, technicalID].contains { $0?.lowercased().contains("decoupled") ?? false }
        let decoupled = marked || (process == 2 && (maxInput ?? 0) == 0)
        return FinTSTANMethod(
            securityFunction: block[0],
            process: process,
            technicalID: technicalID,
            procedureID: procedureID,
            name: field(5) ?? technicalID,
            maxInputLength: maxInput,
            mediumRequirement: field(19).flatMap { Int($0) } ?? 0,
            isDecoupled: decoupled,
            maxStatusRequests: version >= 7 ? field(22).flatMap { Int($0) } : nil,
            secondsBeforeFirstStatus: version >= 7 ? field(23).flatMap { Int($0) } : nil,
            secondsBetweenStatus: version >= 7 ? field(24).flatMap { Int($0) } : nil)
    }

    // MARK: HIPINS, HICAZS, HIUPD

    /// `HIPINS` lists `<segment type>:<J|N>` pairs after five fixed components; scanning for the pairs keeps it
    /// independent of the exact number of leading fields.
    private static func tanRequirements(in segment: FinTSSegment) -> [String: Bool] {
        guard let group = segment.element(3) else { return [:] }
        let components = group.components.map { $0.string ?? "" }
        var result: [String: Bool] = [:]
        var index = 0
        while index + 1 < components.count {
            let job = components[index]
            let flag = components[index + 1]
            if job.hasPrefix("HK"), job.count == 5, flag == "J" || flag == "N" {
                result[job] = flag == "J"
                index += 2
            } else {
                index += 1
            }
        }
        return result
    }

    private static func camtURNs(in segment: FinTSSegment) -> [String] {
        segment.elements.flatMap(\.components).compactMap(\.string).filter { $0.hasPrefix("urn:") && $0.contains("camt.") }
    }

    private static func userAccount(from segment: FinTSSegment) -> FinTSUserAccount {
        let owner = [segment.string(5), segment.string(6)].compactMap { $0 }.joined(separator: " ")
        let allowed = segment.elements.dropFirst(9).compactMap { $0.component(0) }.filter { $0.hasPrefix("HK") }
        return FinTSUserAccount(
            accountNumber: segment.string(0, component: 0) ?? "",
            subaccount: segment.string(0, component: 1),
            bankCode: segment.string(0, component: 3),
            iban: segment.string(1),
            customerID: segment.string(2),
            accountType: segment.element(3)?.int,
            currency: segment.string(4),
            ownerName: owner.isEmpty ? nil : owner,
            productName: segment.string(7),
            allowedTransactions: Set(allowed))
    }
}

extension Character {
    fileprivate var isASCIINumber: Bool { isASCII && isNumber }
}

// MARK: - Number and date formats

enum FinTSValueFormat {
    /// `1234,56` / `1234,5` / `1234,` / `1234` → minor units; nil for anything else. Exact integer math, no floating point.
    static func minorUnits(_ text: String) -> Int? {
        let parts = text.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard let whole = parts.first, !whole.isEmpty || parts.count == 2, whole.allSatisfy(\.isASCIINumber) else { return nil }
        var fraction = parts.count == 2 ? String(parts[1]) : ""
        guard fraction.count <= 2, fraction.allSatisfy(\.isASCIINumber) else { return nil }
        while fraction.count < 2 { fraction += "0" }
        guard let euros = whole.isEmpty ? 0 : Int(whole), let cents = Int(fraction) else { return nil }
        let (scaled, overflow) = euros.multipliedReportingOverflow(by: 100)
        let (total, overflow2) = scaled.addingReportingOverflow(cents)
        return overflow || overflow2 ? nil : total
    }

    /// `YYYYMMDD` → `LocalDate`; nil when not a real calendar day.
    static func date(_ text: String) -> LocalDate? {
        guard text.count == 8, text.allSatisfy(\.isASCIINumber),
              let year = Int(text.prefix(4)), let month = Int(text.dropFirst(4).prefix(2)),
              let day = Int(text.suffix(2)),
              (1...12).contains(month), day >= 1
        else { return nil }
        let candidate = LocalDate(year: year, month: month, day: day)
        return day <= candidate.daysInMonth ? candidate : nil
    }

    /// `YYYYMMDD` for the wire.
    static func wireDate(_ date: LocalDate) -> String {
        String(format: "%04ld%02ld%02ld", date.year, date.month, date.day)
    }
}
