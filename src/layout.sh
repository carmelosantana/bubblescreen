#!/usr/bin/env bash
# src/layout.sh — build the tmux session from APPS (which tools) and MODE (how
# multiple tools are arranged).
set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${_here}/lib.sh"

: "${MODE:=smart}"
: "${APPS:=htop,nvtop}"
: "${BS_TMUX:=tmux}"

bs_build_layout() {
  local session="$1"
  local tmux=(${BS_TMUX})
  local apps; read -ra apps <<< "$(bs_parse_apps "$APPS")"
  local n=${#apps[@]} i

  # Single app: one full-screen window; MODE has nothing to arrange.
  if (( n == 1 )); then
    "${tmux[@]}" new-session -d -s "$session" -n main "$(bs_app_cmd "${apps[0]}")"
    return
  fi

  case "$MODE" in
    split)
      "${tmux[@]}" new-session -d -s "$session" -n dash "$(bs_app_cmd "${apps[0]}")"
      for (( i=1; i<n; i++ )); do
        "${tmux[@]}" split-window -h -t "$session:dash" "$(bs_app_cmd "${apps[$i]}")"
      done
      "${tmux[@]}" select-layout -t "$session:dash" even-horizontal
      ;;
    rotate|smart)
      # overview window: every selected app side by side.
      "${tmux[@]}" new-session -d -s "$session" -n overview "$(bs_app_cmd "${apps[0]}")"
      for (( i=1; i<n; i++ )); do
        "${tmux[@]}" split-window -h -t "$session:overview" "$(bs_app_cmd "${apps[$i]}")"
      done
      "${tmux[@]}" select-layout -t "$session:overview" even-horizontal
      # gpu window: the GPU tool full-screen (the target of smart/rotate switches).
      "${tmux[@]}" new-window -t "$session:1" -n gpu "$(bs_app_cmd nvtop)"
      "${tmux[@]}" select-window -t "$session:overview"
      ;;
    *)
      echo "layout.sh: unknown MODE '$MODE'" >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bs_build_layout "${1:?session name required}"
fi
