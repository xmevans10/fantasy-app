import SwiftUI

/// The bot roster — every ladder character in one browsable grid, independent of where the
/// player has actually got to.
///
/// Stage 1 of the character brief ("browse a roster of visually distinct opponents") had no
/// screen of its own before this one: the only way to meet a bot was to reach their rung, and
/// the ladder list is a progression, not a roster. This is the discovery surface — a silhouette
/// for a character not yet reached, a full card in their own colourway for one that is, and a
/// tap opens the same `BotCharacterCard` the pre-duel briefing uses, with a "your record" block
/// the briefing has no reason to show yet.
struct RosterView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @EnvironmentObject private var auth: AuthService

    @State private var rows: [LadderRungRow] = []
    @State private var records: [String: BotRecord] = [:]
    @State private var loaded = false
    @State private var selectedBot: LadderBot?

    /// `RosterDebugLaunch.forceAllUnlocked` bypasses the lock state for verification only — the
    /// real "long name/3-crest row" risk the design calls out only shows up on an *encountered*
    /// tile (a locked one shows "Rung N unlocks" instead of the name), and every bot but the
    /// first needs real ladder progress to reach otherwise.
    private var entries: [RosterEntry] {
        let base = Self.entries(rows: rows)
        guard RosterDebugLaunch.forceAllUnlocked else { return base }
        return base.map { RosterEntry(bot: $0.bot, firstRung: $0.firstRung, state: .cleared) }
    }

    var body: some View {
        Group {
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                EmptyStateView(symbol: "person.3.fill", title: "Roster unavailable",
                               message: "The roster couldn't be loaded. Check your connection and try again.",
                               actionTitle: "Retry") { Task { await load() } }
            } else {
                grid
            }
        }
        .background(Color.appBackground)
        .navigationTitle("Roster")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $selectedBot) { bot in
            BotCharacterCard(bot: bot, record: RosterDebugLaunch.forcedRecord(botID: bot.id)
                ?? Self.recordDisplay(botID: bot.id, signedIn: auth.isSignedIn, records: records))
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                      spacing: 12) {
                ForEach(entries) { entry in characterCard(entry) }
            }
            .padding(16)
        }
    }

    /// Locked cards can't be opened (there's nothing to show yet) — tapping one just rejects,
    /// the same as tapping a locked rung on the ladder itself.
    @ViewBuilder
    private func characterCard(_ entry: RosterEntry) -> some View {
        let encountered = entry.state != .locked
        Button {
            guard encountered else { Haptics.reject(); return }
            Haptics.tap()
            selectedBot = entry.bot
        } label: {
            cardBody(entry, encountered: encountered)
        }
        .buttonStyle(.plain)
        .disabled(!encountered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(encountered
            ? "\(entry.bot.name), \(entry.bot.tagline)"
            : String(localized: "Locked character, unlocks at rung \(entry.firstRung)"))
    }

    /// `blockCard(fill:)` in the bot's own colourway once they're encountered, `cardSurface()`
    /// while they're still a silhouette — the encountered/locked split is the entire point of
    /// this screen, so it has to be legible at a glance, not just in the portrait's lock icon.
    @ViewBuilder
    private func cardBody(_ entry: RosterEntry, encountered: Bool) -> some View {
        let content = VStack(spacing: 10) {
            BotPortrait(bot: entry.bot, size: 72, locked: !encountered)
            if encountered {
                VStack(spacing: 2) {
                    Text(entry.bot.name)
                        .font(.bodyStrong)
                        .foregroundStyle(entry.bot.palette.ink)
                        .lineLimit(1).minimumScaleFactor(0.75)
                    Text(entry.bot.tagline)
                        .font(.label11)
                        .foregroundStyle(entry.bot.palette.ink.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(String(localized: "Rung \(entry.firstRung) unlocks"))
                    .font(.label11)
                    .foregroundStyle(Color.textMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 132)
        .padding(14)

        if encountered {
            content.blockCard(fill: entry.bot.palette.fill)
        } else {
            content.cardSurface()
        }
    }

    private func load() async {
        defer { loaded = true }
        rows = await container.ladderRows()
        if let ladder = container.ladder {
            records = Dictionary(uniqueKeysWithValues: (await ladder.myBotRecords(auth: auth))
                .map { ($0.botId, $0) })
        } else {
            records = [:]
        }
        if RosterDebugLaunch.autoOpenCard {
            if let id = RosterDebugLaunch.forcedBotID {
                selectedBot = entries.first(where: { $0.bot.id == id })?.bot
            } else {
                selectedBot = entries.first(where: { $0.state != .locked })?.bot
            }
        }
    }

    // MARK: - Pure (unit-tested in RosterTests, no RepositoryContainer needed)

    /// One entry per bot — the earliest rung they guard, and that rung's own unlock state. A
    /// bot's "encountered" state tracks its *first* rung, not any later one it might also guard.
    static func entries(rows: [LadderRungRow]) -> [RosterEntry] {
        var firstRow: [String: LadderRungRow] = [:]
        for row in rows {
            if let existing = firstRow[row.bot.id] {
                if row.rung.rung < existing.rung.rung { firstRow[row.bot.id] = row }
            } else {
                firstRow[row.bot.id] = row
            }
        }
        return firstRow.values
            .map { RosterEntry(bot: $0.bot, firstRung: $0.rung.rung, state: $0.state) }
            .sorted { $0.firstRung < $1.firstRung }
    }

    /// A signed-out player always reads as "sign in" regardless of what's cached locally —
    /// `my_bot_records` can't attribute a record to nobody. A signed-in player with no row for
    /// this bot reads as `.record(nil)`, which `BotCharacterCard` shows as "haven't faced them
    /// yet" rather than a zeroed-out record.
    static func recordDisplay(botID: String, signedIn: Bool, records: [String: BotRecord]) -> BotRecordDisplay {
        signedIn ? .record(records[botID]) : .signedOut
    }
}

/// One roster tile: a bot plus the earliest rung it guards.
struct RosterEntry: Identifiable, Equatable {
    let bot: LadderBot
    let firstRung: Int
    let state: LadderRungState
    var id: String { bot.id }
}

/// Stand-in for a `DebugLaunch` flag. `DebugLaunch.swift` is owned by a concurrent task this
/// session (see `prompts/HANDOFF-bot-characters.md` §0's file list), so this reads the launch
/// argument directly instead of adding to that file. Whoever next touches `DebugLaunch.swift`
/// should fold this in properly (with the same mirrored `#else` stub every other flag there
/// has) rather than leaving two places that check `ProcessInfo`.
enum RosterDebugLaunch {
    #if DEBUG
    /// Combined with `-screenshotVersus` (which alone only selects the Versus tab and needs a
    /// second push to reach the roster): `-screenshotVersus -screenshotRoster` opens the grid.
    static var autoOpen: Bool { ProcessInfo.processInfo.arguments.contains("-screenshotRoster") }
    /// Also opens the first unlocked character's card (simctl can't tap a tile):
    /// `-screenshotVersus -screenshotRoster -screenshotRosterCard`.
    static var autoOpenCard: Bool { ProcessInfo.processInfo.arguments.contains("-screenshotRosterCard") }
    /// Verification-only: every tile renders as encountered, regardless of ladder progress, so
    /// every bot's name/tagline can be checked for truncation in one grid instead of needing
    /// real progress through every rung to reach the later ones: `-screenshotRosterAllUnlocked`.
    static var forceAllUnlocked: Bool { ProcessInfo.processInfo.arguments.contains("-screenshotRosterAllUnlocked") }
    /// Picks which bot `autoOpenCard` opens, for checking one specific character's card (e.g.
    /// the longest favourite-teams row) instead of whichever happens to be first:
    /// `-screenshotRosterAllUnlocked -screenshotRosterCard -screenshotRosterBot archivist`.
    static var forcedBotID: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screenshotRosterBot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    /// Overrides the opened card's "your record" block regardless of real sign-in/network state
    /// — the "with attempts" and "no attempts yet" states both need a real signed-in account
    /// with real `ladder_attempts` history to arrange honestly, which a fresh simulator never
    /// has. Same category as `DebugLaunch.forcePriorZone`/`forcePushPrimer`: a canned state for
    /// a capture that's otherwise unreachable from a launch argument alone.
    /// `-screenshotRosterRecord played` / `-screenshotRosterRecord empty`.
    static func forcedRecord(botID: String) -> BotRecordDisplay? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screenshotRosterRecord"), i + 1 < args.count else { return nil }
        switch args[i + 1] {
        case "played": return .record(BotRecord(botId: botID, played: 4, won: 2,
                                                 bestScore: 0.82, bestBotScore: 0.91))
        case "empty":  return .record(nil)
        default:       return nil
        }
    }
    #else
    static let autoOpen = false
    static let autoOpenCard = false
    static let forceAllUnlocked = false
    static let forcedBotID: String? = nil
    static func forcedRecord(botID: String) -> BotRecordDisplay? { nil }
    #endif
}

#Preview {
    let container = RepositoryContainer.make(client: nil)
    return NavigationStack { RosterView() }
        .environmentObject(container).environmentObject(container.auth)
}
