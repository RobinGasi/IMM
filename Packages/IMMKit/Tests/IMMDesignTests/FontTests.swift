import AppKit
import SwiftUI
import Testing

@testable import IMMDesign

@Suite struct FontTests {
    @Test func bundledFilesAreFound() {
        let names = IMMFonts.fileURLs.map { $0.lastPathComponent }.sorted()
        #expect(names == ["Geist-Medium.otf", "Geist-Regular.otf", "Geist-SemiBold.otf", "GeistMono-Regular.otf"])
    }

    @Test func everyPostScriptNameResolvesAfterRegistration() {
        IMMFonts.registerIfNeeded()
        IMMFonts.registerIfNeeded()
        for name in IMMFonts.postScriptNames {
            #expect(IMMFonts.isAvailable(postScriptName: name), "\(name)")
        }
    }

    @Test func everyStyleUsesARegisteredFace() {
        for style in IMMFont.allStyles {
            #expect(IMMFonts.postScriptNames.contains(style.postScriptName), "\(style.name)")
            #expect(style.nsFont != nil, "\(style.name)")
            #expect(style.lineHeight > 0)
        }
        let names = IMMFont.allStyles.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test func inventoryValues() {
        #expect(IMMFont.body.size == 13 && IMMFont.body.lineHeight == 20 && IMMFont.body.weight == .regular)
        #expect(IMMFont.titleMD.size == 15 && IMMFont.titleMD.weight == .semibold)
        #expect(IMMFont.amountHero.tracking == -0.02 && IMMFont.amountHero.tabularDigits)
        #expect(IMMFont.control.lineHeight == 19.5 && IMMFont.control.weight == .medium)
        #expect(IMMFont.mono.postScriptName == "GeistMono-Regular")
        #expect(IMMFont.body.tabular.tabularDigits)
    }

    @MainActor
    @Test func textBoxMatchesCSSLineHeightForOneAndManyLines() {
        for style in [IMMFont.body, .small, .control, .titleMD] {
            let one = NSHostingView(rootView: Text(verbatim: "Hamburg").immFont(style).fixedSize())
            #expect(abs(one.fittingSize.height - style.lineHeight) <= 0.51, "\(style.name) one line")
            let three = NSHostingView(
                rootView: Text(verbatim: "Hamburg\nHamburg\nHamburg").immFont(style).fixedSize())
            #expect(abs(three.fittingSize.height - 3 * style.lineHeight) <= 0.51, "\(style.name) three lines")
        }
    }
}
