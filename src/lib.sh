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

# Translate SCREEN_TIMEOUT seconds to a setterm blank/powerdown minute value.
# 0 (or less) => never blank. Otherwise round to nearest minute, floor 1, cap 60.
bs_blank_minutes() {
  local sec="$1" min
  if (( sec <= 0 )); then printf '0\n'; return; fi
  min=$(( (sec + 30) / 60 ))
  (( min < 1 )) && min=1
  (( min > 60 )) && min=60
  printf '%s\n' "$min"
}
