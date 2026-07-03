#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_APP="$ROOT_DIR/dist/Relay-Dev.app"
DEV_EXE="$DEV_APP/Contents/MacOS/Relay"
DATA_DIR="$HOME/Library/Application Support/RelayNative-Dev"

build_and_launch() {
  "$ROOT_DIR/build.sh"
  "$ROOT_DIR/scripts/devbundle.sh"
}

case "$MODE" in
  run)
    build_and_launch
    ;;
  --verify|verify)
    build_and_launch
    sleep 1
    pgrep -f "$DEV_EXE" >/dev/null
    ;;
  --debug|debug)
    "$ROOT_DIR/build.sh"
    pkill -f "$DEV_EXE" 2>/dev/null || true
    mkdir -p "$DATA_DIR"
    RELAY_DATA_DIR="$DATA_DIR" lldb -- "$DEV_EXE"
    ;;
  --logs|logs)
    build_and_launch
    touch /tmp/relay-dev.log
    tail -f /tmp/relay-dev.log
    ;;
  --telemetry|telemetry)
    build_and_launch
    /usr/bin/log stream --info --style compact --predicate 'process == "Relay"'
    ;;
  *)
    echo "usage: $0 [run|--verify|--debug|--logs|--telemetry]" >&2
    exit 2
    ;;
esac
