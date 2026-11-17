// An in-memory MeshKernel with scripted behavior for unit tests, previews and the UI fixture launch.
// It follows the same state rules the host expects from the real kernel, and reports changes through the listener it was opened with.

import AstralCore
import Foundation

nonisolated final class InMemoryMeshKernel: MeshKernel, @unchecked Sendable {
    struct Call: Equatable, Sendable {
        let name: String
        let detail: String
    }

    private let lock = NSLock()
    private let listener: any MeshKernelListening
    private let clock: @Sendable () -> Date
    private var status: MeshStatus
    private var principalValue: MeshVerifiedPrincipal?
    private var wakeRouteValue: MeshWakeRoute?
    private var members: [MeshMember] = []
    private var issuedCallers: [MeshCallerTicket] = []
    private var revokedCallerIds: Set<String> = []
    private var stopRaises: UInt64 = 0
    private var callerStopLevels: [String: UInt64] = [:]
    private var nodeCatalogs: [String: Set<String>] = [:]
    private var chats: [String: StoredChat] = [:]
    private var order: [String] = []
    private var consents: [MeshPendingConsent] = []
    private var providers: [MeshModelProvider] = []
    private var remoteMCPServersValue: [String: MeshRemoteMCPServer] = [:]
    private var remoteMCPToolsValue: [String: [MeshRemoteMCPTool]] = [:]
    private var syncValue = MeshSyncState.empty
    private var allowanceValue: MeshAllowance
    private var counter = 0
    private var log: [Call] = []
    private var resumeTargets: Set<MeshResumeTarget> = []
    private var pendingMessages: Set<MeshPendingMessage> = []
    private var offer: MeshPairingOffer?
    private var runsValue: [MeshRun] = []
    private var proposalsValue: [MeshProposal] = []
    private var requestsValue: [MeshRequest] = []
    private var grantsValue: Set<String> = []
    private var handlesValue: [String: MeshResolvedHandle] = [:]
    private var renderedValue: [String: [MeshRenderedSurface]] = [:]
    private var attachmentsValue: [String: (MeshAttachment, Data)] = [:]
    private var mailboxValue = MeshMailboxState.off
    private var toolsValue: [MeshToolEntry] = [
        MeshToolEntry(
            name: "current_datetime", summary: "Returns the current date and time.", effect: .meshRead, deviceId: nil)
    ]

    var autoJoin: MeshJoinRequest?
    var actResult = MeshActResult(status: "ok", code: nil, text: "Done")
    var recoveryWords: [String] = (1...24).map { "word\($0)" }
    var hasLocalMesh = false
    var turnScript: [MeshTurnEvent] = [
        .started, .assistantDelta("Hello"), .assistantDelta(" there"), .assistantFinished, .finished,
    ]
    var turnReply = "Hello there"
    var consentGate: @Sendable () throws -> Void = {}
    var attachmentFetchGate: @Sendable () async -> Void = {}
    var actionSigner: (@Sendable (MeshPendingConsent) throws -> Void)?
    var failure: MeshKernelError?
    var turnError: MeshKernelError?
    var sendGate: @Sendable () -> Void = {}
    var statusGate: @Sendable () async -> Void = {}
    var pendingGate: @Sendable () async -> Void = {}
    var principalGate: @Sendable () throws -> Void = {}
    var wakeRouteGate: @Sendable () async throws -> Void = {}
    var turnGate: @Sendable () async -> Void = {}
    var interruptGate: @Sendable () throws -> Void = {}
    var interruptAcknowledged = true
    var providerSaveGate: @Sendable () -> Void = {}
    var steerAcknowledged = true
    var steerGate: @Sendable () throws -> Void = {}
    var previewResult = MeshPairingPreview(
        comparisonCode: "4821 9307", deviceLabel: "New phone", deviceKind: .pocket, fingerprint: "sha256:0a1b2c3d4e5f")

    private struct StoredChat {
        var title: String
        var messages: [MeshChatMessage]
        var surfaces: [MeshSurface]
        var status: MeshChatStatus
        var updatedAt: Date
    }

    init(
        listener: any MeshKernelListening, hasMesh: Bool = false, recoveryPending: Bool = false,
        hardwareBacked: Bool = true,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.listener = listener
        self.clock = clock
        status = MeshStatus(
            hasMesh: hasMesh && !recoveryPending, meshId: hasMesh ? "sha256:" + String(repeating: "a", count: 64) : nil,
            deviceId: hasMesh ? "sha256:" + String(repeating: "b", count: 64) : nil, recoveryPending: recoveryPending,
            stopped: false, hardwareBacked: hardwareBacked)
        allowanceValue = MeshAllowance(
            share: .solo, periodEndsAt: nil, lines: [], modelTokensRemaining: nil, modelTokensLimit: nil, blocked: nil)
        if hasMesh { members = [Self.thisDevice(status: status)] }
    }

    var calls: [Call] { lock.withLock { log } }

    func startNetwork() async throws { try record("startNetwork") }
    func syncNow() async throws { try record("syncNow") }
    func stopNetwork() async { lock.withLock { log.append(Call(name: "stopNetwork", detail: "")) } }
    func version() -> String { "in-memory" }

    func meshStatus() async throws -> MeshStatus {
        try record("meshStatus")
        let value = lock.withLock { status }
        await statusGate()
        return value
    }

    func meshPrincipal() throws -> MeshVerifiedPrincipal {
        try record("meshPrincipal")
        try principalGate()
        return try lock.withLock {
            guard status.hasMesh, let principalValue else {
                throw MeshKernelError.unavailable("The mesh principal is not available.")
            }
            return principalValue
        }
    }

    func setMeshPrincipal(_ value: MeshVerifiedPrincipal?) { lock.withLock { principalValue = value } }

    func setWakeRoute(expectedMeshId: String, expectedDeviceId: String, route: MeshWakeRoute?) async throws {
        try record("setWakeRoute", expectedMeshId + "/" + expectedDeviceId)
        try await wakeRouteGate()
        try lock.withLock {
            guard status.hasMesh, status.meshId == expectedMeshId, status.deviceId == expectedDeviceId else {
                throw MeshKernelError.refused("wake.target_mismatch")
            }
            if route != nil, status.stopped { throw MeshKernelError.stopped }
            if let route, !route.isValid(at: Int64(clock().timeIntervalSince1970 * 1000)) {
                throw MeshKernelError.refused("wake.malformed")
            }
            wakeRouteValue = route
        }
    }

    func wakeRoutes() async throws -> [MeshDeviceWakeRoute] {
        try record("wakeRoutes")
        return try lock.withLock {
            guard status.hasMesh, let mesh = status.meshId, let device = status.deviceId else {
                throw MeshKernelError.refused("mesh.not_enrolled")
            }
            guard !status.stopped else { throw MeshKernelError.stopped }
            guard let route = wakeRouteValue, route.isValid(at: Int64(clock().timeIntervalSince1970 * 1000)) else {
                return []
            }
            return [MeshDeviceWakeRoute(meshId: mesh, deviceId: device, route: route)]
        }
    }

    func createMesh() throws -> MeshRecoveryKit {
        try record("createMesh")
        try consentGate()
        try lock.withLock {
            guard !status.hasMesh || status.recoveryPending else {
                throw MeshKernelError.refused("This device already belongs to a mesh.")
            }
            status = MeshStatus(
                hasMesh: false, meshId: "sha256:" + String(repeating: "a", count: 64),
                deviceId: "sha256:" + String(repeating: "b", count: 64), recoveryPending: true, stopped: false,
                hardwareBacked: status.hardwareBacked)
            principalValue = MeshVerifiedPrincipal(meshId: status.meshId!)
            members = [Self.thisDevice(status: status)]
        }
        listener.onChange(.rosterChanged)
        return MeshRecoveryKit(words: recoveryWords)
    }

    func confirmMeshRecovery() throws {
        try record("confirmMeshRecovery")
        try consentGate()
        try lock.withLock {
            guard status.meshId != nil else { throw MeshKernelError.refused("This device has no mesh yet.") }
            status.hasMesh = true
            status.recoveryPending = false
        }
        listener.onChange(.rosterChanged)
    }

    func recoverWithWords(words: String, backupPath: String?) throws -> MeshRecovery {
        try record("recoverWithWords", "\(words.split(separator: " ").count)|" + (backupPath ?? ""))
        guard !lock.withLock({ status.hasMesh }) else {
            throw MeshKernelError.refused(KernelMapping.failureText(code: "mesh.already_enrolled"))
        }
        guard words.split(separator: " ").count == 24 else {
            throw MeshKernelError.refused(KernelMapping.failureText(code: "recovery.bad_length"))
        }
        guard words == recoveryWords.joined(separator: " ") else {
            throw MeshKernelError.refused(KernelMapping.failureText(code: "recovery.bad_checksum"))
        }
        guard backupPath != nil || hasLocalMesh else {
            throw MeshKernelError.refused(KernelMapping.failureText(code: "recovery.no_roster"))
        }
        let meshId = "sha256:" + String(repeating: "a", count: 64)
        let deviceId = "sha256:" + String(repeating: "e", count: 64)
        lock.withLock {
            status = MeshStatus(
                hasMesh: true, meshId: meshId, deviceId: deviceId, stopped: false,
                hardwareBacked: status.hardwareBacked)
            members = [
                Self.thisDevice(status: status),
                MeshMember(
                    memberId: "sha256:" + String(repeating: "c", count: 64), label: "Old phone", kind: .pocket,
                    isThisDevice: false, lastSeen: nil, path: .none),
            ]
        }
        listener.onChange(.rosterChanged)
        return MeshRecovery(meshId: meshId, deviceId: deviceId, eventsImported: backupPath == nil ? 0 : 12)
    }

    func createInvitation() async throws -> MeshInvitation {
        try record("createInvitation")
        if let request = lock.withLock({ autoJoin }) {
            Task {
                try? await Task.sleep(for: .seconds(6))
                listener.onChange(.joinRequested(request))
            }
        }
        return MeshInvitation(
            code: "K7QM-39XD", payload: "astral-invite:v1:invitation", expiresAt: clock().addingTimeInterval(600))
    }

    func acceptInvitation(payload: String) async throws -> MeshInvitationAccepted {
        try record("acceptInvitation", payload)
        guard payload.hasPrefix("astral-invite:") else { throw MeshKernelError.refused("pairing.malformed") }
        return MeshInvitationAccepted(
            comparisonCode: previewResult.comparisonCode, invitationCode: "K7QM-39XD",
            inviterDeviceId: "sha256:" + String(repeating: "b", count: 64), expiresAt: clock().addingTimeInterval(600))
    }

    func approveInvitation() async throws {
        try record("approveInvitation")
        try consentGate()
        lock.withLock {
            members.append(
                MeshMember(
                    memberId: "sha256:" + String(repeating: "c", count: 64), label: previewResult.deviceLabel,
                    kind: previewResult.deviceKind, isThisDevice: false, lastSeen: clock(),
                    path: .direct, addedAt: clock()))
        }
        listener.onChange(.rosterChanged)
    }

    func cancelInvitation() async { lock.withLock { log.append(Call(name: "cancelInvitation", detail: "")) } }

    func cancelPairingOffer() { lock.withLock { log.append(Call(name: "cancelPairingOffer", detail: "")) } }

    func renameDevice(memberId: String, label: String) throws {
        try record("renameDevice", memberId + "|" + label)
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MeshKernelError.refused("device.empty_label") }
        lock.withLock {
            members = members.map { member in
                guard member.memberId == memberId else { return member }
                return MeshMember(
                    memberId: member.memberId, label: trimmed, kind: member.kind, isThisDevice: member.isThisDevice,
                    lastSeen: member.lastSeen, path: member.path, addedAt: member.addedAt)
            }
        }
        listener.onChange(.rosterChanged)
    }

    func setRendered(chatId: String, _ value: [MeshRenderedSurface]) { lock.withLock { renderedValue[chatId] = value } }

    func simulateFailure(code: String) { listener.onChange(.pairingFailed(code: code)) }

    func simulateJoinRequest(_ request: MeshJoinRequest) { listener.onChange(.joinRequested(request)) }

    func createPairingOffer() async throws -> MeshPairingOffer {
        try record("createPairingOffer")
        let made = MeshPairingOffer(
            shortCode: "12345678", payload: "astral-pair:v1:offer", expiresAt: clock().addingTimeInterval(600))
        lock.withLock { offer = made }
        return made
    }

    func previewPairing(payload: String) throws -> MeshPairingPreview {
        try record("previewPairing", payload)
        guard payload.hasPrefix("astral-pair:") else { throw MeshKernelError.refused("pairing.malformed") }
        return previewResult
    }

    func approvePairing(payload: String) async throws {
        try record("approvePairing", payload)
        guard payload.hasPrefix("astral-pair:") else { throw MeshKernelError.refused("pairing.malformed") }
        try consentGate()
        lock.withLock {
            members.append(
                MeshMember(
                    memberId: "sha256:" + String(repeating: "c", count: 64), label: previewResult.deviceLabel,
                    kind: previewResult.deviceKind, isThisDevice: false, lastSeen: clock(),
                    path: .direct))
        }
        listener.onChange(.rosterChanged)
    }

    func completeJoin() {
        lock.withLock {
            status = MeshStatus(
                hasMesh: true, meshId: "sha256:" + String(repeating: "a", count: 64),
                deviceId: "sha256:" + String(repeating: "d", count: 64), stopped: false,
                hardwareBacked: status.hardwareBacked)
            members = [Self.thisDevice(status: status)]
        }
        listener.onChange(.rosterChanged)
    }

    func roster() async throws -> [MeshMember] {
        try record("roster")
        return lock.withLock { members }
    }

    func removeDevice(memberId: String) throws {
        try record("removeDevice", memberId)
        try consentGate()
        lock.withLock { members.removeAll { $0.memberId == memberId && !$0.isThisDevice } }
        listener.onChange(.rosterChanged)
    }

    var localMember: MeshMember {
        lock.withLock { members.first { $0.isThisDevice } ?? Self.thisDevice(status: status) }
    }

    func acceptCaller(_ ticket: MeshCallerTicket) { lock.withLock { issuedCallers.append(ticket) } }

    func setNodeCatalog(_ nodeId: String, tools: [String]) {
        lock.withLock { nodeCatalogs[nodeId] = Set(tools) }
    }

    func mintCallerTicket(
        nodeId: String, holderKey: String, label: String, toolNames: [String], a2a: Bool, lifetimeSeconds: UInt64
    ) throws -> MeshCallerTicket {
        try record("mintCallerTicket", nodeId + "|" + label)
        let ticket = try lock.withLock { () -> MeshCallerTicket in
            try requireEnrolledLocked()
            if status.stopped { throw MeshKernelError.stopped }
            guard let local = members.first(where: { $0.isThisDevice }), local.kind != .node else {
                throw Self.callerRefusal("caller.wrong_minter")
            }
            guard members.contains(where: { $0.memberId == nodeId && $0.kind == .node }) else {
                throw Self.callerRefusal("caller.wrong_node")
            }
            guard Self.usableHolder(holderKey), Self.usableLabel(label),
                (1...MeshCallerTicketLimits.maxLifetimeSeconds).contains(lifetimeSeconds)
            else { throw Self.callerRefusal("caller.malformed") }
            guard let catalog = nodeCatalogs[nodeId] else { throw Self.callerRefusal("caller.no_catalog") }
            let count = toolNames.count + (a2a ? 1 : 0)
            guard (1...MeshCallerTicketLimits.maxTools).contains(count),
                Set(toolNames).count == toolNames.count,
                !toolNames.contains(MeshCallerTicketLimits.a2aTool)
            else { throw Self.callerRefusal("caller.malformed") }
            guard toolNames.allSatisfy(catalog.contains) else { throw Self.callerRefusal("caller.unknown_tool") }
            let id = Self.newTicketId()
            let issued = clock()
            let granted = (toolNames + (a2a ? [MeshCallerTicketLimits.a2aTool] : [])).sorted()
            return MeshCallerTicket(
                id: id, text: "in-memory-caller-ticket:" + id, label: label, nodeId: nodeId, tools: granted,
                issuedAt: issued, expiresAt: issued.addingTimeInterval(TimeInterval(lifetimeSeconds)), revoked: false,
                expired: false)
        }
        try consentGate()
        lock.withLock {
            issuedCallers.append(ticket)
            callerStopLevels[ticket.id] = stopRaises
        }
        return ticket
    }

    func callerTickets() throws -> [MeshCallerTicket] {
        try record("callerTickets")
        return try lock.withLock {
            try requireEnrolledLocked()
            return issuedCallers.map(listedLocked)
        }
    }

    func revokeCallerTicket(id: String) throws {
        try record("revokeCallerTicket", id)
        try lock.withLock {
            try requireEnrolledLocked()
            guard Self.validTicketId(id) else { throw Self.callerRefusal("caller.malformed") }
            revokedCallerIds.insert(id)
        }
    }

    func verifyCallerRequest(_ request: MeshCallerRequest) throws -> MeshVerifiedCaller {
        try record("verifyCallerRequest", request.target)
        return try lock.withLock {
            try requireEnrolledLocked()
            guard let local = members.first(where: { $0.isThisDevice }), local.kind == .node else {
                throw Self.callerRefusal("caller.wrong_node")
            }
            guard let held = issuedCallers.first(where: { $0.text == request.authorization }) else {
                throw Self.callerRefusal("caller.malformed")
            }
            let ticket = listedLocked(held)
            guard ticket.nodeId == local.memberId else { throw Self.callerRefusal("caller.wrong_node") }
            if stopRaises > callerStopLevels[ticket.id, default: 0] { throw Self.callerRefusal("caller.stopped") }
            if ticket.revoked { throw Self.callerRefusal("caller.revoked") }
            if ticket.expired { throw Self.callerRefusal("caller.expired") }
            if let tool = request.tool, !ticket.tools.contains(tool) {
                throw Self.callerRefusal("caller.tool_not_covered")
            }
            return MeshVerifiedCaller(
                id: ticket.id, meshId: status.meshId ?? "", deviceId: local.memberId, label: ticket.label,
                tool: request.tool, tools: ticket.tools, expiresAt: ticket.expiresAt)
        }
    }

    private func requireEnrolledLocked() throws {
        guard status.hasMesh else { throw Self.callerRefusal("mesh.not_enrolled") }
    }

    private func listedLocked(_ ticket: MeshCallerTicket) -> MeshCallerTicket {
        MeshCallerTicket(
            id: ticket.id, text: ticket.text, label: ticket.label, nodeId: ticket.nodeId, tools: ticket.tools,
            issuedAt: ticket.issuedAt, expiresAt: ticket.expiresAt, revoked: revokedCallerIds.contains(ticket.id),
            expired: clock() >= ticket.expiresAt)
    }

    private static func callerRefusal(_ code: String) -> MeshKernelError {
        .refused(KernelMapping.failureText(code: code))
    }

    private static let refusedLabelCategories: Set<Unicode.GeneralCategory> = [
        .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned,
    ]

    private static func usableLabel(_ label: String) -> Bool {
        (1...MeshCallerTicketLimits.maxLabelLength).contains(label.unicodeScalars.count)
            && !label.unicodeScalars.contains { refusedLabelCategories.contains($0.properties.generalCategory) }
    }

    private static func usableHolder(_ text: String) -> Bool {
        guard text.hasPrefix(MeshCallerTicketLimits.holderPrefix) else { return false }
        return decodedBase64URL(String(text.dropFirst(MeshCallerTicketLimits.holderPrefix.count)))?.count == 32
    }

    private static func validTicketId(_ id: String) -> Bool {
        guard let raw = decodedBase64URL(id) else { return false }
        return raw.count == 16
    }

    private static func newTicketId() -> String {
        withUnsafeBytes(of: UUID().uuid) { Data($0) }.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func decodedBase64URL(_ text: String) -> Data? {
        guard !text.isEmpty, !text.contains("="), !text.contains("+"), !text.contains("/") else { return nil }
        var padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else { return nil }
        let canonical = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return canonical == text ? data : nil
    }

    func raiseStop() throws {
        try record("raiseStop")
        lock.withLock {
            status.stopped = true
            stopRaises += 1
        }
        listener.onChange(.rosterChanged)
        listener.onChange(.allowanceChanged)
    }

    func resumeStop() throws {
        try record("resumeStop")
        try consentGate()
        lock.withLock { status.stopped = false }
        listener.onChange(.rosterChanged)
        listener.onChange(.allowanceChanged)
    }

    func exportBackup(path: String) throws { try record("exportBackup", path) }

    func listChats() throws -> [MeshChatSummary] {
        try record("listChats")
        return lock.withLock {
            order.compactMap { id in chats[id].map { summary(id: id, chat: $0) } }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    func chat(chatId: String) throws -> MeshChatView {
        try record("chat", chatId)
        return try lock.withLock {
            guard let chat = chats[chatId] else { throw MeshKernelError.notFound }
            return MeshChatView(
                chatId: chatId, title: chat.title, messages: chat.messages, branches: branches(of: chat),
                surfaces: chat.surfaces, rendered: renderedValue[chatId] ?? [], labels: [], status: chat.status)
        }
    }

    func createChat(title: String) throws -> String {
        try record("createChat", title)
        let id = nextId("chat")
        let now = clock()
        lock.withLock {
            chats[id] = StoredChat(title: title, messages: [], surfaces: [], status: .idle, updatedAt: now)
            order.append(id)
        }
        listener.onChange(.chatChanged(chatId: id))
        return id
    }

    func sendMessage(chatId: String, text: String, continues: String?) throws -> String {
        try record("sendMessage", text + "|" + (continues ?? ""))
        return try appendMessage(chatId: chatId, text: text, continues: continues, attachments: [])
    }

    func addAttachment(chatId: String, bytes: Data, mime: String, name: String) throws -> MeshAttachment {
        try record("addAttachment", chatId + "|" + name)
        let id = nextId("attachment")
        let chunks = UInt64((bytes.count + 262_143) / 262_144)
        let attachment = MeshAttachment(
            id: id, handle: "res:" + id, chatId: chatId, name: name, mime: mime, size: UInt64(bytes.count),
            chunks: chunks, chunksHeld: chunks, complete: true, availability: .present)
        try lock.withLock {
            guard chats[chatId] != nil else { throw MeshKernelError.notFound }
            attachmentsValue[attachment.handle] = (attachment, bytes)
        }
        listener.onChange(.chatChanged(chatId: chatId))
        return attachment
    }

    func fetchAttachment(handle: String) async throws -> Data {
        try record("fetchAttachment", handle)
        await attachmentFetchGate()
        return try lock.withLock {
            guard let (_, bytes) = attachmentsValue[handle] else { throw MeshKernelError.notFound }
            return bytes
        }
    }

    func sendMessage(chatId: String, text: String, continues: String?, attachments: [String]) throws -> String {
        try record("sendMessageWithAttachments", text + "|" + attachments.joined(separator: ","))
        return try appendMessage(chatId: chatId, text: text, continues: continues, attachments: attachments)
    }

    private func appendMessage(chatId: String, text: String, continues: String?, attachments: [String]) throws -> String
    {
        guard !text.isEmpty || !attachments.isEmpty else { throw MeshKernelError.refused("message.empty") }
        let id = nextId("event")
        let now = clock()
        try lock.withLock {
            guard var chat = chats[chatId] else { throw MeshKernelError.notFound }
            let selected = try attachments.map { id in
                guard let (attachment, _) = attachmentsValue["res:" + id], attachment.chatId == chatId else {
                    throw MeshKernelError.refused("attachment.not_in_chat")
                }
                return attachment
            }
            let parent = continues ?? Self.head(of: chat.messages)
            chat.messages.append(
                MeshChatMessage(
                    eventId: id, parentId: parent, author: .owner, authorDevice: status.deviceId, text: text,
                    createdAt: now, delivery: .queued, surfaceIds: [], attachments: selected))
            chat.updatedAt = now
            chats[chatId] = chat
        }
        listener.onChange(.chatChanged(chatId: chatId))
        sendGate()
        return id
    }

    func fork(chatId: String, eventId: String) throws -> String {
        try record("fork", eventId)
        try lock.withLock {
            guard let chat = chats[chatId], chat.messages.contains(where: { $0.eventId == eventId }) else {
                throw MeshKernelError.notFound
            }
        }
        return eventId
    }

    func act(surfaceId: String, componentId: String, capability: String, args: [String: JSONValue]) async throws
        -> MeshActResult
    {
        let detail = args.keys.sorted().map { $0 + "=" + String(describing: args[$0]!) }.joined(separator: ",")
        try record("act", surfaceId + "/" + componentId + "/" + capability + (detail.isEmpty ? "" : "?" + detail))
        return actResult
    }

    func pendingOrdinaryMessages() async throws -> [MeshPendingMessage] {
        try record("pendingOrdinaryMessages")
        await pendingGate()
        return lock.withLock {
            guard status.hasMesh, !status.stopped else { return [] }
            let excluded = Set(runsValue.map(\.chatId))
            return pendingMessages.filter { target in
                guard !excluded.contains(target.chatId), let chat = chats[target.chatId], chat.status == .idle else {
                    return false
                }
                let queued = chat.messages.filter { $0.delivery == .queued }
                return queued.count == 1 && queued[0].eventId == target.messageId && queued[0].author == .owner
                    && chat.messages.last(where: { $0.author == .owner })?.eventId == target.messageId
            }.sorted { ($0.chatId, $0.messageId) < ($1.chatId, $1.messageId) }
        }
    }

    func resumePendingMessage(chatId: String, messageId: String) async throws {
        try record("resumePendingMessage", chatId + "/" + messageId)
        guard try await pendingOrdinaryMessages().contains(MeshPendingMessage(chatId: chatId, messageId: messageId))
        else {
            throw MeshKernelError.refused("That message cannot be resumed.")
        }
        let reply = nextId("event")
        let turnId = "turn-" + reply
        lock.withLock {
            guard var chat = chats[chatId], let index = chat.messages.firstIndex(where: { $0.eventId == messageId })
            else { return }
            let message = chat.messages[index]
            chat.messages[index] = MeshChatMessage(
                eventId: message.eventId, parentId: message.parentId, author: message.author,
                authorDevice: message.authorDevice,
                text: message.text, createdAt: message.createdAt, delivery: .recorded, surfaceIds: message.surfaceIds,
                attachments: message.attachments)
            chat.status = .running(turnId: turnId)
            chats[chatId] = chat
            pendingMessages.remove(MeshPendingMessage(chatId: chatId, messageId: messageId))
        }
        await turnGate()
        try driveTurn(chatId: chatId, turnId: turnId, reply: reply, events: turnScript)
    }

    func cancelPendingMessage(chatId: String, messageId: String) async throws {
        try record("cancelPendingMessage", chatId + "/" + messageId)
        let turnId = "turn-" + nextId("event")
        try lock.withLock {
            guard var chat = chats[chatId], chat.status == .idle,
                let index = chat.messages.lastIndex(where: { $0.author == .owner }),
                chat.messages[index].eventId == messageId, chat.messages[index].delivery == .queued
            else { throw MeshKernelError.refused("That message could not be stopped.") }
            let message = chat.messages[index]
            chat.messages[index] = MeshChatMessage(
                eventId: message.eventId, parentId: message.parentId, author: message.author,
                authorDevice: message.authorDevice, text: message.text, createdAt: message.createdAt,
                delivery: .recorded, surfaceIds: message.surfaceIds, attachments: message.attachments)
            chats[chatId] = chat
            pendingMessages.remove(MeshPendingMessage(chatId: chatId, messageId: messageId))
        }
        listener.onChange(.chatChanged(chatId: chatId))
        listener.onChange(.turnProgress(MeshTurnProgress(chatId: chatId, turnId: turnId, event: .started)))
        listener.onChange(.turnProgress(MeshTurnProgress(chatId: chatId, turnId: turnId, event: .interrupted)))
    }

    func ordinaryResumeTargets() async throws -> [MeshResumeTarget] {
        try record("ordinaryResumeTargets")
        return lock.withLock {
            guard status.hasMesh, !status.stopped else { return [] }
            let excluded = Set(runsValue.map(\.chatId))
            return resumeTargets.filter { target in
                !excluded.contains(target.chatId) && chats[target.chatId]?.status == .running(turnId: target.turnId)
            }.sorted { ($0.chatId, $0.turnId) < ($1.chatId, $1.turnId) }
        }
    }

    func resumeTurn(chatId: String, turnId: String) async throws {
        try record("resumeTurn", chatId + "/" + turnId)
        guard try await ordinaryResumeTargets().contains(MeshResumeTarget(chatId: chatId, turnId: turnId)) else {
            throw MeshKernelError.refused("That turn cannot be resumed.")
        }
        await turnGate()
        try driveTurn(
            chatId: chatId, turnId: turnId, reply: nextId("event"), events: turnScript.filter { $0 != .started })
    }

    func runMessage(chatId: String, messageId: String) async throws {
        try record("runMessage", chatId + "/" + messageId)
        try await executeTurn(chatId: chatId, messageId: messageId)
    }

    func runTurn(chatId: String) async throws {
        try record("runTurn", chatId)
        try await executeTurn(chatId: chatId, messageId: nil)
    }

    private func executeTurn(chatId: String, messageId: String?) async throws {
        if let turnError { throw turnError }
        let reply = nextId("event")
        let turnId = "turn-" + reply
        try lock.withLock {
            guard var chat = chats[chatId] else { throw MeshKernelError.notFound }
            if let messageId {
                guard let selected = chat.messages.first(where: { $0.eventId == messageId }),
                    selected.author == .owner, selected.delivery == .queued,
                    chat.messages.last(where: { $0.author == .owner })?.eventId == messageId
                else { throw MeshKernelError.refused("That message cannot be started.") }
            }
            chat.messages = chat.messages.map { message in
                message.delivery == .queued && (messageId == nil || message.eventId == messageId)
                    ? MeshChatMessage(
                        eventId: message.eventId, parentId: message.parentId, author: message.author,
                        authorDevice: message.authorDevice, text: message.text, createdAt: message.createdAt,
                        delivery: .recorded, surfaceIds: message.surfaceIds, attachments: message.attachments) : message
            }
            chat.status = .running(turnId: turnId)
            chats[chatId] = chat
        }
        await turnGate()
        try driveTurn(chatId: chatId, turnId: turnId, reply: reply, events: turnScript)
    }

    private func driveTurn(chatId: String, turnId: String, reply: String, events: [MeshTurnEvent]) throws {
        let now = clock()
        for event in events {
            if event == .finished {
                lock.withLock {
                    guard var chat = chats[chatId] else { return }
                    chat.messages.append(
                        MeshChatMessage(
                            eventId: reply, parentId: Self.head(of: chat.messages), author: .assistant,
                            authorDevice: status.deviceId, text: turnReply, createdAt: now, delivery: .recorded,
                            surfaceIds: []))
                    chat.status = .idle
                    chats[chatId] = chat
                }
                listener.onChange(.chatChanged(chatId: chatId))
            }
            listener.onChange(.turnProgress(MeshTurnProgress(chatId: chatId, turnId: turnId, event: event)))
        }
    }

    func steer(chatId: String, text: String) throws { try record("steer", text) }
    func interrupt(chatId: String) throws {
        try record("interrupt", chatId)
        try interruptGate()
    }

    func steerTurn(chatId: String, turnId: String, text: String) throws -> Bool {
        try record("steerTurn", chatId + "/" + turnId + ":" + text)
        try steerGate()
        return steerAcknowledged
    }

    func steerMessage(chatId: String, messageId: String, text: String) throws -> Bool {
        try record("steerMessage", chatId + "/" + messageId + ":" + text)
        try steerGate()
        return steerAcknowledged
    }

    func steerRequest(requestId: String, text: String) throws -> Bool {
        try record("steerRequest", requestId + ":" + text)
        try steerGate()
        return steerAcknowledged
    }

    func interruptTurn(chatId: String, turnId: String) throws -> Bool {
        try record("interruptTurn", chatId + "/" + turnId)
        try interruptGate()
        return interruptAcknowledged
    }

    func interruptMessage(chatId: String, messageId: String) throws -> Bool {
        try record("interruptMessage", chatId + "/" + messageId)
        try interruptGate()
        return interruptAcknowledged
    }

    func interruptRequest(requestId: String) throws -> Bool {
        try record("interruptRequest", requestId)
        try interruptGate()
        return interruptAcknowledged
    }

    func pendingConsents() throws -> [MeshPendingConsent] {
        try record("pendingConsents")
        return lock.withLock { consents }
    }

    func resolveConsent(requestId: String, approve: Bool) throws {
        try record("resolveConsent", requestId + (approve ? ":approve" : ":deny"))
        if approve {
            try consentGate()
            if let actionSigner, let pending = lock.withLock({ consents.first { $0.requestId == requestId } }) {
                try actionSigner(pending)
            }
        }
        lock.withLock { consents.removeAll { $0.requestId == requestId } }
    }

    func tools() -> [MeshToolEntry] { lock.withLock { toolsValue } }

    func grantTool(name: String, scope: String) throws {
        try record("grantTool", name + "|" + scope)
        guard !name.isEmpty, !scope.isEmpty else {
            throw MeshKernelError.refused(KernelMapping.failureText(code: "grant.malformed"))
        }
        try consentGate()
        lock.withLock { _ = grantsValue.insert(name + "/" + scope) }
    }

    func revokeTool(name: String, scope: String) throws {
        try record("revokeTool", name + "|" + scope)
        guard !name.isEmpty, !scope.isEmpty else {
            throw MeshKernelError.refused(KernelMapping.failureText(code: "grant.malformed"))
        }
        lock.withLock { _ = grantsValue.remove(name + "/" + scope) }
    }

    var grantKeys: Set<String> { lock.withLock { grantsValue } }

    func publishToolCatalog() throws { try record("publishToolCatalog") }

    func grants() throws -> [MeshGrant] {
        try record("grants")
        return lock.withLock {
            grantsValue.sorted().compactMap { key in
                guard let slash = key.lastIndex(of: "/") else { return nil }
                return MeshGrant(
                    grantId: key, tool: String(key[..<slash]), scope: String(key[key.index(after: slash)...]),
                    grantedBy: status.deviceId, consented: true, refusal: nil)
            }
        }
    }

    func resolveHandle(chatId: String, handle: String) throws -> MeshResolvedHandle {
        try record("resolveHandle", chatId + "|" + handle)
        guard let value = lock.withLock({ handlesValue[handle] }) else {
            throw MeshKernelError.refused(KernelMapping.failureText(code: "handle.no_value"))
        }
        return value
    }

    func setHandles(_ value: [String: MeshResolvedHandle]) { lock.withLock { handlesValue = value } }

    func answerRequest(requestId: String) async throws {
        try record("answerRequest", requestId)
        let chat = try changeRequest(requestId, allowed: [.pending, .claimed]) { $0.state = .claimed }
        listener.onChange(.chatChanged(chatId: chat))
        try await runTurn(chatId: chat)
    }

    func setTools(_ value: [MeshToolEntry]) { lock.withLock { toolsValue = value } }

    func chatRequests(chatId: String) throws -> [MeshRequest] {
        try record("chatRequests", chatId)
        return lock.withLock { requestsValue.filter { $0.chatId == chatId }.sorted { $0.createdAt < $1.createdAt } }
    }

    func pendingRequestsForMe() throws -> [MeshRequest] {
        try record("pendingRequestsForMe")
        return lock.withLock {
            requestsValue.filter { $0.toMember == status.deviceId && $0.state == .pending }
                .sorted { $0.createdAt < $1.createdAt }
        }
    }

    func sendRequest(chatId: String, text: String, toMember: String) throws -> String {
        try record("sendRequest", chatId + "|" + toMember + "|" + text)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeshKernelError.refused(KernelMapping.failureText(code: "request.empty"))
        }
        let id = nextId("request")
        let now = clock()
        try lock.withLock {
            guard chats[chatId] != nil else { throw MeshKernelError.notFound }
            guard toMember != status.deviceId else {
                throw MeshKernelError.refused(KernelMapping.failureText(code: "request.self_addressed"))
            }
            guard members.contains(where: { $0.memberId == toMember }) else {
                throw MeshKernelError.refused(KernelMapping.failureText(code: "request.unknown_member"))
            }
            requestsValue.append(
                MeshRequest(
                    requestId: id, chatId: chatId, fromMember: status.deviceId, toMember: toMember, state: .pending,
                    text: text, refusalCode: nil, tool: nil, createdAt: now))
        }
        listener.onChange(.chatChanged(chatId: chatId))
        return id
    }

    func claimRequest(requestId: String) throws {
        try record("claimRequest", requestId)
        let chat = try changeRequest(requestId, allowed: [.pending, .claimed]) { $0.state = .claimed }
        listener.onChange(.chatChanged(chatId: chat))
    }

    func refuseRequest(requestId: String, code: String) throws {
        try record("refuseRequest", requestId + "|" + code)
        let chat = try changeRequest(requestId, allowed: [.pending, .claimed]) {
            $0.state = .refused
            $0.refusalCode = code
        }
        listener.onChange(.chatChanged(chatId: chat))
    }

    func recordSpoken(chatId: String, kind: VoiceSpokenKind, text: String) throws {
        try record("recordSpoken", chatId + ":" + text)
    }

    func setModelProvider(_ config: MeshModelProviderConfig) throws {
        try record("setModelProvider", config.baseURL + " " + config.model)
        guard config.apiKey.isEmpty == false else { throw MeshKernelError.refused("provider.key_missing") }
        providerSaveGate()
        lock.withLock {
            providers = [
                MeshModelProvider(
                    providerId: "provider-1", baseURL: config.baseURL, model: config.model, hasKey: true,
                    isDefault: true, recipients: config.recipients,
                    availableOnDevice: config.recipients?.contains(status.deviceId ?? "") ?? true)
            ]
        }
    }

    func setModelProviderRecipients(name: String, recipients: [String]?) throws -> MeshModelProvider {
        try record("setModelProviderRecipients", name)
        providerSaveGate()
        return try lock.withLock {
            guard let index = providers.firstIndex(where: { $0.providerId == name }) else {
                throw MeshKernelError.notFound
            }
            guard recipients?.isEmpty != true else { throw MeshKernelError.refused("Select at least one device.") }
            let memberIds = Set(members.map(\.memberId))
            guard recipients?.allSatisfy({ memberIds.contains($0) }) != false else {
                throw MeshKernelError.refused("Refresh the device list and try again.")
            }
            providers[index].recipients = recipients?.sorted()
            providers[index].availableOnDevice = recipients?.contains(status.deviceId ?? "") ?? true
            return providers[index]
        }
    }

    func modelProviders() throws -> [MeshModelProvider] {
        try record("modelProviders")
        return lock.withLock { providers.filter(\.availableOnDevice) }
    }

    func setRemoteMCPServer(_ config: MeshRemoteMCPConfig) throws {
        try record("setRemoteMCPServer", config.name)
        lock.withLock {
            remoteMCPServersValue[config.name] = MeshRemoteMCPServer(
                name: config.name, endpoint: config.endpoint, credentialConfigured: config.bearer != nil)
            remoteMCPToolsValue[config.name] = []
        }
    }

    func remoteMCPServers() throws -> [MeshRemoteMCPServer] {
        try record("remoteMCPServers")
        return lock.withLock { remoteMCPServersValue.values.sorted { $0.name < $1.name } }
    }

    func removeRemoteMCPServer(_ name: String) throws {
        try record("removeRemoteMCPServer", name)
        lock.withLock {
            remoteMCPServersValue.removeValue(forKey: name)
            remoteMCPToolsValue.removeValue(forKey: name)
        }
    }

    func refreshRemoteMCPTools(_ server: String) async throws -> [MeshRemoteMCPTool] {
        try record("refreshRemoteMCPTools", server)
        return try lock.withLock {
            guard remoteMCPServersValue[server] != nil else {
                throw MeshKernelError.refused("The MCP server is unavailable.")
            }
            return remoteMCPToolsValue[server] ?? []
        }
    }

    func approveRemoteMCPTool(_ tool: MeshRemoteMCPTool) async throws {
        try record("approveRemoteMCPTool", tool.id + " " + tool.definitionHash)
        try lock.withLock {
            guard
                let index = remoteMCPToolsValue[tool.server]?.firstIndex(where: {
                    $0.name == tool.name && $0.definitionHash == tool.definitionHash
                        && $0.configurationRevision == tool.configurationRevision && $0.endpoint == tool.endpoint
                })
            else {
                throw MeshKernelError.refused("The MCP definition changed. Refresh and review it again.")
            }
            remoteMCPToolsValue[tool.server]?[index].status = "approved"
        }
    }

    func revokeRemoteMCPTool(server: String, tool: String) throws {
        try record("revokeRemoteMCPTool", server + "__" + tool)
        lock.withLock {
            if let index = remoteMCPToolsValue[server]?.firstIndex(where: { $0.name == tool }) {
                remoteMCPToolsValue[server]?[index].status = "new"
            }
        }
    }

    func setRemoteMCPTools(_ server: String, tools: [MeshRemoteMCPTool]) {
        lock.withLock { remoteMCPToolsValue[server] = tools }
    }

    func mailboxState() -> MeshMailboxState { lock.withLock { mailboxValue } }

    func setMailboxState(_ value: MeshMailboxState) { lock.withLock { mailboxValue = value } }

    func syncState() async throws -> MeshSyncState {
        try record("syncState")
        return lock.withLock { syncValue }
    }

    func allowance() throws -> MeshAllowance {
        try record("allowance")
        return lock.withLock { allowanceValue }
    }

    func runs() async throws -> [MeshRun] {
        try record("runs")
        return lock.withLock { runsValue }
    }

    func handOffRun(runId: String, memberId: String) async throws {
        try record("handOffRun", runId + ":" + memberId)
        try consentGate()
        lock.withLock {
            guard let index = runsValue.firstIndex(where: { $0.runId == runId }) else { return }
            let run = runsValue[index]
            runsValue[index] = MeshRun(
                runId: run.runId, chatId: run.chatId, kind: run.kind, goal: run.goal, status: run.status,
                reason: run.reason, rounds: run.rounds, tokensSpent: run.tokensSpent, role: .watcher,
                executor: memberId, unknownSteps: run.unknownSteps)
        }
        listener.onChange(.runProgress(runId: runId))
    }

    func takeOverRun(runId: String) async throws -> MeshTakeOver {
        try record("takeOverRun", runId)
        try consentGate()
        let unknown = lock.withLock { () -> Int in
            guard let index = runsValue.firstIndex(where: { $0.runId == runId }) else { return 0 }
            let run = runsValue[index]
            runsValue[index] = MeshRun(
                runId: run.runId, chatId: run.chatId, kind: run.kind, goal: run.goal, status: run.status,
                reason: run.reason, rounds: run.rounds, tokensSpent: run.tokensSpent, role: .executor,
                executor: status.deviceId, unknownSteps: run.unknownSteps)
            return run.unknownSteps
        }
        listener.onChange(.runProgress(runId: runId))
        return MeshTakeOver(unknownSteps: unknown)
    }

    func learningProposals() async throws -> [MeshProposal] {
        try record("learningProposals")
        return lock.withLock { proposalsValue }
    }

    func reviewProposal(id: String, adopt: Bool) async throws -> MeshEvaluation {
        try record("reviewProposal", id + (adopt ? ":adopt" : ":decline"))
        return try lock.withLock {
            guard let index = proposalsValue.firstIndex(where: { $0.proposalId == id }) else {
                throw MeshKernelError.notFound
            }
            let proposal = proposalsValue[index]
            let next: MeshProposal.Status = adopt ? .adopted : .declined
            proposalsValue[index] = MeshProposal(
                proposalId: proposal.proposalId, kind: proposal.kind, name: proposal.name, content: proposal.content,
                status: next, detail: proposal.detail, tools: proposal.tools, untrusted: proposal.untrusted,
                gatePassed: proposal.gatePassed, replayPassed: proposal.replayPassed,
                ownerReasons: proposal.ownerReasons, hygiene: proposal.hygiene)
            return adopt ? .adopted : .declined("owner")
        }
    }

    func undoAdoption(id: String) async throws {
        try record("undoAdoption", id)
        try lock.withLock {
            guard let index = proposalsValue.firstIndex(where: { $0.proposalId == id && $0.status == .adopted })
            else { throw MeshKernelError.notFound }
            let proposal = proposalsValue[index]
            proposalsValue[index] = MeshProposal(
                proposalId: proposal.proposalId, kind: proposal.kind, name: proposal.name, content: proposal.content,
                status: .reversed, detail: proposal.detail, tools: proposal.tools, untrusted: proposal.untrusted,
                gatePassed: proposal.gatePassed, replayPassed: proposal.replayPassed,
                ownerReasons: proposal.ownerReasons, hygiene: proposal.hygiene)
        }
    }

    func setRequests(_ value: [MeshRequest], notify: Bool = true) {
        lock.withLock { requestsValue = value }
        if notify { listener.onChange(.chatChanged(chatId: nil)) }
    }

    private struct EditableRequest {
        var state: MeshRequestState
        var refusalCode: String?
    }

    private func changeRequest(
        _ id: String, allowed: Set<MeshRequestState>, _ edit: (inout EditableRequest) -> Void
    ) throws -> String {
        try lock.withLock {
            guard let index = requestsValue.firstIndex(where: { $0.requestId == id }) else {
                throw MeshKernelError.refused(KernelMapping.failureText(code: "request.unknown"))
            }
            let request = requestsValue[index]
            guard request.toMember == status.deviceId else {
                throw MeshKernelError.refused(KernelMapping.failureText(code: "request.not_target"))
            }
            guard allowed.contains(request.state) else {
                throw MeshKernelError.refused(KernelMapping.failureText(code: "request." + request.state.rawValue))
            }
            var editable = EditableRequest(state: request.state, refusalCode: request.refusalCode)
            edit(&editable)
            requestsValue[index] = MeshRequest(
                requestId: request.requestId, chatId: request.chatId, fromMember: request.fromMember,
                toMember: request.toMember, state: editable.state, text: request.text,
                refusalCode: editable.refusalCode, tool: request.tool, createdAt: request.createdAt)
            return request.chatId
        }
    }

    func setRuns(_ value: [MeshRun]) {
        lock.withLock { runsValue = value }
        listener.onChange(.runProgress(runId: value.first?.runId ?? ""))
    }

    func setProposals(_ value: [MeshProposal]) {
        lock.withLock { proposalsValue = value }
    }

    func setPending(_ requests: [MeshPendingConsent]) {
        lock.withLock { consents = requests }
        for request in requests { listener.onChange(.consentRequested(requestId: request.requestId)) }
    }

    func setSync(_ value: MeshSyncState) {
        lock.withLock { syncValue = value }
        listener.onChange(.syncStateChanged)
    }

    func setAllowance(_ value: MeshAllowance) {
        lock.withLock { allowanceValue = value }
        listener.onChange(.allowanceChanged)
    }

    func setMembers(_ value: [MeshMember]) {
        lock.withLock { members = value }
        listener.onChange(.rosterChanged)
    }

    func seedChat(title: String, messages: [MeshChatMessage], surfaces: [MeshSurface] = []) -> String {
        let id = nextId("chat")
        lock.withLock {
            chats[id] = StoredChat(
                title: title, messages: messages, surfaces: surfaces, status: .idle,
                updatedAt: messages.last?.createdAt ?? clock())
            order.append(id)
        }
        return id
    }

    func seedPendingOrdinaryMessage(chatId: String, messageId: String) {
        lock.withLock { _ = pendingMessages.insert(MeshPendingMessage(chatId: chatId, messageId: messageId)) }
    }

    func seedOrdinaryResume(chatId: String, turnId: String) {
        lock.withLock {
            resumeTargets.insert(MeshResumeTarget(chatId: chatId, turnId: turnId))
            chats[chatId]?.status = .running(turnId: turnId)
        }
    }

    func emit(_ change: MeshKernelChange) { listener.onChange(change) }

    func setChatStatus(chatId: String, _ value: MeshChatStatus) {
        lock.withLock { chats[chatId]?.status = value }
        listener.onChange(.chatChanged(chatId: chatId))
    }

    private func record(_ name: String, _ detail: String = "") throws {
        let injected = lock.withLock { () -> MeshKernelError? in
            log.append(Call(name: name, detail: detail))
            return failure
        }
        if let injected { throw injected }
    }

    private func nextId(_ kind: String) -> String {
        lock.withLock {
            counter += 1
            return "\(kind)-\(counter)"
        }
    }

    private func summary(id: String, chat: StoredChat) -> MeshChatSummary {
        MeshChatSummary(
            chatId: id, title: chat.title, updatedAt: chat.updatedAt, preview: chat.messages.last?.text ?? "",
            branchCount: max(0, branches(of: chat).count - 1),
            queuedCount: chat.messages.filter { $0.delivery == .queued }.count)
    }

    private func branches(of chat: StoredChat) -> [MeshBranch] {
        let parents = Set(chat.messages.compactMap(\.parentId))
        return chat.messages.filter { !parents.contains($0.eventId) }.map { leaf in
            MeshBranch(
                headId: leaf.eventId, forkId: Self.forkPoint(of: leaf, in: chat.messages),
                messageCount: Self.path(to: leaf, in: chat.messages).count, updatedAt: leaf.createdAt)
        }
    }

    private static func head(of messages: [MeshChatMessage]) -> String? {
        let parents = Set(messages.compactMap(\.parentId))
        return messages.last { !parents.contains($0.eventId) }?.eventId
    }

    private static func path(to leaf: MeshChatMessage, in messages: [MeshChatMessage]) -> [MeshChatMessage] {
        let byId = Dictionary(uniqueKeysWithValues: messages.map { ($0.eventId, $0) })
        var out = [leaf]
        var cursor = leaf.parentId
        while let id = cursor, let next = byId[id] {
            out.append(next)
            cursor = next.parentId
        }
        return out.reversed()
    }

    private static func forkPoint(of leaf: MeshChatMessage, in messages: [MeshChatMessage]) -> String? {
        var counts: [String: Int] = [:]
        for message in messages { if let parent = message.parentId { counts[parent, default: 0] += 1 } }
        return path(to: leaf, in: messages).last { counts[$0.eventId, default: 0] > 1 }?.eventId
    }

    private static func thisDevice(status: MeshStatus) -> MeshMember {
        MeshMember(
            memberId: status.deviceId ?? "", label: "This device", kind: .desktop, isThisDevice: true,
            lastSeen: nil, path: .none)
    }
}
