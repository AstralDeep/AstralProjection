// Verifies that speech model downloads show their size first and start only after the owner confirms that exact offer.
// A scripted provider stands in for the system asset inventory.

import XCTest

@testable import AstralDeep

private final class FakeAssetProvider: VoiceModelAssetProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var current: VoiceModelAssetStatus
    private var downloads = 0
    var fails = false

    init(_ status: VoiceModelAssetStatus) { current = status }

    var downloadCount: Int { lock.withLock { downloads } }

    func status() async -> VoiceModelAssetStatus { lock.withLock { current } }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        lock.withLock { downloads += 1 }
        if fails { throw VoiceTranscriberError.assetsNotInstalled }
        progress(0.5)
        lock.withLock { current = .ready }
    }
}

@MainActor
final class OnDeviceModelAssetsTests: XCTestCase {
    private let offer = VoiceModelDownloadOffer(identifier: "speech_en", displayName: "Speech", sizeBytes: 150_000_000)

    func testOfferShowsItsSizeAndAnUnknownSizeHonestly() {
        XCTAssertTrue(offer.sizeDescription.contains("MB"))
        let unknown = VoiceModelDownloadOffer(identifier: "x", displayName: "X", sizeBytes: nil)
        XCTAssertEqual(unknown.sizeDescription, "Size not reported by the system")
    }

    func testDownloadNeverStartsWithoutConfirmation() async {
        let provider = FakeAssetProvider(.downloadRequired(offer))
        let coordinator = VoiceModelDownloadCoordinator(provider: provider)
        await coordinator.refresh()
        XCTAssertEqual(coordinator.state, .offered(offer))
        await coordinator.download()
        XCTAssertEqual(provider.downloadCount, 0)
        XCTAssertEqual(coordinator.state, .offered(offer))
    }

    func testConfirmedOfferDownloadsAndBecomesReady() async {
        let provider = FakeAssetProvider(.downloadRequired(offer))
        let coordinator = VoiceModelDownloadCoordinator(provider: provider)
        await coordinator.refresh()
        coordinator.confirm()
        XCTAssertEqual(coordinator.state, .confirmed(offer))
        await coordinator.download()
        XCTAssertEqual(provider.downloadCount, 1)
        XCTAssertEqual(coordinator.state, .ready)
    }

    func testDecliningReturnsToTheOffer() async {
        let coordinator = VoiceModelDownloadCoordinator(provider: FakeAssetProvider(.downloadRequired(offer)))
        await coordinator.refresh()
        coordinator.confirm()
        coordinator.decline()
        XCTAssertEqual(coordinator.state, .offered(offer))
    }

    func testFailureIsReportedAndConfirmationIsConsumed() async {
        let provider = FakeAssetProvider(.downloadRequired(offer))
        provider.fails = true
        let coordinator = VoiceModelDownloadCoordinator(provider: provider)
        await coordinator.refresh()
        coordinator.confirm()
        await coordinator.download()
        XCTAssertEqual(coordinator.state, .failed("download_failed"))
        await coordinator.download()
        XCTAssertEqual(provider.downloadCount, 1)
    }

    func testReadyAndUnsupportedStatesNeedNoOffer() async {
        let ready = VoiceModelDownloadCoordinator(provider: FakeAssetProvider(.ready))
        await ready.refresh()
        XCTAssertEqual(ready.state, .ready)
        ready.confirm()
        XCTAssertEqual(ready.state, .ready)
        let unsupported = VoiceModelDownloadCoordinator(provider: FakeAssetProvider(.unsupported))
        await unsupported.refresh()
        XCTAssertEqual(unsupported.state, .unsupported)
    }
}
