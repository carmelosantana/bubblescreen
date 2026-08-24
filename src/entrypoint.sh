#!/usr/bin/env bash
# src/entrypoint.sh — seize the console, run the dashboard, restore on exit.
set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_here}/lib.sh"

: "${MODE:=smart}"
: "${SCREEN_TIMEOUT:=300}"
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

# Console tools required to seize/switch a VT. openvt/chvt/fgconsole ship in the
# 'kbd' package (NOT util-linux — that only provides setterm).
bs_preflight() {
  local t missing=()
  for t in ${BS_REQUIRED_TOOLS:-openvt chvt}; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if (( ${#missing[@]} )); then
    echo "bubblescreen: missing console tools: ${missing[*]} — install the 'kbd' package" >&2
    return 1
  fi
  return 0
}

# Fail safe: log a clear, actionable error and HOLD (do not exit). Exiting would
# let 'restart: unless-stopped' tight-loop, and each restart re-inits/tears down
# the NVIDIA GPU context — spamming knvlinkCoreShutdownDeviceLinks on the console.
# Holding keeps the container up and quiet until the operator fixes the config.
bs_hold() {
  echo "bubblescreen: FATAL: $1" >&2
  echo "bubblescreen: holding without restart to avoid GPU/NVLink churn — fix the config and redeploy (see README troubleshooting)." >&2
  sleep infinity
}

# Load i2c-dev so ddcutil can reach the monitor's DDC/CI bus. The NVIDIA driver
# registers the i2c adapters; i2c-dev exposes them as /dev/i2c-* (needed by the
# controller's DDC power control). Best-effort: needs the host module, which a
# privileged container can load when /lib/modules is bind-mounted. If it fails,
# the controller simply degrades to leaving the screen on.
bs_load_i2c() {
  modprobe i2c-dev >/dev/null 2>&1 || true
}

bs_restore() {
  local original="$1"
  # Disarm the trap so a signal-triggered restore doesn't re-run on EXIT.
  trap - EXIT INT TERM
  echo "bubblescreen: restoring console -> switching to VT $original" >&2
  "${BS_TMUX:-tmux}" kill-server 2>/dev/null || true
  # Ensure the monitor is powered back ON — the controller may have put it to
  # DDC/CI standby, and we must never hand the console back to a dark screen.
  command -v ddcutil >/dev/null 2>&1 && ddcutil setvcp --noverify d6 01 >/dev/null 2>&1 || true
  chvt "$original" 2>/dev/null || true
}

main() {
  local orig_vt vt controller_pid
  orig_vt="$(fgconsole 2>/dev/null || echo 1)"
  vt="$(bs_pick_vt)"

  # Never restore to our OWN dashboard VT. If a prior instance already switched
  # the console to $vt, fgconsole reports $vt here, and restoring to it on exit
  # would leave the dashboard frame on screen (chvt to the current VT is a no-op).
  # Fall back to VT 1, the TrueNAS console.
  if [[ "$orig_vt" == "$vt" ]]; then orig_vt=1; fi

  # Verify the console tools exist BEFORE touching anything — a missing binary
  # must surface as a clear held error, not a silent restart loop.
  if ! bs_preflight; then
    bs_hold "required console tools missing (need: ${BS_REQUIRED_TOOLS:-openvt chvt})"
    return
  fi

  # Bind orig_vt at trap-install time (double-quoted) so restore still has its
  # value after main returns and the EXIT trap fires — a single-quoted body
  # would expand the now-out-of-scope local under set -u and abort before
  # bs_restore ever runs, stranding the console.
  trap "bs_restore '$orig_vt'" EXIT INT TERM

  # Console mouse (wheel scroll) for tmux/htop/nvtop.
  gpm -m /dev/input/mice -t imps2 >/dev/null 2>&1 || true

  # Expose the DDC/CI i2c bus so the controller can power the monitor off/on.
  bs_load_i2c

  # Build the tmux session (view arrangement); the controller drives switching
  # and display power management.
  MODE="$MODE" "${_here}/layout.sh" "$BS_SESSION"

  # Drive behavior (smart/rotate) in the background.
  "${_here}/controller.sh" &
  controller_pid=$!

  # The dashboard always runs on a Linux VT, so TERM must be "linux". Set it
  # unconditionally: the container env often ships TERM=dumb (a no-capability
  # type tmux cannot use), and an empty/dumb TERM makes the tmux client exit 1
  # ("open terminal failed"). Do NOT use ${TERM:-linux} — that keeps a bad
  # non-empty value like "dumb".
  export TERM=linux

  # Attach the session on the chosen VT; openvt runs us there and chvt-switches.
  # -f (force): take over the VT even if it is "in use" — a prior instance that
  # was hard-killed (docker rm) leaves VT $vt allocated, and without -f openvt
  # aborts with "vt N is in use". A kiosk always claims its VT.
  #
  # Run openvt in the BACKGROUND and `wait` on it — NOT in the foreground. A
  # foreground openvt -w blocks bash so a SIGTERM (docker stop → tini → us) can't
  # run the EXIT/TERM trap until openvt returns, which it never does; Docker then
  # SIGKILLs us and the console is never restored (last frame left on screen).
  # `wait` is interruptible, so the trap fires promptly and bs_restore switches
  # the display back to the original VT.
  openvt -f -c "$vt" -s -w -- \
      "${BS_TMUX:-tmux}" -f "${_here}/tmux.conf" attach-session -t "$BS_SESSION" &
  local openvt_pid=$!
  wait "$openvt_pid"
  local rc=$?

  kill "$controller_pid" 2>/dev/null || true

  # rc < 128 and non-zero => openvt/tmux attach genuinely failed (not a signal,
  # which yields 128+signum and means we're shutting down). Hold, don't loop.
  if (( rc != 0 && rc < 128 )); then
    bs_hold "openvt/tmux attach to VT $vt failed — needs 'privileged: true' (host VT nodes) to seize the console, and a valid TERM ($TERM) for the tmux client"
    return
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
