import Foundation

/// Pure logic behind Home's post-completion "come back tomorrow" loop (backlog #2) — pulled out
/// of the view so the midnight math and the "both dailies done" rule are unit-testable without
/// spinning up SwiftUI. Daily puzzles are keyed to the device's *local* calendar day
/// (`PuzzleStore.localDayString` — the pipeline mints `active_date` rows days ahead so every
/// timezone's row exists), so the countdown here targets local midnight, the same boundary the
/// content actually rotates on.
enum HomeDailyLoop {
    /// Whether Home should show the countdown/streak-at-stake state instead of the play cards.
    /// A puzzle that failed to load (`nil`, not `false`) never counts as completed — otherwise a
    /// network blip on one daily would look identical to "you already finished today's games"
    /// and hide the real play card behind a countdown.
    ///
    /// Variadic since Journeyman made it three (M22): a card that says "you're done for today"
    /// over an unplayed ranked daily is simply false, and hard-coding the arity is what made
    /// adding the third daily a two-place change instead of one.
    static func allDailiesComplete(_ completions: Bool?...) -> Bool {
        !completions.isEmpty && completions.allSatisfy { $0 == true }
    }

    /// The next local-midnight boundary strictly after `now` — the instant the daily rolls over
    /// to a fresh puzzle, so this is the number the countdown must hit zero at. `calendar` is
    /// injectable so tests can pin a timezone; production callers take the device default.
    static func nextMidnight(after now: Date, calendar: Calendar = .current) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now.addingTimeInterval(86400)
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

    /// Home's inline streak line. A brand-new install used to open on "0 day streak", which is
    /// the first sentence the app says to someone who has never played — a scoreboard of
    /// nothing. Zero is the one case that should read as an invitation instead of a count.
    static func streakLabel(streak: Int) -> String {
        switch streak {
        case 0:  return String(localized: "Play today to start a streak")
        case 1:  return String(localized: "1 day streak")
        default: return String(localized: "\(streak) day streak")
        }
    }

    /// Streak-at-stake copy: protect an existing streak, or a lighter nudge to start one — a
    /// 0-day streak framed as "protect your 0-day streak" would read as a bug, not a hook.
    static func streakFraming(streak: Int) -> String {
        streak > 0
            ? "Come back tomorrow to protect your \(streak)-day streak"
            : "Come back tomorrow to start your streak"
    }
}
