#!/usr/bin/env bash
# ~/.claude/statusline.sh — Claude Code session status line (aesthetic edition)
#
# Three-line output:
#   Line 1: ◆ model │ gradient progress bar percentage │ cost │ time │ rate limits
#   Line 2: ⎇branch* │ +added/-removed │ directory
#   Line 3: ❯ prompt (color tied to context usage)
#
# Environment variables:
#   CLAUDE_STATUSLINE_ASCII=1     fall back to plain ASCII
#   CLAUDE_STATUSLINE_NERDFONT=1  enable Nerd Font icons
#   CLAUDE_STATUSLINE_POWERLINE=1 enable Powerline separators (defaults to NERDFONT)
#   COLORTERM=truecolor|24bit     set automatically by the system, enables truecolor gradients

set -euo pipefail

# ═══════════════════════════════════════════════════════════════
# Environment detection
# ═══════════════════════════════════════════════════════════════

USE_ASCII="${CLAUDE_STATUSLINE_ASCII:-0}"
USE_NERDFONT="${CLAUDE_STATUSLINE_NERDFONT:-0}"
USE_POWERLINE="${CLAUDE_STATUSLINE_POWERLINE:-$USE_NERDFONT}"
USE_TRUECOLOR=0
if [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" ]]; then
  USE_TRUECOLOR=1
fi

# ═══════════════════════════════════════════════════════════════
# Colors and symbols
# ═══════════════════════════════════════════════════════════════

RST='\033[0m'
CYAN='\033[36m'
BLUE='\033[34m'
GRAY='\033[90m'
DIM='\033[2m'
YELLOW='\033[33m'
GREEN='\033[32m'
RED='\033[31m'
MAGENTA='\033[35m'

# Anthropic brand purple (#7266EA)
if (( USE_TRUECOLOR )); then
  PURPLE='\033[38;2;114;102;234m'
else
  PURPLE='\033[35m'
fi

# Symbol sets
if [[ "$USE_ASCII" == "1" ]]; then
  S_BRAND="<>"
  S_BRANCH=">"
  S_WARN="!"
  S_PROMPT=">"
  S_TIME=""
  S_COST=""
  SEP=" | "
elif [[ "$USE_NERDFONT" == "1" ]]; then
  S_BRAND="◆"
  S_BRANCH=" "
  S_WARN=" 󰀦"
  S_PROMPT="❯"
  S_TIME="󰔟 "
  S_COST=" "
  if [[ "$USE_POWERLINE" == "1" ]]; then
    SEP="  "
  else
    SEP=" │ "
  fi
else
  S_BRAND="◆"
  S_BRANCH="⎇"
  S_WARN=" ⚠"
  S_PROMPT="❯"
  S_TIME=""
  S_COST=""
  if [[ "$USE_POWERLINE" == "1" ]]; then
    SEP="  "
  else
    SEP=" │ "
  fi
fi

# ═══════════════════════════════════════════════════════════════
# Fallback output
# ═══════════════════════════════════════════════════════════════

fallback_prompt() {
  printf '%b' "${GRAY}${1:-─}${RST}"
  exit 0
}

command -v jq &>/dev/null || fallback_prompt "─ │ jq not found"

# ═══════════════════════════════════════════════════════════════
# Read JSON (single jq pass)
# ═══════════════════════════════════════════════════════════════

input=$(cat)

parsed=$(echo "$input" | jq -r '
  (.model.display_name // ""),
  (.context_window.used_percentage // 0 | tostring),
  (.cost.total_cost_usd // 0 | (. * 100 | round) / 100 | tostring),
  (.workspace.current_dir // "." | split("/") | last),
  (.worktree.branch // ""),
  (.rate_limits.five_hour.used_percentage // -1 | tostring),
  (.rate_limits.seven_day.used_percentage // -1 | tostring),
  (.rate_limits.five_hour.resets_at // -1 | tostring),
  (.rate_limits.seven_day.resets_at // -1 | tostring),
  (.agent.name // ""),
  (.workspace.current_dir // "."),
  (.cost.total_lines_added // 0 | tostring),
  (.cost.total_lines_removed // 0 | tostring),
  (.cost.total_duration_ms // 0 | tostring),
  (.context_window.context_window_size // 0 | tostring),
  (.worktree.name // ""),
  "END"
' 2>/dev/null) || fallback_prompt "─ │ parse error"

{
  IFS= read -r model_name
  IFS= read -r ctx_pct
  IFS= read -r cost
  IFS= read -r dir
  IFS= read -r branch
  IFS= read -r rate5h
  IFS= read -r rate7d
  IFS= read -r reset5h
  IFS= read -r reset7d
  IFS= read -r agent_name
  IFS= read -r cwd_full
  IFS= read -r lines_add
  IFS= read -r lines_rm
  IFS= read -r duration_ms
  IFS= read -r ctx_size
  IFS= read -r wt_name
  IFS= read -r _sentinel
} <<< "$parsed"

# ═══════════════════════════════════════════════════════════════
# Model
# ═══════════════════════════════════════════════════════════════

model="${model_name:-─}"

# ═══════════════════════════════════════════════════════════════
# Context progress bar
# ═══════════════════════════════════════════════════════════════

pct_int=${ctx_pct%.*}
pct_int=${pct_int:-0}
if (( pct_int < 0 )); then pct_int=0; fi
if (( pct_int > 100 )); then pct_int=100; fi

bar_filled=$(( pct_int / 10 ))
if (( bar_filled > 10 )); then bar_filled=10; fi

# Gradient colors (truecolor): green → yellow → orange → red
GRAD_R=(46 116 186 241 239 236 233 231 211 192)
GRAD_G=(204 195 186 196 161 126 101 76 66 57)
GRAD_B=(113 89 64 15 24 34 44 60 50 43)

bar=""
if [[ "$USE_ASCII" == "1" ]]; then
  # ASCII mode
  for (( i=0; i<10; i++ )); do
    if (( i < bar_filled )); then bar+="#"; else bar+="-"; fi
  done
elif (( USE_TRUECOLOR )); then
  # Truecolor gradient: color each cell independently
  for (( i=0; i<10; i++ )); do
    if (( i < bar_filled )); then
      bar+="\\033[38;2;${GRAD_R[$i]};${GRAD_G[$i]};${GRAD_B[$i]}m█"
    else
      bar+="\\033[38;2;60;60;60m░"
    fi
  done
  bar+="${RST}"
else
  # ANSI fallback: pick color from overall percentage
  if (( pct_int >= 90 )); then bar_color="$RED"
  elif (( pct_int >= 70 )); then bar_color="$YELLOW"
  else bar_color="$GREEN"; fi

  for (( i=0; i<10; i++ )); do
    if (( i < bar_filled )); then bar+="█"; else bar+="░"; fi
  done
  bar="${bar_color}${bar}${RST}"
fi

# Percentage text color (matches the bar's overall color)
if (( pct_int >= 90 )); then pct_color="$RED"
elif (( pct_int >= 70 )); then pct_color="$YELLOW"
else pct_color="$GREEN"; fi

# Warning symbol
ctx_warn=""
if (( pct_int >= 90 )); then ctx_warn="${RED}${S_WARN}${RST}"; fi

# Context window size (only shown when model display_name lacks context info)
ctx_size_int=${ctx_size:-0}
ctx_label=""
if [[ "$model" != *context* && "$model" != *Context* ]]; then
  if (( ctx_size_int >= 1000000 )); then ctx_label=" ${GRAY}1M${RST}"
  elif (( ctx_size_int >= 200000 )); then ctx_label=" ${GRAY}200k${RST}"
  fi
fi

# ═══════════════════════════════════════════════════════════════
# Cost
# ═══════════════════════════════════════════════════════════════

cost_val="${cost:-0}"
cost_fmt=$(LC_ALL=C printf '%.2f' "$cost_val" 2>/dev/null || echo "0.00")
cost_int=${cost_val%.*}
cost_int=${cost_int:-0}
cost_str="\$${cost_fmt}"

if (( cost_int >= 10 )); then cost_color="$RED"
elif (( cost_int >= 5 )); then cost_color="$YELLOW"
elif [[ "$cost_fmt" == "0.00" ]]; then cost_color="$GRAY"
else cost_color="$YELLOW"; fi

# ═══════════════════════════════════════════════════════════════
# Elapsed time (smart-hidden when zero)
# ═══════════════════════════════════════════════════════════════

dur_ms=${duration_ms:-0}
dur_section=""
if (( dur_ms > 0 )); then
  dur_sec=$((dur_ms / 1000))
  dur_min=$((dur_sec / 60))
  dur_s=$((dur_sec % 60))
  # Skip display if it still formats to 0m0s (dur_ms may be a few hundred ms early in a session)
  if (( dur_min > 0 || dur_s > 0 )); then
    dur_section="${SEP}${GRAY}${S_TIME}${dur_min}m${dur_s}s${RST}"
  fi
fi

# ═══════════════════════════════════════════════════════════════
# Git branch and dirty marker (cached)
# ═══════════════════════════════════════════════════════════════

GIT_CACHE="/tmp/claude-statusline-git-cache"
GIT_CACHE_MAX_AGE=5

git_branch="${branch:-}"
dirty=""

git_cache_is_stale() {
  [[ ! -f "$GIT_CACHE" ]] && return 0
  local cache_age=$(( $(date +%s) - $(stat -f %m "$GIT_CACHE" 2>/dev/null || echo 0) ))
  (( cache_age > GIT_CACHE_MAX_AGE ))
}

if [[ -n "${cwd_full:-}" && -d "${cwd_full:-}" ]]; then
  if git_cache_is_stale; then
    if git -C "$cwd_full" rev-parse --git-dir &>/dev/null; then
      cached_branch="${git_branch}"
      if [[ -z "$cached_branch" ]]; then
        cached_branch=$(git -C "$cwd_full" -c core.useBuiltinFSMonitor=false branch --show-current 2>/dev/null) || true
        if [[ -z "$cached_branch" ]]; then
          cached_branch=$(git -C "$cwd_full" rev-parse --short HEAD 2>/dev/null) || true
        fi
      fi
      cached_dirty=""
      if ! git -C "$cwd_full" -c core.useBuiltinFSMonitor=false diff --quiet 2>/dev/null || \
         ! git -C "$cwd_full" -c core.useBuiltinFSMonitor=false diff --cached --quiet 2>/dev/null; then
        cached_dirty="*"
      fi
      echo "${cached_branch}|${cached_dirty}" > "$GIT_CACHE"
    else
      echo "|" > "$GIT_CACHE"
    fi
  fi

  if [[ -f "$GIT_CACHE" ]]; then
    IFS='|' read -r cached_br cached_dt < "$GIT_CACHE"
    if [[ -z "$git_branch" ]]; then git_branch="${cached_br}"; fi
    dirty="${cached_dt}"
  fi
fi

# ═══════════════════════════════════════════════════════════════
# Lines added/removed (smart-hidden when zero)
# ═══════════════════════════════════════════════════════════════

lines_add=${lines_add:-0}
lines_rm=${lines_rm:-0}
lines_section=""
if (( lines_add > 0 || lines_rm > 0 )); then
  lines_section="${GREEN}+${lines_add}${RST}/${RED}-${lines_rm}${RST}"
fi

# ═══════════════════════════════════════════════════════════════
# Rate limits (shown conditionally, as remaining capacity)
# ═══════════════════════════════════════════════════════════════

reset_minutes() {
  local resets_at="$1" now="$2"
  if [[ -z "$resets_at" || "$resets_at" == "-1" ]]; then
    return
  fi
  local resets_at_int=${resets_at%.*}
  local delta=$(( resets_at_int - now ))
  if (( delta < 0 )); then delta=0; fi
  echo $(( delta / 60 ))
}

format_reset_label() {
  local minutes=$1
  if (( minutes >= 100 )); then
    echo "$(( minutes / 60 ))h"
  else
    echo "${minutes}m"
  fi
}

time_left_color() {
  local minutes=$1 window_min=$2
  local frac_pct=$(( minutes * 100 / window_min ))
  if (( frac_pct > 50 )); then
    echo "$GRAY"
    return
  fi
  if (( USE_TRUECOLOR )); then
    local gi=$(( frac_pct * 9 / 50 ))
    if (( gi > 9 )); then gi=9; fi
    if (( gi < 0 )); then gi=0; fi
    printf '%s\n' "\\033[38;2;${GRAD_R[$gi]};${GRAD_G[$gi]};${GRAD_B[$gi]}m"
  elif (( frac_pct > 33 )); then echo "$RED"
  elif (( frac_pct > 16 )); then echo "$YELLOW"
  else echo "$GREEN"; fi
}

FIVE_HOUR_WINDOW_MIN=$(( 5 * 60 ))
SEVEN_DAY_WINDOW_MIN=$(( 7 * 24 * 60 ))

remaining_pct_color() {
  local pct=$1
  if (( pct <= 10 )); then echo "$RED"
  elif (( pct <= 30 )); then echo "$YELLOW"
  else echo "$GREEN"; fi
}

draw_remaining_bar() {
  local pct=$1
  local filled=$(( pct / 10 ))
  if (( filled > 10 )); then filled=10; fi
  if (( filled < 0 )); then filled=0; fi
  local b=""
  if [[ "$USE_ASCII" == "1" ]]; then
    for (( i=0; i<10; i++ )); do
      if (( i < filled )); then b+="#"; else b+="-"; fi
    done
  elif (( USE_TRUECOLOR )); then
    for (( i=0; i<10; i++ )); do
      if (( i < filled )); then
        local gi=$(( 9 - i ))
        b+="\\033[38;2;${GRAD_R[$gi]};${GRAD_G[$gi]};${GRAD_B[$gi]}m█"
      else
        b+="\\033[38;2;60;60;60m░"
      fi
    done
    b+="${RST}"
  else
    local bcolor
    bcolor=$(remaining_pct_color "$pct")
    for (( i=0; i<10; i++ )); do
      if (( i < filled )); then b+="█"; else b+="░"; fi
    done
    b="${bcolor}${b}${RST}"
  fi
  echo "$b"
}

rate_section=""
rate5h_int=${rate5h%.*}; rate5h_int=${rate5h_int:-0}
rate7d_int=${rate7d%.*}; rate7d_int=${rate7d_int:-0}
now_epoch=$(date +%s)

rate_parts=""
if (( rate5h_int >= 0 )); then
  remaining5h=$(( 100 - rate5h_int ))
  if (( remaining5h < 0 )); then remaining5h=0; fi
  if (( remaining5h > 100 )); then remaining5h=100; fi
  bar5h=$(draw_remaining_bar "$remaining5h")
  color5h=$(remaining_pct_color "$remaining5h")
  min5h=$(reset_minutes "$reset5h" "$now_epoch")
  if [[ -n "$min5h" ]]; then
    label5h=$(format_reset_label "$min5h")
    label_color5h=$(time_left_color "$min5h" "$FIVE_HOUR_WINDOW_MIN")
  else
    label5h="5h"
    label_color5h="$GRAY"
  fi
  rate_parts+="${label_color5h}${label5h}:${RST} ${bar5h} ${color5h}${remaining5h}%${RST}"
fi
if (( rate7d_int >= 0 )); then
  remaining7d=$(( 100 - rate7d_int ))
  if (( remaining7d < 0 )); then remaining7d=0; fi
  if (( remaining7d > 100 )); then remaining7d=100; fi
  bar7d=$(draw_remaining_bar "$remaining7d")
  color7d=$(remaining_pct_color "$remaining7d")
  min7d=$(reset_minutes "$reset7d" "$now_epoch")
  if [[ -n "$min7d" ]]; then
    label7d=$(format_reset_label "$min7d")
    label_color7d=$(time_left_color "$min7d" "$SEVEN_DAY_WINDOW_MIN")
  else
    label7d="7d"
    label_color7d="$GRAY"
  fi
  if [[ -n "$rate_parts" ]]; then rate_parts+=" "; fi
  rate_parts+="${label_color7d}${label7d}:${RST} ${bar7d} ${color7d}${remaining7d}%${RST}"
fi
if [[ -n "$rate_parts" ]]; then
  rate_section="${SEP}${rate_parts}"
fi

# ═══════════════════════════════════════════════════════════════
# Dynamic prompt (color tied to context usage)
# ═══════════════════════════════════════════════════════════════

if (( pct_int >= 90 )); then prompt_color="$RED"
elif (( pct_int >= 70 )); then prompt_color="$YELLOW"
else prompt_color="$GREEN"; fi

# ═══════════════════════════════════════════════════════════════
# Assemble line 1
# ═══════════════════════════════════════════════════════════════

line1="${PURPLE}${S_BRAND}${RST} ${CYAN}${model}${RST}"
line1+="${SEP}${bar} ${pct_color}${pct_int}%${RST}${ctx_warn}${ctx_label}"
line1+="${SEP}${cost_color}${S_COST}${cost_str}${RST}"
line1+="${dur_section}"
line1+="${rate_section}"

# ═══════════════════════════════════════════════════════════════
# Assemble line 2
# ═══════════════════════════════════════════════════════════════

parts=()
if [[ -n "$git_branch" ]]; then
  parts+=("${GRAY}${S_BRANCH}${git_branch}${dirty}${RST}")
fi
if [[ -n "$lines_section" ]]; then
  parts+=("${lines_section}")
fi
parts+=("${BLUE}${dir}${RST}")

# Agent / worktree indicator (only shown for non-main sessions)
if [[ -n "${wt_name:-}" ]]; then
  parts+=("${YELLOW}⚙ worktree:${wt_name}${RST}")
elif [[ -n "${agent_name:-}" ]]; then
  parts+=("${YELLOW}⚙ ${agent_name}${RST}")
fi

line2=""
for i in "${!parts[@]}"; do
  if (( i > 0 )); then
    line2+="${SEP}"
  fi
  line2+="${parts[$i]}"
done

# ═══════════════════════════════════════════════════════════════
# Output
# ═══════════════════════════════════════════════════════════════

# Only output two lines (Claude Code has its own input prompt, ours ❯ isn't needed)
printf '%b\n%b' "$line1" "$line2"
