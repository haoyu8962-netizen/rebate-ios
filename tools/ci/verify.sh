#!/bin/bash
# 本机 CI 入口（03 §11）。任一步失败即停止并退出非零，最后打印各步结果。
#
#   tools/ci/verify.sh          全部步骤
#   tools/ci/verify.sh --fast   只跑到生成物检查、xcodegen 与一次 Debug 构建
#
# 第 1 步（CT-LOCK-01）：快照与 contract.lock 一致——按锁定提交重建逐字节比较 + lock files 哈希（tools/contracts/sync.sh --check）；
# 取不到 rebate-platform / couli 即失败，不退化成只比哈希（只比哈希用 tools/contracts/sync.sh --check-hashes-only 单独跑）。
#
# 所有构建命令都不带额外参数（不带 -xcconfig、不覆盖编译条件），与开发者在命令行或 Xcode 里选配置得到的一样。
#
# 环境变量（可选）：
#   COULI_DERIVED_DATA     DerivedData 路径。默认：worktree 布局下用 ../.dd/<目录名>，否则用 ./DerivedData
#   REBATE_PLATFORM_DIR / COULI_DIR  上游契约仓库（第 1 步用）。默认按 lock 的相对路径推导，见 check_lock
#   COULI_SIM_DESTINATION  测试用模拟器，如 "platform=iOS Simulator,id=<UDID>"；
#                          默认自动选已有的 iOS 26.x iPhone（优先 iPhone 17），不创建、不抹掉模拟器
# 兼容 macOS 自带 bash 3.2。
set -uo pipefail

# 不在工作区生成 __pycache__ / *.pyc（.gitignore 也已忽略）。
export PYTHONDONTWRITEBYTECODE=1

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

FAST=0
for arg in "$@"; do
    case "$arg" in
        --fast) FAST=1 ;;
        *) echo "用法：$0 [--fast]" >&2; exit 2 ;;
    esac
done

if [ -n "${COULI_DERIVED_DATA:-}" ]; then
    DD="$COULI_DERIVED_DATA"
elif [ -d "$ROOT/../.dd" ]; then
    DD="$(cd "$ROOT/../.dd" && pwd)/$(basename "$ROOT")"
else
    DD="$ROOT/DerivedData"
fi
LOGS="$DD/verify-logs"
mkdir -p "$LOGS"
PRODUCTS="$DD/Build/Products"
PROJECT="Couli.xcodeproj"
SCHEME="Couli"
SIM_BUILD_DEST="generic/platform=iOS Simulator"

RESULTS=()

summary() {
    echo ""
    echo "================ verify.sh 汇总 ================"
    for line in "${RESULTS[@]}"; do
        echo "  $line"
    done
    [ ! -s "${CRASH_RERUN_LIST:-}" ] || sed 's/^/  testmanagerd 崩溃后重跑：/' "$CRASH_RERUN_LIST"
    echo "  日志：$LOGS"
    echo "================================================"
}

# step <名字> <命令...>：运行并记录；失败时打印日志尾部、汇总并退出。
step() {
    local name="$1"
    shift
    local log="$LOGS/$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_').log"
    local start end
    start=$(date +%s)
    echo "==> ${name}"
    if "$@" >"$log" 2>&1; then
        end=$(date +%s)
        RESULTS+=("PASS  ${name}（$((end - start))s）")
    else
        local code=$?
        end=$(date +%s)
        RESULTS+=("FAIL  ${name}（退出 ${code}，$((end - start))s）")
        echo "---- ${name} 失败，日志尾部（${log}）----"
        tail -n 60 "$log"
        summary
        exit 1
    fi
}

# grep_status <grep 参数…>：0 命中，1 无匹配；grep 出错（退出 ≥ 2）时打印并返回 2。
# 本脚本判定用的 grep 都经过它，调用方按 0 / 1 / 其他分别处理，出错一律当失败，不当「无匹配」。
grep_status() {
    local status
    grep "$@"
    status=$?
    if [ "$status" -gt 1 ]; then
        echo "grep 出错（退出 ${status}）：grep $*" >&2
        return 2
    fi
    return "$status"
}

# 违反样例：每个规则目录里的样例必须被该规则拦下；allowed/ 里的样例必须一条自定义规则都不触发。
lint_fixtures() {
    local fixtures="$ROOT/tools/ci/lint-fixtures" rule file out status found=0
    for dir in "$fixtures"/*/; do
        rule="$(basename "$dir")"
        while IFS= read -r -d '' file; do
            found=$((found + 1))
            out="$(swiftlint lint --strict --no-cache --config "$ROOT/.swiftlint.yml" "$file" 2>&1)"
            status=$?
            if [ "$rule" = "allowed" ]; then
                grep_status -qE "\((no_hardcoded_chinese_in_features|sdk_init_only_in_privacy_gate|no_observable_macro|no_debug_condition_in_packages)\)" <<<"$out"
                case $? in
                    1) ;;
                    0)
                        echo "允许样例被误拦：$file"
                        printf '%s\n' "$out"
                        return 1
                        ;;
                    *) return 1 ;;
                esac
                echo "ok（未误拦）：${file#"$ROOT"/}"
            else
                grep_status -qF "(${rule})" <<<"$out"
                case $? in
                    0) ;;
                    1)
                        echo "规则 ${rule} 没有拦下样例：$file"
                        printf '%s\n' "$out"
                        return 1
                        ;;
                    *) return 1 ;;
                esac
                if [ "$status" -eq 0 ]; then
                    echo "规则 ${rule} 报了违反但 swiftlint 退出 0：$file"
                    return 1
                fi
                echo "ok（已拦下 ${rule}）：${file#"$ROOT"/}"
            fi
        done < <(find "$dir" -name '*.swift' -print0)
    done
    [ "$found" -gt 0 ] || { echo "没有找到违反样例"; return 1; }
}

# Feature 之间没有依赖边：
# 1. 依赖图：Packages/Features/Package.swift 里每个 Feature target 只依赖其他包的 product，
#    不依赖同包的其他 target（单独构建某个 Feature 时 import 另一个会报 Unable to resolve module）。
# 2. 源码：tools/ci/check-feature-imports.py（先跑内置样例自测，再查真实源码）。同一个脚本也由
#    App 依赖的聚合 target FeatureIsolationCheck 在每次构建时执行（project.yml）；后面还有一步构建级负向验收。
feature_isolation() {
    (cd "$ROOT/Packages/Features" && swift package dump-package) | python3 -c '
import json, sys
manifest = json.load(sys.stdin)
names = {t["name"] for t in manifest["targets"] if t.get("type") != "test"}
bad = []
for target in manifest["targets"]:
    tname = target["name"]
    # 测试 target（如 LoginTests）依赖它所测的那一个 Feature，不是 Feature 之间的边；但测试 target 仍不得依赖第二个 Feature。
    if target.get("type") == "test":
        own = [value[0] for kind, value in (next(iter(d.items())) for d in target["dependencies"])
               if kind in ("byName", "target") and value[0] in names]
        if len(own) > 1:
            bad.append(tname + " -> " + ", ".join(own))
        continue
    for dep in target["dependencies"]:
        kind, value = next(iter(dep.items()))
        if kind in ("byName", "target") and value[0] in names:
            bad.append(tname + " -> " + value[0])
        if kind == "product" and value[1] == manifest["name"]:
            bad.append(tname + " -> " + value[0])
print("依赖图：", ", ".join(sorted(names)), "之间无边" if not bad else "")
if bad:
    print("Feature 之间出现依赖边：" + "; ".join(bad))
    sys.exit(1)
' || return 1
    python3 "$ROOT/tools/ci/check-feature-imports.py" --self-test || return 1
    python3 "$ROOT/tools/ci/check-feature-imports.py" "$ROOT/Packages/Features/Sources"
}

# check-feature-imports 违反样例（FU-IOS-0712，F-IOS-01 / F-X-07；第 1 轮修复 R1-02 加 4 个注释 / 字符串边界样例）：tools/ci/feature-import-fixtures/ 下每个样例还原成临时的
# Features/Sources（`<Feature>__<文件名>.fixture`，另补 Search 模块），退出码必须等于 expect；单独 CR 样例先核对 CR 字节确实在。
# 再现造两种 git 存不了的目录树故障（子目录 chmod 000、chmod 444），必须退出 4（扫不完整），不能放行也不能只报违反。
feature_import_fixtures() {
    local fixtures="$ROOT/tools/ci/feature-import-fixtures" dir name expect tmp file base feature code found=0
    python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); sys.exit(0 if b"\r" in d and b"\r\n" not in d else 1)' \
        "$fixtures/lone-cr-inactive-branch/Home__Probe.swift.fixture" || { echo "单独 CR 样例里没有单独 CR 字节"; return 1; }
    # 评审 R1-02 原样例必须逐字节原样（注释里的指令记号改变注释边界）
    python3 -c 'import sys; sys.exit(0 if open(sys.argv[1],"rb").read() == b"/* #if note */\n#if NEVER_DEFINED\nimport Search\n#endif\n// */\n" else 1)' \
        "$fixtures/comment-marker-moves-boundary/Home__Probe.swift.fixture" || { echo "R1-02 原样例内容不对"; return 1; }
    for dir in "$fixtures"/*/; do
        name="$(basename "$dir")"
        expect="$(cat "$dir/expect")" || return 1
        tmp="$(mktemp -d "${TMPDIR:-/tmp}/couli-feature-fixture.XXXXXX")" || return 1
        mkdir -p "$tmp/Sources/Search" && printf '%s\n' "public struct SearchScreen {}" >"$tmp/Sources/Search/SearchScreen.swift" || return 1
        for file in "$dir"*.fixture; do
            base="$(basename "$file" .fixture)"
            feature="${base%%__*}"
            mkdir -p "$tmp/Sources/$feature" && cp "$file" "$tmp/Sources/$feature/${base#*__}" || return 1
        done
        python3 "$ROOT/tools/ci/check-feature-imports.py" "$tmp/Sources"
        code=$?
        rm -rf "$tmp"
        if [ "$code" != "$expect" ]; then
            echo "样例 ${name}：退出 ${code}，应为 ${expect}"
            return 1
        fi
        echo "ok：样例 ${name} 退出 ${code}"
        found=$((found + 1))
    done
    [ "$found" -ge 9 ] || { echo "样例不全（${found} 个）"; return 1; }
    for mode in 000 444; do
        tmp="$(mktemp -d "${TMPDIR:-/tmp}/couli-feature-fixture.XXXXXX")" || return 1
        mkdir -p "$tmp/Sources/Search" "$tmp/Sources/Home/Locked/Nested" || return 1
        printf '%s\n' "public struct SearchScreen {}" >"$tmp/Sources/Search/SearchScreen.swift"
        printf '%s\n' "import SwiftUI" >"$tmp/Sources/Home/Ok.swift"
        printf '%s\n' "import Search" >"$tmp/Sources/Home/Locked/Hidden.swift"
        chmod "$mode" "$tmp/Sources/Home/Locked"
        python3 "$ROOT/tools/ci/check-feature-imports.py" "$tmp/Sources"
        code=$?
        chmod 755 "$tmp/Sources/Home/Locked"
        rm -rf "$tmp"
        if [ "$code" != 4 ]; then
            echo "目录 chmod ${mode}：退出 ${code}，应为 4（扫不完整）"
            return 1
        fi
        echo "ok：目录 chmod ${mode} 退出 4"
    done
}

# 构建级负向验收：在 Home 里临时放一个探针文件，内容是评审 R2-01 的漏检写法
# `func …() { _ = #/https://example.com/# }; import /* probe */ Search`（此时 Search 模块已构建好、
# 对 Home 隐式可见），普通 Debug 构建必须失败，且失败来自每次构建都跑的 Feature 隔离检查。
# 探针文件名带 PID 与随机后缀（不会与真实源码重名）；写入前确认不存在，用 noclobber 原子创建，
# 只有本次创建成功后才登记清理，trap 只删这个文件。--fast 与提前退出的路径从不登记，也就不会删任何东西。
FEATURE_PROBE=""
cleanup_probe() {
    if [ -n "$FEATURE_PROBE" ]; then
        rm -f -- "$FEATURE_PROBE"
        FEATURE_PROBE=""
    fi
}
trap cleanup_probe EXIT
feature_import_build_probe() {
    local log="$LOGS/feature-import-probe-build.log" status probe
    probe="$ROOT/Packages/Features/Sources/Home/CouliCIProbe_$$_${RANDOM}${RANDOM}.swift"
    if [ -e "$probe" ]; then
        echo "探针文件 ${probe} 已存在，不覆盖也不删除，停止"
        return 1
    fi
    if ! (set -C && printf '%s\n' "func couliCIProbe() { _ = #/https://example.com/# }; import /* probe */ Search" "" "enum FeatureImportProbe {}" >"$probe"); then
        echo "无法创建探针文件 ${probe}"
        return 1
    fi
    FEATURE_PROBE="$probe"
    echo "探针文件：${probe#"$ROOT"/}"
    xcb -configuration Debug -destination "$SIM_BUILD_DEST" build >"$log" 2>&1
    status=$?
    cleanup_probe
    if [ "$status" -eq 0 ]; then
        echo "Home import Search 的构建居然成功了：Feature 隔离没有接入构建（日志 ${log}）"
        return 1
    fi
    grep_status -qF "Feature Home 不能 import 另一个 Feature Search" "$log"
    case $? in
        0) ;;
        1)
            echo "构建失败了，但不是预构建检查拦下的（日志 ${log}）："
            grep -E "error:" "$log" | head -n 20
            return 1
            ;;
        *) return 1 ;;
    esac
    echo "ok：普通 Debug 构建被预构建检查拦下（退出 ${status}）"
    grep -m 1 "不能 import 另一个 Feature" "$log"
}

# Staging 包带调试能力：调试面板标记、组件目录页标记（DS-01）、debug_only 路由表标记、版本检查假数据标记（APP-02c）、测试深链 scheme（APP-02a）、
# 桥一致性页标记（APP-04；本机回环源只在 Debug，Staging 不带）
# 与 staging 地址都在（Staging 是 -O 优化构建，同时证明长标记在优化后仍能被 strings 看到）。
staging_has_debug_capabilities() {
    local app="$PRODUCTS/Staging-iphonesimulator/Couli.app"
    tools/ci/release-scan.sh --self-test \
        --expect COULI_DEBUG_PANEL --expect COULI_DS_COMPONENT_CATALOG_7Q4XK2 \
        --expect COULI_DEBUG_ONLY_ROUTE_TABLE --expect COULI_UPDATE_CHECK_EXAMPLE_5B7E3D91 --expect couli-debug --expect -stg.couliapp.cn \
        --expect COULI_BRIDGE_CONFORMANCE_APP04_7d41c2 --expect COULI_FAKE_LOGIN_SERVER_APP05A_IOS_3f8e21 --expect COULI_FAKE_OAUTH_SERVER_APP05B_IOS_4c7e1d --expect DebugFakeOAuth --expect COULI_FAKE_SEARCH_SERVER_APP06A_IOS_7c2d94 --expect COULI_FAKE_TRADE_SERVER_APP06B_IOS_5d81a7 --expect COULI_DEBUG_JUMP_PORTS_APP06B_IOS_9b3e60 --expect DebugJumpPorts --expect debugNoExternal --expect debugInstalled --expect CouliFakeTradeNoExternal \
        --expect COULI_HOME_PREVIEW --expect COULI_FAKE_HOME_SERVER_APP11_IOS_5e2c7a --expect DebugFakeHome "$app" || return 1
    [ "$(/usr/libexec/PlistBuddy -c "Print :CouliBuildConfiguration" "$app/Info.plist")" = "Staging" ] || {
        echo "Staging 包的 CouliBuildConfiguration 不是 Staging"
        return 1
    }
    [ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes:0:CFBundleURLSchemes:0" "$app/Info.plist")" = "couli-debug" ] || {
        echo "Staging 包没有声明测试深链 scheme couli-debug"
        return 1
    }
}

# Release 包的 Info.plist 不声明任何 URL scheme（占位 scheme 不进正式包，needs N-05；APP-02a）。
release_has_no_url_types() {
    local plist="$PRODUCTS/Release-iphonesimulator/Couli.app/Info.plist" out status
    [ -f "$plist" ] || { echo "找不到 $plist"; return 1; }
    out="$(/usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes" "$plist" 2>&1)"
    status=$?
    if [ "$status" -eq 0 ]; then
        echo "Release 包声明了 CFBundleURLTypes：$out"
        return 1
    fi
    grep_status -qF "Does Not Exist" <<<"$out"
    case $? in
        0) echo "ok：Release 包没有 CFBundleURLTypes" ;;
        *) echo "读取 Release Info.plist 失败：$out"; return 1 ;;
    esac
}

# Generated 包按 Release 配置（-O、不定义 DEBUG）跑一致性测试，走 ContractConformanceTests 的 #else 分支：
# debug_only 路由不得登记。再看优化后的 Generated.o：不带 DEBUG 时没有 debug_only 表标记；
# 模拟「Release 误带 debug_only 路由」（只给这个包强开 DEBUG）时标记必须出现——证明标记随表进入优化制品。
# 0：对象文件含 debug_only 表标记；1：不含；2：读不了。
object_has_marker() {
    local text="$LOGS/object-strings.txt" status
    [ -f "$1" ] || { echo "找不到 $1"; return 2; }
    strings -a "$1" >"$text" || { echo "strings 读取 $1 失败"; return 2; }
    grep -F COULI_DEBUG_ONLY_ROUTE_TABLE "$text" >/dev/null
    status=$?
    [ "$status" -le 1 ] || return 2
    return "$status"
}

generated_release_conformance() {
    local dd="$DD/generated-release" mutated="$DD/generated-release-mutated" dest="$1"
    (cd "$ROOT/Packages/Generated" &&
        xcodebuild -scheme Generated -configuration Release -destination "$dest" -derivedDataPath "$dd" test) || return 1
    object_has_marker "$dd/Build/Products/Release-iphonesimulator/Generated.o"
    case $? in
        0) echo "Release 的 Generated.o 含 debug_only 表标记"; return 1 ;;
        1) ;;
        *) return 1 ;;
    esac
    (cd "$ROOT/Packages/Generated" &&
        xcodebuild -scheme Generated -configuration Release -destination "$SIM_BUILD_DEST" -derivedDataPath "$mutated" \
            SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG build) || return 1
    object_has_marker "$mutated/Build/Products/Release-iphonesimulator/Generated.o" || {
        echo "强开 DEBUG 的优化 Generated.o 里找不到 debug_only 表标记：扫描兜底失效"
        return 1
    }
    echo "ok：Release 一致性测试通过；优化对象里标记随 debug_only 表出现、随其消失"
}

# release-scan 自身出错必须失败：PATH 里放一个返回 127 的假 strings。
release_scan_tool_failure() {
    local fake="$LOGS/fake-strings-bin" status
    mkdir -p "$fake" || return 1
    printf '%s\n' '#!/bin/sh' 'exit 127' >"$fake/strings" && chmod +x "$fake/strings" || return 1
    PATH="$fake:$PATH" tools/ci/release-scan.sh "$PRODUCTS/Release-iphonesimulator/Couli.app"
    status=$?
    if [ "$status" -eq 0 ]; then
        echo "strings 不可用时 release-scan 仍返回 0"
        return 1
    fi
    echo "ok：strings 不可用时 release-scan 退出 ${status}"
    [ "$status" -eq 2 ]
}

# release-scan 的 grep 出错必须失败：PATH 里放一个假 grep，只在检查代码签名授权（参数含 get-task-allow 或
# not signed at all）时返回 2，其他调用转给真 grep。文件扫描正常走完、没有命中，最后授权检查出错 → 必须退出 2。
release_scan_grep_failure() {
    local fake="$LOGS/fake-grep-bin" log="$LOGS/release-scan-fake-grep.log" real status
    real="$(command -v grep)" || return 1
    mkdir -p "$fake" || return 1
    {
        echo '#!/bin/bash'
        echo 'for a in "$@"; do'
        echo '    case "$a" in get-task-allow | "not signed at all") echo "fake grep: 注入故障" >&2; exit 2 ;; esac'
        echo 'done'
        printf 'exec "%s" "$@"\n' "$real"
    } >"$fake/grep" && chmod +x "$fake/grep" || return 1
    PATH="$fake:$PATH" tools/ci/release-scan.sh "$PRODUCTS/Release-iphonesimulator/Couli.app" >"$log" 2>&1
    status=$?
    cat "$log"
    if [ "$status" -ne 2 ]; then
        echo "授权检查的 grep 出错时 release-scan 退出 ${status}，应为 2"
        return 1
    fi
    grep_status -qF "fake grep: 注入故障" "$log" || { echo "假 grep 没有被调用到授权检查"; return 1; }
    grep_status -qF "代码签名授权" "$log" || grep_status -qF "codesign 未签名提示" "$log" || {
        echo "退出 2 但不是授权检查报的错"
        return 1
    }
    echo "ok：授权检查 grep 出错时 release-scan 退出 2"
}

pick_simulator() {
    if [ -n "${COULI_SIM_DESTINATION:-}" ]; then
        printf '%s\n' "$COULI_SIM_DESTINATION"
        return 0
    fi
    xcrun simctl list devices available -j | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
best = None
for runtime, items in devices.items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m or m.group(1) != "26":
        continue
    version = (int(m.group(1)), int(m.group(2)))
    for d in items:
        if not d.get("isAvailable", True) or not d["name"].startswith("iPhone"):
            continue
        key = (d["name"] == "iPhone 17", version, d["name"])
        if best is None or key > best[0]:
            best = (key, d["udid"])
if best is None:
    sys.exit("没有可用的 iOS 26.x iPhone 模拟器")
print("platform=iOS Simulator,id=" + best[1])
'
}

# $1 = "platform=iOS Simulator,id=<UDID>"
fix_status_bar() {
    local udid="${1##*id=}"
    xcrun simctl boot "$udid" 2>/dev/null
    xcrun simctl bootstatus "$udid" -b && xcrun simctl status_bar "$udid" override --time '9:41'
}

# $1 = "platform=iOS Simulator,id=<UDID>"
wallet_visual_tests() {
    local udid="${1##*id=}"
    bash tools/testing/wallet-visual-tests.sh "$udid" -project "$PROJECT" -derivedDataPath "$DD" \
        -test-timeouts-enabled YES -default-test-execution-time-allowance 600 \
        -only-testing:WalletCoreTests/WalletVectorTests -only-testing:WalletCoreTests/WalletVisualFixtureTests \
        -only-testing:CouliTests/WalletVisualOracleTests -only-testing:CouliTests/WalletVisualLayoutTests \
        -only-testing:CouliTests/WalletVisualStateTests -only-testing:CouliTests/WalletVisualAdaptTests \
        -only-testing:CouliTests/WalletVisualMoneyTests -only-testing:CouliTests/WalletVisualSnapshotTests \
        -only-testing:CouliUITests/WalletVisualUITests
}

# $1 = "platform=iOS Simulator,id=<UDID>"
# APP-09v-c：提现页视觉 c 组（tools/testing/withdraw-visual-tests.sh 带参数时不走默认清单，这里显式给全 14 个类 + APP-09v-d 二次验证半屏 8 个类；同一 DerivedData，不重复构建）
withdraw_visual_tests() {
    local udid="${1##*id=}"
    bash tools/testing/withdraw-visual-tests.sh "$udid" -project "$PROJECT" -derivedDataPath "$DD" \
        -test-timeouts-enabled YES -default-test-execution-time-allowance 600 \
        -only-testing:WalletCoreTests/WalletVectorTests -only-testing:WalletCoreTests/WithdrawVisualFixtureTests \
        -only-testing:CouliTests/WithdrawVisualFundsGuardTests -only-testing:CouliTests/WithdrawVisualMoneyTests \
        -only-testing:CouliTests/WithdrawVisualOracleTests -only-testing:CouliTests/WithdrawVisualLayoutTests \
        -only-testing:CouliTests/WithdrawVisualPendingTests -only-testing:CouliTests/WithdrawVisualStateTests \
        -only-testing:CouliTests/WithdrawVisualAdaptTests -only-testing:CouliTests/WithdrawVisualPayoutSharedTests \
        -only-testing:CouliTests/WithdrawVisualSnapshotTests -only-testing:CouliTests/WithdrawVisualErrorTests \
        -only-testing:CouliUITests/WithdrawVisualUITests -only-testing:CouliUITests/WithdrawVisualLookUITests \
        -only-testing:CouliUITests/WithdrawVisualAmountUITests \
        -only-testing:CouliTests/StepUpVisualOracleTests -only-testing:CouliTests/StepUpVisualFundsGuardTests \
        -only-testing:CouliTests/StepUpVisualMoneyTests -only-testing:CouliTests/StepUpVisualActionTests \
        -only-testing:CouliTests/StepUpVisualLayoutTests -only-testing:CouliTests/StepUpVisualAdaptTests \
        -only-testing:CouliTests/StepUpVisualSnapshotTests -only-testing:CouliUITests/StepUpVisualUITests
}

# $1 = "platform=iOS Simulator,id=<UDID>"
# APP-12v：「我的」视觉（tools/testing/me-visual-tests.sh 带参数时不走默认清单，这里显式给全 16 项；同一 DerivedData，不重复构建）
me_visual_tests() {
    local udid="${1##*id=}"
    bash tools/testing/me-visual-tests.sh "$udid" -project "$PROJECT" -derivedDataPath "$DD" \
        -test-timeouts-enabled YES -default-test-execution-time-allowance 600 \
        -only-testing:MeCoreTests/MeVectorTests -only-testing:CouliTests/MeVisualFixtureTests \
        -only-testing:CouliTests/MeVisualFundsGuardTests -only-testing:CouliTests/MeVisualOracleTests \
        -only-testing:CouliTests/MeVisualLayoutTests -only-testing:CouliTests/MeVisualPaletteTests \
        -only-testing:CouliTests/MeVisualStateTests -only-testing:CouliTests/MeVisualRestrictedTests \
        -only-testing:CouliTests/MeVisualAdaptTests -only-testing:CouliTests/MeVisualNoticeTests -only-testing:CouliTests/MeVisualBehaviorTests \
        -only-testing:CouliTests/MeVisualMoneyTests -only-testing:CouliTests/MeVisualSnapshotTests \
        -only-testing:CouliTests/MeTabTests -only-testing:CouliUITests/MeVisualUITests \
        -only-testing:CouliUITests/MeVisualMoneyUITests
}

# $1 = "platform=iOS Simulator,id=<UDID>"
# APP-12w-a：设置一族视觉（tools/testing/settings-visual-tests.sh 带参数时不走默认清单，这里显式给全 14 项；同一 DerivedData，不重复构建）
settings_visual_tests() {
    local udid="${1##*id=}"
    bash tools/testing/settings-visual-tests.sh "$udid" -project "$PROJECT" -derivedDataPath "$DD" \
        -test-timeouts-enabled YES -default-test-execution-time-allowance 600 \
        -only-testing:MeCoreTests/MeVectorTests -only-testing:CouliTests/SettingsVisualFixtureTests \
        -only-testing:CouliTests/SettingsVisualGuardTests -only-testing:CouliTests/SettingsVisualOracleTests \
        -only-testing:CouliTests/SettingsVisualLayoutTests -only-testing:CouliTests/SettingsVisualNicknameTests \
        -only-testing:CouliTests/SettingsVisualNotifyTests -only-testing:CouliTests/SettingsVisualPaletteTests \
        -only-testing:CouliTests/SettingsVisualAdaptTests -only-testing:CouliTests/SettingsVisualNoticeTests \
        -only-testing:CouliTests/SettingsVisualBehaviorTests -only-testing:CouliTests/SettingsVisualSnapshotTests \
        -only-testing:CouliTests/MeSettingsTests -only-testing:CouliUITests/SettingsVisualUITests
}

# $1 = "platform=iOS Simulator,id=<UDID>"
# APP-12w-b：隐私中心 / 关于 / 联系客服视觉（tools/testing/privacy-visual-tests.sh 带参数时不走默认清单，这里显式给全 18 项；同一 DerivedData，不重复构建）
privacy_visual_tests() {
    local udid="${1##*id=}"
    bash tools/testing/privacy-visual-tests.sh "$udid" -project "$PROJECT" -derivedDataPath "$DD" \
        -test-timeouts-enabled YES -default-test-execution-time-allowance 600 \
        -only-testing:MeCoreTests/MeVectorTests -only-testing:CouliTests/MeVisualFundsGuardTests \
        -only-testing:CouliTests/SettingsVisualGuardTests -only-testing:CouliTests/MePrivacyTests \
        -only-testing:CouliTests/MeCsAboutTests -only-testing:CouliTests/PrivacyVisualFixtureTests \
        -only-testing:CouliTests/PrivacyVisualGuardTests -only-testing:CouliTests/PrivacyVisualRedLineTests \
        -only-testing:CouliTests/PrivacyVisualLayoutTests -only-testing:CouliTests/PrivacyVisualAboutTests \
        -only-testing:CouliTests/PrivacyVisualCsTests -only-testing:CouliTests/PrivacyVisualNoticeTests \
        -only-testing:CouliTests/PrivacyVisualBehaviorTests -only-testing:CouliTests/PrivacyVisualPaletteTests \
        -only-testing:CouliTests/PrivacyVisualAdaptTests -only-testing:CouliTests/PrivacyVisualFollowupTests \
        -only-testing:CouliTests/PrivacyVisualSnapshotTests -only-testing:CouliUITests/PrivacyVisualUITests
}

# $1 = "platform=iOS Simulator,id=<UDID>"
# APP-09v-e：收款账号 / 实名 / 劳务视觉 e 组（tools/testing/payout-visual-tests.sh 带参数时不走默认清单，这里显式给全；同一 DerivedData，不重复构建）
payout_visual_tests() {
    local udid="${1##*id=}"
    bash tools/testing/payout-visual-tests.sh "$udid" -project "$PROJECT" -derivedDataPath "$DD" \
        -test-timeouts-enabled YES -default-test-execution-time-allowance 600 \
        -only-testing:WalletCoreTests/WalletVectorTests -only-testing:WalletCoreTests/PayoutVisualFixtureTests \
        -only-testing:CouliTests/PayoutVisualOracleTests -only-testing:CouliTests/PayoutVisualFundsGuardTests \
        -only-testing:CouliTests/PayoutVisualMoneyTests -only-testing:CouliTests/PayoutVisualPrivacyTests \
        -only-testing:CouliTests/PayoutVisualConsentCrashTests -only-testing:CouliTests/PayoutVisualLayoutTests \
        -only-testing:CouliTests/PayoutVisualErrorTests -only-testing:CouliTests/IdentityVisualLayoutTests \
        -only-testing:CouliTests/LaborVisualLayoutTests -only-testing:CouliTests/PayoutVisualAdaptTests \
        -only-testing:CouliTests/PayoutVisualSnapshotTests -only-testing:CouliTests/PayoutAccountTests \
        -only-testing:CouliTests/WithdrawVisualPayoutSharedTests -only-testing:CouliTests/WithdrawVisualFundsGuardTests \
        -only-testing:CouliUITests/PayoutVisualUITests -only-testing:CouliUITests/PayoutVisualInputUITests
}

# $1 = "platform=iOS Simulator,id=<UDID>"
# APP-09v-b：提现记录视觉 b 组（tools/testing/records-visual-tests.sh 默认清单 10 个类，这里显式给全；同一 DerivedData，不重复构建）
records_visual_tests() {
    local udid="${1##*id=}"
    bash tools/testing/records-visual-tests.sh "$udid" -project "$PROJECT" -derivedDataPath "$DD" \
        -test-timeouts-enabled YES -default-test-execution-time-allowance 600 \
        -only-testing:WalletCoreTests/WalletVectorTests -only-testing:WalletCoreTests/RecordsVisualFixtureTests \
        -only-testing:CouliTests/WithdrawRecordsTests -only-testing:CouliTests/RecordsVisualLayoutTests \
        -only-testing:CouliTests/RecordsVisualStateTests -only-testing:CouliTests/RecordsVisualPagingTests \
        -only-testing:CouliTests/RecordsVisualAdaptTests -only-testing:CouliTests/RecordsVisualMoneyTests \
        -only-testing:CouliTests/RecordsVisualSnapshotTests -only-testing:CouliUITests/RecordsVisualUITests
}

xcb() {
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -derivedDataPath "$DD" "$@"
}

# 视觉组第二遍是否要跑：VERIFY_ALL_VISUAL=1、算不出改动范围或没有改动（主干上）时全跑，否则看改动是否碰钱包相关路径
readonly VISUAL_GROUP_PATHS='^(Packages/Features/Sources/Wallet/|Packages/Core/Sources/WalletCore/|Packages/DesignSystem/|App/Sources/Wallet/|App/Sources/Debug/(DebugWallet|DebugFakeWallet)|AppTests/(Wallet|Records|Withdraw|StepUp|Payout|Identity)|UITests/(Wallet|Records|Withdraw|StepUp|Payout|Identity)|specs/wallet-vectors|tools/testing/(wallet|records|withdraw|payout)-visual)'
readonly ME_VISUAL_PATHS='^(Packages/Features/Sources/Me/|Packages/Core/Sources/MeCore/|Packages/DesignSystem/|App/Sources/Me/|App/Sources/Debug/DebugMeVisual|AppTests/(Me|Settings|Privacy)|UITests/(Me|Settings|Privacy)|specs/(me|privacy-visual)-vectors|tools/testing/(me|settings|privacy)-visual)'
changed_paths() {
    local base
    base="$(git merge-base origin/main HEAD 2>/dev/null)" || return 1
    { git diff --name-only "$base" HEAD && git status --porcelain | cut -c4-; } | sort -u
}
visual_groups_needed() {
    local changed pattern="${1:-$VISUAL_GROUP_PATHS}"
    [ "${VERIFY_ALL_VISUAL:-0}" = 1 ] && return 0
    changed="$(changed_paths)" || return 0
    [ -n "$changed" ] || return 0
    printf '%s\n' "$changed" | grep -qE "$pattern"
}

# 列出 test Debug 里失败过的用例（重试后过的也列，合并时看；D10-512）。
# 金额相关用例不吃重试：类名或用例名含下面任一词的，首轮红即算红（approvals #24「不得削弱资金测试」）。
# 名单：Money Amount Fen Rebate FormatVector Funds。同一用例连续两次合并前验都靠重试才过的转缺陷单，不再算偶发。
readonly NO_RETRY_TEST_PATTERN='Money|Amount|Fen|Rebate|FormatVector|Funds'
retried_tests_in() {
    grep -E "^Test [Cc]ase '[^']*' failed" "$1" | sed -E "s/^Test [Cc]ase '([^']*)'.*/\\1/" | sort -u || true
}
report_retried_tests() {
    local log failed money
    log="$LOGS/$(printf '%s' 'test Debug（包测试含格式向量、组件快照与 Router 向量 + App 单测 + UITests 冒烟）' | tr -c 'A-Za-z0-9._-' '_').log"
    [ -f "$log" ] || return 0
    [ ! -s "$CRASH_RERUN_LIST" ] || sed 's/^/    testmanagerd 崩溃后重跑：/' "$CRASH_RERUN_LIST"
    failed="$(retried_tests_in "$log")"
    [ -n "$failed" ] || return 0
    printf '%s\n' "$failed" | sed 's/^/    失败过（含重试后过）：/'
    money="$(printf '%s\n' "$failed" | grep -E "$NO_RETRY_TEST_PATTERN" || true)"
    [ -z "$money" ] && return 0
    printf '%s\n' "$money" | sed 's/^/    金额相关用例首轮红，不吃重试：/'
    return 1
}

# 模拟器 testmanagerd 偶发段错误（Xcode 27.2 + iOS 26.5 运行时，同一崩溃点）：在跑的用例记「Lost connection to testmanagerd」，
# xcodebuild 的失败重试不接这种失败。只有全部失败都是这一种时才重跑这几例（D10-512 的延伸）：重跑不吃失败重试，只再容一次崩溃；
# 金额相关用例不重跑，首轮红即算红；重跑名单留在 verify 主输出。
readonly TEST_DEBUG_RESULT="$LOGS/test-debug.xcresult"
readonly CRASH_RERUN_LIST="$LOGS/crash-rerun.txt"
crashed_tests_in() {
    xcrun xcresulttool get test-results summary --path "$1" --compact | python3 "$ROOT/tools/ci/testmanagerd-crashed-tests.py"
}
test_debug() {
    local code=0 round crashed result="$TEST_DEBUG_RESULT" test
    local -a only
    rm -rf "$TEST_DEBUG_RESULT" "$LOGS"/test-debug-rerun-*.xcresult "$CRASH_RERUN_LIST"
    : >"$CRASH_RERUN_LIST"
    xcb "$@" -resultBundlePath "$result" -retry-tests-on-failure -test-iterations 2 test || code=$?
    for round in 1 2 3; do
        [ "$code" -ne 0 ] || return 0
        [ "$round" -lt 3 ] || break
        crashed="$(crashed_tests_in "$result")" || return "$code"
        [ -n "$crashed" ] || return "$code"
        if printf '%s\n' "$crashed" | grep -E "$NO_RETRY_TEST_PATTERN"; then
            echo "金额相关用例被 testmanagerd 崩溃打断，不重跑"
            return "$code"
        fi
        printf '%s\n' "$crashed" | tee -a "$CRASH_RERUN_LIST"
        only=()
        while IFS= read -r test; do only+=("-only-testing:$test"); done <<<"$crashed"
        result="$LOGS/test-debug-rerun-$round.xcresult"
        code=0
        xcb "$@" -resultBundlePath "$result" test-without-building "${only[@]}" || code=$?
    done
    return "$code"
}

# 视觉组第二遍同样会被 testmanagerd 崩溃打断：入口脚本自己拼 xcodebuild，这里取最新的 xcresult 判，规则与 test_debug 一样。
# $1 = 入口函数 $2 = 模拟器 destination
visual_group() {
    local group="$1" dest="$2" code=0 crashed result test
    local -a only
    "$group" "$dest" || code=$?
    [ "$code" -ne 0 ] || return 0
    result="$(ls -dt "$DD"/Logs/Test/*.xcresult 2>/dev/null | head -1)"
    [ -n "$result" ] || return "$code"
    crashed="$(crashed_tests_in "$result")" || return "$code"
    [ -n "$crashed" ] || return "$code"
    if printf '%s\n' "$crashed" | grep -E "$NO_RETRY_TEST_PATTERN"; then
        echo "金额相关用例被 testmanagerd 崩溃打断，不重跑"
        return "$code"
    fi
    printf '%s\n' "$crashed" | tee -a "$CRASH_RERUN_LIST"
    only=()
    while IFS= read -r test; do only+=("-only-testing:$test"); done <<<"$crashed"
    xcb -configuration Debug -destination "$dest" -test-timeouts-enabled YES -default-test-execution-time-allowance 600 \
        test-without-building "${only[@]}"
}

# CT-LOCK-01：contract.lock 与快照一致——必须按锁定提交重建、逐字节比较，并核对 lock files 哈希（tools/contracts/sync.sh --check）。
# 取不到上游仓库或其中没有锁定提交就失败，不退化成只比哈希（与鸿蒙 / Android CT-LOCK-01 同口径）。上游仓库按顺序推导：
#   1. 环境变量 REBATE_PLATFORM_DIR / COULI_DIR（设了就只用它，不对则失败）；
#   2. lock 里的相对路径，相对本仓库根；
#   3. 同一相对路径，相对主检出（git worktree 的公共 .git 所在目录；worktree 下 2 不成立时用它）；
#   4. 本机固定位置 /Users/zhixing/我的项目/rebate-platform、/Users/zhixing/我的项目/couli。
lock_field() {
    python3 -c 'import json,sys
n=json.load(open(sys.argv[1],encoding="utf-8"))
for p in sys.argv[2].split("."): n=n[p]
print(n)' "$ROOT/contract.lock" "$1"
}

is_git_repo() {
    [ -n "$1" ] && [ -d "$1" ] && git -C "$1" rev-parse --git-dir >/dev/null 2>&1
}

# $1 环境变量值 $2 lock 相对路径 $3 本机固定位置；输出仓库绝对路径，取不到输出空串
resolve_upstream() {
    local override="$1" rel="$2" fixed="$3" main_root="" cand=""
    if [ -n "$override" ]; then
        if is_git_repo "$override"; then (cd "$override" && pwd); fi
        return 0
    fi
    main_root="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    main_root="${main_root%/.git}"
    for cand in "$ROOT/$rel" "${main_root:+$main_root/$rel}" "$fixed"; do
        if is_git_repo "$cand"; then
            (cd "$cand" && pwd)
            return 0
        fi
    done
    return 0
}

check_lock() {
    local rp_dir dt_dir
    rp_dir="$(resolve_upstream "${REBATE_PLATFORM_DIR:-}" "$(lock_field rebate_platform.repo)" "/Users/zhixing/我的项目/rebate-platform")"
    dt_dir="$(resolve_upstream "${COULI_DIR:-}" "$(lock_field design_tokens.repo)" "/Users/zhixing/我的项目/couli")"
    if [ -z "$rp_dir" ] || [ -z "$dt_dir" ]; then
        echo "取不到上游仓库（rebate-platform：${rp_dir:-未找到}；couli：${dt_dir:-未找到}），无法按锁定提交核对快照。" >&2
        echo "请设置 REBATE_PLATFORM_DIR=/path/to/rebate-platform COULI_DIR=/path/to/couli 后重跑；" >&2
        echo "只想核对 lock files 哈希可单独运行 tools/contracts/sync.sh --check-hashes-only（不算完整一致性检查）。" >&2
        return 1
    fi
    echo "rebate-platform：$rp_dir"
    echo "couli：$dt_dir"
    REBATE_PLATFORM_DIR="$rp_dir" COULI_DIR="$dt_dir" "$ROOT/tools/contracts/sync.sh" --check || return 1
    echo "锁定提交 $(lock_field rebate_platform.commit | cut -c1-12) 重建逐字节相同、files 哈希相同"
}

step "快照与 contract.lock 一致（按锁定提交重建核对）" check_lock

# DS-02-iOS-1（D10-643「verify 加检查」）：手抄表 / 旧名为 0、DesignSystem 无手写色值、生成物版本 = 快照版本、令牌锁不早于 v0.5.1。
# couli 仓库与 check_lock 用同一套 resolve_upstream 取。
check_design_tokens() {
    local dt_dir
    dt_dir="$(resolve_upstream "${COULI_DIR:-}" "$(lock_field design_tokens.repo)" "/Users/zhixing/我的项目/couli")"
    python3 "$ROOT/tools/ci/check-design-tokens.py" --self-test || return 1
    python3 "$ROOT/tools/ci/check-design-tokens.py" --couli "$dt_dir" "$ROOT"
}
step "源码树可完整读取（自测 + 全仓，F-X-07）" bash -c 'python3 tools/ci/check-source-tree.py --self-test && python3 tools/ci/check-source-tree.py'
step "swiftformat --lint" swiftformat --lint .
step "swiftlint --strict" swiftlint lint --strict --no-cache
step "lint 违反样例必须被拦" lint_fixtures
step "Feature 之间无依赖（依赖图 + import 检查自测 + 源码）" feature_isolation
step "check-feature-imports 违反样例必须被拦（含扫不完整退出 4）" feature_import_fixtures
step "身份未知展示接线（FU-IOS-0713：漏接样例自测 + 源码）" bash -c 'python3 tools/ci/check-identity-wiring.py --self-test && python3 tools/ci/check-identity-wiring.py'
step "首页接线（APP-11：漏接样例自测 + 源码）" bash -c 'python3 tools/ci/check-home-wiring.py --self-test && python3 tools/ci/check-home-wiring.py'
step "release-scan 拦 staging 真实主机（FU-X-STAGING-HOSTS：合成包 R1–R6，跳过算失败）" tools/ci/test-release-scan-staging.sh
step "首页禁止项（APP-11：不渲染 WebView、不执行脚本 / 模板 / 反射，置灰只在首页根视图；违规样例自测 + 源码）" bash -c 'python3 tools/ci/check-home-forbidden.py --self-test && python3 tools/ci/check-home-forbidden.py'
step "gen.py --check" python3 tools/codegen/gen.py --check
step "gen.py 命名冲突探针（test_gen.py）" python3 tools/codegen/test_gen.py
step "设计令牌来源（DS-02-iOS-1：违规样例自测 + 源码；令牌锁不早于 f088f04）" check_design_tokens
step "xcodegen generate" xcodegen generate
step "build Debug（模拟器）" xcb -configuration Debug -destination "$SIM_BUILD_DEST" build

if [ "$FAST" -eq 0 ]; then
    step "Feature 互相 import 时普通构建失败（构建级负向验收）" feature_import_build_probe
    step "build Staging（模拟器，不带任何额外参数）" xcb -configuration Staging -destination "$SIM_BUILD_DEST" build
    step "Staging 包带调试面板与 debug_only 路由表" staging_has_debug_capabilities
    step "build Release（模拟器）" xcb -configuration Release -destination "$SIM_BUILD_DEST" build
    step "release-scan Release 包" tools/ci/release-scan.sh "$PRODUCTS/Release-iphonesimulator/Couli.app"
    step "Release 包不声明 URL scheme" release_has_no_url_types
    step "release-scan 工具失败时必须失败（假 strings 返回 127）" release_scan_tool_failure
    step "release-scan 授权检查 grep 出错时必须失败（假 grep 返回 2）" release_scan_grep_failure
    DEST="$(pick_simulator)" || { RESULTS+=("FAIL  选择模拟器"); echo "$DEST"; summary; exit 1; }
    echo "    模拟器：$DEST"
    # FU-IOS-0712（F-IOS-10）：打开用例超时——UITests 每用例上限由测试包自己设（UITestTimeouts，480 秒），其余用例按 600 秒；
    # 卡住的用例在上限内判失败，不再单个跑上千秒
    # APP-09v-a：钱包问号说明半屏基准是整屏截图（含状态栏），全量测试前先把状态栏时间固定为 9:41（覆盖保持到模拟器关机）
    step "testmanagerd 崩溃名单解析自测" python3 "$ROOT/tools/ci/testmanagerd-crashed-tests.py" --selftest
    step "固定模拟器状态栏 9:41" fix_status_bar "$DEST"
    # 全量 2400+ 例单轮约有 1 条无关偶发（负载下的瞬时轻提示、测量丢更新等）：失败用例重试一次，重试仍红才算红；重试过的用例列在下方，不藏偶发
    step "test Debug（包测试含格式向量、组件快照与 Router 向量 + App 单测 + UITests 冒烟）" test_debug -configuration Debug -destination "$DEST" \
        -test-timeouts-enabled YES -default-test-execution-time-allowance 600
    # 不走 step：step 把输出写进日志，这份名单要留在 verify 主输出（D10-512）
    if report_retried_tests; then
        RESULTS+=("PASS  金额相关用例未靠重试过关（D10-512）")
    else
        RESULTS+=("FAIL  金额相关用例未靠重试过关（D10-512）")
        summary
        exit 1
    fi
    # APP-09v-a：钱包视觉 a 组入口（tools/testing/wallet-visual-tests.sh：固定状态栏、同一模拟器、不并行）。入口脚本默认清单漏了
    # WalletVisualStateTests，这里显式给全 9 个类（同一 DerivedData，不重复构建）
    # 四组的类都已在上面的 test Debug 里跑过；这里是不并行的第二遍，只在改动碰钱包相关路径时跑（省约 56 分钟）
    if visual_groups_needed; then
        step "钱包视觉 a 组（tools/testing/wallet-visual-tests.sh）" visual_group wallet_visual_tests "$DEST"
        step "提现记录视觉 b 组（tools/testing/records-visual-tests.sh）" visual_group records_visual_tests "$DEST"
        step "提现页视觉 c 组（tools/testing/withdraw-visual-tests.sh）" visual_group withdraw_visual_tests "$DEST"
        step "收款账号实名劳务视觉 e 组（tools/testing/payout-visual-tests.sh）" visual_group payout_visual_tests "$DEST"
    else
        echo "    视觉 a / b / c / e 组：改动未碰钱包相关路径，已由 test Debug 覆盖，跳过（VERIFY_ALL_VISUAL=1 强制全跑）"
        RESULTS+=("SKIP  视觉 a / b / c / e 组第二遍（已由 test Debug 覆盖）")
    fi
    if visual_groups_needed "$ME_VISUAL_PATHS"; then
        step "「我的」视觉（tools/testing/me-visual-tests.sh）" visual_group me_visual_tests "$DEST"
        step "设置一族视觉（tools/testing/settings-visual-tests.sh）" visual_group settings_visual_tests "$DEST"
        step "隐私中心关于客服视觉（tools/testing/privacy-visual-tests.sh）" visual_group privacy_visual_tests "$DEST"
    else
        echo "    「我的」、设置一族、隐私中心视觉组：改动未碰相关路径，已由 test Debug 覆盖，跳过"
        RESULTS+=("SKIP  「我的」、设置一族、隐私中心视觉第二遍（已由 test Debug 覆盖）")
    fi
    step "release-scan --self-test Debug 包" tools/ci/release-scan.sh --self-test \
        --expect COULI_DEBUG_PANEL --expect COULI_DS_COMPONENT_CATALOG_7Q4XK2 \
        --expect COULI_DEBUG_ONLY_ROUTE_TABLE --expect COULI_UPDATE_CHECK_EXAMPLE_5B7E3D91 --expect couli-debug --expect test.couli.invalid --expect -stg.couliapp.cn \
        --expect COULI_BRIDGE_CONFORMANCE_APP04_7d41c2 --expect COULI_FAKE_LOGIN_SERVER_APP05A_IOS_3f8e21 --expect COULI_FAKE_OAUTH_SERVER_APP05B_IOS_4c7e1d --expect DebugFakeOAuth --expect COULI_FAKE_SEARCH_SERVER_APP06A_IOS_7c2d94 --expect COULI_FAKE_TRADE_SERVER_APP06B_IOS_5d81a7 --expect COULI_DEBUG_JUMP_PORTS_APP06B_IOS_9b3e60 --expect DebugJumpPorts --expect debugNoExternal --expect debugInstalled --expect CouliFakeTradeNoExternal --expect COULI_DEBUG_CLIPBOARD_APP07_IOS_4e1b9a --expect CouliClipboardDiagnostics --expect DebugClipboardEvaluation --expect COULI_FAKE_ORDERS_SERVER_APP08_IOS_6a2f19 --expect COULI_FAKE_WALLET_SERVER_APP09_IOS_8d3c52 --expect DebugFakeWallet --expect 127.0.0.1 \
        --expect COULI_FAKE_ME_SERVER_APP12_IOS_2b9e47 --expect DebugFakeMe --expect DebugPushTokenSource \
        --expect COULI_HOME_PREVIEW --expect COULI_FAKE_HOME_SERVER_APP11_IOS_5e2c7a --expect DebugFakeHome \
        --expect COULI_HOME_VISUAL_UITEST_APP11V_IOS_7a3c5e --expect DebugHomeVisual \
        --expect COULI_FAKE_PRODUCT_CARDS --expect DebugFakeProductImages \
        --expect COULI_FAKE_ORDER_VISUAL --expect DebugOrderLog \
        --expect COULI_FAKE_WALLET_VISUAL --expect DebugWalletVisual --expect DebugWalletLog --expect debug.wallet.log \
        --expect backend:realname.submit --expect backend:labor.current --expect backend:labor.sign \
        "$PRODUCTS/Debug-iphonesimulator/Couli.app"
    step "Generated 包 Release 一致性测试 + 优化对象标记" generated_release_conformance "$DEST"
fi

summary
echo "verify.sh: 全部通过"
