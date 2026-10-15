import Combine
import Foundation

/// 一个页面（导航实例或 Tab 根）当前的执行器（App 持有，页面观察）：身份变了 App 同步作废旧执行器并按新身份新建（共性第 18 条），页面按新执行器
/// 重画——旧执行器的确认框、草稿与回调随之作废，新操作不会被旧身份永久拒绝（鸿蒙 R3-02）。`serial` 每换一次加一（页面据此整块重建）。
@MainActor
public final class MePageHost<Controller: AnyObject>: ObservableObject {
    @Published public private(set) var controller: Controller
    public private(set) var serial = 0
    /// 页面出现（App 接：确保这一次进入有有效的执行器、按 G36 取一次）。
    public var onAppear: () -> Void = {}

    public init(_ controller: Controller) {
        self.controller = controller
    }

    public func replace(_ controller: Controller) {
        serial += 1
        self.controller = controller
    }
}

/// 「我的」Tab 根的滚动位置（Android R1-11，共性第 27 条）：放在会话级（Tab 根离开组合——切到其他 Tab——不销毁），按身份分开：身份变了
/// （换账号、退出、撤回同意）给新的位置，不把上一个账号的位置带过去。记的是最上面那一块的标识（返回时滚回到它）。
@MainActor
public final class MeScrollMemory {
    private var owner: String?
    private var anchor: String?

    public init() {}

    public func anchor(for identity: MeIdentity) -> String? {
        owner == identity.key ? anchor : nil
    }

    public func remember(_ anchor: String?, for identity: MeIdentity) {
        owner = identity.key
        self.anchor = anchor
    }

    /// 会话清理（撤回、切换环境）：丢掉保存的位置。
    public func reset() {
        owner = nil
        anchor = nil
    }
}
