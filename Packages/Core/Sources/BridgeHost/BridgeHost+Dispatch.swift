import Foundation

/// BridgeHost 的分派：协议准入、强更守卫、归属核对都已通过，把方法交给能力实现。
extension BridgeHost {
    func dispatch(
        _ method: String,
        _ params: [String: Any],
        readOnlyMode: Bool,
        owner: BridgeCallOwner
    ) async -> BridgeOutcome {
        guard let ui else { return .fail(BridgeCode.nativeError) }
        if method.hasPrefix("ui.") || method == "nav.close" {
            return dispatchUI(method, params, ui: ui)
        }
        switch method {
        case "app.getEnv":
            return .ok(services.env())
        case "app.getConfig":
            return services.config(keys: JSONKind.strings(params, "keys"))
        case "auth.getUser":
            return await services.user(validity: owner.validity)
        case "auth.getH5Token":
            return await services.h5Token(readOnly: readOnlyMode, validity: owner.validity)
        case "auth.login":
            return await services.login()
        case "net.signedRequest":
            return await services.signedRequest(
                method: JSONKind.string(params, "method") ?? "",
                path: JSONKind.string(params, "path") ?? "",
                bodyJson: params["body"].flatMap(JSONKind.encode),
                validity: owner.validity
            )
        case "nav.open":
            let target = (params["params"] as? [String: Any]).flatMap(JSONKind.encode) ?? "{}"
            let route = JSONKind.string(params, "route") ?? ""
            // 打开的目标可能让本容器出栈（如 Home 清栈）：这次调用先按结果结算，再 teardown（三端共性第 43 条）。
            return await performNavigation(owner) {
                await self.services.navOpen(route: route, paramsJson: target, readOnlyPagesOnly: readOnlyMode)
            }
        default:
            return await dispatchDevice(method, params, owner: owner)
        }
    }

    /// 剪贴板、权限、埋点。
    private func dispatchDevice(
        _ method: String,
        _ params: [String: Any],
        owner: BridgeCallOwner
    ) async -> BridgeOutcome {
        switch method {
        case "clipboard.write":
            services.clipboardWrite(text: JSONKind.string(params, "text") ?? "")
        case "clipboard.read":
            await services.clipboardRead()
        case "clipboard.setAutoDetect":
            services.setClipboardAutoDetect(enabled: JSONKind.bool(params["enabled"]) ?? false)
        case "perm.getPushStatus":
            await services.pushStatus()
        case "perm.request":
            await services.requestPermission(type: JSONKind.string(params, "type") ?? "") { [weak self] in
                self?.stillOwned(generation: owner.generation, state: owner.state) ?? false
            }
        case "track.event":
            services.track(name: JSONKind.string(params, "name") ?? "")
        default:
            .fail(BridgeCode.notSupported)
        }
    }

    /// 容器自身的界面能力。
    private func dispatchUI(_ method: String, _ params: [String: Any], ui: any BridgeUI) -> BridgeOutcome {
        switch method {
        case "ui.toast":
            ui.toast(text: JSONKind.string(params, "text") ?? "", long: JSONKind.string(params, "duration") == "long")
        case "ui.showLoading":
            ui.showLoading(text: JSONKind.string(params, "text"))
        case "ui.hideLoading":
            ui.hideLoading()
        case "ui.setNavBar":
            guard ui.setNavBar(BridgeNavBar(params: params)) else {
                return .fail(BridgeCode.notSupported)
            }
        case "nav.close":
            ui.close()
        default:
            return .fail(BridgeCode.notSupported)
        }
        return .ok()
    }
}

/// 已校验的 params（只读，跨越一次 Task 边界用）。
struct BridgeParams: @unchecked Sendable {
    let raw: [String: Any]
}

/// 一次调用的归属：开始时的宿主世代、调用方状态与有效性。
struct BridgeCallOwner {
    let generation: UInt64
    let state: BridgeCallerState
    let validity: BridgeCallValidity
}
