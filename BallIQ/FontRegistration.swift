import CoreText
import Foundation

/// Registers the bundled OFL fonts (Anton, Saira) at launch so `Font.custom(...)` can find them.
/// Runtime registration avoids needing `UIAppFonts` in a generated Info.plist.
enum FontRegistration {
    static func registerAll() {
        var urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        if urls.isEmpty {
            urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        }
        for url in urls {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                #if DEBUG
                print("Font registration failed for \(url.lastPathComponent): \(String(describing: error))")
                #endif
            }
        }
    }
}
