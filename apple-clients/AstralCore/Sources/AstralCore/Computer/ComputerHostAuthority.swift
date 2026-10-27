// Synchronizes computer admission tickets across the UI owner and the asynchronous physical driver.
// Revocation is immediate even while the operating-system API worker is suspended or blocked.

import Foundation

public final class ComputerHostAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var fence = ComputerHostFence()
    private var desktopAvailable = false
    private var desktopRearmRequired = false
    private var projectMode = false
    private var projectManifest: ComputerProjectManifest?
    private var projectRetirements: [String: UInt64] = [:]
    private let now: @Sendable () -> Double
    public init(now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }
    public func begin(_ session: String, projectContext: ComputerProjectContext? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        guard desktopAvailable else {
            throw ComputerHostError("screen_locked", "Enable this Mac again from its active local desktop.")
        }
        try verifyProjectContext(projectContext)
        try fence.begin(sessionId: session, projectContext: projectContext)
    }
    public func configureProjects(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard projectMode != enabled else { return }
        fence.invalidate()
        projectMode = enabled
        projectManifest = nil
        projectRetirements = [:]
    }
    public func acceptProjectManifest(_ manifest: ComputerProjectManifest) throws {
        lock.lock()
        defer { lock.unlock() }
        guard projectMode else {
            throw ComputerHostError("invalid_project_manifest", "Project grants are not negotiated.")
        }
        if let previous = projectManifest {
            guard manifest.generation >= previous.generation,
                manifest.generation != previous.generation || manifest.digest == previous.digest
            else {
                throw ComputerHostError("stale_project_manifest", "This project acknowledgment was superseded.")
            }
        }
        for entry in manifest.projects {
            let previous = projectManifest?.projects.first(where: { $0.projectId == entry.projectId })
            guard entry.grantRevision > (projectRetirements[entry.projectId] ?? 0),
                previous.map({ entry.grantRevision > $0.grantRevision || entry == $0 }) ?? true
            else {
                throw ComputerHostError("stale_project_grant", "The project grant revision was retired or changed.")
            }
        }
        for previous in projectManifest?.projects ?? [] {
            if !manifest.projects.contains(previous) {
                projectRetirements[previous.projectId] = max(
                    projectRetirements[previous.projectId] ?? 0, previous.grantRevision)
                if fence.projectContext?.projectId == previous.projectId { fence.invalidate() }
            }
        }
        projectManifest = manifest
    }
    public func revokeProject(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        if let grant = projectManifest?.projects.first(where: { $0.projectId == id }) {
            projectRetirements[id] = max(projectRetirements[id] ?? 0, grant.grantRevision)
        }
        if fence.projectContext?.projectId == id { fence.invalidate() }
    }
    private func verifyProjectContext(_ context: ComputerProjectContext?) throws {
        if !projectMode {
            guard context == nil else {
                throw ComputerHostError("invalid_project_context", "Project authority is not negotiated.")
            }
            return
        }
        guard let context, let manifest = projectManifest, context.manifestGeneration <= manifest.generation else {
            throw ComputerHostError("project_grant_required", "The origin project has not been admitted on this Mac.")
        }
        let entry = manifest.projects.first(where: { $0.projectId == context.projectId })
        guard context.grantRevision == entry?.grantRevision,
            context.grantRevision.map({ $0 > (projectRetirements[context.projectId] ?? 0) }) ?? true
        else {
            throw ComputerHostError("stale_project_grant", "The origin project's folder grant changed.")
        }
    }
    public func setDesktopAvailable(_ value: Bool, requiresLocalRearm: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        desktopAvailable = value
        if value {
            desktopRearmRequired = false
        } else {
            desktopRearmRequired = desktopRearmRequired || requiresLocalRearm
            fence.invalidate()
        }
    }
    public func restoreDesktopAvailability() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !desktopRearmRequired else { return false }
        desktopAvailable = true
        return true
    }
    public var desktopIsAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return desktopAvailable
    }
    public func pause() {
        lock.lock()
        defer { lock.unlock() }
        fence.pause()
    }
    public func resume() {
        lock.lock()
        defer { lock.unlock() }
        fence.resume()
    }
    public func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        fence.invalidate()
    }
    public func admit(_ request: ComputerHostRequest) throws -> ComputerHostTicket {
        lock.lock()
        defer { lock.unlock() }
        guard desktopAvailable else { throw ComputerHostError("screen_locked", "This desktop is unavailable.") }
        try verifyProjectContext(request.projectContext)
        if projectMode,
            ["read_file", "list_dir", "write_file", "delete_path", "run_command", "read_output", "interrupt_command"]
                .contains(request.verb)
        {
            guard let context = request.projectContext, context.grantRevision != nil,
                projectManifest?.projects.first(where: { $0.projectId == context.projectId })?.roots.isEmpty == false
            else {
                throw ComputerHostError(
                    "project_grant_required", "Choose folders for this project on this Mac.", effectState: "not_started"
                )
            }
        }
        return try fence.admit(request, now: now())
    }
    public func verify(_ ticket: ComputerHostTicket) throws {
        lock.lock()
        defer { lock.unlock() }
        try verifyProjectContext(ticket.projectContext)
        guard desktopAvailable, fence.permits(ticket, now: now()) else {
            throw ComputerHostError(
                "interrupted", "The request expired or computer authority changed. Inspect the result before retrying.")
        }
    }
    public func complete(_ ticket: ComputerHostTicket) {
        lock.lock()
        defer { lock.unlock() }
        fence.complete(ticket)
    }
}
