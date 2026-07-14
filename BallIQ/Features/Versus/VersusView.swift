import SwiftUI

struct VersusView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @EnvironmentObject private var auth: AuthService

    @State private var open: [VersusChallengeRow] = []
    @State private var results: [VersusChallengeRow] = []
    @State private var loaded = false
    @State private var showChallengeSheet = false
    @State private var showVersusInfo = false
    @State private var playChallenge: VersusChallengeRow?
    @State private var playPuzzle: Keep4Puzzle?

    var body: some View {
        NavigationStack {
            Group {
                if !auth.isSignedIn {
                    signInPrompt
                } else if !loaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if open.isEmpty && results.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(Color.appBackground)
            .navigationTitle("Versus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Wordmark() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showVersusInfo = true } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("How Versus works")
                }
                if auth.isSignedIn {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showChallengeSheet = true } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .accessibilityLabel("New challenge")
                    }
                }
            }
        }
        .task { await load() }
        .onAppear {
            if DebugLaunch.autoOpenVersusInfo || HowItWorksSheet.shouldAutoPresent(feature: "versus") {
                showVersusInfo = true
            }
        }
        .sheet(isPresented: $showChallengeSheet) {
            ChallengeSheet { await load() }
        }
        .sheet(isPresented: $showVersusInfo) { versusInfoSheet }
        .fullScreenCover(item: $playPuzzle) { puzzle in
            Keep4GameView(puzzle: puzzle, ranked: false, versusChallengeID: playChallenge?.challenge.id)
                .environmentObject(container)
        }
    }

    private var signInPrompt: some View {
        EmptyStateView(symbol: "bolt.fill",
                       title: "Versus",
                       message: "Sign in to duel anyone 1v1 on today's puzzle — best score wins the day, and wins stack into a best-of-7 series.")
    }

    private var emptyState: some View {
        EmptyStateView(symbol: "bolt.fill",
                       title: "No challenges yet",
                       message: "Challenge anyone by username. You both play the same daily puzzle — higher score wins the day, and wins stack into a best-of-7 series. Play within 24 hours or forfeit.",
                       actionTitle: "New challenge") { showChallengeSheet = true }
    }

    /// Copy derives from the spec's competitive glossary; mechanics mirror
    /// `resolve_versus_challenge` in supabase/schema.sql (ties → challenger, forfeit on
    /// expiry, series completes after 7 duels).
    private var versusInfoSheet: some View {
        HowItWorksSheet(
            title: "Versus Duels",
            intro: "A 1v1 duel: you and your opponent independently play the same daily puzzle, and the scores settle it.",
            symbol: "bolt.fill",
            tint: Color.accentText,
            tintBackground: Color.accentBg,
            rules: [
                .init(symbol: "person.2.fill",
                      title: "Same puzzle, both of you",
                      detail: "Challenge anyone by username. You each play the same daily Keep4 puzzle for the chosen sport — the higher score wins the day."),
                .init(symbol: "crown.fill",
                      title: "Ties go to the challenger",
                      detail: "Dead-even scores count as a win for whoever sent the challenge — an edge for making the first move."),
                .init(symbol: "trophy.fill",
                      title: "Best-of-7 series",
                      detail: "Every duel against the same player in the same sport stacks into a running series — most wins after 7 takes it."),
            ],
            callout: .init(symbol: "clock.fill",
                           label: "24 hours to play",
                           text: "Each duel expires a day after it's sent. Don't play in time and you forfeit the win to your opponent.",
                           tint: Color.warningText,
                           background: Color.warningBg),
            footnote: "Versus games never affect your rating — they're XP and bragging rights only.",
            startExpanded: DebugLaunch.autoOpenVersusInfo)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !open.isEmpty {
                    section("OPEN", rows: open)
                }
                if !results.isEmpty {
                    section("RESULTS", rows: results)
                }
            }
            .padding(16)
        }
    }

    private func section(_ title: String, rows: [VersusChallengeRow]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.label12).foregroundStyle(Color.textMuted)
            ForEach(rows) { row in challengeRow(row) }
        }
    }

    @ViewBuilder
    private func challengeRow(_ row: VersusChallengeRow) -> some View {
        if let me = auth.userID {
            let c = row.challenge
            let played = c.hasPlayed(me: me)
            HStack(spacing: 12) {
                Image(systemName: c.sport.symbol).font(.system(size: 18)).foregroundStyle(Color.accentText)
                // Only the name pushes to the profile — the row's own PLAY button needs its
                // tap target intact, so this can't be a NavigationLink around the whole HStack.
                NavigationLink {
                    PublicProfileView(userID: c.opponentID(me: me), usernameHint: row.opponentUsername)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.opponentUsername ?? "Player").font(.bodyStrong).foregroundStyle(Color.textPrimary)
                        Text(Self.statusLine(c, me: me)).font(.label11).foregroundStyle(Color.textMuted)
                        if let series = row.series, let line = Self.seriesLine(series, me: me) {
                            Text(line)
                                .font(.custom(FontName.condBold, size: 12))
                                .foregroundStyle(seriesColor(series, me: me))
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if c.status == "completed" || c.status == "forfeited" {
                    if let won = c.won(me: me) {
                        Text(won ? "WIN" : "LOSS")
                            .font(.custom(FontName.condBlack, size: 14))
                            .foregroundStyle(won ? Color.successText : Color.dangerText)
                    }
                } else if !played {
                    Button {
                        Task { await play(row) }
                    } label: {
                        Text("PLAY")
                            .font(.heading)
                            .foregroundStyle(Color.onAccent)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Color.accentFill)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(PrimePressStyle())
                } else {
                    Text("WAITING").font(.label11).foregroundStyle(Color.warningText)
                }
            }
            .padding(12)
            .cardSurface()
        }
    }

    // MARK: - Status copy (pure, unit-tested in VersusStatusLineTests)

    /// One line saying where this duel stands. Forfeits are explicit about *who* didn't
    /// play: per `resolve_versus_challenge`, a single no-show resolves to `completed` with
    /// only one score recorded, while `forfeited` is reserved for the double no-show.
    static func statusLine(_ c: VersusChallenge, me: String, now: Date = Date()) -> String {
        let mine = c.myScore(me: me)
        let theirs = c.theirScore(me: me)
        switch c.status {
        case "forfeited":
            return "Expired — neither of you played"
        case "completed":
            if let mine, let theirs {
                return "You \(Int(mine * 100)) – \(Int(theirs * 100)) them"
            }
            return mine != nil
                ? "They didn't play in time — win by forfeit"
                : "Time ran out before you played — forfeit loss"
        default:
            let base = c.hasPlayed(me: me) ? "Waiting for them to play" : "Play today's puzzle"
            return "\(base) · \(timeLeftText(until: c.expiresAt, now: now))"
        }
    }

    /// "14h left" / "45m left" / "Expiring…" (past-due but the 15-minute forfeit cron
    /// hasn't swept it yet).
    static func timeLeftText(until expiry: Date, now: Date = Date()) -> String {
        let seconds = Int(expiry.timeIntervalSince(now))
        guard seconds > 0 else { return "Expiring…" }
        let hours = seconds / 3_600
        return hours >= 1 ? "\(hours)h left" : "\(max(1, seconds / 60))m left"
    }

    /// The running best-of-7 score, or the settled outcome once the series completes.
    /// Nil when the series has no decided duels yet — "Series 0–0" is noise on a first duel.
    static func seriesLine(_ series: VersusSeries, me: String) -> String? {
        let mine = series.myWins(me: me)
        let theirs = series.theirWins(me: me)
        if series.status == "completed" {
            return mine > theirs ? "Series won \(mine)–\(theirs)" : "Series lost \(mine)–\(theirs)"
        }
        guard mine + theirs > 0 else { return nil }
        return "Series \(mine)–\(theirs) · best of 7"
    }

    private func seriesColor(_ series: VersusSeries, me: String) -> Color {
        guard series.status == "completed" else { return Color.accentText }
        return series.myWins(me: me) > series.theirWins(me: me) ? Color.successText : Color.dangerText
    }

    private func play(_ row: VersusChallengeRow) async {
        guard let puzzle = await container.versus?.keep4Puzzle(id: row.challenge.puzzleId) else { return }
        playChallenge = row
        playPuzzle = puzzle
    }

    private func load() async {
        defer { loaded = true }
        guard let versus = container.versus, let userID = auth.userID else { return }
        async let openFetch = versus.pendingAndActive(userID: userID)
        async let resultsFetch = versus.recentResults(userID: userID)
        open = await openFetch
        results = await resultsFetch
    }
}

/// Challenge-a-friend sheet: username + sport, posts via `RepositoryContainer.createVersusChallenge`.
private struct ChallengeSheet: View {
    @EnvironmentObject private var container: RepositoryContainer
    @EnvironmentObject private var auth: AuthService
    @Environment(\.dismiss) private var dismiss
    let onSent: () async -> Void

    @State private var username = ""
    @State private var sport: Sport = .nfl
    @State private var errorMessage: String?
    @State private var sending = false
    /// Accepted friends, for the tap-to-fill chip row below the manual username field.
    /// Best-effort — an empty/failed load just means the chip row doesn't appear and manual
    /// entry (the pre-M19 behavior) still works untouched.
    @State private var friends: [FriendRow] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                PrimeSegmentedControl(options: Sport.allCases.map { ($0.displayName, $0) },
                                      selection: $sport)

                TextField("Opponent's username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Color.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))

                if !friends.isEmpty {
                    friendChipRow
                }

                if let errorMessage {
                    Text(errorMessage).font(.label12).foregroundStyle(Color.dangerText)
                }

                Button {
                    Task { await send() }
                } label: {
                    Text(sending ? "SENDING…" : "SEND CHALLENGE").ctaLabel()
                }
                .buttonStyle(PrimePressStyle())
                .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || sending)

                Spacer()
            }
            .padding(16)
            .background(Color.appBackground)
            .navigationTitle("New Challenge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task { await loadFriends() }
    }

    /// Accepted friends as a horizontal chip row — tapping one fills the username field so a
    /// challenge can skip typing entirely. Only shows friends with a resolved username (an
    /// unresolved one can't be typed into the field anyway).
    private var friendChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(friends) { friend in
                    if let name = friend.username {
                        Button {
                            username = name
                            Haptics.tap()
                        } label: {
                            HStack(spacing: 6) {
                                Text(friend.avatar?.isEmpty == false ? friend.avatar! : "🏟️")
                                    .font(.system(size: 14))
                                Text(name).font(.label12)
                            }
                            .foregroundStyle(Color.textPrimary)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Color.surfaceMuted)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func loadFriends() async {
        guard let social = container.social, let me = auth.userID else { return }
        let rows = await social.friendRows(me: me)
        friends = rows.filter(\.edge.isAccepted)
    }

    private func send() async {
        sending = true; errorMessage = nil
        do {
            _ = try await container.createVersusChallenge(username: username.trimmingCharacters(in: .whitespaces), sport: sport)
            await onSent()
            dismiss()
        } catch VersusError.opponentNotFound {
            errorMessage = "Couldn't find that username."
        } catch VersusError.cannotChallengeSelf {
            errorMessage = "You can't challenge yourself."
        } catch {
            errorMessage = "Something went wrong. Try again."
        }
        sending = false
    }
}

#Preview {
    let container = RepositoryContainer.make(client: nil)
    return VersusView().environmentObject(container).environmentObject(container.auth)
}
