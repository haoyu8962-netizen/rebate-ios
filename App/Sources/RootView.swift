import Config
import DesignSystem
import Generated
import SwiftUI

/// 最小首屏：令牌背景 + App 名称图形占位。DEBUG 下另显示令牌版本、构建配置与调试面板入口（英文开发字样）。
struct RootView: View {
    @EnvironmentObject private var environment: EnvironmentStore
    #if DEBUG
    @State private var showsDebugPanel = false
    #endif

    var body: some View {
        switch environment.gate {
        case .settled:
            content
        case .blocked:
            EnvironmentBlockedView(retry: environment.retryLaunchCleanup)
        }
    }

    private var content: some View {
        ZStack {
            CouliColor.backgroundCanvas
                .ignoresSafeArea()
            VStack(spacing: CouliSpacing.s4) {
                BrandMark()
                #if DEBUG
                debugInfo
                #endif
            }
            .padding(CouliSpacing.s6)
        }
        #if DEBUG
        .sheet(isPresented: $showsDebugPanel) {
            DebugPanelView(store: environment)
        }
        #endif
    }

    #if DEBUG
    private var debugInfo: some View {
        VStack(spacing: CouliSpacing.s2) {
            Text(verbatim: "tokens \(DesignTokens.version)")
                .accessibilityIdentifier("root.tokensVersion")
            Text(verbatim: "config \(BuildInfo.configurationName) · env \(environment.current.id)")
                .accessibilityIdentifier("root.buildConfiguration")
            Button {
                showsDebugPanel = true
            } label: {
                Text(verbatim: "Debug panel")
                    .frame(minWidth: CouliHitTarget.minimum, minHeight: CouliHitTarget.minimum)
            }
            .accessibilityIdentifier("root.debugPanelButton")
        }
        .couliFont(.footnote)
        .foregroundColor(CouliColor.textSecondary)
    }
    #endif
}

/// 启动对账清理失败（自动重试一次后仍失败）时的阻断页：一句说明 +「重试」。不进入正常界面。
/// 文案取包内默认文案：通用失败用 error.50001 的 fallback（不带追踪号），按钮用 external_page.retry。
/// TODO(APP-02): 契约补通用键（如 common.load_failed / common.retry）后改用通用键。
private struct EnvironmentBlockedView: View {
    let retry: () -> Void

    var body: some View {
        ZStack {
            CouliColor.backgroundCanvas
                .ignoresSafeArea()
            VStack(spacing: CouliSpacing.s4) {
                Text(verbatim: DefaultTexts.fallback("error.50001") ?? "")
                    .couliFont(.body)
                    .foregroundColor(CouliColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("environment.blocked.message")
                Button(action: retry) {
                    Text(verbatim: DefaultTexts.text("external_page.retry") ?? "")
                        .frame(minWidth: CouliHitTarget.minimum, minHeight: CouliHitTarget.minimum)
                }
                .accessibilityIdentifier("environment.blocked.retry")
            }
            .padding(CouliSpacing.s6)
        }
    }
}

/// App 名称图形占位（正式图形由设计稿提供后替换）。
private struct BrandMark: View {
    private var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? ""
    }

    var body: some View {
        RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
            .fill(CouliColor.brandPrimary)
            .frame(width: CouliSpacing.s16 * 2, height: CouliSpacing.s16)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: displayName))
            .accessibilityIdentifier("root.brandMark")
    }
}
