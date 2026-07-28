#!/usr/bin/env bash
# src/controller.sh — behavior loop: smart switching, rotation, wake-on-GPU.
set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${_here}/lib.sh"

: "${MODE:=smart}"
: "${GPU_THRESHOLD:=50}"
: "${GPU_THRESHOLD_HOLD:=3}"
: "${GPU_HYSTERESIS:=15}"
: "${WAKE_ON_GPU:=true}"
: "${ROTATE_INTERVAL:=20}"
: "${BS_SESSION:=bubblescreen}"
: "${BS_TMUX:=tmux}"

CURRENT_VIEW=overview
CONSEC_ABOVE=0
CONSEC_BELOW=0

bs_read_gpu_util() {
  local out
  out="$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null || true)"
  bs_parse_gpu_util "$out"
}

bs_show_view() {
  local view="$1"; local tmux=(${BS_TMUX})
  "${tmux[@]}" select-window -t "${BS_SESSION}:${view}" 2>/dev/null || true
}

# Reset the kernel console blank timer and force a redraw so the panel lights up.
bs_wake_display() {
  local tmux=(${BS_TMUX})
  "${tmux[@]}" refresh-client 2>/dev/null || true
}

bs_tick() {
  local util; util="$(bs_read_gpu_util)"
  if (( util >= GPU_THRESHOLD )); then
    CONSEC_ABOVE=$((CONSEC_ABOVE + 1)); CONSEC_BELOW=0
  else
    CONSEC_BELOW=$((CONSEC_BELOW + 1)); CONSEC_ABOVE=0
  fi

  if [[ "$CURRENT_VIEW" != "gpu" ]] \
     && [[ "$(bs_should_show_gpu "$util" "$GPU_THRESHOLD" "$CONSEC_ABOVE" "$GPU_THRESHOLD_HOLD")" == "yes" ]]; then
    bs_show_view gpu
    [[ "$WAKE_ON_GPU" == "true" ]] && bs_wake_display
    CURRENT_VIEW=gpu
  elif [[ "$CURRENT_VIEW" == "gpu" ]] \
     && [[ "$(bs_should_return_overview "$util" "$GPU_THRESHOLD" "$GPU_HYSTERESIS")" == "yes" ]]; then
    bs_show_view overview
    CURRENT_VIEW=overview
  fi
}

# Time-based rotation across windows (rotate mode only).
bs_rotate_loop() {
  local idx=0 count=2 names=(overview gpu)
  while true; do
    sleep "$ROTATE_INTERVAL"
    idx="$(bs_next_index "$idx" "$count")"
    bs_show_view "${names[$idx]}"
  done
}

main() {
  case "$MODE" in
    smart)  while true; do bs_tick; sleep 1; done ;;
    rotate) bs_rotate_loop ;;
    split)  while true; do sleep 3600; done ;;  # static; nothing to drive
    *) echo "controller.sh: unknown MODE '$MODE'" >&2; exit 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
