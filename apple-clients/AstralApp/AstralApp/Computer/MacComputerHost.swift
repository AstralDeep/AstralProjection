// Coordinates the direct-download Mac's explicit consent, current host session and bounded execution queue.
// AppModel supplies an owner-fenced live channel; native controls can revoke authority without waiting for OS work.

#if os(macOS)
    import AppKit
    import ApplicationServices
    import AstralCore
    import CryptoKit
    import Foundation
    import Observation
    import Security
    import SwiftUI

    struct MacComputerPermissions: Sendable {
        let accessibility: Bool
        let screen: Bool
        let monitoring: Bool
        @MainActor static func current() -> MacComputerPermissions {
            MacComputerPermissions(
                accessibility: AXIsProcessTrusted() && CGPreflightPostEventAccess(),
                screen: CGPreflightScreenCaptureAccess(), monitoring: CGPreflightListenEventAccess())
        }
    }

    @MainActor @Observable
    final class MacComputerHost {
        private struct PauseWaiter {
            let continuation: CheckedContinuation<Bool, Never>
            let timeout: Task<Void, Never>
        }
        let available: Bool
        private(set) var enabled = false
        private(set) var desktopAvailable = false
        private(set) var session: ComputerHostSession?
        var controlsPresented = false
        private(set) var accessibilityAllowed = false
        private(set) var screenAllowed = false
        private(set) var monitoringAllowed = false
        private(set) var lastError: String?
        let files: MacComputerFiles
        @ObservationIgnored private let defaults: UserDefaults
        @ObservationIgnored private let authority = ComputerHostAuthority()
        @ObservationIgnored private let driver: any MacComputerDriving
        @ObservationIgnored private let monitor: any MacComputerMonitoring
        @ObservationIgnored private let permissionProvider: @MainActor () -> MacComputerPermissions
        @ObservationIgnored private let desktopProbe: @Sendable () -> Bool
        @ObservationIgnored private let desktopRearm: @MainActor () -> Bool
        @ObservationIgnored private let localResume: @MainActor () -> Bool
        @ObservationIgnored private let localInput: MacComputerLocalInput?
        @ObservationIgnored private let hostId: String
        @ObservationIgnored private var owner: String?
        @ObservationIgnored private var sender: (@MainActor (String) async -> Bool)?
        @ObservationIgnored private var queue: [(ComputerHostRequest, ComputerHostTicket)] = []
        @ObservationIgnored private var worker: Task<Void, Never>?
        @ObservationIgnored private var workerId = UUID()
        @ObservationIgnored private var heartbeat: Task<Void, Never>?
        @ObservationIgnored private var startedAt: Double?
        @ObservationIgnored private var panel: NSPanel?
        @ObservationIgnored private var observers: [NSObjectProtocol] = []
        @ObservationIgnored private var awaitingPauseAcknowledgment = false
        @ObservationIgnored private var localPauseReason: String?
        @ObservationIgnored private var channelEpoch = UUID()
        @ObservationIgnored private var outboundTail: Task<Bool, Never>?
        @ObservationIgnored private var pauseWaiters: [UUID: PauseWaiter] = [:]

        init(
            available: Bool? = nil, defaults: UserDefaults = .standard, driver: (any MacComputerDriving)? = nil,
            monitor: (any MacComputerMonitoring)? = nil,
            permissionProvider: (@MainActor () -> MacComputerPermissions)? = nil,
            desktopProbe: @escaping @Sendable () -> Bool = MacComputerDesktopProbe.usable,
            desktopRearm: (@MainActor () -> Bool)? = nil
        ) {
            self.available = available ?? Self.executionDistribution()
            self.defaults = defaults
            files = MacComputerFiles(defaults: defaults)
            let marker = Int64.random(in: 1...Int64.max)
            self.monitor = monitor ?? MacComputerInputMonitor(marker: marker)
            self.permissionProvider = permissionProvider ?? MacComputerPermissions.current
            self.desktopProbe = desktopProbe
            let localInput = self.available && desktopRearm == nil ? MacComputerLocalInput(marker: marker) : nil
            self.localInput = localInput
            self.desktopRearm =
                desktopRearm ?? {
                    localInput?.consume(current: NSApp.currentEvent?.cgEvent) == true
                        && MacComputerDesktopProbe.localRearm()
                }
            self.localResume =
                desktopRearm ?? {
                    localInput?.consume(current: NSApp.currentEvent?.cgEvent) == true
                }
            self.driver = driver ?? MacComputerDriver(marker: marker)
            if let stored = defaults.string(forKey: "computer.host.id"),
                UUID(uuidString: stored)?.uuidString.lowercased() == stored
            {
                hostId = stored
            } else {
                let fresh = UUID().uuidString.lowercased()
                defaults.set(fresh, forKey: "computer.host.id")
                hostId = fresh
            }
            if self.available {
                let center = NSWorkspace.shared.notificationCenter
                let authority = authority
                for name in [
                    NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification,
                    NSWorkspace.willSleepNotification,
                ] {
                    observers.append(
                        center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                            authority.setDesktopAvailable(false)
                            guard let host = self else { return }
                            Task { @MainActor in host.sessionLocked() }
                        })
                }
                observers.append(
                    DistributedNotificationCenter.default().addObserver(
                        forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: nil
                    ) { [weak self] _ in
                        authority.setDesktopAvailable(false)
                        guard let host = self else { return }
                        Task { @MainActor in host.sessionLocked() }
                    })
            }
            refreshPermissions()
        }
        private static func executionDistribution() -> Bool {
            guard Bundle.main.object(forInfoDictionaryKey: "ASTRALDistribution") as? String == "direct-download" else {
                return false
            }
            var code: SecCode?
            var staticCode: SecStaticCode?
            var information: CFDictionary?
            guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code,
                SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode,
                SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                    == errSecSuccess,
                let info = information as? [String: Any]
            else { return false }
            let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
            let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
            return ComputerHostDistribution.permits(
                marker: Bundle.main.object(forInfoDictionaryKey: "ASTRALDistribution") as? String,
                sandboxed: entitlements["com.apple.security.app-sandbox"] as? Bool == true,
                hardened: flags & SecCodeSignatureFlags.runtime.rawValue != 0,
                signatureValid: SecCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess,
                identityMatches: info[kSecCodeInfoIdentifier as String] as? String == Bundle.main.bundleIdentifier,
                debuggerAllowed: entitlements["com.apple.security.get-task-allow"] as? Bool == true)
        }
        private var consentKey: String? {
            owner.map {
                "computer.consent." + SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
            }
        }
        var statusLabel: String {
            if !available { return "This build is a computer controller" }
            if let session { return session.state == "paused" ? "Computer task paused" : "Computer task active" }
            if owner == nil { return "Sign in to enable this Mac" }
            if enabled && sender == nil { return "Computer access is paused while disconnected" }
            if enabled && desktopAvailable { return "Local computer access is enabled on this Mac" }
            return "Computer access is off"
        }
        var ownerBound: Bool { owner != nil }
        var awaitingPause: Bool { awaitingPauseAcknowledgment }
        var canResume: Bool {
            session?.state == "paused" && !awaitingPauseAcknowledgment && desktopAvailable && permissionsReady
                && sender != nil
        }
        private var permissionsReady: Bool { accessibilityAllowed && screenAllowed && monitoringAllowed }
        var descriptor: ComputerHostDescriptor? {
            guard available, enabled, desktopAvailable, authority.desktopIsAvailable, owner != nil, permissionsReady,
                monitor.running
            else { return nil }
            var count: UInt32 = 0
            guard CGGetActiveDisplayList(0, nil, &count) == .success, (1...8).contains(count) else { return nil }
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
            ids.sort { a, b in a == CGMainDisplayID() || (b != CGMainDisplayID() && a < b) }
            let screens = ids.enumerated().map { index, id in
                ComputerHostScreen(
                    index: index, width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id),
                    scale: Double(CGDisplayPixelsWide(id)) / max(1, CGDisplayBounds(id).width),
                    primary: id == CGMainDisplayID())
            }
            var verbs = ComputerHostRequest.verbs
            if files.roots.isEmpty { verbs.subtract(["read_file", "list_dir", "write_file", "delete_path"]) }
            let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.8"
            let version = raw.split(separator: ".").count == 2 ? raw + ".0" : raw
            let name = String(
                (Host.current().localizedName ?? "This Mac").unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }
                    .prefix(64).map(String.init).joined())
            return try? ComputerHostDescriptor(
                hostId: hostId, name: name.isEmpty ? "This Mac" : name, clientVersion: version, screens: screens,
                verbs: verbs.sorted())
        }
        func bind(owner: String?, sender: @escaping @MainActor (String) async -> Bool) {
            disconnect()
            if self.owner != owner { files.bind(owner) }
            self.owner = owner
            self.sender = sender
            enabled = available && desktopAvailable && consentKey.map { defaults.bool(forKey: $0) } == true
            refreshPermissions()
            if enabled && permissionsReady { _ = monitor.start { [weak self] in self?.pause(reason: "local_input") } }
        }
        func disconnect() {
            localInput?.invalidate()
            channelEpoch = UUID()
            outboundTail?.cancel()
            outboundTail = nil
            retire()
            sender = nil
            monitor.stop()
        }
        func signedOut() {
            disconnect()
            desktopAvailable = false
            authority.setDesktopAvailable(false)
            owner = nil
            enabled = false
            files.bind(nil)
        }
        func showControls() {
            refreshPermissions()
            controlsPresented = true
        }
        func flushCurrentSends() async -> Bool {
            let epoch = channelEpoch
            guard sender != nil, let pending = outboundTail, await pending.value else { return false }
            return epoch == channelEpoch && sender != nil
        }
        func refreshPermissions() {
            let permissions = permissionProvider()
            accessibilityAllowed = permissions.accessibility
            screenAllowed = permissions.screen
            monitoringAllowed = permissions.monitoring
            if enabled && (!authority.desktopIsAvailable || !desktopProbe()) {
                sessionLocked()
                return
            }
            if enabled && !permissionsReady {
                setEnabled(false)
                lastError = "Computer permission is missing or was revoked. Grant access and enable this Mac again."
            }
        }
        func requestAccessibility() {
            _ = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            _ = CGRequestPostEventAccess()
            refreshPermissions()
        }
        func requestScreen() {
            _ = CGRequestScreenCaptureAccess()
            refreshPermissions()
        }
        func requestMonitoring() {
            _ = CGRequestListenEventAccess()
            refreshPermissions()
        }
        func setEnabled(_ value: Bool) {
            guard available else {
                enabled = false
                return
            }
            if value {
                guard owner != nil, permissionsReady else {
                    lastError = "Sign in and grant the listed permissions before enabling this Mac."
                    return
                }
                guard desktopRearm(), desktopProbe() else {
                    lastError = "Enable access yourself from Astral's active, unlocked local desktop."
                    return
                }
                desktopAvailable = true
                authority.setDesktopAvailable(true)
                guard monitor.start({ [weak self] in self?.pause(reason: "local_input") }) else {
                    lastError = "Human input monitoring could not start. Computer access remains off."
                    return
                }
                enabled = true
                lastError = nil
                if let key = consentKey { defaults.set(true, forKey: key) }
                if let descriptor { sendEvent("announce", additional: ["host": descriptor.json]) }
            } else {
                localInput?.invalidate()
                retire()
                enabled = false
                monitor.stop()
                if let key = consentKey { defaults.set(false, forKey: key) }
                sendEvent("withdraw")
            }
        }
        func workspacesChanged() {
            stop()
            if enabled, let descriptor { sendEvent("announce", additional: ["host": descriptor.json]) }
        }
        func sessionLocked() {
            authority.setDesktopAvailable(false)
            desktopAvailable = false
            setEnabled(false)
            lastError = "Computer control stopped because this desktop became unavailable."
        }
        func applicationWillTerminate() {
            localInput?.stop()
            stop()
            monitor.stop()
            authority.invalidate()
        }
        func pause() { pause(reason: "local_pause") }
        private func pause(reason: String) {
            guard let current = session, current.state == "active" else { return }
            localInput?.invalidate()
            authority.pause()
            cancelWork(resetDriver: false)
            awaitingPauseAcknowledgment = true
            localPauseReason = reason
            session = try? ComputerHostSession(
                json: .object([
                    "session_id": .string(current.id), "host_id": .string(hostId), "state": .string("paused"),
                    "controller_label": .string(current.controller),
                ]))
            sendEvent("paused", additional: ["session_id": .string(current.id), "reason": .string(reason)])
            showPanel()
        }
        func resume() {
            guard let current = session, current.state == "paused", !awaitingPauseAcknowledgment, permissionsReady
            else { return }
            guard localResume(), desktopProbe() else {
                lastError = "Resume this task yourself using Astral's local session controls."
                return
            }
            sendEvent("resumed", additional: ["session_id": .string(current.id)])
        }
        func recordApprovalInteraction() -> String? {
            let id = session?.id
            if session?.state == "active" { pause(reason: "local_input") }
            return id
        }
        func approvalStillCurrent(_ expected: String?) -> Bool {
            guard let expected else { return true }
            return session?.id == expected && session?.state == "paused" && localPauseReason == "local_input"
                && enabled && desktopAvailable && authority.desktopIsAvailable && permissionsReady && monitor.running
        }
        func flushApprovalPause(_ expected: String?) async -> Bool {
            guard let expected else { return true }
            guard approvalStillCurrent(expected) else { return false }
            let epoch = channelEpoch
            guard let pending = outboundTail, await pending.value else { return false }
            guard epoch == channelEpoch && approvalStillCurrent(expected) else { return false }
            if approvalPauseReady(expected) { return true }
            guard pauseWaiters.count < 32 else { return false }
            let id = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled, epoch == channelEpoch, approvalStillCurrent(expected) else {
                        continuation.resume(returning: false)
                        return
                    }
                    if approvalPauseReady(expected) {
                        continuation.resume(returning: true)
                        return
                    }
                    let timeout = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                        self?.resolvePauseWaiter(id, accepted: false)
                    }
                    pauseWaiters[id] = PauseWaiter(continuation: continuation, timeout: timeout)
                }
            } onCancel: {
                Task { @MainActor in self.resolvePauseWaiter(id, accepted: false) }
            }
        }
        func approvalPauseReady(_ expected: String?) -> Bool {
            approvalStillCurrent(expected) && !awaitingPauseAcknowledgment
        }
        private func resolvePauseWaiter(_ id: UUID, accepted: Bool) {
            guard let waiter = pauseWaiters.removeValue(forKey: id) else { return }
            waiter.timeout.cancel()
            waiter.continuation.resume(returning: accepted)
        }
        private func resolvePauseWaiters(accepted: Bool) {
            for id in Array(pauseWaiters.keys) { resolvePauseWaiter(id, accepted: accepted) }
        }
        func stop() {
            if let session {
                sendEvent("stopped", additional: ["session_id": .string(session.id), "reason": .string("local_stop")])
            }
            retire()
        }
        private func cancelWork(resetDriver: Bool = true) {
            workerId = UUID()
            worker?.cancel()
            worker = nil
            queue = []
            if resetDriver { Task { await driver.reset() } }
        }
        private func retire() {
            resolvePauseWaiters(accepted: false)
            authority.invalidate()
            cancelWork()
            session = nil
            startedAt = nil
            heartbeat?.cancel()
            heartbeat = nil
            awaitingPauseAcknowledgment = false
            localPauseReason = nil
            panel?.orderOut(nil)
            panel = nil
        }
        @discardableResult
        func consume(_ frame: InboundFrame) -> Bool {
            if frame.name == "computer_host" { return true }
            if frame.name == "computer_session" {
                guard let incoming = try? ComputerHostSession(json: frame.payload), incoming.hostId == hostId else {
                    return true
                }
                if incoming.state == "ended" {
                    if session?.id == incoming.id { retire() }
                    return true
                }
                refreshPermissions()
                guard available, enabled, desktopAvailable, authority.desktopIsAvailable, permissionsReady,
                    monitor.running
                else { return true }
                do {
                    if incoming.id != session?.id {
                        resolvePauseWaiters(accepted: false)
                        cancelWork()
                    }
                    if incoming.state == "active" {
                        if awaitingPauseAcknowledgment && incoming.id == session?.id { return true }
                        try authority.begin(incoming.id)
                        if incoming.id == session?.id && session?.state == "paused" { authority.resume() }
                    } else {
                        if incoming.id != session?.id { try authority.begin(incoming.id) }
                        authority.pause()
                        cancelWork(resetDriver: false)
                        awaitingPauseAcknowledgment = false
                        if let reason = frame.payload["pause_reason"]?.stringValue { localPauseReason = reason }
                    }
                    if session?.id != incoming.id { startedAt = ProcessInfo.processInfo.systemUptime }
                    session = incoming
                    if incoming.state == "paused" { resolvePauseWaiters(accepted: approvalPauseReady(incoming.id)) }
                    showPanel()
                    startHeartbeat()
                } catch { lastError = error.localizedDescription }
                return true
            }
            guard frame.name == "computer_request" else { return false }
            let request: ComputerHostRequest
            do { request = try ComputerHostRequest(json: frame.payload) } catch {
                if let id = frame.payload["request_id"]?.stringValue { respond(id, error: error) }
                return true
            }
            do {
                refreshPermissions()
                guard available, enabled, permissionsReady, monitor.running, sender != nil,
                    descriptor?.verbs.contains(request.verb) == true
                else {
                    throw ComputerHostError(
                        "permission_denied", "This Mac has not granted the requested computer capability.")
                }
                let ticket = try authority.admit(request)
                queue.append((request, ticket))
                drain()
            } catch { respond(request.id, error: error) }
            return true
        }
        private func drain() {
            guard worker == nil, !queue.isEmpty else { return }
            let (request, ticket) = queue.removeFirst()
            let authority = authority
            let driver = driver
            let desktopProbe = desktopProbe
            let workspaces = files.snapshot()
            let id = UUID()
            workerId = id
            worker = Task { [weak self] in
                let result: Result<[String: JSONValue], Error>
                do {
                    result = .success(
                        try await driver.execute(request, workspaces: workspaces) {
                            try authority.verify(ticket)
                            guard desktopProbe() else {
                                authority.setDesktopAvailable(false)
                                throw ComputerHostError(
                                    "screen_locked", "This desktop is unavailable. Enable it locally after unlocking.")
                            }
                            try authority.verify(ticket)
                        })
                } catch { result = .failure(error) }
                guard let self, self.workerId == id else { return }
                do {
                    try authority.verify(ticket)
                    switch result {
                    case .success(let value): self.respond(request.id, result: value)
                    case .failure(let error):
                        self.respond(request.id, error: error)
                        self.lastError = error.localizedDescription
                    }
                } catch {
                    self.lastError =
                        "The operation was interrupted; inspect the current computer state before retrying."
                }
                authority.complete(ticket)
                self.worker = nil
                self.drain()
            }
        }
        private func respond(_ id: String, result: [String: JSONValue]? = nil, error: Error? = nil) {
            var payload: [String: JSONValue] = ["request_id": .string(id), "ok": .bool(error == nil)]
            if let error {
                let typed = error as? ComputerHostError
                payload["error"] = .object([
                    "code": .string(typed?.code ?? "failed"),
                    "message": .string(String((typed?.message ?? "The computer operation failed.").prefix(500))),
                ])
            } else {
                payload["result"] = .object(result ?? [:])
            }
            send(ComputerHostOutbound.frame(action: "computer_response", payload: payload))
        }
        private func sendEvent(_ event: String, additional: [String: JSONValue] = [:]) {
            var payload = additional
            payload["host_id"] = .string(hostId)
            payload["event"] = .string(event)
            send(ComputerHostOutbound.frame(action: "computer_event", payload: payload))
        }
        private func send(_ text: String) {
            guard let sender, text != "{}" else { return }
            let previous = outboundTail
            let epoch = channelEpoch
            outboundTail = Task { [weak self] in
                _ = await previous?.value
                guard let self, !Task.isCancelled, self.channelEpoch == epoch else { return false }
                let sent = await sender(text)
                if !sent && self.channelEpoch == epoch { self.disconnect() }
                return sent
            }
        }
        private func startHeartbeat() {
            guard heartbeat == nil else { return }
            if let session { sendEvent("heartbeat", additional: ["session_id": .string(session.id)]) }
            heartbeat = Task { [weak self] in
                var ticks = 0
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    guard let self, let current = self.session else { return }
                    self.refreshPermissions()
                    guard self.enabled else { return }
                    if let started = self.startedAt, ProcessInfo.processInfo.systemUptime - started >= 7200 {
                        self.stop()
                        return
                    }
                    ticks += 1
                    if ticks % 30 == 0 { self.sendEvent("heartbeat", additional: ["session_id": .string(current.id)]) }
                }
            }
        }
        private func showPanel() {
            guard session != nil else { return }
            if panel == nil {
                let value = NSPanel(
                    contentRect: NSRect(x: 80, y: 80, width: 380, height: 110),
                    styleMask: [.nonactivatingPanel, .titled], backing: .buffered, defer: false)
                value.title = "Astral computer session"
                value.level = .floating
                value.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                value.isReleasedWhenClosed = false
                value.hidesOnDeactivate = false
                value.contentView = NSHostingView(rootView: MacComputerSessionControls(host: self))
                panel = value
                monitor.controlsWindow = value.windowNumber
            }
            panel?.orderFrontRegardless()
        }
    }
#endif
