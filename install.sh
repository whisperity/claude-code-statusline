#!/usr/bin/env bash
# install.sh — One-line installer for claude-code-statusline
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/whisperity/claude-code-statusline/master/install.sh | bash
#   — or —
#   git clone https://github.com/whisperity/claude-code-statusline.git && cd claude-code-statusline && ./install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$HOME/.claude/statusline.sh"
SETTINGS="$HOME/.claude/settings.json"

echo "◆ claude-code-statusline installer"
echo ""

# Check dependencies
if ! command -v jq &>/dev/null; then
  echo "⚠ jq is required but not installed."
  echo "  Install: brew install jq (macOS) or apt install jq (Linux)"
  exit 1
fi

# Copy script
if [[ -f "$SCRIPT_DIR/statusline.sh" ]]; then
  cp "$SCRIPT_DIR/statusline.sh" "$TARGET"
else
  echo "Downloading statusline.sh..."
  curl -fsSL "https://raw.githubusercontent.com/whisperity/claude-code-statusline/master/statusline.sh" -o "$TARGET"
fi
chmod +x "$TARGET"
echo "✓ Installed to $TARGET"

# Update settings.json
if [[ -f "$SETTINGS" ]]; then
  if grep -q '"statusLine"' "$SETTINGS" 2>/dev/null; then
    echo ""
    echo "⚠ Your settings.json already has a statusLine config."
    echo "  To use this script, update it to:"
    echo ""
    echo '  "statusLine": {'
    echo '    "type": "command",'
    echo '    "command": "~/.claude/statusline.sh"'
    echo '  }'
    echo ""
  else
    echo ""
    echo "Add this to your ~/.claude/settings.json:"
    echo ""
    echo '  "statusLine": {'
    echo '    "type": "command",'
    echo '    "command": "~/.claude/statusline.sh"'
    echo '  }'
    echo ""
  fi
else
  echo ""
  echo "No settings.json found. Create ~/.claude/settings.json with:"
  echo ""
  echo '{'
  echo '  "statusLine": {'
  echo '    "type": "command",'
  echo '    "command": "~/.claude/statusline.sh"'
  echo '  }'
  echo '}'
  echo ""
fi

echo "✓ Done! Restart Claude Code to see the status line."
