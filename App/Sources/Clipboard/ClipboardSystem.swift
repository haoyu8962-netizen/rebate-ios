import ClientCore
import Clipboard
import Config
import Foundation
import Privacy
import UIKit

/// 系统剪贴板（brief §3 iOS）：自动识别只用 changeCount 与 detectPatterns（probableWebURL、links）判断有没有链接，不调 detectValues、
/// 不读 `.string`，所以不会出现系统「允许粘贴」弹窗；正文只经用户点击的系统粘贴控件（UIPasteControl）交给 App。写入只经
/// `ClipboardWriter`（先记 hash）。桥 `clipboard.read`（H5 用户手势的程序化读取）不在这里，行为不变。
@MainActor
final class UIKitSystemClipboard: SystemClipboard {
    /// 本进程里经 App 写系统剪贴板的次数（诊断与测试：识别、提示、上传、绑定的前后都应为 0）。
    private(set) var writeCount = 0

    var changeCount: Int {
        UIPasteboard.general.changeCount
    }

    func detectLink(_ completion: @escaping @MainActor (Bool) -> Void) {
        let patterns: Set<PartialKeyPath<UIPasteboard.DetectedValues>> = [\.probableWebURL, \.links]
        // 系统在后台队列回调：显式 @Sendable，不继承本类的主线程隔离
        UIPasteboard.general.detectPatterns(for: patterns) { @Sendable result in
            let hit = (try? result.get()).map { !$0.isEmpty } ?? false
            Task { @MainActor in completion(hit) }
        }
    }

    func write(_ text: String) {
        writeCount += 1
        UIPasteboard.general.string = text
    }
}

/// 剪贴板的本机记录（自写 hash、提示过的 hash 与时间、iOS 最近判定过的 changeCount；不存原文）：Application Support 下一个小文件，
/// 设备级（登录、退出、换账号、切换环境都不清）。写入经原子替换，失败抛错（共性第 14、23、25 条：确认落盘才算成功）。
final class ClipboardFileStore: ClipboardHashStore, @unchecked Sendable {
    static let fileName = "clipboard-records.json"

    private let file: ClientFile
    private let lock = NSLock()

    init(file: ClientFile = ClientFile(name: ClipboardFileStore.fileName)) {
        self.file = file
    }

    func read(_ key: String) -> String? {
        lock.withLock { load()[key] }
    }

    func write(_ key: String, _ value: String?) throws {
        try lock.withLock {
            var all = load()
            all[key] = value
            if all.isEmpty {
                try file.write(nil)
                return
            }
            let data = try JSONSerialization.data(withJSONObject: all, options: [.sortedKeys])
            try file.write(String(bytes: data, encoding: .utf8) ?? "{}")
        }
    }

    /// 撤回同意：整个文件删除（失败抛错）。
    func clear() throws {
        try lock.withLock { try file.write(nil) }
    }

    private func load() -> [String: String] {
        guard let text = try? file.read(), let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
        else { return [:] }
        return object
    }
}

/// 撤回同意的清理项：删除剪贴板 hash 记录（APP-03b 第 11 条思路、brief §0）。只登记在撤回同意的注册表（切换环境不清：记录是设备级）。
/// 删除失败抛错，撤回清理据此保留「待清理」标记并在冷启动、读凭据前重试（共性第 14 条）。在启动对账之前登记（CouliApp.init）。
@MainActor
final class ClipboardRecordsCleaner: EnvironmentSwitchCleaning {
    static let name = "Clipboard.records"
    let cleanerName = ClipboardRecordsCleaner.name
    let store: ClipboardFileStore
    /// 清理后的通知（AppClipboard 作废内存里的提示与请求）。
    var onCleared: (@MainActor () -> Void)?

    init(store: ClipboardFileStore) {
        self.store = store
    }

    func cleanForEnvironmentSwitch() throws {
        try store.clear()
        onCleared?()
    }

    static let shared = ClipboardRecordsCleaner(store: ClipboardFileStore())

    /// 登记进撤回同意的注册表（已登记过就不重复）。
    static func register(_ cleaner: ClipboardRecordsCleaner = shared,
                         withdrawal: EnvironmentSwitchCleanerRegistry = PrivacyWithdrawalCleanup.registry) {
        guard !withdrawal.registeredNames.contains(name) else { return }
        withdrawal.register(cleaner)
    }
}
