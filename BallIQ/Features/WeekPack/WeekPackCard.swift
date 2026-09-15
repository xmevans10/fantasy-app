import SwiftUI

/// Home's entry to a current Week Pack: the loud block treatment (it is the one thing on Home
/// that is new this week), sport-colored like the daily cards, with progress as a row of bars
/// so "2 of 5" reads without reading.
struct WeekPackCard: View {
    let pack: WeekPack
    let progress: WeekPackProgress
    /// Unopened: leads Home and says so.
    var isNew: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: pack.sport.symbol)
                    Text(String(localized: "\(pack.sport.displayName.uppercased()) · WEEK PACK"))
                        .font(.label12)
                        .tracking(0.8)
                    Spacer(minLength: 8)
                    if isNew {
                        Text("JUST DROPPED")
                            .font(.label11)
                            .foregroundStyle(Color.onVolt)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.voltFill))
                            .overlay(Capsule().strokeBorder(Color.borderInk, lineWidth: 1.5))
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .black))
                }
                Text(pack.label.uppercased())
                    .font(.scoreMedium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                // Fills from the front by COUNT, like any progress bar: playing board three first
                // lights the first segment, not the third.
                let played = progress.playedCount(in: pack)
                HStack(spacing: 5) {
                    ForEach(0..<pack.items.count, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(index < played ? Color.voltFill : pack.sport.onCardFill.opacity(0.25))
                            .overlay(RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(Color.borderInk, lineWidth: 1.5))
                            .frame(height: 10)
                    }
                }
                Text(progress.isComplete(pack)
                     ? String(localized: "Pack complete · \(progress.totalCorrect(in: pack))/\(pack.items.count * 8) cards")
                     : String(localized: "\(progress.playedCount(in: pack)) of \(pack.items.count) boards played"))
                    .font(.label12)
            }
            .foregroundStyle(pack.sport.onCardFill)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .blockCard(fill: pack.sport.cardFill)
        }
        .buttonStyle(PrimePressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens this week's pack"))
    }
}
