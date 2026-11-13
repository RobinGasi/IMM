import SwiftUI

private struct IMMDisableMotionKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private struct IMMInertKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private struct IMMFieldInvalidKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    /// When true every `Motion` modifier shows its final state at once (used by screenshot tests).
    public var immDisableMotion: Bool {
        get { self[IMMDisableMotionKey.self] }
        set { self[IMMDisableMotionKey.self] = newValue }
    }

    /// Set by `.inertControl()`: the control is disabled for interaction but keeps its enabled look.
    public var immInert: Bool {
        get { self[IMMInertKey.self] }
        set { self[IMMInertKey.self] = newValue }
    }

    /// Set by `Field` when it shows an error, read by the text fields and selects inside it.
    public var immFieldInvalid: Bool {
        get { self[IMMFieldInvalidKey.self] }
        set { self[IMMFieldInvalidKey.self] = newValue }
    }
}
