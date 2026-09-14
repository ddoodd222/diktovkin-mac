#!/bin/zsh
# Собирает Диктовкин.app и ставит в /Applications. Запуск: ./build.sh
# Модель: всё, что лежит в models/ggml-*.bin, попадает внутрь приложения.
# --no-install: только собрать в dist/, установленное приложение не трогать.
set -e
cd "$(dirname "$0")"
INSTALL=1
[ "$1" = "--no-install" ] && INSTALL=0

APP_NAME="Диктовкин"
BUNDLE_ID="ru.tokarev.diktovkin"
EXE="Diktovkin"
VERSION="1.0"
WHISPER_TAG="v1.8.2"
TARGET="arm64-apple-macosx13.0"

W=".build/whisper.cpp"
OBJ=".build/obj"
mkdir -p .build

# 1. Исходники whisper.cpp. Качаются один раз, дальше сборка живёт без сети.
if [ ! -d "$W" ]; then
  echo "→ Беру whisper.cpp $WHISPER_TAG…"
  git clone --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp.git "$W" 2>/dev/null
fi
WHISPER_VER="${WHISPER_TAG#v}"
COMMIT=$(cd "$W" && git rev-parse --short HEAD)

# 2. whisper.cpp + ggml в статическую библиотеку. Без cmake и без brew: только Command Line Tools.
mkdir -p "$OBJ"
INC=(-I"$W/ggml/include" -I"$W/ggml/src" -I"$W/ggml/src/ggml-cpu" -I"$W/include" -I"$W/src")
DEF=(-DNDEBUG -D_DARWIN_C_SOURCE -DGGML_SCHED_MAX_COPIES=4
     "-DGGML_VERSION=\"$WHISPER_VER\"" "-DGGML_COMMIT=\"$COMMIT\"" "-DWHISPER_VERSION=\"$WHISPER_VER\""
     -DGGML_USE_CPU -DGGML_USE_METAL -DGGML_METAL_EMBED_LIBRARY -DGGML_METAL_NDEBUG
     -DGGML_USE_ACCELERATE -DACCELERATE_NEW_LAPACK -DACCELERATE_LAPACK_ILP64 -DGGML_USE_LLAMAFILE)
CFLAGS=(-target "$TARGET" -mcpu=apple-m1 -O3 -w $INC $DEF)

C_SRC=(ggml/src/ggml.c ggml/src/ggml-alloc.c ggml/src/ggml-quants.c
       ggml/src/ggml-cpu/ggml-cpu.c ggml/src/ggml-cpu/quants.c ggml/src/ggml-cpu/arch/arm/quants.c
       ggml/src/ggml-metal/ggml-metal-device.m ggml/src/ggml-metal/ggml-metal-context.m)
CXX_SRC=(ggml/src/ggml.cpp ggml/src/ggml-backend.cpp ggml/src/ggml-backend-reg.cpp ggml/src/ggml-opt.cpp
         ggml/src/ggml-threading.cpp ggml/src/gguf.cpp
         ggml/src/ggml-cpu/ggml-cpu.cpp ggml/src/ggml-cpu/repack.cpp ggml/src/ggml-cpu/hbm.cpp
         ggml/src/ggml-cpu/traits.cpp ggml/src/ggml-cpu/binary-ops.cpp ggml/src/ggml-cpu/unary-ops.cpp
         ggml/src/ggml-cpu/vec.cpp ggml/src/ggml-cpu/ops.cpp ggml/src/ggml-cpu/llamafile/sgemm.cpp
         ggml/src/ggml-cpu/arch/arm/repack.cpp
         ggml/src/ggml-metal/ggml-metal.cpp ggml/src/ggml-metal/ggml-metal-device.cpp
         ggml/src/ggml-metal/ggml-metal-common.cpp ggml/src/ggml-metal/ggml-metal-ops.cpp
         src/whisper.cpp)

# Металлические шейдеры кладём внутрь бинарника: компилятора metal в Command Line Tools нет,
# поэтому ggml собирает их на лету при первом запуске.
MET="$OBJ/ggml-metal-embed.metal"
if [ ! -f "$MET" ] || [ "$W/ggml/src/ggml-metal/ggml-metal.metal" -nt "$MET" ]; then
  sed -e "/__embed_ggml-common.h__/r $W/ggml/src/ggml-common.h" -e "/__embed_ggml-common.h__/d" \
      < "$W/ggml/src/ggml-metal/ggml-metal.metal" > "$OBJ/tmp.metal"
  sed -e "/#include \"ggml-metal-impl.h\"/r $W/ggml/src/ggml-metal/ggml-metal-impl.h" \
      -e "/#include \"ggml-metal-impl.h\"/d" < "$OBJ/tmp.metal" > "$MET"
  print -r -- ".section __DATA,__ggml_metallib
.globl _ggml_metallib_start
_ggml_metallib_start:
.incbin \"$MET\"
.globl _ggml_metallib_end
_ggml_metallib_end:" > "$OBJ/embed.s"
  clang -target "$TARGET" -c "$OBJ/embed.s" -o "$OBJ/embed.o"
fi

compile() {  # компилятор, стандарт, файл
  local out="$OBJ/${3//\//_}.o"
  [ -f "$out" ] && [ "$out" -nt "$W/$3" ] && return 0
  echo "   $3"
  $1 $2 $CFLAGS -c "$W/$3" -o "$out"
}
echo "→ Компилирую whisper.cpp…"
for f in $C_SRC;   do compile clang   -std=c11   $f; done
for f in $CXX_SRC; do compile clang++ -std=c++17 $f; done
libtool -static -o "$OBJ/libwhisper.a" "$OBJ"/*.o 2>/dev/null

# 3. Swift. Обход поломки в Command Line Tools: старый module.modulemap дублирует bridging.modulemap.
STALE=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
FLAGS=()
if [ -f "$STALE" ] && [ -f "${STALE%/*}/bridging.modulemap" ]; then
  : > .build/empty.modulemap
  printf '{ "version": 0, "roots": [ { "name": "%s", "type": "file", "external-contents": "%s/.build/empty.modulemap" } ] }\n' "$STALE" "$PWD" > .build/overlay.yaml
  FLAGS=(-vfsoverlay "$PWD/.build/overlay.yaml")
fi

echo "→ Компилирую приложение…"
BIN=".build/$EXE"
swiftc -O -swift-version 5 -target "$TARGET" "${FLAGS[@]}" \
  -import-objc-header Sources/Bridge/Diktovkin-Bridging.h -Xcc -I"$PWD/$W/include" -Xcc -I"$PWD/$W/ggml/include" \
  -framework AppKit -framework AVFoundation -framework Carbon -framework ServiceManagement \
  -framework Metal -framework MetalKit -framework Foundation -framework Accelerate \
  -Xlinker -force_load -Xlinker "$OBJ/libwhisper.a" -lc++ \
  Sources/Diktovkin/*.swift -o "$BIN"

echo "→ Собираю приложение…"
OUT="dist/$APP_NAME.app"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/$EXE"
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSMicrophoneUsageDescription</key><string>Диктовкин слушает микрофон, пока идёт запись. Звук остаётся на компьютере.</string>
</dict></plist>
PLIST
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
# Модель внутрь бандла: тогда установщик самодостаточен и на первом запуске сеть не нужна.
for m in models/ggml-*.bin(N); do
  echo "   вшиваю ${m:t} ($(du -h "$m" | cut -f1))"
  cp "$m" "$OUT/Contents/Resources/${m:t}"
done
codesign --force --sign - --identifier "$BUNDLE_ID" "$OUT"

if [ "$INSTALL" = "0" ]; then
  echo "✓ Собрано: $OUT"
  exit 0
fi

echo "→ Устанавливаю…"
pkill -x "$EXE" 2>/dev/null || true
sleep 0.5
DEST="/Applications/$APP_NAME.app"
if ! { rm -rf "$DEST" 2>/dev/null && cp -R "$OUT" "$DEST" 2>/dev/null; }; then
  mkdir -p "$HOME/Applications"
  DEST="$HOME/Applications/$APP_NAME.app"
  rm -rf "$DEST"
  cp -R "$OUT" "$DEST"
fi
# Подпись без сертификата меняется при каждой сборке, поэтому macOS забывает права. Сбрасываем, чтобы спросил заново.
tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
tccutil reset Microphone "$BUNDLE_ID" >/dev/null 2>&1 || true
open "$DEST"
echo "✓ Готово: $DEST"
