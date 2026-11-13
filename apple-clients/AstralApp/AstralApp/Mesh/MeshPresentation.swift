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

    static func icon(_ kind: MeshDeviceKind) -> String {
        switch kind {
        case .desktop: return "desktopcomputer"
        case .pocket: return "iphone"
        case .satellite: return "applewatch"
        case .node: return "server.rack"
        }
    }

    static func connection(_ path: MeshPath) -> String {
        switch path {
        case .direct: return "on this network"
        case .relay: return "through a relay"
        case .mailbox: return "through the mailbox"
        case .none: return "not connected"
        }
    }

    static func deviceStatus(
        _ member: MeshMember, sync: MeshDeviceSync?, now: Date = Date(), calendar: Calendar = .current
    ) -> String {
        if member.isThisDevice { return member.attested ? "Verified" : "Needs sign-in to verify" }
        if !member.attested { return "Needs sign-in to verify" }
        let seen = sync?.lastSeen ?? member.lastSeen
        let path = sync?.path ?? member.path
        switch sync?.state {
        case .synced:
            return "Synced " + ago(seen, now: now) + " · " + connection(path)
        case .behind:
            return "Catching up · " + connection(path)
        case .unreachable, nil:
            guard let seen else { return "Not seen yet" }
            return "Waiting since " + clock(seen, now: now, calendar: calendar)
        }
    }

    static func clock(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return time }
        return date.formatted(.dateTime.month(.abbreviated).day()) + ", " + time
    }

    private static func ago(_ date: Date?, now: Date) -> String {
        guard let date, now.timeIntervalSince(date) >= 45 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
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

    static func toolTitle(_ tool: MeshToolEntry) -> String {
        if tool.deviceId == nil, let title = tool.annotations.title { return title }
        let words = tool.name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
        return tool.deviceId == nil ? words.prefix(1).uppercased() + words.dropFirst() : tool.name
    }

    static func toolEffect(_ tool: MeshToolEntry) -> String {
        switch tool.effect {
        case .meshRead: return "Reads only. Stays on your mesh."
        case .meshWrite: return "Can change things on your mesh."
        case .outwardRead: return "Reads from outside your mesh."
        case .outsideEffect: return "Can make changes outside your mesh."
        }
    }

    static func toolNote(_ tool: MeshToolEntry) -> String? {
        tool.deviceId == nil ? tool.annotations.note : nil
    }

    static func countdown(until date: Date, now: Date) -> String? {
        let seconds = Int(date.timeIntervalSince(now).rounded(.up))
        guard seconds > 0 else { return nil }
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }

    static func invitationCode(_ code: String) -> String {
        let clean = code.filter { !$0.isWhitespace && $0 != "-" }
        guard clean.count == 8 else { return code }
        return String(clean.prefix(4)) + " " + String(clean.suffix(4))
    }

    static func verificationAge(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Not verified" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Verified " + formatter.localizedString(for: date, relativeTo: now)
    }

    static func added(_ date: Date?) -> String {
        guard let date else { return "Unknown" }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func groupedCode(_ code: String) -> String {
        let digits = Array(code)
        guard digits.count == 8 else { return code }
        return String(digits[0..<4]) + " " + String(digits[4..<8])
    }

    static func codeGroups(_ code: String) -> [String] {
        let digits = code.filter { !$0.isWhitespace }
        guard digits.count == 8 else { return [String(code)] }
        return [String(digits.prefix(4)), String(digits.suffix(4))]
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

    static func requestState(_ state: MeshRequestState) -> String {
        switch state {
        case .pending: return "Waiting for the device"
        case .claimed: return "Being answered"
        case .answered: return "Answered"
        case .refused: return "Refused"
        case .cancelled: return "Cancelled"
        }
    }

    static func requestRefusal(_ code: String?) -> String {
        guard let code else { return "Refused" }
        if let known = MeshRequestRefusal(rawValue: code) { return "Refused: " + known.reason }
        return "Refused (" + code + ")"
    }

    static func mailbox(_ state: MeshMailboxState, now: Date = Date()) -> String {
        guard state.configured else { return "No mailbox is set." }
        switch state.status {
        case .disabled: return "No mailbox is set."
        case .idle: return "Set. Waiting for the first exchange."
        case .ok: return "Working. " + lastExchange(state.lastOk, now: now)
        case .waiting: return "Waiting for the mailbox to answer."
        case .removed: return "The mailbox no longer accepts this device."
        case .unreachable: return "The mailbox cannot be reached right now."
        case .error: return "The mailbox refused the exchange" + (state.lastError.map { " (" + $0 + ")." } ?? ".")
        case .unknown: return "The mailbox state is not known."
        }
    }

    private static func lastExchange(_ date: Date?, now: Date) -> String {
        guard let date else { return "No exchange yet." }
        if now.timeIntervalSince(date) < 45 { return "Last exchange just now." }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last exchange " + formatter.localizedString(for: date, relativeTo: now) + "."
    }
}
