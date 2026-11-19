import Foundation

/// 注销页撤回成功、出栈回到本页（APP-13a-1 G18）：在这里轻提示「已撤回注销申请，账号恢复正常使用」。已出栈的执行器不受理。
public extension SettingsController {
    static let deletionWithdrawnKey = "deletion.withdrawn_toast"

    func showDeletionWithdrawn() {
        guard alive else { return }
        toast(MeNotice(Self.deletionWithdrawnKey, id: nextId(), assertive: false))
    }
}
