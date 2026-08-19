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
        XCTAssertEqual(es("THE PATH"), "LA TRAYECTORIA")
        XCTAssertEqual(es("KEEP"), "MANTENER")
        XCTAssertEqual(es("CUT"), "CORTAR")
    }

    /// Branded format names are a deliberate exception (see Localizable.xcstrings'
    /// `shouldTranslate: false` entries) — they must render identically in every locale.
    /// They're absent from the compiled es.lproj, so lookup falls back to the key itself.
    func testBrandedFormatNamesStayEnglish() {
        XCTAssertEqual(es("K4C4"), "K4C4")
        XCTAssertEqual(es("THE GRID"), "THE GRID")
        XCTAssertEqual(es("Journeyman"), "Journeyman")
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

    /// Every user-facing string the Moments feature adds (`MomentCopy` in MomentSheet.swift,
    /// the `SharePreview` title, and the moment CTAs) must resolve to Spanish.
    ///
    /// This is the same quiet failure mode `testFilterChipAndSearchLabelsAreLocalized`
    /// documents: these keys were written with `String(localized:)` / `LocalizedStringKey`
    /// from day one, but were never added to `Localizable.xcstrings` — so a Spanish user was
    /// silently shown the English literal. Each assertion below checks the *Spanish* value,
    /// never key fallback, so a missing entry fails loudly.
    ///
    /// Interpolated details carry their `String(format:)` specifiers (`%lld` for Int,
    /// `%@` for String), matching the catalog's positional form — the lookup key is the
    /// template, and `es(_:)` returns it as stored in es.lproj.
    func testMomentStringsAreLocalized() {
        XCTAssertEqual(es("LOCK IN YOUR NAME"), "ASEGURA TU NOMBRE")
        XCTAssertEqual(es("WHO DO YOU RIDE WITH?"), "¿CON QUIÉN VAS?")
        XCTAssertEqual(es("BETTER WITH A RIVAL"), "MEJOR CON UN RIVAL")
        XCTAssertEqual(es("CLAIM MY USERNAME"), "RECLAMAR MI NOMBRE DE USUARIO")
        XCTAssertEqual(es("PICK MY TEAM"), "ELEGIR MI EQUIPO")
        XCTAssertEqual(es("ADD A FRIEND"), "AGREGAR UN AMIGO")
        XCTAssertEqual(es("CREATE MY ACCOUNT"), "CREAR MI CUENTA")
        XCTAssertEqual(es("My Playbook profile"), "Mi perfil de Playbook")
        XCTAssertEqual(es("You've played %lld. Time everyone knew who did it — your name shows up on leaderboards, Versus and friend requests."), "Has jugado %lld. Es hora de que todos sepan quién lo hizo — tu nombre aparece en las tablas de posiciones, Versus y solicitudes de amistad.")
        XCTAssertEqual(es("Your name shows up on leaderboards, Versus and friend requests."), "Tu nombre aparece en las tablas de posiciones, Versus y solicitudes de amistad.")
        XCTAssertEqual(es("Your streak, rating and league spot live on your account — and a username is how anyone finds you."), "Tu racha, puntaje y puesto en la liga viven en tu cuenta — y un nombre de usuario es como cualquiera te encuentra.")
        XCTAssertEqual(es("%lld %@ rounds in. Pick your team and we'll flag every puzzle that features them."), "Llevas %lld rondas de %@. Elige tu equipo y marcaremos cada acertijo que lo presente.")
        XCTAssertEqual(es("A %lld-day streak and nobody to beat. Add a friend and every daily becomes a head-to-head."), "Una racha de %lld días y nadie a quien vencer. Agrega un amigo y cada diario se convierte en un duelo.")
        XCTAssertEqual(es("You've played %lld and nobody's chasing you. Add a friend and every daily becomes a head-to-head."), "Has jugado %lld y nadie te pisa los talones. Agrega un amigo y cada diario se convierte en un duelo.")
    }

    /// Two days of bot-character work (the ladder's reaction bubbles, the rematch action, the
    /// Roster screen, `BotCharacterCard`) added dozens of `String(localized:)` calls that never
    /// made it into the catalog — the same quiet failure the two tests above guard against, just
    /// for a newer feature area. The Task 5.1 catalog sync (`xcodebuild -exportLocalizations` /
    /// `-importLocalizations`) added them with no Spanish translation yet, which is the
    /// documented, acceptable state (English fallback) — but they must land as their own
    /// standalone key, not silently merge into or get shadowed by an existing translated entry.
    /// `es(_:)` returning the bare key (rather than someone else's Spanish string) is exactly
    /// `testBrandedFormatNamesStayEnglish`'s check, aimed at the two keys most likely to catch a
    /// regression if the next sync mis-imports: `REMATCH` (the shared result-screen action added
    /// in the same push) and the Roster silhouette's `Rung %lld unlocks` (format-specifier key —
    /// a bad re-sync reordering or dropping `%lld` would still pass a same-key check like this
    /// one only if the specifier survives verbatim).
    func testBotCharacterAndRosterKeysAreInCatalog() {
        XCTAssertEqual(es("REMATCH"), "REMATCH")
        XCTAssertEqual(es("Rung %lld unlocks"), "Rung %lld unlocks")
    }
}
