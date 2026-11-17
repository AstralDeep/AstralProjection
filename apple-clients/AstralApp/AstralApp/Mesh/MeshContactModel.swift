// State behind the contact screens: classifying pasted or scanned invitations, the invite, accept and compare flows, and the facts each contact row shows.
// Signatures, expiry and the roster rules stay with the Kernel, and a presence prompt starts only from the Codes match action.

import Foundation
import Observation

nonisolated enum MeshContactLinkError: Error, Equatable, Sendable {
    case empty
    case notAnInvitation
    case wrongHost
    case damaged

    var message: String {
        switch self {
        case .empty: return "Paste or scan an invitation first."
        case .notAnInvitation: return "That is not a contact invitation."
        case .wrongHost: return "That link is not from AstralDeep."
        case .damaged: return "That invitation looks damaged. Ask for a new one."
        }
    }
}

nonisolated struct MeshContactInvite: Equatable, Sendable {
    let text: String
    let name: String
    let expiresAt: Date?
}

nonisolated enum MeshContactLink {
    static let textPrefix = "astral-contact:v1:"
    static let host = "astraldeep.github.io"
    static let path = "/contact/"

    static func classify(_ raw: String) -> Result<MeshContactInvite, MeshContactLinkError> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        let payload: String
        if text.hasPrefix(textPrefix) {
            payload = String(text.dropFirst(textPrefix.count))
        } else if let link = linkPayload(text) {
            switch link {
            case .success(let found): payload = found
            case .failure(let error): return .failure(error)
            }
        } else {
            return .failure(.notAnInvitation)
        }
        guard let body = decode(payload) else { return .failure(.damaged) }
        let expires = (body["expires_s"] as? Int).map { Date(timeIntervalSince1970: Double($0)) }
        return .success(MeshContactInvite(text: text, name: body["name"] as? String ?? "", expiresAt: expires))
    }

    static func text(from url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme?.lowercased() == "https",
            parts.host?.lowercased() == host, parts.path == path
        else { return nil }
        guard case .success(let invite) = classify(url.absoluteString) else { return nil }
        return invite.text
    }

    private static func linkPayload(_ text: String) -> Result<String, MeshContactLinkError>? {
        guard text.lowercased().hasPrefix("https://"), let parts = URLComponents(string: text) else { return nil }
        guard parts.host?.lowercased() == host, parts.path == path else { return .failure(.wrongHost) }
        return .success(parts.fragment ?? "")
    }

    private static func decode(_ payload: String) -> [String: Any]? {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard !payload.isEmpty, payload.allSatisfy({ allowed.contains($0) }) else { return nil }
        let standard = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), String(data: data, encoding: .utf8) != nil else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

nonisolated struct MeshIncomingContact: Identifiable, Equatable, Sendable {
    let id = UUID()
    let text: String
}

nonisolated enum MeshContactCode {
    static func format(_ code: String) -> String {
        let digits = code.filter(\.isNumber)
        guard digits.count == 12 else { return code }
        return stride(from: 0, to: 12, by: 4).map { start in
            String(digits.dropFirst(start).prefix(4))
        }.joined(separator: " ")
    }

    static func isTwelveDigits(_ code: String) -> Bool {
        code.filter { !$0.isWhitespace }.count == 12 && code.allSatisfy { $0.isNumber || $0.isWhitespace }
    }
}

nonisolated enum MeshContactName {
    static let limit = 64

    static func clean(_ raw: String) -> Result<String, MeshContactNameError> {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .failure(.empty) }
        if name.unicodeScalars.count > limit { return .failure(.tooLong) }
        return .success(name)
    }
}

nonisolated enum MeshContactNameError: Error, Equatable, Sendable {
    case empty
    case tooLong

    var message: String {
        switch self {
        case .empty: return "Add the name they will see."
        case .tooLong: return "Use 64 characters or fewer."
        }
    }
}

nonisolated struct MeshContactRowFacts: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let fingerprint: String
    let stateLine: String
    let isVerified: Bool
    let notices: [String]
    let warning: String?

    init(_ contact: MeshContact) {
        id = contact.mesh
        name = contact.name
        fingerprint = contact.fingerprint
        isVerified = contact.isVerified
        stateLine = contact.isVerified ? "Verified" : "Not verified"
        notices = contact.notices.map(Self.line)
        if !contact.isVerified, let reason = contact.reason {
            let detail = KernelMapping.failureText(code: reason)
            warning = "Verification was withdrawn. Compare codes again. " + detail
        } else {
            warning = nil
        }
    }

    static func line(_ notice: MeshContactNotice) -> String {
        switch notice.kind {
        case .deviceAdded: return "A new device joined their mesh."
        case .deviceRemoved: return "A device was removed from their mesh."
        case .recoveryUsed: return "They restored their mesh from recovery words."
        case .other: return "Their devices changed."
        }
    }
}

@MainActor
@Observable
final class MeshContactInviteModel {
    enum Phase: Equatable {
        case form
        case creating
        case shown(MeshContactInvitation, expiresAt: Date)
        case comparing(MeshContactExchange)
        case failed(String)
    }

    static let lifetime: UInt64 = 900

    private let service: any MeshContactService
    private let now: @Sendable () -> Date
    private(set) var phase: Phase = .form
    var name = ""

    init(service: any MeshContactService, now: @escaping @Sendable () -> Date = { Date() }) {
        self.service = service
        self.now = now
    }

    func create() async {
        switch MeshContactName.clean(name) {
        case .failure(let error): phase = .failed(error.message)
        case .success(let clean):
            phase = .creating
            do {
                let invitation = try await service.createContactInvitation(name: clean, ttlSeconds: Self.lifetime)
                phase = .shown(invitation, expiresAt: now().addingTimeInterval(Double(invitation.expiresInSeconds)))
            } catch {
                phase = .failed(MeshRuntime.describe(error))
            }
        }
    }

    func checkPending() async {
        guard case .shown = phase else { return }
        if let found = try? await service.pendingContactExchanges().first { phase = .comparing(found) }
    }

    func cancel() async {
        if case .shown = phase { await service.cancelContactInvitation() }
        phase = .form
    }

    func reset() { phase = .form }
}

@MainActor
@Observable
final class MeshContactAcceptModel {
    enum Phase: Equatable {
        case form
        case working
        case comparing(MeshContactExchange)
        case failed(String)
    }

    private let service: any MeshContactService
    private(set) var phase: Phase = .form
    private(set) var preview: MeshContactInvite?
    var input = ""
    var name = ""

    init(service: any MeshContactService, initial: String = "") {
        self.service = service
        input = initial
        classify()
    }

    func classify() {
        if case .success(let invite) = MeshContactLink.classify(input) { preview = invite } else { preview = nil }
    }

    var canSubmit: Bool { preview != nil && phase != .working }

    func submit() async {
        let invite: MeshContactInvite
        switch MeshContactLink.classify(input) {
        case .failure(let error):
            phase = .failed(error.message)
            return
        case .success(let found): invite = found
        }
        let clean: String
        switch MeshContactName.clean(name) {
        case .failure(let error):
            phase = .failed(error.message)
            return
        case .success(let found): clean = found
        }
        phase = .working
        do {
            phase = .comparing(try await service.acceptContactInvitation(text: invite.text, name: clean))
        } catch {
            phase = .failed(MeshRuntime.describe(error))
        }
    }

    func reset() { phase = .form }
}

@MainActor
@Observable
final class MeshContactCompareModel {
    enum Phase: Equatable {
        case comparing
        case verifying
        case verified(MeshContact)
        case differed
        case failed(String)
    }

    enum Scan: Equatable {
        case none
        case matches
        case differs
    }

    private let service: any MeshContactService
    let exchange: MeshContactExchange
    private(set) var phase: Phase = .comparing
    private(set) var scan: Scan = .none

    init(service: any MeshContactService, exchange: MeshContactExchange) {
        self.service = service
        self.exchange = exchange
    }

    var displayCode: String { MeshContactCode.format(exchange.code) }

    func scanned(_ text: String) {
        scan = text.trimmingCharacters(in: .whitespacesAndNewlines) == exchange.codeQR ? .matches : .differs
    }

    func codesMatch() async {
        guard phase == .comparing || isFailed else { return }
        phase = .verifying
        do {
            phase = .verified(try await service.verifyContact(exchangeId: exchange.id))
        } catch {
            phase = .failed(MeshRuntime.describe(error))
        }
    }

    func codesDiffer() async {
        guard phase == .comparing || isFailed else { return }
        do {
            try await service.rejectContactExchange(exchangeId: exchange.id)
            phase = .differed
        } catch {
            phase = .failed(MeshRuntime.describe(error))
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }
}

enum MeshContactID {
    static let list = "mesh.contacts.list"
    static let add = "mesh.contacts.add"
    static let empty = "mesh.contacts.empty"
    static let inviteName = "mesh.contacts.invite.name"
    static let inviteCreate = "mesh.contacts.invite.create"
    static let inviteQR = "mesh.contacts.invite.qr"
    static let inviteShare = "mesh.contacts.invite.share"
    static let inviteCopy = "mesh.contacts.invite.copy"
    static let inviteCancel = "mesh.contacts.invite.cancel"
    static let acceptInput = "mesh.contacts.accept.input"
    static let acceptName = "mesh.contacts.accept.name"
    static let acceptPaste = "mesh.contacts.accept.paste"
    static let acceptScan = "mesh.contacts.accept.scan"
    static let acceptSubmit = "mesh.contacts.accept.submit"
    static let code = "mesh.contacts.code"
    static let codeQR = "mesh.contacts.code.qr"
    static let codeScan = "mesh.contacts.code.scan"
    static let codesMatch = "mesh.contacts.code.match"
    static let codesDiffer = "mesh.contacts.code.differ"
    static let remove = "mesh.contacts.remove"
    static let verifyAgain = "mesh.contacts.verify"

    static func row(_ mesh: String) -> String { "mesh.contacts.row." + mesh }
}
