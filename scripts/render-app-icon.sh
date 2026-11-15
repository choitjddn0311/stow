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

log "렌더러 컴파일"
swiftc -O -o "$WORK/render-svg" "$REPO_ROOT/scripts/lib/render-svg.swift"

# 포인트 크기, 배율 → 파일 이름과 픽셀 크기
entries=()
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    if [[ $scale == 1 ]]; then
      name="icon_${size}x${size}.png"
    else
      name="icon_${size}x${size}@2x.png"
    fi
    pixels=$((size * scale))
    log "${name} (${pixels}px)"
    "$WORK/render-svg" "$SVG" "$pixels" "$ICONSET/$name"
    entries+=("    { \"filename\" : \"${name}\", \"idiom\" : \"mac\", \"scale\" : \"${scale}x\", \"size\" : \"${size}x${size}\" }")
  done
done

{
  printf '{\n  "images" : [\n'
  last=$((${#entries[@]} - 1))
  for i in "${!entries[@]}"; do
    if [[ $i -lt $last ]]; then
      printf '%s,\n' "${entries[$i]}"
    else
      printf '%s\n' "${entries[$i]}"
    fi
  done
  printf '  ],\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n'
} > "$ICONSET/Contents.json"

log "완료: $ICONSET"
