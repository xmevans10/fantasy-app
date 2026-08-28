import XCTest
@testable import BallIQ

/// Pins the two rules `UpdateNotes` documents, so breaking either fails the build instead of
/// shipping. Both are cheap to violate by accident — a message grows one clause at a time, and
/// artwork goes missing the moment a slide is added without regenerating.
@MainActor
final class UpdateNotesTests: XCTestCase {

    private var allSlides: [(version: String, slide: UpdateNotes.Slide)] {
        UpdateNotes.byVersion.flatMap { version, slides in slides.map { (version, $0) } }
    }

    /// Rule 2: one short line per slide.
    func testEveryMessageFitsTheLimit() {
        for (version, slide) in allSlides {
            XCTAssertLessThanOrEqual(
                slide.message.count, UpdateNotes.messageLimit,
                "\(version)/\(slide.artwork): \(slide.message.count) chars, the cap is \(UpdateNotes.messageLimit)")
            XCTAssertFalse(slide.message.isEmpty, "\(version)/\(slide.artwork) has no message")
        }
    }

    /// A message that wraps to a paragraph defeats the point even under the character cap.
    func testMessagesAreASingleLine() {
        for (version, slide) in allSlides {
            XCTAssertFalse(slide.message.contains("\n"), "\(version)/\(slide.artwork) is multi-line")
        }
    }

    /// Rule 1's mechanical half: the artwork a slide names has to actually be in the bundle.
    /// `noteletNotes` drops a slide whose art is missing, so without this a typo would silently
    /// ship one fewer slide rather than failing anywhere.
    func testEverySlideResolvesItsArtwork() {
        for (version, slide) in allSlides {
            XCTAssertNotNil(UpdateNotes.artworkURL(slide),
                            "\(version): \(slide.artwork).png is not in the bundle, regenerate "
                            + "with OPMSlideGalleryTests and copy it into BallIQ/Resources/OPM/")
        }
    }

    /// Nothing is dropped on the way into Notelet's model — i.e. the count the player sees is the
    /// count declared here.
    func testEveryDeclaredSlideSurvivesTheBridge() {
        let bridged = UpdateNotes.noteletNotes
        for (version, slides) in UpdateNotes.byVersion {
            let notes = bridged.first { $0.version == version }
            XCTAssertNotNil(notes, "\(version) missing from noteletNotes")
            XCTAssertEqual(notes?.items.count, slides.count,
                           "\(version): \(slides.count) slides declared, \(notes?.items.count ?? 0) bridged")
        }
    }

    /// The version keys are matched against `CFBundleShortVersionString` by Notelet, so a key
    /// that isn't a real marketing version can never fire. Catches "1.8" or "v1.8.0" typos.
    func testVersionKeysLookLikeMarketingVersions() {
        for version in UpdateNotes.byVersion.keys {
            XCTAssertNotNil(version.range(of: #"^\d+\.\d+(\.\d+)?$"#, options: .regularExpression),
                            "\(version) is not a marketing version string")
        }
    }

    /// The release being shipped has notes. Guards the specific way this surface fails silently:
    /// everything is wired, the sheet is attached, and nothing appears because nobody added the
    /// entry for the new version.
    func testCurrentBundleVersionHasNotes() throws {
        let current = try XCTUnwrap(
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        XCTAssertNotNil(UpdateNotes.byVersion[current],
                        "no update notes for \(current), add them to UpdateNotes.byVersion, or "
                        + "delete this expectation if the release is deliberately silent")
    }
}
