import SwiftUI

/// Author a Who Am I? puzzle: a mystery player + six ordered clues. Clue text is the
/// creator's (factual accuracy is on them); we keep the same era→jersey clue order as dailies.
struct CreateWhoAmIView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @Environment(\.dismiss) private var dismiss

    private static let kinds: [ClueKind] = [.era, .position, .teams, .statLine, .fact, .jersey]
    private static let hints: [ClueKind: String] = [
        .era: "Played from 1996 to 2010", .position: "Point Guard",
        .teams: "76ers, Nuggets, Pistons", .statLine: "2001 MVP at 26.7 ppg",
        .fact: "Won MVP at six feet tall", .jersey: "Wore number 3",
    ]

    @State private var sport: Sport = .nfl
    @State private var title = ""
    @State private var canonical = ""
    @State private var aliases = ""
    @State private var clues: [ClueKind: String] = [:]
    @State private var publishing = false
    @State private var published: PublishedPuzzle?
    @State private var error: String?

    private var cluesComplete: Bool { Self.kinds.allSatisfy { !(clues[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty } }
    private var canPublish: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !canonical.trimmingCharacters(in: .whitespaces).isEmpty
            && cluesComplete
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                field("Title") { plain("e.g. AI legends", text: $title) }
                field("Sport") {
                    Picker("Sport", selection: $sport) {
                        ForEach(Sport.allCases) { Text($0.displayName).tag($0) }
                    }.pickerStyle(.segmented)
                }
                field("Answer (full name)") { plain("Allen Iverson", text: $canonical) }
                field("Also accept (comma-separated)") { plain("ai, the answer", text: $aliases) }

                Text("CLUES").font(.label11).foregroundStyle(Color.textMuted)
                ForEach(Self.kinds, id: \.self) { kind in
                    clueField(kind)
                }
            }
            .padding(16)
        }
        .background(Color.appBackground)
        .navigationTitle("New Who Am I?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(publishing ? "…" : "Publish") { Task { await publish() } }
                    .disabled(!canPublish || publishing).fontWeight(.semibold)
            }
        }
        .alert("Couldn't publish", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .sheet(item: $published) { p in PublishedSheet(shareID: p.id) { dismiss() } }
    }

    private func clueField(_ kind: ClueKind) -> some View {
        let i = (Self.kinds.firstIndex(of: kind) ?? 0) + 1
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(i). \(kind.label)").font(.label12).foregroundStyle(Color.accentText)
            plain(Self.hints[kind] ?? "", text: Binding(
                get: { clues[kind] ?? "" }, set: { clues[kind] = $0 }))
        }
    }

    private func plain(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(Color.surfaceMuted)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(.label11).foregroundStyle(Color.textMuted)
            content()
        }
    }

    private func publish() async {
        guard canPublish else { return }
        publishing = true
        defer { publishing = false }
        let cluesArr = Self.kinds.enumerated().map { idx, kind in
            WhoAmIPuzzle.Clue(order: idx + 1, kind: kind,
                              text: (clues[kind] ?? "").trimmingCharacters(in: .whitespaces))
        }
        let aliasList = aliases.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        let answer = WhoAmIPuzzle.AcceptedAnswer(canonical: canonical.trimmingCharacters(in: .whitespaces),
                                                 aliases: aliasList)
        let id = container.newCommunityID()
        let puzzle = WhoAmIPuzzle(id: id, sport: sport, clues: cluesArr, answer: answer)
        do {
            _ = try await container.publish(id: id, sport: sport,
                                            format: "whoami", title: title, content: puzzle)
            published = PublishedPuzzle(id: id)
        } catch {
            self.error = String(describing: error)
        }
    }
}
