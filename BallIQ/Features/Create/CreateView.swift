import SwiftUI

/// Entry to puzzle creation. Gated on sign-in (publishing needs a user JWT for RLS).
struct CreateView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if container.isSignedIn {
                    chooser
                } else {
                    signInPrompt
                }
            }
            .background(Color.appBackground)
            .navigationTitle("Create")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var chooser: some View {
        VStack(spacing: 16) {
            Text("What do you want to build?")
                .font(.title).foregroundStyle(Color.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            NavigationLink { CreateKeep4View().environmentObject(container) } label: {
                choice(title: "K4C4", blurb: "Pick 8 real seasons; the top 4 by the stats are the answer.",
                       symbol: "rectangle.stack.fill", accent: .accentFill, on: .onAccent)
            }
            NavigationLink { CreateWhoAmIView().environmentObject(container) } label: {
                choice(title: "Who Am I?", blurb: "Write six clues that lead to a mystery player.",
                       symbol: "person.fill.questionmark", accent: .voltFill, on: .onVolt)
            }
            Spacer()
        }
        .padding(16)
    }

    private func choice(title: String, blurb: String, symbol: String,
                        accent: Color, on: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 22, weight: .bold))
                .foregroundStyle(on).frame(width: 52, height: 52)
                .background(accent).clipShape(RoundedRectangle(cornerRadius: Radius.control))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.heading).foregroundStyle(Color.textPrimary)
                Text(blurb).font(.body14).foregroundStyle(Color.textMuted)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(Color.textMuted)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).cardSurface()
    }

    private var signInPrompt: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "lock.fill").font(.system(size: 40)).foregroundStyle(Color.textMuted)
            Text("Sign in to create").font(.title).foregroundStyle(Color.textPrimary)
            Text("Community puzzles are tied to your account so others know who made them.")
                .font(.body14).foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
