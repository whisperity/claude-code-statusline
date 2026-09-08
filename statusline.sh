#!/usr/bin/env bash
# shellcheck disable=SC2154
# SC2154: to_int() assigns its target variable indirectly via `printf -v`, and
# \shellcheck can't trace the name back to any call site and flags every usage
# as "<> referenced but not assigned".
#
# ~/.claude/statusline.sh — Claude Code session status line (aesthetic edition)
#
# Response output between one-line and two-line versions.
# One-line if the terminal is wide enough to fit everything, otherwise two-line.
# On narrow terminals, the "rate limits" section moves to the front of line 2 to
# balance the consumed space.
#
#   Line 1: ◆ model │ clock │ gradient progress bar percentage │ cost │ time │ rate limits | ⎇branch* │ +added/-removed │ directory
# or
#   Line 1: ◆ model │ clock │ gradient progress bar percentage │ cost │ time │ rate limits
#   Line 2: ⎇branch* │ +added/-removed │ directory
# or
#   Line 1: ◆ model │ clock │ gradient progress bar percentage │ cost │ time
#   Line 2: rate limits │ ⎇branch* │ +added/-removed │ directory
#
# Environment variables:
#
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

STATUSLINE_TMPDIR="${TMPDIR:-/tmp}"
STATUSLINE_TMPDIR="${STATUSLINE_TMPDIR%/}"
CONTEXT_CACHE_MAX_AGE=15 # sec.
GIT_CACHE_MAX_AGE=15 # sec.
FIVE_HOUR_GREY_THRESHOLD_MIN=$(( 3 * 60 ))
SEVEN_DAY_GREY_THRESHOLD_MIN=$(( 72 * 60 ))
FIVE_HOUR_GREEN_FLOOR_MIN=20
SEVEN_DAY_GREEN_FLOOR_MIN=$(( 2 * 60 ))

# ═══════════════════════════════════════════════════════════════
# Colors and symbols
# ═══════════════════════════════════════════════════════════════

# Real ESC bytes via ANSI-C quoting, not the literal text "\033" -- these are
# rendered with printf '%s', not '%b', so a value that merely *contains* the
# ASCII text "\033[...m" (e.g., a maliciously named cwd) can't forge a colour
# code. See sanitise() below for the other half of that defense.
CSI=$'\033['
RST="${CSI}0m"
BLACK="${CSI}30m"
CYAN="${CSI}36m"
BLUE="${CSI}34m"
GRAY="${CSI}90m"
DIM="${CSI}2m"
YELLOW="${CSI}33m"
GREEN="${CSI}32m"
RED="${CSI}31m"
MAGENTA="${CSI}35m"

# Anthropic brand purple (#7266EA)
if (( USE_TRUECOLOR )); then
  PURPLE="${CSI}38;2;114;102;234m"
else
  PURPLE="${CSI}35m"
fi

if (( USE_TRUECOLOR )); then
  CTX_CACHE_ZONE_COLOR="${CSI}38;2;80;80;80m"
  EMPTY_ZONE_COLOR="${CSI}38;2;60;60;60m"
else
  CTX_CACHE_ZONE_COLOR="$BLACK"
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
  S_TIME="@ "
  S_COST=$'$ '
  S_DIRTY="*"
  S_LIMIT="# "
  S_AGENT="@ "
  S_WORKTREE=""
  SEP=" | "
elif [[ "$USE_NERDFONT" == "1" ]]; then
  S_BRAND=$' '
  S_BRANCH=$' '
  S_WARN=" 󰀦"
  S_TIME=" "
  S_COST=$' '
  S_DIRTY=" "
  S_LIMIT="󰔟 "
  S_AGENT="⚙ "
  S_WORKTREE="  "
  if [[ "$USE_POWERLINE" == "1" ]]; then
    SEP=$'  '
  else
    SEP=" │ "
  fi
else
  S_BRAND="◆"
  S_WARN=" ⚠"
  S_TIME="⏲ "
  S_COST=$'$ '
  S_DIRTY="Δ"
  S_LIMIT="⟲ "
  S_AGENT="⚙ "
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
    # bleeds into the next cell — which held the first letter of the
    # branch name, since this was the only tier without a trailing
    # space. The space absorbs the overflow.
    S_BRANCH="⎇ "
    SEP=" │ "
  fi
  S_WORKTREE="$S_BRANCH"
fi

# ═══════════════════════════════════════════════════════════════
# Fallback output
# ═══════════════════════════════════════════════════════════════

fallback_prompt() {
  printf '%s' "${RED}${1:-─}${RST}"
  exit 0
}

# An unexpected failure must never leave the status line blank, because
# empty output makes Claude Code render nothing at all.
trap 'fallback_prompt "─ statusline failed on line $LINENO —"' ERR

command -v jq &>/dev/null || fallback_prompt "─ │ jq not found"

# ═══════════════════════════════════════════════════════════════
# Utility functions
# ═══════════════════════════════════════════════════════════════

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

# Strip C0 control characters and DEL from a value that reaches the
# terminal. A directory name may legally contain a raw ESC, which would
# otherwise be emitted verbatim and run as a terminal control sequence.
# The range stops at \x7f on purpose: 0x80-0x9f are UTF-8 continuation
# bytes, not C1 controls, and stripping them would corrupt non-ASCII names.
sanitise() { # $1=target variable name, holding the value to clean in place
  local v="${!1}"
  printf -v "$1" '%s' "${v//[$'\x01'-$'\x1f'$'\x7f']/}"
}

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
  (if .context_window.current_usage == null then "0" else "1" end),
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
  IFS= read -r usage_populated
  IFS= read -r _sentinel
} <<< "$parsed"

# Every field below is attacker-controllable (a directory name, a branch, a
# subagent name, ...) and ends up in the final output, so strip C0 controls
# from each before it's used for anything -- comparisons, cache keys, or
# display -- rather than trying to catch every render site individually.
for _f in model_name dir branch agent_name cwd_full wt_name; do
  sanitise "$_f"
done

# ═══════════════════════════════════════════════════════════════
# Model
# ═══════════════════════════════════════════════════════════════

model="${model_name:-─}"

# ═══════════════════════════════════════════════════════════════
# Context cache snapshot
# ═══════════════════════════════════════════════════════════════

CONTEXT_CACHE="${STATUSLINE_TMPDIR}/claude-statusline-context-${session_id:-default}"

to_int "${ctx_pct:-0}" pct_int
if (( pct_int < 0 )); then pct_int=0; fi
if (( pct_int > 100 )); then pct_int=100; fi

# Snapshot the pre-chat context cost on first execution, and re-arm it
# after a "/compact". Two independent signals detect compaction, either
# is sufficient:
#
#   1. Definitive: `context_window.current_usage` is null before the
#      first API response in the session, and again immediately after
#      "/compact" until the next API call repopulates it (per Claude
#      Code docs) — so a 1→0 transition in `usage_populated` means a
#      compaction happened. Since it's null, the fresh percentage isn't
#      known yet, so the snapshot is invalidated and left pending until
#      the next API call repopulates it.
#   2. Heuristic fallback, in case a compaction is missed by signal 1
#      (e.g., the statusline didn't run during that exact window):
#      context usage only grows within a session absent compaction, so
#      a drop in `pct_int` below the highest value observed so far also
#      means a compaction happened. Since usage is already populated
#      here, the fresh percentage is known immediately — no pending step.
#
# ctx_cache_state:
#   0 = pre-first-API-call
#   1 = pending: awaiting repopulation after a signal-1 (definitive) detection
#   2 = valid: (re)armed via the initial snapshot or a signal-1 detection
#   3 = valid: (re)armed via a signal-2 (heuristic) detection
ctx_cache_pct=0
ctx_cache_state=0
ctx_cache_last=0

context_cache_is_stale() {
  [[ ! -f "$CONTEXT_CACHE" ]] && return 0
  local cache_age=$(( $(date +%s) - $(file_mtime "$CONTEXT_CACHE") ))
  (( cache_age > CONTEXT_CACHE_MAX_AGE ))
}

if [[ ! -f "$CONTEXT_CACHE" ]]; then
  ctx_cache_pct=$pct_int
  ctx_cache_last=$pct_int
  if (( usage_populated == 1 )); then ctx_cache_state=2; fi
  printf '%s\n%s\n%s\n' "$ctx_cache_pct" "$ctx_cache_state" "$ctx_cache_last" > "$CONTEXT_CACHE"
else
  {
    IFS= read -r ctx_cache_pct
    IFS= read -r ctx_cache_state
    IFS= read -r ctx_cache_last
  } < "$CONTEXT_CACHE"
  to_int "${ctx_cache_pct:-0}" ctx_cache_pct
  to_int "${ctx_cache_state:-0}" ctx_cache_state
  to_int "${ctx_cache_last:-0}" ctx_cache_last

  if (( ( ctx_cache_state == 0 || ctx_cache_state == 1 ) && usage_populated == 1 )); then
    # Initial snapshot, or repopulation after a signal-1 (definitive)
    # detection: snapshot now.
    ctx_cache_pct=$pct_int
    ctx_cache_state=2
    ctx_cache_last=$pct_int
    printf '%s\n%s\n%s\n' "$ctx_cache_pct" "$ctx_cache_state" "$ctx_cache_last" > "$CONTEXT_CACHE"
  elif (( ( ctx_cache_state == 2 || ctx_cache_state == 3 ) && usage_populated == 0 )); then
    # Signal 1: definitive compaction. The fresh percentage isn't known
    # yet — invalidate the snapshot and wait for the next API call.
    ctx_cache_pct=0
    ctx_cache_state=1
    ctx_cache_last=$pct_int
    printf '%s\n%s\n%s\n' "$ctx_cache_pct" "$ctx_cache_state" "$ctx_cache_last" > "$CONTEXT_CACHE"
  elif (( ( ctx_cache_state == 2 || ctx_cache_state == 3 ) && pct_int < ctx_cache_last )); then
    # Signal 2: heuristic compaction. usage is already populated, so the
    # fresh percentage is known immediately — snapshot right away.
    ctx_cache_pct=$pct_int
    ctx_cache_state=3
    ctx_cache_last=$pct_int
    printf '%s\n%s\n%s\n' "$ctx_cache_pct" "$ctx_cache_state" "$ctx_cache_last" > "$CONTEXT_CACHE"
  elif (( ( ctx_cache_state == 2 || ctx_cache_state == 3 ) && pct_int > ctx_cache_last )); then
    # Steady growth: track the high-water mark for the next comparison.
    if context_cache_is_stale; then
      ctx_cache_last=$pct_int
      printf '%s\n%s\n%s\n' "$ctx_cache_pct" "$ctx_cache_state" "$ctx_cache_last" > "$CONTEXT_CACHE"
    fi
  fi
fi

# ═══════════════════════════════════════════════════════════════
# Context progress bar (cache zone + chat zone)
# ═══════════════════════════════════════════════════════════════

ctx_cache_filled=$(( ctx_cache_pct / 10 ))
if (( ctx_cache_filled > 10 )); then ctx_cache_filled=10; fi
if (( ctx_cache_pct > 0 && ctx_cache_filled == 0 )); then ctx_cache_filled=1; fi

bar_filled=$(( pct_int / 10 ))
if (( bar_filled > 10 )); then bar_filled=10; fi
if (( pct_int > 0 && bar_filled == 0 )); then bar_filled=1; fi

# Bar has three zones: cache (dark, solid) → chat (gradient) → empty (dim)
bar=""
if [[ "$USE_ASCII" == "1" ]]; then
  for (( i=0; i<10; i++ )); do
    if (( i < ctx_cache_filled )); then bar+="="
    elif (( i < bar_filled )); then bar+="#"
    else bar+="-"; fi
  done
elif (( USE_TRUECOLOR )); then
  for (( i=0; i<10; i++ )); do
    if (( i < ctx_cache_filled )); then
      # Cache zone: dark gray solid — already consumed, can't get it back
      bar+="${CTX_CACHE_ZONE_COLOR}█"
    elif (( i < bar_filled )); then
      # Chat zone: original gradient color
      bar+="${CSI}38;2;${GRAD_R[$i]};${GRAD_G[$i]};${GRAD_B[$i]}m█"
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
    if (( i < ctx_cache_filled )); then bar+="${CTX_CACHE_ZONE_COLOR}█${RST}"
    elif (( i < bar_filled )); then bar+="${bar_color}█${RST}"
    else bar+="${EMPTY_ZONE_COLOR}░${RST}"; fi
  done
fi

# Cache label: pre-chat context percentage shown to the left of the
# bar, omitted when it rounds to 0%.
ctx_cache_label=""
if (( ctx_cache_pct > 0 )); then
  if (( ctx_cache_pct > 10 )); then ctx_cache_color="$RED"
  elif (( ctx_cache_pct > 5 )); then ctx_cache_color="$YELLOW"
  else ctx_cache_color="$GRAY"; fi
  ctx_cache_label="${ctx_cache_color}${ctx_cache_pct}%${RST} "
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
cost_str="${cost_fmt}"

if (( cost_int >= 50 )); then cost_color="$RED"
elif (( cost_int >= 10 )); then cost_color="$YELLOW"
elif (( cost_int >= 1 )); then cost_color="$GREEN"
else cost_color="$GRAY"; fi

# ═══════════════════════════════════════════════════════════════
# Elapsed time (smart-hidden when zero)
# ═══════════════════════════════════════════════════════════════

# Compact a duration in whole seconds into a two-tier "big small" form:
# a large unit (days/weeks/months, whichever band applies) plus an
# hours-minutes-seconds tail, e.g. "1M2d 3h50m10s" or "1w3d 4h".
# A calendar month has no fixed length without real date math, which is overkill
# for a rough session-age display, so months are approximated at 30 days.
format_duration() {
  local total=$1
  local -r SEC_MIN=60 SEC_HOUR=3600 SEC_DAY=86400 SEC_WEEK=604800 SEC_MONTH=2592000
  local big="" rem=$total
  if (( total >= SEC_MONTH )); then
    local months=$(( total / SEC_MONTH ))
    rem=$(( total % SEC_MONTH ))
    local days=$(( rem / SEC_DAY ))
    rem=$(( rem % SEC_DAY ))
    big="${months}M"
    if (( days > 0 )); then big+="${days}d"; fi
  elif (( total >= SEC_WEEK )); then
    local weeks=$(( total / SEC_WEEK ))
    rem=$(( total % SEC_WEEK ))
    local days=$(( rem / SEC_DAY ))
    rem=$(( rem % SEC_DAY ))
    big="${weeks}w"
    if (( days > 0 )); then big+="${days}d"; fi
  elif (( total >= SEC_DAY )); then
    local days=$(( total / SEC_DAY ))
    rem=$(( total % SEC_DAY ))
    big="${days}d"
  fi

  local h=$(( rem / SEC_HOUR ))
  local rem2=$(( rem % SEC_HOUR ))
  local m=$(( rem2 / SEC_MIN ))
  local s=$(( rem2 % SEC_MIN ))

  local small=""
  if (( h > 0 )); then
    small="${h}h"
    if (( m > 0 || s > 0 )); then small+="${m}m"; fi
    if (( s > 0 )); then small+="${s}s"; fi
  elif (( m > 0 )); then
    small="${m}m"
    if (( s > 0 )); then small+="${s}s"; fi
  elif (( s > 0 )); then
    small="${s}s"
  fi

  if [[ -n "$big" && -n "$small" ]]; then
    echo "${big} ${small}"
  elif [[ -n "$big" ]]; then
    echo "$big"
  elif [[ -n "$small" ]]; then
    echo "$small"
  else
    echo "0s"
  fi
}


to_int "${duration_ms:-0}" dur_ms
dur_section=""
if (( dur_ms > 0 )); then
  dur_sec=$((dur_ms / 1000))
  # Skip display if it still formats to 0s (dur_ms may be a few hundred ms early in a session)
  if (( dur_sec > 0 )); then
    dur_section="${SEP}${GRAY}${S_TIME}$(format_duration "$dur_sec")${RST}"
  fi
fi

# ═══════════════════════════════════════════════════════════════
# Git branch and dirty marker (cached)
# ═══════════════════════════════════════════════════════════════

GIT_CACHE="${STATUSLINE_TMPDIR}/claude-statusline-git-$(cksum <<< "${cwd_full:-.}" | cut -d' ' -f1)"
git_branch="${branch:-}"
dirty=""

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
    sanitise cached_br
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

reset_seconds() {
  local resets_at="$1" now="$2"
  if [[ -z "$resets_at" || "$resets_at" == "-1" ]]; then
    return
  fi
  local resets_at_int
  to_int "$resets_at" resets_at_int
  local delta=$(( resets_at_int - now ))
  if (( delta < 0 )); then delta=0; fi
  echo "$delta"
}

round_half_up() { # $1=n $2=d
  echo $(( (2*$1 + $2) / (2*$2) ))
}

format_5h_reset() {
  local delta=$1
  local floor_min=$(( delta / 60 ))
  if (( floor_min >= 100 )); then
    echo "$(round_half_up "$delta" 3600)h"
  elif (( floor_min >= 10 )); then
    local m
    m=$(round_half_up "$delta" 60)
    if (( m > 99 )); then m=99; fi
    echo "${m}m"
  else
    local m=$(( delta / 60 )) s=$(( delta % 60 ))
    if (( m > 0 )); then
      if (( s > 0 )); then echo "${m}m${s}s"; else echo "${m}m"; fi
    else
      echo "${s}s"
    fi
  fi
}

format_7d_reset() {
  local delta=$1
  local floor_min=$(( delta / 60 ))
  if (( floor_min > 4320 )); then
    echo "$(round_half_up "$delta" 86400)d"
  elif (( floor_min > 720 )); then
    echo "$(round_half_up "$delta" 3600)h"
  elif (( floor_min >= 120 )); then
    local hours_part=$(( delta / 3600 ))
    local rem_sec=$(( delta % 3600 ))
    local rem_min
    rem_min=$(round_half_up "$rem_sec" 60)
    if (( rem_min == 60 )); then
      hours_part=$(( hours_part + 1 ))
      rem_min=0
    fi
    if (( rem_min > 0 )); then
      echo "${hours_part}h${rem_min}m"
    else
      echo "${hours_part}h"
    fi
  elif (( floor_min >= 10 )); then
    local m
    m=$(round_half_up "$delta" 60)
    if (( m > 119 )); then m=119; fi
    echo "${m}m"
  else
    local m=$(( delta / 60 )) s=$(( delta % 60 ))
    if (( m > 0 )); then
      if (( s > 0 )); then echo "${m}m${s}s"; else echo "${m}m"; fi
    else
      echo "${s}s"
    fi
  fi
}

# Color for the reset countdown: grey above grey_threshold_min, green
# at or below green_floor_min (a hard cutoff, not part of the
# continuous scale), and otherwise 9 gradient stops (indices 1-9; index 0 is
# reserved for the green floor) spread to 8 equal steps across the interval:
# (green_floor_min, grey_threshold_min].
time_left_color() {
  local floor_min=$1 grey_threshold_min=$2 green_floor_min=$3
  if (( floor_min > grey_threshold_min )); then
    echo "$GRAY"
    return
  fi
  if (( floor_min <= green_floor_min )); then
    if (( USE_TRUECOLOR )); then
      printf '%s\n' "${CSI}38;2;${GRAD_R[0]};${GRAD_G[0]};${GRAD_B[0]}m"
    else
      echo "$GREEN"
    fi
    return
  fi
  local span=$(( grey_threshold_min - green_floor_min ))
  if (( USE_TRUECOLOR )); then
    local gi=$(( 1 + (floor_min - green_floor_min) * 8 / span ))
    if (( gi > 9 )); then gi=9; fi
    printf '%s\n' "${CSI}38;2;${GRAD_R[$gi]};${GRAD_G[$gi]};${GRAD_B[$gi]}m"
  else
    local frac_pct=$(( (floor_min - green_floor_min) * 100 / span ))
    if (( frac_pct > 66 )); then echo "$RED"
    elif (( frac_pct > 33 )); then echo "$YELLOW"
    else echo "$GREEN"; fi
  fi
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
        b+="${CSI}38;2;${GRAD_R[$gi]};${GRAD_G[$gi]};${GRAD_B[$gi]}m█"
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
rate_limit_icon="${GRAY}${DIM}${S_LIMIT}${RST}"
if (( rate5h_int >= 0 )); then
  remaining5h=$(( 100 - rate5h_int ))
  if (( remaining5h < 0 )); then remaining5h=0; fi
  if (( remaining5h > 100 )); then remaining5h=100; fi
  bar5h=$(draw_remaining_bar "$remaining5h")
  color5h=$(remaining_pct_color "$remaining5h")
  sec5h=$(reset_seconds "$reset5h" "$now_epoch")
  if [[ -n "$sec5h" ]]; then
    label5h=$(format_5h_reset "$sec5h")
    label_color5h=$(time_left_color "$(( sec5h / 60 ))" "$FIVE_HOUR_GREY_THRESHOLD_MIN" "$FIVE_HOUR_GREEN_FLOOR_MIN")
  else
    label5h="5h"
    label_color5h="$GRAY"
  fi
  warn5h=$(rate_warn "$remaining5h")
  rate_parts+="${rate_limit_icon}${label_color5h}${label5h}:${RST} ${bar5h} ${color5h}${remaining5h}%${RST}${warn5h}"
fi
if (( rate7d_int >= 0 )); then
  remaining7d=$(( 100 - rate7d_int ))
  if (( remaining7d < 0 )); then remaining7d=0; fi
  if (( remaining7d > 100 )); then remaining7d=100; fi
  bar7d=$(draw_remaining_bar "$remaining7d")
  color7d=$(remaining_pct_color "$remaining7d")
  sec7d=$(reset_seconds "$reset7d" "$now_epoch")
  if [[ -n "$sec7d" ]]; then
    label7d=$(format_7d_reset "$sec7d")
    label_color7d=$(time_left_color "$(( sec7d / 60 ))" "$SEVEN_DAY_GREY_THRESHOLD_MIN" "$SEVEN_DAY_GREEN_FLOOR_MIN")
  else
    label7d="7d"
    label_color7d="$GRAY"
  fi
  warn7d=$(rate_warn "$remaining7d")
  if [[ -n "$rate_parts" ]]; then rate_parts+="$SEP"; fi
  rate_parts+="${rate_limit_icon}${label_color7d}${label7d}:${RST} ${bar7d} ${color7d}${remaining7d}%${RST}${warn7d}"
fi
if [[ -n "$rate_parts" ]]; then
  rate_section="${SEP}${rate_parts}"
fi

# ═══════════════════════════════════════════════════════════════
# Assemble the output lines
# ═══════════════════════════════════════════════════════════════

# Character count of a line with its ANSI color codes (real ESC bytes, not
# the literal text "\033") stripped, i.e. how many terminal columns it
# actually occupies. Approximate: doesn't account for double-width glyphs
# (CJK, some emoji), so a line right at the edge of the terminal width may
# still wrap by a cell or two.
visible_len() {
  local stripped
  # ${CSI} is ESC followed by a literal '[', which is a regex metachar --
  # keep it escaped in the pattern so it isn't read as a bracket expression.
  stripped=$(printf '%s' "$1" | sed -E "s/${CSI:0:1}\\[[0-9;]*m//g")
  printf '%s' "${#stripped}"
}

now=$(date +%H:%M:%S)
term_cols="${COLUMNS:-0}"
to_int "$term_cols" term_cols

line1="${PURPLE}${S_BRAND}${RST} ${CYAN}${model}${RST}"
line1+="${SEP}${CYAN}${now}${RST}"
line1+="${SEP}${ctx_cache_label}${bar} ${pct_color}${pct_int}%${RST}${ctx_warn}${ctx_label}"
line1+="${SEP}${cost_color}${S_COST}${cost_str}${RST}"
line1+="${dur_section}"

line1_wide="${line1}${rate_section}"

parts=()
if [[ -n "$git_branch" ]]; then
  dirty_display=""
  if [[ -n "$dirty" ]]; then dirty_display="${MAGENTA}${S_DIRTY% }${RST}"; fi
  branch_color="$GRAY"
  branch_warn=""
  case "$git_branch" in
    master | main | stable | trunk)
      branch_color="$YELLOW"
      branch_warn="${YELLOW} ${S_WARN# }${RST} "
      ;;
  esac
  parts+=("${branch_color}${S_BRANCH}${git_branch}${RST}${dirty_display}${branch_warn}")
fi
if [[ -n "$lines_section" ]]; then
  parts+=("${lines_section}")
fi
parts+=("${BLUE}${dir}${RST}")

# Agent / worktree indicator (only shown for non-main sessions)
if [[ -n "${wt_name:-}" ]]; then
  parts+=("${YELLOW}${S_AGENT}${S_WORKTREE}${wt_name}${RST}")
elif [[ -n "${agent_name:-}" ]]; then
  parts+=("${YELLOW}${S_AGENT}${agent_name}${RST}")
fi

line2=""
for i in "${!parts[@]}"; do
  if (( i > 0 )); then
    line2+="${SEP}"
  fi
  line2+="${parts[$i]}"
done

combined_len=$(( $(visible_len "$line1_wide") + $(visible_len "$SEP") + $(visible_len "$line2") ))

# ═══════════════════════════════════════════════════════════════
# Output
# ═══════════════════════════════════════════════════════════════

if (( term_cols > 0 && combined_len <= term_cols )); then
  printf '%s' "${line1_wide}${SEP}${line2}"
else
  line2_narrow="$line2"
  if [[ -n "$rate_parts" ]]; then
    line2_narrow="${rate_parts}${SEP}${line2}"
  fi
  printf '%s\n%s' "$line1" "$line2_narrow"
fi
