import Foundation
import XCTest
@testable import LocalQuotaBar

final class ZAIResetServiceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    private func temporaryStorage() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalQuotaBarResetTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent("pending.json")
    }

    private func context(_ scope: String = "account-a", jwt: String = "test-jwt") -> ZAIResetContext {
        ZAIResetContext(scopeID: scope, jwt: jwt, oauthToken: "test-oauth")
    }

    private func response(_ request: URLRequest, status: Int = 200,
                          body: String = #"{"code":0,"data":{"used":true}}"#) -> (Data, HTTPURLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                        httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    private func payload(_ request: URLRequest) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: XCTUnwrap(request.httpBody))
    }

    private func storedKeys(_ url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["keys"] as? [String: String])
    }

    @MainActor
    func testRequestHasExactEndpointHeadersPayloadAndPersistsBeforeSending() async throws {
        let url = try temporaryStorage()
        var requests: [URLRequest] = []
        let service = ZAIResetService(storageURL: url, transport: { request in
            requests.append(request)
            let body = try self.payload(request)
            XCTAssertEqual(try self.storedKeys(url).values.first, body["idempotency_key"])
            return self.response(request)
        })
        let succeeded = await service.use(context: context(), kind: .fiveHour)
        XCTAssertTrue(succeeded)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://zcode.z.ai/api/v1/coding-plan/reset/use")
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-jwt")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Bigmodel-Authorization"), "test-oauth")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Bigmodel-Target-Type"), "PERSONAL")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try payload(request)
        XCTAssertEqual(Set(body.keys), ["idempotency_key", "reset_type"])
        XCTAssertEqual(body["reset_type"], "FIVE_HOUR")
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(body["idempotency_key"])))
        XCTAssertEqual(try storedKeys(url).count, 0)
    }

    @MainActor
    func testExistingBearerPrefixIsNotDuplicated() async throws {
        let service = ZAIResetService(storageURL: try temporaryStorage(), transport: { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-jwt")
            return self.response(request)
        })
        let succeeded = await service.use(context: context(jwt: "Bearer test-jwt"), kind: .week)
        XCTAssertTrue(succeeded)
    }

    @MainActor
    func testNetworkFailureAndRecreatedServiceAlwaysReusePersistedKey() async throws {
        let url = try temporaryStorage()
        var keys: [String] = []
        let transport: ZAIResetService.Transport = { request in
            keys.append(try XCTUnwrap(self.payload(request)["idempotency_key"]))
            throw URLError(.timedOut)
        }
        let first = ZAIResetService(storageURL: url, transport: transport)
        let firstResult = await first.use(context: context(), kind: .fiveHour)
        let retryResult = await first.use(context: context(), kind: .fiveHour)
        XCTAssertFalse(firstResult)
        XCTAssertFalse(retryResult)
        let second = ZAIResetService(storageURL: url, transport: transport)
        XCTAssertEqual(second.state(scopeID: "account-a", kind: .fiveHour),
                       .failed("上次重置未确认，请重试"))
        let recreatedResult = await second.use(context: context(), kind: .fiveHour)
        XCTAssertFalse(recreatedResult)
        XCTAssertEqual(keys.count, 3)
        XCTAssertEqual(Set(keys).count, 1)
        XCTAssertEqual(try storedKeys(url).values.first, keys.first)
        let raw = try String(contentsOf: url)
        XCTAssertFalse(raw.contains("account-a"))
        XCTAssertFalse(raw.contains("test-jwt"))
        XCTAssertFalse(raw.contains("test-oauth"))
    }

    @MainActor
    func testAccountAndResetTypeHaveIndependentKeys() async throws {
        let url = try temporaryStorage()
        var requests: [URLRequest] = []
        let service = ZAIResetService(storageURL: url, transport: { request in
            requests.append(request)
            return self.response(request, status: 503)
        })
        for account in ["account-a", "account-b"] {
            for kind: ZAIResetCreditCard.Kind in [.fiveHour, .week] {
                _ = await service.use(context: context(account), kind: kind)
            }
        }
        let bodies = try requests.map(payload)
        XCTAssertEqual(Set(bodies.compactMap { $0["idempotency_key"] }).count, 4)
        XCTAssertEqual(bodies.compactMap { $0["reset_type"] }, ["FIVE_HOUR", "WEEK", "FIVE_HOUR", "WEEK"])
        XCTAssertEqual(try storedKeys(url).count, 4)
    }

    @MainActor
    func testSuccessfulResetStaysLockedUntilNewSnapshotAndNextResetGetsNewKey() async throws {
        let url = try temporaryStorage()
        let completion = Date(timeIntervalSince1970: 1000)
        var keys: [String] = []
        let service = ZAIResetService(storageURL: url, transport: { request in
            keys.append(try XCTUnwrap(self.payload(request)["idempotency_key"]))
            return self.response(request)
        }, now: { completion })
        let first = await service.use(context: context(), kind: .fiveHour)
        XCTAssertTrue(first)
        XCTAssertEqual(service.state(scopeID: "account-a", kind: .fiveHour), .succeeded)
        XCTAssertTrue(try storedKeys(url).isEmpty)
        let duplicate = await service.use(context: context(), kind: .fiveHour)
        XCTAssertFalse(duplicate)
        service.acknowledgeFreshSnapshot(scopeID: "account-b", refreshStartedAt: completion)
        service.acknowledgeFreshSnapshot(scopeID: "account-a", refreshStartedAt: completion.addingTimeInterval(-1))
        XCTAssertEqual(service.state(scopeID: "account-a", kind: .fiveHour), .succeeded)
        service.acknowledgeFreshSnapshot(scopeID: "account-a", refreshStartedAt: completion)
        XCTAssertEqual(service.state(scopeID: "account-a", kind: .fiveHour), .idle)
        let second = await service.use(context: context(), kind: .fiveHour)
        XCTAssertTrue(second)
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(Set(keys).count, 2)
    }

    @MainActor
    func testOnlyConfirmedBusinessSuccessClearsKey() async throws {
        let url = try temporaryStorage()
        var bodies = [
            #"{"code":500,"data":{"used":true}}"#,
            #"{"code":0,"success":false,"data":{"used":true}}"#,
            #"{"code":200,"success":false,"data":{"used":true}}"#,
            #"{"code":0,"data":{"used":false}}"#,
            #"{"code":0,"data":{"used":1}}"#,
            #"{"code":0,"data":{"used":"true"}}"#,
            #"{"code":0,"data":{}}"#,
            #"{"code":true,"data":{"used":true}}"#,
            "invalid-json",
            #"{"code":200,"data":{"used":true}}"#
        ]
        var keys: [String] = []
        let service = ZAIResetService(storageURL: url, transport: { request in
            keys.append(try XCTUnwrap(self.payload(request)["idempotency_key"]))
            return self.response(request, body: bodies.removeFirst())
        })
        for _ in 0..<9 {
            let result = await service.use(context: context(), kind: .week)
            XCTAssertFalse(result)
            XCTAssertEqual(try storedKeys(url).count, 1)
        }
        let success = await service.use(context: context(), kind: .week)
        XCTAssertTrue(success)
        XCTAssertEqual(Set(keys).count, 1)
        XCTAssertTrue(try storedKeys(url).isEmpty)
    }

    @MainActor
    func testNon200ResponsesKeepSameKeyIncludingOtherSuccessStatuses() async throws {
        let url = try temporaryStorage()
        var statuses = [201, 204, 302, 401, 429, 500]
        var keys: [String] = []
        let service = ZAIResetService(storageURL: url, transport: { request in
            keys.append(try XCTUnwrap(self.payload(request)["idempotency_key"]))
            return self.response(request, status: statuses.removeFirst())
        })
        for _ in 0..<6 {
            let result = await service.use(context: context(), kind: .week)
            XCTAssertFalse(result)
        }
        XCTAssertEqual(Set(keys).count, 1)
        XCTAssertEqual(try storedKeys(url).count, 1)
    }

    @MainActor
    func testCorruptStorageBlocksRequestsWithoutOverwritingEvidence() async throws {
        let url = try temporaryStorage()
        for text in ["broken-json", #"{"version":1,"keys":{"invalid":"not-a-uuid"}}"#,
                     #"{"version":2,"keys":{}}"#] {
            let original = Data(text.utf8)
            try original.write(to: url)
            var calls = 0
            let service = ZAIResetService(storageURL: url, transport: { request in
                calls += 1
                return self.response(request)
            })
            let result = await service.use(context: context(), kind: .week)
            XCTAssertFalse(result)
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    @MainActor
    func testInitialPersistenceFailureDoesNotSendRequest() async throws {
        let parent = try temporaryStorage()
        let url = parent.appendingPathComponent("pending.json")
        var calls = 0
        let service = ZAIResetService(storageURL: url, transport: { request in
            calls += 1
            return self.response(request)
        })
        // 初始化后把预期目录变成普通文件，模拟落盘失败。
        try Data("block-directory".utf8).write(to: parent)
        let result = await service.use(context: context(), kind: .week)
        XCTAssertFalse(result)
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testFailureToClearStorageKeepsOriginalKeyForRetry() async throws {
        let url = try temporaryStorage()
        var keys: [String] = []
        var savedRecord: Data?
        let service = ZAIResetService(storageURL: url, transport: { request in
            keys.append(try XCTUnwrap(self.payload(request)["idempotency_key"]))
            if keys.count == 1 {
                savedRecord = try Data(contentsOf: url)
                try FileManager.default.removeItem(at: url)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            }
            return self.response(request)
        })
        let first = await service.use(context: context(), kind: .week)
        XCTAssertTrue(first)
        XCTAssertEqual(service.state(scopeID: "account-a", kind: .week),
                       .failed("重置已响应，但记录未能保存，请重试确认"))
        let second = await service.use(context: context(), kind: .week)
        XCTAssertFalse(second)
        XCTAssertEqual(keys.count, 1)
        // 存储不可读时不发送；恢复原记录后仍复用原键确认请求。
        try FileManager.default.removeItem(at: url)
        try XCTUnwrap(savedRecord).write(to: url)
        let recovered = await service.use(context: context(), kind: .week)
        XCTAssertTrue(recovered)
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(Set(keys).count, 1)
    }

    @MainActor
    func testEarlyInitializedInstancesReloadAndReusePendingKey() async throws {
        let url = try temporaryStorage()
        var keys: [String] = []
        let transport: ZAIResetService.Transport = { request in
            keys.append(try XCTUnwrap(self.payload(request)["idempotency_key"]))
            throw URLError(.timedOut)
        }
        let first = ZAIResetService(storageURL: url, transport: transport)
        let second = ZAIResetService(storageURL: url, transport: transport)
        let firstResult = await first.use(context: context(), kind: .week)
        let secondResult = await second.use(context: context(), kind: .week)
        XCTAssertFalse(firstResult)
        XCTAssertFalse(secondResult)
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(Set(keys).count, 1)
        XCTAssertEqual(try storedKeys(url).values.first, keys.first)
    }

    @MainActor
    func testStaleInstanceRetryReusesKeyAfterAnotherInstanceClearsIt() async throws {
        let url = try temporaryStorage()
        var keys: [String] = []
        var firstCalls = 0
        let first = ZAIResetService(storageURL: url, transport: { request in
            firstCalls += 1
            keys.append(try XCTUnwrap(self.payload(request)["idempotency_key"]))
            if firstCalls == 1 { throw URLError(.timedOut) }
            return self.response(request)
        })
        let second = ZAIResetService(storageURL: url, transport: { request in
            keys.append(try XCTUnwrap(self.payload(request)["idempotency_key"]))
            return self.response(request)
        })
        let initial = await first.use(context: context(), kind: .week)
        XCTAssertFalse(initial)
        let confirmedElsewhere = await second.use(context: context(), kind: .week)
        XCTAssertTrue(confirmedElsewhere)
        XCTAssertTrue(try storedKeys(url).isEmpty)
        let staleRetry = await first.use(context: context(), kind: .week)
        XCTAssertTrue(staleRetry)
        XCTAssertEqual(keys.count, 3)
        XCTAssertEqual(Set(keys).count, 1)
        XCTAssertTrue(try storedKeys(url).isEmpty)
    }

    @MainActor
    func testDifferentPersistedKeyRejectsStaleRetryWithoutOverwritingEitherIdentity() async throws {
        let url = try temporaryStorage()
        var keys: [String] = []
        let service = ZAIResetService(storageURL: url, transport: { request in
            keys.append(try XCTUnwrap(self.payload(request)["idempotency_key"]))
            throw URLError(.timedOut)
        })
        _ = await service.use(context: context(), kind: .week)
        let originalRecord = try Data(contentsOf: url)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: originalRecord) as? [String: Any])
        let storedKey = try XCTUnwrap(try storedKeys(url).keys.first)
        object["keys"] = [storedKey: UUID().uuidString]
        let conflictingRecord = try JSONSerialization.data(withJSONObject: object)
        try conflictingRecord.write(to: url, options: .atomic)

        let conflict = await service.use(context: context(), kind: .week)
        XCTAssertFalse(conflict)
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(try Data(contentsOf: url), conflictingRecord)
        XCTAssertEqual(service.state(scopeID: "account-a", kind: .week),
                       .failed("存在另一项待确认重置，请等待其完成后重试原操作"))

        // 另一操作完成清理后，本实例仍应恢复原键，不能采用冲突键或新键。
        object["keys"] = [String: String]()
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        _ = await service.use(context: context(), kind: .week)
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(Set(keys).count, 1)
        XCTAssertEqual(try storedKeys(url).values.first, keys.first)
    }

    @MainActor
    func testCrossInstanceLockRejectsConcurrentRequestAndReleasesForRetry() async throws {
        let url = try temporaryStorage()
        var keys: [String] = []
        var continuation: CheckedContinuation<Void, Never>?
        let entered = expectation(description: "首个实例已持锁发送")
        let first = ZAIResetService(storageURL: url, transport: { request in
            keys.append(try XCTUnwrap(self.payload(request)["idempotency_key"]))
            await withCheckedContinuation { continuation = $0; entered.fulfill() }
            throw URLError(.timedOut)
        })
        var secondCalls = 0
        let second = ZAIResetService(storageURL: url, transport: { request in
            secondCalls += 1
            keys.append(try XCTUnwrap(self.payload(request)["idempotency_key"]))
            return self.response(request)
        })
        let active = Task { await first.use(context: context(), kind: .week) }
        await fulfillment(of: [entered], timeout: 1)
        let blocked = await second.use(context: context(), kind: .week)
        XCTAssertFalse(blocked)
        XCTAssertEqual(secondCalls, 0)
        XCTAssertEqual(second.state(scopeID: "account-a", kind: .week),
                       .failed("另一项重置正在处理，请稍后重试"))
        continuation?.resume()
        let firstResult = await active.value
        XCTAssertFalse(firstResult)
        let retry = await second.use(context: context(), kind: .week)
        XCTAssertTrue(retry)
        XCTAssertEqual(secondCalls, 1)
        XCTAssertEqual(Set(keys).count, 1)
        XCTAssertTrue(try storedKeys(url).isEmpty)
    }

    @MainActor
    func testConcurrentClicksSendOnlyOneRequest() async throws {
        let url = try temporaryStorage()
        var calls = 0
        var continuation: CheckedContinuation<Void, Never>?
        let entered = expectation(description: "请求已开始")
        let service = ZAIResetService(storageURL: url, transport: { request in
            calls += 1
            await withCheckedContinuation { continuation = $0; entered.fulfill() }
            return self.response(request)
        })
        let first = Task { await service.use(context: context(), kind: .week) }
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertEqual(service.state(scopeID: "account-a", kind: .week), .submitting)
        let duplicate = await service.use(context: context(), kind: .week)
        XCTAssertFalse(duplicate)
        XCTAssertEqual(calls, 1)
        continuation?.resume()
        let firstResult = await first.value
        XCTAssertTrue(firstResult)
    }

    @MainActor
    func testMissingCredentialsDoNotSendOrAllocateKey() async throws {
        let url = try temporaryStorage()
        var calls = 0
        let service = ZAIResetService(storageURL: url, transport: { request in
            calls += 1
            return self.response(request)
        })
        let result = await service.use(context: context(jwt: ""), kind: .week)
        XCTAssertFalse(result)
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
