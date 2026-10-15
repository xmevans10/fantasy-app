import SwiftUI

@MainActor
struct TwoMinuteDrillView: View {
    private enum Mode: String, CaseIterable { case daily = "Daily", practice = "Practice", survivor = "Survivor" }
    private enum Family: String, CaseIterable { case run = "RUN", pass = "PASS", rpo = "RPO", trick = "TRICK" }
    @EnvironmentObject private var container: RepositoryContainer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("drill.sound") private var sound = true
    @State private var bank: DrillBank?
    @State private var state: DrillState?
    @State private var mode: Mode = .daily
    @State private var error: String?
    @State private var day = ""
    @State private var seed: UInt64 = 0
    @State private var snapIndex = 0
    @State private var startedAt = Date()
    @State private var family: Family?
    @State private var concept: DrillConcept = .slant
    @State private var targetID: String?
    @State private var routes: [String: DrillConcept] = [:]
    @State private var options = DrillPlayOptions()
    @State private var tempo: DrillTempo = .hurry
    @State private var choices: [DrillConcept: DrillChoice] = [:]
    @State private var preparing = false
    @State private var preparationID = UUID()
    @State private var presentation: DrillPresentation?
    @State private var phase: DrillAnimationPhase = .set
    @State private var motion = 0.0
    @State private var committed: UUID?
    @State private var animationTask: Task<Void, Never>?
    @State private var celebrations = 0
    @State private var saved = false
    @State private var saving = false
    @State private var rewardText = ""
    @State private var showHelp = false
    @State private var showExit = false
    @State private var showComparison = false
    @State private var showLog = false
    @State private var inspected: DrillPlayer?
    @State private var survivorWins = 0
    @State private var survivorPlayed: Set<String> = []

    private var daily: Bool { mode == .daily }
    private var animating: Bool { presentation != nil && phase != .result }
    private var defense: DrillDefense { presentation?.defense ?? .draw(seed: seed, snap: snapIndex) }
    private var lineup: DrillLineup? { state.flatMap { bank?.lineups?[$0.scenario.id] } }
    private var target: DrillPlayer? { lineup?.offense.first { $0.id == targetID } }
    private var alreadyPlayed: Bool { UserDefaults.standard.bool(forKey: "drill.finished.\(day)") }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                Group {
                    if let state, let lineup {
                        VStack(spacing: 10) {
                            scoreboard(state)
                            ZStack {
                                DrillFieldView(state: presentation?.before ?? state, lineup: lineup, defense: defense,
                                    concept: presentation?.concept ?? concept, targetID: presentation?.target?.id ?? targetID,
                                    routes: routes, presentation: presentation, motion: motion, onPlayer: selectPlayer)
                                if phase == .result, let presentation {
                                    VStack {
                                        Text(presentation.headline).font(.display(30)).italic().multilineTextAlignment(.center)
                                            .foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 7)
                                            .background(verdictColor(presentation).opacity(0.95), in: RoundedRectangle(cornerRadius: 9))
                                            .rotationEffect(.degrees(-3)).shadow(color: .black.opacity(0.5), radius: 8)
                                        Spacer()
                                    }.padding(.top, 36).transition(.scale(scale: 1.4).combined(with: .opacity))
                                }
                            }
                            .frame(height: max(195, min(family == nil ? 300 : 250, geometry.size.height * (phase == .result ? 0.33 : 0.41))))
                            .celebrate(on: $celebrations, intensity: 50)
                            ScrollView {
                                if animating { liveCommentary }
                                else if let presentation, phase == .result { feedback(presentation) }
                                else { playbook(state) }
                            }.scrollIndicators(.hidden)
                        }.padding(.horizontal, 14).padding(.top, 8)
                    } else if let bank {
                        ScrollView { setup(bank).padding(20) }
                    } else if let error {
                        ContentUnavailableView("Playbook unavailable", systemImage: "football", description: Text(error))
                    } else { ProgressView("Loading the playbook…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { actionDock }
            .background(Color.surface0).foregroundStyle(Color.ink)
            .navigationTitle("Two-Minute Drill").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") {
                        if state != nil && state?.ended == nil { showExit = true } else { dismiss() }
                    }.labelStyle(.iconOnly).disabled(saving)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(sound ? "Mute game sound" : "Enable game sound", systemImage: sound ? "speaker.wave.2" : "speaker.slash") { sound.toggle() }.labelStyle(.iconOnly)
                    Button("How to play", systemImage: "info.circle") { showHelp = true }.labelStyle(.iconOnly)
                }
            }
            .confirmationDialog("Leave this drive? Unfinished progress will be lost.", isPresented: $showExit, titleVisibility: .visible) {
                Button("Leave drive", role: .destructive) { animationTask?.cancel(); dismiss() }
            }
            .sheet(isPresented: $showHelp) { help }
            .sheet(isPresented: $showComparison) { comparison }
            .sheet(isPresented: $showLog) { playLog }
            .sheet(item: $inspected) { player in playerDetails(player) }
            .task { await load() }
            .onDisappear { animationTask?.cancel(); preparationID = UUID() }
            .onChange(of: scenePhase) { _, value in
                if value == .active && state == nil { day = DrillBank.dayKey(Date()) }
                if value != .active && animating { finishAnimation() }
            }
        }
    }

    private func setup(_ bank: DrillBank) -> some View {
        let preview = dailyScenario(bank)
        return VStack(alignment: .leading, spacing: 18) {
            Text("ARCADE FOOTBALL").font(.label12).tracking(3).foregroundStyle(Color.accentText)
            Text("TWO MINUTES.\nALL YOU.").font(.display(50)).italic().lineSpacing(-12)
            Text("Read the defense. Draw the route. Call the shot.").font(.bodyStrong)
            if let lineup = bank.lineups?[preview.id] {
                DrillFieldView(state: DrillState(preview), lineup: lineup, defense: .twoHigh, concept: .post,
                    targetID: lineup.offense.first { $0.role == "WR1" }?.id, presentation: nil,
                    motion: 0, onPlayer: { inspected = $0 }).frame(height: 205)
            }
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if daily {
                HStack {
                    Text("\(preview.offense) \(preview.offenseScore)  –  \(preview.defenseScore) \(preview.defense)").font(.heading)
                    Spacer()
                    Text("Q4 · \(String(format: "%d:%02d", preview.seconds / 60, preview.seconds % 60))").font(.heading)
                }
                Text("\(preview.date) · \(preview.timeouts) timeouts · Real starting situation").font(.label12).foregroundStyle(Color.textSecondary)
            } else {
                Text(mode == .survivor ? "SCORE TO STAY ALIVE. Tie or take the lead to earn another drive. One failed possession ends your run." : "A fresh historical drive every run. Explore the whole playbook without risking your rating.")
                    .font(.bodyStrong)
            }
            Text(daily ? (alreadyPlayed ? "Daily XP banked · Replays are practice" : "Daily · Unranked · First finish earns XP · Resets midnight UTC") : "Practice scoring · No XP or rating changes")
                .font(.label12).foregroundStyle(Color.textSecondary)
            Text("\(bank.scenarios.count) real starts · \(bank.plays.count.formatted()) archived plays · 2024 rosters").font(.label12)
            Button("Rules, simulation & data sources") { showHelp = true }.font(.bodyStrong)
        }
    }

    private func scoreboard(_ s: DrillState) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 0) {
                teamScore(s.scenario.offense, score: s.scenario.offenseScore + s.points, you: true)
                VStack(spacing: 0) {
                    Text("Q4 · \(mode == .survivor ? "\(survivorWins) WINS" : daily ? "DAILY DRIVE" : "PRACTICE")").font(.system(size: 8, weight: .heavy, design: .monospaced))
                    Text(s.clock).font(.hero(35)).monospacedDigit().contentTransition(.numericText())
                        .foregroundStyle(s.seconds <= 30 ? Color.warningFill : .white)
                }.frame(maxWidth: .infinity)
                teamScore(s.scenario.defense, score: s.scenario.defenseScore + (s.ended == "Safety" ? 2 : 0), you: false)
            }
            HStack {
                Text(s.situation.uppercased()).font(.system(size: 10, weight: .heavy, design: .monospaced))
                Spacer()
                Text(s.ended != nil ? "FINAL" : s.running ? "● CLOCK RUNNING" : "CLOCK STOPPED").font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(s.running ? Color.warningFill : Color.voltFill)
            }
        }.padding(.horizontal, 12).padding(.vertical, 7).foregroundStyle(.white)
            .background(Color(hex: 0x15120B), in: RoundedRectangle(cornerRadius: 12))
            .animation(reduceMotion ? nil : Motion.snap, value: s.seconds)
            .animation(reduceMotion ? nil : Motion.snap, value: s.points)
    }
    private func teamScore(_ team: String, score: Int, you: Bool) -> some View {
        let palette = TeamColors.palette(sport: .nfl, abbr: team)
        return HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2).fill(palette.primary).overlay(RoundedRectangle(cornerRadius: 2).stroke(.white.opacity(0.3))).frame(width: 5, height: 33)
            VStack(alignment: .leading, spacing: 1) {
                Text(team).font(.custom(FontName.condBlack, fixedSize: 22))
                HStack(spacing: 3) {
                    if you { Text("YOU").font(.system(size: 7, weight: .black)).fixedSize() }
                    ForEach(0..<3) { index in Capsule().fill(index < (you ? state?.timeouts ?? 0 : state?.scenario.defenseTimeouts ?? 0) ? Color.goldFill : .white.opacity(0.15)).frame(width: 7, height: 3) }
                }
            }
            Text("\(score)").font(.hero(32)).frame(minWidth: 30).fixedSize()
        }.frame(minWidth: 93).fixedSize(horizontal: true, vertical: false)
    }

    private func playbook(_ s: DrillState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Image(systemName: defense == .blitz ? "bolt.fill" : "eye.fill").foregroundStyle(Color.warningText)
                VStack(alignment: .leading, spacing: 1) {
                    Text(defense.title).font(.heading)
                    Text("ARCADE DEFENSIVE READ").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(Color.textSecondary)
                }
                Spacer()
                Button("Play-by-play", systemImage: "list.bullet") { showLog = true }.labelStyle(.iconOnly)
            }
            if let family {
                HStack {
                    Button("Back", systemImage: "chevron.left") { self.family = nil }.font(.label12)
                    Spacer()
                    Text(family.rawValue + " PLAYBOOK").font(.heading)
                }
                if family == .pass { passPanel }
                else {
                    let concepts = family == .run ? DrillConcept.runs : family == .trick ? DrillConcept.tricks : [.rpo]
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                        ForEach(concepts) { item in conceptButton(item) }
                    }
                    if family == .rpo { Text("Read the box: hand off against a light box or two-high; throw a quick pass against pressure or a loaded box.").font(.label12) }
                }
                optionButtons
                if s.running { tempoPicker }
                if preparing { ProgressView("Reading the matchup…").font(.label12) }
                else if let choice = choices[concept] {
                    HStack(spacing: 12) {
                        Text("\(choice.averageYards, specifier: "%.1f") YDS / CALL")
                        Text("\(Int(choice.stopped * 100))% STOP CLOCK")
                        Text("\(Int(choice.turnover * 100))% TURNOVER")
                    }.font(.system(size: 8, weight: .heavy, design: .monospaced)).foregroundStyle(Color.textSecondary)
                }
            } else {
                Text(defense.detail).font(.body14).foregroundStyle(Color.textSecondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(Family.allCases, id: \.self) { item in
                        Button { chooseFamily(item) } label: {
                            HStack {
                                Image(systemName: item == .run ? "figure.run" : item == .pass ? "arrow.up.right" : item == .rpo ? "arrow.triangle.branch" : "sparkles")
                                Text(item.rawValue)
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .black))
                            }.font(.heading).foregroundStyle(item == .rpo || item == .trick ? Color.onVolt : .white)
                                .padding(12).frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent)
                            .tint(item == .run ? .sportNFLFill : item == .pass ? .accentFill : item == .rpo ? .voltFill : .goldFill)
                    }
                }
                if s.canKick {
                    Button("FIELD GOAL · \(s.yardline + 17) YARDS", systemImage: "sportscourt") {
                        concept = .kick; family = .trick
                        if choices[.kick] != nil { callPlay() } else { prepareChoices() }
                    }.font(.heading).frame(maxWidth: .infinity).buttonStyle(.bordered)
                }
                if s.running { tempoPicker }
            }
            HStack {
                Button("TIMEOUT · \(s.timeouts)") { manageClock(spike: false) }.disabled(!s.running || s.timeouts == 0)
                Button("SPIKE · LOSE DOWN") { manageClock(spike: true) }.disabled(!s.running)
                Button("KNEEL") { kneel() }
            }.font(.label12).buttonStyle(.bordered)
            Text(s.running ? "\(tempo.seconds)s before the snap · 6s to run the play · Thinking time is free" : "Clock stopped · 6s per snap · Thinking time is free")
                .font(.system(size: 9, weight: .medium)).foregroundStyle(Color.textSecondary)
        }.padding(.bottom, 14)
    }

    private var passPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TAP A RECEIVER. TAP HIS TOKEN AGAIN TO CHANGE THE ROUTE.").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.textSecondary)
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(lineup?.offense.filter(\.eligible) ?? []) { player in
                        Button { targetID = player.id; concept = routes[player.id] ?? .slant; prepareChoices(); Haptics.tap() } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("#\(player.jersey) · \(player.position)").font(.system(size: 9, weight: .heavy))
                                Text(player.shortName).font(.bodyStrong).lineLimit(1)
                                Text(player.catchRate.map { "\(Int($0 * 100))% caught · 2024" } ?? "2024 active roster").font(.system(size: 9))
                            }.padding(9).foregroundStyle(targetID == player.id ? Color.onVolt : Color.ink)
                                .background(targetID == player.id ? Color.voltFill : Color.surface1, in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.borderStrong))
                        }.buttonStyle(PrimePressStyle()).accessibilityAddTraits(targetID == player.id ? .isSelected : [])
                    }
                }
            }.scrollIndicators(.hidden)
            ScrollView(.horizontal) {
                HStack(spacing: 6) { ForEach(DrillConcept.routes) { conceptButton($0) } }
            }.scrollIndicators(.hidden)
        }
    }
    private func conceptButton(_ item: DrillConcept) -> some View {
        Button {
            concept = item
            if DrillConcept.routes.contains(item), let targetID { routes[targetID] = item }
            if item == .keeper { targetID = lineup?.offense.first { $0.role == "QB" }?.id }
            else if DrillConcept.runs.contains(item) { targetID = lineup?.offense.first { $0.role == "RB" }?.id }
            Haptics.tap()
        } label: {
            Text(item.title).font(.label12).foregroundStyle(concept == item ? Color.onAccent : Color.ink)
                .padding(.horizontal, 10).padding(.vertical, 9).frame(maxWidth: .infinity)
                .background(concept == item ? Color.accentFill : Color.surface1, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(PrimePressStyle()).accessibilityAddTraits(concept == item ? .isSelected : [])
    }
    private var optionButtons: some View {
        HStack(spacing: 7) {
            if concept.call(against: defense) == .pass {
                option("PLAY ACTION", selected: options.playAction) { options.playAction.toggle(); prepareChoices() }
                option("ROLL OUT", selected: options.rollout) { options.rollout.toggle(); prepareChoices() }
            }
            option("SIDELINE", selected: options.sideline) { options.sideline.toggle(); prepareChoices() }
        }
    }
    private func option(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 9, weight: .bold)).padding(.vertical, 7).padding(.horizontal, 5)
                .foregroundStyle(selected ? Color.accentText : Color.textSecondary)
        }.buttonStyle(.bordered).accessibilityValue(selected ? "On" : "Off")
    }
    private var tempoPicker: some View {
        HStack(spacing: 6) {
            ForEach(DrillTempo.allCases) { value in
                Button { tempo = value; Haptics.tap() } label: {
                    VStack(spacing: 2) {
                        Text(value.title).font(.system(size: 8, weight: .heavy))
                        Text("\(value.seconds)s").font(.label12)
                    }.padding(6).frame(maxWidth: .infinity)
                        .foregroundStyle(tempo == value ? Color.onAccent : Color.textSecondary)
                        .background(tempo == value ? Color.accentFill : Color.surface1, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).accessibilityAddTraits(tempo == value ? .isSelected : [])
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("Tempo, time before the snap")
    }

    private var liveTitle: String {
        guard let p = presentation else { return "GET SET" }
        if p.concept == .kick { return phase == .snap ? "LONG SNAP" : phase == .develop ? "THE HOLD" : phase == .flight ? "KICK IS UP" : "THE VERDICT" }
        if phase == .snap { return "THE SNAP" }
        if p.play.sack == true { return phase == .develop ? "POCKET COLLAPSING" : "SACKED!" }
        if phase == .develop { return p.play.call == .pass ? "EYES DOWNFIELD" : "FOLLOW YOUR BLOCKS" }
        if phase == .flight { return p.play.call == .pass ? "BALL IN THE AIR" : "FIND DAYLIGHT" }
        if p.play.turnover { return "TAKEAWAY!" }
        if p.play.call == .pass && p.play.complete != true { return "INCOMPLETE" }
        return "CONTACT!"
    }
    private var liveLine: String {
        guard let p = presentation else { return "" }
        let who = p.target?.shortName ?? "the ball carrier"
        if p.concept == .kick {
            return phase == .snap ? "\(p.quarterback) secures the long snap." : phase == .develop ? "The holder sets the ball for \(who)." : phase == .flight ? "\(who) sends it toward the uprights." : p.play.made ? "Through the uprights!" : "The kick is no good."
        }
        if phase == .snap { return "\(p.quarterback) takes the snap." }
        if p.play.sack == true { return phase == .develop ? "The rush breaks through the pocket." : "\(p.quarterback) has no time to throw. He goes down behind the line." }
        if phase == .develop { return p.play.call == .pass ? "The receivers break into their routes." : "The line opens a crease for \(who)." }
        if phase == .flight { return p.play.call == .pass ? "\(p.quarterback) fires toward \(who)." : "\(who) attacks the gap." }
        if p.play.turnover { return "The defense takes it away!" }
        if p.play.call == .pass && p.play.complete != true { return "The throw falls incomplete. Nobody comes down with it." }
        return "\(who) has the ball. The defense closes in for the tackle."
    }
    private var liveCommentary: some View {
        VStack(spacing: 12) {
            Text(liveTitle).font(.display(30)).italic().frame(maxWidth: .infinity)
            Text(liveLine).font(.bodyStrong).multilineTextAlignment(.center)
            Text(presentation?.concept.title ?? "").font(.heading).foregroundStyle(Color.accentText)
            Button("SKIP ANIMATION", systemImage: "forward.end.fill") { finishAnimation() }.font(.label12).buttonStyle(.bordered)
        }.padding(.top, 14).accessibilityElement(children: .contain)
    }
    private func feedback(_ p: DrillPresentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(p.grade).font(.display(25)).italic().foregroundStyle(p.quality >= 0.9 ? Color.successText : p.quality >= 0.7 ? Color.accentText : Color.warningText)
                Spacer()
                Text("+\(Int(p.quality * 100)) CALL PTS").font(.heading).foregroundStyle(Color.accentText)
            }
            Text(p.narration).font(.bodyStrong)
            if p.quality < 0.9 { Text("Better read: \(p.bestTitle). Grade measures your call, not the bounce of the ball.").font(.label12).foregroundStyle(Color.textSecondary) }
            HStack {
                Button("Replay", systemImage: "arrow.counterclockwise") { animate(p) }
                Spacer()
                Button("Every option", systemImage: "chart.bar.xaxis") { showComparison = true }
                Spacer()
                Button("Source", systemImage: "list.bullet") { showLog = true }
            }.font(.label12).buttonStyle(.bordered)
            if let s = state, s.ended != nil {
                HStack(alignment: .firstTextBaseline) {
                    CountUpText(value: s.score, font: .hero(46))
                    Text("/ 1000").font(.heading)
                    Spacer()
                    Text("\(Int(s.meanGrade * 100))%\nCALL GRADE").font(.label12).multilineTextAlignment(.trailing)
                }
                Text("Original drive: \(s.scenario.actualResult) · \(s.scenario.game)").font(.label12)
                Text(saving ? "Recording drive…" : rewardText).font(.bodyStrong)
                if mode == .survivor && !survived(s) { Text("RUN OVER · \(survivorWins) DRIVES SURVIVED").font(.heading) }
                ShareLink(item: "Playbook · Two-Minute Drill\n\(daily ? day : mode.rawValue) · \(s.scenario.offense) vs \(s.scenario.defense)\n\(s.score)/1000 · \(Int(s.meanGrade * 100))% call grade · Unranked arcade simulation") {
                    Label("Share drive", systemImage: "square.and.arrow.up")
                }.font(.label12)
            }
        }.padding(.bottom, 18)
    }
    @ViewBuilder private var actionDock: some View {
        if state == nil && bank != nil {
            Button(action: start) {
                Label(daily && alreadyPlayed ? "REPLAY TODAY’S DRIVE" : "TAKE THE FIELD", systemImage: "football.fill")
                    .font(.heading).foregroundStyle(.white).padding(10).frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).tint(Color.accentFill)
                .padding(.horizontal, 20).padding(.vertical, 8).background(Color.surface0)
        } else if let s = state, !animating {
            if presentation == nil && family != nil {
                Button { callPlay() } label: {
                    HStack {
                        Image(systemName: "football.fill")
                        Text(preparing ? "READING THE MATCHUP…" : "SNAP · \(concept.title)")
                        Spacer(); Image(systemName: "arrow.right")
                    }.font(.heading).foregroundStyle(Color.onVolt).padding(10).frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(Color.voltFill)
                    .disabled(preparing || choices[concept]?.pool.isEmpty != false)
                    .padding(.horizontal, 14).padding(.vertical, 8).background(Color.surface0)
            } else if presentation != nil && phase == .result {
                Button {
                    if s.ended == nil { nextSnap() }
                    else if mode == .survivor && survived(s) { start() }
                    else { dismiss() }
                } label: {
                    HStack {
                        Text(s.ended == nil ? "NEXT SNAP" : mode == .survivor && survived(s) ? "NEXT DRIVE · \(survivorWins) WINS" : "BACK TO PLAYBOOK")
                        Spacer()
                        if s.ended == nil { Text(s.clock) }
                        Image(systemName: "arrow.right")
                    }.font(.heading).foregroundStyle(Color.onVolt).padding(10).frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(Color.voltFill).disabled(saving)
                    .padding(.horizontal, 14).padding(.vertical, 8).background(Color.surface0)
            }
        }
    }
    private func verdictColor(_ p: DrillPresentation) -> Color {
        if p.play.turnover || p.after.snaps == p.before.snaps { return .dangerFill }
        return p.after.points == 6 || p.quality >= 0.9 ? .successFill : p.quality >= 0.7 ? .accentFill : .warningFill
    }

    private var comparison: some View {
        NavigationStack {
            List {
                Section("CALL QUALITY · ARCADE MODEL") {
                    Text("\(defense.title): \(defense.detail) Grades compare expected yardage, first downs, clock stops and turnover risk. They aren’t NFL win probabilities.").font(.body14)
                    let best = choices.values.map(\.expected).max() ?? 0
                    ForEach(choices.values.sorted { $0.expected > $1.expected }, id: \.concept) { choice in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(choice.concept.title).font(.heading)
                                Text("\(choice.averageYards, specifier: "%.1f") avg yards · \(Int(choice.turnover * 100))% turnover").font(.label12)
                            }
                            Spacer()
                            Text("\(Int(choice.quality(best: best) * 100))%").font(.heading)
                        }
                    }
                }
            }.navigationTitle("Every option").toolbar { Button("Done") { showComparison = false } }
        }
    }
    private var playLog: some View {
        NavigationStack {
            List {
                Section("VIRTUAL DRIVE · ORIGINAL NFL SOURCES") {
                    Text("Names and positions in the animated drive belong to your roster. The source text below describes the original sampled NFL play.").font(.body14)
                    ForEach(Array((state?.log ?? []).enumerated()), id: \.offset) { _, text in Text(text).font(.body14) }
                }
            }.navigationTitle("Play-by-play").toolbar { Button("Done") { showLog = false } }
        }
    }
    private func playerDetails(_ player: DrillPlayer) -> some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let url = URL(string: player.headshot) {
                    AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Image(systemName: "person.fill") }
                        .frame(height: 140)
                }
                Text(player.name).font(.display1)
                Text("#\(player.jersey) · \(player.position) · 2024 WEEKLY ACTIVE ROSTER").font(.label12)
                if let rate = player.catchRate {
                    Text("\(Int(rate * 100))% CAUGHT").font(.hero(35))
                    Text("\(player.stats["targets", default: 0]) archived regular-season targets · \(player.stats["receivingYards", default: 0]) receiving yards").font(.body14)
                }
                Text("Roster-based schematic. This formation is not a claim about who was on the field on the historical snap.").font(.body14).foregroundStyle(Color.textSecondary)
            }.padding(24).navigationTitle("Player").toolbar { Button("Done") { inspected = nil } }
        }.presentationDetents([.medium, .large])
    }
    private var help: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("READ IT. CALL IT. WATCH IT.").font(.display1)
                    Text("Pick RUN, PASS, RPO or TRICK. Select a receiver, then tap his field token again or a route chip to change the route. Play action, rollouts and sideline intent change the arcade outcome weights. Snap the ball to watch the play. Replay and Skip never execute the play twice.")
                    Text("THE CLOCK").font(.heading)
                    Text("Each play costs 6 seconds. When the clock is running, your selected tempo adds 20, 32 or 38 seconds before the next snap. Timeout stops that runoff; a spike takes 3 seconds and a down. A kneel loses one yard and keeps the clock running. Thinking and animation time are free. Fourth-down spikes turn it over. Kicks unlock inside the opponent’s 45.")
                    Text("MAKE THE RIGHT CALL").font(.heading)
                    Text("Your call grade compares expected yards, first downs, clock stops and turnovers across the available concepts. Final score is 70% average call quality and 30% drive result, so a smart call still matters when a real sampled play goes wrong. Drive result: TD 1,000; field goal to lead 800, other made kicks 600; otherwise five per net yard, capped at 400.")
                    Text("SURVIVOR").font(.heading)
                    Text("Tie or take the lead to keep going. A failed possession ends the run. Each new drive uses another historical situation. Practice and Survivor are unranked and award no XP. Your first daily finish per device earns XP; midnight UTC resets the daily.")
                    Text("HISTORICAL START. ARCADE FOOTBALL.").font(.heading)
                    Text("Starting clock, ball, score and timeouts are real 2024 situations. Roster names, jerseys and receiving stats come from nflverse. The 22-player formation, routes, defensive reads, movement, tempo and defensive weighting are game rules, not NFL tracking data. Route types map to observed pass depth or run direction. RPO chooses a run or quick-pass pool. Trick plays use descriptions identifying reverses, laterals or flea-flickers.")
                    Text("Each concept draws from up to 80 nearby archived plays, with down, distance and field-position matching. Target catch rates use 2024 season statistics; defensive looks and optional adjustments reweight those observed outcomes. Displayed odds describe this arcade model, not calibrated player ratings or real win chances. All samples retain source ids and original descriptions. Penalties, opposing possessions and conversions are not simulated.")
                    Link("nflverse data · CC BY 4.0 · adapted for arcade play", destination: URL(string: "https://github.com/nflverse/nflverse-data")!)
                    Text("Sound respects silent mode. Reduce Motion skips the animated sequence and keeps the full play explanation.").foregroundStyle(Color.textSecondary)
                }.font(.body14).padding(20)
            }.navigationTitle("How to play").toolbar { Button("Done") { showHelp = false } }
        }
    }

    private func dailyScenario(_ bank: DrillBank) -> DrillScenario { bank.scenarios[Int(DrillBank.seed("scenario-\(day)") % UInt64(bank.scenarios.count))] }
    private func load() async {
        guard bank == nil else { return }
        day = DrillBank.dayKey(Date())
        do {
            bank = try await Task.detached { try DrillBank.load() }.value
            if let screen = DebugLaunch.drillScreen, screen != "setup" {
                mode = .practice; start()
                if ["pass", "flight", "feedback", "result", "replay"].contains(screen) { chooseFamily(.pass) }
                else if screen == "run" { chooseFamily(.run) }
                else if screen == "trick" { chooseFamily(.trick) }
            }
        }
        catch { self.error = "The offline playbook couldn’t be loaded. Close and try again." }
    }
    private func start() {
        guard let bank else { return }
        day = DrillBank.dayKey(Date())
        let available = bank.scenarios.filter { !survivorPlayed.contains($0.id) }
        let scenario = daily || DebugLaunch.drillScreen != nil ? dailyScenario(bank) : (available.isEmpty ? bank.scenarios : available).randomElement()!
        if mode == .survivor { survivorPlayed.insert(scenario.id) }
        seed = daily || DebugLaunch.drillScreen != nil ? DrillBank.seed("plays-\(day)") : UInt64.random(in: 1...UInt64.max)
        state = DrillState(scenario); snapIndex = 0; startedAt = Date(); saved = false; saving = false
        rewardText = ""; presentation = nil; committed = nil; phase = .set; motion = 0; family = nil
        targetID = bank.lineups?[scenario.id]?.offense.first { $0.role == "WR1" }?.id
        let receivers: [DrillPlayer] = bank.lineups?[scenario.id]?.offense.filter(\.eligible) ?? []
        let assignments: [(String, DrillConcept)] = receivers.map { ($0.id, DrillConcept.defaultForRole($0.role)) }
        routes = Dictionary(uniqueKeysWithValues: assignments)
        concept = .slant; options = .init(); tempo = .hurry
        prepareChoices(); Haptics.commit()
    }
    private func survived(_ state: DrillState) -> Bool { state.points > 0 && state.scenario.offenseScore + state.points >= state.scenario.defenseScore }
    private func chooseFamily(_ value: Family) {
        family = value; options = .init()
        concept = value == .run ? .inside : value == .pass ? .slant : value == .rpo ? .rpo : .reverse
        let role = concept == .reverse ? "WR2" : concept.call(against: defense) == .run ? "RB" : "WR1"
        targetID = lineup?.offense.first { $0.role == role }?.id
        if value == .pass, let targetID { concept = routes[targetID] ?? .slant }
        prepareChoices(); Haptics.tap()
    }
    private func selectPlayer(_ player: DrillPlayer) {
        guard !animating, phase != .result else { return }
        if player.eligible && lineup?.offense.contains(where: { $0.id == player.id }) == true {
            family = .pass
            if targetID == player.id {
                let index = DrillConcept.routes.firstIndex(of: concept) ?? 0
                concept = DrillConcept.routes[(index + 1) % DrillConcept.routes.count]
                routes[player.id] = concept
            } else { targetID = player.id; concept = routes[player.id] ?? .slant }
            prepareChoices(); Haptics.tap()
        } else { inspected = player }
    }
    private func prepareChoices() {
        guard let bank, let state, state.ended == nil else { return }
        let id = UUID(); preparationID = id; preparing = true
        let defense = self.defense, target = self.target, options = self.options
        Task {
            let result = await Task.detached {
                Dictionary(uniqueKeysWithValues: DrillConcept.allCases.filter { $0 != .kick || state.canKick }.map {
                    ($0, bank.choice($0, state: state, defense: defense, target: target, options: options))
                }.filter { !$0.1.pool.isEmpty })
            }.value
            guard preparationID == id else { return }
            choices = result; preparing = false
            debugSnapshot()

        }
    }
    private func callPlay() {
        guard !preparing, !animating, presentation == nil, let before = state,
              let choice = choices[concept], let play = choice.draw(seed: DrillBank.seed("\(seed)-\(snapIndex)-\(concept.rawValue)-\(targetID ?? "")-\(options.playAction)-\(options.rollout)-\(options.sideline)")) else { return }
        let best = choices.values.max { $0.expected < $1.expected }
        var quality = choice.quality(best: best?.expected ?? choice.expected)
        if before.running && before.seconds <= tempo.seconds { quality = 0 }
        var after = before; after.snap(play, tempo: tempo, grade: quality)
        let actor: DrillPlayer? = concept == .kick ? lineup?.specialists?.first { $0.role == "K" } : play.call == .run ? lineup?.offense.first { $0.role == (concept == .keeper ? "QB" : concept == .reverse ? "WR2" : "RB") } : target
        let p = DrillPresentation(before: before, after: after, play: play, concept: concept, target: actor,
            defense: defense, quality: quality, bestTitle: best?.concept.title ?? concept.title,
            quarterback: (concept == .kick ? lineup?.specialists?.first { $0.role == "H" }?.shortName : lineup?.offense.first { $0.role == "QB" }?.shortName) ?? "The quarterback")
        presentation = p; animate(p)
    }
    private func animate(_ p: DrillPresentation) {
        animationTask?.cancel(); presentation = p; phase = .set; motion = 0
        if reduceMotion || p.after.snaps == p.before.snaps { finishAnimation(); return }
        DrillSound.shared.play("snap", enabled: sound); Haptics.commit()
        animationTask = Task { @MainActor in
            for step in [DrillAnimationPhase.snap, .develop, .flight, .contact] {
                guard !Task.isCancelled else { return }
                phase = step
                withAnimation(.easeInOut(duration: Motion.durSlow)) { motion = Double(step.rawValue) }
                if step == .contact { Haptics.impact(.heavy) }
                do { try await Task.sleep(for: .seconds(Motion.durSlow + Motion.durFast)) }
                catch { return }
                if DebugLaunch.drillScreen == "flight" && step == .flight { return }
            }
            finishAnimation()
        }
    }
    private func finishAnimation() {
        animationTask?.cancel()
        guard let p = presentation else { return }
        withAnimation(reduceMotion ? nil : Motion.overshoot) { phase = .result; motion = p.after.snaps == p.before.snaps ? 0 : 5 }
        // Replay, Skip, backgrounding and repeated taps converge here. One state mutation,
        // one survivor increment and one reward write per presentation, ever.
        guard committed != p.id else { return }
        committed = p.id; state = p.after; snapIndex += 1
        if p.after.snaps == p.before.snaps { DrillSound.shared.play("bad", enabled: sound); Haptics.reject() }
        else if p.after.points == 6 { celebrations += 1; DrillSound.shared.play("touchdown", enabled: sound); Haptics.success() }
        else if p.play.turnover { DrillSound.shared.play("bad", enabled: sound); Haptics.reject() }
        else if p.quality >= 0.9 || p.play.yards >= p.before.toGo { celebrations += 1; DrillSound.shared.play("good", enabled: sound); Haptics.success() }
        if p.after.ended != nil {
            if mode == .survivor && survived(p.after) { survivorWins += 1 }
            Task { await save() }
        }
    }
    private func nextSnap() {
        animationTask?.cancel(); presentation = nil; phase = .set; motion = 0; family = nil
        options = .init(); concept = .slant
        targetID = lineup?.offense.first { $0.role == "WR1" }?.id
        if let targetID { concept = routes[targetID] ?? .slant }
        prepareChoices()
    }
    /// Drives the shipping seams for repeatable layout/animation QA. Flags are nil in Release.
    private func debugSnapshot() {
        guard presentation == nil, state?.snaps == 0, let screen = DebugLaunch.drillScreen else { return }
        if (screen == "flight" || screen == "replay"), let before = state, let choice = choices[concept],
           let play = choice.pool.first(where: { $0.complete == true && $0.yards > 0 }) {
            let best = choices.values.map(\.expected).max() ?? choice.expected
            let quality = choice.quality(best: best)
            var after = before; after.snap(play, tempo: tempo, grade: quality)
            let p = DrillPresentation(before: before, after: after, play: play, concept: concept,
                target: target, defense: defense, quality: quality,
                bestTitle: choices.values.max { $0.expected < $1.expected }?.concept.title ?? concept.title,
                quarterback: lineup?.offense.first { $0.role == "QB" }?.shortName ?? "QB")
            presentation = p; animate(p)
        } else if screen == "feedback" {
            callPlay()
            if screen == "feedback" {
                finishAnimation()
                let snaps = state?.snaps
                finishAnimation() // The skip/replay commit latch must not execute a second snap.
                assert(state?.snaps == snaps)
            }
        } else if screen == "result", let before = state, let bank,
                  let touchdown = bank.plays.filter({ !$0.turnover && $0.yards >= before.yardline }).first {
            var after = before; after.snap(touchdown, grade: 0.95)
            let qb = lineup?.offense.first { $0.role == "QB" }
            let actor = lineup?.offense.first { $0.role == (touchdown.call == .run ? "RB" : "WR1") }
            let p = DrillPresentation(before: before, after: after, play: touchdown,
                concept: touchdown.call == .run ? .outsideLeft : .go, target: actor,
                defense: defense, quality: 0.95, bestTitle: "GO", quarterback: qb?.shortName ?? "QB")
            presentation = p; finishAnimation()
        }
    }
    private func kneel() {
        guard let before = state, !animating, presentation == nil, before.ended == nil else { return }
        var after = before; after.kneel(tempo: tempo)
        let play = DrillPlay(id: "clock-kneel", game: "ARCADE CLOCK RULE", call: .run,
            down: before.down, toGo: before.toGo, yardline: before.yardline, yards: -1,
            turnover: false, stopped: false, made: false, description: "Modeled kneel: one yard lost; clock runs.")
        let qb = lineup?.offense.first { $0.role == "QB" }
        let p = DrillPresentation(before: before, after: after, play: play, concept: .keeper,
            target: qb, defense: defense, quality: 0, bestTitle: "Keep attacking", quarterback: qb?.shortName ?? "The quarterback")
        presentation = p; animate(p)
    }
    private func manageClock(spike: Bool) {
        guard var current = state, !animating, current.ended == nil else { return }
        if spike { current.spike() } else { current.timeout() }
        withAnimation(reduceMotion ? nil : Motion.snap) { state = current }
        Haptics.commit(); prepareChoices()
        if current.ended != nil {
            current.callGrades.append(0); state = current
            // A fourth-down spike or final-second spike must still show a result and save.
            let play = DrillPlay(id: "clock", game: current.scenario.game, call: .run, down: current.down,
                toGo: current.toGo, yardline: current.yardline, yards: 0, turnover: false, stopped: true, made: false, description: "Clock-management action")
            let p = DrillPresentation(before: current, after: current, play: play, concept: .inside, target: nil,
                defense: defense, quality: 0, bestTitle: "Preserve the possession", quarterback: "The quarterback")
            presentation = p; committed = p.id; phase = .result; motion = 0
            Task { await save() }
        }
    }
    private func save() async {
        guard !saved, let state, state.ended != nil else { return }
        saved = true; saving = true
        var details = GameResultDetails(); details.outcome = state.ended; details.totalPoints = state.points
        let detail = RepositoryContainer.SessionDetail(mode: daily && !alreadyPlayed ? .daily : .practice,
            score: state.score, maxScore: 1000, startedAt: startedAt, details: details)
        if daily && !alreadyPlayed {
            UserDefaults.standard.set(true, forKey: "drill.finished.\(day)")
            let reward = await container.complete(format: .twoMinuteDrill, sport: .nfl, performance: Double(state.score) / 1000,
                perfect: false, puzzleID: "drill-v2-\(day)-\(state.scenario.id)", ranked: false, detail: detail)
            rewardText = "+\(reward.xpEarned) XP · DAILY DRIVE BANKED"
        } else {
            await container.logSession(format: .twoMinuteDrill, sport: .nfl, performance: Double(state.score) / 1000,
                perfect: false, puzzleID: "drill-v2-\(state.scenario.id)", detail: detail)
            rewardText = "DRIVE RECORDED · RATING UNCHANGED"
        }
        saving = false
    }
}
