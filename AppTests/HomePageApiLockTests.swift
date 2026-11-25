@testable import Couli
import CryptoKit
import Foundation
import Generated
import XCTest

/// FU-X-HOME-PAGE-API-ios 升锁组（D10-607 D1，CT-LOCK-02 口径；brief §2.1、§6 第 2 条推荐 A）与升锁连带适配：
/// - contract.lock 锁 rebate-platform 00deded0ef6f（与鸿蒙 dc9f4b7、安卓 84b4dde 同一提交），design_tokens 不动（DS-02-iOS 另升）；
/// - iOS 的 23 个快照文件与两端 contract.lock 里同名项逐字节相同（两端多出的 15 个 agent-streams 样例 iOS 不拷，整文件 sha256 不同属预期）；
/// - 文案占位符：草稿表里与契约同名的键，占位符名必须与契约一致（鸿蒙 FU-HM-LOCK-PLACEHOLDERS 同口径）；login.code.countdown 代入 n；
/// - 包内 withdraw.sla_text 随新锁为 BR-TEXT-07 原文；
/// - 刷新失败的轻提示改用 DS 的 couliToast（D10-643），不再自绘。
/// 升锁前（锁 a7c9f1f）本文件多数用例红属预期，由实现者的提交 1（升锁）转绿。
@MainActor
final class HomePageApiLockTests: XCTestCase {
    static let lockedCommit = "6c97062570dadce304821b905e5a31a5c40acbe2"
    /// DS-02-iOS-1 按 #24 换值：令牌锁升到 couli f088f04（v0.5.1，D10-665 ①）；安卓、鸿蒙 TOKENS-PIPE 升到同一提交。
    static let designLockCommit = "f088f0473230d1e70232b8a246b92ef53d723929"

    /// 与 iOS 同名的 23 项。FU-IOS-CONTRACT-LOCK-6c97062（#24）：换成 sync 到 6c97062 后实算的 sha256（改 7 项），与安卓升锁分支
    /// task/FU-AND-CONTRACT-LOCK-6c97062（3fd6a5c）contract.lock 的同名项逐项相同、与安卓 CtaKeyVectorTest.SAME_NAME_SHA256 对上。
    static let sameNameHashes: [String: String] = [
        "contracts/agent-stream.schema.json":
            "c7c6960cd0d606ef3b07757f44aad653681788d5ed1338d9ec4ea4d728c7a38d",
        "contracts/apps.json":
            "921470f2784b2eb41496e3ee890a51a454ddc27ae7e869587062a9e063a0e167",
        "contracts/bridge.schema.json":
            "65605d08e15edda6a49036413b534a77f89202cedae7398d145e47b81833a874",
        "contracts/enums/admin.json":
            "0c77839beff58843dde1d2b73e152a9daa041ec97d521d9ba550d1ab35cf0bd9",
        "contracts/enums/fund.json":
            "fbdfbe6f4698b6e55d4ce613774a6d7dd1477b042fe33b30988f05b0549439ac",
        "contracts/enums/identity.json":
            "299bfc28454fb752059aede6c648decfdb8dc83b36b7cc85625f04ef7bb363ce",
        "contracts/enums/ops.json":
            "de06744044d913f62403fbaf4cbfa9ebc26630740fe46c645bfa03a0c8ea02ac",
        "contracts/enums/order.json":
            "10cb34f7028892b0c4a2a30a7523e1d203017a3bdb1c6abe0ded1d6cda78a9e0",
        "contracts/enums/pay.json":
            "d77e1a6f1ccfb414500cf2c420e9dfa6babcab14441a533ebf6ec06449e297f1",
        "contracts/enums/platform.json":
            "cc4043466111363f8273dc48164f90d489b7e0e14fec5769d8a1e43af2b36a98",
        "contracts/enums/trade.json":
            "2baee49aac11b903b942fedf65835f6528baed8ba99c33aaad6afbcfc0f15fd8",
        "contracts/error-codes.json":
            "a312384e185aefcc1db7f0538ac98b63082b064a3c9fe77f19a0a889b6a398db",
        "contracts/openapi.json":
            "7be6e8303ebd7531fbe70138d9f1f6768321f9e42115a46f24a99e3aefc11863",
        "contracts/routes.json":
            "4e578baef05df6ae9da7eb4576a2c00ef5b9b7e34f802f33ec6eabfbd5c7e2d8",
        "contracts/texts.default.json":
            "78530d1abc70e17b771e4bde9a627f01d5032856c7ed3ad8eee9f94daadb269b",
        "design/design-tokens.json":
            "58b5e1ff8a0481381cf428b284d38b2a96b5128641912acf37d54e7e6cf63c93",
        "specs/app-stores.json":
            "19ad122d9cf7b92044819edd30c615f4f111668a0388eea28814394e130822cf",
        "specs/client-public-ids.json":
            "1ef9e57a1a77dc849899ec72f53d7911ff57b6583cb3eaf78527a3bc6fb9f7b3",
        "specs/client-security-baseline.json":
            "25c48e505e0dee4afd7279ae9b7cbb029dbacb2585e68a7c52d3ad7e2738ff90",
        "specs/device-hash.vectors.json":
            "9c679ba2d4a7a0c5723602dd8879f251ae5250663702b3ef6e3ad0ba359065aa",
        "specs/events.json":
            "87f144bee6ce0f3d7025b9ab56ac0193ea61f9be26fe0ba2adde2bae0bec15a5",
        "specs/request-sign.vectors.json":
            "42512225bf4ada0642b761176d5cf5010c44c0d168f99b087166459518c1cbf9",
        "specs/system-permissions.json":
            "e5040ac178dc76fe2be510351827425a54d65b1a4cd616683237241a38a479b5",
    ]

    private func lock() throws -> [String: Any] {
        let data = try Data(contentsOf: SourceScan.root().appendingPathComponent("contract.lock"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testLockPinsTheSharedCommitAndKeepsDesignTokens() throws {
        let lock = try lock()
        XCTAssertEqual((lock["rebate_platform"] as? [String: Any])?["commit"] as? String, Self.lockedCommit)
        XCTAssertEqual((lock["design_tokens"] as? [String: Any])?["commit"] as? String, Self.designLockCommit,
                       "design_tokens 锁在 f088f04（DS-02-iOS-1）")
    }

    /// 23 个同名快照：lock 的 files 与两端逐项相同，快照文件实算的 sha256 也相同（三端逐字节一致的 iOS 口径）。
    func testSnapshotFilesMatchTheOtherPlatformsByteForByte() throws {
        let files = try XCTUnwrap(try lock()["files"] as? [String: String])
        XCTAssertEqual(files, Self.sameNameHashes, "contract.lock files 与两端同名项不一致")
        let root = try SourceScan.root().appendingPathComponent("contracts/snapshot")
        for (path, expected) in Self.sameNameHashes {
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(actual, expected, path)
        }
    }

    /// 三端同组向量：network-vectors 整文件与鸿蒙 / 安卓逐字节相同（第 125 行 30901 / pay_disabled，编排 11-04 05:35 认可）；
    /// home-sdui-vectors 三端本来逐字节相同、本单不改；wallet-vectors 第 243、261 行取新子键（11:24 认可）。
    /// FU-IOS-HOME-ENTRY-OBJECT-FIELDS（#24，D10-3094）：home-sdui-vectors 第 1061 行徽标换对象形态，
    /// 整份与安卓 1f87039 逐字节相同，sha256 70cab00a… → 53f478fb…。
    func testSharedVectorsMatchTheOtherPlatforms() throws {
        let root = try SourceScan.root().appendingPathComponent("specs")
        let digest: (String) throws -> String = { name in
            SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent(name)))
                .map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(try digest("network-vectors.json"),
                       "ac5220c17cc31ee0660eeed80e90cedec87d091261cd35116bb958ff1bf4f160")
        XCTAssertEqual(try digest("home-sdui-vectors.json"),
                       "53f478fb6473d2d5d985df703c4820ab2d72b5735b2ea5d5a552bb6762efce74")
        let wallet = try String(contentsOf: root.appendingPathComponent("wallet-vectors.json"), encoding: .utf8)
            .components(separatedBy: "\n")
        XCTAssertTrue(wallet[242].hasPrefix(#"    {"name":"G03_G07_payee_daily_count","blockCode":30303,"#))
        XCTAssertTrue(wallet[242].hasSuffix(
            #""expect":{"actionRaw":"notice","textKey":"error.30303.payee_daily_count","fallbackUsed":false}},"#
        ))
        XCTAssertTrue(wallet[260].hasPrefix(#"    {"name":"G07_payee_daily_count","#))
        XCTAssertTrue(wallet[260].hasSuffix(
            #""expect":{"textKey":"error.30303.payee_daily_count","useFallback":false}},"#
        ))
    }

    /// 生成表随新锁：getPage、listPageSectionItems 都在；InviteLink / InviteBackfill 已登记（P1 由 HomePageApiP1RouteTests 管）。
    func testGeneratedTablesFollowTheNewLock() {
        XCTAssertNotNil(ApiOperations.byId("getPage"))
        XCTAssertNotNil(ApiOperations.byId("listPageSectionItems"))
        XCTAssertNotNil(Routes.spec("InviteLink"))
        XCTAssertNotNil(Routes.spec("InviteBackfill"))
    }

    /// 草稿表里与契约同名的键：占位符名（{name}）集合必须与契约文案相同——契约优先取字时，代入的名字就是契约的名字。
    /// 新锁里 login.code.countdown 是 {n}（草稿是 {sec}）；deletion.cooling.deadline 是 {cancel_deadline}（iOS 无草稿）。
    func testDraftPlaceholdersMatchTheContract() throws {
        let drafts = [
            "App/Sources/Update/UpdateDraftTexts.swift", "App/Sources/Shell/ShellDraftTexts.swift",
            "App/Sources/Trade/TradeDraftTexts.swift", "App/Sources/Search/SearchDraftTexts.swift",
            "App/Sources/Login/LoginDraftTexts.swift", "App/Sources/Clipboard/ClipboardDraftTexts.swift",
            "Packages/Core/Sources/HomeCore/HomeTextDrafts.swift",
            "Packages/Core/Sources/WalletCore/WalletDraftTable.swift",
            "Packages/Core/Sources/WalletCore/WalletDraftTable+Records.swift",
            "Packages/Core/Sources/MeCore/MeDraftTexts.swift",
            "Packages/Core/Sources/MeCore/MeDraftTable.swift",
        ]
        let pair = try NSRegularExpression(pattern: #""([a-z0-9_.]+)"\s*:\s*"((?:[^"\\]|\\.)*)""#)
        var compared = 0
        var mismatches: [String] = []
        for path in drafts {
            guard let text = try? SourceScan.read(path) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in pair.matches(in: text, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: text),
                      let valueRange = Range(match.range(at: 2), in: text) else { continue }
                let key = String(text[keyRange])
                guard let contract = DefaultTexts.text(key) else { continue }
                compared += 1
                if Self.placeholders(String(text[valueRange])) != Self.placeholders(contract) {
                    mismatches.append("\(path)：\(key)")
                }
            }
        }
        XCTAssertGreaterThan(compared, 50, "比对到的同名键太少，扫描有误")
        XCTAssertEqual(mismatches, [], "草稿占位符与契约不一致")
    }

    static func placeholders(_ text: String) -> Set<String> {
        let regex = try? NSRegularExpression(pattern: #"\{([a-z0-9_]+)\}"#)
        let range = NSRange(text.startIndex..., in: text)
        return Set((regex?.matches(in: text, range: range) ?? []).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        })
    }

    /// login.code.countdown：契约是 {n}；登录、绑手机、step-up 三处调用都代入 n（不改会显示字面量 {n}，鸿蒙 14:48 升锁回归）。
    func testCodeCountdownSubstitutesN() throws {
        XCTAssertEqual(DefaultTexts.text("login.code.countdown"), "{n} 秒后可重新获取", "前提：新锁的契约文案")
        XCTAssertEqual(LoginDraftTexts.format("login.code.countdown", ["n": "59"]), "59 秒后可重新获取")
        for path in [
            "Packages/Features/Sources/Login/LoginView+Code.swift",
            "Packages/Features/Sources/Login/BindPhoneView+Fields.swift",
            "Packages/Features/Sources/Wallet/StepUpSheet.swift",
        ] {
            let text = try SourceScan.read(path)
            XCTAssertNil(text.range(of: "\"sec\""), "\(path) 仍按 sec 代入倒计时")
            XCTAssertNotNil(text.range(of: "\"n\""), "\(path) 没有按 n 代入倒计时")
        }
    }

    /// 包内 withdraw.sla_text 随新锁为 BR-TEXT-07 原文（服务端不下发时资金页显示的时效句）。
    func testBundledSlaTextIsTheRuleText() throws {
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(DefaultConfig.json.utf8)) as? [String: Any])
        let texts = try XCTUnwrap(config["texts"] as? [String: Any])
        XCTAssertEqual(texts["withdraw.sla_text"] as? String, "人工审核，工作日 24 小时内处理，节假日顺延")
    }

    /// D10-643：首页下拉刷新失败的轻提示用 DS 的 couliToast（HomeController 的 toast 模型不变，只换呈现层），不再自绘 overlay。
    func testHomeRefreshToastUsesCouliToast() throws {
        let text = try SourceScan.read("Packages/Features/Sources/Home/HomeSduiScreen.swift")
        XCTAssertNotNil(text.range(of: ".couliToast("), "首页没有用 couliToast")
        XCTAssertNil(text.range(of: "Text(verbatim: toast.message)"), "首页仍自绘轻提示")
        XCTAssertNil(text.range(of: "Task.sleep(for: .seconds(3))"), "首页仍自己计时消失")
    }
}
