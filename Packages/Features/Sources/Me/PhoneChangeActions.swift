import Foundation
import MeCore

/// 换号子页渲染时取出的回调（照 SettingsActions）：都捕获渲染时的执行器与表单世代（`state.version`），执行时只比较
/// （共性第 6、16、36 条）；执行器已离开、换代后一律不生效。
@MainActor
public struct PhoneChangeActions {
    public let requestOldCode: () -> Void
    public let oldCode: (String) -> Void
    public let next: () -> Void
    /// 「原手机号不能用了？联系客服」：统一客服出口，不提交。
    public let oldUnavailable: () -> Void
    public let newPhone: (String) -> Void
    public let requestNewCode: () -> Void
    public let newCode: (String) -> Void
    public let submit: () -> Void
    /// 页面返回（与系统返回同一处理）：第 2 步 → 第 1 步并重置第 2 步瞬时状态；其余 → 回设置页。
    public let back: () -> Void
    /// Done【完成】：回设置页的唯一实例（关子页）。
    public let finish: () -> Void
    public let confirmPending: () -> Void
    public let askAbandon: () -> Void
    public let confirmAbandon: (PhoneChangeDialog) -> Void
    /// 【知道了】/【再想想】：只认正显示的这一个弹窗；30414 的【知道了】之后回设置页。
    public let dismissDialog: (PhoneChangeDialog) -> Void
    /// 30414【联系客服】、44001【联系客服申诉】：统一客服出口。
    public let contactService: (PhoneChangeDialog) -> Void

    public static func make(_ controller: PhoneChangeController, _ state: PhoneChangeState) -> PhoneChangeActions {
        let version = state.version
        return PhoneChangeActions(
            requestOldCode: { [weak controller] in controller?.requestOldCode(version: version) },
            oldCode: { [weak controller] text in controller?.oldCode(text, version: version) },
            next: { [weak controller] in controller?.next(version: version) },
            oldUnavailable: { [weak controller] in controller?.oldUnavailable(version: version) },
            newPhone: { [weak controller] text in controller?.newPhone(text, version: version) },
            requestNewCode: { [weak controller] in controller?.requestNewCode(version: version) },
            newCode: { [weak controller] text in controller?.newCode(text, version: version) },
            submit: { [weak controller] in controller?.submit(version: version) },
            back: { [weak controller] in controller?.back(version: version) },
            finish: { [weak controller] in controller?.finish(version: version) },
            confirmPending: { [weak controller] in controller?.confirmPending(version: version) },
            askAbandon: { [weak controller] in controller?.askAbandon(version: version) },
            confirmAbandon: { [weak controller] dialog in controller?.confirmAbandon(dialog, version: version) },
            dismissDialog: { [weak controller] dialog in controller?.dismissDialog(dialog) },
            contactService: { [weak controller] dialog in controller?.contactService(dialog) }
        )
    }
}
