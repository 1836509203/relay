#!/bin/bash
# 补发布最后一步：建 GitHub Release + 上传 dist/ 里的 asset。
# 不打 tag（假设 release.sh 已 push tag），幂等：release 已存在则复用。
# token 不写在脚本里 —— 运行时通过环境变量 GITHUB_TOKEN 注入：
#   GITHUB_TOKEN=<你的token> ./scripts/release-finalize.sh
set -uo pipefail
cd "$(dirname "$0")/.."

REPO="1836509203/relay"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
TAG="v$VERSION"

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "错误: 未设置 GITHUB_TOKEN 环境变量。用法: GITHUB_TOKEN=<token> $0" >&2
  exit 1
fi

ZIP="dist/Relay.app.zip"
DMG="dist/Relay-$VERSION.dmg"
for f in "$ZIP" "$DMG" "$ZIP.sha256" "$DMG.sha256"; do
  [ -f "$f" ] || { echo "错误: 缺少 $f，先跑 ./scripts/release.sh 构建打包。" >&2; exit 1; }
done

api() { curl -s -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" "$@"; }

echo "==> 创建/复用 Release $TAG"
RESP=$(api -X POST "https://api.github.com/repos/$REPO/releases" \
  -d "{\"tag_name\":\"$TAG\",\"name\":\"Relay $TAG\",\"generate_release_notes\":true}")
RID=$(echo "$RESP" | python3 -c "import json,sys;print(json.load(sys.stdin).get('id','') or '')" 2>/dev/null)

if [ -z "$RID" ]; then
  # 可能 release 已存在；按 tag 查现有 release 复用其 id
  RID=$(api "https://api.github.com/repos/$REPO/releases/tags/$TAG" \
    | python3 -c "import json,sys;print(json.load(sys.stdin).get('id','') or '')" 2>/dev/null)
fi
if [ -z "$RID" ]; then
  echo "创建 Release 失败，API 返回："
  echo "$RESP" | python3 -c "import json,sys;d=json.load(sys.stdin);print(' ',d.get('message',d));[print('  -',e) for e in d.get('errors',[])]" 2>/dev/null || echo "$RESP"
  echo "（若是 401/403：token 无效或缺 repo 权限；检查后重试。）"
  exit 1
fi
echo "   release id = $RID"

upload() {
  local path="$1" ct="$2" name; name=$(basename "$path")
  echo "==> 上传 $name"
  local r; r=$(curl -s -X POST \
    -H "Authorization: Bearer $GITHUB_TOKEN" -H "Content-Type: $ct" \
    --data-binary @"$path" \
    "https://uploads.github.com/repos/$REPO/releases/$RID/assets?name=$name")
  echo "$r" | python3 -c "import json,sys;d=json.load(sys.stdin);print('   ->',d.get('name') or d.get('message') or d)" 2>/dev/null || echo "   (响应解析失败)"
}

upload "$ZIP" application/zip
upload "$DMG" application/x-apple-diskimage
upload "$ZIP.sha256" text/plain
upload "$DMG.sha256" text/plain

echo "==> 完成: https://github.com/$REPO/releases/tag/$TAG"
