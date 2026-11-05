#!/bin/bash
# FU-X-STAGING-HOSTS-ios R 组：用合成的 .app 证明 release-scan 拦得住 staging 真实主机（照鸿蒙 R1–R5、安卓 R 组）。
#   tools/ci/test-release-scan-staging.sh        全部用例通过退出 0，任一不符退出 1，环境出错退出 2
# 用例：
#   R1 只含五个 staging 主机之一（api / stream / h5 / l / s -stg.couliapp.cn），写成 https、裸主机名、UTF-16LE 任一形式 → 扫描退出 1
#   R2 只含正式主域 couliapp.cn、api.couliapp.cn、l.couliapp.cn、*.prod.couli.invalid → 扫描退出 0（不得把正式主域也拦掉）
#   R3 照 Staging 包实际含的串合成（staging 主机 + couli-debug 等调试标记）：--self-test --expect -stg.couliapp.cn 退出 0
#   R4 同一包去掉 staging 主机：--self-test --expect -stg.couliapp.cn 退出 1（证明 verify.sh 的 Staging 自检真有牙齿）
#   R5 旧占位 staging.couli.invalid 不再是期望项：只含旧占位的合成包 --self-test --expect -stg.couliapp.cn 退出 1
# 只用合成文件，不碰真实构建产物；verify.sh 在 lint 阶段真跑这一步（跳过算失败）。兼容 macOS 自带 bash 3.2。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCAN="$ROOT/tools/ci/release-scan.sh"
[ -x "$SCAN" ] || { echo "找不到可执行的 $SCAN"; exit 2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rs-staging.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
FAILS=0
COUNT=0

# make_app <名字>：建一个最小的未签名 .app（Info.plist + 可执行文件），返回路径
make_app() {
    local app="$WORK/$1.app"
    mkdir -p "$app" || exit 2
    cat >"$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Fake</string><key>CFBundleIdentifier</key><string>com.example.fake</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
    printf 'fake-binary\000' >"$app/Fake" || exit 2
    echo "$app"
}

# put_utf8 <app> <文本>：把文本以 C 字符串形式写进可执行文件（与 Swift 常量串在 __cstring 里的形态相同）
put_utf8() {
    printf '\000%s\000' "$2" >>"$1/Fake" || exit 2
}

# put_utf16 <app> <文本>：UTF-16LE 写进一个资源文件
put_utf16() {
    python3 -c 'import sys; open(sys.argv[1], "ab").write(sys.argv[2].encode("utf-16-le"))' "$1/strings.dat" "$2" || exit 2
}

# expect <期望退出码> <说明> <release-scan 参数…>
expect() {
    local want="$1" label="$2" status
    shift 2
    COUNT=$((COUNT + 1))
    "$SCAN" "$@" >"$WORK/last.log" 2>&1
    status=$?
    if [ "$status" -eq "$want" ]; then
        echo "ok：${label}（退出 ${status}）"
    else
        echo "不符：${label}——期望退出 ${want}，实际 ${status}"
        grep -v "检查项：" "$WORK/last.log" | tail -n 3 | sed "s/^/    /"
        FAILS=$((FAILS + 1))
    fi
}

HOSTS="api-stg.couliapp.cn stream-stg.couliapp.cn h5-stg.couliapp.cn l-stg.couliapp.cn s-stg.couliapp.cn"
n=0
for host in $HOSTS; do
    n=$((n + 1))
    app="$(make_app "r1-https-$n")"
    put_utf8 "$app" "https://$host"
    expect 1 "R1 https://$host" "$app"
    app="$(make_app "r1-bare-$n")"
    put_utf8 "$app" "$host"
    expect 1 "R1 裸主机 $host" "$app"
    app="$(make_app "r1-utf16-$n")"
    put_utf16 "$app" "https://$host"
    expect 1 "R1 UTF-16LE https://$host" "$app"
done

n=0
for host in couliapp.cn https://couliapp.cn https://api.couliapp.cn https://l.couliapp.cn https://api.prod.couli.invalid; do
    n=$((n + 1))
    app="$(make_app "r2-$n")"
    put_utf8 "$app" "$host"
    expect 0 "R2 正式主域放行 $host" "$app"
done

app="$(make_app r3)"
for text in https://api-stg.couliapp.cn https://h5-stg.couliapp.cn https://stream-stg.couliapp.cn l-stg.couliapp.cn \
    couli-debug COULI_DEBUG_PANEL; do
    put_utf8 "$app" "$text"
done
expect 0 "R3 Staging 形态 --self-test --expect -stg.couliapp.cn" --self-test --expect -stg.couliapp.cn \
    --expect couli-debug "$app"

app="$(make_app r4)"
for text in couli-debug COULI_DEBUG_PANEL; do
    put_utf8 "$app" "$text"
done
expect 1 "R4 去掉 staging 主机后 --self-test --expect -stg.couliapp.cn" --self-test --expect -stg.couliapp.cn "$app"

app="$(make_app r5)"
for text in https://api.staging.couli.invalid couli-debug; do
    put_utf8 "$app" "$text"
done
expect 1 "R5 只有旧占位时 --self-test --expect -stg.couliapp.cn" --self-test --expect -stg.couliapp.cn "$app"

if [ "$FAILS" -gt 0 ]; then
    echo "release-scan staging 主机用例：${FAILS} / ${COUNT} 不符"
    exit 1
fi
echo "release-scan staging 主机用例：${COUNT} 条全部符合"
