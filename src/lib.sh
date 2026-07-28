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
