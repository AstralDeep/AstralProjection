// Feature 053 — the ONE inline-markdown parse shared by every Apple surface.
// The wire carries raw markdown in narrative text, alert messages and list
// items (the web renderer converts server-side; native clients parse locally).
// Inline-only, whitespace-preserving: block syntax stays literal and newlines
// survive, matching the established iOS/macOS treatment — and the watch must
// match it too, or the wrist shows literal asterisks (FR-004 parity).
import Foundation

public enum InlineMarkdown {
    /// `**bold**`/`*italic*`/`` `code` ``/links → styled runs; anything the
    /// parser rejects is returned verbatim (never blank, never thrown).
    public static func attributed(_ string: String) -> AttributedString {
        var result =
            (try? AttributedString(
                markdown: string,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(string)
        // Keep the readable label and inline styling when a destination is
        // refused. No model-authored URL may invoke an arbitrary OS handler.
        let links = result.runs.compactMap { run in run.link.map { (run.range, $0) } }
        for (range, url) in links where safeLink(url) == nil {
            result[range].link = nil
        }
        return result
    }

    /// Shared browser/email allowlist. A leading-slash URL remains relative
    /// during parsing; each native UI supplies its configured backend when the
    /// user opens it. This helper neither attaches credentials nor performs IO.
    public static func safeLink(_ url: URL, relativeTo base: URL? = nil) -> URL? {
        let reference = url.absoluteString
        guard !reference.isEmpty,
            !reference.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
                    || $0 == "\\"
            }),
            let parts = URLComponents(string: reference)
        else { return nil }

        if reference.hasPrefix("/") {
            if reference.hasPrefix("//"), parts.host?.isEmpty != false { return nil }
            guard let base else { return url }
            guard let origin = URLComponents(url: base, resolvingAgainstBaseURL: true),
                ["http", "https"].contains(origin.scheme?.lowercased() ?? ""),
                origin.host?.isEmpty == false, origin.user == nil, origin.password == nil, origin.fragment == nil,
                let resolved = URL(string: reference, relativeTo: base)?.absoluteURL
            else { return nil }
            return safeLink(resolved)
        }
        switch parts.scheme?.lowercased() {
        case "http", "https":
            return parts.host?.isEmpty == false ? url : nil
        case "mailto":
            return parts.host == nil && !parts.path.isEmpty ? url : nil
        default:
            return nil
        }
    }
}
