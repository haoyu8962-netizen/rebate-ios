#!/bin/bash
# 按 contract.lock 锁定的两个提交重建 contracts/snapshot/，并刷新 lock 的 files 哈希。
# 用法：tools/contracts/sync.sh
# 仓库路径取 lock 里的相对路径（相对仓库根）；可用环境变量覆盖：
#   REBATE_PLATFORM_DIR=/path/to/rebate-platform COULI_DIR=/path/to/couli tools/contracts/sync.sh
# YAML 用系统自带 Ruby 的 YAML.safe_load 转 JSON；契约按 YAML 1.2 写，Ruby 按 1.1 解析，
# 所以转换后出现布尔或非字符串的映射键（如未加引号的 on/off/yes/no）就报错退出。
# 兼容 macOS 自带 bash 3.2。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOCK="$ROOT/contract.lock"
SNAPSHOT="$ROOT/contracts/snapshot"
RUBY="/usr/bin/ruby"

die() {
    echo "sync.sh: $*" >&2
    exit 1
}

[ -f "$LOCK" ] || die "找不到 $LOCK"

lock_get() {
    python3 - "$LOCK" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
node = data
for part in sys.argv[2].split("."):
    node = node[part]
print(node)
PY
}

resolve_repo() {
    # $1 = lock 里的相对路径，$2 = 覆盖用的环境变量值
    if [ -n "$2" ]; then
        printf '%s\n' "$2"
    else
        (cd "$ROOT" && cd "$1" 2>/dev/null && pwd) || die "仓库 $1 不存在（相对 ${ROOT}），请用环境变量覆盖"
    fi
}

RP_REPO="$(resolve_repo "$(lock_get rebate_platform.repo)" "${REBATE_PLATFORM_DIR:-}")"
RP_COMMIT="$(lock_get rebate_platform.commit)"
DT_REPO="$(resolve_repo "$(lock_get design_tokens.repo)" "${COULI_DIR:-}")"
DT_COMMIT="$(lock_get design_tokens.commit)"
DT_PATH="$(lock_get design_tokens.path)"

git -C "$RP_REPO" cat-file -e "$RP_COMMIT^{commit}" 2>/dev/null || die "$RP_REPO 里没有提交 $RP_COMMIT"
git -C "$DT_REPO" cat-file -e "$DT_COMMIT^{commit}" 2>/dev/null || die "$DT_REPO 里没有提交 $DT_COMMIT"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/couli-sync.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/snapshot"
mkdir -p "$OUT"

# 输出统一格式：保持源文件的键顺序（枚举取值的契约顺序有意义），UTF-8、2 空格缩进、末尾换行。
normalize_json() {
    python3 -c '
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as f:
    data = json.load(f)
with open(dst, "w", encoding="utf-8", newline="\n") as f:
    f.write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
' "$1" "$2"
}

yaml_to_json() {
    "$RUBY" -ryaml -rjson -e '
def check(node, path)
  case node
  when Hash
    node.each do |k, v|
      unless k.is_a?(String)
        STDERR.puts "#{ARGV[0]}: #{path} 下出现非字符串映射键 #{k.inspect}（#{k.class}）；YAML 1.1 会把未加引号的 on/off/yes/no 当布尔，请在契约里给键加引号"
        exit 2
      end
      check(v, "#{path}.#{k}")
    end
  when Array
    node.each_with_index { |v, i| check(v, "#{path}[#{i}]") }
  end
end
data = YAML.safe_load(STDIN.read, permitted_classes: [], permitted_symbols: [], aliases: false)
check(data, "$")
STDOUT.write(JSON.generate(data))
' "$1"
}

# $1 仓库 $2 提交 $3 源路径 $4 快照内相对路径
take() {
    local repo="$1" commit="$2" src="$3" dst="$OUT/$4" raw="$TMP/raw"
    mkdir -p "$(dirname "$dst")"
    git -C "$repo" show "$commit:$src" >"$raw" || die "取不到 $commit:$src"
    case "$src" in
        *.yaml | *.yml)
            yaml_to_json "$src" <"$raw" >"$TMP/converted.json" || die "$src 转换失败"
            normalize_json "$TMP/converted.json" "$dst"
            ;;
        *.json)
            normalize_json "$raw" "$dst"
            ;;
        *) die "不支持的文件类型 $src" ;;
    esac
    echo "  $4  <=  $src"
}

json_name() {
    printf '%s\n' "$1" | sed -E 's/\.(yaml|yml)$/.json/'
}

echo "rebate-platform $RP_COMMIT"
# 先单独取目录列表并检查退出码，再在 shell 里筛 YAML（不用 grep … || true：那样会把 git / grep 出错吞成「部分列表」）。
ENUM_TREE="$(git -C "$RP_REPO" ls-tree --name-only "$RP_COMMIT" contracts/enums/)" || die "列出 contracts/enums/ 失败"
OLDIFS="$IFS"
IFS='
'
ENUM_FILES=""
for f in $ENUM_TREE; do
    case "$f" in
        *.yaml | *.yml) ENUM_FILES="${ENUM_FILES}${f}
" ;;
    esac
done
[ -n "$ENUM_FILES" ] || die "contracts/enums/ 下没有 YAML"
for f in $ENUM_FILES; do
    take "$RP_REPO" "$RP_COMMIT" "$f" "$(json_name "$f")"
done
IFS="$OLDIFS"

# APP-02c 加入 openapi.yaml（只用 GET /v1/app-versions/check 的响应示例作调试假数据；OpenAPI 客户端仍归 APP-03）
# 与 specs/app-stores.yaml（商店对照表，生成 AppStores 常量）。
# APP-03a 加入 specs/request-sign.vectors.json（BR-ID-09 服务端与三端共用的签名测试向量）。
for f in \
    contracts/error-codes.yaml \
    contracts/routes.json \
    contracts/bridge.schema.json \
    contracts/agent-stream.schema.json \
    contracts/texts.default.json \
    contracts/apps.json \
    specs/events.yaml \
    specs/client-public-ids.yaml \
    specs/client-security-baseline.yaml \
    specs/system-permissions.yaml \
    contracts/openapi.yaml \
    specs/app-stores.yaml \
    specs/request-sign.vectors.json; do
    take "$RP_REPO" "$RP_COMMIT" "$f" "$(json_name "$f")"
done

echo "design tokens $DT_COMMIT"
take "$DT_REPO" "$DT_COMMIT" "$DT_PATH" "design/design-tokens.json"

rm -rf "$SNAPSHOT"
mkdir -p "$(dirname "$SNAPSHOT")"
mv "$OUT" "$SNAPSHOT"

python3 - "$LOCK" "$SNAPSHOT" <<'PY'
import hashlib, json, os, sys
lock_path, snap = sys.argv[1], sys.argv[2]
with open(lock_path, encoding="utf-8") as f:
    lock = json.load(f)
files = {}
for dirpath, _, names in os.walk(snap):
    for name in names:
        full = os.path.join(dirpath, name)
        rel = os.path.relpath(full, snap).replace(os.sep, "/")
        with open(full, "rb") as fh:
            files[rel] = hashlib.sha256(fh.read()).hexdigest()
lock["files"] = {k: files[k] for k in sorted(files)}
with open(lock_path, "w", encoding="utf-8", newline="\n") as f:
    f.write(json.dumps(lock, ensure_ascii=False, indent=2) + "\n")
PY
echo "已刷新 contract.lock（$(cd "$SNAPSHOT" && find . -type f | wc -l | tr -d ' ') 个文件）"
