import SwiftUI

/// The words and colors for one moment, derived once from the player's actual situation.
///
/// Pulled out of the views because `MomentSheet` and `MomentInlineCard` render the same ask at two
/// volumes and must not drift into saying two different things — the second, quieter ask is the
/// same offer, not a different one. It's also the part worth reading in a diff: the numbers here
/// are the whole reason these prompts land, since "you've played 5" is a fact about *them* and
/// "claim your username" is a fact about our database.
struct MomentCopy {
    let symbol: String
    let tint: Color
    let onTint: Color
    let headline: LocalizedStringKey
    let detail: String
    let cta: LocalizedStringKey

    init(moment: Moment, context: MomentContext) {
        switch moment {
        case .claimUsername:
            symbol = "person.crop.circle.badge.plus"
            tint = .voltFill
            onTint = .onVolt
            headline = "LOCK IN YOUR NAME"
            // Signed-out players are being asked for an account, not just a handle, so the
            // sentence has to earn the bigger ask — and it earns it with what they'd lose.
            if context.isSignedIn {
                detail = context.gamesPlayed > 0
                    ? String(localized: "You've played \(context.gamesPlayed). Time everyone knew who did it, your name shows up on leaderboards, Versus and friend requests.")
                    : String(localized: "Your name shows up on leaderboards, Versus and friend requests.")
                cta = "CLAIM MY USERNAME"
            } else {
                detail = String(localized: "Your streak, rating and league spot live on your account, and a username is how anyone finds you.")
                cta = "CREATE MY ACCOUNT"
            }

        case .favoriteTeam(let sport):
            symbol = sport.symbol
            tint = sport.cardFill
            onTint = sport.onCardFill
            headline = "WHO DO YOU RIDE WITH?"
            let played = context.gamesBySport[sport] ?? 0
            // The payoff is real and already shipped: `favoriteTeamMatch` badges puzzles
            // featuring your club on Home, Browse and Community. Say the thing it does.
            detail = String(localized: "\(played) \(sport.displayName) rounds in. Pick your team and we'll flag every puzzle that features them.")
            cta = "PICK MY TEAM"

        case .addFriend:
            symbol = "person.2.fill"
            tint = .accentFill
            onTint = .onAccent
            headline = "BETTER WITH A RIVAL"
            detail = context.streak >= MomentEngine.friendStreakThreshold
                ? String(localized: "A \(context.streak)-day streak and nobody to beat. Add a friend and every daily becomes a head-to-head.")
                : String(localized: "You've played \(context.gamesPlayed) and nobody's chasing you. Add a friend and every daily becomes a head-to-head.")
            cta = "ADD A FRIEND"
        }
    }
}

/// The full-volume ask: a medium-detent sheet with the hero sticker, the number they earned, one
/// primary CTA and a muted way out.
///
/// **Layout note — do not "improve" this into a centered layout.** No `ViewThatFits`, no
/// `GeometryReader`. `OnboardingView` records the 2026-07-28 bisect: any layout-negotiating
/// container renders a *ghost duplicate* of the secondary button on iPad (reproduced on iPad Air
/// 11-inch, never on any iPhone, which is why it shipped). A bare `ScrollView` is the fix, and the
/// lost centering is the price.
struct MomentSheet: View {
    let moment: Moment
    let context: MomentContext

    @EnvironmentObject private var container: RepositoryContainer
    @EnvironmentObject private var moments: MomentPresenter
    @Environment(\.dismiss) private var dismiss

    /// Which destination this moment opened. One optional per destination rather than an enum,
    /// because each is a different presentation API and only ever one can be live.
    @State private var showIdentityEditor = false
    @State private var showFriends = false
    @State private var pickingTeamFor: Sport?
    @State private var signInError: String?
    @State private var celebrate = 0

    private var copy: MomentCopy { MomentCopy(moment: moment, context: context) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    sticker.heroReveal(0)
                    VStack(spacing: 10) {
                        Text(copy.headline)
                            .font(.display1)
                            .foregroundStyle(Color.textPrimary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                        Text(copy.detail)
                            .font(.body14)
                            .foregroundStyle(Color.textMuted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .heroReveal(1)
                    if let signInError {
                        Text(signInError).font(.label12).foregroundStyle(Color.dangerText)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 28)
            }
            .scrollBounceBehavior(.basedOnSize)

            actions
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .heroReveal(2)
        }
        .background(Color.appBackground)
        .onAppear { moments.markShown(container: container) }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .celebrate(on: $celebrate, intensity: 60)
        .sheet(isPresented: $showIdentityEditor, onDismiss: completeIfUsernameClaimed) {
            IdentityEditorSheet().environmentObject(container)
        }
        .sheet(item: $pickingTeamFor) { sport in
            TeamPicker(selection: Binding(
                get: { container.favoriteTeams.team(for: sport) },
                set: { setFavoriteTeam($0, for: sport) }),
                sport: sport, fallbackAbbrs: container.catalog.teams(for: sport))
        }
        // FriendsView wraps itself in a NavigationStack (it's presented as a navigationDestination
        // from Profile), so it stands up as a sheet unmodified.
        .sheet(isPresented: $showFriends, onDismiss: completeIfFriendAdded) {
            FriendsView().environmentObject(container).environmentObject(container.auth)
        }
    }

    /// One sport/social glyph as a sticker: tinted fill, ink ring, hard ledge shadow — the same
    /// treatment `OnboardingView.sportSticker` gives the sport rows, so a moment reads as part of
    /// the same first-run family rather than a system alert.
    private var sticker: some View {
        Image(systemName: copy.symbol)
            .font(.system(size: 34, weight: .bold))
            .foregroundStyle(copy.onTint)
            .frame(width: 84, height: 84)
            .background(
                ZStack {
                    Circle().fill(Color.borderInk).offset(x: 4, y: 4)
                    Circle().fill(copy.tint)
                    Circle().strokeBorder(Color.borderInk, lineWidth: 3)
                }
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 12) {
            // The one case where the CTA isn't a button: a signed-out player needs an account
            // before a username exists to claim, and Apple's button can't be reskinned.
            if case .claimUsername = moment, !container.isSignedIn {
                SignInButtons(surface: "moment_claim_username",
                              onError: { signInError = $0 },
                              onSignedIn: signedInFromMoment)
            } else {
                Button { accept() } label: {
                    Text(copy.cta).ctaLabel(fill: copy.tint, on: copy.onTint)
                }
                .buttonStyle(PrimePressStyle())
            }

            // Friends is the one moment that can dead-end: "add a friend by username" needs a
            // friend who already has the app. Sharing the card is the same ask pointed outward,
            // and it's the measured half of the viral loop (`share_tapped` → `share_link_opened`).
            if case .addFriend = moment, let username = container.identity.username {
                shareCardButton(username: username)
            }

            Button { close() } label: {
                Text("Not now")
                    .font(.bodyStrong)
                    .foregroundStyle(Color.textMuted)
                    .padding(.vertical, 4)
            }
        }
    }

    private func shareCardButton(username: String) -> some View {
        let card = ProfileShareCardView(
            username: username,
            avatar: container.identity.avatar?.isEmpty == false ? container.identity.avatar! : "🏟️",
            sport: bestSport, tier: Tier.forRating(container.rating(for: bestSport)),
            rating: container.rating(for: bestSport),
            streak: container.streak, level: container.level)
        return ShareLink(item: card.rendered(),
                         preview: SharePreview("My Playbook profile", image: card.rendered())) {
            Text("SHARE MY CARD")
                .font(.heading)
                .foregroundStyle(Color.accentText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .stroke(Color.accentText.opacity(0.5), lineWidth: 2))
        }
        .buttonStyle(PrimePressStyle())
        .simultaneousGesture(TapGesture().onEnded {
            container.track(.shareTapped, AnalyticsEvent.shareProperties(
                surface: "moment_add_friend", format: "profile", artifact: .profileImage,
                extra: ["sport": bestSport.rawValue]))
        })
    }

    /// Matches `ProfileView.bestSport`'s convention (ties favor `Sport.allCases` order) so the
    /// card shared from here is identical to the one shared from Profile.
    private var bestSport: Sport {
        Sport.allCases.reduce(Sport.nfl) {
            container.rating(for: $1) > container.rating(for: $0) ? $1 : $0
        }
    }

    // MARK: - Actions

    private func accept() {
        Haptics.tap()
        moments.accept(moment, container: container)
        switch moment {
        case .claimUsername:        showIdentityEditor = true
        case .favoriteTeam(let s):  pickingTeamFor = s
        case .addFriend:            showFriends = true
        }
    }

    /// Sign-in landed. A brand-new account has no `profiles.username`, which is the thing this
    /// moment was asking for — so keep going into the editor rather than declaring victory at the
    /// account. A returning user who already had a name is done, and the moment retires.
    private func signedInFromMoment() {
        if container.identity.username == nil {
            showIdentityEditor = true
        } else {
            complete()
        }
    }

    /// The editor dismisses on save *and* on cancel, so the outcome is read back off the identity
    /// rather than assumed — a cancel leaves the moment un-satisfied and eligible for its one
    /// remaining (inline) ask.
    private func completeIfUsernameClaimed() {
        if container.identity.username != nil { complete() } else { close() }
    }

    private func setFavoriteTeam(_ abbr: String?, for sport: Sport) {
        var updated = container.favoriteTeams
        updated.setTeam(abbr, for: sport)
        Task { await container.saveFavoriteTeams(updated) }
        if abbr != nil { complete() } else { close() }
    }

    /// A sent request is enough to call this done — the other side accepting is not something the
    /// player controls, and re-asking someone with a request in flight would read as broken.
    private func completeIfFriendAdded() {
        Task {
            await container.refreshFriendBadge()
            if container.acceptedFriends > 0 { complete() } else { close() }
        }
    }

    private func complete() {
        Haptics.success()
        celebrate += 1
        moments.complete(moment, container: container)
        dismiss()
    }

    private func close() {
        moments.dismiss()
        dismiss()
    }
}

/// The second, quieter ask — Home's inline prompt slot, the shape `pushPrimerCard` occupies.
///
/// Same offer, same words, no interruption: it sits in the page and can be scrolled past. Tapping
/// it hands off to the sheet, so there is exactly one implementation of what each CTA actually
/// does (see `MomentSheet.accept`).
struct MomentInlineCard: View {
    let moment: Moment
    let context: MomentContext
    let onTap: () -> Void
    let onDismiss: () -> Void

    private var copy: MomentCopy { MomentCopy(moment: moment, context: context) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: copy.symbol)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(copy.tint)
                Text(copy.headline)
                    .font(.heading)
                    .foregroundStyle(Color.textPrimary)
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.textMuted)
                }
                .accessibilityLabel("Dismiss")
            }
            Text(copy.detail)
                .font(.label12)
                .foregroundStyle(Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onTap) {
                Text(copy.cta)
                    .font(.custom(FontName.condBlack, size: 14))
                    .foregroundStyle(copy.onTint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(copy.tint)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
            .buttonStyle(PrimePressStyle())
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .blockCard()
    }
}
