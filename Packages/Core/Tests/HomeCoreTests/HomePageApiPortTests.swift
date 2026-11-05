import CouliNetwork
import Foundation
import Generated
@testable import HomeCore
import XCTest

/// FU-X-HOME-PAGE-API-ios 生产端口（brief §2.2 第 1 条、§3「端口」）：`ApiClientHomeContractPort` 把 HomeCall 原样翻成契约调用——
/// getPage(`GET /v1/pages/{page_key}`)、listPageSectionItems(`GET /v1/pages/{page_key}/sections/{section_id}/items`，只带
/// cursor)。
/// 这里用记录替身代替 ApiClient（只看交给执行层的 ApiCall、闸门与归属）；真实 URL、请求头在 AppTests 的 HomePageApiWiringTests 里核。
/// 与安卓 p01–p07、鸿蒙 HomePageApi.test.ets 端口组同口径。
final class HomePageApiPortTests: XCTestCase {
    private let owner = RequestOwnership(account: "user-a", generation: 7, epoch: 3)

    private func homeCall(anonymous: Bool = false, flag: HomePageFlag = HomePageFlag()) -> HomeCall {
        HomeCall(anonymous: anonymous, owner: owner, sendAllowed: { flag.on })
    }

    /// p01 getPage：恰好一个调用，operationId getPage，路径参数只有 page_key=home，不带查询、请求体、幂等键、step-up；归属原样。
    func testGetPageSendsExactlyOneContractCall() async throws {
        let api = HomePageRecordingApi()
        let port = ApiClientHomeContractPort(api: api)
        _ = await port.getPage(pageKey: "home", call: homeCall())
        XCTAssertEqual(api.sent.count, 1, "getPage 应只交给执行层一次")
        let sent = try XCTUnwrap(api.sent.first)
        XCTAssertEqual(sent.call.operationId, "getPage")
        XCTAssertEqual(sent.call.pathParams, ["page_key": "home"])
        XCTAssertNil(sent.call.query, "getPage 不带任何查询参数")
        XCTAssertNil(sent.call.body)
        XCTAssertNil(sent.call.idempotencyKey)
        XCTAssertNil(sent.call.stepUpToken)
        XCTAssertEqual(sent.expected, owner, "归属必须是 HomeCall.owner（鸿蒙评审 S2-03：真实端口没设 owner）")
    }

    /// p02 首屏取卡：listPageSectionItems，路径参数恰为 page_key + section_id，没有任何查询参数（不带 kind / pool_id / limit / 频道）。
    func testFirstSectionPageHasNoQueryAtAll() async throws {
        let api = HomePageRecordingApi()
        let port = ApiClientHomeContractPort(api: api)
        _ = await port.listSectionItems(pageKey: "home", sectionId: "demo-today", cursor: nil, call: homeCall())
        let sent = try XCTUnwrap(api.sent.first)
        XCTAssertEqual(api.sent.count, 1)
        XCTAssertEqual(sent.call.operationId, "listPageSectionItems")
        XCTAssertEqual(sent.call.pathParams, ["page_key": "home", "section_id": "demo-today"])
        XCTAssertNil(sent.call.query, "首屏不得带 kind / pool_id / limit / 频道 / 排序")
        XCTAssertNil(sent.call.body)
        XCTAssertNil(sent.call.idempotencyKey)
        XCTAssertEqual(sent.expected, owner)
    }

    /// p03 游标是唯一参数，按 RFC 3986 非保留字符编码；游标里的 `&` `=` 不得变成别的参数。
    func testCursorIsTheOnlyParameterAndIsPercentEncoded() async throws {
        let api = HomePageRecordingApi()
        let port = ApiClientHomeContractPort(api: api)
        _ = await port.listSectionItems(pageKey: "home", sectionId: "feed", cursor: "Y3Vy+c29y/LWV4=", call: homeCall())
        _ = await port.listSectionItems(pageKey: "home", sectionId: "feed", cursor: "a&limit=99 b", call: homeCall())
        XCTAssertEqual(api.sent.map(\.call.query), ["cursor=Y3Vy%2Bc29y%2FLWV4%3D", "cursor=a%26limit%3D99%20b"])
        let parts = try XCTUnwrap(api.sent.last?.call.query).split(separator: "&")
        XCTAssertEqual(parts.count, 1, "游标里的 & 不得拆出第二个参数")
    }

    /// p04 发送前闸门：交给执行层的 sendAllowed 就是 HomeCall.sendAllowed（每次现读，不在端口里取一次存下）；闸门关着时端口不另造成功。
    func testSendAllowedIsForwardedAndReadLive() async {
        let api = HomePageRecordingApi()
        let port = ApiClientHomeContractPort(api: api)
        let flag = HomePageFlag()
        _ = await port.getPage(pageKey: "home", call: homeCall(flag: flag))
        _ = await port.listSectionItems(pageKey: "home", sectionId: "s", cursor: nil, call: homeCall(flag: flag))
        XCTAssertEqual(api.sent.count, 2)
        for sent in api.sent {
            XCTAssertTrue(sent.sendAllowed())
        }
        flag.on = false
        for sent in api.sent {
            XCTAssertFalse(sent.sendAllowed(), "sendAllowed 必须每次现读 HomeCall 的闸门")
        }
        api.reply = .localReject(reason: LocalRejectReason.sendBlocked)
        let blocked = await port.getPage(pageKey: "home", call: homeCall(flag: flag))
        XCTAssertEqual(blocked, .localReject(reason: LocalRejectReason.sendBlocked), "闸门关着不得交成功")
    }

    /// p05 结果原样交回：30701、20001、断网、超时、42901、10405 都不改写（不当崩溃、不另造强更）。
    func testResultsAreReturnedVerbatim() async {
        let api = HomePageRecordingApi()
        let port = ApiClientHomeContractPort(api: api)
        let samples: [ApiResult] = [
            HomeKit.failure(30701, trace: "t1"),
            HomeKit.failure(20001, trace: "t2"),
            HomeKit.failure(42901, retryAfter: "3", trace: "t3"),
            HomeKit.failure(10405, trace: "t4"),
            .transportFailure(kind: "disconnect", httpStatus: nil, idempotencyKey: nil, pendingKeyUnknown: false),
            .transportFailure(kind: "timeout", httpStatus: nil, idempotencyKey: nil, pendingKeyUnknown: false),
            .success(data: Data("{\"page_key\":\"home\"}".utf8), traceId: "t5", idempotencyKey: nil),
        ]
        for sample in samples {
            api.reply = sample
            let page = await port.getPage(pageKey: "home", call: homeCall())
            XCTAssertEqual(page, sample, "getPage 改写了结果")
            let items = await port.listSectionItems(pageKey: "home", sectionId: "s", cursor: "c", call: homeCall())
            XCTAssertEqual(items, sample, "listSectionItems 改写了结果")
        }
    }

    /// p06 基本模式（anonymous）照发：端口不另拒；是否带凭据由 ApiClient 按隐私结论决定。
    func testAnonymousCallsAreStillSent() async {
        let api = HomePageRecordingApi()
        let port = ApiClientHomeContractPort(api: api)
        _ = await port.getPage(pageKey: "home", call: homeCall(anonymous: true))
        _ = await port.listSectionItems(pageKey: "home", sectionId: "s", cursor: nil, call: homeCall(anonymous: true))
        XCTAssertEqual(api.sent.map(\.call.operationId), ["getPage", "listPageSectionItems"])
    }

    /// p07 一次调用只交给执行层一次（端口里不重试、不扇出），失败也一样。
    func testOneCallReachesTheClientOnceEvenOnFailure() async {
        let api = HomePageRecordingApi()
        api.reply = .transportFailure(
            kind: "disconnect",
            httpStatus: nil,
            idempotencyKey: nil,
            pendingKeyUnknown: false
        )
        let port = ApiClientHomeContractPort(api: api)
        _ = await port.getPage(pageKey: "home", call: homeCall())
        _ = await port.listSectionItems(pageKey: "home", sectionId: "s", cursor: nil, call: homeCall())
        XCTAssertEqual(api.sent.count, 2)
    }

    /// 生成表里两个操作的形状（listPageSectionItems 只在新锁 00deded0ef6f 里有；升锁前红属预期）。
    func testGeneratedOperationsMatchTheContract() throws {
        let page = try XCTUnwrap(ApiOperations.byId("getPage"))
        XCTAssertEqual(page.method, "GET")
        XCTAssertEqual(page.pathTemplate, "/v1/pages/{page_key}")
        XCTAssertFalse(page.signed)
        let items = try XCTUnwrap(ApiOperations.byId("listPageSectionItems"), "升锁 00deded0ef6f 之后才有")
        XCTAssertEqual(items.method, "GET")
        XCTAssertEqual(items.pathTemplate, "/v1/pages/{page_key}/sections/{section_id}/items")
        XCTAssertFalse(items.signed)
        XCTAssertFalse(items.idempotent)
        XCTAssertFalse(items.planned)
        XCTAssertEqual(Set(items.errorCodes), [20001, 30701])
    }
}

/// 记录交给执行层的调用；每次调用按脚本回一个结果。
private final class HomePageRecordingApi: HomeArticlesApi, @unchecked Sendable {
    struct Sent {
        let call: ApiCall
        let sendAllowed: @Sendable () -> Bool
        let isValid: @Sendable () -> Bool
        let expected: RequestOwnership?
    }

    private let lock = NSLock()
    private var log: [Sent] = []
    var reply: ApiResult = .success(
        data: Data("{\"items\":[],\"next_cursor\":null}".utf8),
        traceId: "t",
        idempotencyKey: nil
    )

    var sent: [Sent] {
        lock.withLock { log }
    }

    func send(
        _ call: ApiCall, isValid: @escaping @Sendable () -> Bool, sendAllowed: @escaping @Sendable () -> Bool,
        expected: RequestOwnership?
    ) async -> ApiResult {
        lock.withLock {
            log.append(Sent(call: call, sendAllowed: sendAllowed, isValid: isValid, expected: expected))
            return reply
        }
    }
}

/// 线程安全的开关（发送前闸门每次现读）。
private final class HomePageFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var on: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
