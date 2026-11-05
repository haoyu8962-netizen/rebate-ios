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
#   - 非 prod 环境地址：local / test 的 .couli.invalid 域名；staging 真实主机的公共后缀 -stg.couliapp.cn
#     （FU-X-STAGING-HOSTS：api / stream / h5 / l / s-stg 五个主机的 https 与裸主机写法都含它，16 字节超过 Swift 15 字节
#     内联上限，strings 看得到；不列 couliapp.cn 本身，以免拦掉正式主域）。macOS 的 strings 不读 UTF-16，所以这一项
#     另用 python 按 UTF-16LE 字节再查一遍。限制：运行时拼接出来的地址（分段字面量再拼）字节匹配拦不住，靠源码检查
#     （AppTests StagingHostsEnvironmentTests X 组：主机只许写在 App 的 #if DEBUG 里）兜底。
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
#   - 剪贴板调试计数（APP-07）：标记 COULI_DEBUG_CLIPBOARD_APP07_IOS_4e1b9a、启动参数 CouliClipboardDiagnostics
#     （App/Sources/Debug/DebugClipboard.swift）
#   - 剪贴板本机开关重置（FU-X-CLIP-DEFAULT-ON）：启动参数 CouliClipboardSwitchReset（App/Sources/Clipboard/ClipboardSystem.swift 的 #if DEBUG）
#   - 订单本机假服务（APP-08）：标记 COULI_FAKE_ORDERS_SERVER_APP08_IOS_6a2f19、类型名 DebugFakeOrders、启动参数 CouliFakeOrders
#     （App/Sources/Debug/DebugFakeOrders.swift）
#   - 「我的」本机假服务与假推送令牌来源（APP-12）：标记 COULI_FAKE_ME_SERVER_APP12_IOS_2b9e47、类型名 DebugFakeMe、DebugPushTokenSource、
#     启动参数 CouliFakeMe、CouliFakePushToken、假令牌前缀 debug-push-token-（App/Sources/Debug/DebugFakeMe.swift、DebugPushTokenSource.swift）
#   - 第三方登录与绑手机本机假服务、假第三方适配器（APP-05b）：标记 COULI_FAKE_OAUTH_SERVER_APP05B_IOS_4c7e1d、类型名 DebugFakeOAuth、
#     DebugFakeAuthorizer、启动参数 CouliFakeOAuth（App/Sources/Debug/DebugFakeOAuth.swift）
#   - 钱包本机假服务（APP-09）：标记 COULI_FAKE_WALLET_SERVER_APP09_IOS_8d3c52、类型名 DebugFakeWallet、启动参数 CouliFakeWallet
#     （App/Sources/Debug/DebugFakeWallet.swift）
#   - 首页草稿预览 HomePreview 与首页本机假服务（APP-11，03 §3.6，AC-S1-86 ②③）：标记 COULI_HOME_PREVIEW（App/Sources/Debug/HomePreviewView.swift）、
#     COULI_FAKE_HOME_SERVER_APP11_IOS_5e2c7a、类型名 DebugFakeHome（App/Sources/Debug/DebugFakeHome.swift）；路由名 HomePreview 由下面的 routes.json 一项覆盖；
#     首页 UI 测试设施类型名 DebugHomeUITestSupport、启动参数 CouliHomeTestReset 与 CouliFakeFlags、运行中改开关与配置回答信号名（App/Sources/Debug/DebugHomeUITestSupport.swift）
#   - 首页视觉 UI 测试场景与布局测量桥（APP-11v）：标记 COULI_HOME_VISUAL_UITEST_APP11V_IOS_7a3c5e、类型名 DebugHomeVisual、启动参数 CouliHomeVisual、
#     环境变量 COULI_HOME_VISUAL_REQUEST、只读调试元素前缀 home.visual.、信号前缀 debug.uitest.home-visual.（App/Sources/Debug/DebugHomeVisual*.swift）
#   - 本机假服务总入口（APP-05a；原为上一条的孤立续行，APP-06v 补条目头）：
#     （App/Sources/Debug/DebugFakeLoginServer.swift，调试面板引用）、类名 DebugFakeLoginServer、启动参数 CouliFakeLoginServer
#   - 商品详情视觉 UI 测试的卡片注入（APP-06v）：环境变量 COULI_FAKE_PRODUCT_CARDS、类型名 DebugFakeProductCards、DebugFakeProductImages
#     （App/Sources/Debug/DebugFakeProductCards.swift）；只读记录 DebugPurchaseLog / 标识 debug.purchase.log（APP-06v-b）
#   - 订单视觉 UI 测试的数据注入（APP-08v）：环境变量 COULI_FAKE_ORDER_VISUAL、类型名 DebugOrderVisual、只读记录 DebugOrderLog /
#     标识 debug.order.log（App/Sources/Debug/DebugOrderVisual.swift）
#   - 钱包视觉 UI 测试的摘要注入与只读记录（APP-09v-a）：环境变量 COULI_FAKE_WALLET_VISUAL、类型名 DebugWalletVisual、DebugWalletLog、
#     标识 debug.wallet.log（App/Sources/Debug/DebugWalletVisual.swift）
#   - 收款账号 / 实名 / 劳务视觉（APP-09v-e）：只读记录项 backend:realname.submit、backend:labor.current、backend:labor.sign；
#     环境变量里的 payout 键只被 DebugWalletVisual 读，由上一条的类型名覆盖（短键名会被内联，strings 看不到）
#   - 「我的」视觉 UI 测试的报文注入与只读记录（APP-12v）：环境变量 COULI_FAKE_ME_VISUAL、类型名 DebugMeVisual、DebugMeLog、
#     标识 debug.me.log（App/Sources/Debug/DebugMeVisual.swift）
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

STAGING_HOST_SUFFIX="-stg.couliapp.cn"

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
    echo "$STAGING_HOST_SUFFIX"
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
    echo "COULI_DEBUG_CLIPBOARD_APP07_IOS_4e1b9a"
    echo "CouliClipboardDiagnostics"
    echo "CouliClipboardSwitchReset"
    echo "COULI_FAKE_ORDERS_SERVER_APP08_IOS_6a2f19"
    echo "DebugFakeOrders"
    echo "CouliFakeOrders"
    echo "COULI_FAKE_WALLET_SERVER_APP09_IOS_8d3c52"
    echo "DebugFakeWallet"
    echo "CouliFakeWallet"
    echo "COULI_FAKE_ME_SERVER_APP12_IOS_2b9e47"
    echo "DebugFakeMe"
    echo "COULI_FAKE_OAUTH_SERVER_APP05B_IOS_4c7e1d"
    echo "DebugFakeOAuth"
    echo "DebugFakeAuthorizer"
    echo "CouliFakeOAuth"
    echo "CouliFakeMe"
    echo "DebugPushTokenSource"
    echo "CouliFakePushToken"
    echo "debug-push-token-"
    echo "COULI_HOME_PREVIEW"
    echo "COULI_FAKE_HOME_SERVER_APP11_IOS_5e2c7a"
    echo "DebugFakeHome"
    echo "DebugHomeUITestSupport"
    echo "CouliHomeTestReset"
    echo "CouliFakeFlags"
    echo "debug.uitest.fake-flag."
    echo "debug.uitest.config-served"
    echo "COULI_HOME_VISUAL_UITEST_APP11V_IOS_7a3c5e"
    echo "DebugHomeVisual"
    echo "CouliHomeVisual"
    echo "COULI_HOME_VISUAL_REQUEST"
    echo "home.visual."
    echo "debug.uitest.home-visual."
    echo "COULI_FAKE_PRODUCT_CARDS"
    echo "DebugFakeProductCards"
    echo "DebugFakeProductImages"
    echo "DebugPurchaseLog"
    echo "debug.purchase.log"
    echo "COULI_FAKE_ORDER_VISUAL"
    echo "DebugOrderVisual"
    echo "DebugOrderLog"
    echo "debug.order.log"
    echo "COULI_FAKE_WALLET_VISUAL"
    echo "DebugWalletVisual"
    echo "DebugWalletLog"
    echo "debug.wallet.log"
    echo "backend:realname.submit"
    echo "backend:labor.current"
    echo "backend:labor.sign"
    echo "COULI_FAKE_ME_VISUAL"
    echo "DebugMeVisual"
    echo "DebugMeLog"
    echo "debug.me.log"
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

# staging 主机的 UTF-16LE 写法（strings 看不到）：一次读完全部文件，命中的文件逐个记。
python3 -c '
import os, sys
needle = sys.argv[2].encode("utf-16-le")
app = sys.argv[3]
with open(sys.argv[1], "rb") as fh:
    paths = [p for p in fh.read().split(b"\0") if p]
for raw in paths:
    with open(raw, "rb") as f:
        if needle in f.read():
            print(os.path.relpath(os.fsdecode(raw), app))
' "$FILES" "$STAGING_HOST_SUFFIX" "$APP" >"$FOUND" || fail_scan "UTF-16LE 检查失败"
while IFS= read -r rel; do
    echo "  命中：${rel}：${STAGING_HOST_SUFFIX}（UTF-16LE）"
    echo "$STAGING_HOST_SUFFIX" >>"$HITS_LOG"
    HITS=$((HITS + 1))
done <"$FOUND"

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
