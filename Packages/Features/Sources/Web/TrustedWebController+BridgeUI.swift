import BridgeHost
import Foundation
import WebKit

// MARK: - BridgeUI

extension TrustedWebController: BridgeUI {
    public func toast(text: String, long: Bool) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: long ? 3_500_000_000 : 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    public func showLoading(text: String?) {
        loadingText = text
        isLoadingOverlay = true
    }

    public func hideLoading() {
        isLoadingOverlay = false
        loadingText = nil
    }

    /// 全部字段都生效才返回 true。status_bar_style=light（浅色状态栏文字）本端做不到：App 固定浅色界面，SwiftUI 宿主的状态栏
    /// 样式不能按页面改（capability-ios.md）；这时整次调用什么都不改、返回 false（宿主回 90001）。dark 就是本端状态栏的现状。
    public func setNavBar(_ bar: BridgeNavBar) -> Bool {
        if let style = bar.statusBarStyle, style != TrustedNavStyle.statusBarDark {
            return false
        }
        if let visible = bar.visible {
            navBarVisible = visible
        }
        if let title = bar.title {
            navTitle = title
        }
        if let hide = bar.hideClose {
            hideClose = hide
        }
        if let bounce = bar.bounce {
            webView.scrollView.bounces = bounce
            webView.scrollView.alwaysBounceVertical = bounce
        }
        navStyle = navStyle.applying(bar)
        return true
    }

    /// 关闭容器。来自 nav.close 时，先让这次调用把成功响应交回页面（结算在本轮主线程任务里完成），下一轮再作废其余在途调用并关闭。
    public func close() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            host?.invalidate()
            onClose()
        }
    }
}
