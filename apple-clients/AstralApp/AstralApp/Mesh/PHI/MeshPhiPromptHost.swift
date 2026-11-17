// Answers the Kernel's uncertain-match question by showing one host-drawn sheet and waiting for a tap, and answers treat-as-PHI whenever no one can answer.
// MeshPhiPromptCenter holds the one pending question for the sheet, and MeshKernelFactories installs the host on the Kernel at open.

import Foundation
import Observation

nonisolated struct MeshPhiPromptRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let question: MeshPhiQuestion
}

@MainActor
@Observable
final class MeshPhiPromptCenter {
    private(set) var pending: MeshPhiPromptRequest?
    private(set) var isForeground = false
    @ObservationIgnored private var resolve: (@Sendable (MeshPhiAnswer) -> Void)?

    var canShow: Bool { isForeground && pending == nil }

    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        if !foreground { answer(.treatAsPhi) }
    }

    func present(
        _ question: MeshPhiQuestion, id: UUID, resolve: @escaping @Sendable (MeshPhiAnswer) -> Void
    ) -> Bool {
        guard canShow else { return false }
        pending = MeshPhiPromptRequest(id: id, question: question)
        self.resolve = resolve
        return true
    }

    func answer(_ value: MeshPhiAnswer) {
        guard pending != nil else { return }
        let finish = resolve
        pending = nil
        resolve = nil
        finish?(value)
    }

    func expire(_ id: UUID) {
        guard pending?.id == id else { return }
        answer(.treatAsPhi)
    }
}

nonisolated final class MeshPhiPromptHost: MeshPhiPrompting, @unchecked Sendable {
    static let defaultTimeout: DispatchTimeInterval = .seconds(120)

    private final class Slot: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var value: MeshPhiAnswer?

        func set(_ answer: MeshPhiAnswer) {
            let first = lock.withLock { () -> Bool in
                guard value == nil else { return false }
                value = answer
                return true
            }
            if first { semaphore.signal() }
        }

        func wait(_ timeout: DispatchTimeInterval) -> MeshPhiAnswer {
            if semaphore.wait(timeout: .now() + timeout) == .timedOut { set(.treatAsPhi) }
            return lock.withLock { value ?? .treatAsPhi }
        }
    }

    private let center: MeshPhiPromptCenter
    private let timeout: DispatchTimeInterval

    init(center: MeshPhiPromptCenter, timeout: DispatchTimeInterval = MeshPhiPromptHost.defaultTimeout) {
        self.center = center
        self.timeout = timeout
    }

    func ask(_ question: MeshPhiQuestion) -> MeshPhiAnswer {
        guard !Thread.isMainThread, !question.items.isEmpty else { return .treatAsPhi }
        let slot = Slot()
        let id = UUID()
        let center = center
        Task { @MainActor in
            if !center.present(question, id: id, resolve: { slot.set($0) }) { slot.set(.treatAsPhi) }
        }
        let answer = slot.wait(timeout)
        Task { @MainActor in center.expire(id) }
        return answer
    }
}
