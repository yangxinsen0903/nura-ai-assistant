#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./scripts/sync_ios_to_xcode.sh /path/to/nura-ai-assistant/NuraAI/NuraAI
# Example:
#   ./scripts/sync_ios_to_xcode.sh "$HOME/Documents/GitHub/nura-ai-assistant/NuraAI/NuraAI"

if [ $# -ne 1 ]; then
  echo "Usage: $0 <xcode_source_dir>"
  exit 1
fi

SRC_DIR="$(cd "$(dirname "$0")/../ios/NuraAI" && pwd)"
DST_DIR="$1"

if [ ! -d "$DST_DIR" ]; then
  echo "Destination not found: $DST_DIR"
  exit 2
fi

cp -f "$SRC_DIR"/*.swift "$DST_DIR"/

echo "Synced Swift files from: $SRC_DIR"
echo "To: $DST_DIR"
ls -1 "$DST_DIR"/*.swift | sed 's#^.*/##'
