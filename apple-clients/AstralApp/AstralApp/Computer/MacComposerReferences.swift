// Owns the macOS composer's @-reference vocabulary: token scanning, grant-fenced completion over
// the active project's folders through AstralCore's ComputerWorkspace boundary, and bounded chip
// previews. Listing refuses excluded and protected paths exactly as the host's file verbs do.

#if os(macOS)
    import AstralCore
    import Foundation
    import Observation

    struct MacReferenceToken: Equatable {
        enum Kind: String {
            case file, folder, diff
        }
        let kind: Kind
        let path: String
        let range: Range<String.Index>

        static let maximumTokens = 64
        static let maximumPathScalars = 1024

        var malformed: Bool {
            guard !path.isEmpty, path.unicodeScalars.count <= Self.maximumPathScalars else { return true }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            return parts.isEmpty || parts.contains(where: { $0 == "." || $0 == ".." })
        }

        static func scan(_ text: String) -> [MacReferenceToken] {
            var tokens: [MacReferenceToken] = []
            var index = text.startIndex
            while index < text.endIndex, tokens.count < maximumTokens {
                if text[index] == "@", index == text.startIndex || text[text.index(before: index)].isWhitespace {
                    var cursor = text.index(after: index)
                    while cursor < text.endIndex, !text[cursor].isWhitespace, text[cursor] != "@" {
                        cursor = text.index(after: cursor)
                    }
                    if let separator = text[index..<cursor].firstIndex(of: ":"),
                        separator > text.index(after: index),
                        let kind = Kind(rawValue: String(text[text.index(after: index)..<separator]).lowercased())
                    {
                        let path = String(text[text.index(after: separator)..<cursor])
                        if !path.isEmpty {
                            tokens.append(MacReferenceToken(kind: kind, path: path, range: index..<cursor))
                        }
                    }
                    index = cursor > index ? cursor : text.index(after: index)
                } else {
                    index = text.index(after: index)
                }
            }
            return tokens
        }
    }

    struct MacReferenceCandidate: Identifiable, Equatable {
        let kind: MacReferenceToken.Kind
        let rootName: String
        let relative: String
        let name: String

        var tokenPath: String { relative.isEmpty ? rootName : rootName + "/" + relative }
        var id: String { "\(kind.rawValue)|\(tokenPath)" }
    }

    enum MacReferenceCompletion: Equatable {
        case idle
        case suggestions([MacReferenceCandidate])
        case unavailable(String)
    }

    enum MacReferencePreview: Equatable {
        case file(text: String, truncated: Bool, bytes: Int)
        case folder(names: [String], excluded: Int)
        case diff(root: String)
    }

    struct MacReferenceQuery: Equatable {
        let prefix: String
        let text: String
    }

    @MainActor @Observable final class MacComposerReferences {
        private(set) var completion: MacReferenceCompletion = .idle
        private(set) var query: MacReferenceQuery?
        private(set) var lastError: String?
        @ObservationIgnored private let grants: MacProjectGrants
        @ObservationIgnored private let hostAvailable: () -> Bool
        @ObservationIgnored private let workspaceExclusions: ComputerWorkspaceExclusions

        static let maximumSuggestions = 12
        static let previewBytes = 4096

        init(
            grants: MacProjectGrants, hostAvailable: @escaping () -> Bool = { true },
            exclusions: ComputerWorkspaceExclusions = .defaults
        ) {
            self.grants = grants
            self.hostAvailable = hostAvailable
            self.workspaceExclusions = exclusions
        }

        static func trigger(in draft: String) -> MacReferenceQuery? {
            guard let marker = draft.lastIndex(of: "@"), !draft.isEmpty else { return nil }
            guard marker == draft.startIndex || draft[draft.index(before: marker)].isWhitespace else { return nil }
            let tail = draft[draft.index(after: marker)...]
            guard tail.unicodeScalars.count <= 512, !tail.contains(where: { $0.isWhitespace || $0 == "@" })
            else { return nil }
            return MacReferenceQuery(prefix: String(draft[..<marker]) + "@", text: String(tail))
        }

        func refresh(draft: String, project: String?) {
            let active = Self.trigger(in: draft)
            query = active
            completion = active.map { evaluate(query: $0.text, project: project) } ?? .idle
        }

        func dismiss() {
            query = nil
            completion = .idle
        }

        func evaluate(query: String, project: String?) -> MacReferenceCompletion {
            guard hostAvailable() else {
                return .unavailable("This Mac is not running computer tools, so folder references are unavailable.")
            }
            guard let project else {
                return .unavailable("Open this chat from a project to reference its folders.")
            }
            let roots = grants.roots(project: project)
            guard !roots.isEmpty else {
                return .unavailable("Choose folders for this project on this Mac to reference their files.")
            }
            guard let (directory, fragment) = Self.split(query) else {
                return .unavailable("Folder references cannot include relative parent paths.")
            }
            let name = fragment.lowercased()
            var candidates: [MacReferenceCandidate] = []
            var failure: String?
            for root in roots.sorted() {
                let rootName = URL(fileURLWithPath: root).lastPathComponent
                if directory.isEmpty {
                    if "diff".hasPrefix(name) {
                        candidates.append(
                            MacReferenceCandidate(kind: .diff, rootName: rootName, relative: "", name: rootName))
                    }
                    if name.isEmpty || rootName.lowercased().contains(name) {
                        candidates.append(
                            MacReferenceCandidate(kind: .folder, rootName: rootName, relative: "", name: rootName))
                    }
                } else {
                    let folded = directory.lowercased()
                    guard folded == rootName.lowercased() || folded.hasPrefix(rootName.lowercased() + "/") else {
                        continue
                    }
                }
                guard let workspace = try? ComputerWorkspace(root: root, exclusions: workspaceExclusions) else {
                    failure = failure ?? "The project folder \(rootName) is no longer available."
                    continue
                }
                let isRoot = directory.lowercased() == rootName.lowercased()
                let under = isRoot ? "" : String(directory.dropFirst(rootName.count + 1))
                let target = under.isEmpty ? root : root + "/" + under
                do {
                    let listing = try workspace.list(target)
                    for entry in listing["entries"]?.arrayValue ?? [] {
                        guard let entryName = entry["name"]?.stringValue,
                            name.isEmpty || entryName.lowercased().contains(name)
                        else { continue }
                        let inside = entry["is_dir"]?.boolValue == true
                        candidates.append(
                            MacReferenceCandidate(
                                kind: inside ? .folder : .file, rootName: rootName,
                                relative: under.isEmpty ? entryName : under + "/" + entryName,
                                name: entryName))
                    }
                } catch {
                    failure = failure ?? (error as? LocalizedError)?.errorDescription ?? "The folder cannot be listed."
                }
            }
            if candidates.isEmpty {
                return .unavailable(failure ?? "No matching files or folders under this project's grants.")
            }
            return .suggestions(Array(candidates.prefix(Self.maximumSuggestions)))
        }

        func insert(_ candidate: MacReferenceCandidate) -> String? {
            guard let active = query else { return nil }
            return active.prefix + "@\(candidate.kind.rawValue):\(candidate.tokenPath) "
        }

        func remove(_ token: MacReferenceToken, from draft: String) -> String {
            var text = draft
            text.removeSubrange(token.range)
            return text
        }

        func preview(_ token: MacReferenceToken, project: String?) async -> Result<MacReferencePreview, String> {
            guard let resolved = resolve(token: token, project: project) else {
                return .failure("This reference does not match a folder granted to this project.")
            }
            do {
                switch token.kind {
                case .file:
                    let read = try resolved.workspace.read(resolved.path, maximum: Self.previewBytes)
                    return .success(
                        .file(
                            text: read["text"]?.stringValue ?? "",
                            truncated: read["truncated"]?.boolValue == true,
                            bytes: Int(read["size"]?.numberValue ?? 0)))
                case .folder:
                    let listing = try resolved.workspace.list(resolved.path)
                    return .success(
                        .folder(
                            names: (listing["entries"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue },
                            excluded: Int(listing["excluded"]?.numberValue ?? 0)))
                case .diff:
                    return .success(.diff(root: resolved.rootName))
                }
            } catch {
                return .failure((error as? LocalizedError)?.errorDescription ?? "The preview is unavailable.")
            }
        }

        func content(path: String, project: String?) async -> Result<String, String> {
            let token = MacReferenceToken(
                kind: .file, path: path,
                range: path.startIndex..<path.endIndex)
            guard let resolved = resolve(token: token, project: project) else {
                return .failure("This file is not under a folder granted to this project.")
            }
            do {
                let read = try resolved.workspace.read(resolved.path, maximum: 262_144)
                var text = read["text"]?.stringValue ?? ""
                if read["truncated"]?.boolValue == true { text += "\n\u{2026}" }
                return .success(text)
            } catch {
                return .failure((error as? LocalizedError)?.errorDescription ?? "The file cannot be read.")
            }
        }

        private func resolve(token: MacReferenceToken, project: String?) -> (
            workspace: ComputerWorkspace, path: String, rootName: String
        )? {
            guard let project, !token.malformed else { return nil }
            let parts = token.path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard let head = parts.first else { return nil }
            let roots = grants.roots(project: project).filter {
                URL(fileURLWithPath: $0).lastPathComponent == head
            }
            guard roots.count == 1, let root = roots.first,
                let workspace = try? ComputerWorkspace(root: root, exclusions: workspaceExclusions)
            else { return nil }
            let remainder = parts.count > 1 ? String(parts[1]) : ""
            return (workspace, remainder.isEmpty ? root : root + "/" + remainder, String(head))
        }

        private static func split(_ query: String) -> (directory: String, fragment: String)? {
            guard let marker = query.lastIndex(of: "/") else { return ("", query) }
            let directory = String(query[..<marker])
            let fragment = String(query[query.index(after: marker)...])
            guard directory.isEmpty
                || !directory.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                    $0 == "." || $0 == ".." || $0.isEmpty
                })
            else { return nil }
            return (directory, fragment)
        }
    }
#endif
