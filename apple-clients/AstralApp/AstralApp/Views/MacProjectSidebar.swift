// Presents synchronized project sections and device-local folder controls in the Mac sidebar.
// Every chat action uses AppModel's selected-project creation path and keeps grants on this Mac.

#if os(macOS)
    import AstralCore
    import SwiftUI

    struct MacProjectSidebar: View {
        @Environment(AppModel.self) private var model
        @Environment(ThemeStore.self) private var theme
        let query: String
        @State private var creating = false
        @State private var renaming: ProjectRecord?
        @State private var name = ""
        private var p: AstralPalette { theme.palette }
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Projects").font(ConsoleTypography.subheadline.weight(.semibold))
                    Spacer()
                    Button {
                        name = ""
                        creating = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain).accessibilityLabel("Create project").accessibilityIdentifier("project-create")
                    Button {
                        Task { await model.projects.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain).accessibilityLabel("Refresh projects").accessibilityIdentifier(
                        "project-refresh")
                }
                if model.projects.loading { ProgressView().controlSize(.small) }
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
                ForEach(model.projects.projects) { project in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Button {
                                model.selectProject(project.id)
                            } label: {
                                Label(
                                    project.name,
                                    systemImage: model.projects.selectedId == project.id ? "folder.fill" : "folder"
                                )
                                .font(ConsoleTypography.subheadline.weight(.medium)).frame(
                                    maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain).accessibilityIdentifier("project-select-\(project.id)")
                            .accessibilityValue(model.projects.selectedId == project.id ? "Selected" : "")
                            Button {
                                model.selectProject(project.id)
                                model.newChat()
                            } label: {
                                Image(systemName: "square.and.pencil")
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
                                Button("Delete empty project", role: .destructive) {
                                    Task { await model.projects.delete(project) }
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
                            .accessibilityLabel("Project controls for \(project.name)").accessibilityIdentifier(
                                "project-controls-\(project.id)")
                        }
                        .padding(8).background(
                            model.projects.selectedId == project.id ? p.primary.opacity(0.13) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                        if model.projects.selectedId == project.id {
                            let roots = model.macComputerHost.projectGrants.roots(project: project.id)
                            ForEach(Array(roots.enumerated()), id: \.element) { index, path in
                                HStack {
                                    Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
                                    if index == 0 { Text("Primary").foregroundStyle(p.muted) }
                                    Spacer()
                                    Menu {
                                        if index != 0 {
                                            Button("Make primary") {
                                                model.macComputerHost.updateProjectFolders {
                                                    try model.macComputerHost.projectGrants.primary(
                                                        project: project.id, path: path)
                                                }
                                            }
                                        }
                                        Button("Remove folder", role: .destructive) {
                                            model.macComputerHost.updateProjectFolders {
                                                try model.macComputerHost.projectGrants.remove(
                                                    project: project.id, path: path)
                                            }
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis")
                                    }
                                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
                                    .accessibilityLabel("Folder controls for \(path)").accessibilityIdentifier(
                                        "project-folder-\(project.id)-\(index)")
                                }
                                .font(ConsoleTypography.caption).padding(.horizontal, 12)
                            }
                        }
                        ForEach(
                            (model.projects.chats[project.id] ?? []).filter {
                                query.isEmpty
                                    || ($0.displayTitle + " " + $0.displayPreview).localizedCaseInsensitiveContains(
                                        query)
                            }
                        ) { chat in
                            Button {
                                model.openChat(chat.id)
                            } label: {
                                HistoryRow(chat: chat, showsDetails: false)
                                    .background(
                                        model.activeChatId == chat.id ? p.primary.opacity(0.13) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain).disabled(model.mandatorySurface)
                            .accessibilityIdentifier("project-chat-\(chat.id)")
                            .contextMenu {
                                Button("Delete conversation", role: .destructive) { model.deleteChat(chat.id) }
                            }
                        }
                    }
                    .accessibilityElement(children: .contain).accessibilityLabel(project.name)
                }
            }
            .alert("New project", isPresented: $creating) {
                TextField("Project name", text: $name)
                Button("Create and choose folders…") {
                    let value = name
                    Task { await model.createProject(name: value, chooseFolders: true) }
                }
                Button("Create text-only project") {
                    let value = name
                    Task { await model.createProject(name: value, chooseFolders: false) }
                }
                Button("Cancel", role: .cancel) {}
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
