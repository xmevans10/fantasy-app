import XCTest
import SwiftUI
@testable import BallIQ

/// Renders the daily X posts from the shipping components: the K4C4 card, Home's daily card, the
/// Journeyman career path, the Who Am I? clue ladder and the Week Pack card.
///
/// Same house rule as `OPMSlideGalleryTests` and `XCardGalleryTests`: marketing shows what a
/// player actually sees, so a restyle of any of those views reaches the next morning's posts
/// with no second copy to keep in step. The previous renderer redrew a generic tile grid in
/// Pillow, and every post looked like the same spreadsheet whatever the format.
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
            let renderer = ImageRenderer(content: XPostView(post: post)
                .frame(width: XPost.size.width, height: XPost.size.height)
                .environment(\.colorScheme, .light))
            renderer.scale = XPost.scale
            guard let png = renderer.uiImage?.pngData() else {
                failures.append(post.file)
                continue
            }
            try png.write(to: out.appendingPathComponent(post.file))
            print("X_POST: \(post.file)")
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
        case keep4Daily(Keep4Puzzle, layout: String)
        case keep4Answers(Keep4Puzzle)
        case journeymanDaily(JourneymanPuzzle)
        case journeymanAnswer(JourneymanPuzzle)
        case whoAmIDaily(WhoAmIPuzzle)
        case lineup(Sport, Keep4Puzzle?, WhoAmIPuzzle?, JourneymanPuzzle?)
        case pack(WeekPack)
        case game(WeekPack, WeekPackItem)
    }

    let file: String
    let board: Board

    enum CodingKeys: String, CodingKey {
        case file, kind, layout, sport, content, keep4, whoami, journeyman, pack, items, item
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decode(String.self, forKey: .file)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "daily":
            board = .keep4Daily(try c.decode(Keep4Puzzle.self, forKey: .content),
                                layout: try c.decodeIfPresent(String.self, forKey: .layout) ?? "fan")
        case "answers":
            board = .keep4Answers(try c.decode(Keep4Puzzle.self, forKey: .content))
        case "journeyman":
            board = .journeymanDaily(try c.decode(JourneymanPuzzle.self, forKey: .content))
        case "journeyman-answer":
            board = .journeymanAnswer(try c.decode(JourneymanPuzzle.self, forKey: .content))
        case "whoami":
            board = .whoAmIDaily(try c.decode(WhoAmIPuzzle.self, forKey: .content))
        case "lineup":
            board = .lineup(try c.decode(Sport.self, forKey: .sport),
                            try c.decodeIfPresent(Keep4Puzzle.self, forKey: .keep4),
                            try c.decodeIfPresent(WhoAmIPuzzle.self, forKey: .whoami),
                            try c.decodeIfPresent(JourneymanPuzzle.self, forKey: .journeyman))
        case "pack", "game":
            // The app's own wire rows, so a board this build can't read is dropped the same way.
            let row = try c.decode(WeekPackRow.self, forKey: .pack)
            let items = try c.decode([Lossy<WeekPackItemRow>].self, forKey: .items)
                .compactMap { $0.value?.item }.sorted { $0.ordinal < $1.ordinal }
            let pack = WeekPack(id: row.id, sport: row.sport, label: row.label,
                                releaseDate: row.releaseDate, items: items)
            if kind == "pack" {
                board = .pack(pack)
            } else {
                let id = try c.decode(String.self, forKey: .item)
                guard let item = items.first(where: { $0.id == id }) else {
                    throw DecodingError.dataCorruptedError(forKey: .item, in: c,
                                                           debugDescription: "no pack item \(id)")
                }
                board = .game(pack, item)
            }
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                                                   debugDescription: "unknown post kind \(kind)")
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
        func keep4(_ puzzle: Keep4Puzzle) {
            for p in puzzle.players {
                if let h = p.headshot, let u = URL(string: h) { urls.append(u) }
                if let crest = puzzle.sport.teamLogoURL(forAbbr: p.teamAbbr) { urls.append(crest) }
            }
        }
        func journeyman(_ puzzle: JourneymanPuzzle) {
            for s in puzzle.stints {
                if let crest = puzzle.sport.teamLogoURL(forAbbr: s.teamAbbr, league: s.league) { urls.append(crest) }
            }
            if let h = puzzle.headshot, let u = URL(string: h) { urls.append(u) }
        }
        switch post.board {
        case .keep4Daily(let p, _), .keep4Answers(let p): keep4(p)
        case .journeymanDaily(let p), .journeymanAnswer(let p): journeyman(p)
        case .whoAmIDaily: break
        case .lineup(_, let k, _, let j):
            if let k { keep4(k) }
            if let j { journeyman(j) }
        case .pack(let pack), .game(let pack, _):
            for item in pack.items { keep4(item.keep4) }
        }
        for url in Set(urls) {
            for size in buckets { _ = await ImageCache.shared.image(for: url, targetSize: size) }
        }
    }
}

// MARK: - Posts

struct XPostView: View {
    let post: XPostSpecPost

    var body: some View {
        switch post.board {
        case .keep4Daily(let puzzle, let layout): Keep4DailyPost(puzzle: puzzle, layout: layout)
        case .keep4Answers(let puzzle): Keep4AnswersPost(puzzle: puzzle)
        case .journeymanDaily(let puzzle): JourneymanPost(puzzle: puzzle, revealed: false)
        case .journeymanAnswer(let puzzle): JourneymanPost(puzzle: puzzle, revealed: true)
        case .whoAmIDaily(let puzzle): WhoAmIPost(puzzle: puzzle)
        case .lineup(let sport, let k, let w, let j): LineupPost(sport: sport, keep4: k, whoAmI: w, journeyman: j)
        case .pack(let pack): PackPost(pack: pack)
        case .game(let pack, let item): GamePost(pack: pack, item: item)
        }
    }
}

// MARK: Shared frame

/// Paper ground, a header row, the post's content, and the broadcast-bug footer.
private struct PostFrame<Content: View>: View {
    var ground: Color = .appBackground
    let content: Content

    init(ground: Color = .appBackground, @ViewBuilder content: () -> Content) {
        self.ground = ground
        self.content = content()
    }

    var body: some View {
        ZStack {
            ground
            content
        }
        .clipped()
    }
}

private struct Footer: View {
    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            Wordmark(size: 26)
            Spacer()
            Text("Free on the App Store")
                .font(.custom(FontName.bodyMedium, size: 14))
                .foregroundStyle(Color.textPrimary)
        }
    }
}

/// Sport capsule + lower-third title, as a Home section reads.
private struct PostHeader: View {
    let sport: Sport?
    let title: String
    var formatName: String? = nil
    var formatFill: Color = .accentFill
    var onFormat: Color = .onAccent

    var body: some View {
        HStack(spacing: 8) {
            if let sport { SportChip(sport: sport) }
            if let formatName {
                Text(formatName.uppercased())
                    .font(.custom(FontName.condBlack, size: 14))
                    .foregroundStyle(onFormat)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(formatFill))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.borderInk, lineWidth: 2))
            }
            LowerThirdHeader(title: LocalizedStringKey(title))
                .lineLimit(1)
                .fixedSize()
        }
        .fixedSize()
    }
}

private struct SportChip: View {
    let sport: Sport
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: sport.symbol).font(.system(size: 12, weight: .bold))
            Text(sport.displayName.uppercased()).font(.custom(FontName.condBlack, size: 14))
        }
        .foregroundStyle(sport.onCardFill)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(sport.cardFill))
        .overlay(Capsule().strokeBorder(Color.borderInk, lineWidth: 2))
    }
}

private struct Headline: View {
    let text: String
    var size: CGFloat = 54
    var lines: Int = 2
    var color: Color = .textPrimary

    var body: some View {
        Text(text.uppercased())
            .font(.hero(size))
            .foregroundStyle(color)
            .lineLimit(lines)
            .minimumScaleFactor(0.45)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Kicker: View {
    let text: String
    var color: Color = .textMuted
    var body: some View {
        Text(text)
            .font(.custom(FontName.bodyMedium, size: 17))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The K4C4 card at its real board size, scaled — never squeezed, because its image sizes are
/// derived from its measured proportions.
private struct ScaledCard: View {
    let player: PlayerSeason
    let puzzle: Keep4Puzzle
    var assignment: Pile? = nil
    var revealCorrect: Bool? = nil
    var foil: Bool = false
    let height: CGFloat

    private static let native = CGSize(width: 370, height: 470)

    var body: some View {
        let s = height / Self.native.height
        Keep4CardView(player: player, sport: puzzle.sport,
                      assignment: assignment, revealCorrect: revealCorrect, foil: foil,
                      gradeUnit: puzzle.scoringKind().gradeUnit,
                      showGrade: puzzle.scoringKind() != .vibes,
                      fillsHeight: true,
                      teamFullName: TeamIdentityIndex.shared
                          .identity(sport: puzzle.sport, abbr: player.teamAbbr, league: nil)?.fullName) { _ in }
            .frame(width: Self.native.width, height: Self.native.height)
            .scaleEffect(s)
            .frame(width: Self.native.width * s, height: height)
    }
}

/// Every post is the same two columns: copy on the left, the app on a fixed stage on the right.
/// Fixed, because `ImageRenderer` takes one layout pass and an HStack that is a few points too
/// wide doesn't wrap, it overflows both edges of the canvas.
private enum Grid {
    static let pad = EdgeInsets(top: 24, leading: 30, bottom: 24, trailing: 30)
    static let gap: CGFloat = 24
    static let copyWidth: CGFloat = 320
    static var stage: CGSize {
        CGSize(width: XPost.size.width - pad.leading - pad.trailing - copyWidth - gap,
               height: XPost.size.height - pad.top - pad.bottom)
    }
}

private struct TwoColumn<Copy: View, Stage: View>: View {
    var copyWidth: CGFloat = Grid.copyWidth
    @ViewBuilder let copy: () -> Copy
    @ViewBuilder let stage: () -> Stage

    var body: some View {
        let stageWidth = XPost.size.width - Grid.pad.leading - Grid.pad.trailing - copyWidth - Grid.gap
        HStack(spacing: Grid.gap) {
            VStack(alignment: .leading, spacing: 12) { copy() }
                .frame(width: copyWidth, height: Grid.stage.height, alignment: .leading)
            stage()
                .frame(width: stageWidth, height: Grid.stage.height)
        }
        .padding(Grid.pad)
        .frame(width: XPost.size.width, height: XPost.size.height)
    }
}

/// Lays `content` out at the width the app gives it, then scales the result into the stage.
private struct Scaled<Content: View>: View {
    let nativeWidth: CGFloat
    let scale: CGFloat
    var height: CGFloat = Grid.stage.height
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(width: nativeWidth)
            .fixedSize(horizontal: false, vertical: true)
            .scaleEffect(scale, anchor: .center)
            .frame(width: nativeWidth * scale, height: height)
    }
}

/// Deterministic, spoiler-free pick: never grade order.
private func spoilerFreeOrder(_ players: [PlayerSeason], salt: String) -> [PlayerSeason] {
    players.sorted { stableHash($0.id + salt) < stableHash($1.id + salt) }
}

private func stableHash(_ s: String) -> UInt64 {
    s.utf8.reduce(1469598103934665603) { ($0 ^ UInt64($1)) &* 1099511628211 }
}

// MARK: K4C4

private struct Keep4DailyPost: View {
    let puzzle: Keep4Puzzle
    let layout: String

    private var picks: [PlayerSeason] { spoilerFreeOrder(puzzle.players, salt: puzzle.id) }

    var body: some View {
        PostFrame {
            switch layout {
            case "hero": hero
            case "duo": duo
            default: fan
            }
        }
    }

    /// Three cards dealt like a hand.
    private var fan: some View {
        TwoColumn {
            PostHeader(sport: puzzle.sport, title: "Today's K4C4")
            Spacer(minLength: 0)
            Headline(text: puzzle.theme, size: 50, lines: 3)
            Kicker(text: "Eight real stat lines. Keep four, cut four.")
            Spacer(minLength: 0)
            Footer()
        } stage: {
            ZStack {
                ForEach(Array(picks.prefix(3).enumerated()), id: \.offset) { i, player in
                    ScaledCard(player: player, puzzle: puzzle, height: 300)
                        .rotationEffect(.degrees(Double(i - 1) * 8))
                        .offset(x: CGFloat(i - 1) * 78, y: i == 1 ? -10 : 12)
                        .zIndex(i == 1 ? 1 : 0)
                }
            }
        }
    }

    /// One card, full height, and the rest of the board named beside it.
    private var hero: some View {
        TwoColumn(copyWidth: 400) {
            PostHeader(sport: puzzle.sport, title: "Keep or cut?")
            Spacer(minLength: 0)
            Headline(text: puzzle.theme, size: 44, lines: 3)
            Kicker(text: "\(picks[0].name) is one of eight. Only four make the cut.")
            FlowNames(names: picks.dropFirst().map(\.name))
            Spacer(minLength: 0)
            Footer()
        } stage: {
            ScaledCard(player: picks[0], puzzle: puzzle, height: 390)
                .rotationEffect(.degrees(3))
        }
    }

    /// Two cards and a question.
    private var duo: some View {
        TwoColumn {
            PostHeader(sport: puzzle.sport, title: "Today's K4C4")
            Spacer(minLength: 0)
            Headline(text: "Which one makes your four?", size: 50, lines: 3)
            Kicker(text: puzzle.theme)
            Spacer(minLength: 0)
            Footer()
        } stage: {
            ZStack {
                ScaledCard(player: picks[0], puzzle: puzzle, height: 262)
                    .rotationEffect(.degrees(-4))
                    .offset(x: -100, y: 8)
                ScaledCard(player: picks[1], puzzle: puzzle, height: 262)
                    .rotationEffect(.degrees(4))
                    .offset(x: 100, y: -8)
                OrDisc()
            }
        }
    }
}

private struct OrDisc: View {
    var label: String = "OR"
    var body: some View {
        Text(label)
            .font(.hero(22))
            .foregroundStyle(Color.onVolt)
            .frame(width: 52, height: 52)
            .background(Circle().fill(Color.voltFill))
            .background(Circle().fill(Color.borderInk).offset(x: 3, y: 3))
            .overlay(Circle().strokeBorder(Color.borderInk, lineWidth: 2.5))
    }
}

/// Names as chips that wrap.
private struct FlowNames: View {
    let names: [String]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(names, id: \.self) { name in
                Text(name)
                    .font(.custom(FontName.condBold, size: 14))
                    .foregroundStyle(Color.textPrimary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.surface1))
                    .overlay(Capsule().strokeBorder(Color.borderInk, lineWidth: 1.5))
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { y += row + spacing; x = 0; row = 0 }
            x += s.width + spacing; row = max(row, s.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { y += row + spacing; x = bounds.minX; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

private struct Keep4AnswersPost: View {
    let puzzle: Keep4Puzzle

    private var ranked: [PlayerSeason] { puzzle.players.sorted { $0.grade > $1.grade } }

    var body: some View {
        PostFrame {
            TwoColumn {
                PostHeader(sport: puzzle.sport, title: "Yesterday's answers")
                Spacer(minLength: 0)
                Headline(text: puzzle.theme, size: 38, lines: 2)
                HStack(alignment: .top, spacing: 14) {
                    pile("KEEP", ranked.prefix(4), .successFill, "checkmark")
                    pile("CUT", ranked.dropFirst(4).prefix(4), .dangerFill, "xmark")
                }
                Spacer(minLength: 0)
                Footer()
            } stage: {
                ZStack {
                    // The fifth-best line: the closest call on the board.
                    ScaledCard(player: ranked[4], puzzle: puzzle, assignment: .cut,
                               revealCorrect: true, height: 290)
                        .rotationEffect(.degrees(6))
                        .offset(x: 84, y: 30)
                    ScaledCard(player: ranked[0], puzzle: puzzle, assignment: .keep,
                               revealCorrect: true, foil: true, height: 340)
                        .rotationEffect(.degrees(-4))
                        .offset(x: -60, y: -6)
                }
            }
        }
    }

    private func pile(_ title: String, _ players: some Sequence<PlayerSeason>, _ fill: Color,
                      _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.custom(FontName.condBlack, size: 14))
                .foregroundStyle(Color.onSuccess)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(fill))
            ForEach(Array(players), id: \.id) { p in
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 11, weight: .black)).foregroundStyle(fill)
                    Text(p.name).font(.custom(FontName.condBold, size: 17)).foregroundStyle(Color.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Journeyman

private struct JourneymanPost: View {
    let puzzle: JourneymanPuzzle
    let revealed: Bool

    /// Rows per column of the path. A long career wraps into a second column rather than
    /// shrinking every crest to nothing.
    private var columns: [[JourneymanPuzzle.Stint]] {
        let perColumn = puzzle.stints.count <= 4 ? 4 : Int((Double(puzzle.stints.count) / 2).rounded(.up))
        return stride(from: 0, to: puzzle.stints.count, by: perColumn).map {
            Array(puzzle.stints[$0..<min($0 + perColumn, puzzle.stints.count)])
        }
    }

    var body: some View {
        PostFrame {
            TwoColumn {
                PostHeader(sport: puzzle.sport, title: revealed ? "The answer" : "Today's daily",
                           formatName: "Journeyman", formatFill: .goldFill, onFormat: .onGold)
                Spacer(minLength: 0)
                if revealed {
                    reveal
                } else {
                    Headline(text: "Name the player from their clubs", size: 48, lines: 3)
                    Kicker(text: "\(puzzle.stints.count) clubs. Five guesses. The sooner you get it, the more it pays.")
                    GuessPips()
                }
                Spacer(minLength: 0)
                Footer()
            } stage: {
                HStack(alignment: .center, spacing: 12) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, stints in
                        CareerPathTimeline(sport: puzzle.sport, stints: stints)
                            .frame(width: columns.count > 1 ? 200 : 300)
                    }
                }
                .scaleEffect(pathScale, anchor: .center)
                .frame(width: Grid.stage.width, height: Grid.stage.height)
                .blockCard(fill: .goldFill)
            }
        }
    }

    /// Fits the tallest column (a stint row is about 88pt with its connector) and the widest
    /// row into the stage, growing a short career rather than leaving it marooned.
    private var pathScale: CGFloat {
        let rows = CGFloat(columns.map(\.count).max() ?? 1)
        let width: CGFloat = columns.count > 1 ? CGFloat(columns.count) * 212 : 300
        return min(1.2, (Grid.stage.height - 40) / (rows * 88), (Grid.stage.width - 40) / width)
    }

    private var reveal: some View {
        HStack(spacing: 14) {
            PlayerHeadshotBadge(headshot: puzzle.headshot, tint: .goldFill, size: 96,
                                name: puzzle.answer.canonical)
            VStack(alignment: .leading, spacing: 4) {
                Headline(text: puzzle.answer.canonical, size: 44, lines: 2)
                Kicker(text: "\(puzzle.stints.count) clubs, \(puzzle.stints.first?.firstYear ?? 0) to \(puzzle.stints.last?.lastYear ?? 0).")
            }
        }
    }
}

private struct GuessPips: View {
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<JourneymanScoring.maxGuesses, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.goldFill)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.borderInk, lineWidth: 1.5))
                    .frame(width: 34, height: 12)
            }
        }
    }
}

// MARK: Who Am I?

private struct WhoAmIPost: View {
    let puzzle: WhoAmIPuzzle
    /// Clue one is free in the game too, so the post gives away nothing a player wouldn't see
    /// the moment they open the board.
    private let revealed = 1

    var body: some View {
        PostFrame {
            TwoColumn {
                PostHeader(sport: puzzle.sport, title: "Today's daily",
                           formatName: "Who am I?", formatFill: .voltFill, onFormat: .onVolt)
                Spacer(minLength: 0)
                Headline(text: "One clue in. Who is it?", size: 52, lines: 3)
                Kicker(text: "\(puzzle.clues.count) clues. Name the player early and the points are yours.")
                Spacer(minLength: 0)
                Footer()
            } stage: {
                // Six rows of about 62pt plus gaps: laid out at the phone's width, then scaled.
                Scaled(nativeWidth: 380, scale: min(1, (Grid.stage.height - 8) / (CGFloat(puzzle.clues.count) * 70 + 28))) {
                    VStack(spacing: 8) {
                        ForEach(Array(puzzle.clues.enumerated()), id: \.offset) { index, clue in
                            if index < revealed {
                                WhoAmIClueRow(clue: clue)
                            } else {
                                let cost = WhoAmIScoring.cost(toUnlock: index + 1, difficulty: puzzle.difficulty)
                                WhoAmILockedClueRow(position: index + 1, costText: "−\(cost) pts",
                                                    accessibilityText: "")
                            }
                        }
                    }
                    .padding(14)
                    .blockCard(fill: .surface1)
                }
            }
        }
    }
}

// MARK: Lineup

/// One sport's three dailies as Home stacks them.
private struct LineupPost: View {
    let sport: Sport
    let keep4: Keep4Puzzle?
    let whoAmI: WhoAmIPuzzle?
    let journeyman: JourneymanPuzzle?

    private var count: Int { [keep4 != nil, whoAmI != nil, journeyman != nil].filter { $0 }.count }

    var body: some View {
        PostFrame {
            TwoColumn {
                PostHeader(sport: sport, title: "Today")
                Spacer(minLength: 0)
                Headline(text: "\(["One board", "Two boards", "Three boards"][max(0, count - 1)]). One morning.",
                         size: 56, lines: 3)
                Kicker(text: "Today's \(sport.displayName) dailies are live, built from real stat lines.")
                Spacer(minLength: 0)
                Footer()
            } stage: {
                // Laid out wide enough that each card's badges sit on one row (about 185pt tall),
                // then scaled by whichever of width and height binds first.
                Scaled(nativeWidth: 520, scale: min(Grid.stage.width / 520,
                                                    (Grid.stage.height - 8) / (CGFloat(count) * 197))) {
        VStack(spacing: 12) {
                            if let keep4 {
                                DailyGameCard(formatName: "K4C4", symbol: "rectangle.stack.fill", sport: sport,
                                              title: keep4.theme,
                                              subtitle: "\(keep4.players.count) \(keep4.puzzleGrain().countNoun)",
                                              scoring: keep4.scoringKind(), grain: keep4.puzzleGrain(),
                                              completed: false, ranked: true,
                                              dateBadge: DailyGameCard.todayDateBadge) {}
                            }
                            if let whoAmI {
                                DailyGameCard(formatName: "Who am I?", symbol: "questionmark.circle.fill", sport: sport,
                                              title: String(localized: "Guess today's mystery player"),
                                              subtitle: String(localized: "\(whoAmI.clues.count) clues"),
                                              difficulty: whoAmI.difficulty, completed: false,
                                              typeColor: .voltFill, onTypeColor: .onVolt, ranked: true,
                                              dateBadge: DailyGameCard.todayDateBadge) {}
                            }
                            if let journeyman {
                                DailyGameCard(formatName: "Journeyman", symbol: "arrow.triangle.branch", sport: sport,
                                              title: String(localized: "Name the player from their clubs"),
                                              subtitle: String(localized: "\(journeyman.stints.count) clubs"),
                                              difficulty: journeyman.difficulty, completed: false,
                                              typeColor: .goldFill, onTypeColor: .onGold, ranked: true,
                                              dateBadge: DailyGameCard.todayDateBadge) {}
                            }
                        }
                }
            }
        }
    }
}

// MARK: Week Pack

private struct PackPost: View {
    let pack: WeekPack

    /// The boards the post can hold at a readable size; the rest are counted.
    private let shown = 2

    var body: some View {
        PostFrame {
            TwoColumn {
                PostHeader(sport: nil, title: "Just dropped")
                Spacer(minLength: 0)
                WeekPackCard(pack: pack, progress: WeekPackProgress(pack: pack, results: []),
                             isNew: true) {}
                Kicker(text: "\(pack.items.count) boards on the week that just ended. Every stat line is from it.")
                Spacer(minLength: 0)
                Footer()
            } stage: {
                VStack(spacing: 6) {
                    Scaled(nativeWidth: 520, scale: min(Grid.stage.width / 520, (Grid.stage.height - 40) / 430),
                           height: Grid.stage.height - 40) {
                        VStack(spacing: 10) {
                            ForEach(pack.items.prefix(shown)) { item in
                                let puzzle = item.keep4
                                DailyGameCard(formatName: "K4C4", symbol: "rectangle.stack.fill", sport: puzzle.sport,
                                              title: item.displayTitle(packLabel: pack.label),
                                              subtitle: "\(item.role.label) · \(puzzle.players.count) \(puzzle.puzzleGrain().countNoun)",
                                              scoring: puzzle.scoringKind(), grain: puzzle.puzzleGrain(),
                                              completed: false, ranked: false) {}
                            }
                        }
                    }
                    if pack.items.count > shown {
                        Text("+ \(pack.items.count - shown) more boards in the pack")
                            .font(.custom(FontName.condBlack, size: 16))
                            .foregroundStyle(Color.textPrimary)
                    }
                }
            }
        }
    }
}

private struct GamePost: View {
    let pack: WeekPack
    let item: WeekPackItem

    private var puzzle: Keep4Puzzle { item.keep4 }
    private var teams: [String] {
        var seen: [String] = []
        for p in puzzle.players where !seen.contains(p.teamAbbr) { seen.append(p.teamAbbr) }
        return seen
    }

    var body: some View {
        let (a, b) = (teams.first ?? "", teams.dropFirst().first ?? "")
        let left = spoilerFreeOrder(puzzle.players.filter { $0.teamAbbr == a }, salt: item.id).first
        let right = spoilerFreeOrder(puzzle.players.filter { $0.teamAbbr == b }, salt: item.id).first
        return PostFrame {
            TwoColumn {
                PostHeader(sport: pack.sport, title: "Game of the week")
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    badge(a)
                    Text("vs").font(.custom(FontName.condBlack, size: 22)).foregroundStyle(Color.textMuted)
                    badge(b)
                }
                Headline(text: "Who had the better day?", size: 50, lines: 2)
                Kicker(text: "Eight players from one game. Keep the best four.")
                Spacer(minLength: 0)
                Footer()
            } stage: {
                ZStack {
                    if let left {
                        ScaledCard(player: left, puzzle: puzzle, height: 280)
                            .rotationEffect(.degrees(-4)).offset(x: -94, y: 8)
                    }
                    if let right {
                        ScaledCard(player: right, puzzle: puzzle, height: 280)
                            .rotationEffect(.degrees(4)).offset(x: 94, y: -8)
                    }
                    OrDisc(label: "VS")
                }
            }
        }
    }

    private func badge(_ abbr: String) -> some View {
        let palette = TeamColors.palette(sport: pack.sport, abbr: abbr)
        return HStack(spacing: 6) {
            TeamLogoBadge(sport: pack.sport, teamAbbr: abbr, tint: palette.primary, size: 44)
            Text(abbr).font(.hero(40)).foregroundStyle(Color.textPrimary)
        }
    }
}
