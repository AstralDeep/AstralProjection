// Talks to the local node over loopback: it reads the public v2 descriptor and asks for a mesh pairing offer with the pairing secret from the node's own data directory.
// NodeHostController passes the offer's payload to the mesh runtime's existing add-a-device approval, so the node joins like any other device.

#if os(macOS)
    import Foundation

    public protocol NodeHTTP: Sendable {
        func send(_ request: URLRequest) async throws -> (data: Data, status: Int)
    }

    public struct URLSessionNodeHTTP: NodeHTTP {
        private static let session = URLSession(configuration: .ephemeral)

        public init() {}

        public func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
            let (data, response) = try await Self.session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    public struct NodeDescriptor: Decodable, Equatable, Sendable {
        public struct Mesh: Decodable, Equatable, Sendable {
            public let state: String
            public let meshId: String?
            public let memberId: String?
            public let requests: Bool?

            enum CodingKeys: String, CodingKey {
                case state, requests
                case meshId = "mesh_id"
                case memberId = "member_id"
            }
        }

        public static let format = "astral.node.descriptor/v2"

        public let format: String
        public let nodeId: String
        public let capabilities: [String]
        public let mesh: Mesh?

        public var canJoinMesh: Bool { capabilities.contains("mesh-peer") }

        enum CodingKeys: String, CodingKey {
            case format, capabilities, mesh
            case nodeId = "node_id"
        }
    }

    public struct NodePairingOffer: Equatable, Sendable {
        public let code: String
        public let payload: String
        public let expiresMs: Int64?
    }

    public enum NodePairingResult: Equatable, Sendable {
        case offer(NodePairingOffer)
        case alreadyJoined(meshId: String?)
    }

    public enum NodePairingError: Error, Equatable, Sendable {
        case notLoopback
        case unknownDescriptorFormat
        case pairingSecretUnavailable
        case pairingSecretRequired
        case loopbackRequired
        case ownerMismatch
        case ownerBindingUnavailable
        case profileInactive
        case rateLimited
        case refused(status: Int, code: String)
        case unexpectedResponse
        case meshUnavailable(String)
    }

    public struct NodePairingClient: Sendable {
        public static let maximumResponseBytes = 256 * 1024
        private let base: URL
        private let http: NodeHTTP

        public init(port: Int, http: NodeHTTP = URLSessionNodeHTTP()) throws {
            guard let base = URL(string: "http://127.0.0.1:\(port)"), (1...65_535).contains(port) else {
                throw NodePairingError.notLoopback
            }
            self.base = base
            self.http = http
        }

        public func descriptor() async throws -> NodeDescriptor {
            var request = URLRequest(url: base.appendingPathComponent("api/node/descriptor"))
            request.timeoutInterval = 5
            let (data, status) = try await http.send(request)
            guard status == 200, data.count <= Self.maximumResponseBytes,
                let descriptor = try? JSONDecoder().decode(NodeDescriptor.self, from: data)
            else { throw NodePairingError.unexpectedResponse }
            guard descriptor.format == NodeDescriptor.format else { throw NodePairingError.unknownDescriptorFormat }
            return descriptor
        }

        public func pairingOffer(secret: String) async throws -> NodePairingResult {
            var request = URLRequest(url: base.appendingPathComponent("api/node/mesh/offer"))
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue(secret, forHTTPHeaderField: "Astral-Pairing-Secret")
            let (data, status) = try await http.send(request)
            guard data.count <= Self.maximumResponseBytes else { throw NodePairingError.unexpectedResponse }
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard (200...299).contains(status) else { throw Self.refusal(status: status, body: object) }
            guard let state = object?["state"] as? String else { throw NodePairingError.unexpectedResponse }
            switch state {
            case "offer":
                guard let code = object?["code"] as? String, let payload = object?["payload"] as? String,
                    !payload.isEmpty
                else { throw NodePairingError.unexpectedResponse }
                return .offer(
                    NodePairingOffer(
                        code: code, payload: payload, expiresMs: (object?["expires_ms"] as? NSNumber)?.int64Value))
            case "enrolled":
                return .alreadyJoined(meshId: object?["mesh_id"] as? String)
            default:
                throw NodePairingError.unexpectedResponse
            }
        }

        private static func refusal(status: Int, body: [String: Any]?) -> NodePairingError {
            let code = String(((body?["detail"] as? String) ?? "").prefix(80))
            switch code {
            case "node.loopback_required": return .loopbackRequired
            case "node.pairing_secret_required": return .pairingSecretRequired
            case "node.owner_mismatch": return .ownerMismatch
            case "node.owner_binding_unavailable": return .ownerBindingUnavailable
            case "node_profile_inactive": return .profileInactive
            case "node.pairing_rate_limited": return .rateLimited
            case "mesh_unavailable": return .meshUnavailable(code)
            default: return .refused(status: status, code: code)
            }
        }
    }
#endif
