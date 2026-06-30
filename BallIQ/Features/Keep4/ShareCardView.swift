import SwiftUI

/// The shareable result image for a Keep4/Cut4 attempt.
/// Per the brief: logo + theme + score, the 8 seasons with Keep/Cut + correct/incorrect.
/// Deliberately shows NO rating.
struct ShareCardView: View {
    let puzzle: Keep4Puzzle
    let placement: [String: Pile]
    let result: Keep4Scoring.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Wordmark(size: 20)
                Spacer()
                Text("K4C4")
                    .font(.label12)
                    .foregroundStyle(Color.accentText)
            }

            Text(puzzle.theme)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.textPrimary)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(result.correctCount)/\(puzzle.players.count)")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                Text(result.isPerfect ? "Perfect sort" : "correct")
                    .font(.body14)
                    .foregroundStyle(result.isPerfect ? Color.successText : Color.textMuted)
            }

            VStack(spacing: 6) {
                ForEach(puzzle.players) { player in
                    let pile = placement[player.id]
                    let correct = result.correctness[player.id] ?? false
                    HStack(spacing: 8) {
                        Text(pile == .keep ? "Keep" : "Cut")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(pile == .keep ? Color.onSuccess : Color.onDanger)
                            .frame(width: 42)
                            .padding(.vertical, 3)
                            .background(pile == .keep ? Color.successFill : Color.dangerFill)
                            .clipShape(Capsule())
                        Text(player.name)
                            .font(.label12)
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        Image(systemName: correct ? "checkmark" : "xmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(correct ? Color.successText : Color.dangerText)
                    }
                }
            }

            Text("Play at BallIQ")
                .font(.label11)
                .foregroundStyle(Color.textMuted)
        }
        .padding(20)
        .frame(width: 320)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .stroke(Color.hairline, lineWidth: Hairline.width)
        )
    }
}

extension ShareCardView {
    /// Render the card to a SwiftUI Image for ShareLink.
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
