// Coordinates the direct-download Mac's explicit consent, current host session, physical queue and command executor.
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
        let posting: Bool
        init(accessibility: Bool, screen: Bool, monitoring: Bool, posting: Bool? = nil) {
            self.accessibility = accessibility
            self.screen = screen
            self.monitoring = monitoring
            self.posting = posting ?? accessibility
        }
        @MainActor static func current() -> MacComputerPermissions {
            MacComputerPermissions(
                accessibility: AXIsProcessTrusted(), screen: CGPreflightScreenCaptureAccess(),
                monitoring: CGPreflightListenEventAccess(), posting: CGPreflightPostEventAccess())
        }
    }

    enum MacComputerPermission: Equatable {
        case accessibility, screen, monitoring
        var title: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .screen: return "Screen Recording"
            case .monitoring: return "Input Monitoring"
            }
        }
        var pane: String {
            switch self {
            case .accessibility: return "Device Control and Data Access"
            case .screen: return "Screen & System Audio Recording"
            case .monitoring: return "Input Monitoring"
            }
        }
        var noPromptGuidance: String {
            "macOS no longer prompts for this app; open \(pane) and add AstralDeep with +"
        }
        var settingsURL: URL {
            let anchor: String
            switch self {
            case .accessibility: anchor = "Privacy_Accessibility"
            case .screen: anchor = "Privacy_ScreenCapture"
            case .monitoring: anchor = "Privacy_ListenEvent"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor)!
        }
        @MainActor func request() -> Bool {
            switch self {
            case .accessibility:
                let trusted = AXIsProcessTrustedWithOptions(
                    [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                let posting = CGRequestPostEventAccess()
                return trusted && posting
            case .screen: return CGRequestScreenCaptureAccess()
            case .monitoring: return CGRequestListenEventAccess()
            }
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
        private(set) var consentEnabled = false
        private(set) var desktopAvailable = false
        private(set) var session: ComputerHostSession?
        var controlsPresented = false
        private(set) var accessibilityAllowed = false
        private(set) var accessibilityTrusted = false
        private(set) var eventPostingAllowed = false
        private(set) var screenAllowed = false
        private(set) var monitoringAllowed = false
        private(set) var lastError: String?
        private(set) var awaitingApproval = false
        private(set) var working = false
        let files: MacComputerFiles
        @ObservationIgnored private let defaults: UserDefaults
        @ObservationIgnored private let authority = ComputerHostAuthority()
        @ObservationIgnored private let driver: any MacComputerDriving
        @ObservationIgnored private let monitor: any MacComputerMonitoring
        @ObservationIgnored private let permissionProvider: @MainActor () -> MacComputerPermissions
        @ObservationIgnored private let permissionRequester: @MainActor (MacComputerPermission) -> Bool
        @ObservationIgnored private let settingsOpener: @MainActor (URL) -> Bool
        @ObservationIgnored private let desktopProbe: @Sendable () -> Bool
        @ObservationIgnored private let desktopRearm: @MainActor () -> Bool
        @ObservationIgnored private let localResume: @MainActor () -> Bool
        @ObservationIgnored private let system: any MacComputerSystemIO
        @ObservationIgnored private let panelPresenter: @MainActor (NSPanel) -> Void
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
        @ObservationIgnored private var localResumeSession: String?
        @ObservationIgnored private let commands: MacComputerCommands
        @ObservationIgnored private let appActivator: @MainActor () -> Void
        @ObservationIgnored weak var browser: (any MacBrowserVerbHandling)?
        @ObservationIgnored private var auxiliary: [UUID: Task<Void, Never>] = [:]
        @ObservationIgnored private var browserTail: Task<Void, Never>?

        init(
            available: Bool? = nil, defaults: UserDefaults = .standard, files: MacComputerFiles? = nil,
            driver: (any MacComputerDriving)? = nil,
            monitor: (any MacComputerMonitoring)? = nil,
            permissionProvider: (@MainActor () -> MacComputerPermissions)? = nil,
            permissionRequester: (@MainActor (MacComputerPermission) -> Bool)? = nil,
            settingsOpener: (@MainActor (URL) -> Bool)? = nil,
            desktopProbe: @escaping @Sendable () -> Bool = MacComputerDesktopProbe.usable,
            desktopRearm: (@MainActor () -> Bool)? = nil,
            system: any MacComputerSystemIO = MacComputerLiveSystem.shared,
            panelPresenter: (@MainActor (NSPanel) -> Void)? = nil,
            commands: MacComputerCommands? = nil,
            appActivator: (@MainActor () -> Void)? = nil
        ) {
            self.available = available ?? Self.executionDistribution()
            self.defaults = defaults
            self.files = files ?? MacComputerFiles(defaults: defaults)
            self.system = system
            self.panelPresenter = panelPresenter ?? { $0.orderFrontRegardless() }
            self.commands = commands ?? MacComputerCommands()
            self.appActivator = appActivator ?? { NSApp.activate() }
            let marker = Int64.random(in: 1...Int64.max)
            self.monitor = monitor ?? MacComputerInputMonitor(marker: marker)
            self.permissionProvider = permissionProvider ?? MacComputerPermissions.current
            self.permissionRequester = permissionRequester ?? { $0.request() }
            self.settingsOpener = settingsOpener ?? { NSWorkspace.shared.open($0) }
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
            self.driver = driver ?? MacComputerDriver(marker: marker, system: system)
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
                observers.append(
                    NotificationCenter.default.addObserver(
                        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
                    ) { [weak self] _ in
                        Task { @MainActor in self?.refreshPermissions() }
                    })
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
            if consentEnabled && !enabled { return "Computer access is saved but paused" }
            if enabled && sender == nil { return "Computer access is paused while disconnected" }
            if enabled && desktopAvailable { return "Local computer access is enabled on this Mac" }
            return "Computer access is off"
        }
        var ownerBound: Bool { owner != nil }
        var taskActive: Bool { session != nil }
        private static let commandVerbs: Set<String> = ["run_command", "read_output", "interrupt_command"]
        private static let computerName: String = {
            let name = String(
                (Host.current().localizedName ?? "This Mac").unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }
                    .prefix(64).map(String.init).joined())
            return name.isEmpty ? "This Mac" : name
        }()
        var awaitingPause: Bool { awaitingPauseAcknowledgment }
        var canResume: Bool {
            session?.state == "paused" && !awaitingPauseAcknowledgment && desktopAvailable && permissionsReady
                && sender != nil
        }
        private var permissionsReady: Bool { accessibilityAllowed && screenAllowed && monitoringAllowed }
        var permissionDiagnostic: String {
            "macOS checks: Accessibility trust = \(accessibilityTrusted); event posting = \(eventPostingAllowed); event listening = \(monitoringAllowed)."
        }
        var descriptor: ComputerHostDescriptor? {
            guard available, enabled, desktopAvailable, authority.desktopIsAvailable, owner != nil, permissionsReady,
                monitor.running
            else { return nil }
            let (countResult, count) = system.displayCount()
            guard countResult == .success, (1...8).contains(count) else { return nil }
            let (enumerationResult, displays) = system.displayIDs(capacity: count)
            guard enumerationResult == .success, displays.count == Int(count), Set(displays).count == Int(count),
                !displays.contains(0)
            else { return nil }
            var ids = displays
            let primary = system.mainDisplay()
            ids.sort { a, b in a == primary || (b != primary && a < b) }
            var screens: [ComputerHostScreen] = []
            for (index, id) in ids.enumerated() {
                let pixels = system.displayPixels(id)
                let bounds = system.displayBounds(id)
                guard pixels.width.isFinite, pixels.height.isFinite,
                    pixels.width >= 1, pixels.width <= 16384, pixels.height >= 1, pixels.height <= 16384,
                    pixels.width.rounded(.towardZero) == pixels.width,
                    pixels.height.rounded(.towardZero) == pixels.height,
                    bounds.origin.x.isFinite, bounds.origin.y.isFinite,
                    bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0
                else { return nil }
                screens.append(
                    ComputerHostScreen(
                        index: index, width: Int(pixels.width), height: Int(pixels.height),
                        scale: Double(pixels.width) / max(1, bounds.width), primary: id == primary))
            }
            var verbs = ComputerHostRequest.verbs
            if files.roots.isEmpty {
                verbs.subtract(Self.commandVerbs.union(["read_file", "list_dir", "write_file", "delete_path"]))
            }
            if browser?.isEnabled != true { verbs = verbs.filter { !Self.browserVerb($0) } }
            let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            let version = raw + String(repeating: ".0", count: max(0, 3 - raw.split(separator: ".").count))
            let roots = files.roots.compactMap { root -> ComputerHostWorkspaceRoot? in
                let folder = String(
                    URL(fileURLWithPath: root).lastPathComponent.unicodeScalars.filter {
                        $0.value >= 32 && $0.value != 127
                    }.prefix(255).map(String.init).joined())
                let value = ComputerHostWorkspaceRoot(name: folder.isEmpty ? "Workspace" : folder, path: root)
                return value.isValid ? value : nil
            }
            return try? ComputerHostDescriptor(
                hostId: hostId, name: Self.computerName, clientVersion: version, screens: screens,
                verbs: verbs.sorted(),
                workspaceRoots: Array(roots.prefix(ComputerHostDescriptor.maximumWorkspaceRoots)))
        }
        func bind(owner: String?, sender: @escaping @MainActor (String) async -> Bool) {
            let epoch = UUID()
            disconnect(epoch: epoch)
            guard channelEpoch == epoch else { return }
            if self.owner != owner {
                files.bind(owner)
                commands.forget()
            }
            guard channelEpoch == epoch else { return }
            self.owner = owner
            self.sender = sender
            enabled = false
            desktopAvailable = false
            authority.setDesktopAvailable(false, requiresLocalRearm: false)
            consentEnabled = available && consentKey.map { defaults.bool(forKey: $0) } == true
            refreshPermissions()
            guard channelEpoch == epoch, consentEnabled, permissionsReady else { return }
            let desktopUsable = desktopProbe()
            guard channelEpoch == epoch, desktopUsable, authority.restoreDesktopAvailability() else { return }
            desktopAvailable = true
            let monitoring = monitor.start { [weak self] in self?.pause(reason: "local_input") }
            guard channelEpoch == epoch else { return }
            guard monitoring else {
                suspendAccess()
                lastError = "Human input monitoring could not start. Resume computer access locally to try again."
                return
            }
            enabled = true
            lastError = nil
        }
        func disconnect() {
            disconnect(epoch: UUID())
        }
        private func disconnect(epoch: UUID) {
            localInput?.invalidate()
            channelEpoch = epoch
            outboundTail?.cancel()
            outboundTail = nil
            retire(commands: "uncertain")
            guard channelEpoch == epoch else { return }
            sender = nil
            monitor.stop()
        }
        func signedOut() {
            let epoch = UUID()
            disconnect(epoch: epoch)
            guard channelEpoch == epoch else { return }
            desktopAvailable = false
            authority.setDesktopAvailable(false, requiresLocalRearm: false)
            owner = nil
            enabled = false
            consentEnabled = false
            files.bind(nil)
            commands.forget()
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
            accessibilityTrusted = permissions.accessibility
            eventPostingAllowed = permissions.posting
            accessibilityAllowed = permissions.accessibility && permissions.posting
            screenAllowed = permissions.screen
            monitoringAllowed = permissions.monitoring
            if enabled, session?.state != "paused", !authority.desktopIsAvailable || !desktopProbe() {
                sessionLocked()
                return
            }
            if enabled && !permissionsReady {
                suspendAccess()
                lastError = "Computer permission is missing or was revoked. Grant access and resume this Mac locally."
            }
        }
        func requestAccessibility() {
            request(.accessibility)
        }
        func requestScreen() { request(.screen) }
        func requestMonitoring() { request(.monitoring) }
        private func permissionReady(_ permission: MacComputerPermission) -> Bool {
            switch permission {
            case .accessibility: return accessibilityAllowed
            case .screen: return screenAllowed
            case .monitoring: return monitoringAllowed
            }
        }
        private func request(_ permission: MacComputerPermission) {
            guard available else { return }
            refreshPermissions()
            if permissionReady(permission) {
                if settingsOpener(permission.settingsURL) {
                    lastError = nil
                } else {
                    let pane =
                        permission == .accessibility
                        ? "Accessibility or Device Control and Data Access" : permission.title
                    lastError =
                        "Open System Settings > Privacy & Security > \(pane) to review AstralDeep's access. AstralDeep could not open that pane."
                }
                return
            }
            let asked = "computer.permission.requested." + permission.title
            if defaults.bool(forKey: asked) {
                lastError =
                    permission.noPromptGuidance
                    + (settingsOpener(permission.settingsURL) ? "" : ". AstralDeep could not open that pane.")
                return
            }
            defaults.set(true, forKey: asked)
            let granted = permissionRequester(permission)
            refreshPermissions()
            let ready = permissionReady(permission)
            if granted && ready {
                lastError = nil
                return
            }
            let result = "\(permission.title) request returned \(granted ? "granted" : "not granted")."
            if ready {
                lastError = result + " The current macOS check is now granted. Enable computer access yourself."
                return
            }
            let opened = settingsOpener(permission.settingsURL)
            let instruction = opened ? "System Settings is open." : "Open System Settings > Privacy & Security."
            let pane =
                permission == .accessibility ? "Accessibility or Device Control and Data Access" : permission.title
            lastError =
                result + " The permission check immediately after this request reported no access. " + instruction
                + " Enable AstralDeep under \(pane). If macOS asks, quit and reopen AstralDeep. Return here and choose Refresh permissions."
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
                    suspendAccess()
                    lastError = "Human input monitoring could not start. Computer access remains off."
                    return
                }
                enabled = true
                consentEnabled = true
                lastError = nil
                if let key = consentKey { defaults.set(true, forKey: key) }
                if let descriptor { sendEvent("announce", additional: ["host": descriptor.json]) }
            } else {
                consentEnabled = false
                if let key = consentKey { defaults.set(false, forKey: key) }
                suspendAccess()
            }
        }
        private func suspendAccess() {
            let epoch = channelEpoch
            localInput?.invalidate()
            enabled = false
            desktopAvailable = false
            authority.setDesktopAvailable(false)
            retire()
            guard channelEpoch == epoch else { return }
            monitor.stop()
            guard channelEpoch == epoch else { return }
            sendEvent("withdraw")
        }
        func workspacesChanged() {
            stop()
            if enabled, let descriptor { sendEvent("announce", additional: ["host": descriptor.json]) }
        }
        func sessionLocked() {
            suspendAccess()
            lastError = "Computer control stopped because this desktop became unavailable."
        }
        func applicationWillTerminate() {
            commands.terminateNow()
            localInput?.stop()
            stop()
            monitor.stop()
            authority.invalidate()
        }
        func pause() { pause(reason: "local_pause") }
        func takeover() { pause(reason: "local_input") }
        func approvalWaiting(_ waiting: Bool) {
            awaitingApproval = waiting && session != nil
            if awaitingApproval { showPanel() }
        }
        func bringAstralForward() { appActivator() }
        private func pause(reason: String, retainingPermits: Bool = false) {
            if !retainingPermits { browser?.discardPermits() }
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
            localResumeSession = current.id
            sendEvent("resumed", additional: ["session_id": .string(current.id)])
        }
        func recordApprovalInteraction() -> String? {
            let id = session?.id
            if session?.state == "active" { pause(reason: "local_input", retainingPermits: true) }
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
                    let system = system
                    let timeout = Task { [weak self] in
                        do { try await system.delay(nanoseconds: 5_000_000_000) } catch { return }
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
        private func cancelWork(resetDriver: Bool = true, commands state: String = "interrupted") {
            workerId = UUID()
            worker?.cancel()
            worker = nil
            queue = []
            commands.endAll(as: state)
            for task in auxiliary.values { task.cancel() }
            auxiliary = [:]
            browserTail = nil
            refreshWorking()
            if resetDriver { Task { await driver.reset() } }
        }
        private func refreshWorking() {
            let busy = worker != nil || !queue.isEmpty || !auxiliary.isEmpty
            if working != busy { working = busy }
        }
        private func retire(commands state: String = "interrupted") {
            resolvePauseWaiters(accepted: false)
            authority.invalidate()
            cancelWork(commands: state)
            session = nil
            startedAt = nil
            heartbeat?.cancel()
            heartbeat = nil
            awaitingPauseAcknowledgment = false
            localPauseReason = nil
            localResumeSession = nil
            awaitingApproval = false
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
                        if incoming.id == session?.id, session?.state == "paused", localPauseReason == "local_pause",
                            localResumeSession != incoming.id
                        {
                            sendEvent(
                                "paused",
                                additional: ["session_id": .string(incoming.id), "reason": .string("local_pause")])
                            return true
                        }
                        try authority.begin(incoming.id)
                        if incoming.id == session?.id && session?.state == "paused" { authority.resume() }
                        localResumeSession = nil
                        localPauseReason = nil
                    } else {
                        let locallyPaused =
                            incoming.id == session?.id && session?.state == "paused"
                            && localPauseReason == "local_pause"
                        if incoming.id != session?.id { try authority.begin(incoming.id) }
                        authority.pause()
                        cancelWork(resetDriver: false)
                        awaitingPauseAcknowledgment = false
                        if !locallyPaused, let reason = frame.payload["pause_reason"]?.stringValue {
                            localPauseReason = reason
                        }
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
                guard available, enabled, permissionsReady, monitor.running, sender != nil else {
                    throw ComputerHostError(
                        "permission_denied", "This Mac has not granted the requested computer capability.")
                }
                if Self.browserVerb(request.verb), browser?.isEnabled != true {
                    throw ComputerHostError("unsupported", "The browser pane is turned off on this Mac.")
                }
                guard descriptor?.verbs.contains(request.verb) == true else {
                    throw ComputerHostError(
                        "permission_denied", "This Mac has not granted the requested computer capability.")
                }
                let ticket = try authority.admit(request)
                queue.append((request, ticket))
                drain()
            } catch { respond(request.id, error: error) }
            return true
        }
        private static func browserVerb(_ verb: String) -> Bool { verb.hasPrefix("browser_") }
        private static func nonPhysical(_ verb: String) -> Bool { browserVerb(verb) || commandVerbs.contains(verb) }
        private func drain() {
            defer { refreshWorking() }
            while let index = queue.firstIndex(where: { Self.nonPhysical($0.0.verb) }) {
                let (request, ticket) = queue.remove(at: index)
                runAuxiliary(request, ticket)
            }
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
        private func runAuxiliary(_ request: ComputerHostRequest, _ ticket: ComputerHostTicket) {
            let authority = authority
            let desktopProbe = desktopProbe
            let roots = files.roots
            let authorize: @Sendable () throws -> Void = {
                try authority.verify(ticket)
                guard desktopProbe() else {
                    authority.setDesktopAvailable(false)
                    throw ComputerHostError(
                        "screen_locked", "This desktop is unavailable. Enable it locally after unlocking.")
                }
                try authority.verify(ticket)
            }
            let id = UUID()
            let serial = Self.browserVerb(request.verb)
            let previous = serial ? browserTail : nil
            let task = Task { [weak self] in
                _ = await previous?.value
                let result: Result<[String: JSONValue], Error>
                do {
                    try authorize()
                    guard let host = self else { return }
                    result = .success(
                        try await host.performAuxiliary(request, ticket: ticket, roots: roots, authorize: authorize))
                } catch { result = .failure(error) }
                guard let self, self.auxiliary.removeValue(forKey: id) != nil else { return }
                self.refreshWorking()
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
            }
            auxiliary[id] = task
            if serial { browserTail = task }
        }
        private func performAuxiliary(
            _ request: ComputerHostRequest, ticket: ComputerHostTicket, roots: [String],
            authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue] {
            switch request.verb {
            case "run_command":
                return try await commands.run(request, session: ticket.sessionId, roots: roots, authorize: authorize)
            case "read_output": return try await commands.read(request, authorize: authorize)
            case "interrupt_command": return try await commands.interrupt(request, authorize: authorize)
            default: break
            }
            guard let browser, browser.isEnabled else {
                throw ComputerHostError("unsupported", "The browser pane is turned off on this Mac.")
            }
            return try await browser.handle(request, ticket: ticket, authorize: authorize)
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
                value.title = MacComputerPanelIdentity.title
                value.level = .floating
                value.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                value.isReleasedWhenClosed = false
                value.hidesOnDeactivate = false
                let content = NSHostingController(rootView: MacComputerSessionPanel(host: self))
                content.sizingOptions = [.preferredContentSize]
                value.contentViewController = content
                panel = value
            }
            if let panel { panelPresenter(panel) }
        }
    }

    struct MacComputerSessionPanel: View {
        @Bindable var host: MacComputerHost
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                if host.awaitingApproval {
                    HStack(spacing: 8) {
                        Label("Approval waiting", systemImage: "hand.raised").font(.headline)
                            .accessibilityIdentifier("mac-computer-approval-waiting")
                        Spacer()
                        Button("Open Astral", action: host.bringAstralForward)
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("mac-computer-open-astral")
                    }.padding([.horizontal, .top], 12)
                }
                MacComputerSessionControls(host: host)
            }.frame(width: 380, alignment: .leading)
        }
    }
#endif
