#!/bin/bash
#
# smb-automount build: turns src/ into ready-to-use apps and a CLI installer
# in dist/. Can be run from anywhere.
#
#   bash build/build.sh
#
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/src"
DIST="$ROOT/dist"

APP_NAME="Network Folder"
LOG_APP_NAME="Network Folder Log"

# Substitutes the contents of a file for a marker line.
# sed/awk are finicky with multi-line insertions, so python3 does it — it is
# present on macOS and in any build environment.
expand() { # template-file marker insert-file
  python3 - "$1" "$2" "$3" <<'PY'
import sys, pathlib
tpl, marker, part = sys.argv[1], sys.argv[2], sys.argv[3]
text = pathlib.Path(tpl).read_text()
piece = pathlib.Path(part).read_text().rstrip('\n')
line = '# ' + marker
if line not in text:
    sys.exit('marker %s not found in %s' % (marker, tpl))
sys.stdout.write(text.replace(line, piece))
PY
}

# Builds an .app bundle around a ready executable script.
make_app() { # app-name executable identifier name-inside-MacOS
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
    <key>CFBundleDevelopmentRegion</key><string>en</string>
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

# 1. Worker script: shared functions + the worker body.
expand "$SRC/worker.sh" '@@COMMON@@' "$SRC/lib/common.sh" > "$DIST/tmp/worker.sh"

# 2. Frontends: shared functions + the embedded worker.
expand "$SRC/app.sh"         '@@COMMON@@' "$SRC/lib/common.sh" > "$DIST/tmp/app.stage1"
expand "$DIST/tmp/app.stage1" '@@WORKER@@' "$DIST/tmp/worker.sh" > "$DIST/tmp/app.sh"

expand "$SRC/cli-install.sh"  '@@COMMON@@' "$SRC/lib/common.sh" > "$DIST/tmp/cli.stage1"
expand "$DIST/tmp/cli.stage1" '@@WORKER@@' "$DIST/tmp/worker.sh" > "$DIST/smb-automount-install.sh"
chmod 755 "$DIST/smb-automount-install.sh"

# 3. Syntax check before packaging.
for f in "$DIST/tmp/worker.sh" "$DIST/tmp/app.sh" "$DIST/smb-automount-install.sh" "$SRC/log-app.sh"; do
  bash -n "$f" || { echo "FAIL: syntax error in $f" >&2; exit 1; }
done

# 4. Compatibility check against bash 3.2 — the system bash on macOS.
bash "$ROOT/tests/check-bash32.sh" "$DIST/tmp/app.sh" "$DIST/tmp/worker.sh" "$DIST/smb-automount-install.sh"

# 5. Bundles and archives.
make_app "$APP_NAME"     "$DIST/tmp/app.sh"    'com.user.smb-automount.setup' 'smb-automount'
make_app "$LOG_APP_NAME" "$SRC/log-app.sh"     'com.user.smb-automount.log'   'smb-log'

( cd "$DIST" && zip -qry "$APP_NAME.app.zip"     "$APP_NAME.app" )
( cd "$DIST" && zip -qry "$LOG_APP_NAME.app.zip" "$LOG_APP_NAME.app" )

rm -rf "$DIST/tmp"

echo "done, everything is in $DIST:"
ls -1 "$DIST"
