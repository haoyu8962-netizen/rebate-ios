#!/usr/bin/env python3
"""首页（APP-11）的 App 层接线检查。

    python3 tools/ci/check-home-wiring.py [仓库根]   检查；违反退出 1，文件读不出退出 2
    python3 tools/ci/check-home-wiring.py --self-test  用内置漏接样例自测（每个样例都必须被拦，合规样例必须放行）

为什么要查：首页的行为都在 HomeCore 的执行器与 App/Sources/Home 的 AppHome 里，单测经它们断言；SwiftUI 入口（CouliApp、路由视图表、
首页路由视图）没有单测目标，只允许一行转发。本检查只守「转发存在、参数没被替换」（cross-platform-lessons C 节；FU-IOS-0713 止损口径：
下列漏接写法都要拦住，此外的语法层绕过按 S2 处理），不判断行为。

规则（去掉注释与字符串字面量之后逐行匹配；每条只许出现一次，所在行与它的外层都不得是条件分支 / 死代码）：
  R1 CouliApp.registerEarlyCleaners 里：`HomeDataCleaner.register()`（启动对账之前登记，撤回同意与切换环境都清）。
  R2 CouliApp 的场景切换：`AppScenePhases.Targets(` 的实参里有 `home: home`（不得写成 `home: nil` 等恒值）。
  R3 CouliApp：`home.connect(me: <账号组合>.me)`（诊断信息的首页版本，G31）；接收者必须是 `home`。
  R4 CouliApp：`.environmentObject(home)`。
  R5 路由视图表：`"Home": { AnyView(HomeRouteView(destination: $0)) }`（正式首页与基本模式只读首页同一个渲染器）。
  R6 路由视图表（只在 #if DEBUG 里）：`"HomePreview": { AnyView(HomePreviewView(destination: $0)) }`。
  R7 首页路由视图：`HomeSduiScreen(controller: home.controller` 且 `grayscale: home.grayscale`（置灰只作用于首页根视图）。
  R8 首页路由视图出现时 `.onAppear { home.tabAppeared() }`（第 2 版，评审 T-15：真实首页必须被启动）。
  R9 CouliApp 经生产工厂 `AppHome.make(..., variant: .current, ...)` 装配首页（第 2 版，评审 T-12）；不得直接 `AppHome(`、不得写死变体。
  R10 生产工厂（App/Sources/Home/AppHomeSupport.swift）构造生产端口 `ApiClientHomeContractPort(`（正好一次、不在条件分支里），
      Release 分支不得写成恒为空：禁止 `debugPort() : nil`、`? … : nil` 的端口三元式、`port: nil`、`?? nil`
      （FU-X-HOME-PAGE-API-ios，D10-643「CI 断言 Release 首页 port 非空」的源码层；行为由 AppTests HomePageApiWiringTests 证明）。
漏接样例（--self-test）：恒值（`home: nil`、`grayscale: false`）、死代码（`if false {`、`#if NEVER`）、二次读取（同一规则写两次，后一次覆盖）、
后续覆盖（转发后又把同名变量改掉）、错误接收者（`other.connect(me:`、`HomeSduiScreen(controller: preview.controller`）。
只用 Python 3 标准库。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

COULI_APP = "App/Sources/CouliApp.swift"
REGISTRY = "App/Sources/Routing/RouteViewRegistry.swift"
HOME_ROUTE = "App/Sources/Home/HomeRouteView.swift"
HOME_SUPPORT = "App/Sources/Home/AppHomeSupport.swift"

# (文件, 规则名, 必须匹配的正则, 所在函数 / 块的要求)
RULES = [
    (COULI_APP, "R1 撤回同意 / 切换环境清理器登记", r"\bHomeDataCleaner\.register\(\s*\)", "func registerEarlyCleaners"),
    (COULI_APP, "R2 场景切换交给首页", r"AppScenePhases\.Targets\([^)]*\bhome:\s*home\b", None),
    (COULI_APP, "R3 诊断信息首页版本", r"(?<![\w.])home\.connect\(\s*me:\s*\w+\.me\s*\)", None),
    (COULI_APP, "R4 首页注入环境", r"\.environmentObject\(\s*home\s*\)", None),
    (REGISTRY, "R5 Home 路由视图", r"\"Home\":\s*\{\s*AnyView\(\s*HomeRouteView\(\s*destination:\s*\$0\s*\)\s*\)\s*\}", None),
    (REGISTRY, "R6 HomePreview 路由视图（DEBUG）", r"\"HomePreview\":\s*\{\s*AnyView\(\s*HomePreviewView\(\s*destination:\s*\$0\s*\)\s*\)\s*\}",
     "#if DEBUG"),
    (HOME_ROUTE, "R7 首页渲染器", r"HomeSduiScreen\(\s*controller:\s*home\.controller\s*,\s*grayscale:\s*home\.grayscale\b", None),
    (HOME_ROUTE, "R8 首页出现时启动（生命周期转发）", r"\.onAppear\s*\{\s*home\.tabAppeared\(\s*\)\s*\}", None),
    (COULI_APP, "R9 经生产工厂按当前构建装配首页", r"AppHome\.make\([^)]*\bvariant:\s*\.current\b", None),
    (HOME_SUPPORT, "R10 生产工厂构造生产端口", r"(?<![\w.])ApiClientHomeContractPort\(", None),
]

# 恒值 / 被替换的实参
FORBIDDEN = [
    (COULI_APP, r"\bhome:\s*nil\b", "场景切换没有交给首页（home: nil）"),
    (COULI_APP, r"(?<![\w.])AppHome\(", "首页没有经生产工厂 AppHome.make 装配（直接构造）"),
    (COULI_APP, r"variant:\s*\.(debug|release)\b", "构建变体被写死"),
    (HOME_ROUTE, r"grayscale:\s*(true|false)\b", "置灰写死"),
    (HOME_ROUTE, r"HomeSduiScreen\(\s*controller:(?!\s*home\.controller\b)", "渲染器的控制器不是 home.controller"),
    (COULI_APP, r"(?<![\w.])(?!home\b)\w+\.connect\(\s*me:", "connect(me:) 的接收者不是 home"),
    (COULI_APP, r"\bvar\s+home\b[^\n]*=|(?<!let )(?<![\w.])home\s*=[^=]", "home 被重新赋值（后续覆盖）"),
    (HOME_SUPPORT, r"debugPort\(\)\s*:\s*nil\b", "R10 Release 分支的首页端口写成了 nil（debugPort() : nil）"),
    (HOME_SUPPORT, r"\bport\b[^\n=]*=[^\n]*\?[^\n]*:\s*nil\b", "R10 首页端口的三元式有一支恒为 nil"),
    (HOME_SUPPORT, r"\bport:\s*nil\b", "R10 首页端口直接传 nil"),
    (HOME_SUPPORT, r"\?\?\s*nil\b", "R10 首页端口回落到 nil（?? nil）"),
]

DEAD_OPENERS = re.compile(r"^\s*(if\s+false\b|if\s+true\s*\{\s*\}\s*else|#if\s+(?!DEBUG\b)\w+|#if\s+false\b|while\s+false\b|guard\s+false\b)")


def strip(text: str) -> list[str]:
    """去掉注释与字符串字面量内容（保留引号），保留行号。路由名字面量 "Home" / "HomePreview" 保留原文。"""
    out, i, n = [], 0, len(text)
    buf = []
    block = 0
    while i < n:
        c = text[i]
        if block:
            if text.startswith("*/", i):
                block -= 1
                i += 2
                continue
            if text.startswith("/*", i):
                block += 1
                i += 2
                continue
            if c == "\n":
                buf.append("\n")
            i += 1
            continue
        if text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
            continue
        if text.startswith("/*", i):
            block = 1
            i += 2
            continue
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"' and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            literal = text[i:j + 1]
            buf.append(literal if literal in ('"Home"', '"HomePreview"') else '""')
            i = j + 1
            continue
        buf.append(c)
        i += 1
    out = "".join(buf).split("\n")
    return out


def enclosing(lines: list[str], index: int) -> list[str]:
    """按缩进找所在行的各层外层开头行（swiftformat 保证缩进反映嵌套）。"""
    result = []
    indent = len(lines[index]) - len(lines[index].lstrip())
    for k in range(index - 1, -1, -1):
        line = lines[k]
        if not line.strip():
            continue
        level = len(line) - len(line.lstrip())
        if line.lstrip().startswith("#"):
            result.append(line)
            continue
        if level < indent:
            result.append(line)
            indent = level
    return result


def check_text(path: str, text: str) -> list[str]:
    errors = []
    lines = strip(text)
    joined = "\n".join(lines)
    for file, name, pattern, scope in RULES:
        if file != path:
            continue
        hits = [m for m in re.finditer(pattern, joined, re.S)]
        if len(hits) != 1:
            errors.append(f"{path}: {name} 应正好出现一次，实际 {len(hits)} 次")
            continue
        line_index = joined[: hits[0].start()].count("\n")
        outer = enclosing(lines, line_index)
        for opener in outer:
            stripped = opener.strip()
            if DEAD_OPENERS.match(opener) or re.match(r"^(if|else|guard|switch|case|default|while)\b", stripped) \
                    or stripped.startswith("} else"):
                errors.append(f"{path}: {name} 在条件分支 / 死代码里（{stripped}）")
                break
        if scope == "#if DEBUG":
            if not any(o.strip() == "#if DEBUG" for o in outer) and not inside_debug(lines, line_index):
                errors.append(f"{path}: {name} 必须只在 #if DEBUG 里")
        elif scope and not any(scope in o for o in outer):
            errors.append(f"{path}: {name} 不在 {scope} 里")
    for file, pattern, message in FORBIDDEN:
        if file == path and re.search(pattern, joined):
            errors.append(f"{path}: {message}")
    return errors


def inside_debug(lines: list[str], index: int) -> bool:
    depth = []
    for k in range(index):
        s = lines[k].strip()
        if s.startswith("#if"):
            depth.append(s)
        elif s.startswith("#else") and depth:
            depth[-1] = "#else"
        elif s.startswith("#endif") and depth:
            depth.pop()
    return bool(depth) and depth[-1] == "#if DEBUG"


def check(root: Path) -> int:
    errors = []
    for path in (COULI_APP, REGISTRY, HOME_ROUTE, HOME_SUPPORT):
        try:
            text = (root / path).read_text(encoding="utf-8")
        except OSError as error:
            print(f"读不出 {path}：{error}")
            return 2
        errors += check_text(path, text)
    for error in errors:
        print(error)
    if errors:
        return 1
    print("首页接线检查通过")
    return 0


GOOD = {
    COULI_APP: """
struct CouliApp: App {
    @StateObject private var home: AppHome

    private static func registerEarlyCleaners() {
        OrderCacheCleaner.register()
        HomeDataCleaner.register()
    }

    init() {
        let home = AppHome.make(network: web.network, routing: web.routing, variant: .current, debugPort: Self.debugHomePort)
        home.connect(me: account.me)
        _home = StateObject(wrappedValue: home)
    }

    var body: some Scene {
        WindowGroup {
            RootView(routing: routing)
                .environmentObject(home)
                .onChange(of: scenePhase) { phase in
                    AppScenePhases.apply(phase, AppScenePhases.Targets(
                        routing: routing, me: me, login: login, home: home
                    ))
                }
        }
    }
}
""",
    REGISTRY: """
enum RouteViewRegistry {
    static let builders: [String: Builder] = {
        var table: [String: Builder] = [
            "Home": { AnyView(HomeRouteView(destination: $0)) },
            "Search": { AnyView(SearchRouteView(destination: $0)) },
        ]
        #if DEBUG
        table["HomePreview"] = nil
        table.merge([
            "HomePreview": { AnyView(HomePreviewView(destination: $0)) },
        ]) { $1 }
        #endif
        return table
    }()
}
""",
    HOME_ROUTE: """
struct HomeRouteView: View {
    let destination: RouteDestination
    @EnvironmentObject private var home: AppHome

    var body: some View {
        HomeSduiScreen(controller: home.controller, grayscale: home.grayscale)
            .onAppear { home.tabAppeared() }
    }
}
""",
    HOME_SUPPORT: """
extension AppHome {
    static func make(
        network: AppNetwork,
        variant: HomeBuildVariant,
        debugPort: () -> HomeContractPort?
    ) -> AppHome {
        let live = ApiClientHomeContractPort(api: network.client)
        let port: HomeContractPort = variant == .debug ? (debugPort() ?? live) : live
        return AppHome(network: network, port: port)
    }
}
""",
}

# 漏接样例：(说明, 文件, 把合规样例里的 old 换成 new)
BAD = [
    ("恒值：场景切换 home: nil", COULI_APP, "login: login, home: home", "login: login, home: nil"),
    ("缺失：清理器没登记", COULI_APP, "        HomeDataCleaner.register()\n", ""),
    ("错误位置：清理器登记在 init 里", COULI_APP, "        HomeDataCleaner.register()\n", ""),
    ("死代码：if false 包住诊断接线", COULI_APP, "        home.connect(me: account.me)\n",
     "        if false {\n            home.connect(me: account.me)\n        }\n"),
    ("错误接收者：connect 接到别的对象", COULI_APP, "home.connect(me: account.me)", "preview.connect(me: account.me)"),
    ("后续覆盖：home 之后被改成别的实例", COULI_APP, "        _home = StateObject(wrappedValue: home)\n",
     "        home = AppHome.placeholder\n        _home = StateObject(wrappedValue: home)\n"),
    ("二次读取：Home 登记两次，后一次覆盖", REGISTRY, "            \"Search\": { AnyView(SearchRouteView(destination: $0)) },\n",
     "            \"Search\": { AnyView(SearchRouteView(destination: $0)) },\n            \"Home\": { AnyView(HomeRouteView(destination: $0)) },\n"),
    ("缺失：Home 没有接路由视图", REGISTRY, "            \"Home\": { AnyView(HomeRouteView(destination: $0)) },\n", ""),
    ("DEBUG 外：HomePreview 登记在 Release 也编译的表里", REGISTRY,
     "            \"Search\": { AnyView(SearchRouteView(destination: $0)) },\n",
     "            \"Search\": { AnyView(SearchRouteView(destination: $0)) },\n            \"HomePreview\": { AnyView(HomePreviewView(destination: $0)) },\n"),
    ("死代码：#if NEVER 包住预览登记", REGISTRY, "        #if DEBUG\n", "        #if NEVER\n"),
    ("恒值：置灰写死", HOME_ROUTE, "grayscale: home.grayscale", "grayscale: false"),
    ("错误接收者：渲染预览的控制器", HOME_ROUTE, "controller: home.controller", "controller: home.previewController"),
    ("缺失：首页出现时不启动", HOME_ROUTE, "\n            .onAppear { home.tabAppeared() }", ""),
    ("错误接收者：出现时启动的是别的对象", HOME_ROUTE, ".onAppear { home.tabAppeared() }", ".onAppear { preview.tabAppeared() }"),
    ("绕过工厂：直接构造 AppHome", COULI_APP, "AppHome.make(network: web.network, routing: web.routing, variant: .current,",
     "AppHome(network: web.network, routing: web.routing, variant: .current,"),
    ("恒值：构建变体写死成 debug", COULI_APP, "variant: .current", "variant: .debug"),
    ("死代码：渲染器在 if false 里", HOME_ROUTE,
     "        HomeSduiScreen(controller: home.controller, grayscale: home.grayscale)\n            .onAppear { home.tabAppeared() }\n",
     "        if false {\n            HomeSduiScreen(controller: home.controller, grayscale: home.grayscale)\n        }\n"),
    ("注释里的假转发", HOME_ROUTE,
     "        HomeSduiScreen(controller: home.controller, grayscale: home.grayscale)\n",
     "        // HomeSduiScreen(controller: home.controller, grayscale: home.grayscale)\n        EmptyView()\n"),
    ("R10 恒值：Release 端口写成 nil（底版写法）", HOME_SUPPORT,
     "        let port: HomeContractPort = variant == .debug ? (debugPort() ?? live) : live\n",
     "        let port = variant == .debug ? debugPort() : nil\n"),
    ("R10 恒值：三元式 Release 一支为 nil", HOME_SUPPORT, "? (debugPort() ?? live) : live", "? live : nil"),
    ("R10 恒值：直接传 port: nil", HOME_SUPPORT, "AppHome(network: network, port: port)", "AppHome(network: network, port: nil)"),
    ("R10 恒值：?? nil 回落", HOME_SUPPORT, "(debugPort() ?? live) : live", "(debugPort() ?? live) : debugPort() ?? nil"),
    ("R10 缺失：没有构造生产端口", HOME_SUPPORT, "        let live = ApiClientHomeContractPort(api: network.client)\n",
     "        let live = debugPort()!\n"),
    ("R10 条件分支：生产端口只在 debug 分支构造", HOME_SUPPORT,
     "        let live = ApiClientHomeContractPort(api: network.client)\n",
     "        var live: HomeContractPort = debugPort()!\n        if variant == .debug {\n            live = ApiClientHomeContractPort(api: network.client)\n        }\n"),
    ("R10 死代码：生产端口在 if false 里", HOME_SUPPORT,
     "        let live = ApiClientHomeContractPort(api: network.client)\n",
     "        var live: HomeContractPort = debugPort()!\n        if false {\n            live = ApiClientHomeContractPort(api: network.client)\n        }\n"),
    ("R10 注释里的假构造", HOME_SUPPORT,
     "        let live = ApiClientHomeContractPort(api: network.client)\n",
     "        // let live = ApiClientHomeContractPort(api: network.client)\n        let live = debugPort()!\n"),
]


def self_test() -> int:
    failures = 0
    for path, text in GOOD.items():
        errors = check_text(path, text)
        if errors:
            failures += 1
            print(f"合规样例被误拦：{path}：{errors}")
    for name, path, old, new in BAD:
        good = GOOD[path]
        if old not in good:
            failures += 1
            print(f"样例写错（找不到要替换的片段）：{name}")
            continue
        bad = good.replace(old, new, 1)
        if name.startswith("错误位置"):
            bad = bad.replace("        _home = StateObject", "        HomeDataCleaner.register()\n        _home = StateObject", 1)
        if not check_text(path, bad):
            failures += 1
            print(f"漏接样例没有被拦：{name}")
        else:
            print(f"ok（已拦下）：{name}")
    if failures:
        print(f"自测失败 {failures} 项")
        return 1
    print(f"自测通过：{len(BAD)} 个漏接样例全部被拦，合规样例放行")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    sys.exit(check(Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]))
