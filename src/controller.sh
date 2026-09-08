#!/usr/bin/env bash
# src/controller.sh — behavior loop: smart/rotate view switching, GPU-alert
# wake, and DDC/CI display power management (sleep on input-idle, wake on
# input or GPU activity).
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
: "${SCREEN_TIMEOUT:=300}"
: "${APPS:=htop,nvtop}"
: "${BS_SESSION:=bubblescreen}"
: "${BS_TMUX:=tmux}"
: "${BS_INPUT_STAMP:=/run/bubblescreen.input}"
: "${BS_I2C_CLASS_GLOB:=/sys/class/i2c-dev/i2c-*}"
: "${BS_I2C_DEV_PREFIX:=/dev/i2c-}"

# --- view-switching state ---
CURRENT_VIEW=overview
CONSEC_ABOVE=0
CONSEC_BELOW=0
# --- power / wake state ---
WAKE_LATCH=0          # 1 while a GPU spike is "active" (fires wake once per spike)
MONITOR_STATE=on      # our view of the display: on|off
BS_DDC_AVAILABLE=0    # set by bs_ddc_init
BS_DDC_BUS=""
BS_WATCHER_PID=""

bs_read_gpu_util() {
  local out
  out="$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null || true)"
  bs_parse_gpu_util "$out"
}

bs_show_view() {
  local view="$1"; local tmux=(${BS_TMUX})
  "${tmux[@]}" select-window -t "${BS_SESSION}:${view}" 2>/dev/null || true
}

bs_refresh_client() {
  local tmux=(${BS_TMUX})
  "${tmux[@]}" refresh-client 2>/dev/null || true
}

# --- DDC/CI display power control -------------------------------------------

# Create /dev/i2c-* char nodes from sysfs. Docker gives the container a private,
# point-in-time /dev, so the i2c nodes the kernel creates after the container
# starts (when i2c-dev loads, or the GPU registers its DDC adapters) never appear
# in it — even though /sys (a live mount) does show the adapters. Recreate the
# nodes from the major:minor that sysfs publishes. A privileged container can
# mknod; safe to re-run (existing nodes are skipped).
bs_sync_i2c_nodes() {
  local d n dn maj min dev
  for d in $BS_I2C_CLASS_GLOB; do
    [ -e "$d" ] || continue
    n=${d##*/i2c-}
    dn="$(cat "$d/dev" 2>/dev/null)" || continue
    maj="${dn%:*}"; min="${dn#*:}"
    dev="${BS_I2C_DEV_PREFIX}${n}"
    [ -e "$dev" ] || mknod "$dev" c "$maj" "$min" 2>/dev/null || true
  done
}

# Detect the DDC/CI display's i2c bus, so power writes can target it directly.
# Ensures i2c-dev is loaded and the /dev nodes exist first. Leaves
# BS_DDC_AVAILABLE=0 quietly when no display answers yet — main retries, because
# the GPU's i2c adapters can come up a little after the container starts.
bs_ddc_init() {
  BS_DDC_AVAILABLE=0; BS_DDC_BUS=""
  command -v ddcutil >/dev/null 2>&1 || return
  modprobe i2c-dev >/dev/null 2>&1 || true
  bs_sync_i2c_nodes
  local out bus
  out="$(ddcutil detect --brief 2>/dev/null || true)"
  if bus="$(bs_ddc_parse_bus "$out")"; then
    BS_DDC_BUS="$bus"; BS_DDC_AVAILABLE=1
    echo "bubblescreen: DDC/CI display on /dev/i2c-$bus — screen sleeps after ${SCREEN_TIMEOUT}s idle" >&2
  fi
}

# Write VCP feature D6 (power mode). --noverify: a monitor entering standby
# can't answer the read-back ddcutil normally does to confirm the write, so
# verification "fails" even though the command took effect. Skip it.
bs_ddc_power() {
  ddcutil --bus "$BS_DDC_BUS" setvcp --noverify d6 "$1" >/dev/null 2>&1 || true
}

bs_display_off() {
  (( BS_DDC_AVAILABLE )) || return 0
  [[ "$MONITOR_STATE" == "on" ]] || return 0
  bs_ddc_power 04          # DPMS off (standby; wakeable via D6=01)
  MONITOR_STATE=off
}

bs_display_on() {
  (( BS_DDC_AVAILABLE )) || return 0
  [[ "$MONITOR_STATE" == "off" ]] || return 0
  bs_ddc_power 01          # power on
  bs_refresh_client        # repaint the current frame
  MONITOR_STATE=on
}

# Seconds since the last recorded input event (keyboard/mouse). Console output
# (htop/nvtop redraws) does NOT touch this — that is the whole point: it tracks
# *user* idle, which a kernel blank timer cannot on a constantly-redrawn console.
bs_idle_secs() {
  local now stamp
  now="$(date +%s)"
  stamp="$(stat -c %Y "$BS_INPUT_STAMP" 2>/dev/null || echo "$now")"
  printf '%s\n' "$(( now - stamp ))"
}

bs_stamp_now() { : > "$BS_INPUT_STAMP"; }

# Wake the display and treat it as fresh activity (resets the idle timer). Used
# for a GPU spike "alert" and reused as the input-driven wake path.
bs_wake_display() {
  bs_stamp_now
  bs_display_on
}

# Background: re-stamp on any /dev/input activity. One reader per device, all
# feeding a single pipe; any bytes (an input_event struct) bump the stamp.
bs_start_input_watcher() {
  local d
  ( for d in /dev/input/event*; do [ -e "$d" ] && cat "$d" & done 2>/dev/null; wait ) 2>/dev/null \
    | while IFS= read -r -d '' -n 24 _ 2>/dev/null; do bs_stamp_now; done &
  BS_WATCHER_PID=$!
}

# --- per-tick decisions ------------------------------------------------------

bs_update_consec() {
  local util="$1"
  if (( util >= GPU_THRESHOLD )); then
    CONSEC_ABOVE=$((CONSEC_ABOVE + 1)); CONSEC_BELOW=0
  else
    CONSEC_BELOW=$((CONSEC_BELOW + 1)); CONSEC_ABOVE=0
  fi
}

# Smart mode: switch the visible window to gpu when a sustained spike starts,
# back to overview once it subsides.
bs_view_step() {
  local util="$1"
  if [[ "$CURRENT_VIEW" != "gpu" ]] \
     && [[ "$(bs_should_show_gpu "$util" "$GPU_THRESHOLD" "$CONSEC_ABOVE" "$GPU_THRESHOLD_HOLD")" == "yes" ]]; then
    bs_show_view gpu; CURRENT_VIEW=gpu
  elif [[ "$CURRENT_VIEW" == "gpu" ]] \
     && [[ "$(bs_should_return_overview "$util" "$GPU_THRESHOLD" "$GPU_HYSTERESIS")" == "yes" ]]; then
    bs_show_view overview; CURRENT_VIEW=overview
  fi
}

# GPU-alert wake: fire ONCE per spike (rising edge), not every second it stays
# high — so a sustained multi-hour run wakes the screen once, shows it for
# SCREEN_TIMEOUT, then lets it sleep again. Re-arms after the GPU subsides.
bs_wake_step() {
  local util="$1"
  [[ "$WAKE_ON_GPU" == "true" ]] || return 0
  if [[ "$(bs_should_show_gpu "$util" "$GPU_THRESHOLD" "$CONSEC_ABOVE" "$GPU_THRESHOLD_HOLD")" == "yes" ]]; then
    (( WAKE_LATCH )) || { bs_wake_display; WAKE_LATCH=1; }
  elif [[ "$(bs_should_return_overview "$util" "$GPU_THRESHOLD" "$GPU_HYSTERESIS")" == "yes" ]]; then
    WAKE_LATCH=0
  fi
}

# Sleep the display after SCREEN_TIMEOUT of input idle; keep it on otherwise.
bs_power_step() {
  local idle; idle="$(bs_idle_secs)"
  if [[ "$(bs_should_sleep "$idle" "$SCREEN_TIMEOUT")" == "yes" ]]; then
    bs_display_off
  else
    bs_display_on
  fi
}

main() {
  bs_stamp_now
  bs_ddc_init
  if (( ! BS_DDC_AVAILABLE )); then
    if command -v ddcutil >/dev/null 2>&1; then
      echo "bubblescreen: no DDC/CI display yet — retrying. If it never appears, enable DDC/CI in the monitor's OSD menu." >&2
    else
      echo "bubblescreen: ddcutil not installed — display power management disabled." >&2
    fi
  fi
  bs_start_input_watcher
  trap 'kill "${BS_WATCHER_PID:-0}" 2>/dev/null || true' EXIT TERM INT

  local apps; read -ra apps <<< "$(bs_parse_apps "$APPS")"
  local multi=0; (( ${#apps[@]} >= 2 )) && multi=1

  local rotate_elapsed=0 rot_idx=0 names=(overview gpu) util ddc_retry=0
  while true; do
    # The GPU's DDC i2c bus can appear after startup; keep retrying until found.
    if (( ! BS_DDC_AVAILABLE )); then
      ddc_retry=$((ddc_retry + 1))
      if (( ddc_retry >= 10 )); then ddc_retry=0; bs_ddc_init; fi
    fi

    util="$(bs_read_gpu_util)"
    bs_update_consec "$util"
    bs_wake_step "$util"

    if (( multi )); then
      case "$MODE" in
        smart) bs_view_step "$util" ;;
        rotate)
          rotate_elapsed=$((rotate_elapsed + 1))
          if (( rotate_elapsed >= ROTATE_INTERVAL )); then
            rotate_elapsed=0
            rot_idx="$(bs_next_index "$rot_idx" 2)"
            bs_show_view "${names[$rot_idx]}"
          fi
          ;;
        split) : ;;
        *) echo "controller.sh: unknown MODE '$MODE'" >&2 ;;
      esac
    fi

    bs_power_step
    sleep 1
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
