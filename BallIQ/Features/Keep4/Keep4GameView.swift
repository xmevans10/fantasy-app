import SwiftUI

struct Keep4GameView: View {
    let puzzle: Keep4Puzzle
    /// Daily play is ranked; community puzzles pass `ranked: false` (XP only, no rating).
    var ranked: Bool = true
    /// Set for community puzzles so a play is logged (powers the Popular sort).
    var communityID: String? = nil
    /// Community author's username — personalizes the custom-scoring explainer when known.
    var authorName: String? = nil
    /// Set when played from the Versus tab or the bot ladder: the score is submitted to the
    /// duel, and a server-authoritative clock runs over the board. See `DuelSession`.
    var duel: DuelSession? = nil
    /// Set when opened from a `balliq://challenge` link. Distinct from `duel`: that is a
    /// server-mediated series between two signed-in accounts (or a ladder rung), this is a link
    /// anyone can send anyone with no account on either end. Only ever non-nil when the
    /// resolved board is exactly the one challenged (see `ContentView.accept`). If both are
    /// somehow set, `duel` wins — it is the one with a server row behind it.
    var challenge: ChallengeLink? = nil
    /// Set when this board is one round of a Puzzle Blitz run. Suppresses this view's own result
    /// screen and its `RepositoryContainer.complete` call — a blitz banks XP once for the whole
    /// run — and reports the outcome to the session instead. See `BlitzSession`, which documents
    /// the contract all four blitzable formats share.
    ///
    /// Mutually exclusive with `duel` and `challenge` in practice; `duel` still wins if both are
    /// somehow set, for the same reason it wins over `challenge` (it is the one with a server row
    /// behind it and an opponent waiting on a submission).
    var blitz: BlitzSession? = nil

    @EnvironmentObject private var container: RepositoryContainer
    @Environment(\.dismiss) private var dismiss

    @State private var order: [PlayerSeason] = []
    @State private var index = 0
    @State private var placement: [String: Pile] = [:]
    @State private var result: Keep4Scoring.Result?
    /// Captured at the existing `track(.gameStarted)` site so the session log can carry a
    /// real duration; nil is legitimate (untimed) if `finish()` somehow runs before `onAppear`.
    @State private var startedAt: Date?
    @State private var rewards: RepositoryContainer.SessionRewards?
    @State private var mode: Keep4Mode = .normal
    @State private var showReportDialog = false
    @State private var showReportSent = false
    @State private var showScoringInfo = false
    @State private var showPaywall = false

    private let pileLimit = 4

    private var keepCount: Int { placement.values.filter { $0 == .keep }.count }
    private var cutCount: Int { placement.values.filter { $0 == .cut }.count }

    /// When a pile is full, the rest are forced into the other pile.
    private var forcedDisabledPile: Pile? {
        if keepCount >= pileLimit { return .keep }
        if cutCount >= pileLimit { return .cut }
        return nil
    }

    private var currentPlayer: PlayerSeason? {
        index < order.count ? order[index] : nil
    }

    var body: some View {
        Group {
            // `blitz == nil` is the whole "score at the end only" rule at this call site: a blitz
            // round still sets `result` (it's the double-finish guard), but must never render the
            // result screen — the run's one score comes from `BlitzResultView`. The board stays
            // up for the frame it takes `BlitzGameView` to swap in the next one.
            if let result, blitz == nil {
                Keep4ResultView(puzzle: puzzle,
                                placement: placement,
                                result: result,
                                rewards: rewards,
                                // `ranked` is already "this is today's daily" at every call
                                // site — see `Keep4ResultView.isDaily`. An accepted challenge
                                // is the one unranked path that IS on the canonical board:
                                // `ContentView.accept` only attaches one on an exact match.
                                // A duel board is neither today's daily nor the board a link
                                // named, so it must not offer the dare either of those do.
                                isDaily: duel == nil && (ranked || challenge != nil),
                                challenge: duel == nil ? challenge : nil,
                                // A ladder rung's payoff is knowing whether you beat the bot.
                                // Without this the result screen never mentions the opponent
                                // you just spent two minutes racing.
                                duelVerdict: duel?.ladder?.verdict(myHits: result.correctCount),
                                onDone: { dismiss() })
            } else {
                playBoard
            }
        }
        .background(Color.appBackground)
        .onAppear {
            if order.isEmpty {
                order = Self.blindOrder(for: puzzle)
                startedAt = Date()
                container.track(.gameStarted, ["format": "keep4", "ranked": "\(ranked)",
                                               "community": "\(communityID != nil)"])
            }
            if DebugLaunch.autoSubmitResult { autoFillForScreenshot() }
            if DebugLaunch.autoOpenScoringInfo { showScoringInfo = true }
        }
        .reportReasonDialog(isPresented: $showReportDialog) { reason in report(reason: reason) }
        .alert("Report sent", isPresented: $showReportSent) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Thanks — we'll take a look.")
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(trigger: .hardMode).environmentObject(container)
        }
    }

    /// Best-effort (matches `reportCommunity`'s own `try?` fire-and-forget).
    private func report(reason: String) {
        guard let communityID else { return }
        Task {
            await container.reportCommunity(id: communityID, reason: reason)
            Haptics.success()
            showReportSent = true
        }
    }

    // MARK: - Board

    private var playBoard: some View {
        VStack(spacing: 0) {
            if let blitz {
                // Same slot the duel bar uses, and only ever one of the two: a blitz board is
                // never also a duel board.
                BlitzStatusBar(session: blitz)
            } else if let duel {
                // Above the header, not inside it: the clock has to be the first thing on
                // screen at every scroll position and in every one of the header's states.
                // `placement.count` is cards decided, not cards known-correct (blind sort) —
                // see `DuelStatusBar.playerScore`'s doc comment for why that's still the right
                // number to race the bot's live score against.
                DuelStatusBar(session: duel, playerScore: placement.count)
            }
            header
            Spacer(minLength: 0)
            if let player = currentPlayer {
                ZStack {
                    deckStack
                    Keep4CardView(player: player,
                                  sport: puzzle.sport,
                                  assignment: nil,
                                  revealCorrect: nil,
                                  hideStats: mode == .hard,
                                  disabledPile: forcedDisabledPile) { pile in
                        decide(player: player, pile: pile)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .id(player.id)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 14)),
                        removal: .opacity))
                }
                .padding(.horizontal, 16)
            }
            Spacer(minLength: 0)
            footer
        }
        .background(Color.appBackground)
    }

    /// Hint of the remaining deck behind the current card.
    private var deckStack: some View {
        let remaining = order.count - index - 1
        return ZStack {
            if remaining >= 2 {
                RoundedRectangle(cornerRadius: Radius.card)
                    .fill(Color.surfaceMuted)
                    .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Color.borderStrong, lineWidth: 1))
                    .frame(height: 120).offset(y: 18).scaleEffect(0.92)
            }
            if remaining >= 1 {
                RoundedRectangle(cornerRadius: Radius.card)
                    .fill(Color.surface1)
                    .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Color.borderStrong, lineWidth: 1))
                    .frame(height: 130).offset(y: 9).scaleEffect(0.96)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Button { close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.textMuted)
                }
                .accessibilityLabel("Close")
                Spacer()
                Text("CARD \(min(index + 1, order.count)) OF \(order.count)")
                    .font(.label12)
                    .foregroundStyle(Color.textMuted)
                if communityID != nil {
                    Button { showReportDialog = true } label: {
                        Image(systemName: "flag")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.textMuted)
                    }
                    .accessibilityLabel("Report this puzzle")
                    .padding(.leading, 12)
                }
            }

            VStack(spacing: 4) {
                Text("K4C4")
                    .font(.label12)
                    .foregroundStyle(Color.accentText)
                Text(puzzle.theme)
                    .font(.title)
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.center)
                if let description = puzzle.description, !description.isEmpty {
                    Text(description)
                        .font(.body14)
                        .foregroundStyle(Color.textMuted)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: 6) {
                    scoringNote
                    // Season is the default grain — only the exceptions (career totals,
                    // single game) earn a second explainer chip. Stacking "ranked by real
                    // fantasy points" over "ranked by real single-season stats" on every
                    // ordinary daily read as redundant copy.
                    if puzzle.puzzleGrain() != .season {
                        GrainChip(grain: puzzle.puzzleGrain())
                    }
                }
            }

            HStack(spacing: 10) {
                tally(label: String(localized: "Keep"), count: keepCount, color: .successText)
                tally(label: String(localized: "Cut"), count: cutCount, color: .dangerText)
            }

            // `placement` here is the board's keep/cut card placement, not the M30 rating window —
            // same word, unrelated concept. The added clause is the Pro one: the HARD · PRO control
            // is a subscription upsell on card 1 of the first game a new player ever sees, so it
            // stays hidden until they have finished one. Hidden, not disabled — a greyed-out paid
            // control is the same ask wearing a worse outfit.
            if placement.isEmpty, container.entitlements.isPro || container.completedGames >= 1 {
                modePicker
            } else if mode == .hard {
                Label("Hard mode — stats hidden", systemImage: "eye.slash")
                    .font(.label11)
                    .foregroundStyle(Color.warningText)
            }
        }
        .padding(16)
        .background(Color.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.hairline).frame(height: Hairline.width)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let forced = forcedDisabledPile {
                let full = forced == .keep ? String(localized: "KEEP") : String(localized: "CUT")
                let rest = forced == .keep ? String(localized: "CUTS") : String(localized: "KEEPS")
                Label("\(full) PILE FULL — REMAINING ARE \(rest)", systemImage: "lock.fill")
                    .font(.label12)
                    .foregroundStyle(forced == .keep ? Color.dangerText : Color.successText)
            } else {
                Text("Blind sort — swipe right to Keep, left to Cut. Decisions are final.")
                    .font(.label11)
                    .foregroundStyle(Color.textMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }

    /// How this puzzle's hidden ranking was produced (PPR / era-adjusted / author's custom
    /// rule) — the pre-game scoring explainer, always visible above the deck. Tapping it
    /// opens the full formula sheet.
    private var scoringNote: some View {
        Button {
            Haptics.tap()
            showScoringInfo = true
        } label: {
            ScoringNoteChip(kind: puzzle.scoringKind(), sport: puzzle.sport,
                            author: authorName, tappable: true)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the exact scoring formula")
        .padding(.top, 2)
        .sheet(isPresented: $showScoringInfo) {
            ScoringDetailSheet(puzzle: puzzle, author: authorName,
                               isCommunity: communityID != nil)
        }
    }

    /// Hard mode is Pro-gated: selecting it while locked opens the paywall and leaves `mode`
    /// unchanged instead of silently reverting (less confusing than a picker that "snaps back").
    private var modePicker: some View {
        let hardLocked = !container.entitlements.canPlayHardMode
        let options: [(title: String, value: Keep4Mode)] = Keep4Mode.allCases.map { m in
            (title: (m == .hard && hardLocked) ? "\(m.title) · Pro" : m.title, value: m)
        }
        return PrimeSegmentedControl(options: options, selection: gatedMode)
            .frame(maxWidth: 220)
    }

    private var gatedMode: Binding<Keep4Mode> {
        Binding(
            get: { mode },
            set: { newValue in
                if newValue == .hard && !container.entitlements.canPlayHardMode {
                    showPaywall = true
                } else {
                    mode = newValue
                }
            }
        )
    }

    private func tally(label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(label.uppercased()) \(count)/\(pileLimit)")
                .font(.label12)
                .foregroundStyle(Color.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.surfaceMuted)
        .clipShape(Capsule())
    }

    // MARK: - Logic

    /// Record a final decision for the current card, then advance. Forced tail is auto-enforced
    /// because `forcedDisabledPile` blocks the full pile, so the only path always lands at 4/4.
    private func decide(player: PlayerSeason, pile: Pile) {
        guard result == nil, placement[player.id] == nil else { return }
        // Safety: never exceed a full pile.
        if pile == forcedDisabledPile { Haptics.reject(); return }

        placement[player.id] = pile
        Haptics.tap()

        if index + 1 >= order.count {
            finish()
        } else {
            withAnimation(Motion.snap) { index += 1 }
        }
    }

    /// The clock ran out. Score whatever has been decided so far — every undecided card is
    /// already counted wrong by `Keep4Scoring` (an unplaced player matches neither pile), so
    /// this is just the normal finish arriving early. A blown clock still has to resolve the
    /// duel; abandoning the run would leave the opponent waiting on a forfeit sweep.
    private func expire() {
        guard result == nil else { return }
        finish()
    }

    /// Leaving the board. Inside a blitz that means **ending the run**, not dismissing this view:
    /// this board is presented inline by `BlitzGameView`, so a bare `dismiss()` would tear down
    /// the whole blitz cover and the player would never see their score. Shared by every exit in
    /// this view so none of them can drift.
    private func close() {
        if let blitz { blitz.endEarly() } else { dismiss() }
    }

    private func finish() {
        // The clock and the eighth card can both try to finish the same run.
        guard result == nil else { return }
        let r = Keep4Scoring.score(puzzle: puzzle, placement: placement)
        if r.isPerfect { Haptics.success() } else { Haptics.commit() }
        let performance = Double(r.correctCount) / Double(puzzle.players.count)
        // A blitz round reports up and stops here: no result screen (the run's score is shown
        // once, at the end) and no `complete` (the run banks XP once, for all its boards).
        // `cleared` is "beat the chance floor" for this format — a blind 4/4 sort expects four
        // right by assignment alone, so five is the first score that means anything.
        if let blitz {
            result = r
            blitz.finishRound(format: .keep4, sport: puzzle.sport, puzzleID: puzzle.id,
                              performance: performance,
                              cleared: r.correctCount > puzzle.players.count / 2)
            return
        }
        // Versus and community are both possible on the same session (a community-authored
        // puzzle can't currently be a Versus board, but if that ever changes, Versus should
        // win — it's the more specific mode).
        let playMode: PlayMode = duel != nil ? .versus : (communityID != nil ? .community : .daily)
        let detail = RepositoryContainer.SessionDetail(
            mode: playMode, score: r.total, maxScore: 3000,
            correct: r.correctCount, attempted: puzzle.players.count, startedAt: startedAt,
            details: Self.buildDetails(puzzle: puzzle, placement: placement, result: r,
                                       opponentUserID: duel?.opponentUserID))
        Task { @MainActor in
            // A duel board is one the opponent's challenge (or a rung) chose off the archive —
            // neither today's daily nor a re-rollable practice board — so it earns the
            // career-log row but no rating, XP or streak movement. That is the Versus info
            // sheet's standing promise: "Versus games never affect your rating", and the
            // ladder inherits it.
            if duel != nil {
                await container.logSession(format: mode.formatKind, sport: puzzle.sport,
                                           performance: performance, perfect: r.isPerfect,
                                           puzzleID: puzzle.id, detail: detail)
            } else {
                rewards = await container.complete(format: mode.formatKind, sport: puzzle.sport,
                                                   performance: performance, perfect: r.isPerfect,
                                                   puzzleID: puzzle.id, ranked: ranked, detail: detail)
            }
            if let communityID { await container.recordCommunityPlay(id: communityID) }
            if let duel {
                await container.submitDuelResult(duel, performance: performance,
                                                 elapsed: Date().timeIntervalSince(startedAt ?? Date()))
            }
            withAnimation(Motion.easeOut) { result = r }
        }
    }

    /// The Keep4-specific slice of `GameResultDetails` for a finished placement. Pure and
    /// static so the miss-direction math (kept-should've-been-cut vs. cut-should've-been-kept)
    /// is unit-testable without a live game session — see `Keep4ScoringTests`.
    static func buildDetails(puzzle: Keep4Puzzle, placement: [String: Pile],
                             result: Keep4Scoring.Result, opponentUserID: String? = nil) -> GameResultDetails {
        let correctKeepIDs = puzzle.correctKeepIDs
        var missedIDs: [String] = []
        var missedNames: [String] = []
        var missedKeepCount = 0   // kept someone who should have been cut
        var missedCutCount = 0    // cut someone who should have been kept

        for player in puzzle.players {
            guard result.correctness[player.id] == false else { continue }
            missedIDs.append(player.id)
            missedNames.append(player.name)
            let shouldKeep = correctKeepIDs.contains(player.id)
            if placement[player.id] == .keep && !shouldKeep {
                missedKeepCount += 1
            } else if placement[player.id] == .cut && shouldKeep {
                missedCutCount += 1
            }
        }

        var details = GameResultDetails()
        details.missedPlayerIDs = missedIDs.isEmpty ? nil : missedIDs
        details.missedPlayerNames = missedNames.isEmpty ? nil : missedNames
        details.missedKeepCount = missedKeepCount
        details.missedCutCount = missedCutCount
        details.theme = puzzle.theme
        details.opponentUserID = opponentUserID
        return details
    }

    /// Debug-only: fill a deliberately imperfect placement (6/8) and finish, to screenshot the result.
    private func autoFillForScreenshot() {
        let ranked = puzzle.players.sorted { $0.grade > $1.grade }
        for (i, player) in ranked.enumerated() {
            placement[player.id] = i < 4 ? .keep : .cut
        }
        if ranked.count >= 5 {
            placement[ranked[3].id] = .cut
            placement[ranked[4].id] = .keep
        }
        finish()
    }

    // MARK: - Deterministic blind order

    /// Same serve order for everyone, stable per puzzle, and not grade-sorted (so order doesn't leak the answer).
    static func blindOrder(for puzzle: Keep4Puzzle) -> [PlayerSeason] {
        var gen = SeededGenerator(seed: SeededGenerator.stableHash(puzzle.id))
        return puzzle.players.shuffled(using: &gen)
    }
}

/// Deterministic RNG (SplitMix64) — used anywhere content must be reproducible across devices
/// from a stable string seed (Keep4's blind serve order; Over/Under's daily round generation).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// FNV-1a hash of a string into a `UInt64` seed — stable across devices/OS versions
    /// (unlike `String.hashValue`, which is randomized per-process).
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}
