#!/bin/bash
# Windows용 ffmpeg.exe·ffprobe.exe를 LGPL 구성으로 교차 빌드해 엔진 폴더에 둔다. Linux(x86_64)에서만 실행한다.
#
#   windows/scripts/build-ffmpeg.sh <win-x64|win-arm64> [엔진 폴더(기본 windows/engine/<rid>)]
#
# - 컴파일러는 llvm-mingw(clang + mingw-w64, UCRT) 하나로 x64·ARM64를 모두 만든다.
# - 구성 요소 목록은 Mac scripts/build-ffmpeg.sh와 같게 유지한다(오디오 변환 + 영상·오디오 합치기, 재인코딩 없음).
# - GPL·nonfree·version3는 켜지 않고, 빌드 후 config.h로 확인한다. LAME(LGPL)·zlib(zlib 라이선스)은 정적으로 넣는다.
# - 결과 실행 파일은 Windows 기본 DLL(KERNEL32, UCRT 등)에만 의존해야 한다(lib*.dll이 있으면 실패).
source "$(dirname "$0")/lib.sh"

[[ $# -ge 1 && $# -le 2 ]] || die "사용법: windows/scripts/build-ffmpeg.sh <win-x64|win-arm64> [엔진 폴더]"
RID=$1
ARCH=$(arch_for "$RID")
DEST=${2:-$WIN_ROOT/engine/$RID}
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die "Linux x86_64에서만 실행할 수 있습니다."

LLVM_MINGW_VERSION=20261104
LLVM_MINGW_SHA256=919380403de87dca3c581c2053230cd298af5e891286628ba0613b7fed370926
# Mac scripts/build-ffmpeg.sh와 같은 버전·체크섬
LAME_VERSION=3.100
LAME_SHA256=ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
FFMPEG_VERSION=9.0.2
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
ZLIB_VERSION=1.3.1
ZLIB_SHA256=9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23

TRIPLE="$ARCH-w64-mingw32"
JOBS=$(nproc)
CONFIG_HASH=$(cat "$0" "$(dirname "$0")/lib.sh" | sha256sum | cut -c1-16)
PREFIX="$WIN_CACHE/ffmpeg-$FFMPEG_VERSION-$RID-$CONFIG_HASH"

toolchain() {
  local name="llvm-mingw-$LLVM_MINGW_VERSION-ucrt-ubuntu-22.04-x86_64"
  local dir="$WIN_CACHE/$name"
  if [[ ! -x $dir/bin/$TRIPLE-clang ]]; then
    download_verified "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VERSION/$name.tar.xz" \
      "$LLVM_MINGW_SHA256" "$WIN_CACHE/$name.tar.xz"
    tar -xJf "$WIN_CACHE/$name.tar.xz" -C "$WIN_CACHE"
  fi
  echo "$dir/bin"
}

# 정적 라이브러리의 오브젝트가 대상 아키텍처인지 확인한다.
check_lib() {
  local formats
  formats=$(llvm-objdump -f "$1" | sed -n 's/.*file format //p' | sort -u | tr '\n' ' ')
  log "$(basename "$1"): $formats"
  case $ARCH in
    x86_64) [[ $formats == "coff-x86-64 " ]] || die "$(basename "$1")가 x64가 아닙니다: $formats" ;;
    aarch64) [[ $formats == "coff-arm64 " ]] || die "$(basename "$1")가 ARM64가 아닙니다: $formats" ;;
  esac
}

build() {
  local bin src work stage
  bin=$(toolchain)
  export PATH="$bin:$PATH"
  src="$WIN_CACHE/src"
  download_verified "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz" \
    "$LAME_SHA256" "$src/lame-$LAME_VERSION.tar.gz"
  download_verified "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" \
    "$FFMPEG_SHA256" "$src/ffmpeg-$FFMPEG_VERSION.tar.xz"
  download_verified "https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.gz" \
    "$ZLIB_SHA256" "$src/zlib-$ZLIB_VERSION.tar.gz"

  work=$(mktemp -d "$WIN_CACHE/ffmpeg-build.XXXXXX")
  # 실패·중단해도 작업 폴더가 캐시에 남지 않게 한다.
  trap 'rm -rf "$work"' EXIT
  stage="$work/stage"
  mkdir -p "$stage/include" "$stage/lib"

  log "zlib $ZLIB_VERSION ($TRIPLE)"
  tar -xzf "$src/zlib-$ZLIB_VERSION.tar.gz" -C "$work"
  (
    cd "$work/zlib-$ZLIB_VERSION"
    make -f win32/Makefile.gcc CC="$TRIPLE-clang" AR="$TRIPLE-ar" RC="$TRIPLE-windres" STRIP="$TRIPLE-strip" \
      CFLAGS="-O2 -w" libz.a >/dev/null
    cp libz.a "$stage/lib/"
    cp zlib.h zconf.h "$stage/include/"
  )

  log "libmp3lame $LAME_VERSION ($TRIPLE)"
  tar -xzf "$src/lame-$LAME_VERSION.tar.gz" -C "$work"
  (
    cd "$work/lame-$LAME_VERSION"
    # 3.100의 config.sub(2017)는 aarch64-w64-mingw32를 모를 수 있어 시스템의 최신 파일로 바꾼다.
    for f in config.sub config.guess; do
      [[ -f /usr/share/misc/$f ]] && cp "/usr/share/misc/$f" "$f"
    done
    # 3.100의 심볼 목록에 실제로 없는 lame_init_old가 있다(Mac 빌드와 같은 처리).
    sed -i '/^lame_init_old$/d' include/libmp3lame.sym
    # AR·RANLIB도 툴체인 것을 쓴다(시스템 ar은 ARM64 Windows 오브젝트의 색인을 못 만들어 링커가 라이브러리를 무시한다).
    CC="$TRIPLE-clang" AR="$TRIPLE-ar" RANLIB="$TRIPLE-ranlib" CFLAGS="-O2 -w" \
      ./configure --prefix="$stage" --host="$TRIPLE" \
      --disable-shared --enable-static --disable-frontend --disable-decoder \
      --disable-dependency-tracking >/dev/null
    make -j"$JOBS" >/dev/null
    make install >/dev/null
  )

  check_lib "$stage/lib/libmp3lame.a"
  check_lib "$stage/lib/libz.a"
  # LAME·zlib을 툴체인의 대상별 기본 경로(<툴체인>/<트리플>/lib·include)에 넣는다. 컴파일러가 항상 찾는 곳이라
  # configure에 경로를 넘기지 않아도 된다(넘기면 -buildconf로 실행 파일에 빌드 경로가 남는다).
  # 환경 변수(LIBRARY_PATH)는 Linux 툴체인의 ARM64 대상에서 적용되지 않았다.
  local sysroot="$bin/../$TRIPLE"
  cp "$stage/lib/libmp3lame.a" "$stage/lib/libz.a" "$sysroot/lib/"
  mkdir -p "$sysroot/include/lame"
  cp "$stage/include/lame/lame.h" "$sysroot/include/lame/"
  cp "$stage/include/zlib.h" "$stage/include/zconf.h" "$sysroot/include/"

  log "ffmpeg $FFMPEG_VERSION ($TRIPLE)"
  tar -xJf "$src/ffmpeg-$FFMPEG_VERSION.tar.xz" -C "$work"
  local config=(
    --target-os=mingw32 --arch="$ARCH" --enable-cross-compile
    --cross-prefix="$TRIPLE-" --cc="$TRIPLE-clang"
    --extra-ldflags=-static
    --pkg-config=false
    --disable-autodetect --disable-everything
    --enable-w32threads
    --disable-doc --disable-ffplay --disable-network --disable-avdevice --disable-debug
    --enable-static --disable-shared
    --enable-zlib
    --enable-libmp3lame
    --enable-protocol=file,pipe
    # 아래 목록은 Mac scripts/build-ffmpeg.sh와 같게 유지한다.
    --enable-demuxer=mov,matroska,ogg,mp3,aac,flac,wav,mpegts,ffmetadata
    --enable-muxer=mp3,wav,flac,mp4,ipod,mov,matroska,webm,ogg
    --enable-decoder=aac,aac_fixed,aac_latm,opus,vorbis,mp3,mp3float,flac,alac,ac3,eac3,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s32le,pcm_f32le,pcm_u8
    --enable-encoder=libmp3lame,flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le
    --enable-parser=aac,aac_latm,opus,vorbis,flac,mpegaudio,ac3
    --enable-bsf=aac_adtstoasc
    --enable-filter=aresample,aformat,anull,atrim,abuffer,abuffersink,volume
  )
  (
    cd "$work/ffmpeg-$FFMPEG_VERSION"
    ./configure "${config[@]}" >/dev/null \
      || { tail -30 ffbuild/config.log >&2; die "ffmpeg configure 실패"; }
    # GPL·nonfree·version3가 꺼져 있어야 한다.
    for flag in GPL NONFREE VERSION3; do
      grep -q "^#define CONFIG_$flag 0" config.h || die "ffmpeg 구성에 ${flag}가 켜져 있습니다."
    done
    make -j"$JOBS" >/dev/null
    # 결과를 작업 폴더에 다 모은 뒤 한 번에 캐시 위치로 옮긴다(중간에 실패하면 캐시가 생기지 않는다).
    local out="$work/out"
    mkdir -p "$out/licenses"
    # ffmpeg.exe·ffprobe.exe는 심볼을 뺀 실행 파일이다(_g가 붙은 파일은 디버그용).
    cp ffmpeg.exe ffprobe.exe "$out/"
    cp COPYING.LGPLv2.1 "$out/licenses/ffmpeg-COPYING.LGPLv2.1.txt"
    cp LICENSE.md "$out/licenses/ffmpeg-LICENSE.md"
    cp "$work/lame-$LAME_VERSION/COPYING" "$out/licenses/lame-COPYING.txt"
    cp "$work/zlib-$ZLIB_VERSION/LICENSE" "$out/licenses/zlib-LICENSE.txt"
    rm -rf "$PREFIX"
    mv "$out" "$PREFIX"
  )
  rm -rf "$work"
  trap - EXIT
}

verify() {
  local exe=$1 imports bin
  bin=$(toolchain)
  imports=$("$bin/llvm-readobj" --coff-imports "$exe" | sed -n 's/^ *Name: *//p' | sort -u)
  log "$(basename "$exe")가 쓰는 DLL: $(echo "$imports" | tr '\n' ' ')"
  # mingw 런타임(libwinpthread·libc++·libunwind 등)이 동적으로 남으면 앱 폴더에 DLL이 따로 필요하다.
  if grep -qi '^lib' <<<"$imports"; then die "$(basename "$exe")가 mingw 런타임 DLL에 의존합니다."; fi
  local machine
  machine=$("$bin/llvm-readobj" --file-headers "$exe" | sed -n 's/^ *Machine: *//p')
  case $ARCH in
    x86_64) [[ $machine == *AMD64* ]] || die "x64 실행 파일이 아닙니다: $machine" ;;
    aarch64) [[ $machine == *ARM64* ]] || die "ARM64 실행 파일이 아닙니다: $machine" ;;
  esac
}

if [[ -f $PREFIX/ffmpeg.exe && -f $PREFIX/ffprobe.exe && -f $PREFIX/licenses/zlib-LICENSE.txt ]]; then
  log "ffmpeg $FFMPEG_VERSION ($RID): 캐시된 빌드 사용"
else
  build
fi
verify "$PREFIX/ffmpeg.exe"
verify "$PREFIX/ffprobe.exe"

mkdir -p "$DEST/licenses"
cp "$PREFIX/ffmpeg.exe" "$PREFIX/ffprobe.exe" "$DEST/"
cp "$PREFIX"/licenses/* "$DEST/licenses/"
log "ffmpeg $FFMPEG_VERSION ($RID): $DEST"
