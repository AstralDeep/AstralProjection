// Plain-language text for mesh state: sync summaries, last seen, paths and allowance refusals.
// Views and tests share these so every screen words the same state the same way.

import Foundation

nonisolated enum MeshPresentation {
    static func lastSeen(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Not seen yet" }
        if now.timeIntervalSince(date) < 45 { return "Seen just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last seen " + formatter.localizedString(for: date, relativeTo: now)
    }

    static func syncLine(_ summary: MeshSyncSummary, now: Date = Date()) -> String {
        switch summary {
        case .alone: return "This is your only device. Nothing to sync."
        case .synced: return "Synced with your other devices."
        case .waiting(let device, let since): return "Waiting for \(device). " + lastSeen(since, now: now) + "."
        case .unknown: return "Sync state is not known yet."
        }
    }

    static func path(_ path: MeshPath) -> String {
        switch path {
        case .direct: return "Direct"
        case .relay: return "Through a relay"
        case .mailbox: return "Through the mailbox"
        case .none: return "Not connected"
        }
    }

    static func kind(_ kind: MeshDeviceKind) -> String {
        switch kind {
        case .desktop: return "Computer"
        case .pocket: return "Phone"
        case .satellite: return "Watch"
        case .node: return "Node"
        }
    }

    static func syncState(_ state: MeshDeviceSync.State) -> String {
        switch state {
        case .synced: return "Synced"
        case .behind: return "Catching up"
        case .unreachable: return "Waiting"
        }
    }

    static func refusal(_ refusal: MeshAllowance.Refusal) -> String {
        switch refusal {
        case .periodExhausted: return "This device has used its share for today."
        case .effectClassExhausted: return "This kind of action has reached its limit for today."
        case .modelSpendExhausted: return "This device has used its model allowance for today."
        case .soloNeedsConsent:
            return "This device has not heard from your other devices today, so each action outside the mesh needs your approval."
        case .stale: return "This device has not heard from your mesh recently."
        case .stopped: return "The mesh is stopped."
        case .notAMember: return "This device is no longer in the mesh."
        }
    }

    static func share(_ share: MeshAllowance.Share) -> String {
        switch share {
        case .fresh: return "Full share"
        case .solo: return "Solo share"
        }
    }

    static func groupedCode(_ code: String) -> String {
        let digits = Array(code)
        guard digits.count == 8 else { return code }
        return String(digits[0..<4]) + " " + String(digits[4..<8])
    }

    static func runStatus(_ run: MeshRun) -> String {
        switch run.status {
        case .active: return "Running"
        case .paused: return "Paused"
        case .done: return "Done"
        case .stopped: return "Stopped"
        }
    }

    static func runKind(_ kind: MeshRun.Kind) -> String {
        switch kind {
        case .goal: return "Goal"
        case .schedule: return "Schedule"
        case .watch: return "Watch"
        }
    }

    static func runRole(_ run: MeshRun, executorLabel: String?) -> String {
        switch run.role {
        case .executor: return "Running on this device"
        case .watcher: return "Running on " + (executorLabel ?? "another device")
        case .contested: return "Two devices claim this run"
        case .unassigned: return "No device is running it"
        }
    }

    static func proposalStatus(_ status: MeshProposal.Status) -> String {
        switch status {
        case .staged: return "New"
        case .gated: return "Checked"
        case .replayed: return "Tested"
        case .waitingOwner: return "Needs your review"
        case .rejected: return "Rejected"
        case .declined: return "Declined"
        case .adopted: return "In use"
        case .reversed: return "Undone"
        }
    }

    static func evaluation(_ value: MeshEvaluation) -> String {
        switch value {
        case .adopted: return "Adopted."
        case .waitingOwner: return "Still waiting for your review."
        case .declined(let reason): return "Declined: " + reason + "."
        }
    }
}
