// A thin Swift API over the generated kernel bindings: it opens a kernel in a data directory, signs and verifies event headers, and exposes endpoint state changes as an AsyncStream.
// App code imports this module and never touches the generated bindings directly.
@_exported import AstralKernelBindings
import Foundation

public enum AstralKernelInfo {
    public static var version: String { kernelVersion() }
}

public final class KernelService: @unchecked Sendable {
    private let kernel: Kernel
    private let relay: StateRelay

    public init(dataDirectory: URL, localOnly: Bool = false) throws {
        let path = dataDirectory.path
        kernel = localOnly ? try Kernel.localOnly(dataDir: path) : try Kernel(dataDir: path)
        relay = StateRelay()
        kernel.setListener(listener: relay)
    }

    public var version: String { kernel.version() }

    public func openStore() throws -> StoreInfo { try kernel.openStore() }

    public func newOperationsSecret() throws -> Data { try kernel.newOperationsSecret() }

    public func operationsPublicKey(secret: Data) throws -> String {
        try kernel.operationsPublicKey(secret: secret)
    }

    public func signEventHeader(json: String, secret: Data) throws -> String {
        try kernel.signEventHeader(headerJson: json, secret: secret)
    }

    public func verifyEventHeader(json: String) throws -> VerifiedEvent {
        try kernel.verifyEventHeader(signedJson: json)
    }

    public func startEndpoint() async throws -> String { try await kernel.startEndpoint() }

    public func endpointAddress() async throws -> String { try await kernel.endpointAddress() }

    public func stopEndpoint() async { await kernel.stopEndpoint() }

    public func endpointStates() -> AsyncStream<EndpointState> { relay.stream() }
}

private final class StateRelay: KernelListener, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<EndpointState>.Continuation] = [:]

    func onEndpointState(state: EndpointState) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets { continuation.yield(state) }
    }

    func stream() -> AsyncStream<EndpointState> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }
}
