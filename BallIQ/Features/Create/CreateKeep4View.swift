import SwiftUI

/// Build a K4C4 from real player-seasons. Three decoupled axes — *how it's scored* (a
/// composable rule), *who's in the pool* (free discovery facets), and *the 8 picks* — with a
/// live answer preview. Discovery facets never touch the selection: the creator curates the
/// pool to fit their theme; the UI doesn't filter for them.
struct CreateKeep4View: View {
    @EnvironmentObject private var container: RepositoryContainer
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var query = CatalogQuery(sport: .nfl)
    @State private var scoringSport: Sport = .nfl
    @State private var terms: [ScoringRule.Term] = CreateKeep4View.integerized(ScoringRule.preset("nfl_skill_ppr")!.terms)
    /// The active preset's 0–100 display bounds — `terms` alone doesn't carry this, so it must
    /// be tracked alongside whenever a preset is selected (see `applyPreset`).
    @State private var displayScale: ScoringRule.FixedScale? = ScoringRule.preset("nfl_skill_ppr")!.displayScale
    @State private var eraAdjusted = false
    @State private var selected: [CatalogSeason] = []
    @State private var results: [CatalogSeason] = []
    @State private var searching = false
    @State private var publishing = false
    @State private var published: PublishedPuzzle?
    @State private var error: String?

    private let target = 8
    private var rule: ScoringRule { ScoringRule(terms: terms, displayScale: displayScale).eraAdjusted(eraAdjusted) }
    /// A fantasy-points rule (coefficients in `perUnit`, no editable weights/era-adjust).
    private var isPointsRule: Bool { ScoringRule(terms: terms).isPoints }
    private var bounds: ClosedRange<Int> { container.catalog.yearBounds }
    private var canPublish: Bool {
        selected.count == target && !terms.isEmpty &&
            !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func grade(_ s: CatalogSeason) -> Double { rule.grade(s, baselines: container.baselines) }

    /// Each term's share of the total weight, e.g. "57%". The composite normalizes by the sum.
    private func pct(_ i: Int) -> String {
        let sum = terms.reduce(0) { $0 + $1.weight }
        guard sum > 0 else { return "0%" }
        return "\(Int((terms[i].weight / sum * 100).rounded()))%"
    }

    /// Presets store fractional weights (0.60/0.25/0.15); convert to clean 1–5 "importance"
    /// integers (preserving rank order) so the stepper reads sensibly. The percentage readout
    /// then shows each term's real share.
    private static func integerized(_ terms: [ScoringRule.Term]) -> [ScoringRule.Term] {
        // Points rules carry their coefficients in `perUnit`, not the 1–5 weight — leave them be.
        if terms.contains(where: { if case .points = $0.norm { return true } else { return false } }) {
            return terms
        }
        guard let minW = terms.map(\.weight).filter({ $0 > 0 }).min(), minW > 0 else { return terms }
        return terms.map { t in
            let w = min(5, max(1, (t.weight / minW).rounded()))
            return .init(stat: t.stat, weight: w, higherWins: t.higherWins, norm: t.norm)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                titleField
                scoringSection
                preview
                discoverySection
                resultsSection
            }
            .padding(16)
        }
        .background(Color.appBackground)
        .navigationTitle("New K4C4")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(publishing ? "…" : "Publish") { Task { await publish() } }
                    .disabled(!canPublish || publishing)
                    .fontWeight(.semibold)
            }
        }
        .task { await runSearch() }
        .onChange(of: query) { Task { await runSearch() } }
        .alert("Couldn't publish", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .sheet(item: $published) { p in PublishedSheet(shareID: p.id) { dismiss() } }
    }

    // MARK: - Title

    private var titleField: some View {
        field("Title") {
            TextField("e.g. One-hit wonders: 2010s WRs", text: $title)
                .textInputAutocapitalization(.words)
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(Color.surfaceMuted)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
    }

    // MARK: - Scoring (the answer axis)

    private var scoringSection: some View {
        sectionCard("How it's scored", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 12) {
                sportToggle(selection: scoringSport) { setScoringSport($0) }
                presetChips
                if isPointsRule {
                    fantasyFormula
                } else {
                    ForEach(Array(terms.enumerated()), id: \.offset) { i, _ in termRow(i) }
                    Button { addTerm() } label: {
                        Label("Add stat", systemImage: "plus").font(.bodyStrong)
                            .foregroundStyle(Color.accentText)
                    }
                    .disabled(terms.count >= 4)
                }
            }
        }
    }

    private var presetChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(presets(for: scoringSport), id: \.1) { name, key in
                    chip(name, selected: false) {
                        let preset = ScoringRule.preset(key)!
                        terms = Self.integerized(preset.terms)
                        displayScale = preset.displayScale
                        Haptics.tap()
                    }
                }
            }
        }
    }

    private func termRow(_ i: Int) -> some View {
        let term = terms[i]
        let stat = ScoringStat.find(term.stat, sport: scoringSport)
        return HStack(spacing: 8) {
            Menu {
                ForEach(ScoringStat.catalog(for: scoringSport)) { s in
                    Button(s.label) { setStat(i, s) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(stat?.label ?? term.stat).font(.bodyStrong).foregroundStyle(Color.textPrimary)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(Color.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { toggleDirection(i) } label: {
                Image(systemName: term.higherWins ? "arrow.up" : "arrow.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.accentText)
                    .frame(width: 30, height: 30).background(Color.accentBg).clipShape(Circle())
            }
            Stepper("weight", value: weightBinding(i), in: 1...5)
                .labelsHidden()
            Text(pct(i)).font(.label12).foregroundStyle(Color.textMuted).frame(width: 36)
            Button { removeTerm(i) } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(Color.dangerText)
            }
            .disabled(terms.count <= 1)
        }
        .padding(10).background(Color.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    /// Read-only summary of a fantasy-points preset: each stat and its point coefficient. The
    /// formula is fixed (not term-editable) — pick a different preset chip to switch scoring.
    private var fantasyFormula: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(terms.enumerated()), id: \.offset) { _, term in
                if case .points(let perUnit) = term.norm {
                    let stat = ScoringStat.find(term.stat, sport: scoringSport)
                    HStack {
                        Text(stat?.label ?? term.stat).font(.bodyStrong).foregroundStyle(Color.textPrimary)
                        Spacer()
                        Text(Self.coeffLabel(perUnit)).font(.label12).foregroundStyle(Color.textMuted)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8).background(Color.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                }
            }
            Text("Ranked by true fantasy points; the grade shown is normalized to 0–100.")
                .font(.label11).foregroundStyle(Color.textMuted)
        }
    }

    /// Format a points coefficient as "×1", "×0.1", "×−2".
    private static func coeffLabel(_ v: Double) -> String {
        let s = v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
        return "×\(s)".replacingOccurrences(of: "-", with: "−")
    }

    // MARK: - Live answer preview

    @ViewBuilder private var preview: some View {
        if !selected.isEmpty {
            let graded = selected.sorted { grade($0) > grade($1) }
            sectionCard("Answer preview · \(selected.count)/\(target)", systemImage: "eye") {
                VStack(spacing: 6) {
                    ForEach(Array(graded.enumerated()), id: \.element.id) { i, s in
                        previewRow(rank: i, season: s, keep: i < 4)
                    }
                    if selected.count != target {
                        Text("Add \(target - selected.count) more to publish.")
                            .font(.label11).foregroundStyle(Color.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
                    }
                }
            }
        }
    }

    private func previewRow(rank: Int, season: CatalogSeason, keep: Bool) -> some View {
        let team = TeamColors.palette(sport: season.sport, abbr: season.teamAbbr)
        return HStack(spacing: 8) {
            Text(keep ? "KEEP" : "CUT")
                .font(.custom(FontName.condBlack, size: 11))
                .foregroundStyle(keep ? Color.successText : Color.dangerText)
                .frame(width: 40, alignment: .leading)
            RoundedRectangle(cornerRadius: 3).fill(team.primary).frame(width: 9, height: 16)
            Text(season.name).font(.bodyStrong).foregroundStyle(Color.textPrimary).lineLimit(1)
            Text(season.subtitle).font(.label11).foregroundStyle(Color.textMuted).lineLimit(1)
            Spacer(minLength: 2)
            Text("\(Int(grade(season).rounded()))").font(.hero(15)).foregroundStyle(Color.textPrimary)
            Button { toggle(season) } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(Color.dangerText)
            }
        }
    }

    // MARK: - Discovery (the pool — never constrains the answer)

    private var discoverySection: some View {
        sectionCard("Find players", systemImage: "magnifyingglass") {
            VStack(alignment: .leading, spacing: 12) {
                anySportToggle
                positionChips
                eraRow
                facetField("Team", text: teamBinding, placeholder: "e.g. KC")
                facetField("Name", text: $query.name, placeholder: "Search a player")
                if searching { ProgressView() }
            }
        }
    }

    private var anySportToggle: some View {
        HStack(spacing: 8) {
            chip("Any", selected: query.sport == nil) { query.sport = nil; query.positions = [] }
            ForEach(Sport.allCases) { s in
                chip(s.displayName, selected: query.sport == s) {
                    query.sport = s; query.positions = []
                }
            }
        }
    }

    private var positionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(positions(for: query.sport), id: \.self) { pos in
                    chip(pos, selected: query.positions.contains(pos)) { togglePosition(pos) }
                }
            }
        }
    }

    private var eraRow: some View {
        HStack(spacing: 12) {
            Stepper("From \(query.minYear ?? bounds.lowerBound)", value: minYearBinding,
                    in: bounds.lowerBound...(query.maxYear ?? bounds.upperBound))
                .font(.label12)
            Stepper("To \(query.maxYear ?? bounds.upperBound)", value: maxYearBinding,
                    in: (query.minYear ?? bounds.lowerBound)...bounds.upperBound)
                .font(.label12)
        }
    }

    // MARK: - Results

    private var resultsSection: some View {
        let ranked = results.sorted { grade($0) > grade($1) }
        return LazyVStack(spacing: 6) {
            ForEach(ranked) { s in resultRow(s) }
            if ranked.isEmpty && !searching {
                Text("No players match. Loosen the filters above.")
                    .font(.body14).foregroundStyle(Color.textMuted).padding(.vertical, 8)
            }
        }
    }

    private func resultRow(_ s: CatalogSeason) -> some View {
        let isSelected = selected.contains(s)
        let full = selected.count >= target && !isSelected
        let team = TeamColors.palette(sport: s.sport, abbr: s.teamAbbr)
        return Button { toggle(s) } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3).fill(team.primary).frame(width: 10, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name).font(.bodyStrong).foregroundStyle(Color.textPrimary)
                    Text(s.subtitle).font(.label12).foregroundStyle(Color.textMuted)
                }
                Spacer()
                Text("\(Int(grade(s).rounded()))").font(.hero(16)).foregroundStyle(Color.textMuted)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle")
                    .foregroundStyle(isSelected ? Color.successText : Color.accentText)
            }
            .padding(12).frame(maxWidth: .infinity).cardSurface()
            .opacity(full ? 0.4 : 1)
        }
        .buttonStyle(.plain).disabled(full)
    }

    // MARK: - Reusable bits

    private func sectionCard<Content: View>(_ title: String, systemImage: String,
                                            @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title.uppercased(), systemImage: systemImage)
                .font(.label12).foregroundStyle(Color.textSecondary)
            content()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).cardSurface()
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(.label11).foregroundStyle(Color.textMuted)
            content()
        }
    }

    private func facetField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(label.uppercased()).font(.label11).foregroundStyle(Color.textMuted).frame(width: 52, alignment: .leading)
            TextField(placeholder, text: text).autocorrectionDisabled()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private func chip(_ label: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: { action(); Haptics.tap() }) {
            Text(label)
                .font(.custom(selected ? FontName.condBlack : FontName.condBold, size: 14))
                .foregroundStyle(selected ? Color.onAccent : Color.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(selected ? Color.accentFill : Color.surfaceMuted)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func sportToggle(selection: Sport, _ pick: @escaping (Sport) -> Void) -> some View {
        HStack(spacing: 8) {
            ForEach(Sport.allCases) { s in chip(s.displayName, selected: selection == s) { pick(s) } }
        }
    }

    // MARK: - Bindings

    private var teamBinding: Binding<String> {
        Binding(get: { query.team ?? "" }, set: { query.team = $0.isEmpty ? nil : $0 })
    }
    private var minYearBinding: Binding<Int> {
        Binding(get: { query.minYear ?? bounds.lowerBound }, set: { query.minYear = $0 })
    }
    private var maxYearBinding: Binding<Int> {
        Binding(get: { query.maxYear ?? bounds.upperBound }, set: { query.maxYear = $0 })
    }
    private func weightBinding(_ i: Int) -> Binding<Int> {
        Binding(get: { Int(terms[i].weight) }, set: { setWeight(i, Double($0)) })
    }

    // MARK: - Mutations

    private func setScoringSport(_ s: Sport) {
        guard s != scoringSport else { return }
        scoringSport = s
        let preset = ScoringRule.preset(s == .nfl ? "nfl_skill_ppr" : "nba_fantasy")!
        terms = Self.integerized(preset.terms)
        displayScale = preset.displayScale
        eraAdjusted = false
        Haptics.tap()
    }

    private func setStat(_ i: Int, _ s: ScoringStat) {
        terms[i] = s.term(weight: terms[i].weight)
    }
    private func toggleDirection(_ i: Int) {
        let t = terms[i]
        terms[i] = .init(stat: t.stat, weight: t.weight, higherWins: !t.higherWins, norm: t.norm)
        Haptics.tap()
    }
    private func setWeight(_ i: Int, _ w: Double) {
        let t = terms[i]
        terms[i] = .init(stat: t.stat, weight: w, higherWins: t.higherWins, norm: t.norm)
    }
    private func removeTerm(_ i: Int) {
        guard terms.count > 1 else { return }
        terms.remove(at: i); Haptics.tap()
    }
    private func addTerm() {
        let used = Set(terms.map(\.stat))
        if let next = ScoringStat.catalog(for: scoringSport).first(where: { !used.contains($0.key) }) {
            terms.append(next.term())
        }
    }

    private func togglePosition(_ pos: String) {
        if let idx = query.positions.firstIndex(of: pos) { query.positions.remove(at: idx) }
        else { query.positions.append(pos) }
    }

    private func toggle(_ s: CatalogSeason) {
        if let idx = selected.firstIndex(of: s) { selected.remove(at: idx) }
        else if selected.count < target { selected.append(s) }
        Haptics.tap()
    }

    private func positions(for sport: Sport?) -> [String] {
        switch sport {
        case .nfl: return ["QB", "RB", "WR", "TE"]
        case .nba: return ["G", "F", "C"]
        case nil:  return ["QB", "RB", "WR", "TE", "G", "F", "C"]
        }
    }

    /// Fantasy points is the one shipped scoring mechanism (NFL skill PPR + QB fantasy; NBA DK).
    /// The legacy fixed 0–100 scales and the era-adjust lever stay in the model but off the surface.
    private func presets(for sport: Sport) -> [(String, String)] {
        sport == .nfl
            ? [("Fantasy (PPR)", "nfl_skill_ppr"), ("QB Fantasy", "nfl_qb_fantasy")]
            : [("Fantasy", "nba_fantasy")]
    }

    // MARK: - Actions

    private func runSearch() async {
        searching = true
        results = await container.catalog.search(query)
        searching = false
        if DebugLaunch.autoOpenCreateKeep4 && selected.isEmpty {
            selected = Array(results.sorted { grade($0) > grade($1) }.prefix(target))
            if title.isEmpty { title = "One-hit wonders: 2010s WRs" }
        }
    }

    /// Build the puzzle cards: grade from the rule (baked at publish), display columns from the
    /// scored stats, each formatted via its `ScoringStat`. Sport = the modal sport of the picks.
    private func cards() -> [PlayerSeason] {
        let r = rule
        return selected.map { s in
            let lines = terms.prefix(3).map { term -> PlayerSeason.StatLine in
                let stat = ScoringStat.find(term.stat, sport: s.sport)
                let value = s.stats[term.stat] ?? 0
                return .init(label: stat?.label ?? term.stat,
                             value: stat?.format(value) ?? "\(Int(value.rounded()))")
            }
            return PlayerSeason(id: s.id, name: s.name, teamAbbr: s.teamAbbr,
                                seasonYear: s.seasonYear, stats: Array(lines),
                                grade: r.grade(s, baselines: container.baselines))
        }
    }

    private var primarySport: Sport {
        let counts = Dictionary(grouping: selected, by: { $0.sport }).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key ?? scoringSport
    }

    private func publish() async {
        guard canPublish else { return }
        publishing = true
        defer { publishing = false }
        let sport = primarySport
        let id = container.newCommunityID()
        let puzzle = Keep4Puzzle(id: id, theme: title, sport: sport, players: cards())
        do {
            _ = try await container.publish(id: id, sport: sport, format: "keep4",
                                            title: title, content: puzzle)
            published = PublishedPuzzle(id: id)
        } catch {
            self.error = String(describing: error)
        }
    }
}

/// Identifies a freshly published puzzle for the confirmation sheet.
struct PublishedPuzzle: Identifiable { let id: String }

/// Shown after publishing — share the deep link, then return to the feed.
struct PublishedSheet: View {
    let shareID: String
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var shareURL: URL { URL(string: "balliq://play/\(shareID)")! }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 48))
                .foregroundStyle(Color.successFill)
            Text("Published!").font(.display1).foregroundStyle(Color.textPrimary)
            Text("Share this link so anyone can play your puzzle.")
                .font(.body14).foregroundStyle(Color.textMuted).multilineTextAlignment(.center)
            Text(shareURL.absoluteString).font(.bodyStrong).foregroundStyle(Color.accentText)
                .padding(12).frame(maxWidth: .infinity).background(Color.surfaceMuted)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control))
            ShareLink(item: shareURL) {
                Text("Share").font(.heading).foregroundStyle(Color.onAccent)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color.accentFill)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control))
            }
            Button("Done") { dismiss(); onDone() }.foregroundStyle(Color.textMuted)
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}
