# 平台内置图标（F-X-05a）

本文说明同级目录 `PlatformIcons/`；本文在 `Package.swift` 里 exclude，不打进安装包。

BR-TEXT-24「内置兜底图」：从规划仓库 `couli` 的 `design/icons/platform/` 按文件名**原样拷入**（不改像素、不重新压缩、不生成 @2x / @3x 派生图；224px 原图够 44pt × 3 倍屏）。
来源提交：`couli` `8209d6e31bf5e4eb336421f51aa5354eb6b539c2`。机器可读清单是 `PlatformIcons/manifest.json`（随图入包）（源路径、sha256、字节数、尺寸），以它为准。

| 标识键 | 文件 | sha256 | 字节 |
| --- | --- | --- | --- |
| `taobao` | `taobao.png` | `d987c0084948eeeada4da71bce00653a9eb2e5743149adb4b25587adb573a4ea` | 34046 |
| `jd` | `jd.png` | `574f09c6bdfc99fa91e814a07e5fd569618060065fa723165059586b0e79766c` | 6565 |
| `pdd` | `pinduoduo.png` | `6b9ff1c90ef7c168ecda69b56e5b33ab609a7883a910688aeeee8ca8ee07997d` | 9935 |

- `PlatformIcons/` 在 `Package.swift` 里用 `.copy` 声明，保留原始字节；不要放进 `.xcassets`（会被重新压缩）。
- 只放 BR-TEXT-24 标识键表里已有官方图的平台。暂缺：tmall、wechat、wechat_pay、alipay、wecom（界面只显示文字，不画占位）。vip、douyin、meituan、eleme、fliggy、didi 尚无标识键，首页金刚区目前也不用，未拷入。
- 凑狸自有品牌素材不得放进 `PlatformIcons/`（品牌图在 `Brand.xcassets`）。
- 换图：更新规划仓库原图后，重新原样拷贝并同步更新 `manifest.json` 与本表，以及测试里的独立摘要清单。后台下发替换图（`/v1/config.platform_icons`）归 F-X-05。
