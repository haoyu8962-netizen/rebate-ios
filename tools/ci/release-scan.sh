#!/bin/bash
# Release 制品扫描（03 §3.6；05 QA-09 的最小前身，完整版在 QA-09）。
#
#   tools/ci/release-scan.sh <Couli.app>
#       扫 Release 包：任一项命中退出 1，未命中退出 0。
#   tools/ci/release-scan.sh --self-test [--expect <检查项>]... <Couli.app>
#       对 Debug / Staging 包运行：必须命中（证明扫描有牙齿），且每个 --expect 的检查项都要命中；
#       满足退出 0，否则退出 1。
#   扫描本身出错（找不到工具、find / strings / grep / codesign / 读路由表失败）一律退出 2，绝不当作「未命中」。
#   grep 一律经 has_match：退出 1 才是「无匹配」，≥ 2 是出错（含代码签名授权检查）。verify.sh 用返回 127 的假 strings、
#   只对授权内容返回 2 的假 grep 做故障注入，证明两处都退出 2。
#
# 用 strings 扫 .app 里的每个文件（二进制与资源），查：
#   - 非 prod 环境地址：local / test / staging 的 .couli.invalid 域名
#   - 调试面板标记 COULI_DEBUG_PANEL（App/Sources/Debug/DebugPanelView.swift）
#   - 组件目录页标记 COULI_DS_COMPONENT_CATALOG_7Q4XK2（App/Sources/Debug/Catalog/ComponentCatalogView.swift，DS-01）
#   - debug_only 路由表标记 COULI_DEBUG_ONLY_ROUTE_TABLE（tools/codegen/gen.py 生成在 debug_only 表所在的
#     #if DEBUG 块里，被表的初始化引用，-O 下保留）
#   - 调试版本检查假数据标记 COULI_UPDATE_CHECK_EXAMPLE_5B7E3D91（App/Sources/Generated/AppVersionCheckExample.swift，
#     APP-02c：契约 openapi 的 check 响应示例只在 Debug / Staging 编译，调试面板引用它）
#   - 快照 routes.json 里 debug_only 为 true 的路由名（长名字直接可见；不超过 15 字节的短名字会被 Swift
#     内联进指令、strings 看不到，所以靠上一条标记兜底，verify.sh 用优化过的 Staging 包证明标记命中）
#   - 调试授权项 get-task-allow（也查代码签名里的授权）
#   - 测试深链 scheme couli-debug（APP-02a：Info.plist 只在 Debug / Staging 声明，App 的深链配置也只在 #if DEBUG 里）
#   - 桥一致性页（APP-04，03 §5.5；APP-04 三端共性第 2 条）：标记 COULI_BRIDGE_CONFORMANCE_APP04_7d41c2
#     （App/Sources/Debug/DebugBridgeConformance.swift）、类名 DebugBridgeConformance、启动参数 CouliBridgeConformance、
#     「假定已登录」的调试归属键 conformance-assumed-login、回环地址 127.0.0.1 / localhost（本机一致性源与 Info.plist 的
#     ATS 例外只在 Debug）、包内 WebView 测试页名 bridge-frames（只在测试 bundle）
#   - 登录本机假服务（APP-05a；APP-04 三端共性第 2 条）：标记 COULI_FAKE_LOGIN_SERVER_APP05A_IOS_3f8e21
#   - 搜索与详情本机假服务（APP-06a）：标记 COULI_FAKE_SEARCH_SERVER_APP06A_IOS_7c2d94、类型名 DebugFakeSearch
#   - 购买本机假服务（APP-06b）：标记 COULI_FAKE_TRADE_SERVER_APP06B_IOS_5d81a7、类型名 DebugFakeTrade
#   - 外跳假端口（APP-06b 共性第 42 条：模拟安装状态 / 模拟外跳结果的开关与执行分支只在调试编译单元）：
#     标记 COULI_DEBUG_JUMP_PORTS_APP06B_IOS_9b3e60、类名 DebugJumpPorts、字段名 debugInstalled / debugNoExternal、
#     启动参数 CouliFakeTradeNoExternal、假安装状态键 CouliFakeInstalled（App/Sources/Debug/DebugJumpPorts.swift）
#     （App/Sources/Debug/DebugFakeLoginServer.swift，调试面板引用）、类名 DebugFakeLoginServer、启动参数 CouliFakeLoginServer
# 兼容 macOS 自带 bash 3.2。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ROUTES="$ROOT/contracts/snapshot/contracts/routes.json"

usage() {
    echo "用法：$0 [--self-test [--expect <检查项>]...] <App.app>" >&2
    exit 2
}

fail_scan() {
    echo "release-scan: 扫描出错：$*" >&2
    exit 2
}

# has_match <说明> <grep 参数…>：命中返回 0，无匹配返回 1；grep 出错（退出 ≥ 2）直接按扫描出错退出 2。
# 本脚本里所有 grep 都经过这里，不能把 grep 出错当成「未命中」。不要放进 $(…) 或管道里调用（那样 exit 只退子 shell）。
has_match() {
    local what="$1" status
    shift
    grep "$@"
    status=$?
    [ "$status" -le 1 ] || fail_scan "grep 检查${what}失败（退出 ${status}）"
    return "$status"
}

SELF_TEST=0
EXPECTS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --self-test) SELF_TEST=1; shift ;;
        --expect)
            [ $# -ge 2 ] || usage
            EXPECTS+=("$2")
            shift 2
            ;;
        --*) usage ;;
        *) break ;;
    esac
done
[ $# -eq 1 ] || usage
[ "${#EXPECTS[@]}" -eq 0 ] || [ "$SELF_TEST" -eq 1 ] || usage
APP="$1"
[ -d "$APP" ] || fail_scan "找不到 $APP"
[ -f "$ROUTES" ] || fail_scan "找不到 $ROUTES"
for tool in strings grep find python3 codesign sort mktemp; do
    command -v "$tool" >/dev/null 2>&1 || fail_scan "找不到工具 $tool"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/release-scan.XXXXXX")" || fail_scan "mktemp 失败"
trap 'rm -rf "$WORK"' EXIT
PATTERNS="$WORK/patterns"
FILES="$WORK/files"
TEXT="$WORK/strings"
FOUND="$WORK/found"
HITS_LOG="$WORK/hits"
: >"$HITS_LOG" || fail_scan "无法写临时文件"

{
    echo "local.couli.invalid"
    echo "test.couli.invalid"
    echo "staging.couli.invalid"
    echo "COULI_DEBUG_PANEL"
    echo "COULI_DS_COMPONENT_CATALOG_7Q4XK2"
    echo "COULI_DEBUG_ONLY_ROUTE_TABLE"
    echo "COULI_UPDATE_CHECK_EXAMPLE_5B7E3D91"
    echo "get-task-allow"
    echo "couli-debug"
    echo "COULI_BRIDGE_CONFORMANCE_APP04_7d41c2"
    echo "DebugBridgeConformance"
    echo "CouliBridgeConformance"
    echo "conformance-assumed-login"
    echo "127.0.0.1"
    echo "localhost"
    echo "bridge-frames"
    echo "COULI_FAKE_LOGIN_SERVER_APP05A_IOS_3f8e21"
    echo "DebugFakeLoginServer"
    echo "CouliFakeLoginServer"
    echo "COULI_FAKE_SEARCH_SERVER_APP06A_IOS_7c2d94"
    echo "DebugFakeSearch"
    echo "COULI_FAKE_TRADE_SERVER_APP06B_IOS_5d81a7"
    echo "DebugFakeTrade"
    echo "COULI_DEBUG_JUMP_PORTS_APP06B_IOS_9b3e60"
    echo "DebugJumpPorts"
    echo "debugInstalled"
    echo "debugNoExternal"
    echo "CouliFakeTradeNoExternal"
    echo "CouliFakeInstalled"
} >"$PATTERNS" || fail_scan "无法写检查项"
python3 -c '
import json, sys
routes = json.load(open(sys.argv[1], encoding="utf-8"))["routes"]
for name in sorted(routes):
    if routes[name].get("debug_only") is True:
        print(name)
' "$ROUTES" >>"$PATTERNS" || fail_scan "读取 debug_only 路由失败（${ROUTES}）"

echo "release-scan: $APP"
echo "release-scan: 检查项：$(tr '\n' ' ' <"$PATTERNS")"

find "$APP" -type f -print0 >"$FILES" || fail_scan "find 枚举文件失败"
[ -s "$FILES" ] || fail_scan "$APP 里没有文件"

HITS=0
SCANNED=0
while IFS= read -r -d '' file; do
    rel="${file#"$APP"/}"
    [ -r "$file" ] || fail_scan "无法读取 $rel"
    strings -a -n 4 "$file" >"$TEXT" || fail_scan "strings 处理 ${rel} 失败（退出 $?）"
    SCANNED=$((SCANNED + 1))
    has_match "文件 ${rel} " -F -o -f "$PATTERNS" "$TEXT" >"$FOUND" || continue # 1：无匹配，正常
    sort -u "$FOUND" >"$FOUND.sorted" || fail_scan "sort 失败"
    while IFS= read -r m; do
        echo "  命中：${rel}：${m}"
        echo "$m" >>"$HITS_LOG"
        HITS=$((HITS + 1))
    done <"$FOUND.sorted"
done <"$FILES"
[ "$SCANNED" -gt 0 ] || fail_scan "一个文件都没扫到"

# 代码签名里的授权。未签名的包（通用设备构建 CODE_SIGNING_ALLOWED=NO）没有授权可查。
if entitlements="$(codesign -d --entitlements - "$APP" 2>&1)"; then
    if has_match "代码签名授权 " -F -q -- "get-task-allow" <<<"$entitlements"; then
        echo "  命中：代码签名授权含 get-task-allow"
        echo "get-task-allow" >>"$HITS_LOG"
        HITS=$((HITS + 1))
    fi
elif ! has_match "codesign 未签名提示 " -F -q -- "not signed at all" <<<"$entitlements"; then
    fail_scan "codesign 读取授权失败：$entitlements"
fi

if [ "$SELF_TEST" -eq 1 ]; then
    missing=0
    for expected in ${EXPECTS[@]+"${EXPECTS[@]}"}; do
        if ! has_match "期望项 ${expected} " -F -x -q -- "$expected" "$HITS_LOG"; then
            echo "release-scan --self-test: 期望命中的检查项没有命中：$expected" >&2
            missing=$((missing + 1))
        fi
    done
    if [ "$HITS" -gt 0 ] && [ "$missing" -eq 0 ]; then
        echo "release-scan --self-test: 通过（命中 ${HITS} 处，扫描有效）"
        exit 0
    fi
    echo "release-scan --self-test: 失败（命中 ${HITS} 处，缺 ${missing} 个期望项，扫描规则失效）" >&2
    exit 1
fi

if [ "$HITS" -gt 0 ]; then
    echo "release-scan: 失败，命中 ${HITS} 处，阻断发布" >&2
    exit 1
fi
echo "release-scan: 通过（未命中，扫描 ${SCANNED} 个文件）"
