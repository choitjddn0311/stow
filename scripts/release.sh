#!/bin/bash
# 배포용 DMG를 만든다(5a: Apple Developer 계정 없이 ad-hoc 서명).
#
#   scripts/release.sh            DMG만 만든다(build/release/Stow-<버전>.dmg와 .sha256)
#                                 LGPL 구성 요소(FFmpeg·LAME)의 원본 소스도 build/release/sources/에 모은다.
#   scripts/release.sh --publish  만든 DMG와 LGPL 소스를 GitHub Releases에 "초안(draft)"으로 올린다.
#                                 공개는 GitHub에서 초안을 확인한 뒤 직접 한다.
#   scripts/release.sh --notes    빌드·업로드 없이 릴리스 노트만 만들어 보여 준다(미리보기).
#
# 릴리스 노트 = 제목 + docs/release/notes/<버전>.md(변경 사항, --publish에 필수) + 설치 안내.
#
# 버전은 Xcode 프로젝트의 MARKETING_VERSION을 쓴다. 태그는 v<버전>.
# 5b(서명·공증)에서는 이 스크립트에 Developer ID 서명·notarytool·stapler 단계를 추가한다.
source "$(dirname "$0")/lib/common.sh"

PUBLISH=0
NOTES_ONLY=0
case "${1:-}" in
  "") ;;
  --publish) PUBLISH=1 ;;
  --notes) NOTES_ONLY=1 ;;
  *) die "알 수 없는 옵션: $1 (사용법: scripts/release.sh [--publish | --notes])" ;;
esac

OUT="$REPO_ROOT/build/release"
DERIVED="$OUT/DerivedData"
cd "$REPO_ROOT"

if [[ $NOTES_ONLY == 0 ]]; then
  [[ -z $(git status --porcelain) ]] || die "커밋하지 않은 변경이 있습니다. 배포는 커밋된 상태에서만 만든다."
fi
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
BUILD_NUMBER=$(setting CURRENT_PROJECT_VERSION)
MIN_MACOS=$(setting MACOSX_DEPLOYMENT_TARGET)
BUNDLE_ID=$(setting PRODUCT_BUNDLE_IDENTIFIER)
[[ -n $VERSION && -n $BUILD_NUMBER && -n $MIN_MACOS && -n $BUNDLE_ID ]] \
  || die "버전·빌드 번호·최소 macOS·번들 ID를 빌드 설정에서 읽지 못했습니다."
TAG="v$VERSION"
DMG="$OUT/Stow-$VERSION.dmg"
# LGPL 구성 요소의 원본 소스(build-ffmpeg.sh가 체크섬을 검증해 복사). 앱의 "오픈소스 라이선스" 창이 이 릴리스를 가리킨다.
SOURCES="$OUT/sources"
FFMPEG_VERSION=$(awk -F= '/^FFMPEG_VERSION=/{print $2}' scripts/build-ffmpeg.sh)
LAME_VERSION=$(awk -F= '/^LAME_VERSION=/{print $2}' scripts/build-ffmpeg.sh)
[[ -n $FFMPEG_VERSION && -n $LAME_VERSION ]] || die "build-ffmpeg.sh에서 FFmpeg·LAME 버전을 읽지 못했습니다."
FFMPEG_SOURCE="ffmpeg-${FFMPEG_VERSION}.tar.xz"
LAME_SOURCE="lame-${LAME_VERSION}.tar.gz"
CHANGES="docs/release/notes/${VERSION}.md"
REPO_URL="https://github.com/choitjddn0311/stow"
# Sparkle 업데이트 서명키(EdDSA)의 키체인 계정. 공개키는 Config/Stow-Info.plist의 SUPublicEDKey.
SPARKLE_ACCOUNT="$BUNDLE_ID"

# write_appcast FILE ED_SIGNATURE LENGTH: Sparkle 업데이트 목록(이 버전 한 항목). 앱은
# releases/latest/download/appcast.xml을 읽으므로 최신 릴리스에 함께 올린다.
write_appcast() {
  local file=$1 signature=$2 length=$3 pub_date notes_html
  pub_date=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
  # 변경 사항(마크다운의 제목·글머리표·번호 목록·굵게·코드·링크)을 Sparkle 업데이트 창용 간단한 HTML로 바꾼다.
  notes_html=""
  if [[ -f $CHANGES ]]; then
    notes_html=$(perl -CSD -ne '
      chomp; next if /^\s*$/;
      s/&/&amp;/g; s/</&lt;/g; s/>/&gt;/g;
      s/\*\*(.+?)\*\*/<b>$1<\/b>/g; s/`([^`]+)`/<code>$1<\/code>/g;
      s/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/<a href="$2">$1<\/a>/g;
      my ($kind, $item) = /^- (.*)/ ? ("ul", $1) : /^\d+\. (.*)/ ? ("ol", $1) : ("", "");
      if ($open && $open ne $kind) { print "</$open>"; $open = "" }
      if ($kind) { print "<$kind>" unless $open; $open = $kind; print "<li>$item</li>"; next }
      if (/^#+ (.*)/) { print "<h3>$1</h3>" } else { print "<p>$_</p>" }
      END { print "</$open>" if $open }' "$CHANGES") || die "변경 사항(${CHANGES})을 HTML로 바꾸지 못했습니다."
  else
    log "주의: 변경 사항 파일(${CHANGES})이 없어 업데이트 창에 변경 사항이 보이지 않습니다."
  fi
  cat > "$file" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Stow</title>
    <link>${REPO_URL}/releases</link>
    <item>
      <title>Stow ${VERSION}</title>
      <pubDate>${pub_date}</pubDate>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_MACOS}</sparkle:minimumSystemVersion>
      <description><![CDATA[${notes_html}]]></description>
      <enclosure url="${REPO_URL}/releases/download/${TAG}/Stow-${VERSION}.dmg" length="${length}" type="application/octet-stream" sparkle:edSignature="${signature}"/>
    </item>
  </channel>
</rss>
EOF
}

# write_notes FILE SHA256: GitHub 페이지용 릴리스 노트(DMG 안의 INSTALL.txt는 열린 DMG 창 기준이라 따로 쓴다).
write_notes() {
  local file=$1 sha=$2
  {
    printf '## Stow %s\n\n' "$VERSION"
    if [[ -f $CHANGES ]]; then
      cat "$CHANGES"
      printf '\n'
    fi
    cat <<EOF
macOS 14 이상, Apple Silicon(M1 이후) 전용입니다.

### 설치
1. 아래 Assets에서 \`Stow-$VERSION.dmg\`를 받아 엽니다.
2. Stow를 "Applications"(응용 프로그램) 폴더로 끌어다 놓습니다.
3. 아직 Apple 개발자 서명·공증 전이라 처음 열 때 macOS가 실행을 막습니다.
   - **macOS 15 이후**: 경고창에서 "완료" → 시스템 설정 → 개인정보 보호 및 보안 → "그래도 열기" → 암호·Touch ID 확인 → 다시 열고 "열기"
   - **macOS 14**: Finder의 응용 프로그램 폴더에서 Stow를 Control-클릭(또는 우클릭) → "열기" → 경고창에서 "열기"
   - 터미널: \`xattr -dr com.apple.quarantine /Applications/Stow.app\`
4. 한 번 열고 나면 이후에는 경고 없이 열립니다.

SHA-256: \`$sha\`

본인이 저작권을 가지고 있거나 사용 허락을 받은 영상에만 사용하세요. 오픈소스 구성 요소와 라이선스는 앱 메뉴 "오픈소스 라이선스…"와 [README](https://github.com/choitjddn0311/stow#오픈소스-구성-요소)를 참고하세요.

### LGPL 소스
앱에 들어 있는 FFmpeg·LAME(LGPL)의 원본 소스는 아래 Assets의 \`$FFMPEG_SOURCE\`, \`$LAME_SOURCE\`입니다. 빌드 방법은 이 버전 소스 코드의 \`scripts/build-ffmpeg.sh\`에 있습니다.
EOF
  } > "$file"
}

if [[ $NOTES_ONLY == 1 ]]; then
  mkdir -p "$OUT"
  [[ -f $CHANGES ]] || log "주의: 변경 사항 파일(${CHANGES})이 없습니다. --publish에는 필요합니다."
  write_notes "$OUT/release-notes.md" "(DMG를 만든 뒤 계산)"
  write_appcast "$OUT/appcast-preview.xml" "(DMG 서명 후 계산)" 0
  log "릴리스 노트 미리보기: $OUT/release-notes.md, Sparkle 업데이트 목록 미리보기: $OUT/appcast-preview.xml"
  cat "$OUT/release-notes.md"
  exit 0
fi
log "Stow $VERSION 배포 파일을 만듭니다 ($(git rev-parse --short HEAD))"

if [[ $PUBLISH == 1 ]]; then
  [[ -f $CHANGES ]] || die "변경 사항 파일(${CHANGES})이 없습니다. 이 버전의 변경 사항을 적은 뒤 다시 실행하세요."
  # 릴리스가 없어도 태그가 남아 있으면 gh가 그 태그(다른 커밋일 수 있음)에 DMG를 붙이므로 태그도 확인한다.
  remote_tag=$(git ls-remote --tags origin "refs/tags/$TAG") || die "원격 태그를 확인하지 못했습니다(네트워크·인증 확인)."
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || [[ -n $remote_tag ]]; then
    die "태그 ${TAG}가 이미 있습니다. 버전(MARKETING_VERSION)을 올리세요."
  fi
  release_check=$(gh release view "$TAG" 2>&1) && die "GitHub에 $TAG 릴리스가 이미 있습니다. 버전(MARKETING_VERSION)을 올리세요."
  grep -qi "not found" <<<"$release_check" || die "GitHub 릴리스를 확인하지 못했습니다: $release_check"
  # Sparkle은 빌드 번호(CFBundleVersion = CURRENT_PROJECT_VERSION)로 새 버전인지 판단한다.
  # 직전 릴리스보다 크지 않으면 업데이트가 조용히 전달되지 않으므로 막는다.
  tags=$(git tag --list 'v*' --sort=-v:refname)
  prev_tag=${tags%%$'\n'*}
  if [[ -n $prev_tag ]]; then
    prev_pbxproj=$(git show "$prev_tag:Stow.xcodeproj/project.pbxproj") || die "${prev_tag}의 프로젝트 파일을 읽지 못했습니다."
    prev_build=$(awk -F' = ' '/CURRENT_PROJECT_VERSION = /{gsub(";", "", $2); print $2}' <<<"$prev_pbxproj" | sort -n | tail -n 1)
    [[ $prev_build =~ ^[0-9]+$ && $BUILD_NUMBER =~ ^[0-9]+$ ]] \
      || die "빌드 번호를 비교하지 못했습니다(${prev_tag}: ${prev_build:-?}, 현재: ${BUILD_NUMBER})."
    (( BUILD_NUMBER > prev_build )) || die "빌드 번호(CURRENT_PROJECT_VERSION) ${BUILD_NUMBER}가 직전 릴리스 ${prev_tag}의 ${prev_build}보다 커야 합니다. 같거나 작으면 Sparkle이 업데이트를 알리지 않습니다."
  fi
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
[[ -d $APP/Contents/Frameworks/Sparkle.framework ]] || die "앱에 Sparkle.framework가 없습니다."
[[ $(plutil -extract SUPublicEDKey raw "$APP/Contents/Info.plist" 2>/dev/null) != "" ]] || die "Info.plist에 SUPublicEDKey가 없습니다."
# 오픈소스 라이선스 원문(앱의 "오픈소스 라이선스" 창). Sparkle 원문은 저장소에 복사해 두므로 Sparkle을 올리면 같이 바꾼다.
for f in KeyboardShortcuts-LICENSE.txt Sparkle-LICENSE.txt bin/licenses/ffmpeg-COPYING.LGPLv2.1.txt bin/licenses/lame-COPYING.txt; do
  [[ -s $APP/Contents/Resources/$f ]] || die "앱에 라이선스 원문이 없습니다: $f"
done
cmp -s "$APP/Contents/Resources/Sparkle-LICENSE.txt" "$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/LICENSE" \
  || die "Stow/Licenses/Sparkle-LICENSE.txt가 빌드에 쓴 Sparkle의 LICENSE와 다릅니다. 새 원문으로 바꾸세요."
# 앱을 실제로 실행해 시작 직후 종료되지 않는지 본다. 프레임워크 로드·서명 문제(예: 라이브러리 검증)는
# 실행해야 드러난다. 실행하면 창이 잠깐 떴다가 닫힌다. STOW_DISABLE_UPDATERS=1: Sparkle·엔진 업데이트를 끄고
# 실행해, 실제 사용자 설정·엔진 저장소를 건드리거나 네트워크로 받는 도중에 종료되지 않게 한다.
log "앱 실행 확인(5초)"
STOW_DISABLE_UPDATERS=1 "$APP/Contents/MacOS/Stow" >"$OUT/launch.log" 2>&1 &
launch_pid=$!
sleep 5
kill -0 "$launch_pid" 2>/dev/null || die "앱이 실행 직후 종료되었습니다: $OUT/launch.log"
kill "$launch_pid"
wait "$launch_pid" 2>/dev/null || true

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

# 4b. LGPL 소스(FFmpeg·LAME 원본, 체크섬 검증)
log "LGPL 소스 모으기"
scripts/build-ffmpeg.sh --sources "$SOURCES"
[[ -s $SOURCES/$FFMPEG_SOURCE && -s $SOURCES/$LAME_SOURCE ]] || die "LGPL 소스를 모으지 못했습니다: $SOURCES"

# 5. Sparkle: DMG에 EdDSA 서명 → appcast.xml 생성·서명 → 둘 다 검증
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
APPCAST="$OUT/appcast.xml"
# 도구가 없으면(패키지 구조 변경 등) "서명키 없음"과 구분해 멈춘다.
[[ -x $SPARKLE_BIN/generate_keys && -x $SPARKLE_BIN/sign_update ]] \
  || die "Sparkle 도구(generate_keys, sign_update)를 찾지 못했습니다: $SPARKLE_BIN"
if "$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p >/dev/null 2>&1; then
  log "Sparkle 서명"
  [[ $("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p) == $(plutil -extract SUPublicEDKey raw "$APP/Contents/Info.plist") ]] \
    || die "키체인의 Sparkle 공개키가 앱의 SUPublicEDKey와 다릅니다."
  signature=$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" -p "$DMG") || die "DMG Sparkle 서명 실패"
  "$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" --verify "$DMG" "$signature" >/dev/null || die "DMG Sparkle 서명 검증 실패"
  write_appcast "$APPCAST" "$signature" "$(stat -f %z "$DMG")"
  xmllint --noout "$APPCAST" || die "appcast.xml 형식 오류"
  "$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$APPCAST" >/dev/null || die "appcast.xml 서명 실패"
  "$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" --verify "$APPCAST" >/dev/null || die "appcast.xml 서명 검증 실패"
  log "Sparkle 업데이트 목록: $APPCAST"
elif [[ $PUBLISH == 1 ]]; then
  die "키체인에 Sparkle 서명키(계정 ${SPARKLE_ACCOUNT})가 없습니다. 업데이트를 받을 수 없게 되므로 올리지 않습니다."
else
  log "주의: Sparkle 서명키가 없어 appcast.xml을 만들지 않았습니다(--publish에는 필요)."
fi

# 6. GitHub Releases 초안
if [[ $PUBLISH == 1 ]]; then
  notes="$OUT/release-notes.md"
  write_notes "$notes" "$(cut -d' ' -f1 "$DMG.sha256")"
  gh release create "$TAG" "$DMG" "$DMG.sha256" "$APPCAST" "$SOURCES/$FFMPEG_SOURCE" "$SOURCES/$LAME_SOURCE" --draft --title "Stow $VERSION" \
    --notes-file "$notes" --target "$(git rev-parse HEAD)"
  log "GitHub Releases에 초안 ${TAG}를 만들었습니다. GitHub에서 확인한 뒤 공개하세요."
fi
