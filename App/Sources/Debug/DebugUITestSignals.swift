#if DEBUG
import Foundation

/// UI 测试的显式完成信号（FU-IOS-0712 第 2 项 F-IOS-02，只在 Debug / Staging 编译）：进后台的同步保存（搜索恢复记录、订单恢复记录等）
/// 全部执行完之后发一条 Darwin 通知，UI 测试据此结束进程，不再固定睡 2 秒猜保存是否完成。通知不带任何数据。
/// R1-05：只有恢复内容与后台标记已显式提交并核对（`SearchRouteRestoration.sceneEnteredBackground` 返回 true）才发；提交失败或没完成
/// 一律不发，UI 测试等不到信号就在上限内失败，不会提前结束进程。启动参数 `-CouliUITestHoldBackgroundCommit` 让提交永不完成（只给
/// 「挂住提交时测试不提前结束进程」的用例用）。
@MainActor
enum DebugUITestSignals {
    static let backgroundSaved = "com.couli.app.debug.uitest.background-saved"
    static let holdCommitArgument = "-CouliUITestHoldBackgroundCommit"

    /// 实际发通知（测试替换以计数）。
    static var poster: @MainActor (String) -> Void = { name in
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true
        )
    }

    /// 进后台的保存结束：已提交并核对才发「保存完成」信号。
    static func backgroundSaveFinished(committed: Bool) {
        guard committed else { return }
        poster(backgroundSaved)
    }

    /// 「挂住提交」开关：启动参数带 `holdCommitArgument` 时，搜索恢复的提交永不完成（返回 false）。
    static func installHold(
        on restoration: SearchRouteRestoration,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        guard arguments.contains(holdCommitArgument) else { return }
        restoration.commit = { _ in false }
    }
}
#endif
