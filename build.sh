#!/bin/bash
# 构建原生单进程 Relay.app（无 Xcode，仅 CLT：swift build + 手工组包 + ad-hoc 签名）。
set -euo pipefail
cd "$(dirname "$0")"

# 强制 arm64：调用方 shell 可能跑在 Rosetta 下（x86_64），swift 会跟随
# 调用进程架构产出转译二进制 —— 实测 footprint 从 ~60MB 膨胀到 141MB。
swift build -c release --arch arm64 2>&1 | tail -5
BIN=$(swift build -c release --arch arm64 --show-bin-path)

APP=dist/Relay.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Relay" "$APP/Contents/MacOS/Relay"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 优先自签证书（稳定签名身份，macOS 26 WindowManager 角标缓存认它），
# 没有证书的机器回落 ad-hoc。证书生成见 README 或 scripts/release.sh 注释。
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Relay Local Dev"; then
    codesign --force --deep --sign "Relay Local Dev" "$APP"
else
    codesign --force --deep --sign - "$APP"
fi
# Finder 自定义图标（必须在签名后：Icon\r 资源文件不属于签名内容）。
# macOS 26 角标管线只认 Assets.car，icns 不够 —— 见 scripts/seticon.swift。
swift scripts/seticon.swift "$APP" scripts/AppIcon-1024.png
echo "OK: $APP"
