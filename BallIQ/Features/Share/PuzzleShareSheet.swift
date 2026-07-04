import SwiftUI

/// A puzzle reduced to what's safe and enticing to share *before* anyone has played it
/// (M13 pre-play sharing): no answers, no grades — just the pitch and the deep link.
struct SharablePuzzle: Identifiable, Equatable {
    let id: String            // puzzle id → balliq://play/<id>
    let formatName: String
    let sport: Sport
    let title: String
    /// Grading badge (K4C4 only) — an "Author's Call" share reads differently from a PPR daily.
    let scoring: ScoringKind?
    /// Grain badge (K4C4 only) — nil for Who Am I?, which has no grain concept.
    let grain: PuzzleGrain?
    let subtitle: String

    var url: URL { URL(string: "balliq://play/\(id)")! }

    init(keep4 puzzle: Keep4Puzzle) {
        id = puzzle.id
        formatName = "K4C4"
        sport = puzzle.sport
        title = puzzle.theme
        scoring = puzzle.scoringKind()
        grain = puzzle.puzzleGrain()
        subtitle = "\(puzzle.players.count) \(grain!.countNoun) — can you sort them?"
    }

    /// Deliberately anonymous — a shared Who Am I? must never leak the answer.
    init(whoAmI puzzle: WhoAmIPuzzle) {
        id = puzzle.id
        formatName = "Who am I?"
        sport = puzzle.sport
        title = "A mystery player"
        scoring = nil
        grain = nil
        subtitle = "\(puzzle.clues.count) clues — guess who"
    }

    init(community item: CommunitySummary) {
        id = item.id
        formatName = item.format == "keep4" ? "K4C4" : "Who am I?"
        sport = item.sport
        title = item.title
        scoring = item.format == "keep4" ? item.scoringKind : nil
        grain = item.format == "keep4" ? item.grainKind : nil
        subtitle = item.format == "keep4" ? "8 \(item.grainKind.countNoun) — can you sort them?"
                                          : "6 clues — guess who"
    }
}

/// The shareable *invitation* card — `ShareCardView`'s Prime Time frame (ink border, hard
/// ledge) but for a puzzle, not a result: format, title, ScoringKind badge, no spoilers.
struct PuzzlePreviewCardView: View {
    let puzzle: SharablePuzzle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Wordmark(size: 20)
                    Spacer()
                    Text(puzzle.formatName.uppercased())
                        .font(.custom(FontName.condBlack, size: 14))
                        .foregroundStyle(Color.onAccent.opacity(0.85))
                }
                Text(puzzle.title.uppercased())
                    .font(.custom(FontName.condBlack, size: 24))
                    .foregroundStyle(Color.onAccent)
                    .lineLimit(3)
                HStack(spacing: 6) {
                    if let scoring = puzzle.scoring {
                        capsuleBadge(symbol: scoring.symbol,
                                     text: scoring.badgeLabel(for: puzzle.sport))
                    }
                    if let grain = puzzle.grain {
                        capsuleBadge(symbol: grain.symbol, text: grain.badgeLabel)
                    }
                    capsuleBadge(symbol: puzzle.sport.symbol, text: puzzle.sport.displayName)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentFill)

            Text(puzzle.subtitle.uppercased())
                .font(.custom(FontName.condBold, size: 13))
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.surface1)

            Text("PLAY AT PLAYBOOK")
                .font(.custom(FontName.condBold, size: 11))
                .foregroundStyle(Color.textMuted)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.surfaceMuted)
        }
        .frame(width: 320)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.borderInk, lineWidth: 2.5)
        )
        .padding(6)   // room for the ledge in the rendered image
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.borderInk)
                .offset(x: 4, y: 4)
                .padding(6)
        )
    }

    private func capsuleBadge(symbol: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text(text).font(.label11).lineLimit(1)
        }
        .foregroundStyle(Color.onAccent)
        .fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.onAccent.opacity(0.18))
        .clipShape(Capsule())
    }

    /// Render to an Image for `SharePreview` (same approach as `ShareCardView.rendered`).
    @MainActor
    func rendered(scale: CGFloat = 3) -> Image {
        let renderer = ImageRenderer(content: self)
        renderer.scale = scale
        if let ui = renderer.uiImage {
            return Image(uiImage: ui)
        }
        return Image(systemName: "square.dashed")
    }
}

/// Share-a-puzzle sheet (pattern: `PublishedSheet`) — preview card + the deep link.
/// Rendering happens once here, never per feed card.
struct PuzzleShareSheet: View {
    let puzzle: SharablePuzzle
    /// Analytics surface: "puzzle_home" | "puzzle_browse" | "puzzle_community".
    let surface: String
    @EnvironmentObject private var container: RepositoryContainer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let card = PuzzlePreviewCardView(puzzle: puzzle)
        VStack(spacing: 16) {
            card
            ShareLink(item: puzzle.url,
                      preview: SharePreview(puzzle.title, image: card.rendered())) {
                Label("SHARE PUZZLE", systemImage: "square.and.arrow.up").ctaLabel()
            }
            .buttonStyle(PrimePressStyle())
            // ShareLink has no tap callback — a simultaneous gesture is the standard hook.
            .simultaneousGesture(TapGesture().onEnded {
                container.track(.shareTapped, ["surface": surface, "puzzle_id": puzzle.id])
            })
            Button("Done") { dismiss() }.foregroundStyle(Color.textMuted)
        }
        .padding(16)
        .presentationDetents([.medium, .large])
    }
}
