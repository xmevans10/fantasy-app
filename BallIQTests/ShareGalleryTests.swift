import XCTest
import SwiftUI
@testable import BallIQ

/// Renders what actually leaves the app, so it can be judged against the only bar that matters:
/// *would a stranger seeing this in a group chat understand it and want to play?*
///
/// Same hosted-`ImageRenderer` pattern as `ScoringGalleryTests`/`GridBoardGalleryTests`; each PNG
/// path is printed as `SHARE_GALLERY:`. Two galleries, because the app emits two kinds of thing:
///
///  - **`share_chat.png`** — every format's real `shareText`, verbatim, in chat bubbles. The text
///    IS the artifact for five of the seven surfaces, so a PNG of a card would be checking the
///    wrong object. The strings are pulled from the same functions the ShareLinks call, not
///    retyped, so this can't drift from what ships.
///  - **`challenge_banner_*.png`** — the head-to-head verdict, which is new UI and has three
///    states that must each read correctly (including the losing one, which is the state a
///    challenge recipient hits most often).
@MainActor
final class ShareGalleryTests: XCTestCase {

    private let now = ISO8601DateFormatter().date(from: "2026-07-27T12:00:00Z")!

    private func write(_ view: some View, _ name: String, width: CGFloat = 390) throws {
        let renderer = ImageRenderer(content: view.frame(width: width))
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage, "\(name) rendered nothing")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("SHARE_GALLERY:\(url.path)")
    }

    // MARK: - Fixtures (real content shapes, not placeholder strings)

    private func keep4Puzzle() -> Keep4Puzzle {
        let names = ["J. Allen 2022", "P. Mahomes 2018", "L. Jackson 2019", "J. Burrow 2022",
                     "D. Carr 2016", "K. Cousins 2019", "R. Tannehill 2019", "M. Ryan 2016"]
        let players = names.enumerated().map { i, name in
            PlayerSeason(id: "p\(i)", name: name, teamAbbr: "TM",
                         seasonYear: 2016 + i, stats: [], grade: Double(400 - i * 10))
        }
        return Keep4Puzzle(id: "k", theme: "Peak QB seasons", sport: .nfl, players: players)
    }

    private func keep4Result(_ puzzle: Keep4Puzzle) -> Keep4Scoring.Result {
        var placement: [String: Pile] = [:]
        for i in 0..<4 { placement["p\(i)"] = .keep }
        for i in 4..<8 { placement["p\(i)"] = .cut }
        placement["p0"] = .cut          // one wrong pair, so the strip isn't all-green
        placement["p4"] = .keep
        return Keep4Scoring.score(puzzle: puzzle, placement: placement)
    }

    private func whoAmIPuzzle() -> WhoAmIPuzzle {
        WhoAmIPuzzle(id: "w", sport: .nba,
                     clues: (1...6).map { .init(order: $0, kind: .fact, text: "clue \($0)") },
                     answer: .init(canonical: "Allen Iverson", aliases: []))
    }

    /// Every string this app can put in someone's clipboard, in one place.
    private var everyShareText: [(String, String)] {
        let k4 = keep4Puzzle()
        let solvedGrid = [0: "A", 1: "B", 3: "C", 4: "D", 5: "E", 7: "F", 8: "G"]
        return [
            ("Grid · daily (the challenge)",
             GridResultView.shareText(sport: .nfl, score: 1240, solved: solvedGrid,
                                      date: now, challenger: "alex", now: now)),
            ("Grid · immaculate",
             GridResultView.shareText(sport: .baseball, score: 2400,
                                      solved: Dictionary(uniqueKeysWithValues: (0..<9).map { ($0, "P\($0)") }),
                                      date: now, challenger: "alex", now: now)),
            ("Grid · practice board (no dare)",
             GridResultView.shareText(sport: .soccer, score: 300, solved: [0: "A", 4: "B"],
                                      date: now, isDaily: false, now: now)),
            ("Keep 4 · daily",
             Keep4ResultView.shareText(puzzle: k4, result: keep4Result(k4),
                                       date: now, challenger: "alex", now: now)),
            ("Who Am I? · solved on clue 3",
             WhoAmIResultView.shareText(puzzle: whoAmIPuzzle(),
                                        result: WhoAmIScoring.score(cluesUsed: 3, wrongGuesses: 0,
                                                                    solved: true))),
            ("Who Am I? · never got it",
             WhoAmIResultView.shareText(puzzle: whoAmIPuzzle(),
                                        result: WhoAmIScoring.score(cluesUsed: 6, wrongGuesses: 2,
                                                                    solved: false))),
            ("Over/Under · streak brag",
             OverUnderResultView.shareText(sport: .nba, score: 2300, correctCount: 14,
                                           beatHighScore: true)),
            ("Community puzzle invite",
             SharablePuzzle(whoAmI: whoAmIPuzzle()).shareText),
        ]
    }

    // MARK: - The galleries

    func testRenderEveryShareTextAsItWouldArrive() throws {
        try write(ChatMockup(messages: everyShareText), "share_chat", width: 420)
    }

    func testRenderChallengeBannerInEveryOutcome() throws {
        let challenge = ChallengeLink(format: .grid, sport: .nfl, day: "2026-07-27",
                                      hits: 7, outOf: 9, score: 1240, challenger: "alex")
        // The three verdicts, plus the two tiebreak wordings that only appear on equal hits.
        let cases: [(String, Int, Int)] = [
            ("win", 8, 1600),
            ("loss", 5, 900),
            ("tie", 7, 1240),
            ("win_on_points", 7, 1300),
            ("loss_on_points", 7, 1100),
        ]
        for (name, hits, score) in cases {
            try write(ChallengeResultBanner(challenge: challenge, hits: hits, score: score)
                        .padding(16).background(Color.appBackground),
                      "challenge_banner_\(name)")
        }
        // An anonymous challenger (signed-out sharer) must not render "nil went 7/9".
        let anon = ChallengeLink(format: .keep4, sport: .soccer, day: "2026-07-27",
                                 hits: 6, outOf: 8, score: 1500, challenger: nil)
        try write(ChallengeResultBanner(challenge: anon, hits: 4, score: 1000)
                    .padding(16).background(Color.appBackground),
                  "challenge_banner_anonymous")
        // The longest username the profile validator allows, against the widest board — the
        // layout most likely to truncate (AGENTS.md §5: check the outlier, not the happy path).
        let longName = ChallengeLink(format: .grid, sport: .baseball, day: "2026-07-27",
                                     hits: 9, outOf: 9, score: 2400,
                                     challenger: "bartholomew_j")
        try write(ChallengeResultBanner(challenge: longName, hits: 3, score: 400)
                    .padding(16).background(Color.appBackground),
                  "challenge_banner_long_name")
    }

    /// The whole result screen with a challenge attached, not just the banner in isolation —
    /// what a challenge recipient actually lands on, with the head-to-head sitting above the
    /// leaderboard row (the ordering `GridResultView` deliberately swaps in for this case).
    ///
    /// Rendered rather than driven on-simulator because `-screenshotGridResult` also flips
    /// `DebugLaunch.autoOpenGrid`, which makes HomeView present its own Grid cover and races the
    /// deep link's — neither wins and you land back on Home. The link's own resolution *is*
    /// verified live (it opens today's real NFL board); this covers the frame after it.
    func testRenderChallengeResultScreen() async throws {
        let puzzle = GridPuzzle(
            sport: .nfl,
            rows: [.init(kind: .team, label: "KC"), .init(kind: .team, label: "DAL"),
                   .init(kind: .team, label: "SEA")],
            cols: [.init(kind: .decade, label: "1980s"), .init(kind: .decade, label: "1990s"),
                   .init(kind: .decade, label: "2010s")],
            cells: (0..<9).map { i in
                .init(validAnswerIds: ["id-\(i)"], validAnswerNames: ["Player \(i)"],
                      rarityStars: (i % 5) + 1)
            },
            archetype: "teams-x-decades")
        let solved = [0: "Joe Montana", 1: "Priest Holmes", 3: "Troy Aikman",
                      4: "Emmitt Smith", 6: "Steve Largent"]
        let challenge = ChallengeLink(format: .grid, sport: .nfl, day: "2026-07-27",
                                      hits: 7, outOf: 9, score: 1240, challenger: "alex")
        let view = GridResultView(sport: .nfl, score: 820, correctCount: solved.count,
                                  puzzle: puzzle, solved: solved, isDaily: true,
                                  challenge: challenge, onDone: {})
        // Hosted in a real window rather than `ImageRenderer`, because every card on this screen
        // enters through `heroReveal` (opacity 0 → 1 on a stagger) and `ImageRenderer` captures
        // the pre-animation frame — a first attempt produced an empty page with only the bottom
        // bar on it. Same reason `GridBoardGalleryTests` hosts.
        let window = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first,
            "no window in hosted test app")
        let host = UIHostingController(
            rootView: view.environmentObject(RepositoryContainer.make()))
        let previous = window.rootViewController
        window.rootViewController = host
        defer { window.rootViewController = previous }

        for _ in 0..<3 {
            await Task.yield()
            try await Task.sleep(nanoseconds: 300_000_000)
        }

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("live_challenge_result_screen.png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("SHARE_GALLERY:\(url.path)")
    }

    /// The image artifacts that still exist, for contrast with the text ones above.
    /// `ShareCardView` is included deliberately: it is the answer key, and seeing it next to the
    /// spoiler-free strip that replaced it in the payload is the clearest statement of why.
    func testRenderSurvivingImageCards() throws {
        let k4 = keep4Puzzle()
        var placement: [String: Pile] = [:]
        for i in 0..<4 { placement["p\(i)"] = .keep }
        for i in 4..<8 { placement["p\(i)"] = .cut }
        try write(ShareCardView(puzzle: k4, placement: placement, result: keep4Result(k4)),
                  "card_keep4_result", width: 340)
        try write(PuzzlePreviewCardView(puzzle: SharablePuzzle(keep4: k4)),
                  "card_puzzle_invite", width: 340)
    }
}

/// A stand-in for the place these strings actually land. Not decoration: judging "would a
/// stranger want to play this" from a Swift string literal in a diff is exactly how the current
/// artifacts shipped — a `balliq://` URL looks fine in code and is dead on a phone.
private struct ChatMockup: View {
    let messages: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("WHAT ACTUALLY LEAVES THE APP")
                .font(.custom(FontName.condBlack, size: 15))
                .foregroundStyle(Color.textPrimary)
            ForEach(messages, id: \.0) { label, text in
                VStack(alignment: .leading, spacing: 6) {
                    Text(label.uppercased())
                        .font(.label11)
                        .foregroundStyle(Color.textMuted)
                    Text(text)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.onAccent)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Color.accentFill)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appBackground)
    }
}
