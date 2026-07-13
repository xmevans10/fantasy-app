import Foundation

/// Pure logic behind Home's post-completion "come back tomorrow" loop (backlog #2) — pulled out
/// of the view so the UTC-midnight math and the "both dailies done" rule are unit-testable
/// without spinning up SwiftUI. Daily puzzles are minted per UTC day (`PuzzleStore
/// .todayUTCString`), not local midnight, so the countdown here has to target the same boundary
/// the content actually rotates on.
enum HomeDailyLoop {
    /// Whether Home should show the countdown/streak-at-stake state instead of the two play
    /// cards. A puzzle that failed to load (`nil`, not `false`) never counts as completed —
    /// otherwise a network blip on one daily would look identical to "you already finished
    /// today's games" and hide the real play card behind a countdown.
    static func bothDailiesComplete(keep4Completed: Bool?, whoAmICompleted: Bool?) -> Bool {
        keep4Completed == true && whoAmICompleted == true
    }

    /// The next UTC-midnight boundary strictly after `now` — the instant a fresh daily puzzle
    /// is minted server-side, so this is the number the countdown must hit zero at.
    static func nextUTCMidnight(after now: Date) -> Date {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let startOfToday = utcCalendar.startOfDay(for: now)
        return utcCalendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now.addingTimeInterval(86400)
    }

    /// "HH:MM:SS" remaining until `target`, clamped at zero — a render that lands exactly on
    /// rollover (or a `target` that's already passed, e.g. a stale `TimelineView` tick) should
    /// read 00:00:00 for a frame rather than counting into negative territory.
    static func countdownString(now: Date, target: Date) -> String {
        let remaining = max(0, Int(target.timeIntervalSince(now).rounded(.down)))
        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60
        let seconds = remaining % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    /// Streak-at-stake copy: protect an existing streak, or a lighter nudge to start one — a
    /// 0-day streak framed as "protect your 0-day streak" would read as a bug, not a hook.
    static func streakFraming(streak: Int) -> String {
        streak > 0
            ? "Come back tomorrow to protect your \(streak)-day streak"
            : "Come back tomorrow to start your streak"
    }
}
