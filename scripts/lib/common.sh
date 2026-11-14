# 엔진 스크립트 공통 설정과 함수. 각 스크립트에서 source 해서 사용한다.
set -euo pipefail

# pwd -P: 대소문자까지 실제 경로로 맞춘다(macOS 파일 시스템은 대소문자를 구분하지 않아 경로 비교가 어긋날 수 있음).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# 앱 번들(Contents/Resources/bin)에 복사할 엔진 파일 위치(git 미포함).
# Stow/ 폴더 동기화 그룹 밖에 둔다. 안에 두면 Xcode가 모든 파일을 Resources/에 평탄화해 복사한다.
BIN_DIR="$REPO_ROOT/engine"
# 설치된 구성 요소별 버전 기록. embed-engine.sh가 변경 여부 판단에 사용한다.
VERSIONS_DIR="$BIN_DIR/.versions"
LICENSES_DIR="$BIN_DIR/licenses"
# 다운로드·빌드 캐시(build/는 git 미포함, CI에서 actions/cache로 보존)
CACHE_DIR="$REPO_ROOT/build/engine-cache"

MACOS_MIN=14.0

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# download_verified URL SHA256 DEST
# 캐시에 같은 체크섬의 파일이 있으면 재사용하고, 새로 받은 파일의 체크섬이 다르면 실패한다.
download_verified() {
  local url=$1 sha=$2 dest=$3
  if [[ -f $dest && $(sha256_of "$dest") == "$sha" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  log "다운로드: $url"
  curl --fail --location --silent --show-error --retry 3 -o "$dest.part" "$url"
  local actual
  actual=$(sha256_of "$dest.part")
  if [[ $actual != "$sha" ]]; then
    rm -f "$dest.part"
    die "체크섬 불일치: $url (기대 $sha, 실제 $actual)"
  fi
  mv "$dest.part" "$dest"
}

# is_current NAME STAMP: 같은 구성으로 이미 설치되어 있으면 성공
is_current() {
  [[ -f $VERSIONS_DIR/$1 && $(cat "$VERSIONS_DIR/$1") == "$2" ]]
}

# mark_current NAME STAMP
mark_current() {
  mkdir -p "$VERSIONS_DIR"
  printf '%s\n' "$2" > "$VERSIONS_DIR/$1"
}
