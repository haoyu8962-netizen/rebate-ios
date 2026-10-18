#if DEBUG
import DesignSystem
import Home
import Router
import SwiftUI

struct HomePreviewView: View {
    static let marker = "COULI_HOME_PREVIEW"
    let destination: RouteDestination
    @EnvironmentObject private var home: AppHome
    @EnvironmentObject private var environment: EnvironmentStore
    @State private var switching = false
    var body: some View {
        HomePreviewContent(model: home.preview(for: destination))
            .onAppear { home.onOpenEnvironmentSwitch = { switching = true } }
            .sheet(isPresented: $switching) { DebugPanelView(store: environment, update: home.update) }
            .accessibilityIdentifier(Self.marker)
    }
}

private struct HomePreviewContent: View {
    @ObservedObject var model: HomePreviewModel
    var body: some View {
        VStack(spacing: 0) {
            if let banner = model.banner {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: HomePreviewTexts.title).couliFont(.title)
                    Text(verbatim: "\(banner.pageKey) · \(banner.environmentName) · v\(banner.draftVersion)")
                    Text(verbatim: banner.validUntil + HomePreviewTexts.validUntil)
                    Button(HomePreviewTexts.exit, action: model.exit).frame(minHeight: 44)
                }.padding().frame(maxWidth: 600).frame(maxWidth: .infinity).background(CouliColor.backgroundMuted)
            }
            if let controller = model.controller {
                HomeSduiScreen(controller: controller)
                ScrollView {
                    VStack(alignment: .leading) {
                        Text(verbatim: HomePreviewTexts.dropped).couliFont(.footnote)
                        ForEach(Array(controller.state.dropped.enumerated()), id: \.offset) { _, drop in
                            Text(verbatim: "\(drop.id) · \(drop.type) · \(drop.reason)").couliFont(.caption)
                        }
                    }.padding().frame(maxWidth: 600).frame(maxWidth: .infinity)
                }.frame(maxHeight: 160)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        if model.phase == .loading {
                            ProgressView()
                        }
                        if model.phase == .expired {
                            Text(verbatim: HomePreviewTexts.expired).couliFont(.title)
                            Text(verbatim: HomePreviewTexts.explanation).fixedSize(horizontal: false, vertical: true)
                            Button(HomePreviewTexts.switchEnvironment, action: model.switchEnvironment)
                                .frame(minHeight: 44)
                        }
                        if case let .failed(error) = model.phase {
                            Text(verbatim: error?.message ?? "").fixedSize(horizontal: false, vertical: true)
                            Button(HomePreviewTexts.retry, action: model.retry).disabled(error?.retryEnabled != true)
                                .frame(minHeight: 44)
                        }
                        Button(HomePreviewTexts.exit, action: model.exit).frame(minHeight: 44)
                    }.padding().frame(maxWidth: 600).frame(maxWidth: .infinity)
                }
            }
        }.background(CouliColor.backgroundCanvas)
    }
}

// TODO(N-35): 调试专用草稿，不进入 Release 文案表。
private enum HomePreviewTexts {
    static let title = "草稿预览 · 仅测试包"
    static let validUntil = " 前有效"
    static let exit = "退出预览"
    static let dropped = "被丢弃的卡与原因"
    static let expired = "换不到草稿"
    static let explanation = "预览码在 10 分钟内有效，请确认当前环境后重新打开。"
    static let switchEnvironment = "切换环境"
    static let retry = "重试"
}
#endif
