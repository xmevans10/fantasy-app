import SwiftUI

/// One nine-guess budget across the board; rejected duplicates and solved-cell taps spend none.
struct GridRunState {
    struct Attempt: Equatable { let cell: Int; let name: String; let correct: Bool }
    private(set) var attempts: [Attempt] = []
    private(set) var solved: [Int: String] = [:]
    var remaining: Int { max(0, 9 - attempts.count) }
    var unsolvedMisses: Set<Int> { Set(attempts.filter { !$0.correct && solved[$0.cell] == nil }.map(\.cell)) }
    /// Crowd statistics retain one final pick per cell under the existing backend uniqueness key.
    var finalCellAttempts: [Attempt] {
        var last: [Int: Attempt] = [:]
        for attempt in attempts { last[attempt.cell] = attempt }
        return last.keys.sorted().compactMap { last[$0] }
    }
    /// Screenshot fixtures use a matching, since picking each cell's first name can reuse players.
    static func distinctAnswerAssignment(_ puzzle: GridPuzzle) -> [Int: String] {
        var owners: [String: Int] = [:]
        var names: [String: String] = [:]
        func place(_ index: Int, seen: inout Set<String>) -> Bool {
            for name in puzzle.cells[index].validAnswerNames {
                let key = AnswerMatcher.normalize(name)
                guard seen.insert(key).inserted else { continue }
                if let previous = owners[key], !place(previous, seen: &seen) { continue }
                owners[key] = index
                names[key] = name
                return true
            }
            return false
        }
        for index in puzzle.cells.indices {
            var seen: Set<String> = []
            _ = place(index, seen: &seen)
        }
        return Dictionary(uniqueKeysWithValues: owners.map { ( $0.value, names[$0.key]! ) })
    }
    @discardableResult mutating func submit(_ guess: String, at index: Int, puzzle: GridPuzzle) -> Bool? {
        guard remaining > 0, puzzle.cells.indices.contains(index), solved[index] == nil,
              !guess.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !GridGuessSheet.isDuplicate(guess, usedNames: Array(solved.values)) else { return nil }
        let matched = puzzle.cells[index].validAnswerNames.first {
            AnswerMatcher.matches(guess, answer: .init(canonical: $0, aliases: []))
        }
        // Canonicalization closes the case where tolerant matching resolves to an already-used player.
        if let matched, GridGuessSheet.isDuplicate(matched, usedNames: Array(solved.values)) { return nil }
        let correct = matched != nil
        let name = matched ?? guess.trimmingCharacters(in: .whitespacesAndNewlines)
        attempts.append(Attempt(cell: index, name: name, correct: correct))
        if correct { solved[index] = name }
        return correct
    }
}

/// The production board, reused for play, recap and the hosted screenshot gallery.
struct GridBoardPresentation: View {
    let puzzle: GridPuzzle
    let solved: [Int: String]
    var missed: Set<Int> = []
    var completed = false
    var pickPct: [Int: [String: Int]] = [:]
    let onCell: (Int) -> Void
    @State private var helpAxis: GridPuzzle.GridAxis?

    var body: some View {
        let columns = [GridItem(.fixed(62), spacing: 4)] + puzzle.cols.map { _ in GridItem(.flexible(), spacing: 4) }
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(0..<16, id: \.self) { slot in
                let row = slot / 4, col = slot % 4
                if row == 0 && col == 0 {
                    Color.clear.frame(height: 68)
                } else if row == 0 {
                    axis(puzzle.cols[col - 1])
                } else if col == 0 {
                    axis(puzzle.rows[row - 1])
                } else {
                    cell((row - 1) * 3 + col - 1)
                }
            }
        }
        .alert(helpAxis?.label ?? "Category", isPresented: Binding(get: { helpAxis != nil }, set: { if !$0 { helpAxis = nil } })) {
            Button("Got it") { helpAxis = nil }
        } message: {
            if let helpAxis { Text(puzzle.explanation(for: helpAxis)) }
        }
    }

    private func axis(_ axis: GridPuzzle.GridAxis) -> some View {
        Button { helpAxis = axis } label: {
            VStack(spacing: 3) {
                if axis.kind == .team {
                    let tint = TeamColors.palette(sport: puzzle.sport, abbr: axis.teamAbbr, league: axis.teamLeague).primary
                    TeamLogoBadge(sport: puzzle.sport, teamAbbr: axis.teamAbbr, tint: tint,
                                  league: axis.teamLeague, size: 42)
                }
                Text(axis.label)
                    .font(.custom(FontName.condBlack, size: axis.kind == .team ? 12 : 14))
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, minHeight: 68)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(axis.label), category information")
    }

    private func cell(_ index: Int) -> some View {
        Button { onCell(index) } label: {
            ZStack {
                Rectangle().fill(solved[index] == nil ? Color.surface : Color.successText.opacity(0.1))
                VStack(spacing: 4) {
                if let name = solved[index] {
                    Text(name).font(.label11).foregroundStyle(Color.textPrimary)
                        .multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.75)
                    if let pct = pickPct[index]?[name] {
                        Text("\(pct)%").font(.label11).foregroundStyle(Color.textMuted)
                    }
                } else if completed {
                    Image(systemName: "plus").foregroundStyle(Color.textMuted)
                } else if missed.contains(index) {
                    Image(systemName: "arrow.clockwise").foregroundStyle(Color.textMuted)
                    Text("Try again").font(.label11).foregroundStyle(Color.textMuted)
                }
            }
                .padding(4)
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(Rectangle().strokeBorder(Color.borderInk, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!completed && solved[index] != nil)
        .accessibilityLabel("\(puzzle.prompt(row: index / 3, col: index % 3)): \(solved[index] ?? (completed ? "Explore answers" : "Choose a player"))")
    }
}
