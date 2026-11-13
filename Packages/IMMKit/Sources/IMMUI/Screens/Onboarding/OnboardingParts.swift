import IMMDesign
import SwiftUI

// Pieces shared by Add bank and Bank login. Values come from `Onboarding2AddBankSetup.tsx`,
// `Onboarding3BankLoginSetup.tsx` and the `States / Bank login` artboards.

/// The design's `FieldLabel` above an input: 12 px medium, `leading-snug` (16.5 px), 8 px above the control.
struct OnboardingField<Content: View>: View {
    let label: Text
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            label
                .immFont(IMMFont.smallMedium.withLineHeight(16.5))
                .foregroundStyle(IMMColor.foreground)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An input drawn disabled the way the "Waiting" artboard does it: `muted` fill, `border` border,
/// `muted-foreground` text, full opacity.
struct OnboardingDisabledInput: View {
    let text: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: IMMRadius.md, style: .continuous)
        Text(verbatim: text)
            .immFont(.controlRegular)
            .foregroundStyle(IMMColor.mutedForeground)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
            .background(shape.fill(IMMColor.muted))
            .overlay(shape.strokeBorder(IMMColor.border, lineWidth: 1))
    }
}

/// The footer's primary button. Disabled it is drawn as the artboards do: `muted` fill, `border`
/// border, `muted-foreground` text.
struct OnboardingPrimaryButton: View {
    let title: Text
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        if enabled {
            Button(action: action) { title }
                .immButtonStyle(.default)
        } else {
            let shape = RoundedRectangle(cornerRadius: IMMRadius.md, style: .continuous)
            title
                .immFont(.control)
                .foregroundStyle(IMMColor.mutedForeground)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(shape.fill(IMMColor.muted))
                .overlay(shape.strokeBorder(IMMColor.border, lineWidth: 1))
                .accessibilityAddTraits(.isButton)
        }
    }
}

/// `Spinner` of the design (Lucide `loader-circle`, 16 px): three quarters of a ring turning once a second.
struct OnboardingSpinner: View {
    @Environment(\.immDisableMotion) private var disableMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if disableMotion || reduceMotion {
            ring(turn: 0)
        } else {
            TimelineView(.animation) { context in
                ring(turn: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1))
            }
        }
    }

    private func ring(turn: Double) -> some View {
        Circle()
            .trim(from: 0, to: 0.8)
            .stroke(style: StrokeStyle(lineWidth: 1.75 * 16 / 24, lineCap: .round))
            .frame(width: 18 * 16 / 24, height: 18 * 16 / 24)
            .frame(width: 16, height: 16)
            .rotationEffect(.degrees(turn * 360))
    }
}

/// Lucide `circle-check` (24 px grid, drawn at 16 px) with its draw-on animation.
struct OnboardingCircleCheck: View {
    var color: Color

    var body: some View {
        ZStack {
            DrawnStroke(CircleRing(), color: color, lineWidth: 1.75 * 16 / 24, duration: 0.35, delay: 0.2)
            DrawnStroke(TickPath(), color: color, lineWidth: 1.75 * 16 / 24, duration: 0.35, delay: 0.2)
        }
        .frame(width: 16, height: 16)
    }

    private struct CircleRing: Shape {
        func path(in rect: CGRect) -> Path {
            Path(ellipseIn: CGRect(x: 2, y: 2, width: 20, height: 20).scaled(to: rect))
        }
    }

    private struct TickPath: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let k = rect.width / 24
            path.move(to: CGPoint(x: 9 * k, y: 12 * k))
            path.addLine(to: CGPoint(x: 11 * k, y: 14 * k))
            path.addLine(to: CGPoint(x: 15 * k, y: 10 * k))
            return path
        }
    }
}

private extension CGRect {
    /// Maps a rectangle given in the 24 px icon grid into `rect`.
    func scaled(to rect: CGRect) -> CGRect {
        let k = rect.width / 24
        return CGRect(x: origin.x * k + rect.minX, y: origin.y * k + rect.minY, width: width * k, height: height * k)
    }
}

/// The status line below the login form: 12 px above, 1 px rule on top, icon and 13 px text.
struct OnboardingStatusLine<Icon: View>: View {
    let text: String
    let color: Color
    @ViewBuilder let icon: Icon

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rule()
            HStack(spacing: 8) {
                icon
                Text(verbatim: text)
                    .immFont(IMMFont.body.withLineHeight(18).tabular)
                    .foregroundStyle(color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .immFadeIn(duration: 0.2, delay: 0.3)
            }
            .padding(.top, 12)
        }
        .foregroundStyle(color)
    }
}

/// `HH:mm` in the Mac's time zone, as "Confirmed in S-pushTAN at 08:41".
enum OnboardingClock {
    static func string(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
