import Foundation
@testable import Network
import SecureStore
@testable import Session
import XCTest

/// FU-IOS-0712 第 1 项：持久化登录世代与撤销标记（跨端教训 2、9、10、13–17；Android FU-AND-0714 / 0715、鸿蒙 FU-HM-0715 / 0718 同口径）。
/// 真实 `SecureSessionTokens` + 可分账号注入故障的安全存储（`ScriptedSecureStore`）+ 内存独立撤销介质；ApiClient 走真实管线与假服务。
final class FollowupIos0712SessionTests: XCTestCase {
    let tokensAccount = SecureSessionTokens.keychainAccount
    let markAccount = SecureSessionTokens.revokedAccount

    func login(_ harness: Harness, user: String = "user-a", access: String = "login-access") async {
        StubURLProtocol.install { _ in ok(loginData(access: access, scope: "full", user: user)) }
        let result = await harness.client.send(ApiCall(operationId: "loginBySms", body: "{}"))
        XCTAssertTrue(result.isSuccess, "登录：\(result)")
    }

    private func rawSession(_ store: ScriptedSecureStore) throws -> [String: Any] {
        let data = try XCTUnwrap(store.raw(tokensAccount))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - 世代与令牌同次写入；登录换新、刷新沿用

    func testLoginEpochIsWrittenWithTheTokensNewOnLoginKeptOnRefresh() async throws {
        let store = ScriptedSecureStore()
        let tokens = SecureSessionTokens(store: store, revocationFile: MemorySessionRevocationMarks())
        let harness = makeHarness(sessionStore: tokens)
        await login(harness)
        let first = try XCTUnwrap(harness.client.sessionLoginEpoch(credentialsReadable: true))
        XCTAssertEqual(try rawSession(store)["login_epoch"] as? String, first, "世代与令牌在同一个 Keychain 条目里")
        XCTAssertEqual(store.writes(tokensAccount), 1, "一次写入")
        XCTAssertEqual(harness.client.loginEpoch(forAccount: "user-a", credentialsReadable: true), first)
        XCTAssertNil(harness.client.loginEpoch(forAccount: "user-b", credentialsReadable: true), "账号不是它：不给")
        XCTAssertNil(harness.client.sessionLoginEpoch(credentialsReadable: false), "凭据不可读：未知")

        // 刷新：getMe 10002 → 刷新成功 → 重放；世代沿用
        StubURLProtocol.install { request in
            if request.path == "/v1/auth/refresh" {
                return ok(refreshData(access: "access-2"))
            }
            return request.header("Authorization") == "Bearer access-2" ? ok("{}") : fail(10002, status: 401)
        }
        let replayed = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertTrue(replayed.isSuccess)
        XCTAssertEqual(try tokens.readSession()?.access, "access-2")
        XCTAssertEqual(harness.client.sessionLoginEpoch(credentialsReadable: true), first, "刷新沿用登录世代")

        // 同账号重新登录：换新世代
        harness.client.signOut()
        await login(harness)
        let second = try XCTUnwrap(harness.client.sessionLoginEpoch(credentialsReadable: true))
        XCTAssertNotEqual(second, first, "登录换新")
    }

    // MARK: - 世代与会话可用性同口径（教训 2、9）

    func testLoginEpochIsUnknownWhenQuarantinedUnreadableCorruptOrBarrierRaised() async throws {
        let store = ScriptedSecureStore()
        let tokens = SecureSessionTokens(store: store, revocationFile: MemorySessionRevocationMarks())
        let harness = makeHarness(sessionStore: tokens)
        await login(harness)
        XCTAssertNotNil(harness.client.sessionLoginEpoch(credentialsReadable: true))

        store.failReads = [tokensAccount]
        XCTAssertNil(harness.client.sessionLoginEpoch(credentialsReadable: true), "令牌读不出：未知")
        store.failReads = [markAccount]
        // 冷启动（还没确认过「没有标记」的实例）：标记读不出 → 会话读不出、世代未知（同一实例确认没有标记后不再重读，标记只由本进程写，
        // 任何实例落标记都会让确认失效）
        let cold = makeHarness(sessionStore: SecureSessionTokens(
            store: store,
            revocationFile: MemorySessionRevocationMarks()
        ))
        XCTAssertNil(cold.client.sessionLoginEpoch(credentialsReadable: true), "撤销标记读不出：未知")
        store.failReads = []
        XCTAssertNotNil(cold.client.sessionLoginEpoch(credentialsReadable: true), "不缓存失败：恢复后可读")
        XCTAssertNotNil(harness.client.sessionLoginEpoch(credentialsReadable: true), "恢复后回到同一世代")

        // 撤回禁读屏障（撤回同意 / 切换环境）竖着：不读令牌、世代未知
        let before = store.reads(tokensAccount)
        harness.client.invalidateSessions()
        XCTAssertNil(harness.client.sessionLoginEpoch(credentialsReadable: true))
        XCTAssertEqual(store.reads(tokensAccount), before, "屏障竖着时不读令牌")

        // 隔离（清会话删除失败）：世代未知
        let other = makeHarness(sessionStore: tokens)
        StubURLProtocol.install { _ in ok(loginData(access: "x", scope: "full", user: "user-a")) }
        _ = await other.client.send(ApiCall(operationId: "loginBySms", body: "{}"))
        XCTAssertNotNil(other.client.sessionLoginEpoch(credentialsReadable: true))
        store.failRemoves = [tokensAccount]
        other.client.signOut()
        XCTAssertNil(other.client.sessionLoginEpoch(credentialsReadable: true), "隔离中：未知")
        XCTAssertNotNil(store.raw(tokensAccount), "令牌还在盘上")

        // 内容损坏：未知
        store.failRemoves = []
        try store.set(Data("{\"access\":\"a\",\"refresh\":\"r\",\"scope\":\"weird\"}".utf8), forAccount: tokensAccount)
        let third = makeHarness(sessionStore: SecureSessionTokens(store: store))
        XCTAssertNil(third.client.sessionLoginEpoch(credentialsReadable: true), "非法作用域：整组隔离")
    }

    // MARK: - 撤销标记先于删除落盘、跨进程（教训 10、14）

    func testRevocationMarkIsCommittedBeforeTheTokenDeleteAndSurvivesRebuild() async throws {
        let store = ScriptedSecureStore()
        let file = MemorySessionRevocationMarks()
        let harness = makeHarness(sessionStore: SecureSessionTokens(store: store, revocationFile: file))
        await login(harness)
        let epoch = try XCTUnwrap(harness.client.sessionLoginEpoch(credentialsReadable: true))
        store.failRemoves = [tokensAccount]
        let fileEventsBefore = file.events.count
        harness.client.signOut()
        XCTAssertNotNil(store.raw(tokensAccount), "前提：令牌删不掉")
        let order = store.events.filter { $0 == "set:\(markAccount)" || $0 == "remove:\(tokensAccount)" }
        XCTAssertEqual(order.first, "set:\(markAccount)", "标记先于令牌删除提交")
        XCTAssertEqual(
            SessionRevocation.decode(String(data: try XCTUnwrap(store.raw(markAccount)), encoding: .utf8) ?? ""),
            "e:" + epoch, "标记撤销的是这一次登录"
        )
        XCTAssertEqual(Array(file.events.dropFirst(fileEventsBefore)), ["file.write"], "Keychain 标记已落、删除失败：独立介质补一份")

        // 未重新登录即重建进程（删除仍失败）：读不回旧会话与旧世代
        for _ in 0..<2 {
            let rebuilt = SecureSessionTokens(store: store, revocationFile: file)
            XCTAssertNil(try rebuilt.readSession(), "旧会话读不回")
            let client = makeHarness(sessionStore: rebuilt).client
            XCTAssertNil(client.sessionLoginEpoch(credentialsReadable: true))
            XCTAssertNil(client.isolatedAccount)
        }
        // 删除恢复：下一次读取删掉令牌与标记
        store.failRemoves = []
        XCTAssertNil(try SecureSessionTokens(store: store, revocationFile: file).readSession())
        XCTAssertNil(store.raw(tokensAccount))
        XCTAssertNil(store.raw(markAccount))
        XCTAssertTrue(file.stored.formal == nil && file.stored.temp == nil)
    }

    /// Keychain 整体不可写（标记与删除都失败）：先落独立介质，再尝试删令牌；每个截点的快照重建都读不回（Android F-AND-32 同口径）。
    func testWholeKeychainUnwritableIndependentMarkRevokesAcrossRebuildAndEveryInterruptPoint() async throws {
        let store = ScriptedSecureStore()
        let file = MemorySessionRevocationMarks()
        let harness = makeHarness(sessionStore: SecureSessionTokens(store: store, revocationFile: file))
        await login(harness)
        store.failWritesAll = true
        let fileEventsBefore = file.events.count
        var snapshots: [CutPoint] = []
        store.beforeRemove = { account, values in
            if account == SecureSessionTokens.keychainAccount {
                snapshots.append(CutPoint(label: "删除令牌入口", values: values, formal: file.stored.formal,
                                          temp: file.stored.temp))
            }
        }
        harness.client.signOut()
        XCTAssertEqual(file.events.dropFirst(fileEventsBefore).first, "file.write", "Keychain 标记写不进：先落独立介质")
        XCTAssertFalse(snapshots.isEmpty)
        XCTAssertNotNil(snapshots.first?.formal, "删除令牌的入口处独立介质标记已在")
        for cut in snapshots {
            let replay = ScriptedSecureStore(values: cut.values)
            let medium = MemorySessionRevocationMarks()
            medium.put(formal: cut.formal, temp: cut.temp)
            XCTAssertNil(try SecureSessionTokens(store: replay, revocationFile: medium).readSession(), cut.label)
        }
        // 独立介质只剩临时文件（改名前中断）也读不回
        let tempOnly = MemorySessionRevocationMarks()
        tempOnly.put(formal: nil, temp: file.stored.formal)
        XCTAssertNil(try SecureSessionTokens(store: ScriptedSecureStore(values: store.values), revocationFile: tempOnly)
            .readSession(), "只剩临时文件")
        // 未重登重建：读不回
        XCTAssertNil(try SecureSessionTokens(store: store, revocationFile: file).readSession())
        // 新登录（存储恢复）：换新世代、照常可用，残留标记不误伤
        store.failWritesAll = false
        let fresh = makeHarness(sessionStore: SecureSessionTokens(store: store, revocationFile: file))
        await login(fresh, access: "new-access")
        XCTAssertEqual(try SecureSessionTokens(store: store, revocationFile: file).readSession()?.access, "new-access")
    }

    /// 残余（rule-gaps G03）：Keychain 与独立介质都写不进时只剩进程内隔离，重建后旧会话读回。断言的是现状。
    func testResidualBothMediaUnwritableLeavesOnlyInProcessIsolation() async throws {
        let store = ScriptedSecureStore()
        let file = MemorySessionRevocationMarks()
        let harness = makeHarness(sessionStore: SecureSessionTokens(store: store, revocationFile: file))
        await login(harness)
        store.failWritesAll = true
        file.failWrites = true
        harness.client.signOut()
        XCTAssertNil(harness.client.isolatedAccount, "本进程隔离")
        XCTAssertNotNil(try SecureSessionTokens(store: store, revocationFile: file).readSession(), "残余：重建读回")
    }

    // MARK: - 标记完整性（教训 15、17）

    func testIncompleteOrCorruptMarksBlockAnySessionAndCompleteOldMarkSparesNewLogin() throws {
        let session = Data(
            "{\"access\":\"a\",\"refresh\":\"r\",\"scope\":\"full\",\"account\":\"u\",\"login_epoch\":\"E2\"}".utf8
        )
        let full = SessionRevocation.encode("e:E1")
        let bad: [(String, Data)] = [
            ("空", Data()),
            ("截断", Data(full.dropLast(3).utf8)),
            ("缺结束符", Data(full.replacingOccurrences(of: "|end", with: "").utf8)),
            ("摘要被改", Data(full.replacingOccurrences(of: "e:E1|4|", with: "e:E2|4|").utf8)),
            ("长度不符", Data(full.replacingOccurrences(of: "|4|", with: "|5|").utf8)),
            ("不是文本", Data([0xFF, 0xFE, 0x00])),
            ("短写", Data("e:E".utf8)),
            ("认不出的目标", Data(SessionRevocation.encode("z:E2").utf8)),
        ]
        for (label, mark) in bad {
            for place in ["keychain", "formal", "temp"] {
                let store = ScriptedSecureStore(values: [tokensAccount: session])
                let file = MemorySessionRevocationMarks()
                switch place {
                case "keychain": store.values[markAccount] = mark
                case "formal": file.put(formal: mark)
                default: file.put(formal: nil, temp: mark)
                }
                store.failRemoves = [tokensAccount]
                let tokens = SecureSessionTokens(store: store, revocationFile: file)
                XCTAssertNil(try tokens.readSession(), "\(label)（\(place)）：按撤销阻断")
            }
        }
        // 完整的旧标记（e:E1）不误伤新登录（E2）；s:E2 只放行 E2
        let store = ScriptedSecureStore(values: [tokensAccount: session, markAccount: Data(full.utf8)])
        let file = MemorySessionRevocationMarks()
        file.put(formal: Data(full.utf8), temp: Data(SessionRevocation.encode("s:E2").utf8))
        XCTAssertEqual(try SecureSessionTokens(store: store, revocationFile: file).readSession()?.loginEpoch, "E2")
        file.put(formal: Data(SessionRevocation.encode("s:E3").utf8))
        XCTAssertNil(try SecureSessionTokens(store: store, revocationFile: file).readSession(), "s:E3 撤销 E2")
    }

    /// 独立撤销记录只有明确不存在才算无标记：读不出抛错、阻断会话、不缓存成「无标记」（教训 17）；真实文件实现的 ENOTDIR / 目录。
    func testIndependentMarkOnlyExplicitAbsenceCountsAsNoMark() throws {
        let session = Data(
            "{\"access\":\"a\",\"refresh\":\"r\",\"scope\":\"full\",\"account\":\"u\",\"login_epoch\":\"E1\"}".utf8
        )
        let store = ScriptedSecureStore(values: [tokensAccount: session])
        let file = MemorySessionRevocationMarks()
        let tokens = SecureSessionTokens(store: store, revocationFile: file)
        file.failReads = true
        XCTAssertThrowsError(try tokens.readSession()) { XCTAssertEqual($0 as? SessionReadError, .readFailed) }
        XCTAssertThrowsError(try tokens.readSession(), "不缓存：再读仍查")
        // 查不了期间撤销落进了独立文件（另一实例清会话、Keychain 整体不可写）
        file.failReads = false
        file.put(formal: Data(SessionRevocation.encode("e:E1").utf8))
        XCTAssertNil(try tokens.readSession(), "恢复可读后重新核对并阻断")

        // 真实文件实现
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("fuios0712-marks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        XCTAssertEqual(
            try FileSessionRevocationMarks(url: temp.appendingPathComponent("missing/session.revoked")).read(), [],
            "父目录不存在 = 明确不存在"
        )
        let blocker = temp.appendingPathComponent("plain")
        try Data("x".utf8).write(to: blocker)
        XCTAssertThrowsError(
            try FileSessionRevocationMarks(url: blocker.appendingPathComponent("session.revoked")).read(), "ENOTDIR"
        )
        let directory = temp.appendingPathComponent("session.revoked")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertThrowsError(try FileSessionRevocationMarks(url: directory).read(), "标记位置是目录")
        let real = FileSessionRevocationMarks(url: temp.appendingPathComponent("ok/session.revoked"))
        try real.write(Data("m".utf8))
        XCTAssertEqual(try real.read(), [Data("m".utf8)])
        try real.delete()
        XCTAssertEqual(try real.read(), [])
    }

    // MARK: - 持久化会话完整校验（教训 13）

    func testInvalidPersistedSessionFieldsIsolateTheWholeSessionEvenWhenDeleteFails() async throws {
        let cases: [(String, String)] = [
            ("空 access", #"{"access":"","refresh":"r","scope":"full"}"#),
            ("空 refresh", #"{"access":"a","refresh":"","scope":"full"}"#),
            ("缺 refresh", #"{"access":"a","scope":"full"}"#),
            ("非法作用域", #"{"access":"a","refresh":"r","scope":"weird"}"#),
            ("缺作用域", #"{"access":"a","refresh":"r"}"#),
            ("作用域类型错", #"{"access":"a","refresh":"r","scope":1}"#),
            ("令牌类型错", #"{"access":1,"refresh":"r","scope":"full"}"#),
            ("空账号", #"{"access":"a","refresh":"r","scope":"full","account":""}"#),
            ("账号类型错", #"{"access":"a","refresh":"r","scope":"full","account":7}"#),
            ("空世代", #"{"access":"a","refresh":"r","scope":"full","login_epoch":""}"#),
            ("世代类型错", #"{"access":"a","refresh":"r","scope":"full","login_epoch":true}"#),
            ("不是对象", #"["a","r","full"]"#),
        ]
        for (label, json) in cases {
            let store = ScriptedSecureStore(values: [tokensAccount: Data(json.utf8)])
            store.failRemoves = [tokensAccount]
            for _ in 0..<2 {
                let tokens = SecureSessionTokens(store: store, revocationFile: MemorySessionRevocationMarks())
                XCTAssertThrowsError(try tokens.readSession(), label) {
                    XCTAssertEqual($0 as? SessionReadError, .corrupted, label)
                }
                let harness = makeHarness(sessionStore: tokens)
                StubURLProtocol.install { _ in ok() }
                _ = await harness.client.send(ApiCall(operationId: "getMe"))
                XCTAssertTrue(StubURLProtocol.requests.allSatisfy { $0.header("Authorization") == nil }, label)
                XCTAssertNil(harness.client.sessionLoginEpoch(credentialsReadable: true), label)
            }
        }
        // 合法会话（含升级前没有世代、没有账号）照常可读
        for json in [
            #"{"access":"a","refresh":"r","scope":"deletion_only"}"#,
            #"{"access":"a","refresh":"r","scope":"full","account":null,"login_epoch":null}"#,
        ] {
            let store = ScriptedSecureStore(values: [tokensAccount: Data(json.utf8)])
            XCTAssertNotNil(try SecureSessionTokens(store: store).readSession(), json)
        }
        // 写入同样校验：写不出之后会被隔离的会话
        let tokens = SecureSessionTokens(store: ScriptedSecureStore())
        XCTAssertThrowsError(try tokens.save(access: "a", refresh: "r", scope: "weird", account: "u"))
        XCTAssertThrowsError(try tokens.save(access: "", refresh: "r", scope: "full", account: "u"))
    }

    // MARK: - 清会话路径零读取（教训 16）

    func testClearingPathsNeverRereadForbiddenCredentials() async throws {
        // 撤回待清理 / 切换环境：网络层竖起禁读屏障后清会话；清理器（另一个实例，从没读过）清令牌
        let store = ScriptedSecureStore()
        let file = MemorySessionRevocationMarks()
        let harness = makeHarness(sessionStore: SecureSessionTokens(store: store, revocationFile: file))
        await login(harness)
        let epoch = try XCTUnwrap(harness.client.sessionLoginEpoch(credentialsReadable: true))
        let before = store.reads(tokensAccount)
        harness.client.invalidateSessions()
        harness.client.signOut()
        store.failRemoves = [tokensAccount]
        let cleaned: Bool = await MainActor.run {
            let cleaner = SessionTokensCleaner(tokens: SecureSessionTokens(store: store, revocationFile: file))
            return (try? cleaner.cleanForEnvironmentSwitch()) != nil
        }
        XCTAssertFalse(cleaned, "删除失败：清理器报错")
        XCTAssertEqual(store.reads(tokensAccount), before, "清会话路径不读令牌")
        // 没读过的实例写「待核验」标记（撤销任何会话）；读过的实例（网络层）写的是这一次登录
        let marks = try file.read().compactMap { String(data: $0, encoding: .utf8).flatMap(SessionRevocation.decode) }
        XCTAssertTrue(marks.contains(SessionRevocation.anySession), "不知道是哪一份：写 *")
        XCTAssertNil(try SecureSessionTokens(store: store, revocationFile: file).readSession(), "删除失败后重建读不回")
        _ = epoch
    }
}

/// 一个截点的持久化快照（Keychain 全部内容 + 独立介质的正式 / 临时文件）。
private struct CutPoint {
    let label: String
    let values: [String: Data]
    let formal: Data?
    let temp: Data?
}
