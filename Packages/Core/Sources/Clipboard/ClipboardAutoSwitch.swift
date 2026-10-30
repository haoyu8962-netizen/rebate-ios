import Combine
import Foundation

/// 本机开关「打开 App 自动识别剪贴板」（BR-ID-16 2026-10-30「默认开启」「开关的适用范围」「撤回与关闭」；FU-X-CLIP-DEFAULT-ON C1、C5、C6、C7）。
///
/// - 设备级：登录、退出、切换账号不改它；撤回隐私同意不清它（关闭态本机保留，重新同意后仍按它）。生产存储由 App 给，不得与撤回清理会删的
///   剪贴板记录放在同一文件。
/// - 默认开启：存储里没有值（从未在设置里作出选择）即为开启。
/// - 迁移（C6）：iOS 旧版本机从未有过这个开关键，也没有功能同意版本 / 已看过弹层的记录，所以没有旧键要换算——没有存过值一律开启；
///   用户一旦在设置里选过，之后只认这个值。只读 `key` 一个键，旧 UserDefaults `couli.clipboard.autoDetect`（H5 桥写过、从未被读）不参与。
///   没有单独的「已迁移」标记：判定只看 `key` 有没有值，天然幂等。
/// - 关闭立即生效：`set` 先改内存再落盘；没确认落盘返回 false（内存仍按用户的新选择），重启后若未落盘会回到上次落盘的值。
/// - 只有用户在设置里能改它；服务端配置只能让读取跳过（`ClipboardReadState.configEnabled`），不改这里的值。
@MainActor
public final class ClipboardAutoSwitch: ObservableObject {
    /// 存储键（值 "on" / "off"）。
    public static let key = "auto_switch"
    static let valueOn = "on"
    static let valueOff = "off"

    @Published public private(set) var isOn: Bool
    private let store: ClipboardHashStore
    private var observers: [UUID: @MainActor (Bool) -> Void] = [:]

    public init(store: ClipboardHashStore) {
        self.store = store
        // 读不到、内容不认识都按「从未选择」= 开启
        isOn = store.read(Self.key) != Self.valueOff
    }

    /// 用户在设置里切换。返回是否确认落盘；不论成败内存里立即生效并通知观察者（AppClipboard 据此作废提示条与挂起的探测）。
    @discardableResult
    public func set(_ on: Bool) -> Bool {
        let changed = isOn != on
        isOn = on
        let saved = (try? store.write(Self.key, on ? Self.valueOn : Self.valueOff)) != nil
        if changed {
            for observer in observers.values {
                observer(on)
            }
        }
        return saved
    }

    /// 开关值变化时回调（只在值真的变化时）。返回的标识交给 `removeObserver`。
    @discardableResult
    public func observe(_ handler: @escaping @MainActor (Bool) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers[id] = nil
    }
}
