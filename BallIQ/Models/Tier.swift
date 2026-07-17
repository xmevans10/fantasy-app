import SwiftUI

/// Rating tiers from the brief.
enum Tier: String, CaseIterable {
    case bronze, silver, gold, platinum, diamond, legend

    var name: String { rawValue.capitalized }

    var range: ClosedRange<Int> {
        switch self {
        case .bronze:   return 0...999
        case .silver:   return 1000...1199
        case .gold:     return 1200...1399
        case .platinum: return 1400...1599
        case .diamond:  return 1600...1799
        case .legend:   return 1800...10000
        }
    }

    var symbol: String {
        switch self {
        case .legend: return "crown.fill"
        case .diamond: return "diamond.fill"
        default: return "shield.fill"
        }
    }

    var color: Color {
        switch self {
        case .bronze:   return Color(hex: 0xA1672F)
        case .silver:   return Color(hex: 0x9BA3AD)
        case .gold:     return Color(hex: 0xE0A92E)
        case .platinum: return Color(hex: 0x4FB0C6)
        case .diamond:  return Color(hex: 0x36C7E0)
        case .legend:   return Color.proPurple
        }
    }

    /// Legible ink on this tier's `color` fill. Static (not the dynamic `.ink`) because the
    /// tier fills themselves don't change between light and dark mode.
    var onColor: Color {
        switch self {
        case .bronze, .legend: return .white
        default:               return Color(hex: 0x15120B)
        }
    }

    static func forRating(_ rating: Int) -> Tier {
        allCases.first { $0.range.contains(rating) } ?? .bronze
    }

    /// Rating at which the next tier begins, or nil if already Legend.
    var nextTierFloor: Int? {
        switch self {
        case .legend: return nil
        default: return range.upperBound + 1
        }
    }
}
