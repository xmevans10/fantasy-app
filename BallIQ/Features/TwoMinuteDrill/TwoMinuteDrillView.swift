import SwiftUI

struct TwoMinuteDrillView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var bank: DrillBank?
    @State private var state: DrillState?
    @State private var error: String?
    @State private var daily = true
    @State private var seed: UInt64 = 0
    @State private var snapIndex = 0
    @State private var day = ""
    @State private var startedAt = Date()
    @State private var saved = false
    @State private var saving = false
    @State private var rewardText = ""
    @State private var showHelp = false
    @State private var showField = true
    @State private var showExit = false
    @State private var pools: [DrillCall: [DrillPlay]] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let state {
                        DisclosureGroup("FIELD POSITION", isExpanded: $showField) {
                            field(state).padding(.top, 8)
                        }.font(.label12)
                        if let ending = state.ended { recap(state, ending: ending) }
                        else { controls(state) }
                        if !state.log.isEmpty {
                            DisclosureGroup("PLAY-BY-PLAY · \(state.log.count)") {
                                ForEach(Array(state.log.enumerated()), id: \.offset) { _, text in
                                    Text(text).font(.body14).frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 8)
                                    Divider()
                                }
                            }.font(.heading)
                        }
                    } else if let bank {
                        setup(bank)
                    } else if let error {
                        ContentUnavailableView("Drive unavailable", systemImage: "wifi.exclamationmark", description: Text(error))
                        Button("Try again") { load() }.buttonStyle(.borderedProminent)
                    } else { ProgressView("Loading playbook…").frame(maxWidth: .infinity) }
                }.padding(20)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let state {
                    scoreboard(state).padding(.horizontal, 20).padding(.vertical, 12)
                        .background(Color.surface0)
                }
            }
            .background(Color.surface0)
            .foregroundStyle(Color.ink)
            .navigationTitle("Two-Minute Drill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") {
                        if state != nil && state?.ended == nil { showExit = true } else { dismiss() }
                    }.labelStyle(.iconOnly).disabled(saving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("How to play", systemImage: "info.circle") { showHelp = true }.labelStyle(.iconOnly)
                }
            }
            .confirmationDialog("Leave this drive? Progress on this drive will be lost.", isPresented: $showExit, titleVisibility: .visible) {
                Button("Leave drive", role: .destructive) { dismiss() }
            }
            .sheet(isPresented: $showHelp) { help }
            .task { load() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active && state == nil { day = DrillBank.dayKey(Date()) }
            }
            .onChange(of: state?.ended) { _, ended in
                if ended != nil { Task { await save() } }
            }
        }
    }

    private func setup(_ bank: DrillBank) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("YOU CALL.\nTHE CLOCK RUNS.").font(.display(46)).lineSpacing(-4)
            Text("One possession. Real NFL situations. Find the points before time runs out.").font(.bodyStrong)
            Picker("Mode", selection: $daily) {
                Text("Daily drive").tag(true)
                Text("Practice").tag(false)
            }.pickerStyle(.segmented)
            let preview = dailyScenario(bank)
            if daily {
                VStack(alignment: .leading, spacing: 8) {
                    Text("TODAY’S DRIVE · NFL").font(.label12)
                    Text("\(preview.offense) vs \(preview.defense)").font(.display1)
                    Text("\(preview.date) · Q4 · \(preview.seconds / 60):\(String(format: "%02d", preview.seconds % 60)) remaining").font(.bodyStrong)
                    Text("\(preview.offenseScore)–\(preview.defenseScore) · \(preview.timeouts) timeouts").font(.body14)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.sportNFLFill).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: Radius.card))
            }
            Button(action: start) {
                Label(daily && alreadyPlayed ? "REPLAY TODAY’S DRIVE" : "TAKE THE FIELD", systemImage: "arrow.right")
                    .font(.heading).foregroundStyle(.white).frame(maxWidth: .infinity).padding(12)
            }.buttonStyle(.borderedProminent).tint(Color.accentFill)
            Text(daily ? (alreadyPlayed ? "Today’s XP is banked. Replays are practice." : "First finish earns XP. Unranked. Daily resets at midnight UTC.") : "A random historical situation each run. Practice records your score without XP or rating changes.")
                .font(.body14).foregroundStyle(Color.textSecondary)
            Text("\(bank.scenarios.count) starting situations · \(String(bank.season)) season").font(.label12)
            Button("Rules & data sources") { showHelp = true }.font(.bodyStrong)
        }
    }

    private func scoreboard(_ s: DrillState) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text("\(s.scenario.offense) · YOU").font(.label12)
                    Text("\(s.scenario.offenseScore + s.points)").font(.hero(42))
                }
                Spacer()
                VStack {
                    Text("Q4").font(.label12)
                    Text(s.clock).font(.hero(42)).monospacedDigit()
                        .foregroundStyle(s.seconds <= 30 ? Color.dangerText : Color.ink)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text(s.scenario.defense).font(.label12)
                    Text("\(s.scenario.defenseScore + (s.ended == "Safety" ? 2 : 0))").font(.hero(42))
                }
            }
            Divider()
            HStack {
                Text(s.situation).font(.bodyStrong)
                Spacer()
                Text("\(s.timeouts) TO").font(.statValue)
            }
            Text(s.ended != nil ? "DRIVE COMPLETE" : s.running ? "CLOCK RUNNING · hurry-up costs 20s before next snap" : "CLOCK STOPPED")
                .font(.label12).foregroundStyle(Color.textSecondary)
        }.padding(16).cardSurface()
    }

    private func field(_ s: DrillState) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: Radius.card).fill(Color.sportNFLFill)
                VStack(spacing: 0) {
                    Text(s.scenario.defense + " END ZONE").font(.label12).frame(height: 26)
                    ForEach(1..<10) { yard in
                        HStack {
                            Text("\(yard <= 5 ? yard * 10 : (10 - yard) * 10)")
                            Rectangle().fill(.white.opacity(0.4)).frame(height: 1)
                            Text("\(yard <= 5 ? yard * 10 : (10 - yard) * 10)")
                        }.font(.system(size: 9, weight: .medium, design: .monospaced)).frame(maxHeight: .infinity)
                    }
                    Text(s.scenario.offense + " END ZONE").font(.label12).frame(height: 26)
                }.padding(.horizontal, 12)
                let playable = geo.size.height - 52
                let ballY = 26 + playable * CGFloat(100 - s.yardline) / 100
                let firstY = 26 + playable * CGFloat(100 - max(0, s.yardline - s.toGo)) / 100
                Rectangle().fill(Color.goldFill).frame(height: 3).offset(y: -firstY)
                HStack(spacing: 6) {
                    Image(systemName: "football.fill")
                    Text(s.fieldPosition.uppercased()).font(.label12)
                }.padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.black.opacity(0.85)).clipShape(Capsule()).offset(y: -ballY + 14)
            }.foregroundStyle(.white)
        }.frame(height: 160)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Football field. Ball at \(s.fieldPosition). \(s.toGo) yards to first down.")
    }

    private func controls(_ s: DrillState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("YOUR CALL").font(.display1)
            Text(s.scenario.defenseScore - s.scenario.offenseScore >= 4 ? "You need a touchdown to take the lead." : "A field goal can tie it or take the lead. A touchdown takes the lead.")
                .font(.body14).foregroundStyle(Color.textSecondary)
            HStack(spacing: 12) {
                callButton(.run)
                callButton(.pass)
            }
            if s.canKick { callButton(.fieldGoal) }
            HStack {
                Button("TIMEOUT (\(s.timeouts))") { mutate { $0.timeout() } }
                    .disabled(!s.running || s.timeouts == 0)
                Spacer()
                Button("SPIKE · LOSE DOWN") { mutate { $0.spike() } }.disabled(!s.running)
            }.font(.label12).buttonStyle(.bordered)
            Text("Each snap uses 6s. Use a timeout or spike to avoid the 20s hurry-up runoff. Your thinking time doesn’t run the clock.")
                .font(.label12).foregroundStyle(Color.textSecondary)
            if let last = s.log.first {
                Text(last.components(separatedBy: "\n").first ?? last).font(.bodyStrong)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.accentBg)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control))
            }
        }
    }

    private func callButton(_ call: DrillCall) -> some View {
        let pool = pools[call] ?? []
        return Button { snap(call) } label: {
            VStack(spacing: 6) {
                Label(call.title, systemImage: call.symbol).font(.heading)
                if !pool.isEmpty {
                    if call == .fieldGoal {
                        Text("\((state?.yardline ?? 0) + 17)-yard try · \(pool.filter(\.made).count * 100 / pool.count)% sample success").font(.label12)
                    } else {
                        let average = Double(pool.reduce(0) { $0 + $1.yards }) / Double(pool.count)
                        Text("\(average, specifier: "%.1f") avg yds · \(pool.filter(\.stopped).count * 100 / pool.count)% stop clock").font(.label12)
                    }
                }
            }.foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 60).padding(8)
        }.buttonStyle(.borderedProminent).tint(call == .run ? Color.sportNFLFill : Color.accentFill)
            .disabled(pool.isEmpty)
    }

    private func recap(_ s: DrillState, ending: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ending.uppercased()).font(.display(38))
            Text("\(s.score) PTS").font(.hero(52)).foregroundStyle(Color.accentText)
            Text(s.points > 0 ? "You added \(s.points) points on this possession. Opponent possessions and conversions aren’t simulated." : "The drive is over. Use the recap to plan your next one.").font(.body14)
            Text("ORIGINAL DRIVE · \(s.scenario.actualResult)").font(.heading)
            Text("\(s.scenario.game) · \(s.scenario.date)").font(.label12)
            Text("Your drive sampled other NFL plays. This is a historical comparison, not a replay or a prediction of who wins.")
                .font(.body14).foregroundStyle(Color.textSecondary)
            if saving { ProgressView("Recording drive…") }
            else { Text(rewardText).font(.bodyStrong) }
            ShareLink(item: "Playbook · Two-Minute Drill\n\(daily ? day : "Practice") · \(s.scenario.offense) vs \(s.scenario.defense)\n\(ending) · \(s.score) pts · Unranked historical simulation") {
                Label("Share drive", systemImage: "square.and.arrow.up")
            }.buttonStyle(.bordered)
            Button("BACK TO PLAYBOOK") { dismiss() }.buttonStyle(.borderedProminent).disabled(saving)
        }
    }

    private var help: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("MAKE THE MOST OF ONE DRIVE").font(.display1)
                    Text("Call run or pass, watch the down and distance, and manage your timeouts. Field goals unlock inside the opponent’s 45. A spike costs a down and 3 seconds. A fourth-down spike turns it over.")
                    Text("The clock advances when you act: 6 seconds per snap, plus 20 seconds before the next snap if the previous play stayed in bounds. Incompletions and out-of-bounds plays stop it. A timeout removes the runoff. No real-time countdown.")
                    Text("SCORING").font(.heading)
                    Text("Touchdown: 1,000. Field goal to lead: 800; other made field goals: 600. Otherwise: 5 per net yard gained, capped at 400. Results never move your rating. First daily completion earns XP; practice and replays don’t.")
                    Text("REAL DATA. MODELED DRIVE.").font(.heading)
                    Text("Starting score, ball, clock and timeouts come from 53 real 2024 regular-season drives, tied or trailing by up to five points. Each call draws from the 40 closest league-wide plays of that type, matching down, distance and field position. The averages shown describe that sample, not a win probability.")
                    Text("Gains, turnovers, clock-stopping outcomes and kick results are observed. Clock costs, field-position changes and scoring are game rules. Penalties, opposing possessions, extra points, defensive reads and player ratings aren’t simulated. Source descriptions refer to the original play, not your virtual field position.")
                    Link("NFLverse data & attribution", destination: URL(string: "https://github.com/nflverse/nflverse-data")!)
                    Link("Data license: CC BY 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                }.font(.body14).padding(20)
            }.navigationTitle("How to play").toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showHelp = false } }
            }
        }
    }

    private var alreadyPlayed: Bool { UserDefaults.standard.bool(forKey: "drill.finished.\(day)") }
    private func dailyScenario(_ bank: DrillBank) -> DrillScenario {
        bank.scenarios[Int(DrillBank.seed("scenario-\(day)" ) % UInt64(bank.scenarios.count))]
    }
    private func load() {
        guard bank == nil else { return }
        day = DrillBank.dayKey(Date())
        do { bank = try DrillBank.load(); error = nil }
        catch { self.error = "The offline playbook couldn’t be loaded. Close and try again." }
    }
    private func start() {
        guard let bank else { return }
        day = DrillBank.dayKey(Date())
        let scenario = daily ? dailyScenario(bank) : bank.scenarios.randomElement()!
        seed = daily ? DrillBank.seed("plays-\(day)") : UInt64.random(in: 1...UInt64.max)
        state = DrillState(scenario)
        snapIndex = 0
        startedAt = Date()
        refreshPools()
        Haptics.tap()
    }
    private func refreshPools() {
        guard let bank, let state, state.ended == nil else { return }
        pools = Dictionary(uniqueKeysWithValues: DrillCall.allCases.map { ($0, bank.candidates($0, state: state)) })
    }
    private func mutate(_ change: (inout DrillState) -> Void) {
        guard var current = state, current.ended == nil else { return }
        change(&current)
        state = current
        refreshPools()
        Haptics.tap()
    }
    private func snap(_ call: DrillCall) {
        guard let pool = pools[call], !pool.isEmpty else { return }
        // Independent deterministic draw for each snap and call. Reopening today's drive
        // cannot re-roll a bad result; choosing a different call changes the outcome pool.
        let draw = DrillBank.seed("\(seed)-\(snapIndex)-\(call.rawValue)")
        mutate { $0.snap(pool[Int(draw % UInt64(pool.count))]) }
        snapIndex += 1
    }
    @MainActor private func save() async {
        guard !saved, let state, state.ended != nil else { return }
        saved = true
        saving = true
        var details = GameResultDetails()
        details.outcome = state.ended
        details.totalPoints = state.points
        let detail = RepositoryContainer.SessionDetail(mode: daily && !alreadyPlayed ? .daily : .practice,
            score: state.score, maxScore: 1000, startedAt: startedAt, details: details)
        if daily && !alreadyPlayed {
            // Reserve before awaiting, so repeated UI events cannot award twice.
            UserDefaults.standard.set(true, forKey: "drill.finished.\(day)")
            let rewards = await container.complete(format: .twoMinuteDrill, sport: .nfl,
                performance: Double(state.score) / 1000, perfect: false,
                puzzleID: "drill-\(day)-\(state.scenario.id)", ranked: false, detail: detail)
            rewardText = "+\(rewards.xpEarned) XP · Daily drive banked"
        } else {
            await container.logSession(format: .twoMinuteDrill, sport: .nfl,
                performance: Double(state.score) / 1000, perfect: false,
                puzzleID: "drill-\(state.scenario.id)", detail: detail)
            rewardText = "Practice recorded · Rating unchanged"
        }
        saving = false
    }
}
