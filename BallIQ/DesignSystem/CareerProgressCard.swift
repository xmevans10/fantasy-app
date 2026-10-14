import SwiftUI

struct CareerProgressCard: View {
    let xp: Int
    var leveledUp = false
    var compact = false
    private var progress: (level: Int, intoLevel: Int, span: Int) { LevelCurve.progress(forXP: xp) }

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(leveledUp ? "LEVEL \(progress.level) REACHED" : "LEVEL \(progress.level) · \(LevelCurve.title(for: progress.level).uppercased())").font(.label12)
                    Spacer(minLength: 6)
                    Text("\(progress.span - progress.intoLevel) XP TO LEVEL \(progress.level + 1)").font(.label11)
                }
                ProgressView(value: Double(progress.intoLevel), total: Double(progress.span))
                    .tint(.accentFill)
                    .accessibilityLabel("Level \(progress.level), \(progress.span - progress.intoLevel) XP to level \(progress.level + 1)")
            }.foregroundStyle(Color.textPrimary).padding(14).cardSurface()
                .animation(Motion.easeOut, value: xp)
        } else {
            fullCard
        }
    }
    private var fullCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(leveledUp ? "LEVEL UP!" : "YOUR CAREER").font(.label12)
                    Text(LevelCurve.title(for: progress.level).uppercased()).font(.title)
                }
                Spacer(minLength: 8)
                Text("LVL \(progress.level)").font(.hero(34))
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.onAccent.opacity(0.22))
                    Capsule().fill(Color.onAccent)
                        .frame(width: geometry.size.width * Double(progress.intoLevel) / Double(progress.span))
                }
            }
            .frame(height: 10)
            .accessibilityLabel("Progress to level \(progress.level + 1)")
            .accessibilityValue("\(progress.intoLevel) of \(progress.span) XP")
            Text("\(progress.span - progress.intoLevel) XP TO LEVEL \(progress.level + 1)")
                .font(.label12)
            if !compact, let next = LevelCurve.nextMilestone(after: progress.level) {
                Text("Next career title: \(next.title) · Level \(next.level)")
                    .font(.body14)
            }
            if !compact {
                Text("Every completed game earns XP. Your career level never falls.")
                    .font(.label11)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(Color.onAccent)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .blockCard(fill: .accentFill)
        .animation(Motion.easeOut, value: xp)
        .accessibilityElement(children: .combine)
    }
}
