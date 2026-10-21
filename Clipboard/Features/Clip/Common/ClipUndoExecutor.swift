//
//  ClipUndoExecutor.swift
//  Clipboard
//
//  Shared undo execution logic between Card and Floating views.
//

import AppKit
import Foundation

@MainActor
enum ClipUndoExecutor {
    static func performUndo() {
        guard ClipUndoStore.shared.canUndo else {
            NSSound.beep()
            return
        }

        Task { @MainActor in
            let outcome = await PasteDataStore.main.undoLastDelete()
            if outcome.failedCount > 0 {
                HUDManager.shared.show(
                    icon: NSImage(
                        systemSymbolName: "exclamationmark.triangle",
                        accessibilityDescription: nil
                    ),
                    text: String(
                        localized: .undoDeletePartiallyFailed(
                            outcome.restoredCount,
                            outcome.failedCount
                        )
                    )
                )
                return
            }
            guard outcome.restoredCount > 0 else { return }
            HUDManager.shared.show(
                icon: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil),
                text: String(localized: .undoDeleteSucceeded(outcome.restoredCount))
            )
        }
    }
}
