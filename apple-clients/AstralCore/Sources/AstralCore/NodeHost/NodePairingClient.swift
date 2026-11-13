// Talks to the local node over loopback: it reads the public descriptor and asks the node for a mesh pairing offer with the owner's bearer token.
// NodeHostController passes the offer's payload to the mesh runtime's existing add-a-device approval, so the node joins like any other device.

#if os(macOS)
    import CryptoKit
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

        public let nodeId: String
        public let capabilities: [String]
        public let mesh: Mesh?

        public var canJoinMesh: Bool { capabilities.contains("mesh-peer") }

        enum CodingKeys: String, CodingKey {
            case capabilities, mesh
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
        case unauthorized
        case refused(status: Int, detail: String)
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
            return descriptor
        }

        public func pairingOffer(bearer: String, label: String, ttlSeconds: Int = 300) async throws -> NodePairingResult {
            var request = URLRequest(url: base.appendingPathComponent("api/node/pairing"))
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let placeholderKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
            let body: [String: Any] = [
                "label": label,
                "device_key": ["kty": "OKP", "crv": "Ed25519", "x": Self.base64URL(placeholderKey)],
                "scopes": [String](),
                "ttl_seconds": ttlSeconds,
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, status) = try await http.send(request)
            guard data.count <= Self.maximumResponseBytes else { throw NodePairingError.unexpectedResponse }
            switch status {
            case 200...299: break
            case 401: throw NodePairingError.unauthorized
            default:
                let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
                throw NodePairingError.refused(status: status, detail: String((detail ?? "").prefix(120)))
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let mesh = object["mesh"] as? [String: Any], let state = mesh["state"] as? String
            else { throw NodePairingError.unexpectedResponse }
            if state == "offer" {
                guard let code = mesh["code"] as? String, let payload = mesh["payload"] as? String,
                    !payload.isEmpty
                else { throw NodePairingError.unexpectedResponse }
                return .offer(
                    NodePairingOffer(code: code, payload: payload, expiresMs: (mesh["expires_ms"] as? NSNumber)?.int64Value))
            }
            if let error = mesh["error"] as? String { throw NodePairingError.meshUnavailable(error) }
            return .alreadyJoined(meshId: mesh["mesh_id"] as? String)
        }

        static func base64URL(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
    }
#endif
