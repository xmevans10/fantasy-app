import SwiftUI

struct VersusView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @EnvironmentObject private var auth: AuthService
    /// Root tab selection — the signed-out empty state's "Sign in" CTA jumps to the
    /// Profile tab (4), where the actual sign-in buttons live. Defaults to a dead
    /// binding so previews/older call sites don't have to care.
    var selectedTab: Binding<Int> = .constant(0)

    @State private var open: [VersusChallengeRow] = []
    @State private var results: [VersusChallengeRow] = []
    @State private var loaded = false
    @State private var showChallengeSheet = false
    @State private var showVersusInfo = false
    /// Driven by `-screenshotLadder` (see `DebugLaunch`) so the pushed ladder can be captured
    /// non-interactively, the same way `-screenshotBrowse` reaches the Browse archive.
    @State private var showLadder = false
    /// The duel currently being opened or played. `board` is set only once the clock has
    /// actually started server-side, so a failed `start_versus_challenge` can never present a
    /// board with no clock on it.
    @State private var board: DuelBoard?
    @State private var startingID: Int?
    @State private var startError: String?

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
            .navigationDestination(isPresented: $showLadder) {
                LadderView().environmentObject(container).environmentObject(auth)
            }
            .navigationTitle("Versus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Wordmark.toolbarItem()
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
                        .accessibilityLabel("New duel")
                    }
                }
            }
        }
        .task { await load() }
        .onAppear {
            if DebugLaunch.autoOpenVersusInfo || HowItWorksSheet.shouldAutoPresent(feature: "versus") {
                showVersusInfo = true
            }
            if DebugLaunch.autoOpenLadder { showLadder = true }
        }
        .sheet(isPresented: $showChallengeSheet) {
            ChallengeSheet { await load() }
        }
        .sheet(isPresented: $showVersusInfo) { versusInfoSheet }
        .alert("Couldn't open that duel",
               isPresented: Binding(get: { startError != nil }, set: { if !$0 { startError = nil } })) {
            Button("OK", role: .cancel) { Task { await load() } }
        } message: {
            Text(startError ?? "")
        }
        .fullScreenCover(item: $board, onDismiss: { Task { await load() } }) { board in
            board.view.environmentObject(container)
        }
    }

    /// Signed out, the ladder leads.
    ///
    /// It is the only thing on this screen a signed-out player can act on, and it is the honest
    /// answer to "why would I sign in" — so it goes above the sign-in pitch rather than under a
    /// paragraph about duels they can't send yet.
    private var signInPrompt: some View {
        ScrollView {
            VStack(spacing: 16) {
                ladderHero
                promptCard(title: "Duel a real person",
                           message: "Sign in to challenge anyone 1v1 on the same board. Same clock, highest score wins, first to 4 takes the series.",
                           actionTitle: "SIGN IN") { selectedTab.wrappedValue = 4 }
            }
            .padding(16)
        }
    }

    /// No duels yet — same shape and the same reason. This screen is exactly where a player
    /// with nobody to play lands, and "type a stranger's username" is the ask that produced
    /// zero completed duels in the first place.
    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 16) {
                ladderHero
                promptCard(title: "Duel a real person",
                           message: "Challenge anyone in K4C4, Who am I? or The Grid. Same board, same clock — a tie goes to whoever was faster.",
                           actionTitle: "NEW DUEL") { showChallengeSheet = true }
            }
            .padding(16)
        }
    }

    /// The ladder as the screen's hero when there is nothing else to do: full-width block card,
    /// the next opponent named, and real progress. A bot with a name and a face is a more
    /// concrete invitation than "30 bot opponents" ever was.
    private var ladderHero: some View {
        NavigationLink {
            LadderView().environmentObject(container).environmentObject(auth)
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "figure.stair.stepper")
                        .font(.system(size: 13, weight: .bold))
                    Text("THE LADDER").font(.label12)
                    Spacer()
                    Text("\(container.ladderProgress.highestRung)/30")
                        .font(.custom(FontName.condBlack, size: 13))
                        .monospacedDigit()
                }
                .foregroundStyle(Color.onAccent.opacity(0.85))

                Text(ladderHeadline)
                    .font(.title)
                    .foregroundStyle(Color.onAccent)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Every rung is a bot that plays the same board you do, on the same clock — and you watch its score climb while you play.")
                    .font(.label12)
                    .foregroundStyle(Color.onAccent.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)

                // A progress bar rather than a number alone: 30 rungs is a journey, and the bar
                // is the only element here that says how long.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.onAccent.opacity(0.25))
                        Capsule().fill(Color.onAccent)
                            .frame(width: max(4, geo.size.width
                                              * min(1, Double(container.ladderProgress.highestRung) / 30)))
                    }
                }
                .frame(height: 6)

                Text(container.ladderProgress.highestRung == 0 ? "START THE CLIMB" : "CONTINUE")
                    .font(.heading)
                    .foregroundStyle(Color.accentText)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(Color.onAccent)
                    .clipShape(Capsule())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .blockCard(fill: Color.accentFill)
        }
        .buttonStyle(.plain)
    }

    /// The compact ladder entry, for when the list already has real duels above it. Same
    /// destination as `ladderHero`, a quarter of the height — it should not compete with a duel
    /// that has a clock running on it.
    private var ladderStrip: some View {
        NavigationLink {
            LadderView().environmentObject(container).environmentObject(auth)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "figure.stair.stepper")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.onAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("The Ladder").font(.bodyStrong).foregroundStyle(Color.onAccent)
                    Text(ladderHeadline)
                        .font(.label11).foregroundStyle(Color.onAccent.opacity(0.8))
                        .lineLimit(1)
                }
                Spacer()
                Text("\(container.ladderProgress.highestRung)/30")
                    .font(.custom(FontName.condBlack, size: 13))
                    .monospacedDigit()
                    .foregroundStyle(Color.onAccent.opacity(0.85))
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.onAccent.opacity(0.7))
            }
            .padding(14)
            .blockCard(fill: Color.accentFill)
        }
        .buttonStyle(.plain)
    }

    private var ladderHeadline: String {
        let high = container.ladderProgress.highestRung
        return high == 0
            ? String(localized: "Thirty opponents, ready when you are.")
            : String(localized: "Rung \(high + 1) is waiting.")
    }

    /// The secondary ask below the hero — a card, not a full-screen empty state, because it is
    /// no longer the only thing on the screen.
    private func promptCard(title: LocalizedStringKey, message: LocalizedStringKey,
                            actionTitle: LocalizedStringKey,
                            action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.bodyStrong).foregroundStyle(Color.textPrimary)
            Text(message)
                .font(.label12).foregroundStyle(Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: action) {
                Text(actionTitle)
                    .font(.heading)
                    .foregroundStyle(Color.surface0)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.ink)
                    .clipShape(Capsule())
            }
            .buttonStyle(PrimePressStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface()
    }

    /// Copy derives from the spec's competitive glossary; mechanics mirror
    /// `resolve_versus_challenge` in supabase/schema.sql.
    private var versusInfoSheet: some View {
        HowItWorksSheet(
            title: "Versus Duels",
            intro: "A 1v1 duel: you and your opponent play the same board, each against your own clock, and the scores settle it.",
            symbol: "bolt.fill",
            tint: Color.accentText,
            tintBackground: Color.accentBg,
            rules: [
                .init(symbol: "person.2.fill",
                      title: "Same board, both of you",
                      detail: "Duel anyone in K4C4, Who am I? or The Grid. The board comes from the archive and is one neither of you has played, so nobody starts with the answers."),
                .init(symbol: "timer",
                      title: "Your clock starts when you open it",
                      detail: "Play whenever you like — but once the board is on screen you're against the clock, and the timer keeps running if you leave the app."),
                .init(symbol: "hare.fill",
                      title: "A tie goes to the faster run",
                      detail: "Dead-even scores are broken on how long each of you took, not on who sent the duel."),
                .init(symbol: "trophy.fill",
                      title: "Race to 4",
                      detail: "Every duel against the same player in the same sport and game stacks into a running series — first to 4 wins takes it."),
            ],
            callout: .init(symbol: "clock.fill",
                           label: "24 hours to open it",
                           text: "A duel expires a day after it's sent. Don't open it in time and you forfeit the win to your opponent.",
                           tint: Color.warningText,
                           background: Color.warningBg),
            footnote: "Versus games never affect your rating — they're XP and bragging rights only.",
            startExpanded: DebugLaunch.autoOpenVersusInfo)
    }

    /// Duels where the ball is in my court, soonest to expire first — an open duel is a thing
    /// with a deadline, so the one about to lapse belongs at the top rather than the one that
    /// happened to be created last.
    private var myTurn: [VersusChallengeRow] {
        guard let me = auth.userID else { return [] }
        return open.filter { !$0.challenge.hasPlayed(me: me) }
            .sorted { $0.challenge.expiresAt < $1.challenge.expiresAt }
    }

    /// Played, waiting on them. Nothing to do here — it is status, not a task.
    private var theirTurn: [VersusChallengeRow] {
        guard let me = auth.userID else { return [] }
        return open.filter { $0.challenge.hasPlayed(me: me) }
    }

    /// Ordered by **what the player can do right now**, not by which table the rows came from.
    ///
    /// The first cut led with the ladder card and then a single "OPEN" section that mixed
    /// "it's your move, and there's a clock" with "you've played, nothing to do" — the two
    /// states that most need telling apart. Now: things to act on (your duels, then the ladder,
    /// which is always playable), then things you're waiting on, then history.
    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !myTurn.isEmpty {
                    section("YOUR TURN", rows: myTurn, tint: Color.accentText)
                }
                ladderStrip
                if !theirTurn.isEmpty {
                    section("WAITING ON THEM", rows: theirTurn, tint: Color.textMuted)
                }
                if !results.isEmpty {
                    section("RESULTS", rows: results, tint: Color.textMuted)
                }
            }
            .padding(16)
        }
    }

    private func section(_ title: LocalizedStringKey, rows: [VersusChallengeRow],
                         tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title).font(.label12).foregroundStyle(tint)
                // The count belongs in the header, not implied by scrolling: "YOUR TURN 3" is
                // the whole state of the tab in one line.
                Text("\(rows.count)")
                    .font(.custom(FontName.condBlack, size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Color.surface0)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(tint)
                    .clipShape(Capsule())
            }
            ForEach(rows) { row in challengeRow(row) }
        }
    }

    @ViewBuilder
    private func challengeRow(_ row: VersusChallengeRow) -> some View {
        if let me = auth.userID {
            let c = row.challenge
            let played = c.hasPlayed(me: me)
            HStack(spacing: 12) {
                // The format is now the headline glyph, not the sport: a player can have several
                // live series against the same person, and "which game is this one" is the thing
                // that tells them apart. The sport rides along in the status line.
                Image(systemName: c.format.symbol)
                    .font(.system(size: 18)).foregroundStyle(Color.accentText)
                    .frame(width: 22)
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
                outcomeControl(row, me: me, played: played)
            }
            .padding(12)
            .cardSurface()
        }
    }

    @ViewBuilder
    private func outcomeControl(_ row: VersusChallengeRow, me: String, played: Bool) -> some View {
        let c = row.challenge
        if c.status == "completed" || c.status == "forfeited" {
            if c.isDraw {
                Text("DRAW")
                    .font(.custom(FontName.condBlack, size: 14))
                    .foregroundStyle(Color.textMuted)
            } else if let won = c.won(me: me) {
                Text(won ? "WIN" : "LOSS")
                    .font(.custom(FontName.condBlack, size: 14))
                    .foregroundStyle(won ? Color.successText : Color.dangerText)
            }
        } else if !played {
            Button {
                Task { await play(row) }
            } label: {
                // The label names the clock, because tapping it *starts* that clock server-side
                // and there is no way back. "PLAY" undersold a decision the player can't undo.
                VStack(spacing: 1) {
                    Text(startingID == c.id ? "…" : "PLAY")
                        .font(.heading)
                    Text(DuelSession.clockText(c.timeLimitSeconds))
                        .font(.label11).opacity(0.75).monospacedDigit()
                }
                .foregroundStyle(Color.onAccent)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Color.accentFill)
                .clipShape(Capsule())
            }
            .buttonStyle(PrimePressStyle())
            .disabled(startingID != nil)
        } else {
            Text("WAITING").font(.label11).foregroundStyle(Color.warningText)
        }
    }

    // MARK: - Status copy (pure, unit-tested in VersusStatusLineTests)

    /// One line saying where this duel stands. Forfeits are explicit about *who* didn't
    /// play: per `resolve_versus_challenge`, a single no-show resolves to `completed` with
    /// only one score recorded, while `forfeited` is reserved for the double no-show, and a
    /// `completed` row with no winner is a genuine dead heat.
    static func statusLine(_ c: VersusChallenge, me: String, now: Date = Date()) -> String {
        let mine = c.myScore(me: me)
        let theirs = c.theirScore(me: me)
        switch c.status {
        case "forfeited":
            return String(localized: "Expired — neither of you played")
        case "completed":
            if let mine, let theirs {
                return c.isDraw
                    ? String(localized: "Dead heat — \(Int(mine * 100)) each, to the second")
                    : String(localized: "You \(Int(mine * 100)) – \(Int(theirs * 100)) them")
            }
            return mine != nil
                ? String(localized: "They didn't play in time — win by forfeit")
                : String(localized: "Time ran out before you played — forfeit loss")
        default:
            // "the board" rather than "today's puzzle": a duel board comes from the archive
            // now, so it is very often not today's at all.
            let base = c.hasPlayed(me: me)
                ? String(localized: "Waiting for them to play")
                : String(localized: "\(c.format.displayName) · \(c.sport.displayName)")
            return "\(base) · \(timeLeftText(until: c.expiresAt, now: now))"
        }
    }

    /// "14h left" / "45m left" / "Expiring…" (past-due but the 15-minute forfeit cron
    /// hasn't swept it yet).
    static func timeLeftText(until expiry: Date, now: Date = Date()) -> String {
        let seconds = Int(expiry.timeIntervalSince(now))
        guard seconds > 0 else { return String(localized: "Expiring…") }
        let hours = seconds / 3_600
        return hours >= 1 ? String(localized: "\(hours)h left") : String(localized: "\(max(1, seconds / 60))m left")
    }

    /// The running series score, or the settled outcome once it completes.
    /// Nil when the series has no decided duels yet — "Series 0–0" is noise on a first duel.
    static func seriesLine(_ series: VersusSeries, me: String) -> String? {
        let mine = series.myWins(me: me)
        let theirs = series.theirWins(me: me)
        if series.status == "completed" {
            return mine > theirs ? "Series won \(mine)–\(theirs)" : "Series lost \(mine)–\(theirs)"
        }
        guard mine + theirs > 0 else { return nil }
        return "Series \(mine)–\(theirs) · first to \(VersusSeries.winTarget)"
    }

    private func seriesColor(_ series: VersusSeries, me: String) -> Color {
        guard series.status == "completed" else { return Color.accentText }
        return series.myWins(me: me) > series.theirWins(me: me) ? Color.successText : Color.dangerText
    }

    /// Start the clock, fetch the exact board, present it.
    ///
    /// Order matters: the board is fetched *after* `start_versus_challenge` succeeds, so a
    /// server that refuses (duel already resolved, expired, or not ours) costs nothing. It
    /// would be worse the other way round — the clock would be running while the fetch failed.
    private func play(_ row: VersusChallengeRow) async {
        guard startingID == nil else { return }
        startingID = row.challenge.id
        defer { startingID = nil }
        // `startVersusBoard` starts the clock server-side first and only then fetches the board,
        // so a duel the server refuses (resolved, expired, not ours) costs nothing.
        guard let started = await container.startVersusBoard(row) else {
            startError = String(localized: "This duel is no longer open, or its board couldn't be loaded. Pull to refresh.")
            return
        }
        board = started
    }

    private func load() async {
        defer { loaded = true }
        guard let versus = container.versus, let userID = auth.userID else { return }
        async let openFetch = versus.openChallenges(userID: userID)
        async let resultsFetch = versus.recentResults(userID: userID)
        open = await openFetch
        results = await resultsFetch
    }
}

/// New-duel sheet: opponent + sport + game, posts via `RepositoryContainer.createVersusChallenge`.
private struct ChallengeSheet: View {
    @EnvironmentObject private var container: RepositoryContainer
    @EnvironmentObject private var auth: AuthService
    @Environment(\.dismiss) private var dismiss
    let onSent: () async -> Void

    @State private var username = ""
    @State private var sport: Sport = .nfl
    @State private var format: PuzzleFormat = .keep4
    @State private var errorMessage: String?
    @State private var sending = false
    /// Accepted friends, for the tap-to-fill chip row below the manual username field.
    /// Best-effort — an empty/failed load just means the chip row doesn't appear and manual
    /// entry still works untouched. The chips carry a user id, so tapping one challenges
    /// directly rather than round-tripping through the name.
    @State private var friends: [FriendRow] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                labelled("SPORT") {
                    PrimeSegmentedControl(options: Sport.allCases.map { ($0.displayName, $0) },
                                          selection: $sport)
                }
                labelled("GAME") {
                    PrimeSegmentedControl(options: PuzzleFormat.allCases.map { ($0.displayName, $0) },
                                          selection: $format)
                }

                TextField("Opponent's username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Color.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))

                if !friends.isEmpty {
                    friendChipRow
                }

                Label("\(DuelSession.clockText(format.defaultDuelSeconds)) on the clock, each. The board comes from the archive — one neither of you has played.",
                      systemImage: "timer")
                    .font(.label11)
                    .foregroundStyle(Color.textMuted)
                    .multilineTextAlignment(.leading)

                if let errorMessage {
                    Text(errorMessage).font(.label12).foregroundStyle(Color.dangerText)
                }

                Button {
                    Task { await send(username: username.trimmingCharacters(in: .whitespaces)) }
                } label: {
                    Text(sending ? "SENDING…" : "SEND DUEL").ctaLabel()
                }
                .buttonStyle(PrimePressStyle())
                .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || sending)

                Spacer()
            }
            .padding(16)
            .background(Color.appBackground)
            .navigationTitle("New Duel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task { await loadFriends() }
    }

    private func labelled<Content: View>(_ title: LocalizedStringKey,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.label11).foregroundStyle(Color.textMuted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Accepted friends as a horizontal chip row — tapping one sends the duel outright. Friends
    /// without a claimed username still appear (a duel needs an id, not a name); they just show
    /// as "Player".
    private var friendChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(friends) { friend in
                    Button {
                        Haptics.tap()
                        Task { await send(userID: friend.userID) }
                    } label: {
                        HStack(spacing: 6) {
                            AvatarView(avatar: friend.avatar, size: 14)
                            Text(friend.username ?? String(localized: "Player")).font(.label12)
                        }
                        .foregroundStyle(Color.textPrimary)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Color.surfaceMuted)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(sending)
                }
            }
        }
    }

    private func loadFriends() async {
        guard let social = container.social, let me = auth.userID else { return }
        let rows = await social.friendRows(me: me)
        friends = rows.filter(\.edge.isAccepted)
    }

    private func send(username: String? = nil, userID: String? = nil) async {
        sending = true; errorMessage = nil
        do {
            if let userID {
                _ = try await container.createVersusChallenge(userID: userID, sport: sport, format: format)
            } else if let username {
                _ = try await container.createVersusChallenge(username: username, sport: sport, format: format)
            }
            await onSent()
            dismiss()
        } catch VersusError.opponentNotFound {
            errorMessage = String(localized: "Couldn't find that username.")
        } catch VersusError.cannotChallengeSelf {
            errorMessage = String(localized: "You can't duel yourself.")
        } catch VersusError.noUnplayedPuzzle {
            errorMessage = String(localized: "No \(sport.displayName) \(format.displayName) board left that neither of you has played. Try another sport or game.")
        } catch {
            errorMessage = String(localized: "Something went wrong. Try again.")
        }
        sending = false
    }
}

#Preview {
    let container = RepositoryContainer.make(client: nil)
    return VersusView().environmentObject(container).environmentObject(container.auth)
}
