#!/bin/bash
# Windows 앱에 넣을 엔진(Python·yt-dlp·deno)을 받아 체크섬을 확인하고 엔진 폴더에 둔다.
# ffmpeg/ffprobe는 build-ffmpeg.sh가 같은 폴더에 만든다.
#
#   windows/scripts/fetch-engine.sh <win-x64|win-arm64> [엔진 폴더(기본 windows/engine/<rid>)]
#
# - yt-dlp는 Windows 실행 파일(yt-dlp.exe, PyInstaller 묶음이라 GPLv3+)이 아니라 zipimport 버전을 쓰고,
#   번들 Python으로 실행한다(python.exe -I -B yt-dlp ...). Mac 앱(scripts/fetch-binaries.sh)과 같은 버전·파일이다.
# - 어느 OS에서든 실행할 수 있다(내려받기·압축 풀기만 한다).
source "$(dirname "$0")/lib.sh"

[[ $# -ge 1 && $# -le 2 ]] || die "사용법: windows/scripts/fetch-engine.sh <win-x64|win-arm64> [엔진 폴더]"
RID=$1
ARCH=$(arch_for "$RID")
DEST=${2:-$WIN_ROOT/engine/$RID}

# Mac scripts/fetch-binaries.sh와 같은 버전을 쓴다(올릴 때 둘 다 올린다).
YTDLP_VERSION=2026.10.26
YTDLP_SHA256=e51e69e89489f199530f13d32a4342da3ddb2cf34842f364603a066db05afbf3
YTDLP_LICENSE_SHA256=7e12e5df4bae12cb21581ba157ced20e1986a0508dd10d0e8a4ab9a4cf94e85c
YTDLP_THIRD_PARTY_SHA256=472aefe951c7db35e1657c1d13fd337140511ed6f2b329205105ad441c5a02b7

# python-build-standalone(astral-sh) install_only_stripped. 체크섬은 릴리스의 SHA256SUMS 값.
PYTHON_VERSION=3.13.18
PYTHON_BUILD=20261110
case $ARCH in
  x86_64) PYTHON_SHA256=2e0fed09d48989f64c9305da9ff2d37a41c0d13ab2aa6283405b2b620dfbf805 ;;
  aarch64) PYTHON_SHA256=0a8840071810ddb8565256cd406b466d4e9dc6dc523395a5477880dbc4f67eb3 ;;
esac

DENO_VERSION=2.9.8
case $ARCH in
  x86_64) DENO_SHA256=cba84b26e0df5ae7f74fc66b86a95b866872a86292ebd84fa1e959927edd93bf ;;
  aarch64) DENO_SHA256=b413b92b735b50c198e8fe3b85af1aa50e29d5f72e229aab701d132286e14cef ;;
esac
DENO_LICENSE_SHA256=f62497fffecc0852960c8d3e6934b9db86d16396e9b604072e923892cae3a588

mkdir -p "$DEST/licenses"

log "yt-dlp $YTDLP_VERSION"
yt_base="https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION"
yt_raw="https://raw.githubusercontent.com/yt-dlp/yt-dlp/$YTDLP_VERSION"
yt_cache="$WIN_CACHE/yt-dlp-$YTDLP_VERSION"
download_verified "$yt_base/yt-dlp" "$YTDLP_SHA256" "$yt_cache/yt-dlp"
download_verified "$yt_raw/LICENSE" "$YTDLP_LICENSE_SHA256" "$yt_cache/LICENSE"
download_verified "$yt_raw/THIRD_PARTY_LICENSES.txt" "$YTDLP_THIRD_PARTY_SHA256" "$yt_cache/THIRD_PARTY_LICENSES.txt"
cp "$yt_cache/yt-dlp" "$DEST/yt-dlp"
printf '%s\n' "$YTDLP_VERSION" > "$DEST/yt-dlp.version"
cp "$yt_cache/LICENSE" "$DEST/licenses/yt-dlp-LICENSE.txt"
cp "$yt_cache/THIRD_PARTY_LICENSES.txt" "$DEST/licenses/yt-dlp-THIRD_PARTY_LICENSES.txt"

log "Python $PYTHON_VERSION ($ARCH)"
py_name="cpython-$PYTHON_VERSION+$PYTHON_BUILD-$ARCH-pc-windows-msvc-install_only_stripped.tar.gz"
py_archive="$WIN_CACHE/python/$py_name"
download_verified "https://github.com/astral-sh/python-build-standalone/releases/download/$PYTHON_BUILD/${py_name//+/%2B}" \
  "$PYTHON_SHA256" "$py_archive"
rm -rf "$DEST/python"
tar -xzf "$py_archive" -C "$DEST"   # python/ 폴더로 풀린다
[[ -f $DEST/python/python.exe ]] || die "python.exe가 없습니다: $DEST/python"
cp "$DEST/python/LICENSE.txt" "$DEST/licenses/python-LICENSE.txt"
# yt-dlp 실행에 필요 없는 것을 뺀다(Mac과 같은 기준): 헤더·링크용 라이브러리, Tcl/Tk, 테스트·IDLE·ensurepip, 추가 패키지.
py="$DEST/python"
rm -rf "$py/include" "$py/libs" "$py/tcl" "$py/Scripts" \
  "$py"/Lib/{test,idlelib,tkinter,turtledemo,ensurepip} "$py"/Lib/site-packages/* \
  "$py"/DLLs/_tkinter.pyd "$py"/DLLs/tcl*.dll "$py"/DLLs/tk*.dll
# 표준 라이브러리를 미리 컴파일해 둔다(yt-dlp는 -B로 실행해 .pyc를 쓰지 않으므로, 없으면 실행할 때마다 컴파일한다).
# .pyc는 같은 마이너 버전(3.13)이면 OS·아키텍처와 무관하다. PYC_PYTHON(예: python3.13)이 없으면 건너뛴다.
if [[ -n ${PYC_PYTHON:-} ]]; then
  [[ $("$PYC_PYTHON" -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")') == "${PYTHON_VERSION%.*}" ]] \
    || die "PYC_PYTHON의 버전이 ${PYTHON_VERSION%.*}가 아닙니다."
  log "표준 라이브러리 미리 컴파일"
  "$PYC_PYTHON" -I -B -m compileall -q -f -j0 --invalidation-mode unchecked-hash -s "$py" -p "" "$py/Lib" >/dev/null
else
  log "주의: PYC_PYTHON이 없어 표준 라이브러리를 미리 컴파일하지 않습니다(실행이 느려짐)."
fi

log "deno $DENO_VERSION ($ARCH)"
deno_cache="$WIN_CACHE/deno-$DENO_VERSION"
download_verified "https://github.com/denoland/deno/releases/download/v$DENO_VERSION/deno-$ARCH-pc-windows-msvc.zip" \
  "$DENO_SHA256" "$deno_cache/deno-$ARCH.zip"
download_verified "https://raw.githubusercontent.com/denoland/deno/v$DENO_VERSION/LICENSE.md" \
  "$DENO_LICENSE_SHA256" "$deno_cache/LICENSE.md"
rm -f "$DEST/deno.exe"
unzip -q -o "$deno_cache/deno-$ARCH.zip" deno.exe -d "$DEST"
cp "$deno_cache/LICENSE.md" "$DEST/licenses/deno-LICENSE.md"

log "엔진(Python·yt-dlp·deno): $DEST"
