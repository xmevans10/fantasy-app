import SwiftUI

/// One Week Pack: its boards in slot order, each with a result or a way in.
///
/// Board zero opened on the pack's release day plays as that day's ranked daily, because it IS
/// the daily (same puzzle id). Everything else plays unranked as `PlayMode.pack`. A played board
/// is not reopened: replaying the daily from here would be a second rated attempt at a board
/// whose answer the player now knows.
struct WeekPackView: View {
    let pack: WeekPack

    @EnvironmentObject private var container: RepositoryContainer
    @State private var progress: WeekPackProgress
    @State private var active: ActiveBoard?

    init(pack: WeekPack) {
        self.pack = pack
        _progress = State(initialValue: WeekPackProgress(pack: pack, results: []))
    }

    private struct ActiveBoard: Identifiable {
        let item: WeekPackItem
        let asDaily: Bool
        var id: String { item.id }
    }

    private var today: String { PuzzleStore.localDayString() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if progress.isComplete(pack) { completeCard }
                VStack(spacing: 10) {
                    ForEach(pack.items) { item in row(item) }
                }
                Text("Pack boards are unranked. The first board is also the day's daily, so playing it here or on Home counts once.")
                    .font(.label11)
                    .foregroundStyle(Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .background(Color.appBackground)
        .navigationTitle("")
        .task { await refreshProgress() }
        .onAppear { WeekPackEngagement.markEngaged(pack.id) }
        .fullScreenCover(item: $active, onDismiss: { Task { await refreshProgress() } }) { board in
            if board.asDaily {
                Keep4GameView(puzzle: board.item.keep4).environmentObject(container)
            } else {
                Keep4GameView(puzzle: board.item.keep4, ranked: false, packID: pack.id)
                    .environmentObject(container)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: pack.sport.symbol)
                Text(String(localized: "\(pack.sport.displayName.uppercased()) · WEEK PACK"))
                    .font(.label12)
                    .tracking(0.8)
            }
            Text(pack.label.uppercased())
                .font(.scoreMedium)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(String(localized: "\(progress.playedCount(in: pack)) of \(pack.items.count) boards played"))
                .font(.label12)
        }
        .foregroundStyle(pack.sport.onCardFill)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .blockCard(fill: pack.sport.cardFill)
    }

    private var completeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("PACK COMPLETE")
                    .font(.title)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Text("\(progress.totalCorrect(in: pack))/\(pack.items.count * 8)")
                    .font(.scoreMedium)
                    .foregroundStyle(Color.textPrimary)
                    .monospacedDigit()
            }
            ShareLink(item: progress.shareText(for: pack)) {
                Label("SHARE PACK", systemImage: "square.and.arrow.up").ctaLabel()
            }
            .buttonStyle(PrimePressStyle())
            .simultaneousGesture(TapGesture().onEnded {
                container.track(.shareTapped, AnalyticsEvent.shareProperties(
                    surface: "week_pack", format: PuzzleFormat.keep4.rawValue,
                    artifact: .challengeText,
                    extra: ["sport": pack.sport.rawValue, "pack": pack.id]))
            })
        }
        .padding(16)
        .cardSurface()
    }

    /// The same card every other puzzle list uses (Home's dailies, Browse), so a pack board
    /// carries the sport band, K4C4 chip, grain and scoring badges and the blue PLAY control.
    /// The slot's role rides in the subtitle, where the card already puts its secondary facts.
    private func row(_ item: WeekPackItem) -> some View {
        let puzzle = item.keep4
        let asDaily = pack.isDaily(item, today: today)
        let correct = progress.correctByItem[item.id]
        let grain = puzzle.puzzleGrain()
        let subtitle = correct.map { String(localized: "\(item.role.label) · \($0)/8 correct") }
            ?? "\(item.role.label) · \(puzzle.players.count) \(grain.countNoun)"
        return DailyGameCard(formatName: "K4C4",
                             symbol: "rectangle.stack.fill",
                             sport: puzzle.sport,
                             title: item.displayTitle(packLabel: pack.label),
                             subtitle: subtitle,
                             scoring: puzzle.scoringKind(),
                             grain: grain,
                             completed: correct != nil,
                             ranked: asDaily,
                             dateBadge: asDaily ? DailyGameCard.todayDateBadge : nil) {
            active = ActiveBoard(item: item, asDaily: asDaily)
        }
        .disabled(correct != nil)
        // Same rule as Browse rows: a board's photos are warm before its card can be tapped.
        .onAppear { if correct == nil { PuzzleAssets(keep4: puzzle).prefetch() } }
    }

    private func refreshProgress() async {
        progress = WeekPackProgress(pack: pack, results: await container.gameLog.all())
    }
}
