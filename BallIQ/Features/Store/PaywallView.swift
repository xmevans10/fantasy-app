import SwiftUI
import StoreKit

/// The one paywall every locked touchpoint routes through (hard mode, archive, all-sport
/// filter, The Grid, unlimited Over/Under lives). Reads `RepositoryContainer.products`/
/// `purchase(_:)` directly — no parallel store, per the repository-seam constraint.
struct PaywallView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @Environment(\.dismiss) private var dismiss
    @State private var purchasingID: String?
    @State private var errorMessage: String?

    private var subscriptions: [Product] {
        container.products
            .filter { StoreProduct(rawValue: $0.id)?.isSubscription == true }
            .sorted { $0.price < $1.price }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    hero.heroReveal(0)
                    benefits.heroReveal(1)
                    plans.heroReveal(2)
                    restoreButton.heroReveal(3)
                }
                .padding(16)
            }
            .background(Color.appBackground)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .alert("Purchase failed", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 8) {
            Image(systemName: "crown.fill")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(Color.onPro)
                .frame(width: 84, height: 84)
                .background(Color.proFill)
                .clipShape(Circle())
            Text("PLAYBOOK PRO")
                .font(.display1)
                .foregroundStyle(Color.textPrimary)
            Text("Unlock every format, every sport, every day.")
                .font(.body14)
                .foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 12) {
            benefitRow(symbol: "square.grid.3x3.fill", text: "The Grid — Pro-only format")
            benefitRow(symbol: "eye.slash", text: "Hard mode on every Keep4/Cut4")
            benefitRow(symbol: "square.grid.2x2.fill", text: "Full archive — replay every past daily")
            benefitRow(symbol: "sportscourt.fill", text: "All 5 sports on the daily filter")
            benefitRow(symbol: "infinity", text: "Unlimited Over/Under lives")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func benefitRow(symbol: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.proText)
                .frame(width: 20)
            Text(text).font(.body14).foregroundStyle(Color.textPrimary)
        }
    }

    private var plans: some View {
        VStack(spacing: 10) {
            if subscriptions.isEmpty {
                Text(container.isLoadingProducts ? "Loading plans…" : "Plans unavailable right now.")
                    .font(.body14)
                    .foregroundStyle(Color.textMuted)
                    .padding(.vertical, 8)
            }
            ForEach(subscriptions, id: \.id) { product in
                Button {
                    Task { await buy(product) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(product.displayName.uppercased()).font(.heading)
                            Text(product.displayPrice).font(.label12).opacity(0.85)
                        }
                        Spacer()
                        if purchasingID == product.id {
                            ProgressView().tint(Color.onAccent)
                        }
                    }
                    .ctaLabel()
                }
                .buttonStyle(PrimePressStyle())
                .disabled(purchasingID != nil)
                .accessibilityLabel("\(product.displayName), \(product.displayPrice)")
            }
        }
    }

    private var restoreButton: some View {
        Button {
            Task { await container.restorePurchases() }
        } label: {
            Text("RESTORE PURCHASES")
                .font(.label12)
                .foregroundStyle(Color.accentText)
        }
        .buttonStyle(.plain)
        .disabled(purchasingID != nil)
    }

    private func buy(_ product: Product) async {
        purchasingID = product.id
        defer { purchasingID = nil }
        do {
            _ = try await container.purchase(product)
        } catch {
            errorMessage = "Something went wrong. Please try again."
        }
    }
}

#Preview {
    PaywallView().environmentObject(RepositoryContainer.make())
}
