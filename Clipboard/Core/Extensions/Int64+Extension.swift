//
//  Int64+Extension.swift
//  Clipboard
//
//  Created by crown on 2025/9/23.
//

import AppKit

extension Int64 {
    func timeAgo(relativeTo currentDate: Date) -> String {
        let diffDate = NSCalendar.current.dateComponents(
            [.month, .day, .hour, .minute],
            from: Date(timeIntervalSince1970: TimeInterval(self)),
            to: currentDate
        )
        let seconds = currentDate.timeIntervalSince(
            Date(timeIntervalSince1970: TimeInterval(self))
        )
        if seconds >= 30, seconds < 60 {
            return String(localized: .recentHalfMinute)
        }
        if let month = diffDate.month, month > 0 {
            return String(localized: .monthAgo(month))
        } else if let day = diffDate.day, day > 0 {
            return String(localized: .dayAgo(day))
        } else if let hour = diffDate.hour, hour > 0 {
            return String(localized: .hourAgo(hour))
        } else if let minute = diffDate.minute, minute > 0 {
            return String(localized: .minuteAgo(minute))
        } else {
            return String(localized: .currentTime)
        }
    }
}
