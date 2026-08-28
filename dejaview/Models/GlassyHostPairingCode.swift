import Foundation

/// A first-use pairing code displayed by the Glassy Host companion app.
///
/// The host generates twelve symbols and groups them for readability as
/// `XXXX-XXXX-XXXX`. The formatted value is fourteen characters because the
/// two hyphens are separators, not part of the pairing code.
struct GlassyHostPairingCode: Equatable, Hashable, Sendable {
    static let symbolCount = 12

    /// The twelve uppercase pairing symbols, without separators.
    let rawValue: String

    init?(_ input: String) {
        guard let normalizedValue = Self.normalizedValue(for: input) else {
            return nil
        }

        rawValue = normalizedValue
    }

    /// The human-readable representation used by Glassy Host.
    var formattedValue: String {
        stride(from: 0, to: Self.symbolCount, by: 4)
            .map { offset in
                let start = rawValue.index(rawValue.startIndex, offsetBy: offset)
                let end = rawValue.index(start, offsetBy: 4)
                return String(rawValue[start..<end])
            }
            .joined(separator: "-")
    }

    static func isValid(_ input: String) -> Bool {
        normalizedValue(for: input) != nil
    }

    private static func normalizedValue(for input: String) -> String? {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String

        switch trimmedInput.count {
        case symbolCount:
            candidate = trimmedInput

        case symbolCount + 2:
            let characters = Array(trimmedInput)
            guard characters[4] == "-", characters[9] == "-" else {
                return nil
            }
            candidate = String(characters[0..<4]
                + characters[5..<9]
                + characters[10..<14])

        default:
            return nil
        }

        let normalizedValue = candidate.uppercased()
        guard normalizedValue.count == symbolCount,
              normalizedValue.unicodeScalars.allSatisfy(Self.validSymbols.contains) else {
            return nil
        }

        return normalizedValue
    }

    private static let validSymbols = CharacterSet(
        charactersIn: "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    )
}
