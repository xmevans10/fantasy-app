import SwiftUI

/// The shareable result image for a Keep4/Cut4 attempt — the one piece of the app people see
/// *outside* the app, so it carries the full Prime Time treatment: condensed caps, an Anton
/// score block, ink outline + hard ledge. Per the brief: logo + theme + score, the 8 seasons
/// with Keep/Cut + correct/incorrect. Deliberately shows NO rating.
struct ShareCardView: View {
    let puzzle: Keep4Puzzle
    let placement: [String: Pile]
    let result: Keep4Scoring.Result

    private var heroFill: Color { result.isPerfect ? .voltFill : .accentFill }
    private var heroInk: Color { result.isPerfect ? .onVolt : .onAccent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Colored header band: score + theme
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Wordmark(size: 20)
                    Spacer()
                    Text("K4C4")
                        .font(.custom(FontName.condBlack, size: 14))
                        .foregroundStyle(heroInk.opacity(0.85))
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(result.correctCount)/\(puzzle.players.count)")
                        .font(.hero(40))
                        .foregroundStyle(heroInk)
                    Text(result.isPerfect ? "PERFECT SORT" : "CORRECT")
                        .font(.custom(FontName.condBlack, size: 15))
                        .foregroundStyle(heroInk.opacity(0.85))
                }
                Text(puzzle.theme.uppercased())
                    .font(.custom(FontName.condBold, size: 14))
                    .foregroundStyle(heroInk.opacity(0.8))
                    .lineLimit(2)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(heroFill)

            // The 8 picks
            VStack(spacing: 0) {
                ForEach(Array(puzzle.players.enumerated()), id: \.element.id) { i, player in
                    let pile = placement[player.id]
                    let correct = result.correctness[player.id] ?? false
                    HStack(spacing: 8) {
                        Text(pile == .keep ? "KEEP" : "CUT")
                            .font(.custom(FontName.condBlack, size: 11))
                            .foregroundStyle(pile == .keep ? Color.onSuccess : Color.onDanger)
                            .frame(width: 44)
                            .padding(.vertical, 3)
                            .background(pile == .keep ? Color.successFill : Color.dangerFill)
                            .clipShape(Capsule())
                        Text(player.name.uppercased())
                            .font(.custom(FontName.condBold, size: 13))
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Spacer()
                        Image(systemName: correct ? "checkmark" : "xmark")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(correct ? Color.successText : Color.dangerText)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    if i < puzzle.players.count - 1 {
                        Rectangle().fill(Color.hairline).frame(height: Hairline.width)
                            .padding(.leading, 16)
                    }
                }
            }
            .padding(.vertical, 6)
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
