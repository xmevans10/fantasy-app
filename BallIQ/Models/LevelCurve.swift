import Foundation

/// XP → level mapping. Level measures longevity, not skill (separate from rating).
/// Thresholds grow quadratically so early levels come fast and later ones slow down.
enum LevelCurve {
    /// Cumulative XP required to *reach* a given level (level 1 = 0 XP).
    static func xpToReach(level: Int) -> Int {
        guard level > 1 else { return 0 }
        return (level - 1) * (level - 1) * 100
    }

    static func level(forXP xp: Int) -> Int {
        guard xp > 0 else { return 1 }
        return Int((Double(xp) / 100.0).squareRoot()) + 1
    }

    /// Progress within the current level: (current level, XP into level, XP span of this level).
    static func progress(forXP xp: Int) -> (level: Int, intoLevel: Int, span: Int) {
        let lvl = level(forXP: xp)
        let floor = xpToReach(level: lvl)
        let ceil = xpToReach(level: lvl + 1)
        return (lvl, xp - floor, max(1, ceil - floor))
    }
}
