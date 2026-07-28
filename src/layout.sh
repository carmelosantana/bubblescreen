#!/usr/bin/env bash
# src/layout.sh — build the tmux session for the selected MODE.
set -euo pipefail

: "${MODE:=smart}"
: "${BTOP_PRESET:=0}"
: "${BS_TMUX:=tmux}"
: "${BS_OVERVIEW_CMD:=btop -p ${BTOP_PRESET}}"
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
