import Foundation

/// Supabase connection config, loaded from a gitignored `Supabase.plist` in the app bundle.
/// The anon key is public (Row Level Security is the real guard) but kept out of source control.
/// When the plist is absent or blank, `isConfigured` is false and the app runs local-only.
///
/// To enable the backend: copy `Supabase.example.plist` → `Supabase.plist`, fill in your project
/// URL and anon key. NEVER put the `service_role` key here.
struct SupabaseConfig {
    let url: URL
    let anonKey: String

    static let shared: SupabaseConfig? = load()

    static var isConfigured: Bool { shared != nil }

    private static func load() -> SupabaseConfig? {
        guard let plistURL = Bundle.main.url(forResource: "Supabase", withExtension: "plist"),
              let data = try? Data(contentsOf: plistURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let urlString = dict["SUPABASE_URL"] as? String, isFilled(urlString),
              let anonKey = dict["SUPABASE_ANON_KEY"] as? String, isFilled(anonKey),
              let url = URL(string: urlString) else {
            return nil
        }
        return SupabaseConfig(url: url, anonKey: anonKey)
    }

    /// True only when a value is present and not the placeholder text from the template.
    private static func isFilled(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("YOUR-")
    }
}
