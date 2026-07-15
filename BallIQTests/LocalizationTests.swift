import XCTest
@testable import BallIQ

/// Smoke test for `Localizable.xcstrings` (M14 backlog #10): confirms the catalog actually
/// compiles into the app bundle and resolves Spanish values, not just that the JSON file
/// exists on disk. Hosted unit tests run inside the BallIQ.app process, so `Bundle.main`
/// here is the real app bundle carrying the compiled `es.lproj/Localizable.strings`.
///
/// Lookup goes through the `es.lproj` sub-bundle directly — `String(localized:locale:)`'s
/// `locale` parameter only affects interpolation formatting, not which localization the
/// bundle picks (that follows the process language), so it can't test Spanish from an
/// English-running test host.
final class LocalizationTests: XCTestCase {

    private var spanish: Bundle {
        guard let path = Bundle.main.path(forResource: "es", ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            XCTFail("es.lproj missing from app bundle — Localizable.xcstrings didn't compile")
            return .main
        }
        return bundle
    }

    private func es(_ key: String) -> String {
        spanish.localizedString(forKey: key, value: nil, table: "Localizable")
    }

    func testKnownKeyResolvesToSpanish() {
        XCTAssertEqual(es("Home"), "Inicio")
        XCTAssertEqual(es("KEEP"), "MANTENER")
        XCTAssertEqual(es("CUT"), "CORTAR")
    }

    /// Branded format names are a deliberate exception (see Localizable.xcstrings'
    /// `shouldTranslate: false` entries) — they must render identically in every locale.
    /// They're absent from the compiled es.lproj, so lookup falls back to the key itself.
    func testBrandedFormatNamesStayEnglish() {
        XCTAssertEqual(es("K4C4"), "K4C4")
        XCTAssertEqual(es("THE GRID"), "THE GRID")
    }

    /// Every key in the catalog is its own English source string (verified: no `en`
    /// stringUnit differs from its key), so English resolution is key fallback and needs
    /// no en.lproj. This guards the catalog against a key drifting from its English text.
    func testKnownKeyResolvesToEnglishByDefault() {
        XCTAssertEqual(String(localized: "Home", bundle: .main), "Home")
    }
}
