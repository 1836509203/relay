#!/bin/bash
# 为已存在的 tag 创建/补全 GitHub Release 并上传安装包（幂等，可重跑）。
# release.sh 在 tag 已 push 之后无法续传（开头的 tag 存在检查会直接退出），
# 本脚本专门补这一步：Release 不存在则建、已存在则复用；asset 同名先删再传。
#   用法: GITHUB_TOKEN=xxx ./scripts/publish-release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="1836509203/relay"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
TAG="v$VERSION"
ZIP="dist/Relay.app.zip"
DMG="dist/Relay-$VERSION.dmg"

: "${GITHUB_TOKEN:?需要 GITHUB_TOKEN 环境变量（repo / contents 写权限）}"

# 产物齐全性校验（缺任一个直接停，避免发出半截 Release）。
for f in "$ZIP" "$ZIP.sha256" "$DMG" "$DMG.sha256"; do
    [ -f "$f" ] || { echo "缺少产物: $f（先跑 ./build.sh 与打包步骤）" >&2; exit 1; }
done

api() {
    curl -sf -H "Authorization: Bearer $GITHUB_TOKEN" \
         -H "Accept: application/vnd.github+json" "$@"
}

echo "==> 查找/创建 Release $TAG"
if RJSON=$(api "https://api.github.com/repos/$REPO/releases/tags/$TAG" 2>/dev/null); then
    RELEASE_ID=$(printf '%s' "$RJSON" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
    echo "    复用已存在 Release id=$RELEASE_ID"
else
    RJSON=$(api -X POST "https://api.github.com/repos/$REPO/releases" \
        -d "{\"tag_name\":\"$TAG\",\"name\":\"Relay $TAG\",\"generate_release_notes\":true}")
    RELEASE_ID=$(printf '%s' "$RJSON" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
    echo "    新建 Release id=$RELEASE_ID"
fi

EXISTING=$(api "https://api.github.com/repos/$REPO/releases/$RELEASE_ID/assets")

upload() {
    local path="$1" ctype="$2" name old_id
    name=$(basename "$path")
    # 同名 asset 先删，保证脚本可重跑（GitHub 不允许重名 asset）。
    old_id=$(printf '%s' "$EXISTING" | ASSET_NAME="$name" /usr/bin/python3 -c '
import json, os, sys
n = os.environ["ASSET_NAME"]
for a in json.load(sys.stdin):
    if a["name"] == n:
        print(a["id"])
' 2>/dev/null || true)
    if [ -n "$old_id" ]; then
        echo "    覆盖同名 asset $name (删 id=$old_id)"
        api -X DELETE "https://api.github.com/repos/$REPO/releases/assets/$old_id" >/dev/null || true
    fi
    echo "==> 上传 $name"
    curl -sf -X POST \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Content-Type: $ctype" \
        --data-binary @"$path" \
        "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=$name" >/dev/null
}

# zip 的 asset 名必须是 Relay.app.zip（自动更新器据此定位下载）。
upload "$ZIP"        "application/zip"
upload "$DMG"        "application/x-apple-diskimage"
upload "$ZIP.sha256" "text/plain"
upload "$DMG.sha256" "text/plain"

echo "==> 完成: https://github.com/$REPO/releases/tag/$TAG"
