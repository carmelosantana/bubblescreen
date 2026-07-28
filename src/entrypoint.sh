#!/usr/bin/env bash
# src/entrypoint.sh — seize the console, run the dashboard, restore on exit.
set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_here}/lib.sh"

: "${MODE:=smart}"
: "${SCREEN_TIMEOUT:=1800}"
: "${TARGET_VT:=auto}"
: "${BS_SESSION:=bubblescreen}"
export BS_SESSION

bs_pick_vt() {
  if [[ "$TARGET_VT" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$TARGET_VT"; return
  fi
  # openvt -s allocates and switches to the first free VT; ask it to print which.
  # Discovery hook for tests:
  if [[ -n "${BS_OPENVT_VT:-}" ]]; then printf '%s\n' "$BS_OPENVT_VT"; return; fi
  fgconsole >/dev/null 2>&1 || true
  # Fall back to VT 7 (matches the steam-headless convention for a free VT).
  printf '7\n'
}

bs_set_blank() {
  local vt="$1" timeout="$2" min
  min="$(bs_blank_minutes "$timeout")"
  setterm --term linux --blank "$min" --powerdown "$min" >/dev/null 2>&1 || true
}

bs_restore() {
  local original="$1"
  # Disarm the trap so a signal-triggered restore doesn't re-run on EXIT.
  trap - EXIT INT TERM
  "${BS_TMUX:-tmux}" kill-server 2>/dev/null || true
  setterm --term linux --blank 0 --powerdown 0 >/dev/null 2>&1 || true
  chvt "$original" 2>/dev/null || true
}

main() {
  local orig_vt vt
  orig_vt="$(fgconsole 2>/dev/null || echo 1)"
  vt="$(bs_pick_vt)"
  # Bind orig_vt at trap-install time (double-quoted) so restore still has its
  # value after main returns and the EXIT trap fires — a single-quoted body
  # would expand the now-out-of-scope local under set -u and abort before
  # bs_restore ever runs, stranding the console.
  trap "bs_restore '$orig_vt'" EXIT INT TERM

  # Console mouse (wheel scroll) for tmux/btop/nvtop.
  gpm -m /dev/input/mice -t imps2 >/dev/null 2>&1 || true

  # Build the session and set the kernel blank timer.
  MODE="$MODE" "${_here}/layout.sh" "$BS_SESSION"
  bs_set_blank "$vt" "$SCREEN_TIMEOUT"

  # Drive behavior (smart/rotate) in the background.
  "${_here}/controller.sh" &
  local controller_pid=$!

  # Attach the session on the chosen VT; openvt runs us there and chvt-switches.
  openvt -c "$vt" -s -w -- \
    tmux -f "${_here}/tmux.conf" attach-session -t "$BS_SESSION" || true

  kill "$controller_pid" 2>/dev/null || true
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
