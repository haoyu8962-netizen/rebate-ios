import Combine
import DesignSystem
import MeCore

/// 「我的」Tab 的轻提示队列（G-M12、G-M14）：一次只显示一条；刷新失败优先，复制结果排在其后；正在显示的一条显示满再换下一条，不被后到的打断。
///
/// - 只决定「先显示哪条」：`consumeToast` / `consumeError` 的消费时机与编号规则不变（调用方入队时就消费）。
/// - 显示放到下一拍：同一拍里先后到的复制结果与刷新失败，都入队之后才挑，刷新失败先显示。
/// - 刷新失败的播报只有一个出口：`MeAnnounce` assertive 一次，DS Toast 静默。复制结果沿用 DS Toast 的礼貌播报。
/// - `MeAnnounceProbe.toast` 在真正显示时调，不是入队时。
/// - 队列是视图状态，`MeTabBody` 的 `@StateObject` 不随执行器重建：条目记下入队时的执行器，执行器失效就丢；执行器换了调用方 `drop()`，
///   连同正在显示的一条清掉（Android 评审 r1 S1：上一账号的提示不带到新身份）。
@MainActor
final class MeToastQueue: ObservableObject {
    private struct Item {
        let text: String
        let icon: CouliToastIcon
        let isValid: () -> Bool
    }

    /// 绑给 `couliToast`。DS 显示满后置 nil，这里接着挑下一条。
    @Published var current: CouliToastMessage? {
        didSet {
            if current == nil {
                schedule()
            }
        }
    }

    private var failure: Item?
    private var result: Item?
    private var scheduled = false
    /// 上一次收下的复制结果（执行器 + 编号）：发布值重放时不重复入队。
    private var received: (owner: ObjectIdentifier, id: Int)?

    /// 刷新失败（只留最新一条）。
    func enqueueFailure(_ text: String, owner: MeTabController) {
        failure = Item(text: text, icon: .none, isValid: Self.isValid(owner))
        schedule()
    }

    /// 复制结果（只留最新一条）：只有复制成功带对勾（G-M12）。
    func enqueueResult(_ notice: MeNotice, texts: MeTexts, owner: MeTabController) {
        guard received?.owner != ObjectIdentifier(owner) || received?.id != notice.id else { return }
        received = (ObjectIdentifier(owner), notice.id)
        let icon: CouliToastIcon = notice.key == MeTabController.copied ? .success : .none
        result = Item(text: notice.message(texts), icon: icon, isValid: Self.isValid(owner))
        schedule()
    }

    /// 执行器换了（换身份、撤回同意、退出、新的一次进入）：排队的与正在显示的全部作废。
    func drop() {
        failure = nil
        result = nil
        received = nil
        current = nil
    }

    private static func isValid(_ owner: MeTabController) -> () -> Bool {
        { [weak owner] in owner?.alive == true }
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in
            self?.scheduled = false
            self?.showNext()
        }
    }

    private func showNext() {
        guard current == nil else { return }
        if let item = failure {
            failure = nil
            if item.isValid() {
                show(item, assertive: true)
                return
            }
        }
        if let item = result {
            result = nil
            if item.isValid() {
                show(item, assertive: false)
            }
        }
    }

    private func show(_ item: Item, assertive: Bool) {
        MeAnnounceProbe.toast?(item.text)
        if assertive {
            MeAnnounce.post(item.text, assertive: true)
        }
        current = CouliToastMessage(item.text, icon: item.icon, silent: assertive)
    }
}
