import Foundation

nonisolated enum LogSanitizer {
    static func redactedSnippet(from text: String, limit: Int = 300) -> String {
        let normalized =
            text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")

        let patterns: [(pattern: String, replacement: String)] = [
            (
                #"(?i)(\"(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|authorization)\"\s*:\s*)\"(?:[^\"\\]|\\.)*\""#,
                #"$1\"[redacted]\""#
            ),
            (
                #"(?i)('(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|authorization)'\s*[:=]\s*)'[^'\r\n]*'"#,
                "$1'[redacted]'"
            ),
            (#"(?i)(Bearer|Token)\s+[A-Za-z0-9._~+/=-]{10,}"#, "$1 [redacted]"),
            (
                #"(?i)(api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|authorization)\s*[:=]\s*[^\"',\s}]{6,}"#,
                "$1=[redacted]"
            ),
            (#"(?i)sk-[A-Za-z0-9._*-]{6,}"#, "[redacted-key]"),
            (#"AIza[0-9A-Za-z_-]{10,}"#, "[redacted-key]"),
        ]
        let redacted = patterns.reduce(normalized) { partial, entry in
            partial.replacingOccurrences(
                of: entry.pattern,
                with: entry.replacement,
                options: .regularExpression
            )
        }
        return String(redacted.prefix(limit))
    }

    static func errorDiagnostic(_ error: Error, state: String) -> String {
        let nsError = error as NSError
        return "state=\(safeToken(state)) domain=\(safeToken(nsError.domain)) code=\(nsError.code)"
    }

    private static func safeToken(_ value: String) -> String {
        let redacted = redactedSnippet(from: value, limit: 80)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = redacted.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let sanitized = String(scalars)
        return sanitized.isEmpty ? "unknown" : sanitized
    }
}
