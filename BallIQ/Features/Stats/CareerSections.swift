import SwiftUI
import Charts

/// The sections `CareerView` stacks below its hero card — split out because five independent
/// pieces (Records, Splits, Patterns, Trend, Fun Facts), each with its own local toggle state,
/// made the parent file unwieldy as a single `body`.

// MARK: - Shared locked-card wording

/// "3 more NBA games" / "3 more games" — `scopeLabel` is `CareerView`'s current top-level
/// scope (empty string for ALL). Every locked `StatCard` anywhere on this screen reads its
/// requirement through this one function rather than a scattered `if` per card.
func lockRequirement(_ card: StatCard, scopeLabel: String) -> String {
    let needed = max(card.minReps - card.repsSoFar, 0)
    let unit = scopeLabel.isEmpty ? "game" : "\(scopeLabel) game"
    return "\(needed) more \(unit)\(needed == 1 ? "" : "s")"
}

/// A single dimmed, lock-badged placeholder for a section that isn't `StatCard`-backed
/// (Splits/Patterns/Trend have no per-tile `minReps` of their own to key off).
struct LockedSectionPlaceholder: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.textMuted)
            Text(title.uppercased()).font(.heading).foregroundStyle(Color.textPrimary)
            Text(subtitle)
                .font(.body14)
                .foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28).padding(.horizontal, 16)
        .cardSurface()
    }
}

// MARK: - Records

/// One `.cardSurface()` tile per `.record`-kind `StatCard` — best-evers, streaks, biggest
/// rating jump. Two-column grid so the ~10 records don't turn into an endless single column.
struct RecordsSection: View {
    let cards: [StatCard]
    let scopeLabel: String

    private var records: [StatCard] { cards.filter { $0.kind == .record } }
    private let columns = [GridItem(.flexible(), spacing: Space.sm), GridItem(.flexible(), spacing: Space.sm)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LowerThirdHeader(title: "Records")
            LazyVGrid(columns: columns, spacing: Space.sm) {
                ForEach(records) { tile($0) }
            }
        }
    }

    @ViewBuilder
    private func tile(_ card: StatCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(card.title).font(.label11).foregroundStyle(Color.textMuted)
                Spacer()
                if !card.isUnlocked {
                    Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Color.textMuted)
                }
            }
            if card.isUnlocked {
                Text(card.value).font(.hero(22)).foregroundStyle(Color.textPrimary)
                if let context = card.context {
                    Text(context).font(.label11).foregroundStyle(Color.textMuted)
                }
            } else {
                Text(lockRequirement(card, scopeLabel: scopeLabel))
                    .font(.label11)
                    .foregroundStyle(Color.textMuted)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardSurface()
        .opacity(card.isUnlocked ? 1 : 0.55)
    }
}

// MARK: - Splits

private enum SplitsMode: Hashable { case bySport, byFormat }

/// Always computed over the *full*, unscoped log — the point of a "by sport"/"by format"
/// breakdown is comparing across them, so scoping it to `CareerView`'s current sport would
/// leave the BY SPORT tab showing exactly one bar.
struct SplitsSection: View {
    let rows: [GameResult]
    @State private var mode: SplitsMode = .bySport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LowerThirdHeader(title: "Splits")
            VStack(alignment: .leading, spacing: 12) {
                PrimeSegmentedControl(
                    options: [(title: "BY SPORT", value: SplitsMode.bySport),
                              (title: "BY FORMAT", value: SplitsMode.byFormat)],
                    selection: $mode
                )
                switch mode {
                case .bySport:
                    ForEach(Sport.allCases) { sport in
                        bar(label: sport.displayName,
                            split: FormatSplit(rows.filter { $0.sport == sport }), fill: sport.cardFill)
                    }
                case .byFormat:
                    ForEach(GameFormatKind.allCases, id: \.self) { format in
                        bar(label: format.shortName,
                            split: FormatSplit(rows.filter { $0.format == format }), fill: .accentFill)
                    }
                }
            }
            .padding(12)
            .cardSurface()
        }
    }

    /// Every bar carries its rep count in the trailing label — a 100% bar backed by one
    /// attempt reads very differently from one backed by two hundred, and the bar's fill
    /// alone can't tell those apart.
    private func bar(label: String, split: FormatSplit, fill: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label.uppercased()).font(.label12).foregroundStyle(Color.textPrimary)
                Spacer()
                Text(split.attempted > 0
                     ? "\(CareerFmt.percent(split.accuracy)) · \(CareerFmt.plain(split.attempted)) reps"
                     : "no reps yet")
                    .font(.label11).foregroundStyle(Color.textMuted)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.surfaceMuted)
                    Capsule().fill(fill).frame(width: geo.size.width * CGFloat(split.accuracy ?? 0))
                }
            }
            .frame(height: 8)
        }
    }
}

private extension GameFormatKind {
    /// Player-facing name — mirrors `StatCatalog`'s own private `displayName`, which is
    /// file-private and unreachable from here.
    var shortName: String {
        switch self {
        case .keep4Normal: return "K4C4"
        case .keep4Hard:   return "K4C4 Hard"
        case .whoAmI:      return "Who Am I?"
        case .overUnder:   return "Over/Under"
        case .draftSpin:   return "Draft & Spin"
        case .grid:        return "The Grid"
        }
    }
}

// MARK: - Patterns

/// Day-of-week accuracy bars plus a time-of-day tile row. `TimeOfDayBucket` has five real
/// buckets (early riser through night owl) — all five render rather than dropping one to hit
/// a round tile count, since silently discarding a bucket would misreport where the player
/// actually plays.
struct PatternsSection: View {
    let rows: [GameResult]

    private var byDay: [Int: FormatSplit] { CareerStatsMath.accuracyByDayOfWeek(rows) }
    private var byTime: [TimeOfDayBucket: FormatSplit] { CareerStatsMath.accuracyByTimeOfDay(rows) }
    private var weekdaySymbols: [String] { Calendar.current.veryShortWeekdaySymbols }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LowerThirdHeader(title: "Patterns")
            VStack(alignment: .leading, spacing: 14) {
                dayChart
                timeOfDayRow
            }
            .padding(12)
            .cardSurface()
        }
    }

    private var dayChart: some View {
        Chart {
            ForEach(1...7, id: \.self) { weekday in
                let accuracy = (byDay[weekday]?.accuracy ?? 0) * 100
                BarMark(x: .value("Day", weekdaySymbols[weekday - 1]), y: .value("Accuracy", accuracy))
                    .foregroundStyle(Color.accentFill)
            }
        }
        .frame(height: 140)
        .chartYAxis { AxisMarks(position: .leading) }
    }

    private var timeOfDayRow: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: TimeOfDayBucket.allCases.count)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(TimeOfDayBucket.allCases, id: \.self) { bucket in
                VStack(spacing: 2) {
                    Text(bucket.label.uppercased())
                        .font(.label11).foregroundStyle(Color.textMuted)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(CareerFmt.percent(byTime[bucket]?.accuracy))
                        .font(.bodyStrong).foregroundStyle(Color.textPrimary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.surfaceMuted)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
        }
    }
}

// MARK: - Trend

private enum TrendMode: Hashable { case accuracy, rating }

private struct TrendPoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

/// Rating-vs-time only means something within one sport (five separate Elo tracks can't share
/// an axis), so the RATING toggle only appears once `CareerView`'s scope has narrowed to one;
/// under ALL scope this always renders the rolling-10 accuracy line instead.
struct TrendSection: View {
    let rows: [GameResult]
    let showRatingToggle: Bool
    @State private var mode: TrendMode = .accuracy

    private var effectiveMode: TrendMode { showRatingToggle ? mode : .accuracy }

    /// Rolling-10 accuracy over judged rows in chronological order — the same "hot or cold"
    /// idea `StatCatalog.accuracyTrendCard` reduces to one number, plotted as a series instead.
    private var accuracySeries: [TrendPoint] {
        let judged = rows.filter { $0.attempted > 0 }.sorted { $0.playedAt < $1.playedAt }
        var out: [TrendPoint] = []
        for i in judged.indices {
            let window = judged[max(0, i - 9)...i]
            let correct = window.reduce(into: 0) { $0 += $1.correct }
            let attempted = window.reduce(into: 0) { $0 += $1.attempted }
            guard attempted > 0 else { continue }
            out.append(TrendPoint(date: judged[i].playedAt, value: Double(correct) / Double(attempted)))
        }
        return out
    }

    private var ratingSeries: [TrendPoint] {
        rows.sorted { $0.playedAt < $1.playedAt }
            .map { TrendPoint(date: $0.playedAt, value: Double($0.ratingAfter)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LowerThirdHeader(title: "Trend")
            VStack(alignment: .leading, spacing: 12) {
                if showRatingToggle {
                    PrimeSegmentedControl(
                        options: [(title: "ACCURACY", value: TrendMode.accuracy),
                                  (title: "RATING", value: TrendMode.rating)],
                        selection: $mode
                    )
                }
                chart
            }
            .padding(12)
            .cardSurface()
        }
    }

    @ViewBuilder
    private var chart: some View {
        switch effectiveMode {
        case .accuracy:
            if accuracySeries.count < 2 {
                emptyChartMessage
            } else {
                Chart(accuracySeries) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Accuracy", point.value))
                        .foregroundStyle(Color.accentFill)
                        .interpolationMethod(.monotone)
                    AreaMark(x: .value("Date", point.date), y: .value("Accuracy", point.value))
                        .foregroundStyle(Color.accentFill.opacity(0.12))
                        .interpolationMethod(.monotone)
                }
                .frame(height: 160)
                .chartYScale(domain: 0...1)
                .chartYAxis { AxisMarks(position: .leading) }
            }
        case .rating:
            if ratingSeries.count < 2 {
                emptyChartMessage
            } else {
                Chart(ratingSeries) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Rating", point.value))
                        .foregroundStyle(Color.voltText)
                        .interpolationMethod(.monotone)
                    AreaMark(x: .value("Date", point.date), y: .value("Rating", point.value))
                        .foregroundStyle(Color.voltFill.opacity(0.15))
                        .interpolationMethod(.monotone)
                }
                .frame(height: 160)
                .chartYAxis { AxisMarks(position: .leading) }
            }
        }
    }

    private var emptyChartMessage: some View {
        Text("Not enough games yet to chart a trend.")
            .font(.body14).foregroundStyle(Color.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
            .multilineTextAlignment(.center)
    }
}

// MARK: - Fun Facts

/// Every unlocked `StatCard` carrying a `flavor` gets a full-bleed sentence card, alternating
/// fills so a long scroll of facts doesn't read as one undifferentiated blue wall. Locked ones
/// get the same dim + lock treatment as Records rather than vanishing outright — a scroll that
/// randomly gets shorter as history grows would read as a bug, not progress.
struct FunFactsSection: View {
    let cards: [StatCard]
    let scopeLabel: String

    private var facts: [StatCard] { cards.filter { $0.flavor != nil } }
    private let palette: [(fill: Color, on: Color)] = [(.accentFill, .onAccent), (.voltFill, .onVolt), (.goldFill, .onGold)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LowerThirdHeader(title: "Fun Facts")
            VStack(spacing: 10) {
                ForEach(Array(facts.enumerated()), id: \.element.id) { index, card in
                    tile(card, colors: palette[index % palette.count])
                }
            }
        }
    }

    @ViewBuilder
    private func tile(_ card: StatCard, colors: (fill: Color, on: Color)) -> some View {
        if card.isUnlocked {
            VStack(alignment: .leading, spacing: 6) {
                Text(card.title).font(.label12).foregroundStyle(colors.on.opacity(0.75))
                Text(card.flavor ?? "").font(.body14).foregroundStyle(colors.on)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .blockCard(fill: colors.fill)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").font(.system(size: 12)).foregroundStyle(Color.textMuted)
                Text(lockRequirement(card, scopeLabel: scopeLabel)).font(.label12).foregroundStyle(Color.textMuted)
                Spacer()
            }
            .padding(14)
            .cardSurface()
        }
    }
}
