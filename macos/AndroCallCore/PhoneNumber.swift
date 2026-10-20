import Foundation

/// Dial-pad input handling and phone-number sanitisation (PROTOCOL.md §5).
///
/// The **phone** is authoritative for normalisation; the Mac only sanitises
/// what the user typed so that the value it sends is always something the
/// phone can interpret.
public enum PhoneNumberSanitizer {

    /// Characters the dial pad allows: digits, `*`, `#`, `+` and a pause/wait
    /// marker produced by a long press.
    public static let allowedCharacters: Set<Character> = {
        var set = Set<Character>("0123456789*#+")
        set.insert(",")
        set.insert(";")
        return set
    }()

    /// Strip the characters that humans add for readability.
    ///
    /// * whitespace (including non-breaking and narrow no-break spaces)
    /// * `-`, `(`, `)`, `.`
    ///
    /// A leading `+` is preserved because it means an international number, and
    /// a leading `00` international prefix is rewritten to `+`.
    public static func sanitize(_ input: String) -> String {
        var cleaned = ""
        cleaned.reserveCapacity(input.count)
        for character in input {
            if character.isWhitespace || character == "-" || character == "("
                || character == ")" || character == "." || character == "\u{00A0}"
                || character == "\u{202F}" {
                continue
            }
            cleaned.append(character)
        }
        if cleaned.hasPrefix("00") {
            cleaned = "+" + String(cleaned.dropFirst(2))
        }
        return cleaned
    }

    /// Whether the sanitised number is plausibly dialable.
    ///
    /// The Mac refuses to offer a dial action for input that the phone would
    /// certainly reject, but the phone remains the final authority.
    public static func isDialable(_ input: String) -> Bool {
        let sanitized = sanitize(input)
        guard !sanitized.isEmpty else { return false }
        var digits = 0
        for character in sanitized {
            if character.isNumber {
                digits += 1
            } else if !"*#+;,".contains(character) {
                return false
            }
        }
        return digits > 0
    }

    /// Filter a dial-pad string to the characters the pad allows.
    public static func filterDialPad(_ input: String) -> String {
        String(input.filter { allowedCharacters.contains($0) })
    }
}

/// Formats a duration in milliseconds for the active-call screen.
public enum DurationFormatter {
    public static func string(milliseconds: Int64) -> String {
        let totalSeconds = max(0, milliseconds / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
