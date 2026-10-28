// Presents synchronized projects as a compact tree with local folder controls and nested chats.
// Disclosure stays in presentation state; selection, chat actions and folder grants retain AppModel's fences.

#if os(macOS)
    import AstralCore
    import SwiftUI

    struct MacProjectSidebar: View {
        @Environment(AppModel.self) private var model
        @Environment(ThemeStore.self) private var theme
        let query: String
        @State private var disclosure = ProjectSidebarDisclosure()
        @State private var hoveredProject: String?
        @State private var renaming: ProjectRecord?
        @State private var name = ""
        private var p: AstralPalette { theme.palette }
        private var search: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
        private var activeProject: String? { model.activeChatId.flatMap { model.projects.project(for: $0) } }
        private var visibleProjects: [ProjectRecord] {
            model.projects.projects.filter {
                search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || !chats(in: $0).isEmpty
            }
        }

        private func chats(in project: ProjectRecord) -> [ChatSummary] {
            (model.projects.chats[project.id] ?? []).filter {
                search.isEmpty || project.name.localizedCaseInsensitiveContains(search)
                    || ($0.displayTitle + " " + $0.displayPreview).localizedCaseInsensitiveContains(search)
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Projects").font(ConsoleTypography.subheadline.weight(.medium)).foregroundStyle(p.muted)
                    Spacer(minLength: 0)
                    Button {
                        model.presentProjectCreation()
                    } label: {
                        Image(systemName: "plus").frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Create project").accessibilityIdentifier("project-create")
                    Button {
                        Task { await model.projects.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Refresh projects").accessibilityIdentifier(
                        "project-refresh")
                }
                .font(.system(size: 16)).foregroundStyle(p.muted).padding(.horizontal, 8)
                if model.projects.loading || model.projects.negotiating { ProgressView().controlSize(.small) }
                if let error = model.projects.errorMessage {
                    Text(error).font(ConsoleTypography.caption).foregroundStyle(p.error)
                        .accessibilityIdentifier("project-error")
                }
                if let error = model.macComputerHost.projectGrants.errorMessage {
                    Text(error).font(ConsoleTypography.caption).foregroundStyle(p.error)
                        .accessibilityIdentifier("project-folder-error")
                }
                if let error = model.macComputerHost.projectGrantError {
                    Text(error).font(ConsoleTypography.caption).foregroundStyle(p.error)
                        .accessibilityIdentifier("project-grant-refusal")
                }
                if !model.macComputerHost.projectGrants.unavailableProjects.isEmpty {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Folders unavailable on this Mac.").foregroundStyle(p.warning)
                            Text("Projects and chats are saved.").foregroundStyle(p.muted)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(p.warning)
                    }
                    .font(ConsoleTypography.caption).padding(.horizontal, 12)
                    .accessibilityIdentifier("project-folders-unavailable")
                }
                if !search.isEmpty, visibleProjects.isEmpty {
                    Text("No matching chats").font(ConsoleTypography.caption).foregroundStyle(p.muted)
                        .padding(.horizontal, 12)
                }
                ForEach(visibleProjects) { project in
                    let expanded = disclosure.isExpanded(
                        project.id, selected: model.projects.selectedId, active: activeProject,
                        searching: !search.isEmpty)
                    VStack(alignment: .leading, spacing: 2) {
                        projectHeader(project, expanded: expanded)
                        if let paths = model.macComputerHost.projectGrants.unavailableProjects[project.id] {
                            folderRecovery(project, paths: paths)
                        }
                        if expanded {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(chats(in: project)) { chat in
                                    Button {
                                        model.openChat(chat.id)
                                    } label: {
                                        MacProjectChatRow(chat: chat, active: model.activeChatId == chat.id)
                                    }
                                    .buttonStyle(.plain).disabled(model.mandatorySurface)
                                    .accessibilityIdentifier("project-chat-\(chat.id)")
                                    .accessibilityValue(model.activeChatId == chat.id ? "Active conversation" : "")
                                    .help(chat.displayTitle)
                                    .contextMenu {
                                        Button("Delete conversation", role: .destructive) { model.deleteChat(chat.id) }
                                    }
                                }
                                if search.isEmpty {
                                    let roots = model.macComputerHost.projectGrants.roots(project: project.id)
                                    VStack(spacing: 0) {
                                        ForEach(Array(roots.enumerated()), id: \.element) { index, path in
                                            folderRow(project: project.id, path: path, index: index)
                                        }
                                    }
                                    .padding(.top, roots.isEmpty || chats(in: project).isEmpty ? 0 : 4)
                                }
                            }
                        }
                    }
                    .accessibilityElement(children: .contain).accessibilityLabel(project.name)
                }
            }
            .onChange(of: model.projects.projects.map(\.id), initial: true) { _, ids in
                disclosure.retain(Set(ids))
            }
            .alert("Rename project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }))
            {
                TextField("Project name", text: $name)
                Button("Rename") {
                    if let project = renaming {
                        let value = name
                        Task { await model.projects.rename(project, name: value) }
                    }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }

        private func projectHeader(_ project: ProjectRecord, expanded: Bool) -> some View {
            HStack(spacing: 8) {
                Button {
                    disclosure.toggle(
                        project.id, selected: model.projects.selectedId, active: activeProject,
                        searching: !search.isEmpty)
                } label: {
                    Image(
                        systemName: hoveredProject == project.id
                            ? (expanded ? "chevron.down" : "chevron.right") : (expanded ? "folder.fill" : "folder")
                    )
                    .font(.system(size: 16)).foregroundStyle(p.muted).frame(width: 24, height: 24)
                }
                .buttonStyle(.plain).disabled(!search.isEmpty)
                .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(project.name)")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("project-expansion-\(project.id)")
                .help(
                    search.isEmpty
                        ? "\(expanded ? "Collapse" : "Expand") project" : "Clear search to collapse this project")
                Button {
                    model.selectProject(project.id)
                } label: {
                    Text(verbatim: project.name).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(ConsoleTypography.subheadline).foregroundStyle(p.text).frame(height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityIdentifier("project-select-\(project.id)")
                .accessibilityValue(model.projects.selectedId == project.id ? "Selected" : "").help(project.name)
                Button {
                    disclosure.reveal(project.id)
                    model.selectProject(project.id)
                    model.newChat()
                } label: {
                    Image(systemName: "square.and.pencil").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain).disabled(model.projects.creatingChat || model.mandatorySurface)
                .accessibilityLabel("New chat in \(project.name)").accessibilityIdentifier(
                    "project-new-chat-\(project.id)")
                Menu {
                    Button("Rename project") {
                        name = project.name
                        renaming = project
                    }
                    Button("Choose folders on this Mac…") {
                        model.macComputerHost.updateProjectFolders {
                            try model.macComputerHost.projectGrants.choose(project: project.id)
                        }
                    }
                    if model.macComputerHost.projectGrants.unavailableProjects[project.id] != nil {
                        Button("Remove saved folders", role: .destructive) {
                            model.macComputerHost.updateProjectFolders {
                                try model.macComputerHost.projectGrants.clear(project: project.id)
                            }
                        }
                    }
                    Button("Delete empty project", role: .destructive) {
                        Task { await model.projects.delete(project) }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(p.muted).frame(width: 24, height: 24)
                .accessibilityLabel("Project controls for \(project.name)").accessibilityIdentifier(
                    "project-controls-\(project.id)")
            }
            .font(.system(size: 16)).foregroundStyle(p.muted).padding(.horizontal, 8)
            .background(
                p.text.opacity(
                    hoveredProject == project.id ? 0.08 : model.projects.selectedId == project.id ? 0.04 : 0),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .onHover { hoveredProject = $0 ? project.id : nil }
        }

        private func folderRecovery(_ project: ProjectRecord, paths: [String]) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("Computer access needs folders again.").foregroundStyle(p.warning)
                ForEach(paths, id: \.self) { path in
                    Text(verbatim: path).lineLimit(1).truncationMode(.middle).foregroundStyle(p.muted).help(path)
                        .accessibilityLabel("Saved folder: \(path)")
                }
                Button("Choose folders…") {
                    model.macComputerHost.updateProjectFolders {
                        try model.macComputerHost.projectGrants.choose(project: project.id)
                    }
                }
                .buttonStyle(.plain).foregroundStyle(p.accent)
                .accessibilityLabel("Choose folders for \(project.name)")
                .accessibilityIdentifier("project-recover-folders-\(project.id)")
            }
            .font(ConsoleTypography.caption).padding(.leading, 40).padding(.trailing, 8).padding(.vertical, 4)
            .accessibilityElement(children: .contain).accessibilityIdentifier("project-folder-warning-\(project.id)")
        }

        private func folderRow(project: String, path: String, index: Int) -> some View {
            HStack(spacing: 8) {
                Image(systemName: "folder").font(.system(size: 16)).frame(width: 24).accessibilityHidden(true)
                Text(verbatim: URL(fileURLWithPath: path).lastPathComponent).lineLimit(1).truncationMode(.middle)
                if index == 0 {
                    Text("Primary").font(ConsoleTypography.sans(10, relativeTo: .caption2))
                        .fixedSize(horizontal: true, vertical: false)
                }
                Spacer(minLength: 0)
                Menu {
                    if index != 0 {
                        Button("Make primary") {
                            model.macComputerHost.updateProjectFolders {
                                try model.macComputerHost.projectGrants.primary(project: project, path: path)
                            }
                        }
                    }
                    Button("Remove folder", role: .destructive) {
                        model.macComputerHost.updateProjectFolders {
                            try model.macComputerHost.projectGrants.remove(project: project, path: path)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(p.muted).frame(width: 24, height: 24)
                .accessibilityLabel("Folder controls for \(path)").accessibilityIdentifier(
                    "project-folder-\(project)-\(index)")
            }
            .font(ConsoleTypography.caption).foregroundStyle(p.muted).frame(height: 26)
            .padding(.leading, 40).padding(.trailing, 8)
            .help(path)
        }
    }

    private struct MacProjectChatRow: View {
        @Environment(ThemeStore.self) private var theme
        let chat: ChatSummary
        let active: Bool
        @State private var hovered = false

        var body: some View {
            Text(verbatim: chat.displayTitle).font(ConsoleTypography.subheadline)
                .foregroundStyle(theme.palette.text).lineLimit(1).truncationMode(.tail)
                .padding(.leading, 40).padding(.trailing, 8)
                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
                .background(
                    active || hovered ? theme.palette.text.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .contentShape(Rectangle()).onHover { hovered = $0 }
        }
    }
    struct MacProjectChoiceSheet: View {
        @Environment(AppModel.self) private var model
        @State private var name = ""
        @State private var chooseFolders = true
        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Choose a project").font(.headline)
                    Spacer()
                    Button("Cancel") { model.cancelProjectChoice() }.keyboardShortcut(.cancelAction)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.projects.projects) { project in
                            Button(project.name) { model.chooseProjectForPendingChat(project.id) }
                                .accessibilityIdentifier("project-choice-\(project.id)")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 220)
                Divider()
                TextField("New project name", text: $name).accessibilityIdentifier("project-choice-name")
                Toggle("Choose folders on this Mac after creating", isOn: $chooseFolders)
                    .accessibilityIdentifier("project-choice-folders")
                if let error = model.projects.errorMessage { Text(error).foregroundStyle(.red) }
                Button("Create project") {
                    let value = name
                    let folders = chooseFolders
                    Task { await model.createProject(name: value, chooseFolders: folders) }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("project-choice-create")
            }
            .padding(24).frame(width: 420)
            .accessibilityIdentifier("project-choice-sheet")
        }
    }
#endif
