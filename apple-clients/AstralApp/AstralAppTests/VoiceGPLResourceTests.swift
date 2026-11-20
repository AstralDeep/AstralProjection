// Asserts the running app bundle holds no FluidAudio LuxTTS G2P resource bundle, whose eSpeak NG derived data is GPL-3.0-or-later.
// The Xcode build phase that runs strip-voice-gpl-resources.sh removes it from every build, so a failure here means that phase stopped working.

import Foundation
import XCTest

final class VoiceGPLResourceTests: XCTestCase {
    func testTheAppBundleHoldsNoLuxTtsResourceBundle() throws {
        let root = Bundle.main.bundleURL
        XCTAssertEqual(root.pathExtension, "app")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var found: [String] = []
        for case let url as URL in walker {
            // The test bundle sits in PlugIns only while tests run and is never shipped.
            if url.pathExtension == "xctest" {
                walker.skipDescendants()
            } else if url.path.contains("LuxTtsG2pResources") {
                found.append(url.path)
            }
        }
        XCTAssertEqual(found, [])
    }

    func testNoLoadedBundleIsALuxTtsResourceBundle() {
        let loaded = (Bundle.allBundles + Bundle.allFrameworks).map(\.bundleURL.lastPathComponent)
        XCTAssertFalse(loaded.contains { $0.contains("LuxTtsG2pResources") })
    }
}
