#!/usr/bin/env python3
"""源码树可完整读取（F-X-07 iOS，跨端教训 18、20）：swiftlint / swiftformat 的源码规则扫描前提。

    python3 tools/ci/check-source-tree.py [仓库根]   检查；能完整读取退出 0，扫不完整退出 4，用法错误退出 2
    python3 tools/ci/check-source-tree.py --self-test  目录树故障注入自测

为什么要单独查：SwiftLint 遇到列不出内容的目录会静默跳过（实测：chmod 000 的子目录里的违规不报，退出码只看别的文件），
读不出的文件只打印 "Could not read contents" 而不算失败——源码规则在扫不完整时会放行。这里先把扫描范围逐层显式走一遍，
任何一处没法保证扫到都以 4 退出，verify.sh 在 swiftformat / swiftlint 之前运行它。

扫描范围：App、AppTests、UITests、Packages、tools（跳过构建产物目录 .build / .swiftpm；check-feature-imports 的违反样例
后缀是 .fixture，不是 .swift）。
- 目录或子目录列不出内容、条目属性查不了（有读无执行权限）、符号链接、特殊文件 → 4；不用吞错的 os.walk / isdir 判断条目类型；
- .swift 源码读不出、不是 UTF-8 → 4；
- .swift 源码含 CR（单独 CR 或 CRLF）→ 4：本仓库源码一律 LF，各规则扫描器（含 swiftlint 的正则规则）不对 CR 行尾单独保证口径。
"""

from __future__ import annotations

import os
import shutil
import stat
import sys
import tempfile

ROOTS = ["App", "AppTests", "UITests", "Packages", "tools"]
SKIP_DIR_NAMES = {".build", ".swiftpm"}


class ScanIncomplete(Exception):
    pass


def kind(path: str) -> str:
    try:
        info = os.lstat(path)
    except OSError as exc:
        raise ScanIncomplete(f"条目属性查不了：{path}（{exc.__class__.__name__}: {exc}）") from exc
    if stat.S_ISLNK(info.st_mode):
        raise ScanIncomplete(f"符号链接（扫描器不跟随，无法保证扫到）：{path}")
    if stat.S_ISDIR(info.st_mode):
        return "dir"
    if stat.S_ISREG(info.st_mode):
        return "file"
    raise ScanIncomplete(f"不是普通文件或目录：{path}")


def names(path: str) -> list[str]:
    try:
        return sorted(os.listdir(path))
    except OSError as exc:
        raise ScanIncomplete(f"目录列不出内容：{path}（{exc.__class__.__name__}: {exc}）") from exc


def check_swift(path: str) -> None:
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError as exc:
        raise ScanIncomplete(f"源码读不出：{path}（{exc.__class__.__name__}: {exc}）") from exc
    try:
        raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ScanIncomplete(f"源码不是 UTF-8：{path}") from exc
    if b"\r" in raw:
        raise ScanIncomplete(f"源码含 CR 行尾（本仓库一律 LF）：{path}")


def scan(repo: str) -> int:
    """返回扫过的 .swift 个数；扫不完整抛 ScanIncomplete。"""
    count = 0
    pending = []
    for root in ROOTS:
        path = os.path.join(repo, root)
        if kind(path) != "dir":
            raise ScanIncomplete(f"扫描范围不是目录：{path}")
        pending.append(path)
    while pending:
        current = pending.pop()
        for name in names(current):
            path = os.path.join(current, name)
            entry = kind(path)
            if entry == "dir":
                if name not in SKIP_DIR_NAMES:
                    pending.append(path)
            elif name.endswith(".swift"):
                check_swift(path)
                count += 1
    if count == 0:
        raise ScanIncomplete("扫描范围里一个 .swift 都没有")
    return count


def run(repo: str, quiet: bool = False) -> int:
    try:
        count = scan(repo)
    except ScanIncomplete as exc:
        if not quiet:
            print(f"check-source-tree: error: [scan-incomplete] {exc}", file=sys.stderr)
        return 4
    if not quiet:
        print(f"check-source-tree: {count} 个 .swift 源码都可完整读取（UTF-8、LF）")
    return 0


def _force_rmtree(root: str) -> None:
    pending = [root]
    while pending:
        current = pending.pop()
        try:
            os.chmod(current, 0o755)
            entries = os.listdir(current)
        except OSError:
            continue
        for name in entries:
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


def _write(path: str, data: bytes) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def self_test() -> int:
    if os.geteuid() == 0:
        print("FAIL 不能在 root 下自测（权限位无效）")
        return 1

    def unlistable(repo: str) -> None:
        _write(os.path.join(repo, "Packages", "Core", "Locked", "Hidden.swift"), b"let x = 1\n")
        os.chmod(os.path.join(repo, "Packages", "Core", "Locked"), 0)

    def unqueryable(repo: str) -> None:
        _write(os.path.join(repo, "App", "NoExec", "Hidden.swift"), b"let x = 1\n")
        os.makedirs(os.path.join(repo, "App", "NoExec", "Nested"))
        os.chmod(os.path.join(repo, "App", "NoExec"), 0o444)

    def unreadable(repo: str) -> None:
        path = os.path.join(repo, "AppTests", "Unreadable.swift")
        _write(path, b"let x = 1\n")
        os.chmod(path, 0)

    def not_utf8(repo: str) -> None:
        _write(os.path.join(repo, "UITests", "Latin1.swift"), b"// \xff\n")

    def lone_cr(repo: str) -> None:
        _write(os.path.join(repo, "Packages", "Features", "LoneCr.swift"), b"// note\rlet x = 1\n")

    def crlf(repo: str) -> None:
        _write(os.path.join(repo, "tools", "Crlf.swift"), b"let x = 1\r\n")

    def symlink(repo: str) -> None:
        os.symlink("/nonexistent/couli-tree-probe", os.path.join(repo, "App", "Linked.swift"))

    def missing_root(repo: str) -> None:
        shutil.rmtree(os.path.join(repo, "UITests"))

    cases = [
        ("子目录列不出内容", unlistable, 4),
        ("条目属性查不了（有读无执行）", unqueryable, 4),
        ("源码读不出", unreadable, 4),
        ("源码不是 UTF-8", not_utf8, 4),
        ("单独 CR", lone_cr, 4),
        ("CRLF", crlf, 4),
        ("符号链接", symlink, 4),
        ("扫描范围缺目录", missing_root, 4),
        ("正常树", lambda repo: None, 0),
    ]
    failures = 0
    for label, build, expected in cases:
        tmp = tempfile.mkdtemp(prefix="couli-source-tree-")
        try:
            for root in ROOTS:
                _write(os.path.join(tmp, root, "Ok.swift"), b"let ok = 1\n")
            _write(os.path.join(tmp, "tools", "ci", "feature-import-fixtures", "Cr.swift.fixture"), b"let x = 1\r")
            build(tmp)
            code = run(tmp, quiet=True)
            ok = code == expected
            failures += 0 if ok else 1
            print(f"{'ok  ' if ok else 'FAIL'} {label} → 退出 {code}（应为 {expected}）")
        finally:
            _force_rmtree(tmp)
    if failures:
        print(f"check-source-tree --self-test: {failures} 个用例判断错误", file=sys.stderr)
        return 1
    print(f"check-source-tree --self-test: 通过（{len(cases)} 个目录树用例）")
    return 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["--self-test"]:
        return self_test()
    if len(argv) > 2:
        print(f"用法：{argv[0]} [--self-test | 仓库根]", file=sys.stderr)
        return 2
    repo = argv[1] if len(argv) == 2 else os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    return run(repo)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
