#!/bin/bash
# Xcode 빌드 단계(Stow 대상 "Embed Engine")에서 실행한다.
# engine/을 앱 번들 Contents/Resources/bin/으로 복사하고, 포함된 Mach-O를
# Hardened Runtime으로 서명한다. 앱 자체 서명은 이 단계 뒤에 Xcode가 한다.
set -euo pipefail

: "${SRCROOT:?Xcode 빌드 단계에서 실행해야 합니다}"
SRC="$SRCROOT/engine"
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/bin"
ENTITLEMENTS_DIR="$SRCROOT/scripts/entitlements"

for f in python/bin/python3 yt-dlp ffmpeg ffprobe deno .versions; do
  if [[ ! -e $SRC/$f ]]; then
    echo "error: 엔진 파일이 없습니다: engine/$f — scripts/fetch-binaries.sh와 scripts/build-ffmpeg.sh를 먼저 실행하세요."
    exit 1
  fi
done

# 서명 ID: Xcode가 계산한 값(인증서 해시). 비어 있거나 "-"이면 ad-hoc 서명이다.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[[ -n $IDENTITY ]] || IDENTITY="-"
SIGN=1
[[ ${CODE_SIGNING_ALLOWED:-YES} == YES ]] || SIGN=0
# Apple 타임스탬프 서버는 배포용(Developer ID) 서명에만 쓴다. 개발 서명에서 쓰면 빌드가 느려지고 오프라인에서 실패한다.
TIMESTAMP=(--timestamp=none)
[[ ${EXPANDED_CODE_SIGN_IDENTITY_NAME:-} == "Developer ID Application"* ]] && TIMESTAMP=(--timestamp)
# 빌드 상태 기록은 앱 번들이 아닌 중간 산출물 폴더에 둔다(배포 파일에 섞이지 않게).
STAMP_FILE="${DERIVED_FILE_DIR:?}/engine-embedded.stamp"

# 엔진 버전, 서명 ID, 이 스크립트·엔타이틀먼트가 같으면 다시 복사·서명하지 않는다.
STAMP=$(
  {
    cat "$SRC"/.versions/*
    echo "$IDENTITY $SIGN ${TIMESTAMP[*]} $DEST"
    cat "$0" "$ENTITLEMENTS_DIR"/*.entitlements
  } | shasum -a 256 | cut -d' ' -f1
)
if [[ -f $STAMP_FILE && $(cat "$STAMP_FILE") == "$STAMP" && -x $DEST/python/bin/python3 ]]; then
  echo "엔진: 변경 없음"
  exit 0
fi

rm -f "$STAMP_FILE"
rm -rf "$DEST"
mkdir -p "$DEST"
# .versions는 스크립트용 기록이므로 번들에 넣지 않는다.
rsync -a --exclude .versions "$SRC/" "$DEST/"

if [[ $SIGN == 1 ]]; then
  if [[ $IDENTITY == "-" ]]; then
    python_entitlements=(--entitlements "$ENTITLEMENTS_DIR/python-adhoc.entitlements")
  else
    python_entitlements=()
  fi

  sign() { # sign FILE [추가 인자...]
    local file=$1; shift
    codesign --force --options runtime "${TIMESTAMP[@]}" --sign "$IDENTITY" "$@" "$file"
  }

  count=0
  while IFS= read -r -d '' file; do
    [[ $(file -b "$file") == Mach-O* ]] || continue
    case "$file" in
      "$DEST/deno") sign "$file" --entitlements "$ENTITLEMENTS_DIR/deno.entitlements" ;;
      "$DEST"/python/bin/python3.*) sign "$file" ${python_entitlements[@]+"${python_entitlements[@]}"} ;;
      *) sign "$file" ;;
    esac
    count=$((count + 1))
  done < <(find "$DEST" -type f \( -perm -u+x -o -name '*.so' -o -name '*.dylib' \) -print0)
  echo "엔진: Mach-O ${count}개 서명 (ID: $IDENTITY)"
fi

mkdir -p "$(dirname "$STAMP_FILE")"
echo "$STAMP" > "$STAMP_FILE"
