#!/usr/bin/env bats

SOCK=bstest
T() { tmux -L "$SOCK" "$@"; }
export SOCK
export -f T

setup() {
  export BS_TMUX="tmux -L $SOCK"
  source "${BATS_TEST_DIRNAME}/../src/layout.sh"
  # Run harmless placeholders instead of real htop/nvtop (not installed on the
  # test runner); keep unknown apps failing so bs_parse_apps still validates.
  bs_app_cmd() { case "$1" in htop|nvtop) echo "sleep 300";; *) return 1;; esac; }
  export -f bs_app_cmd
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

@test "single app (APPS=nvtop): one 'main' window, one pane, MODE ignored" {
  APPS=nvtop MODE=smart bs_build_layout dash
  run bash -c "T list-windows -t dash -F '#{window_name}' | tr '\n' ','"
  [ "$output" = "main," ]
  run bash -c "T list-panes -t dash | wc -l"
  [ "$output" -eq 1 ]
}

@test "single app (APPS=htop): one 'main' window even in split mode" {
  APPS=htop MODE=split bs_build_layout dash
  run bash -c "T list-windows -t dash -F '#{window_name}' | tr '\n' ','"
  [ "$output" = "main," ]
}

@test "explicit APPS=htop,nvtop split still builds two panes" {
  APPS=htop,nvtop MODE=split bs_build_layout dash
  run bash -c "T list-panes -t dash | wc -l"
  [ "$output" -eq 2 ]
}
