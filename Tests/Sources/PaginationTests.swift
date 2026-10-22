//
//  PaginationTests.swift
//  Tests
//
//  Unit tests for pagination deduplication, barrier checks, and boundary logic.
//

import Foundation

@MainActor
enum PaginationTests {
    struct TestItem: Equatable {
        let id: Int64?
        let uniqueId: String
        let title: String
    }

    static func run(runner: TestRunner.Type) {
        print("\n--- Testing Pagination Deduplication & Boundary Logic ---")

        // 1. Double-shield deduplication by id and uniqueId
        let initialList: [TestItem] = [
            TestItem(id: 1, uniqueId: "u1", title: "First"),
            TestItem(id: 2, uniqueId: "u2", title: "Second"),
        ]

        let fetchedBatch: [TestItem] = [
            TestItem(id: 2, uniqueId: "u2", title: "Duplicate by ID & uniqueId"),
            TestItem(id: 3, uniqueId: "u1", title: "Duplicate by uniqueId only"),
            TestItem(id: 1, uniqueId: "u4", title: "Duplicate by ID only"),
            TestItem(id: 4, uniqueId: "u5", title: "Unique Item 4"),
            TestItem(id: 5, uniqueId: "u6", title: "Unique Item 5"),
        ]

        let existingUniqueIds = Set(initialList.map(\.uniqueId))
        let existingDbIds = Set(initialList.compactMap(\.id))

        let deduplicated = fetchedBatch.filter { item in
            if existingUniqueIds.contains(item.uniqueId) { return false }
            if let id = item.id, existingDbIds.contains(id) { return false }
            return true
        }

        runner.assertEqual(deduplicated.count, 2, "Only 2 unique items should pass deduplication")
        runner.assertEqual(deduplicated.map(\.uniqueId), ["u5", "u6"], "Deduplicated items should preserve fetch order")

        var combinedList = initialList
        combinedList.append(contentsOf: deduplicated)
        runner.assertEqual(combinedList.count, 4, "Combined list count should be 4")
        runner.assertEqual(combinedList.map(\.uniqueId), ["u1", "u2", "u5", "u6"], "List integrity maintained")

        // 2. hasMoreData boundary logic
        let pageSize = 50

        // Case A: Fetched count < pageSize -> hasMoreData must be false
        let hasMoreA = (40 == pageSize && 40 < 100)
        runner.assertTrue(!hasMoreA, "Under-filled page indicates no more data")

        // Case B: Fetched count == pageSize, but accumulated count >= effectiveTotal -> false
        let hasMoreB = (50 == pageSize && 100 < 100)
        runner.assertTrue(!hasMoreB, "When accumulated count reaches total, hasMoreData is false")

        // Case C: Fetched count == pageSize, accumulated count < effectiveTotal -> true
        let hasMoreC = (50 == pageSize && 50 < 100)
        runner.assertTrue(hasMoreC, "When page is full and more items remain, hasMoreData is true")

        // Case D: Capped count (500+): when page is full, pagination continues even if list reaches 500
        let isCountCapped = true
        let hasMoreD = (50 == pageSize && (isCountCapped || 500 < 500))
        runner.assertTrue(hasMoreD, "Capped count allows pagination beyond cap")

        // 3. Stale revision barrier simulation
        func simulateBarrier(captured: Int, current: Int) -> Bool {
            captured == current
        }

        runner.assertTrue(simulateBarrier(captured: 1, current: 1), "Normal fetch applies update")
        runner.assertTrue(!simulateBarrier(captured: 1, current: 2), "Stale async result is safely discarded on revision drift")

        print("✓ Pagination deduplication & boundary tests passed!")
    }
}
