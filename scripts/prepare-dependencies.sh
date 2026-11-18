#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
bash "$PROJECT_DIR/scripts/prepare-vlc.sh"
python3 "$PROJECT_DIR/scripts/prepare-sparkle.py"
