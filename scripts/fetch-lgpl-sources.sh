#!/bin/bash
# LGPL 구성 요소(FFmpeg·LAME)의 원본 소스를 체크섬을 검증해 지정한 폴더에 복사한다.
# release.sh가 릴리스에 DMG와 함께 올린다(앱의 "오픈소스 라이선스" 창이 그 릴리스를 가리킨다).
#
#   scripts/fetch-lgpl-sources.sh <폴더>
#
# 버전·체크섬은 build-ffmpeg.sh의 값을 그대로 읽는다(빌드에 쓴 소스와 같은 파일). 이 스크립트를 따로 둔 것은
# build-ffmpeg.sh 내용이 바뀌면 ffmpeg를 다시 빌드하기 때문이다.
source "$(dirname "$0")/lib/common.sh"

dest=${1:-}
[[ -n $dest && $# == 1 ]] || die "사용법: scripts/fetch-lgpl-sources.sh <폴더>"

build_script="$REPO_ROOT/scripts/build-ffmpeg.sh"
constant() { awk -F= -v key="$1" '$1 == key {print $2}' "$build_script"; }
FFMPEG_VERSION=$(constant FFMPEG_VERSION)
FFMPEG_SHA256=$(constant FFMPEG_SHA256)
LAME_VERSION=$(constant LAME_VERSION)
LAME_SHA256=$(constant LAME_SHA256)
[[ -n $FFMPEG_VERSION && -n $FFMPEG_SHA256 && -n $LAME_VERSION && -n $LAME_SHA256 ]] \
  || die "build-ffmpeg.sh에서 FFmpeg·LAME 버전과 체크섬을 읽지 못했습니다."

# build-ffmpeg.sh와 같은 캐시 위치·주소를 쓴다(이미 빌드했다면 다시 받지 않는다).
src="$CACHE_DIR/src"
download_verified "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz" \
  "$LAME_SHA256" "$src/lame-$LAME_VERSION.tar.gz"
download_verified "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" \
  "$FFMPEG_SHA256" "$src/ffmpeg-$FFMPEG_VERSION.tar.xz"
mkdir -p "$dest"
install -m 644 "$src/ffmpeg-$FFMPEG_VERSION.tar.xz" "$src/lame-$LAME_VERSION.tar.gz" "$dest/"
log "LGPL 소스: $dest/ffmpeg-$FFMPEG_VERSION.tar.xz, $dest/lame-$LAME_VERSION.tar.gz"
