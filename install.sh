#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_SUPPORT="$HOME/Library/Application Support/Snack Record"
RUNTIME_DIR="$APP_SUPPORT/Runtime"
MODELS_DIR="$APP_SUPPORT/Models"
VENV_DIR="$RUNTIME_DIR/venv"
INSTALL_DIR="${SNACK_RECORD_INSTALL_DIR:-$HOME/Applications}"
DEST_APP="$INSTALL_DIR/Snack Record.app"

command -v xcrun >/dev/null || { echo "Install Xcode Command Line Tools first: xcode-select --install"; exit 1; }
command -v python3 >/dev/null || { echo "Python 3 is required."; exit 1; }
command -v security >/dev/null || { echo "The macOS security command is required."; exit 1; }

if ! command -v ffmpeg >/dev/null; then
  if command -v brew >/dev/null; then
    brew install ffmpeg
  else
    echo "FFmpeg is required. Install Homebrew, then run: brew install ffmpeg"
    exit 1
  fi
fi

mkdir -p "$RUNTIME_DIR" "$MODELS_DIR" "$INSTALL_DIR"
python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/python" -m pip install -r "$ROOT/requirements.txt"

echo "Downloading local speech models (about 2 GB on first install)..."
MODELSCOPE_CACHE="$MODELS_DIR" "$VENV_DIR/bin/python" "$ROOT/scripts/download_models.py"

zsh "$ROOT/build.sh"
rm -rf "$DEST_APP"
ditto "$ROOT/build/Snack Record.app" "$DEST_APP"
open "$DEST_APP"

echo "Installed: $DEST_APP"
