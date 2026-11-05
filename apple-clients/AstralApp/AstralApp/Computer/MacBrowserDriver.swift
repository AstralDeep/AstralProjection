// Executes the browser verbs on the active tab of the Mac browser pane, acting only on approved origins, refusing
// stale references and secret fields, and holding consequential controls until a matching server permit or a request
// the server marked bypass-approved. MacComputerHost routes browser_* requests here and MacBrowserPaneView shows tabs.

#if os(macOS)
    import AppKit
    import AstralCore
    import CryptoKit
    import Foundation
    import Observation

    struct MacBrowserTab: Identifiable, Equatable {
        let id: String
        let pane: MacBrowserPane
        static func == (lhs: MacBrowserTab, rhs: MacBrowserTab) -> Bool { lhs.id == rhs.id && lhs.pane === rhs.pane }
    }

    @MainActor @Observable
    final class MacBrowserDriver: MacBrowserVerbHandling {
        private struct Target {
            let token: String
            let local: Int
            let snapshot: String
            let frame: MacBrowserFrame
        }
        private struct Snapshot {
            let id: String
            let tab: String
            let generation: Int
            let refs: Set<String>
        }
        private struct Described {
            let element: ComputerBrowserElement
            let line: String
            let secret: Bool
        }

        static let preferencePrefix = "computer.browser_pane."
        static let maximumImageBytes = 2_900_000
        static let maximumZoomWidth: CGFloat = 1920
        static let maximumEvaluationBytes = 51_200
        static let maximumTabs = 8
        static let embeddedViewRefusers: Set<String> = ["accounts.google.com"]
        static let longVerbs: Set<String> = ["browser_navigate", "browser_wait", "browser_evaluate", "browser_tabs"]

        let context: MacBrowserContext
        private(set) var tabs: [MacBrowserTab]
        private(set) var activeTabId: String
        private(set) var emulation: ComputerBrowserViewport?
        private(set) var emulationPreset = "desktop"
        private(set) var colorScheme: String?
        var isPresented = false
        private(set) var driving = false
        private(set) var paneEnabled = false
        private(set) var lastError: String?
        @ObservationIgnored weak var host: MacComputerHost?
        @ObservationIgnored var takeover: () -> Void
        @ObservationIgnored var agentActive: () -> Bool
        @ObservationIgnored var bypassActive: () -> Bool
        @ObservationIgnored private var bypassedRequest = false
        @ObservationIgnored private let defaults: UserDefaults
        @ObservationIgnored private let shortVerbTimeoutCeiling: Double
        @ObservationIgnored private var owner: String?
        @ObservationIgnored private var sessionId: String?
        @ObservationIgnored private(set) var approved: Set<String> = []
        @ObservationIgnored private var snapshots: [Snapshot] = []
        @ObservationIgnored private var refs: [String: (token: String, local: Int)] = [:]
        @ObservationIgnored private var index: [String: String] = [:]
        @ObservationIgnored private var refGeneration = -1
        @ObservationIgnored private var refTab = ""
        @ObservationIgnored private var working: MacBrowserTab?
        @ObservationIgnored private var nextTab = 2
        @ObservationIgnored private var nextRef = 1
        @ObservationIgnored private var nextSnapshot = 1
        @ObservationIgnored private var issued: Set<String> = []
        @ObservationIgnored private var granted: Set<String> = []
        @ObservationIgnored private var consumed: Set<String> = []
        @ObservationIgnored private var running = 0
        @ObservationIgnored private var settleUntil = 0.0
        @ObservationIgnored private var linger: Task<Void, Never>?

        init(
            host: MacComputerHost?, defaults: UserDefaults = .standard, pane: MacBrowserPane? = nil,
            shortVerbTimeoutCeiling: Double = 5.0
        ) {
            let first = pane ?? MacBrowserPane()
            context = first.context
            tabs = [MacBrowserTab(id: "t1", pane: first)]
            activeTabId = "t1"
            self.defaults = defaults
            self.shortVerbTimeoutCeiling = shortVerbTimeoutCeiling
            self.host = host
            takeover = { [weak host] in host?.takeover() }
            agentActive = { [weak host] in host?.session?.state == "active" }
            bypassActive = { [weak host] in host?.bypass == true }
            install(first)
            refTab = "t1"
            host?.browser = self
        }

        var activeTab: MacBrowserTab { tabs.first { $0.id == activeTabId } ?? tabs[0] }
        var pane: MacBrowserPane { activeTab.pane }
        private var page: MacBrowserPane { (working ?? activeTab).pane }
        private var pageTab: String { (working ?? activeTab).id }

        var isEnabled: Bool { paneEnabled && owner != nil && pane.unavailable == nil }
        var accountBound: Bool { owner != nil }

        func bind(owner: String?) {
            guard self.owner != owner else { return }
            self.owner = owner
            paneEnabled = preferenceKey.map { defaults.bool(forKey: $0) } ?? false
            for tab in tabs.dropFirst() { retire(tab) }
            tabs = Array(tabs.prefix(1))
            activeTabId = tabs[0].id
            emulation = nil
            emulationPreset = "desktop"
            colorScheme = nil
            applyViewport()
            resetSession(nil)
            if !paneEnabled { isPresented = false }
        }

        private func install(_ pane: MacBrowserPane) {
            pane.navigationRule = { [weak self] url, user in self?.allows(url, userInitiated: user) ?? false }
            pane.humanInput = { [weak self] in self?.humanInput() }
        }

        private var preferenceKey: String? {
            owner.map {
                Self.preferencePrefix + SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
            }
        }

        func setPaneEnabled(_ value: Bool) {
            guard let key = preferenceKey else { return }
            defaults.set(value, forKey: key)
            paneEnabled = value
            if !value {
                resetSession(nil)
                isPresented = false
            }
            host?.workspacesChanged()
        }

        func handle(
            _ request: ComputerHostRequest, ticket: ComputerHostTicket,
            authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue] {
            guard isEnabled else {
                throw ComputerHostError("unsupported", "The browser pane is turned off on this Mac.")
            }
            return try await execute(
                request.verb, args: request.args, session: request.sessionId,
                remaining: ticket.expiresAt - ProcessInfo.processInfo.systemUptime,
                approvalSource: request.approvalSource, authorize: authorize)
        }

        func execute(
            _ verb: String, args: [String: JSONValue], session: String, remaining: Double,
            approvalSource: String? = nil, authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue] {
            try authorize()
            bypassedRequest = approvalSource == "bypass" && bypassActive()
            defer { bypassedRequest = false }
            if session != sessionId { resetSession(session) }
            let ceiling = Self.longVerbs.contains(verb) ? 15.0 : shortVerbTimeoutCeiling
            let budget = min(ceiling, remaining - 0.35)
            guard budget > 0.2 else {
                throw ComputerHostError("interrupted", "The request deadline leaves no time for the browser pane.")
            }
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(budget * 1000)))
            begin()
            defer { end() }
            let previous = working
            working = activeTab
            defer { working = previous }
            try await page.prepare()
            _ = page.takeNotices()
            var result: [String: JSONValue]
            switch verb {
            case "browser_snapshot": result = try await snapshot(args, deadline)
            case "browser_find": result = try await find(args, deadline)
            case "browser_get_text": result = try await text(args, deadline)
            case "browser_screenshot": result = try await screenshot(args, deadline)
            case "browser_zoom": result = try await zoom(args, deadline)
            case "browser_wait": result = try await wait(args, deadline)
            case "browser_navigate": result = try await navigate(args, deadline, authorize)
            case "browser_click": result = try await click(args, deadline, authorize)
            case "browser_hover": result = try await hover(args, deadline, authorize)
            case "browser_fill": result = try await fill(args, deadline, authorize)
            case "browser_press": result = try await press(args, deadline, authorize)
            case "browser_scroll": result = try await scroll(args, deadline, authorize)
            case "browser_dialog": result = try await dialog(args, authorize)
            case "browser_console": result = try consoleEntries(args)
            case "browser_network": result = try networkEntries(args)
            case "browser_evaluate": result = try await evaluate(args, deadline, authorize)
            case "browser_resize": result = try resize(args, authorize)
            case "browser_tabs": result = try await tabsAction(args, deadline, authorize)
            default: throw ComputerHostError("unsupported", "That browser action is not available.")
            }
            try authorize()
            guard let current = working, tabs.contains(current) else {
                throw ComputerHostError("interrupted", "The browser tab Astral was using closed.")
            }
            let shown = readable(current.pane)
            result["tab_id"] = .string(current.id)
            result["url"] = shown ? .string(current.pane.webView.url?.absoluteString ?? "about:blank") : .null
            result["title"] = shown ? .string(String((current.pane.webView.title ?? "").prefix(300))) : .null
            result["pending_dialog"] = current.pane.dialogs.first?.json ?? .null
            let notices = current.pane.takeNotices()
            if !notices.isEmpty { result["blocked"] = .array(notices.map(\.json)) }
            return result
        }

        private func readable(_ pane: MacBrowserPane) -> Bool {
            guard let url = pane.webView.url, url.absoluteString != "about:blank" else { return true }
            return ComputerBrowserPolicy.origin(of: url).map(approved.contains) == true
        }

        private func begin() {
            running += 1
            driving = true
            isPresented = true
            linger?.cancel()
            lastError = nil
        }

        private func end() {
            running = max(0, running - 1)
            settleUntil = ProcessInfo.processInfo.systemUptime + 2
            guard running == 0 else { return }
            linger = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
                guard let self, self.running == 0 else { return }
                self.driving = false
            }
        }

        private func allows(_ url: URL, userInitiated: Bool) -> Bool {
            guard let origin = ComputerBrowserPolicy.origin(of: url) else { return false }
            if userInitiated || approved.contains(origin) { return true }
            return running == 0 && ProcessInfo.processInfo.systemUptime >= settleUntil
        }

        private func humanInput() {
            guard agentActive() else { return }
            takeover()
        }

        private func resetSession(_ session: String?) {
            sessionId = session
            approved = []
            snapshots = []
            refs = [:]
            index = [:]
            refGeneration = pane.generation
            refTab = activeTabId
            issued = []
            granted = []
            consumed = []
        }

        private func syncGeneration() {
            guard refGeneration != page.generation || refTab != pageTab else { return }
            refGeneration = page.generation
            refTab = pageTab
            refs = [:]
            index = [:]
            snapshots = []
            issued = []
            granted = []
        }

        private func remaining(_ deadline: ContinuousClock.Instant) throws -> Duration {
            let left = deadline - ContinuousClock.now
            guard left > .milliseconds(50) else {
                throw ComputerHostError("timeout", "The browser pane ran out of time for this action.")
            }
            return left
        }

        private var currentOrigin: String? { page.webView.url.flatMap(ComputerBrowserPolicy.origin(of:)) }

        private var blank: Bool {
            guard let url = page.webView.url else { return true }
            return url.absoluteString == "about:blank"
        }

        @discardableResult
        private func approvedPage() throws -> String {
            guard let origin = currentOrigin else {
                throw ComputerHostError(
                    "origin_not_approved",
                    "No approved page is open in the browser pane. Open one with browser_navigate.")
            }
            guard approved.contains(origin) else {
                throw ComputerHostError(
                    "origin_not_approved", "The browser pane shows \(origin), which is not approved in this session.")
            }
            return origin
        }

        private func noDialog() throws {
            guard page.dialogs.isEmpty else {
                throw ComputerHostError(
                    "pending_dialog",
                    "A page dialog is waiting. Read it with browser_snapshot, then use browser_dialog.")
            }
        }

        private func refName(_ token: String, _ local: Int) -> String {
            let key = token + "|" + String(local)
            if let existing = index[key] { return existing }
            let name = "e\(nextRef)"
            nextRef += 1
            index[key] = name
            refs[name] = (token, local)
            return name
        }

        private func locate(_ ref: String, snapshot: String?) throws -> Target {
            syncGeneration()
            let stale = ComputerHostError(
                "stale_ref", "Reference \(ref) belongs to an older page or snapshot. Take a fresh browser_snapshot.")
            guard let entry = refs[ref] else { throw stale }
            let record: Snapshot?
            if let snapshot {
                record = snapshots.first { $0.id == snapshot }
            } else {
                record = snapshots.last { $0.refs.contains(ref) }
            }
            guard let record, record.tab == pageTab, record.generation == page.generation, record.refs.contains(ref),
                let frame = page.frames.first(where: { $0.token == entry.token })
            else { throw stale }
            return Target(token: entry.token, local: entry.local, snapshot: record.id, frame: frame)
        }

        private func script(_ value: JSONValue, ref: String?) throws {
            guard let code = value["error"]?.stringValue else { return }
            switch code {
            case "stale_ref":
                throw ComputerHostError(
                    "stale_ref",
                    "Reference \(ref ?? "") no longer resolves on this page. Take a fresh browser_snapshot.")
            case "secret_field":
                throw ComputerHostError(
                    "secret_field", "That is a password, card or one-time-code field. Astral never reads or fills it.")
            case "disabled": throw ComputerHostError("target_disabled", "That control is disabled or read-only.")
            case "no_option": throw ComputerHostError("out_of_range", "No option in that list matches the value.")
            case "upload_blocked":
                throw ComputerHostError("unsupported", "File uploads are blocked in the browser pane in this version.")
            default: throw ComputerHostError("out_of_range", "That element cannot take this action.")
            }
        }

        private func describe(_ target: Target, ref: String?, _ deadline: ContinuousClock.Instant) async throws
            -> Described
        {
            let value = try await page.call(
                .describe, ["snapshot": target.snapshot, "id": target.local], in: target.frame,
                within: try remaining(deadline))
            try script(value, ref: ref)
            guard let element = ComputerBrowserElement(json: value) else {
                throw ComputerHostError("stale_ref", "That element could not be read. Take a fresh browser_snapshot.")
            }
            let body = String((value["line"]?.stringValue ?? element.tag).prefix(280))
            return Described(
                element: element, line: ref.map { "[\($0)] " + body } ?? body,
                secret: ComputerBrowserPolicy.isSecret(element) || value["secret"]?.boolValue == true)
        }

        private func permits(_ args: [String: JSONValue], ref: String, snapshot: String, origin: String) -> Bool {
            let key = snapshot + "|" + ref
            if granted.contains(key) || bypassedRequest { return true }
            guard let permit = args["permit"]?.objectValue, permit["origin"]?.stringValue == origin,
                permit["snapshot_id"]?.stringValue == snapshot, issued.contains(key), !consumed.contains(key)
            else { return false }
            let named =
                permit["refs"]?.arrayValue?.compactMap(\.stringValue) ?? permit["ref"].flatMap(\.stringValue).map {
                    [$0]
                } ?? []
            return named.contains(ref)
        }

        private func grant(_ refs: [String], snapshot: String) {
            for ref in refs { granted.insert(snapshot + "|" + ref) }
        }

        private func revoke(_ refs: [String], snapshot: String) {
            for ref in refs { granted.remove(snapshot + "|" + ref) }
        }

        func discardPermits() {
            issued = []
            granted = []
        }

        private func review(_ described: Described, ref: String, snapshot: String) -> ComputerHostError {
            issued.insert(snapshot + "|" + ref)
            return ComputerHostError(
                "confirmation_required", "The user must review this control first: " + described.line)
        }

        private func consume(_ refs: [String], snapshot: String) {
            for ref in refs {
                let key = snapshot + "|" + ref
                if granted.remove(key) != nil { consumed.insert(key) }
                issued.remove(key)
            }
        }

        private struct Walk {
            var lines: [String] = []
            var matches: [JSONValue] = []
            var frames: [JSONValue] = []
            var truncated = false
            var origin: String?
        }

        private func newSnapshotId() -> String {
            defer { nextSnapshot += 1 }
            return "s\(nextSnapshot)"
        }

        private func scopeReference(_ args: [String: JSONValue]) throws -> String? {
            let alias = args["ref"]?.stringValue
            let scope = args["scope_ref"]?.stringValue
            if let alias, let scope, alias != scope {
                throw ComputerHostError(
                    "out_of_range", "Give ref or scope_ref for one subtree, not two different ones.")
            }
            return alias ?? scope
        }

        private func walk(
            id: String, mode: String, maximum: Int, scopeRef: String?, depth: Int?, query: String?, limit: Int,
            _ deadline: ContinuousClock.Instant
        ) async throws -> Walk {
            syncGeneration()
            let generation = page.generation
            let tab = pageTab
            var out = Walk()
            var listed = Set<String>()
            var used = 0
            func add(_ line: String) -> Bool {
                guard used + line.count + 1 <= maximum else {
                    out.truncated = true
                    return false
                }
                out.lines.append(line)
                used += line.count + 1
                return true
            }
            defer {
                snapshots.append(Snapshot(id: id, tab: tab, generation: generation, refs: listed))
                if snapshots.count > 8 { snapshots.removeFirst(snapshots.count - 8) }
            }
            if !page.dialogs.isEmpty || blank { return out }
            let origin = try approvedPage()
            let scope = try scopeRef.map { try locate($0, snapshot: nil) }
            guard try await page.waitForMainFrame(within: min(.seconds(1), try remaining(deadline))) != nil else {
                return out
            }
            out.origin = origin
            for frame in page.frames {
                out.frames.append(.object(["id": .string(frame.id), "url": .string(frame.url)]))
                if let scope, scope.token != frame.token { continue }
                let allowed = frame.isMain || frame.origin.map { approved.contains($0) || $0 == origin } == true
                if !frame.isMain && scope == nil && query == nil {
                    let header = "frame \(frame.id) " + Self.quoted(frame.url) + (allowed ? "" : " origin not approved")
                    guard add(header) else { break }
                }
                guard allowed else { continue }
                var call: [String: Any] = ["snapshot": id, "mode": mode, "max_chars": max(1, maximum - used)]
                if let scope {
                    call["scope"] = scope.local
                    call["scope_snapshot"] = scope.snapshot
                }
                if let depth { call["depth"] = depth }
                if let query {
                    call["query"] = query
                    call["limit"] = max(1, limit - out.matches.count)
                }
                let value: JSONValue
                do {
                    value = try await page.call(.snapshot, call, in: frame, within: try remaining(deadline))
                } catch let error as ComputerHostError where !frame.isMain && error.code != "timeout" {
                    continue
                }
                if value["error"] != nil {
                    if scope != nil || frame.isMain { try script(value, ref: scopeRef) }
                    continue
                }
                for node in value["nodes"]?.arrayValue ?? [] {
                    guard let local = node["id"]?.numberValue, let line = node["line"]?.stringValue else { continue }
                    let ref = refName(frame.token, Int(local))
                    let body = String(line.prefix(2000))
                    if query != nil {
                        guard out.matches.count < limit, used + body.count + 1 <= maximum else {
                            out.truncated = true
                            break
                        }
                        used += body.count + 1
                        var match: [String: JSONValue] = ["ref": .string(ref), "line": .string(body)]
                        if !frame.isMain { match["frame"] = .string(frame.id) }
                        out.matches.append(.object(match))
                    } else {
                        guard add("[\(ref)] " + body) else { break }
                    }
                    listed.insert(ref)
                }
                if value["truncated"]?.boolValue == true { out.truncated = true }
                if out.truncated { break }
            }
            return out
        }

        private func snapshot(_ args: [String: JSONValue], _ deadline: ContinuousClock.Instant) async throws
            -> [String: JSONValue]
        {
            let mode = args["mode"]?.stringValue ?? "interactive"
            let scopeRef = try scopeReference(args)
            let depth = args["depth"]?.numberValue.map { max(1, min(30, Int($0))) }
            let id = newSnapshotId()
            let out = try await walk(
                id: id, mode: mode, maximum: max(1, min(60000, Int(args["max_chars"]?.numberValue ?? 60000))),
                scopeRef: scopeRef, depth: depth, query: nil, limit: 0, deadline)
            var result: [String: JSONValue] = [
                "snapshot_id": .string(id), "mode": .string(mode), "lines": .array(out.lines.map(JSONValue.string)),
                "frames": .array(out.frames), "truncated": .bool(out.truncated),
            ]
            if let origin = out.origin { result["origin"] = .string(origin) }
            return result
        }

        private func find(_ args: [String: JSONValue], _ deadline: ContinuousClock.Instant) async throws
            -> [String: JSONValue]
        {
            let query = (args["query"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { throw ComputerHostError("out_of_range", "browser_find needs a query.") }
            let limit = max(1, min(20, Int(args["max"]?.numberValue ?? 20)))
            let id = newSnapshotId()
            let out = try await walk(
                id: id, mode: "interactive", maximum: 60000, scopeRef: nil, depth: nil,
                query: String(query.prefix(200)).lowercased(), limit: limit, deadline)
            var result: [String: JSONValue] = [
                "snapshot_id": .string(id), "matches": .array(out.matches), "truncated": .bool(out.truncated),
            ]
            if let origin = out.origin { result["origin"] = .string(origin) }
            return result
        }

        static func quoted(_ text: String) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            let data = (try? encoder.encode(String(text.prefix(300)))) ?? Data("\"\"".utf8)
            return String(decoding: data, as: UTF8.self)
        }

        private func mainFrame(_ deadline: ContinuousClock.Instant) async throws -> MacBrowserFrame {
            guard let frame = try await page.waitForMainFrame(within: min(.seconds(1), try remaining(deadline))) else {
                throw ComputerHostError("unsupported", "This page cannot be read in the browser pane.")
            }
            return frame
        }

        private func text(_ args: [String: JSONValue], _ deadline: ContinuousClock.Instant) async throws
            -> [String: JSONValue]
        {
            try noDialog()
            try approvedPage()
            let maximum = Int(args["max_chars"]?.numberValue ?? 60000)
            let value: JSONValue
            if let ref = args["ref"]?.stringValue {
                let target = try locate(ref, snapshot: nil)
                let described = try await describe(target, ref: ref, deadline)
                guard !described.secret else {
                    throw ComputerHostError(
                        "secret_field", "\(ref) is a password, card or one-time-code field. Astral never reads it.")
                }
                value = try await page.call(
                    .text, ["snapshot": target.snapshot, "id": target.local, "max_chars": maximum], in: target.frame,
                    within: try remaining(deadline))
                try script(value, ref: ref)
            } else {
                value = try await page.call(
                    .text, ["max_chars": maximum], in: try await mainFrame(deadline), within: try remaining(deadline))
                try script(value, ref: nil)
            }
            return [
                "text": .string(String((value["text"]?.stringValue ?? "").prefix(maximum))),
                "truncated": .bool(value["truncated"]?.boolValue ?? false),
            ]
        }

        private func navigationTarget(_ text: String) throws -> (url: URL, origin: String) {
            let url = try ComputerBrowserPolicy.navigableURL(text)
            guard let origin = ComputerBrowserPolicy.origin(of: url) else {
                throw ComputerHostError("url_rejected", "The browser pane cannot open that address.")
            }
            return (url, origin)
        }

        private func navigate(
            _ args: [String: JSONValue], _ deadline: ContinuousClock.Instant,
            _ authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue] {
            try noDialog()
            let mark = page.mark()
            if let text = args["url"]?.stringValue {
                let target = try navigationTarget(text)
                try authorize()
                approved.insert(target.origin)
                page.load(target.url)
            } else {
                let action = args["action"]?.stringValue ?? ""
                if action == "reload" { try approvedPage() }
                try authorize()
                guard page.history(action) else {
                    throw ComputerHostError("out_of_range", "There is no page to go \(action) to.")
                }
            }
            return try await loaded(after: mark, deadline)
        }

        private func loaded(after mark: Int, _ deadline: ContinuousClock.Instant) async throws -> [String: JSONValue] {
            let outcome = try await page.waitForLoad(after: mark, within: try remaining(deadline))
            var result: [String: JSONValue] = ["loaded": .bool(outcome == .finished)]
            switch outcome {
            case .finished?, nil: break
            case .failed(let reason)?:
                throw ComputerHostError(
                    "navigation_failed",
                    "The page could not be opened in the browser pane (\(reason)). Sites that refuse embedded views "
                        + "need the user's own browser through the desktop path.")
            case .refused?:
                let notices = page.takeNotices()
                if case .origin(let blocked)? = notices.first(where: { if case .origin = $0 { true } else { false } }) {
                    throw ComputerHostError(
                        "origin_not_approved",
                        "The page tried to open \(blocked), which is not approved in this session.")
                }
                if notices.contains(where: { if case .download = $0 { true } else { false } }) {
                    throw ComputerHostError("unsupported", "Downloads are blocked in the browser pane in this version.")
                }
                throw ComputerHostError("url_rejected", "The page tried to open an address the browser pane refuses.")
            case .crashed?:
                throw ComputerHostError("failed", "The page stopped responding. Navigate to it again.")
            case .started?: break
            }
            if let status = page.mainStatus { result["status"] = .number(Double(status)) }
            if let host = page.webView.url?.host?.lowercased(), Self.embeddedViewRefusers.contains(host) {
                result["note"] = .string(
                    "This sign-in page refuses embedded browsers. Ask the user to use their own browser through the "
                        + "desktop path.")
            }
            if let origin = currentOrigin { result["origin"] = .string(origin) }
            return result
        }

        private func settleNavigation(after mark: Int, _ deadline: ContinuousClock.Instant) async throws -> Bool {
            guard page.events.contains(where: { $0.sequence > mark && $0.event == .started }) else { return false }
            let left = (deadline - ContinuousClock.now) - .milliseconds(150)
            if left > .milliseconds(50) { _ = try await page.waitForLoad(after: mark, within: left) }
            return true
        }

        private func click(
            _ args: [String: JSONValue], _ deadline: ContinuousClock.Instant,
            _ authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue] {
            try noDialog()
            let origin = try approvedPage()
            guard let ref = args["ref"]?.stringValue, let snapshot = args["snapshot_id"]?.stringValue else {
                throw ComputerHostError("out_of_range", "A click needs ref and snapshot_id.")
            }
            let target = try locate(ref, snapshot: snapshot)
            let described = try await describe(target, ref: ref, deadline)
            let consequential = ComputerBrowserPolicy.isConsequential(described.element)
            if consequential && !permits(args, ref: ref, snapshot: snapshot, origin: origin) {
                throw review(described, ref: ref, snapshot: snapshot)
            }
            defer { if consequential { revoke([ref], snapshot: snapshot) } }
            try authorize()
            if consequential { grant([ref], snapshot: snapshot) }
            let mark = page.mark()
            let right = args["button"]?.stringValue == "right"
            let count = Int(args["count"]?.numberValue ?? 1)
            let value: JSONValue
            do {
                value = try await page.call(
                    .click,
                    [
                        "snapshot": target.snapshot, "id": target.local, "button": right ? "right" : "left",
                        "count": count,
                    ],
                    in: target.frame, within: try remaining(deadline))
            } catch let error as ComputerHostError where error.code == "pending_dialog" {
                if consequential { consume([ref], snapshot: snapshot) }
                return ["clicked": .string(ref), "method": .string("synthetic"), "dialog_opened": .bool(true)]
            }
            try script(value, ref: ref)
            if consequential { consume([ref], snapshot: snapshot) }
            var effect = true
            if let observation = value["observation"]?.numberValue {
                try await Task.sleep(for: .milliseconds(300))
                if page.dialogs.isEmpty,
                    let settled = try? await page.call(
                        .settle, ["observation": Int(observation)], in: target.frame,
                        within: min(.seconds(1), try remaining(deadline)))
                {
                    effect = settled["effect"]?.boolValue ?? true
                }
            }
            if page.dialogs.first != nil {
                return ["clicked": .string(ref), "method": .string("synthetic"), "dialog_opened": .bool(true)]
            }
            var method = "synthetic"
            if !effect, !consequential,
                !page.events.contains(where: { $0.sequence > mark }), let point = viewPoint(value["geometry"])
            {
                try authorize()
                try page.nativeClick(at: point, right: right, count: count)
                method = "native"
            }
            let navigated = try await settleNavigation(after: mark, deadline)
            return ["clicked": .string(ref), "method": .string(method), "navigated": .bool(navigated)]
        }

        private func hover(
            _ args: [String: JSONValue], _ deadline: ContinuousClock.Instant,
            _ authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue] {
            try noDialog()
            try approvedPage()
            guard let ref = args["ref"]?.stringValue, let snapshot = args["snapshot_id"]?.stringValue else {
                throw ComputerHostError("out_of_range", "A hover needs ref and snapshot_id.")
            }
            let target = try locate(ref, snapshot: snapshot)
            try authorize()
            let value: JSONValue
            do {
                value = try await page.call(
                    .hover, ["snapshot": target.snapshot, "id": target.local], in: target.frame,
                    within: try remaining(deadline))
            } catch let error as ComputerHostError where error.code == "pending_dialog" {
                return ["hovered": .string(ref), "method": .string("synthetic"), "dialog_opened": .bool(true)]
            }
            try script(value, ref: ref)
            var method = "synthetic"
            if page.dialogs.isEmpty, let point = viewPoint(value["geometry"]) {
                try authorize()
                if page.nativeMove(to: point) { method = "native" }
            }
            return ["hovered": .string(ref), "method": .string(method)]
        }

        private func viewPoint(_ geometry: JSONValue?) -> CGPoint? {
            guard let geometry, geometry["obscured"]?.boolValue == false,
                let offset = geometry["offset"]?.objectValue, let ox = offset["x"]?.numberValue,
                let oy = offset["y"]?.numberValue, let x = geometry["x"]?.numberValue,
                let y = geometry["y"]?.numberValue,
                let width = geometry["width"]?.numberValue, let height = geometry["height"]?.numberValue,
                width > 0, height > 0
            else { return nil }
            return viewPoint(css: CGPoint(x: ox + x + width / 2, y: oy + y + height / 2))
        }

        private func viewPoint(css: CGPoint) -> CGPoint? {
            let view = page.webView
            let zoom = view.pageZoom * view.magnification
            let point = CGPoint(x: css.x * zoom, y: view.isFlipped ? css.y * zoom : view.bounds.height - css.y * zoom)
            return view.bounds.contains(point) ? point : nil
        }

        private func fill(
            _ args: [String: JSONValue], _ deadline: ContinuousClock.Instant,
            _ authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue] {
            try noDialog()
            let origin = try approvedPage()
            guard let snapshot = args["snapshot_id"]?.stringValue, let fields = args["fields"]?.arrayValue else {
                throw ComputerHostError("out_of_range", "A fill needs fields and snapshot_id.")
            }
            var plan: [(ref: String, value: String, target: Target)] = []
            var reviewed: [String] = []
            for field in fields {
                guard let ref = field["ref"]?.stringValue, let value = field["value"]?.stringValue else {
                    throw ComputerHostError("out_of_range", "Each field needs ref and value.")
                }
                let target = try locate(ref, snapshot: snapshot)
                let described = try await describe(target, ref: ref, deadline)
                if described.secret {
                    throw ComputerHostError(
                        "secret_field",
                        "\(ref) is a password, card or one-time-code field. Ask the user to fill it themselves.")
                }
                if ComputerBrowserPolicy.isConsequential(described.element) {
                    guard permits(args, ref: ref, snapshot: snapshot, origin: origin) else {
                        throw review(described, ref: ref, snapshot: snapshot)
                    }
                    grant([ref], snapshot: snapshot)
                    reviewed.append(ref)
                }
                plan.append((ref, value, target))
            }
            var filled: [JSONValue] = []
            defer { revoke(reviewed, snapshot: snapshot) }
            for item in plan {
                try authorize()
                let value: JSONValue
                do {
                    value = try await page.call(
                        .fill, ["snapshot": item.target.snapshot, "id": item.target.local, "value": item.value],
                        in: item.target.frame, within: try remaining(deadline))
                } catch let error as ComputerHostError where error.code == "pending_dialog" {
                    filled.append(.string(item.ref))
                    consume(reviewed, snapshot: snapshot)
                    return ["filled": .array(filled), "dialog_opened": .bool(true)]
                }
                try script(value, ref: item.ref)
                filled.append(.string(item.ref))
            }
            consume(reviewed, snapshot: snapshot)
            return ["filled": .array(filled)]
        }

        private func press(
            _ args: [String: JSONValue], _ deadline: ContinuousClock.Instant,
            _ authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue] {
            try noDialog()
            try approvedPage()
            let keys = args["keys"]?.stringValue ?? ""
            let chord = try ComputerHostChord(keys)
            let ref = args["ref"]?.stringValue
            let target = try ref.map { try locate($0, snapshot: nil) }
            let frame: MacBrowserFrame
            if let target { frame = target.frame } else { frame = try await mainFrame(deadline) }
            var call: [String: Any] = [:]
            if let target {
                call["snapshot"] = target.snapshot
                call["id"] = target.local
            }
            let focus = try await page.call(.focusTarget, call, in: frame, within: try remaining(deadline))
            try script(focus, ref: ref)
            guard let element = ComputerBrowserElement(json: focus) else {
                throw ComputerHostError("stale_ref", "The focused element could not be read. Take a fresh snapshot.")
            }
            let nonTyping: Set<String> = [
                "tab", "escape", "enter", "up", "down", "left", "right", "home", "end", "pageup", "pagedown",
            ]
            if (ComputerBrowserPolicy.isSecret(element) || focus["secret"]?.boolValue == true)
                && !(nonTyping.contains(chord.key) && chord.modifiers.subtracting(["shift"]).isEmpty)
            {
                throw ComputerHostError(
                    "secret_field",
                    "The focused field holds a password, card or one-time code. Astral never types into it.")
            }
            let activating = (chord.key == "enter" || chord.key == "space") && chord.modifiers.isEmpty
            let submitsSecret = chord.key == "enter" && element.inForm && element.formHasSecret
            if activating && (ComputerBrowserPolicy.isConsequential(element) || submitsSecret) {
                let body = String((focus["line"]?.stringValue ?? element.tag).prefix(280))
                throw ComputerHostError(
                    "confirmation_required",
                    "Pressing \(keys) here needs review. Use browser_click on the control so the user can approve it: "
                        + (ref.map { "[\($0)] " } ?? "") + body)
            }
            try authorize()
            let mark = page.mark()
            call["key"] = chord.key
            for modifier in ["cmd", "ctrl", "alt", "shift"] { call[modifier] = chord.modifiers.contains(modifier) }
            let value: JSONValue
            do {
                value = try await page.call(.press, call, in: frame, within: try remaining(deadline))
            } catch let error as ComputerHostError where error.code == "pending_dialog" {
                return ["keys": .string(keys), "action": .string("dialog"), "dialog_opened": .bool(true)]
            }
            try script(value, ref: ref)
            let navigated = try await settleNavigation(after: mark, deadline)
            return [
                "keys": .string(keys), "action": .string(value["action"]?.stringValue ?? "none"),
                "navigated": .bool(navigated),
            ]
        }

        private func scroll(
            _ args: [String: JSONValue], _ deadline: ContinuousClock.Instant,
            _ authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue] {
            try noDialog()
            try approvedPage()
            let dy = Int(args["dy"]?.numberValue ?? 600)
            var call: [String: Any] = ["dy": dy]
            let frame: MacBrowserFrame
            if let ref = args["ref"]?.stringValue {
                let target = try locate(ref, snapshot: nil)
                call["snapshot"] = target.snapshot
                call["id"] = target.local
                frame = target.frame
            } else {
                frame = try await mainFrame(deadline)
            }
            try authorize()
            let value = try await page.call(.scroll, call, in: frame, within: try remaining(deadline))
            try script(value, ref: args["ref"]?.stringValue)
            var result: [String: JSONValue] = ["dy": .number(Double(dy))]
            for key in ["target", "scroll_top", "scroll_height", "client_height"] { result[key] = value[key] ?? .null }
            return result
        }

        private func dialog(_ args: [String: JSONValue], _ authorize: @escaping @Sendable () throws -> Void)
            async throws
            -> [String: JSONValue]
        {
            try approvedPage()
            guard let dialog = page.dialogs.first else {
                throw ComputerHostError("no_dialog", "No page dialog is waiting.")
            }
            let accept = args["action"]?.stringValue == "accept"
            if args["text"] != nil && dialog.type != "prompt" {
                throw ComputerHostError("out_of_range", "Only a prompt dialog takes text.")
            }
            try authorize()
            _ = try page.answer(accept: accept, text: args["text"]?.stringValue)
            try await Task.sleep(for: .milliseconds(100))
            return ["answered": .string(dialog.type), "action": .string(accept ? "accept" : "dismiss")]
        }

        private func wait(_ args: [String: JSONValue], _ deadline: ContinuousClock.Instant) async throws
            -> [String: JSONValue]
        {
            try noDialog()
            let condition = args["for"]?.stringValue ?? "load"
            let seconds = args["seconds"]?.numberValue ?? 10
            let until = min(deadline, ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000))))
            if condition != "load" { try approvedPage() }
            let target = try args["ref"]?.stringValue.map { try locate($0, snapshot: nil) }
            while true {
                try Task.checkCancellation()
                try noDialog()
                let matched: Bool
                switch condition {
                case "load": matched = !page.webView.isLoading
                case "text":
                    let frame = try await mainFrame(deadline)
                    let value = try await page.call(
                        .contains, ["text": args["text"]?.stringValue ?? ""], in: frame, within: try remaining(deadline)
                    )
                    matched = value["matched"]?.boolValue == true
                default:
                    guard let target else { throw ComputerHostError("out_of_range", "Missing ref.") }
                    let value = try await page.call(
                        .probe, ["snapshot": target.snapshot, "id": target.local], in: target.frame,
                        within: try remaining(deadline))
                    guard value["exists"]?.boolValue == true else {
                        throw ComputerHostError(
                            "stale_ref", "Reference \(args["ref"]?.stringValue ?? "") is gone. Take a fresh snapshot.")
                    }
                    matched = value["visible"]?.boolValue == true && value["enabled"]?.boolValue == true
                }
                if matched { return ["matched": .bool(true), "for": .string(condition)] }
                guard ContinuousClock.now.advanced(by: .milliseconds(200)) < until else {
                    return ["matched": .bool(false), "for": .string(condition)]
                }
                try await Task.sleep(for: .milliseconds(200))
            }
        }

        private var viewZoom: CGFloat { max(0.05, page.webView.pageZoom * page.webView.magnification) }

        private func viewRect(_ box: JSONValue?, offset: JSONValue?) -> CGRect? {
            guard let box, let x = box["x"]?.numberValue, let y = box["y"]?.numberValue,
                let width = box["width"]?.numberValue, let height = box["height"]?.numberValue
            else { return nil }
            let view = page.webView
            let zoom = viewZoom
            let ox = offset?["x"]?.numberValue ?? 0
            let oy = offset?["y"]?.numberValue ?? 0
            let top = (oy + y) * zoom
            return CGRect(
                x: (ox + x) * zoom, y: view.isFlipped ? top : view.bounds.height - top - height * zoom,
                width: width * zoom, height: height * zoom)
        }

        private func secretMasks(_ deadline: ContinuousClock.Instant) async throws -> [CGRect] {
            guard !blank else { return [] }
            var masks: [CGRect] = []
            var unplaced = false
            var frameBoxes: [CGRect] = []
            for frame in page.frames {
                guard
                    let value = try? await page.call(
                        .secretRects, [:], in: frame, within: min(.seconds(1), try remaining(deadline)))
                else { continue }
                let rects = value["rects"]?.arrayValue ?? []
                if frame.isMain {
                    frameBoxes = (value["frames"]?.arrayValue ?? []).compactMap { viewRect($0, offset: nil) }
                }
                if value["offset"]?.objectValue == nil {
                    if !rects.isEmpty { unplaced = true }
                    continue
                }
                masks += rects.compactMap { viewRect($0, offset: value["offset"]) }
            }
            let crossOrigin = page.frames.contains { !$0.isMain && $0.origin != currentOrigin }
            if unplaced || crossOrigin { masks += frameBoxes }
            return masks
        }

        private func screenshot(_ args: [String: JSONValue], _ deadline: ContinuousClock.Instant) async throws
            -> [String: JSONValue]
        {
            try noDialog()
            if !blank { try approvedPage() }
            let maximum = CGFloat(args["max_width"]?.numberValue ?? 1280)
            let view = page.webView
            var capture = view.bounds
            if let ref = args["ref"]?.stringValue {
                let target = try locate(ref, snapshot: nil)
                let value = try await page.call(
                    .geometry, ["snapshot": target.snapshot, "id": target.local, "reveal": true], in: target.frame,
                    within: try remaining(deadline))
                try script(value, ref: ref)
                guard value["offset"]?.objectValue != nil, let box = viewRect(value, offset: value["offset"]),
                    !box.intersection(view.bounds).isNull, !box.intersection(view.bounds).isEmpty
                else {
                    throw ComputerHostError("out_of_range", "That element is not visible in the browser pane.")
                }
                capture = box.intersection(view.bounds)
            }
            let masks = try await secretMasks(deadline)
            let image = try await page.image(
                rect: capture, width: capture.width / viewZoom, within: try remaining(deadline))
            guard
                let encoded = Self.encode(
                    image, capture: capture, masks: masks, maximumWidth: maximum, flipped: view.isFlipped)
            else { throw ComputerHostError("failed", "The browser pane image could not be encoded.") }
            return [
                "base64": .string(encoded.data.base64EncodedString()), "media_type": .string("image/jpeg"),
                "width": .number(Double(encoded.width)), "height": .number(Double(encoded.height)),
                "masked": .number(Double(masks.count)),
            ]
        }

        private func zoom(_ args: [String: JSONValue], _ deadline: ContinuousClock.Instant) async throws
            -> [String: JSONValue]
        {
            try noDialog()
            if !blank { try approvedPage() }
            guard let x0 = args["x0"]?.numberValue, let y0 = args["y0"]?.numberValue,
                let x1 = args["x1"]?.numberValue, let y1 = args["y1"]?.numberValue, x1 > x0, y1 > y0
            else {
                throw ComputerHostError("out_of_range", "browser_zoom needs x0 < x1 and y0 < y1 in viewport pixels.")
            }
            let scale = CGFloat(max(1, min(4, args["scale"]?.numberValue ?? 2)))
            let view = page.webView
            let zoom = viewZoom
            let viewport = CGRect(x: 0, y: 0, width: view.bounds.width / zoom, height: view.bounds.height / zoom)
            let region = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).intersection(viewport)
            guard !region.isNull, region.width >= 1, region.height >= 1 else {
                throw ComputerHostError(
                    "out_of_range",
                    "That region is outside the \(Int(viewport.width))x\(Int(viewport.height)) browser viewport.")
            }
            let capture = CGRect(
                x: region.minX * zoom, y: view.isFlipped ? region.minY * zoom : view.bounds.height - region.maxY * zoom,
                width: region.width * zoom, height: region.height * zoom)
            let width = min(Self.maximumZoomWidth, (region.width * scale).rounded())
            let masks = try await secretMasks(deadline)
            let image = try await page.image(rect: capture, width: width, within: try remaining(deadline))
            guard
                let encoded = Self.encode(
                    image, capture: capture, masks: masks, maximumWidth: width, flipped: view.isFlipped)
            else { throw ComputerHostError("failed", "The browser pane image could not be encoded.") }
            return [
                "base64": .string(encoded.data.base64EncodedString()), "media_type": .string("image/jpeg"),
                "width": .number(Double(encoded.width)), "height": .number(Double(encoded.height)),
                "masked": .number(Double(masks.count)), "scale": .number(Double(scale)),
                "region": .object([
                    "x0": .number(Double(region.minX.rounded())), "y0": .number(Double(region.minY.rounded())),
                    "x1": .number(Double(region.maxX.rounded())), "y1": .number(Double(region.maxY.rounded())),
                ]),
            ]
        }

        private func visible(_ origin: String?) -> Bool { origin.map(approved.contains) == true }

        private func consoleEntries(_ args: [String: JSONValue]) throws -> [String: JSONValue] {
            if !blank { try approvedPage() }
            let errorsOnly = args["level"]?.stringValue == "error"
            let limit = max(1, min(200, Int(args["limit"]?.numberValue ?? 100)))
            let pattern = args["pattern"]?.stringValue.map { String($0.prefix(200)).lowercased() } ?? ""
            let matching = page.console.filter { entry in
                visible(entry.origin) && (!errorsOnly || entry.level == "error")
                    && (pattern.isEmpty || entry.text.lowercased().contains(pattern)
                        || entry.url.lowercased().contains(pattern))
            }
            let shown = matching.suffix(limit)
            return [
                "entries": .array(shown.map(\.json)), "total": .number(Double(matching.count)),
                "truncated": .bool(matching.count > shown.count), "dropped": .number(Double(page.consoleDropped)),
            ]
        }

        private func networkEntries(_ args: [String: JSONValue]) throws -> [String: JSONValue] {
            if !blank { try approvedPage() }
            let limit = max(1, min(100, Int(args["limit"]?.numberValue ?? 50)))
            let pattern = args["url_pattern"]?.stringValue.map { String($0.prefix(200)).lowercased() } ?? ""
            let matching = page.network.filter { entry in
                visible(entry.origin) && (pattern.isEmpty || entry.url.lowercased().contains(pattern))
            }
            let shown = matching.suffix(limit)
            return [
                "entries": .array(shown.map(\.json)), "total": .number(Double(matching.count)),
                "truncated": .bool(matching.count > shown.count), "dropped": .number(Double(page.networkDropped)),
            ]
        }

        static func evaluationBody(_ source: String, expression: Bool) -> String {
            var inner = source
            if expression {
                var trimmed = source
                while let last = trimmed.last, last.isWhitespace || last == ";" { trimmed.removeLast() }
                inner = "return (\n" + trimmed + "\n);"
            }
            return """
                let __astralValue;
                try {
                __astralValue = await (async () => {
                \(inner)
                })();
                } catch (error) {
                let message;
                try { message = error && error.name ? String(error.name) + ': ' + String(error.message) : String(error); }
                catch (inner) { message = 'The script threw a value that cannot be printed.'; }
                return { thrown: message.slice(0, 500) };
                }
                if (__astralValue === undefined) return { type: 'undefined' };
                const __astralSeen = new WeakSet();
                let __astralJSON;
                try {
                __astralJSON = JSON.stringify(__astralValue, (key, item) => {
                if (typeof item === 'bigint') return String(item);
                if (typeof item === 'function') return '[Function]';
                if (typeof item === 'symbol') return String(item);
                if (item && typeof item === 'object') {
                if (typeof Node === 'function' && item instanceof Node) return '[' + String(item.nodeName) + ']';
                if (item === window) return '[Window]';
                if (__astralSeen.has(item)) return '[Circular]';
                __astralSeen.add(item);
                }
                return item;
                });
                } catch (error) { __astralJSON = undefined; }
                const __astralType = __astralValue === null ? 'null' : typeof __astralValue;
                if (typeof __astralJSON === 'string') return { type: __astralType, json: __astralJSON.slice(0, \(maximumEvaluationBytes + 1)) };
                let __astralText;
                try { __astralText = String(__astralValue); } catch (error) { __astralText = '[unprintable]'; }
                return { type: __astralType, text: __astralText.slice(0, \(maximumEvaluationBytes + 1)) };
                """
        }

        private func evaluate(
            _ args: [String: JSONValue], _ deadline: ContinuousClock.Instant,
            _ authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue] {
            try noDialog()
            try approvedPage()
            guard let source = args["script"]?.stringValue, !source.isEmpty, source.unicodeScalars.count <= 8000 else {
                throw ComputerHostError("out_of_range", "browser_evaluate needs a script of at most 8000 characters.")
            }
            try authorize()
            var value: JSONValue
            do {
                value = try await page.evaluate(
                    Self.evaluationBody(source, expression: true), within: try remaining(deadline))
            } catch let error as ComputerHostError
                where error.code == "script_error" && error.message.hasPrefix("SyntaxError")
            {
                try authorize()
                value = try await page.evaluate(
                    Self.evaluationBody(source, expression: false), within: try remaining(deadline))
            } catch let error as ComputerHostError where error.code == "pending_dialog" {
                return [
                    "result": .null, "type": .string("pending"), "truncated": .bool(false),
                    "dialog_opened": .bool(true),
                ]
            }
            if let thrown = value["thrown"]?.stringValue { throw ComputerHostError("script_error", thrown) }
            let type = value["type"]?.stringValue ?? "undefined"
            let text = value["json"]?.stringValue ?? value["text"]?.stringValue
            guard let text else { return ["result": .null, "type": .string(type), "truncated": .bool(false)] }
            if text.utf8.count > Self.maximumEvaluationBytes {
                var bytes = Array(text.utf8.prefix(Self.maximumEvaluationBytes))
                while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
                return [
                    "result": .string(String(decoding: bytes, as: UTF8.self)), "type": .string(type),
                    "truncated": .bool(true),
                ]
            }
            if value["json"] != nil, let parsed = try? JSONValue.parse(Data(text.utf8)) {
                return ["result": parsed, "type": .string(type), "truncated": .bool(false)]
            }
            return ["result": .string(text), "type": .string(type), "truncated": .bool(false)]
        }

        private func resize(_ args: [String: JSONValue], _ authorize: @escaping @Sendable () throws -> Void) throws
            -> [String: JSONValue]
        {
            var size = emulation
            var preset = emulationPreset
            if let name = args["preset"]?.stringValue {
                guard name == "desktop" || ComputerBrowserViewport.presets[name] != nil else {
                    throw ComputerHostError("out_of_range", "Use the mobile, tablet or desktop preset.")
                }
                size = ComputerBrowserViewport.presets[name]
                preset = name
            } else if args["width"] != nil || args["height"] != nil {
                guard let width = args["width"]?.numberValue, let height = args["height"]?.numberValue,
                    let custom = ComputerBrowserViewport(validWidth: Int(width), height: Int(height))
                else {
                    throw ComputerHostError(
                        "out_of_range", "Give width 320-3840 and height 320-2160 together, or a preset.")
                }
                size = custom
                preset = "custom"
            }
            var scheme = colorScheme
            if let requested = args["color_scheme"]?.stringValue {
                guard ["light", "dark"].contains(requested) else {
                    throw ComputerHostError("out_of_range", "color_scheme is light or dark.")
                }
                scheme = requested
            }
            try authorize()
            emulation = size
            emulationPreset = preset
            colorScheme = scheme
            applyViewport()
            let view = page.webView
            let zoom = max(0.05, view.pageZoom)
            let width = size?.width ?? Int((view.bounds.width / zoom).rounded())
            let height = size?.height ?? Int((view.bounds.height / zoom).rounded())
            return [
                "width": .number(Double(width)), "height": .number(Double(height)), "preset": .string(preset),
                "color_scheme": .string(scheme ?? "system"), "scale": .number((Double(zoom) * 1000).rounded() / 1000),
            ]
        }

        func applyViewport() {
            let appearance = colorScheme.flatMap { NSAppearance(named: $0 == "dark" ? .darkAqua : .aqua) }
            for tab in tabs {
                let view = tab.pane.webView
                view.appearance = appearance
                if let viewport = view.superview as? MacBrowserViewportView {
                    viewport.emulation = emulation
                    viewport.layoutSubtreeIfNeeded()
                } else {
                    MacBrowserViewportView.place(view, emulation: emulation, in: view.superview?.bounds)
                }
            }
        }

        private func invalidateReferences() {
            snapshots = []
            refs = [:]
            index = [:]
            issued = []
            granted = []
        }

        private func tabJSON(_ tab: MacBrowserTab) -> JSONValue {
            let shown = readable(tab.pane)
            return .object([
                "id": .string(tab.id), "active": .bool(tab.id == activeTabId),
                "url": shown ? .string(tab.pane.webView.url?.absoluteString ?? "about:blank") : .null,
                "title": shown ? .string(String((tab.pane.webView.title ?? "").prefix(300))) : .null,
                "approved": .bool(shown),
            ])
        }

        private func makeTab() -> MacBrowserTab {
            let pane = MacBrowserPane(context: context)
            install(pane)
            let tab = MacBrowserTab(id: "t\(nextTab)", pane: pane)
            nextTab += 1
            tabs.append(tab)
            applyViewport()
            return tab
        }

        private func retire(_ tab: MacBrowserTab) {
            tab.pane.close()
            tab.pane.webView.removeFromSuperview()
        }

        private func select(_ id: String) {
            guard id != activeTabId else { return }
            activeTabId = id
            invalidateReferences()
        }

        private func closeTab(_ id: String) throws {
            guard let position = tabs.firstIndex(where: { $0.id == id }) else {
                throw ComputerHostError("out_of_range", "No browser tab has id \(String(id.prefix(32))).")
            }
            guard tabs.count > 1 else {
                throw ComputerHostError("out_of_range", "The browser pane keeps at least one tab open.")
            }
            let tab = tabs.remove(at: position)
            if activeTabId == id { select(tabs[min(position, tabs.count - 1)].id) }
            retire(tab)
        }

        private func tabsAction(
            _ args: [String: JSONValue], _ deadline: ContinuousClock.Instant,
            _ authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue] {
            let action = args["action"]?.stringValue ?? "list"
            let id = args["tab_id"]?.stringValue
            var result: [String: JSONValue] = [:]
            switch action {
            case "list": break
            case "select":
                guard let id, tabs.contains(where: { $0.id == id }) else {
                    throw ComputerHostError("out_of_range", "No browser tab has id \(String((id ?? "").prefix(32))).")
                }
                try authorize()
                select(id)
            case "close":
                guard let id else { throw ComputerHostError("out_of_range", "Missing tab_id.") }
                try authorize()
                try closeTab(id)
            case "create":
                guard tabs.count < Self.maximumTabs else {
                    throw ComputerHostError(
                        "out_of_range", "The browser pane holds at most \(Self.maximumTabs) tabs. Close one first.")
                }
                let target = try args["url"]?.stringValue.map(navigationTarget)
                try authorize()
                let previous = activeTabId
                let tab = makeTab()
                select(tab.id)
                working = tab
                do {
                    try await tab.pane.prepare()
                    if let target {
                        let mark = page.mark()
                        try authorize()
                        approved.insert(target.origin)
                        page.load(target.url)
                        result = try await loaded(after: mark, deadline)
                    }
                } catch {
                    tabs.removeAll { $0.id == tab.id }
                    retire(tab)
                    if tabs.contains(where: { $0.id == previous }) { select(previous) }
                    working = activeTab
                    throw error
                }
                result["tab"] = tabJSON(tab)
            default:
                throw ComputerHostError("out_of_range", "browser_tabs takes list, create, close or select.")
            }
            working = activeTab
            result["tabs"] = .array(tabs.map(tabJSON))
            result["active"] = .string(activeTabId)
            return result
        }

        static func encode(_ image: CGImage, capture: CGRect, masks: [CGRect], maximumWidth: CGFloat, flipped: Bool)
            -> (data: Data, width: Int, height: Int)?
        {
            var width = max(1, min(Int(maximumWidth), image.width))
            for _ in 0..<6 {
                let height = max(1, Int((CGFloat(image.height) * CGFloat(width) / CGFloat(image.width)).rounded()))
                guard
                    let context = CGContext(
                        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                else { return nil }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                let scale = CGFloat(width) / max(1, capture.width)
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                for mask in masks {
                    let local = mask.intersection(capture)
                    guard !local.isNull, !local.isEmpty else { continue }
                    let x = (local.minX - capture.minX) * scale
                    let top = flipped ? (local.minY - capture.minY) * scale : (capture.maxY - local.maxY) * scale
                    context.fill(
                        CGRect(
                            x: x, y: CGFloat(height) - top - local.height * scale, width: local.width * scale,
                            height: local.height * scale))
                }
                guard let output = context.makeImage() else { return nil }
                let rep = NSBitmapImageRep(cgImage: output)
                for quality in [0.7, 0.5, 0.35] {
                    if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]),
                        !data.isEmpty, data.count <= maximumImageBytes
                    {
                        return (data, width, height)
                    }
                }
                width = max(1, Int(CGFloat(width) * 0.7))
            }
            return nil
        }

        func userNavigate(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
            do {
                let url = try ComputerBrowserPolicy.navigableURL(candidate)
                lastError = nil
                Task {
                    do {
                        try await pane.prepare()
                        pane.load(url, userInitiated: true)
                    } catch { lastError = error.localizedDescription }
                }
            } catch {
                lastError = "Enter an http or https address without sign-in details."
            }
        }

        func userHistory(_ action: String) {
            _ = pane.history(action, userInitiated: true)
        }

        func userAnswerDialog(accept: Bool) {
            _ = try? pane.answer(accept: accept, text: nil)
        }

        func requestTakeover() {
            guard agentActive() else { return }
            takeover()
        }

        func userSelectTab(_ id: String) {
            guard id != activeTabId, tabs.contains(where: { $0.id == id }) else { return }
            humanInput()
            select(id)
        }

        func userCloseTab(_ id: String) {
            guard tabs.count > 1, tabs.contains(where: { $0.id == id }) else { return }
            humanInput()
            try? closeTab(id)
        }

        func userNewTab() {
            guard tabs.count < Self.maximumTabs else { return }
            humanInput()
            select(makeTab().id)
        }

        func userResize(preset: String) {
            emulation = ComputerBrowserViewport.presets[preset]
            emulationPreset = emulation == nil ? "desktop" : preset
            applyViewport()
        }

        func userColorScheme(_ scheme: String?) {
            colorScheme = scheme
            applyViewport()
        }
    }
#endif
