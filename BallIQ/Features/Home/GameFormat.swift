import SwiftUI

/// The launch game formats shown in the Home formats grid.
struct GameFormat: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let isPro: Bool
    /// Whether this format is playable in the current slice.
    let isPlayable: Bool
    /// Grid card subtitle. Defaults to "Daily"/"Pro only"/"Soon" by playability if unset —
    /// only needed when a playable format isn't a daily puzzle (e.g. Versus).
    /// `LocalizedStringKey` (not `String`) so both this and the fallback default in
    /// `FormatGridItem` extract into Localizable.xcstrings.
    var subtitle: LocalizedStringKey? = nil
    /// Cartridge color — each format tile is its own bold block (2026-07-17 "too much
    /// white" pass), reusing the puzzle-type colors already established elsewhere (K4C4
    /// blue and Who Am I? volt match their `DailyGameCard` type chips).
    var tint: Color = .accentFill
    var onTint: Color = .onAccent

    static let all: [GameFormat] = [
        // "Daily + archive": these two tiles open the format hub (BrowseView pinned),
        // not just today's puzzle — the subtitle should promise what the tap delivers.
        GameFormat(id: "keep4", name: "K4C4", symbol: "rectangle.stack.fill", isPro: false, isPlayable: true,
                   subtitle: "Daily + archive", tint: .accentFill, onTint: .onAccent),
        GameFormat(id: "whoami", name: "Who am I?", symbol: "questionmark.circle.fill", isPro: false, isPlayable: true,
                   subtitle: "Daily + archive", tint: .voltFill, onTint: .onVolt),
        GameFormat(id: "draft", name: "Draft & Spin", symbol: "dice.fill", isPro: false, isPlayable: true, subtitle: "Arcade",
                   tint: .warningFill, onTint: .onWarning),
        // No explicit subtitle: Over/Under's first run each UTC day is ranked (see
        // OverUnderGameView's `ranked` flag), so it takes the "Daily · Ranked" fallback —
        // the old "Arcade" label hid that it moves rating (user feedback 2026-07-17).
        GameFormat(id: "overunder", name: "Over / Under", symbol: "arrow.up.arrow.down", isPro: false, isPlayable: true,
                   tint: .dangerFill, onTint: .onDanger),
        GameFormat(id: "grid", name: "The Grid", symbol: "square.grid.3x3.fill", isPro: true, isPlayable: true,
                   tint: .proFill, onTint: .onPro),
        GameFormat(id: "versus", name: "Versus", symbol: "person.2.fill", isPro: false, isPlayable: true, subtitle: "Head-to-head",
                   tint: .ink, onTint: .surface0)
    ]

    /// The "while you wait" arcade nudge on Home's post-completion state — Draft & Spin,
    /// Over/Under, and The Grid are pure arcade (no daily obligation), unlike K4C4/Who Am I
    /// (already played out for today) and Versus (a separate social loop, not filler).
    static let arcade: [GameFormat] = all.filter { ["draft", "overunder", "grid"].contains($0.id) }
}
