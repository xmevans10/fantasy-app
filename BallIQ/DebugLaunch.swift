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
    /// `-autoSubmit` alone works with `-openURL` (deep-linked game → result) without also
    /// auto-opening the daily the way `-screenshotResult` does.
    static var autoSubmitResult: Bool {
        has("-screenshotResult") || has("-screenshotWhoAmIResult") || has("-autoSubmit")
    }
    static var autoOpenCreateKeep4: Bool { has("-screenshotCreate") }
    static var autoOpenStats: Bool { has("-screenshotStats") }
    static var autoOpenProfile: Bool { has("-screenshotProfile") }
    static var autoOpenLeagues: Bool { has("-screenshotLeagues") }
    static var autoOpenVersus: Bool { has("-screenshotVersus") }
    static var autoOpenCommunity: Bool { has("-screenshotCommunity") }
    static var autoOpenBrowse: Bool { has("-screenshotBrowse") }
    static var autoOpenModeration: Bool { has("-screenshotModeration") }
    static var autoOpenPaywall: Bool { has("-screenshotPaywall") }
    static var autoOpenOverUnder: Bool { has("-screenshotOverUnder") || has("-screenshotOverUnderResult") }
    /// Forces an immediate out-of-lives finish once the session loads (simctl can't play a real
    /// round-by-round session): `-screenshotOverUnderResult`.
    static var autoSubmitOverUnder: Bool { has("-screenshotOverUnderResult") }
    static var autoOpenDraftSpin: Bool { has("-screenshotDraftSpin") || has("-screenshotDraftSpinResult") }
    /// Auto-picks the first candidate in every slot (simctl can't tap through the draft board).
    static var autoSubmitDraftSpin: Bool { has("-screenshotDraftSpinResult") }
    static var autoOpenGrid: Bool { has("-screenshotGrid") || has("-screenshotGridResult") }
    /// Auto-answers every cell with its first valid answer (simctl can't type into the guess field).
    static var autoSubmitGrid: Bool { has("-screenshotGridResult") }
    /// Browse: auto-open the pre-play share sheet for the first archive puzzle.
    static var autoOpenShare: Bool { has("-screenshotShare") }
    /// Keep4 game: auto-open the scoring-formula sheet (simctl can't tap the chip).
    static var autoOpenScoringInfo: Bool { has("-screenshotScoringInfo") }
    /// Prefill the Browse search field (simctl can't type): `-searchQuery lamb`.
    static var searchQuery: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-searchQuery"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    /// Preselect Browse's sport dropdown (simctl can't tap it): `-browseSport soccer`.
    static var browseSport: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-browseSport"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    /// Auto-apply a Create-flow theme template by key (simctl can't tap chips):
    /// `-screenshotCreateTheme nba-career-fantasy`.
    static var createTemplateKey: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screenshotCreateTheme"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    /// Override Draft & Spin's date-seeded sport-of-the-day (simctl can't wait for a lucky
    /// date to test a specific sport's season shape/outcome titles): `-draftSpinSport soccer`.
    static var draftSpinSport: Sport? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-draftSpinSport"), i + 1 < args.count else { return nil }
        return Sport(rawValue: args[i + 1])
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
    static let autoOpenProfile = false
    static let autoOpenLeagues = false
    static let autoOpenVersus = false
    static let autoOpenCommunity = false
    static let autoOpenBrowse = false
    static let autoOpenModeration = false
    static let autoOpenPaywall = false
    static let autoOpenOverUnder = false
    static let autoSubmitOverUnder = false
    static let autoOpenDraftSpin = false
    static let autoSubmitDraftSpin = false
    static let autoOpenGrid = false
    static let autoSubmitGrid = false
    static let autoOpenShare = false
    static let autoOpenScoringInfo = false
    static let searchQuery: String? = nil
    static let browseSport: String? = nil
    static let createTemplateKey: String? = nil
    static let openURL: URL? = nil
    static let draftSpinSport: Sport? = nil
    #endif
}
