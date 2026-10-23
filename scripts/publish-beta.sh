#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

: "${GITHUB_REPOSITORY:?This script runs in GitHub Actions}"
: "${GITHUB_SHA:?Missing build commit}"
: "${GITHUB_RUN_ID:?Missing workflow run}"
: "${GH_TOKEN:?Missing GitHub Actions token}"

VERSION="$(tr -d '\r\n' < VERSION)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$ ]]; then
  echo 'VERSION must have the form 0.1.0-beta.1' >&2
  exit 1
fi
TAG="v$VERSION"
RELEASE_URL="https://github.com/$GITHUB_REPOSITORY/releases/tag/$TAG"
BUILD_URL="https://github.com/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
export RELEASE_URL BUILD_URL

for arch in arm64 x86_64; do
  test -s "release-assets/DesktopMemo-macOS-$arch.zip"
  test -s "release-assets/DesktopMemo-macOS-$arch.dmg"
  test -s "release-assets/DesktopMemo-macOS-$arch-SHA256SUMS.txt"
  (cd release-assets && sha256sum -c "DesktopMemo-macOS-$arch-SHA256SUMS.txt")
done

# This file is generated only after both macOS jobs and checksum checks succeed.
python3 - <<'PY'
import os
from pathlib import Path

notes = Path('RELEASE_NOTES.md').read_text(encoding='utf-8')
notes = '\n'.join(line for line in notes.splitlines()
                  if not line.startswith('**发布准备状态：')
                  and not line.startswith('下载页：'))
proof = (f"\n\n构建记录：{os.environ['BUILD_URL']}\n\n"
         f"Apple 芯片与 Intel 云端构建、时间规划单元测试、签名完整性和安装包校验均通过。"
         f"UI、系统通知和登录启动仍需实际使用验证。\n\n"
         f"源码提交：`{os.environ['GITHUB_SHA']}`\n\n"
         f"下载页：{os.environ['RELEASE_URL']}\n")
Path('release-assets/RELEASE_NOTES.md').write_text(notes + proof, encoding='utf-8')
PY

# Never replace assets on an already published version. Bump VERSION for new code.
if gh release view "$TAG" --repo "$GITHUB_REPOSITORY" --json isDraft,targetCommitish > release-state.json 2>/dev/null; then
  python3 - <<'PY'
import json
import os
state = json.load(open('release-state.json', encoding='utf-8'))
if not state['isDraft']:
    raise SystemExit('This version is already published. Bump VERSION before publishing a new build.')
if state['targetCommitish'] != os.environ['GITHUB_SHA']:
    raise SystemExit('Existing draft belongs to another commit. Review it and use a new VERSION.')
PY
else
  gh release create "$TAG" --repo "$GITHUB_REPOSITORY" \
    --target "$GITHUB_SHA" --title "桌面备忘 $TAG" \
    --notes-file release-assets/RELEASE_NOTES.md --draft --prerelease
fi

gh release upload "$TAG" --repo "$GITHUB_REPOSITORY" \
  release-assets/*.zip release-assets/*.dmg release-assets/*-SHA256SUMS.txt --clobber
gh release edit "$TAG" --repo "$GITHUB_REPOSITORY" \
  --notes-file release-assets/RELEASE_NOTES.md --draft=false --prerelease=true --latest=false
printf 'Beta release: %s\n' "$RELEASE_URL"
