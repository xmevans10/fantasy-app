import SwiftUI

/// The angle a Who Am I? clue comes from — the taxonomy the clue pipeline actually selects
/// against (`tools/ingest/whoami_clues.py`'s `Dimension.family`), ported to the client so the
/// board can colour its clue chips by something that means anything.
///
/// **Why this and not `ClueKind`.** `ClueKind` is a wire-compatibility contract, not a
/// taxonomy: the pipeline maps 32 dimensions onto its six fixed values so already-shipped App
/// Store builds can still decode, and the mapping is lopsided. Measured against all 916 live
/// boards on 2026-08-26, keying chip colour off `kind` puts three or more identical chips on 70
/// boards and five identical chips on `nfl-whoami-barry-sanders`. `family` is capped at two per
/// board by `select_clues`, so it never does that — 0 of 916.
///
/// **`family` is deliberately NOT on the wire.** It is derived here from `Clue.dimension`, with
/// `Clue.kind` as the fallback for content minted before dimensions existed (52 of 916 boards,
/// every one of them the identical legacy six). Adding a `family` field to the JSON would mean
/// touching the clue contract, which is the thing the pipeline bends over backwards to avoid.
///
/// `byDimension` is a hand-port of the Python registry and would drift silently on the next
/// dimension added — `test_clue_families_match_the_swift_map` in
/// `tools/ingest/tests/test_whoami_clues.py` reads this file back and fails if it does. That's
/// the same posture as `test_point_multipliers_match_the_swift_table`.
enum ClueFamily: String, CaseIterable {
    case career, bio, draft, team, production, story

    /// The family a clue belongs to. Never fails: an unrecognised dimension (a new one the
    /// pipeline shipped before this map was updated) falls through to the `kind` mapping, which
    /// is total.
    static func of(_ clue: WhoAmIPuzzle.Clue) -> ClueFamily {
        if let dimension = clue.dimension, let family = byDimension[dimension] { return family }
        return fallback(clue.kind)
    }

    /// Every legacy `ClueKind`, mapped to the family its own dimension carries in the registry.
    /// `jersey` lands on `.bio` because that's where the `jersey` dimension actually sits.
    private static func fallback(_ kind: ClueKind) -> ClueFamily {
        switch kind {
        case .era:      return .career
        case .position: return .bio
        case .jersey:   return .bio
        case .teams:    return .team
        case .statLine: return .production
        case .fact:     return .story
        }
    }

    /// All 32 dimensions in `whoami_clues.DIMENSIONS`, keyed to their `family` column.
    private static let byDimension: [String: ClueFamily] = [
        "era": .career, "longevity": .career, "debut": .career, "finale": .career,
        "position": .bio, "weight": .bio, "height": .bio, "born": .bio,
        "ageAtDebut": .bio, "frame": .bio, "jersey": .bio, "college": .bio,
        "conference": .bio,
        "draftClass": .draft, "undrafted": .draft, "draftRound": .draft,
        "draftTeam": .draft, "draftPick": .draft,
        "league": .team, "nationality": .team, "franchiseCount": .team, "oneTeam": .team,
        "firstTeam": .team, "lastTeam": .team, "teams": .team,
        "peakYear": .production, "bestSeason": .production, "statLine": .production,
        "accolades": .story, "initials": .story, "fact": .story, "nickname": .story,
    ]

    /// Chip fill. Existing `Theme.swift` role tokens only — DESIGN.md keeps the palette small,
    /// and six new hex constants would be six new things to re-audit for contrast.
    ///
    /// **`dangerFill`/`dangerText` are deliberately excluded**, and no family may ever take
    /// them: the wrong-guess counter directly below this list is `Color.dangerText`, and red on
    /// a clue chip would read as "you got that one wrong".
    var chipFill: Color {
        switch self {
        case .career:     return .accentFill    // electric blue — the dominant
        case .bio:        return .proFill       // purple
        case .draft:      return .goldFill      // trophy gold
        case .team:       return .successFill   // green
        case .production: return .warningFill   // hot orange
        case .story:      return .voltFill      // lime — the sharp accent
        }
    }

    /// Legible ink on `chipFill`. Each is the `on*` token Theme.swift already pairs with that
    /// fill, so contrast is inherited rather than re-guessed.
    var onChip: Color {
        switch self {
        case .career:     return .onAccent
        case .bio:        return .onPro
        case .draft:      return .onGold
        case .team:       return .onSuccess
        case .production: return .onWarning
        case .story:      return .onVolt
        }
    }
}
