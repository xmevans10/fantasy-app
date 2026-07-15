import SwiftUI

/// Username + avatar editor — the one place `profiles.username`/`profiles.avatar` get
/// written from. Opened both from the "claim your username" CTA (first-run) and from the
/// pencil on an already-claimed hero card (edit).
struct IdentityEditorSheet: View {
    @EnvironmentObject private var container: RepositoryContainer
    @Environment(\.dismiss) private var dismiss

    @State private var usernameInput: String
    @State private var selectedAvatar: String
    @State private var saving = false
    @State private var errorMessage: String?

    /// Sports-flavored preset set — single-select, stored as the raw emoji string.
    static let presetAvatars = [
        "🏈", "🏀", "⚾", "⚽", "🎾", "🥎", "🏒", "🥍",
        "🏐", "🎱", "⛳", "🥊", "🏆", "🥇", "🎯", "🧢",
        "🦅", "🐻", "🦁", "🐯", "🔥", "⚡", "💎", "🚀",
    ]

    init() {
        _usernameInput = State(initialValue: "")
        _selectedAvatar = State(initialValue: IdentityEditorSheet.presetAvatars[0])
    }

    private var validation: Result<String, UsernameValidationError> {
        UsernameValidator.validate(usernameInput)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    usernameField
                    avatarGrid
                    if let errorMessage {
                        Text(errorMessage).font(.label12).foregroundStyle(Color.dangerText)
                    }
                    saveButton
                }
                .padding(16)
            }
            .background(Color.appBackground)
            .navigationTitle("Your Identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear {
            // Seed from the current identity so re-opening to edit shows what's saved,
            // not a blank field — but only once (onAppear can refire on some transitions).
            if usernameInput.isEmpty, let existing = container.identity.username {
                usernameInput = existing
            }
            if let existingAvatar = container.identity.avatar,
               IdentityEditorSheet.presetAvatars.contains(existingAvatar) {
                selectedAvatar = existingAvatar
            }
        }
    }

    private var usernameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("USERNAME").font(.label12).foregroundStyle(Color.textMuted)
            TextField("yourname", text: $usernameInput)
                .font(.title)
                .foregroundStyle(Color.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(Color.surfaceMuted)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            if case .failure(let error) = validation, !usernameInput.isEmpty {
                Text(error.message).font(.label11).foregroundStyle(Color.dangerText)
            } else {
                Text("3–20 characters: letters, numbers, underscore. Must start with a letter.")
                    .font(.label11).foregroundStyle(Color.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface()
    }

    private var avatarGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AVATAR").font(.label12).foregroundStyle(Color.textMuted)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                ForEach(IdentityEditorSheet.presetAvatars, id: \.self) { emoji in
                    let selected = emoji == selectedAvatar
                    Button {
                        selectedAvatar = emoji
                        Haptics.tap()
                    } label: {
                        Text(emoji)
                            .font(.system(size: 26))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(selected ? Color.accentBg : Color.surfaceMuted)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                    .strokeBorder(selected ? Color.accentFill : .clear, lineWidth: 2)
                            )
                    }
                    .buttonStyle(PrimePressStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface()
    }

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            if saving {
                ProgressView().tint(Color.onAccent).frame(maxWidth: .infinity).padding(.vertical, 14)
            } else {
                Text("SAVE").ctaLabel()
            }
        }
        .buttonStyle(PrimePressStyle())
        .disabled(saving || validation.isFailure)
    }

    private func save() async {
        guard case .success(let validated) = validation else { return }
        saving = true; errorMessage = nil
        do {
            try await container.saveIdentity(username: validated, avatar: selectedAvatar)
            Haptics.success()
            dismiss()
        } catch SupabaseError.http(status: 409, body: _) {
            errorMessage = String(localized: "That username is taken.")
        } catch {
            errorMessage = String(localized: "Couldn't save. Try again.")
        }
        saving = false
    }
}

private extension Result {
    var isFailure: Bool { if case .failure = self { return true }; return false }
}
