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

OUT="$REPO_ROOT/build/release"
DERIVED="$OUT/DerivedData"
cd "$REPO_ROOT"

[[ -z $(git status --porcelain) ]] || die "커밋하지 않은 변경이 있습니다. 배포는 커밋된 상태에서만 만든다."
if [[ $PUBLISH == 1 ]]; then
  # 빌드에 몇 분이 걸리므로, 올릴 수 없는 상황이면 먼저 멈춘다.
  gh auth status >/dev/null 2>&1 || die "GitHub CLI에 로그인되어 있지 않습니다(gh auth login)."
  [[ $(git branch --show-current) == main ]] || die "--publish는 main 브랜치에서만 할 수 있습니다."
  git fetch -q origin main --tags
  [[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || die "로컬 main이 origin/main과 다릅니다."
fi

# 빌드 설정은 변수로 받은 뒤 읽는다(파이프에서 awk가 먼저 끝나면 pipefail로 메시지 없이 멈출 수 있음).
settings=$(xcodebuild -project Stow.xcodeproj -target Stow -configuration Release -showBuildSettings 2>/dev/null) \
  || die "빌드 설정을 읽지 못했습니다."
setting() { awk -F' = ' -v key="$1" '$1 ~ "^ *"key"$" {print $2}' <<<"$settings" | head -n 1; }
VERSION=$(setting MARKETING_VERSION)
BUNDLE_ID=$(setting PRODUCT_BUNDLE_IDENTIFIER)
[[ -n $VERSION && -n $BUNDLE_ID ]] || die "MARKETING_VERSION 또는 PRODUCT_BUNDLE_IDENTIFIER를 읽지 못했습니다."
TAG="v$VERSION"
DMG="$OUT/Stow-$VERSION.dmg"
log "Stow $VERSION 배포 파일을 만듭니다 ($(git rev-parse --short HEAD))"

if [[ $PUBLISH == 1 ]]; then
  # 릴리스가 없어도 태그가 남아 있으면 gh가 그 태그(다른 커밋일 수 있음)에 DMG를 붙이므로 태그도 확인한다.
  remote_tag=$(git ls-remote --tags origin "refs/tags/$TAG") || die "원격 태그를 확인하지 못했습니다(네트워크·인증 확인)."
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || [[ -n $remote_tag ]]; then
    die "태그 ${TAG}가 이미 있습니다. 버전(MARKETING_VERSION)을 올리세요."
  fi
  release_check=$(gh release view "$TAG" 2>&1) && die "GitHub에 $TAG 릴리스가 이미 있습니다. 버전(MARKETING_VERSION)을 올리세요."
  grep -qi "not found" <<<"$release_check" || die "GitHub 릴리스를 확인하지 못했습니다: $release_check"
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
[[ $(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist") == "$BUNDLE_ID" ]] \
  || die "앱의 번들 ID가 빌드 설정($BUNDLE_ID)과 다릅니다."
[[ $(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist") == "$VERSION" ]] || die "앱 버전 불일치"
python_bin=$(find "$BIN/python/bin" -name 'python3.*' -type f | head -n 1)
[[ -n $python_bin ]] || die "번들에 Python 실행 파일이 없습니다."
for f in "$APP" "$python_bin" "$BIN/deno" "$BIN/ffmpeg" "$BIN/ffprobe"; do
  [[ -e $f ]] || die "번들에 없습니다: $f"
  flags=$(codesign -dv "$f" 2>&1 | grep -o 'flags=[^ ]*' || true)
  [[ $flags == *runtime* ]] || die "Hardened Runtime 미적용 또는 서명 없음: $f (${flags:-서명 정보 없음})"
done
"$python_bin" -I -B "$BIN/yt-dlp" --version >/dev/null || die "yt-dlp 실행 실패"
[[ $("$BIN/deno" eval 'console.log(6*7)') == 42 ]] || die "deno 실행 실패"
conf=$("$BIN/ffmpeg" -hide_banner -buildconf)
if grep -qE -- '--enable-(gpl|nonfree|version3)' <<<"$conf"; then die "ffmpeg 구성에 GPL/nonfree/version3 포함"; fi
# 배포 파일에 저장소 경로나 홈 폴더 경로(사용자 이름)가 남지 않았는지 확인한다.
leaked=$(grep -rlaiF -e "$REPO_ROOT" -e "$HOME/" "$APP" || true)
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
  # GitHub 페이지용 안내(DMG 안의 INSTALL.txt는 열린 DMG 창 기준이라 그대로 쓰지 않는다).
  cat > "$notes" <<EOF
## Stow $VERSION

macOS 14 이상, Apple Silicon(M1 이후) 전용입니다.

### 설치
1. 아래 Assets에서 \`Stow-$VERSION.dmg\`를 받아 엽니다.
2. Stow를 "Applications"(응용 프로그램) 폴더로 끌어다 놓습니다.
3. 아직 Apple 개발자 서명·공증 전이라 처음 열 때 macOS가 실행을 막습니다.
   - **macOS 15 이후**: 경고창에서 "완료" → 시스템 설정 → 개인정보 보호 및 보안 → "그래도 열기" → 암호·Touch ID 확인 → 다시 열고 "열기"
   - **macOS 14**: Finder의 응용 프로그램 폴더에서 Stow를 Control-클릭(또는 우클릭) → "열기" → 경고창에서 "열기"
   - 터미널: \`xattr -dr com.apple.quarantine /Applications/Stow.app\`
4. 한 번 열고 나면 이후에는 경고 없이 열립니다.

SHA-256: \`$(cut -d' ' -f1 "$DMG.sha256")\`

본인이 저작권을 가지고 있거나 사용 허락을 받은 영상에만 사용하세요. 오픈소스 구성 요소와 라이선스는 [README](https://github.com/choitjddn0311/stow#오픈소스-구성-요소)를 참고하세요.
EOF
  gh release create "$TAG" "$DMG" "$DMG.sha256" --draft --title "Stow $VERSION" \
    --notes-file "$notes" --target "$(git rev-parse HEAD)"
  log "GitHub Releases에 초안 ${TAG}를 만들었습니다. GitHub에서 확인한 뒤 공개하세요."
fi
