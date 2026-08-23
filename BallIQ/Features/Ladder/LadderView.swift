import SwiftUI

/// Lets a ladder result screen (three formats away, inside a `fullScreenCover`) offer a
/// same-rung rematch without either `DuelBoard` or the three result views needing to know who's
/// presenting them — `LadderView` is the only producer, set alongside the board it's hosting.
/// `Bool` returned = whether a fresh board actually started, so the result screen's own
/// "REMATCHING…" state knows when to give up and let the player try again (on success the game
/// view is about to be torn down for a fresh one anyway, so there's nothing left to reset).
private struct LadderRematchKey: EnvironmentKey {
    static let defaultValue: (() async -> Bool)? = nil
}
extension EnvironmentValues {
    var ladderRematch: (() async -> Bool)? {
        get { self[LadderRematchKey.self] }
        set { self[LadderRematchKey.self] = newValue }
    }
}

/// The bot ladder — 30 rungs of skill-limited solvers, climbed one at a time.
///
/// This is not a consolation prize for having no players. It is the mode that works at N=1: the
/// bot's run is computed on-device before the board opens and replayed in real time beside you
/// (see `LadderRunSession`), so a rung feels like a live opponent with no realtime
/// infrastructure at all. It also teaches the duel format before anyone risks a real one, and
/// fills `ladder_attempts` with the per-board score corpus human ghost duels will need later.
struct LadderView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @EnvironmentObject private var auth: AuthService
    var selectedTab: Binding<Int> = .constant(0)

    @State private var rows: [LadderRungRow] = []
    @State private var loaded = false
    @State private var board: DuelBoard?
    @State private var startingRung: Int?
    @State private var startError: String?
    @State private var showInfo = false
    @State private var briefing: LadderRungRow?

    var body: some View {
        Group {
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                EmptyStateView(symbol: "figure.stair.stepper", title: "Ladder unavailable",
                               message: "The ladder couldn't be loaded. Check your connection and try again.",
                               actionTitle: "Retry") { Task { await load() } }
            } else {
                list
            }
        }
        .background(Color.appBackground)
        .navigationTitle("Ladder")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    RosterView().environmentObject(container).environmentObject(auth)
                } label: { Image(systemName: "person.3.fill") }
                    .accessibilityLabel("Roster")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showInfo = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("How the ladder works")
            }
        }
        .task {
            await load()
            // No tap can reach a live rung board (the briefing sheet's START button is a real
            // tap), and the live-reaction bubble only fires once real time has passed on a
            // hosted view — a static render can't produce it. `-screenshotLadderDuel` exists
            // solely so that state is screenshottable at all.
            if DebugLaunch.autoStartLadderDuel, let row = rows.first(where: { $0.state != .locked }) {
                await start(row)
            }
        }
        .sheet(isPresented: $showInfo) { infoSheet }
        .sheet(item: $briefing) { row in
            LadderBriefingSheet(row: row, starting: startingRung == row.rung.rung,
                                signedIn: auth.isSignedIn) {
                await start(row)
            }
        }
        .alert("Couldn't start that rung",
               isPresented: Binding(get: { startError != nil }, set: { if !$0 { startError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(startError ?? "") }
        .fullScreenCover(item: $board, onDismiss: { Task { await load() } }) { activeBoard in
            activeBoard.view
                .environmentObject(container)
                // Set only for a ladder duel — a human Versus board never sees this key, so
                // `duelVerdict == nil` there is belt-and-suspenders, not the only guard.
                .environment(\.ladderRematch, activeBoard.session.ladder != nil
                             ? { await rematch(activeBoard.session) } : nil)
                // The rung number alone doesn't change on a rematch (same rung, new board), so
                // `DuelBoard.id` — which `fullScreenCover(item:)` presents by — stays identical
                // and the cover updates in place rather than dismissing and re-presenting. This
                // forces the *content* to a fresh identity on every distinct board, which is
                // what resets the game view's `@State` (including its own `result`) instead of
                // silently reusing the just-finished run's.
                .id(activeBoard.session.boardID)
        }
    }

    /// Starts the same rung again on the next unseen board — Task 1's `next_ladder_board` RPC
    /// already guarantees a different board, so this is just calling `startLadderRung` again.
    /// Losing should feel like an invitation, so the caller (`Keep4ResultView` &c.) keeps this
    /// action on `accentFill`, never `dangerFill`.
    private func rematch(_ session: DuelSession) async -> Bool {
        guard let ladder = session.ladder else { return false }
        // `state` is unused by `startLadderRung` (only `rung`/`bot` are), so any value works —
        // this row exists purely to satisfy the same signature the briefing sheet uses.
        let row = LadderRungRow(rung: ladder.rung, bot: ladder.bot, state: .open)
        guard let started = await container.startLadderRung(row) else {
            startError = String(localized: "That rung's board couldn't be loaded. Check your connection and try again.")
            return false
        }
        board = started
        return true
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                ForEach(LadderRung.Tier.allCases, id: \.self) { tier in
                    let tierRows = rows.filter { $0.rung.tier == tier }
                    if !tierRows.isEmpty {
                        Section {
                            ForEach(tierRows) { row in
                                rungRow(row)
                            }
                        } header: {
                            tierHeader(tier, rows: tierRows)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func tierHeader(_ tier: LadderRung.Tier, rows tierRows: [LadderRungRow]) -> some View {
        let cleared = tierRows.filter { $0.state == .cleared }.count
        return HStack(spacing: 8) {
            Text(tier.displayName)
                .font(.custom(FontName.condBlack, size: 13))
                .foregroundStyle(tier.onTint)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(tier.tint)
                .clipShape(Capsule())
            Text("\(cleared)/\(tierRows.count)")
                .font(.label11).foregroundStyle(Color.textMuted).monospacedDigit()
            Spacer()
        }
        .padding(.vertical, 8)
        .background(Color.appBackground)
    }

    /// One opponent, as the ladder lists them: portrait, name, tagline. Deliberately nothing
    /// else — no format, no sport, no clock. Choosing a rung should read as picking who to face,
    /// not as comparing spec sheets, and the briefing sheet is where what-you're-playing belongs.
    @ViewBuilder
    private func rungRow(_ row: LadderRungRow) -> some View {
        let locked = row.state == .locked
        Button {
            guard !locked else { Haptics.reject(); return }
            briefing = row
        } label: {
            HStack(spacing: 12) {
                // The rung number is the spine of the whole screen — it has to read at a glance
                // while scrolling 30 of them.
                Text("\(row.rung.rung)")
                    .font(.custom(FontName.condBlack, size: 18))
                    .monospacedDigit()
                    .foregroundStyle(row.state == .cleared ? row.rung.tier.onTint : Color.textPrimary)
                    .frame(width: 34, height: 34)
                    .background(row.state == .cleared ? row.rung.tier.tint : Color.surfaceMuted)
                    .clipShape(Circle())

                BotPortrait(bot: row.bot, size: 42, locked: locked)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.bot.name)
                            .font(.bodyStrong)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                        if row.rung.isBoss {
                            Text("BOSS")
                                .font(.custom(FontName.condBlack, size: 10))
                                .foregroundStyle(Color.onDanger)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.dangerFill)
                                .clipShape(Capsule())
                        }
                    }
                    // The tagline, and nothing else. The list used to carry the board line
                    // ("K4C4 · NFL"), the style line and the clock — which made choosing an
                    // opponent a spec comparison rather than meeting someone, and told you which
                    // game you were about to play before the briefing sheet got to. Who they are
                    // is the hook; what they play is the briefing's job.
                    if !row.bot.tagline.isEmpty {
                        Text(row.bot.tagline)
                            .font(.label11).foregroundStyle(Color.textMuted)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 2) {
                    if row.state == .cleared {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.successText)
                    } else if row.state == .open {
                        Text("PLAY")
                            .font(.custom(FontName.condBlack, size: 12))
                            .foregroundStyle(Color.onAccent)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color.accentFill)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(12)
            .opacity(locked ? 0.45 : 1)
            .cardSurface()
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(row))
    }

    private func accessibilityLabel(_ row: LadderRungRow) -> String {
        let state: String
        switch row.state {
        case .cleared: state = String(localized: "cleared")
        case .open:    state = String(localized: "ready to play")
        case .locked:  state = String(localized: "locked")
        }
        return String(localized: "Rung \(row.rung.rung), \(row.bot.name), \(row.boardLine), \(state)")
    }

    private var infoSheet: some View {
        HowItWorksSheet(
            title: "The Ladder",
            intro: "Thirty rungs, thirty opponents. Every one of them is a bot, and every one of them plays the same board you do.",
            symbol: "figure.stair.stepper",
            tint: Color.accentText,
            tintBackground: Color.accentBg,
            rules: [
                // Saying this plainly is a product rule, not a disclaimer: beating "The Analyst"
                // is a better story than beating an anonymous number, and it only works if the
                // player knows what they beat.
                .init(symbol: "cpu",
                      title: "They're bots, and we say so",
                      detail: "Each one is a real solver with a skill level — it makes a genuine call on every card, cell or clue, nails the obvious ones and fumbles the close ones, exactly like a human at that level."),
                .init(symbol: "bolt.fill",
                      title: "Watch them play, live",
                      detail: "Your opponent's score climbs in real time while you play the same board. Finish fast and you'll pick up a speed bonus — nothing here can end your run early."),
                .init(symbol: "arrow.up.right",
                      title: "One rung at a time",
                      detail: "Beat a rung to unlock the next. Bots get sharper, boards get harder, and the games start mixing."),
            ],
            callout: .init(symbol: "bolt.fill",
                           label: "XP and rank only",
                           text: "Ladder runs never move your rating — same rule as Versus duels.",
                           tint: Color.accentText,
                           background: Color.accentBg),
            footnote: "A tie goes to you. You matched the machine; take the win.",
            startExpanded: false)
    }

    private func start(_ row: LadderRungRow) async {
        guard startingRung == nil else { return }
        startingRung = row.rung.rung
        defer { startingRung = nil }
        guard let started = await container.startLadderRung(row) else {
            startError = String(localized: "That rung's board couldn't be loaded. Check your connection and try again.")
            return
        }
        briefing = nil
        board = started
    }

    private func load() async {
        defer { loaded = true }
        rows = await container.ladderRows()
    }
}

/// The pre-duel screen: who you're about to play, and on what.
///
/// Worth its own sheet rather than starting on tap. A rung is a one-shot run, and the bot's
/// persona is most of what makes the ladder a progression rather than a list — meeting the
/// opponent before the run starts is the difference between the two. The card itself is
/// `BotCharacterCard` — shared with `RosterView`'s discovery card so the two can't fork — with
/// the rung's own badge/stats and a pinned "start the run" footer.
private struct LadderBriefingSheet: View {
    let row: LadderRungRow
    let starting: Bool
    /// Signed-out players can still *play* a rung — the bot runs entirely on-device, so there
    /// is nothing to stop. What they can't do is bank it (`submit_ladder_attempt` needs a
    /// `user_id`), and a rung that silently refuses to unlock the next one is worse than one
    /// that says so up front.
    let signedIn: Bool
    let onStart: () async -> Void

    var body: some View {
        BotCharacterCard(
            bot: row.bot,
            rungBadge: row.rung.isBoss
                ? String(localized: "BOSS · RUNG \(row.rung.rung)")
                : String(localized: "RUNG \(row.rung.rung)"),
            stats: [
                (row.boardLine, String(localized: "BOARD")),
                // Was "CLOCK" pre-M25 — `rung.timeLimitSeconds` never stopped being real data,
                // it stopped being a deadline: `LadderOutcome.playerWon` still divides by it
                // through `SpeedMultiplier`, so it's the target a fast run gets paid for beating,
                // not a countdown that ends one. Same value, honest label.
                (DuelSession.clockText(row.rung.timeLimitSeconds), String(localized: "PAR")),
                ("\(Int((row.rung.botSkill * 100).rounded()))%", String(localized: "SKILL")),
            ]
        ) {
            // Pinned: starting the run is the one thing this card exists for.
            VStack(spacing: 10) {
                Button {
                    Task { await onStart() }
                } label: {
                    Text(starting ? "STARTING…" : "START THE RUN").ctaLabel()
                }
                .buttonStyle(PrimePressStyle())
                .disabled(starting)

                Text(signedIn
                     ? String(localized: "Solve fast for a speed bonus — no deadline, just points on the table.")
                     : String(localized: "Solve fast for a speed bonus — no deadline, just points on the table. Sign in to bank the result and unlock the next rung."))
                    .font(.label11)
                    .foregroundStyle(signedIn ? Color.textMuted : Color.warningText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .background(Color.appBackground)
        }
    }
}

#Preview {
    let container = RepositoryContainer.make(client: nil)
    return NavigationStack { LadderView() }
        .environmentObject(container).environmentObject(container.auth)
}
