import ClientCore
import DesignSystem
import Foundation
import Generated
import SwiftUI
import UIKit

/// App 的权限申请入口（03 §4.9；APP-03b）：持有 Core 的 `PermissionRequester`，把用途说明与「去设置」引导画成 CouliDialog。
/// 原生入口与以后的桥方法 `perm.request` 都只调 `request`；业务代码不直接调系统授权接口。
@MainActor
final class AppPermissions: ObservableObject {
    static let fileName = "permission-throttle.json"

    /// 用途说明（iOS：先出一屏说明，用户点【继续】后立刻弹系统框）。
    struct Rationale: Identifiable {
        let id = UUID()
        let purposeKey: String
        let continueKey: String
    }

    /// 引导去系统设置（永久拒绝、节流期内）。
    struct SettingsGuide: Identifiable {
        let id = UUID()
        let messageKey: String?
        let buttonKey: String
    }

    @Published private(set) var rationale: Rationale?
    @Published var settingsGuide: SettingsGuide?

    private var requester: PermissionRequester?
    private var rationaleContinuation: CheckedContinuation<Void, Never>?

    init(file: ClientFile = ClientFile(name: AppPermissions.fileName)) {
        requester = PermissionRequester(
            readFile: file.read,
            writeFile: file.write,
            clock: { Int64(Date().timeIntervalSince1970 * 1000) },
            platform: ClientPlatform.ios.rawValue,
            status: PermissionSystem.status,
            showRationale: { [weak self] purpose, continueKey in
                await self?.presentRationale(purpose: purpose, continueKey: continueKey)
            },
            systemRequest: PermissionSystem.request,
            showSettingsGuide: { [weak self] message, button in
                self?.settingsGuide = SettingsGuide(messageKey: message, buttonKey: button)
            }
        )
    }

    /// 申请一项权限（push / photos）。
    func request(_ permission: String, fromSettingsEntry: Bool = false, purposeShown: Bool = false) async
        -> PermissionResult {
        guard let requester else {
            return PermissionResult.unavailable(permission)
        }
        return await requester.request(
            permission: permission, fromSettingsEntry: fromSettingsEntry, purposeShown: purposeShown
        )
    }

    /// 说明页点【继续】。
    func continueFromRationale() {
        rationale = nil
        rationaleContinuation?.resume()
        rationaleContinuation = nil
    }

    /// 「去设置」：跳到系统里本 App 的设置页。
    func openSettings() {
        settingsGuide = nil
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    func dismissSettingsGuide() {
        settingsGuide = nil
    }

    private func presentRationale(purpose: String, continueKey: String?) async {
        rationaleContinuation?.resume()
        await withCheckedContinuation { continuation in
            rationaleContinuation = continuation
            rationale = Rationale(purposeKey: purpose, continueKey: continueKey ?? PermissionTextKeys.continueButton)
        }
    }

    // MARK: - 弹窗

    /// 用途说明：正文是用途文案，只有【继续】（不写「允许」「同意」这类冒充系统选项的字样，03 §4.9）。
    var rationaleDialog: CouliDialog {
        CouliDialog(
            title: rationale.flatMap { DefaultTexts.text($0.purposeKey) } ?? "",
            primary: CouliDialogAction(
                DefaultTexts.text(rationale?.continueKey ?? PermissionTextKeys.continueButton) ?? ""
            ) { [weak self] in
                self?.continueFromRationale()
            }
        )
    }

    /// 去设置引导：提示文案 +【去设置】+【取消】。
    var settingsGuideDialog: CouliDialog {
        CouliDialog(
            title: settingsGuide?.messageKey.flatMap { DefaultTexts.text($0) } ?? "",
            primary: CouliDialogAction(
                DefaultTexts.text(settingsGuide?.buttonKey ?? PermissionTextKeys.goSettings) ?? ""
            ) { [weak self] in
                self?.openSettings()
            },
            secondary: CouliDialogAction(PermissionDraftTexts.cancel) { [weak self] in
                self?.dismissSettingsGuide()
            }
        )
    }
}

/// 字典里还没有的权限引导文案（草稿）。TODO(N-21): 「去设置」引导的取消按钮键 BR-TEXT-14 表 D 未登记。
enum PermissionDraftTexts {
    static let cancel = "取消"
}

extension PermissionResult {
    static func unavailable(_ permission: String) -> PermissionResult {
        PermissionResult(permission: permission, resultRaw: PermissionResultRaw.unavailable)
    }
}
