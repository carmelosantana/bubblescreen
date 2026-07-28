#!/usr/bin/env bash
# scripts/screenshots.sh — render README images without a physical monitor.
# Requires: freeze (github.com/charmbracelet/freeze), btop, nvtop.
# Run on a box with the NVIDIA runtime so the GPU frame shows real data.
set -euo pipefail

OUT="docs/screenshots"
mkdir -p "$OUT"
SIZE="${SIZE:-120x34}"     # columns x rows

command -v freeze >/dev/null || { echo "install freeze first" >&2; exit 1; }

# --execute runs the command in a pty, waits briefly, and captures a frame.
freeze --execute "btop"  --window --width "${SIZE%x*}" --height "${SIZE#*x}" \
       --output "$OUT/overview.png"
freeze --execute "nvtop" --window --width "${SIZE%x*}" --height "${SIZE#*x}" \
       --output "$OUT/gpu.png"

echo "Wrote $OUT/overview.png and $OUT/gpu.png"
echo "Note: live TUI capture is timing-sensitive; re-run if a frame is blank."
