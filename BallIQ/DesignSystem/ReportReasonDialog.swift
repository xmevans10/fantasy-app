import SwiftUI

/// Shared "report this puzzle?" reason picker (confirmation dialog + a free-text follow-up for
/// "Other") — used by both `CommunityView`'s feed cards and the in-game header report button, so
/// the 4-reason list isn't tripled across call sites.
private struct ReportReasonDialog: ViewModifier {
    @Binding var isPresented: Bool
    let onSelect: (String) -> Void

    @State private var showOtherPrompt = false
    @State private var otherText = ""

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Report this puzzle?", isPresented: $isPresented, titleVisibility: .visible) {
                Button("Spam") { onSelect("spam") }
                Button("Offensive") { onSelect("offensive") }
                Button("Inaccurate or broken puzzle") { onSelect("inaccurate") }
                Button("Other") { showOtherPrompt = true }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Tell us more", isPresented: $showOtherPrompt) {
                TextField("What's wrong with this puzzle?", text: $otherText)
                Button("Send") {
                    onSelect(otherText.isEmpty ? "other" : otherText)
                    otherText = ""
                }
                Button("Cancel", role: .cancel) { otherText = "" }
            }
    }
}

extension View {
    /// Presents the shared report-reason picker; `onSelect` receives the chosen reason string
    /// (matches `CommunityPuzzleRepository.report`'s free-form `reason: String?` field).
    func reportReasonDialog(isPresented: Binding<Bool>, onSelect: @escaping (String) -> Void) -> some View {
        modifier(ReportReasonDialog(isPresented: isPresented, onSelect: onSelect))
    }
}
