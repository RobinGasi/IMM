import SwiftUI

/// The design's named animations. Durations are the usual values; pass the
/// exact duration and delay of the artboard where it differs.
///
/// Every modifier shows the final state at once when Reduce Motion is on or
/// `EnvironmentValues.immDisableMotion` is true.
public enum Motion {
    public enum Kind: String, CaseIterable, Sendable {
        case draw, fadeIn, growX, growY, popIn, riseIn, sheetDown, slideInRight
    }

    /// Usual duration in seconds: fade-in 0.2, rise-in 0.24, pop-in 0.16, grow-x 0.4, grow-y 0.3,
    /// draw 0.7, sheet-down 0.26, slide-in-right 0.24.
    public static func defaultDuration(_ kind: Kind) -> Double {
        switch kind {
        case .fadeIn: return 0.2
        case .riseIn: return 0.24
        case .popIn: return 0.16
        case .growX: return 0.4
        case .growY: return 0.3
        case .draw: return 0.7
        case .sheetDown: return 0.26
        case .slideInRight: return 0.24
        }
    }

    /// `cubic-bezier(0.23, 1, 0.32, 1)` for all kinds except `sheetDown` and `slideInRight`,
    /// which use `cubic-bezier(0.32, 0.72, 0, 1)`.
    public static func animation(_ kind: Kind, duration: Double? = nil, delay: Double = 0) -> Animation {
        let d = duration ?? defaultDuration(kind)
        let base: Animation
        switch kind {
        case .sheetDown, .slideInRight:
            base = .timingCurve(0.32, 0.72, 0, 1, duration: d)
        default:
            base = .timingCurve(0.23, 1, 0.32, 1, duration: d)
        }
        return delay > 0 ? base.delay(delay) : base
    }

    /// CSS `ease` (`cubic-bezier(0.25, 0.1, 0.25, 1)`); hover transitions use 0.12 s, buttons 0.15 s.
    public static func ease(_ duration: Double = 0.12) -> Animation {
        .timingCurve(0.25, 0.1, 0.25, 1, duration: duration)
    }

    /// Press feedback: `scale 150ms cubic-bezier(0.23, 1, 0.32, 1)`.
    public static let press: Animation = .timingCurve(0.23, 1, 0.32, 1, duration: 0.15)

    /// Scale of a pressed button.
    public static let pressedScale: CGFloat = 0.96
}

private struct MotionModifier: ViewModifier {
    let kind: Motion.Kind
    let duration: Double?
    let delay: Double

    @Environment(\.immDisableMotion) private var disableMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = false

    private var settled: Bool { disableMotion || reduceMotion || started }

    func body(content: Content) -> some View {
        effect(content)
            .onAppear {
                guard !(disableMotion || reduceMotion), !started else { return }
                withAnimation(Motion.animation(kind, duration: duration, delay: delay)) {
                    started = true
                }
            }
    }

    @ViewBuilder
    private func effect(_ content: Content) -> some View {
        switch kind {
        case .fadeIn:
            content.opacity(settled ? 1 : 0)
        case .riseIn:
            content
                .opacity(settled ? 1 : 0)
                .offset(y: settled ? 0 : 8)
        case .popIn:
            content
                .opacity(settled ? 1 : 0)
                .scaleEffect(settled ? 1 : 0.96)
        case .growX:
            content.scaleEffect(x: settled ? 1 : 0.0001, y: 1, anchor: .leading)
        case .growY:
            content.scaleEffect(x: 1, y: settled ? 1 : 0.0001, anchor: .bottom)
        case .sheetDown:
            content
                .opacity(settled ? 1 : 0)
                .offset(y: settled ? 0 : -12)
                .scaleEffect(settled ? 1 : 0.98, anchor: .top)
        case .slideInRight:
            content
                .opacity(settled ? 1 : 0)
                .offset(x: settled ? 0 : 16)
        case .draw:
            // Generic reveal from the leading edge. For strokes use `DrawnStroke`.
            content.mask(alignment: .leading) {
                Rectangle().scaleEffect(x: settled ? 1 : 0.0001, y: 1, anchor: .leading)
            }
        }
    }
}

extension View {
    /// Plays a named entrance animation once when the view appears.
    public func immMotion(_ kind: Motion.Kind, duration: Double? = nil, delay: Double = 0) -> some View {
        modifier(MotionModifier(kind: kind, duration: duration, delay: delay))
    }

    /// `fade-in`: opacity 0 → 1.
    public func immFadeIn(duration: Double? = nil, delay: Double = 0) -> some View {
        immMotion(.fadeIn, duration: duration, delay: delay)
    }

    /// `rise-in`: opacity 0 → 1 and 8 pt up.
    public func immRiseIn(duration: Double? = nil, delay: Double = 0) -> some View {
        immMotion(.riseIn, duration: duration, delay: delay)
    }

    /// `pop-in`: opacity 0 → 1 and scale 0.96 → 1.
    public func immPopIn(duration: Double? = nil, delay: Double = 0) -> some View {
        immMotion(.popIn, duration: duration, delay: delay)
    }

    /// `grow-x`: scaleX 0 → 1 from the leading edge.
    public func immGrowX(duration: Double? = nil, delay: Double = 0) -> some View {
        immMotion(.growX, duration: duration, delay: delay)
    }

    /// `grow-y`: scaleY 0 → 1 from the bottom.
    public func immGrowY(duration: Double? = nil, delay: Double = 0) -> some View {
        immMotion(.growY, duration: duration, delay: delay)
    }

    /// `sheet-down`: opacity, 12 pt down and scale 0.98 → 1 from the top.
    public func immSheetDown(duration: Double? = nil, delay: Double = 0) -> some View {
        immMotion(.sheetDown, duration: duration, delay: delay)
    }

    /// `slide-in-right`: opacity 0 → 1 and 16 pt from the right.
    public func immSlideInRight(duration: Double? = nil, delay: Double = 0) -> some View {
        immMotion(.slideInRight, duration: duration, delay: delay)
    }
}

/// A stroked shape that draws itself from start to end (`draw`, `pathLength="1"` dash offset 1 → 0).
public struct DrawnStroke<S: Shape>: View {
    private let shape: S
    private let color: Color
    private let style: StrokeStyle
    private let duration: Double?
    private let delay: Double

    @Environment(\.immDisableMotion) private var disableMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = false

    public init(
        _ shape: S, color: Color, lineWidth: CGFloat, lineCap: CGLineCap = .round,
        lineJoin: CGLineJoin = .round, duration: Double? = nil, delay: Double = 0
    ) {
        self.shape = shape
        self.color = color
        self.style = StrokeStyle(lineWidth: lineWidth, lineCap: lineCap, lineJoin: lineJoin)
        self.duration = duration
        self.delay = delay
    }

    public var body: some View {
        let settled = disableMotion || reduceMotion || started
        shape
            .trim(from: 0, to: settled ? 1 : 0)
            .stroke(color, style: style)
            .onAppear {
                guard !(disableMotion || reduceMotion), !started else { return }
                withAnimation(Motion.animation(.draw, duration: duration, delay: delay)) {
                    started = true
                }
            }
    }
}
