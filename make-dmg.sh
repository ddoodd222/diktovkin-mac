#!/bin/zsh
# Собирает dist/Диктовкин-<версия>.dmg с фоном и раскладкой окна. Запуск: ./make-dmg.sh (сначала ./build.sh)
set -e
cd "$(dirname "$0")"
APP_NAME="Диктовкин"
APP="dist/$APP_NAME.app"
[ -d "$APP" ] || { echo "Сначала ./build.sh"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE="dist/dmg"
RW="dist/rw.dmg"
DMG="dist/$APP_NAME-$VERSION.dmg"
VOL="/Volumes/$APP_NAME"

# Модель могла уехать внутрь приложения — тогда интернет на первом запуске не нужен.
if ls "$APP/Contents/Resources/"ggml-*.bin >/dev/null 2>&1; then
  MODEL_STEP="3. Модель распознавания уже внутри. Интернет не нужен вообще."
else
  MODEL_STEP="3. Первый запуск скачает модель, 190 МБ. Нужен интернет, один раз."
fi

rm -rf "$STAGE" "$RW" "$DMG"; mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Программы"
cp Resources/dmg-bg.tiff "$STAGE/.background/bg.tiff"
cat > "$STAGE/Как установить.txt" <<TXT
Диктовкин $VERSION — голосовой ввод. Говоришь, а он печатает за тебя.
Распознавание идёт прямо на компьютере, звук никуда не уходит.

1. Перетащи «Диктовкин» в папку «Программы».
2. Запусти. macOS скажет, что не может проверить приложение — это нормально,
   у него нет подписи Apple. Закрой окно и открой:
   Системные настройки → Конфиденциальность и безопасность → внизу «Всё равно открыть».
$MODEL_STEP
4. Разреши два доступа, когда спросит:
   • «Микрофон» — иначе нечего слушать;
   • «Универсальный доступ» — иначе он не сможет вставить текст за тебя.

Как пользоваться:
• Нажми ⌃⌥Пробел — пошла запись, иконка в строке меню краснеет.
• Скажи фразу и нажми ⌃⌥Пробел ещё раз. Текст встанет туда, где стоял курсор.
• Модель, язык и горячую клавишу меняешь в меню по клику на иконку.
TXT

# 1) образ с правом записи, чтобы Finder мог сохранить раскладку окна
[ -d "$VOL" ] && hdiutil detach "$VOL" -quiet || true
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$RW" >/dev/null
hdiutil attach "$RW" -readwrite -noverify -noautoopen >/dev/null
sleep 1

# 2) раскладка окна: фон, размер, позиции иконок
osascript <<AS
tell application "Finder"
  tell disk "$APP_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 12
    set background picture of opts to file ".background:bg.tiff"
    set position of item "$APP_NAME.app" of container window to {170, 210}
    set position of item "Программы" of container window to {490, 210}
    set position of item "Как установить.txt" of container window to {590, 280}
    -- скрытые служебные элементы уводим за пределы окна: у части людей включён показ скрытых файлов
    repeat with n in {".background", ".fseventsd", ".Trashes", ".DS_Store", ".VolumeIcon.icns"}
      try
        set position of item (n as string) of container window to {1200, 900}
      end try
    end repeat
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
AS
sync
hdiutil detach "$VOL" -quiet
sleep 1

# 3) сжатый образ только для чтения
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -rf "$STAGE" "$RW"
echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
