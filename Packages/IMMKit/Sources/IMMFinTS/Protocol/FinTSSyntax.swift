import Foundation

// FinTS 3.0 wire syntax ("Formals", chapter on syntax rules): a message is a sequence of segments, each terminated by
// `'`. A segment is a list of data elements separated by `+`; a data element is either a single value or a data
// element group whose components are separated by `:`. The release character `?` makes the next byte literal
// (`? + : ' @` must all be released). Binary values are written `@<length>@<bytes>`, where the length counts bytes and
// the bytes are not escaped. Text is ISO 8859-1.

/// One data element of a segment: nothing, a text value, binary data, or a group of components.
///
/// On the wire a group has at most two levels (`a:b+c`); a `.group` nested in a `.group` is written flattened into the
/// parent, and the decoder never produces one. A single-component group is written like its component and decodes as
/// that component. Use ``normalized`` to compare a hand-built element with a decoded one.
public indirect enum FinTSElement: Sendable, Hashable {
    /// An omitted element (`++`).
    case empty
    /// A text value (unescaped; the codec adds and removes release characters).
    case value(String)
    /// Raw bytes (`@<len>@<bytes>`).
    case binary(Data)
    /// A data element group, components separated by `:`.
    case group([FinTSElement])
}

/// One segment: header (`type:number:version[:reference]`) followed by data elements.
public struct FinTSSegment: Sendable, Hashable {
    /// Segment identifier such as `HNHBK`, `HKIDN`, `HIRMS`.
    public var type: String
    /// Position in the message, counted from 1. Requests use it as the target of `reference` in the answer.
    public var number: Int
    /// Segment version.
    public var version: Int
    /// *Bezugssegment*: the request segment number an answer segment belongs to (`HIRMS`, `HI…`); nil if absent.
    public var reference: Int?
    /// The data elements after the header; element 0 is the first element after `type:number:version`.
    public var elements: [FinTSElement]

    public init(type: String, number: Int = 0, version: Int, reference: Int? = nil, elements: [FinTSElement] = []) {
        self.type = type
        self.number = number
        self.version = version
        self.reference = reference
        self.elements = elements
    }
}

/// A syntax error found while decoding wire bytes.
public enum FinTSSyntaxError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The input ended inside a segment (no closing `'`) or right after a release character. `offset` is the byte
    /// index where the segment started.
    case unterminatedSegment(offset: Int)
    /// A `@…@` binary marker has no digits, a non-numeric or oversized length, announces more bytes than remain,
    /// or sits in the middle of a text value. `offset` is the byte index of the opening `@`.
    case badBinaryLength(offset: Int)
    /// The first data element is not `type:number:version[:reference]` with numeric number/version/reference.
    case badHeader(String)

    public var description: String {
        switch self {
        case .unterminatedSegment(let offset): "FinTS segment starting at byte \(offset) is not terminated"
        case .badBinaryLength(let offset): "FinTS binary value at byte \(offset) has an invalid length"
        case .badHeader(let text): "FinTS segment header is invalid: \(text)"
        }
    }
}

// MARK: - Codec

public enum FinTSSyntax {
    private static let plus = UInt8(ascii: "+")
    private static let colon = UInt8(ascii: ":")
    private static let apostrophe = UInt8(ascii: "'")
    private static let release = UInt8(ascii: "?")
    private static let at = UInt8(ascii: "@")

    // MARK: Encoding

    /// Encodes segments to wire bytes. Segment numbers are written as given. Trailing empty elements and trailing
    /// empty group components are omitted.
    ///
    /// Text is written as ISO 8859-1. Characters outside Latin-1 never fail: text is first composed (NFC); then `€` is
    /// written `EUR`, typographic quotes/dashes/ellipsis become their ASCII look-alikes, other characters lose
    /// their diacritics (`ł` → `l`), and whatever remains becomes `.`. Banks accept only a small SEPA subset of
    /// characters anyway, so a lossy but valid message beats a thrown error mid-dialog.
    public static func encode(_ segments: [FinTSSegment]) -> Data {
        var out = Data()
        for segment in segments { write(segment, into: &out) }
        return out
    }

    /// Encodes one segment; see ``encode(_:)``.
    public static func encode(_ segment: FinTSSegment) -> Data {
        var out = Data()
        write(segment, into: &out)
        return out
    }

    private static func write(_ segment: FinTSSegment, into out: inout Data) {
        writeText(segment.type, into: &out)
        out.append(colon)
        writeText(String(segment.number), into: &out)
        out.append(colon)
        writeText(String(segment.version), into: &out)
        if let reference = segment.reference {
            out.append(colon)
            writeText(String(reference), into: &out)
        }
        var count = segment.elements.count
        while count > 0, segment.elements[count - 1].isEmpty { count -= 1 }
        for element in segment.elements[..<count] {
            out.append(plus)
            write(element, into: &out)
        }
        out.append(apostrophe)
    }

    private static func write(_ element: FinTSElement, into out: inout Data) {
        switch element {
        case .empty:
            break
        case .value(let text):
            writeText(text, into: &out)
        case .binary(let data):
            out.append(at)
            out.append(contentsOf: String(data.count).utf8)
            out.append(at)
            out.append(data)
        case .group:
            let flat = element.normalized
            guard case .group(let components) = flat else {
                // Normalisation collapsed the group into a single component or nothing.
                write(flat, into: &out)
                return
            }
            for (index, component) in components.enumerated() {
                if index > 0 { out.append(colon) }
                write(component, into: &out)
            }
        }
    }

    /// Appends `text` as ISO 8859-1, releasing delimiters.
    private static func writeText(_ text: String, into out: inout Data) {
        var ascii = true
        for byte in text.utf8 where byte >= 0x80 {
            ascii = false
            break
        }
        if ascii {
            for byte in text.utf8 { writeByte(byte, into: &out) }
            return
        }
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            if scalar.value <= 0xFF {
                writeByte(UInt8(scalar.value), into: &out)
            } else {
                for byte in latin1Substitute(for: scalar).utf8 { writeByte(byte, into: &out) }
            }
        }
    }

    private static func writeByte(_ byte: UInt8, into out: inout Data) {
        switch byte {
        case plus, colon, apostrophe, release, at: out.append(release)
        default: break
        }
        out.append(byte)
    }

    /// ASCII replacement for a scalar above U+00FF.
    private static func latin1Substitute(for scalar: Unicode.Scalar) -> String {
        switch scalar {
        case "\u{20AC}": return "EUR"
        case "\u{2018}", "\u{2019}", "\u{201A}", "\u{2032}": return "'"
        case "\u{201C}", "\u{201D}", "\u{201E}", "\u{2033}": return "\""
        case "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2212}": return "-"
        case "\u{2026}": return "..."
        case "\u{0141}": return "L"
        case "\u{0142}": return "l"
        case "\u{0152}": return "OE"
        case "\u{0153}": return "oe"
        default:
            let folded = String(scalar).folding(options: .diacriticInsensitive, locale: nil)
            if !folded.isEmpty, folded.unicodeScalars.allSatisfy({ $0.value < 0x80 }) { return folded }
            return "."
        }
    }

    // MARK: Decoding

    /// Decodes wire bytes into segments. The result is normalised (see ``FinTSElement/normalized``): trailing empty
    /// elements and components are dropped, so `element(_:)` past the last sent element returns nil.
    ///
    /// Text is read as ISO 8859-1. CR and LF between segments are ignored. Empty input yields no segments.
    /// - Throws: ``FinTSSyntaxError``.
    public static func decode(_ data: Data) throws -> [FinTSSegment] {
        try data.withUnsafeBytes { buffer in
            var parser = Parser(bytes: buffer)
            return try parser.parseAll()
        }
    }

    private struct Parser {
        let bytes: UnsafeRawBufferPointer
        var position = 0

        init(bytes: UnsafeRawBufferPointer) { self.bytes = bytes }

        mutating func parseAll() throws -> [FinTSSegment] {
            var segments: [FinTSSegment] = []
            while position < bytes.count {
                let byte = bytes[position]
                if byte == 0x0A || byte == 0x0D {
                    position += 1
                    continue
                }
                segments.append(try parseSegment())
            }
            return segments
        }

        mutating func parseSegment() throws -> FinTSSegment {
            let start = position
            var elements: [FinTSElement] = []
            var components: [FinTSElement] = []
            var text: [UInt8] = []
            var binary: Data?

            func closeComponent() {
                if let data = binary {
                    components.append(.binary(data))
                    binary = nil
                } else {
                    components.append(text.isEmpty ? .empty : .value(FinTSSyntax.latin1String(text)))
                    text.removeAll(keepingCapacity: true)
                }
            }
            func closeElement() {
                closeComponent()
                elements.append(FinTSElement.group(components).normalized)
                components.removeAll(keepingCapacity: true)
            }

            while position < bytes.count {
                let byte = bytes[position]
                switch byte {
                case FinTSSyntax.release:
                    if binary != nil { throw FinTSSyntaxError.badBinaryLength(offset: position) }
                    guard position + 1 < bytes.count else { throw FinTSSyntaxError.unterminatedSegment(offset: start) }
                    text.append(bytes[position + 1])
                    position += 2
                case FinTSSyntax.at:
                    guard text.isEmpty, binary == nil else { throw FinTSSyntaxError.badBinaryLength(offset: position) }
                    binary = try readBinary()
                case FinTSSyntax.colon:
                    closeComponent()
                    position += 1
                case FinTSSyntax.plus:
                    closeElement()
                    position += 1
                case FinTSSyntax.apostrophe:
                    closeElement()
                    position += 1
                    return try makeSegment(from: elements)
                default:
                    guard binary == nil else { throw FinTSSyntaxError.badBinaryLength(offset: position) }
                    text.append(byte)
                    position += 1
                }
            }
            throw FinTSSyntaxError.unterminatedSegment(offset: start)
        }

        /// Reads `@<len>@<bytes>` at `position` (pointing at the opening `@`).
        mutating func readBinary() throws -> Data {
            let marker = position
            var cursor = position + 1
            var length = 0
            var digits = 0
            while cursor < bytes.count, bytes[cursor] >= 0x30, bytes[cursor] <= 0x39 {
                digits += 1
                guard digits <= 9 else { throw FinTSSyntaxError.badBinaryLength(offset: marker) }
                length = length * 10 + Int(bytes[cursor] - 0x30)
                cursor += 1
            }
            guard digits > 0, cursor < bytes.count, bytes[cursor] == FinTSSyntax.at else {
                throw FinTSSyntaxError.badBinaryLength(offset: marker)
            }
            cursor += 1
            guard length <= bytes.count - cursor else { throw FinTSSyntaxError.badBinaryLength(offset: marker) }
            let data = Data(bytes[cursor..<(cursor + length)])
            position = cursor + length
            return data
        }

        func makeSegment(from elements: [FinTSElement]) throws -> FinTSSegment {
            guard let header = elements.first else { throw FinTSSyntaxError.badHeader("empty segment") }
            let parts = header.components
            guard (3...4).contains(parts.count), let type = parts[0].string,
                  let number = parts[1].int, let version = parts[2].int
            else { throw FinTSSyntaxError.badHeader(describe(header)) }
            var reference: Int?
            if parts.count == 4, parts[3] != .empty {
                guard let value = parts[3].int else { throw FinTSSyntaxError.badHeader(describe(header)) }
                reference = value
            }
            var body = Array(elements.dropFirst())
            while body.last == .empty { body.removeLast() }
            return FinTSSegment(type: type, number: number, version: version, reference: reference, elements: body)
        }

        func describe(_ header: FinTSElement) -> String {
            header.components.map { $0.string ?? "" }.joined(separator: ":")
        }
    }

    private static func latin1String(_ bytes: [UInt8]) -> String {
        if bytes.allSatisfy({ $0 < 0x80 }) { return String(decoding: bytes, as: UTF8.self) }
        var scalars = String.UnicodeScalarView()
        for byte in bytes { scalars.append(Unicode.Scalar(byte)) }
        return String(scalars)
    }
}

// MARK: - Accessors

extension FinTSElement {
    /// True for `.empty`, an empty text value, and groups whose components are all empty.
    public var isEmpty: Bool {
        switch self {
        case .empty: true
        case .value(let text): text.isEmpty
        case .binary: false
        case .group(let components): components.allSatisfy(\.isEmpty)
        }
    }

    /// The wire-equivalent canonical form: empty text becomes `.empty`, nested groups are flattened, trailing empty
    /// components are removed, and a group with one component becomes that component. Decoder output is always
    /// normalised; encoding then decoding returns the normalised input.
    public var normalized: FinTSElement {
        switch self {
        case .empty: return .empty
        case .value(let text): return text.isEmpty ? .empty : self
        case .binary: return self
        case .group(let components):
            var leaves: [FinTSElement] = []
            Self.appendLeaves(of: components, to: &leaves)
            while leaves.last == .empty { leaves.removeLast() }
            switch leaves.count {
            case 0: return .empty
            case 1: return leaves[0]
            default: return .group(leaves)
            }
        }
    }

    private static func appendLeaves(of components: [FinTSElement], to leaves: inout [FinTSElement]) {
        for component in components {
            if case .group(let nested) = component {
                appendLeaves(of: nested, to: &leaves)
            } else {
                leaves.append(component.normalized)
            }
        }
    }

    /// The text of a `.value`; nil for every other case (groups included, see ``component(_:)``).
    public var string: String? {
        if case .value(let text) = self { text } else { nil }
    }

    /// The bytes of a `.binary`; nil otherwise.
    public var binaryValue: Data? {
        if case .binary(let data) = self { data } else { nil }
    }

    /// The text of a `.value` parsed as an integer; nil otherwise or when not numeric.
    public var int: Int? {
        string.flatMap { Int($0) }
    }

    /// The components of a group, or `[self]` for any other element (a single value reads as a one-component group).
    public var components: [FinTSElement] {
        if case .group(let components) = self { components } else { [self] }
    }

    /// The text of component `index` (0-based); nil when out of range, empty, or not a text value.
    public func component(_ index: Int) -> String? {
        let parts = components
        return parts.indices.contains(index) ? parts[index].string : nil
    }

    /// A text element; nil or empty text gives `.empty`.
    public static func text(_ text: String?) -> FinTSElement {
        guard let text, !text.isEmpty else { return .empty }
        return .value(text)
    }

    /// A numeric element written in decimal.
    public static func number(_ number: Int) -> FinTSElement {
        .value(String(number))
    }

    /// A group of text components; nil components are empty.
    public static func group(of components: [String?]) -> FinTSElement {
        .group(components.map { text($0) })
    }
}

extension FinTSElement: ExpressibleByStringLiteral {
    /// `""` is `.empty`.
    public init(stringLiteral value: String) {
        self = value.isEmpty ? .empty : .value(value)
    }
}

extension FinTSSegment {
    /// The data element `index` after the header (0-based); nil when the segment has fewer elements.
    public func element(_ index: Int) -> FinTSElement? {
        elements.indices.contains(index) ? elements[index] : nil
    }

    /// Text of component `component` of data element `element`; nil when missing or empty.
    public func string(_ element: Int, component: Int = 0) -> String? {
        self.element(element)?.component(component)
    }

    /// Canonical form: every element normalised and trailing empty elements removed.
    public var normalized: FinTSSegment {
        var copy = self
        copy.elements = elements.map(\.normalized)
        while copy.elements.last == .empty { copy.elements.removeLast() }
        return copy
    }
}
