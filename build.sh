#!/bin/bash
# Compila iDeck y monta el .app en dist/
set -euo pipefail

cd "$(dirname "$0")"
APP="dist/iDeck.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/iDeck "$APP/Contents/MacOS/iDeck"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Sources/iDeck/Web "$APP/Contents/Resources/web"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# macOS ata los permisos (Accesibilidad) a la identidad de firma. Con firma
# ad-hoc el hash cambia en cada compilación y hay que reconceder el permiso
# cada vez; con un certificado real la identidad se mantiene.
IDENTITY=$(security find-identity -v -p codesigning \
  | grep -m1 "Apple Development" \
  | sed -E 's/.*\) ([A-F0-9]{40}) .*/\1/')

if [ -n "$IDENTITY" ]; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
  echo "Firmado con Apple Development ($IDENTITY)"
else
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
  echo "Sin certificado: firma ad-hoc (habrá que reconceder permisos en cada build)"
fi

echo "Listo: $APP"

# ./build.sh --install lo deja en /Applications, que es donde Spotlight y
# Launchpad buscan. Si no, queda solo dentro del proyecto.
if [ "${1:-}" = "--install" ]; then
  pkill -f "/Applications/iDeck.app/Contents/MacOS/iDeck" 2>/dev/null || true
  pkill -f "$PWD/dist/iDeck.app/Contents/MacOS/iDeck" 2>/dev/null || true
  rm -rf /Applications/iDeck.app
  ditto "$APP" /Applications/iDeck.app
  echo "Instalado en /Applications/iDeck.app"
  echo "Ábrelo con:  open -a iDeck"
else
  echo "Ábrelo con:  open $APP"
  echo "Instálalo con: ./build.sh --install"
fi
