import SwiftUI

/// The Grid's guess input: a focused text field with a live player-name autocomplete popup
/// (the pattern Immaculate Grid uses). Suggestions come from a sport-wide name index — never
/// the cell's own answers — so the dropdown helps you spell and pick a real player without
/// revealing whether that player actually fits the square. Selecting a suggestion (or hitting
/// return / Guess) submits exactly one guess; the cell validates it, same as before.
struct GridGuessSheet: View {
    let prompt: String
    /// Sport-wide distinct player names (may be empty → the field still works as free text).
    let names: [String]
    /// Display names already used in other cells — the Immaculate Grid rule: one player per
    /// grid. Filtered out of suggestions, and a typed duplicate is blocked with inline
    /// feedback rather than burning the cell's one attempt. Duplicate detection uses the same
    /// typo-tolerant `AnswerMatcher` the grader uses, so "Tom Bradyy" can't sneak a reuse past
    /// an exact-string check.
    let usedNames: [String]
    let onGuess: (String) -> Void
    let onCancel: () -> Void

    init(prompt: String, names: [String], usedNames: [String] = [], initialText: String = "",
         onGuess: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.prompt = prompt
        self.names = names
        self.usedNames = usedNames
        self.onGuess = onGuess
        self.onCancel = onCancel
        _text = State(initialValue: initialText)   // seed only used by the render-gallery test
    }

    @State private var text: String
    @State private var duplicateBlocked = false
    /// The index normalized once on appear (diacritic/case-folded), so each keystroke filters
    /// cheaply instead of re-normalizing thousands of names (soccer alone has ~21k).
    @State private var normalizedNames: [(display: String, norm: String)] = []
    @FocusState private var focused: Bool

    static let maxSuggestions = 8

    private var usedNormalized: Set<String> { Set(usedNames.map(AnswerMatcher.normalize)) }

    private var suggestions: [String] {
        Self.rank(query: text, normalized: normalizedNames, limit: Self.maxSuggestions)
            .filter { !usedNormalized.contains(AnswerMatcher.normalize($0)) }
    }

    /// True when `guess` would re-answer with a player already placed in another cell.
    static func isDuplicate(_ guess: String, usedNames: [String]) -> Bool {
        usedNames.contains { AnswerMatcher.matches(guess, answer: .init(canonical: $0, aliases: [])) }
    }

    /// Prefix hits ranked above interior hits, each alphabetical within its group (the index
    /// arrives already sorted). Uses the grader's normalizer so "jarrett"/"Jarrett" and
    /// "darnold"/"Darnöld" behave the same here as at scoring time. Requires ≥2 query chars so
    /// a single letter doesn't dump a third of the league. Pure — locked by tests.
    static func rank(query: String, normalized: [(display: String, norm: String)],
                     limit: Int = maxSuggestions) -> [String] {
        let q = AnswerMatcher.normalize(query)
        guard q.count >= 2, !normalized.isEmpty else { return [] }
        var prefix: [String] = []
        var contains: [String] = []
        for entry in normalized {
            if entry.norm.hasPrefix(q) { prefix.append(entry.display) }
            else if entry.norm.contains(q) { contains.append(entry.display) }
        }
        return Array((prefix + contains).prefix(limit))
    }

    /// Convenience for callers/tests that hold raw display names (normalizes up front).
    static func rank(query: String, names: [String], limit: Int = maxSuggestions) -> [String] {
        rank(query: query, normalized: names.map { ($0, AnswerMatcher.normalize($0)) }, limit: limit)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text(prompt)
                    .font(.label12).foregroundStyle(Color.proText)
                    .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.textMuted)
                    TextField("Name a player", text: $text)
                        .font(.body14)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($focused)
                        .onSubmit(submitTyped)
                    if !text.isEmpty {
                        Button { text = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.textMuted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Color.surfaceMuted)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .padding(.horizontal, 16)
                .onChange(of: text) { duplicateBlocked = false }

                if duplicateBlocked {
                    Label("Already used in another cell — one player per grid.", systemImage: "exclamationmark.triangle.fill")
                        .font(.label12).foregroundStyle(Color.dangerText)
                        .padding(.horizontal, 16).padding(.top, 10)
                }

                suggestionList

                Spacer(minLength: 0)
            }
            .background(Color.appBackground)
            .navigationTitle("Name that player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guess", action: submitTyped).disabled(trimmed.isEmpty)
                }
            }
        }
        .onAppear {
            focused = true
            if normalizedNames.isEmpty {
                normalizedNames = names.map { ($0, AnswerMatcher.normalize($0)) }
            }
        }
    }

    @ViewBuilder
    private var suggestionList: some View {
        let hits = suggestions
        if !hits.isEmpty {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(hits, id: \.self) { name in
                        Button { onGuess(name) } label: {
                            HStack {
                                Text(name).font(.body14).foregroundStyle(Color.textPrimary)
                                Spacer()
                                Image(systemName: "arrow.up.left")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.textMuted)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 13)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Color.hairline)
                    }
                }
            }
            .padding(.top, 8)
        } else if trimmed.count >= 2 && !names.isEmpty {
            Text("No player by that name — tap Guess to submit it anyway.")
                .font(.label12).foregroundStyle(Color.textMuted)
                .padding(.horizontal, 16).padding(.top, 12)
        }
    }

    private func submitTyped() {
        guard !trimmed.isEmpty else { return }
        guard !Self.isDuplicate(trimmed, usedNames: usedNames) else {
            duplicateBlocked = true
            return
        }
        onGuess(trimmed)
    }
}
