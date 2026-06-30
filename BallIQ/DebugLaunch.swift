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
    #else
    static let autoOpenGame = false
    static let autoOpenWhoAmI = false
    static let autoSubmitResult = false
    static let autoOpenCreateKeep4 = false
    #endif
}
