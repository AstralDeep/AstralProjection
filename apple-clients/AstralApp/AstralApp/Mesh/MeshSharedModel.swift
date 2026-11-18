// State behind the reader side of sharing: the list of chats others share, and one shared chat that opens read only after a refresh.
// A grant from a contact the reader has not verified fetches nothing, and a stopped grant keeps no content.

import Foundation
import Observation

nonisolated struct MeshSharedBadgeFacts: Equatable, Sendable {
    let text: String
    let name: String
    let isVerified: Bool
    let stateLine: String

    init(_ item: MeshSharedItem) {
        name = item.contactName.isEmpty ? "A contact" : item.contactName
        text = "From " + name
        isVerified = item.state == .ready
        stateLine = item.state == .needsVerification ? "Not verified" : "Verified"
    }
}

nonisolated struct MeshSharedRowFacts: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let badge: MeshSharedBadgeFacts
    let stateLine: String?
    let withheldLine: String?
    let canOpen: Bool

    init(_ item: MeshSharedItem) {
        id = item.grant
        title = item.title.isEmpty ? "A chat" : item.title
        badge = MeshSharedBadgeFacts(item)
        canOpen = item.state != .stopped
        switch item.state {
        case .ready: stateLine = nil
        case .needsVerification: stateLine = "Verify " + badge.name + " to read this."
        case .stopped: stateLine = "No longer shared"
        }
        withheldLine = item.state == .ready && item.withheldAny ? MeshSharedCopy.withheld : nil
    }
}

nonisolated enum MeshSharedCopy {
    static let withheld = "Some of this chat isn't shared."
    static let stopped = "No longer shared"
    static let stoppedDetail = "The owner stopped sharing this chat. What it held is no longer shown here."
    static let readOnly = "You can read this chat. You can't reply to it."
}

@MainActor
@Observable
final class MeshSharedChatModel {
    enum Phase: Equatable {
        case loading
        case needsVerification
        case ready(MeshChatView)
        case stopped
        case failed(String)
    }

    private let service: any MeshSharedService
    private(set) var item: MeshSharedItem
    private(set) var phase: Phase = .loading
    private(set) var refreshProblem: String?

    init(item: MeshSharedItem, service: any MeshSharedService) {
        self.item = item
        self.service = service
        phase = Self.initial(item)
    }

    var badge: MeshSharedBadgeFacts { MeshSharedBadgeFacts(item) }
    var withheldNotice: String? { item.withheldAny ? MeshSharedCopy.withheld : nil }

    private static func initial(_ item: MeshSharedItem) -> Phase {
        switch item.state {
        case .needsVerification: return .needsVerification
        case .stopped: return .stopped
        case .ready: return .loading
        }
    }

    func open() async {
        guard item.state == .ready else {
            phase = Self.initial(item)
            return
        }
        refreshProblem = nil
        do {
            if try await service.refreshShared(grant: item.grant).stopped.contains(item.grant) {
                await settleStopped()
                return
            }
        } catch {
            if (error as? MeshKernelError)?.code == "contact.unverified" {
                phase = .needsVerification
                return
            }
            refreshProblem = MeshRuntime.describe(error)
        }
        await adopt(service: service)
    }

    private func adopt(service: any MeshSharedService) async {
        await service.refreshSharedItems()
        if let latest = service.sharedItems.first(where: { $0.grant == item.grant }) {
            item = latest
            guard latest.state == .ready else {
                phase = Self.initial(latest)
                return
            }
        }
        do {
            phase = .ready(try await service.sharedChat(grant: item.grant))
        } catch {
            if (error as? MeshKernelError)?.code == "share.grant_unknown" {
                phase = .stopped
            } else {
                phase = .failed(MeshRuntime.describe(error))
            }
        }
    }

    private func settleStopped() async {
        await service.refreshSharedItems()
        if let latest = service.sharedItems.first(where: { $0.grant == item.grant }) { item = latest }
        phase = .stopped
    }

    func attachment(_ attachment: MeshAttachment) async -> Data? {
        guard case .ready = phase else { return nil }
        do { return try await service.sharedAttachment(grant: item.grant, event: attachment.id) } catch {
            refreshProblem = MeshRuntime.describe(error)
            return nil
        }
    }
}

enum MeshSharedID {
    static let list = "mesh.shared.list"
    static let entry = "mesh.chats.shared"
    static let chat = "mesh.shared.chat"
    static let badge = "mesh.shared.badge"
    static let verify = "mesh.shared.verify"
    static let stopped = "mesh.shared.stopped"
    static let withheld = "mesh.shared.withheld"
    static let readOnly = "mesh.shared.readonly"

    static func row(_ grant: String) -> String { "mesh.shared.row." + grant }
}
