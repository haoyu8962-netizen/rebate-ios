import Foundation

/// 设置页里的换手机号入口（APP-13a-2；brief §1「入口」、§2）：
/// - 手机号行在上层覆盖（不改 `SettingsItems.model`：me-vectors.json:41 / :45 照旧，照安卓 Settings.kt:139-142）：已登录、
///   `phone_bound == true`、入口可用（`MeEnv.phoneChangeAvailable()`，Release 由 `PhoneChangeEntry.sinceIOS` 关）且已接上依赖 →
///   `route == nil, clickable == true`；其余照 `SettingsItems`（false → BindPhone；未知 → 不可点）；
/// - 点了建子页执行器（构造时一次固定身份）、`sub = .phoneChange`、版本加一（作废设置页旧回调 = 导航许可，G22），同步 `start()`；
///   不经 Router、不压栈、不注册路由；
/// - 子页的返回与系统返回都经 `closeSub()` 先交子页处理；子页自己要关（30414、【完成】、第 1 步返回、身份变了）走 `closePhoneChange`。
extension SettingsController: PhoneChangeHost {
    /// 手机号行此刻是不是换号入口。
    private func phoneChangeEntry(phoneBound: Bool?) -> Bool {
        identity.member && phoneBound == true && deps.env.phoneChangeAvailable() && deps.env.phoneChangePorts() != nil
    }

    func phoneRowOverride(_ model: SettingsModel, phoneBound: Bool?) -> SettingsModel {
        guard phoneChangeEntry(phoneBound: phoneBound) else { return model }
        let groups = model.groups.map { group in
            SettingsGroup(name: group.name, rows: group.rows.map { row in
                row.id == SettingsItems.idPhone ? SettingsRow(row.id, nil, clickable: true) : row
            })
        }
        return SettingsModel(groups: groups, footer: model.footer)
    }

    func phoneChangeOpen(_ row: SettingsRow) -> Bool {
        row.clickable && row.route == nil && phoneChangeEntry(phoneBound: deps.repo.me(of: identity)?.phoneBound)
    }

    func openPhoneChange() {
        guard let ports = deps.env.phoneChangePorts() else { return }
        phoneChange?.leave()
        let controller = PhoneChangeController(deps: deps, identity: identity, ports: ports, host: self, page: page)
        phoneChange = controller
        state.sub = .phoneChange
        state.version += 1
        controller.start()
    }

    /// 只关发起的这一个换号子页（旧子页的回调不关新子页），回到设置页并刷新（手机号行按重取的 Me 显示）。
    func closePhoneChange(_ sub: PhoneChangeController) {
        guard sub === phoneChange else { return }
        sub.leave()
        phoneChange = nil
        if state.sub == .phoneChange {
            state.sub = .none
        }
        state.version += 1
        refresh()
    }
}
