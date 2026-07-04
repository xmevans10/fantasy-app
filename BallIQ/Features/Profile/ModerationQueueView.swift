import SwiftUI

/// Admin-only review queue for reported community puzzles (M12's policy half).
/// Reads `community_reports` back out (admin RLS), groups rows into per-puzzle cases via
/// `ModerationPolicy`, and lets the operator restore, hide, or remove each one. Reached
/// from Profile, visible only when `RepositoryContainer.isAdmin` is set.
struct ModerationQueueView: View {
    @EnvironmentObject private var container: RepositoryContainer

    @State private var cases: [ModerationPolicy.ReviewCase] = []
    @State private var summaries: [String: CommunitySummary] = [:]
    @State private var authors: [String: String] = [:]
    @State private var loading = false
    @State private var loadFailed = false
    @State private var removeTarget: ModerationPolicy.ReviewCase?

    var body: some View {
        Group {
            if loading && cases.isEmpty {
                ProgressView().tint(.accentFill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if cases.isEmpty && loadFailed {
                EmptyStateView(symbol: "wifi.exclamationmark",
                               title: "Couldn't load reports",
                               message: "Check your connection and try again.",
                               actionTitle: "Retry") { Task { await load() } }
            } else if cases.isEmpty {
                EmptyStateView(symbol: "checkmark.shield.fill",
                               title: "Queue is clear",
                               message: "No reported puzzles to review.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(cases) { reviewCard($0) }
                    }
                    .padding(16)
                }
            }
        }
        .background(Color.appBackground)
        .navigationTitle("Moderation")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Remove this puzzle permanently?",
                            isPresented: Binding(get: { removeTarget != nil },
                                                 set: { if !$0 { removeTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let target = removeTarget { Task { await remove(target) } }
                removeTarget = nil
            }
            Button("Cancel", role: .cancel) { removeTarget = nil }
        } message: {
            Text("Deletion can't be undone — restoring or leaving it hidden are reversible.")
        }
    }

    // MARK: - Card

    private func reviewCard(_ reviewCase: ModerationPolicy.ReviewCase) -> some View {
        let summary = summaries[reviewCase.puzzleId]
        let isHidden = summary?.visibility == "hidden"
        let author = summary.flatMap { authors[$0.authorId] }.map { "@\($0)" } ?? "unknown author"
        let reports = reviewCase.distinctReporters == 1 ? "1 REPORT"
                                                        : "\(reviewCase.distinctReporters) REPORTS"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(summary?.format == "whoami" ? "WHO AM I?" : "K4C4")
                    .font(.label11).foregroundStyle(Color.textMuted)
                if isHidden { badge("HIDDEN", fg: .dangerText, bg: .dangerBg) }
                Spacer()
                badge(reports, fg: .warningText, bg: .warningBg)
            }
            VStack(alignment: .leading, spacing: 2) {
                // A report can outlive its puzzle (author self-deleted) — show the id so the
                // stale case is still identifiable before a refresh clears it.
                Text(summary?.title ?? "Deleted puzzle (\(reviewCase.puzzleId))")
                    .font(.title).foregroundStyle(Color.textPrimary)
                Text(author.uppercased()).font(.label11).foregroundStyle(Color.textMuted)
            }
            if !reviewCase.reasons.isEmpty {
                Text(reviewCase.reasons.joined(separator: " · "))
                    .font(.body14).foregroundStyle(Color.textSecondary)
            }
            if summary != nil {
                HStack(spacing: 8) {
                    if isHidden {
                        actionButton("RESTORE", fg: .onAccent, bg: .accentFill) {
                            Task { await restore(reviewCase) }
                        }
                    } else {
                        actionButton("HIDE", fg: .warningText, bg: .warningBg) {
                            Task { await hide(reviewCase) }
                        }
                    }
                    actionButton("REMOVE", fg: .dangerText, bg: .dangerBg) {
                        removeTarget = reviewCase
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface()
    }

    private func badge(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text).font(.label11).foregroundStyle(fg)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(bg)
            .clipShape(Capsule())
    }

    private func actionButton(_ title: String, fg: Color, bg: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.label12).foregroundStyle(fg)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(bg)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(PrimePressStyle())
    }

    // MARK: - Data

    private func load() async {
        guard let community = container.community else { cases = []; return }
        loading = true
        defer { loading = false }
        do {
            let reports = try await community.reports()
            let grouped = ModerationPolicy.reviewCases(from: reports)
            let fetched = try await community.summaries(ids: grouped.map(\.puzzleId))
            cases = grouped
            summaries = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
            loadFailed = false
            let missing = Set(fetched.map(\.authorId)).subtracting(authors.keys)
            authors.merge(await community.authorNames(ids: missing)) { _, new in new }
        } catch is CancellationError {
        } catch {
            print("ModerationQueueView.load failed: \(error)")
            loadFailed = true
        }
    }

    /// Restore = clear the reports first (so the next report starts a fresh count),
    /// then flip visibility back to public.
    private func restore(_ reviewCase: ModerationPolicy.ReviewCase) async {
        guard let community = container.community else { return }
        try? await community.clearReports(puzzleID: reviewCase.puzzleId)
        try? await community.setVisibility(id: reviewCase.puzzleId, visibility: "public")
        Haptics.success()
        await load()
    }

    private func hide(_ reviewCase: ModerationPolicy.ReviewCase) async {
        guard let community = container.community else { return }
        try? await community.setVisibility(id: reviewCase.puzzleId, visibility: "hidden")
        Haptics.success()
        await load()
    }

    private func remove(_ reviewCase: ModerationPolicy.ReviewCase) async {
        guard let community = container.community else { return }
        try? await community.delete(id: reviewCase.puzzleId)
        Haptics.success()
        await load()
    }
}
