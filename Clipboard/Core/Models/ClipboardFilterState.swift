//
//  ClipboardFilterState.swift
//  Clipboard
//
//  UI filter and search state machine: manages search criteria, compiled SQL filter expressions, and filtered count.
//

import Combine
import Foundation
import SQLite

final class ClipboardFilterState: @unchecked Sendable {
    static let shared = ClipboardFilterState()

    /// Current search and filter criteria
    private(set) var criteria: SearchCriteria = .empty

    /// Compiled SQLite expression for filtering
    private(set) var currentFilter: SQLite.Expression<Bool>?

    /// Whether UI is currently in filter mode (has active search or tag/app/date/group filters)
    var isInFilterMode: Bool {
        currentFilter != nil
    }

    /// Total matching count in filter mode
    var filteredCount: Int = 0

    /// Monotonically increasing revision to detect cancellation or stale results
    private(set) var revision: Int = 0

    init() {}

    /// Updates active search criteria and compiles corresponding SQL filter expression.
    @discardableResult
    func update(criteria: SearchCriteria) -> SQLite.Expression<Bool>? {
        revision &+= 1
        self.criteria = criteria
        if criteria.isEmpty {
            self.currentFilter = nil
        } else {
            self.currentFilter = PasteFilterBuilder.buildFilter(from: criteria)
        }
        return self.currentFilter
    }

    /// Resets filter state back to default unfiltered browse mode.
    func reset() {
        revision &+= 1
        criteria = .empty
        currentFilter = nil
    }

    /// Manually sets currentFilter for specialized queries or maintenance reload.
    func setFilter(_ filter: SQLite.Expression<Bool>?) {
        revision &+= 1
        self.currentFilter = filter
    }
}
