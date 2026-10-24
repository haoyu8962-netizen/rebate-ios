import DesignSystem
import HomeCore
import SwiftUI

/// 轮播（Main 稿）：按 height_ratio 定高、圆角 16；左上「推广」胶囊；底部指示点（当前页 16×6 品牌色胶囊，其余 6×6 控件边框色）。
/// 图片失败的那一帧只换成占位色且不可点，不把整张轮播压成禁用态。
struct HomeBanner: View {
    let section: HomeSectionUi
    let controller: HomeController
    @State private var index = 0
    var body: some View {
        GeometryReader { geometry in
            TabView(selection: $index) {
                ForEach(Array(section.items.enumerated()), id: \.element.id) { offset, item in
                    HomeItemImage(item: item, controller: controller)
                        .overlay(alignment: .topLeading) { HomeAdBadge(label: item.adLabel).padding(CouliSpacing.s2) }
                        .clipped()
                        .homeTap(item.tap, controller)
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(item.tap == nil ? .isImage : .isButton)
                        .accessibilityLabel(Text(verbatim: ([item.spokenName, item.adLabel].compactMap(\.self))
                                .joined(separator: ", ")))
                        .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: geometry.size.width * section.heightRatio)
        }
        .aspectRatio(1 / section.heightRatio, contentMode: .fit)
        .overlay(alignment: .bottom) {
            if section.items.count > 1 {
                HStack(spacing: CouliSpacing.s1) {
                    ForEach(0..<section.items.count, id: \.self) { dot in
                        Capsule().fill(dot == index ? CouliColor.brandPrimary : CouliColor.borderControl)
                            .frame(width: dot == index ? CouliSpacing.s4 : 6, height: 6)
                    }
                }
                .padding(.bottom, CouliSpacing.s2)
                .accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous))
        .task(id: section.autoplay) {
            guard section.autoplay, section.items.count > 1 else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(max(1, section.autoplayMillis))) } catch { return }
                withAnimation { index = (index + 1) % section.items.count }
            }
        }
    }
}

/// 公告条（APP-11v 按令牌推导：brand.subtle 底、圆角 16）：行高至少 44；左侧次要色圆圈 i，正文 14/21 主文字色（长文完整换行），右侧 44×44 关闭（次要色 ×）。
/// 没有跳转目标的条目按普通文字画，不用禁用按钮的灰字。
struct HomeNoticeView: View {
    let section: HomeSectionUi
    let controller: HomeController
    @State private var index = 0
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(section.items.enumerated()), id: \.element.id) { offset, item in
                if !section.autoplay || offset == index % max(1, section.items.count) {
                    row(item)
                }
            }
        }
        .padding(.leading, CouliSpacing.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 第 1 批定稿没画公告条：按令牌推导（brand.subtle 底、卡片圆角 16，与其他卡同间距；APP-11v compare 记「无定稿」）
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous).fill(CouliColor.brandSubtle)
        )
        .task(id: section.autoplay) {
            guard section.autoplay, section.items.count > 1 else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(max(1, section.autoplayMillis))) } catch { return }
                withAnimation { index += 1 }
            }
        }
    }

    private func row(_ item: HomeItemUi) -> some View {
        HStack(alignment: .center, spacing: CouliSpacing.s2) {
            CouliIconView(.info, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                .foregroundColor(CouliColor.textSecondary)
            VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                HomeAdBadge(label: item.adLabel)
                Text(verbatim: item.title ?? "").couliFont(.footnote).foregroundColor(CouliColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("home.notice.text")
            }
            .padding(.vertical, CouliSpacing.s2)
            .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum, alignment: .leading)
            .homeTap(item.tap, controller)
            .accessibilityElement(children: .combine)
            if let close = item.close {
                Button { controller.closeNotice(close) } label: {
                    CouliIconView(.close, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                        .foregroundColor(CouliColor.textSecondary)
                        .frame(width: CouliHitTarget.minimum, height: CouliHitTarget.minimum)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: controller.text("home.notice.close")))
            } else {
                Spacer().frame(width: CouliSpacing.s3)
            }
        }
    }
}

/// 首页弹窗（MainPopup 稿；G14 无标题与按钮文字）：遮罩为令牌主文字色 40%；白卡左右各留 32、圆角 16、浮层阴影；
/// 关闭 44×44 在右上角（主文字色 ×，源码顺序先于图片，不被图片遮挡）；图片左右 16、圆角 12，底部留 16。
public struct HomePopupView: View {
    let popup: HomePopupUi
    let onClose: () -> Void
    let onTap: () -> Void
    @AccessibilityFocusState private var closeFocused: Bool
    public init(popup: HomePopupUi, onClose: @escaping () -> Void, onTap: @escaping () -> Void) {
        self.popup = popup; self.onClose = onClose; self.onTap = onTap
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                CouliScrim.color.ignoresSafeArea().onTapGesture(perform: onClose).accessibilityHidden(true)
                ScrollView {
                    card(height: geometry.size.height)
                        .padding(.horizontal, CouliSpacing.s8)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
            }
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(Text(verbatim: HomeVisualRules.popupAccessibilityName))
        .accessibilityAction(.escape, onClose)
        .onAppear { closeFocused = true }
    }

    private func card(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: onClose) {
                    CouliIconView(.close).foregroundColor(CouliColor.textPrimary)
                        .frame(width: CouliHitTarget.minimum, height: CouliHitTarget.minimum)
                        .background(Circle().fill(CouliColor.backgroundSurface))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: HomeText.text("home.popup.close")))
                .accessibilityFocused($closeFocused)
            }
            .padding([.top, .trailing], 6)
            image(height: height)
                .accessibilityLabel(Text(verbatim: HomeText.text("home.popup.image")))
                .padding([.horizontal, .bottom], CouliSpacing.s4)
        }
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                .fill(CouliColor.backgroundSurface)
                .couliShadow(.floating)
        )
        .frame(maxWidth: 360)
    }

    /// 没有动作的图片按普通图片画（不用禁用按钮：系统会把禁用态压淡）。
    @ViewBuilder private func image(height: CGFloat) -> some View {
        let picture = CouliColor.backgroundPlaceholder
            .overlay(ProductRemoteImage(url: ProductImageSource.url(popup.image)))
            .overlay(alignment: .topLeading) { HomeAdBadge(label: popup.adLabel).padding(CouliSpacing.s2) }
            .frame(height: max(CouliHitTarget.minimum, min(440, height * 0.6)))
            .clipShape(RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous))
        if popup.clickable {
            Button(action: onTap) { picture }.buttonStyle(.plain)
        } else {
            picture.accessibilityElement(children: .ignore).accessibilityAddTraits(.isImage)
        }
    }
}
