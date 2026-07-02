#!/bin/bash
# 从 dist/Relay.app 派生一个独立 bundle id 的 Relay-Dev.app，与已安装的正式版并存：
#   • bundle id = com.relay.terminal.dev（避免 LaunchServices 把 open 劫持到已装实例）
#   • 名称 = "Relay Dev"
#   • RELAY_DATA_DIR 隔离数据目录（HookServer 随机端口，无冲突）
# 然后杀掉旧 dev 实例并以隔离数据目录重启，供本机滚动选中实验测试。
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=dist/Relay.app
DEV=dist/Relay-Dev.app
DEV_ID="com.relay.terminal.dev"
DEV_NAME="Relay Dev"
DATA_DIR="$HOME/Library/Application Support/RelayNative-Dev"

[ -d "$SRC" ] || { echo "missing $SRC — run ./build.sh first"; exit 1; }

rm -rf "$DEV"
cp -R "$SRC" "$DEV"

PLIST="$DEV/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DEV_ID" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $DEV_NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DEV_NAME" "$PLIST"

# 去掉拷贝带入的扩展属性/自定义图标资源叉，否则 codesign 报 "resource fork ... not allowed"。
xattr -cr "$DEV"
rm -f "$DEV/Icon"$'\r' 2>/dev/null || true

if security find-identity -v -p codesigning 2>/dev/null | grep -q "Relay Local Dev"; then
    codesign --force --deep --sign "Relay Local Dev" "$DEV"
else
    codesign --force --deep --sign - "$DEV"
fi

# 杀掉旧 dev 实例（按可执行路径精确匹配，不误杀已装正式版）。
pkill -f "$DEV/Contents/MacOS/Relay" 2>/dev/null || true
sleep 1

mkdir -p "$DATA_DIR"
# 直接拉起可执行（而非 open）：只有这样 RELAY_DATA_DIR 环境变量才确实传进 app ——
# open 经 LaunchServices 启动会丢掉调用方 env。nohup + disown 让它在 Bash 工具调用
# 结束后继续存活。（RELAY_ALT_HARVEST 已随收割代码删除，v0.5.7 起无此开关。）
RELAY_DATA_DIR="$DATA_DIR" \
    nohup "$DEV/Contents/MacOS/Relay" >/tmp/relay-dev.log 2>&1 &
disown || true

echo "OK: relaunched $DEV (id=$DEV_ID, data=$DATA_DIR)"
