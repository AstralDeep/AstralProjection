// Renders the macOS composer's @-reference completion, token chips with previews, and the chat
// header's project instructions indicator with its read-only viewer and per-project toggle.
// Rows and chips carry stable identifiers and accessible names for the native suites.

#if os(macOS)
    import AstralCore
    import SwiftUI

    struct MacReferenceComposerSection: View {
        @Environment(AppModel.self) var model
        @Environment(ThemeStore.self) var theme
        let references: MacComposerReferences
        @Binding var input: String
        @State private var preview: MacReferencePreviewPresentation?
        private var p: AstralPalette { theme.palette }

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                if !tokens.isEmpty { chips }
                switch references.completion {
                case .idle:
                    EmptyView()
                case .suggestions(let candidates):
                    completionList(candidates)
                case .unavailable(let message):
                    unavailable(message)
                }
            }
            .onAppear {
                references.refresh(draft: input, project: model.composerReferenceProject)
            }
            .onChange(of: input) { _, value in
                references.refresh(draft: value, project: model.composerReferenceProject)
            }
            .popover(item: $preview) { presentation in
                MacReferencePreviewPopover(presentation: presentation, references: references)
            }
        }

        private var tokens: [MacReferenceToken] {
            MacReferenceToken.scan(input)
        }

        private var chips: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                        chip(index: index, token: token)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Message references")
            .accessibilityIdentifier("composer-reference-chips")
        }

        private func chip(index: Int, token: MacReferenceToken) -> some View {
            HStack(spacing: 4) {
                Image(systemName: Self.icon(token.kind))
                    .font(ConsoleTypography.caption2)
                    .foregroundStyle(token.malformed ? p.error : p.primary)
                    .accessibilityHidden(true)
                Text(token.path)
                    .font(ConsoleTypography.caption)
                    .foregroundStyle(p.text)
                    .lineLimit(1)
                    .frame(maxWidth: 240, alignment: .leading)
                Button {
                    preview = MacReferencePreviewPresentation(token: token, project: model.composerReferenceProject)
                } label: {
                    Image(systemName: "eye").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.muted)
                .disabled(token.malformed)
                .accessibilityLabel("Preview reference \(token.path)")
                .accessibilityIdentifier("composer-reference-chip-preview-\(index)")
                .help("Preview what this reference attaches")
                Button {
                    input = references.remove(token, from: input)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.muted)
                .accessibilityLabel("Remove reference \(token.path)")
                .accessibilityIdentifier("composer-reference-chip-remove-\(index)")
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(p.primary.opacity(token.malformed ? 0.06 : 0.12), in: Capsule())
            .overlay(Capsule().stroke(token.malformed ? p.error.opacity(0.5) : p.primary.opacity(0.3)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(token.kind.rawValue) reference \(token.path)")
            .accessibilityValue(token.malformed ? "Unresolvable path" : token.path)
            .accessibilityIdentifier("composer-reference-chip-\(index)")
        }

        private func completionList(_ candidates: [MacReferenceCandidate]) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                    Button {
                        if let inserted = references.insert(candidate) { input = inserted }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: Self.icon(candidate.kind))
                                .font(ConsoleTypography.caption)
                                .foregroundStyle(p.primary).frame(width: 16)
                                .accessibilityHidden(true)
                            Text(candidate.name)
                                .font(ConsoleTypography.caption.weight(.medium))
                                .foregroundStyle(p.text)
                            Spacer(minLength: 8)
                            Text("@\(candidate.kind.rawValue):\(candidate.tokenPath)")
                                .font(ConsoleTypography.mono(10))
                                .foregroundStyle(p.muted)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Reference \(candidate.kind.rawValue) \(candidate.tokenPath)")
                    .accessibilityIdentifier("composer-reference-option-\(index)")
                }
            }
            .padding(6)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Folder reference completion")
            .accessibilityIdentifier("composer-reference-completion")
        }

        private func unavailable(_ message: String) -> some View {
            HStack(spacing: 6) {
                Image(systemName: "slash.circle").foregroundStyle(p.muted).accessibilityHidden(true)
                Text(message).font(ConsoleTypography.caption).foregroundStyle(p.muted)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("composer-reference-unavailable")
        }

        static func icon(_ kind: MacReferenceToken.Kind) -> String {
            switch kind {
            case .file: return "doc"
            case .folder: return "folder"
            case .diff: return "arrow.left.arrow.right"
            }
        }
    }

    struct MacReferencePreviewPresentation: Identifiable, Equatable {
        let token: MacReferenceToken
        let project: String?
        var id: String { "\(token.kind.rawValue)|\(token.path)" }
    }

    struct MacReferencePreviewPopover: View {
        @Environment(ThemeStore.self) var theme
        let presentation: MacReferencePreviewPresentation
        let references: MacComposerReferences
        @State private var state: Result<MacReferencePreview, String>?
        private var p: AstralPalette { theme.palette }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("Preview \(presentation.token.kind.rawValue) reference")
                    .font(ConsoleTypography.headline).foregroundStyle(p.text)
                Text(presentation.token.path)
                    .font(ConsoleTypography.mono(11)).foregroundStyle(p.muted)
                Group {
                    switch state {
                    case .none:
                        ProgressView().controlSize(.small)
                    case .some(.success(let preview)):
                        content(preview)
                    case .some(.failure(let message)):
                        Text(message).font(ConsoleTypography.caption).foregroundStyle(p.error)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
            .padding(16)
            .task {
                state = await references.preview(presentation.token, project: presentation.project)
            }
        }

        @ViewBuilder
        private func content(_ preview: MacReferencePreview) -> some View {
            switch preview {
            case .file(let text, let truncated, let bytes):
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(bytes) bytes\(truncated ? ", first part shown" : "")")
                        .font(ConsoleTypography.caption2).foregroundStyle(p.muted)
                    ScrollView {
                        Text(text.isEmpty ? "(empty file)" : text)
                            .font(ConsoleTypography.mono(11)).foregroundStyle(p.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 280)
                }
            case .folder(let names, let excluded):
                VStack(alignment: .leading, spacing: 4) {
                    Text(excluded > 0 ? "\(names.count) entries, \(excluded) excluded" : "\(names.count) entries")
                        .font(ConsoleTypography.caption2).foregroundStyle(p.muted)
                    Text(names.prefix(40).joined(separator: "\n"))
                        .font(ConsoleTypography.mono(11)).foregroundStyle(p.text)
                }
            case .diff(let root):
                Text(
                    "The working-tree diff of the granted folder \(root), resolved by the server at send time."
                )
                    .font(ConsoleTypography.caption).foregroundStyle(p.text)
            }
        }
    }

    struct MacInstructionViewerTarget: Identifiable {
        let path: String
        var id: String { path }
    }

    struct MacProjectInstructionsIndicator: View {
        @Environment(AppModel.self) var model
        @Environment(ThemeStore.self) var theme
        @State private var presented = false
        @State private var viewer: MacInstructionViewerTarget?
        private var p: AstralPalette { theme.palette }

        private var files: [ProjectInstructionsFile] {
            if case .loaded(let report) = model.projectInstructions.state { return report.files }
            return []
        }

        var body: some View {
            Button {
                presented.toggle()
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "books.vertical").frame(width: 36, height: 40)
                    if !files.isEmpty {
                        Text("\(files.count)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .background(p.primary, in: Capsule())
                            .offset(x: 7, y: 3)
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.plain).foregroundStyle(p.muted)
            .help("Project instructions")
            .accessibilityLabel("Project instructions")
            .accessibilityValue(files.isEmpty ? "None loaded" : "\(files.count) files loaded")
            .accessibilityIdentifier("project-instructions-indicator")
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                MacProjectInstructionsPanel { viewer = MacInstructionViewerTarget(path: $0) }
            }
            .sheet(item: $viewer) { target in
                MacProjectInstructionsViewer(path: target.path)
            }
        }
    }

    struct MacProjectInstructionsPanel: View {
        @Environment(AppModel.self) var model
        @Environment(ThemeStore.self) var theme
        let openViewer: (String) -> Void
        private var p: AstralPalette { theme.palette }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Project instructions")
                        .font(ConsoleTypography.headline).foregroundStyle(p.text)
                    Spacer()
                    Toggle("Included", isOn: Binding(
                        get: {
                            if case .loaded(let report) = model.projectInstructions.state { return report.enabled }
                            return false
                        },
                        set: { enabled in Task { await model.projectInstructions.setEnabled(enabled) } }
                    ))
                    .toggleStyle(.switch).controlSize(.small)
                    .disabled(!model.projectInstructions.ingestionControlled || model.projectInstructions.working)
                    .accessibilityLabel("Include project instructions")
                    .accessibilityIdentifier("project-instructions-toggle")
                }
                content.frame(maxWidth: 380, alignment: .leading)
            }
            .padding(16)
            .task(id: model.composerReferenceProject) {
                model.projectInstructions.select(project: model.composerReferenceProject)
                await model.projectInstructions.refresh()
            }
        }

        @ViewBuilder
        private var content: some View {
            switch model.projectInstructions.state {
            case .idle:
                Text("The server has not reported project instruction files for this chat.")
                    .font(ConsoleTypography.caption).foregroundStyle(p.muted)
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading instruction files").font(ConsoleTypography.caption).foregroundStyle(p.muted)
                }
            case .unavailable(let message):
                Text(message).font(ConsoleTypography.caption).foregroundStyle(p.error)
            case .loaded(let report):
                VStack(alignment: .leading, spacing: 6) {
                    if report.files.isEmpty {
                        Text("No instruction files are loaded for this project.")
                            .font(ConsoleTypography.caption).foregroundStyle(p.muted)
                    }
                    ForEach(report.files, id: \.path) { file in
                        Button {
                            openViewer(file.path)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.path)
                                    .font(ConsoleTypography.mono(11)).foregroundStyle(p.text)
                                    .lineLimit(1)
                                Text(String(file.sha256.prefix(12)))
                                    .font(ConsoleTypography.mono(10)).foregroundStyle(p.muted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("View instruction file \(file.path)")
                        .accessibilityValue("Hash \(file.sha256)")
                        .accessibilityIdentifier("project-instructions-file-\(file.path)")
                        .help("SHA-256 \(file.sha256)")
                    }
                    if !report.enabled {
                        Text("Instruction ingestion is off for this project.")
                            .font(ConsoleTypography.caption2).foregroundStyle(p.muted)
                    }
                }
            }
        }
    }

    struct MacProjectInstructionsViewer: View {
        @Environment(AppModel.self) var model
        @Environment(ThemeStore.self) var theme
        @Environment(\.dismiss) private var dismiss
        let path: String
        @State private var content: Result<String, String>?
        private var p: AstralPalette { theme.palette }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(path).font(ConsoleTypography.headline).foregroundStyle(p.text).lineLimit(1)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark").frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain).foregroundStyle(p.muted)
                    .accessibilityLabel("Close instruction viewer")
                    .accessibilityIdentifier("project-instructions-viewer-close")
                }
                Group {
                    switch content {
                    case .none:
                        ProgressView().controlSize(.small)
                    case .some(.success(let text)):
                        ScrollView {
                            Text(text)
                                .font(ConsoleTypography.mono(11)).foregroundStyle(p.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    case .some(.failure(let message)):
                        Text(message).font(ConsoleTypography.caption).foregroundStyle(p.error)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(20)
            .frame(width: 560, height: 480)
            .task {
                content = await model.composerReferences.content(
                    path: path, project: model.composerReferenceProject)
            }
        }
    }
#endif
