//
//  TimeManager.swift
//  Clipboard
//
//  Created by crown on 2025/10/6.
//

import Combine
import Foundation

final class TimeManager {
    var currentTime = Date()
    private var timer: Timer?

    let tick = PassthroughSubject<Date, Never>()

    static let shared = TimeManager()

    private init() {
        startTimer()
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard WindowManager.shared.isVisible else { return }
                self.currentTime = Date()
                self.tick.send(self.currentTime)
            }
        }
        timer.tolerance = 3.0
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
