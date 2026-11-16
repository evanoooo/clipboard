//
//  ClipboardApp.swift
//  clipboard
//
//  Created by crown on 2025/9/11.
//

import SwiftUI

@main
enum ClipboardEntrypoint {
    static func main() {
        if CommandLine.arguments.contains("--ocr-worker") {
            OCRWorkerProcess.runLoop()
            return
        }
        ClipboardApp.main()
    }
}

struct ClipboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {}
}
