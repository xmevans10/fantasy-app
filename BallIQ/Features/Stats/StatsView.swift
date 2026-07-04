import SwiftUI
import Charts

struct StatsView: View {
    @EnvironmentObject private var container: RepositoryContainer

    @State private var sport: Sport = .nfl
    @State private var history: [Sport: [RatingPoint]] = [:]

    private var rating: Int { container.rating(for: sport) }
    private var tier: Tier { Tier.forRating(rating) }
    private var points: [RatingPoint] { history[sport] ?? [] }
    private var summary: StatsSummary { StatsSummary(history: points, currentRating: rating) }

    /// Pushed from Profile (no NavigationStack of its own — a 6th tab would overflow the tab bar).
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                sportPicker.heroReveal(0)
                chartCard.heroReveal(1)
                summaryRow.heroReveal(2)
                streakCard.heroReveal(3)
            }
            .padding(16)
        }
        .background(Color.appBackground)
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadAll() }
    }

    private var sportPicker: some View {
        PrimeSegmentedControl(options: Sport.allCases.map { ($0.displayName, $0) },
                              selection: $sport)
    }

    @ViewBuilder
    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("RATING").font(.label12).foregroundStyle(Color.textMuted)
                Spacer()
                Text("\(rating)").font(.hero(28)).foregroundStyle(tier.color)
            }
            if points.isEmpty {
                Text("Play a ranked \(sport.displayName) puzzle to start your rating history.")
                    .font(.body14)
                    .foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
                    .multilineTextAlignment(.center)
            } else {
                Chart(points, id: \.date) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Rating", point.rating))
                        .foregroundStyle(tier.color)
                        .interpolationMethod(.monotone)
                    AreaMark(x: .value("Date", point.date), y: .value("Rating", point.rating))
                        .foregroundStyle(tier.color.opacity(0.12))
                        .interpolationMethod(.monotone)
                }
                .frame(height: 160)
                .chartYAxis { AxisMarks(position: .leading) }
            }
        }
        .padding(16)
        .cardSurface()
    }

    private var summaryRow: some View {
        HStack(spacing: 16) {
            stat("BEST", "\(summary.best)")
            Divider().frame(height: 32)
            stat("NET CHANGE", signed(summary.netChange))
            Divider().frame(height: 32)
            stat("GAMES", "\(summary.gamesPlayed)")
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .cardSurface()
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.label11).foregroundStyle(Color.textMuted)
            Text(value).font(.hero(22)).foregroundStyle(Color.textPrimary)
        }
        .frame(maxWidth: .infinity)
    }

    private func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }

    private var streakCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CURRENT STREAK").font(.label11).foregroundStyle(Color.textMuted)
                Text("\(container.streak) day\(container.streak == 1 ? "" : "s")")
                    .font(.heading).foregroundStyle(Color.textPrimary)
            }
            Spacer()
            Image(systemName: "flame.fill")
                .font(.system(size: 26))
                .foregroundStyle(Color.warningFill)
        }
        .padding(16)
        .cardSurface()
    }

    private func loadAll() async {
        for s in Sport.allCases {
            history[s] = await container.ratingHistory(for: s)
        }
    }
}

#Preview {
    let container = RepositoryContainer.make(client: nil)
    return NavigationStack { StatsView() }.environmentObject(container)
}
