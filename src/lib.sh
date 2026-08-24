#!/usr/bin/env bash
# src/lib.sh — pure decision helpers. No side effects; safe to source in tests.

# Max integer GPU utilization across (possibly multi-line) nvidia-smi output.
bs_parse_gpu_util() {
  local max=0 line n
  while IFS= read -r line; do
    n="${line//[[:space:]]/}"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    (( n > max )) && max="$n"
  done <<< "${1:-}"
  printf '%s\n' "$max"
}

# Next index in a ring of COUNT items (0-based).
bs_next_index() {
  printf '%s\n' "$(( ($1 + 1) % $2 ))"
}

# Smart mode: switch TO the gpu view? yes iff sustained above threshold.
bs_should_show_gpu() {
  local util="$1" threshold="$2" consec_above="$3" hold_needed="$4"
  if (( util >= threshold )) && (( consec_above >= hold_needed )); then
    printf 'yes\n'; else printf 'no\n'; fi
}

# Smart mode: return to overview? yes iff util below threshold - hysteresis.
bs_should_return_overview() {
  local util="$1" threshold="$2" hysteresis="$3"
  if (( util < threshold - hysteresis )); then printf 'yes\n'; else printf 'no\n'; fi
}

# Map an app name to the command that runs it. Returns non-zero for unknowns.
# This is the single place that defines which tools BubbleScreen can show.
bs_app_cmd() {
  case "$1" in
    htop)  printf 'htop\n' ;;
    nvtop) printf 'nvtop\n' ;;
    *) return 1 ;;
  esac
}

# Parse the APPS list (comma-separated) into a validated, order-preserving,
# space-joined list. Whitespace is trimmed; unknown apps are dropped; if nothing
# valid remains, fall back to the default "htop nvtop".
bs_parse_apps() {
  local raw="${1:-}" a out=()
  local parts; IFS=',' read -ra parts <<< "$raw"
  for a in "${parts[@]}"; do
    a="${a//[[:space:]]/}"
    [[ -z "$a" ]] && continue
    bs_app_cmd "$a" >/dev/null 2>&1 && out+=("$a")
  done
  (( ${#out[@]} )) || out=(htop nvtop)
  printf '%s\n' "${out[*]}"
}

# Should the display sleep now? yes iff a positive timeout is set and the input
# idle time has reached it. Compared in whole seconds — DDC/CI power control is
# driven directly, with no kernel-blank minute rounding.
bs_should_sleep() {
  local idle="$1" timeout="$2"
  if (( timeout > 0 )) && (( idle >= timeout )); then printf 'yes\n'; else printf 'no\n'; fi
}

# Parse `ddcutil detect` output and print the i2c bus number of the first
# DDC/CI-capable display (the digits in its /dev/i2c-N line). Returns non-zero
# when no display/bus is present, so the caller can degrade to no power control.
bs_ddc_parse_bus() {
  local line bus=""
  while IFS= read -r line; do
    if [[ "$line" =~ /dev/i2c-([0-9]+) ]]; then
      bus="${BASH_REMATCH[1]}"; break
    fi
  done <<< "${1:-}"
  [[ -n "$bus" ]] || return 1
  printf '%s\n' "$bus"
}
