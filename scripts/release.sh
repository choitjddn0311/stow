#!/bin/bash
# 배포용 DMG를 만든다(5a: Apple Developer 계정 없이 ad-hoc 서명).
#
#   scripts/release.sh            DMG만 만든다(build/release/Stow-<버전>.dmg와 .sha256)
#   scripts/release.sh --publish  만든 DMG를 GitHub Releases에 "초안(draft)"으로 올린다.
#                                 공개는 GitHub에서 초안을 확인한 뒤 직접 한다.
#
# 버전은 Xcode 프로젝트의 MARKETING_VERSION을 쓴다. 태그는 v<버전>.
# 5b(서명·공증)에서는 이 스크립트에 Developer ID 서명·notarytool·stapler 단계를 추가한다.
source "$(dirname "$0")/lib/common.sh"

PUBLISH=0
case "${1:-}" in
  "") ;;
  --publish) PUBLISH=1 ;;
  *) die "알 수 없는 옵션: $1 (사용법: scripts/release.sh [--publish])" ;;
esac

EXPECTED_BUNDLE_ID=io.github.choitjddn0311.stow
OUT="$REPO_ROOT/build/release"
DERIVED="$OUT/DerivedData"
cd "$REPO_ROOT"

[[ -z $(git status --porcelain) ]] || die "커밋하지 않은 변경이 있습니다. 배포는 커밋된 상태에서만 만든다."
if [[ $PUBLISH == 1 ]]; then
  [[ $(git branch --show-current) == main ]] || die "--publish는 main 브랜치에서만 할 수 있습니다."
  git fetch -q origin main
  [[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || die "로컬 main이 origin/main과 다릅니다."
fi

VERSION=$(xcodebuild -project Stow.xcodeproj -target Stow -configuration Release -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/^ *MARKETING_VERSION = /{print $2; exit}')
[[ -n $VERSION ]] || die "MARKETING_VERSION을 읽지 못했습니다."
TAG="v$VERSION"
DMG="$OUT/Stow-$VERSION.dmg"
log "Stow $VERSION 배포 파일을 만듭니다 ($(git rev-parse --short HEAD))"

if [[ $PUBLISH == 1 ]] && gh release view "$TAG" >/dev/null 2>&1; then
  die "GitHub에 $TAG 릴리스가 이미 있습니다. 버전(MARKETING_VERSION)을 올리세요."
fi

# 1. 엔진 준비(이미 있으면 건너뜀)
scripts/fetch-binaries.sh
scripts/build-ffmpeg.sh

# 2. Release 빌드(깨끗한 DerivedData)
rm -rf "$OUT"
mkdir -p "$OUT"
log "Release 빌드"
xcodebuild -project Stow.xcodeproj -scheme Stow -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" build >"$OUT/build.log" 2>&1 \
  || die "Release 빌드 실패: $OUT/build.log"
APP="$DERIVED/Build/Products/Release/Stow.app"
BIN="$APP/Contents/Resources/bin"

# 3. 검증
log "앱 검증"
codesign --verify --deep --strict "$APP" || die "앱 서명 검증 실패"
[[ $(lipo -archs "$APP/Contents/MacOS/Stow") == arm64 ]] || die "arm64 전용이 아닙니다."
[[ $(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist") == "$EXPECTED_BUNDLE_ID" ]] \
  || die "번들 ID가 $EXPECTED_BUNDLE_ID가 아닙니다."
[[ $(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist") == "$VERSION" ]] || die "앱 버전 불일치"
for f in "$APP" "$BIN/python/bin/python3.13" "$BIN/deno" "$BIN/ffmpeg" "$BIN/ffprobe"; do
  flags=$(codesign -dv "$f" 2>&1 | grep -o 'flags=[^ ]*')
  [[ $flags == *runtime* ]] || die "Hardened Runtime 미적용: $f ($flags)"
done
"$BIN/python/bin/python3" -I -B "$BIN/yt-dlp" --version >/dev/null || die "yt-dlp 실행 실패"
[[ $("$BIN/deno" eval 'console.log(6*7)') == 42 ]] || die "deno 실행 실패"
conf=$("$BIN/ffmpeg" -hide_banner -buildconf)
if grep -qE -- '--enable-(gpl|nonfree|version3)' <<<"$conf"; then die "ffmpeg 구성에 GPL/nonfree/version3 포함"; fi
leaked=$(grep -rlaiF -- "$REPO_ROOT" "$APP" || true)
[[ -z $leaked ]] || die "앱에 로컬 경로가 남아 있습니다:$(printf '\n%s' "$leaked" | head -4)"

# 4. DMG: 앱, 응용 프로그램 폴더 바로가기, 설치 안내
log "DMG 만들기"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Stow.app"
ln -s /Applications "$STAGE/Applications"
cp docs/release/INSTALL.txt "$STAGE/설치 안내.txt"
hdiutil create -volname "Stow $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null \
  || die "DMG 만들기 실패"
hdiutil verify "$DMG" >/dev/null || die "DMG 검증 실패"
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
log "완료: $DMG ($(du -h "$DMG" | cut -f1))"
cat "$DMG.sha256" >&2

# 5. GitHub Releases 초안
if [[ $PUBLISH == 1 ]]; then
  notes="$OUT/release-notes.md"
  {
    echo "## Stow $VERSION"
    echo
    echo "macOS 14 이상, Apple Silicon 전용. 아직 Apple 개발자 서명·공증 전이라 처음 열 때 아래 절차가 필요합니다."
    echo
    echo '```'
    cat docs/release/INSTALL.txt
    echo '```'
    echo
    echo "SHA-256: \`$(cut -d' ' -f1 "$DMG.sha256")\`"
  } > "$notes"
  gh release create "$TAG" "$DMG" "$DMG.sha256" --draft --title "Stow $VERSION" \
    --notes-file "$notes" --target "$(git rev-parse HEAD)"
  log "GitHub Releases에 초안 $TAG를 만들었습니다. GitHub에서 확인한 뒤 공개하세요."
fi
