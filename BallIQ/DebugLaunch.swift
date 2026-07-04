import Foundation

/// Launch-argument hooks used only for automated UI verification (screenshots).
/// Compiled out of release builds.
enum DebugLaunch {
    #if DEBUG
    private static func has(_ arg: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(arg)
    }
    static var autoOpenGame: Bool { has("-screenshotGame") || has("-screenshotResult") }
    static var autoOpenWhoAmI: Bool { has("-screenshotWhoAmI") || has("-screenshotWhoAmIResult") }
    static var autoSubmitResult: Bool { has("-screenshotResult") || has("-screenshotWhoAmIResult") }
    static var autoOpenCreateKeep4: Bool { has("-screenshotCreate") }
    static var autoOpenStats: Bool { has("-screenshotStats") }
    static var autoOpenLeagues: Bool { has("-screenshotLeagues") }
    static var autoOpenVersus: Bool { has("-screenshotVersus") }
    static var autoOpenCommunity: Bool { has("-screenshotCommunity") }
    static var autoOpenBrowse: Bool { has("-screenshotBrowse") }
    static var autoOpenModeration: Bool { has("-screenshotModeration") }
    /// Browse: auto-open the pre-play share sheet for the first archive puzzle.
    static var autoOpenShare: Bool { has("-screenshotShare") }
    /// Prefill the Browse search field (simctl can't type): `-searchQuery lamb`.
    static var searchQuery: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-searchQuery"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    /// Auto-apply a Create-flow theme template by key (simctl can't tap chips):
    /// `-screenshotCreateTheme nba-career-fantasy`.
    static var createTemplateKey: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screenshotCreateTheme"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    /// Feed a deep link straight to `ContentView.handle` (bypasses SpringBoard's
    /// "Open in …?" confirm, which automated runs can't tap): `-openURL balliq://play/<id>`.
    static var openURL: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-openURL"), i + 1 < args.count else { return nil }
        return URL(string: args[i + 1])
    }
    #else
    static let autoOpenGame = false
    static let autoOpenWhoAmI = false
    static let autoSubmitResult = false
    static let autoOpenCreateKeep4 = false
    static let autoOpenStats = false
    static let autoOpenLeagues = false
    static let autoOpenVersus = false
    static let autoOpenCommunity = false
    static let autoOpenBrowse = false
    static let autoOpenModeration = false
    static let autoOpenShare = false
    static let searchQuery: String? = nil
    static let createTemplateKey: String? = nil
    static let openURL: URL? = nil
    #endif
}
