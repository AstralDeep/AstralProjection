// Reads macOS accessibility trees into bounded snapshots whose a-references resolve back to live elements.
// MacComputerDriver maps frames into screenshot space, revalidates references before effects and walks menu bars here.

#if os(macOS)
    import AppKit
    import ApplicationServices
    import AstralCore
    import Foundation

    nonisolated enum MacComputerAXMode: Sendable {
        case interactive, all
    }

    nonisolated struct MacComputerAXNode {
        let element: AXUIElement
        let role: String
        let subrole: String?
        let roleDescription: String?
        let title: String?
        let detail: String?
        let identifier: String?
        let text: String?
        let number: Double?
        let enabled: Bool
        let focused: Bool
        let selected: Bool?
        let expanded: Bool?
        let frame: CGRect?
        let children: [AXUIElement]
        var secure: Bool { subrole == "AXSecureTextField" || role == "AXSecureTextField" }
        var label: String? {
            for candidate in [title, detail, role == "AXStaticText" ? text : nil] {
                if let candidate, !MacComputerAccessibility.clean(candidate).isEmpty { return candidate }
            }
            return nil
        }
        var name: String {
            if subrole == "AXSearchField" { return "searchfield" }
            if subrole == "AXSwitch" { return "switch" }
            return MacComputerAccessibility.displayRole(role)
        }
        var framed: Bool { frame.map { $0.width > 0 && $0.height > 0 } == true }
    }

    nonisolated struct MacComputerAXMapping {
        let bounds: CGRect
        let width: Int
        let height: Int
        let screenIndex: Int
        func rect(_ frame: CGRect) -> [Int] {
            let sx = Double(width) / max(1, Double(bounds.width))
            let sy = Double(height) / max(1, Double(bounds.height))
            return [
                Int(((frame.minX - bounds.minX) * sx).rounded()), Int(((frame.minY - bounds.minY) * sy).rounded()),
                Int((frame.width * sx).rounded()), Int((frame.height * sy).rounded()),
            ]
        }
        func point(_ point: CGPoint) -> [Int] {
            let sx = Double(width) / max(1, Double(bounds.width))
            let sy = Double(height) / max(1, Double(bounds.height))
            return [Int(((point.x - bounds.minX) * sx).rounded()), Int(((point.y - bounds.minY) * sy).rounded())]
        }
    }

    nonisolated struct MacComputerAXEntry {
        let element: AXUIElement
        let role: String
        let name: String
        let label: String?
        let secure: Bool
    }

    nonisolated struct MacComputerAXSnapshot {
        let id: String
        let pid: pid_t
        let bundle: String
        let app: String
        let hwnd: Int
        let entries: [String: MacComputerAXEntry]
    }

    nonisolated struct MacComputerAXTarget {
        let ref: String
        let snapshot: MacComputerAXSnapshot
        let entry: MacComputerAXEntry
        let frame: CGRect
        var element: AXUIElement { entry.element }
        var pid: pid_t { snapshot.pid }
        var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
        var label: String {
            "\(entry.label.map { MacComputerAccessibility.clean($0) } ?? entry.name) — \(snapshot.app)"
        }
    }

    nonisolated struct MacComputerAXMenuItem {
        let element: AXUIElement
        let title: String
        let enabled: Bool
        let checked: Bool
        let shortcut: String?
        let submenu: AXUIElement?
        let frame: CGRect?
        var json: JSONValue {
            .object([
                "title": .string(String(title.prefix(100))), "enabled": .bool(enabled), "checked": .bool(checked),
                "shortcut": shortcut.map(JSONValue.string) ?? .null, "has_children": .bool(submenu != nil),
            ])
        }
    }

    nonisolated final class MacComputerAccessibility {
        static let maximumSnapshots = 4
        static let visitLimit = 4000
        static let walkSeconds = 5.0
        static let interactiveRoles: Set<String> = [
            "AXButton", "AXTextField", "AXTextArea", "AXSecureTextField", "AXCheckBox", "AXRadioButton",
            "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXMenuBarItem", "AXLink", "AXComboBox", "AXSlider",
            "AXIncrementor", "AXDisclosureTriangle", "AXColorWell", "AXSearchField", "AXTab",
        ]
        static let selectableRoles: Set<String> = ["AXRow", "AXCell", "AXOutlineRow"]
        static let choiceGroups: Set<String> = ["AXTabGroup", "AXRadioGroup"]
        static let readableRoles: Set<String> = ["AXStaticText", "AXImage", "AXHeading", "AXWebArea"]
        static let toggleRoles: Set<String> = ["AXCheckBox", "AXRadioButton", "AXDisclosureTriangle"]
        static let numericRoles: Set<String> = [
            "AXSlider", "AXIncrementor", "AXValueIndicator", "AXProgressIndicator", "AXLevelIndicator",
        ]
        static let readNames = [
            kAXRoleAttribute, kAXSubroleAttribute, kAXRoleDescriptionAttribute, kAXTitleAttribute,
            kAXDescriptionAttribute, kAXIdentifierAttribute, kAXValueAttribute, kAXEnabledAttribute,
            kAXFocusedAttribute, kAXSelectedAttribute, kAXExpandedAttribute, kAXPositionAttribute, kAXSizeAttribute,
            kAXVisibleChildrenAttribute, kAXChildrenAttribute,
        ]
        static let actionVerbs: [String: String] = [
            kAXPressAction: "press", kAXShowMenuAction: "show_menu", kAXConfirmAction: "confirm",
            kAXCancelAction: "cancel", kAXIncrementAction: "increment", kAXDecrementAction: "decrement",
            kAXRaiseAction: "raise",
        ]
        static let desktopConsequential =
            "(?:^|[^a-z0-9])(?:erase|quit|empty\\s+(?:the\\s+)?trash|move\\s+to\\s+(?:the\\s+)?(?:trash|bin))"
            + "(?=$|[^a-z0-9])"

        private let system: any MacComputerSystemIO
        private(set) var snapshots: [MacComputerAXSnapshot] = []
        private var nextSnapshot = 1
        private var nextRef = 1
        private var issued: Set<String> = []
        private var consumed: Set<String> = []

        init(system: any MacComputerSystemIO) { self.system = system }

        func reset() {
            snapshots = []
            issued = []
            consumed = []
        }

        static func element(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }

        static func frame(_ values: [String: CFTypeRef]) -> CGRect? {
            guard let position = values[kAXPositionAttribute], let size = values[kAXSizeAttribute],
                CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
            else { return nil }
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
                AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions),
                point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite
            else { return nil }
            return CGRect(origin: point, size: dimensions)
        }

        func frame(of element: AXUIElement) -> CGRect? {
            Self.frame(system.attributes([kAXPositionAttribute, kAXSizeAttribute], of: element))
        }

        static func displayRole(_ role: String) -> String {
            (role.hasPrefix("AX") ? String(role.dropFirst(2)) : role).lowercased()
        }

        static func normalizedRole(_ text: String) -> String {
            let folded = text.lowercased().filter { !$0.isWhitespace && $0 != "_" && $0 != "-" }
            return folded.hasPrefix("ax") ? String(folded.dropFirst(2)) : folded
        }

        static func clean(_ text: String) -> String {
            let scalars = text.unicodeScalars.map { $0.value < 32 || $0.value == 127 ? " " : Character($0) }
            return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        static func quoted(_ text: String, _ limit: Int) -> String {
            var value = clean(text)
            if value.unicodeScalars.count > limit {
                value = String(String.UnicodeScalarView(value.unicodeScalars.prefix(limit - 1))) + "…"
            }
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"" + escaped + "\""
        }

        static func number(_ value: Double) -> String {
            value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(format: "%.2f", value)
        }

        func read(_ element: AXUIElement) -> MacComputerAXNode? {
            let values = system.attributes(Self.readNames, of: element)
            guard let role = values[kAXRoleAttribute] as? String, !role.isEmpty else { return nil }
            func string(_ name: String) -> String? {
                guard let value = values[name], CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
                return value as? String
            }
            func flag(_ name: String) -> Bool? {
                guard let value = values[name], CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
                return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
            }
            var number: Double?
            if let value = values[kAXValueAttribute] {
                if CFGetTypeID(value) == CFNumberGetTypeID() {
                    number = (value as? NSNumber)?.doubleValue
                } else if CFGetTypeID(value) == CFBooleanGetTypeID() {
                    number = CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self)) ? 1 : 0
                }
            }
            let visible = values[kAXVisibleChildrenAttribute] as? [AXUIElement]
            return MacComputerAXNode(
                element: element, role: role, subrole: string(kAXSubroleAttribute),
                roleDescription: string(kAXRoleDescriptionAttribute), title: string(kAXTitleAttribute),
                detail: string(kAXDescriptionAttribute), identifier: string(kAXIdentifierAttribute),
                text: string(kAXValueAttribute), number: number, enabled: flag(kAXEnabledAttribute) ?? true,
                focused: flag(kAXFocusedAttribute) ?? false, selected: flag(kAXSelectedAttribute),
                expanded: flag(kAXExpandedAttribute), frame: Self.frame(values),
                children: visible ?? (values[kAXChildrenAttribute] as? [AXUIElement]) ?? [])
        }

        static func wanted(_ node: MacComputerAXNode, parent: String?, web: Bool, mode: MacComputerAXMode) -> Bool {
            if interactiveRoles.contains(node.role) || node.subrole == "AXSearchField" || node.secure { return true }
            if selectableRoles.contains(node.role) || node.subrole == "AXOutlineRow", node.selected != nil {
                return true
            }
            if let parent, choiceGroups.contains(parent) { return true }
            guard mode == .all else { return false }
            if node.role == "AXStaticText" { return node.label != nil }
            if readableRoles.contains(node.role) { return true }
            if node.role == "AXGroup", node.label != nil { return true }
            return web && (node.label != nil || node.text.map { !clean($0).isEmpty } == true)
        }

        static func matches(_ node: MacComputerAXNode, query: String, role: String?) -> Bool {
            if let role {
                let wanted = normalizedRole(role)
                guard [node.name, displayRole(node.role), node.subrole.map(displayRole)].contains(wanted) else {
                    return false
                }
            }
            let fields: [String?] = [
                node.name, node.role, node.subrole, node.roleDescription, node.title, node.detail, node.identifier,
                node.secure ? nil : node.text, node.secure ? nil : node.number.map(number),
            ]
            return fields.contains { $0?.lowercased().contains(query) == true }
        }

        func walk(
            _ root: AXUIElement, depth limit: Int, nodes maximum: Int,
            include: (MacComputerAXNode, String?, Bool) -> Bool
        ) -> (nodes: [MacComputerAXNode], truncated: Bool) {
            var queue: [(element: AXUIElement, depth: Int, path: [Int], parent: String?, web: Bool)] = [
                (root, 0, [], nil, false)
            ]
            var head = 0
            var found: [(node: MacComputerAXNode, path: [Int])] = []
            var truncated = false
            let deadline = ProcessInfo.processInfo.systemUptime + Self.walkSeconds
            while head < queue.count {
                if head >= Self.visitLimit || ProcessInfo.processInfo.systemUptime > deadline {
                    truncated = true
                    break
                }
                let item = queue[head]
                head += 1
                system.messagingTimeout(0.25, for: item.element)
                guard let node = read(item.element) else { continue }
                if item.depth > 0, node.framed, include(node, item.parent, item.web) {
                    guard found.count < maximum else {
                        truncated = true
                        break
                    }
                    found.append((node, item.path))
                }
                guard item.depth < limit, !node.secure else { continue }
                let web = item.web || node.role == "AXWebArea"
                for (index, child) in node.children.enumerated() {
                    queue.append((child, item.depth + 1, item.path + [index], node.role, web))
                }
            }
            let ordered = found.sorted { $0.path.lexicographicallyPrecedes($1.path) }.map(\.node)
            return (ordered, truncated)
        }

        func record(pid: pid_t, bundle: String, app: String, hwnd: Int, nodes: [MacComputerAXNode]) throws
            -> (id: String, refs: [String])
        {
            purge()
            guard nextSnapshot < 999_999_999, nextRef + nodes.count < 999_999_999 else {
                throw ComputerHostError("capacity_exceeded", "Accessibility reference capacity is exhausted.")
            }
            let id = "x\(nextSnapshot)"
            nextSnapshot += 1
            var entries: [String: MacComputerAXEntry] = [:]
            var refs: [String] = []
            for node in nodes {
                let ref = "a\(nextRef)"
                nextRef += 1
                refs.append(ref)
                entries[ref] = MacComputerAXEntry(
                    element: node.element, role: node.role, name: node.name, label: node.label, secure: node.secure)
            }
            snapshots.append(
                MacComputerAXSnapshot(id: id, pid: pid, bundle: bundle, app: app, hwnd: hwnd, entries: entries))
            if snapshots.count > Self.maximumSnapshots {
                snapshots.removeFirst(snapshots.count - Self.maximumSnapshots)
            }
            return (id, refs)
        }

        func purge() {
            snapshots.removeAll { system.bundleIdentifier(for: $0.pid) != $0.bundle }
        }

        func resolve(_ ref: String, snapshot id: String, displays: [CGRect]) throws -> MacComputerAXTarget {
            purge()
            guard let snapshot = snapshots.first(where: { $0.id == id }) else {
                throw ComputerHostError(
                    "stale_ref", "Snapshot \(id) expired or its application quit. Take a new ax_tree or ax_find.")
            }
            guard let entry = snapshot.entries[ref] else {
                throw ComputerHostError("stale_ref", "\(ref) is not in snapshot \(id). Take a new ax_tree or ax_find.")
            }
            try ComputerHostTargetPolicy.externalProcess(snapshot.pid, hostPID: system.hostPID)
            system.messagingTimeout(0.25, for: entry.element)
            guard system.pid(of: entry.element) == snapshot.pid,
                (system.attribute(kAXRoleAttribute, of: entry.element) as? String) == entry.role,
                let frame = frame(of: entry.element), frame.width > 0, frame.height > 0
            else {
                throw ComputerHostError(
                    "stale_ref", "\(ref) no longer exists in \(snapshot.app). Take a new ax_tree or ax_find.")
            }
            guard displays.contains(where: { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }) else {
                throw ComputerHostError(
                    "stale_ref", "\(ref) is no longer on screen. Take a new ax_tree or ax_find.")
            }
            return MacComputerAXTarget(ref: ref, snapshot: snapshot, entry: entry, frame: frame)
        }

        func current(_ target: MacComputerAXTarget) -> Bool {
            system.messagingTimeout(0.25, for: target.element)
            return system.pid(of: target.element) == target.pid
                && (system.attribute(kAXRoleAttribute, of: target.element) as? String) == target.entry.role
                && frame(of: target.element) == target.frame
        }

        func secure(_ target: MacComputerAXTarget) -> Bool {
            target.entry.secure
                || (system.attribute(kAXSubroleAttribute, of: target.element) as? String) == "AXSecureTextField"
        }

        static func line(_ ref: String, _ node: MacComputerAXNode, mapping: MacComputerAXMapping, window: CGRect?)
            -> String
        {
            var parts = ["[\(ref)]", node.name]
            if let label = node.label { parts.append(quoted(label, 100)) }
            if let value = value(node) { parts.append("value=" + quoted(value, 100)) }
            let frame = node.frame ?? .zero
            let rect = mapping.rect(frame)
            parts.append("(\(rect[0]),\(rect[1]),\(rect[2]),\(rect[3]))")
            parts.append(contentsOf: states(node, frame: frame, mapping: mapping, window: window))
            return parts.joined(separator: " ")
        }

        static func value(_ node: MacComputerAXNode) -> String? {
            if node.secure || toggleRoles.contains(node.role) || node.subrole == "AXSwitch" { return nil }
            if node.role == "AXStaticText", node.title == nil || node.title?.isEmpty == true,
                node.detail == nil || node.detail?.isEmpty == true
            {
                return nil
            }
            if let text = node.text, !clean(text).isEmpty { return text }
            if let number = node.number, numericRoles.contains(node.role) { return Self.number(number) }
            return nil
        }

        static func states(_ node: MacComputerAXNode, frame: CGRect, mapping: MacComputerAXMapping, window: CGRect?)
            -> [String]
        {
            var states: [String] = []
            if node.focused { states.append("focused") }
            if !node.enabled { states.append("disabled") }
            if node.selected == true { states.append("selected") }
            if ["AXCheckBox", "AXRadioButton"].contains(node.role) || node.subrole == "AXSwitch" {
                if node.number == 1 { states.append("checked") }
                if node.number == 2 { states.append("mixed") }
            }
            if node.role == "AXDisclosureTriangle", let number = node.number {
                states.append(number == 1 ? "expanded" : "collapsed")
            } else if let expanded = node.expanded {
                states.append(expanded ? "expanded" : "collapsed")
            }
            if node.secure { states.append("secure") }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            if !mapping.bounds.contains(center) || window.map({ !$0.contains(center) }) == true {
                states.append("offscreen")
            }
            return states
        }

        func actions(_ node: MacComputerAXNode) -> [String] {
            var verbs = system.actionNames(of: node.element).compactMap { Self.actionVerbs[$0] }
            if system.settable(kAXFocusedAttribute, of: node.element) { verbs.append("focus") }
            if !node.secure, system.settable(kAXValueAttribute, of: node.element) { verbs.append("set_value") }
            if ["AXPopUpButton", "AXMenuButton", "AXComboBox"].contains(node.role) { verbs.append("pick") }
            var seen: Set<String> = []
            return verbs.filter { seen.insert($0).inserted }
        }

        static func reviewLine(_ target: MacComputerAXTarget, value: String?) -> String {
            var parts = ["[\(target.ref)]", target.entry.name]
            if let label = target.entry.label { parts.append(quoted(label, 80)) }
            if let value { parts.append("value=" + quoted(value, 60)) }
            return bounded(parts.joined(separator: " ") + " — " + clean(target.snapshot.app), 200)
        }

        static func menuLine(_ titles: [String], app: String) -> String {
            bounded("menu " + quoted(titles.map(clean).joined(separator: " › "), 140) + " — " + clean(app), 200)
        }

        static func bounded(_ text: String, _ limit: Int) -> String {
            String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit)))
        }

        static func consequential(_ texts: [String?]) -> Bool {
            let values = texts.compactMap { $0 }.map(clean).filter { !$0.isEmpty }
            guard !values.isEmpty else { return false }
            if ComputerBrowserPolicy.isConsequential(
                ComputerBrowserElement(tag: "div", label: values.joined(separator: " ")))
            {
                return true
            }
            return values.contains {
                $0.lowercased().range(of: desktopConsequential, options: .regularExpression) != nil
            }
        }

        func issue(_ key: String) {
            if issued.count >= 256 { issued.removeAll() }
            issued.insert(key)
        }

        func redeem(_ key: String, once: Bool) -> Bool {
            guard issued.remove(key) != nil else { return false }
            if once {
                if consumed.count >= 512 { consumed.removeAll() }
                consumed.insert(key)
            }
            return true
        }

        func isIssued(_ key: String) -> Bool { issued.contains(key) }

        func isConsumed(_ key: String) -> Bool { consumed.contains(key) }

        static func menuTitle(_ title: String) -> String {
            var value = clean(title)
            if value.hasSuffix("…") {
                value.removeLast()
            } else if value.hasSuffix("...") {
                value.removeLast(3)
            }
            return value.trimmingCharacters(in: .whitespaces).lowercased()
        }

        static func shortcut(_ character: String?, modifiers: Int?) -> String? {
            guard let character, !clean(character).isEmpty else { return nil }
            let mask = modifiers ?? 0
            var text = ""
            if mask & 4 != 0 { text += "⌃" }
            if mask & 2 != 0 { text += "⌥" }
            if mask & 1 != 0 { text += "⇧" }
            if mask & 8 == 0 { text += "⌘" }
            return text + clean(character).uppercased()
        }

        func submenu(of element: AXUIElement) -> AXUIElement? {
            let children = system.attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
            return children.first { (system.attribute(kAXRoleAttribute, of: $0) as? String) == "AXMenu" }
        }

        func menuItems(of container: AXUIElement) -> [MacComputerAXMenuItem] {
            system.messagingTimeout(0.25, for: container)
            let children = system.attribute(kAXChildrenAttribute, of: container) as? [AXUIElement] ?? []
            return children.prefix(200).compactMap { element in
                system.messagingTimeout(0.25, for: element)
                let values = system.attributes(
                    [
                        kAXRoleAttribute, kAXTitleAttribute, kAXEnabledAttribute, kAXMenuItemMarkCharAttribute,
                        kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute, kAXPositionAttribute,
                        kAXSizeAttribute,
                    ], of: element)
                guard let role = values[kAXRoleAttribute] as? String, ["AXMenuItem", "AXMenuBarItem"].contains(role),
                    let title = values[kAXTitleAttribute] as? String, !Self.clean(title).isEmpty
                else { return nil }
                let mark = values[kAXMenuItemMarkCharAttribute] as? String
                return MacComputerAXMenuItem(
                    element: element, title: Self.clean(title), enabled: values[kAXEnabledAttribute] as? Bool ?? true,
                    checked: mark.map { !Self.clean($0).isEmpty } == true,
                    shortcut: Self.shortcut(
                        values[kAXMenuItemCmdCharAttribute] as? String,
                        modifiers: (values[kAXMenuItemCmdModifiersAttribute] as? NSNumber)?.intValue),
                    submenu: submenu(of: element), frame: Self.frame(values))
            }
        }

        func menuChoice(under element: AXUIElement, title: String)
            -> (item: AXUIElement?, menu: AXUIElement?, titles: [String])
        {
            guard let menu = submenu(of: element) else { return (nil, nil, []) }
            let items = menuItems(of: menu)
            let wanted = Self.menuTitle(title)
            return (items.first { Self.menuTitle($0.title) == wanted }?.element, menu, items.map(\.title))
        }

        static func check(_ result: AXError, _ action: String) throws {
            switch result {
            case .success: return
            case .actionUnsupported, .attributeUnsupported, .notImplemented, .parameterizedAttributeUnsupported:
                throw ComputerHostError("unsupported", "The element does not support \(action).")
            case .invalidUIElement:
                throw ComputerHostError("stale_ref", "The element no longer exists. Take a new ax_tree or ax_find.")
            case .illegalArgument:
                throw ComputerHostError("out_of_range", "The application rejected the \(action) value.")
            case .apiDisabled:
                throw ComputerHostError("permission_denied", "Allow Accessibility access in System Settings.")
            case .cannotComplete:
                throw ComputerHostError("failed", "The application did not respond to \(action).")
            default:
                throw ComputerHostError("failed", "The accessibility \(action) failed.")
            }
        }
    }
#endif
