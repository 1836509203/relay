#!/bin/bash
# 发布一个版本到 GitHub Releases（自动更新的数据源）。
#   用法: ./scripts/release.sh
#   读 Info.plist 的 CFBundleShortVersionString 作为版本号 → 构建 →
#   打 Relay.app.zip → git tag vX.Y.Z + push → 有 GITHUB_TOKEN 时调 API
#   创建 Release 并上传 asset，否则提示手动上传。
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="1836509203/relay"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
TAG="v$VERSION"
ZIP="dist/Relay.app.zip"

echo "==> 发布 $TAG"

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "错误: tag $TAG 已存在；先在 Info.plist bump 版本号。" >&2
    exit 1
fi

echo "==> 构建"
./build.sh

echo "==> 打包 $ZIP"
rm -f "$ZIP"
# --sequesterRsrc 保留 resource fork（Finder 自定义图标）。
ditto -c -k --sequesterRsrc --keepParent dist/Relay.app "$ZIP"

echo "==> 打包 DMG"
DMG="dist/Relay-$VERSION.dmg"
./scripts/mkdmg.sh

# 生成校验和（自动更新器下载后比对哈希，防镜像投毒）。
# shasum 输出 "<hex>  <文件名>"，文件名只留 basename 便于客户端核对。
echo "==> 生成校验和"
( cd dist && shasum -a 256 "Relay.app.zip" > "Relay.app.zip.sha256" )
( cd dist && shasum -a 256 "Relay-$VERSION.dmg" > "Relay-$VERSION.dmg.sha256" )

echo "==> 打 tag 并推送"
git tag "$TAG"
git push origin main "$TAG"

if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "==> 创建 GitHub Release"
    RELEASE_JSON=$(curl -sf -X POST \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$REPO/releases" \
        -d "{\"tag_name\":\"$TAG\",\"name\":\"Relay $TAG\",\"generate_release_notes\":true}")
    RELEASE_ID=$(echo "$RELEASE_JSON" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
    echo "==> 上传 $ZIP"
    curl -sf -X POST \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Content-Type: application/zip" \
        --data-binary @"$ZIP" \
        "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=Relay.app.zip" >/dev/null
    echo "==> 上传 $DMG"
    curl -sf -X POST \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Content-Type: application/x-apple-diskimage" \
        --data-binary @"$DMG" \
        "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=$(basename "$DMG")" >/dev/null
    # 校验和文件（必须随包上传，否则新版客户端校验失败会拒装）。
    for SUM in "$ZIP.sha256" "$DMG.sha256"; do
        echo "==> 上传 $(basename "$SUM")"
        curl -sf -X POST \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            -H "Content-Type: text/plain" \
            --data-binary @"$SUM" \
            "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=$(basename "$SUM")" >/dev/null
    done
    echo "==> 完成: https://github.com/$REPO/releases/tag/$TAG"
else
    echo "未设置 GITHUB_TOKEN，请手动操作："
    echo "  1. 打开 https://github.com/$REPO/releases/new?tag=$TAG"
    echo "  2. 上传 ${ZIP}（asset 名必须是 Relay.app.zip）和 ${DMG}"
    echo "  3. 点击 Publish release"
fi
