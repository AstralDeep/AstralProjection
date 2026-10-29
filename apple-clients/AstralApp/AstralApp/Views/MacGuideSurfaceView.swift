// Adapts the server's guide document into persistent Mac topic controls and a separately scrolling article.
// Labels, selection, disabled states and action payloads come from the current server-offered components.

#if os(macOS)
    import AstralCore
    import SwiftUI

    struct MacGuideDocument {
        struct Section: Identifiable {
            let id: String
            let label: String
            let action: String
            let payload: [String: JSONValue]
            let enabled: Bool
        }

        let article: [AstralComponent]
        let navigationTitle: String
        let sections: [Section]
        let selectedIndex: Int
        var selectedID: String { sections[selectedIndex].id }

        init?(components: [AstralComponent]) {
            guard components.count >= 3, let navigation = components.last, navigation.type == "container",
                !navigation.children.isEmpty,
                components[components.count - 2].type == "text",
                components[components.count - 2].variant == "h3",
                let title = components[components.count - 2].textContent, !title.isEmpty
            else { return nil }
            var topics: [Section] = []
            var selected: [Int] = []
            for button in navigation.children {
                guard button.type == "button", let label = button.label, !label.isEmpty,
                    button.raw["action"] == .string("chrome_open"),
                    let payload = button.raw["payload"]?.objectValue,
                    payload["surface"] == .string("guide"),
                    let id = payload["params"]?["section"]?.stringValue, !id.isEmpty
                else { return nil }
                if button.variant == "primary" { selected.append(topics.count) }
                topics.append(
                    .init(
                        id: id, label: label, action: "chrome_open", payload: payload,
                        enabled: button.raw["disabled"]?.boolValue != true && button.raw["enabled"]?.boolValue != false)
                )
            }
            guard selected.count == 1, Set(topics.map(\.id)).count == topics.count else { return nil }
            article = Array(components.dropLast(2))
            navigationTitle = title
            sections = topics
            selectedIndex = selected[0]
        }
    }

    extension AppModel {
        func openGuideSection(_ id: String) {
            guard signedIn, connected, screen == .surface, !mandatorySurface, pendingSurfaceKey == "guide",
                let surface = pendingSurface, surface.surfaceKey == "guide",
                let current = MacGuideDocument(components: surface.components), current.selectedID != id,
                let section = current.sections.first(where: { $0.id == id }), section.enabled
            else { return }
            emit(section.action, payload: section.payload)
        }
    }

    struct MacGuideSurfaceView: View {
        let document: MacGuideDocument
        @Environment(AppModel.self) private var model
        @Environment(ThemeStore.self) private var theme
        private var ready: Bool {
            model.signedIn && model.connected && model.screen == .surface && !model.mandatorySurface
        }
        private var waiting: Bool {
            guard model.surfaceFailureMessage == nil,
                let requested = model.pendingSurfaceParams["section"]?.stringValue
            else { return false }
            return requested != document.selectedID && document.sections.contains { $0.id == requested }
        }
        private var previous: MacGuideDocument.Section? {
            document.selectedIndex > 0 ? document.sections[document.selectedIndex - 1] : nil
        }
        private var next: MacGuideDocument.Section? {
            document.sections.indices.contains(document.selectedIndex + 1)
                ? document.sections[document.selectedIndex + 1] : nil
        }

        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Picker(
                        document.navigationTitle,
                        selection: Binding(
                            get: { document.selectedID }, set: { model.openGuideSection($0) })
                    ) {
                        ForEach(document.sections) { section in
                            Text(section.label).tag(section.id).disabled(!section.enabled)
                        }
                    }
                    .pickerStyle(.menu).disabled(!ready).frame(maxWidth: .infinity)
                    .accessibilityLabel("User guide section").accessibilityIdentifier("guide-section-picker")
                    if waiting {
                        ProgressView().controlSize(.small).accessibilityLabel("Loading section")
                    }
                    Button {
                        if let previous { model.openGuideSection(previous.id) }
                    } label: {
                        Image(systemName: "chevron.left").frame(width: 24, height: 24)
                    }
                    .disabled(!ready || waiting || previous?.enabled != true)
                    .help("Previous section").accessibilityLabel("Previous section")
                    .accessibilityIdentifier("guide-previous-section")
                    Button {
                        if let next { model.openGuideSection(next.id) }
                    } label: {
                        Image(systemName: "chevron.right").frame(width: 24, height: 24)
                    }
                    .disabled(!ready || waiting || next?.enabled != true)
                    .help("Next section").accessibilityLabel("Next section")
                    .accessibilityIdentifier("guide-next-section")
                }
                .buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 10)
                .fixedSize(horizontal: false, vertical: true)
                Divider().overlay(theme.palette.border)
                if let message = model.surfaceFailureMessage {
                    Text(message).font(ConsoleTypography.caption).foregroundStyle(theme.palette.error)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .accessibilityIdentifier("surface-failure-message")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(zip(SurfaceView.componentKeys(document.article), document.article)), id: \.0) {
                            _, component in
                            ComponentView(component: component).environment(\.astralNavigationSurface, true)
                        }
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(document.selectedID).accessibilityIdentifier("guide-article-scroll")
            }
            .font(ConsoleTypography.subheadline).foregroundStyle(theme.palette.text)
            .background(theme.palette.surface).tint(theme.palette.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
#endif
