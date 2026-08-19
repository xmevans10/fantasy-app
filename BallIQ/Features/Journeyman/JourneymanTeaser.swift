import Foundation

/// The **fallback** teaser for a Journeyman archive card — a joke about the *shape* of a career,
/// for boards whose content carries no minted `teaser`.
///
/// The good line comes from the pipeline (`tools/ingest/journeyman.py`'s `build_teaser`), which
/// knows the subject and can say something about *them*: "Part of the 2003 draft class — and no
/// forwarding address." This can't, and structurally never will — see below — so it jokes about
/// the path instead. Both exist because `teaser` is optional in the wire contract, and a card
/// with no title is not an option.
///
/// **It never sees the answer, and that is structural rather than a promise.** Everything here
/// is derived from `stints` — how many clubs, how long each spell ran, whether the player went
/// back somewhere — so there is no path by which a teaser can leak the player's name, and no way
/// for a future edit to introduce one without changing the signature. The same rule
/// `WhoAmIResultView.emojiClues` and every `shareText` in the app follow.
///
/// Nor does it leak anything the card wasn't already showing: the club count sits in the
/// subtitle right underneath ("4 clubs · archive"), and no line here names a club, a year, or an
/// era. It is a hint about the *kind* of career, which is the joke the format is built on.
///
/// Deterministic per puzzle, seeded off the id via `SeededGenerator.stableHash` — a card must
/// read the same on every launch and on every device, so `String.hashValue` (randomized per
/// process) would be exactly wrong here.
enum JourneymanTeaser {

    /// The teaser for one board. Pure; locked by tests.
    static func line(for puzzle: JourneymanPuzzle) -> String {
        let lines = pool(for: puzzle)
        guard !lines.isEmpty else { return lines2Club[0] }
        // The id, not the index: a board's teaser must survive the archive being re-sorted,
        // re-filtered, or a new puzzle landing above it.
        let index = Int(SeededGenerator.stableHash(puzzle.id) % UInt64(lines.count))
        return lines[index]
    }

    /// Which set of jokes this career qualifies for, most specific first. Order matters: a
    /// six-club career that also went back somewhere is funnier as a journeyman than as a
    /// homecoming, and a truncated path has to say so or the count under it reads as a lie.
    private static func pool(for puzzle: JourneymanPuzzle) -> [String] {
        let stints = puzzle.stints
        if puzzle.truncated == true { return linesTruncated }
        if stints.count >= 6 { return linesJourneyman }
        if let longest = stints.map(\.seasonCount).max(), longest >= 10, stints.count <= 3 {
            return linesLoyal
        }
        if returnedSomewhere(stints) { return linesReturn }
        if stints.filter({ $0.seasonCount == 1 }).count >= 2 { return linesCupOfCoffee }
        if stints.count >= 4 { return linesWanderer }
        return lines2Club
    }

    /// True when the same club appears more than once — the format's best material, and worth
    /// its own joke. Compares the club NAME for the same reason the pipeline's run-length
    /// encoding does: one franchise reaches the catalog under several codes.
    static func returnedSomewhere(_ stints: [JourneymanPuzzle.Stint]) -> Bool {
        let names = stints.map(\.teamName)
        return Set(names).count < names.count
    }

    // MARK: - The lines
    //
    // Pronoun-free by construction, like the clue library upstream: this catalog serves men's
    // and women's sports, and a teaser that guesses wrong about a subject is worse than a
    // teaser that never brings it up.

    private static let linesJourneyman = [
        String(localized: "Knew every baggage carousel"),
        String(localized: "Kept a moving company in business"),
        String(localized: "Never quite finished a lease"),
        String(localized: "Collected jerseys, not rings"),
    ]

    private static let linesWanderer = [
        String(localized: "Packed light, just in case"),
        String(localized: "A well-travelled résumé"),
        String(localized: "Always someone's new signing"),
    ]

    private static let linesReturn = [
        String(localized: "Left. Thought about it. Came back."),
        String(localized: "Absence made the heart grow fonder"),
        String(localized: "You can go home again, apparently"),
    ]

    private static let linesCupOfCoffee = [
        String(localized: "Several very brief hellos"),
        String(localized: "Some of these barely count"),
        String(localized: "Blink and you'd have missed a stop"),
    ]

    private static let linesLoyal = [
        String(localized: "Loyal, right up until the end"),
        String(localized: "Practically had a mortgage there"),
        String(localized: "One club, and then one goodbye"),
    ]

    private static let linesTruncated = [
        String(localized: "There were more. We ran out of room."),
        String(localized: "This is only the recent stuff"),
    ]

    /// The fallback, and the two-or-three-club default.
    private static let lines2Club = [
        String(localized: "Not much of a journeyman, this one"),
        String(localized: "A tidy little career"),
        String(localized: "Made a move, made it count"),
    ]
}
