#!/usr/bin/env bash
# src/layout.sh — build the tmux session for the selected MODE.
set -euo pipefail

: "${MODE:=smart}"
: "${BS_TMUX:=tmux}"
# htop renders with console-native ACS line-drawing (no UTF-8 locale needed) and
# adapts to narrow panes — unlike btop, which needs a UTF-8 locale and >=80 cols.
: "${BS_OVERVIEW_CMD:=htop}"
: "${BS_GPU_CMD:=nvtop}"

bs_build_layout() {
  local session="$1"
  local tmux=(${BS_TMUX})

  case "$MODE" in
    split)
      "${tmux[@]}" new-session -d -s "$session" -n dash "$BS_OVERVIEW_CMD"
      "${tmux[@]}" split-window -h -t "$session:dash" "$BS_GPU_CMD"
      "${tmux[@]}" select-layout -t "$session:dash" even-horizontal
      ;;
    rotate|smart)
      "${tmux[@]}" new-session -d -s "$session" -n overview "$BS_OVERVIEW_CMD"
      "${tmux[@]}" split-window -h -t "$session:overview" "$BS_GPU_CMD"
      "${tmux[@]}" select-layout -t "$session:overview" even-horizontal
      "${tmux[@]}" new-window -t "$session:1" -n gpu "$BS_GPU_CMD"
      "${tmux[@]}" select-window -t "$session:overview"
      ;;
    *)
      echo "layout.sh: unknown MODE '$MODE'" >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bs_build_layout "${1:?session name required}"
fi
