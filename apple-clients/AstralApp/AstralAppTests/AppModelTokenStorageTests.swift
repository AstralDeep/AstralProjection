// Verifies AppModel's injected token storage keeps startup responsive and cannot restore a superseded session.
// Sign-out and blocked startup tests use synchronized memory fixtures without accessing device credentials.

import AstralCore
import XCTest

@testable import AstralDeep

@MainActor
final class AppModelTokenStorageTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func isolatedModel(store: TokenStorage) -> AppModel {
        let suite = "AppModelTokenStorageTests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("http://127.0.0.1:1", forKey: "serverBase")
        return AppModel(tokenStore: store, defaults: defaults)
    }

    private final class BlockingStore: TokenStorage, @unchecked Sendable {
        private let condition = NSCondition()
        private let started = AsyncStream<Bool>.makeStream()
        private var released = false
        private var stored: StoredTokens?
        private var wipes = 0

        init(_ stored: StoredTokens? = nil) {
            self.stored = stored
        }

        func load() -> StoredTokens? {
            condition.lock()
            let result = stored
            condition.unlock()
            let onMainThread = Thread.isMainThread
            started.continuation.yield(onMainThread)
            if onMainThread { return nil }
            condition.lock()
            while !released { condition.wait() }
            condition.unlock()
            return result
        }

        func save(_ tokens: StoredTokens) {
            condition.lock()
            stored = tokens
            condition.unlock()
        }

        func wipe() {
            condition.lock()
            stored = nil
            wipes += 1
            condition.unlock()
        }

        func loadStartedOnMainThread() async -> Bool {
            var iterator = started.stream.makeAsyncIterator()
            return await iterator.next() ?? true
        }

        func release() {
            condition.lock()
            released = true
            condition.broadcast()
            condition.unlock()
        }

        var wipeCount: Int {
            condition.lock()
            defer { condition.unlock() }
            return wipes
        }
    }

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

        await model.signOut(revokeRemote: false)
        XCTAssertEqual(first.counts, [0, 1, 1])
        XCTAssertEqual(second.counts, [0, 1, 0])
        XCTAssertNil(first.load())
        XCTAssertEqual(second.load(), secondFixture)
        XCTAssertFalse(model.signedIn)
        XCTAssertTrue(otherModel.signedIn)

        first.save(firstFixture)
        XCTAssertEqual(first.load(), firstFixture)
        await otherModel.signOut(revokeRemote: false)
        XCTAssertEqual(first.load(), firstFixture)
        XCTAssertNil(second.load())
    }

    func testBlockedBootstrapKeepsTheMainActorResponsive() async {
        let store = BlockingStore()
        let model = isolatedModel(store: store)
        let bootstrap = Task { await model.bootstrap() }
        let onMainThread = await store.loadStartedOnMainThread()
        XCTAssertFalse(onMainThread)
        model.composerDraft = "The interface can still respond"
        XCTAssertEqual(model.composerDraft, "The interface can still respond")
        XCTAssertFalse(model.signedIn)
        store.release()
        await bootstrap.value
        XCTAssertFalse(model.signedIn)
        XCTAssertEqual(store.wipeCount, 0)
    }

    func testSignOutDuringBlockedBootstrapCannotRestoreTheLoadedSession() async {
        let store = BlockingStore(
            StoredTokens(from: TokenSet(accessToken: "synthetic-old", refreshToken: nil, expiresIn: 3600)))
        let model = isolatedModel(store: store)
        var outbound = 0
        model.outboundTap = { _ in outbound += 1 }
        let bootstrap = Task { await model.bootstrap() }
        let onMainThread = await store.loadStartedOnMainThread()
        XCTAssertFalse(onMainThread)
        await model.signOut(revokeRemote: false)
        store.release()
        await bootstrap.value
        XCTAssertFalse(model.signedIn)
        XCTAssertNil(model.downloadOwner.account)
        XCTAssertEqual(store.wipeCount, 1)
        XCTAssertEqual(outbound, 0)
    }

    func testNewSignInDuringBlockedBootstrapKeepsItsOwnerAndSession() async {
        let store = BlockingStore(
            StoredTokens(from: TokenSet(accessToken: "synthetic-old", refreshToken: nil, expiresIn: 3600)))
        let model = isolatedModel(store: store)
        let bootstrap = Task { await model.bootstrap() }
        let onMainThread = await store.loadStartedOnMainThread()
        XCTAssertFalse(onMainThread)
        let account = ConversationAccount(issuer: "https://iam.example.test", subject: "new-owner")!
        model.bindConversationAccount(account)
        model.signedIn = true
        model.accountName = "New session"
        model.activeChatId = "new-session-chat"
        store.save(StoredTokens(from: TokenSet(accessToken: "synthetic-new", refreshToken: nil, expiresIn: 3600)))
        store.release()
        await bootstrap.value
        XCTAssertTrue(model.signedIn)
        XCTAssertEqual(model.downloadOwner.account, account)
        XCTAssertEqual(model.accountName, "New session")
        XCTAssertEqual(model.activeChatId, "new-session-chat")
        XCTAssertEqual(store.wipeCount, 0)
    }

    func testOwnerChangeDuringBlockedBootstrapCannotApplyTheOldAccount() async {
        let store = BlockingStore(
            StoredTokens(from: TokenSet(accessToken: "synthetic-old", refreshToken: nil, expiresIn: 3600)))
        let model = isolatedModel(store: store)
        let bootstrap = Task { await model.bootstrap() }
        let onMainThread = await store.loadStartedOnMainThread()
        XCTAssertFalse(onMainThread)
        let account = ConversationAccount(issuer: "https://iam.example.test", subject: "other-owner")!
        model.bindConversationAccount(account)
        store.release()
        await bootstrap.value
        XCTAssertFalse(model.signedIn)
        XCTAssertEqual(model.downloadOwner.account, account)
        XCTAssertEqual(store.wipeCount, 0)
    }

    func testCancelledBlockedBootstrapCannotRestoreTheLoadedSession() async {
        let store = BlockingStore(
            StoredTokens(from: TokenSet(accessToken: "synthetic-old", refreshToken: nil, expiresIn: 3600)))
        let model = isolatedModel(store: store)
        let bootstrap = Task { await model.bootstrap() }
        let onMainThread = await store.loadStartedOnMainThread()
        XCTAssertFalse(onMainThread)
        bootstrap.cancel()
        store.release()
        await bootstrap.value
        XCTAssertFalse(model.signedIn)
        XCTAssertNil(model.downloadOwner.account)
        XCTAssertEqual(store.wipeCount, 0)
    }
}
