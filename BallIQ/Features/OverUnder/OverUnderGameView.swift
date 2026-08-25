import SwiftUI

/// Arcade Over/Under: guess whether a real player-season stat cleared a shown line. Session-
/// based (not a fixed daily puzzle) — plays until lives run out, then banks a high score.
/// First session of the day is ranked; replays that same day are XP-only (mirrors the
/// community `ranked: false` pattern — arcade replays must not farm the competitive ladder).
struct OverUnderGameView: View {
    /// Set when this is **one round** of a Puzzle Blitz rather than a full arcade session.
    ///
    /// The mode collapses to a single decision: no setup screen (the board arrives ready), no
    /// lives (the blitz clock is the only limit), no score or combo chip in the header (a blitz
    /// shows no score until it ends), and one `decide` before reporting to the session. See
    /// `BlitzSession` for the contract the four blitzable formats share.
    var blitz: BlitzSession? = nil
    /// The round to play, supplied by `BlitzRoundLoader`. Only read when `blitz` is set — a solo
    /// session still generates its own rounds from a pool it fetches itself.
    var blitzRound: OverUnderRound? = nil
    /// The sport `blitzRound` was drawn for. An `OverUnderRound` doesn't record its own sport,
    /// and every palette/crest/stat lookup on this board needs one.
    var blitzSport: Sport = .nfl

    @EnvironmentObject private var container: RepositoryContainer
    @Environment(\.dismiss) private var dismiss

    @State private var pool: [CatalogSeason] = []
    @State private var round: OverUnderRound?
    @State private var roundIndex = 0
    @State private var lives: LivesBank = .initial
    @State private var combo = 0
    @State private var score = 0
    @State private var correctCount = 0
    @State private var wrongCount = 0
    @State private var bestCombo = 0
    /// Split by which side the player picked, not just whether they were right — powers the
    /// "you trust the over, but it only lands N% of the time" stat, which a single correct/wrong
    /// tally can't express.
    @State private var overPicks = 0
    @State private var overCorrect = 0
    @State private var underPicks = 0
    @State private var underCorrect = 0
    @State private var startedAt: Date?
    @State private var dragX: CGFloat = 0
    @State private var lastVerdict: Bool?
    @State private var showResult = false
    @State private var beatHighScore = false
    @State private var rewards: RepositoryContainer.SessionRewards?
    @State private var loading = true
    @State private var showingSetup = true
    @State private var sport: Sport = .nfl
    /// Blitz only: a round is one decision, and both the buttons and the swipe gesture can fire
    /// it. Latches so a fast double-input can't report the same board twice.
    @State private var blitzDecided = false

    private let store = LocalOverUnderStore()
    private let commitThreshold: CGFloat = 70

    /// A blitz round has no lives at all — the run's clock is the only thing that ends anything,
    /// and a heart lost on a coin flip inside a timed run would be a second, hidden fail-state.
    private var unlimitedLives: Bool { blitz != nil || container.entitlements.hasUnlimitedOverUnderLives }
    private var dailyID: String { "overunder-\(sport.rawValue)-\(OverUnderRoundGenerator.dayString(Date()))" }

    var body: some View {
        Group {
            // `blitz == nil` on both branches: a blitz round owns neither the setup screen (its
            // board arrives ready) nor the result screen (the run's one score comes from
            // `BlitzResultView`). See `Keep4GameView.body`.
            if showResult, blitz == nil {
                OverUnderResultView(sport: sport, score: score, correctCount: correctCount,
                                    wrongCount: wrongCount, highScore: store.highScore(for: sport),
                                    beatHighScore: beatHighScore, rewards: rewards,
                                    onDone: { dismiss() })
            } else if showingSetup, blitz == nil {
                GameSetupScreen(formatName: "Over / Under", title: "Pick your sport",
                                startLabel: "Start the streak", sport: $sport,
                                onStart: { Task { await load() } },
                                onClose: { dismiss() }) { EmptyView() }
            } else {
                playBoard
            }
        }
        .background(Color.appBackground)
        .task {
            // A blitz round is fully supplied: sport and board both come from the loader, so
            // this skips the pool fetch, the setup screen and the prefetch entirely.
            if blitz != nil {
                sport = blitzSport
                round = blitzRound
                showingSetup = false
                loading = false
                startedAt = Date()
                return
            }
            sport = container.sportFilter.sport ?? .nfl
            container.catalog.prefetchDraftSpinSample(for: sport)
            // Screenshot flows target the board/result — skip the setup screen.
            if DebugLaunch.autoOpenOverUnder {
                await load()
                if DebugLaunch.autoSubmitOverUnder { forceOutOfLivesForScreenshot() }
            }
        }
        .onChange(of: sport) { _, selected in
            // Warm the pool while the player is still on setup (same pattern as Draft & Spin).
            if showingSetup { container.catalog.prefetchDraftSpinSample(for: selected) }
        }
    }

    private func load() async {
        showingSetup = false
        lives = store.loadLives()
        // Served from the shared cached arcade sample (see PlayerSeasonCatalog.arcadePool) —
        // warm from Home's prefetch or this setup screen's own, so start is instant.
        let fetched = await container.catalog.arcadePool(for: sport, limit: 200)
        pool = PlayerRelevance.filter(fetched, sport: sport, minimum: 20)
        startedAt = Date()
        container.track(.gameStarted, ["format": "overunder", "sport": sport.rawValue])
        nextRound()
        loading = false
    }

    private func nextRound() {
        round = OverUnderRoundGenerator.round(from: pool, sport: sport, date: Date(), index: roundIndex)
    }

    // MARK: - Board

    private var playBoard: some View {
        VStack(spacing: 0) {
            if let blitz { BlitzStatusBar(session: blitz) }
            header
            Spacer(minLength: 0)
            if loading {
                ProgressView().tint(Color.accentText)
            } else if let round {
                roundCard(round)
                    .id(round.id)
                    .padding(.horizontal, 16)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 14)), removal: .opacity))
            } else {
                EmptyStateView(symbol: "exclamationmark.triangle", title: "No data",
                              message: "Couldn't load player seasons for \(sport.displayName) right now.")
            }
            Spacer(minLength: 0)
            footer
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Button { close() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .medium)).foregroundStyle(Color.textMuted)
                }
                .accessibilityLabel("Close")
                Spacer()
                Text("OVER / UNDER").font(.label12).foregroundStyle(Color.accentText)
                Spacer()
                // No hearts in a blitz — see `unlimitedLives`. A hidden mirror of the close
                // glyph balances the row exactly, where a guessed spacer width left the title
                // visibly off-centre.
                if blitz == nil {
                    livesRow
                } else {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .medium)).hidden()
                }
            }
            // The score and combo chips are the one thing a blitz must not render: "scoring
            // displayed ONLY at the end" is this mode's defining rule, and a running total here
            // would break it on the busiest board in the rotation.
            if blitz == nil {
                HStack(spacing: 10) {
                    statChip(label: String(localized: "Score"), value: "\(score)")
                    if combo > 0 {
                        statChip(label: String(localized: "Combo"), value: "×\(String(format: "%.1f", OverUnderScoring.comboMultiplier(consecutiveCorrect: combo)))",
                                fill: .voltFill, on: .onVolt)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.hairline).frame(height: Hairline.width) }
    }

    private var livesRow: some View {
        HStack(spacing: 3) {
            if unlimitedLives {
                Image(systemName: "infinity").font(.system(size: 15, weight: .bold)).foregroundStyle(Color.proText)
            } else {
                ForEach(0..<LivesBank.maxLives, id: \.self) { i in
                    Image(systemName: i < lives.count ? "heart.fill" : "heart")
                        .font(.system(size: 13))
                        .foregroundStyle(i < lives.count ? Color.dangerFill : Color.textMuted.opacity(0.4))
                }
            }
        }
        .accessibilityLabel(unlimitedLives ? "Unlimited lives" : "\(lives.count) of \(LivesBank.maxLives) lives")
    }

    private func statChip(label: String, value: String, fill: Color = .surfaceMuted, on: Color = .textPrimary) -> some View {
        HStack(spacing: 5) {
            Text(label.uppercased()).font(.label11).foregroundStyle(on.opacity(0.7))
            Text(value).font(.custom(FontName.condBlack, size: 14)).foregroundStyle(on)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(fill)
        .clipShape(Capsule())
    }

    private func roundCard(_ round: OverUnderRound) -> some View {
        let team = TeamColors.palette(sport: sport, abbr: round.player.teamAbbr)
        let tint: Color? = dragX > commitThreshold ? .successFill : (dragX < -commitThreshold ? .dangerFill : nil)
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 11) {
                PlayerHeadshotBadge(headshot: round.player.headshot, tint: team.onPrimary, name: round.player.name)
                VStack(alignment: .leading, spacing: 3) {
                    Text(round.player.name.uppercased())
                        .font(.custom(FontName.condBlack, size: 21))
                        .foregroundStyle(team.onPrimary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(CardLabel.dotJoined(round.player.teamAbbr.uppercased(),
                                             String(round.player.seasonYear)))
                        .font(.custom(FontName.condBold, size: 12))
                        .foregroundStyle(team.onPrimary.opacity(0.72))
                }
                Spacer(minLength: 6)
                TeamLogoBadge(sport: sport, teamAbbr: round.player.teamAbbr, tint: team.onPrimary)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(team.primary)

            VStack(spacing: 6) {
                Text(round.stat.label.uppercased())
                    .font(.label12)
                    .foregroundStyle(Color.textMuted)
                Text(round.stat.format(round.threshold))
                    .font(.hero(56))
                    .foregroundStyle(Color.textPrimary)
                Text("OVER OR UNDER?")
                    .font(.label11)
                    .foregroundStyle(Color.textMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)

            overUnderControl
                .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 2)
        }
        .background(tint?.opacity(0.10) ?? Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.borderInk, lineWidth: 3))
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.borderInk).offset(x: 5, y: 5))
        .offset(x: dragX)
        .gesture(dragGesture)
        .animation(Motion.snap, value: dragX)
        .accessibilityAction(named: "Over") { decide(guessOver: true) }
        .accessibilityAction(named: "Under") { decide(guessOver: false) }
    }

    private static let underGradient = LinearGradient(
        colors: [Color(hex: 0xFF5B4A), Color(hex: 0xC41F14)], startPoint: .top, endPoint: .bottom)
    private static let overGradient = LinearGradient(
        colors: [Color(hex: 0x2BD27A), Color(hex: 0x12923F)], startPoint: .top, endPoint: .bottom)

    private var overUnderControl: some View {
        HStack(spacing: 0) {
            segment(title: String(localized: "Under"), guessOver: false, gradient: Self.underGradient)
            segment(title: String(localized: "Over"), guessOver: true, gradient: Self.overGradient)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.borderInk, lineWidth: 2))
    }

    private func segment(title: String, guessOver: Bool, gradient: LinearGradient) -> some View {
        Button { decide(guessOver: guessOver) } label: {
            Text(title.uppercased())
                .font(.custom(FontName.condBlack, size: 15))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(gradient)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(round?.threshold.description ?? "")")
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in dragX = value.translation.width }
            .onEnded { value in
                let dx = value.translation.width
                if dx > commitThreshold { decide(guessOver: true) }
                else if dx < -commitThreshold { decide(guessOver: false) }
                dragX = 0
            }
    }

    private var footer: some View {
        Text("Swipe right for Over, left for Under — or tap below.")
            .font(.label11)
            .foregroundStyle(Color.textMuted)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Logic

    /// Leaving the board — ends the whole run inside a blitz rather than dismissing this view.
    /// See `Keep4GameView.close`.
    private func close() {
        if let blitz { blitz.endEarly() } else { dismiss() }
    }

    private func decide(guessOver: Bool) {
        guard let round else { return }
        let correct = guessOver == round.isOver
        // One decision is the whole blitz round: report it and stop. `performance` is binary
        // here (there is one call and it was right or it wasn't), which `BlitzScoring` then
        // rebases against this format's 0.5 chance floor — so a coin flip pays nothing and only
        // calls you actually made pay out.
        if let blitz {
            // Neutral tap, deliberately not `success`/`reject`: an over/under call is the one
            // board in the rotation where the player can't tell how they did, and a haptic
            // verdict is a per-round score by another name.
            guard !blitzDecided else { return }
            blitzDecided = true
            Haptics.tap()
            blitz.finishRound(format: .overunder, sport: sport, puzzleID: round.id,
                              performance: correct ? 1 : 0, cleared: correct)
            return
        }
        if guessOver { overPicks += 1 } else { underPicks += 1 }
        if correct {
            score += OverUnderScoring.points(consecutiveCorrectBeforeThisRound: combo)
            combo += 1
            bestCombo = max(bestCombo, combo)
            correctCount += 1
            if guessOver { overCorrect += 1 } else { underCorrect += 1 }
            Haptics.success()
        } else {
            combo = 0
            wrongCount += 1
            Haptics.reject()
            if !unlimitedLives {
                lives = lives.losingALife()
                store.saveLives(lives)
            }
        }

        if !unlimitedLives && lives.isEmpty {
            finish()
        } else {
            roundIndex += 1
            withAnimation(Motion.snap) { nextRound() }
        }
    }

    private func finish() {
        beatHighScore = store.recordScore(score, for: sport)
        let attempts = correctCount + wrongCount
        let performance = attempts > 0 ? Double(correctCount) / Double(attempts) : 0
        let ranked = !container.hasCompletedToday(puzzleID: dailyID)
        let detail = RepositoryContainer.SessionDetail(
            mode: .daily, score: score, maxScore: 0, correct: correctCount, attempted: attempts,
            startedAt: startedAt,
            details: OverUnderSessionDetail.build(bestCombo: bestCombo, livesLeft: lives.count,
                                                  overPicks: overPicks, overCorrect: overCorrect,
                                                  underPicks: underPicks, underCorrect: underCorrect))
        Task {
            rewards = await container.complete(format: .overUnder, sport: sport, performance: performance,
                                               perfect: wrongCount == 0 && correctCount > 0,
                                               puzzleID: dailyID, ranked: ranked, detail: detail)
            withAnimation(Motion.snap) { showResult = true }
        }
        // Every finished run posts (not just local highs) — the weekly board ranks each
        // user's best server-side, so a lower run this week is a harmless no-op there.
        Task { await container.submitArcadeScore(game: .overUnder, sport: sport, score: score) }
    }

    /// `-screenshotOverUnderResult`: simctl can't play through a real session, so force an
    /// immediate out-of-lives finish instead.
    private func forceOutOfLivesForScreenshot() {
        score = 350; correctCount = 3; wrongCount = 3
        lives = LivesBank(count: 0, lastLostAt: Date())
        finish()
    }
}

/// Assembles the Over/Under `GameResultDetails` payload — pulled out of `finish()` so the
/// over/under split (the one genuinely new piece of state here) can be tested as a pure
/// function against a simulated sequence of picks, without driving the view itself.
enum OverUnderSessionDetail {
    static func build(bestCombo: Int, livesLeft: Int, overPicks: Int, overCorrect: Int,
                      underPicks: Int, underCorrect: Int) -> GameResultDetails {
        var details = GameResultDetails()
        details.bestCombo = bestCombo
        details.livesLeft = livesLeft
        details.overPicks = overPicks
        details.overCorrect = overCorrect
        details.underPicks = underPicks
        details.underCorrect = underCorrect
        return details
    }
}
