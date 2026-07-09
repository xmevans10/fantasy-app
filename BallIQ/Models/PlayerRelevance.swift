import Foundation

/// A minimum-relevance floor for gameplay pools (Over/Under rounds, Draft & Spin draft
/// candidates) — keeps marginal/low-production seasons out of arcade formats where the player
/// has no say in which season they're shown, unlike the Create-flow catalog browser, which is
/// deliberately unconstrained (`CatalogQuery`'s own doc comment: "none of these constrain the
/// final puzzle" — a creator browsing for an obscure season on purpose is a different case).
enum PlayerRelevance {
    /// Reuses `DraftSpinSimulator.power` — already a generic 0...1 "how good is this season"
    /// signal across every sport, normalized against `ScoringStat`'s own reference bounds. A
    /// season scoring below this is one where most of its recorded stats sit near the bottom of
    /// their sport's typical range (e.g. a handful of catches for modest yardage), not a
    /// standout performance worth surfacing in an arcade round.
    static let minPower = 0.15

    /// Filters to seasons scoring at least `minPower`, but falls back to the full input when
    /// that would leave fewer than `minimum` candidates — the same graceful-degradation shape
    /// as `Sport.sliceForPosition`, so an already-thin position/sport (soccer DF today) never
    /// goes empty just because every real candidate happens to be a modest season.
    static func filter(_ seasons: [CatalogSeason], sport: Sport, minimum: Int = 3) -> [CatalogSeason] {
        let relevant = seasons.filter { DraftSpinSimulator.power($0, sport: sport) >= minPower }
        return relevant.count >= minimum ? relevant : seasons
    }
}
