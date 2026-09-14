#!/bin/zsh
# Делает Resources/AppIcon.icns из квадратного PNG. Запуск: ./make-icon.sh картинка.png
# По умолчанию обрезает по скруглённому квадрату macOS. --raw — оставить как есть.
set -e
cd "$(dirname "$0")"
SRC="${1:-Resources/AppIcon.png}"
[ -f "$SRC" ] || { echo "Нет файла: $SRC"; exit 1; }
mkdir -p .build

if [ "$2" != "--raw" ]; then
  # Обход поломки в Command Line Tools: старый module.modulemap дублирует bridging.modulemap.
  STALE=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
  FLAGS=()
  if [ -f "$STALE" ] && [ -f "${STALE%/*}/bridging.modulemap" ]; then
    : > .build/empty.modulemap
    printf '{ "version": 0, "roots": [ { "name": "%s", "type": "file", "external-contents": "%s/.build/empty.modulemap" } ] }\n' "$STALE" "$PWD" > .build/overlay.yaml
    FLAGS=(-vfsoverlay "$PWD/.build/overlay.yaml")
  fi
  if [ ! -x .build/squircle ] || [ Sources/Tools/Squircle.swift -nt .build/squircle ]; then
    swiftc -O -swift-version 5 "${FLAGS[@]}" Sources/Tools/Squircle.swift -o .build/squircle
  fi
  .build/squircle "$SRC" .build/masked.png >/dev/null
  SRC=.build/masked.png
fi

IS=".build/AppIcon.iconset"
rm -rf "$IS"; mkdir -p "$IS"
for s in 16 32 128 256 512; do
  sips -Z $s "$SRC" --out "$IS/icon_${s}x${s}.png" >/dev/null
  sips -Z $((s * 2)) "$SRC" --out "$IS/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$IS" -o Resources/AppIcon.icns
cp "$SRC" Resources/AppIcon.png
echo "✓ Resources/AppIcon.icns — дальше ./build.sh"
