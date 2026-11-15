import IMMDesign
import SwiftUI

/// Pairing step 1: scan the QR code that IMM shows on the Mac.
///
/// Follows `DesignReference/screens/iphone-pair-scan@1x.png`: title bar with Cancel, a large dark rounded panel
/// holding the injected camera view with four corner brackets, and a caption underneath.
struct PairScanView<Scanner: View>: View {
    @Environment(CompanionModel.self) private var model
    private let scanner: Scanner
    private let isConnecting: Bool
    private let macName: String?

    init(scanner: Scanner, isConnecting: Bool = false, macName: String? = nil) {
        self.scanner = scanner
        self.isConnecting = isConnecting
        self.macName = macName
    }

    var body: some View {
        VStack(spacing: 0) {
            PairTitleBar(title: Text("Pair with your Mac", bundle: .module), cancelsPairing: true)
            panel
                .padding(.horizontal, 16)
                .padding(.top, 12)
            caption
                .padding(.horizontal, 40)
                .padding(.top, 24)
                .padding(.bottom, 32)
        }
    }

    private var panel: some View {
        ZStack {
            scanner
            ScanCornerBrackets()
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .frame(width: 234, height: 234)
                .accessibilityHidden(true)
            if isConnecting {
                CompanionColor.scannerSurface.opacity(0.85)
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large).tint(Color.white)
                    Text("Connecting…", bundle: .module)
                        .immFont(CompanionFont.headline)
                        .foregroundStyle(Color.white)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CompanionColor.scannerSurface)
        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
    }

    @ViewBuilder
    private var caption: some View {
        if isConnecting {
            Text(verbatim: connectingText)
                .immFont(CompanionFont.body)
                .foregroundStyle(IMMColor.foreground)
                .multilineTextAlignment(.center)
        } else {
            Text("Point your camera at the code in IMM on your Mac.", bundle: .module)
                .immFont(CompanionFont.body)
                .foregroundStyle(IMMColor.foreground)
                .multilineTextAlignment(.center)
        }
    }

    private var connectingText: String {
        if let macName {
            return String(localized: "Connecting to \(macName)…", bundle: .module)
        }
        return String(localized: "Connecting to your Mac…", bundle: .module)
    }
}

/// Title bar of the pairing screens: centred bold title, optional Cancel on the left in the accent colour.
struct PairTitleBar: View {
    @Environment(CompanionModel.self) private var model
    let title: Text
    let cancelsPairing: Bool

    var body: some View {
        ZStack {
            title
                .immFont(CompanionFont.headline)
                .foregroundStyle(IMMColor.foreground)
            if cancelsPairing {
                HStack {
                    Button {
                        model.cancelPairing()
                    } label: {
                        Text("Cancel", bundle: .module)
                            .immFont(CompanionFont.body)
                            .foregroundStyle(IMMColor.primary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 16)
    }
}

/// Four rounded L-shaped corner marks that frame the scan area.
struct ScanCornerBrackets: Shape {
    var arm: CGFloat = 48
    var radius: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = radius
        let a = arm
        // Top left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + a))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + a, y: rect.minY))
        // Top right
        path.move(to: CGPoint(x: rect.maxX - a, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + a))
        // Bottom right
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - a))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - a, y: rect.maxY))
        // Bottom left
        path.move(to: CGPoint(x: rect.minX + a, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - a))
        return path
    }
}

#Preview("Scan") {
    CompanionRootView(model: .preview(.scanning))
}

#Preview("Connecting") {
    CompanionRootView(model: .preview(.connecting))
}
