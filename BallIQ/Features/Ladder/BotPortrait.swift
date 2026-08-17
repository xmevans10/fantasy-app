import SwiftUI

/// A bot's face.
///
/// **Illustrated where we have one, composed where we don't.** The six shipped characters have
/// authored portraits in `Assets.xcassets` (`bot-<id>`), generated from their own row in `bots` by
/// `tools/avatars/generate_bot_avatars.sh` — see that script for the style and licence, and for
/// why every trait is pinned rather than seeded.
///
/// Anything without an asset falls back to the original composed portrait: the bot's colourway, a
/// backdrop pattern keyed to its playing style, and its emoji as the subject. That fallback is the
/// load-bearing half of this view, not dead code — `bots` is a world-readable table a seventh
/// character can be INSERTed into, and a roster row must never render blank on a shipped build
/// just because the art hasn't caught up. Same defensive shape as `LadderRung.Tier` decoding an
/// unknown tier as bronze rather than throwing.
///
/// The pattern is keyed off `style`, not off the id — so what you see is a readout of how the
/// opponent plays, and two bots sharing a style would visibly rhyme.
struct BotPortrait: View {
    let bot: LadderBot
    var size: CGFloat = 64
    /// Dimmed and desaturated for a rung the player hasn't unlocked.
    var locked: Bool = false

    /// Nil when this character has no shipped portrait — see the fallback note above.
    private var portrait: Image? {
        #if canImport(UIKit)
        guard UIImage(named: "bot-\(bot.id)") != nil else { return nil }
        #endif
        return Image("bot-\(bot.id)")
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(bot.palette.fill.opacity(locked ? 0.16 : 1))
            if let portrait, !locked {
                portrait
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            } else {
                BotPattern(style: bot.style)
                    .stroke(bot.palette.ink.opacity(locked ? 0.10 : 0.28), lineWidth: size * 0.035)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
                Text(locked ? "🔒" : bot.avatar)
                    .font(.system(size: size * 0.46))
                    .shadow(color: .black.opacity(0.18), radius: size * 0.02, y: size * 0.012)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(Color.borderInk, lineWidth: max(1, size * 0.028)))
        .accessibilityHidden(true)   // the name and style always sit beside it in text
    }
}

/// The backdrop, one shape language per playing style. Each is a readout of the mechanic:
/// scattered for the streaky one, a rising ramp for the one that builds, concentric rings for
/// the one that already knows.
private struct BotPattern: Shape {
    let style: BotStyle

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        switch style {
        case .overeager:
            // Scattered ticks at irregular angles — all over the place, like the play.
            let pts: [(CGFloat, CGFloat, CGFloat)] = [
                (0.16, 0.22, 0.7), (0.74, 0.14, -0.5), (0.28, 0.78, -0.9),
                (0.84, 0.66, 0.4), (0.52, 0.10, 1.1), (0.10, 0.56, -0.3)]
            for (x, y, angle) in pts {
                let c = CGPoint(x: w * x, y: h * y)
                let d = CGPoint(x: cos(angle) * w * 0.11, y: sin(angle) * h * 0.11)
                p.move(to: CGPoint(x: c.x - d.x, y: c.y - d.y))
                p.addLine(to: CGPoint(x: c.x + d.x, y: c.y + d.y))
            }
        case .methodical:
            // A ruled grid. Reads the box score, twice.
            for i in 1..<5 {
                let t = CGFloat(i) / 5
                p.move(to: CGPoint(x: w * t, y: 0)); p.addLine(to: CGPoint(x: w * t, y: h))
                p.move(to: CGPoint(x: 0, y: h * t)); p.addLine(to: CGPoint(x: w, y: h * t))
            }
        case .consistent:
            // Even horizontal rules — a metronome.
            for i in 1..<6 {
                let y = h * CGFloat(i) / 6
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
            }
        case .deepCuts:
            // Diagonals running the other way, for the style that runs the other way.
            for i in -2..<6 {
                let x = w * CGFloat(i) / 4
                p.move(to: CGPoint(x: x, y: h)); p.addLine(to: CGPoint(x: x + w * 0.6, y: 0))
            }
        case .slowBurn:
            // A staircase, climbing. Starts cold and gets stronger every card.
            let steps = 5
            var x: CGFloat = 0, y = h
            p.move(to: CGPoint(x: x, y: y))
            for _ in 0..<steps {
                x += w / CGFloat(steps); p.addLine(to: CGPoint(x: x, y: y))
                y -= h / CGFloat(steps); p.addLine(to: CGPoint(x: x, y: y))
            }
        case .prescient:
            // Concentric rings, already resolved around the centre.
            for i in 1..<5 {
                let r = min(w, h) * 0.11 * CGFloat(i)
                p.addEllipse(in: CGRect(x: w / 2 - r, y: h / 2 - r, width: r * 2, height: r * 2))
            }
        }
        return p
    }
}

extension BotPalette {
    /// Backdrop. Drawn from the existing role tokens rather than new colours — the format-tile
    /// system already reserves its hues, and a roster inventing six more would put the app's
    /// palette out of the design system's control.
    var fill: Color {
        switch self {
        case .amber:    return .warningFill
        case .teal:     return .successFill
        case .electric: return .accentFill
        case .green:    return .voltFill
        case .plum:     return .proFill
        case .gold:     return .ink
        }
    }

    /// What reads on top of `fill` — pattern strokes and any text laid over the portrait.
    var ink: Color {
        switch self {
        case .amber:    return .onWarning
        case .teal:     return .onSuccess
        case .electric: return .onAccent
        case .green:    return .onVolt
        case .plum:     return .onPro
        case .gold:     return .surface0
        }
    }

    /// A quiet tint of the same hue, for chips and rails beside the portrait.
    var soft: Color {
        switch self {
        case .amber:    return .warningBg
        case .teal:     return .successBg
        case .electric: return .accentBg
        case .green:    return .voltFill.opacity(0.18)
        case .plum:     return .proBg
        case .gold:     return .surfaceMuted
        }
    }
}

#Preview {
    let bots: [(String, String, BotStyle, BotPalette)] = [
        ("The Rookie", "🐣", .overeager, .amber),
        ("Stat Head", "📊", .methodical, .teal),
        ("The Analyst", "🎙️", .consistent, .electric),
        ("The Scout", "🔭", .deepCuts, .green),
        ("The Archivist", "📼", .slowBurn, .plum),
        ("The Oracle", "🔮", .prescient, .gold),
    ]
    return ScrollView {
        VStack(spacing: 18) {
            ForEach(bots, id: \.0) { name, emoji, style, palette in
                HStack(spacing: 14) {
                    BotPortrait(bot: LadderBot(id: name, name: name, avatar: emoji, tagline: "",
                                               baseSkill: 0.5, persona: "", style: style,
                                               palette: palette), size: 72)
                    BotPortrait(bot: LadderBot(id: name, name: name, avatar: emoji, tagline: "",
                                               baseSkill: 0.5, persona: "", style: style,
                                               palette: palette), size: 44, locked: true)
                    VStack(alignment: .leading) {
                        Text(name).font(.bodyStrong)
                        Text(style.rawValue).font(.label11).foregroundStyle(Color.textMuted)
                    }
                    Spacer()
                }
            }
        }
        .padding(20)
    }
    .background(Color.appBackground)
}
