#!/bin/bash
set -euo pipefail
mkdir -p screenshot-output screenshot-work
sw_vers > screenshot-output/environment.txt
uname -m >> screenshot-output/environment.txt
printf '%s\n' 'Released app: v0.1.0-beta.1 (154e51800754e071510203757cc6bb77e5b9c234)' 'Data: demonstration memos created on an ephemeral macOS runner.' >> screenshot-output/environment.txt
curl --fail --location --retry 3 'https://github.com/tengxiansheng0204-dotcom/desktop-memo/releases/download/v0.1.0-beta.1/DesktopMemo-macOS-arm64.zip' -o screenshot-work/app.zip
printf '%s\n' '561dbd43e8c6166d37189fcf053eab43dd6719e3187c37382da182632aef3f14  screenshot-work/app.zip' | shasum -a 256 -c -
ditto -x -k screenshot-work/app.zip screenshot-work
APP="$PWD/screenshot-work/DesktopMemo.app"
codesign --verify --deep --strict "$APP"
python3 - <<'PY'
import json, pathlib, time, uuid
now = time.time() - 978307200
samples = [
    ("整理今天的工作事项", "把需要跟进的事情写下来，逐个完成。", -20 * 60, 15, None),
    ("下午项目沟通", "提前准备好进度和需要确认的问题。", 45 * 60, 15, None),
    ("起身走走，喝一杯水", "忙碌的时候，也记得照顾自己。", 2 * 60 * 60, 30, None),
    ("查看今天的日程", "已经完成，提醒已停止。", -60 * 60, 15, now - 30 * 60),
]
memos = [dict(id=str(uuid.uuid4()), title=t, details=d, dueAt=now + delta,
              repeatMinutes=interval, completedAt=completed, createdAt=now - 3600)
         for t, d, delta, interval, completed in samples]
path = pathlib.Path.home() / "Library/Application Support/DesktopMemo/memos.json"
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(memos, ensure_ascii=False), encoding="utf-8")
PY
APP_PID=''
cleanup() {
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID"
    wait "$APP_PID" 2>/dev/null || true
  fi
}
trap 'exit_status=$?; cleanup; exit "$exit_status"' EXIT
# Show the real macOS desktop and Dock on this disposable runner.
defaults write com.apple.dock autohide -bool false
killall Dock 2>/dev/null || true
osascript <<'APPLESCRIPT' > screenshot-output/desktop-setup.log 2>&1 || true
with timeout of 8 seconds
    tell application "Finder"
        activate
        close every window
    end tell
end timeout
APPLESCRIPT
sleep 3
for appearance in Light; do
  "$APP/Contents/MacOS/DesktopMemo" -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN -AppleInterfaceStyle "$appearance" > "screenshot-output/startup-${appearance}.log" 2>&1 &
  APP_PID=$!
  sleep 6
  kill -0 "$APP_PID"
  WINDOW_ID=$(swift scripts/window-id.swift "$APP_PID" 2> "screenshot-output/window-${appearance}.log")
  /usr/sbin/screencapture -x -o -l "$WINDOW_ID" "screenshot-output/DesktopMemo-macOS-${appearance}.png"
  /usr/sbin/screencapture -x -D 1 "screenshot-output/DesktopMemo-macOS-Desktop.png"
  test -s "screenshot-output/DesktopMemo-macOS-Desktop.png"
  sips -g pixelWidth -g pixelHeight "screenshot-output/DesktopMemo-macOS-Desktop.png"
  test -s "screenshot-output/DesktopMemo-macOS-${appearance}.png"
  sips -g pixelWidth -g pixelHeight "screenshot-output/DesktopMemo-macOS-${appearance}.png"
  cleanup
  APP_PID=''
  sleep 1
done
