import SwiftUI

/// Another player's profile — the shared destination every social surface (Leagues rows,
/// Community authors, Versus opponents, Friends lists) navigates to. Reads only the
/// `public_profile` RPC's leaderboard-grade projection plus the caller's own friend edge,
/// and offers the two social verbs: friend and challenge.
struct PublicProfileView: View {
    let userID: String
    /// Optional display hint so the title isn't blank while the profile loads.
    var usernameHint: String? = nil

    @EnvironmentObject private var container: RepositoryContainer
    @EnvironmentObject private var auth: AuthService

    @State private var profile: PublicProfile?
    @State private var loaded = false
    @State private var friendEdge: FriendEdge?
    @State private var working = false
    @State private var showDuelPicker = false
    @State private var challengeSentSummary: String?
    @State private var errorMessage: String?

    private var isMe: Bool { auth.userID == userID }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let profile {
                    heroCard(profile).heroReveal(0)
                    if auth.isSignedIn && !isMe { actionRow(profile).heroReveal(1) }
                    statRow(profile).heroReveal(2)
                    ratingsCard(profile).heroReveal(3)
                } else if loaded {
                    EmptyStateView(symbol: "person.crop.circle.badge.questionmark",
                                   title: "Player not found",
                                   message: "This profile isn't available.")
                } else {
                    ProgressView().tint(Color.accentText)
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(16)
        }
        .background(Color.appBackground)
        .navigationTitle(profile?.username ?? usernameHint ?? "Player")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        defer { loaded = true }
        profile = await container.social?.publicProfile(userID: userID)
        await refreshEdge()
    }

    private func refreshEdge() async {
        guard let social = container.social, let me = auth.userID, !isMe else { return }
        friendEdge = await social.edges(me: me).first {
            $0.otherID(me: me) == userID
        }
    }

    // MARK: - Hero

    private func heroCard(_ profile: PublicProfile) -> some View {
        let rating = profile.rating(for: profile.bestSport)
        let tier = Tier.forRating(rating)
        return VStack(spacing: 8) {
            AvatarView(avatar: profile.avatar, size: 84, background: Color.onAccent.opacity(0.14))
            Text(profile.username ?? "Player")
                .font(.custom(FontName.condBlack, size: 24))
                .foregroundStyle(Color.onAccent)
            HStack(spacing: 6) {
                Image(systemName: tier.symbol).font(.system(size: 13, weight: .black))
                Text("\(tier.name.uppercased()) · \(rating)").font(.label12)
            }
            .foregroundStyle(Color.onAccent.opacity(0.85))
            Text("BEST IN \(profile.bestSport.displayName.uppercased())")
                .font(.label11).foregroundStyle(Color.onAccent.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .blockCard(fill: .accentFill)
    }

    // MARK: - Actions (friend + challenge)

    @ViewBuilder
    private func actionRow(_ profile: PublicProfile) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                friendButton
                challengeButton
            }
            if let errorMessage {
                Text(errorMessage).font(.label12).foregroundStyle(Color.dangerText)
            }
            if let challengeSentSummary {
                Text("Challenge sent — \(challengeSentSummary).")
                    .font(.label12).foregroundStyle(Color.successText)
            }
        }
        .sheet(isPresented: $showDuelPicker) {
            DuelPickerSheet(opponentID: userID, opponentUsernameHint: profile.username,
                            defaultSport: profile.bestSport) { sport, format in
                challengeSentSummary = "\(sport.displayName) · \(format.displayName)"
                Haptics.success()
            }
        }
    }

    @ViewBuilder
    private var friendButton: some View {
        if let me = auth.userID {
            if let edge = friendEdge {
                if edge.isAccepted {
                    Menu {
                        Button("Remove friend", role: .destructive) {
                            Task { await mutateFriends { await container.social?.removeFriend(userID: userID) } }
                        }
                    } label: {
                        actionLabel("FRIENDS", symbol: "checkmark.circle.fill",
                                    fill: Color.successFill.opacity(0.18), ink: Color.successText)
                    }
                } else if edge.isIncomingPending(me: me) {
                    HStack(spacing: 8) {
                        Button {
                            Task { await mutateFriends { await container.social?.respond(toRequester: userID, accept: true) } }
                        } label: {
                            actionLabel("ACCEPT", symbol: "checkmark", fill: Color.accentFill, ink: Color.onAccent)
                        }
                        .buttonStyle(PrimePressStyle())
                        Button {
                            Task { await mutateFriends { await container.social?.respond(toRequester: userID, accept: false) } }
                        } label: {
                            actionLabel("DECLINE", symbol: "xmark", fill: Color.surfaceMuted, ink: Color.textMuted)
                        }
                        .buttonStyle(PrimePressStyle())
                    }
                } else {
                    Button {
                        Task { await mutateFriends { await container.social?.removeFriend(userID: userID) } }
                    } label: {
                        actionLabel("REQUESTED", symbol: "hourglass", fill: Color.surfaceMuted, ink: Color.textMuted)
                    }
                    .buttonStyle(PrimePressStyle())
                }
            } else {
                Button {
                    Task {
                        await mutateFriends {
                            try? await container.social?.sendRequest(toUserID: userID, me: me)
                        }
                    }
                } label: {
                    actionLabel("ADD FRIEND", symbol: "person.badge.plus", fill: Color.accentFill, ink: Color.onAccent)
                }
                .buttonStyle(PrimePressStyle())
                .disabled(working)
            }
        }
    }

    // Challenging resolves `userID` directly (this view was constructed with one) rather than
    // round-tripping through `profile.username` — a profile with no chosen username used to
    // disable this button outright, which was a second cold-start bottleneck independent of
    // the friends graph (see prompts/HANDOFF-multiplayer.md).
    private var challengeButton: some View {
        Button {
            Haptics.tap()
            showDuelPicker = true
        } label: {
            actionLabel("CHALLENGE", symbol: "bolt.fill", fill: Color.ink, ink: Color.surface0)
        }
        .buttonStyle(PrimePressStyle())
    }

    private func actionLabel(_ text: String, symbol: String, fill: Color, ink: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold))
            Text(text).font(.custom(FontName.condBlack, size: 14))
        }
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(fill)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private func mutateFriends(_ operation: () async -> Void) async {
        working = true; errorMessage = nil
        await operation()
        await refreshEdge()
        await container.refreshFriendBadge()
        working = false
    }

    // MARK: - Stats

    private func statRow(_ profile: PublicProfile) -> some View {
        HStack(spacing: 16) {
            statCell("STREAK", "\(profile.streak)")
            Divider().frame(height: 32)
            statCell("XP", "\(profile.xp)")
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .cardSurface()
    }

    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.label11).foregroundStyle(Color.textMuted)
            Text(value).font(.hero(26)).foregroundStyle(Color.textPrimary)
        }
        .frame(maxWidth: .infinity)
    }

    private func ratingsCard(_ profile: PublicProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RATINGS").font(.label12).foregroundStyle(Color.textMuted)
            ForEach(Sport.allCases) { sport in
                let rating = profile.rating(for: sport)
                let tier = Tier.forRating(rating)
                HStack(spacing: 8) {
                    Image(systemName: sport.symbol).font(.system(size: 14)).foregroundStyle(tier.color)
                    Text(sport.displayName).font(.heading).foregroundStyle(Color.textPrimary)
                    Spacer()
                    Text(tier.name.uppercased()).font(.label11).foregroundStyle(tier.color)
                    Text("\(rating)").font(.hero(22)).foregroundStyle(Color.textPrimary)
                        .frame(minWidth: 52, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface()
    }
}

/// Sport + format picker for sending a Versus challenge to a known `user_id`. One sheet reused
/// by every surface that already has an opponent's id in hand (this view, `FriendsView`,
/// `LeaguesView`'s standings rows) rather than three near-identical copies of the same two
/// `PrimeSegmentedControl`s — mirrors `VersusView`'s username-entry `ChallengeSheet`, minus the
/// username field this one doesn't need. Duels are no longer Keep4-only, so — unlike the old
/// sport-only menu this replaced — a format must be chosen too.
struct DuelPickerSheet: View {
    let opponentID: String
    var opponentUsernameHint: String? = nil
    var defaultSport: Sport = .nfl
    /// Fires once the challenge is confirmed sent; the sheet dismisses itself.
    let onSent: (Sport, PuzzleFormat) -> Void

    @EnvironmentObject private var container: RepositoryContainer
    @Environment(\.dismiss) private var dismiss

    @State private var sport: Sport
    @State private var format: PuzzleFormat = .keep4
    @State private var sending = false
    @State private var errorMessage: String?

    init(opponentID: String, opponentUsernameHint: String? = nil, defaultSport: Sport = .nfl,
        onSent: @escaping (Sport, PuzzleFormat) -> Void) {
        self.opponentID = opponentID
        self.opponentUsernameHint = opponentUsernameHint
        self.defaultSport = defaultSport
        self.onSent = onSent
        _sport = State(initialValue: defaultSport)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let opponentUsernameHint {
                    Text("Challenge @\(opponentUsernameHint)")
                        .font(.heading)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("SPORT").font(.label12).foregroundStyle(Color.textMuted)
                    PrimeSegmentedControl(options: Sport.allCases.map { ($0.displayName, $0) },
                                          selection: $sport)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("FORMAT").font(.label12).foregroundStyle(Color.textMuted)
                    PrimeSegmentedControl(options: PuzzleFormat.allCases.map { ($0.displayName, $0) },
                                          selection: $format)
                }

                if let errorMessage {
                    Text(errorMessage).font(.label12).foregroundStyle(Color.dangerText)
                }

                Button {
                    Task { await send() }
                } label: {
                    Text(sending ? "SENDING…" : "SEND CHALLENGE").ctaLabel(fill: .ink, on: .surface0)
                }
                .buttonStyle(PrimePressStyle())
                .disabled(sending)

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
    }

    private func send() async {
        sending = true; errorMessage = nil
        do {
            _ = try await container.createVersusChallenge(userID: opponentID, sport: sport, format: format)
            onSent(sport, format)
            dismiss()
        } catch VersusError.cannotChallengeSelf {
            errorMessage = String(localized: "You can't challenge yourself.")
        } catch VersusError.noUnplayedPuzzle {
            errorMessage = String(localized: "No fresh \(format.displayName) board left for \(sport.displayName) right now — try another format or sport.")
        } catch {
            errorMessage = String(localized: "Couldn't send the challenge. Try again.")
        }
        sending = false
    }
}
