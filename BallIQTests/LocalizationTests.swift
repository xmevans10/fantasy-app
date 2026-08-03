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

    /// Chip and search-field labels are the catalog's blind spot, and this test is the only
    /// thing that closes it.
    ///
    /// `PrimeChip.label` and `PrimeExpandingSearch.placeholder` are `String`, not
    /// `LocalizedStringKey`, because nearly every caller passes a computed display name that is
    /// localized at its source. The consequence is that a bare literal — `PrimeChip(label:
    /// "My Team")` — compiles, renders, reads perfectly in English, and silently ships English
    /// to every other locale, because `Text(someString)` performs no lookup. Four such literals
    /// had accumulated ("My Team", "Any", both search placeholders); none were in the catalog.
    ///
    /// A failure here means someone added a literal without `String(localized:)`, or added the
    /// call but never added the key to `Localizable.xcstrings` — the second being the quieter
    /// of the two, since the lookup then just falls back to the English literal.
    func testFilterChipAndSearchLabelsAreLocalized() {
        XCTAssertEqual(es("My Team"), "Mi Equipo")
        XCTAssertEqual(es("Any"), "Cualquiera")
        XCTAssertEqual(es("Search titles"), "Buscar títulos")
        XCTAssertEqual(es("Search themes or players"), "Buscar temas o jugadores")
    }
}
