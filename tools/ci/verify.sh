#!/bin/bash
# 本机 CI 入口（03 §11）。任一步失败即停止并退出非零，最后打印各步结果。
#
#   tools/ci/verify.sh          全部步骤
#   tools/ci/verify.sh --fast   只跑到生成物检查、xcodegen 与一次 Debug 构建
#
# 所有构建命令都不带额外参数（不带 -xcconfig、不覆盖编译条件），与开发者在命令行或 Xcode 里选配置得到的一样。
#
# 环境变量（可选）：
#   COULI_DERIVED_DATA     DerivedData 路径。默认：worktree 布局下用 ../.dd/<目录名>，否则用 ./DerivedData
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
        --expect COULI_DEBUG_ONLY_ROUTE_TABLE --expect COULI_UPDATE_CHECK_EXAMPLE_5B7E3D91 --expect couli-debug --expect staging.couli.invalid \
        --expect COULI_BRIDGE_CONFORMANCE_APP04_7d41c2 --expect COULI_FAKE_LOGIN_SERVER_APP05A_IOS_3f8e21 "$app" || return 1
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

xcb() {
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -derivedDataPath "$DD" "$@"
}

step "swiftformat --lint" swiftformat --lint .
step "swiftlint --strict" swiftlint lint --strict --no-cache
step "lint 违反样例必须被拦" lint_fixtures
step "Feature 之间无依赖（依赖图 + import 检查自测 + 源码）" feature_isolation
step "gen.py --check" python3 tools/codegen/gen.py --check
step "gen.py 命名冲突探针（test_gen.py）" python3 tools/codegen/test_gen.py
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
    step "test Debug（包测试含格式向量、组件快照与 Router 向量 + App 单测 + UITests 冒烟）" xcb -configuration Debug -destination "$DEST" test
    step "release-scan --self-test Debug 包" tools/ci/release-scan.sh --self-test \
        --expect COULI_DEBUG_PANEL --expect COULI_DS_COMPONENT_CATALOG_7Q4XK2 \
        --expect COULI_DEBUG_ONLY_ROUTE_TABLE --expect COULI_UPDATE_CHECK_EXAMPLE_5B7E3D91 --expect couli-debug --expect test.couli.invalid \
        --expect COULI_BRIDGE_CONFORMANCE_APP04_7d41c2 --expect COULI_FAKE_LOGIN_SERVER_APP05A_IOS_3f8e21 --expect 127.0.0.1 \
        "$PRODUCTS/Debug-iphonesimulator/Couli.app"
    step "Generated 包 Release 一致性测试 + 优化对象标记" generated_release_conformance "$DEST"
fi

summary
echo "verify.sh: 全部通过"
