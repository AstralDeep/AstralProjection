// Checks Foundation Models preference over the installed LFM2.5 fallback for typed chat without loading real weights.
// Fixtures stand in for both models, and the default fallback is the LFM2.5 model the voice session shares.

import Foundation
import XCTest

@testable import AstralDeep

final class OnDeviceFallbackModelTests: XCTestCase {
    private let request = OnDeviceRequest(
        messages: [.init(role: .user, text: "What is two plus two?")], schemaJSON: nil, maxTokens: 80)

    func testFoundationModelsRemainPreferredIncludingRefusals() async {
        let preferred = FallbackModelFixture(available: true, response: .refused("declined"))
        let fallback = FallbackModelFixture(available: true, response: .text("four"))
        let model = PreferredOnDeviceModel(preferred: preferred, fallback: fallback)
        XCTAssertTrue(model.available())
        let answer = await model.complete(request)
        XCTAssertEqual(answer, .refused("declined"))
        XCTAssertEqual(preferred.callCount, 1)
        XCTAssertEqual(fallback.callCount, 0)
    }

    func testIneligibleFoundationModelsUseOnlyTheInstalledFallback() async {
        let preferred = FallbackModelFixture(available: false, response: .unavailable(.deviceNotEligible))
        let fallback = FallbackModelFixture(available: true, response: .text("four"))
        let model = PreferredOnDeviceModel(preferred: preferred, fallback: fallback)
        let answer = await model.complete(request)
        XCTAssertEqual(answer, .text("four"))
        XCTAssertEqual(preferred.callCount, 0)
        XCTAssertEqual(fallback.callCount, 1)
        XCTAssertFalse(PreferredOnDeviceModel(preferred: preferred, fallback: preferred).available())
    }

    func testNeitherModelAvailableMeansTheKernelHasNoLocalModel() async {
        let none = FallbackModelFixture(available: false, response: .unavailable(.deviceNotEligible))
        XCTAssertFalse(PreferredOnDeviceModel(preferred: none, fallback: none).available())
        XCTAssertTrue(
            PreferredOnDeviceModel(
                preferred: none, fallback: FallbackModelFixture(available: true, response: .text("four"))
            ).available())
    }

    func testTheDefaultFallbackIsTheLFM25Model() {
        XCTAssertTrue(PreferredOnDeviceModel().fallback is LFM25OnDeviceModel)
    }
}

private nonisolated final class FallbackModelFixture: AstralOnDeviceModel, @unchecked Sendable {
    private let lock = NSLock()
    private let installed: Bool
    private let response: OnDeviceResponse
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }
    init(available: Bool, response: OnDeviceResponse) {
        installed = available
        self.response = response
    }
    func available() -> Bool { installed }
    func complete(_ request: OnDeviceRequest) async -> OnDeviceResponse {
        lock.withLock { calls += 1 }
        return response
    }
}
