# rebate-ios

凑狸 iOS 原生壳。规则见 `AGENTS.md`。

## 上手

```sh
xcodegen generate                      # 生成 Couli.xcodeproj（不入库）
open Couli.xcodeproj                   # 方案 Couli；Debug 默认连 test 环境
tools/ci/verify.sh --fast              # lint + 生成物漂移 + Debug 构建
tools/ci/verify.sh                     # 全量本机 CI（三套配置构建、测试、Release 制品扫描）
```

## 目录

| 路径 | 内容 |
| --- | --- |
| `App/` | AppShell 入口、`Info.plist`（手写、经预处理：测试深链 scheme 只在 Debug / Staging 声明）、路由接线与页面注册表（`Sources/Routing`）、Entitlements、隐私清单、`Config/*.xcconfig`；环境与地址（`Sources/Environment`）、调试源码集（`Sources/Debug`，只在 Debug / Staging 编译）、生成的 debug_only 路由表（`Sources/Generated`） |
| `Packages/Generated` | 契约生成物（`tools/codegen/gen.py` 生成，禁止手改）+ 一致性测试 |
| `Packages/Core` | Core 层：`Config`（环境类型、生效记录与切换清理）、`Router`（入口守卫、深链解析、pending_action、推送落点、启动意图排队；向量 `specs/router-vectors.json`）与各模块占位 |
| `Packages/DesignSystem` | 令牌 → SwiftUI 映射（颜色、文字样式、间距、圆角、命中区） |
| `Packages/Features` | 9 个功能 target，互不依赖 |
| `contracts/snapshot/` | 按 `contract.lock` 锁定的契约快照（`tools/contracts/sync.sh` 生成） |
| `UITests/`、`AppTests/` | XCUITest 冒烟、App 单测 |
| `tools/` | 快照同步、代码生成、本机 CI、Release 制品扫描、lint 违反样例 |

## 构建配置

| 配置 | 显示名 | 默认环境 | 调试能力 |
| --- | --- | --- | --- |
| Debug | 凑狸调试 | test | 编译 |
| Staging | 凑狸测试（构建号带 `.9` 后缀） | staging | 编译（连 prod 时只剩切换服务器） |
| Release | 凑狸 | prod（唯一） | 不编译 |

Staging 用普通命令构建即可（`xcodebuild -scheme Couli -configuration Staging build`，或 Xcode 里选 Staging）。
注意：Xcode 对自定义配置名 Staging 按本地包的 Release 编译包，包里看不到 `DEBUG`；所以调试能力一律写在
App target 的 `#if DEBUG` 里，包源码不写 DEBUG 条件（swiftlint 规则 `no_debug_condition_in_packages`，理由见 `project.yml`）。
Team ID 与正式域名未给定（`../couli-runs/NATIVE/needs.md` N-04、N-05），现只做模拟器与未签名构建。

## 换契约版本

改 `contract.lock` 里的提交 → `tools/contracts/sync.sh` → `python3 tools/codegen/gen.py` → `tools/ci/verify.sh`。
worktree 里仓库相对路径不成立时：`REBATE_PLATFORM_DIR=… COULI_DIR=… tools/contracts/sync.sh`。
