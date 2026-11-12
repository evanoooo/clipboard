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

    private init() {}

    func start() {
        guard timer == nil else { return }
        currentTime = Date()
        tick.send(currentTime)
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard WindowManager.shared.isVisible else {
                    self.stop()
                    return
                }
                self.currentTime = Date()
                self.tick.send(self.currentTime)
            }
        }
        timer.tolerance = 3.0
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
