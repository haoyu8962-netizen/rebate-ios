#!/usr/bin/env python3
"""Feature 之间不能互相 import（03 §3.1；Features 的 9 个 target 之间没有依赖边）。

    python3 tools/ci/check-feature-imports.py [Features/Sources 目录]   检查；违反退出 1，工具出错退出 2
    python3 tools/ci/check-feature-imports.py --self-test               用内置样例自测（含工具故障注入）

为什么要静态查：App 整体构建里 Xcode 共用产物目录，先构建好的兄弟 Feature 模块对后构建的 target
隐式可见，`import Search` 在 Home 里不一定编译失败。所以 App target 依赖一个每次构建都运行本脚本的
聚合 target FeatureIsolationCheck（project.yml），tools/ci/verify.sh 也调用它并跑自测。

识别方式：不自己做词法分析，导入列表一律由 Swift 编译器自己解析得出：
    xcrun --sdk iphonesimulator swiftc -frontend -emit-imported-modules <该 Feature 的全部源码> -o <列表>
只解析、不需要被导入的模块存在（实测 Xcode 27 / Swift 6.4：对不存在的模块照样列出）。注释、字符串、
正则字面量（含 `#/…/#`）、Unicode 标识符都由编译器处理。每个 Feature 跑两遍：
  A. 原样源码：必须解析成功（退出 0）。编译器也会拒绝条件编译指令行后面跟代码（实测在非活动分支里同样拒绝）。
  B. 去掉所有 `#if/#elseif/#else/#endif` 指令行后的副本：编译器只列活动分支里的 import，
     去掉指令行让所有分支都参与解析，`#if DEBUG`、`#if canImport(Search)` 里的导入也逃不掉。
     去指令行只会让更多代码可见（或解析失败），不会藏起导入；解析失败按违反处理。
每次调用都额外放一个只含 `import CouliImportCanary` 的哨兵文件，输出里必须有它，证明编译器真的解析了输入。
编译器找不到、退出非零、没写出列表、列表缺哨兵：一律失败，不放行。只用 Python 3 标准库与 Xcode 自带的 swiftc。
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile

CANARY = "CouliImportCanary"
DIRECTIVE_LINE = re.compile(r"^[ \t]*#(?:if|elseif|else|endif)\b.*$", re.MULTILINE)


class ToolError(Exception):
    """编译器不可用或没有给出可信的结果。"""


def compiler() -> tuple[str, str]:
    """返回 (swiftc 路径, iphonesimulator SDK 路径)。COULI_SWIFTC 只给自测做故障注入用。"""
    override = os.environ.get("COULI_SWIFTC")
    try:
        swiftc = override or subprocess.run(
            ["xcrun", "--sdk", "iphonesimulator", "--find", "swiftc"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        sdk = subprocess.run(
            ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        raise ToolError(f"找不到 swiftc 或 iphonesimulator SDK：{exc}") from exc
    if not swiftc or not sdk:
        raise ToolError("xcrun 没有给出 swiftc 或 SDK 路径")
    return swiftc, sdk


def emit_imported_modules(files: list[str], module: str, workdir: str) -> list[str]:
    """用编译器解析 files，返回导入的模块名（不含哨兵）。任何异常都抛 ToolError 或 ParseError。"""
    swiftc, sdk = compiler()
    canary = os.path.join(workdir, "__couli_import_canary__.swift")
    with open(canary, "w", encoding="utf-8") as f:
        f.write(f"import {CANARY}\n")
    out = os.path.join(workdir, "imported-modules.txt")
    if os.path.exists(out):
        os.remove(out)
    cmd = [
        swiftc, "-frontend", "-emit-imported-modules", *files, canary,
        "-module-name", module, "-sdk", sdk, "-target", "arm64-apple-ios16.0-simulator",
        "-swift-version", "6", "-o", out,
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True)
    except OSError as exc:
        raise ToolError(f"无法运行 {swiftc}：{exc}") from exc
    if proc.returncode != 0:
        raise ParseError(f"swiftc 退出 {proc.returncode}：{(proc.stderr or proc.stdout).strip()[:2000]}")
    try:
        with open(out, encoding="utf-8") as f:
            modules = [line.strip() for line in f if line.strip()]
    except OSError as exc:
        raise ToolError(f"swiftc 退出 0 但没有写出导入列表：{exc}") from exc
    if CANARY not in modules:
        raise ToolError("swiftc 的导入列表里没有哨兵模块，结果不可信")
    return [m for m in modules if m != CANARY]


class ParseError(Exception):
    """源码解析失败（按违反处理）。"""


def flatten_conditionals(src: str) -> str:
    """去掉条件编译指令行（保留行数），让所有分支都参与解析。"""
    return DIRECTIVE_LINE.sub("", src)


def feature_imports(feature_dir: str, feature: str, workdir: str) -> list[str]:
    """返回该 Feature 全部源码（原样 + 展平条件编译后）导入的模块。"""

    def walk_error(exc: OSError):
        # 读不到目录（如构建脚本沙盒拒绝）一律失败，不能当作「没有文件」放行。
        raise exc

    files = []
    for dirpath, _, names in os.walk(feature_dir, onerror=walk_error):
        files += [os.path.join(dirpath, n) for n in sorted(names) if n.endswith(".swift")]
    if not files:
        raise ParseError("没有读到任何 Swift 源码，无法确认隔离")

    original_dir = os.path.join(workdir, "original")
    flat_dir = os.path.join(workdir, "flattened")
    os.makedirs(original_dir)
    os.makedirs(flat_dir)
    flat_files = []
    for k, path in enumerate(files):
        with open(path, encoding="utf-8") as f:
            src = f.read()
        flat = os.path.join(flat_dir, f"{k:04d}_{os.path.basename(path)}")
        with open(flat, "w", encoding="utf-8") as f:
            f.write(flatten_conditionals(src))
        flat_files.append(flat)

    modules = emit_imported_modules(files, feature, original_dir)
    try:
        modules += emit_imported_modules(flat_files, feature, flat_dir)
    except ParseError as exc:
        raise ParseError(f"去掉条件编译指令后无法解析（{exc}）") from exc
    return modules


def check(sources_dir: str) -> list[str]:
    """返回违反列表；编译器不可用时抛 ToolError。"""
    features = sorted(d for d in os.listdir(sources_dir) if os.path.isdir(os.path.join(sources_dir, d)))
    if not features:
        raise ToolError(f"{sources_dir} 下没有 Feature 目录")
    problems = []
    with tempfile.TemporaryDirectory(prefix="couli-feature-imports-") as tmp:
        for feature in features:
            feature_dir = os.path.join(sources_dir, feature)
            workdir = os.path.join(tmp, feature)
            os.makedirs(workdir)
            try:
                modules = feature_imports(feature_dir, feature, workdir)
            except ParseError as exc:
                problems.append(f"{feature_dir}: error: Feature {feature} 的源码无法确认隔离，按违反处理：{exc}")
                continue
            for module in sorted(set(modules)):
                if module in features and module != feature:
                    problems.append(
                        f"{feature_dir}: error: Feature {feature} 不能 import 另一个 Feature {module}"
                        "（Feature 之间没有依赖边，跨功能只经 Router 路由名，03 §3.1）"
                    )
    return problems


# 自测样例：(说明, Home 里的源码, 是否应当被拦)。
SAMPLES = [
    ("普通 import", "import Search\n", True),
    ("块注释夹在中间", "import /* comment */ Search\n", True),
    ("嵌套块注释", "import /* a /* b */ c */ Search\n", True),
    ("@testable", "@testable import Search\n", True),
    ("属性 @preconcurrency", "@preconcurrency import Search\n", True),
    ("访问级别", "public import Search\n", True),
    ("导入种类", "import struct Search.SearchScreen\n", True),
    ("分号后", "import SwiftUI; import Search\n", True),
    ("语句后分号", "let value = 1; import Search\n", True),
    ("跨行", "import\n    Search\n", True),
    ("反引号", "import `Search`\n", True),
    ("子模块", "import Search.Internal\n", True),
    ("行注释后换行", "import // Search?\n  Search\n", True),
    ("字符串插值后", 'let s = "\\(f("x"))"; import Search\n', True),
    ("评审 R2-01：正则字面量里有 //", "func probe() { _ = #/https://example.com/# }; import Search\n", True),
    ("裸斜杠正则后", "let r = /a\\/b/; import Search\n", True),
    ("Unicode 标识符后", "let 名字 = 1; let café = 名字\nimport Search\n", True),
    ("#if DEBUG 里", "#if DEBUG\nimport Search\n#endif\n", True),
    ("#if canImport 里", "#if canImport(Search)\nimport Search\n#endif\n", True),
    ("非活动分支", "#if os(Android)\nimport SwiftUI\n#elseif NEVER_DEFINED\nimport Search\n#else\nimport Foundation\n#endif\n", True),
    ("指令行后跟 import（编译器拒绝）", "#if NEVER_DEFINED\n#else import Search\n#endif\n", True),
    ("无法解析", 'import SwiftUI\nlet s = "unterminated\n', True),
    ("同一 Feature", "import Home\n", False),
    ("Core 模块", "import Router\nimport DesignSystem\n", False),
    ("不存在的非 Feature 模块", "import NotAFeatureModule\n", False),
    ("行注释", "// import Search\n", False),
    ("块注释", "/* import Search */\n", False),
    ("字符串", 'let s = "import Search"\n', False),
    ("多行字符串", 'let s = """\nimport Search\n"""\n', False),
    ("多行字符串里的指令样文字", 'let s = """\n#if X\nimport Search\n#endif\n"""\n', False),
    ("原始字符串", 'let s = #"import "Search""#\n', False),
    ("成员访问", "let x = foo.import\n", False),
    ("评审 R2-01：正则 #/import Search/# 不是导入", "let r = #/import Search/#\n", False),
    ("Unicode 标识符", "let 名字 = 1\nlet café = 名字\nfunc 搜索() {}\n", False),
    ("条件编译里的合法导入", "#if DEBUG\nimport SwiftUI\n#else\nimport Foundation\n#endif\n", False),
]


def _write_fake_swiftc(directory: str, body: str) -> str:
    path = os.path.join(directory, "fake-swiftc")
    with open(path, "w", encoding="utf-8") as f:
        f.write("#!/bin/sh\n" + body + "\n")
    os.chmod(path, 0o755)
    return path


def self_test() -> int:
    failures = 0
    with tempfile.TemporaryDirectory() as tmp:
        sources = os.path.join(tmp, "Sources")
        for feature in ("Home", "Search"):
            os.makedirs(os.path.join(sources, feature))
        with open(os.path.join(sources, "Search", "SearchScreen.swift"), "w", encoding="utf-8") as f:
            f.write("public struct SearchScreen {}\n")
        probe = os.path.join(sources, "Home", "Probe.swift")
        for label, src, should_flag in SAMPLES:
            with open(probe, "w", encoding="utf-8") as f:
                f.write(src)
            try:
                problems = check(sources)
            except ToolError as exc:
                print(f"FAIL 工具出错：{label}：{exc}")
                failures += 1
                continue
            flagged = bool(problems)
            ok = flagged == should_flag
            failures += 0 if ok else 1
            verdict = "拦下" if flagged else "放行"
            print(f"{'ok  ' if ok else 'FAIL'} {verdict}：{label}：{src.strip()!r}")
            if not ok:
                print("\n".join(problems))

        # 工具故障注入：编译器失败、不写列表、写空列表，都必须让检查失败（不能当作没有导入）。
        with open(probe, "w", encoding="utf-8") as f:
            f.write("import SwiftUI\n")
        fakes = [
            ("swiftc 退出 1", "exit 1"),
            ("swiftc 退出 0 但不写列表", "exit 0"),
            ("swiftc 写空列表", 'while [ $# -gt 0 ]; do [ "$1" = -o ] && : > "$2"; shift; done; exit 0'),
            ("swiftc 不存在", None),
        ]
        saved = os.environ.get("COULI_SWIFTC")
        try:
            for label, body in fakes:
                if body is None:
                    os.environ["COULI_SWIFTC"] = os.path.join(tmp, "no-such-swiftc")
                else:
                    os.environ["COULI_SWIFTC"] = _write_fake_swiftc(tmp, body)
                code = run_check(sources, quiet=True)
                ok = code != 0
                failures += 0 if ok else 1
                print(f"{'ok  ' if ok else 'FAIL'} 工具故障注入（{label}）→ 退出 {code}")
        finally:
            if saved is None:
                os.environ.pop("COULI_SWIFTC", None)
            else:
                os.environ["COULI_SWIFTC"] = saved
    if failures:
        print(f"check-feature-imports --self-test: {failures} 个样例判断错误", file=sys.stderr)
        return 1
    print(f"check-feature-imports --self-test: 通过（{len(SAMPLES)} 个源码样例 + 4 个工具故障注入）")
    return 0


def run_check(sources: str, quiet: bool = False) -> int:
    try:
        problems = check(sources)
    except (ToolError, OSError) as exc:
        if not quiet:
            print(f"check-feature-imports: error: 检查工具出错，按失败处理：{exc}", file=sys.stderr)
        return 2
    if problems:
        if not quiet:
            print("\n".join(problems), file=sys.stderr)
        return 1
    if not quiet:
        count = len([d for d in os.listdir(sources) if os.path.isdir(os.path.join(sources, d))])
        print(f"check-feature-imports: {count} 个 Feature 之间没有互相 import（swiftc -emit-imported-modules）")
    return 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["--self-test"]:
        return self_test()
    if len(argv) > 2:
        print(f"用法：{argv[0]} [--self-test | Features/Sources 目录]", file=sys.stderr)
        return 2
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    sources = argv[1] if len(argv) == 2 else os.path.join(root, "Packages", "Features", "Sources")
    if not os.path.isdir(sources):
        print(f"check-feature-imports: 找不到 {sources}", file=sys.stderr)
        return 2
    if shutil.which("xcrun") is None and not os.environ.get("COULI_SWIFTC"):
        print("check-feature-imports: error: 找不到 xcrun，按失败处理", file=sys.stderr)
        return 2
    return run_check(sources)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
