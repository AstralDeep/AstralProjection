import Foundation
import Network
import XCTest

@testable import AstralCore

final class CanvasExportTransportTests: XCTestCase {
    func testRealSlowDripCannotExtendPresentationResourceDeadline() async throws {
        let server = try CanvasExportDripServer()
        defer { server.stop() }
        server.start()
        await fulfillment(of: [server.ready], timeout: 3)
        let port = try XCTUnwrap(server.listener.port)
        let url = URL(string: "http://127.0.0.1:\(port.rawValue)/presentation")!
        let configuration = NoStoreHTTP.configuration()
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 0.4
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let start = ContinuousClock.now
        do {
            _ = try await CanvasExportPolicy.response(NoStoreHTTP.request(url: url), session: session)
            XCTFail("A peer sending bytes forever cannot retain the capture")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        XCTAssertEqual(server.requestCount, 1)
    }

    func testRealStreamingPresentationCancelsWithoutWaitingForMoreBytes() async throws {
        let server = try CanvasExportDripServer()
        defer { server.stop() }
        server.start()
        await fulfillment(of: [server.ready], timeout: 3)
        let port = try XCTUnwrap(server.listener.port)
        let url = URL(string: "http://127.0.0.1:\(port.rawValue)/presentation")!
        let session = URLSession(configuration: NoStoreHTTP.configuration())
        defer { session.invalidateAndCancel() }
        let task = Task { try await CanvasExportPolicy.response(NoStoreHTTP.request(url: url), session: session) }
        await fulfillment(of: [server.startedBody], timeout: 3)
        let start = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled response")
        } catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        XCTAssertEqual(server.requestCount, 1)
    }

    func testRealAuthorizationDownloadHasTheSameTotalDeadlineAndRemovesPartialFile() async throws {
        let server = try CanvasExportDripServer()
        defer { server.stop() }
        server.start()
        await fulfillment(of: [server.ready], timeout: 3)
        let port = try XCTUnwrap(server.listener.port)
        let base = URL(string: "http://127.0.0.1:\(port.rawValue)")!
        let configuration = NoStoreHTTP.configuration()
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 0.4
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("astral-downloads")
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? [])
        let client = RestClient(serverBase: base, tokenProvider: { "synthetic" }, downloadSession: session)
        do {
            _ = try await client.downloadFile(from: "/canvas.html", expectedRenderRevision: 7)
            XCTFail("A peer cannot retain a partial private export indefinitely")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? [])
        XCTAssertEqual(after, before)
        XCTAssertEqual(server.requestCount, 1)
    }
}

/// A real loopback HTTP peer keeps the idle timeout alive with small chunks.
/// No external listener, user credential, file or application is involved.
private final class CanvasExportDripServer: @unchecked Sendable {
    let ready = XCTestExpectation(description: "loopback listener ready")
    let startedBody = XCTestExpectation(description: "response body started")
    let listener: NWListener
    private let queue = DispatchQueue(label: "astral.export.deadline-test")
    private var connections: [NWConnection] = []
    private var timers: [DispatchSourceTimer] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    var requestCount: Int { queue.sync { connections.count } }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.ready.fulfill() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] _, _, _, _ in
                guard let self else { return }
                let header =
                    "HTTP/1.1 200 OK\r\nContent-Length: 100000\r\nX-Astral-Render-Revision: 7\r\nConnection: close\r\n\r\n"
                connection.send(
                    content: Data(header.utf8),
                    completion: .contentProcessed { [weak self] error in
                        guard let self, error == nil else { return }
                        self.startedBody.fulfill()
                        let timer = DispatchSource.makeTimerSource(queue: self.queue)
                        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
                        timer.setEventHandler { [weak connection] in
                            connection?.send(content: Data([65]), completion: .idempotent)
                        }
                        self.timers.append(timer)
                        timer.resume()
                    })
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.sync {
            for timer in timers { timer.cancel() }
            for connection in connections { connection.cancel() }
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
        }
    }
}
