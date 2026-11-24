#!/bin/bash
# Mac(scripts/build-ffmpeg.sh)과 Windows(windows/scripts/build-ffmpeg.sh)의 ffmpeg·LAME 버전·체크섬과
# 켜는 구성 요소 목록이 같은지 확인한다(두 플랫폼의 기능이 어긋나지 않게). 한쪽만 바꾸면 실패한다.
source "$(dirname "$0")/lib.sh"

MAC="$WIN_ROOT/../scripts/build-ffmpeg.sh"
WIN="$WIN_ROOT/scripts/build-ffmpeg.sh"

extract() {
  grep -E '^(FFMPEG|LAME)_(VERSION|SHA256)=|^ *--enable-(protocol|demuxer|muxer|decoder|encoder|parser|bsf|filter)=|^ *--enable-(zlib|libmp3lame)$|^ *--disable-(everything|autodetect|network|avdevice)' "$1" \
    | sed -E 's/^ +//' | tr ' ' '\n' | grep -E '^(FFMPEG|LAME)_|^--' | sort
}

if ! diff <(extract "$MAC") <(extract "$WIN"); then
  die "Mac과 Windows의 ffmpeg 구성이 다릅니다(위 차이). 두 build-ffmpeg.sh를 함께 고치세요."
fi
log "ffmpeg 구성: Mac과 Windows가 같습니다."
