# Windows 엔진 스크립트 공통 설정과 함수. 각 스크립트에서 source 한다.
# 주의: 메시지에서 변수 바로 뒤에 한글이 오면 ${VAR} 형태로 쓴다(bash가 한글 바이트를 변수 이름으로 읽음).
set -euo pipefail

WIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# 다운로드·빌드 캐시(windows/build/는 git 미포함, CI에서 actions/cache로 보존)
WIN_CACHE="$WIN_ROOT/build/cache"

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# download_verified URL SHA256 DEST — 캐시에 같은 체크섬 파일이 있으면 재사용, 다르면 실패.
download_verified() {
  local url=$1 sha=$2 dest=$3
  if [[ -f $dest && $(sha256_of "$dest") == "$sha" ]]; then return 0; fi
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

# rid(win-x64·win-arm64) → 각 배포물의 아키텍처 이름
arch_for() {
  case $1 in
    win-x64) echo x86_64 ;;
    win-arm64) echo aarch64 ;;
    *) die "알 수 없는 RID: $1 (win-x64 또는 win-arm64)" ;;
  esac
}
