//
//  ClipboardFilterState.swift
//  Clipboard
//
//  UI filter and search state machine: manages search criteria, compiled SQL filter expressions, and filtered count.
//

import Combine
import Foundation
import os
import SQLite

final class ClipboardFilterState: @unchecked Sendable {
    static let shared = ClipboardFilterState()

    private struct State {
        var criteria: SearchCriteria = .empty
        var currentFilter: SQLite.Expression<Bool>?
        var filteredCount: Int = 0
        var isCountCapped: Bool = false
        var revision: Int = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Current search and filter criteria
    var criteria: SearchCriteria {
        state.withLock { $0.criteria }
    }

    /// Compiled SQLite expression for filtering
    var currentFilter: SQLite.Expression<Bool>? {
        state.withLock { $0.currentFilter }
    }

    /// Whether UI is currently in filter mode (has active search or tag/app/date/group filters)
    var isInFilterMode: Bool {
        state.withLock { $0.currentFilter != nil }
    }

    /// Total matching count in filter mode
    var filteredCount: Int {
        get { state.withLock { $0.filteredCount } }
        set { state.withLock { $0.filteredCount = newValue } }
    }

    /// Whether the filteredCount is capped at the threshold (e.g. 500+)
    var isCountCapped: Bool {
        get { state.withLock { $0.isCountCapped } }
        set { state.withLock { $0.isCountCapped = newValue } }
    }

    /// Monotonically increasing revision to detect cancellation or stale results
    var revision: Int {
        state.withLock { $0.revision }
    }

    init() {}

    /// Updates active search criteria and compiles corresponding SQL filter expression.
    @discardableResult
    func update(criteria: SearchCriteria) -> SQLite.Expression<Bool>? {
        let filter: SQLite.Expression<Bool>? = criteria.isEmpty ? nil : PasteFilterBuilder.buildFilter(from: criteria)
        state.withLock { s in
            s.revision &+= 1
            s.criteria = criteria
            s.isCountCapped = false
            s.currentFilter = filter
        }
        return filter
    }

    /// Resets filter state back to default unfiltered browse mode.
    func reset() {
        state.withLock { s in
            s.revision &+= 1
            s.criteria = .empty
            s.currentFilter = nil
            s.filteredCount = 0
            s.isCountCapped = false
        }
    }

    /// Manually sets currentFilter for specialized queries or maintenance reload.
    func setFilter(_ filter: SQLite.Expression<Bool>?) {
        state.withLock { s in
            s.revision &+= 1
            s.currentFilter = filter
            s.isCountCapped = false
        }
    }
}
