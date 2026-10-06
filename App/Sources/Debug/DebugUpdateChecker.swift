#if DEBUG
import Config
import Foundation
import Update

/// 调试面板的版本检查场景（只在 Debug / Staging 编译；Release 用永远失败的 `FailingUpdateChecker`，
/// release-scan 查 `AppVersionCheckExample.marker`）。数据一律从契约 openapi `GET /v1/app-versions/check` 的响应示例
/// （`AppVersionCheckExample.dataJSON`，gen.py 生成）改几个字段得到，不臆造报文字段（与 Android 同一组场景）。
enum DebugUpdateScenario: String, CaseIterable, Identifiable {
    /// 正常：recommended_version 改成与 min_supported_version 相同（本机 1.0.0 不低于两者）。
    case normal
    /// 建议更新：契约示例原样（min 1.0.0、recommended 1.1.0、latest 1.2.0）。
    case recommend
    /// 强制更新：min_supported_version 改成 latest_version。
    case force
    /// 商店都不可用：强制更新，且各商店 listed_version 都为 null（没有已知上架版本）。
    case storesUnavailable = "stores_unavailable"
    /// 请求失败。
    case failure

    var id: String {
        rawValue
    }

    /// 面板上的英文字样（调试用，不进文案字典）。
    var label: String {
        switch self {
        case .normal: "Update: normal"
        case .recommend: "Update: recommend"
        case .force: "Update: force"
        case .storesUnavailable: "Update: no store"
        case .failure: "Update: request failed"
        }
    }

    /// 选择存在 UserDefaults 的 `CouliUpdateScenario`（不在 App 命名空间里，切换环境不清）；
    /// 截图与 UI 测试可用启动参数 `-CouliUpdateScenario force` 覆盖。
    static let defaultsKey = "CouliUpdateScenario"

    static var current: DebugUpdateScenario {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .normal }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// 调试假结果的强更记录键：与 Release 读取的 `AppNamespace.updateRecordKey` 分开（编排者裁定：调试假结果不得写进
    /// Release 读取的同一持久化存储）；在 App 命名空间里，切换环境时一并清掉。
    static let recordKey = AppNamespace.userDefaultsPrefix + "debug.update.record"

    /// 截图与 UI 测试：启动参数 `-CouliUpdateReset 1` 在 Gate 读取之前清掉本机调试强更记录（含「暂不更新」）
    /// 与面板上存下的场景（回到「正常」；启动参数 `-CouliUpdateScenario` 仍优先）。
    static func applyResetArgument(defaults: UserDefaults = .standard) {
        guard defaults.bool(forKey: "CouliUpdateReset") else { return }
        defaults.removeObject(forKey: recordKey)
        defaults.removeObject(forKey: defaultsKey)
    }

    /// 契约示例按场景改字段后的 check.data。
    func data() -> [String: Any] {
        guard let raw = AppVersionCheckExample.dataJSON.data(using: .utf8),
              let example = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else {
            return [:]
        }
        var fields = example
        switch self {
        case .normal:
            fields["recommended_version"] = example["min_supported_version"]
        case .recommend, .failure:
            break
        case .force:
            fields["min_supported_version"] = example["latest_version"]
        case .storesUnavailable:
            fields["min_supported_version"] = example["latest_version"]
            let stores = example["stores"] as? [[String: Any]] ?? []
            fields["stores"] = stores.map { entry in
                var copy = entry
                copy["listed_version"] = NSNull()
                return copy
            }
        }
        return fields
    }
}

/// check.data → `UpdateCheckResult`（只投影字段，不做判定）。listed_version 为 null 的商店丢弃（rule-gaps G04）；
/// recheck_interval_sec 不在 check 响应里，用包内默认（rule-gaps G01）。
enum DebugUpdateAdapter {
    static func adapt(_ data: [String: Any]) -> UpdateCheckResult {
        let stores = (data["stores"] as? [[String: Any]] ?? []).compactMap { entry -> UpdateStoreListing? in
            guard let store = entry["store"] as? String, let version = entry["listed_version"] as? String else {
                return nil
            }
            return UpdateStoreListing(store: store, version: version)
        }
        return UpdateCheckResult(
            minSupported: data["min_supported_version"] as? String,
            recommended: data["recommended_version"] as? String,
            latest: data["latest_version"] as? String,
            defaultStore: data["default_store"] as? String,
            stores: stores,
            updateTitle: data["update_title"] as? String,
            updateNotes: data["update_notes"] as? String
        )
    }
}

/// 读调试场景、返回假结果的检查器；模拟一点网络耗时，让「检查中」可见。
@MainActor
final class DebugUpdateChecker: UpdateChecker {
    static let fakeLatency: Duration = .milliseconds(300)

    func check(completion: @escaping @MainActor (UpdateCheckOutcome) -> Void) {
        let scenario = DebugUpdateScenario.current
        Task { @MainActor in
            try? await Task.sleep(for: Self.fakeLatency)
            if scenario == .failure {
                completion(.failure)
            } else {
                completion(.success(DebugUpdateAdapter.adapt(scenario.data())))
            }
        }
    }
}
#endif
