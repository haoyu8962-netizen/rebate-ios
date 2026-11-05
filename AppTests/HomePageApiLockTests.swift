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
    static let lockedCommit = "00deded0ef6f62716fcd8ca62f549dfdc1da4995"
    static let designLockCommit = "18ad5b4aa66235855a92e68f40f8b8ef7822f4dc"

    /// 鸿蒙 main contract.lock（ee878ac3…cd03，与安卓 84b4dde 整文件相同）里与 iOS 同名的 23 项。
    static let sameNameHashes: [String: String] = [
        "contracts/agent-stream.schema.json":
            "895bd7458fc9185e5b9022e316fc4313b90b84f91d75f72227bd3e907139fb9e",
        "contracts/apps.json":
            "b7c3e07ad63d52e7ec5b6021b13dc2003cabb0755adffa4af5079aa3ac2267dd",
        "contracts/bridge.schema.json":
            "553c7f79b4a803fcdab70d6efa5c0d631f9a8a3263f9fd7f373a053c654dc1e3",
        "contracts/enums/admin.json":
            "0a31468548e9a376a822e896465781033bfd37e89cea123d950b42e6a6ca3f72",
        "contracts/enums/fund.json":
            "609f58a2598222e9b9c88364a77662c9c7efce5612fad7f84b43c133b62e3f5e",
        "contracts/enums/identity.json":
            "1fc21235dbe4c642da2bb698ca03a100828dba5366184fd5ec2e1bf92da45a19",
        "contracts/enums/ops.json":
            "cf931b2a615086bc3a37e781041baf2ab937fbce8457e4da04f029ef77f7ffc6",
        "contracts/enums/order.json":
            "9c520a728229f8636b5d1c4556719d61d8cee0d2fd7d5739fb07580134e3007e",
        "contracts/enums/pay.json":
            "d77e1a6f1ccfb414500cf2c420e9dfa6babcab14441a533ebf6ec06449e297f1",
        "contracts/enums/platform.json":
            "cc4043466111363f8273dc48164f90d489b7e0e14fec5769d8a1e43af2b36a98",
        "contracts/enums/trade.json":
            "2baee49aac11b903b942fedf65835f6528baed8ba99c33aaad6afbcfc0f15fd8",
        "contracts/error-codes.json":
            "c73af4261ea443dcd4ae07aeb22ded9ec844c85ae881555cdb5b01f48acd2540",
        "contracts/openapi.json":
            "366e96cf0793c7a58feee7fd7ecdfec6b4baa97677c4967cc52fa6e24b23655b",
        "contracts/routes.json":
            "ab9b31952c979f61b40608edc982423423a38617f40b0937e3541e0766a31b06",
        "contracts/texts.default.json":
            "23eac6f8bf02693840a02ac4828b226bff58a4458ffae467445ba5e2bb9881cc",
        "design/design-tokens.json":
            "cae7499e21496fbeaddc190c7d6170dbf03161436e0e85062d8d4373670f42f1",
        "specs/app-stores.json":
            "19ad122d9cf7b92044819edd30c615f4f111668a0388eea28814394e130822cf",
        "specs/client-public-ids.json":
            "1ef9e57a1a77dc849899ec72f53d7911ff57b6583cb3eaf78527a3bc6fb9f7b3",
        "specs/client-security-baseline.json":
            "25c48e505e0dee4afd7279ae9b7cbb029dbacb2585e68a7c52d3ad7e2738ff90",
        "specs/device-hash.vectors.json":
            "9c679ba2d4a7a0c5723602dd8879f251ae5250663702b3ef6e3ad0ba359065aa",
        "specs/events.json":
            "2f3628e7a02e48f10269d60e54f5116a9934e500582e9aa6fefb55587dfe8d3a",
        "specs/request-sign.vectors.json":
            "42512225bf4ada0642b761176d5cf5010c44c0d168f99b087166459518c1cbf9",
        "specs/system-permissions.json":
            "bd7c09ae405d0ed5493704be0a51e59ec2628bf7a0c24c2433c39acfe8175b2f",
    ]

    private func lock() throws -> [String: Any] {
        let data = try Data(contentsOf: SourceScan.root().appendingPathComponent("contract.lock"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testLockPinsTheSharedCommitAndKeepsDesignTokens() throws {
        let lock = try lock()
        XCTAssertEqual((lock["rebate_platform"] as? [String: Any])?["commit"] as? String, Self.lockedCommit)
        XCTAssertEqual((lock["design_tokens"] as? [String: Any])?["commit"] as? String, Self.designLockCommit,
                       "design_tokens 本单不升（DS-02-iOS）")
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
    func testSharedVectorsMatchTheOtherPlatforms() throws {
        let root = try SourceScan.root().appendingPathComponent("specs")
        let digest: (String) throws -> String = { name in
            SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent(name)))
                .map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(try digest("network-vectors.json"),
                       "ac5220c17cc31ee0660eeed80e90cedec87d091261cd35116bb958ff1bf4f160")
        XCTAssertEqual(try digest("home-sdui-vectors.json"),
                       "70cab00a88a26ce45bcd078bd10178a3f383fa3f07ef6cc14bced87a1d9f100e")
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
