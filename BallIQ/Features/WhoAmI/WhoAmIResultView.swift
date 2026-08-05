import SwiftUI

struct WhoAmIResultView: View {
    let puzzle: WhoAmIPuzzle
    let result: WhoAmIScoring.Result
    var rewards: RepositoryContainer.SessionRewards? = nil
    let onDone: () -> Void

    @EnvironmentObject private var container: RepositoryContainer
    @State private var confetti = 0
    /// Resolved from the live catalog at reveal time (WhoAmI content has no photo URL) —
    /// see `WhoAmIAnswerPhoto` for the conservative matching rules. Stays nil (silhouette)
    /// when no confident match exists.
    @State private var answerHeadshot: String?

    private var heroFill: Color { result.solved ? (result.cluesUsed == 1 ? .voltFill : .accentFill) : .surface1 }
    private var heroInk: Color { result.solved ? (result.cluesUsed == 1 ? .onVolt : .onAccent) : .textPrimary }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    scoreHeader.heroReveal(0)
                    if let rewards { RewardsRow(rewards: rewards).heroReveal(1) }
                    answerCard.heroReveal(2)
                    shareRow.heroReveal(3)
                }
                .padding(16)
            }
            doneBar
        }
        .background(Color.appBackground)
        .celebrate(on: $confetti, intensity: result.cluesUsed == 1 ? 90 : 50)
        .onAppear { if result.solved { confetti += 1 } }
        .task {
            let rows = await container.catalog.search(
                CatalogQuery(sport: puzzle.sport, name: puzzle.answer.canonical), limit: 30)
            answerHeadshot = WhoAmIAnswerPhoto.headshot(from: rows, for: puzzle)
        }
    }

    private var scoreHeader: some View {
        VStack(spacing: 4) {
            Text(result.solved ? (result.cluesUsed == 1 ? "FIRST-CLUE GENIUS" : "SOLVED") : "OUT OF GUESSES")
                .font(.heading)
                .foregroundStyle(heroInk.opacity(0.85))

            CountUpText(value: result.total, font: .heroNumber, color: heroInk)

            Text(result.solved ? "SOLVED ON CLUE \(result.cluesUsed)" : "BETTER LUCK TOMORROW")
                .font(.label12)
                .foregroundStyle(heroInk.opacity(0.75))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 16)
        .blockCard(fill: heroFill)
    }

    /// Header-band + headshot-badge shape so the reveal reads as the same "player card"
    /// language every other minigame's result screen already uses. The photo is resolved
    /// live from the catalog (`answerHeadshot`); the badge's own silhouette fallback covers
    /// the no-confident-match case.
    private var answerCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                PlayerHeadshotBadge(headshot: answerHeadshot, tint: Color.onAccent, size: 44, name: puzzle.answer.canonical)
                VStack(alignment: .leading, spacing: 1) {
                    Text("THE ANSWER WAS")
                        .font(.label11)
                        .foregroundStyle(Color.onAccent.opacity(0.75))
                    Text(puzzle.answer.canonical)
                        .font(.custom(FontName.condBlack, size: 20))
                        .foregroundStyle(Color.onAccent)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Color.accentFill)
            Text(puzzle.sport.displayName)
                .font(.label11)
                .foregroundStyle(Color.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.borderInk, lineWidth: 2))
    }

    /// Who Am I? shipped with **no share affordance at all** — a whole daily format contributing
    /// nothing to the loop. It's also the format where a spoiler-free artifact matters most: the
    /// answer is one name, so a result card would ruin the puzzle for every reader.
    ///
    /// The emoji row is clue *spend*, not correctness: ⬛ per clue burned, 🟩 on the one that got
    /// it (nothing green at all means it was never solved). It says how close someone came
    /// without leaking a single thing about who the player was.
    static func emojiClues(result: WhoAmIScoring.Result, clueCount: Int) -> String {
        let used = max(1, min(result.cluesUsed, clueCount))
        return (1...clueCount).map { i -> String in
            if result.solved && i == used { return "🟩" }
            return i <= used ? "⬛" : "⬜"
        }.joined()
    }

    static func shareText(puzzle: WhoAmIPuzzle, result: WhoAmIScoring.Result) -> String {
        let headline = result.solved
            ? "I got today's \(puzzle.sport.displayName) Who Am I? in \(result.cluesUsed) clue\(result.cluesUsed == 1 ? "" : "s")."
            : "Today's \(puzzle.sport.displayName) Who Am I? beat me."
        return ShareMessage.compose(
            headline: headline,
            board: emojiClues(result: result, clueCount: puzzle.clues.count),
            detail: "\(ShareMessage.points(result.total)) pts — no spoilers, go find out who.",
            campaign: "res_whoami_\(puzzle.sport.rawValue)")
    }

    private var shareRow: some View {
        let card = WhoAmIShareCardView(sport: puzzle.sport, clueCount: puzzle.clues.count, result: result)
        return ShareLink(item: Self.shareText(puzzle: puzzle, result: result),
                          preview: SharePreview("My Who Am I? result", image: card.rendered())) {
            Label("SHARE (NO SPOILERS)", systemImage: "square.and.arrow.up").ctaLabel()
        }
        .buttonStyle(PrimePressStyle())
        // ShareLink has no tap callback — a simultaneous gesture is the standard hook.
        .simultaneousGesture(TapGesture().onEnded {
            container.track(.shareTapped, AnalyticsEvent.shareProperties(
                surface: "whoami_result", format: "whoami", artifact: .challengeText,
                extra: ["sport": puzzle.sport.rawValue, "solved": String(result.solved)]))
        })
    }

    private var doneBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.hairline).frame(height: Hairline.width)
            Button(action: onDone) {
                Text("DONE")
                    .font(.heading)
                    .foregroundStyle(Color.accentText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
            }
            .buttonStyle(.plain)
            .padding(16)
            .background(Color.surface)
        }
    }
}

/// Shared rating / XP / streak summary shown on result screens.
struct RewardsRow: View {
    let rewards: RepositoryContainer.SessionRewards

    var body: some View {
        let change = rewards.ratingChange
        let up = change.delta >= 0
        return HStack(spacing: 16) {
            metric(label: String(localized: "Rating"), value: "\(change.new)",
                   accent: "\(up ? "+" : "")\(change.delta)",
                   accentColor: up ? .successText : .dangerText)
            Divider().frame(height: 32)
            metric(label: String(localized: "XP"), value: "+\(rewards.xpEarned)", accent: nil, accentColor: .textMuted)
            Divider().frame(height: 32)
            metric(label: String(localized: "Streak"), value: "\(rewards.newStreak)", accent: nil, accentColor: .textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .cardSurface()
    }

    private func metric(label: String, value: String, accent: String?, accentColor: Color) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.label11).foregroundStyle(Color.textMuted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.hero(20)).foregroundStyle(Color.textPrimary)
                if let accent { Text(accent).font(.label12).foregroundStyle(accentColor) }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Shareable result image for Who Am I? — deliberately takes only `sport`/`clueCount`/`result`,
/// never the puzzle's answer or resolved headshot, so it's structurally impossible for this card
/// to leak who the player was (same rule `shareText`/`emojiClues` already follow).
struct WhoAmIShareCardView: View {
    let sport: Sport
    let clueCount: Int
    let result: WhoAmIScoring.Result

    private var rare: Bool { result.solved && result.cluesUsed == 1 }
    private var ink: Color { rare ? .onVolt : .onAccent }

    var body: some View {
        ShareCardFrame {
            ShareCardHeaderBand(rare: rare) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Wordmark(size: 20)
                        Spacer()
                        Text("\(sport.displayName) · WHO AM I?")
                            .font(.custom(FontName.condBlack, size: 12)).foregroundStyle(ink.opacity(0.85))
                    }
                    Text(result.solved ? (result.cluesUsed == 1 ? "FIRST-CLUE GENIUS" : "SOLVED") : "OUT OF GUESSES")
                        .font(.custom(FontName.condBlack, size: 22)).foregroundStyle(ink)
                    Text("\(result.total)").font(.hero(36)).foregroundStyle(ink)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(WhoAmIResultView.emojiClues(result: result, clueCount: clueCount))
                    .font(.system(size: 30))
                Text(result.solved ? "SOLVED ON CLUE \(result.cluesUsed)" : "BETTER LUCK TOMORROW")
                    .font(.custom(FontName.condBold, size: 13))
                    .foregroundStyle(Color.textMuted)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface1)

            ShareCardFooter()
        }
    }

    @MainActor
    func rendered(scale: CGFloat = 3) -> Image { renderedForShare(scale: scale) }
}
