import IMMDesign
import SwiftUI

/// A design icon that turns once per second while `spinning` (sync symbol in toolbar and sidebar);
/// it is drawn in `primary` while it turns, as on the Sync in progress artboard. With Reduce Motion on
/// (or `immDisableMotion`) it stays still and keeps the `primary` colour as the only sign of activity.
struct SpinningIcon: View {
    let name: String
    let size: CGFloat
    var color: Color?
    let spinning: Bool

    @Environment(\.immDisableMotion) private var disableMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if spinning, disableMotion || reduceMotion {
            IMMIcon(name, size: size, color: IMMColor.primary)
        } else if spinning {
            TimelineView(.animation) { context in
                let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
                IMMIcon(name, size: size, color: IMMColor.primary)
                    .rotationEffect(.degrees(turn * 360))
            }
        } else {
            IMMIcon(name, size: size, color: color)
        }
    }
}
