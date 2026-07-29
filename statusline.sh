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

STATUSLINE_TMPDIR="${TMPDIR:-/tmp}"
STATUSLINE_TMPDIR="${STATUSLINE_TMPDIR%/}"

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
BLACK='\033[30m'
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

if (( USE_TRUECOLOR )); then
  BOOT_ZONE_COLOR='\033[38;2;80;80;80m'
  EMPTY_ZONE_COLOR='\033[38;2;60;60;60m'
else
  BOOT_ZONE_COLOR="$BLACK"
  EMPTY_ZONE_COLOR="$GRAY"
fi

# Gradient colors (truecolor): green → yellow → orange → red
GRAD_R=(46 116 186 241 239 236 233 231 211 192)
GRAD_G=(204 195 186 196 161 126 101 76 66 57)
GRAD_B=(113 89 64 15 24 34 44 60 50 43)

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
  S_BRANCH=$' '
  S_WARN=" 󰀦"
  S_PROMPT="❯"
  S_TIME="󰔟 "
  S_COST=" "
  if [[ "$USE_POWERLINE" == "1" ]]; then
    SEP=$'  '
  else
    SEP=" │ "
  fi
else
  S_BRAND="◆"
  S_WARN=" ⚠"
  S_PROMPT="❯"
  S_TIME=""
  S_COST=""
  if [[ "$USE_POWERLINE" == "1" ]]; then
    # U+E0A0 is a Powerline glyph, so it is available whenever Powerline
    # separators are. It is monospace, so it occupies exactly one cell.
    S_BRANCH=$' '
    SEP="  "
  else
    # U+2387 is absent from common monospace fonts (Hack, Noto Sans Mono,
    # DejaVu Sans Mono), so fontconfig falls back to a proportional face.
    # Its East_Asian_Width is Neutral, so the terminal reserves a single
    # cell, but the proportional glyph is drawn wider than that and
    # bleeds into the next cell -- which held the first letter of the
    # branch name, since this was the only tier without a trailing
    # space. The space absorbs the overflow.
    S_BRANCH="⎇ "
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

# An unexpected failure must never leave the status line blank, because
# empty output makes Claude Code render nothing at all.
trap 'fallback_prompt "─"' ERR

# Integer part of a value. Anything non-numeric (null, stray command
# output) becomes 0, so it can never blow up an arithmetic context and
# abort the script under `set -u`.
to_int() { # $1=raw value  $2=target variable name
  local raw="$1" v
  if [[ "$raw" == *[eE]* ]]; then
    v=$(LC_ALL=C printf '%.10f' "$raw" 2>/dev/null)
    v="${v%%.*}"
  else
    v="${raw%%.*}"
  fi
  [[ "$v" =~ ^-?[0-9]+$ ]] || v=0
  printf -v "$2" '%s' "$v"
}

command -v jq &>/dev/null || fallback_prompt "─ │ jq not found"

# ═══════════════════════════════════════════════════════════════
# Read JSON (single jq pass)
# ═══════════════════════════════════════════════════════════════

input=$(cat)

parsed=$(echo "$input" | jq -r '
  (.model.display_name // ""),
  (.session_id // ""),
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
  IFS= read -r session_id
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
# Boot cost snapshot
# ═══════════════════════════════════════════════════════════════

BOOT_CACHE="${STATUSLINE_TMPDIR}/claude-statusline-boot-${session_id:-default}"

to_int "${ctx_pct:-0}" pct_int
if (( pct_int < 0 )); then pct_int=0; fi
if (( pct_int > 100 )); then pct_int=100; fi

# Snapshot the boot cost on first execution.
boot_pct=0
if [[ ! -f "$BOOT_CACHE" ]]; then
  echo "$pct_int" > "$BOOT_CACHE"
  boot_pct=$pct_int
else
  to_int "$(cat "$BOOT_CACHE" 2>/dev/null)" boot_pct
fi

# ═══════════════════════════════════════════════════════════════
# Context progress bar (boot zone + chat zone)
# ═══════════════════════════════════════════════════════════════

bar_filled=$(( pct_int / 10 ))
if (( bar_filled > 10 )); then bar_filled=10; fi
if (( pct_int > 0 && bar_filled == 0 )); then bar_filled=1; fi

boot_filled=$(( boot_pct / 10 ))
if (( boot_filled > 10 )); then boot_filled=10; fi
if (( boot_pct > 0 && boot_filled == 0 )); then boot_filled=1; fi

# Bar has three zones: boot (dark, solid) → chat (gradient) → empty (dim)
bar=""
if [[ "$USE_ASCII" == "1" ]]; then
  for (( i=0; i<10; i++ )); do
    if (( i < boot_filled )); then bar+="="
    elif (( i < bar_filled )); then bar+="#"
    else bar+="-"; fi
  done
elif (( USE_TRUECOLOR )); then
  for (( i=0; i<10; i++ )); do
    if (( i < boot_filled )); then
      # Boot zone: dark gray solid — already consumed, can't get it back
      bar+="${BOOT_ZONE_COLOR}█"
    elif (( i < bar_filled )); then
      # Chat zone: original gradient color
      bar+="\\033[38;2;${GRAD_R[$i]};${GRAD_G[$i]};${GRAD_B[$i]}m█"
    else
      # Empty zone: dark gray hollow
      bar+="${EMPTY_ZONE_COLOR}░"
    fi
  done
  bar+="${RST}"
else
  # ANSI fallback: pick color from overall percentage
  if (( pct_int >= 90 )); then bar_color="$RED"
  elif (( pct_int >= 70 )); then bar_color="$YELLOW"
  else bar_color="$GREEN"; fi

  for (( i=0; i<10; i++ )); do
    if (( i < boot_filled )); then bar+="${BOOT_ZONE_COLOR}█${RST}"
    elif (( i < bar_filled )); then bar+="${bar_color}█${RST}"
    else bar+="${EMPTY_ZONE_COLOR}░${RST}"; fi
  done
fi

# Boot label: startup-cost percentage shown to the left of the bar,
# omitted when it rounds to 0%.
boot_label=""
if (( boot_pct > 0 )); then
  if (( boot_pct > 10 )); then boot_color="$RED"
  elif (( boot_pct > 5 )); then boot_color="$YELLOW"
  else boot_color="$GRAY"; fi
  boot_label="${boot_color}${boot_pct}%${RST} "
fi

# Percentage text color (matches the bar's overall color)
if (( pct_int >= 90 )); then pct_color="$RED"
elif (( pct_int >= 70 )); then pct_color="$YELLOW"
else pct_color="$GREEN"; fi

# Warning symbol
ctx_warn=""
if (( pct_int >= 90 )); then ctx_warn="${RED}${S_WARN}${RST}"; fi

# Context window size (only shown when model display_name lacks context info)
to_int "${ctx_size:-0}" ctx_size_int
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
to_int "$cost_val" cost_int
cost_str="\$${cost_fmt}"

if (( cost_int >= 50 )); then cost_color="$RED"
elif (( cost_int >= 10 )); then cost_color="$YELLOW"
elif (( cost_int >= 1 )); then cost_color="$GREEN"
else cost_color="$GRAY"; fi

# ═══════════════════════════════════════════════════════════════
# Elapsed time (smart-hidden when zero)
# ═══════════════════════════════════════════════════════════════

to_int "${duration_ms:-0}" dur_ms
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

GIT_CACHE_DIR="${STATUSLINE_TMPDIR}/claude-statusline-git-${UID:-0}"
mkdir -p "$GIT_CACHE_DIR" 2>/dev/null || true
GIT_CACHE="$GIT_CACHE_DIR/$(cksum <<< "${cwd_full:-.}" | cut -d' ' -f1)"
GIT_CACHE_MAX_AGE=5

git_branch="${branch:-}"
dirty=""

file_mtime() {
  local file="$1" mtime=""
  if mtime=$(stat -c %Y "$file" 2>/dev/null) && [[ "$mtime" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$mtime"
  elif mtime=$(stat -f %m "$file" 2>/dev/null) && [[ "$mtime" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$mtime"
  else
    printf '0\n'
  fi
}

git_cache_is_stale() {
  [[ ! -f "$GIT_CACHE" ]] && return 0
  local cache_age=$(( $(date +%s) - $(file_mtime "$GIT_CACHE") ))
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
      echo "${cached_branch}|${cached_dirty}" > "$GIT_CACHE" 2>/dev/null || true
    else
      echo "|" > "$GIT_CACHE" 2>/dev/null || true
    fi
  fi

  if [[ -f "$GIT_CACHE" ]]; then
    IFS='|' read -r cached_br cached_dt < "$GIT_CACHE" || true
    if [[ -z "$git_branch" ]]; then git_branch="${cached_br}"; fi
    dirty="${cached_dt}"
  fi
fi

# ═══════════════════════════════════════════════════════════════
# Lines added/removed (smart-hidden when zero)
# ═══════════════════════════════════════════════════════════════

to_int "${lines_add:-0}" lines_add
to_int "${lines_rm:-0}" lines_rm
lines_section=""
if (( lines_add > 0 || lines_rm > 0 )); then
  lines_section="${GREEN}+${lines_add}${RST}/${RED}-${lines_rm}${RST}"
fi

# ═══════════════════════════════════════════════════════════════
# Rate limits (shown conditionally, as remaining capacity)
# ═══════════════════════════════════════════════════════════════

FIVE_HOUR_WINDOW_MIN=$(( 5 * 60 ))
SEVEN_DAY_WINDOW_MIN=$(( 7 * 24 * 60 ))

reset_minutes() {
  local resets_at="$1" now="$2"
  if [[ -z "$resets_at" || "$resets_at" == "-1" ]]; then
    return
  fi
  local resets_at_int
  to_int "$resets_at" resets_at_int
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

remaining_pct_color() {
  local pct=$1
  if (( pct <= 10 )); then echo "$RED"
  elif (( pct <= 30 )); then echo "$YELLOW"
  else echo "$GREEN"; fi
}

rate_warn() {
  local pct=$1
  if (( pct <= 10 )); then echo "${RED}${S_WARN}${RST}"; fi
}

draw_remaining_bar() {
  local pct=$1
  local filled=$(( pct / 10 ))
  if (( filled > 10 )); then filled=10; fi
  if (( filled < 0 )); then filled=0; fi
  if (( pct > 0 && filled == 0 )); then filled=1; fi
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
        b+="${EMPTY_ZONE_COLOR}░"
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
to_int "${rate5h:--1}" rate5h_int
to_int "${rate7d:--1}" rate7d_int
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
  warn5h=$(rate_warn "$remaining5h")
  rate_parts+="${label_color5h}${label5h}:${RST} ${bar5h} ${color5h}${remaining5h}%${RST}${warn5h}"
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
  warn7d=$(rate_warn "$remaining7d")
  if [[ -n "$rate_parts" ]]; then rate_parts+=" "; fi
  rate_parts+="${label_color7d}${label7d}:${RST} ${bar7d} ${color7d}${remaining7d}%${RST}${warn7d}"
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
line1+="${SEP}${boot_label}${bar} ${pct_color}${pct_int}%${RST}${ctx_warn}${ctx_label}"
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
