#!/usr/bin/env bash
# 앱 아이콘 원본(design/AppIcon.svg)으로 AppIcon.appiconset의 PNG와 Contents.json을 만든다.
# 원본 SVG를 바꾼 뒤 실행하고, 결과 PNG를 함께 커밋한다(빌드 중에는 실행하지 않는다).
source "$(dirname "$0")/lib/common.sh"

SVG="$REPO_ROOT/design/AppIcon.svg"
ICONSET="$REPO_ROOT/Stow/Assets.xcassets/AppIcon.appiconset"

[[ -f $SVG ]] || die "원본 SVG가 없습니다: $SVG"
[[ -d $ICONSET ]] || die "아이콘 세트 폴더가 없습니다: $ICONSET"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/out"
mkdir "$OUT"

log "렌더러 컴파일"
swiftc -O -o "$WORK/render-svg" "$REPO_ROOT/scripts/lib/render-svg.swift"

# 픽셀 크기마다 한 번만 그린다. 모두 성공한 뒤에만 아이콘 세트로 옮겨, 실패해도 섞이지 않게 한다.
for pixels in 16 32 64 128 256 512 1024; do
  log "${pixels}px"
  "$WORK/render-svg" "$SVG" "$pixels" "$OUT/$pixels.png"
done

# 파일 이름 → 픽셀 크기
place() { cp "$OUT/$2.png" "$WORK/$1"; }
place icon_16x16.png 16
place icon_16x16@2x.png 32
place icon_32x32.png 32
place icon_32x32@2x.png 64
place icon_128x128.png 128
place icon_128x128@2x.png 256
place icon_256x256.png 256
place icon_256x256@2x.png 512
place icon_512x512.png 512
place icon_512x512@2x.png 1024

cat > "$WORK/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

mv -f "$WORK"/icon_*.png "$WORK/Contents.json" "$ICONSET/"
log "완료: $ICONSET"
