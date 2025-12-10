import SwiftUI

@Observable
final class AppEnvironment {
    let topBarVM = TopBarViewModel()

    var actions: ClipboardActionService {
        ClipboardActionService()
    }

    var focusView: FocusField = .history {
        didSet {
            EventDispatcher.shared.bypassAllEvents =
                (focusView == .popover || focusView == .search || focusView == .filter)
        }
    }

    // UI 状态
    var isShowDel: Bool = false
    var draggingItemId: Int64?

    init() {}
}
