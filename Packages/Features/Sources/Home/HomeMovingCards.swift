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
            CouliIconView(.info, size: CouliComponentMetric.iconInline, relativeTo: .footnote)
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
                    CouliIconView(.close, size: CouliComponentMetric.iconInline, relativeTo: .footnote)
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

/// 首页弹窗（MainPopupStatic / MainPopupDark，APP-11v-b A15；G14 无标题与按钮文字；Lottie 不做，G-V06）：图片即弹窗，没有白色衬底与
/// 关闭行。遮罩令牌主文字色 40%；图片框宽 = 窗口宽 − 2×32（最宽 400），按 4:5（画板 326×408）定高；窗口太矮时按（窗口高 − 2×24）
/// 收高、宽随之收。圆角 16 + 卡片阴影；`ad_label` 原样左上 8。关闭：44 命中区压在图片右上（视觉 40 圆底 surface + 24 主文字色 ×，
/// 距边 8），在图片裁剪层之外、绘制与触摸都在图片之上，外框至少容下关闭命中区，图片多小都不被挤掉。
/// 读屏：整窗读名「首页弹窗」（`alt` 进锁前用默认名），顺序 关闭 → 图片；打开焦点到关闭（关闭后回原处由首页搜索入口接）。
public struct HomePopupView: View {
    let popup: HomePopupUi
    let onClose: () -> Void
    let onTap: () -> Void
    @AccessibilityFocusState private var closeFocused: Bool
    /// 把读屏焦点移到关闭的次数（测量桥上报用，见 `couliFocusProbe`）。
    @State private var closeFocusRequests = 0
    public init(popup: HomePopupUi, onClose: @escaping () -> Void, onTap: @escaping () -> Void) {
        self.popup = popup; self.onClose = onClose; self.onTap = onTap
    }

    /// 画板图片框 326×408。
    static let aspect: CGFloat = 408.0 / 326.0
    static let maxWidth: CGFloat = 400
    /// 关闭命中区 44 + 距边 4×2：外框最小边。
    static let minSide: CGFloat = CouliHitTarget.minimum + 8

    /// 图片框尺寸：宽 = 窗口宽 − 64（≤400），高 = 宽 × 4:5 比；高超过（窗口高 − 48）时按高收、宽随之收；都不小于关闭所需。
    static func frameSize(in window: CGSize) -> CGSize {
        var width = min(maxWidth, max(0, window.width - CouliSpacing.s8 * 2))
        var height = width * aspect
        let maxHeight = max(0, window.height - CouliSpacing.s6 * 2)
        if height > maxHeight {
            height = maxHeight
            width = height / aspect
        }
        return CGSize(width: max(minSide, width), height: max(minSide, height))
    }

    public var body: some View {
        GeometryReader { geometry in
            let size = Self.frameSize(in: geometry.size)
            ZStack {
                CouliScrim.color.ignoresSafeArea().onTapGesture(perform: onClose).accessibilityHidden(true)
                ZStack(alignment: .topTrailing) {
                    image
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous))
                        .background(
                            RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                                .fill(CouliColor.backgroundPlaceholder)
                                .couliShadow(.floating)
                        )
                        .accessibilitySortPriority(0)
                    close
                        .padding(4)
                        .accessibilitySortPriority(1)
                }
                .frame(width: size.width, height: size.height)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(verbatim: HomeVisualRules.popupAccessibilityName))
                .accessibilityAddTraits(.isModal)
                .accessibilityAction(.escape, onClose)
                .accessibilityIdentifier("home.popup")
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
        // 全屏浮层底透明：遮罩与首页由本视图自己画（MainPopupStatic 稿：遮罩下能看到首页）；不在浮层里时不起作用
        .modifier(HomePopupClearBackground())
        .task {
            // 等弹窗挂上无障碍树后再把读屏焦点放到关闭（与组件库弹层同一时机）
            try? await Task.sleep(nanoseconds: 150_000_000)
            closeFocused = true
            closeFocusRequests += 1
        }
    }

    private var close: some View {
        Button(action: onClose) {
            CouliIconView(.close, size: 24).foregroundColor(CouliColor.textPrimary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(CouliColor.backgroundSurface))
                .frame(width: CouliHitTarget.minimum, height: CouliHitTarget.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: HomeText.text("home.popup.close")))
        .accessibilityIdentifier("home.popup.close")
        .accessibilityFocused($closeFocused)
        .couliFocusProbe("home.popup.close", focused: closeFocused, requests: closeFocusRequests)
    }

    /// 图片区：没有动作的图片按普通图片画（不用禁用按钮：系统会把禁用态压淡）。
    @ViewBuilder private var image: some View {
        let picture = Color.clear
            .overlay(ProductRemoteImage(url: ProductImageSource.url(popup.image)))
            .overlay(alignment: .topLeading) { HomeAdBadge(label: popup.adLabel).padding(CouliSpacing.s2) }
            .contentShape(Rectangle())
            .accessibilityLabel(Text(verbatim: HomeText.text("home.popup.image")))
        if popup.clickable {
            Button(action: onTap) { picture }.buttonStyle(.plain)
        } else {
            picture.accessibilityElement(children: .ignore).accessibilityAddTraits(.isImage)
        }
    }
}

/// 弹窗全屏浮层的系统底色改为透明（iOS 16.4+ 用 presentationBackground；更早的系统把承载视图的底色清掉）。
private struct HomePopupClearBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.presentationBackground(.clear)
        } else {
            content.background(HomePopupHostClearer())
        }
    }
}

private struct HomePopupHostClearer: UIViewRepresentable {
    func makeUIView(context _: Context) -> UIView {
        let view = UIView()
        DispatchQueue.main.async {
            view.superview?.superview?.backgroundColor = .clear
        }
        return view
    }

    func updateUIView(_: UIView, context _: Context) {}
}
