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

    /// Which gate sent the user here, logged with `paywallViewed`. Defaults to `.other` so an
    /// un-updated call site degrades to an honest "unknown" bucket rather than silently
    /// attributing itself to whatever surface happens to be listed first.
    var trigger: PaywallTrigger = .other

    /// App Store guideline 3.1.2(c) requires functional Terms of Use (EULA) + Privacy Policy
    /// links inside the subscription purchase flow. Apple's standard EULA (the app ships no
    /// custom terms) + our GitHub Pages privacy page.
    private static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    private static let privacyURL = URL(string: "https://xmevans10.github.io/fantasy-app/privacy.html")!

    private var subscriptions: [Product] {
        container.products
            .filter { StoreProduct(rawValue: $0.id)?.isSubscription == true }
            .sorted { $0.price < $1.price }
    }

    /// One-time format unlocks (Draft & Spin, The Grid) — hidden once owned, and for Pro
    /// (whose subscription already covers every format).
    private var packs: [Product] {
        guard !container.entitlements.isPro else { return [] }
        return container.products
            .filter { StoreProduct(rawValue: $0.id)?.isSubscription == false }
            .filter { !container.entitlements.unlockedPacks.contains($0.id) }
            .sorted { $0.price < $1.price }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    hero.heroReveal(0)
                    benefits.heroReveal(1)
                    plans.heroReveal(2)
                    packSection.heroReveal(3)
                    restoreButton.heroReveal(4)
                    legalFooter.heroReveal(5)
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
            // `.task` rather than `.onAppear`: this view is presented in a `.sheet`, and
            // onAppear re-fires when the sheet returns to front (e.g. after Apple's purchase
            // sheet dismisses), which would double-count a single visit and inflate the top
            // of the funnel against the attempts below it.
            .task {
                container.track(.paywallViewed, ["trigger": trigger.rawValue])
                // Never trust the single launch-time fetch. If it lost a cold-start race the
                // catalog is empty and every plan row is missing — which is precisely how
                // 1.3 build 16 was rejected under Guideline 2.1(a). Opening the paywall is the
                // exact moment the products are needed, so re-fetch here when we have none.
                if container.products.isEmpty { await container.reloadProducts() }
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

    private func benefitRow(symbol: String, text: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.proText)
                .frame(width: 20)
            Text(text).font(.body14).foregroundStyle(Color.textPrimary)
        }
    }

    /// `.loaded` with nothing to show is not a connection problem — it's the store answering
    /// with an empty catalog (products still propagating through App Store Connect, or
    /// unavailable in this storefront). Saying "check your connection" there sends the user off
    /// to fix something that isn't broken.
    private var emptyStateMessage: LocalizedStringKey {
        switch container.productLoadState {
        case .idle, .loading:
            return "Loading plans…"
        case .failed:
            return "Couldn't reach the App Store. Check your connection and try again."
        case .loaded:
            return "Plans aren't available in your region right now."
        }
    }

    private var plans: some View {
        VStack(spacing: 10) {
            if subscriptions.isEmpty {
                // A dead-end string was the whole failure mode here: no plans, no explanation,
                // no way to try again. Give the state an action, so a transient store hiccup
                // costs a tap instead of the entire session.
                //
                // Branch on `productLoadState`, not on a loading boolean. The boolean version
                // read `false` before the first fetch had even been attempted, so the *first
                // frame* a reviewer saw was "Couldn't reach the App Store" — an error reporting
                // a request nobody had made yet. `.idle` and `.loading` are both "wait", and
                // only `.failed` earns the retry affordance.
                VStack(spacing: 10) {
                    Text(emptyStateMessage)
                        .font(.body14)
                        .foregroundStyle(Color.textMuted)
                        .multilineTextAlignment(.center)
                    if container.productLoadState == .failed {
                        Button("Try again") {
                            Task { await container.reloadProducts() }
                        }
                        .font(.custom(FontName.condBold, size: 15))
                        .foregroundStyle(Color.accentText)
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
            }
            ForEach(subscriptions, id: \.id) { product in
                Button {
                    Task { await buy(product) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(product.displayName.uppercased()).font(.heading)
                            Text(priceLine(for: product)).font(.label12).opacity(0.85)
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

    @ViewBuilder
    private var packSection: some View {
        if !packs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Just want one format? Unlock it forever.")
                    .font(.label12)
                    .foregroundStyle(Color.textMuted)
                ForEach(packs, id: \.id) { product in
                    Button {
                        Task { await buy(product) }
                    } label: {
                        HStack {
                            Text(product.displayName.uppercased())
                                .font(.heading)
                                .foregroundStyle(Color.textPrimary)
                            Spacer()
                            if purchasingID == product.id {
                                ProgressView().tint(Color.textPrimary)
                            } else {
                                Text(product.displayPrice)
                                    .font(.label12)
                                    .foregroundStyle(Color.proText)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(PrimePressStyle())
                    .disabled(purchasingID != nil)
                    .accessibilityLabel("\(product.displayName), \(product.displayPrice)")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
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

    /// Legal disclosures required for auto-renewable subscriptions (App Store 3.1.2(c)):
    /// renewal terms plus functional Terms of Use (EULA) + Privacy Policy links.
    private var legalFooter: some View {
        VStack(spacing: 10) {
            Text("Subscriptions renew automatically unless canceled at least 24 hours before the end of the period. Your Apple Account is charged at confirmation of purchase. Manage or cancel anytime in Settings › Apple Account.")
                .font(.label12)
                .foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Link("Terms of Use (EULA)", destination: Self.termsURL)
                Text("·").foregroundStyle(Color.textMuted)
                Link("Privacy Policy", destination: Self.privacyURL)
            }
            .font(.label12)
            .tint(Color.accentText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    /// Price plus the billing period, so "length of subscription" is explicit
    /// (App Store 3.1.2(c)) — e.g. "$4.99 / month".
    private func priceLine(for product: Product) -> String {
        guard let period = periodText(for: product) else { return product.displayPrice }
        return "\(product.displayPrice) / \(period)"
    }

    private func periodText(for product: Product) -> String? {
        guard let unit = product.subscription?.subscriptionPeriod.unit else { return nil }
        switch unit {
        case .day: return String(localized: "day")
        case .week: return String(localized: "week")
        case .month: return String(localized: "month")
        case .year: return String(localized: "year")
        @unknown default: return nil
        }
    }

    private func buy(_ product: Product) async {
        purchasingID = product.id
        defer { purchasingID = nil }
        container.track(.purchaseAttempted, ["product_id": product.id, "trigger": trigger.rawValue])
        do {
            // `purchase` returns false without throwing when StoreKit came back with no
            // transaction — overwhelmingly the user dismissing Apple's sheet. That's a
            // different signal from a thrown error (intent vs bug), so they're logged apart
            // rather than both collapsing into "no sale".
            let purchased = try await container.purchase(product)
            if !purchased {
                container.track(.purchaseFailed,
                                Self.failureProperties(productID: product.id, trigger: trigger, error: nil))
            }
        } catch {
            container.track(.purchaseFailed,
                            Self.failureProperties(productID: product.id, trigger: trigger, error: error))
            errorMessage = String(localized: "Something went wrong. Please try again.")
        }
    }

    /// The `purchase_failed` payload, split out pure so the `reason` strings — which SQL
    /// groups by, same stable-schema rule as the event names — are testable without a
    /// StoreKit `Product` (which a unit test can't construct). `error == nil` is the
    /// no-transaction return, i.e. the user backed out; a thrown error is a real failure.
    nonisolated static func failureProperties(productID: String, trigger: PaywallTrigger,
                                              error: Error?) -> [String: String] {
        ["product_id": productID,
         "trigger": trigger.rawValue,
         "reason": error == nil ? "cancelled" : "error"]
    }
}

#Preview {
    PaywallView().environmentObject(RepositoryContainer.make())
}
