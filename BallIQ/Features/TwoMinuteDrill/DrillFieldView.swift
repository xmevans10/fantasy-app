import SwiftUI

/// A schematic broadcast camera, not tracking data. Positions are normalized so the same
/// animation runs on an SE, a larger iPhone, and with the field expanded for replay.
struct DrillFieldView: View, Animatable {
    let state: DrillState
    let lineup: DrillLineup
    let defense: DrillDefense
    let concept: DrillConcept
    let targetID: String?
    var routes: [String: DrillConcept] = [:]
    let presentation: DrillPresentation?
    var motion: Double
    let onPlayer: (DrillPlayer) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var animatableData: Double { get { motion } set { motion = newValue } }

    private var offense: TeamPalette { TeamColors.palette(sport: .nfl, abbr: state.scenario.offense) }
    private var opponent: TeamPalette { TeamColors.palette(sport: .nfl, abbr: state.scenario.defense) }
    private var advance: Double { min(1, max(0, motion - 3)) }
    private var routeProgress: Double { min(1, max(0, (motion - 1) / 2)) }
    private var fieldOffense: [DrillPlayer] {
        guard concept == .kick else { return lineup.offense }
        return lineup.offense.map { player in
            if player.role == "QB" { return lineup.specialists?.first { $0.role == "H" } ?? player }
            if player.role == "RB" { return lineup.specialists?.first { $0.role == "K" } ?? player }
            return player
        }
    }
    private var cameraShift: Double {
        let yardsInView = (0.66 - ballPosition.y) / 0.78 * 45
        return max(0, yardsInView - 24) / 45 * 0.78
    }
    private var target: DrillPlayer? { fieldOffense.first { $0.id == targetID } }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Color(hex: 0x103E2A))
                fieldLines(size)
                routeLines(size)
                ForEach(lineup.defense) { player in
                    token(player, offensive: false).position(point(position(player, offensive: false), size))
                }
                ForEach(fieldOffense) { player in
                    token(player, offensive: true).position(point(position(player, offensive: true), size))
                }
                if motion > 0 {
                    Image(systemName: "football.fill").font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(Color.warningFill)
                        .padding(3).background(.black.opacity(0.7), in: Capsule())
                        .rotationEffect(.degrees(motion * 190))
                        .shadow(color: Color.goldFill.opacity(0.9), radius: 9)
                        .position(point(ballPosition, size))
                        .accessibilityHidden(true)
                }
                if motion >= 3 && motion < 5 {
                    Circle().stroke(Color.goldFill.opacity(max(0, 1 - advance)), lineWidth: 3)
                        .frame(width: 28 + advance * 65, height: 28 + advance * 65)
                        .position(point(carrierEnd, size)).accessibilityHidden(true)
                }
                VStack {
                    HStack(spacing: 6) {
                        Circle().fill(Color.dangerFill).frame(width: 5, height: 5)
                        Text("LIVE · \(state.scenario.defense) DEFENSE").font(.system(size: 9, weight: .heavy, design: .monospaced))
                        Spacer()
                        Text("↑ ATTACK").font(.system(size: 9, weight: .bold, design: .monospaced))
                    }.padding(10).background(.black.opacity(0.3))
                    Spacer()
                    HStack {
                        Text("\(state.scenario.offense) · \(state.fieldPosition.uppercased())")
                        Spacer()
                        Text("ROSTER-BASED SCHEMATIC")
                    }.font(.system(size: 8, weight: .bold, design: .monospaced))
                        .padding(9).background(.black.opacity(0.4))
                }.foregroundStyle(.white)
                if motion > 0 && motion < 4 {
                    VStack {
                        Spacer()
                        Text(stageText).font(.display(26)).italic()
                            .foregroundStyle(Color.onVolt).padding(.horizontal, 18).padding(.vertical, 3)
                            .background(Color.voltFill, in: Capsule())
                            .shadow(color: .black.opacity(0.5), radius: 8)
                            .padding(.bottom, 32)
                    }.allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: offense.primary.opacity(0.24), radius: 16, y: 5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Arcade football field. \(state.situation). \(defense.title). Tap an eligible receiver to select or change his route.")
    }

    private var stageText: String {
        if motion < 1.8 { return "HUT! HUT!" }
        if presentation?.play.sack == true { return "PRESSURE!" }
        if concept == .kick { return "KICK IS UP…" }
        if presentation?.play.call == .run { return motion < 2.7 ? "FOLLOW THE BLOCKS" : "FIND DAYLIGHT" }
        return motion < 2.7 ? "EYES DOWNFIELD" : "BALL IN THE AIR"
    }

    private func fieldLines(_ size: CGSize) -> some View {
        Canvas { context, canvas in
            for yards in stride(from: -15, through: 110, by: 5) {
                let y = 0.66 - Double(yards) / 45 * 0.78 + cameraShift
                guard y > 0.12 && y < 0.92 else { continue }
                let absolute = 100 - state.yardline + yards
                guard (0...100).contains(absolute) else { continue }
                let number = absolute <= 50 ? absolute : 100 - absolute
                if yards % 10 == 0 {
                    context.fill(Path(CGRect(x: 0, y: y * canvas.height, width: canvas.width, height: canvas.height * 0.085)), with: .color(.white.opacity(0.025)))
                }
                var line = Path(); line.move(to: CGPoint(x: 12, y: y * canvas.height)); line.addLine(to: CGPoint(x: canvas.width - 12, y: y * canvas.height))
                context.stroke(line, with: .color(.white.opacity(yards % 10 == 0 ? 0.4 : 0.15)), lineWidth: 1)
                if number % 10 == 0 {
                    let label = Text("\(number)").font(.system(size: 10, weight: .heavy, design: .monospaced)).foregroundColor(.white.opacity(0.6))
                    context.draw(label, at: CGPoint(x: 23, y: y * canvas.height - 8))
                    context.draw(label, at: CGPoint(x: canvas.width - 23, y: y * canvas.height - 8))
                }
                for x in [0.4, 0.6] {
                    var hash = Path(); hash.move(to: CGPoint(x: x * canvas.width, y: y * canvas.height - 3)); hash.addLine(to: CGPoint(x: x * canvas.width, y: y * canvas.height + 3))
                    context.stroke(hash, with: .color(.white.opacity(0.35)), lineWidth: 1)
                }
            }
            let goalY = 0.66 - Double(state.yardline) / 45 * 0.78 + cameraShift
            if goalY > 0.1 {
                context.fill(Path(CGRect(x: 0, y: 0, width: canvas.width, height: min(1, goalY) * canvas.height)), with: .color(opponent.primary.opacity(0.6)))
                let endzone = Text("\(state.scenario.defense) END ZONE").font(.system(size: 13, weight: .black, design: .rounded)).foregroundColor(.white)
                context.draw(endzone, at: CGPoint(x: canvas.width / 2, y: max(0.15, goalY - 0.09) * canvas.height))
                var goal = Path(); goal.move(to: .init(x: 0, y: goalY * canvas.height)); goal.addLine(to: .init(x: canvas.width, y: goalY * canvas.height))
                context.stroke(goal, with: .color(.white), lineWidth: 3)
                if concept == .kick {
                    let postY = goalY - 10.0 / 45 * 0.78
                    var posts = Path()
                    posts.move(to: .init(x: canvas.width * 0.42, y: (postY - 0.07) * canvas.height))
                    posts.addLine(to: .init(x: canvas.width * 0.42, y: (postY + 0.04) * canvas.height))
                    posts.addLine(to: .init(x: canvas.width * 0.58, y: (postY + 0.04) * canvas.height))
                    posts.addLine(to: .init(x: canvas.width * 0.58, y: (postY - 0.07) * canvas.height))
                    context.stroke(posts, with: .color(.goldFill), lineWidth: 3)
                }
            }
            for (y, color) in [(0.66 + cameraShift, Color.accentFill), (0.66 - Double(state.toGo) / 45 * 0.78 + cameraShift, Color.goldFill)] {
                guard y >= 0.12 && y <= 0.92 else { continue }
                var p = Path(); p.move(to: CGPoint(x: 0, y: y * canvas.height)); p.addLine(to: CGPoint(x: canvas.width, y: y * canvas.height))
                context.stroke(p, with: .color(color), lineWidth: 2)
            }
        }.allowsHitTesting(false)
    }

    private func routeLines(_ size: CGSize) -> some View {
        ZStack {
            ForEach(concept == .kick ? [] : lineup.offense.filter(\.eligible)) { player in
                let selected = player.id == targetID
                let route = selected ? concept : (routes[player.id] ?? DrillConcept.defaultForRole(player.role))
                let nodes = routeNodes(player, route: route)
                Path { path in
                    path.move(to: point(nodes[0], size))
                    for node in nodes.dropFirst() { path.addLine(to: point(node, size)) }
                }.trim(from: 0, to: motion == 0 ? 1 : max(0.12, routeProgress))
                    .stroke(selected ? Color.voltFill : Color.white.opacity(0.22), style: StrokeStyle(lineWidth: selected ? 2.5 : 1, lineCap: .round, dash: selected ? [] : [3, 5]))
                if let end = nodes.last, motion == 0 {
                    Image(systemName: "arrowtriangle.up.fill").font(.system(size: selected ? 9 : 6))
                        .foregroundStyle(selected ? Color.voltFill : .white.opacity(0.4))
                        .position(point(end, size))
                }
            }
        }.allowsHitTesting(false)
    }

    private func token(_ player: DrillPlayer, offensive: Bool) -> some View {
        let selected = offensive && player.id == targetID
        let palette = offensive ? offense : opponent
        return Button { onPlayer(player) } label: {
            VStack(spacing: 1) {
                ZStack {
                    Circle().fill(offensive ? palette.primary : palette.secondary)
                    Circle().stroke(selected ? Color.voltFill : Color.white.opacity(offensive ? 0.9 : 0.45), lineWidth: selected ? 3 : 1.5)
                    Text("\(player.jersey)").font(.system(size: selected ? 11 : 10, weight: .black, design: .rounded)).foregroundStyle(offensive ? palette.onPrimary : palette.onSecondary)
                }.frame(width: selected ? 29 : 23, height: selected ? 29 : 23)
                    .shadow(color: selected ? .voltFill.opacity(0.6) : .black.opacity(0.5), radius: selected ? 7 : 3, y: 2)
                if player.eligible || ["QB", "K", "H"].contains(player.role) {
                    Text(player.shortName).font(.system(size: 8, weight: .bold)).lineLimit(1)
                        .foregroundStyle(.white).padding(.horizontal, 3).background(.black.opacity(0.65), in: Capsule())
                        .frame(width: 76)
                }
            }
            .frame(width: offensive && player.eligible ? 64 : 34, height: 40)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).allowsHitTesting(motion == 0).accessibilityHidden(motion > 0)
            .accessibilityLabel("\(player.name), \(player.position), number \(player.jersey)\(selected ? ", selected, \(concept.title) route" : "")")
    }

    private func base(_ p: DrillPlayer, offensive: Bool) -> CGPoint {
        if concept == .kick && offensive {
            let positions: [String: CGPoint] = [
                "LT": .init(x: 0.32, y: 0.69), "LG": .init(x: 0.41, y: 0.69), "C": .init(x: 0.5, y: 0.69), "RG": .init(x: 0.59, y: 0.69), "RT": .init(x: 0.68, y: 0.69),
                "TE": .init(x: 0.78, y: 0.69), "WR1": .init(x: 0.22, y: 0.69), "WR2": .init(x: 0.12, y: 0.75), "WR3": .init(x: 0.88, y: 0.75),
                "H": .init(x: 0.5, y: 0.81), "K": .init(x: 0.65, y: 0.85)]
            return positions[p.role] ?? .init(x: 0.5, y: 0.8)
        }
        let offensePositions: [String: CGPoint] = [
            "QB": .init(x: 0.5, y: 0.83), "RB": .init(x: 0.65, y: 0.83),
            "WR1": .init(x: 0.11, y: 0.68), "WR2": .init(x: 0.89, y: 0.68), "WR3": .init(x: 0.22, y: 0.74), "TE": .init(x: 0.75, y: 0.68),
            "LT": .init(x: 0.37, y: 0.69), "LG": .init(x: 0.435, y: 0.69), "C": .init(x: 0.5, y: 0.69), "RG": .init(x: 0.565, y: 0.69), "RT": .init(x: 0.63, y: 0.69)]
        let rushY = defense == .blitz ? 0.58 : 0.45
        let safetyY = defense == .twoHigh ? 0.19 : 0.3
        let defensePositions: [String: CGPoint] = [
            "E1": .init(x: 0.34, y: 0.59), "DT1": .init(x: 0.45, y: 0.59), "DT2": .init(x: 0.55, y: 0.59), "E2": .init(x: 0.67, y: 0.59),
            "LB1": .init(x: defense == .blitz ? 0.24 : 0.37, y: rushY), "LB2": .init(x: defense == .blitz ? 0.77 : 0.65, y: rushY),
            "CB1": .init(x: 0.11, y: 0.53), "CB2": .init(x: 0.89, y: 0.53), "CB3": .init(x: 0.22, y: 0.43),
            "S1": .init(x: 0.35, y: defense == .loadedBox ? 0.36 : safetyY), "S2": .init(x: 0.72, y: safetyY)]
        return (offensive ? offensePositions : defensePositions)[p.role] ?? .init(x: 0.5, y: 0.5)
    }
    private func routeNodes(_ p: DrillPlayer, route: DrillConcept) -> [CGPoint] {
        let start = base(p, offensive: true)
        let sign = start.x < 0.5 ? 1.0 : -1.0
        let top = max(0.14, start.y - route.depth / 45 * 0.78)
        switch route {
        case .inside, .keeper: return [start, .init(x: 0.5, y: 0.7), .init(x: 0.5, y: top)]
        case .outsideLeft: return [start, .init(x: 0.4, y: 0.83), .init(x: 0.15, y: 0.7), .init(x: 0.1, y: top)]
        case .outsideRight: return [start, .init(x: 0.85, y: 0.83), .init(x: 0.9, y: 0.7), .init(x: 0.9, y: top)]
        case .reverse: return [start, .init(x: 0.8, y: 0.78), .init(x: 0.5, y: 0.86), .init(x: 0.18, y: 0.78), .init(x: 0.1, y: top)]
        case .screen: return [start, .init(x: min(0.9, max(0.1, start.x - sign * 0.07)), y: start.y + 0.03)]
        case .slant: return [start, .init(x: start.x, y: start.y - 0.04), .init(x: start.x + sign * 0.2, y: top)]
        case .out: return [start, .init(x: start.x, y: top), .init(x: start.x < 0.5 ? 0.06 : 0.94, y: top)]
        case .post, .fleaFlicker: return [start, .init(x: start.x, y: start.y - 0.14), .init(x: start.x + sign * 0.22, y: top)]
        default: return [start, .init(x: start.x, y: top)]
        }
    }
    private func position(_ p: DrillPlayer, offensive: Bool) -> CGPoint {
        let start = base(p, offensive: offensive)
        guard motion > 0 else { return start }
        if concept == .kick && offensive { return start }
        if offensive {
            if p.id == targetID && presentation?.play.call == .run {
                var nodes = routeNodes(p, route: concept)
                nodes[nodes.count - 1] = carrierEnd
                return follow(nodes, min(1, max(0, (motion - 1) / 3)))
            }
            if p.eligible {
                let route = p.id == targetID ? concept : (routes[p.id] ?? DrillConcept.defaultForRole(p.role))
                let catchPoint = follow(routeNodes(p, route: route), routeProgress)
                let completed = presentation?.play.complete == true || presentation?.play.call == .run
                return p.id == targetID && completed ? mix(catchPoint, carrierEnd, advance) : catchPoint
            }
            if p.role == "QB" {
                return CGPoint(x: start.x - (concept == .outsideLeft ? 0.06 : 0), y: min(0.91, start.y + min(1, motion) * 0.05))
            }
            return CGPoint(x: start.x, y: start.y - min(1, motion) * 0.035)
        }
        let rushing = p.role.hasPrefix("E") || p.role.hasPrefix("DT") || (defense == .blitz && p.role.hasPrefix("LB"))
        let destination = rushing && concept.call(against: defense) == .pass ? CGPoint(x: 0.5, y: 0.84) : carrierEnd
        let speed = rushing ? 0.85 : 0.45
        return mix(start, destination, min(1, max(0, (motion - 1) / 3)) * speed)
    }
    private var carrierEnd: CGPoint {
        let yards = Double(presentation?.creditedYards ?? 0)
        let y = min(0.91, 0.66 - yards / 45 * 0.78)
        if concept == .outsideLeft || concept == .reverse { return .init(x: 0.1, y: y) }
        if concept == .outsideRight { return .init(x: 0.9, y: y) }
        if presentation?.play.call == .run { return .init(x: 0.5, y: y) }
        return .init(x: target.map { routeNodes($0, route: concept).last?.x ?? 0.5 } ?? 0.6, y: y)
    }
    private var ballPosition: CGPoint {
        let qb = CGPoint(x: 0.5, y: 0.87)
        if motion < 1 { return mix(.init(x: 0.5, y: 0.69), qb, motion) }
        if concept == .kick {
            let t = min(1, max(0, (motion - 1) / 3))
            return .init(x: 0.5 + (presentation?.play.made == false ? t * 0.3 : 0), y: 0.85 + t * (0.66 - Double(state.yardline) / 45 * 0.78 - 0.2 - 0.85))
        }
        if presentation?.play.sack == true { return qb }
        if presentation?.play.call == .run {
            if let target { return position(target, offensive: true) }
            return mix(qb, carrierEnd, min(1, max(0, (motion - 1) / 3)))
        }
        let catchPoint = target.map { routeNodes($0, route: concept).last ?? carrierEnd } ?? carrierEnd
        let t = min(1, max(0, motion - 2))
        var flight = mix(qb, catchPoint, t)
        flight.y -= sin(t * .pi) * 0.15
        if motion >= 3 {
            if presentation?.play.complete != true {
                return mix(catchPoint, .init(x: min(0.95, catchPoint.x + 0.08), y: catchPoint.y + 0.07), advance)
            }
            return mix(catchPoint, carrierEnd, advance)
        }
        return flight
    }
    private func follow(_ nodes: [CGPoint], _ progress: Double) -> CGPoint {
        guard let start = nodes.first else { return .init(x: 0.5, y: 0.5) }
        var path = Path(); path.move(to: start)
        for node in nodes.dropFirst() { path.addLine(to: node) }
        return path.trimmedPath(from: 0, to: CGFloat(min(1, max(0, progress)))).currentPoint ?? start
    }
    private func point(_ p: CGPoint, _ size: CGSize) -> CGPoint { .init(x: p.x * size.width, y: (p.y + cameraShift) * size.height) }
    private func mix(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint { .init(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
}
