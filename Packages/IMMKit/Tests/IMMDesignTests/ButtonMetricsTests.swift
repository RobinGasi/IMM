import AppKit
import SwiftUI
import Testing

@testable import IMMDesign

@MainActor
@Suite struct ButtonMetricsTests {
    private func fitting<V: View>(_ view: V) -> CGSize {
        NSHostingView(rootView: view.environment(\.immDisableMotion, true)).fittingSize
    }

    private var textWidth: CGFloat {
        fitting(Text(verbatim: "Review one by one").immFont(.control)).width
    }

    /// The design's buttons are `border-box` with a 1 px border and 8 px padding: text + 18, 28 or 24 high.
    @Test func textButtonsAreTextPlusEighteen() {
        for variant in [IMMButtonStyle.Variant.default, .outline, .ghost] {
            let regular = fitting(Button {} label: { Text(verbatim: "Review one by one") }.immButtonStyle(variant))
            #expect(abs(regular.width - (textWidth + 18)) < 0.5, "\(variant)")
            #expect(regular.height == 28)
            let small = fitting(Button {} label: { Text(verbatim: "Review one by one") }.immButtonStyle(variant, size: .sm))
            #expect(abs(small.width - (textWidth + 18)) < 0.5, "\(variant) sm")
            #expect(small.height == 24)
        }
    }

    /// A leading icon moves the left inset from 9 to 7 (`pl-1.5` plus the border); the icon is 14 px, the gap 4.
    @Test func leadingIconButtonsAreIconGapTextPlusSixteen() {
        let icon = fitting(
            Button {} label: {
                HStack(spacing: 4) {
                    IMMIcon("arrow-up-right", size: 14)
                    Text(verbatim: "Review one by one")
                }
            }
            .immButtonStyle(.default, leadingIcon: true))
        #expect(abs(icon.width - (textWidth + 14 + 4 + 16)) < 0.5)
    }

    @Test func squareButtonsStayFixed() {
        #expect(fitting(Button {} label: { IMMIcon("x", size: 14) }.immButtonStyle(.ghost, size: .icon)) == CGSize(width: 28, height: 28))
        #expect(fitting(Button {} label: { IMMIcon("x", size: 12) }.immButtonStyle(.ghost, size: .iconSm)) == CGSize(width: 24, height: 24))
    }
}

private struct FocusHost: View {
    @State var text = ""
    @FocusState var focused: Bool

    var body: some View {
        VStack {
            IMMSecureField(text: $text, focused: $focused)
            IMMTextField(text: $text, focused: $focused)
            InputGroup(text: $text, focused: $focused) { Text(verbatim: "a") }
        }
    }
}

@MainActor
@Suite struct ExternalFocusTests {
    /// The external focus parameter exists on all three fields and the host renders.
    @Test func fieldsAcceptAnExternalFocusBinding() {
        let size = NSHostingView(rootView: FocusHost()).fittingSize
        #expect(size.width > 0 && size.height > 0)
    }
}
