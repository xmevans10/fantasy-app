import SwiftUI

/// Build a K4C4 from real player-seasons. Three decoupled axes — *how it's scored* (PPR / Half
/// PPR / Standard / Vibes), *who's in the pool* (free discovery facets), and *the 8 picks* — with
/// a live answer preview. Discovery facets never touch the selection: the creator curates the
/// pool to fit their theme; the UI doesn't filter for them.
struct CreateKeep4View: View {
    @EnvironmentObject private var container: RepositoryContainer
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var description = ""
    @State private var query = CatalogQuery(sport: .nfl)
    @State private var scoringSport: Sport = .nfl
    @State private var scoringChoice: ScoringChoice = .ppr
    /// Era-adjust lever for the three fantasy-points choices (irrelevant for Vibes, which has
    /// no formula at all).
    @State private var eraAdjusted = false
    /// Daily-theme template in effect (M10 unification). While set, the published card's
    /// stat columns come from the theme — exactly what the daily pipeline bakes — instead
    /// of being derived from the scoring preset. Cleared by any manual scoring change.
    @State private var activeTheme: Keep4Theme?
    /// Creatable themes (any grain — season, career, or single-game) with an app-mirrored
    /// scale, from the bundled keep4_themes.json.
    private let themes: [Keep4Theme] = Keep4Theme.bundled.filter(\.isCreatable)
    /// The 8 picks. Order is meaningless for the three fantasy-points choices (the preview
    /// sorts by grade) but IS the ranking itself for Vibes — drag to reorder there.
    @State private var selected: [CatalogSeason] = []
    @State private var results: [CatalogSeason] = []
    @State private var searching = false
    @State private var publishing = false
    @State private var published: PublishedPuzzle?
    @State private var error: String?

    private let target = 8
    private var isVibes: Bool { scoringChoice == .vibes }
    /// nil for Vibes (no formula) or if a preset key can't be resolved.
    private var rule: ScoringRule? {
        guard let key = scaleKey, let preset = ScoringRule.preset(key) else { return nil }
        return preset.eraAdjusted(eraAdjusted)
    }
    /// The grade-scale key behind `rule` — baked into the published puzzle so the scoring
    /// explainer can show the exact formula (Half PPR vs full, pitcher vs hitter).
    private var scaleKey: String? {
        isVibes ? nil : (activeTheme?.scale ?? scoringChoice.presetKey(for: scoringSport))
    }
    private var bounds: ClosedRange<Int> { container.catalog.yearBounds }
    private var canPublish: Bool {
        guard selected.count == target, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return isVibes || rule != nil
    }

    private func grade(_ s: CatalogSeason) -> Double? { rule?.grade(s, baselines: container.baselines) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                titleField
                if !themes.isEmpty { templateSection }
                scoringSection
                previewSection
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
        .task {
            if let key = DebugLaunch.createTemplateKey, let theme = themes.first(where: { $0.key == key }) {
                apply(theme)
            }
            await runSearch()
        }
        .onChange(of: query) { Task { await runSearch() } }
        .alert("Couldn't publish", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .sheet(item: $published) { p in
            PublishedSheet(shareID: p.id) { dismiss() }.environmentObject(container)
        }
    }

    // MARK: - Title

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("Title") {
                TextField("e.g. One-hit wonders: 2010s WRs", text: $title)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12).padding(.vertical, 11)
                    .background(Color.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
            field("Description (optional)") {
                TextField("A brief note about this puzzle", text: $description, axis: .vertical)
                    .lineLimit(2...4)
                    .padding(.horizontal, 12).padding(.vertical, 11)
                    .background(Color.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
        }
    }

    // MARK: - Templates (daily themes as creation starting points)

    /// Pick a daily theme to start from: sets the exact scoring rule, position filters, and
    /// card stat columns the pipeline uses, so the published puzzle matches daily rows in
    /// structure. The author still curates the 8 picks; facet search stays for discovery.
    private var templateSection: some View {
        sectionCard("Start from a daily theme", systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(themes) { theme in
                            PrimeChip(label: theme.title, active: activeTheme?.key == theme.key) {
                                if activeTheme?.key == theme.key {
                                    clearTemplate()          // back to free-form
                                } else {
                                    apply(theme)
                                }
                            }
                        }
                    }
                }
                Text(activeTheme.map {
                        let noun = PuzzleGrain(rawValue: $0.grain)?.countNoun ?? "seasons"
                        return "Cards will show \($0.title)'s exact stat columns, scored like the daily puzzle. Search below is scoped to \(noun) only." }
                     ?? "Templates copy a daily theme's scoring and card layout; you pick the 8 seasons.")
                    .font(.label11).foregroundStyle(Color.textMuted)
            }
        }
    }

    /// Adopt a theme template: same scale, sport, and discovery positions as the pipeline.
    /// The theme's own grain also scopes search to that grain only (never mixing season,
    /// career, and single-game rows in one pool).
    private func apply(_ theme: Keep4Theme) {
        guard theme.scoringRule != nil else { return }
        activeTheme = theme
        scoringSport = theme.sport
        scoringChoice = .ppr
        eraAdjusted = theme.eraAdjusted
        query = CatalogQuery(sport: theme.sport, positions: theme.positions,
                             grain: PuzzleGrain(rawValue: theme.grain) ?? .season)
        Haptics.tap()
    }

    /// Leave any active theme template and drop its grain-only search scope — free-form
    /// creation defaults back to season (the original, most-populated pool).
    private func clearTemplate() {
        activeTheme = nil
        query.grain = .season
    }

    // MARK: - Scoring (the answer axis)

    private var scoringSection: some View {
        sectionCard("Scoring", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 12) {
                sportToggle(selection: scoringSport) { setScoringSport($0) }
                scoringChips
                if isVibes {
                    Text("Vibes — you rank the 8 yourself, no formula, no scores. Players will " +
                         "see this labeled as your call, not a stat line.")
                        .font(.label11).foregroundStyle(Color.textMuted)
                } else {
                    eraToggle
                }
            }
        }
    }

    private var scoringChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ScoringChoice.available(for: scoringSport)) { choice in
                    PrimeChip(label: choice.label(for: scoringSport),
                             active: scoringChoice == choice && activeTheme == nil) {
                        scoringChoice = choice
                        clearTemplate()    // manual scoring choice leaves the template
                    }
                }
            }
        }
    }

    /// Era-adjust lever for the fantasy-points choices (M10): the season's point total × its
    /// era's volume index, so the same production is worth more in a scarcer era. Not shown
    /// for Vibes, which has no formula to adjust.
    private var eraToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Era-adjust scoring", isOn: eraBinding)
                .font(.bodyStrong)
                .tint(Color.accentFill)
            Text("Multiplies each season's points by its era's league volume — a 2002 stat line can outrank a bigger modern one.")
                .font(.label11).foregroundStyle(Color.textMuted)
        }
    }

    /// Toggling era by hand is a scoring change: leave the template unless it matches the theme.
    private var eraBinding: Binding<Bool> {
        Binding(get: { eraAdjusted }, set: { on in
            eraAdjusted = on
            if let theme = activeTheme, theme.eraAdjusted != on { clearTemplate() }
            Haptics.tap()
        })
    }

    // MARK: - Live answer preview

    @ViewBuilder private var previewSection: some View {
        if !selected.isEmpty {
            if isVibes { vibesOrderSection } else { pprPreview }
        }
    }

    private var pprPreview: some View {
        let graded = selected.sorted { (grade($0) ?? 0) > (grade($1) ?? 0) }
        return sectionCard("Answer preview · \(selected.count)/\(target)", systemImage: "eye") {
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
            Text("\(Int((grade(season) ?? 0).rounded()))").font(.hero(15)).foregroundStyle(Color.textPrimary)
            Button { toggle(season) } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(Color.dangerText)
            }
        }
    }

    /// Vibes has no formula, so the "preview" is the ranking itself — drag the 8 picks into
    /// the order you'd keep them. Top 4 become KEEP, bottom 4 become CUT. No numbers anywhere.
    private var vibesOrderSection: some View {
        sectionCard("Your ranking · \(selected.count)/\(target)", systemImage: "hand.draw") {
            VStack(alignment: .leading, spacing: 10) {
                Text(selected.count == target
                     ? "Drag into the order you'd keep them — top 4 are KEEP, bottom 4 are CUT."
                     : "Add \(target - selected.count) more, then drag them into your order.")
                    .font(.label11).foregroundStyle(Color.textMuted)
                List {
                    ForEach(Array(selected.enumerated()), id: \.element.id) { i, s in
                        vibesRow(rank: i, season: s)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    .onMove { indices, newOffset in
                        selected.move(fromOffsets: indices, toOffset: newOffset)
                        Haptics.tap()
                    }
                }
                .listStyle(.plain)
                .scrollDisabled(true)
                .environment(\.editMode, .constant(.active))
                .frame(height: CGFloat(selected.count) * 44)
            }
        }
    }

    private func vibesRow(rank: Int, season: CatalogSeason) -> some View {
        let team = TeamColors.palette(sport: season.sport, abbr: season.teamAbbr)
        let keep = rank < 4
        return HStack(spacing: 8) {
            Text("\(rank + 1)").font(.hero(15)).foregroundStyle(Color.textMuted).frame(width: 22)
            Text(keep ? "KEEP" : "CUT")
                .font(.custom(FontName.condBlack, size: 11))
                .foregroundStyle(keep ? Color.successText : Color.dangerText)
                .frame(width: 40, alignment: .leading)
            RoundedRectangle(cornerRadius: 3).fill(team.primary).frame(width: 9, height: 16)
            Text(season.name).font(.bodyStrong).foregroundStyle(Color.textPrimary).lineLimit(1)
            Text(season.subtitle).font(.label11).foregroundStyle(Color.textMuted).lineLimit(1)
            Spacer(minLength: 2)
            Button { toggle(season) } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(Color.dangerText)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Discovery (the pool — never constrains the answer)

    private var discoverySection: some View {
        sectionCard("Find players", systemImage: "magnifyingglass") {
            VStack(alignment: .leading, spacing: 12) {
                grainToggle
                anySportToggle
                positionChips
                eraRow
                facetField("Team", text: teamBinding, placeholder: "e.g. KC")
                PrimeSearchField(placeholder: "Search a player", text: $query.name)
                if searching { ProgressView() }
            }
        }
    }

    /// Which grain to search — locked to one at a time (never mixed within a single pool,
    /// same discipline `apply(theme:)` already applies for a template). Switching away from
    /// a template's grain implicitly leaves the template, same as any other manual facet
    /// change would once a rule stops matching — but grain changes never clear the template
    /// mid-search here since the chips already reflect `query.grain`, kept in sync by
    /// `apply`/`clearTemplate`.
    private var grainToggle: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach([PuzzleGrain.season, .singleGame, .career], id: \.self) { g in
                    PrimeChip(label: g.badgeLabel, active: query.grain == g) {
                        guard query.grain != g else { return }
                        query.grain = g
                        if activeTheme != nil, activeTheme?.grain != g.rawValue { activeTheme = nil }
                        Haptics.tap()
                    }
                }
            }
        }
    }

    private var anySportToggle: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                PrimeChip(label: "Any", active: query.sport == nil) {
                    query.sport = nil; query.positions = []
                }
                ForEach(Sport.allCases) { s in
                    PrimeChip(label: s.displayName, active: query.sport == s) {
                        query.sport = s; query.positions = []
                    }
                }
            }
        }
    }

    private var positionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(positions(for: query.sport), id: \.self) { pos in
                    PrimeChip(label: pos, active: query.positions.contains(pos)) { togglePosition(pos) }
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
        let ranked = isVibes ? results : results.sorted { (grade($0) ?? 0) > (grade($1) ?? 0) }
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
                if let g = grade(s) {
                    Text("\(Int(g.rounded()))").font(.hero(16)).foregroundStyle(Color.textMuted)
                }
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

    private func sportToggle(selection: Sport, _ pick: @escaping (Sport) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Sport.allCases) { s in
                    PrimeChip(label: s.displayName, active: selection == s) { pick(s) }
                }
            }
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

    // MARK: - Mutations

    private func setScoringSport(_ s: Sport) {
        guard s != scoringSport else { return }
        scoringSport = s
        // Half PPR / Standard are NFL-only concepts (they're both just "Fantasy" on NBA).
        if scoringChoice == .halfPPR || scoringChoice == .standard { scoringChoice = .ppr }
        eraAdjusted = false
        clearTemplate()    // manual scoring choice leaves the template
        Haptics.tap()
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
        case .baseball: return ["H", "P"]
        case .soccer: return ["FW", "MF", "DF", "GK"]
        case .tennis: return ["Player"]
        case nil:
            return ["QB", "RB", "WR", "TE", "G", "F", "C", "H", "P", "FW", "MF", "DF", "GK", "Player"]
        }
    }

    // MARK: - Actions

    private func runSearch() async {
        searching = true
        results = await container.catalog.search(query)
        searching = false
        if DebugLaunch.autoOpenCreateKeep4 && selected.isEmpty {
            selected = Array(results.sorted { (grade($0) ?? 0) > (grade($1) ?? 0) }.prefix(target))
            if title.isEmpty { title = "One-hit wonders: 2010s WRs" }
        }
    }

    /// Default card stat lines for Vibes (no scoring terms to derive from — a few
    /// informative headline stats for the sport, sliced to the season's own position via
    /// `ScoringStat.displayColumns` so a free-form pool mixing positions — e.g. a QB
    /// alongside WRs — never bakes a stat family the QB's card doesn't record. `grain`
    /// matters here too: a single-game NBA/baseball row's stat keys differ from its
    /// season counterpart (see `Sport.positionStatTemplatesGame`), so the wrong grain
    /// would silently read absent keys and render every stat as zero.
    private func defaultStatLines(_ s: CatalogSeason) -> [PlayerSeason.StatLine] {
        ScoringStat.displayColumns(sport: s.sport, position: s.position, grain: query.grain).map { stat in
            let value = s.stats[stat.key] ?? 0
            return .init(label: stat.label, value: stat.format(value))
        }
    }

    /// Build the puzzle cards. Vibes bakes the grade as a descending rank (the drag order —
    /// never shown to players) so `Keep4Puzzle.correctKeepIDs`' top-4/bottom-4 math works
    /// unchanged. Otherwise the grade is the rule's real fantasy total. Display columns come
    /// from the active theme template when one is set, otherwise the rule's own terms (or, for
    /// Vibes, a few generic headline stats). Sport = modal sport of picks. `week`/`opponent`/
    /// `gameDate` carry through so a single-game puzzle's cards show "vs OPP · date" instead
    /// of a bare season year, same as the daily pipeline's own single-game cards.
    private func cards() -> [PlayerSeason] {
        if isVibes {
            let n = selected.count
            return selected.enumerated().map { i, s in
                PlayerSeason(id: s.id, name: s.name, teamAbbr: s.teamAbbr,
                            seasonYear: s.seasonYear, stats: defaultStatLines(s),
                            grade: Double(n - i), headshot: s.headshot,
                            week: s.week, opponent: s.opponent, gameDate: s.gameDate,
                            firstYear: s.firstYear, lastYear: s.lastYear)
            }
        }
        let r = rule
        return selected.map { s in
            let lines: [PlayerSeason.StatLine]
            if let theme = activeTheme {
                lines = theme.cardStats(for: s.stats, position: s.position)
            } else {
                // Prefer the rule's own terms (display should reflect what's scored), but
                // slice to the season's position first — a QB in a mixed pool under a
                // skill-position rule would otherwise show its (all-zero) receiving terms.
                let preferredKeys = (r?.terms ?? []).map(\.stat)
                lines = ScoringStat.displayColumns(sport: s.sport, position: s.position,
                                                   preferredKeys: preferredKeys,
                                                   grain: query.grain).map { stat in
                    let value = s.stats[stat.key] ?? 0
                    return .init(label: stat.label, value: stat.format(value))
                }
            }
            return PlayerSeason(id: s.id, name: s.name, teamAbbr: s.teamAbbr,
                                seasonYear: s.seasonYear, stats: lines,
                                grade: r?.grade(s, baselines: container.baselines) ?? 0,
                                headshot: s.headshot,
                                week: s.week, opponent: s.opponent, gameDate: s.gameDate,
                                firstYear: s.firstYear, lastYear: s.lastYear)
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
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let scoring: ScoringKind = isVibes ? .vibes : (rule.map(ScoringKind.init(rule:)) ?? .ppr)
        // Bakes the discovery grain actually searched (season/career/single-game) — not
        // just the active template's, so free-form creation (no template) still tags the
        // puzzle correctly instead of hardcoding "season" regardless of what was picked.
        let puzzle = Keep4Puzzle(id: id, theme: title, sport: sport, players: cards(),
                                 description: trimmedDescription.isEmpty ? nil : trimmedDescription,
                                 scoring: scoring, grain: query.grain.rawValue,
                                 scale: rule == nil ? nil : scaleKey)
        do {
            _ = try await container.publish(id: id, sport: sport, format: "keep4",
                                            title: title, content: puzzle)
            published = PublishedPuzzle(id: id)
        } catch {
            self.error = String(describing: error)
        }
    }
}

/// The four selectable scoring philosophies. PPR/Half PPR/Standard are objective fantasy-point
/// formulas that only differ in reception credit (an NFL distinction — NBA has no receptions, so
/// it only ever offers "Fantasy" + "Vibes"); Vibes has no formula at all.
private enum ScoringChoice: String, CaseIterable, Identifiable {
    case ppr, halfPPR, standard, vibes
    var id: String { rawValue }

    static func available(for sport: Sport) -> [ScoringChoice] {
        sport == .nfl ? [.ppr, .halfPPR, .standard, .vibes] : [.ppr, .vibes]
    }

    func label(for sport: Sport) -> String {
        switch self {
        case .ppr:      return sport == .nfl ? "PPR" : "Fantasy"
        case .halfPPR:  return "Half PPR"
        case .standard: return "Standard"
        case .vibes:    return "Vibes"
        }
    }

    /// The `ScoringRule.presets` key this choice resolves to, or nil for Vibes (no rule).
    ///
    /// Baseball/soccer default to their *hitter*/*attacker* scale here — free-form creation
    /// has no per-position scale to pick from without a template; picking one of this
    /// sport's bundled themes (`templateSection`) applies the right position-specific
    /// scale (e.g. pitcher/defender) instead of this fallback.
    func presetKey(for sport: Sport) -> String? {
        switch (self, sport) {
        case (.vibes, _):         return nil
        case (_, .nba):           return "nba_fantasy"
        case (_, .baseball):      return "baseball_hitter_fantasy"
        case (_, .soccer):        return "soccer_attacker_fantasy"
        case (_, .tennis):        return "tennis_fantasy"
        case (.ppr, .nfl):        return "nfl_fantasy"
        case (.halfPPR, .nfl):    return "nfl_fantasy_half"
        case (.standard, .nfl):   return "nfl_fantasy_standard"
        }
    }
}

/// Identifies a freshly published puzzle for the confirmation sheet.
struct PublishedPuzzle: Identifiable { let id: String }

/// Shown after publishing — share the deep link, then return to the feed.
struct PublishedSheet: View {
    let shareID: String
    let onDone: () -> Void
    @EnvironmentObject private var container: RepositoryContainer
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
                Text("SHARE").ctaLabel()
            }
            .buttonStyle(PrimePressStyle())
            // ShareLink has no tap callback — a simultaneous gesture is the standard hook.
            .simultaneousGesture(TapGesture().onEnded {
                container.track(.shareTapped, ["surface": "publish_link"])
            })
            Button("Done") { dismiss(); onDone() }.foregroundStyle(Color.textMuted)
        }
        .padding(16)
        .presentationDetents([.medium])
    }
}
