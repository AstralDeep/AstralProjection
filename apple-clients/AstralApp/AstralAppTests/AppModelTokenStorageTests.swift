import AstralCore
import XCTest

@testable import AstralDeep

@MainActor
final class AppModelTokenStorageTests: XCTestCase {
    /// This spy delegates exclusively to the existing in-memory store. Even
    /// the regression's failure path must never construct or query Keychain.
    private final class MemoryStore: TokenStorage, @unchecked Sendable {
        private let memory = InMemoryTokenStore()
        private let lock = NSLock()
        private var loads = 0
        private var saves = 0
        private var wipes = 0

        var counts: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return [loads, saves, wipes]
        }

        func load() -> StoredTokens? {
            lock.lock()
            loads += 1
            lock.unlock()
            return memory.load()
        }

        func save(_ tokens: StoredTokens) {
            lock.lock()
            saves += 1
            lock.unlock()
            memory.save(tokens)
        }

        func wipe() {
            lock.lock()
            wipes += 1
            lock.unlock()
            memory.wipe()
        }
    }

    func testEmptyBootstrapReadsOnlyTheInjectedMemoryStoreWithoutStartingAuthentication() async {
        let store = MemoryStore()
        let model = AppModel(tokenStore: store)
        var outbound = 0
        model.outboundTap = { _ in outbound += 1 }
        XCTAssertEqual(store.counts, [0, 0, 0])
        await model.bootstrap()
        XCTAssertEqual(store.counts, [1, 0, 0])
        XCTAssertFalse(model.signedIn)
        XCTAssertFalse(model.connected)
        XCTAssertEqual(outbound, 0)
    }

    func testSignOutWipesOnlyItsInjectedFixtureAndNeverAnotherModelsSavedTokens() async {
        let first = MemoryStore()
        let second = MemoryStore()
        let firstFixture = StoredTokens(
            from: TokenSet(accessToken: "synthetic-first", refreshToken: nil, expiresIn: 3600))
        let secondFixture = StoredTokens(
            from: TokenSet(accessToken: "synthetic-second", refreshToken: nil, expiresIn: 3600))
        first.save(firstFixture)
        second.save(secondFixture)
        let model = AppModel(tokenStore: first)
        let otherModel = AppModel(tokenStore: second)
        model.signedIn = true
        otherModel.signedIn = true

        // Match the former dangerous paths: these models never bootstrapped
        // credentials, but sign-out still performs a durable storage wipe.
        await model.signOut(revokeRemote: false)
        XCTAssertEqual(first.counts, [0, 1, 1])
        XCTAssertEqual(second.counts, [0, 1, 0])
        XCTAssertNil(first.load())
        XCTAssertEqual(second.load(), secondFixture)
        XCTAssertFalse(model.signedIn)
        XCTAssertTrue(otherModel.signedIn)

        // A second memory-only test session remains independent on reuse.
        first.save(firstFixture)
        XCTAssertEqual(first.load(), firstFixture)
        await otherModel.signOut(revokeRemote: false)
        XCTAssertEqual(first.load(), firstFixture)
        XCTAssertNil(second.load())
    }
}
