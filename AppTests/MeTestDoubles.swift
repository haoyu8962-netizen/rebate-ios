import ClientCore
@testable import Couli
import CouliNetwork
import Foundation
import MeCore
import Push

/// 系统能力替身：权限状态、被拒时刻、外跳结果、微信已装、缓存大小；记下打开系统设置与外部链接的次数。
@MainActor
final class FakeMeSystem: MeSystemPorts {
    var status: [String: String] = ["push": "not_asked", "photos": "not_asked"]
    var deniedAt: [String: Int64] = [:]
    var wechat = "unknown"
    var openResult = true
    var opened: [String] = []
    var notificationSettingsOpened = 0
    var appSettingsOpened = 0
    var permissionRequests = 0
    var bytes: Int64 = 3 * 1024 * 1024 + 300 * 1024
    var cleared = 0

    func permissionStatus(_ type: String) async -> String {
        status[type] ?? "not_asked"
    }

    func permissionDeniedAt(_ type: String) -> Int64? {
        deniedAt[type]
    }

    func openNotificationSettings() {
        notificationSettingsOpened += 1
    }

    func openAppSettings() {
        appSettingsOpened += 1
    }

    func openExternal(_ url: String) async -> Bool {
        opened.append(url)
        return openResult
    }

    func wechatInstalled() -> String {
        wechat
    }

    func cacheBytes() async -> Int64? {
        bytes
    }

    /// 清除后的占用（nil = 占用不变：系统缓存占用不保证同步缩小，R3-01 裁定）。
    var bytesAfterClear: Int64? = 12 * 1024
    /// 清理动作是否完成（false = 有 I/O 错误）。
    var clearSucceeds = true

    func clearCache() async -> Bool {
        cleared += 1
        if let bytesAfterClear {
            bytes = bytesAfterClear
        }
        return clearSucceeds
    }

    func osVersion() -> String? {
        "26.0"
    }

    func model() -> String? {
        "iPhone18,1"
    }
}

/// 可控的推送令牌来源（Debug 假来源同口径：start 之后才给令牌）。
@MainActor
final class TestPushSource: PushTokenSource {
    private(set) var started = false
    private(set) var stopped = 0
    var token: String?
    private var listeners: [Int: @MainActor () -> Void] = [:]
    private var next = 0

    init(token: String?) {
        self.token = token
    }

    func start() {
        started = true
        notify()
    }

    func stop() {
        stopped += 1
        started = false
    }

    func current() -> String? {
        started ? token : nil
    }

    func subscribe(_ listener: @escaping @MainActor () -> Void) -> () -> Void {
        next += 1
        let id = next
        listeners[id] = listener
        return { [weak self] in MainActor.assumeIsolated { self?.listeners[id] = nil } }
    }

    func change(_ value: String) {
        token = value
        notify()
    }

    private func notify() {
        for listener in listeners.values {
            listener()
        }
    }
}

/// 改昵称的测试后端（G01 待定 operation）：按脚本回答；记下收到的昵称与发出时的固定归属。
final class TestNicknameBackend: NicknameBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [ApiResult] = []
    private var saved: [(String, RequestOwnership?)] = []
    var hold: CheckedContinuation<Void, Never>?

    func reply(_ results: ApiResult...) {
        lock.withLock { replies = results }
    }

    var calls: [(nickname: String, owner: RequestOwnership?)] {
        lock.withLock { saved.map { ($0.0, $0.1) } }
    }

    func save(nickname: String, owner: RequestOwnership?, allowed: @escaping @Sendable () -> Bool) async -> ApiResult {
        guard allowed() else { return .localReject(reason: LocalRejectReason.sendBlocked) }
        return lock.withLock {
            saved.append((nickname, owner))
            return replies.isEmpty ? .success(data: Data("{}".utf8), traceId: nil, idempotencyKey: nil) : replies
                .removeFirst()
        }
    }
}

final class TestNotifyBackend: NotifyBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var on = true
    var putReply: ApiResult = .success(data: Data("{}".utf8), traceId: nil, idempotencyKey: nil)

    func get(owner _: RequestOwnership?, allowed: @escaping @Sendable () -> Bool) async -> ApiResult {
        guard allowed() else { return .localReject(reason: LocalRejectReason.sendBlocked) }
        let value = lock.withLock { on }
        return .success(data: Data("{\"service\":\(value)}".utf8), traceId: nil, idempotencyKey: nil)
    }

    func put(service: Bool, owner _: RequestOwnership?, allowed: @escaping @Sendable () -> Bool) async -> ApiResult {
        guard allowed() else { return .localReject(reason: LocalRejectReason.sendBlocked) }
        return lock.withLock {
            if case .success = putReply {
                on = service
            }
            return putReply
        }
    }
}

/// 设备级偏好文件的替身：真实落盘（ClientFile，临时目录），可让本文件的删除或写入失败（模拟存储失败）；`sibling` 给同目录的作废标记（另一个
/// 替身，失败开关各自独立：只让偏好文件删不掉时，作废标记照常可写可删）。
final class FlakyMeFile: MeLocalFile, @unchecked Sendable {
    struct Failure: Error {}

    let base: ClientFile
    private let lock = NSLock()
    private var deleteFails = false
    private var writeFails = false
    private var children: [FlakyMeFile] = []

    init(_ base: ClientFile) {
        self.base = base
    }

    /// 本文件删除失败。
    var failDelete: Bool {
        get { lock.withLock { deleteFails } }
        set { lock.withLock { deleteFails = newValue } }
    }

    /// 本文件写入失败。
    var failWrite: Bool {
        get { lock.withLock { writeFails } }
        set { lock.withLock { writeFails = newValue } }
    }

    func sibling(_ name: String) -> FlakyMeFile {
        let child = FlakyMeFile(base.sibling(name))
        lock.withLock { children.append(child) }
        return child
    }

    var pendingFile: FlakyMeFile? {
        lock.withLock { children.first }
    }

    func read() throws -> String? {
        try base.read()
    }

    func write(_ text: String?) throws {
        if text == nil ? failDelete : failWrite {
            throw Failure()
        }
        try base.write(text)
    }
}
