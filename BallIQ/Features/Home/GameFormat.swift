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
    var subtitle: String? = nil

    static let all: [GameFormat] = [
        GameFormat(id: "keep4", name: "K4C4", symbol: "rectangle.stack.fill", isPro: false, isPlayable: true),
        GameFormat(id: "whoami", name: "Who am I?", symbol: "questionmark.circle.fill", isPro: false, isPlayable: true),
        GameFormat(id: "draft", name: "Draft & Spin", symbol: "dice.fill", isPro: false, isPlayable: true, subtitle: "Arcade"),
        GameFormat(id: "overunder", name: "Over / Under", symbol: "arrow.up.arrow.down", isPro: false, isPlayable: true, subtitle: "Arcade"),
        GameFormat(id: "grid", name: "The Grid", symbol: "square.grid.3x3.fill", isPro: true, isPlayable: true),
        GameFormat(id: "versus", name: "Versus", symbol: "person.2.fill", isPro: false, isPlayable: true, subtitle: "Head-to-head")
    ]
}
