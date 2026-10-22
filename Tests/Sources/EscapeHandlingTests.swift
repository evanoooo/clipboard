//
//  EscapeHandlingTests.swift
//  Tests
//
//  Unit tests for Esc key double-tap fast-dismiss logic and dismiss idempotency.
//

import Foundation

struct DoubleTapEscapeDetector {
    private(set) var lastEscapeTime: TimeInterval = 0
    let threshold: TimeInterval

    init(threshold: TimeInterval = 0.35) {
        self.threshold = threshold
    }

    mutating func registerEscape(at currentTime: TimeInterval) -> Bool {
        let elapsed = currentTime - lastEscapeTime
        let isDoubleTap = lastEscapeTime > 0 && elapsed >= 0 && elapsed < threshold
        lastEscapeTime = currentTime
        return isDoubleTap
    }

    mutating func reset() {
        lastEscapeTime = 0
    }
}

@MainActor
final class MockDismissableWindowController {
    enum State {
        case hidden
        case showing
        case visible
        case dismissing
    }

    private(set) var state: State = .hidden
    private(set) var dismissCallCount = 0
    private(set) var showCallCount = 0

    func show() {
        showCallCount += 1
        state = .visible
    }

    func dismiss(completion: (@MainActor () -> Void)? = nil) {
        guard state == .visible else { return }
        dismissCallCount += 1
        state = .dismissing
        state = .hidden
        completion?()
    }

    func toggle() {
        if state == .visible {
            dismiss()
        } else if state == .hidden {
            show()
        }
    }
}

@MainActor
final class EscapeHandlingTests {
    static func run(runner: TestRunner.Type) {
        print("\n--- Testing Escape Key Double-Tap & Dismiss Idempotency ---")

        testDoubleTapDetection(runner: runner)
        testDoubleTapThresholdBoundary(runner: runner)
        testDoubleTapResetOnAppear(runner: runner)
        testDismissIdempotency(runner: runner)
        testDoubleTapEscFlow(runner: runner)

        print("✓ Escape Key Double-Tap & Dismiss tests passed!")
    }

    private static func testDoubleTapDetection(runner: TestRunner.Type) {
        var detector = DoubleTapEscapeDetector(threshold: 0.35)

        // 1. First tap at t = 1.0 -> should not be double tap
        let tap1 = detector.registerEscape(at: 1.0)
        runner.assertFalse(tap1, "First tap must not trigger double tap")

        // 2. Second tap at t = 1.15 (150ms later) -> should be double tap
        let tap2 = detector.registerEscape(at: 1.15)
        runner.assertTrue(tap2, "Tap within 150ms (< 350ms) must trigger double tap")

        // 3. Third tap at t = 2.0 (850ms later) -> should reset to single tap
        let tap3 = detector.registerEscape(at: 2.0)
        runner.assertFalse(tap3, "Tap after 850ms (> 350ms) must not trigger double tap")

        // 4. Fourth tap at t = 2.20 (200ms later) -> double tap again
        let tap4 = detector.registerEscape(at: 2.20)
        runner.assertTrue(tap4, "Second quick tap must trigger double tap")
    }

    private static func testDoubleTapThresholdBoundary(runner: TestRunner.Type) {
        var detector = DoubleTapEscapeDetector(threshold: 0.35)

        _ = detector.registerEscape(at: 10.0)
        // At 400ms (> 350ms) -> false
        let beyondBoundary = detector.registerEscape(at: 10.40)
        runner.assertFalse(beyondBoundary, "Tap at 400ms (> 350ms) should be considered separate")

        _ = detector.registerEscape(at: 20.0)
        // Within 250ms (< 350ms) -> true
        let withinBoundary = detector.registerEscape(at: 20.25)
        runner.assertTrue(withinBoundary, "Tap within 250ms (< 350ms) should be considered double-tap")
    }

    private static func testDoubleTapResetOnAppear(runner: TestRunner.Type) {
        var detector = DoubleTapEscapeDetector(threshold: 0.35)

        _ = detector.registerEscape(at: 100.0)
        // Window reappears and resets timestamp
        detector.reset()

        // Next tap at t = 100.1 (even though 100ms has elapsed since previous session)
        let tap = detector.registerEscape(at: 100.1)
        runner.assertFalse(tap, "Reset must prevent stale timestamps from previous sessions triggering double tap")
    }

    private static func testDismissIdempotency(runner: TestRunner.Type) {
        let mock = MockDismissableWindowController()
        mock.show()
        runner.assertTrue(mock.state == .visible, "Window should be visible initially")

        // First dismiss
        mock.dismiss()
        runner.assertEqual(mock.dismissCallCount, 1, "Dismiss should execute once")

        // Second dismiss during transition (e.g. fast double Esc key)
        mock.dismiss()
        runner.assertEqual(mock.dismissCallCount, 1, "Subsequent dismiss calls during transition must be idempotent no-op")
    }

    private static func testDoubleTapEscFlow(runner: TestRunner.Type) {
        var detector = DoubleTapEscapeDetector(threshold: 0.35)
        let mock = MockDismissableWindowController()
        mock.show()

        var didForceDismiss = false

        // Simulate user rapidly double tapping Esc
        let t1 = 50.0
        let isDouble1 = detector.registerEscape(at: t1)
        if isDouble1 {
            didForceDismiss = true
            mock.dismiss()
        } else {
            // normal layer dismiss
            mock.dismiss()
        }

        let t2 = 50.12 // 120ms later
        let isDouble2 = detector.registerEscape(at: t2)
        if isDouble2 {
            didForceDismiss = true
            mock.dismiss()
        }

        runner.assertTrue(didForceDismiss, "Fast double tap flow must trigger force dismiss")
        runner.assertEqual(mock.dismissCallCount, 1, "Even with fast double tap, window controller dismiss is invoked cleanly without double animation or re-showing")
    }
}
