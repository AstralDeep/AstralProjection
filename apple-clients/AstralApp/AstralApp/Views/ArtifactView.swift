// Renders the server's native `artifact` page: a header with title, kind, version, labeled actions and the
// component chrome, then bounded sections whose children render through ComponentView. ChatView's CanvasArea
// gives the newest artifact the canvas, and MacWorkbenchView uses ArtifactArrival when the browser pane hides it.

import AstralCore
import SwiftUI

struct ArtifactDocument: Equatable {
    static let types: Set<String> = ["artifact", "html_artifact"]
    static let kinds: Set<String> = ["report", "dashboard", "document", "app", "analysis"]
    static let maximumSections = 12
    static let maximumDepth = 3
    static let maximumDescendants = 60
    static let collapseWidth: CGFloat = 560

    enum Layout: String, Equatable {
        case stack
        case grid2 = "grid-2"
        case grid3 = "grid-3"

        var authoredColumns: Int {
            switch self {
            case .stack: return 1
            case .grid2: return 2
            case .grid3: return 3
            }
        }

        func columns(width: CGFloat) -> Int {
            guard width.isFinite, width >= ArtifactDocument.collapseWidth else { return 1 }
            return authoredColumns
        }
    }

    enum Action: String, Equatable, CaseIterable {
        case copy, export, share, open
    }

    struct ActionItem: Equatable {
        let label: String
        let action: Action
    }

    struct Child: Equatable {
        let index: Int
        let component: AstralComponent
    }

    struct Section: Equatable, Identifiable {
        let id: String
        let index: Int
        let heading: String
        let layout: Layout
        let children: [Child]
    }

    let id: String
    let title: String
    let kind: String?
    let subtitle: String
    let summary: String
    let version: Int?
    let sections: [Section]
    let actions: [ActionItem]
    let referencedIds: Set<String>

    init(component: AstralComponent, references: [String: AstralComponent] = [:]) {
        let raw = component.raw
        id = Self.text(raw["id"], 120).isEmpty ? Self.text(raw["component_id"], 120) : Self.text(raw["id"], 120)
        title = Self.text(raw["title"], 120)
        let kind = Self.text(raw["kind"], 40).lowercased()
        self.kind = Self.kinds.contains(kind) ? kind : nil
        subtitle = Self.text(raw["subtitle"], 200)
        summary = Self.text(raw["summary"], 400)
        version = Self.version(raw["version"])
        var budget = Self.maximumDescendants
        var referenced = Set<String>()
        var sections: [Section] = []
        for (index, value) in (raw["sections"]?.arrayValue ?? []).enumerated() {
            guard sections.count < Self.maximumSections, value.objectValue != nil else { continue }
            var children: [Child] = []
            for (childIndex, child) in (value["children"]?.arrayValue ?? []).enumerated() {
                guard
                    let bounded = Self.bounded(
                        child, depth: 1, budget: &budget, references: references, referenced: &referenced),
                    let rendered = AstralComponent(json: bounded)
                else { continue }
                children.append(Child(index: childIndex, component: rendered))
            }
            let sectionId = Self.text(value["id"], 64)
            sections.append(
                Section(
                    id: sectionId.isEmpty ? "s\(index + 1)" : sectionId, index: index,
                    heading: Self.text(value["heading"], 80),
                    layout: Layout(rawValue: Self.text(value["layout"], 16)) ?? .stack, children: children))
        }
        self.sections = sections
        referencedIds = referenced
        var seen = Set<Action>()
        actions = (raw["actions"]?.arrayValue ?? []).compactMap { value in
            guard let action = Action(rawValue: Self.text(value["action"], 16)), seen.insert(action).inserted
            else { return nil }
            let label = Self.text(value["label"], 40)
            return ActionItem(label: label.isEmpty ? action.rawValue.capitalized : label, action: action)
        }
    }

    static func references(in canvas: [AstralComponent]) -> [String: AstralComponent] {
        var table: [String: AstralComponent] = [:]
        var duplicates = Set<String>()
        for component in canvas where !types.contains(component.type) {
            guard let id = component.raw["component_id"]?.stringValue, !id.isEmpty else { continue }
            if table.updateValue(component, forKey: id) != nil { duplicates.insert(id) }
        }
        return table.filter { !duplicates.contains($0.key) }
    }

    var plainText: String {
        var lines: [String] = []
        if !title.isEmpty { lines.append(title) }
        for line in [subtitle, summary] where !line.isEmpty { lines.append(line) }
        for section in sections {
            lines.append("")
            if !section.heading.isEmpty { lines.append(section.heading) }
            for child in section.children {
                let text = child.component.fallbackText
                if !text.isEmpty, text != "[\(child.component.type)]" { lines.append(text) }
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func text(_ value: JSONValue?, _ maximum: Int) -> String {
        let string = (value?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(string.unicodeScalars.prefix(maximum))
    }

    static func version(_ value: JSONValue?) -> Int? {
        guard let number = value?.numberValue, number.isFinite, number >= 1, number <= 1_000_000,
            number.rounded(.towardZero) == number
        else { return nil }
        return Int(number)
    }

    private static func bounded(
        _ value: JSONValue, depth: Int, budget: inout Int, references: [String: AstralComponent],
        referenced: inout Set<String>
    ) -> JSONValue? {
        guard budget > 0, var object = value.objectValue, let type = object["type"]?.stringValue, !type.isEmpty
        else { return nil }
        if type == "ref" {
            let id = object["component_id"]?.stringValue ?? object["id"]?.stringValue ?? ""
            guard !referenced.contains(id), let resolved = references[id], var target = resolved.raw.objectValue
            else { return nil }
            referenced.insert(id)
            target["type"] = .string(resolved.type)
            object = target
        }
        guard let resolvedType = object["type"]?.stringValue, !types.contains(resolvedType) else { return nil }
        budget -= 1
        for key in ["content", "children"] {
            guard let nested = object[key]?.arrayValue else { continue }
            object[key] = .array(
                depth >= maximumDepth
                    ? []
                    : nested.compactMap {
                        bounded(
                            $0, depth: depth + 1, budget: &budget, references: references, referenced: &referenced)
                    })
        }
        if let tabs = object["tabs"]?.arrayValue {
            object["tabs"] = .array(
                tabs.map { tab in
                    guard var entry = tab.objectValue else { return tab }
                    for key in ["content", "children"] {
                        guard let nested = entry[key]?.arrayValue else { continue }
                        entry[key] = .array(
                            depth >= maximumDepth
                                ? []
                                : nested.compactMap {
                                    bounded(
                                        $0, depth: depth + 1, budget: &budget, references: references,
                                        referenced: &referenced)
                                })
                    }
                    return .object(entry)
                })
        }
        return .object(object)
    }
}

enum ArtifactAccessibility {
    static func root(_ id: String) -> String { "artifact.\(id)" }
    static func title(_ id: String) -> String { root(id) + ".title" }
    static func section(_ id: String, _ section: String) -> String { root(id) + ".section." + section }
    static func control(_ id: String, _ name: String) -> String { root(id) + "." + name }
}

enum CanvasArtifactFocus {
    static var types: Set<String> {
        #if os(macOS)
            return ArtifactDocument.types
        #else
            return ["artifact"]
        #endif
    }

    static func index(in canvas: [AstralComponent]) -> Int? {
        canvas.lastIndex { types.contains($0.type) }
    }

    static func identity(of canvas: [AstralComponent]) -> String? {
        guard let index = index(in: canvas) else { return nil }
        let raw = canvas[index].raw
        let id = raw["component_id"]?.stringValue ?? raw["id"]?.stringValue ?? "\(index)"
        let version = ArtifactDocument.version(raw["version"]).map(String.init) ?? ""
        return "\(canvas[index].type):\(id):\(version)"
    }

    static func hidden(in canvas: [AstralComponent], focus: Int) -> Set<String> {
        guard canvas.indices.contains(focus), canvas[focus].type == "artifact" else { return [] }
        return ArtifactDocument(
            component: canvas[focus], references: ArtifactDocument.references(in: canvas)
        ).referencedIds
    }
}

struct ArtifactArrival: Equatable {
    private(set) var latest: String?
    private(set) var unseen = false

    mutating func canvasChanged(_ identity: String?, browserPresented: Bool, running: Bool) -> Bool {
        defer { latest = identity }
        guard let identity, identity != latest, browserPresented else { return false }
        if running {
            unseen = true
            return false
        }
        unseen = false
        return true
    }

    mutating func browserChanged(presented: Bool) {
        if !presented { unseen = false }
    }

    mutating func runChanged(running: Bool) -> Bool {
        guard !running, unseen else { return false }
        unseen = false
        return true
    }
}

struct ArtifactView: View {
    let component: AstralComponent
    var onChromeAction: ((ComponentActionTarget) -> Void)? = nil
    @Environment(ThemeStore.self) private var theme
    @Environment(AppModel.self) private var model
    @Environment(\.canvasCapturePath) private var capturePath
    @Environment(\.astralComponentActionOwner) private var inheritedOwner
    @State private var width: CGFloat = 0
    @State private var exportContext: AppModel.WorkspaceActionContext?
    private var p: AstralPalette { theme.palette }

    var body: some View {
        let document = ArtifactDocument(
            component: component, references: ArtifactDocument.references(in: model.workspaceCanvas))
        VStack(alignment: .leading, spacing: ComponentSpacing.loose) {
            header(document)
            ForEach(document.sections) { section in
                sectionView(section, document: document)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { geometry in
                Color.clear.onAppear { width = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, value in
                        if abs(value - width) > 1 { width = value }
                    }
            }
        }
        .sheet(item: $exportContext) { context in
            if let url = model.workspaceExportURL(context) {
                ExportDownloadSheet(url: url, filename: Self.filename(document.title), workspaceExport: context)
            }
        }
        .onChange(of: exportContext.map(model.workspaceActionIsCurrent) ?? false) { _, current in
            if !current { exportContext = nil }
        }
        .environment(
            \.astralComponentActionOwner,
            model.workspaceCanvas.contains(component) && ComponentChromeModel.canonicalIdentity(of: component) != nil
                ? component : inheritedOwner
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ArtifactAccessibility.root(document.id))
    }

    static func filename(_ title: String) -> String {
        let slug = String(title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return (slug.isEmpty ? "astraldeep-artifact" : String(slug.prefix(60))) + ".html"
    }

    private func header(_ document: ArtifactDocument) -> some View {
        VStack(alignment: .leading, spacing: ComponentSpacing.tight) {
            HStack(alignment: .top, spacing: ComponentSpacing.regular) {
                VStack(alignment: .leading, spacing: 8) {
                    if document.kind != nil || document.version != nil {
                        HStack(spacing: 8) {
                            if let kind = document.kind {
                                ArtifactChip(text: kind.capitalized, palette: p, accent: true)
                            }
                            if let version = document.version { ArtifactChip(text: "v\(version)", palette: p) }
                        }
                    }
                    if !document.title.isEmpty {
                        Text(verbatim: document.title)
                            .font(ConsoleTypography.sans(28, relativeTo: .largeTitle).weight(.semibold))
                            .foregroundStyle(p.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier(ArtifactAccessibility.title(document.id))
                    }
                    if !document.subtitle.isEmpty {
                        Text(verbatim: document.subtitle)
                            .font(ComponentTypeScale.heading.weight(.regular)).foregroundStyle(p.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                actionBar(document)
            }
            if !document.summary.isEmpty {
                Text(verbatim: document.summary)
                    .font(ComponentTypeScale.body).foregroundStyle(p.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            p.border.frame(height: 1).accessibilityHidden(true)
        }
    }

    private func actionBar(_ document: ArtifactDocument) -> some View {
        let share =
            document.actions.contains { $0.action == .share } && onChromeAction != nil
            && model.componentActionContext(for: .share, component: component) != nil
        return VStack(alignment: .trailing, spacing: 2) {
            AstralToolbarLayout(wraps: true, spacing: 8) {
                ForEach(document.actions, id: \.action) { item in
                    actionButton(item, document: document, share: share)
                }
                if let onChromeAction {
                    ComponentChromeActions(
                        component: component, onAction: onChromeAction, excluding: share ? [.share] : [])
                }
            }
            ProvenanceBadge(kind: component.raw["provenance"]?.stringValue)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func actionButton(_ item: ArtifactDocument.ActionItem, document: ArtifactDocument, share: Bool) -> some View
    {
        switch item.action {
        case .copy:
            ComponentCopyButton(text: document.plainText, palette: p, label: item.label)
                .accessibilityIdentifier(ArtifactAccessibility.control(document.id, "copy"))
        case .export:
            if onChromeAction != nil, let context = model.workspaceActionContext(for: .exportCanvas) {
                Button(item.label) {
                    if exportContext == nil { exportContext = context }
                }
                .buttonStyle(AstralButtonStyle(palette: p, variant: "secondary"))
                .disabled(model.workspaceActionInFlight(.exportCanvas) || exportContext != nil)
                .accessibilityIdentifier(ArtifactAccessibility.control(document.id, "export"))
            }
        case .share:
            if share, let onChromeAction {
                Button(item.label) {
                    if let context = model.componentActionContext(for: .share, component: component) {
                        onChromeAction(ComponentActionTarget(context: context))
                    }
                }
                .buttonStyle(AstralButtonStyle(palette: p, variant: "secondary"))
                .accessibilityIdentifier(ArtifactAccessibility.control(document.id, "share"))
            }
        case .open:
            EmptyView()
        }
    }

    private func sectionView(_ section: ArtifactDocument.Section, document: ArtifactDocument) -> some View {
        let columns = section.layout.columns(width: width)
        return VStack(alignment: .leading, spacing: ComponentSpacing.tight) {
            if !section.heading.isEmpty {
                Text(verbatim: section.heading)
                    .font(ComponentTypeScale.heading).foregroundStyle(p.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            if columns > 1 {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: ComponentSpacing.regular, alignment: .top),
                        count: columns),
                    alignment: .leading, spacing: ComponentSpacing.regular
                ) {
                    children(section)
                }
            } else {
                VStack(alignment: .leading, spacing: ComponentSpacing.regular) { children(section) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ArtifactAccessibility.section(document.id, section.id))
    }

    private func children(_ section: ArtifactDocument.Section) -> some View {
        ForEach(section.children, id: \.index) { child in
            ComponentView(component: child.component)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(
                    \.canvasCapturePath,
                    capturePath.map { $0 + "/sections/\(section.index)/children/\(child.index)" })
        }
    }
}

struct ArtifactChip: View {
    let text: String
    let palette: AstralPalette
    var accent = false

    var body: some View {
        let color = accent ? palette.readablePrimary : palette.muted
        Text(verbatim: text)
            .font(ComponentTypeScale.caption.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.3)))
            .fixedSize()
    }
}

#if os(macOS)
    struct ArtifactArrivalChip: View {
        let palette: AstralPalette
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Label("New artifact", systemImage: "doc.richtext")
                    .font(ConsoleTypography.caption.weight(.semibold))
                    .foregroundStyle(palette.readablePrimary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(palette.primary.opacity(0.16), in: Capsule())
                    .overlay(Capsule().strokeBorder(palette.primary.opacity(0.4)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("New artifact")
            .accessibilityIdentifier("workbench-new-artifact")
        }
    }

    extension View {
        func artifactArrivalTracking(
            _ arrival: Binding<ArtifactArrival>, model: AppModel, browserPresented: Bool,
            showCanvas: @escaping () -> Void
        ) -> some View {
            let running = model.turnActive || model.macComputerHost.session != nil
            return onAppear {
                _ = arrival.wrappedValue.canvasChanged(
                    CanvasArtifactFocus.identity(of: model.workspaceCanvas), browserPresented: false,
                    running: running)
            }
            .onChange(of: CanvasArtifactFocus.identity(of: model.workspaceCanvas)) { _, identity in
                if arrival.wrappedValue.canvasChanged(identity, browserPresented: browserPresented, running: running) {
                    showCanvas()
                }
            }
            .onChange(of: browserPresented) { _, presented in
                arrival.wrappedValue.browserChanged(presented: presented)
            }
            .onChange(of: running) { _, active in
                if arrival.wrappedValue.runChanged(running: active) { showCanvas() }
            }
        }
    }
#endif
