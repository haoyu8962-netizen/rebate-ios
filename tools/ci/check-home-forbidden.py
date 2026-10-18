#!/usr/bin/env python3
"""首页（APP-11）源码禁止项检查（红线 1：不执行服务端下发的任何代码；G27：置灰只作用于首页根视图）。

    python3 tools/ci/check-home-forbidden.py [仓库根]   检查；违反退出 1，目录读不出退出 2
    python3 tools/ci/check-home-forbidden.py --self-test  内置违规样例必须全部被拦，合规样例必须放行

范围：首页与预览的源码——Packages/Core/Sources/HomeCore、Packages/Features/Sources/Home、App/Sources/Home、
App/Sources/Debug 下文件名含 Home 的文件。去掉注释后逐行匹配（字符串字面量单独检查模板语法）。
禁止：
  F1 WebView 渲染：WebKit / WKWebView / SFSafariViewController / UIWebView
  F2 脚本执行：JavaScriptCore / JSContext / JSValue / evaluateJavaScript
  F3 表达式 / 模板求值：NSExpression、NSPredicate(format:)、字符串字面量里的「{{」「${」「<%」模板语法
  F4 按字符串反射调用：NSClassFromString / NSSelectorFromString / Selector(…) / perform(#selector / Selector / NSSelectorFromString…) /
     responds(to: Selector…) / value(forKey:) / value(forKeyPath:) / setValue(_:forKey:) / objc_msgSend / dlsym（强类型 perform(_:) 方法不算，第 3 版评审 T-22）
另：F5 `.grayscale(` 只许出现在 Packages/Features/Sources/Home（置灰只作用于首页根视图，不加到外壳、其他 Tab 或整个 App）。
只用 Python 3 标准库。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

CODE_RULES = [
    ("F1 WebView 渲染", re.compile(r"\bimport\s+WebKit\b|\bWKWebView\b|\bSFSafariViewController\b|\bUIWebView\b")),
    ("F2 脚本执行", re.compile(r"\bJavaScriptCore\b|\bJSContext\b|\bJSValue\b|\bevaluateJavaScript\b")),
    ("F3 表达式求值", re.compile(r"\bNSExpression\b|\bNSPredicate\s*\(\s*format:")),
    ("F4 字符串反射", re.compile(
        # 只认「字符串转 selector / class」与动态派发的形状；强类型的 perform(_:) 之类普通方法名不算
        r"\bNSClassFromString\b|\bNSSelectorFromString\b|\bSelector\s*\(|\bobjc_msgSend\b|\bdlsym\b|"
        r"\.perform\s*\(\s*(#selector|Selector\s*\(|NSSelectorFromString)|\bresponds\s*\(\s*to:\s*(Selector|NSSelectorFromString)|"
        r"\bvalue\s*\(\s*forKey:|\bsetValue\s*\([^)]*forKey:|\bvalue\s*\(\s*forKeyPath:"
    )),
]
TEMPLATE = re.compile(r"\{\{|\$\{|<%")
GRAYSCALE = re.compile(r"\.grayscale\s*\(")


def split(text: str) -> tuple[list[str], list[tuple[int, str]]]:
    """返回（去掉注释与字符串内容后的行，字符串字面量（行号, 内容））。"""
    code, literals = [], []
    i, n, line, block = 0, len(text), 1, 0
    buf = []
    while i < n:
        c = text[i]
        if block:
            if text.startswith("*/", i):
                block -= 1
                i += 2
            elif text.startswith("/*", i):
                block += 1
                i += 2
            else:
                if c == "\n":
                    buf.append("\n")
                    line += 1
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
            literals.append((line, text[i + 1:j]))
            buf.append('""')
            i = j + 1
            continue
        if c == "\n":
            line += 1
        buf.append(c)
        i += 1
    code = "".join(buf).split("\n")
    return code, literals


def check_text(path: str, text: str, grayscale_allowed: bool) -> list[str]:
    errors = []
    code, literals = split(text)
    for number, content in enumerate(code, start=1):
        for name, pattern in CODE_RULES:
            if pattern.search(content):
                errors.append(f"{path}:{number}: {name}：{content.strip()}")
        if not grayscale_allowed and GRAYSCALE.search(content):
            errors.append(f"{path}:{number}: F5 置灰不在首页根视图：{content.strip()}")
    for number, literal in literals:
        if TEMPLATE.search(literal):
            errors.append(f"{path}:{number}: F3 模板语法字面量：\"{literal}\"")
    return errors


def files(root: Path) -> list[tuple[Path, bool]]:
    out = []
    for folder in ["Packages/Core/Sources/HomeCore", "Packages/Features/Sources/Home", "App/Sources/Home"]:
        base = root / folder
        if base.is_dir():
            out += [(p, folder == "Packages/Features/Sources/Home") for p in sorted(base.rglob("*.swift"))]
    debug = root / "App/Sources/Debug"
    if debug.is_dir():
        out += [(p, False) for p in sorted(debug.rglob("*Home*.swift"))]
    return out


def grayscale_elsewhere(root: Path) -> list[str]:
    errors = []
    for p in sorted((root / "App/Sources").rglob("*.swift")):
        code, _ = split(p.read_text(encoding="utf-8"))
        for number, content in enumerate(code, start=1):
            if GRAYSCALE.search(content):
                errors.append(f"{p.relative_to(root)}:{number}: F5 置灰不在首页根视图：{content.strip()}")
    return errors


def check(root: Path) -> int:
    targets = files(root)
    if not targets:
        print("找不到首页源码（HomeCore / Features/Home / App/Sources/Home）")
        return 2
    errors = []
    try:
        for path, allowed in targets:
            errors += check_text(str(path.relative_to(root)), path.read_text(encoding="utf-8"), allowed)
        errors += grayscale_elsewhere(root)
    except OSError as error:
        print(f"读不出源码：{error}")
        return 2
    for error in sorted(set(errors)):
        print(error)
    if errors:
        return 1
    print(f"首页禁止项检查通过（{len(targets)} 个文件）")
    return 0


BAD = [
    ("F1 import WebKit", "import WebKit\nstruct A {}\n"),
    ("F1 WKWebView 渲染卡片", "let view = WKWebView(frame: .zero)\n"),
    ("F2 JSContext 执行脚本", "let context = JSContext()\ncontext?.evaluateScript(js)\n"),
    ("F2 evaluateJavaScript", "web.evaluateJavaScript(card.js)\n"),
    ("F3 NSExpression 求值", "let value = NSExpression(format: condition).expressionValue(with: nil, context: nil)\n"),
    ("F3 NSPredicate 求值", "let ok = NSPredicate(format: rule).evaluate(with: user)\n"),
    ("F3 模板语法", "let url = raw.replacingOccurrences(of: \"{{uid}}\", with: uid)\n"),
    ("F3 ${} 模板", "let url = template.replacingOccurrences(of: \"${phone}\", with: phone)\n"),
    ("F4 NSClassFromString", "let type = NSClassFromString(card.className)\n"),
    ("F4 perform selector", "target.perform(NSSelectorFromString(name))\n"),
    ("F4 Selector 字符串", "_ = target.perform(Selector(card.method))\n"),
    ("F4 #selector 动态派发", "target.perform(#selector(NSObject.description))\n"),
    ("F4 KVC 取值", "let v = object.value(forKey: card.field)\n"),
    ("F4 KVC 赋值", "object.setValue(x, forKey: card.field)\n"),
]
GOOD = (
    "// WebView、JSContext、NSExpression 都不用（注释里提到不算）\n"
    "/* WKWebView */\n"
    "let label = \"{trace6}\"\n"
    "func performRefresh() { refresh() }\n"
    "controller.performRefresh()\n"
    "func perform(_ tap: HomeTap) { open(tap) }\n"
    "runner.perform(tap)\n"
    "perform(tap)\n"
    "let card = values.value\n"
)


def self_test() -> int:
    failures = 0
    for name, text in BAD:
        if not check_text("Sample.swift", text, grayscale_allowed=False):
            failures += 1
            print(f"违规样例没有被拦：{name}")
        else:
            print(f"ok（已拦下）：{name}")
    if not check_text("Sample.swift", ".grayscale(1)\n", grayscale_allowed=False):
        failures += 1
        print("违规样例没有被拦：F5 置灰在首页之外")
    else:
        print("ok（已拦下）：F5 置灰在首页之外")
    if check_text("Sample.swift", ".grayscale(grayscale ? 1 : 0)\n", grayscale_allowed=True):
        failures += 1
        print("首页根视图的置灰被误拦")
    errors = check_text("Sample.swift", GOOD, grayscale_allowed=False)
    if errors:
        failures += 1
        print(f"合规样例被误拦：{errors}")
    if failures:
        print(f"自测失败 {failures} 项")
        return 1
    print(f"自测通过：{len(BAD) + 1} 个违规样例全部被拦，合规样例放行")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    sys.exit(check(Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]))
