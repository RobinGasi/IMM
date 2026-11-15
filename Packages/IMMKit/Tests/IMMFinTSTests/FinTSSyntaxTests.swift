import Foundation
import Testing
@testable import IMMFinTS

private func latin1(_ text: String) -> Data {
    text.data(using: .isoLatin1)!
}

private func ascii(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self)
}

@Suite struct FinTSSyntaxTests {
    // MARK: Encoding

    @Test func releasesAllDelimitersInText() {
        let segment = FinTSSegment(type: "HKTEST", number: 3, version: 1, elements: [.value("Rechnung 5?'+:@")])
        #expect(ascii(FinTSSyntax.encode(segment)) == "HKTEST:3:1+Rechnung 5???'?+?:?@'")
    }

    @Test func writesHeaderWithReference() {
        let segment = FinTSSegment(type: "HIRMS", number: 4, version: 2, reference: 3, elements: ["0020"])
        #expect(ascii(FinTSSyntax.encode(segment)) == "HIRMS:4:2:3+0020'")
    }

    @Test func omitsTrailingEmptiesButKeepsInteriorOnes() {
        let segment = FinTSSegment(type: "HKX", number: 5, version: 1, elements: [
            .value("a"),
            .group([.value("b"), .empty, .value("c"), .empty, .value("")]),
            .empty,
            .group([.empty, .empty]),
            .empty,
        ])
        #expect(ascii(FinTSSyntax.encode(segment)) == "HKX:5:1+a+b::c'")
        let interior = FinTSSegment(type: "HKX", number: 5, version: 1, elements: [.value("a"), .empty, .empty, .value("d")])
        #expect(ascii(FinTSSyntax.encode(interior)) == "HKX:5:1+a+++d'")
    }

    @Test func segmentWithoutElementsIsHeaderOnly() {
        #expect(ascii(FinTSSyntax.encode(FinTSSegment(type: "HKEND", number: 7, version: 1))) == "HKEND:7:1'")
    }

    @Test func binaryIsLengthPrefixedAndNotEscaped() {
        let payload = Data("a'b+c:d@e?f".utf8)
        let segment = FinTSSegment(type: "HNVSD", number: 999, version: 1, elements: [.binary(payload)])
        #expect(ascii(FinTSSyntax.encode(segment)) == "HNVSD:999:1+@11@a'b+c:d@e?f'")
        let empty = FinTSSegment(type: "HKB", number: 1, version: 1, elements: [.binary(Data())])
        #expect(ascii(FinTSSyntax.encode(empty)) == "HKB:1:1+@0@'")
    }

    @Test func binaryInsideGroup() {
        let segment = FinTSSegment(type: "HNVSK", number: 998, version: 3, elements: [
            .group([.value("2"), .value("2"), .value("13"), .binary(Data("00000000".utf8)), .value("5"), .value("1")]),
        ])
        #expect(ascii(FinTSSyntax.encode(segment)) == "HNVSK:998:3+2:2:13:@8@00000000:5:1'")
    }

    @Test func encodesTextAsLatin1() {
        let segment = FinTSSegment(type: "HKX", number: 1, version: 1, elements: [.value("Müller & Söhne, Straße")])
        let bytes = FinTSSyntax.encode(segment)
        #expect(bytes == latin1("HKX:1:1+Müller & Söhne, Straße'"))
        #expect(bytes.contains(0xFC))   // ü as a single byte, not UTF-8
        #expect(!bytes.contains(0xC3))
    }

    @Test func charactersOutsideLatin1AreSubstituted() {
        let segment = FinTSSegment(type: "HKX", number: 1, version: 1, elements: [
            .value("5 € “quoted” – dash Łódź 日本"),
        ])
        // ó is Latin-1 and stays a single byte; Ł and ź are folded; the CJK characters become one dot each.
        #expect(FinTSSyntax.encode(segment) == latin1("HKX:1:1+5 EUR \"quoted\" - dash Lódz ..'"))
        // A decomposed "é" (e + combining accent) is composed into the Latin-1 byte.
        let decomposed = FinTSSegment(type: "HKX", number: 1, version: 1, elements: [.value("Cafe\u{301}")])
        #expect(FinTSSyntax.encode(decomposed) == latin1("HKX:1:1+Café'"))
    }

    // MARK: Decoding

    @Test func decodesReleasedDelimiters() throws {
        let segments = try FinTSSyntax.decode(latin1("HKTEST:3:1+Rechnung 5???'?+?:?@'"))
        #expect(segments.count == 1)
        #expect(segments[0].element(0) == .value("Rechnung 5?'+:@"))
    }

    @Test func decodesLatin1Text() throws {
        let segments = try FinTSSyntax.decode(latin1("HIRMS:3:2:2+0020::Der Auftrag wurde ausgeführt.'"))
        #expect(segments[0].element(0)?.component(2) == "Der Auftrag wurde ausgeführt.")
    }

    @Test func decodesBinaryContainingDelimiters() throws {
        let payload = Data("x'+:@y?z".utf8)
        var wire = Data("HIKAZ:5:7:4+@8@".utf8)
        wire.append(payload)
        wire.append(contentsOf: "'HIRMS:6:2:4+0020::OK'".utf8)
        let segments = try FinTSSyntax.decode(wire)
        #expect(segments.map(\.type) == ["HIKAZ", "HIRMS"])
        #expect(segments[0].reference == 4)
        #expect(segments[0].element(0)?.binaryValue == payload)
        #expect(segments[1].number == 6)
    }

    @Test func binaryLengthCountsBytesNotCharacters() throws {
        // Two bytes 0xFC 0x27: an ü followed by a quote that must not end the segment.
        var wire = Data("HNVSD:999:1+@2@".utf8)
        wire.append(contentsOf: [0xFC, 0x27])
        wire.append(contentsOf: "'".utf8)
        let segments = try FinTSSyntax.decode(wire)
        #expect(segments.count == 1)
        #expect(segments[0].element(0)?.binaryValue == Data([0xFC, 0x27]))
    }

    @Test func decodesGroupsAndEmptyElements() throws {
        let segments = try FinTSSyntax.decode(latin1("HKIDN:3:2+280:12030000++0+1::+'"))
        let segment = segments[0]
        #expect(segment.element(0)?.components.count == 2)
        #expect(segment.string(0) == "280")
        #expect(segment.string(0, component: 1) == "12030000")
        #expect(segment.element(1) == .empty)
        #expect(segment.string(1) == nil)
        #expect(segment.string(2) == "0")
        #expect(segment.string(3) == "1")
        // Trailing empties (`1::` and the final `+`) are dropped on decode.
        #expect(segment.element(3) == .value("1"))
        #expect(segment.element(4) == nil)
    }

    @Test func ignoresLineBreaksBetweenSegments() throws {
        let segments = try FinTSSyntax.decode(latin1("HKA:1:1+a'\r\nHKB:2:1+b'\n"))
        #expect(segments.map(\.type) == ["HKA", "HKB"])
    }

    @Test func emptyInputHasNoSegments() throws {
        #expect(try FinTSSyntax.decode(Data()).isEmpty)
    }

    // MARK: Round trips

    @Test func roundTripsTrickyText() throws {
        let texts = [
            "plain", "?", "??", "'", "?'", "+:", "@", "?@?", "a?b'c+d:e@f", "'''", "Zeile 1\nZeile 2", "Müller?", " ", "0",
            "@5@abcde", "HKX:1:1+evil'",
        ]
        for text in texts {
            let segment = FinTSSegment(type: "HKX", number: 3, version: 2, reference: 1, elements: [
                .value(text), .group([.value(text), .value("tail")]),
            ])
            let decoded = try FinTSSyntax.decode(FinTSSyntax.encode(segment))
            #expect(decoded == [segment], "text: \(text)")
        }
    }

    @Test func roundTripsMixedSegmentListNormalised() throws {
        var allBytes = Data(0...255)
        allBytes.append(contentsOf: Data("'+:@?".utf8))
        let segments = [
            FinTSSegment(type: "HNHBK", number: 1, version: 3, elements: ["000000000100", "300", "0", "1"]),
            FinTSSegment(type: "HKX", number: 2, version: 1, reference: 7, elements: [
                .empty,
                .group([.value("a"), .empty, .binary(allBytes), .value("z")]),
                .binary(Data()),
                .group([.value("only")]),                       // normalises to .value("only")
                .group([.value("x"), .group([.value("y"), .value("")])]),   // nested group is flattened
                .value(""),                                    // normalises to .empty
                .empty,
            ]),
            FinTSSegment(type: "HKEND", number: 3, version: 1),
        ]
        let decoded = try FinTSSyntax.decode(FinTSSyntax.encode(segments))
        #expect(decoded == segments.map(\.normalized))
        #expect(decoded[1].elements == [
            .empty,
            .group([.value("a"), .empty, .binary(allBytes), .value("z")]),
            .binary(Data()),
            .value("only"),
            .group([.value("x"), .value("y")]),
        ])
        // Decoded output is a fixed point of encode/decode.
        #expect(try FinTSSyntax.decode(FinTSSyntax.encode(decoded)) == decoded)
    }

    @Test func encodingSegmentListConcatenatesSegments() {
        let a = FinTSSegment(type: "HKA", number: 1, version: 1, elements: ["a"])
        let b = FinTSSegment(type: "HKB", number: 2, version: 1)
        #expect(FinTSSyntax.encode([a, b]) == FinTSSyntax.encode(a) + FinTSSyntax.encode(b))
    }

    // MARK: Malformed input

    @Test func throwsOnUnterminatedSegment() {
        #expect(throws: FinTSSyntaxError.unterminatedSegment(offset: 0)) {
            try FinTSSyntax.decode(latin1("HKIDN:3:2+abc"))
        }
        #expect(throws: FinTSSyntaxError.unterminatedSegment(offset: 8)) {
            try FinTSSyntax.decode(latin1("HKA:1:1'HKB:2:1+b"))
        }
        // A trailing release character has nothing to release.
        #expect(throws: FinTSSyntaxError.unterminatedSegment(offset: 0)) {
            try FinTSSyntax.decode(latin1("HKIDN:3:2+abc?"))
        }
        // The terminator is released, so the segment never ends.
        #expect(throws: FinTSSyntaxError.unterminatedSegment(offset: 0)) {
            try FinTSSyntax.decode(latin1("HKIDN:3:2+abc?'"))
        }
    }

    @Test func throwsOnBadBinaryLength() {
        for wire in ["HKX:1:1+@x@ab'", "HKX:1:1+@@'", "HKX:1:1+@5@ab'", "HKX:1:1+@2'", "HKX:1:1+@99999999999@a'",
                     "HKX:1:1+ab@2@cd'", "HKX:1:1+@2@ab@2@cd'", "HKX:1:1+@2@ab?c'", "HKX:1:1+@2@abc'"] {
            #expect(throws: FinTSSyntaxError.self, "\(wire)") { try FinTSSyntax.decode(latin1(wire)) }
        }
        #expect(throws: FinTSSyntaxError.badBinaryLength(offset: 8)) {
            try FinTSSyntax.decode(latin1("HKX:1:1+@5@ab'"))
        }
    }

    @Test func throwsOnBadHeader() {
        for wire in ["'", "HKIDN'", "HKIDN+1'", "HKIDN:1'", "HKIDN:a:2'", "HKIDN:1:b'", ":1:2'", "HKIDN:1:2:x'",
                     "HKIDN:1:2:3:4'", "HKIDN:1:2+x'HKIDN:1'"] {
            #expect(throws: FinTSSyntaxError.self, "\(wire)") { try FinTSSyntax.decode(latin1(wire)) }
        }
        #expect(throws: FinTSSyntaxError.badHeader("HKIDN:a:2")) {
            try FinTSSyntax.decode(latin1("HKIDN:a:2'"))
        }
    }

    // MARK: Accessors

    @Test func accessorsOnElements() {
        let group = FinTSElement.group([.value("280"), .empty, .value("12030000")])
        #expect(group.components.count == 3)
        #expect(group.component(0) == "280")
        #expect(group.component(1) == nil)
        #expect(group.component(2) == "12030000")
        #expect(group.component(3) == nil)
        #expect(group.string == nil)
        let single = FinTSElement.value("42")
        #expect(single.components == [single])
        #expect(single.component(0) == "42")
        #expect(single.component(1) == nil)
        #expect(single.int == 42)
        #expect(FinTSElement.value("x").int == nil)
        #expect(FinTSElement.binary(Data([1])).binaryValue == Data([1]))
        #expect(single.binaryValue == nil)
        #expect(FinTSElement.text(nil) == .empty)
        #expect(FinTSElement.text("") == .empty)
        #expect(FinTSElement.group(of: ["a", nil, "c"]) == .group([.value("a"), .empty, .value("c")]))
    }

    @Test func accessorsOnSegments() {
        let segment = FinTSSegment(type: "HKX", number: 1, version: 1, elements: ["a", .group(of: ["b", "c"])])
        #expect(segment.element(0) == .value("a"))
        #expect(segment.element(2) == nil)
        #expect(segment.element(-1) == nil)
        #expect(segment.string(1, component: 1) == "c")
        #expect(segment.string(5) == nil)
    }
}
