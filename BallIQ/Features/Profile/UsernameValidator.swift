import Foundation

/// Client-side username rules for `profiles.username` (server also enforces the UNIQUE
/// constraint — this only catches shape problems before a round trip). Pure + stateless so
/// it's unit-testable without touching `RepositoryContainer`.
enum UsernameValidationError: Error, Equatable {
    case tooShort
    case tooLong
    case invalidCharacters
    case mustStartWithLetter

    /// Inline hint shown under the TextField.
    var message: String {
        switch self {
        case .tooShort: return "At least 3 characters."
        case .tooLong: return "20 characters or fewer."
        case .invalidCharacters: return "Letters, numbers, and underscores only."
        case .mustStartWithLetter: return "Must start with a letter."
        }
    }
}

enum UsernameValidator {
    static let minLength = 3
    static let maxLength = 20

    /// Trims whitespace and lowercases before checking shape, so "  Xander_10  " and
    /// "xander_10" validate identically — the sheet fills the field with `.get`'s
    /// normalized value so what's saved matches what's shown as valid.
    static func validate(_ raw: String) -> Result<String, UsernameValidationError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard trimmed.count >= minLength else { return .failure(.tooShort) }
        guard trimmed.count <= maxLength else { return .failure(.tooLong) }

        guard let first = trimmed.first, first.isASCII, first.isLetter else {
            return .failure(.mustStartWithLetter)
        }

        let allowed = trimmed.allSatisfy { char in
            (char.isASCII && char.isLetter) || (char.isASCII && char.isNumber) || char == "_"
        }
        guard allowed else { return .failure(.invalidCharacters) }

        return .success(trimmed)
    }
}
