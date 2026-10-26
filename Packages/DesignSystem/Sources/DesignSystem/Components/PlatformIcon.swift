import Foundation
import SwiftUI
import UIKit

/// 平台图标的尺寸档（F-X-05a）：来源标签里的 14、首页金刚区平台格的 44；授权半屏标题前的 32（APP-06v G-D14，同一张内置图缩放，
/// 不新增素材）。不随动态字号放大。
public enum PlatformIconSize: Sendable {
    /// 来源标签 `PlatformBadge` 里的小图标（design/specs/app-home.md「14px 官方图标」）。
    case badge
    /// 首页金刚区平台格（APP-11v）。
    case grid
    /// 授权半屏标题前（APP-06v G-D14「标题前 32 平台官方图标」）。
    case sheet
    /// 选择列表（APP-08v 平台筛选半屏的选项前 20，变更记录「来源标签图标尺寸补 20（选择列表）」）。
    case select

    public var points: CGFloat {
        switch self {
        case .badge: 14
        case .grid: 44
        case .sheet: 32
        case .select: 20
        }
    }
}

/// 包内内置的平台官方图（BR-TEXT-24「内置兜底图」）。
///
/// 资源是 `Resources/PlatformIcons/` 下从规划仓库 `design/icons/platform/` 原样拷入的 PNG（来源提交与 sha256 见同目录
/// `manifest.json`）；按 `.copy` 入包，保留原始字节。只按图片解码显示。
enum PlatformIconCatalog {
    /// 标识键 → 内置文件名（BR-TEXT-24 标识键表；只列已有官方图的平台）。
    /// 暂缺：tmall、wechat、wechat_pay、alipay、wecom —— 没有图时调用方只显示文字。
    static let builtinFiles: [String: String] = [
        "taobao": "taobao.png",
        "jd": "jd.png",
        "pdd": "pinduoduo.png",
    ]

    @MainActor private static var cache: [String: UIImage] = [:]

    /// 取内置图；未知编码、暂缺平台或文件读不出时为 nil（不崩溃，调用方按文字兜底）。
    /// 只用表里的固定文件名，平台编码本身不参与拼路径。
    @MainActor
    static func image(for platformCode: String) -> UIImage? {
        guard let file = builtinFiles[platformCode] else { return nil }
        if let cached = cache[file] {
            return cached
        }
        guard let url = Bundle.module.resourceURL?
            .appendingPathComponent("PlatformIcons", isDirectory: true)
            .appendingPathComponent(file),
            let data = try? Data(contentsOf: url),
            let image = UIImage(data: data)
        else { return nil }
        cache[file] = image
        return image
    }
}

/// 平台图标（F-X-05a）：按平台编码（BR-TEXT-24 标识键，如 `pdd`）取包内官方图，按 14 / 44 两档显示。
///
/// - 图片原样显示（`renderingMode(.original)`）：不跟前景色 / tint 着色，深色模式不反色。
/// - 装饰性：读屏隐藏；平台名由外层（来源标签、金刚区格子）读出。
/// - 没有内置图的编码（暂缺平台、未知编码）什么也不画，不画占位方块；可先用 `hasBuiltinImage` 判断。
/// - `remoteURL`：给 F-X-05（后台下发替换图 `/v1/config.platform_icons`）预留；本任务一律显示内置图，
///   下载、摘要校验与失败回内置的逻辑在 F-X-05 做。
public struct PlatformIcon: View {
    private let platformCode: String
    private let size: PlatformIconSize
    private let remoteURL: URL?

    public init(platformCode: String, size: PlatformIconSize = .badge, remoteURL: URL? = nil) {
        self.platformCode = platformCode
        self.size = size
        self.remoteURL = remoteURL
    }

    /// 这个平台编码有没有包内官方图。
    @MainActor
    public static func hasBuiltinImage(_ platformCode: String) -> Bool {
        PlatformIconCatalog.image(for: platformCode) != nil
    }

    public var body: some View {
        if let image = PlatformIconCatalog.image(for: platformCode) {
            Image(uiImage: image)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: size.points, height: size.points)
                .accessibilityHidden(true)
        }
    }
}
