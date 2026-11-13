import SwiftUI

/// The IMM logo mark (viewBox 0 0 40 28): two letters drawn with 2.25 strokes over two rules of 1.5.
public struct IMMLogoMark: View {
    private let width: CGFloat
    private let color: Color
    private let animated: Bool

    /// - Parameters:
    ///   - width: drawn width; height follows the 40 : 28 aspect (design uses 40 and 60).
    ///   - color: stroke colour, the primary token by default.
    ///   - animated: plays the 600 ms `draw` animation (Create vault, Unlock).
    public init(width: CGFloat = 40, color: Color = IMMColor.primary, animated: Bool = false) {
        self.width = width
        self.color = color
        self.animated = animated
    }

    public var body: some View {
        let scale = width / 40
        ZStack {
            stroke(IMMLogoLetters(), lineWidth: 2.25 * scale)
            stroke(IMMLogoRules(), lineWidth: 1.5 * scale)
        }
        .frame(width: width, height: 28 * scale)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "IMM"))
    }

    @ViewBuilder
    private func stroke<S: Shape>(_ shape: S, lineWidth: CGFloat) -> some View {
        if animated {
            DrawnStroke(shape, color: color, lineWidth: lineWidth, lineCap: .square, lineJoin: .miter, duration: 0.6)
        } else {
            shape.stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .square, lineJoin: .miter))
        }
    }
}

/// `M4 3v16M10 19V3l5 8 5-8v16M24 19V3l5 8 5-8v16` in a 40 × 28 box.
struct IMMLogoLetters: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 40
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
        }
        var path = Path()
        path.move(to: p(4, 3))
        path.addLine(to: p(4, 19))
        path.move(to: p(10, 19))
        path.addLine(to: p(10, 3))
        path.addLine(to: p(15, 11))
        path.addLine(to: p(20, 3))
        path.addLine(to: p(20, 19))
        path.move(to: p(24, 19))
        path.addLine(to: p(24, 3))
        path.addLine(to: p(29, 11))
        path.addLine(to: p(34, 3))
        path.addLine(to: p(34, 19))
        return path
    }
}

/// `M2 23.5h36M2 26.5h36` in a 40 × 28 box.
struct IMMLogoRules: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 40
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 2 * s, y: rect.minY + 23.5 * s))
        path.addLine(to: CGPoint(x: rect.minX + 38 * s, y: rect.minY + 23.5 * s))
        path.move(to: CGPoint(x: rect.minX + 2 * s, y: rect.minY + 26.5 * s))
        path.addLine(to: CGPoint(x: rect.minX + 38 * s, y: rect.minY + 26.5 * s))
        return path
    }
}
