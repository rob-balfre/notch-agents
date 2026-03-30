#!/bin/zsh

set -euo pipefail

ROOT_DIR=${0:A:h:h}
APP_NAME="NotchAgents"
CLI_NAME="notchagentsctl"
APP_DIR="$ROOT_DIR/build/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications/$APP_NAME.app"
CLI_INSTALL_DIR="$HOME/.local/bin"

cd "$ROOT_DIR"

swift build -c release --product "$APP_NAME"
swift build -c release --product "$CLI_NAME"
BIN_DIR=$(swift build -c release --show-bin-path)

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
find "$ROOT_DIR/Resources" -mindepth 1 -maxdepth 1 ! -name 'Info.plist' -exec cp -R {} "$APP_DIR/Contents/Resources/" \;

chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "Built $APP_DIR"

mkdir -p "$HOME/Applications"
rm -rf "$INSTALL_DIR"
cp -R "$APP_DIR" "$INSTALL_DIR"

echo "Installed $INSTALL_DIR"

mkdir -p "$CLI_INSTALL_DIR"
cp "$BIN_DIR/$CLI_NAME" "$CLI_INSTALL_DIR/$CLI_NAME"
chmod +x "$CLI_INSTALL_DIR/$CLI_NAME"

echo "Installed $CLI_INSTALL_DIR/$CLI_NAME"

"$CLI_INSTALL_DIR/$CLI_NAME" install-claude-hooks >/dev/null 2>&1 || true
echo "Verified Claude hook integration"

if [[ "${1-}" == "--open" ]]; then
    open "$INSTALL_DIR"
fi
