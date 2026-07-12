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
    @State private var challengeSent: Sport?
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
            Text(profile.avatar?.isEmpty == false ? profile.avatar! : "🏟️")
                .font(.system(size: 52))
                .frame(width: 84, height: 84)
                .background(Color.onAccent.opacity(0.14))
                .clipShape(Circle())
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
                challengeMenu(profile)
            }
            if let errorMessage {
                Text(errorMessage).font(.label12).foregroundStyle(Color.dangerText)
            }
            if let challengeSent {
                Text("Challenge sent — today's \(challengeSent.displayName) puzzle.")
                    .font(.label12).foregroundStyle(Color.successText)
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

    private func challengeMenu(_ profile: PublicProfile) -> some View {
        Menu {
            ForEach(Sport.allCases) { sport in
                Button(sport.displayName) {
                    Task { await challenge(profile, sport: sport) }
                }
            }
        } label: {
            actionLabel("CHALLENGE", symbol: "bolt.fill", fill: Color.voltFill, ink: Color.onVolt)
        }
        .disabled(profile.username == nil || working)
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

    private func challenge(_ profile: PublicProfile, sport: Sport) async {
        guard let username = profile.username else { return }
        working = true; errorMessage = nil; challengeSent = nil
        do {
            _ = try await container.createVersusChallenge(username: username, sport: sport)
            challengeSent = sport
            Haptics.success()
        } catch {
            errorMessage = "Couldn't send the challenge. Try again."
        }
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
