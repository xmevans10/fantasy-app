import SwiftUI
import PhotosUI
import UIKit

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
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var uploadingPhoto = false
    @State private var photoUploadError: String?

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
               IdentityEditorSheet.presetAvatars.contains(existingAvatar) || existingAvatar.hasPrefix("http") {
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
            photoPickerRow
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

    /// A photo upload alongside the emoji grid, not a replacement — `selectedAvatar` holds
    /// whichever one the user picked last, since `saveIdentity`'s `avatar` param treats both
    /// as an opaque string. Selecting an emoji below overwrites a photo selection and vice versa.
    private var photoPickerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            PhotosPicker(selection: $photoPickerItem, matching: .images) {
                HStack(spacing: 10) {
                    if uploadingPhoto {
                        ProgressView().frame(width: 44, height: 44)
                    } else if selectedAvatar.hasPrefix("http") {
                        AvatarView(avatar: selectedAvatar, size: 44)
                    } else {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(Color.surfaceMuted)
                            .clipShape(Circle())
                    }
                    Text(selectedAvatar.hasPrefix("http") ? "Photo selected — tap to change" : "Or choose a photo")
                        .font(.label12)
                        .foregroundStyle(Color.textPrimary)
                    Spacer()
                }
                .padding(10)
                .background(selectedAvatar.hasPrefix("http") ? Color.accentBg : Color.surfaceMuted)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
            .buttonStyle(PrimePressStyle())
            .disabled(uploadingPhoto)
            if let photoUploadError {
                Text(photoUploadError).font(.label11).foregroundStyle(Color.dangerText)
            }
        }
        .onChange(of: photoPickerItem) { _, newItem in
            Task { await handlePhotoPick(newItem) }
        }
    }

    private func handlePhotoPick(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        photoUploadError = nil
        uploadingPhoto = true
        defer { uploadingPhoto = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: data),
                  let jpeg = uiImage.resizedForAvatar().jpegData(compressionQuality: 0.85) else {
                photoUploadError = String(localized: "Couldn't read that photo.")
                return
            }
            let url = try await container.uploadAvatarPhoto(jpeg)
            selectedAvatar = url
            Haptics.tap()
        } catch {
            photoUploadError = String(localized: "Upload failed. Try again.")
        }
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

private extension UIImage {
    /// Downscales to at most 512pt on the longest side before upload — avatars render at
    /// ≤84pt in the app, so this keeps uploads small without visible quality loss.
    func resizedForAvatar(maxDimension: CGFloat = 512) -> UIImage {
        let scale = min(1, maxDimension / max(size.width, size.height))
        guard scale < 1 else { return self }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
