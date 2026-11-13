// Exercises the node pack installer against real archives: the descriptor checks, every digest gate, tampered trees, unpacking safety, previous-install preservation and removal.

#if os(macOS)
    import XCTest

    @testable import AstralCore

    final class NodePackInstallerTests: XCTestCase {
        private var root: URL!

        override func setUpWithError() throws { root = try NodePackTestSupport.temporaryDirectory() }
        override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

        private func installer(
            transport: FileTransport = FileTransport(), pin: String? = nil, space: Int64 = .max
        ) -> NodePackInstaller {
            NodePackInstaller(root: root, transport: transport, pinnedDescriptorSha256: pin, availableSpace: { _ in space })
        }

        func testInstallsAVerifiedPackAndRecordsIt() async throws {
            let built = try NodePackTestSupport.build()
            let subject = installer()
            let offer = try await subject.fetchOffer(from: built.descriptorURL)
            XCTAssertEqual(offer.archiveURL.lastPathComponent, "pack.tar.gz")
            XCTAssertTrue(offer.sizeDescription.contains("to download"))
            let log = ProgressLog()
            let result = try await subject.install(offer) { log.add($0) }
            XCTAssertEqual(result.version, "3.11.18-test")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: result.root.appendingPathComponent("python/bin/python3.11").path))
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: result.root.appendingPathComponent("python/bin/python").path),
                "python3.11")
            let installed = await subject.installed()
            XCTAssertEqual(installed?.version, result.version)
            try await subject.verify(result)
            XCTAssertTrue(log.values.contains(.verifying) && log.values.contains(.unpacking) && log.values.last == .done)
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("staging") }
            XCTAssertTrue(leftovers.isEmpty)
        }

        func testACorruptedDownloadIsRefusedAndNothingIsInstalled() async throws {
            let built = try NodePackTestSupport.build()
            let subject = installer(transport: FileTransport(corruptDownload: true))
            let offer = try await subject.fetchOffer(from: built.descriptorURL)
            do {
                _ = try await subject.install(offer) { _ in }
                XCTFail("expected a digest failure")
            } catch { XCTAssertEqual(error as? NodePackError, .digestMismatch("archive")) }
            let installed = await subject.installed()
            XCTAssertNil(installed)
        }

        func testAWrongSizeIsRefusedBeforeHashing() async throws {
            let built = try NodePackTestSupport.build()
            let descriptor = NodePackDescriptor(
                version: built.descriptor.version,
                archive: .init(file: "pack.tar.gz", size: built.descriptor.archive.size + 1, sha256: built.descriptor.archive.sha256),
                installedBytes: built.descriptor.installedBytes, manifestSha256: built.descriptor.manifestSha256)
            try JSONEncoder().encode(descriptor).write(to: built.descriptorURL)
            let subject = installer()
            let offer = try await subject.fetchOffer(from: built.descriptorURL)
            do {
                _ = try await subject.install(offer) { _ in }
                XCTFail("expected a size failure")
            } catch { XCTAssertEqual(error as? NodePackError, .sizeMismatch(expected: built.descriptor.archive.size + 1, actual: built.descriptor.archive.size)) }
        }

        func testADownloadFailureIsReported() async throws {
            let built = try NodePackTestSupport.build()
            let subject = installer(transport: FileTransport(failDownload: true))
            let offer = try await subject.fetchOffer(from: built.descriptorURL)
            do {
                _ = try await subject.install(offer) { _ in }
                XCTFail("expected a download failure")
            } catch { XCTAssertEqual(error as? NodePackError, .downloadFailed("offline")) }
        }

        func testAManifestThatDiffersFromTheDescriptorDigestIsRefused() async throws {
            let built = try NodePackTestSupport.build()
            let forged = NodePackDescriptor(
                version: built.descriptor.version, archive: built.descriptor.archive, installedBytes: built.descriptor.installedBytes,
                manifestSha256: String(repeating: "a", count: 64))
            try JSONEncoder().encode(forged).write(to: built.descriptorURL)
            let subject = installer()
            let offer = try await subject.fetchOffer(from: built.descriptorURL)
            do {
                _ = try await subject.install(offer) { _ in }
                XCTFail("expected a manifest failure")
            } catch { XCTAssertEqual(error as? NodePackError, .digestMismatch("manifest")) }
        }

        func testATreeThatDoesNotMatchItsManifestIsRefused() async throws {
            let built = try NodePackTestSupport.build { tree in
                try Data("tampered".utf8).write(to: tree.appendingPathComponent("app/backend/orchestrator/orchestrator.py"))
                try Data("extra".utf8).write(to: tree.appendingPathComponent("app/backend/extra.py"))
                try FileManager.default.removeItem(at: tree.appendingPathComponent("launcher/astral_node_launch.py"))
            }
            let subject = installer()
            let offer = try await subject.fetchOffer(from: built.descriptorURL)
            do {
                _ = try await subject.install(offer) { _ in }
                XCTFail("expected a tree failure")
            } catch {
                guard case .treeMismatch(let problems)? = error as? NodePackError else { return XCTFail("\(error)") }
                XCTAssertTrue(problems.contains("content changed app/backend/orchestrator/orchestrator.py"))
                XCTAssertTrue(problems.contains("unexpected file app/backend/extra.py"))
                XCTAssertTrue(problems.contains("missing file launcher/astral_node_launch.py"))
            }
            let installed = await subject.installed()
            XCTAssertNil(installed)
        }

        func testALinkThatLeavesThePackAndAModeChangeAreRefused() async throws {
            let built = try NodePackTestSupport.build(version: "escape") { tree in
                let link = tree.appendingPathComponent("python/bin/python")
                try FileManager.default.removeItem(at: link)
                try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../../outside")
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o644], ofItemAtPath: tree.appendingPathComponent("python/bin/python3.11").path)
            }
            let subject = installer()
            let offer = try await subject.fetchOffer(from: built.descriptorURL)
            do {
                _ = try await subject.install(offer) { _ in }
                XCTFail("expected a tree failure")
            } catch {
                guard case .treeMismatch(let problems)? = error as? NodePackError else { return XCTFail("\(error)") }
                XCTAssertTrue(problems.contains("link changed python/bin/python"))
                XCTAssertTrue(problems.contains("mode changed python/bin/python3.11"))
            }
        }

        func testAnArchiveEntryThatEscapesTheDestinationIsNotExtractedOutside() async throws {
            let built = try NodePackTestSupport.build()
            let outside = root.appendingPathComponent("evil.txt")
            let work = try NodePackTestSupport.temporaryDirectory()
            let nested = work.appendingPathComponent("a/b")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: work.appendingPathComponent("evil.txt"))
            let archive = built.directory.appendingPathComponent("pack.tar.gz")
            try NodePackTestSupport.tar(nested, to: archive, names: ["../../evil.txt"])
            let data = try Data(contentsOf: archive)
            let descriptor = NodePackDescriptor(
                version: "evil", archive: .init(file: "pack.tar.gz", size: Int64(data.count), sha256: NodePackTestSupport.sha(data)),
                installedBytes: 10, manifestSha256: built.descriptor.manifestSha256)
            try JSONEncoder().encode(descriptor).write(to: built.descriptorURL)
            let subject = installer()
            let offer = try await subject.fetchOffer(from: built.descriptorURL)
            do { _ = try await subject.install(offer) { _ in } } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
            let installed = await subject.installed()
            XCTAssertNil(installed)
        }

        func testDescriptorChecks() async throws {
            let built = try NodePackTestSupport.build()
            let subject = installer()
            let good = built.descriptor
            func write(_ transform: (NodePackDescriptor) -> NodePackDescriptor) throws {
                try JSONEncoder().encode(transform(good)).write(to: built.descriptorURL)
            }
            func offerError() async -> NodePackError? {
                do { _ = try await subject.fetchOffer(from: built.descriptorURL) } catch { return error as? NodePackError }
                return nil
            }
            try write { NodePackDescriptor(format: "other", version: $0.version, archive: $0.archive, installedBytes: $0.installedBytes, manifestSha256: $0.manifestSha256) }
            let wrongFormat = await offerError()
            XCTAssertEqual(wrongFormat, .descriptorInvalid("unrecognized format"))
            try write { NodePackDescriptor(version: $0.version, platform: "linux-arm64", archive: $0.archive, installedBytes: $0.installedBytes, manifestSha256: $0.manifestSha256) }
            let wrongPlatform = await offerError()
            XCTAssertEqual(wrongPlatform, .platformMismatch("linux-arm64"))
            for file in ["../pack.tar.gz", "a/b.tar.gz", "..", ""] {
                try write { NodePackDescriptor(version: $0.version, archive: .init(file: file, size: $0.archive.size, sha256: $0.archive.sha256), installedBytes: $0.installedBytes, manifestSha256: $0.manifestSha256) }
                let badFile = await offerError()
                XCTAssertEqual(badFile, .descriptorInvalid("fields are out of range"), file)
            }
            try write { NodePackDescriptor(version: $0.version, archive: .init(file: "p", size: $0.archive.size, sha256: "XYZ"), installedBytes: $0.installedBytes, manifestSha256: $0.manifestSha256) }
            let badDigest = await offerError()
            XCTAssertEqual(badDigest, .descriptorInvalid("fields are out of range"))
            try write { NodePackDescriptor(version: "../x y", archive: $0.archive, installedBytes: $0.installedBytes, manifestSha256: $0.manifestSha256) }
            let badVersion = await offerError()
            XCTAssertEqual(badVersion, .descriptorInvalid("fields are out of range"))
            try Data("not json".utf8).write(to: built.descriptorURL)
            let notJSON = await offerError()
            XCTAssertEqual(notJSON, .descriptorInvalid("unrecognized format"))
        }

        func testDescriptorPinAndURLPolicy() async throws {
            let built = try NodePackTestSupport.build()
            let pinned = installer(pin: String(repeating: "0", count: 64))
            do {
                _ = try await pinned.fetchOffer(from: built.descriptorURL)
                XCTFail("expected a pin failure")
            } catch { XCTAssertEqual(error as? NodePackError, .descriptorPinMismatch) }
            let digest = NodePackTestSupport.sha(try Data(contentsOf: built.descriptorURL))
            let matching = installer(pin: digest.uppercased())
            _ = try await matching.fetchOffer(from: built.descriptorURL)
            for text in ["http://example.com/node-pack.json", "ftp://example.com/x", "javascript:alert(1)", "https:///x"] {
                do {
                    _ = try await matching.fetchOffer(from: URL(string: text)!)
                    XCTFail("expected \(text) to be refused")
                } catch { XCTAssertEqual(error as? NodePackError, .unsupportedURL(text)) }
            }
            XCTAssertTrue(NodePackURLPolicy.permits(URL(string: "https://releases.example.com/p.json")!))
            XCTAssertTrue(NodePackURLPolicy.permits(URL(string: "http://127.0.0.1:8000/p.json")!))
            XCTAssertTrue(NodePackURLPolicy.permits(URL(string: "http://localhost/p.json")!))
            XCTAssertTrue(NodePackURLPolicy.permits(URL(string: "http://[::1]:9/p.json")!))
            XCTAssertFalse(NodePackURLPolicy.permits(URL(string: "http://127.0.0.1.example.com/p.json")!))
        }

        func testInsufficientSpaceStopsBeforeDownloading() async throws {
            let built = try NodePackTestSupport.build()
            let subject = installer(space: 1_000)
            let offer = try await subject.fetchOffer(from: built.descriptorURL)
            do {
                _ = try await subject.install(offer) { _ in }
                XCTFail("expected a space failure")
            } catch {
                guard case .insufficientSpace(_, let available)? = error as? NodePackError else { return XCTFail("\(error)") }
                XCTAssertEqual(available, 1_000)
            }
        }

        func testAFailedUpgradeKeepsThePreviousInstallationAndASuccessfulOneReplacesIt() async throws {
            let first = try NodePackTestSupport.build(version: "one")
            let subject = installer()
            _ = try await subject.install(try await subject.fetchOffer(from: first.descriptorURL)) { _ in }
            let broken = try NodePackTestSupport.build(version: "two") { tree in
                try Data("x".utf8).write(to: tree.appendingPathComponent("stray"))
            }
            do {
                _ = try await subject.install(try await subject.fetchOffer(from: broken.descriptorURL)) { _ in }
                XCTFail("expected a failure")
            } catch {}
            let kept = await subject.installed()
            XCTAssertEqual(kept?.version, "one")
            let second = try NodePackTestSupport.build(version: "two")
            _ = try await subject.install(try await subject.fetchOffer(from: second.descriptorURL)) { _ in }
            let current = await subject.installed()
            XCTAssertEqual(current?.version, "two")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("packs").path), ["two"])
        }

        func testVerifyDetectsLaterTamperingAndRemoveForgetsThePack() async throws {
            let built = try NodePackTestSupport.build()
            let subject = installer()
            let installed = try await subject.install(try await subject.fetchOffer(from: built.descriptorURL)) { _ in }
            try Data("changed".utf8).write(to: installed.root.appendingPathComponent("app/backend/orchestrator/orchestrator.py"))
            do {
                try await subject.verify(installed)
                XCTFail("expected tampering to be found")
            } catch { XCTAssertEqual(error as? NodePackError, .treeMismatch(["content changed app/backend/orchestrator/orchestrator.py"])) }
            try Data("changed".utf8).write(to: installed.root.appendingPathComponent("manifest.json"))
            do {
                try await subject.verify(installed)
                XCTFail("expected the manifest digest to fail")
            } catch { XCTAssertEqual(error as? NodePackError, .digestMismatch("manifest")) }
            try await subject.remove()
            let removed = await subject.installed()
            XCTAssertNil(removed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: installed.root.path))
        }

        func testLinkEscapeRules() {
            XCTAssertTrue(NodePackTree.linkEscapes(path: "a/b", target: "/etc/passwd"))
            XCTAssertTrue(NodePackTree.linkEscapes(path: "a/b", target: "../../x"))
            XCTAssertFalse(NodePackTree.linkEscapes(path: "a/b", target: "../x"))
            XCTAssertFalse(NodePackTree.linkEscapes(path: "python/bin/python", target: "python3.11"))
        }

        func testTheURLSessionTransportReadsAndDownloadsFilesAndRefusesOtherSchemes() async throws {
            let built = try NodePackTestSupport.build()
            let transport = URLSessionNodePackTransport()
            let data = try await transport.data(from: built.descriptorURL, maxBytes: 4096)
            XCTAssertFalse(data.isEmpty)
            do {
                _ = try await transport.data(from: built.descriptorURL, maxBytes: 4)
                XCTFail("expected a size refusal")
            } catch { XCTAssertEqual(error as? NodePackError, .downloadFailed("response is larger than 4 bytes")) }
            let destination = root.appendingPathComponent("copy.tar.gz")
            let received = ProgressLog()
            try await transport.download(from: built.directory.appendingPathComponent("pack.tar.gz"), to: destination) { got, _ in
                received.add(.downloading(received: got, expected: 0))
            }
            XCTAssertEqual(try Data(contentsOf: destination).count, Int(built.descriptor.archive.size))
            do {
                try await transport.download(from: URL(string: "ftp://example.com/x")!, to: destination) { _, _ in }
                XCTFail("expected a refusal")
            } catch { XCTAssertEqual(error as? NodePackError, .unsupportedURL("ftp://example.com/x")) }
            let missing = built.directory.appendingPathComponent("missing.tar.gz")
            do {
                try await transport.download(from: missing, to: destination) { _, _ in }
                XCTFail("expected a failure")
            } catch {}
        }
    }
#endif
