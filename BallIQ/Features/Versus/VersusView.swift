import SwiftUI

struct VersusView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @EnvironmentObject private var auth: AuthService

    @State private var open: [VersusChallengeRow] = []
    @State private var results: [VersusChallengeRow] = []
    @State private var loaded = false
    @State private var showChallengeSheet = false
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
        .sheet(isPresented: $showChallengeSheet) {
            ChallengeSheet { await load() }
        }
        .fullScreenCover(item: $playPuzzle) { puzzle in
            Keep4GameView(puzzle: puzzle, ranked: false, versusChallengeID: playChallenge?.challenge.id)
                .environmentObject(container)
        }
    }

    private var signInPrompt: some View {
        EmptyStateView(symbol: "bolt.fill",
                       title: "Versus",
                       message: "Sign in to challenge friends to a head-to-head on today's puzzle.")
    }

    private var emptyState: some View {
        EmptyStateView(symbol: "bolt.fill",
                       title: "No challenges yet",
                       message: "Challenge a friend by username.",
                       actionTitle: "New challenge") { showChallengeSheet = true }
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
                        Text(statusLine(c, me: me)).font(.label11).foregroundStyle(Color.textMuted)
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

    private func statusLine(_ c: VersusChallenge, me: String) -> String {
        if c.status == "completed" || c.status == "forfeited" {
            guard let mine = c.myScore(me: me), let theirs = c.theirScore(me: me) else { return "Forfeited" }
            return "You \(Int(mine * 100)) – \(Int(theirs * 100)) them"
        }
        return c.hasPlayed(me: me) ? "Waiting for them to play" : "Play today's puzzle"
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
