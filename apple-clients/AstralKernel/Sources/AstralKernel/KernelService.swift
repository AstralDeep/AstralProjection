// A thin Swift API over the generated kernel bindings: it opens a kernel with host custody callbacks and republishes its change events as an AsyncStream.
// App code imports this module and never touches the generated bindings directly.
@_exported import AstralKernelBindings
import Foundation

public enum AstralKernelInfo {
    public static var version: String { kernelVersion() }
}

public enum KernelNetworking {
    public static let loopback = NetworkConfig(
        relay: .disabled, localDiscovery: false, internetLookup: false, loopbackOnly: true,
        syncIntervalMs: 500, mailbox: nil)
}

public final class KernelService: @unchecked Sendable {
    public let kernel: Kernel
    private let relay: ChangeRelay

    public init(
        config: KernelConfig, signer: HostSigner, model: OnDeviceModel? = nil, tools: LocalTools? = nil,
        listener: KernelListener? = nil
    ) throws {
        relay = ChangeRelay(forwarding: listener)
        kernel = try Kernel.open(config: config, signer: signer, model: model, tools: tools, listener: relay)
    }

    public var version: String { kernel.version() }

    public func changes() -> AsyncStream<KernelChange> { relay.stream() }
}

private final class ChangeRelay: KernelListener, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<KernelChange>.Continuation] = [:]
    private let forwarding: KernelListener?

    init(forwarding: KernelListener?) { self.forwarding = forwarding }

    func onChange(change: KernelChange) {
        let targets = lock.withLock { Array(continuations.values) }
        for continuation in targets { continuation.yield(change) }
        forwarding?.onChange(change: change)
    }

    func stream() -> AsyncStream<KernelChange> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.continuations[id] = nil }
            }
        }
    }
}
