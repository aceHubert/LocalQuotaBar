import Foundation
import XCTest
@testable import LocalQuotaBar

final class CodexResetServiceTests: XCTestCase {
    private enum TestError: Error {
        case requestFailed
    }

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    private func temporaryStorage() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexResetServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent("codex-pending-reset-keys.json")
    }

    private func storedKeys(_ url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["keys"] as? [String: String])
    }

    @MainActor
    func testErrorRetriesReuseSameIdempotencyKey() async throws {
        let storageURL = try temporaryStorage()
        var receivedKeys: [String] = []
        let service = CodexResetService(storageURL: storageURL) { creditID, idempotencyKey in
            XCTAssertEqual(creditID, "credit-a")
            receivedKeys.append(idempotencyKey)
            throw TestError.requestFailed
        }

        let firstResult = await service.use(accountID: "account-a", creditID: "credit-a")
        let secondResult = await service.use(accountID: "account-a", creditID: "credit-a")

        XCTAssertFalse(firstResult)
        XCTAssertFalse(secondResult)
        XCTAssertEqual(receivedKeys.count, 2)
        XCTAssertEqual(Set(receivedKeys).count, 1)
        XCTAssertEqual(try storedKeys(storageURL).values.first, receivedKeys.first)
        XCTAssertEqual(
            service.state(accountID: "account-a", creditID: "credit-a"),
            .failed("重置请求未确认，请重试")
        )
    }

    @MainActor
    func testDifferentCardsAreMutuallyExclusiveWhileSubmitting() async throws {
        var calls: [(String, String)] = []
        var continuation: CheckedContinuation<CodexResetOutcome, Never>?
        let entered = expectation(description: "第一张重置卡请求已开始")
        let service = CodexResetService(storageURL: try temporaryStorage()) { creditID, idempotencyKey in
            calls.append((creditID, idempotencyKey))
            return await withCheckedContinuation {
                continuation = $0
                entered.fulfill()
            }
        }

        let first = Task {
            await service.use(accountID: "account-a", creditID: "credit-a")
        }
        await fulfillment(of: [entered], timeout: 1)

        XCTAssertTrue(service.isSubmitting)
        XCTAssertEqual(service.state(accountID: "account-a", creditID: "credit-a"), .submitting)
        let blockedResult = await service.use(accountID: "account-a", creditID: "credit-b")
        XCTAssertFalse(blockedResult)
        XCTAssertEqual(service.state(accountID: "account-a", creditID: "credit-b"), .idle)
        XCTAssertEqual(calls.count, 1)

        continuation?.resume(returning: .noCredit)
        let firstResult = await first.value
        XCTAssertFalse(firstResult)
        XCTAssertFalse(service.isSubmitting)
    }

    @MainActor
    func testResetClearsPendingKeyAndPreventsDuplicateSubmission() async throws {
        let storageURL = try temporaryStorage()
        var receivedKeys: [String] = []
        var outcomes: [Result<CodexResetOutcome, TestError>] = [
            .failure(.requestFailed),
            .success(.reset)
        ]
        let service = CodexResetService(storageURL: storageURL) { _, idempotencyKey in
            receivedKeys.append(idempotencyKey)
            return try outcomes.removeFirst().get()
        }

        let failedResult = await service.use(accountID: "account-a", creditID: "credit-a")
        let successfulResult = await service.use(accountID: "account-a", creditID: "credit-a")
        XCTAssertFalse(failedResult)
        XCTAssertTrue(successfulResult)
        XCTAssertEqual(receivedKeys.count, 2)
        XCTAssertEqual(Set(receivedKeys).count, 1)
        XCTAssertTrue(try storedKeys(storageURL).isEmpty)
        XCTAssertEqual(service.state(accountID: "account-a", creditID: "credit-a"), .succeeded)

        let duplicateResult = await service.use(accountID: "account-a", creditID: "credit-a")
        XCTAssertFalse(duplicateResult)
        XCTAssertEqual(receivedKeys.count, 2)
    }

    @MainActor
    func testAlreadyRedeemedIsSuccessfulAndClearsPendingKey() async throws {
        let storageURL = try temporaryStorage()
        var receivedKeys: [String] = []
        var callCount = 0
        let service = CodexResetService(storageURL: storageURL) { _, idempotencyKey in
            receivedKeys.append(idempotencyKey)
            callCount += 1
            if callCount == 1 { throw TestError.requestFailed }
            return .alreadyRedeemed
        }

        let failedResult = await service.use(accountID: "account-a", creditID: "credit-a")
        let successfulResult = await service.use(accountID: "account-a", creditID: "credit-a")
        XCTAssertFalse(failedResult)
        XCTAssertTrue(successfulResult)
        XCTAssertEqual(Set(receivedKeys).count, 1)
        XCTAssertTrue(try storedKeys(storageURL).isEmpty)
        XCTAssertEqual(service.state(accountID: "account-a", creditID: "credit-a"), .succeeded)
    }

    @MainActor
    func testConfirmedResetStillRefreshesWhenKeyCleanupFails() async throws {
        let storageURL = try temporaryStorage()
        var keys: [String] = []
        let service = CodexResetService(storageURL: storageURL) { _, key in
            keys.append(key)
            if keys.count == 1 {
                // 只在临时目录制造写入失败；不会使用真实传输或用户记录。
                try FileManager.default.removeItem(at: storageURL)
                try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: false)
                return .reset
            }
            return .alreadyRedeemed
        }
        let confirmed = await service.use(accountID: "account-a", creditID: "credit-a")
        XCTAssertTrue(confirmed, "上游成功后即使本地清理失败，也必须触发额度刷新")
        XCTAssertEqual(service.state(accountID: "account-a", creditID: "credit-a"),
                       .failed("重置已成功，但记录未能保存，请重试确认"))
        try FileManager.default.removeItem(at: storageURL)
        let retried = await service.use(accountID: "account-a", creditID: "credit-a")
        XCTAssertTrue(retried)
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0], keys[1])
        XCTAssertTrue(try storedKeys(storageURL).isEmpty)
    }

    @MainActor
    func testNoCreditAndNothingToResetRetainPendingKey() async throws {
        let storageURL = try temporaryStorage()
        var receivedKeys: [String] = []
        var outcomes: [CodexResetOutcome] = [.noCredit, .nothingToReset]
        let service = CodexResetService(storageURL: storageURL) { _, idempotencyKey in
            receivedKeys.append(idempotencyKey)
            return outcomes.removeFirst()
        }

        let noCreditResult = await service.use(accountID: "account-a", creditID: "credit-a")
        let nothingToResetResult = await service.use(accountID: "account-a", creditID: "credit-a")
        XCTAssertFalse(noCreditResult)
        XCTAssertFalse(nothingToResetResult)
        XCTAssertEqual(Set(receivedKeys).count, 1)
        XCTAssertEqual(try storedKeys(storageURL).values.first, receivedKeys.first)
    }

    @MainActor
    func testPersistedKeysRecoverSeparatelyForEachAccount() async throws {
        let storageURL = try temporaryStorage()
        var initialKeys: [String] = []
        let first = CodexResetService(storageURL: storageURL) { _, idempotencyKey in
            initialKeys.append(idempotencyKey)
            throw TestError.requestFailed
        }

        let firstAccountResult = await first.use(accountID: "account-a", creditID: "shared-credit")
        let secondAccountResult = await first.use(accountID: "account-b", creditID: "shared-credit")
        XCTAssertFalse(firstAccountResult)
        XCTAssertFalse(secondAccountResult)
        XCTAssertEqual(try storedKeys(storageURL).count, 2)

        var recoveredKeys: [String] = []
        let second = CodexResetService(storageURL: storageURL) { _, idempotencyKey in
            recoveredKeys.append(idempotencyKey)
            throw TestError.requestFailed
        }

        XCTAssertEqual(
            second.state(accountID: "account-a", creditID: "shared-credit"),
            .failed("上次重置未确认，请重试")
        )
        XCTAssertEqual(
            second.state(accountID: "account-b", creditID: "shared-credit"),
            .failed("上次重置未确认，请重试")
        )
        let recoveredFirstResult = await second.use(accountID: "account-a", creditID: "shared-credit")
        let recoveredSecondResult = await second.use(accountID: "account-b", creditID: "shared-credit")
        XCTAssertFalse(recoveredFirstResult)
        XCTAssertFalse(recoveredSecondResult)

        XCTAssertEqual(initialKeys.count, 2)
        XCTAssertNotEqual(initialKeys[0], initialKeys[1])
        XCTAssertEqual(recoveredKeys, initialKeys)
    }
}
