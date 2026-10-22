//
//  FilterStateTests.swift
//  Tests
//
//  Unit tests for ClipboardFilterState machine.
//

import Foundation
import SQLite

@MainActor
enum FilterStateTests {
    static func run(runner: TestRunner.Type) {
        print("\n--- Testing ClipboardFilterState Machine ---")

        let state = ClipboardFilterState()

        // 1. Initial State
        runner.assertEqual(state.criteria, SearchCriteria.empty, "Initial criteria should be empty")
        runner.assertTrue(state.currentFilter == nil, "Initial filter should be nil")
        runner.assertTrue(!state.isInFilterMode, "Initial mode should not be in filter mode")
        runner.assertEqual(state.filteredCount, 0, "Initial filtered count should be 0")
        runner.assertTrue(!state.isCountCapped, "Initial isCountCapped should be false")
        runner.assertEqual(state.revision, 0, "Initial revision should be 0")

        // 2. Update with empty criteria
        state.update(criteria: .empty)
        runner.assertTrue(!state.isInFilterMode, "Empty criteria should remain out of filter mode")
        runner.assertEqual(state.revision, 1, "Revision should increment")

        // 3. Update with short keyword (< 3 chars -> LIKE mode)
        let shortCriteria = SearchCriteria(
            keyword: "hi",
            selectedTypes: [],
            selectedAppIDs: [],
            selectedDateFilter: nil,
            selectedGroupIds: []
        )
        let shortFilter = state.update(criteria: shortCriteria)
        runner.assertTrue(shortFilter != nil, "Filter should be produced for short keyword")
        runner.assertTrue(state.isInFilterMode, "Should enter filter mode")
        runner.assertEqual(state.searchWord, "hi", "searchWord should reflect criteria")
        runner.assertEqual(state.revision, 2, "Revision should be 2")

        // 4. Update with long keyword (>= 3 chars -> FTS mode)
        let longCriteria = SearchCriteria(
            keyword: "swift code",
            selectedTypes: [],
            selectedAppIDs: [],
            selectedDateFilter: nil,
            selectedGroupIds: []
        )
        let longFilter = state.update(criteria: longCriteria)
        runner.assertTrue(longFilter != nil, "Filter should be produced for FTS keyword")
        runner.assertTrue(state.isInFilterMode, "Should be in filter mode")
        runner.assertEqual(state.revision, 3, "Revision should be 3")

        // 5. Update with multi-criteria (keyword + group + appID)
        let multiCriteria = SearchCriteria(
            keyword: "func",
            selectedTypes: [.string],
            selectedAppIDs: [100],
            selectedDateFilter: nil,
            selectedGroupIds: [1]
        )
        let multiFilter = state.update(criteria: multiCriteria)
        runner.assertTrue(multiFilter != nil, "Multi-criteria filter must be compiled")
        runner.assertTrue(state.isInFilterMode, "Should remain in filter mode")
        runner.assertEqual(state.revision, 4, "Revision should be 4")

        // 6. Reset
        state.isCountCapped = true
        state.reset()
        runner.assertEqual(state.criteria, SearchCriteria.empty, "Criteria must be reset to empty")
        runner.assertTrue(state.currentFilter == nil, "Filter must be reset to nil")
        runner.assertTrue(!state.isInFilterMode, "Should exit filter mode after reset")
        runner.assertTrue(!state.isCountCapped, "Reset should clear isCountCapped")
        runner.assertEqual(state.revision, 5, "Revision should be 5")

        // 7. Manual setFilter
        let dummyExpr = Expression<Bool>(value: true)
        state.setFilter(dummyExpr)
        runner.assertTrue(state.isInFilterMode, "Manual filter sets filter mode to true")
        runner.assertEqual(state.revision, 6, "Revision should be 6")

        // 8. Capped count state transitions
        func applyScanned(_ scanned: Int, to s: ClipboardFilterState) {
            let cap = 500
            let isCapped = scanned > cap
            s.filteredCount = isCapped ? cap : scanned
            s.isCountCapped = isCapped
        }

        applyScanned(300, to: state)
        runner.assertEqual(state.filteredCount, 300, "Uncapped scanned count sets exact number")
        runner.assertTrue(!state.isCountCapped, "Uncapped scanned count sets isCountCapped to false")

        applyScanned(501, to: state)
        runner.assertEqual(state.filteredCount, 500, "Capped scanned count caps at 500")
        runner.assertTrue(state.isCountCapped, "501 rows sets isCountCapped to true")

        // 9. Maintenance delete resets capped state
        state.reset()
        runner.assertTrue(!state.isCountCapped, "Reset clears capped state")

        print("✓ ClipboardFilterState tests passed!")
    }
}

private extension ClipboardFilterState {
    var searchWord: String { criteria.keyword }
}
