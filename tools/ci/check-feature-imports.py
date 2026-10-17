#!/usr/bin/env python3
"""Feature 之间不能互相 import（03 §3.1；Features 的 9 个 target 之间没有依赖边）。

    python3 tools/ci/check-feature-imports.py [Features/Sources 目录]   检查；违反退出 1，工具出错退出 2，扫不完整退出 4
    python3 tools/ci/check-feature-imports.py --self-test               用内置样例自测（含工具故障注入、目录树故障注入）

为什么要静态查：App 整体构建里 Xcode 共用产物目录，先构建好的兄弟 Feature 模块对后构建的 target
隐式可见，`import Search` 在 Home 里不一定编译失败。所以 App target 依赖一个每次构建都运行本脚本的
聚合 target FeatureIsolationCheck（project.yml），tools/ci/verify.sh 也调用它并跑自测。

识别方式：不自己做词法分析，导入列表一律由 Swift 编译器自己解析得出：
    xcrun --sdk iphonesimulator swiftc -frontend -emit-imported-modules <该 Feature 的全部源码> -o <列表>
只解析、不需要被导入的模块存在（实测 Xcode 27 / Swift 6.4：对不存在的模块照样列出）。注释、字符串、
正则字面量（含 `#/…/#`）、Unicode 标识符都由编译器处理。每个 Feature 跑两遍：
  A. 原样源码：必须解析成功（退出 0）。编译器也会拒绝条件编译指令行后面跟代码（实测在非活动分支里同样拒绝）。
  B. 去掉所有 `#if/#elseif/#else/#endif` 指令后的副本：编译器只列活动分支里的 import，
     去掉指令让所有分支都参与解析，`#if DEBUG`、`#if canImport(Search)` 里的导入也逃不掉。
     去指令只会让更多代码可见（或解析失败），不会藏起导入；解析失败按违反处理。
     FU-IOS-0712 第 1 轮修复（R1-02）：只展平**词法上确认**的真实指令——按块注释深度（可嵌套）、字符串（单行 / 多行三引号 /
     扩展分隔符 #"…"# 与插值）、扩展正则 #/…/# 逐字符跟踪，某行开头处在顶层代码、行首空白之后就是 #if/#elseif/#else/#endif，
     且该行没有 /*、*/、引号、反斜杠，才把这一行（记号起到行尾）删掉。其余任何位置出现指令记号（块注释 / 行注释 / 字符串 / 正则 /
     插值里、块注释之后的同一行、语句之后）、块注释 / 字符串 / 正则 / 插值到文件末尾没闭合、单行字符串跨行、代码里孤立的 */，
     代码里裸 /（除法或裸正则，不是 // 或 /* 开头）之后同一行还有 " /* */ // # 任一记号，
     一律无法确认边界 → 扫不完整（退出 4），不猜。确认的指令行换成等长空格（不是删掉），保留行数与记号分隔。原来「从任何位置删到行尾」会删掉注释里的 */、改变注释边界（R1-02 样例
     `/* #if note */` …`// */`），已废弃。
扫不完整一律非零退出（退出 4，F-X-07）：Feature 目录或子目录列不出、条目属性查不了（有读无执行权限）、符号链接、
不是 .swift 的源码文件（.DS_Store 除外）、源码读不出或不是 UTF-8。不用吞错的 os.path.isdir / os.walk 判断条目类型。
每次调用都额外放一个只含 `import CouliImportCanary` 的哨兵文件，输出里必须有它，证明编译器真的解析了输入。
编译器找不到、退出非零、没写出列表、列表缺哨兵：一律失败，不放行。只用 Python 3 标准库与 Xcode 自带的 swiftc。
"""

from __future__ import annotations

import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile

CANARY = "CouliImportCanary"
# 条件编译指令记号（后面不能紧跟标识符字符：#iffy、#elseifx 不算）。
DIRECTIVE = re.compile(r"#(?:if|elseif|else|endif)(?![A-Za-z0-9_])")
# 确认的指令行上不允许出现的字符序列（出现就无法确认这一行删掉后注释 / 字符串边界不变）。
DIRECTIVE_LINE_FORBIDDEN = ("/*", "*/", '"', "\\", "#/")
# 代码里裸 /（除法或裸正则 /…/）之后同一行若还有这些记号，无法确认边界（编排追加 B）。
BARE_SLASH_UNSURE = ('"', "/*", "*/", "//", "#")
# 目录树里不扫、也不算扫不完整的文件。
IGNORED_FILES = {".DS_Store"}


class ToolError(Exception):
    """编译器不可用或没有给出可信的结果。"""


class ScanIncomplete(Exception):
    """无法保证扫完整个源码树（F-X-07）：按失败处理，退出 4。"""


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


def flatten_conditionals(src: str, path: str = "<source>") -> str:
    """把词法上确认的条件编译指令行（记号起到行尾）换成等长空格（保留行尾、行数与记号分隔），让所有分支都参与解析。

    无法确认注释 / 字符串边界时抛 ScanIncomplete（退出 4）。见模块说明 R1-02。
    """
    spans = directive_spans(src, path)
    out = []
    last = 0
    for start, end in spans:
        # 以等长空格替代（保留行数、换行、列位置与记号分隔；编排追加 A）
        out.append(src[last:start])
        out.append(" " * (end - start))
        last = end
    out.append(src[last:])
    return "".join(out)


def _unsure(path: str, src: str, pos: int, why: str) -> ScanIncomplete:
    line = src.count("\n", 0, pos) + src.count("\r", 0, pos) - src.count("\r\n", 0, pos) + 1
    return ScanIncomplete(f"无法确认注释 / 字符串边界：{path}:{line}：{why}")


def _line_end(src: str, i: int) -> int:
    n = len(src)
    while i < n and src[i] not in "\r\n":
        i += 1
    return i


def directive_spans(src: str, path: str = "<source>") -> list[tuple[int, int]]:
    """逐字符词法跟踪，返回确认的指令（记号起到行尾，不含行尾）区间。

    栈：("code", 括号深度)——底部是顶层代码，插值里的代码在字符串之上；("block", 深度)；("str", 井号数, 是否多行)；
    ("regex", 井号数)。任何无法确认的情况抛 ScanIncomplete。
    """
    n = len(src)
    stack: list[list] = [["code", 0]]
    spans: list[tuple[int, int]] = []
    i = 0
    line_start = True
    while i < n:
        top = stack[-1]
        ch = src[i]
        # 行尾（CR、LF、CRLF 都算一行）
        if ch in "\r\n":
            if any(f[0] == "str" and not f[2] for f in stack):
                raise _unsure(path, src, i, "单行字符串（或其插值）跨行")
            i += 2 if src.startswith("\r\n", i) else 1
            line_start = True
            continue
        if line_start:
            line_start = False
            if len(stack) == 1:
                j = i
                while j < n and src[j] in " \t":
                    j += 1
                if DIRECTIVE.match(src, j):
                    end = _line_end(src, j)
                    text = src[j:end]
                    for bad in DIRECTIVE_LINE_FORBIDDEN:
                        if bad in text:
                            raise _unsure(path, src, j, f"指令行上带 {bad!r}")
                    spans.append((j, end))
                    i = end
                    continue
        kind = top[0]
        if DIRECTIVE.match(src, i):
            where = {"code": "代码中间（不在行首）" if len(stack) == 1 else "字符串插值里", "block": "块注释里",
                     "str": "字符串里", "regex": "正则字面量里"}[kind]
            raise _unsure(path, src, i, f"指令记号出现在{where}")
        if kind == "code":
            if src.startswith("//", i):
                end = _line_end(src, i)
                if DIRECTIVE.search(src, i, end):
                    raise _unsure(path, src, i, "指令记号出现在行注释里")
                i = end
                continue
            if src.startswith("/*", i):
                stack.append(["block", 1])
                i += 2
                continue
            if src.startswith("*/", i):
                raise _unsure(path, src, i, "代码里孤立的 */")
            if ch == "/":
                # 裸 /（不是 // 或 /* 开头）：除法还是裸正则字面量 /…/ 无法确认。同一行之后还有可能改变字符串 / 注释边界的
                # 记号（" /* */ // #）→ 扫不完整；之后同行没有这些记号的（纯除法、/=）照常（编排追加 B，fail-closed）
                rest = src[i + 1:_line_end(src, i)]
                for token in BARE_SLASH_UNSURE:
                    if token in rest:
                        raise _unsure(path, src, i, f"裸 / 之后同一行还有 {token!r}（无法确认是除法还是正则）")
                i += 1
                continue
            if ch == "#" or ch == '"':
                j = i
                while j < n and src[j] == "#":
                    j += 1
                hashes = j - i
                if j < n and src[j] == '"':
                    multi = src.startswith('"""', j)
                    stack.append(["str", hashes, multi])
                    i = j + (3 if multi else 1)
                    continue
                if hashes and j < n and src[j] == "/":
                    stack.append(["regex", hashes])
                    i = j + 1
                    continue
                i = j if hashes else i + 1
                continue
            if len(stack) > 1:
                if ch == "(":
                    top[1] += 1
                elif ch == ")":
                    if top[1] == 0:
                        stack.pop()
                    else:
                        top[1] -= 1
            i += 1
            continue
        if kind == "block":
            if src.startswith("/*", i):
                top[1] += 1
                i += 2
            elif src.startswith("*/", i):
                top[1] -= 1
                i += 2
                if top[1] == 0:
                    stack.pop()
            else:
                i += 1
            continue
        if kind == "str":
            hashes, multi = top[1], top[2]
            if ch == "\\" and src.startswith("#" * hashes, i + 1):
                k = i + 1 + hashes
                if k < n and src[k] == "(":
                    stack.append(["code", 0])
                    i = k + 1
                elif k < n and src[k] in "\r\n":
                    i = k  # 多行字符串的续行：行尾照常处理
                else:
                    i = k + 1
                continue
            quote = '"""' if multi else '"'
            if src.startswith(quote + "#" * hashes, i):
                stack.pop()
                i += len(quote) + hashes
                continue
            i += 1
            continue
        # regex
        hashes = top[1]
        if ch == "\\":
            i += 2 if i + 1 < n and src[i + 1] not in "\r\n" else 1
            continue
        if src.startswith("/" + "#" * hashes, i):
            stack.pop()
            i += 1 + hashes
            continue
        i += 1
    if len(stack) != 1:
        what = {"block": "块注释", "str": "字符串", "regex": "正则字面量", "code": "字符串插值"}[stack[-1][0]]
        raise _unsure(path, src, n, f"{what}到文件末尾没闭合")
    return spans


def entry_kind(path: str) -> str:
    """显式查条目属性（不跟随符号链接）：dir / file；查不了、符号链接、特殊文件都按扫不完整。"""
    try:
        info = os.lstat(path)
    except OSError as exc:
        raise ScanIncomplete(f"条目属性查不了：{path}（{exc.__class__.__name__}: {exc}）") from exc
    if stat.S_ISLNK(info.st_mode):
        raise ScanIncomplete(f"符号链接不扫：{path}")
    if stat.S_ISDIR(info.st_mode):
        return "dir"
    if stat.S_ISREG(info.st_mode):
        return "file"
    raise ScanIncomplete(f"不是普通文件或目录：{path}")


def list_dir(path: str) -> list[str]:
    try:
        return sorted(os.listdir(path))
    except OSError as exc:
        raise ScanIncomplete(f"目录列不出内容：{path}（{exc.__class__.__name__}: {exc}）") from exc


def swift_files(feature_dir: str) -> list[str]:
    """逐层显式列举 Feature 目录：只认 .swift 普通文件；任何列不出 / 查不了 / 不认识的条目都按扫不完整。"""
    files = []
    pending = [feature_dir]
    while pending:
        current = pending.pop()
        for name in list_dir(current):
            path = os.path.join(current, name)
            kind = entry_kind(path)
            if kind == "dir":
                pending.append(path)
            elif name.endswith(".swift"):
                files.append(path)
            elif name not in IGNORED_FILES:
                raise ScanIncomplete(f"不认识的源码文件（不是 .swift）：{path}")
    return sorted(files)


def read_source(path: str) -> str:
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError as exc:
        raise ScanIncomplete(f"源码读不出：{path}（{exc.__class__.__name__}: {exc}）") from exc
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ScanIncomplete(f"源码不是 UTF-8：{path}") from exc


def feature_imports(feature_dir: str, feature: str, workdir: str) -> list[str]:
    """返回该 Feature 全部源码（原样 + 展平条件编译后）导入的模块。"""
    files = swift_files(feature_dir)
    if not files:
        raise ParseError("没有读到任何 Swift 源码，无法确认隔离")

    original_dir = os.path.join(workdir, "original")
    flat_dir = os.path.join(workdir, "flattened")
    os.makedirs(original_dir)
    os.makedirs(flat_dir)
    flat_files = []
    for k, path in enumerate(files):
        src = read_source(path)
        flat = os.path.join(flat_dir, f"{k:04d}_{os.path.basename(path)}")
        # 原样字节写出（newline=""：CR / CRLF 不被改写，编译器按自己的行尾规则解析）
        with open(flat, "w", encoding="utf-8", newline="") as f:
            f.write(flatten_conditionals(src, path))
        flat_files.append(flat)

    modules = emit_imported_modules(files, feature, original_dir)
    try:
        modules += emit_imported_modules(flat_files, feature, flat_dir)
    except ParseError as exc:
        raise ParseError(f"去掉条件编译指令后无法解析（{exc}）") from exc
    return modules


def check(sources_dir: str) -> list[str]:
    """返回违反列表；编译器不可用时抛 ToolError。"""
    features = []
    for name in list_dir(sources_dir):
        kind = entry_kind(os.path.join(sources_dir, name))
        if kind == "dir":
            features.append(name)
        elif name not in IGNORED_FILES:
            raise ScanIncomplete(f"Features/Sources 下不该有文件：{os.path.join(sources_dir, name)}")
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


# 自测样例：(说明, Home 里的源码, 期望退出码)：0 = 放行，1 = 违反（拦下），4 = 无法确认注释 / 字符串边界（扫不完整）。
SAMPLES = [
    ("普通 import", "import Search\n", 1),
    ("块注释夹在中间", "import /* comment */ Search\n", 1),
    ("嵌套块注释", "import /* a /* b */ c */ Search\n", 1),
    ("@testable", "@testable import Search\n", 1),
    ("属性 @preconcurrency", "@preconcurrency import Search\n", 1),
    ("访问级别", "public import Search\n", 1),
    ("导入种类", "import struct Search.SearchScreen\n", 1),
    ("分号后", "import SwiftUI; import Search\n", 1),
    ("语句后分号", "let value = 1; import Search\n", 1),
    ("跨行", "import\n    Search\n", 1),
    ("反引号", "import `Search`\n", 1),
    ("子模块", "import Search.Internal\n", 1),
    ("行注释后换行", "import // Search?\n  Search\n", 1),
    ("字符串插值后", 'let s = "\\(f("x"))"; import Search\n', 1),
    ("评审 R2-01：正则字面量里有 //", "func probe() { _ = #/https://example.com/# }; import Search\n", 1),
    ("裸斜杠正则后", "let r = /a\\/b/; import Search\n", 1),
    ("Unicode 标识符后", "let 名字 = 1; let café = 名字\nimport Search\n", 1),
    ("#if DEBUG 里", "#if DEBUG\nimport Search\n#endif\n", 1),
    ("#if canImport 里", "#if canImport(Search)\nimport Search\n#endif\n", 1),
    ("非活动分支", "#if os(Android)\nimport SwiftUI\n#elseif NEVER_DEFINED\nimport Search\n#else\nimport Foundation\n#endif\n", 1),
    ("指令行后跟 import（编译器拒绝）", "#if NEVER_DEFINED\n#else import Search\n#endif\n", 1),
    ("无法解析（单行字符串跨行）", 'import SwiftUI\nlet s = "unterminated\n', 4),
    ("同一 Feature", "import Home\n", 0),
    ("Core 模块", "import Router\nimport DesignSystem\n", 0),
    ("不存在的非 Feature 模块", "import NotAFeatureModule\n", 0),
    ("行注释", "// import Search\n", 0),
    ("块注释", "/* import Search */\n", 0),
    ("字符串", 'let s = "import Search"\n', 0),
    ("多行字符串", 'let s = """\nimport Search\n"""\n', 0),
    ("多行字符串里的指令样文字（无法确认，R1-02）", 'let s = """\n#if X\nimport Search\n#endif\n"""\n', 4),
    ("原始字符串", 'let s = #"import "Search""#\n', 0),
    ("成员访问", "let x = foo.import\n", 0),
    ("评审 R2-01：正则 #/import Search/# 不是导入", "let r = #/import Search/#\n", 0),
    ("Unicode 标识符", "let 名字 = 1\nlet café = 名字\nfunc 搜索() {}\n", 0),
    ("条件编译里的合法导入", "#if DEBUG\nimport SwiftUI\n#else\nimport Foundation\n#endif\n", 0),
    # FU-IOS-0712（F-IOS-01 / F-X-07）
    ("F-IOS-01：块注释后的 #if（R1-02：不在行首，无法确认）", "/* c */ #if NEVER_DEFINED\nimport Search\n#endif\n", 4),
    ("块注释后的 #elseif / #else", "#if os(iOS)\nimport SwiftUI\n/* x */ #elseif NEVER\nimport Search\n/**/#else\nimport Search\n#endif\n", 4),
    ("单独 CR 换行的非活动分支", "#if NEVER_DEFINED\rimport Search\r#endif\r", 1),
    ("CRLF 换行的非活动分支", "#if NEVER_DEFINED\r\nimport Search\r\n#endif\r\n", 1),
    ("单独 CR 结束行注释", "// note\rimport Search\r", 1),
    ("未闭合块注释", "import SwiftUI\n/* never closed\n", 4),
    ("单独 CR 换行的合法源码", "import SwiftUI\r#if DEBUG\rimport Foundation\r#endif\r", 0),
    # FU-IOS-0712 第 1 轮修复（R1-02）：只展平词法确认的指令，无法确认边界一律退出 4
    ("R1-02：注释里的记号改变注释边界", "/* #if note */\n#if NEVER_DEFINED\nimport Search\n#endif\n// */\n", 4),
    ("R1-02 边界：行内 /* */ 后接 #if", "import SwiftUI\n/* x */ #if NEVER_DEFINED\nimport Search\n#endif\n", 4),
    ("R1-02 边界：普通字符串里的 #if，后跟真实跨 Feature 导入", 'let s = "#if X"\nimport Search\n', 4),
    ("R1-02 边界：多行字符串里的 #endif", 'let s = """\n#endif\n"""\n#if NEVER_DEFINED\nimport Search\n#endif\n', 4),
    ("行注释里的指令记号", "// #if DEBUG\nimport SwiftUI\n", 4),
    ("语句后的 #if", "let a = 1 #if NEVER_DEFINED\nimport Search\n#endif\n", 4),
    ("插值里的指令记号", 'let s = "\\(a #if)"\n', 4),
    ("指令行带块注释", "#if NEVER_DEFINED /* c */\nimport Search\n#endif\n", 4),
    ("指令行带 */", "/* a\n*/\n#endif */\n", 4),
    ("代码里孤立的 */", "import SwiftUI\nlet a = 1 */\n", 4),
    ("扩展分隔符字符串没闭合", 'let s = #"abc"\n', 4),
    ("多行字符串没闭合", 'let s = """\nabc\n', 4),
    ("扩展正则没闭合", "let r = #/abc\n", 4),
    ("缩进的真实指令", "struct A {\n    #if NEVER_DEFINED\n    func f() {}\n    #endif\n}\nimport Search\n", 1),
    ("缩进的真实指令里的导入", "  #if NEVER_DEFINED\n  import Search\n  #endif\n", 1),
    ("指令行尾的行注释", "#if NEVER_DEFINED // note\nimport Search\n#endif // done\n", 1),
    ("块注释之后另起一行的真实指令", "/* a\n b */\n#if NEVER_DEFINED\nimport Search\n#endif\n", 1),
    ("嵌套块注释闭合后的真实指令", "/* a /* b */ c */\n#if NEVER_DEFINED\nimport Search\n#endif\n", 1),
    ("扩展分隔符字符串里的引号后真实指令", 'let s = #"a " b"#\n#if NEVER_DEFINED\nimport Search\n#endif\n', 1),
    ("多行字符串闭合后的真实指令", 'let s = """\n a "q" \\(x)\n"""\n#if NEVER_DEFINED\nimport Search\n#endif\n', 1),
    ("扩展正则里的引号与 /* 后真实指令", 'let r = #/a"/*b/#\n#if NEVER_DEFINED\nimport Search\n#endif\n', 1),
    ("合法：#iffy 之类不是指令", "let x = #fileID\n", 0),
    # 编排追加 A：注释紧贴 / 制表符分隔的导入必须报违反（活动分支与非活动分支各一遍）
    ("A：import/* x */Search", "import/* x */Search\n", 1),
    ("A：import/**/Search", "import/**/Search\n", 1),
    ("A：@testable/* */import Search", "@testable/* */import Search\n", 1),
    ("A：import 制表符 Search", "import\tSearch\n", 1),
    ("A：import struct/* */Search.Foo", "import struct/* */Search.Foo\n", 1),
    ("A：非活动分支里的 import/**/Search", "#if NEVER_DEFINED\nimport/**/Search\n#endif\n", 1),
    ("A：非活动分支里的 @testable/* */import Search", "#if NEVER_DEFINED\n@testable/* */import Search\n#endif\n", 1),
    ("A：非活动分支里的 import struct/* */Search.Foo", "#if NEVER_DEFINED\nimport struct/* */Search.Foo\n#endif\n", 1),
    ("A：指令行末尾紧跟换行的非活动分支（等长空格）", "#if NEVER_DEFINED\nimport\tSearch\n#else\nimport SwiftUI\n#endif", 1),
    # 编排追加 B：裸 / 之后同行有边界记号 → 4；纯除法照常
    ("B：裸正则 /\"/ 后跟跨 Feature 导入", 'let r = /"/\nimport Search\n', 4),
    ("B：裸 / 之后同行有成对引号", 'let x = a / b; let q = "x"\nimport SwiftUI\n', 4),
    ("B：裸 / 之后同行有 /*", "let x = a / b /* c */\nimport SwiftUI\n", 4),
    ("B：裸 / 之后同行有 //", "let x = a / b // c\nimport SwiftUI\n", 4),
    ("B：裸 / 之后同行有 */", "let r = /a*/\nimport SwiftUI\n", 4),
    ("B：裸 / 之后同行有 #", "let r = /a#/\nimport SwiftUI\n", 4),
    ("B：合法除法", "let a = 4\nlet b = 2\nlet x = a / b\nimport SwiftUI\n", 0),
    ("B：合法 /=", "var a = 4\nfunc f() { a /= 2 }\n", 0),
    ("B：除法之后另起一行的跨 Feature 导入", "let x = 4 / 2\nimport Search\n", 1),
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
        for label, src, expected in SAMPLES:
            with open(probe, "w", encoding="utf-8", newline="") as f:
                f.write(src)
            code = run_check(sources, quiet=True)
            ok = code == expected
            failures += 0 if ok else 1
            verdict = {0: "放行", 1: "拦下", 4: "扫不完整"}.get(code, f"退出 {code}")
            print(f"{'ok  ' if ok else 'FAIL'} {verdict}（应为 {expected}）：{label}：{src.strip()!r}")
            if not ok and code in (1, 2):
                try:
                    print("\n".join(check(sources)))
                except (ScanIncomplete, ToolError) as exc:
                    print(exc)

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
    failures += tree_self_test()
    if failures:
        print(f"check-feature-imports --self-test: {failures} 个样例判断错误", file=sys.stderr)
        return 1
    print(
        f"check-feature-imports --self-test: 通过（{len(SAMPLES)} 个源码样例 + 4 个工具故障注入 + {len(TREE_CASES)} 个目录树故障注入）"
    )
    return 0


# 目录树故障注入（F-X-07，教训 18、20）：(说明, 造树函数)；每个都在「旁边有正常源码」的情况下必须退出 4。
def _tree_unlistable(home: str) -> None:
    locked = os.path.join(home, "Locked")
    os.makedirs(locked)
    with open(os.path.join(locked, "Hidden.swift"), "w", encoding="utf-8") as f:
        f.write("import Search\n")
    os.chmod(locked, 0)


def _tree_unqueryable(home: str) -> None:
    # 有读权限、没有执行权限：能列出名字，条目属性查不了
    locked = os.path.join(home, "NoExec")
    os.makedirs(os.path.join(locked, "Nested"))
    with open(os.path.join(locked, "Hidden.swift"), "w", encoding="utf-8") as f:
        f.write("import Search\n")
    os.chmod(locked, 0o444)


def _tree_unreadable_file(home: str) -> None:
    path = os.path.join(home, "Unreadable.swift")
    with open(path, "w", encoding="utf-8") as f:
        f.write("import Search\n")
    os.chmod(path, 0)


def _tree_not_utf8(home: str) -> None:
    with open(os.path.join(home, "Latin1.swift"), "wb") as f:
        f.write(b"// \xff\xfe\nimport Search\n")


def _tree_unknown_file(home: str) -> None:
    with open(os.path.join(home, "Bridge.m"), "w", encoding="utf-8") as f:
        f.write("@import Search;\n")


def _tree_symlink(home: str) -> None:
    os.symlink("/nonexistent/couli-import-probe", os.path.join(home, "Linked.swift"))


TREE_CASES = [
    ("子目录列不出内容", _tree_unlistable),
    ("条目属性查不了（有读无执行）", _tree_unqueryable),
    ("源码读不出", _tree_unreadable_file),
    ("源码不是 UTF-8", _tree_not_utf8),
    ("不认识的源码文件", _tree_unknown_file),
    ("符号链接", _tree_symlink),
]


def _force_rmtree(root: str) -> None:
    """删掉自测临时树：先把里面的目录、文件都恢复成可读写可进入，再删。"""
    pending = [root]
    while pending:
        current = pending.pop()
        try:
            os.chmod(current, 0o755)
            names = os.listdir(current)
        except OSError:
            continue
        for name in names:
            path = os.path.join(current, name)
            if os.path.islink(path):
                continue
            try:
                os.chmod(path, 0o755)
            except OSError:
                pass
            if os.path.isdir(path):
                pending.append(path)
    shutil.rmtree(root, ignore_errors=True)


def tree_self_test() -> int:
    if os.geteuid() == 0:
        print("FAIL 目录树故障注入不能在 root 下跑（权限位无效）")
        return 1
    failures = 0
    for label, build in TREE_CASES:
        tmp = tempfile.mkdtemp(prefix="couli-feature-tree-")
        try:
            sources = os.path.join(tmp, "Sources")
            home = os.path.join(sources, "Home")
            os.makedirs(home)
            os.makedirs(os.path.join(sources, "Search"))
            with open(os.path.join(sources, "Search", "SearchScreen.swift"), "w", encoding="utf-8") as f:
                f.write("public struct SearchScreen {}\n")
            with open(os.path.join(home, "Ok.swift"), "w", encoding="utf-8") as f:
                f.write("import SwiftUI\n")
            build(home)
            code = run_check(sources, quiet=True)
            ok = code == 4
            failures += 0 if ok else 1
            print(f"{'ok  ' if ok else 'FAIL'} 目录树故障注入（{label}）→ 退出 {code}（应为 4）")
        finally:
            _force_rmtree(tmp)
    return failures


def run_check(sources: str, quiet: bool = False) -> int:
    try:
        problems = check(sources)
    except ScanIncomplete as exc:
        if not quiet:
            print(f"check-feature-imports: error: [scan-incomplete] 无法保证扫完整个源码树，按失败处理：{exc}", file=sys.stderr)
        return 4
    except (ToolError, OSError) as exc:
        if not quiet:
            print(f"check-feature-imports: error: 检查工具出错，按失败处理：{exc}", file=sys.stderr)
        return 2
    if problems:
        if not quiet:
            print("\n".join(problems), file=sys.stderr)
        return 1
    if not quiet:
        count = len(list_dir(sources))
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
