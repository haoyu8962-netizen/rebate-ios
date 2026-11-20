import Foundation

/// 设置页的半屏、确认框取消与底部按钮（从 SettingsController.swift 原样拆出，APP-13a-2 为控制类型体长度；行为不变）。
public extension SettingsController {
    /// 协议半屏的一个按钮（G32：半屏两个按钮 → Agreement {type}）：只认正显示的这一个半屏（编号），用过即作废。
    func openAgreement(_ choice: SettingsChoice, version: Int, sheet: Int) {
        guard state.sheet == sheet else { return }
        state.sheet = nil
        guard bound(version) else { return }
        deps.env.open(choice.route, params: ["type": choice.type], from: page)
    }

    /// 关闭半屏（同一编号才生效）。
    func closeSheet(_ sheet: Int) {
        if state.sheet == sheet {
            state.sheet = nil
        }
    }

    /// 取消确认框（【取消】；同一编号才生效）。
    func closeDialog(_ dialog: MeDialog) {
        if state.dialog == dialog {
            state.dialog = nil
        }
    }

    /// 底部【去登录】（游客）。
    func openLogin(version: Int) {
        guard bound(version), identity.level == MeLevel.guest else { return }
        deps.env.open(Self.login, params: [:], from: page)
    }

    /// 底部【开启完整功能】（基本模式）。
    func enableFull(version: Int) {
        guard bound(version), identity.level == MeLevel.basic else { return }
        deps.env.requestFullFunction()
    }
}

extension SettingsController {
    /// 其余行：手机号行在换号入口打开时开换号子页（APP-13a-2，SettingsController+PhoneChange），否则按路由经 Router 打开。
    func openRowRoute(_ row: SettingsRow) {
        if row.id == SettingsItems.idPhone, phoneChangeOpen(row) {
            openPhoneChange()
            return
        }
        guard let route = row.route, row.clickable else { return }
        deps.env.open(route, params: [:], from: page)
    }
}
