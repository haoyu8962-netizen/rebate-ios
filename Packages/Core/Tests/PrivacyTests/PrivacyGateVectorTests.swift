import Foundation
import XCTest
@testable import Privacy

// 实现前测试；只读会话未编译或运行。
// 接线约定，不改变 brief.md §2.1 已指定的构造器和方法标签：
// 1. PrivacyStore 是引用类型协议，具有可读写字段：
//    decisionRaw: String、consentedVersion: String?、
//    consentedAtMillis: Int64?、basicMode: Bool。
//    本文件提供内存实现；生产存储自行映射 APP-01 命名空间。
// 2. clock: () -> Int64，所有 now/delayMillis 均为毫秒。
// 3. PrivacyGate 暴露可注入的 retryScheduler: any RetryScheduler、
//    withdrawalCleanup: () -> Void。
//    生产 withdrawalCleanup 接 APP-01 清理器注册表，此处替换成 spy。
// 4. RetryScheduler.schedule(delayMillis: Int64, action: @escaping () -> Void)。
// 5. registerInitStep(name: String, action: @escaping () throws -> Void)；
//    device_register 抛错表示本次失败；正常返回表示成功。
//    本组使用同步 action，退避回调只由假调度器执行。
// 6. 所有状态读取使用 decisionRaw、mustPrompt、promptStageRaw。
// 7. expect.decision == nil 表示原文未规定临时表示，不要求实际返回 nil。
// Core 需建立 Privacy、PrivacyTests target；这里不使用真实 SDK、网络或睡眠。

private struct InitialPrivacy: Decodable {
    let decision: String
    let consentedVersion: String?
    let basicMode: Bool
}

private struct ExpectedPrivacy: Decodable {
    let decision: String?
    let mustPrompt: Bool
    let promptStage: String
}

private struct GateStep: Decodable {
    let op: String
    let atMillis: Int64
    let expect: ExpectedPrivacy
}

private struct GateVector: Decodable {
    let name: String
    let bundledPolicyVersion: String
    let initial: InitialPrivacy
    let steps: [GateStep]
    let note: String
}

private struct InitCheckpoint: Decodable {
    let started: Bool
    let deviceRegisterAttempts: Int
    let scheduledRetries: Int
    let pendingRetries: Int
}

private struct InitStep: Decodable {
    let op: String
    let atMillis: Int64
    let expect: InitCheckpoint?
}

private struct InitExpected: Decodable {
    let order: [String]
    let calledOnce: Bool
    let deviceRegisterRetryDelaysMillis: [Int64]
}

private struct InitVector: Decodable {
    let name: String
    let bundledPolicyVersion: String
    let initial: InitialPrivacy
    let deviceRegisterResults: [Bool]
    let steps: [InitStep]
    let expect: InitExpected
    let note: String
}

private struct PrivacyVectors: Decodable {
    let version: Int
    let sources: [String]
    let gate: [GateVector]
    let initialization: [InitVector]
    let gaps: [String]

    enum CodingKeys: String, CodingKey {
        case version, sources, gate, gaps
        case initialization = "init"
    }
}

private enum VectorFailure: Error {
    case invalid(String)
    case deviceOffline
}

private final class VectorPrivacyStore: PrivacyStore {
    var decisionRaw: String
    var consentedVersion: String?
    var consentedAtMillis: Int64?
    var basicMode: Bool

    init(_ initial: InitialPrivacy) {
        decisionRaw = initial.decision
        consentedVersion = initial.consentedVersion
        consentedAtMillis = initial.consentedVersion == nil ? nil : 0
        basicMode = initial.basicMode
    }
}

private final class VectorClock {
    var nowMillis: Int64 = 0
}

private final class CleanupSpy {
    var calls = 0
    var credentials = ["token", "device_id", "install_secret"]

    func clear() {
        calls += 1
        credentials.removeAll()
    }
}

private final class RecordingScheduler: RetryScheduler {
    private struct Job {
        let dueMillis: Int64
        let action: () -> Void
    }

    private let clock: VectorClock
    private var jobs: [Job] = []
    private(set) var delays: [Int64] = []

    var pendingCount: Int { jobs.count }

    init(clock: VectorClock) {
        self.clock = clock
    }

    func schedule(delayMillis: Int64, action: @escaping () -> Void) {
        delays.append(delayMillis)
        jobs.append(Job(dueMillis: clock.nowMillis + delayMillis, action: action))
    }

    func advance(to target: Int64) throws {
        guard target >= clock.nowMillis else {
            throw VectorFailure.invalid("虚拟时间不能倒退")
        }

        var executed = 0
        while let index = jobs.indices.min(by: {
            jobs[$0].dueMillis < jobs[$1].dueMillis
        }) {
            guard jobs[index].dueMillis <= target else { break }
            executed += 1
            guard executed <= 128 else {
                throw VectorFailure.invalid("重试循环超过测试保护上限")
            }
            let job = jobs.remove(at: index)
            clock.nowMillis = job.dueMillis
            job.action()
        }
        clock.nowMillis = target
    }
}

private struct ConsentObservation {
    let name: String
    let decisionRaw: String
    let version: String?
    let atMillis: Int64?
    let basicMode: Bool

    init(name: String, store: VectorPrivacyStore) {
        self.name = name
        decisionRaw = store.decisionRaw
        version = store.consentedVersion
        atMillis = store.consentedAtMillis
        basicMode = store.basicMode
    }
}

private final class InitProbe {
    var observations: [ConsentObservation] = []
    var attempts = 0
}

final class PrivacyGateVectorTests: XCTestCase {
    func testGateVectors() throws {
        for row in try vectors().gate {
            try checkGate(row)
        }
    }

    func testInitializationVectors() throws {
        for row in try vectors().initialization {
            try checkInitialization(row)
        }
    }

    private func checkGate(_ row: GateVector) throws {
        let label = "\(row.name): \(row.note)"
        let store = VectorPrivacyStore(row.initial)
        let clock = VectorClock()
        let scheduler = RecordingScheduler(clock: clock)
        let cleanup = CleanupSpy()

        func makeGate() -> PrivacyGate {
            let result = PrivacyGate(
                store: store,
                clock: { clock.nowMillis },
                bundledPolicyVersion: row.bundledPolicyVersion
            )
            result.retryScheduler = scheduler
            result.withdrawalCleanup = { cleanup.clear() }
            return result
        }

        var gate = makeGate()
        for (index, step) in row.steps.enumerated() {
            let context = "\(label) step[\(index)] \(step.op)"
            clock.nowMillis = step.atMillis
            let previousCleanupCalls = cleanup.calls

            switch step.op {
            case "coldStart":
                // 重建对象，禁止只靠上一个 Gate 的内存状态通过。
                gate = makeGate()
                gate.coldStart(now: step.atMillis)
            case "agree":
                gate.agree(now: step.atMillis)
                assertRecorded(store, version: row.bundledPolicyVersion,
                               atMillis: step.atMillis, label: context)
            case "disagree":
                gate.disagree(now: step.atMillis)
            case "stillDisagree":
                gate.stillDisagree(now: step.atMillis)
            case "requestFullFunction":
                gate.requestFullFunction(now: step.atMillis)
            case "withdraw":
                gate.withdraw(now: step.atMillis)
            default:
                throw VectorFailure.invalid("\(context): 未知 gate op")
            }

            let actual = gate.state(now: step.atMillis)
            XCTAssertTrue(
                ["not_decided", "consented", "basic_mode"].contains(actual.decisionRaw),
                "\(context): 非法 decisionRaw"
            )
            if let decision = step.expect.decision {
                XCTAssertEqual(actual.decisionRaw, decision, context)
            }
            XCTAssertEqual(actual.mustPrompt, step.expect.mustPrompt, context)
            XCTAssertEqual(actual.promptStageRaw, step.expect.promptStage, context)

            if step.op == "withdraw" {
                XCTAssertGreaterThan(cleanup.calls, previousCleanupCalls, context)
                XCTAssertTrue(cleanup.credentials.isEmpty, context)
            } else {
                XCTAssertEqual(cleanup.calls, previousCleanupCalls,
                               "\(context): 不应误走撤回清理")
            }

            if step.op == "stillDisagree" || step.op == "withdraw" {
                XCTAssertEqual(store.decisionRaw, "basic_mode", context)
                XCTAssertTrue(store.basicMode, "\(context): 基本模式必须持久化")
            }
        }
    }

    private func checkInitialization(_ row: InitVector) throws {
        let label = "\(row.name): \(row.note)"
        let store = VectorPrivacyStore(row.initial)
        let clock = VectorClock()
        let scheduler = RecordingScheduler(clock: clock)
        let probe = InitProbe()
        var acceptedAt = store.consentedAtMillis
        let gate = PrivacyGate(
            store: store,
            clock: { clock.nowMillis },
            bundledPolicyVersion: row.bundledPolicyVersion
        )
        gate.retryScheduler = scheduler

        // 注册顺序故意与执行顺序相反。
        for name in row.expect.order.reversed() {
            gate.registerInitStep(name: name, action: {
                probe.observations.append(ConsentObservation(name: name, store: store))
                if name == "device_register" {
                    probe.attempts += 1
                    let index = probe.attempts - 1
                    if index < row.deviceRegisterResults.count,
                       !row.deviceRegisterResults[index] {
                        throw VectorFailure.deviceOffline
                    }
                }
            })
        }
        XCTAssertTrue(probe.observations.isEmpty, "\(label): 注册不能执行步骤")
        XCTAssertTrue(scheduler.delays.isEmpty, "\(label): 注册不能安排重试")

        for (index, step) in row.steps.enumerated() {
            let context = "\(label) step[\(index)] \(step.op)"
            if step.op == "advance" {
                try scheduler.advance(to: step.atMillis)
            } else {
                clock.nowMillis = step.atMillis
                switch step.op {
                case "coldStart":
                    gate.coldStart(now: step.atMillis)
                case "agree":
                    acceptedAt = step.atMillis
                    gate.agree(now: step.atMillis)
                    assertRecorded(store, version: row.bundledPolicyVersion,
                                   atMillis: step.atMillis, label: context)
                case "disagree":
                    gate.disagree(now: step.atMillis)
                case "stillDisagree":
                    gate.stillDisagree(now: step.atMillis)
                case "requestFullFunction":
                    gate.requestFullFunction(now: step.atMillis)
                case "onConsented":
                    gate.onConsented(now: step.atMillis)
                default:
                    throw VectorFailure.invalid("\(context): 未知 init op")
                }
            }

            // 断言放在 action 外，避免被被测代码的错误处理吞掉。
            for observed in probe.observations {
                XCTAssertEqual(observed.decisionRaw, "consented", context)
                XCTAssertEqual(observed.version, row.bundledPolicyVersion, context)
                XCTAssertEqual(observed.atMillis, acceptedAt,
                               "\(context): 必须先保存点击时间，重试不能重写")
                XCTAssertFalse(observed.basicMode, context)
            }
            XCTAssertLessThanOrEqual(probe.attempts, row.deviceRegisterResults.count,
                                     "\(context): 超出脚本规定的注册次数")

            if let expected = step.expect {
                let trace = expected.started
                    ? row.expect.order + Array(
                        repeating: "device_register",
                        count: max(0, expected.deviceRegisterAttempts - 1)
                    )
                    : []
                XCTAssertEqual(probe.observations.map(\.name), trace,
                               "\(context): 完整调用轨迹")
                XCTAssertEqual(probe.attempts, expected.deviceRegisterAttempts, context)
                XCTAssertEqual(
                    scheduler.delays,
                    Array(row.expect.deviceRegisterRetryDelaysMillis.prefix(
                        expected.scheduledRetries
                    )),
                    "\(context): 累计退避延迟"
                )
                XCTAssertEqual(scheduler.pendingCount, expected.pendingRetries, context)
            }
        }

        XCTAssertTrue(row.expect.calledOnce, "\(label): 本组要求幂等初始化")
        for name in row.expect.order where name != "device_register" {
            XCTAssertEqual(probe.observations.filter { $0.name == name }.count, 1, label)
        }
        XCTAssertEqual(
            Array(probe.observations.prefix(row.expect.order.count)).map(\.name),
            row.expect.order,
            label
        )
        XCTAssertEqual(scheduler.delays, row.expect.deviceRegisterRetryDelaysMillis, label)
        XCTAssertEqual(scheduler.pendingCount, 0, "\(label): 成功后不得残留重试")
    }

    private func assertRecorded(
        _ store: VectorPrivacyStore,
        version: String,
        atMillis: Int64,
        label: String
    ) {
        XCTAssertEqual(store.decisionRaw, "consented", label)
        XCTAssertEqual(store.consentedVersion, version, label)
        XCTAssertEqual(store.consentedAtMillis, atMillis, label)
        XCTAssertFalse(store.basicMode, label)
    }

    private func vectors() throws -> PrivacyVectors {
        let url = try repositoryRoot()
            .appendingPathComponent("specs/privacy-gate-vectors.json")
        let root = try JSONDecoder().decode(
            PrivacyVectors.self,
            from: Data(contentsOf: url)
        )
        XCTAssertEqual(root.version, 1, url.path)
        XCTAssertFalse(root.sources.isEmpty, url.path)
        XCTAssertFalse(root.gaps.isEmpty, url.path)
        XCTAssertFalse(root.gate.isEmpty, url.path)
        XCTAssertFalse(root.initialization.isEmpty, url.path)
        XCTAssertEqual(Set(root.gate.map(\.name)).count, root.gate.count, url.path)
        XCTAssertEqual(
            Set(root.initialization.map(\.name)).count,
            root.initialization.count,
            url.path
        )
        for row in root.gate {
            XCTAssertFalse(row.name.isEmpty || row.note.isEmpty || row.steps.isEmpty, url.path)
        }
        for row in root.initialization {
            XCTAssertFalse(row.name.isEmpty || row.note.isEmpty || row.steps.isEmpty, url.path)
            XCTAssertFalse(row.deviceRegisterResults.isEmpty, url.path)
        }
        return root
    }

    private func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .standardizedFileURL

        while true {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("contract.lock").path
            ) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else {
                throw VectorFailure.invalid(
                    "从 \(#filePath) 向上找不到含 contract.lock 的仓库根"
                )
            }
            directory = parent
        }
    }
}
