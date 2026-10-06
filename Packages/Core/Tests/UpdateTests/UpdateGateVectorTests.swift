import Foundation
import XCTest
@testable import Update

/*
 实现前测试；只读会话未编译或运行。

 接线约定：
 - UpdateGate 的构造器、方法、Swift 参数标签严格按 brief.md §2.1。
 - 实现提供 MemoryUpdateStore()；同一实例可供重建后的 Gate 复用。
   不规定存储字段、序列化格式或生产持久化技术。
 - clock: () -> Int64；所有 now 为毫秒；platform/channel 接受原始字符串。
 - 内部列表元素命名为 UpdateStoreListing(store: String, version: String)。
 - UpdateCheckResult 按 brief 中的字段提供同名初始化参数。
 - installSource 是外层已核对并归一化的来源商店键；canOpen 是能力替身。
   示例 huawei/xiaomi 不代表当前 app-stores.yaml 已配置真实映射。
 - JSON result 是 check 响应的 data，不是内部 DTO：
   listed_version -> version；null 上架版本不进入内部已知版本列表。
   recheckIntervalSec 来自配置，测试使用 BR-ID-01 包内默认 1800。
 - prompt 的 state.targetVersion/暂不更新记录键为 latest；
   prompt 选店门槛按 BR-ID-01 为 recommended，force 为 minSupported。
 - coldStart 重建 Gate、复用 store，验证持久化；其余步骤复用 Gate。
 - Core 包需登记 Update 与 UpdateTests target；不调用真实网络或商店。
 */

private struct UpdateVectorFile: Decodable {
    let version: Int
    let sources: [String]
    let versionCompare: [ComparisonVector]
    let gate: [GateVector]
    let pickStore: [StoreVector]
    let gaps: [String]
}

private struct ComparisonVector: Decodable {
    let a: String
    let b: String
    let expect: Int
}

private struct ListingData: Decodable {
    let store: String
    let listedVersion: String?

    enum CodingKeys: String, CodingKey {
        case store
        case listedVersion = "listed_version"
    }
}

private struct CheckData: Decodable {
    let minSupported: String?
    let recommended: String?
    let latest: String
    let defaultStore: String
    let stores: [ListingData]

    enum CodingKeys: String, CodingKey {
        case minSupported = "min_supported_version"
        case recommended = "recommended_version"
        case latest = "latest_version"
        case defaultStore = "default_store"
        case stores
    }
}

private struct ExpectedState: Decodable {
    let shouldCheck: Bool?
    let status: String
    let showPrompt: Bool
    let targetVersion: String?
}

private struct GateStep: Decodable {
    let op: String
    let atMillis: Int64
    let result: CheckData?
    let expect: ExpectedState
}

private struct GateVector: Decodable {
    let name: String
    let appVersion: String
    let steps: [GateStep]
    let note: String
}

private struct ExpectedChoice: Decodable {
    let storeKey: String?
    let unavailable: Bool
}

private struct StoreVector: Decodable {
    let name: String
    let appVersion: String
    let installSource: String?
    let result: CheckData
    let canOpen: [String]
    let mode: String
    let expect: ExpectedChoice
    let note: String
}

private final class VectorClock {
    var nowMillis: Int64 = 0
}

private struct FixtureError: Error {
    let message: String
}

final class UpdateGateVectorTests: XCTestCase {
    func testVersionComparisonVectors() throws {
        let root = try vectors()

        for (index, row) in root.versionCompare.enumerated() {
            let label = "versionCompare[\(index)] \(row.a) / \(row.b)"
            XCTAssertTrue([-1, 0, 1].contains(row.expect), label)
            XCTAssertEqual(
                UpdateGate.compareVersions(a: row.a, b: row.b),
                row.expect,
                label
            )
        }
    }

    func testGateVectors() throws {
        for row in try vectors().gate {
            let label = "\(row.name): \(row.note)"
            XCTAssertFalse(row.steps.isEmpty, label)

            let store = MemoryUpdateStore()
            let clock = VectorClock()

            func makeGate() -> UpdateGate {
                UpdateGate(
                    store: store,
                    clock: { clock.nowMillis },
                    appVersion: row.appVersion,
                    platform: "android",
                    channel: "official",
                    installSource: "huawei"
                )
            }

            var gate = makeGate()

            for (index, step) in row.steps.enumerated() {
                let context = "\(label) step[\(index)] \(step.op)"
                clock.nowMillis = step.atMillis
                var shouldCheck: Bool?

                switch step.op {
                case "coldStart":
                    gate = makeGate()
                    shouldCheck = gate.onColdStart(now: clock.nowMillis)

                case "foreground":
                    shouldCheck = gate.onForeground(now: clock.nowMillis)

                case "apply":
                    let input = try XCTUnwrap(step.result, context)
                    gate.apply(
                        result: adapt(input),
                        now: clock.nowMillis
                    )

                case "applyFailure":
                    gate.applyFailure(now: clock.nowMillis)

                case "on10405":
                    // 错误入口只消费最低版本，不把错误登记为检查成功。
                    gate.on10405(
                        minSupported: step.result?.minSupported,
                        now: clock.nowMillis
                    )

                case "dismissPrompt":
                    gate.dismissPrompt(now: clock.nowMillis)

                default:
                    throw FixtureError(
                        message: "\(context): 未知 op，不能静默跳过"
                    )
                }

                XCTAssertEqual(
                    shouldCheck,
                    step.expect.shouldCheck,
                    "\(context): shouldCheck"
                )

                let actual = gate.state(now: clock.nowMillis)
                XCTAssertEqual(
                    actual.statusRaw,
                    step.expect.status,
                    "\(context): statusRaw"
                )
                XCTAssertEqual(
                    actual.showPrompt,
                    step.expect.showPrompt,
                    "\(context): showPrompt"
                )
                XCTAssertEqual(
                    actual.targetVersion,
                    step.expect.targetVersion,
                    "\(context): targetVersion"
                )
            }
        }
    }

    func testStoreChoiceVectors() throws {
        for row in try vectors().pickStore {
            let label = "\(row.name): \(row.note)"
            let clock = VectorClock()
            clock.nowMillis = 1000

            let gate = UpdateGate(
                store: MemoryUpdateStore(),
                clock: { clock.nowMillis },
                appVersion: row.appVersion,
                platform: "android",
                channel: "official",
                installSource: row.installSource
            )
            let result = adapt(row.result)
            gate.apply(result: result, now: clock.nowMillis)

            let expectedStatus: String
            switch row.mode {
            case "force":
                expectedStatus = "below_min"
            case "prompt":
                expectedStatus = "below_recommended"
            default:
                throw FixtureError(message: "\(label): 未知 mode")
            }

            XCTAssertEqual(
                gate.state(now: clock.nowMillis).statusRaw,
                expectedStatus,
                "\(label): 场景前置状态"
            )

            var attempted: [String] = []
            let choice = gate.pickStore(
                result: result,
                now: clock.nowMillis,
                canOpen: { storeKey in
                    attempted.append(storeKey)
                    return row.canOpen.contains(storeKey)
                }
            )

            XCTAssertEqual(
                choice.storeKey,
                row.expect.storeKey,
                "\(label): storeKey"
            )
            XCTAssertEqual(
                choice.unavailable,
                row.expect.unavailable,
                "\(label): unavailable"
            )
            XCTAssertEqual(
                attempted.count,
                Set(attempted).count,
                "\(label): 同一家候选只能检查一次；实际 \(attempted)"
            )
        }
    }

    private func adapt(_ input: CheckData) -> UpdateCheckResult {
        // 只做报文字段投影，不在测试适配器里实现版本判定或选店。
        let listings = input.stores.compactMap { entry -> UpdateStoreListing? in
            guard let version = entry.listedVersion else {
                return nil
            }
            return UpdateStoreListing(store: entry.store, version: version)
        }

        return UpdateCheckResult(
            minSupported: input.minSupported,
            recommended: input.recommended,
            latest: input.latest,
            defaultStore: input.defaultStore,
            stores: listings,
            recheckIntervalSec: 1800
        )
    }

    private func vectors() throws -> UpdateVectorFile {
        let file = try repositoryRoot()
            .appendingPathComponent("specs/update-vectors.json")
        let root = try JSONDecoder().decode(
            UpdateVectorFile.self,
            from: Data(contentsOf: file)
        )

        XCTAssertEqual(root.version, 1, file.path)
        XCTAssertFalse(root.sources.isEmpty, file.path)
        XCTAssertFalse(root.gaps.isEmpty, file.path)
        XCTAssertFalse(root.versionCompare.isEmpty, file.path)
        XCTAssertFalse(root.gate.isEmpty, file.path)
        XCTAssertFalse(root.pickStore.isEmpty, file.path)

        for names in [
            root.gate.map(\.name),
            root.pickStore.map(\.name),
        ] {
            XCTAssertEqual(names.count, Set(names).count, "向量名称重复")
            XCTAssertTrue(names.allSatisfy { !$0.isEmpty }, "向量名称不能为空")
        }
        XCTAssertTrue(root.gate.allSatisfy { !$0.note.isEmpty })
        XCTAssertTrue(root.pickStore.allSatisfy { !$0.note.isEmpty })
        return root
    }

    private func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .standardizedFileURL

        while true {
            let lock = directory.appendingPathComponent("contract.lock")
            if FileManager.default.fileExists(atPath: lock.path) {
                return directory
            }

            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path {
                throw FixtureError(
                    message: "从 \(#filePath) 向上找不到含 contract.lock 的仓库根"
                )
            }
            directory = parent
        }
    }
}
