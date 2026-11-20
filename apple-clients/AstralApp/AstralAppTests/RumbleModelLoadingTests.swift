// Covers the real VoiceModelOwner loaders against tiny temporary files and a test manifest: a missing file, a wrong digest, an unsupported device and the configuration each device class loads with.
// The runtime load itself is replaced by a recording hook, so no model is ever loaded.

import AstralVoiceRuntime
import XCTest

@testable import AstralDeep

private struct HookReached: Error, Equatable {
    let paths: [String]
    let compute: RuntimeConfiguration.Compute
    let contextTokens: Int
}

final class RumbleModelLoadingTests: XCTestCase {
    private var root: URL!
    private let contents = [
        RumbleModelLoading.recognitionPath: "recognition",
        RumbleModelLoading.audioEncoderPath: "encoder",
        RumbleModelLoading.textPath: "text model",
    ]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func install(_ path: String, text: String) throws {
        let url = root.appendingPathComponent("model").appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func manifest() throws -> VoicePackManifest {
        var files: [VoicePackManifest.File] = []
        for (path, text) in contents.sorted(by: { $0.key < $1.key }) {
            try install(path, text: text)
            let digest = try VoiceModelDigest.sha256(
                of: root.appendingPathComponent("model").appendingPathComponent(path))
            files.append(
                VoicePackManifest.File(
                    repository: VoicePackManifest.rumbleRepository, revision: String(repeating: "a", count: 40),
                    path: path,
                    bytes: Int64(text.utf8.count), sha256: digest,
                    part: path.hasPrefix("chat") ? .localText : .recognition))
        }
        return VoicePackManifest(
            displayName: "Test", format: VoicePackManifest.supportedFormat, id: "test",
            origin: VoicePackManifest.origin,
            totalBytes: files.reduce(0) { $0 + $1.bytes }, files: files)
    }

    private func loading(
        _ manifest: VoicePackManifest,
        device: VoiceDeviceProfile = VoiceDeviceProfile(
            platform: .mac, isAppleSilicon: true, isSimulator: false, physicalMemoryBytes: 16 << 30)
    ) -> RumbleModelLoading {
        func relative(_ url: URL) -> String { String(url.path.dropFirst(root.path.count + "/model/".count)) }
        return RumbleModelLoading(
            manifest: manifest, root: root, device: device,
            loadRecognizer: { model, encoder, configuration, _ in
                throw HookReached(
                    paths: [relative(model), relative(encoder)], compute: configuration.compute,
                    contextTokens: configuration.contextTokens)
            },
            loadGenerator: { model, configuration, _ in
                throw HookReached(
                    paths: [relative(model)], compute: configuration.compute, contextTokens: configuration.contextTokens
                )
            })
    }

    func testVerifiedFilesReachTheRuntimeWithTheAcceleratedConfigurationOnADevice() async throws {
        let loading = loading(try manifest())
        do {
            _ = try await loading.loaders.recognizer(RuntimeScheduler())
            XCTFail("the hook should have stopped the load")
        } catch let reached as HookReached {
            XCTAssertEqual(reached.paths, [RumbleModelLoading.recognitionPath, RumbleModelLoading.audioEncoderPath])
            XCTAssertEqual(reached.compute, .automatic)
            XCTAssertEqual(reached.contextTokens, 2_048)
        }
        do {
            _ = try await loading.loaders.generator(RuntimeScheduler())
            XCTFail("the hook should have stopped the load")
        } catch let reached as HookReached {
            XCTAssertEqual(reached.paths, [RumbleModelLoading.textPath])
            XCTAssertEqual(reached.compute, .automatic)
            XCTAssertEqual(reached.contextTokens, 4_096)
        }
    }

    func testTheSimulatorLoadsCPUOnly() async throws {
        let simulator = VoiceDeviceProfile(
            platform: .phone, isAppleSilicon: true, isSimulator: true, physicalMemoryBytes: 16 << 30)
        let loading = loading(try manifest(), device: simulator)
        do {
            _ = try await loading.loaders.generator(RuntimeScheduler())
            XCTFail("the hook should have stopped the load")
        } catch let reached as HookReached {
            XCTAssertEqual(reached.compute, .cpuOnly)
        }
    }

    func testAMissingFileFailsBeforeTheRuntimeIsCalled() async throws {
        let manifest = try manifest()
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("model").appendingPathComponent(RumbleModelLoading.audioEncoderPath))
        do {
            _ = try await loading(manifest).loaders.recognizer(RuntimeScheduler())
            XCTFail("a missing encoder must fail")
        } catch {
            XCTAssertEqual(error as? VoiceModelRuntimeError, .filesMissing(RumbleModelLoading.audioEncoderPath))
        }
    }

    func testAFileWithTheWrongDigestFailsBeforeTheRuntimeIsCalled() async throws {
        let manifest = try manifest()
        try install(RumbleModelLoading.textPath, text: "text modeX")
        do {
            _ = try await loading(manifest).loaders.generator(RuntimeScheduler())
            XCTFail("a changed model must fail")
        } catch {
            XCTAssertEqual(error as? VoiceModelRuntimeError, .digestMismatch(RumbleModelLoading.textPath))
        }
    }

    func testAFileOfTheWrongSizeIsRefused() async throws {
        let manifest = try manifest()
        try install(RumbleModelLoading.textPath, text: "short")
        do {
            _ = try await loading(manifest).loaders.generator(RuntimeScheduler())
            XCTFail("a truncated model must fail")
        } catch {
            XCTAssertEqual(error as? VoiceModelRuntimeError, .digestMismatch(RumbleModelLoading.textPath))
        }
    }

    func testAFileTheManifestDoesNotListIsMissing() async throws {
        let manifest = try manifest()
        let trimmed = VoicePackManifest(
            displayName: manifest.displayName, format: manifest.format, id: manifest.id, origin: manifest.origin,
            totalBytes: manifest.totalBytes, files: manifest.files.filter { $0.path != RumbleModelLoading.textPath })
        do {
            _ = try await loading(trimmed).loaders.generator(RuntimeScheduler())
            XCTFail("an unlisted model must fail")
        } catch {
            XCTAssertEqual(error as? VoiceModelRuntimeError, .filesMissing(RumbleModelLoading.textPath))
        }
    }

    func testADeviceThatCannotRunVoiceNeverLoads() async throws {
        let intel = VoiceDeviceProfile(
            platform: .mac, isAppleSilicon: false, isSimulator: false, physicalMemoryBytes: 16 << 30)
        let smallPhone = VoiceDeviceProfile(
            platform: .phone, isAppleSilicon: true, isSimulator: false, physicalMemoryBytes: 4 << 30)
        for device in [intel, smallPhone] {
            let loading = loading(try manifest(), device: device)
            XCTAssertFalse(loading.isInstalled)
            do {
                _ = try await loading.loaders.recognizer(RuntimeScheduler())
                XCTFail("an unsupported device must not load")
            } catch {
                XCTAssertEqual(error as? VoiceModelRuntimeError, .deviceUnsupported)
            }
        }
    }

    func testNothingIsInstalledWithoutTheInstallMarker() throws {
        XCTAssertFalse(loading(try manifest()).isInstalled)
    }

    func testRuntimeErrorsMapOntoTheAppsVoiceErrors() {
        XCTAssertEqual(VoiceModelRuntimeError(.emptyAudio), .emptyInput)
        XCTAssertEqual(VoiceModelRuntimeError(.audioTooLong(maximumSeconds: 30)), .inputTooLong)
        XCTAssertEqual(VoiceModelRuntimeError(.unsupportedLanguage("x")), .unsupportedLanguage)
        XCTAssertEqual(VoiceModelRuntimeError(.decodeFailed), .needsReload)
        XCTAssertEqual(VoiceModelRuntimeError(.unloaded), .needsReload)
        XCTAssertEqual(VoiceModelRuntimeError(.tokenizationFailed), .failed)
        XCTAssertTrue(VoiceModelRuntimeError.mapping(CancellationError()) is CancellationError)
        XCTAssertEqual(VoiceModelRuntimeError.mapping(CocoaError(.fileReadUnknown)) as? VoiceModelRuntimeError, .failed)
    }
}
