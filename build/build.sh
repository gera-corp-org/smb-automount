#!/bin/bash
#
# Сборка smb-automount: из src/ собирает готовые приложения и CLI-установщик
# в dist/. Запускать можно откуда угодно.
#
#   bash build/build.sh
#
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/src"
DIST="$ROOT/dist"

APP_NAME="Сетевая папка"
LOG_APP_NAME="Журнал сетевой папки"

# Подставляет содержимое файла вместо строки-маркера.
# sed/awk с многострочной вставкой капризны, поэтому берём python3 —
# он есть и в macOS, и в любой сборочной среде.
expand() { # файл-шаблон маркер файл-вставки
  python3 - "$1" "$2" "$3" <<'PY'
import sys, pathlib
tpl, marker, part = sys.argv[1], sys.argv[2], sys.argv[3]
text = pathlib.Path(tpl).read_text()
piece = pathlib.Path(part).read_text().rstrip('\n')
line = '# ' + marker
if line not in text:
    sys.exit('маркер %s не найден в %s' % (marker, tpl))
sys.stdout.write(text.replace(line, piece))
PY
}

# Собирает бандл .app вокруг готового исполняемого скрипта.
make_app() { # имя-приложения исполняемый-файл идентификатор имя-внутри-MacOS
  local name="$1" exe="$2" ident="$3" binname="$4"
  local app="$DIST/$name.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$exe" "$app/Contents/MacOS/$binname"
  chmod 755 "$app/Contents/MacOS/$binname"
  printf 'APPL????' > "$app/Contents/PkgInfo"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>ru</string>
    <key>CFBundleExecutable</key><string>$binname</string>
    <key>CFBundleIdentifier</key><string>$ident</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$name</string>
    <key>CFBundleDisplayName</key><string>$name</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleSignature</key><string>????</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>10.13</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST
}

rm -rf "$DIST"
mkdir -p "$DIST/tmp"

# 1. Рабочий скрипт: общие функции + тело воркера.
expand "$SRC/worker.sh" '@@COMMON@@' "$SRC/lib/common.sh" > "$DIST/tmp/worker.sh"

# 2. Фронтенды: общие функции + встроенный воркер.
expand "$SRC/app.sh"         '@@COMMON@@' "$SRC/lib/common.sh" > "$DIST/tmp/app.stage1"
expand "$DIST/tmp/app.stage1" '@@WORKER@@' "$DIST/tmp/worker.sh" > "$DIST/tmp/app.sh"

expand "$SRC/cli-install.sh"  '@@COMMON@@' "$SRC/lib/common.sh" > "$DIST/tmp/cli.stage1"
expand "$DIST/tmp/cli.stage1" '@@WORKER@@' "$DIST/tmp/worker.sh" > "$DIST/smb-automount-install.sh"
chmod 755 "$DIST/smb-automount-install.sh"

# 3. Проверка синтаксиса до упаковки.
for f in "$DIST/tmp/worker.sh" "$DIST/tmp/app.sh" "$DIST/smb-automount-install.sh" "$SRC/log-app.sh"; do
  bash -n "$f" || { echo "СБОЙ: синтаксическая ошибка в $f" >&2; exit 1; }
done

# 4. Проверка совместимости с bash 3.2 — системным на macOS.
bash "$ROOT/tests/check-bash32.sh" "$DIST/tmp/app.sh" "$DIST/tmp/worker.sh" "$DIST/smb-automount-install.sh"

# 5. Бандлы и архивы.
make_app "$APP_NAME"     "$DIST/tmp/app.sh"    'com.user.smb-automount.setup' 'smb-automount'
make_app "$LOG_APP_NAME" "$SRC/log-app.sh"     'com.user.smb-automount.log'   'smb-log'

( cd "$DIST" && zip -qry "$APP_NAME.app.zip"     "$APP_NAME.app" )
( cd "$DIST" && zip -qry "$LOG_APP_NAME.app.zip" "$LOG_APP_NAME.app" )

rm -rf "$DIST/tmp"

echo "готово, всё в $DIST:"
ls -1 "$DIST"
