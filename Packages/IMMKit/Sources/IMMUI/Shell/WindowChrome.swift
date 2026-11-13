import AppKit
import SwiftUI

/// Gives a window the design's look: transparent title bar, full-size content, and the real close,
/// minimise and zoom buttons at the positions of the drawn dots. Add it as a background of the window's
/// root view: `.background(WindowChrome(.main))`.
///
/// Button centres, measured from the window's top left (design offsets):
/// - `.main`: (24, 28), (44, 28), (64, 28)
/// - `.setup`: (24, 26), (44, 26), (64, 26) (12 px dots starting at x 18, y 20)
/// - `.settings`: (18, 26), (38, 26), (58, 26) (12 px dots starting at x 12, y 20)
public struct WindowChrome: NSViewRepresentable {
    public enum Layout: Sendable {
        case main, setup, settings

        /// Centre of the close button from the window's top left.
        var firstCenter: CGPoint {
            switch self {
            case .main: return CGPoint(x: 24, y: 28)
            case .setup: return CGPoint(x: 24, y: 26)
            case .settings: return CGPoint(x: 18, y: 26)
            }
        }

        /// Distance between button centres.
        var spacing: CGFloat { 20 }
    }

    /// Height of the (transparent) title bar that SwiftUI adds to the window size of a content view
    /// that ignores the safe area. Windows with a fixed design size ask for `size - titlebarInset`.
    public static let titlebarInset: CGFloat = 32

    private let layout: Layout

    public init(_ layout: Layout) {
        self.layout = layout
    }

    public func makeNSView(context: Context) -> ChromeProbeView {
        ChromeProbeView(layout: layout)
    }

    public func updateNSView(_ nsView: ChromeProbeView, context: Context) {
        nsView.layout = layout
        if let window = nsView.window { nsView.apply(to: window) }
    }
}

/// Finds the hosting window and keeps its title-bar buttons in place.
public final class ChromeProbeView: NSView {
    var layout: WindowChrome.Layout
    private var observers: [NSObjectProtocol] = []

    init(layout: WindowChrome.Layout) {
        self.layout = layout
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        guard let window else { return }
        apply(to: window)
        // Re-apply when AppKit lays the title bar out again.
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didEndLiveResizeNotification, NSWindow.didUpdateNotification,
        ]
        for name in names {
            let token = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    self.apply(to: window)
                }
            }
            observers.append(token)
        }
    }

    private func removeObservers() {
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers = []
    }

    func apply(to window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
        if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
        // Setup and Settings have a fixed size: the zoom button is disabled and the edges do not resize.
        if layout != .main, window.styleMask.contains(.resizable) { window.styleMask.remove(.resizable) }
        positionButtons(in: window)
    }


    private func positionButtons(in window: NSWindow) {
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = types.compactMap { window.standardWindowButton($0) }
        guard buttons.count == 3, let titlebarView = buttons[0].superview,
              let container = titlebarView.superview, let theme = container.superview else { return }

        let size = buttons[0].frame.size
        let center = layout.firstCenter
        // The title-bar container must be tall enough to contain the buttons (and to hit-test them).
        let height = (center.y + size.height / 2).rounded(.up)
        let wanted = NSRect(x: 0, y: theme.bounds.height - height, width: theme.bounds.width, height: height)
        if String(describing: type(of: container)).contains("Titlebar"), container.frame != wanted {
            container.frame = wanted
            titlebarView.frame = container.bounds
        }

        let y = titlebarView.isFlipped ? center.y - size.height / 2 : titlebarView.bounds.height - center.y - size.height / 2
        for (index, button) in buttons.enumerated() {
            let x = center.x + CGFloat(index) * layout.spacing - size.width / 2
            let origin = NSPoint(x: x, y: y)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }
}
