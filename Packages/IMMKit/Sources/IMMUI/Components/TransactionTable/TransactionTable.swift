import AppKit
import IMMDesign
import SwiftUI

/// The transaction list: a view-based `NSTableView` in an `NSScrollView` whose cells are hosted
/// SwiftUI views. Month headers are floating group rows; transactions are single-selectable.
///
/// The table always scrolls inside its frame. Column headers are not part of the table: draw
/// `TransactionTableHeader` above it with the same `layout` and padding.
public struct TransactionTable: NSViewRepresentable {
    public var rows: [TransactionTableRow]
    public var layout: TransactionTableLayout
    @Binding public var selection: String?
    /// Left and right row padding. nil uses `clamp(20, 2.2 % of the window width, 32)`.
    public var horizontalPadding: CGFloat?
    /// Extra scrollable space below the last row.
    public var bottomInset: CGFloat

    public init(
        rows: [TransactionTableRow], layout: TransactionTableLayout, selection: Binding<String?>,
        horizontalPadding: CGFloat? = nil, bottomInset: CGFloat = 0
    ) {
        self.rows = rows
        self.layout = layout
        self._selection = selection
        self.horizontalPadding = horizontalPadding
        self.bottomInset = bottomInset
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        IMMFonts.registerIfNeeded()
        let coordinator = context.coordinator

        let tableView = TransactionNSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 0
        column.width = 100
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.allowsColumnSelection = false
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.usesAutomaticRowHeights = false
        tableView.floatsGroupRows = true
        tableView.focusRingType = .none
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.backgroundColor = IMMColor.nsColor(named: "background") ?? .windowBackgroundColor
        tableView.delegate = coordinator
        tableView.dataSource = coordinator
        tableView.onGeometryChange = { [weak coordinator] in coordinator?.geometryDidChange() }
        coordinator.tableView = tableView

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = IMMColor.nsColor(named: "background") ?? .windowBackgroundColor
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.update(
            parent: self, disableMotion: context.environment.immDisableMotion, scrollView: scrollView)
    }

    // MARK: Coordinator

    @MainActor
    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        fileprivate var parent: TransactionTable
        fileprivate weak var tableView: TransactionNSTableView?
        private var rows: [TransactionTableRow] = []
        private var layout: TransactionTableLayout
        private var disableMotion = false
        private var isProgrammatic = false

        private static let cellID = NSUserInterfaceItemIdentifier("TransactionCell")
        private static let rowID = NSUserInterfaceItemIdentifier("TransactionRow")

        init(parent: TransactionTable) {
            self.parent = parent
            self.layout = parent.layout
        }

        // MARK: Updates from SwiftUI

        fileprivate func update(parent: TransactionTable, disableMotion: Bool, scrollView: NSScrollView) {
            guard let tableView else { return }
            let previousPadding = self.parent.horizontalPadding
            self.parent = parent

            let metricsChanged =
                layout != parent.layout || previousPadding != parent.horizontalPadding
                || self.disableMotion != disableMotion
            layout = parent.layout
            self.disableMotion = disableMotion

            let inset = NSEdgeInsets(top: 0, left: 0, bottom: parent.bottomInset, right: 0)
            if scrollView.contentInsets.bottom != inset.bottom {
                scrollView.contentInsets = inset
            }

            isProgrammatic = true
            apply(newRows: parent.rows, to: tableView)
            if metricsChanged { refreshAllCells() }
            syncSelectionFromBinding(tableView, scroll: true)
            isProgrammatic = false
        }

        /// Applies a new snapshot: same ids reload the changed rows, different ids use a minimal
        /// insert/remove batch (full reload for very large changes). Scroll position and selection stay.
        private func apply(newRows: [TransactionTableRow], to tableView: NSTableView) {
            let old = rows
            guard old != newRows else { return }
            rows = newRows

            let oldIDs = old.map(\.id)
            let newIDs = newRows.map(\.id)

            if oldIDs == newIDs {
                var changed = IndexSet()
                for index in newRows.indices where old[index] != newRows[index] {
                    changed.insert(index)
                }
                tableView.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
                return
            }

            let difference = newIDs.difference(from: oldIDs)
            if difference.count > 500 {
                tableView.reloadData()
                return
            }

            tableView.beginUpdates()
            for change in difference {
                switch change {
                case .remove(let offset, _, _):
                    tableView.removeRows(at: IndexSet(integer: offset), withAnimation: [])
                case .insert(let offset, _, _):
                    tableView.insertRows(at: IndexSet(integer: offset), withAnimation: [])
                }
            }
            tableView.endUpdates()

            // Survivors whose content changed.
            var oldByID: [String: TransactionTableRow] = [:]
            oldByID.reserveCapacity(old.count)
            for row in old { oldByID[row.id] = row }
            var changed = IndexSet()
            for (index, row) in newRows.enumerated() {
                if let previous = oldByID[row.id], previous != row { changed.insert(index) }
            }
            if !changed.isEmpty {
                tableView.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
            }
        }

        private func syncSelectionFromBinding(_ tableView: NSTableView, scroll: Bool) {
            let wanted = parent.selection.flatMap { id in
                rows.firstIndex { $0.transactionID == id }
            }
            let current = tableView.selectedRow
            switch wanted {
            case nil:
                if current != -1 { tableView.deselectAll(nil) }
            case let row?:
                if current != row {
                    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    if scroll { tableView.scrollRowToVisible(row) }
                }
            }
        }

        private func refreshSelectionState(_ tableView: NSTableView) {
            let selected = tableView.selectedRow
            tableView.enumerateAvailableRowViews { rowView, row in
                guard let rowView = rowView as? TransactionRowView else { return }
                rowView.hostedCell?.interaction.isSelected = rowView.isInteractive && row == selected
            }
        }

        // MARK: Geometry

        fileprivate func geometryDidChange() {
            refreshAllCells()
        }

        private func currentPadding(_ tableView: NSTableView) -> CGFloat {
            if let fixed = parent.horizontalPadding { return fixed }
            let windowWidth = tableView.window?.contentView?.bounds.width ?? 1440
            return IMMLayout.contentPadding(windowWidth: windowWidth)
        }

        private func refreshAllCells() {
            guard let tableView else { return }
            tableView.enumerateAvailableRowViews { rowView, row in
                guard row < rows.count, let rowView = rowView as? TransactionRowView,
                    let cell = rowView.hostedCell
                else { return }
                configure(cell, row: row, in: tableView)
            }
        }

        private func configure(_ cell: TransactionHostingCell, row: Int, in tableView: NSTableView) {
            let padding = currentPadding(tableView)
            let width = tableView.bounds.width
            let columns = TransactionColumns(layout: layout, contentWidth: width - 2 * padding)
            cell.configure(
                TransactionCellRoot(
                    row: rows[row], layout: layout, columns: columns, padding: padding,
                    interaction: cell.interaction, disableMotion: disableMotion))
        }

        // MARK: NSTableViewDataSource / Delegate

        public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            rows[row].height
        }

        public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            if case .monthHeader = rows[row] { return true }
            return false
        }

        public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            rows[row].transactionID != nil
        }

        public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view =
                tableView.makeView(withIdentifier: Self.rowID, owner: nil) as? TransactionRowView
                ?? {
                    let created = TransactionRowView()
                    created.identifier = Self.rowID
                    return created
                }()
            view.isInteractive = rows[row].transactionID != nil
            return view
        }

        public func tableView(
            _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
        ) -> NSView? {
            let cell =
                tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? TransactionHostingCell
                ?? {
                    let created = TransactionHostingCell()
                    created.identifier = Self.cellID
                    return created
                }()
            cell.interaction.reset()
            cell.interaction.isSelected = rows[row].transactionID != nil && tableView.selectedRowIndexes.contains(row)
            configure(cell, row: row, in: tableView)
            return cell
        }

        public func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView else { return }
            refreshSelectionState(tableView)
            guard !isProgrammatic else { return }
            let row = tableView.selectedRow
            let id = (row >= 0 && row < rows.count) ? rows[row].transactionID : nil
            if parent.selection != id {
                parent.selection = id
            }
        }
    }
}

// MARK: - AppKit pieces

/// The table: swallows Return and space, reports width changes.
final class TransactionNSTableView: NSTableView {
    var onGeometryChange: (@MainActor () -> Void)?
    private var lastWidth: CGFloat = -1

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76, 49:  // return, enter, space: no-op
            return
        default:
            super.keyDown(with: event)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(newSize.width - lastWidth) > 0.5 {
            lastWidth = newSize.width
            onGeometryChange?()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onGeometryChange?() }
    }
}

/// Row container: draws the opaque background of floating headers and tracks hover and press.
final class TransactionRowView: NSTableRowView {
    var isInteractive = false
    private var trackingArea: NSTrackingArea?

    var hostedCell: TransactionHostingCell? {
        subviews.lazy.compactMap { $0 as? TransactionHostingCell }.first
    }

    override var isSelected: Bool {
        didSet { hostedCell?.interaction.isSelected = isSelected && isInteractive }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isInteractive = false
    }

    override func drawBackground(in dirtyRect: NSRect) {
        (IMMColor.nsColor(named: "background") ?? .windowBackgroundColor).setFill()
        dirtyRect.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        updateHoverFromPointer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateHoverFromPointer()
    }

    private func updateHoverFromPointer() {
        guard isInteractive, let window else {
            hostedCell?.interaction.isHovered = false
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        hostedCell?.interaction.isHovered = bounds.contains(point) && window.isKeyWindow
    }

    override func mouseEntered(with event: NSEvent) {
        if isInteractive { hostedCell?.interaction.isHovered = true }
    }

    override func mouseExited(with event: NSEvent) {
        hostedCell?.interaction.isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractive else {
            super.mouseDown(with: event)
            return
        }
        let interaction = hostedCell?.interaction
        interaction?.isPressed = true
        // NSTableView tracks the click until the mouse is released.
        super.mouseDown(with: event)
        interaction?.isPressed = false
    }
}

/// A cell that hosts one SwiftUI row and lets every click through to the row view.
final class TransactionHostingCell: NSTableCellView {
    let interaction = RowInteraction()
    private var hosting: NSHostingView<TransactionCellRoot>?

    func configure(_ root: TransactionCellRoot) {
        if let hosting {
            hosting.rootView = root
        } else {
            let view = NSHostingView(rootView: root)
            view.sizingOptions = []
            view.safeAreaRegions = []
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
            hosting = view
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
