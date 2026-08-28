import SwiftUI

/// A bot's full-height character card — colourway, portrait, allegiances, voice line, playing
/// style and backstory. Shared by two call sites: `LadderView`'s pre-duel briefing (which pins a
/// "start the run" CTA under it) and `RosterView`'s discovery card (which shows a "your record"
/// block instead). Extracted from what used to be `LadderView`'s private `LadderBriefingSheet` —
/// the roster would otherwise have forked every section of it, and the two would drift.
///
/// A full-height sheet, not a peek — presented at `.large` only. The medium detent it used to
/// offer was the wrong shape for what this screen is: meeting the opponent is the moment the
/// ladder's whole premise pays off, and a half-height sheet turned a character card into a
/// settings row with a portrait on it. A scrolling body under a pinned footer, rather than one
/// `VStack` with a `Spacer`, is what keeps the card correct at `.large` *and* at large
/// accessibility text sizes — the `VStack` version laid out taller than the detent and clipped
/// the rung badge off the top instead of scrolling to it.
struct BotCharacterCard<Footer: View>: View {
    let bot: LadderBot
    /// "RUNG 7" / "BOSS · RUNG 7" under the portrait, or nil to omit it — the roster's card has
    /// no single rung in mind (a character can guard several across the ladder).
    var rungBadge: String? = nil
    /// The board/par/skill trio a pre-duel briefing reports. Empty hides the row entirely —
    /// the roster's card has no live rung to describe.
    var stats: [(value: String, label: String)] = []
    /// "Your record" — nil hides the block outright (the pre-duel briefing has no record to
    /// show; the run hasn't happened yet).
    var record: BotRecordDisplay? = nil
    /// Pinned below the scrolling body: the pre-duel briefing's "START THE RUN" CTA, or nothing
    /// from the roster.
    let footer: () -> Footer

    init(bot: LadderBot, rungBadge: String? = nil, stats: [(value: String, label: String)] = [],
         record: BotRecordDisplay? = nil, @ViewBuilder footer: @escaping () -> Footer) {
        self.bot = bot
        self.rungBadge = rungBadge
        self.stats = stats
        self.record = record
        self.footer = footer
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    VStack(spacing: 16) {
                        favoriteTeamsBlock
                        if let intro = bot.voice.intro { introQuote(intro) }
                        if !stats.isEmpty { statsRow }
                        if let record { recordBlock(record) }
                        if !bot.styleLine.isEmpty { howTheyPlayBlock }
                        if !bot.backstory.isEmpty { whoTheyAreBlock }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }
            }
            footer()
        }
        .frame(maxWidth: .infinity)
        .background(Color.appBackground)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // Rung badge and the character's own colourway, edge to edge — the card should read as
    // *theirs* before a word of it is legible.
    private var header: some View {
        ZStack {
            bot.palette.fill
            VStack(spacing: 14) {
                if let rungBadge {
                    Text(rungBadge)
                        .font(.custom(FontName.condBlack, size: 12))
                        .foregroundStyle(bot.palette.ink.opacity(0.85))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(bot.palette.ink.opacity(0.16))
                        .clipShape(Capsule())
                }
                BotPortrait(bot: bot, size: 116)
                Text(bot.name)
                    .font(.hero(40))
                    .foregroundStyle(bot.palette.ink)
                Text(bot.tagline)
                    .font(.body14)
                    .foregroundStyle(bot.palette.ink.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 26).padding(.bottom, 22).padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity)
    }

    // Who they support. Three crests characterise a sports fan faster than any paragraph, and
    // they cost nothing — `TeamAbbrChip` already resolves real logos and colours for any
    // (sport, abbr).
    @ViewBuilder
    private var favoriteTeamsBlock: some View {
        if !bot.favoriteTeams.isEmpty {
            cardBlock(label: String(localized: "FAVOURITE TEAMS")) {
                HStack(spacing: 8) {
                    ForEach(bot.favoriteTeams) { team in
                        TeamAbbrChip(sport: team.sport, abbr: team.abbr,
                                     fontSize: 13, minHeight: 34, showLogo: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        } else {
            cardBlock(label: String(localized: "FAVOURITE TEAMS")) {
                Text("No allegiances. Never has had any.")
                    .font(.label12).foregroundStyle(Color.textMuted)
            }
        }
    }

    private func introQuote(_ intro: String) -> some View {
        Text("“\(intro)”")
            .font(.body14).italic()
            .foregroundStyle(Color.textPrimary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(bot.palette.soft)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            ForEach(Array(stats.enumerated()), id: \.offset) { _, item in
                stat(item.value, label: item.label)
            }
        }
    }

    // "Your record" — the roster card's whole reason to exist. A bot with `played == 0` reads
    // the same whether that's "never unlocked" or "unlocked and never played" — both are
    // honestly "you haven't faced them yet".
    @ViewBuilder
    private func recordBlock(_ record: BotRecordDisplay) -> some View {
        cardBlock(label: String(localized: "YOUR RECORD")) {
            if case .signedOut = record {
                Text(String(localized: "Sign in to track your record against \(bot.name)."))
                    .font(.label12).foregroundStyle(Color.textMuted)
            } else if case .record(let botRecord) = record, let botRecord, botRecord.played > 0 {
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        stat("\(botRecord.played)", label: String(localized: "PLAYED"))
                        stat("\(botRecord.won)", label: String(localized: "WON"))
                    }
                    HStack(spacing: 10) {
                        stat(Self.percentText(botRecord.bestScore), label: String(localized: "YOUR BEST"))
                        stat(Self.percentText(botRecord.bestBotScore), label: String(localized: "THEIR BEST"))
                    }
                }
            } else {
                Text(String(localized: "You haven't faced \(bot.name) yet."))
                    .font(.label12).foregroundStyle(Color.textMuted)
            }
        }
    }

    private static func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    // How they play, stated before the run. A style the player cannot anticipate is noise
    // rather than personality.
    private var howTheyPlayBlock: some View {
        cardBlock(label: String(localized: "HOW THEY PLAY")) {
            Text(bot.styleLine)
                .font(.body14).foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var whoTheyAreBlock: some View {
        cardBlock(label: String(localized: "WHO THEY ARE")) {
            Text(bot.backstory)
                .font(.label12).foregroundStyle(Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A labelled block. One shape for every section of the card so the eye can skip between
    /// them, rather than differently-styled paragraphs.
    private func cardBlock<Content: View>(label: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.label11).foregroundStyle(Color.textMuted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardSurface()
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

/// The "your record" case for `BotCharacterCard` — kept separate from a plain `BotRecord?` so a
/// signed-out player reads as its own state rather than as "nobody has a record", which is what
/// a bare `nil` would otherwise mean.
enum BotRecordDisplay: Equatable {
    case signedOut
    /// A signed-in caller: `nil` means no `ladder_attempts` row for this bot yet.
    case record(BotRecord?)
}

/// Convenience initializer for call sites with no pinned footer (`RosterView`'s card — nothing
/// to start from a discovery screen).
extension BotCharacterCard where Footer == EmptyView {
    init(bot: LadderBot, rungBadge: String? = nil, stats: [(value: String, label: String)] = [],
         record: BotRecordDisplay? = nil) {
        self.init(bot: bot, rungBadge: rungBadge, stats: stats, record: record) { EmptyView() }
    }
}

#Preview {
    let bot = LadderBot(id: "archivist", name: "The Archivist", avatar: "📼", tagline: "Remembers every box score since before you were born.",
                        baseSkill: 0.7, persona: "", style: .slowBurn,
                        styleLine: "Starts cold, finishes strong, skill ramps across the run.",
                        backstory: "Nobody knows how long The Archivist has been running the ladder. Longer than the ladder has existed, some say.",
                        palette: .plum,
                        voice: BotVoice(intro: "I've seen this board before. Somewhere."),
                        favoriteTeams: [BotTeam(sport: .nfl, abbr: "GB"), BotTeam(sport: .nba, abbr: "BOS")])
    return Color.clear.sheet(isPresented: .constant(true)) {
        BotCharacterCard(bot: bot,
                         rungBadge: "BOSS · RUNG 24",
                         stats: [("K4C4 · NFL", "BOARD"), ("0:45", "PAR"), ("88%", "SKILL")],
                         record: .record(BotRecord(botId: "archivist", played: 3, won: 1,
                                                   bestScore: 0.82, bestBotScore: 0.91))) {
            VStack(spacing: 10) {
                Button { } label: { Text("START THE RUN").ctaLabel() }
                    .buttonStyle(PrimePressStyle())
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 20)
            .background(Color.appBackground)
        }
    }
}
