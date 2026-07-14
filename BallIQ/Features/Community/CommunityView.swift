import SwiftUI

/// Browse + play user-generated puzzles. A `＋` opens the creation flow. Playing a
/// community puzzle is unranked (XP only) and logs a play for the Popular sort.
struct CommunityView: View {
    @EnvironmentObject private var container: RepositoryContainer

    @State private var format: CommunityFormat = .keep4
    @State private var sort: CommunitySort = .recent
    @State private var sportFilter: SportFilter = .all
    @State private var searchText = ""
    @State private var searchExpanded = false
    @State private var items: [CommunitySummary] = []
    @State private var authors: [String: String] = [:]   // author_id → username
    @State private var loading = false
    @State private var loadFailed = false

    @State private var showCreate = false
    @State private var activeKeep4: Keep4Puzzle?
    @State private var activeWhoAmI: WhoAmIPuzzle?
    @State private var pendingID: String?      // community id for the open game
    @State private var pendingAuthor: String?  // its author's username (for the explainer)

    @State private var menuTarget: CommunitySummary?   // card whose overflow menu is open
    @State private var showCardMenu = false
    @State private var shareTarget: SharablePuzzle?
    @State private var reportTarget: CommunitySummary?
    @State private var showReportDialog = false
    @State private var showReportSent = false

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
                ToolbarItem(placement: .topBarLeading) { Wordmark(size: 22) }
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
                Keep4GameView(puzzle: p, ranked: false, communityID: pendingID,
                              authorName: pendingAuthor)
                    .environmentObject(container)
            }
            .fullScreenCover(item: $activeWhoAmI) { p in
                WhoAmIGameView(puzzle: p, ranked: false, communityID: pendingID)
                    .environmentObject(container)
            }
            .confirmationDialog("Puzzle options", isPresented: $showCardMenu) {
                Button("Share puzzle") {
                    if let item = menuTarget { shareTarget = SharablePuzzle(community: item) }
                }
                Button("Report puzzle", role: .destructive) {
                    reportTarget = menuTarget
                    showReportDialog = true
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $shareTarget) { target in
                PuzzleShareSheet(puzzle: target, surface: "puzzle_community")
                    .environmentObject(container)
            }
            .reportReasonDialog(isPresented: $showReportDialog) { reason in report(reason: reason) }
            .alert("Report sent", isPresented: $showReportSent) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Thanks — we'll take a look.")
            }
        }
    }

    /// Fires the report, gives haptic + confirmation feedback, and resets the picker state.
    /// Best-effort (matches `reportCommunity`'s own `try?` fire-and-forget), so the confirmation
    /// fires optimistically rather than waiting on a success signal that doesn't exist.
    private func report(reason: String) {
        guard let item = reportTarget else { return }
        reportTarget = nil
        Task {
            await container.reportCommunity(id: item.id, reason: reason)
            Haptics.success()
            showReportSent = true
        }
    }

    private var refreshKey: String { "\(format.rawValue)-\(sort)-\(sportFilter.rawValue)" }

    private func sortTitle(_ s: CommunitySort) -> String {
        switch s {
        case .recent: return "New"
        case .popular: return "Popular"
        case .week: return "This Week"
        }
    }

    // MARK: - Controls

    /// One collapsed control row instead of a stack of always-expanded chip rows: Format/
    /// Sport/Sort are `PrimeDropdown`s (native `Menu`), search collapses to an icon until
    /// tapped — mirrors Browse's redesigned row so the two browsing surfaces feel like one
    /// system.
    private var controls: some View {
        HStack(spacing: 8) {
            if searchExpanded {
                PrimeExpandingSearch(placeholder: "Search titles", text: $searchText, isExpanded: $searchExpanded)
            } else {
                PrimeDropdown(options: CommunityFormat.allCases, selection: $format,
                             title: \.title, isDefault: { _ in false })
                PrimeDropdown(options: SportFilter.allCases, selection: $sportFilter, title: \.title)
                PrimeDropdown(options: [CommunitySort.recent, .popular, .week], selection: $sort,
                             title: sortTitle, isDefault: { $0 == .recent })
                Spacer(minLength: 0)
                PrimeExpandingSearch(placeholder: "Search titles", text: $searchText, isExpanded: $searchExpanded)
            }
        }
        .padding(16)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if loading && items.isEmpty {
            Spacer(); ProgressView().tint(.accentFill); Spacer()
        } else if items.isEmpty && loadFailed {
            errorState
        } else if items.isEmpty {
            emptyState
        } else if visibleItems.isEmpty {
            EmptyStateView(symbol: "line.3.horizontal.decrease.circle",
                           title: "No puzzles match",
                           message: "Try a different search.")
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if loadFailed { failedBanner }
                    ForEach(visibleItems) { item in communityCard(item) }
                }
                .padding(16)
            }
        }
    }

    /// The fetched feed narrowed by the search field (client-side — see `PuzzleSearch`).
    private var visibleItems: [CommunitySummary] {
        items.filter { PuzzleSearch.matches(query: searchText, community: $0) }
    }

    /// A community feed card. The header band is colored by sport, same as daily cards; human-made
    /// puzzles get a soft warm body tint instead (vs the daily cards' white) plus the grading
    /// badge (K4C4 only). The author line sits below the card rather than inside it (M19):
    /// `DailyGameCard`'s whole body is a single tap target for "play", so a second tappable
    /// target for "view author" has to live outside it rather than nested inside.
    private func communityCard(_ item: CommunitySummary) -> some View {
        let plays = item.playCount == 1 ? "1 play" : "\(item.playCount) plays"
        let isKeep4 = item.format == "keep4"
        return VStack(alignment: .leading, spacing: 6) {
            DailyGameCard(
                formatName: isKeep4 ? "K4C4" : "Who Am I?",
                symbol: isKeep4 ? "rectangle.stack.fill" : "questionmark.circle.fill", sport: item.sport,
                title: item.title,
                subtitle: plays,
                description: item.description,
                scoring: isKeep4 ? item.scoringKind : nil,
                grain: isKeep4 ? item.grainKind : nil,
                completed: container.hasCompletedToday(puzzleID: item.id),
                typeColor: isKeep4 ? .accentFill : .voltFill, onTypeColor: isKeep4 ? .onAccent : .onVolt,
                bodyFill: .warningBg
            ) { Task { await open(item) } }
            secondaryAction: { menuTarget = item; showCardMenu = true }

            NavigationLink {
                PublicProfileView(userID: item.authorId, usernameHint: authors[item.authorId])
            } label: {
                Text(authorLine(item))
                    .font(.label12)
                    .foregroundStyle(Color.textMuted)
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
        }
    }

    private func authorLine(_ item: CommunitySummary) -> String {
        authors[item.authorId].map { "by @\($0)" } ?? "by community"
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
        EmptyStateView(symbol: "square.stack.3d.up.slash",
                       title: "No community puzzles yet",
                       message: "Be the first — tap ＋ to cook one up.")
    }

    /// Shown only when we have *no* puzzles to fall back on and the fetch failed.
    private var errorState: some View {
        EmptyStateView(symbol: "wifi.exclamationmark",
                       title: "Couldn't load community",
                       message: "Check your connection and try again.",
                       actionTitle: "Retry") { Task { await load() } }
    }

    // MARK: - Data

    private func load() async {
        guard let community = container.community else { items = []; return }
        loading = true
        defer { loading = false }
        do {
            var fetched = try await community.feed(format: format.rawValue,
                                                   sport: sportFilter.sport, sort: sort)
            if sort == .week, let counts = try? await community.weeklyPlayCounts() {
                // RPC not deployed / transient failure → keep the fetched recent order.
                fetched = CommunityTrending.sorted(items: fetched, weeklyPlays: counts)
            }
            items = Self.merge(prior: items, fetched: fetched)
            loadFailed = false
            let missing = Set(items.map(\.authorId)).subtracting(authors.keys)
            authors.merge(await community.authorNames(ids: missing)) { _, new in new }
        } catch is CancellationError {
            // SwiftUI cancelled this load (e.g. a `.refreshable` gesture torn down mid-flight)
            // rather than the request actually failing — leave the prior state untouched.
        } catch {
            // Transient failure: keep the last good list and surface a retry, never blank it.
            print("CommunityView.load failed: \(error)")
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
        container.track(.communityPuzzlePlayed, ["source": "community", "puzzle_id": item.id])
        pendingID = item.id
        pendingAuthor = authors[item.authorId]
        if item.format == "keep4" {
            activeKeep4 = await community.keep4(id: item.id)
        } else {
            activeWhoAmI = await community.whoAmI(id: item.id)
        }
    }
}
