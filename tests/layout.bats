#!/usr/bin/env bats

SOCK=bstest
T() { tmux -L "$SOCK" "$@"; }
export SOCK
export -f T

setup() {
  export BS_TMUX="tmux -L $SOCK"
  export BS_OVERVIEW_CMD="sleep 300"
  export BS_GPU_CMD="sleep 300"
  source "${BATS_TEST_DIRNAME}/../src/layout.sh"
}
teardown() { T kill-server 2>/dev/null || true; }

@test "split mode: one window, two panes" {
  MODE=split bs_build_layout dash
  run bash -c "T list-windows -t dash | wc -l"
  [ "$output" -eq 1 ]
  run bash -c "T list-panes -t dash | wc -l"
  [ "$output" -eq 2 ]
}

@test "smart mode: overview and gpu windows in order" {
  MODE=smart bs_build_layout dash
  run bash -c "T list-windows -t dash -F '#{window_index}:#{window_name}' | tr '\n' ','"
  [ "$output" = "0:overview,1:gpu," ]
}

@test "smart mode: overview window is split into two panes" {
  MODE=smart bs_build_layout dash
  run bash -c "T list-panes -t dash:overview | wc -l"
  [ "$output" -eq 2 ]
}
