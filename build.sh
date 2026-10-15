#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Gota"
BUNDLE_ID="com.vleineker.gota"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications/$APP_NAME.app"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

echo "==> Limpando build anterior"
rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

echo "==> Compilando"
swiftc -parse-as-library -swift-version 5 -O -whole-module-optimization \
  -target arm64-apple-macosx14.0 -sdk "$SDK_PATH" \
  -framework SwiftUI -framework AppKit -framework UserNotifications -framework ServiceManagement \
  Sources/*.swift -o "$APP_DIR/Contents/MacOS/$APP_NAME"

echo "==> Copiando Info.plist"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
plutil -lint "$APP_DIR/Contents/Info.plist"

echo "==> Assinando (ad-hoc)"
codesign --force --sign - "$APP_DIR"

echo "==> Encerrando instância em execução"
pkill -x "$APP_NAME" || true

echo "==> Instalando em $INSTALL_DIR"
mkdir -p "$HOME/Applications"
rm -rf "$INSTALL_DIR"
ditto "$APP_DIR" "$INSTALL_DIR"

echo "==> Atualizando registro do LaunchServices"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_DIR"

echo "==> Abrindo"
open "$INSTALL_DIR"

echo "==> Limpando build/"
rm -rf "$APP_DIR"

echo "==> Pronto: $INSTALL_DIR"
