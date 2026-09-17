import XCTest
import SwiftUI
@testable import BallIQ

/// Draws the daily X posts (see `tools/marketing/x_assets.py` for what each format is for).
///
/// Each image carries ONE question and has to read at phone feed width, where a 1600x900 post is
/// shown about 360pt wide: nothing that matters is set below ~15pt here. The app shows up as its
/// type, colors, crests and headshots, never as a screenshot of a screen with a PLAY button,
/// which is an ad and gets scrolled past like one.
///
/// Driven by the `spec.json` that `tools/marketing/x_assets.py` writes from what is published
/// (puzzle content verbatim, decoded here by the app's own models). Skips without one, so it is
/// inert in normal verification:
///
///     python -m tools.marketing.x_assets --daily 2026-09-17 --answers 2026-09-16 --out build/x --no-render
///     TEST_RUNNER_X_POST_SPEC=$PWD/build/x/spec.json xcodebuild test -scheme BallIQ \
///       -project BallIQ.xcodeproj -destination 'platform=iOS Simulator,name=iPhone 17' \
///       -only-testing:BallIQTests/XPostRenderTests
@MainActor
final class XPostRenderTests: XCTestCase {

    func testRenderPosts() async throws {
        guard let path = ProcessInfo.processInfo.environment["X_POST_SPEC"] else {
            throw XCTSkip("X_POST_SPEC not set; nothing to render")
        }
        let specURL = URL(fileURLWithPath: path)
        let spec = try JSONDecoder().decode(XPostSpec.self, from: Data(contentsOf: specURL))
        if let teams = spec.teams {
            TeamIdentityIndex.shared.store(teams: teams.map(TeamIdentity.init(row:)))
        }
        let out = URL(fileURLWithPath: spec.out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var failures: [String] = []
        for post in spec.posts {
            await XPostWarmup.warm(post)
            for (file, view) in post.renders {
                let renderer = ImageRenderer(content: view
                    .frame(width: XPost.size.width, height: XPost.size.height)
                    .environment(\.colorScheme, .light))
                renderer.scale = XPost.scale
                guard let png = renderer.uiImage?.pngData() else {
                    failures.append(file)
                    continue
                }
                try png.write(to: out.appendingPathComponent(file))
                print("X_POST: \(file)")
            }
        }
        XCTAssertTrue(failures.isEmpty, "failed to render: \(failures)")
    }
}

// MARK: - Spec

enum XPost {
    /// 1600x900 (X's 16:9) at scale 2.
    static let size = CGSize(width: 800, height: 450)
    static let scale: CGFloat = 2
}

struct XPostSpec: Decodable {
    let out: String
    let posts: [XPostSpecPost]
    /// Raw `teams` rows, so crests, colors and full names resolve the way the app resolves them.
    let teams: [TeamIdentity.Row]?

    enum CodingKeys: String, CodingKey { case out, posts, teams }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        out = try c.decode(String.self, forKey: .out)
        posts = try c.decode([XPostSpecPost].self, forKey: .posts)
        // Snake-case rows: the app decodes these through `.supabase`, so do the same here.
        if let raw = try c.decodeIfPresent(RawJSON.self, forKey: .teams) {
            teams = try JSONDecoder.supabase.decode([TeamIdentity.Row].self, from: raw.data)
        } else {
            teams = nil
        }
    }
}

/// Re-encodes a nested JSON value so it can be handed to a differently-configured decoder.
private struct RawJSON: Decodable {
    let data: Data
    init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        data = try JSONEncoder().encode(value)
    }
}

private enum JSONValue: Codable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: AnyKey.self) {
            var out: [String: JSONValue] = [:]
            for key in c.allKeys { out[key.stringValue] = try c.decode(JSONValue.self, forKey: key) }
            self = .object(out)
        } else if var c = try? decoder.unkeyedContainer() {
            var out: [JSONValue] = []
            while !c.isAtEnd { out.append(try c.decode(JSONValue.self)) }
            self = .array(out)
        } else {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let n = try? c.decode(Double.self) { self = .number(n) }
            else { self = .string(try c.decode(String.self)) }
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let s): try s.encode(to: encoder)
        case .number(let n): try n.encode(to: encoder)
        case .bool(let b): try b.encode(to: encoder)
        case .object(let o): try o.encode(to: encoder)
        case .array(let a): try a.encode(to: encoder)
        case .null: var c = encoder.singleValueContainer(); try c.encodeNil()
        }
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

struct XPostSpecPost: Decodable {
    enum Board {
        case resume(Keep4Puzzle, a: PlayerSeason, b: PlayerSeason, file: String, reveal: String)
        case keep4(Keep4Puzzle, label: String?, title: String?, file: String)
        case career(JourneymanPuzzle, file: String)
    }

    let board: Board

    enum CodingKeys: String, CodingKey { case file, reveal_file, kind, content, a, b, label, title }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let file = try c.decode(String.self, forKey: .file)
        switch kind {
        case "resume":
            let puzzle = try c.decode(Keep4Puzzle.self, forKey: .content)
            let (ia, ib) = (try c.decode(String.self, forKey: .a), try c.decode(String.self, forKey: .b))
            guard let a = puzzle.players.first(where: { $0.id == ia }),
                  let b = puzzle.players.first(where: { $0.id == ib }) else {
                throw DecodingError.dataCorruptedError(forKey: .a, in: c, debugDescription: "pair not on board")
            }
            board = .resume(puzzle, a: a, b: b, file: file,
                            reveal: try c.decode(String.self, forKey: .reveal_file))
        case "keep4":
            board = .keep4(try c.decode(Keep4Puzzle.self, forKey: .content),
                           label: try c.decodeIfPresent(String.self, forKey: .label),
                           title: try c.decodeIfPresent(String.self, forKey: .title), file: file)
        case "career":
            board = .career(try c.decode(JourneymanPuzzle.self, forKey: .content), file: file)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                                                   debugDescription: "unknown post kind \(kind)")
        }
    }

    /// Every image this post needs, by file name.
    @MainActor
    var renders: [(String, AnyView)] {
        switch board {
        case let .resume(puzzle, a, b, file, reveal):
            return [(file, AnyView(ResumePost(puzzle: puzzle, a: a, b: b))),
                    (reveal, AnyView(ResumePost(puzzle: puzzle, a: a, b: b, revealed: true)))]
        case let .keep4(puzzle, label, title, file):
            return [(file, AnyView(Keep4BoardPost(puzzle: puzzle, label: label, title: title ?? puzzle.theme)))]
        case let .career(puzzle, file):
            return [(file, AnyView(CareerPost(puzzle: puzzle)))]
        }
    }
}

// MARK: - Photos

/// `RemoteImage` seeds from a synchronous cache probe, so whatever is warm draws on the first
/// frame `ImageRenderer` takes. Every size bucket is warmed because which one a view asks for
/// depends on its measured size (see `OPMSlideGalleryTests.warmCardImages`), and a miss draws
/// the monogram fallback.
@MainActor
enum XPostWarmup {
    private static let buckets = [AppImagePipeline.warmSize, AppImagePipeline.cardWarmSize,
                                  AppImagePipeline.crestWarmSize]

    static func warm(_ post: XPostSpecPost) async {
        var urls: [URL] = []
        func players(_ sport: Sport, _ list: [PlayerSeason]) {
            for p in list {
                if let h = p.headshot, let u = URL(string: h) { urls.append(u) }
                if let crest = sport.teamLogoURL(forAbbr: p.teamAbbr) { urls.append(crest) }
            }
        }
        switch post.board {
        case let .resume(puzzle, a, b, _, _): players(puzzle.sport, [a, b])
        case let .keep4(puzzle, _, _, _): players(puzzle.sport, puzzle.players)
        case let .career(puzzle, _):
            for s in puzzle.stints {
                if let crest = puzzle.sport.teamLogoURL(forAbbr: s.teamAbbr, league: s.league) { urls.append(crest) }
            }
        }
        for url in Set(urls) {
            for size in buckets { _ = await ImageCache.shared.image(for: url, targetSize: size) }
        }
    }
}

// MARK: - Shared pieces

private enum Layout {
    static let pad: CGFloat = 26
}

/// Paper ground and the post's content; the wordmark rides small in `TopLine`. No store line:
/// the link lives in the first reply, and an ad-shaped image is what people scroll past.
private struct Poster<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Color.appBackground
            content()
                .padding(Layout.pad)
                .frame(width: XPost.size.width, height: XPost.size.height, alignment: .topLeading)
        }
        .frame(width: XPost.size.width, height: XPost.size.height)
        .clipped()
    }
}

private struct SportChip: View {
    let sport: Sport
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: sport.symbol).font(.system(size: 15, weight: .bold))
            Text(sport.displayName.uppercased()).font(.custom(FontName.condBlack, size: 18))
        }
        .foregroundStyle(sport.onCardFill)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Capsule().fill(sport.cardFill))
        .overlay(Capsule().strokeBorder(Color.borderInk, lineWidth: 2))
        .fixedSize()
    }
}

/// Sport chip, the format's name as a lower third, and the board's own title beside them.
private struct TopLine: View {
    let sport: Sport
    let format: String
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            SportChip(sport: sport)
            LowerThirdHeader(title: LocalizedStringKey(format)).lineLimit(1).fixedSize()
            if let subtitle {
                Text(subtitle)
                    .font(.custom(FontName.condBlack, size: 22))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            Spacer(minLength: 8)
            Wordmark(size: 24).fixedSize()
        }
        .frame(height: 40)
    }
}

private struct OrDisc: View {
    var label: String = "OR"
    var body: some View {
        Text(label)
            .font(.hero(24))
            .foregroundStyle(Color.onVolt)
            .frame(width: 60, height: 60)
            .background(Circle().fill(Color.voltFill))
            .background(Circle().fill(Color.borderInk).offset(x: 3, y: 3))
            .overlay(Circle().strokeBorder(Color.borderInk, lineWidth: 2.5))
    }
}

private func noun(_ puzzle: Keep4Puzzle) -> String {
    switch puzzle.grain {
    case "game": return "GAME"
    case "career": return "CAREER"
    default: return "SEASON"
    }
}

// MARK: - Blind résumé

/// Two lines, no names, one question: the format fantasy X already argues about every offseason.
/// Both lines come off one published board, so the comparison is fair. The reveal is the same
/// two panels unmasked, so the pair reads as a before and after in the thread.
private struct ResumePost: View {
    let puzzle: Keep4Puzzle
    let a: PlayerSeason
    let b: PlayerSeason
    var revealed: Bool = false

    private var aWins: Bool { a.grade >= b.grade }

    var body: some View {
        Poster {
            VStack(alignment: .leading, spacing: 12) {
                TopLine(sport: puzzle.sport, format: "Blind résumé", subtitle: puzzle.theme)
                Text(revealed ? "THE ANSWER" : "WHICH \(noun(puzzle)) WAS BETTER?")
                    .font(.hero(34))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                ZStack {
                    HStack(spacing: 24) {
                        ResumePanel(letter: "A", player: a, puzzle: puzzle, band: .accentFill, onBand: .onAccent,
                                    revealed: revealed, wins: aWins)
                        ResumePanel(letter: "B", player: b, puzzle: puzzle, band: .borderInk, onBand: .surface1,
                                    revealed: revealed, wins: !aWins)
                    }
                    if !revealed { OrDisc() }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}

private struct ResumePanel: View {
    let letter: String
    let player: PlayerSeason
    let puzzle: Keep4Puzzle
    let band: Color
    let onBand: Color
    let revealed: Bool
    let wins: Bool

    private var stats: [PlayerSeason.StatLine] { Array(player.stats.prefix(5)) }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 0) {
                ForEach(Array(stats.enumerated()), id: \.offset) { i, stat in
                    HStack(alignment: .firstTextBaseline) {
                        Text(stat.label.uppercased())
                            .font(.custom(FontName.condBold, size: 20))
                            .foregroundStyle(Color.textMuted)
                        Spacer(minLength: 8)
                        Text(stat.value)
                            .font(.hero(stats.count > 4 ? 28 : 34))
                            .foregroundStyle(Color.textPrimary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 18)
                    .frame(maxHeight: .infinity)
                    if i < stats.count - 1 {
                        Rectangle().fill(Color.hairline).frame(height: 1).padding(.horizontal, 14)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .blockCard(fill: .surface1, radius: 14)
        .overlay(alignment: .topTrailing) {
            if revealed && wins {
                Text("BETTER \(noun(puzzle))")
                    .font(.custom(FontName.condBlack, size: 17))
                    .foregroundStyle(Color.onVolt)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.voltFill))
                    .overlay(Capsule().strokeBorder(Color.borderInk, lineWidth: 2))
                    .rotationEffect(.degrees(4))
                    .offset(x: 10, y: -12)
            }
        }
        .opacity(revealed && !wins ? 0.82 : 1)
    }

    @ViewBuilder private var header: some View {
        if revealed {
            HStack(spacing: 10) {
                PlayerHeadshotBadge(headshot: player.headshot, tint: onBand.opacity(0.3), size: 46, name: player.name)
                VStack(alignment: .leading, spacing: 0) {
                    Text(player.name.uppercased())
                        .font(.hero(24))
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text("\(player.teamAbbr) · \(player.week.map { "WEEK \($0)" } ?? String(player.seasonYear)) · \(String(format: "%.1f", player.grade)) \(puzzle.scoringKind().gradeUnit)")
                        .font(.custom(FontName.condBold, size: 15))
                        .opacity(0.85)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(onBand)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(band)
        } else {
            Text("PLAYER \(letter)")
                .font(.hero(30))
                .foregroundStyle(onBand)
                .frame(maxWidth: .infinity, minHeight: 58)
                .background(band)
        }
    }
}

// MARK: - Keep 4

/// The whole board, readable: eight names, where and when, and the three stats that lead the
/// card. The post is playable in the replies without opening anything.
private struct Keep4BoardPost: View {
    let puzzle: Keep4Puzzle
    let label: String?
    let title: String

    private var columns: [PlayerSeason.StatLine] { Array((puzzle.players.first?.stats ?? []).prefix(3)) }

    var body: some View {
        // Alphabetical: never grade order, and easy to find a name to reply with.
        let players = puzzle.players.sorted { $0.name < $1.name }
        return Poster {
            VStack(alignment: .leading, spacing: 12) {
                TopLine(sport: puzzle.sport, format: label.map { "\($0): Keep 4" } ?? "Keep 4. Cut 4.")
                Text(title.uppercased())
                    .font(.hero(34))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.5)
                HStack(alignment: .top, spacing: 16) {
                    column(Array(players.prefix(4)))
                    column(Array(players.dropFirst(4).prefix(4)))
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.bottom, 22)
        }
    }

    private func column(_ players: [PlayerSeason]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer()
                ForEach(Array(columns.enumerated()), id: \.offset) { _, c in
                    Text(c.label.uppercased())
                        .font(.custom(FontName.condBlack, size: 17))
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .frame(width: 60, alignment: .trailing)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            ForEach(Array(players.enumerated()), id: \.offset) { i, p in
                row(p)
                if i < players.count - 1 {
                    Rectangle().fill(Color.hairline).frame(height: 1)
                }
            }
        }
        .background(Color.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .blockCard(fill: .surface1, radius: 14)
    }

    private func row(_ p: PlayerSeason) -> some View {
        let palette = TeamColors.palette(sport: puzzle.sport, abbr: p.teamAbbr)
        return HStack(spacing: 8) {
            TeamLogoBadge(sport: puzzle.sport, teamAbbr: p.teamAbbr, tint: palette.primary, size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text(p.name)
                    .font(.custom(FontName.condBlack, size: 22))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .fixedSize(horizontal: false, vertical: true)
                // A week board is all one week (the title says which); say the club instead.
                Text(p.week != nil ? p.teamAbbr : "\(p.teamAbbr) · \(String(p.seasonYear))")
                    .font(.custom(FontName.condBold, size: 15))
                    .foregroundStyle(Color.textMuted)
            }
            .layoutPriority(1)
            Spacer(minLength: 2)
            ForEach(Array(columns.enumerated()), id: \.offset) { _, c in
                Text(p.stats.first(where: { $0.label == c.label })?.value ?? "–")
                    .font(.hero(24))
                    .foregroundStyle(Color.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(width: 60, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 62)
    }
}

// MARK: - Name the player

/// The career path as big crests, left to right in the order it happened, and nothing else.
private struct CareerPost: View {
    let puzzle: JourneymanPuzzle

    private var rows: [[JourneymanPuzzle.Stint]] {
        let s = puzzle.stints
        guard s.count > 4 else { return [s] }
        let half = Int((Double(s.count) / 2).rounded(.up))
        return [Array(s.prefix(half)), Array(s.dropFirst(half))]
    }

    var body: some View {
        Poster {
            VStack(alignment: .leading, spacing: 10) {
                TopLine(sport: puzzle.sport, format: "Name the player")
                VStack(spacing: 18) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { r, stints in
                        HStack(spacing: 10) {
                            ForEach(Array(stints.enumerated()), id: \.offset) { i, stint in
                                if r > 0 || i > 0 { arrow }
                                stop(stint)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("\(puzzle.stints.count) CLUBS, IN ORDER. WHO IS IT?")
                    .font(.hero(30))
                    .foregroundStyle(Color.textPrimary)
                    .padding(.bottom, 4)
            }
        }
    }

    private var single: Bool { rows.count == 1 }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: single ? 26 : 20, weight: .black))
            .foregroundStyle(Color.goldFill)
    }

    private func stop(_ stint: JourneymanPuzzle.Stint) -> some View {
        let palette = TeamColors.palette(sport: puzzle.sport, abbr: stint.teamAbbr, league: stint.league)
        let badge: CGFloat = single ? 96 : 64
        return VStack(spacing: 6) {
            TeamLogoBadge(sport: puzzle.sport, teamAbbr: stint.teamAbbr, tint: palette.primary,
                          league: stint.league, size: badge, showsLogo: !(stint.historical ?? false))
            Text(stint.teamName)
                .font(.custom(FontName.condBlack, size: single ? 22 : 18))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2).multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
            Text(stint.yearsLabel)
                .font(.custom(FontName.condBold, size: single ? 20 : 16))
                .foregroundStyle(Color.textMuted)
        }
        .padding(.vertical, single ? 16 : 10).padding(.horizontal, 8)
        .frame(width: single ? 150 : 128)
        .blockCard(fill: .surface1, radius: 14)
    }
}
