#!/bin/bash
# 소개 웹페이지(GitHub Pages)를 한 폴더로 모은다. site/ 내용에 README와 같은 스크린샷(docs/images)을 images/로 더한다.
# 스크린샷을 한 곳(docs/images)에만 두려고 배포 때 복사한다. Pages 워크플로와 로컬 미리보기가 함께 쓴다.
#
#   scripts/build-site.sh [폴더]      # 기본 build/site
#   python3 -m http.server -d build/site 8000   # 로컬 미리보기
source "$(dirname "$0")/lib/common.sh"

[[ $# -le 1 ]] || die "사용법: scripts/build-site.sh [폴더]"
out=${1:-$REPO_ROOT/build/site}
[[ -f $REPO_ROOT/site/index.html && -f $REPO_ROOT/site/en/index.html ]] || die "site/index.html·site/en/index.html이 없습니다."

# 지울 폴더가 저장소 안이면 build/ 아래만 허용한다(site/·저장소 전체를 지우지 않도록).
mkdir -p "$out"
out=$(cd "$out" && pwd -P)
if [[ $out == "$REPO_ROOT" || $out == "$REPO_ROOT"/* ]] && [[ $out != "$REPO_ROOT"/build/* ]]; then
  die "저장소 안에서는 build/ 아래 폴더만 쓸 수 있습니다: $out"
fi
rm -rf "$out"
mkdir -p "$out/images"
cp -R "$REPO_ROOT/site/." "$out/"
for name in icon main-light main-dark panel-light panel-dark playlist-light; do
  [[ -f $REPO_ROOT/docs/images/$name.png ]] || die "docs/images/$name.png가 없습니다."
  cp "$REPO_ROOT/docs/images/$name.png" "$out/images/"
done
touch "$out/.nojekyll"
echo "웹페이지: $out"
