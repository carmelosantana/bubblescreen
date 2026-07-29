#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../src/lib.sh"
  source "${BATS_TEST_DIRNAME}/../src/entrypoint.sh"
  CALLS=""
  setterm() { CALLS="${CALLS}setterm $*;"; }
  chvt()    { CALLS="${CALLS}chvt $*;"; }
  export -f setterm chvt
}

@test "bs_pick_vt honours a numeric TARGET_VT" {
  TARGET_VT=4 run bs_pick_vt
  [ "$output" = "4" ]
}

@test "bs_set_blank translates 1800s to 30 minutes on the target VT" {
  bs_set_blank 7 1800
  [[ "$CALLS" == *"setterm --term linux --blank 30 --powerdown 30"* ]]
}

@test "bs_set_blank with timeout 0 disables blanking" {
  bs_set_blank 7 0
  [[ "$CALLS" == *"--blank 0 --powerdown 0"* ]]
}

@test "bs_restore switches back to the original VT and unblanks" {
  bs_restore 1
  [[ "$CALLS" == *"chvt 1"* ]]
  [[ "$CALLS" == *"--blank 0"* ]]
}

@test "bs_preflight fails when a required console tool is missing" {
  BS_REQUIRED_TOOLS="definitely_not_a_real_command_xyz" run bs_preflight
  [ "$status" -ne 0 ]
}

@test "bs_preflight passes when required tools are present" {
  BS_REQUIRED_TOOLS="true" run bs_preflight
  [ "$status" -eq 0 ]
}

@test "main holds (does not loop) and never calls openvt when console tools are missing" {
  local log="$BATS_TEST_TMPDIR/calls.log"; : > "$log"; export BS_LOG="$log"
  bs_hold() { printf 'HOLD:%s\n' "$1" >> "$BS_LOG"; }   # override: log, don't sleep
  openvt()  { printf 'openvt-called\n' >> "$BS_LOG"; }   # must NOT be reached
  fgconsole() { printf '1\n'; }
  export -f bs_hold openvt fgconsole
  BS_REQUIRED_TOOLS="definitely_not_a_real_command_xyz"
  TARGET_VT=2

  ( main ) || true

  run cat "$log"
  [[ "$output" == *"HOLD:"* ]]
  [[ "$output" != *"openvt-called"* ]]
}

@test "main holds (does not loop) when openvt fails to grab the VT" {
  local stubdir="$BATS_TEST_TMPDIR/stub2"; mkdir -p "$stubdir"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stubdir/layout.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stubdir/controller.sh"
  : > "$stubdir/tmux.conf"; chmod +x "$stubdir/layout.sh" "$stubdir/controller.sh"
  _here="$stubdir"

  local log="$BATS_TEST_TMPDIR/calls2.log"; : > "$log"; export BS_LOG="$log"
  bs_hold()   { printf 'HOLD:%s\n' "$1" >> "$BS_LOG"; }   # override: log, don't sleep
  setterm()   { :; }
  chvt()      { :; }
  fgconsole() { printf '1\n'; }
  gpm()       { :; }
  openvt()    { return 1; }   # openvt present (passes preflight) but fails to attach
  export -f bs_hold setterm chvt fgconsole gpm openvt
  TARGET_VT=2; SCREEN_TIMEOUT=1800; BS_TMUX=true

  ( main ) || true

  run cat "$log"
  [[ "$output" == *"HOLD:"* ]]
}

@test "main attaches with TERM=linux so the tmux client can init the VT" {
  local stubdir="$BATS_TEST_TMPDIR/stub3"; mkdir -p "$stubdir"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stubdir/layout.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stubdir/controller.sh"
  : > "$stubdir/tmux.conf"; chmod +x "$stubdir/layout.sh" "$stubdir/controller.sh"
  _here="$stubdir"

  local log="$BATS_TEST_TMPDIR/term.log"; : > "$log"; export BS_LOG="$log"
  setterm()   { :; }
  chvt()      { :; }
  fgconsole() { printf '1\n'; }
  gpm()       { :; }
  # Record the TERM openvt (hence the tmux client) is given, then succeed.
  openvt()    { printf 'TERM=%s\n' "${TERM:-UNSET}" >> "$BS_LOG"; return 0; }
  export -f setterm chvt fgconsole gpm openvt
  TARGET_VT=2; SCREEN_TIMEOUT=1800; BS_TMUX=true
  unset TERM   # mimic the container PID-1 env; main must set it

  ( main ) || true

  run cat "$log"
  [[ "$output" == *"TERM=linux"* ]]
}

@test "main restores the console on exit (trap fires with orig_vt bound)" {
  # Stub the scripts main invokes by path, and point _here at them.
  local stubdir="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$stubdir"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stubdir/layout.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stubdir/controller.sh"
  : > "$stubdir/tmux.conf"
  chmod +x "$stubdir/layout.sh" "$stubdir/controller.sh"
  _here="$stubdir"

  # Log restore-path calls to a file so they survive main's subshell.
  local log="$BATS_TEST_TMPDIR/calls.log"
  : > "$log"
  export BS_LOG="$log"
  setterm()   { printf 'setterm %s\n' "$*" >> "$BS_LOG"; }
  chvt()      { printf 'chvt %s\n' "$*" >> "$BS_LOG"; }
  fgconsole() { printf '1\n'; }
  openvt()    { :; }
  gpm()       { :; }
  export -f setterm chvt fgconsole openvt gpm

  # Numeric TARGET_VT avoids discovery; BS_TMUX=true avoids a real tmux.
  TARGET_VT=2
  SCREEN_TIMEOUT=1800
  BS_TMUX=true

  # Run main in a subshell so its EXIT trap fires before we assert.
  ( main ) || true

  run cat "$log"
  # Restore must have run: chvt back to the original VT and un-blank.
  [[ "$output" == *"chvt 1"* ]]
  [[ "$output" == *"setterm --term linux --blank 0"* ]]
}
