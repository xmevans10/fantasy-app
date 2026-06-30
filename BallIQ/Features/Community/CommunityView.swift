import SwiftUI

/// Browse + play user-generated puzzles. A `＋` opens the creation flow. Playing a
/// community puzzle is unranked (XP only) and logs a play for the Popular sort.
struct CommunityView: View {
    @EnvironmentObject private var container: RepositoryContainer

    @State private var format: CommunityFormat = .keep4
    @State private var sort: CommunitySort = .recent
    @State private var sportFilter: SportFilter = .all
    @State private var items: [CommunitySummary] = []
    @State private var loading = false
    @State private var loadFailed = false

    @State private var showCreate = false
    @State private var activeKeep4: Keep4Puzzle?
    @State private var activeWhoAmI: WhoAmIPuzzle?
    @State private var pendingID: String?      // community id for the open game

    enum CommunityFormat: String, CaseIterable { case keep4, whoami
        var title: String { self == .keep4 ? "K4C4" : "Who Am I?" }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider().overlay(Color.hairline)
                content
            }
            .background(Color.appBackground)
            .navigationTitle("Community")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { Wordmark(size: 22) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCreate = true } label: { Image(systemName: "plus.circle.fill") }
                        .accessibilityLabel("Create puzzle")
                }
            }
            .task(id: refreshKey) { await load() }
            .refreshable { await load() }
            .sheet(isPresented: $showCreate, onDismiss: { Task { await load() } }) {
                CreateView().environmentObject(container)
            }
            .fullScreenCover(item: $activeKeep4) { p in
                Keep4GameView(puzzle: p, ranked: false, communityID: pendingID)
                    .environmentObject(container)
            }
            .fullScreenCover(item: $activeWhoAmI) { p in
                WhoAmIGameView(puzzle: p, ranked: false, communityID: pendingID)
                    .environmentObject(container)
            }
        }
    }

    private var refreshKey: String { "\(format.rawValue)-\(sort == .popular)-\(sportFilter.rawValue)" }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 10) {
            Picker("Format", selection: $format) {
                ForEach(CommunityFormat.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                ForEach(SportFilter.allCases) { f in
                    pill(f.title, active: sportFilter == f) { sportFilter = f }
                }
                Spacer()
                pill(sort == .recent ? "New" : "Popular", active: false, systemImage: "arrow.up.arrow.down") {
                    sort = sort == .recent ? .popular : .recent
                }
            }
        }
        .padding(16)
    }

    private func pill(_ title: String, active: Bool, systemImage: String? = nil,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11)) }
                Text(title.uppercased()).font(.label12)
            }
            .foregroundStyle(active ? Color.onAccent : Color.textPrimary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(active ? Color.accentFill : Color.surfaceMuted)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if loading && items.isEmpty {
            Spacer(); ProgressView().tint(.accentFill); Spacer()
        } else if items.isEmpty && loadFailed {
            errorState
        } else if items.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if loadFailed { failedBanner }
                    ForEach(items) { item in
                        DailyGameCard(
                            formatName: item.format == "keep4" ? "K4C4" : "Who Am I?",
                            symbol: item.sport.symbol, sport: item.sport,
                            title: item.title,
                            subtitle: "\(item.playCount) plays · community",
                            completed: false, accent: .voltFill, onAccent: .onVolt
                        ) { Task { await open(item) } }
                    }
                }
                .padding(16)
            }
        }
    }

    /// Subtle banner over a still-populated list: the last refresh failed but we kept the prior items.
    private var failedBanner: some View {
        Button { Task { await load() } } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12))
                Text("Couldn't refresh — tap to retry").font(.label12)
                Spacer()
                Image(systemName: "arrow.clockwise").font(.system(size: 12))
            }
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.surfaceMuted)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 40)).foregroundStyle(Color.textMuted)
            Text("No community puzzles yet").font(.heading).foregroundStyle(Color.textPrimary)
            Text("Be the first — tap ＋ to cook one up.")
                .font(.body14).foregroundStyle(Color.textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Shown only when we have *no* puzzles to fall back on and the fetch failed.
    private var errorState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40)).foregroundStyle(Color.textMuted)
            Text("Couldn't load community").font(.heading).foregroundStyle(Color.textPrimary)
            Text("Check your connection and try again.")
                .font(.body14).foregroundStyle(Color.textMuted)
            Button { Task { await load() } } label: {
                Text("Retry").font(.label12).foregroundStyle(Color.onAccent)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Color.accentFill)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Data

    private func load() async {
        guard let community = container.community else { items = []; return }
        loading = true
        defer { loading = false }
        do {
            let fetched = try await community.feed(format: format.rawValue,
                                                   sport: sportFilter.sport, sort: sort)
            items = Self.merge(prior: items, fetched: fetched)
            loadFailed = false
        } catch {
            // Transient failure: keep the last good list and surface a retry, never blank it.
            items = Self.merge(prior: items, fetched: nil)
            loadFailed = true
        }
    }

    /// Decide the items to display: a successful fetch (even an empty one — genuinely no puzzles)
    /// replaces the list; a failure (`nil`) keeps the prior list so a transient error can't blank it.
    static func merge(prior: [CommunitySummary], fetched: [CommunitySummary]?) -> [CommunitySummary] {
        fetched ?? prior
    }

    private func open(_ item: CommunitySummary) async {
        guard let community = container.community else { return }
        pendingID = item.id
        if item.format == "keep4" {
            activeKeep4 = await community.keep4(id: item.id)
        } else {
            activeWhoAmI = await community.whoAmI(id: item.id)
        }
    }
}
