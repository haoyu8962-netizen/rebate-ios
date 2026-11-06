#!/usr/bin/env python3
"""设计令牌来源检查（DS-02-iOS-1，D10-643「verify 加检查」）。

    python3 tools/ci/check-design-tokens.py [--couli DIR] [仓库根]   检查；违反退出 1，读不出 / 取不到上游退出 2
    python3 tools/ci/check-design-tokens.py --self-test             内置违规样例必须全部被拦，合规样例必须放行

检查项：
  T1 手抄表与旧名：Packages/*/Sources、App/Sources 的 .swift 全文（含注释）里，手抄深色表、旧「设计稿尺寸」枚举、旧 TODO
     三个名字为 0（名字在本文件里拆开拼写，本文件自己不命中 git grep）。
  T2 DesignSystem 源码（Packages/DesignSystem/Sources，去掉注释）没有 "#RRGGBB" / "#RRGGBBAA" 字面色值：颜色只来自生成物。
  T3 生成物 DesignTokens.swift 的 version 等于锁定快照 design-tokens.json 的 metadata.version。
  T4 contract.lock 的 design_tokens.commit 是 couli f088f04（v0.5.1）或其后代（git merge-base --is-ancestor）；
     couli 仓库由 --couli 给出（verify.sh 用 check_lock 同一套 resolve_upstream 取），取不到退出 2。
只用 Python 3 标准库。
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

BANNED = ["Couli" + "DarkTokens", "Couli" + "GuideMetric", "TODO(" + "DS-02-iOS)"]
MIN_DESIGN_LOCK = "f088f0473230d1e70232b8a246b92ef53d723929"
HEX_LITERAL = re.compile(r'"#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?"')
VERSION_LINE = re.compile(r'public static let version: Swift\.String = "([^"]*)"')


def strip_comments(text: str) -> str:
    """去掉 // 与 /* */（可嵌套）注释，保留字符串字面量（含 \"\"\" 多行与转义）与换行。"""
    out: list[str] = []
    i, n, depth = 0, len(text), 0
    while i < n:
        if depth:
            if text.startswith("*/", i):
                depth -= 1
                i += 2
            elif text.startswith("/*", i):
                depth += 1
                i += 2
            else:
                if text[i] == "\n":
                    out.append("\n")
                i += 1
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
        elif text.startswith("/*", i):
            depth = 1
            i += 2
        elif text[i] == '"':
            quote = '"""' if text.startswith('"""', i) else '"'
            out.append(quote)
            i += len(quote)
            while i < n:
                if text[i] == "\\":
                    out.append(text[i:i + 2])
                    i += 2
                elif text.startswith(quote, i):
                    out.append(quote)
                    i += len(quote)
                    break
                elif quote == '"' and text[i] == "\n":
                    break
                else:
                    out.append(text[i])
                    i += 1
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def swift_files(root: Path, tops: list[str]) -> list[Path]:
    files: list[Path] = []
    for top in tops:
        base = root / top
        if not base.is_dir():
            raise OSError(f"找不到目录 {top}")
        files += sorted(p for p in base.rglob("*.swift") if ".build" not in p.parts)
    return files


def source_tops(root: Path) -> list[str]:
    tops = ["App/Sources"]
    packages = root / "Packages"
    if not packages.is_dir():
        raise OSError("找不到目录 Packages")
    tops += [f"Packages/{p.name}/Sources" for p in sorted(packages.iterdir()) if (p / "Sources").is_dir()]
    return tops


def check(root: Path, couli: Path | None) -> list[str]:
    problems: list[str] = []
    # T1
    tops = source_tops(root)
    if not any(t == "Packages/DesignSystem/Sources" for t in tops):
        raise OSError("找不到 Packages/DesignSystem/Sources")
    for path in swift_files(root, tops):
        text = path.read_text(encoding="utf-8")
        for name in BANNED:
            if name in text:
                problems.append(f"T1 {path.relative_to(root)}：仍有 {name}")
    # T2
    for path in swift_files(root, ["Packages/DesignSystem/Sources"]):
        for number, line in enumerate(strip_comments(path.read_text(encoding="utf-8")).splitlines(), 1):
            if HEX_LITERAL.search(line):
                problems.append(f"T2 {path.relative_to(root)}:{number}：手写色值 {HEX_LITERAL.search(line).group(0)}")
    # T3
    generated = root / "Packages/Generated/Sources/Generated/DesignTokens.swift"
    snapshot = root / "contracts/snapshot/design/design-tokens.json"
    match = VERSION_LINE.search(generated.read_text(encoding="utf-8"))
    locked = (json.loads(snapshot.read_text(encoding="utf-8")).get("metadata") or {}).get("version")
    if not match or match.group(1) != locked:
        problems.append(f"T3 DesignTokens.version {match.group(1) if match else '缺失'} ≠ 快照 metadata.version {locked}")
    # T4
    lock = json.loads((root / "contract.lock").read_text(encoding="utf-8"))
    commit = (lock.get("design_tokens") or {}).get("commit", "")
    if couli is None:
        raise OSError("取不到 couli 仓库（--couli），无法核对令牌锁不早于 f088f04")
    result = subprocess.run(["git", "-C", str(couli), "merge-base", "--is-ancestor", MIN_DESIGN_LOCK, commit],
                            capture_output=True, text=True)
    if result.returncode == 1:
        problems.append(f"T4 design_tokens.commit {commit[:12]} 早于 f088f04（v0.5.1）")
    elif result.returncode != 0:
        raise OSError(f"couli 仓库里取不到提交：{result.stderr.strip()}")
    return problems


# ---------- 自测 ----------

GOOD_COLOR = '''import Generated
/// 注释里可以写 "#C44820"
public enum CouliColor {
    public static let brandPrimary = token("brand.primary")
    static let note = "#notacolor"
}
'''


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True, text=True).stdout.strip()


def make_upstream(base: Path) -> tuple[Path, str, str]:
    """临时 couli：旧提交 → 「f088f04」（用 replace 不了真实哈希，改为比较两个本地提交）。"""
    repo = base / "couli"
    repo.mkdir()
    git(repo, "init", "-q")
    for index in (1, 2):
        (repo / "f.txt").write_text(str(index), encoding="utf-8")
        git(repo, "add", "f.txt")
        git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", str(index))
    return repo, git(repo, "rev-parse", "HEAD~1"), git(repo, "rev-parse", "HEAD")


def make_repo(base: Path, files: dict[str, str], commit: str, generated_version: str = "0.5.1") -> Path:
    root = base / "repo"
    if root.exists():
        subprocess.run(["rm", "-rf", str(root)], check=True)
    defaults = {
        "App/Sources/App.swift": "import SwiftUI\n",
        "Packages/DesignSystem/Sources/DesignSystem/TokenColor.swift": GOOD_COLOR,
        "Packages/Features/Sources/Me/Me.swift": "import DesignSystem\n",
        "Packages/Generated/Sources/Generated/DesignTokens.swift":
            f'public enum DesignTokens {{\n    public static let version: Swift.String = "{generated_version}"\n}}\n',
        "contracts/snapshot/design/design-tokens.json": '{"metadata": {"version": "0.5.1"}, "tokens": {}}\n',
        "contract.lock": json.dumps({"design_tokens": {"commit": commit}}),
    }
    defaults.update(files)
    for rel, text in defaults.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return root


# 自测的独立期望名单（评审 r1 S2-4）：与 BANNED 换一种拆法拼写，样例用这份名单造；BANNED 写错一个字时样例不再被拦、自测变红。
EXPECTED_BANNED = ["CouliDark" + "Tokens", "CouliGuide" + "Metric", "TODO(DS-02" + "-iOS)"]


def self_test() -> int:
    global MIN_DESIGN_LOCK
    saved = MIN_DESIGN_LOCK
    failures: list[str] = []
    if BANNED != EXPECTED_BANNED:
        failures.append(f"禁名表与期望名单不一致：{BANNED} ≠ {EXPECTED_BANNED}")
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        couli, older, newer = make_upstream(base)
        MIN_DESIGN_LOCK = newer
        try:
            cases = [
                ("合规", {}, newer, "0.5.1", None),
                ("T1 App/Sources 手抄表名（注释里也算）", {"App/Sources/X.swift": "// " + EXPECTED_BANNED[0] + "\n"}, newer, "0.5.1", "T1"),
                ("T1 Features 旧尺寸枚举", {"Packages/Features/Sources/Me/Y.swift": "let a = " + EXPECTED_BANNED[1] + ".iconSmall\n"},
                 newer, "0.5.1", "T1"),
                ("T1 旧 TODO", {"Packages/DesignSystem/Sources/DesignSystem/Z.swift": "// " + EXPECTED_BANNED[2] + "\n"},
                 newer, "0.5.1", "T1"),
                ("T2 6 位色", {"Packages/DesignSystem/Sources/DesignSystem/C.swift": 'let c = "#A83B1F"\n'},
                 newer, "0.5.1", "T2"),
                ("T2 8 位色", {"Packages/DesignSystem/Sources/DesignSystem/C.swift": 'let c = "#0000008C" /* x */\n'},
                 newer, "0.5.1", "T2"),
                ("T3 版本不一致", {}, newer, "0.3.0", "T3"),
                ("T4 锁早于最低提交", {}, older, "0.5.1", "T4"),
            ]
            for name, files, commit, version, want in cases:
                root = make_repo(base, files, commit, version)
                problems = check(root, couli)
                got = {p.split(" ", 1)[0] for p in problems}
                ok = (not problems) if want is None else (got == {want})
                if not ok:
                    failures.append(f"{name}：期望 {want or '通过'}，实际 {problems}")
            root = make_repo(base, {}, newer)
            try:
                check(root, None)
                failures.append("取不到 couli 时应报错退出")
            except OSError:
                pass
        finally:
            MIN_DESIGN_LOCK = saved
    if strip_comments('let a = "// x" // y\n/* /* n */ */let b = 1\n') != 'let a = "// x" \nlet b = 1\n':
        failures.append("去注释：字符串里的 // 或嵌套块注释处理错")
    for line in failures:
        print(f"自测失败：{line}", file=sys.stderr)
    print("check-design-tokens 自测：" + ("通过" if not failures else f"{len(failures)} 项失败"))
    return 1 if failures else 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["--self-test"]:
        return self_test()
    args = argv[1:]
    couli = None
    if args[:1] == ["--couli"]:
        if len(args) < 2:
            print("用法：check-design-tokens.py [--couli DIR] [仓库根] | --self-test", file=sys.stderr)
            return 2
        couli = Path(args[1]) if args[1] else None
        args = args[2:]
    root = Path(args[0]) if args else Path(__file__).resolve().parents[2]
    try:
        problems = check(root, couli)
    except (OSError, ValueError, UnicodeDecodeError) as exc:
        print(f"check-design-tokens：{exc}", file=sys.stderr)
        return 2
    for line in problems:
        print(line)
    print("check-design-tokens：" + ("通过" if not problems else f"{len(problems)} 处违反"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
