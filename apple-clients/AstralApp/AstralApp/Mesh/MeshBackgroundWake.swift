// Admits content-free wake hints for an existing mesh and completes each OS callback once within a cancellable budget.
// The iOS delegate supplies protected-data and mode checks; the runtime requests sync without opening custody or authenticating.

import CoreFoundation
import Foundation

@MainActor
final class MeshBackgroundWake {
    enum Result: Equatable { case newData, noData, failed }

    private final class Delivery {
        let completion: (Result) -> Void
        var work: Task<Void, Never>?
        var budget: Task<Void, Never>?
        var finished = false

        init(completion: @escaping (Result) -> Void) { self.completion = completion }

        func finish(_ result: Result) {
            guard !finished else { return }
            finished = true
            work?.cancel()
            budget?.cancel()
            work = nil
            budget = nil
            completion(result)
        }
    }

    static weak var active: MeshBackgroundWake?
    private let authorized: () -> Bool
    private let synchronize: () async throws -> Bool
    private let waitBudget: () async throws -> Void
    private var delivery: Delivery?

    init(
        authorized: @escaping () -> Bool, synchronize: @escaping () async throws -> Bool,
        waitBudget: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(20)) }
    ) {
        self.authorized = authorized
        self.synchronize = synchronize
        self.waitBudget = waitBudget
    }

    static func accepts(_ payload: [AnyHashable: Any]) -> Bool {
        let metadata: Set<String> = ["apns-id", "apns-collapse-id", "apns-expiration", "apns-priority", "apns-topic"]
        guard let aps = payload["aps"] as? [String: Any], Set(aps.keys) == ["content-available"],
            let value = aps["content-available"] as? NSNumber,
            CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue == 1
        else { return false }
        return payload.allSatisfy { key, value in
            guard let name = key as? String else { return false }
            return name == "aps" || (metadata.contains(name) && (value as? String).map { $0.utf8.count <= 256 } == true)
        }
    }

    @discardableResult
    func receive(_ payload: [AnyHashable: Any], completion: @escaping (Result) -> Void) -> Task<Void, Never>? {
        guard Self.accepts(payload), authorized(), delivery == nil else {
            completion(.noData)
            return nil
        }
        let current = Delivery(completion: completion)
        delivery = current
        let work = Task { [weak self, current] in
            guard let self else { current.finish(.noData); return }
            let result: Result
            do {
                let changed = try await synchronize()
                result = authorized() && !Task.isCancelled ? (changed ? .newData : .noData) : .noData
            } catch is CancellationError {
                result = .noData
            } catch {
                result = authorized() ? .failed : .noData
            }
            complete(current, result: result)
        }
        current.work = work
        current.budget = Task { [weak self, current] in
            guard let self else { return }
            do { try await waitBudget() } catch { return }
            complete(current, result: .noData)
        }
        return work
    }

    func cancel() {
        guard let delivery else { return }
        complete(delivery, result: .noData)
    }

    private func complete(_ current: Delivery, result: Result) {
        if delivery === current { delivery = nil }
        current.finish(result)
    }
}
