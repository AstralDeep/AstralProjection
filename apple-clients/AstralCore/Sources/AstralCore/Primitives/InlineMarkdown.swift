// The one inline-markdown parse (bold, italic, code, links) shared by every Apple surface, since the wire
// carries raw markdown in narrative text and list items. Used by MarkdownBlockView, ComponentView, and the
// watch's chat/component views.

import Foundation

public enum InlineMarkdown {
    public static func attributed(_ string: String) -> AttributedString {
        var result =
            (try? AttributedString(
                markdown: string,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(string)
        let links = result.runs.compactMap { run in run.link.map { (run.range, $0) } }
        for (range, url) in links where safeLink(url) == nil {
            result[range].link = nil
        }
        return result
    }

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
