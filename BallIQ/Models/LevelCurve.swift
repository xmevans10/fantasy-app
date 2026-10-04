import Foundation

/// Permanent career progress, separate from competitive rating and day streak.
/// Preserve the original early thresholds; cap later gaps so advancement stays reachable.
enum LevelCurve {
    static let steadySpan = 1900
    static func xpToReach(level: Int) -> Int {
        let level = max(1, level)
        if level <= 10 { return (level - 1) * (level - 1) * 100 }
        return 8100 + (level - 10) * steadySpan
    }

    static func level(forXP xp: Int) -> Int {
        let xp = max(0, xp)
        if xp >= 8100 { return 10 + (xp - 8100) / steadySpan }
        return Int((Double(xp) / 100.0).squareRoot()) + 1
    }

    static func progress(forXP xp: Int) -> (level: Int, intoLevel: Int, span: Int) {
        let xp = max(0, xp)
        let level = level(forXP: xp)
        return (level, xp - xpToReach(level: level),
                xpToReach(level: level + 1) - xpToReach(level: level))
    }

    static let milestones: [(level: Int, title: String)] = [
        (1, "Rookie"), (5, "Regular"), (10, "Starter"),
        (20, "Veteran"), (35, "Captain"), (50, "Club legend")
    ]
    static func title(for level: Int) -> String {
        milestones.last { $0.level <= level }?.title ?? milestones[0].title
    }
    static func nextMilestone(after level: Int) -> (level: Int, title: String)? {
        milestones.first { $0.level > level }
    }
}
