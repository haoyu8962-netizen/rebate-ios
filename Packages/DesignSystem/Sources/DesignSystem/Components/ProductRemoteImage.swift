import SwiftUI

/// 契约 ProductCard.image（string | null，format uri）→ 可加载的地址。只接受 https（ATS 也只放行它）；
/// 字段缺失、为 null、空串、不是绝对 https 地址时返回 nil，页面显示占位底。
public enum ProductImageSource {
    public static func url(_ raw: Any?) -> URL? {
        guard let text = raw as? String, !text.isEmpty, let url = URL(string: text),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false
        else { return nil }
        return url
    }
}

/// 商品图的加载阶段（读屏值与测试核对用）。
public enum ProductImagePhase: String, Sendable {
    /// 没有图片地址（字段为空）。
    case none
    case loading
    case loaded
    case failed
}

/// 商品图（系统 AsyncImage，不加依赖；共性 22）：加载成功铺满容器（裁切）；加载中、字段为空、失败时透明，露出容器的
/// 占位底（ProductCard 的图片框、ProductHeroImage 的占位块）。`onPhase` 回报阶段。
public struct ProductRemoteImage: View {
    private let url: URL?
    private let onPhase: ((ProductImagePhase) -> Void)?

    public init(url: URL?, onPhase: ((ProductImagePhase) -> Void)? = nil) {
        self.url = url
        self.onPhase = onPhase
    }

    public var body: some View {
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFill().onAppear { onPhase?(.loaded) }
                case .failure:
                    Color.clear.onAppear { onPhase?(.failed) }
                default:
                    Color.clear.onAppear { onPhase?(.loading) }
                }
            }
        } else {
            Color.clear.onAppear { onPhase?(.none) }
        }
    }
}

/// 详情页头图（设计稿 Product：圆角大图，宽高比 3:2）：占位底 + 商品图；读屏是一张图片（「商品图片，{标题}」）。
public struct ProductHeroImage: View {
    private let url: URL?
    private let accessibilityLabel: String
    @State private var phase: ProductImagePhase = .none

    public init(url: URL?, accessibilityLabel: String) {
        self.url = url
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
            .fill(CouliColor.backgroundPlaceholder)
            .aspectRatio(1.5, contentMode: .fit)
            .overlay(ProductRemoteImage(url: url) { phase = $0 })
            .clipShape(RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous))
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: accessibilityLabel))
            .accessibilityAddTraits(.isImage)
            // UI 测试据此核对加载结果（成功显示图片、失败与为空显示占位）。
            .accessibilityIdentifier("product.image.\(phase.rawValue)")
    }
}
