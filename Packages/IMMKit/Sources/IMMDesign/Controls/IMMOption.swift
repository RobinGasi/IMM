import SwiftUI

/// One choice of a `SelectTrigger`, `SegmentedTabs` or `ToggleGroup`.
///
/// Titles are `Text` so screens pass localised literals: `IMMOption(.month, Text("Month", bundle: .module))`.
public struct IMMOption<Value: Hashable>: Identifiable {
    public let value: Value
    public let title: Text

    public var id: Value { value }

    public init(_ value: Value, _ title: Text) {
        self.value = value
        self.title = title
    }

    public init(_ value: Value, verbatim title: String) {
        self.value = value
        self.title = Text(verbatim: title)
    }
}
