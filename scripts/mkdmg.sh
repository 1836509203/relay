#!/bin/bash
# 把 dist/Relay.app 打包成可分发 DMG（Relay.app + Applications 链接的
# 拖拽安装布局，带卷图标）。产物 dist/Relay-<版本>.dmg。
# 与 Relay.app.zip 的分工：zip 供应用内自动更新下载覆盖；DMG 供人工下载安装
#（不经第三方解压工具，resource fork/执行权限/图标元数据零损耗）。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
DMG="dist/Relay-$VERSION.dmg"
VOL="Relay"

[ -d dist/Relay.app ] || { echo "错误: dist/Relay.app 不存在，先跑 ./build.sh" >&2; exit 1; }

STAGE=$(mktemp -d)/dmg-root
mkdir -p "$STAGE"
ditto dist/Relay.app "$STAGE/Relay.app"
ln -s /Applications "$STAGE/Applications"

# 先做可写镜像 → 挂载设置卷图标 → 压缩成只读 UDZO 发布镜像。
RW=$(mktemp -d)/relay-rw.dmg
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDRW -quiet "$RW"
# 不能 -quiet：挂载点路径就在 attach 的输出里。卷名冲突时系统会挂成
# "Relay 1" 这类带空格路径，必须取 /Volumes/ 起的整段而不是末字段。
MOUNT=$(hdiutil attach "$RW" -nobrowse | /usr/bin/grep -o "/Volumes/.*" | tail -1)
[ -n "$MOUNT" ] || { echo "错误: 挂载 RW 镜像失败" >&2; exit 1; }
# 卷图标：seticon.swift 会写 .VolumeIcon.icns 并设置 custom-icon flag。
swift scripts/seticon.swift "$MOUNT" scripts/AppIcon-1024.png || true
hdiutil detach "$MOUNT" -quiet

rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -quiet -o "$DMG"
rm -rf "$(dirname "$RW")" "$(dirname "$STAGE")"
echo "OK: $DMG"
