import AstralCore
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// A local presentation lease, never a server authorization or provenance claim.
struct CanvasCaptureScope: Equatable {
    let owner: AppModel.DownloadOwner
    let server: URL
    let chat: String
}

struct CanvasCaptureNode: Equatable {
    let scope: CanvasCaptureScope
    let path: String
    let raw: JSONValue

    var identity: JSONValue { raw["component_id"] ?? raw["id"] ?? .null }
}

enum CanvasCaptureError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        "This canvas could not be exported. Make sure its images and charts have loaded, or open it in the web client."
    }
}

private struct CanvasCapturePathKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var canvasCapturePath: String? {
        get { self[CanvasCapturePathKey.self] }
        set { self[CanvasCapturePathKey.self] = newValue }
    }
}

/// Raw indices survive lenient rendering: an invalid child must never move a
/// later child's captured state onto another structural path.
enum CanvasCaptureChildren {
    static func key(_ raw: JSONValue) -> String {
        raw["content"]?.arrayValue != nil ? "content" : "children"
    }

    static func items(_ raw: JSONValue) -> [(index: Int, component: AstralComponent)] {
        (raw[key(raw)]?.arrayValue ?? []).enumerated().compactMap { index, value in
            AstralComponent(json: value).map { (index, $0) }
        }
    }
}

struct CanvasComponentChildren: View {
    let raw: JSONValue
    let path: String?

    var body: some View {
        ForEach(CanvasCaptureChildren.items(raw), id: \.index) { item in
            ComponentView(component: item.component)
                .environment(\.canvasCapturePath, path.map { $0 + "/\(CanvasCaptureChildren.key(raw))/\(item.index)" })
        }
    }
}

@MainActor
final class CanvasCaptureRegistry {
    struct Entry {
        let node: CanvasCaptureNode
        var state: JSONValue?
        var columns: Int?
        var pixels: Data?
        var imageSize: CGSize?
        var lease: UUID?
        var provider: (() async throws -> Data)?
    }

    var currentScope: () -> CanvasCaptureScope? = { nil }
    var currentComponents: (() -> [AstralComponent])?
    private var entries: [String: Entry] = [:]
    private var boundComponents: [AstralComponent]?
    private var boundScope: CanvasCaptureScope?
    private var boundNodes: [String: JSONValue] = [:]
    private(set) var epoch = UUID()
    private var window: CGSize = .zero
    private var canvas: CGSize = .zero
    private var palette: AstralPalette?
    static let maximumPixelBytes = 6 * 1024 * 1024
    static let maximumEntries = 12000
    private static func displayFields(_ component: AstralComponent) -> [String: JSONValue] {
        let common: Set<String> = ["type", "id", "component_id", "css", "style"]
        let fields: [String: Set<String>] = [
            "container": ["content", "children", "direction"], "card": ["title", "content", "children"],
            "grid": ["title", "content", "children", "columns", "gap"],
            "collapsible": ["title", "content", "children", "default_open"],
            "tabs": ["tabs"], "text": ["content", "text", "variant"], "alert": ["title", "message", "variant"],
            "table": ["title", "headers", "rows", "total_rows", "page_size", "page_offset"],
            "list": ["title", "items", "ordered", "content", "children"], "keyvalue": ["title", "items", "pairs"],
            "timeline": ["title", "items"],
            "metric": ["title", "variant", "aria-label", "value", "subtitle", "progress"],
            "hero": ["title", "variant", "heading", "subtitle", "subheading", "eyebrow", "badges"],
            "badge": ["label", "variant"], "code": ["code", "content"], "image": ["alt", "caption"],
            "progress": ["label", "title", "value", "show_percentage"],
            "rating": ["label", "title", "value", "max_value", "max", "show_value", "subtitle"],
            "bar_chart": ["title"], "line_chart": ["title"], "pie_chart": ["title"], "plotly_chart": ["title"],
        ]
        let allowed = common.union(fields[component.type] ?? [])
        var result = (component.raw.objectValue ?? [:]).filter { allowed.contains($0.key) }
        result["type"] = .string(component.type)
        for field in ["title", "variant", "label", "subtitle", "eyebrow", "caption", "alt", "language", "aria-label"] {
            if result[field] != nil, result[field]?.stringValue == nil { result.removeValue(forKey: field) }
        }
        for field in ["total_rows", "page_size", "page_offset", "progress", "width", "height", "max_value", "max"] {
            if result[field] != nil, result[field]?.numberValue == nil { result.removeValue(forKey: field) }
        }
        for field in ["ordered", "show_percentage", "show_value", "default_open"] {
            if result[field] != nil, result[field]?.boolValue == nil { result.removeValue(forKey: field) }
        }
        if ["rating", "progress"].contains(component.type) {
            result["value"] = .number(component.raw["value"]?.numberValue ?? 0)
        }
        let variants: [String: Set<String>] = [
            "text": ["markdown", "h1", "h2", "h3", "caption"],
            "alert": ["error", "danger", "warning", "success", "info", "accent"],
            "badge": ["error", "danger", "warning", "success", "info", "accent"],
            "metric": ["success", "warning", "error"], "hero": ["gradient", "subtle"],
        ]
        if let variant = result["variant"]?.stringValue, !(variants[component.type] ?? []).contains(variant) {
            result.removeValue(forKey: "variant")
        }
        if component.type == "container", component.raw["direction"]?.stringValue != "row" {
            result.removeValue(forKey: "direction")
        }
        switch component.type {
        case "text":
            result["content"] = .string(component.textContent ?? component.fallbackText)
            result.removeValue(forKey: "text")
        case "alert": result["message"] = .string(component.message ?? component.fallbackText)
        case "metric": result["value"] = .string(component.value ?? "")
        case "progress", "rating":
            result["label"] = .string(component.label ?? component.title ?? "")
            result.removeValue(forKey: "title")
        case "image":
            result["caption"] = .string(
                component.raw["caption"]?.stringValue ?? component.raw["alt"]?.stringValue ?? "")
        case "badge": result["label"] = .string(component.label ?? component.fallbackText)
        case "code":
            result["code"] = .string(component.textContent ?? component.raw["code"]?.stringValue ?? "")
            result.removeValue(forKey: "content")
        case "hero":
            result["title"] = .string(component.raw["heading"]?.stringValue ?? component.title ?? "")
            result["subtitle"] = .string(
                component.raw["subtitle"]?.stringValue ?? component.raw["subheading"]?.stringValue ?? "")
            result.removeValue(forKey: "heading")
            result.removeValue(forKey: "subheading")
            result["badges"] = .array(
                (component.raw["badges"]?.arrayValue ?? []).map {
                    .object(["label": .string($0["label"]?.stringValue ?? $0.displayText)])
                })
        case "table":
            result["headers"] = .array(component.tableHeaders.map(JSONValue.string))
            result["rows"] = .array(component.tableRows.map { .array($0.map(JSONValue.string)) })
        case "list":
            result["items"] = .array(component.listItems.map(JSONValue.string))
            if !component.listItems.isEmpty {
                result.removeValue(forKey: "children")
                result.removeValue(forKey: "content")
            }
        case "keyvalue":
            result["items"] = .array(
                component.keyValuePairs.map { .object(["label": .string($0.0), "value": .string($0.1)]) })
            result.removeValue(forKey: "pairs")
        case "timeline":
            result["items"] = .array(
                (component.raw["items"]?.arrayValue ?? []).map { item in
                    var display: [String: JSONValue] = [
                        "title": .string(item["title"]?.stringValue ?? item["label"]?.stringValue ?? item.displayText)
                    ]
                    for key in ["time", "description"] {
                        if let text = item[key]?.stringValue { display[key] = .string(text) }
                    }
                    if let variant = item["variant"]?.stringValue,
                        ["error", "danger", "warning", "success", "info", "accent"].contains(variant)
                    {
                        display["variant"] = .string(variant)
                    }
                    return .object(display)
                })
        default: break
        }
        return result
    }

    /// Keep the whole displayed tree, including hidden panes and offscreen
    /// rows. Only exact removed/replaced paths release their retained media.
    private func reconcile() {
        guard let currentComponents else { return }
        let components = currentComponents()
        let scope = currentScope()
        guard components != boundComponents || scope != boundScope else { return }
        boundComponents = components
        boundScope = scope
        var nodes: [String: JSONValue] = [:]
        var valid = scope != nil
        func walk(_ raw: JSONValue, path: String, depth: Int) {
            guard valid else { return }
            guard depth <= 32, nodes.count < Self.maximumEntries else {
                valid = false
                return
            }
            guard raw.objectValue != nil, raw["type"]?.stringValue != nil else { return }
            nodes[path] = raw
            for key in ["content", "children"] {
                for (index, child) in (raw[key]?.arrayValue ?? []).enumerated() {
                    walk(child, path: path + "/\(key)/\(index)", depth: depth + 1)
                }
            }
            for (index, tab) in (raw["tabs"]?.arrayValue ?? []).enumerated() {
                for key in ["content", "children"] {
                    for (childIndex, child) in (tab[key]?.arrayValue ?? []).enumerated() {
                        walk(child, path: path + "/tabs/\(index)/\(key)/\(childIndex)", depth: depth + 1)
                    }
                }
            }
        }
        for (index, component) in components.enumerated() {
            var raw = component.raw.objectValue ?? [:]
            raw["type"] = .string(component.type)
            walk(.object(raw), path: "/components/\(index)", depth: 0)
        }
        boundNodes = valid ? nodes : [:]
        entries = entries.filter { $0.value.node.scope == scope && boundNodes[$0.key] == $0.value.node.raw }
        epoch = UUID()
    }

    func clear() {
        entries.removeAll()
        boundComponents = nil
        boundScope = nil
        boundNodes.removeAll()
        palette = nil
        canvas = .zero
        epoch = UUID()
    }

    func setWindow(_ size: CGSize) {
        guard window != size else { return }
        window = size
        epoch = UUID()
    }

    func setCanvas(_ size: CGSize, palette: AstralPalette) {
        guard canvas != size || self.palette != palette else { return }
        canvas = size
        self.palette = palette
        epoch = UUID()
    }

    func node(path: String?, component: AstralComponent) -> CanvasCaptureNode? {
        guard let path, let scope = currentScope() else { return nil }
        var raw = component.raw.objectValue ?? [:]
        raw["type"] = .string(component.type)
        return CanvasCaptureNode(scope: scope, path: path, raw: .object(raw))
    }

    func accepts(_ node: CanvasCaptureNode) -> Bool {
        reconcile()
        return currentScope() == node.scope && (currentComponents == nil || boundNodes[node.path] == node.raw)
    }

    func state(for node: CanvasCaptureNode?) -> JSONValue? {
        guard let node, accepts(node), let entry = entries[node.path], entry.node == node else { return nil }
        return entry.state
    }

    private func entry(_ node: CanvasCaptureNode) -> Entry? {
        guard accepts(node) else { return nil }
        // Drop data from a prior account/chat as soon as any new presentation
        // is observed; resetChatState also clears synchronously.
        entries = entries.filter { $0.value.node.scope == node.scope }
        if let existing = entries[node.path], existing.node == node { return existing }
        guard entries[node.path] != nil || entries.count < Self.maximumEntries else { return nil }
        return Entry(node: node)
    }

    func record(_ node: CanvasCaptureNode?, state: JSONValue? = nil, columns: Int? = nil) {
        guard let node, var next = entry(node) else { return }
        if entries[node.path]?.node == node, next.state == state, next.columns == columns { return }
        next.state = state
        next.columns = columns
        entries[node.path] = next
        epoch = UUID()
    }

    func register(_ node: CanvasCaptureNode, lease: UUID, provider: @escaping () async throws -> Data) {
        guard var next = entry(node) else { return }
        guard next.lease != lease else { return }
        next.lease = lease
        next.provider = provider
        next.pixels = nil
        entries[node.path] = next
        epoch = UUID()
    }

    func retain(_ pixels: Data?, for node: CanvasCaptureNode, lease: UUID? = nil, imageSize: CGSize? = nil) {
        guard var next = entry(node), lease == nil || next.lease == lease else { return }
        let otherBytes = entries.filter { $0.key != node.path }.values.reduce(0) { $0 + ($1.pixels?.count ?? 0) }
        let bounded = pixels.flatMap { $0.count <= Self.maximumPixelBytes - otherBytes ? $0 : nil }
        guard next.pixels != bounded || next.imageSize != imageSize || entries[node.path]?.node != node else { return }
        next.pixels = bounded
        next.imageSize = imageSize
        entries[node.path] = next
        epoch = UUID()
    }

    func unmount(_ node: CanvasCaptureNode, lease: UUID, pixels: Data?) {
        guard accepts(node), var next = entries[node.path], next.node == node, next.lease == lease else { return }
        next.provider = nil
        entries[node.path] = next
        retain(pixels, for: node, lease: lease)
    }

    func capture(_ components: [AstralComponent], timeout: Duration = .seconds(20), isCurrent: () -> Bool) async throws
        -> Data
    {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        reconcile()
        try Task.checkCancellation()
        guard isCurrent(), let scope = currentScope(), let palette,
            (64...4096).contains(canvas.width), (32...16384).contains(canvas.height),
            (64...16384).contains(window.width), (32...16384).contains(window.height), canvas.width <= window.width
        else { throw CanvasCaptureError.unavailable }
        let frozenEpoch = epoch
        let frozen = entries
        var state: [JSONValue] = []
        var images: [JSONValue] = []
        var count = 0
        var pixelBytes = 0
        let charts: Set<String> = ["bar_chart", "line_chart", "pie_chart", "plotly_chart"]
        func check() throws {
            reconcile()
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw CanvasCaptureError.unavailable }
            guard isCurrent(), currentScope() == scope, epoch == frozenEpoch else { throw CancellationError() }
        }
        func walk(_ raw: JSONValue, path: String, depth: Int) async throws -> JSONValue {
            try check()
            count += 1
            guard depth <= 32, count <= Self.maximumEntries, var object = raw.objectValue,
                let type = raw["type"]?.stringValue
            else { throw CanvasCaptureError.unavailable }
            // Refuse unsupported authored styling before any captured data is
            // posted. Metadata in unused scalar fields never becomes display.
            for key in ["css", "style"] {
                if let authored = raw[key], ![JSONValue.null, .string(""), .object([:])].contains(authored) {
                    throw CanvasCaptureError.unavailable
                }
            }
            for key in ["id", "component_id"] {
                if let value = raw[key], value != .null, value.stringValue == nil {
                    throw CanvasCaptureError.unavailable
                }
            }
            let node = CanvasCaptureNode(scope: scope, path: path, raw: raw)
            let saved = frozen[path].flatMap { $0.node == node ? $0 : nil }
            object = Self.displayFields(AstralComponent(type: type, raw: raw))
            if type == "tabs" || type == "collapsible" {
                guard let local = saved?.state else { throw CanvasCaptureError.unavailable }
                state.append(
                    .object([
                        "path": .string(path), "component_id": node.identity,
                        "kind": .string(type + "_open"), "value": local,
                    ]))
            }
            if type == "grid" || type == "container" && raw["direction"]?.stringValue == "row" {
                guard let columns = saved?.columns, columns > 0, columns <= 64 else {
                    throw CanvasCaptureError.unavailable
                }
                object["type"] = .string("grid")
                object["columns"] = .number(Double(columns))
                object["gap"] = .number(8)
                object.removeValue(forKey: "direction")
            }
            if type == "image" || charts.contains(type) {
                let pixels: Data
                if let provider = saved?.provider {
                    pixels = try await provider()
                } else if let retained = saved?.pixels {
                    pixels = retained
                } else {
                    throw CanvasCaptureError.unavailable
                }
                try check()
                pixelBytes += pixels.count
                guard !pixels.isEmpty, pixelBytes <= Self.maximumPixelBytes else {
                    throw CanvasCaptureError.unavailable
                }
                images.append(
                    .object([
                        "path": .string(path), "component_id": node.identity,
                        "data_url": .string("data:image/png;base64," + pixels.base64EncodedString()),
                    ]))
                if charts.contains(type) {
                    object = object.filter { ["type", "component_id", "id", "title", "css", "style"].contains($0.key) }
                } else {
                    if let size = saved?.imageSize {
                        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                            size.width <= 16384, size.height <= 16384
                        else { throw CanvasCaptureError.unavailable }
                        object["width"] = .number(size.width)
                        object["height"] = .number(size.height)
                    }
                    for key in ["url", "src", "source"] { object.removeValue(forKey: key) }
                }
            }
            let childList =
                type == "list" && AstralComponent(type: type, raw: raw).listItems.isEmpty
                && !CanvasCaptureChildren.items(raw).isEmpty
            if childList { object["type"] = .string("container") }
            if ["container", "card", "grid", "collapsible"].contains(type) || childList {
                guard object["content"] == nil || object["children"] == nil else {
                    throw CanvasCaptureError.unavailable
                }
                for key in ["content", "children"] where object[key] != nil {
                    guard let children = object[key]?.arrayValue else { throw CanvasCaptureError.unavailable }
                    if type == "collapsible" && saved?.state == .bool(false) {
                        object[key] = .array([])
                    } else {
                        var next: [JSONValue] = []
                        for (index, child) in children.enumerated() {
                            next.append(try await walk(child, path: path + "/\(key)/\(index)", depth: depth + 1))
                        }
                        object[key] = .array(next)
                    }
                }
            } else if type == "tabs" {
                guard let tabs = raw["tabs"]?.arrayValue, let selected = saved?.state?.arrayValue else {
                    throw CanvasCaptureError.unavailable
                }
                var nextTabs: [JSONValue] = []
                for (index, tab) in tabs.enumerated() {
                    guard var next = tab.objectValue else { throw CanvasCaptureError.unavailable }
                    next = next.filter { ["label", "content", "children"].contains($0.key) }
                    next["label"] = .string(tab["label"]?.stringValue ?? "Tab \(index + 1)")
                    guard next["content"] == nil || next["children"] == nil else {
                        throw CanvasCaptureError.unavailable
                    }
                    for key in ["content", "children"] where next[key] != nil {
                        guard let children = next[key]?.arrayValue else { throw CanvasCaptureError.unavailable }
                        var nextChildren: [JSONValue] = []
                        if selected.contains(.number(Double(index))) {
                            for (childIndex, child) in children.enumerated() {
                                nextChildren.append(
                                    try await walk(
                                        child, path: path + "/tabs/\(index)/\(key)/\(childIndex)", depth: depth + 1))
                            }
                        }
                        next[key] = .array(nextChildren)
                    }
                    nextTabs.append(.object(next))
                }
                object["tabs"] = .array(nextTabs)
            }
            return .object(object)
        }
        var tree: [JSONValue] = []
        for (index, component) in components.enumerated() {
            var raw = component.raw.objectValue ?? [:]
            raw["type"] = .string(component.type)
            tree.append(try await walk(.object(raw), path: "/components/\(index)", depth: 0))
        }
        try check()
        let result = try JSONValue.object([
            "version": .string(CanvasExportPolicy.version), "components": .array(tree),
            "display_state": .array(state), "images": .array(images), "theme": try palette.exportColors(),
            "viewport": .object([
                "width": .number(canvas.width), "height": .number(canvas.height),
                "window_width": .number(window.width), "window_height": .number(window.height),
            ]),
        ]).encoded()
        guard result.count <= CanvasExportPolicy.maximumInputBytes else { throw CanvasCaptureError.unavailable }
        return result
    }
}

extension AstralPalette {
    @MainActor
    func exportColors() throws -> JSONValue {
        let roles = [
            "bg": bg, "surface": surface, "surface2": surface2, "border": border, "primary": primary,
            "secondary": secondary, "accent": accent, "text": text, "muted": muted,
            "success": success, "warning": warning, "error": error, "info": info,
        ]
        var colors: [String: JSONValue] = [:]
        for (name, color) in roles {
            let rgba: [CGFloat]
            #if os(macOS)
                guard let value = NSColor(color).usingColorSpace(.sRGB) else { throw CanvasCaptureError.unavailable }
                rgba = [value.redComponent, value.greenComponent, value.blueComponent, value.alphaComponent]
            #else
                var r: CGFloat = 0
                var g: CGFloat = 0
                var b: CGFloat = 0
                var a: CGFloat = 0
                guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else {
                    throw CanvasCaptureError.unavailable
                }
                rgba = [r, g, b, a]
            #endif
            guard rgba.allSatisfy({ $0.isFinite && (0...1).contains($0) }), name == "border" || rgba[3] == 1 else {
                throw CanvasCaptureError.unavailable
            }
            colors[name] = .string(
                "#"
                    + rgba.prefix(name == "border" ? 4 : 3).map { String(format: "%02X", Int(($0 * 255).rounded())) }
                    .joined())
        }
        return .object(colors)
    }
}

/// Render only the Image already returned by AsyncImage. No URLSession,
/// authenticated URL, file access or image refetch participates in capture.
struct CanvasLoadedImage: View {
    let image: Image
    let node: CanvasCaptureNode?
    let registry: CanvasCaptureRegistry
    @State private var size: CGSize = .zero

    var body: some View {
        image.resizable().scaledToFit()
            .background {
                GeometryReader { geometry in
                    Color.clear.onAppear {
                        size = geometry.size
                        retain()
                    }
                    .onChange(of: geometry.size) { _, value in
                        size = value
                        retain()
                    }
                }
            }
            .onChange(of: node) { _, _ in retain() }
            .onChange(of: image) { _, _ in retain() }
    }

    @MainActor
    private func retain() {
        guard let node, registry.accepts(node), size.width.isFinite, size.height.isFinite,
            size.width > 0, size.height > 0, size.width <= 16384, size.height <= 16384
        else { return }
        let renderer = ImageRenderer(
            content: image.resizable().scaledToFit().frame(width: size.width, height: size.height))
        renderer.scale = min(2, 4096 / max(size.width, size.height))
        guard let cgImage = renderer.cgImage, cgImage.width > 0, cgImage.height > 0,
            cgImage.width <= 4096, cgImage.height <= 4096
        else {
            registry.retain(nil, for: node)
            return
        }
        #if os(macOS)
            let pixels = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        #else
            let pixels = UIImage(cgImage: cgImage).pngData()
        #endif
        registry.retain(pixels, for: node, imageSize: size)
    }
}

enum CanvasCaptureFile {
    static func write(_ html: Data) throws -> URL {
        guard !html.isEmpty, html.count <= CanvasExportPolicy.maximumOutputBytes else {
            throw CanvasCaptureError.unavailable
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "astral-downloads", isDirectory: true
        )
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("astraldeep-canvas.html")
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw CanvasCaptureError.unavailable }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.write(contentsOf: html)
        complete = true
        return file
    }
}
