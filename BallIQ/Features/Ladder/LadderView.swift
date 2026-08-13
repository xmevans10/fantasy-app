import SwiftUI

/// The bot ladder — 30 rungs of skill-limited solvers, climbed one at a time.
///
/// This is not a consolation prize for having no players. It is the mode that works at N=1: the
/// bot's run is computed on-device before the board opens and replayed against the clock beside
/// you (see `LadderRunSession`), so a rung feels like a live opponent with no realtime
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
                Button { showInfo = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("How the ladder works")
            }
        }
        .task { await load() }
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
        .fullScreenCover(item: $board, onDismiss: { Task { await load() } }) { board in
            board.view.environmentObject(container)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                ForEach(LadderRung.Tier.allCases, id: \.self) { tier in
                    let tierRows = rows.filter { $0.rung.tier == tier }
                    if !tierRows.isEmpty {
                        Section {
                            ForEach(tierRows) { row in rungRow(row) }
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

                Text(locked ? "🔒" : row.bot.avatar).font(.system(size: 20))

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
                    Text(row.boardLine).font(.label11).foregroundStyle(Color.textMuted)
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 2) {
                    Label(DuelSession.clockText(row.rung.timeLimitSeconds), systemImage: "timer")
                        .font(.label11).monospacedDigit()
                        .foregroundStyle(Color.textMuted)
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
                .init(symbol: "timer",
                      title: "Watch them play, live",
                      detail: "Your opponent's score climbs beside the clock while you play. They get the same board and the same time you do."),
                .init(symbol: "arrow.up.right",
                      title: "One rung at a time",
                      detail: "Beat a rung to unlock the next. Bots get sharper, clocks get shorter, boards get harder, and the games start mixing."),
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

/// The pre-duel screen: who you're about to play, on what, and for how long.
///
/// Worth its own sheet rather than starting on tap. A rung is a one-shot run against a clock,
/// and the bot's persona is most of what makes the ladder a progression rather than a list —
/// meeting the opponent before the buzzer is the difference between the two.
private struct LadderBriefingSheet: View {
    let row: LadderRungRow
    let starting: Bool
    /// Signed-out players can still *play* a rung — the bot runs entirely on-device, so there
    /// is nothing to stop. What they can't do is bank it (`submit_ladder_attempt` needs a
    /// `user_id`), and a rung that silently refuses to unlock the next one is worse than one
    /// that says so up front.
    let signedIn: Bool
    let onStart: () async -> Void
    @Environment(\.dismiss) private var dismiss

    /// A scrolling body under a pinned CTA, rather than one `VStack` with a `Spacer`.
    ///
    /// The `VStack` version was laid out taller than the `.medium` detent (the persona and the
    /// signed-out caption both wrap to two lines on the widest bots), and a sheet clips rather
    /// than grows: the rung badge was pushed off the top edge entirely. Only visible in the
    /// simulator — every layer of this compiles and unit-tests identically. Scrolling the body
    /// makes the sheet correct at both detents *and* at large accessibility text sizes, which
    /// no amount of tuning a fixed layout would have.
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    Text(row.rung.isBoss
                         ? String(localized: "BOSS · RUNG \(row.rung.rung)")
                         : String(localized: "RUNG \(row.rung.rung)"))
                        .font(.custom(FontName.condBlack, size: 13))
                        .foregroundStyle(row.rung.tier.onTint)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(row.rung.tier.tint)
                        .clipShape(Capsule())

                    Text(row.bot.avatar).font(.system(size: 56))
                    Text(row.bot.name).font(.title).foregroundStyle(Color.textPrimary)
                    Text(row.bot.tagline)
                        .font(.body14).foregroundStyle(Color.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        stat(row.boardLine, label: String(localized: "BOARD"))
                        stat(DuelSession.clockText(row.rung.timeLimitSeconds),
                             label: String(localized: "CLOCK"))
                        // Skill as a percentage is the honest version of a difficulty star
                        // rating: it is literally the number `BotSolver` uses.
                        stat("\(Int((row.rung.botSkill * 100).rounded()))%",
                             label: String(localized: "SKILL"))
                    }

                    if !row.bot.persona.isEmpty {
                        Text(row.bot.persona)
                            .font(.label12).foregroundStyle(Color.textMuted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 24)   // clears the drag indicator
                .padding(.bottom, 16)
            }

            // Pinned: starting a run is the one thing this sheet exists for, so it must never
            // be the thing that scrolled off.
            VStack(spacing: 10) {
                Button {
                    Task { await onStart() }
                } label: {
                    Text(starting ? "STARTING…" : "START THE RUN").ctaLabel()
                }
                .buttonStyle(PrimePressStyle())
                .disabled(starting)

                Text(signedIn
                     ? String(localized: "The clock starts as soon as the board opens.")
                     : String(localized: "The clock starts as soon as the board opens. Sign in to bank the result and unlock the next rung."))
                    .font(.label11)
                    .foregroundStyle(signedIn ? Color.textMuted : Color.warningText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        .background(Color.appBackground)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func stat(_ value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.custom(FontName.condBlack, size: 15))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.label11).foregroundStyle(Color.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

#Preview {
    let container = RepositoryContainer.make(client: nil)
    return NavigationStack { LadderView() }
        .environmentObject(container).environmentObject(container.auth)
}
