#!/bin/bash
set -euo pipefail

NO_OPEN=0
for argument in "$@"; do
  case "$argument" in
    --no-open) NO_OPEN=1 ;;
    -h|--help)
      echo "Usage: bash build-mac.command [--no-open]"
      echo "Test and package a native-architecture macOS beta (ad hoc signed, not notarized)."
      echo "Set SMOKE_TEST=1 on a disposable macOS CI runner to check app startup for 8 seconds."
      exit 0
      ;;
    *) echo "Unknown argument: $argument" >&2; exit 2 ;;
  esac
done

case "${SMOKE_TEST:-0}" in
  0|1) ;;
  *) echo "SMOKE_TEST must be 0 or 1" >&2; exit 2 ;;
esac

cd "$(dirname "$0")"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "此脚本只能在 Mac 上运行。"
  exit 1
fi
if ! xcrun --find swift >/dev/null 2>&1; then
  echo "请先安装 Apple 开发工具：在终端运行 xcode-select --install"
  echo "安装完成后，重新运行本脚本。需要 Swift 5.9 或更新版本。"
  exit 1
fi

ARCH="$(uname -m)"
case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "Unsupported host architecture: $ARCH" >&2; exit 1 ;;
esac
PACKAGE_NAME="DesktopMemo-macOS-$ARCH"
mkdir -p dist
DIST="$(cd dist && pwd -P)"
STAGING="$(mktemp -d "$DIST/.package.XXXXXX")"
SMOKE_PID=""
stop_smoke() {
  if [[ -n "$SMOKE_PID" ]]; then
    # Only signal the child launched by this invocation, never other app instances.
    kill "$SMOKE_PID" 2>/dev/null || true
    for attempt in 1 2 3 4 5; do
      if ! kill -0 "$SMOKE_PID" 2>/dev/null; then break; fi
      sleep 1
    done
    if kill -0 "$SMOKE_PID" 2>/dev/null; then
      kill -KILL "$SMOKE_PID" 2>/dev/null || true
    fi
    wait "$SMOKE_PID" 2>/dev/null || true
    SMOKE_PID=""
  fi
}
cleanup() {
  stop_smoke
  # Only remove the fresh private staging directory created by this invocation.
  case "$STAGING" in
    "$DIST"/.package.??????) rm -rf -- "$STAGING" ;;
    *) echo "Refusing to remove unexpected staging path: $STAGING" >&2 ;;
  esac
}
trap 'exit_status=$?; cleanup; exit "$exit_status"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "正在验证并构建桌面备忘 Beta（${ARCH}）…"
xcrun swift test -c release --arch "$ARCH"
xcrun swift build -c release --arch "$ARCH"
BIN_DIR="$(xcrun swift build -c release --arch "$ARCH" --show-bin-path)"
xcrun lipo "$BIN_DIR/DesktopMemo" -verify_arch "$ARCH"
APP="$STAGING/DesktopMemo.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DesktopMemo" "$APP/Contents/MacOS/DesktopMemo"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/DesktopMemo"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - --identifier com.desktopmemo.local "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [[ "${SMOKE_TEST:-0}" -eq 1 ]]; then
  SMOKE_LOG="$DIST/startup-$ARCH.log"
  echo "检查已签名应用能否持续运行 8 秒（不会操作通知权限）…"
  "$APP/Contents/MacOS/DesktopMemo" > "$SMOKE_LOG" 2>&1 &
  SMOKE_PID=$!
  sleep 8
  if ! kill -0 "$SMOKE_PID" 2>/dev/null; then
    if wait "$SMOKE_PID"; then
      SMOKE_STATUS=0
    else
      SMOKE_STATUS=$?
    fi
    SMOKE_PID=""
    echo "Startup smoke test failed: app exited before 8 seconds (status $SMOKE_STATUS)." >&2
    tail -n 80 "$SMOKE_LOG" >&2
    exit 1
  fi
  stop_smoke
  echo "Startup smoke test passed: app remained alive for 8 seconds." | tee -a "$SMOKE_LOG"
fi

cat > "$STAGING/README-Beta.txt" <<EOF
桌面备忘 / DesktopMemo — 0.1.0 Beta

适用系统：macOS 13 或更新版本
处理器架构：${ARCH}（arm64 = Apple 芯片；x86_64 = Intel）

安装：将 DesktopMemo.app 拖入“应用程序”，然后打开。
首次启动请允许系统通知。关闭备忘窗口后，应用仍在菜单栏运行。
开启“开机启动”前，请先完成安装。

这是用于测试的 Beta，由构建机器进行临时（ad hoc）签名。
它没有 Apple Developer ID 签名，也没有经过 Apple 公证。
从网络下载后，macOS 可能阻止首次打开。仅在确认下载来源可信时，
按 macOS 的提示到“系统设置 → 隐私与安全性”允许打开。
无需也不建议关闭系统安全保护。

Beta build: ad hoc signed; no Developer ID signature; not notarized by Apple.
Drag DesktopMemo.app to Applications. Allow notifications on first launch.
macOS may block the first launch after download. If you trust the source,
follow the macOS Privacy & Security approval flow. Keep system protections on.
EOF

echo "正在生成 ZIP 和 DMG…"
# Keep the beta notice beside the app in both download formats.
mkdir "$STAGING/zip-content"
ditto "$APP" "$STAGING/zip-content/DesktopMemo.app"
cp "$STAGING/README-Beta.txt" "$STAGING/zip-content/README-Beta.txt"
ditto -c -k --sequesterRsrc "$STAGING/zip-content" "$STAGING/$PACKAGE_NAME.zip"

mkdir "$STAGING/dmg-content"
ditto "$APP" "$STAGING/dmg-content/DesktopMemo.app"
cp "$STAGING/README-Beta.txt" "$STAGING/dmg-content/README-Beta.txt"
ln -s /Applications "$STAGING/dmg-content/Applications"
hdiutil create -volname "DesktopMemo Beta" -srcfolder "$STAGING/dmg-content" \
  -format UDZO -ov "$STAGING/$PACKAGE_NAME.dmg"
hdiutil verify "$STAGING/$PACKAGE_NAME.dmg"

# Publish only after both formats were built and the disk image was verified.
mv -f "$STAGING/$PACKAGE_NAME.zip" "$DIST/$PACKAGE_NAME.zip"
mv -f "$STAGING/$PACKAGE_NAME.dmg" "$DIST/$PACKAGE_NAME.dmg"
(
  cd "$DIST"
  shasum -a 256 "$PACKAGE_NAME.zip" "$PACKAGE_NAME.dmg" > "$PACKAGE_NAME-SHA256SUMS.txt"
)

echo ""
echo "Beta 构建完成（临时签名，未经 Apple 公证）："
echo "$DIST/$PACKAGE_NAME.zip"
echo "$DIST/$PACKAGE_NAME.dmg"
echo "$DIST/$PACKAGE_NAME-SHA256SUMS.txt"
echo "打开 DMG，将 DesktopMemo.app 拖入“应用程序”。首次使用请开启通知。"
if [[ "$NO_OPEN" -eq 0 ]]; then
  open -R "$DIST/$PACKAGE_NAME.dmg"
fi
