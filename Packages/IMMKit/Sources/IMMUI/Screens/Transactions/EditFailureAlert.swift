import AppKit
import Foundation

/// The alert shown when an edit cannot be stored.
enum EditFailureAlert {
    @MainActor
    static func show(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "The change could not be saved.", bundle: .module)
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "OK", bundle: .module))
        alert.runModal()
    }
}
