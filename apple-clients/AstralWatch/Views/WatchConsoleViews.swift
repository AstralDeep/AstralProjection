// Presents the shared console catalog and settings as ROTE-selected watch navigation stacks.
// WatchModel validates each server-offered action and keeps result detail bound to current conversation state.

import AstralCore
import SwiftUI

struct WatchConsoleHome: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        ScrollView {
            WatchConsoleHomeContent(model: model)
        }
        .background(model.theme.palette.bg)
        .navigationTitle(model.consoleLabel("brand"))
    }
}

struct WatchConsoleCatalogView: View {
    @Environment(WatchModel.self) private var model
    @State private var category = ""

    var body: some View {
        ScrollView {
            WatchConsoleCatalogViewContent(model: model, category: $category)
        }
        .navigationTitle(model.consoleLabel("start_here"))
    }
}

struct WatchConsoleAgentsView: View {
    @Environment(WatchModel.self) private var model
    @State private var query = ""

    var body: some View {
        ScrollView {
            WatchConsoleAgentsViewContent(model: model, query: $query)
        }
        .background(model.theme.palette.bg)
        .navigationTitle(model.consoleLabel("agent_directory"))
        .navigationDestination(
            isPresented: Binding(
                get: { model.consoleSurfaceVisible },
                set: { if !$0 { model.closeConsoleSurface() } }
            )
        ) { WatchConsoleSurfaceView() }
    }
}

struct WatchConsoleSettingsView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        ScrollView {
            WatchConsoleSettingsViewContent(model: model)
        }
        .background(model.theme.palette.bg)
        .navigationTitle(model.chromeMenu?.settingsControl?.label ?? "")
        .modifier(WatchOwnerSurfaceNavigation())
    }
}

struct WatchConsoleActionsView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        ScrollView {
            WatchConsoleActionsViewContent(model: model)
        }
        .background(model.theme.palette.bg)
        .navigationTitle(model.consoleLabel("more"))
        .modifier(WatchOwnerSurfaceNavigation())
    }
}

private struct WatchConsoleRowStyle: ViewModifier {
    @Environment(WatchModel.self) private var model
    func body(content: Content) -> some View {
        content.font(ConsoleTypography.footnote)
            .frame(
                maxWidth: .infinity, minHeight: model.consolePresentation?.minimumControlHeight ?? 44,
                alignment: .leading
            )
            .padding(6)
            .background(model.theme.palette.surface, in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(model.theme.palette.text)
    }
}

extension View {
    fileprivate func watchConsoleRow() -> some View { modifier(WatchConsoleRowStyle()) }
}

struct WatchConsoleSurfaceView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        ScrollView {
            WatchConsoleSurfaceViewContent(model: model)
        }
    }
}

struct WatchConsoleResultView: View {
    let entryID: String?
    @Environment(WatchModel.self) private var model

    var body: some View {
        ScrollView { WatchConsoleResultContent(model: model, entryID: entryID) }
            .navigationTitle(model.consoleLabel("fullscreen"))
    }
}

struct WatchConsoleResultContent: View {
    let model: WatchModel
    let entryID: String?
    private var components: [AstralComponent] {
        if let entryID {
            if case .turn(_, let components) = model.visibleEntries.first(where: { $0.id == entryID }) {
                return components
            }
            return []
        }
        return model.workspaceCanvas
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(components.enumerated()), id: \.offset) { _, component in
                WatchComponentView(component: component)
            }
        }.padding(model.consoleContentInsets)
    }
}

extension WatchModel {
    var consoleContentInsets: EdgeInsets {
        guard let padding = consolePresentation?.contentPadding else { return EdgeInsets() }
        return EdgeInsets(top: padding.top, leading: padding.left, bottom: padding.bottom, trailing: padding.right)
    }

    var consoleComposerInsets: EdgeInsets {
        guard let padding = consolePresentation?.composerPadding else { return EdgeInsets() }
        return EdgeInsets(top: padding.top, leading: padding.left, bottom: padding.bottom, trailing: padding.right)
    }
}

struct WatchConsoleHomeContent: View {
    let model: WatchModel
    var body: some View {
        if let console = model.console {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: console.labels["title"] ?? "").font(ConsoleTypography.title3)
                Text(verbatim: console.labels["subtitle"] ?? "").font(ConsoleTypography.caption)
                    .foregroundStyle(model.theme.palette.muted)
                Button {
                    model.newConversation()
                    model.consoleChatVisible = true
                } label: {
                    Label(console.labels["new_chat"] ?? "", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .watchConsoleRow()
                NavigationLink {
                    WatchConsoleCatalogView()
                } label: {
                    Label(console.labels["start_here"] ?? "", systemImage: "sparkles")
                }.watchConsoleRow()
                NavigationLink {
                    WatchConsoleAgentsView()
                } label: {
                    Label(console.labels["agent_directory"] ?? "", systemImage: "square.grid.2x2")
                }.watchConsoleRow()
                Text(verbatim: console.labels["history"] ?? "").font(ConsoleTypography.headline)
                if model.recentsLoading { ProgressView() }
                ForEach(model.recents) { chat in
                    Button {
                        model.openChat(chat)
                        model.consoleChatVisible = true
                    } label: {
                        WatchHistoryRow(chat: chat)
                    }.watchConsoleRow()
                }
                Divider()
                HStack(spacing: 8) {
                    Text(verbatim: console.identity.initials).font(ConsoleTypography.caption)
                        .frame(width: 28, height: 28)
                        .background(model.theme.palette.primary.opacity(0.25), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: console.identity.name).font(ConsoleTypography.headline)
                        Text(verbatim: console.identity.role).font(ConsoleTypography.caption)
                            .foregroundStyle(model.theme.palette.muted)
                    }
                }
                NavigationLink {
                    WatchConsoleSettingsView()
                } label: {
                    Label(model.chromeMenu?.settingsControl?.label ?? "", systemImage: "gearshape")
                }.watchConsoleRow()
            }.padding(model.consoleContentInsets)
        }
    }
}

struct WatchConsoleCatalogViewContent: View {
    let model: WatchModel
    @Binding var category: String
    var body: some View {
        if let console = model.console {
            VStack(alignment: .leading, spacing: 10) {
                Picker(console.labels["all_categories"] ?? "", selection: $category) {
                    Text(verbatim: console.labels["all_categories"] ?? "").tag("")
                    ForEach(console.catalog.categories, id: \.self) { Text(verbatim: $0).tag($0) }
                }.pickerStyle(.navigationLink)
                ForEach(console.catalog.scenarios.filter { category.isEmpty || $0.category == category }) {
                    scenario in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: scenario.category).font(ConsoleTypography.caption2)
                            .foregroundStyle(model.theme.palette.primary)
                        Text(verbatim: scenario.title).font(ConsoleTypography.headline)
                        Text(verbatim: scenario.description).font(ConsoleTypography.footnote)
                        Button(console.labels["run"] ?? "") { model.useScenario(scenario, run: true) }
                            .buttonStyle(.borderedProminent)
                            .frame(minHeight: model.consolePresentation?.minimumControlHeight ?? 44)
                        Button(console.labels["load_prompt"] ?? "") { model.useScenario(scenario, run: false) }
                            .frame(minHeight: model.consolePresentation?.minimumControlHeight ?? 44)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(model.theme.palette.surface, in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(model.consoleContentInsets)
        }
    }
}

struct WatchConsoleAgentsViewContent: View {
    let model: WatchModel
    @Binding var query: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(model.consoleLabel("search_agents"), text: $query)
            ForEach(
                model.console?.catalog.agents.filter {
                    query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                        || $0.description.localizedCaseInsensitiveContains(query)
                } ?? []
            ) { agent in
                Button {
                    model.openAgent(agent)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(agent.name, systemImage: agent.state == .ready ? "circle.fill" : "circle")
                            .font(ConsoleTypography.headline)
                        Text(verbatim: agent.description).font(ConsoleTypography.caption)
                            .foregroundStyle(model.theme.palette.muted)
                        if let message = agent.availability?.message {
                            Text(verbatim: message).font(ConsoleTypography.caption2)
                        }
                    }
                }
                .watchConsoleRow()
                .disabled(agent.availability == nil || (agent.availability?.mode == .native && !model.connected))
            }
        }.padding(model.consoleContentInsets)
    }
}

struct WatchConsoleSettingsViewContent: View {
    let model: WatchModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.chromeMenu?.menu ?? []) { group in
                Text(verbatim: group.label).font(ConsoleTypography.headline)
                ForEach(group.items) { item in
                    Button {
                        model.openMenuItem(item)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: item.label)
                            if let message = item.availability?.message {
                                Text(verbatim: message).font(ConsoleTypography.caption2)
                                    .foregroundStyle(model.theme.palette.muted)
                            }
                        }
                    }
                    .watchConsoleRow()
                    .disabled(item.availability == nil || (item.availability?.mode == .native && !model.connected))
                }
            }
            if let signout = model.chromeMenu?.signout, signout.action == "logout" {
                Button(signout.label, role: .destructive) { Task { await model.signOut() } }
                    .watchConsoleRow()
            }
        }.padding(model.consoleContentInsets)
    }
}

struct WatchConsoleActionsViewContent: View {
    let model: WatchModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.console?.composerActions ?? []) { action in
                Button {
                    model.performComposerAction(action)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: action.label)
                        if let message = action.availability?.message {
                            Text(verbatim: message).font(ConsoleTypography.caption2)
                                .foregroundStyle(model.theme.palette.muted)
                        }
                    }
                }
                .watchConsoleRow()
                .disabled(action.availability == nil || (action.availability?.mode == .native && !model.connected))
            }
        }.padding(model.consoleContentInsets)
    }
}

struct WatchConsoleSurfaceViewContent: View {
    let model: WatchModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let surface = model.consoleSurface {
                Text(verbatim: surface.title).font(ConsoleTypography.headline)
                ForEach(Array(surface.components.enumerated()), id: \.offset) { _, component in
                    WatchComponentView(component: component, consoleSurface: true)
                }
            } else if model.consoleSurfaceFailed || !model.connected {
                Text("This view is unavailable. Reconnect and retry.")
                Button("Retry") { model.retryConsoleSurface() }.disabled(!model.connected)
            } else {
                ProgressView()
            }
        }
        .padding(model.consoleContentInsets)
        .frame(maxWidth: model.consolePresentation?.dialogWidth ?? .infinity)
    }
}
