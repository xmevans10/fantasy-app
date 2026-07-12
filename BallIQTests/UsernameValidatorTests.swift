import XCTest
@testable import BallIQ

/// Client-side shape rules for `profiles.username` — the server's UNIQUE constraint is the
/// real source of truth (surfaced as a 409 elsewhere), this only covers the pure shape checks.
final class UsernameValidatorTests: XCTestCase {

    func testValidNamePasses() {
        switch UsernameValidator.validate("xander10") {
        case .success(let value): XCTAssertEqual(value, "xander10")
        case .failure(let error): XCTFail("expected success, got \(error)")
        }
    }

    func testTooShortFails() {
        XCTAssertEqual(UsernameValidator.validate("ab"), .failure(.tooShort))
    }

    func testTooLongFails() {
        let name = String(repeating: "a", count: 21)
        XCTAssertEqual(UsernameValidator.validate(name), .failure(.tooLong))
    }

    func testBadCharactersFail() {
        XCTAssertEqual(UsernameValidator.validate("xander-evans"), .failure(.invalidCharacters))
        XCTAssertEqual(UsernameValidator.validate("xander!"), .failure(.invalidCharacters))
        XCTAssertEqual(UsernameValidator.validate("xander evans"), .failure(.invalidCharacters))
    }

    func testLeadingDigitFails() {
        XCTAssertEqual(UsernameValidator.validate("10xander"), .failure(.mustStartWithLetter))
    }

    func testLeadingUnderscoreFails() {
        XCTAssertEqual(UsernameValidator.validate("_xander"), .failure(.mustStartWithLetter))
    }

    func testUppercaseInputIsLowercased() {
        switch UsernameValidator.validate("Xander10") {
        case .success(let value): XCTAssertEqual(value, "xander10")
        case .failure(let error): XCTFail("expected success, got \(error)")
        }
    }

    func testWhitespaceIsTrimmed() {
        switch UsernameValidator.validate("  xander10  ") {
        case .success(let value): XCTAssertEqual(value, "xander10")
        case .failure(let error): XCTFail("expected success, got \(error)")
        }
    }

    func testMinimumLengthBoundaryPasses() {
        switch UsernameValidator.validate("abc") {
        case .success(let value): XCTAssertEqual(value, "abc")
        case .failure(let error): XCTFail("expected success, got \(error)")
        }
    }

    func testMaximumLengthBoundaryPasses() {
        let name = "a" + String(repeating: "b", count: 19) // 20 chars total
        switch UsernameValidator.validate(name) {
        case .success(let value): XCTAssertEqual(value, name)
        case .failure(let error): XCTFail("expected success, got \(error)")
        }
    }
}
