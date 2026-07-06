import SwiftUI

struct Keep4GameView: View {
    let puzzle: Keep4Puzzle
    /// Daily play is ranked; community puzzles pass `ranked: false` (XP only, no rating).
    var ranked: Bool = true
    /// Set for community puzzles so a play is logged (powers the Popular sort).
    var communityID: String? = nil
    /// Community author's username — personalizes the custom-scoring explainer when known.
    var authorName: String? = nil
    /// Set when played from the Versus tab, so the score is submitted to the challenge.
    var versusChallengeID: Int? = nil

    @EnvironmentObject private var container: RepositoryContainer
    @Environment(\.dismiss) private var dismiss

    @State private var order: [PlayerSeason] = []
    @State private var index = 0
    @State private var placement: [String: Pile] = [:]
    @State private var result: Keep4Scoring.Result?
    @State private var rewards: RepositoryContainer.SessionRewards?
    @State private var mode: Keep4Mode = .normal
    @State private var showReportDialog = false
    @State private var showReportSent = false

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
            if let result {
                Keep4ResultView(puzzle: puzzle,
                                placement: placement,
                                result: result,
                                rewards: rewards,
                                onDone: { dismiss() })
            } else {
                playBoard
            }
        }
        .background(Color.appBackground)
        .onAppear {
            if order.isEmpty {
                order = Self.blindOrder(for: puzzle)
                container.track(.gameStarted, ["format": "keep4", "ranked": "\(ranked)",
                                               "community": "\(communityID != nil)"])
            }
            if DebugLaunch.autoSubmitResult { autoFillForScreenshot() }
        }
        .reportReasonDialog(isPresented: $showReportDialog) { reason in report(reason: reason) }
        .alert("Report sent", isPresented: $showReportSent) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Thanks — we'll take a look.")
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
                Button { dismiss() } label: {
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
                tally(label: "Keep", count: keepCount, color: .successText)
                tally(label: "Cut", count: cutCount, color: .dangerText)
            }

            if placement.isEmpty {
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
                let full = forced == .keep ? "KEEP" : "CUT"
                let rest = forced == .keep ? "CUTS" : "KEEPS"
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
    /// rule) — the pre-game scoring explainer, always visible above the deck.
    private var scoringNote: some View {
        ScoringNoteChip(kind: puzzle.scoringKind(), sport: puzzle.sport, author: authorName)
            .padding(.top, 2)
    }

    private var modePicker: some View {
        PrimeSegmentedControl(options: Keep4Mode.allCases.map { ($0.title, $0) },
                              selection: $mode)
            .frame(maxWidth: 220)
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

    private func finish() {
        let r = Keep4Scoring.score(puzzle: puzzle, placement: placement)
        if r.isPerfect { Haptics.success() } else { Haptics.commit() }
        let performance = Double(r.correctCount) / Double(puzzle.players.count)
        Task { @MainActor in
            let rw = await container.complete(format: mode.formatKind, sport: puzzle.sport,
                                              performance: performance, perfect: r.isPerfect,
                                              puzzleID: puzzle.id, ranked: ranked)
            rewards = rw
            if let communityID { await container.recordCommunityPlay(id: communityID) }
            if let versusChallengeID { await container.submitVersusResult(challengeID: versusChallengeID, performance: performance) }
            withAnimation(Motion.easeOut) { result = r }
        }
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
        var gen = SeededGenerator(seed: stableHash(puzzle.id))
        return puzzle.players.shuffled(using: &gen)
    }

    private static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}

/// Deterministic RNG (SplitMix64) so the blind serve order is reproducible across devices.
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
}
