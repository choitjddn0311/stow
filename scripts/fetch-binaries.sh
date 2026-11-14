#!/bin/bash
# yt-dlp(zipimport 버전), Python 런타임, deno를 고정 버전·체크섬으로 받아 engine/에 둔다.
#
# - yt-dlp 공식 macOS 단독 실행 파일(yt-dlp_macos)은 GPLv3+ 코드를 포함하므로 쓰지 않는다.
#   대신 Unlicense(+MIT/ISC) 코드만 담긴 zipimport 버전을 번들한 Python으로 실행한다.
# - deno: 유튜브 전체 지원에 필요한 JavaScript 런타임(yt-dlp-ejs 실행용, MIT).
# 버전을 올릴 때는 버전과 SHA256을 함께 바꾼다.
source "$(dirname "$0")/lib/common.sh"

YTDLP_VERSION=2026.10.26
YTDLP_SHA256=e51e69e89489f199530f13d32a4342da3ddb2cf34842f364603a066db05afbf3
YTDLP_LICENSE_SHA256=7e12e5df4bae12cb21581ba157ced20e1986a0508dd10d0e8a4ab9a4cf94e85c
YTDLP_THIRD_PARTY_SHA256=472aefe951c7db35e1657c1d13fd337140511ed6f2b329205105ad441c5a02b7

# python-build-standalone (astral-sh), install_only_stripped 빌드
PYTHON_VERSION=3.13.18
PYTHON_BUILD=20261110
PYTHON_SHA256=7a2384641584ab9984221fcb0fc9265df465922af71be71410529e2a9c3f0540

DENO_VERSION=2.9.8
DENO_SHA256=9f0bf660393da2eaff044cdc7444cb08c73f235849b61d224d825a194ce7c98e
DENO_LICENSE_SHA256=f62497fffecc0852960c8d3e6934b9db86d16396e9b604072e923892cae3a588

[[ $(uname -m) == arm64 ]] || die "Apple Silicon(arm64)에서만 실행할 수 있습니다."

install_ytdlp() {
  local stamp="$YTDLP_VERSION $YTDLP_SHA256"
  # 앱이 번들 yt-dlp 버전을 Python 실행 없이 알 수 있게 한다(앱 안 엔진 업데이트의 비교 기준).
  mkdir -p "$BIN_DIR"
  printf '%s\n' "$YTDLP_VERSION" > "$BIN_DIR/yt-dlp.version"
  if is_current yt-dlp "$stamp"; then log "yt-dlp $YTDLP_VERSION: 이미 설치됨"; return; fi

  local base="https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION"
  local raw="https://raw.githubusercontent.com/yt-dlp/yt-dlp/$YTDLP_VERSION"
  local cache="$CACHE_DIR/yt-dlp-$YTDLP_VERSION"
  download_verified "$base/yt-dlp" "$YTDLP_SHA256" "$cache/yt-dlp"
  download_verified "$raw/LICENSE" "$YTDLP_LICENSE_SHA256" "$cache/LICENSE"
  download_verified "$raw/THIRD_PARTY_LICENSES.txt" "$YTDLP_THIRD_PARTY_SHA256" "$cache/THIRD_PARTY_LICENSES.txt"

  mkdir -p "$BIN_DIR" "$LICENSES_DIR"
  install -m 644 "$cache/yt-dlp" "$BIN_DIR/yt-dlp"
  install -m 644 "$cache/LICENSE" "$LICENSES_DIR/yt-dlp-LICENSE.txt"
  install -m 644 "$cache/THIRD_PARTY_LICENSES.txt" "$LICENSES_DIR/yt-dlp-THIRD_PARTY_LICENSES.txt"
  mark_current yt-dlp "$stamp"
  log "yt-dlp $YTDLP_VERSION 설치 완료"
}

install_python() {
  local stamp="$PYTHON_VERSION+$PYTHON_BUILD $PYTHON_SHA256"
  if is_current python "$stamp"; then log "Python $PYTHON_VERSION: 이미 설치됨"; return; fi

  local name="cpython-$PYTHON_VERSION+$PYTHON_BUILD-aarch64-apple-darwin-install_only_stripped.tar.gz"
  local url="https://github.com/astral-sh/python-build-standalone/releases/download/$PYTHON_BUILD/${name//+/%2B}"
  local archive="$CACHE_DIR/$name"
  download_verified "$url" "$PYTHON_SHA256" "$archive"

  local work
  work=$(mktemp -d "$CACHE_DIR/python.XXXXXX")
  tar -xzf "$archive" -C "$work"
  local py="$work/python"
  local minor="${PYTHON_VERSION%.*}"
  local stdlib="$py/lib/python$minor"

  # yt-dlp 실행에 필요 없는 구성 요소를 뺀다(GUI, 개발 도구, 테스트, pip).
  # _dbm은 GNU gdbm(GPLv3)을 정적으로 포함하므로 반드시 뺀다(GPL 구성 요소 미포함 규칙).
  find "$py/bin" -mindepth 1 ! -name "python$minor" -delete
  ln -s "python$minor" "$py/bin/python3"
  rm -rf "$py/include" "$py/share" "$py/lib/pkgconfig" \
    "$py"/lib/itcl* "$py"/lib/tcl* "$py"/lib/tk* "$py"/lib/thread* "$py"/lib/libtcl* \
    "$py/lib/libpython$minor.dylib" \
    "$stdlib"/{test,idlelib,tkinter,turtledemo,ensurepip,"config-$minor-darwin"} \
    "$stdlib"/site-packages/* "$stdlib"/lib-dynload/_tkinter* "$stdlib"/lib-dynload/_dbm* "$stdlib"/lib-dynload/_gdbm*
  # 표준 라이브러리를 미리 컴파일한다. 실행 시에는 -B로 번들 안에 .pyc를 쓰지 않으므로(서명 보존)
  # 미리 만들어 두지 않으면 매번 컴파일한다. unchecked-hash는 파일 시각이 바뀌어도 유효하다.
  # -s: .pyc에 기록되는 소스 경로에서 로컬 작업 경로를 뺀다(배포 파일에 사용자 경로가 남지 않게).
  # -B -f: 시작 시 import로 경로가 든 .pyc가 먼저 생기지 않게 하고, 모두 새로 컴파일한다.
  "$py/bin/python3" -I -B -m compileall -q -f -j0 --invalidation-mode unchecked-hash -s "$work" "$stdlib" >/dev/null

  # GPL 라이브러리(GNU gdbm, GNU readline)가 남아 있지 않은지 확인한다.
  "$py/bin/python3" -I -B -c "
'''GPL 구성 요소 검사'''
import importlib.util, readline, sys
for name in ('_dbm', '_gdbm'):
    if importlib.util.find_spec(name) is not None:
        sys.exit(f'{name} 모듈이 남아 있습니다(GNU gdbm, GPL)')
if 'GNU readline' in readline._READLINE_LIBRARY_VERSION or getattr(readline, 'backend', '') != 'editline':
    sys.exit('readline이 GNU readline(GPL)에 링크되어 있습니다')
" || die "Python 런타임에 GPL 구성 요소가 있습니다."

  mkdir -p "$BIN_DIR" "$LICENSES_DIR"
  install -m 644 "$stdlib/LICENSE.txt" "$LICENSES_DIR/python-LICENSE.txt"
  rm -rf "$BIN_DIR/python"
  mv "$py" "$BIN_DIR/python"
  rm -rf "$work"
  mark_current python "$stamp"
  log "Python $PYTHON_VERSION 설치 완료"
}

install_deno() {
  local stamp="$DENO_VERSION $DENO_SHA256"
  if is_current deno "$stamp"; then log "deno $DENO_VERSION: 이미 설치됨"; return; fi

  local cache="$CACHE_DIR/deno-$DENO_VERSION"
  download_verified "https://github.com/denoland/deno/releases/download/v$DENO_VERSION/deno-aarch64-apple-darwin.zip" \
    "$DENO_SHA256" "$cache/deno.zip"
  download_verified "https://raw.githubusercontent.com/denoland/deno/v$DENO_VERSION/LICENSE.md" \
    "$DENO_LICENSE_SHA256" "$cache/LICENSE.md"

  mkdir -p "$BIN_DIR" "$LICENSES_DIR"
  rm -f "$BIN_DIR/deno"
  unzip -q -o "$cache/deno.zip" deno -d "$BIN_DIR"
  chmod 755 "$BIN_DIR/deno"
  install -m 644 "$cache/LICENSE.md" "$LICENSES_DIR/deno-LICENSE.md"
  mark_current deno "$stamp"
  log "deno $DENO_VERSION 설치 완료"
}

install_ytdlp
install_python
install_deno

# 배포 파일에 로컬 경로가 남지 않았는지 확인한다(대소문자 무시).
# pipefail에서 grep -q로 파이프를 일찍 닫으면 검사가 무시될 수 있어 결과를 변수로 받는다.
leaked=$(grep -rlaiF -- "$REPO_ROOT" "$BIN_DIR" || true)
[[ -z $leaked ]] || die "엔진 파일에 로컬 경로가 남아 있습니다:$(printf "\n%s" "$leaked" | head -4)"
