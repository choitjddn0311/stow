#!/bin/bash
# ffmpeg/ffprobe를 arm64·LGPL 구성으로 빌드해 engine/에 둔다.
#
# - GPL·nonfree·version3 구성은 켜지 않는다(--enable-gpl 등 미사용). 빌드 후 -buildconf로 확인한다.
# - libmp3lame(LGPL)을 정적으로 링크한다.
# - --disable-everything 후 MP3·WAV·FLAC 추출에 필요한 구성 요소만 켠다.
# - --disable-autodetect로 시스템(Homebrew 등)의 라이브러리가 자동으로 섞이지 않게 한다.
# 구성(이 파일)이 바뀌면 다시 빌드한다. 빌드 결과는 build/engine-cache/에 캐시한다.
source "$(dirname "$0")/lib/common.sh"

LAME_VERSION=3.100
LAME_SHA256=ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
# ffmpeg.org는 SHA256을 공개하지 않는다. 릴리스 서명(키 FCF986EA15E6E293A5644F10B4322F04D67658D8)을
# 검증한 tarball의 SHA256을 고정했다.
FFMPEG_VERSION=9.0.2
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e

[[ $(uname -m) == arm64 ]] || die "Apple Silicon(arm64)에서만 실행할 수 있습니다."

# 이 스크립트와 공통 스크립트의 내용이 같으면 같은 빌드로 본다.
CONFIG_HASH=$(cat "$0" "$(dirname "$0")/lib/common.sh" | shasum -a 256 | cut -c1-16)
STAMP="ffmpeg $FFMPEG_VERSION lame $LAME_VERSION config $CONFIG_HASH"
PREFIX="$CACHE_DIR/ffmpeg-$FFMPEG_VERSION-$CONFIG_HASH"
JOBS=$(sysctl -n hw.ncpu)

if is_current ffmpeg "$STAMP" && [[ -x $BIN_DIR/ffmpeg && -x $BIN_DIR/ffprobe ]]; then
  log "ffmpeg $FFMPEG_VERSION: 이미 설치됨"
  exit 0
fi

build() {
  local src="$CACHE_DIR/src"
  download_verified "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz" \
    "$LAME_SHA256" "$src/lame-$LAME_VERSION.tar.gz"
  download_verified "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" \
    "$FFMPEG_SHA256" "$src/ffmpeg-$FFMPEG_VERSION.tar.xz"

  local work
  work=$(mktemp -d "$CACHE_DIR/ffmpeg-build.XXXXXX")
  local stage="$work/stage"
  local cflags="-arch arm64 -mmacosx-version-min=$MACOS_MIN -O2 -w"  # -w: lame 경고 숨김

  log "libmp3lame $LAME_VERSION 빌드"
  tar -xzf "$src/lame-$LAME_VERSION.tar.gz" -C "$work"
  (
    cd "$work/lame-$LAME_VERSION"
    # 3.100의 심볼 목록에 실제로 없는 lame_init_old가 있어 최신 링커에서 실패한다(정적 빌드에는 무관하지만 제거).
    sed -i '' '/^lame_init_old$/d' include/libmp3lame.sym
    CC=clang CFLAGS="$cflags" ./configure --prefix="$stage" --host=aarch64-apple-darwin \
      --disable-shared --enable-static --disable-frontend --disable-decoder \
      --disable-dependency-tracking >/dev/null
    make -j"$JOBS" >/dev/null
    make install >/dev/null
  )

  log "ffmpeg $FFMPEG_VERSION 빌드"
  tar -xJf "$src/ffmpeg-$FFMPEG_VERSION.tar.xz" -C "$work"
  # lame 경로는 configure 인자 대신 clang 환경 변수(CPATH, LIBRARY_PATH)로 넘긴다.
  # configure 인자는 -buildconf로 바이너리에 그대로 남으므로 로컬 경로가 들어가지 않게 한다.
  local config=(
    --arch=aarch64 --target-os=darwin --cc=clang
    --extra-cflags="-mmacosx-version-min=$MACOS_MIN"
    --extra-ldflags="-mmacosx-version-min=$MACOS_MIN"
    --disable-autodetect --disable-everything
    --disable-doc --disable-ffplay --disable-network --disable-avdevice --disable-debug
    --enable-static --disable-shared
    --enable-zlib
    --enable-libmp3lame
    --enable-protocol=file,pipe
    # 입력: 유튜브 오디오 컨테이너(m4a/mp4, webm, ogg)와 일반 오디오 파일
    --enable-demuxer=mov,matroska,ogg,mp3,aac,flac,wav,mpegts
    # 출력: MP3·WAV·FLAC, yt-dlp 보정 처리용 mp4/m4a·webm
    --enable-muxer=mp3,wav,flac,mp4,ipod,mov,matroska,webm,ogg
    --enable-decoder=aac,aac_fixed,aac_latm,opus,vorbis,mp3,mp3float,flac,alac,ac3,eac3,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s32le,pcm_f32le,pcm_u8
    --enable-encoder=libmp3lame,flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le
    --enable-parser=aac,aac_latm,opus,vorbis,flac,mpegaudio,ac3
    --enable-bsf=aac_adtstoasc
    --enable-filter=aresample,aformat,anull,atrim,abuffer,abuffersink,volume
  )
  (
    cd "$work/ffmpeg-$FFMPEG_VERSION"
    CPATH="$stage/include" LIBRARY_PATH="$stage/lib" ./configure "${config[@]}" >/dev/null
    CPATH="$stage/include" LIBRARY_PATH="$stage/lib" make -j"$JOBS" >/dev/null
    rm -rf "$PREFIX"
    mkdir -p "$PREFIX/bin" "$PREFIX/licenses"
    # ffmpeg, ffprobe는 심볼이 제거된 실행 파일이다(_g가 붙은 파일은 디버그용).
    install -m 755 ffmpeg ffprobe "$PREFIX/bin/"
    cp COPYING.LGPLv2.1 "$PREFIX/licenses/ffmpeg-COPYING.LGPLv2.1.txt"
    cp LICENSE.md "$PREFIX/licenses/ffmpeg-LICENSE.md"
    cp "$work/lame-$LAME_VERSION/COPYING" "$PREFIX/licenses/lame-COPYING.txt"
  )
  rm -rf "$work"
}

verify() {
  local ffmpeg=$1 conf
  conf=$("$ffmpeg" -hide_banner -buildconf)
  if grep -qE -- '--enable-(gpl|nonfree|version3)' <<<"$conf"; then
    die "ffmpeg 구성에 GPL/nonfree/version3가 포함되어 있습니다."
  fi
  if grep -qiF -- "$REPO_ROOT" <<<"$conf"; then
    die "ffmpeg 구성에 로컬 경로가 남아 있습니다."
  fi
  local license
  license=$("$ffmpeg" -hide_banner -L)
  grep -q 'GNU Lesser General Public' <<<"$license" || die "ffmpeg 라이선스가 LGPL이 아닙니다."
  [[ $(lipo -archs "$ffmpeg") == arm64 ]] || die "ffmpeg가 arm64 전용이 아닙니다."
  # 시스템 라이브러리(/usr/lib, /System) 외의 동적 링크가 없어야 한다.
  local foreign
  foreign=$(otool -L "$ffmpeg" | tail -n +2 | grep -vE '^\s+(/usr/lib/|/System/Library/)' || true)
  [[ -z $foreign ]] || die "ffmpeg가 시스템 외 라이브러리에 링크되어 있습니다:$foreign"
}

if [[ -x $PREFIX/bin/ffmpeg && -x $PREFIX/bin/ffprobe ]]; then
  log "ffmpeg $FFMPEG_VERSION: 캐시된 빌드 사용"
else
  build
fi
verify "$PREFIX/bin/ffmpeg"

mkdir -p "$BIN_DIR" "$LICENSES_DIR"
install -m 755 "$PREFIX/bin/ffmpeg" "$PREFIX/bin/ffprobe" "$BIN_DIR/"
install -m 644 "$PREFIX"/licenses/* "$LICENSES_DIR/"
mark_current ffmpeg "$STAMP"
log "ffmpeg $FFMPEG_VERSION 설치 완료"
