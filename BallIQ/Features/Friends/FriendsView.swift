import SwiftUI

/// Friends hub (M19): add-by-username, incoming requests, the friends list, and outgoing
/// (sent) requests. Mirrors `VersusView`'s shape (sign-in gate → loading → empty → list) so
/// the two social surfaces feel like one system.
struct FriendsView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @EnvironmentObject private var auth: AuthService

    @State private var rows: [FriendRow] = []
    @State private var loaded = false

    @State private var usernameField = ""
    @State private var addError: String?
    @State private var sending = false

    /// Which friend's challenge menu most recently fired, for the transient "sent" line —
    /// keyed by userID since multiple friend rows share this screen.
    @State private var challengeSentFor: String?

    var body: some View {
        NavigationStack {
            Group {
                if !auth.isSignedIn {
                    signInPrompt
                } else if !loaded {
                    ProgressView().tint(Color.accentText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content
                }
            }
            .background(Color.appBackground)
            .navigationTitle("Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Wordmark() } }
        }
        .task { await load() }
    }

    private var signInPrompt: some View {
        EmptyStateView(symbol: "person.2.fill",
                       title: "Friends",
                       message: "Sign in to add friends by username and start Versus battles.")
    }

    @ViewBuilder
    private var content: some View {
        if let me = auth.userID {
            let partitioned = Self.partition(rows, me: me)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    addFriendCard.heroReveal(0)
                    if partitioned.incoming.isEmpty && partitioned.accepted.isEmpty && partitioned.outgoing.isEmpty {
                        EmptyStateView(symbol: "person.2.fill",
                                       title: "No friends yet",
                                       message: "Add friends by username to compare profiles and start Versus battles.")
                            .frame(minHeight: 260)
                            .heroReveal(1)
                    } else {
                        if !partitioned.incoming.isEmpty {
                            section("REQUESTS", rows: partitioned.incoming) { requestRow($0, me: me) }
                                .heroReveal(1)
                        }
                        if !partitioned.accepted.isEmpty {
                            section("FRIENDS", rows: partitioned.accepted) { friendRow($0, me: me) }
                                .heroReveal(2)
                        }
                        if !partitioned.outgoing.isEmpty {
                            section("SENT", rows: partitioned.outgoing) { sentRow($0, me: me) }
                                .heroReveal(3)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func section<Row: Identifiable>(_ title: String, rows: [Row], @ViewBuilder row: @escaping (Row) -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.label12).foregroundStyle(Color.textMuted)
            ForEach(rows) { row($0) }
        }
    }

    // MARK: - Add friend

    private var addFriendCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ADD FRIEND").font(.label12).foregroundStyle(Color.textMuted)
            HStack(spacing: 10) {
                TextField("Username", text: $usernameField)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Color.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                Button {
                    Task { await sendRequest() }
                } label: {
                    if sending {
                        ProgressView().tint(Color.onAccent)
                            .frame(width: 44, height: 44)
                    } else {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.onAccent)
                            .frame(width: 44, height: 44)
                    }
                }
                .background(Color.accentFill)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .buttonStyle(PrimePressStyle())
                .disabled(usernameField.trimmingCharacters(in: .whitespaces).isEmpty || sending)
            }
            if let addError {
                Text(addError).font(.label12).foregroundStyle(Color.dangerText)
            }
        }
        .padding(16)
        .cardSurface()
    }

    private func sendRequest() async {
        guard let me = auth.userID else { return }
        let username = usernameField.trimmingCharacters(in: .whitespaces)
        sending = true; addError = nil
        do {
            try await container.social?.sendRequest(toUsername: username, me: me)
            usernameField = ""
            Haptics.success()
            await reload()
        } catch FriendsError.notFound {
            addError = "No player with that username."
        } catch FriendsError.cannotFriendSelf {
            addError = "That's you."
        } catch FriendsError.alreadyLinked {
            addError = "Already friends or request pending."
        } catch {
            addError = "Something went wrong. Try again."
        }
        sending = false
    }

    // MARK: - Requests (incoming pending)

    private func requestRow(_ row: FriendRow, me: String) -> some View {
        HStack(spacing: 12) {
            avatar(row)
            Text(row.username ?? "Player").font(.bodyStrong).foregroundStyle(Color.textPrimary)
            Spacer()
            Button {
                Task { await respond(row, accept: true) }
            } label: {
                Text("ACCEPT")
                    .font(.custom(FontName.condBlack, size: 13))
                    .foregroundStyle(Color.onAccent)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.accentFill)
                    .clipShape(Capsule())
            }
            .buttonStyle(PrimePressStyle())
            Button {
                Task { await respond(row, accept: false) }
            } label: {
                Text("DECLINE")
                    .font(.custom(FontName.condBlack, size: 13))
                    .foregroundStyle(Color.textMuted)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.surfaceMuted)
                    .clipShape(Capsule())
            }
            .buttonStyle(PrimePressStyle())
        }
        .padding(12)
        .cardSurface()
    }

    private func respond(_ row: FriendRow, accept: Bool) async {
        await container.social?.respond(toRequester: row.userID, accept: accept)
        await reload()
    }

    // MARK: - Friends (accepted)

    private func friendRow(_ row: FriendRow, me: String) -> some View {
        HStack(spacing: 12) {
            NavigationLink {
                PublicProfileView(userID: row.userID, usernameHint: row.username)
            } label: {
                HStack(spacing: 12) {
                    avatar(row)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.username ?? "Player").font(.bodyStrong).foregroundStyle(Color.textPrimary)
                        if challengeSentFor == row.userID {
                            Text("Challenge sent").font(.label11).foregroundStyle(Color.successText)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Menu {
                ForEach(Sport.allCases) { sport in
                    Button(sport.displayName) {
                        Task { await challenge(row, sport: sport) }
                    }
                }
            } label: {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.onVolt)
                    .frame(width: 34, height: 34)
                    .background(Color.voltFill)
                    .clipShape(Circle())
            }
            .disabled(row.username == nil)
        }
        .padding(12)
        .cardSurface()
        .contextMenu {
            Button("Remove friend", role: .destructive) {
                Task { await removeFriend(row) }
            }
        }
    }

    private func challenge(_ row: FriendRow, sport: Sport) async {
        guard let username = row.username else { return }
        do {
            _ = try await container.createVersusChallenge(username: username, sport: sport)
            challengeSentFor = row.userID
            Haptics.success()
        } catch {
            // Silent — VersusView/ChallengeSheet is the primary flow for surfacing challenge
            // errors; this menu is a shortcut and a failure here just means "try Versus tab".
        }
    }

    // MARK: - Sent (outgoing pending)

    private func sentRow(_ row: FriendRow, me: String) -> some View {
        HStack(spacing: 12) {
            avatar(row)
            Text(row.username ?? "Player").font(.bodyStrong).foregroundStyle(Color.textPrimary)
            Text("PENDING").font(.label11).foregroundStyle(Color.textMuted)
            Spacer()
            Button {
                Task { await removeFriend(row) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.textMuted)
                    .frame(width: 30, height: 30)
                    .background(Color.surfaceMuted)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .cardSurface()
    }

    private func removeFriend(_ row: FriendRow) async {
        await container.social?.removeFriend(userID: row.userID)
        await reload()
    }

    // MARK: - Shared

    private func avatar(_ row: FriendRow) -> some View {
        Group {
            if let avatar = row.avatar, !avatar.isEmpty {
                Text(avatar).font(.system(size: 22))
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.textMuted)
            }
        }
        .frame(width: 36, height: 36)
    }

    // MARK: - Data

    private func load() async {
        defer { loaded = true }
        await reload()
    }

    private func reload() async {
        guard let social = container.social, let me = auth.userID else { rows = []; return }
        rows = await social.friendRows(me: me)
        await container.refreshFriendBadge()
    }

    // MARK: - Partitioning (pure, unit-tested — see FriendsPartitionTests)

    struct Partitioned {
        let incoming: [FriendRow]
        let accepted: [FriendRow]
        let outgoing: [FriendRow]
    }

    /// Splits every edge the caller participates in into the three buckets the UI renders.
    /// Pure and side-effect-free so it's directly testable without a repository/network stub.
    /// Defensively drops any row whose `userID` is `me` — a self-edge should never occur
    /// (the backend rejects it and `SocialRepository` never produces one), but the UI must
    /// not render a "friend" row for yourself if one ever slipped through.
    static func partition(_ rows: [FriendRow], me: String) -> Partitioned {
        let valid = rows.filter { $0.userID != me }
        return Partitioned(
            incoming: valid.filter { $0.edge.isIncomingPending(me: me) },
            accepted: valid.filter { $0.edge.isAccepted },
            outgoing: valid.filter { $0.edge.isOutgoingPending(me: me) }
        )
    }
}

#Preview {
    let container = RepositoryContainer.make(client: nil)
    return FriendsView().environmentObject(container).environmentObject(container.auth)
}
