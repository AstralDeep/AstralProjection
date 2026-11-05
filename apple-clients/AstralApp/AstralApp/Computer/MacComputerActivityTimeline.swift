// Retains a bounded, in-memory summary of one Mac computer owner’s local activity.
// MacComputerHost records only closed event types and request verbs, never request data or results.

#if os(macOS)
    import AstralCore
    import Foundation
    import Observation

    enum MacComputerActivityKind: String, CaseIterable, Sendable {
        case approval, admission, result, denial, pause, resume, stop, checkpoint
    }

    struct MacComputerActivityEntry: Identifiable, Equatable, Sendable {
        let id: String
        let occurredAt: Date
        let kind: MacComputerActivityKind
        let state: String
        let verb: String?

        var title: String {
            switch (kind, state) {
            case (.approval, "waiting"): "Approval requested"
            case (.approval, "cleared"): "Approval cleared"
            case (.admission, _): "Request admitted"
            case (.result, "succeeded"): "Request completed"
            case (.result, _): "Request interrupted"
            case (.denial, _): "Request denied"
            case (.pause, _): "Computer access paused"
            case (.resume, "requested"): "Resume requested"
            case (.resume, "active"): "Computer access resumed"
            case (.resume, _): "Resume denied"
            case (.stop, _): "Computer task stopped"
            case (.checkpoint, "admitted"): "Checkpoint request admitted"
            case (.checkpoint, "succeeded"): "Checkpoint request completed"
            case (.checkpoint, "denied"): "Checkpoint request denied"
            default: "Computer activity"
            }
        }

        var safeVerb: String? { verb?.replacingOccurrences(of: "_", with: " ") }
    }

    @MainActor @Observable
    final class MacComputerActivityTimeline {
        static let maximumEntries = 100
        private(set) var entries: [MacComputerActivityEntry] = []
        private var owner: String?
        private let now: () -> Date

        init(now: @escaping () -> Date = Date.init) { self.now = now }

        func bind(owner: String?) {
            guard self.owner != owner else { return }
            self.owner = owner
            entries.removeAll(keepingCapacity: true)
        }

        func record(_ kind: MacComputerActivityKind, state: String, verb: String? = nil) {
            guard owner != nil, Self.valid(kind: kind, state: state) else { return }
            let safeVerb = verb.flatMap { ComputerHostRequest.verbs.contains($0) ? $0 : nil }
            let entry = MacComputerActivityEntry(
                id: UUID().uuidString.lowercased(), occurredAt: now(), kind: kind, state: state, verb: safeVerb)
            entries.append(entry)
            if entries.count > Self.maximumEntries {
                entries.removeFirst(entries.count - Self.maximumEntries)
            }
        }

        private static func valid(kind: MacComputerActivityKind, state: String) -> Bool {
            switch kind {
            case .approval: ["waiting", "cleared"].contains(state)
            case .admission: state == "admitted"
            case .result: ["succeeded", "interrupted"].contains(state)
            case .denial: state == "denied"
            case .pause: state == "paused"
            case .resume: ["requested", "active", "denied"].contains(state)
            case .stop: state == "stopped"
            case .checkpoint: ["admitted", "succeeded", "denied"].contains(state)
            }
        }
    }
#endif
