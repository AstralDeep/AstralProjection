// Executes the ten browser verbs in the Mac browser pane for MacComputerHost, acting only on approved origins,
// refusing stale references and secret fields, and holding consequential controls until a matching server permit.
// The host routes browser_* requests here through MacBrowserVerbHandling; MacBrowserPaneView presents the pane.

#if os(macOS)
    import AppKit
    import AstralCore
    import CryptoKit
    import Foundation
    import Observation

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
        static let embeddedViewRefusers: Set<String> = ["accounts.google.com"]

        let pane: MacBrowserPane
        var isPresented = false
        private(set) var driving = false
        private(set) var paneEnabled = false
        private(set) var lastError: String?
        @ObservationIgnored weak var host: MacComputerHost?
        @ObservationIgnored var takeover: () -> Void
        @ObservationIgnored var agentActive: () -> Bool
        @ObservationIgnored private let defaults: UserDefaults
        @ObservationIgnored private var owner: String?
        @ObservationIgnored private var sessionId: String?
        @ObservationIgnored private(set) var approved: Set<String> = []
        @ObservationIgnored private var snapshots: [Snapshot] = []
        @ObservationIgnored private var refs: [String: (token: String, local: Int)] = [:]
        @ObservationIgnored private var index: [String: String] = [:]
        @ObservationIgnored private var refGeneration = -1
        @ObservationIgnored private var nextRef = 1
        @ObservationIgnored private var nextSnapshot = 1
        @ObservationIgnored private var issued: Set<String> = []
        @ObservationIgnored private var granted: Set<String> = []
        @ObservationIgnored private var consumed: Set<String> = []
        @ObservationIgnored private var active = 0
        @ObservationIgnored private var settleUntil = 0.0
        @ObservationIgnored private var linger: Task<Void, Never>?

        init(host: MacComputerHost?, defaults: UserDefaults = .standard, pane: MacBrowserPane? = nil) {
            self.pane = pane ?? MacBrowserPane()
            self.defaults = defaults
            self.host = host
            takeover = { [weak host] in host?.takeover() }
            agentActive = { [weak host] in host?.session?.state == "active" }
            self.pane.navigationRule = { [weak self] url, user in self?.allows(url, userInitiated: user) ?? false }
            self.pane.humanInput = { [weak self] in self?.humanInput() }
            host?.browser = self
        }

        var isEnabled: Bool { paneEnabled && owner != nil && pane.unavailable == nil }
        var accountBound: Bool { owner != nil }

        func bind(owner: String?) {
            guard self.owner != owner else { return }
            self.owner = owner
            paneEnabled = preferenceKey.map { defaults.bool(forKey: $0) } ?? false
            resetSession(nil)
            if !paneEnabled { isPresented = false }
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
                remaining: ticket.expiresAt - ProcessInfo.processInfo.systemUptime, authorize: authorize)
        }

        func execute(
            _ verb: String, args: [String: JSONValue], session: String, remaining: Double,
            authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue] {
            try authorize()
            if session != sessionId { resetSession(session) }
            let ceiling = ["browser_navigate", "browser_wait"].contains(verb) ? 15.0 : 5.0
            let budget = min(ceiling, remaining - 0.35)
            guard budget > 0.2 else {
                throw ComputerHostError("interrupted", "The request deadline leaves no time for the browser pane.")
            }
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(budget * 1000)))
            begin()
            defer { end() }
            try await pane.prepare()
            _ = pane.takeNotices()
            var result: [String: JSONValue]
            switch verb {
            case "browser_snapshot": result = try await snapshot(args, deadline)
            case "browser_get_text": result = try await text(args, deadline)
            case "browser_screenshot": result = try await screenshot(args, deadline)
            case "browser_wait": result = try await wait(args, deadline)
            case "browser_navigate": result = try await navigate(args, deadline, authorize)
            case "browser_click": result = try await click(args, deadline, authorize)
            case "browser_fill": result = try await fill(args, deadline, authorize)
            case "browser_press": result = try await press(args, deadline, authorize)
            case "browser_scroll": result = try await scroll(args, deadline, authorize)
            case "browser_dialog": result = try await dialog(args, authorize)
            default: throw ComputerHostError("unsupported", "That browser action is not available.")
            }
            try authorize()
            result["url"] = .string(pane.webView.url?.absoluteString ?? "about:blank")
            result["title"] = .string(String((pane.webView.title ?? "").prefix(300)))
            result["pending_dialog"] = pane.dialogs.first?.json ?? .null
            let notices = pane.takeNotices()
            if !notices.isEmpty { result["blocked"] = .array(notices.map(\.json)) }
            return result
        }

        private func begin() {
            active += 1
            driving = true
            isPresented = true
            linger?.cancel()
            lastError = nil
        }

        private func end() {
            active = max(0, active - 1)
            settleUntil = ProcessInfo.processInfo.systemUptime + 2
            guard active == 0 else { return }
            linger = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
                guard let self, self.active == 0 else { return }
                self.driving = false
            }
        }

        private func allows(_ url: URL, userInitiated: Bool) -> Bool {
            guard let origin = ComputerBrowserPolicy.origin(of: url) else { return false }
            if userInitiated || approved.contains(origin) { return true }
            return active == 0 && ProcessInfo.processInfo.systemUptime >= settleUntil
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
            issued = []
            granted = []
            consumed = []
        }

        private func syncGeneration() {
            guard refGeneration != pane.generation else { return }
            refGeneration = pane.generation
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

        private var currentOrigin: String? { pane.webView.url.flatMap(ComputerBrowserPolicy.origin(of:)) }

        private var blank: Bool {
            guard let url = pane.webView.url else { return true }
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
            guard pane.dialogs.isEmpty else {
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
            guard let record, record.generation == pane.generation, record.refs.contains(ref),
                let frame = pane.frames.first(where: { $0.token == entry.token })
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
            let value = try await pane.call(
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
            if granted.contains(key) { return true }
            guard let permit = args["permit"]?.objectValue, permit["origin"]?.stringValue == origin,
                permit["snapshot_id"]?.stringValue == snapshot, issued.contains(key), !consumed.contains(key)
            else { return false }
            let named =
                permit["refs"]?.arrayValue?.compactMap(\.stringValue) ?? permit["ref"].flatMap(\.stringValue).map {
                    [$0]
                } ?? []
            guard named.contains(ref) else { return false }
            granted.insert(key)
            return true
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

        private func snapshot(_ args: [String: JSONValue], _ deadline: ContinuousClock.Instant) async throws
            -> [String: JSONValue]
        {
            syncGeneration()
            let mode = args["mode"]?.stringValue ?? "interactive"
            let maximum = Int(args["max_chars"]?.numberValue ?? 60000)
            let generation = pane.generation
            let id = "s\(nextSnapshot)"
            nextSnapshot += 1
            var lines: [String] = []
            var listed = Set<String>()
            var frames: [JSONValue] = []
            var truncated = false
            var used = 0
            func add(_ line: String) -> Bool {
                guard used + line.count + 1 <= maximum else {
                    truncated = true
                    return false
                }
                lines.append(line)
                used += line.count + 1
                return true
            }
            defer {
                snapshots.append(Snapshot(id: id, generation: generation, refs: listed))
                if snapshots.count > 8 { snapshots.removeFirst(snapshots.count - 8) }
            }
            var result: [String: JSONValue] = ["snapshot_id": .string(id), "mode": .string(mode)]
            if !pane.dialogs.isEmpty || blank {
                result.merge(["lines": .array([]), "frames": .array([]), "truncated": .bool(false)]) { $1 }
                return result
            }
            let origin = try approvedPage()
            let scope = try args["scope_ref"]?.stringValue.map { try locate($0, snapshot: nil) }
            guard try await pane.waitForMainFrame(within: min(.seconds(1), try remaining(deadline))) != nil else {
                result.merge(["lines": .array([]), "frames": .array([]), "truncated": .bool(false)]) { $1 }
                return result
            }
            for frame in pane.frames {
                frames.append(.object(["id": .string(frame.id), "url": .string(frame.url)]))
                if let scope, scope.token != frame.token { continue }
                let allowed = frame.isMain || frame.origin.map { approved.contains($0) || $0 == origin } == true
                if !frame.isMain && scope == nil {
                    let header = "frame \(frame.id) " + Self.quoted(frame.url) + (allowed ? "" : " origin not approved")
                    guard add(header) else { break }
                }
                guard allowed else { continue }
                var call: [String: Any] = ["snapshot": id, "mode": mode, "max_chars": max(1, maximum - used)]
                if let scope {
                    call["scope"] = scope.local
                    call["scope_snapshot"] = scope.snapshot
                }
                let value: JSONValue
                do {
                    value = try await pane.call(.snapshot, call, in: frame, within: try remaining(deadline))
                } catch let error as ComputerHostError where !frame.isMain && error.code != "timeout" {
                    continue
                }
                if value["error"] != nil {
                    if scope != nil || frame.isMain { try script(value, ref: args["scope_ref"]?.stringValue) }
                    continue
                }
                for node in value["nodes"]?.arrayValue ?? [] {
                    guard let local = node["id"]?.numberValue, let line = node["line"]?.stringValue else { continue }
                    let ref = refName(frame.token, Int(local))
                    guard add("[\(ref)] " + String(line.prefix(2000))) else { break }
                    listed.insert(ref)
                }
                if value["truncated"]?.boolValue == true { truncated = true }
                if truncated { break }
            }
            result.merge([
                "lines": .array(lines.map(JSONValue.string)), "frames": .array(frames), "truncated": .bool(truncated),
                "origin": .string(origin),
            ]) { $1 }
            return result
        }

        static func quoted(_ text: String) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            let data = (try? encoder.encode(String(text.prefix(300)))) ?? Data("\"\"".utf8)
            return String(decoding: data, as: UTF8.self)
        }

        private func mainFrame(_ deadline: ContinuousClock.Instant) async throws -> MacBrowserFrame {
            guard let frame = try await pane.waitForMainFrame(within: min(.seconds(1), try remaining(deadline))) else {
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
                value = try await pane.call(
                    .text, ["snapshot": target.snapshot, "id": target.local, "max_chars": maximum], in: target.frame,
                    within: try remaining(deadline))
                try script(value, ref: ref)
            } else {
                value = try await pane.call(
                    .text, ["max_chars": maximum], in: try await mainFrame(deadline), within: try remaining(deadline))
                try script(value, ref: nil)
            }
            return [
                "text": .string(String((value["text"]?.stringValue ?? "").prefix(maximum))),
                "truncated": .bool(value["truncated"]?.boolValue ?? false),
            ]
        }

        private func navigate(
            _ args: [String: JSONValue], _ deadline: ContinuousClock.Instant,
            _ authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue] {
            try noDialog()
            let mark = pane.mark()
            if let text = args["url"]?.stringValue {
                let url = try ComputerBrowserPolicy.navigableURL(text)
                guard let origin = ComputerBrowserPolicy.origin(of: url) else {
                    throw ComputerHostError("url_rejected", "The browser pane cannot open that address.")
                }
                approved.insert(origin)
                try authorize()
                pane.load(url)
            } else {
                let action = args["action"]?.stringValue ?? ""
                if action == "reload" { try approvedPage() }
                try authorize()
                guard pane.history(action) else {
                    throw ComputerHostError("out_of_range", "There is no page to go \(action) to.")
                }
            }
            let outcome = try await pane.waitForLoad(after: mark, within: try remaining(deadline))
            var result: [String: JSONValue] = ["loaded": .bool(outcome == .finished)]
            switch outcome {
            case .finished?, nil: break
            case .failed(let reason)?:
                throw ComputerHostError(
                    "navigation_failed",
                    "The page could not be opened in the browser pane (\(reason)). Sites that refuse embedded views "
                        + "need the user's own browser through the desktop path.")
            case .refused?:
                let notices = pane.takeNotices()
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
            if let status = pane.mainStatus { result["status"] = .number(Double(status)) }
            if let host = pane.webView.url?.host?.lowercased(), Self.embeddedViewRefusers.contains(host) {
                result["note"] = .string(
                    "This sign-in page refuses embedded browsers. Ask the user to use their own browser through the "
                        + "desktop path.")
            }
            if let origin = currentOrigin { result["origin"] = .string(origin) }
            return result
        }

        private func settleNavigation(after mark: Int, _ deadline: ContinuousClock.Instant) async throws -> Bool {
            guard pane.events.contains(where: { $0.sequence > mark && $0.event == .started }) else { return false }
            let left = (deadline - ContinuousClock.now) - .milliseconds(150)
            if left > .milliseconds(50) { _ = try await pane.waitForLoad(after: mark, within: left) }
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
            try authorize()
            let mark = pane.mark()
            let right = args["button"]?.stringValue == "right"
            let count = Int(args["count"]?.numberValue ?? 1)
            let value: JSONValue
            do {
                value = try await pane.call(
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
                if pane.dialogs.isEmpty,
                    let settled = try? await pane.call(
                        .settle, ["observation": Int(observation)], in: target.frame,
                        within: min(.seconds(1), try remaining(deadline)))
                {
                    effect = settled["effect"]?.boolValue ?? true
                }
            }
            if pane.dialogs.first != nil {
                return ["clicked": .string(ref), "method": .string("synthetic"), "dialog_opened": .bool(true)]
            }
            var method = "synthetic"
            if !effect, !consequential,
                !pane.events.contains(where: { $0.sequence > mark }), let point = viewPoint(value["geometry"])
            {
                try authorize()
                try pane.nativeClick(at: point, right: right, count: count)
                method = "native"
            }
            let navigated = try await settleNavigation(after: mark, deadline)
            return ["clicked": .string(ref), "method": .string(method), "navigated": .bool(navigated)]
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
            let view = pane.webView
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
                    reviewed.append(ref)
                }
                plan.append((ref, value, target))
            }
            var filled: [JSONValue] = []
            for item in plan {
                try authorize()
                let value: JSONValue
                do {
                    value = try await pane.call(
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
            let focus = try await pane.call(.focusTarget, call, in: frame, within: try remaining(deadline))
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
            let mark = pane.mark()
            call["key"] = chord.key
            for modifier in ["cmd", "ctrl", "alt", "shift"] { call[modifier] = chord.modifiers.contains(modifier) }
            let value: JSONValue
            do {
                value = try await pane.call(.press, call, in: frame, within: try remaining(deadline))
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
            let value = try await pane.call(.scroll, call, in: frame, within: try remaining(deadline))
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
            guard let dialog = pane.dialogs.first else {
                throw ComputerHostError("no_dialog", "No page dialog is waiting.")
            }
            let accept = args["action"]?.stringValue == "accept"
            if args["text"] != nil && dialog.type != "prompt" {
                throw ComputerHostError("out_of_range", "Only a prompt dialog takes text.")
            }
            try authorize()
            _ = try pane.answer(accept: accept, text: args["text"]?.stringValue)
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
                case "load": matched = !pane.webView.isLoading
                case "text":
                    let frame = try await mainFrame(deadline)
                    let value = try await pane.call(
                        .contains, ["text": args["text"]?.stringValue ?? ""], in: frame, within: try remaining(deadline)
                    )
                    matched = value["matched"]?.boolValue == true
                default:
                    guard let target else { throw ComputerHostError("out_of_range", "Missing ref.") }
                    let value = try await pane.call(
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

        private func screenshot(_ args: [String: JSONValue], _ deadline: ContinuousClock.Instant) async throws
            -> [String: JSONValue]
        {
            try noDialog()
            if !blank { try approvedPage() }
            let maximum = CGFloat(args["max_width"]?.numberValue ?? 1280)
            let view = pane.webView
            let zoom = view.pageZoom * view.magnification
            func rect(_ box: JSONValue?, offset: JSONValue?) -> CGRect? {
                guard let box, let x = box["x"]?.numberValue, let y = box["y"]?.numberValue,
                    let width = box["width"]?.numberValue, let height = box["height"]?.numberValue
                else { return nil }
                let ox = offset?["x"]?.numberValue ?? 0
                let oy = offset?["y"]?.numberValue ?? 0
                let top = (oy + y) * zoom
                return CGRect(
                    x: (ox + x) * zoom, y: view.isFlipped ? top : view.bounds.height - top - height * zoom,
                    width: width * zoom, height: height * zoom)
            }
            var capture = view.bounds
            if let ref = args["ref"]?.stringValue {
                let target = try locate(ref, snapshot: nil)
                let value = try await pane.call(
                    .geometry, ["snapshot": target.snapshot, "id": target.local, "reveal": true], in: target.frame,
                    within: try remaining(deadline))
                try script(value, ref: ref)
                guard value["offset"]?.objectValue != nil, let box = rect(value, offset: value["offset"]),
                    !box.intersection(view.bounds).isNull, !box.intersection(view.bounds).isEmpty
                else {
                    throw ComputerHostError("out_of_range", "That element is not visible in the browser pane.")
                }
                capture = box.intersection(view.bounds)
            }
            var masks: [CGRect] = []
            if !blank {
                var unplaced = false
                var frameBoxes: [CGRect] = []
                for frame in pane.frames {
                    guard
                        let value = try? await pane.call(
                            .secretRects, [:], in: frame, within: min(.seconds(1), try remaining(deadline)))
                    else { continue }
                    let rects = value["rects"]?.arrayValue ?? []
                    if frame.isMain {
                        frameBoxes = (value["frames"]?.arrayValue ?? []).compactMap { rect($0, offset: nil) }
                    }
                    if value["offset"]?.objectValue == nil {
                        if !rects.isEmpty { unplaced = true }
                        continue
                    }
                    masks += rects.compactMap { rect($0, offset: value["offset"]) }
                }
                let crossOrigin = pane.frames.contains { !$0.isMain && $0.origin != currentOrigin }
                if unplaced || crossOrigin { masks += frameBoxes }
            }
            let image = try await pane.image(rect: capture, width: capture.width, within: try remaining(deadline))
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
    }
#endif
