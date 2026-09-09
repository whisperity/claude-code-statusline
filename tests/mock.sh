#!/usr/bin/env bash
# mock.sh — Test statusline.sh with mock JSON data
#
# Usage: ./tests/mock.sh [scenario]
# Scenarios: normal, warning, danger, startup, agent, worktree, boot, primary,
#            ascii, nerdfont

set -euo pipefail

SCRIPT="${1:-all}"
STATUSLINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/statusline.sh"

if [[ ! -x "$STATUSLINE" ]]; then
  echo "Error: $STATUSLINE not found or not executable"
  exit 1
fi

NOW=$(date +%s)
RESET_5H=$(( NOW + 4 * 3600 + 12 * 60 ))
RESET_7D=$(( NOW + 5 * 86400 ))

run_test() {
  local label="$1"
  local json="$2"
  local env_prefix="${3:-}"

  echo ""
  echo "━━━ $label ━━━"
  if [[ -n "$env_prefix" ]]; then
    echo "$json" | env "$env_prefix" "$STATUSLINE"
  else
    echo "$json" | "$STATUSLINE"
  fi
  echo ""
}

# The boot-cost and /compact-detection cache is keyed by session_id, and only
# reveals its behavior across repeated calls with the same id: the first call
# in a session snapshots whatever percentage it sees as the "boot" cost, so a
# demo needs a priming call before the one that's actually shown.
run_test_primed() {
  local label="$1"
  local boot_json="$2"
  local json="$3"
  local env_prefix="${4:-}"

  if [[ -n "$env_prefix" ]]; then
    echo "$boot_json" | env "$env_prefix" "$STATUSLINE" > /dev/null
  else
    echo "$boot_json" | "$STATUSLINE" > /dev/null
  fi
  run_test "$label" "$json" "$env_prefix"
}

# ── Test data ──

JSON_NORMAL='{"model":{"display_name":"Claude Opus 4.6"},"session_id":"mock-normal","context_window":{"used_percentage":42,"current_usage":420000,"context_window_size":1000000},"cost":{"total_cost_usd":0.85,"total_lines_added":150,"total_lines_removed":30,"total_duration_ms":222000},"workspace":{"current_dir":"/Users/dev/my-project"},"worktree":{"branch":"main"},"rate_limits":{"five_hour":{"used_percentage":15,"resets_at":'"$RESET_5H"'},"seven_day":{"used_percentage":8,"resets_at":'"$RESET_7D"'}}}'

JSON_WARNING='{"model":{"display_name":"Claude Sonnet 4.6"},"session_id":"mock-warning","context_window":{"used_percentage":75,"current_usage":150000,"context_window_size":200000},"cost":{"total_cost_usd":3.20,"total_lines_added":280,"total_lines_removed":45,"total_duration_ms":725000},"workspace":{"current_dir":"/Users/dev/my-project"},"worktree":{"branch":"feat/auth"},"rate_limits":{"five_hour":{"used_percentage":48,"resets_at":'"$RESET_5H"'}}}'

JSON_DANGER='{"model":{"display_name":"Claude Opus 4.6"},"session_id":"mock-danger","context_window":{"used_percentage":92,"current_usage":920000,"context_window_size":1000000},"cost":{"total_cost_usd":65.30,"total_lines_added":500,"total_lines_removed":120,"total_duration_ms":2712000},"workspace":{"current_dir":"/Users/dev/api-server"},"worktree":{"branch":"main"},"rate_limits":{"five_hour":{"used_percentage":93,"resets_at":'"$(( NOW + 8 * 60 ))"'},"seven_day":{"used_percentage":62,"resets_at":'"$RESET_7D"'}}}'

JSON_STARTUP='{"model":{"display_name":"Opus 4.6 (1M context)"},"session_id":"mock-startup","context_window":{"used_percentage":0,"current_usage":0,"context_window_size":1000000},"cost":{"total_cost_usd":0,"total_duration_ms":0},"workspace":{"current_dir":"/Users/dev/my-project"}}'

JSON_AGENT='{"model":{"display_name":"Claude Opus 4.6"},"session_id":"mock-agent","context_window":{"used_percentage":42,"current_usage":420000,"context_window_size":1000000},"cost":{"total_cost_usd":0.85,"total_lines_added":150,"total_lines_removed":30,"total_duration_ms":222000},"workspace":{"current_dir":"/Users/dev/my-project"},"worktree":{"branch":"main"},"agent":{"name":"code-reviewer"}}'

JSON_WORKTREE='{"model":{"display_name":"Claude Opus 4.6"},"session_id":"mock-worktree","context_window":{"used_percentage":42,"current_usage":420000,"context_window_size":1000000},"cost":{"total_cost_usd":0.85,"total_lines_added":150,"total_lines_removed":30,"total_duration_ms":222000},"workspace":{"current_dir":"/Users/dev/my-project"},"worktree":{"branch":"worktree-my-feature","name":"my-feature","path":"/path/to/worktree"}}'

# Boot cost: the priming call reports a low percentage (startup config only),
# the real call reports a much higher one -- the gap between them is what the
# dark-grey "boot" zone on the bar represents.
JSON_BOOT_PRIME='{"model":{"display_name":"Claude Opus 4.6"},"session_id":"mock-boot","context_window":{"used_percentage":6,"current_usage":60000,"context_window_size":1000000},"cost":{"total_cost_usd":0,"total_duration_ms":0},"workspace":{"current_dir":"/Users/dev/my-project"},"worktree":{"branch":"main"}}'
JSON_BOOT='{"model":{"display_name":"Claude Opus 4.6"},"session_id":"mock-boot","context_window":{"used_percentage":38,"current_usage":380000,"context_window_size":1000000},"cost":{"total_cost_usd":1.10,"total_lines_added":40,"total_lines_removed":5,"total_duration_ms":95000},"workspace":{"current_dir":"/Users/dev/my-project"},"worktree":{"branch":"main"}}'

# Primary branch: master/main/stable/trunk gets a yellow name and a warning
# glyph, since working directly on one is usually a mistake worth noticing.
JSON_PRIMARY='{"model":{"display_name":"Claude Opus 4.6"},"session_id":"mock-primary","context_window":{"used_percentage":20,"current_usage":200000,"context_window_size":1000000},"cost":{"total_cost_usd":0.40,"total_lines_added":12,"total_lines_removed":2,"total_duration_ms":60000},"workspace":{"current_dir":"/Users/dev/my-project"},"worktree":{"branch":"master"}}'

# ── Run tests ──

case "${SCRIPT}" in
  normal)   run_test "Normal (42%, green)" "$JSON_NORMAL" ;;
  warning)  run_test "Warning (75%, yellow)" "$JSON_WARNING" ;;
  danger)   run_test "Danger (92%, red + ⚠)" "$JSON_DANGER" ;;
  startup)  run_test "Session startup (zero values hidden)" "$JSON_STARTUP" ;;
  agent)    run_test "Agent mode (code-reviewer)" "$JSON_AGENT" ;;
  worktree) run_test "Worktree mode (my-feature)" "$JSON_WORKTREE" ;;
  boot)     run_test_primed "Boot cost indicator (6% boot, 38% chat)" "$JSON_BOOT_PRIME" "$JSON_BOOT" ;;
  primary)  run_test "Primary branch warning (master)" "$JSON_PRIMARY" ;;
  ascii)    run_test "ASCII fallback" "$JSON_NORMAL" "CLAUDE_STATUSLINE_ASCII=1" ;;
  nerdfont) run_test "Nerd Font mode" "$JSON_NORMAL" "CLAUDE_STATUSLINE_NERDFONT=1" ;;
  all)
    run_test "Normal (42%, green)" "$JSON_NORMAL"
    run_test "Warning (75%, yellow)" "$JSON_WARNING"
    run_test "Danger (92%, red + ⚠)" "$JSON_DANGER"
    run_test "Session startup (zero values hidden)" "$JSON_STARTUP"
    run_test "Agent mode (code-reviewer)" "$JSON_AGENT"
    run_test "Worktree mode (my-feature)" "$JSON_WORKTREE"
    run_test_primed "Boot cost indicator (6% boot, 38% chat)" "$JSON_BOOT_PRIME" "$JSON_BOOT"
    run_test "Primary branch warning (master)" "$JSON_PRIMARY"
    run_test "ASCII fallback" "$JSON_NORMAL" "CLAUDE_STATUSLINE_ASCII=1"
    run_test "Nerd Font mode" "$JSON_NORMAL" "CLAUDE_STATUSLINE_NERDFONT=1"
    ;;
  *)
    echo "Unknown scenario: $SCRIPT"
    echo "Available: normal, warning, danger, startup, agent, worktree, boot, primary, ascii, nerdfont, all"
    exit 1
    ;;
esac
