import SwiftUI

/// The personal career-analytics screen — pushed from Profile, no `NavigationStack` of its
/// own (the convention it inherited from the rating-only `StatsView` it replaced; that file is
/// gone, so this is the sole Profile stats destination). Loads the
/// whole game log once via the actor-isolated `GameLogRepository`, then a scope picker
/// re-slices everything below it except Splits, which is deliberately always the *unscoped*
/// cross-sport/format comparison — scoping "by sport" down to a single sport would leave that
/// tab showing exactly one bar.
struct CareerView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [GameResult] = []
    @State private var loaded = false
    @State private var scope: CareerScope = .all

    /// Below this, Splits/Patterns/Trend degrade into near-empty charts rather than saying
    /// anything real — locked as whole sections instead. Records/Fun Facts don't need this:
    /// they're `StatCard`-backed, so each tile already gates itself on its own `minReps`.
    private static let sectionUnlockThreshold = 5

    private var scopedRows: [GameResult] {
        switch scope {
        case .all: return rows
        case .sport(let sport): return rows.filter { $0.sport == sport }
        }
    }

    private var statScope: StatScope {
        switch scope {
        case .all: return .all
        case .sport(let sport): return .sport(sport)
        }
    }

    /// Empty label for ALL ("3 more games"), sport name when scoped ("3 more NBA games") — fed
    /// to every locked-card caption so the requirement reads like the current scope, not a
    /// generic one.
    private var scopeLabel: String {
        switch scope {
        case .all: return ""
        case .sport(let sport): return sport.displayName
        }
    }

    private var summary: CareerSummary { CareerSummary(scopedRows) }
    /// Passes the *full* log, not `scopedRows` — `StatCatalog.cards` does its own scope
    /// filtering internally (and needs the unscoped rows for its own cross-sport cards).
    private var cards: [StatCard] { StatCatalog.cards(rows, scope: statScope) }

    var body: some View {
        ScrollView {
            content
                .padding(16)
        }
        .background(Color.appBackground)
        .navigationTitle("Career")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            rows = await container.gameLog.all()
            loaded = true
        }
    }

    @ViewBuilder
    private var content: some View {
        if !loaded {
            ProgressView().frame(maxWidth: .infinity, minHeight: 320)
        } else if rows.isEmpty {
            emptyState
        } else {
            VStack(spacing: 18) {
                scopePicker.heroReveal(0)
                heroCard.heroReveal(1)
                if rows.count >= Self.sectionUnlockThreshold {
                    RecordsSection(cards: cards, scopeLabel: scopeLabel).heroReveal(2)
                    SplitsSection(rows: rows).heroReveal(3)
                    PatternsSection(rows: scopedRows).heroReveal(4)
                    TrendSection(rows: scopedRows, showRatingToggle: scope != .all).heroReveal(5)
                    FunFactsSection(cards: cards, scopeLabel: scopeLabel).heroReveal(6)
                } else {
                    starterRow.heroReveal(2)
                    lockedRest.heroReveal(3)
                }
            }
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            symbol: "chart.line.uptrend.xyaxis",
            title: "Your Career Starts Today",
            message: "Play a puzzle and this fills up with your accuracy, records and personal bests.",
            actionTitle: "Play a Puzzle"
        ) { dismiss() }
        .frame(maxWidth: .infinity, minHeight: 420)
    }

    private var scopePicker: some View {
        PrimeSegmentedControl(
            options: [(title: "ALL", value: CareerScope.all)]
                + Sport.allCases.map { (title: $0.displayName, value: CareerScope.sport($0)) },
            selection: $scope
        )
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(spacing: 14) {
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    CountUpText(value: Int(((summary.accuracy ?? 0) * 100).rounded()),
                                font: .hero(48), color: .onAccent)
                    Text("%").font(.hero(26)).foregroundStyle(Color.onAccent)
                }
                Text("CAREER ACCURACY").font(.label12).foregroundStyle(Color.onAccent.opacity(0.8))
            }
            accuracyBar
            Text(heroSubtext)
                .font(.label11)
                .foregroundStyle(Color.onAccent.opacity(0.75))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24).padding(.horizontal, 16)
        .blockCard(fill: .accentFill)
    }

    private var accuracyBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.onAccent.opacity(0.2))
                Capsule().fill(Color.voltFill)
                    .frame(width: geo.size.width * CGFloat(summary.accuracy ?? 0))
            }
        }
        .frame(height: 10)
    }

    private var heroSubtext: String {
        let games = CareerFmt.plain(summary.games)
        let judged = CareerFmt.grouped(summary.cardsJudged)
        let time = CareerFmt.longDuration(ms: summary.totalPlayMs)
        return "\(games) game\(summary.games == 1 ? "" : "s") · \(judged) cards judged · \(time) played"
    }

    // MARK: - 1-4 game tier

    /// Only what's meaningful with a handful of games — everything else needs `minReps`
    /// thresholds this tier can't clear, so it's shown locked in `lockedRest` instead of
    /// rendered half-empty.
    private var starterRow: some View {
        HStack(spacing: 12) {
            starterTile("GAMES", CareerFmt.plain(summary.games))
            starterTile("BEST SCORE", bestScoreText)
            starterTile("PERFECTS", CareerFmt.plain(summary.perfects))
            starterTile("STREAK", "\(container.streak)")
        }
    }

    private func starterTile(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.label11).foregroundStyle(Color.textMuted)
            Text(value).font(.hero(20)).foregroundStyle(Color.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .cardSurface()
    }

    private var bestScoreText: String {
        let eligible = scopedRows.filter { $0.mode.countsForRecords && $0.maxScore > 0 }
        guard let best = eligible.map(\.score).max() else { return "—" }
        return CareerFmt.grouped(best)
    }

    private var lockedRest: some View {
        let remaining = Self.sectionUnlockThreshold - rows.count
        return LockedSectionPlaceholder(
            title: "More Unlocks at \(Self.sectionUnlockThreshold) Games",
            subtitle: "\(remaining) more game\(remaining == 1 ? "" : "s") and records, splits, patterns and a trend chart open up."
        )
    }
}

/// Wraps `StatScope` with the `Hashable` conformance `PrimeSegmentedControl`'s selection
/// binding needs — `StatScope` itself only promises `Equatable`, which is all `StatCatalog`
/// ever asked of it.
enum CareerScope: Hashable {
    case all
    case sport(Sport)
}

/// Numeric-to-string formatting shared by this screen's sections — mirrors `StatCatalog`'s
/// private `Fmt` (grouped vs. plain matters here too: "42 games" should never gain a comma),
/// but that one is file-private to `StatCatalog.swift` and this screen doesn't own that file.
enum CareerFmt {
    static func plain(_ value: Int) -> String { String(value) }

    static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? plain(value)
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }

    /// "1h 42m" over an hour, "42m" under.
    static func longDuration(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 { return "\(plain(hours))h \(plain(minutes))m" }
        return "\(plain(minutes))m"
    }
}

#Preview {
    let container = RepositoryContainer.make(client: nil)
    return NavigationStack { CareerView() }.environmentObject(container)
}
