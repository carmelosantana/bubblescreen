#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../src/lib.sh"
  source "${BATS_TEST_DIRNAME}/../src/entrypoint.sh"
  CALLS=""
  setterm()  { CALLS="${CALLS}setterm $*;"; }
  chvt()     { CALLS="${CALLS}chvt $*;"; }
  ddcutil()  { CALLS="${CALLS}ddcutil $*;"; }
  modprobe() { :; }
  export -f setterm chvt ddcutil modprobe
}

@test "bs_pick_vt honours a numeric TARGET_VT" {
  TARGET_VT=4 run bs_pick_vt
  [ "$output" = "4" ]
}

@test "bs_restore switches back to the original VT and wakes the monitor" {
  bs_restore 1
  [[ "$CALLS" == *"chvt 1"* ]]
  [[ "$CALLS" == *"ddcutil setvcp --noverify d6 01"* ]]
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

@test "main falls back to VT 1 when the console is already on our target VT" {
  local stubdir="$BATS_TEST_TMPDIR/stubvt"; mkdir -p "$stubdir"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stubdir/layout.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stubdir/controller.sh"
  : > "$stubdir/tmux.conf"; chmod +x "$stubdir/layout.sh" "$stubdir/controller.sh"
  _here="$stubdir"

  local log="$BATS_TEST_TMPDIR/vt.log"; : > "$log"; export BS_LOG="$log"
  setterm()   { :; }
  chvt()      { printf 'chvt %s\n' "$*" >> "$BS_LOG"; }
  fgconsole() { printf '7\n'; }   # a prior instance already switched to VT 7
  gpm()       { :; }
  openvt()    { return 0; }
  export -f setterm chvt fgconsole gpm openvt
  TARGET_VT=7; SCREEN_TIMEOUT=1800; BS_TMUX=true   # our VT is also 7

  ( main ) || true                 # normal exit -> EXIT trap runs bs_restore

  run cat "$log"
  [[ "$output" == *"chvt 1"* ]]    # restored to the console, NOT our own VT
  [[ "$output" != *"chvt 7"* ]]
}

@test "main restores the console on SIGTERM (trap + restore path runs on stop)" {
  local stubdir="$BATS_TEST_TMPDIR/stub5"; mkdir -p "$stubdir/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stubdir/layout.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stubdir/controller.sh"
  : > "$stubdir/tmux.conf"; chmod +x "$stubdir/layout.sh" "$stubdir/controller.sh"
  _here="$stubdir"
  # openvt must be a real EXTERNAL command that BLOCKS, to faithfully reproduce a
  # foreground `openvt -w` (a shell-function stub would let bash run the trap even
  # in the foreground, hiding the bug). This blocks until killed.
  printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$stubdir/bin/openvt"
  chmod +x "$stubdir/bin/openvt"
  PATH="$stubdir/bin:$PATH"

  local log="$BATS_TEST_TMPDIR/term.log"; : > "$log"; export BS_LOG="$log"
  setterm()   { printf 'setterm %s\n' "$*" >> "$BS_LOG"; }
  chvt()      { printf 'chvt %s\n' "$*" >> "$BS_LOG"; }
  fgconsole() { printf '1\n'; }
  gpm()       { :; }
  export -f setterm chvt fgconsole gpm
  TARGET_VT=2; SCREEN_TIMEOUT=1800; BS_TMUX=true

  ( main ) &
  local mpid=$!
  sleep 0.5                    # let main reach `wait`
  kill -TERM "$mpid"
  # Poll: with background+wait the trap fires now; a foreground openvt would defer
  # it until openvt returns (30s), so chvt would NOT appear within this window.
  local i
  for i in $(seq 1 15); do grep -q 'chvt 1' "$log" && break; sleep 0.2; done
  pkill -P "$mpid" 2>/dev/null || true
  kill "$mpid" 2>/dev/null || true
  pkill -f "$stubdir/bin/openvt" 2>/dev/null || true

  run cat "$log"
  [[ "$output" == *"chvt 1"* ]]                       # restore ran on SIGTERM
}

@test "main forces the VT takeover with openvt -f (VT may be in use from a prior run)" {
  local stubdir="$BATS_TEST_TMPDIR/stub4"; mkdir -p "$stubdir"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stubdir/layout.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stubdir/controller.sh"
  : > "$stubdir/tmux.conf"; chmod +x "$stubdir/layout.sh" "$stubdir/controller.sh"
  _here="$stubdir"

  local log="$BATS_TEST_TMPDIR/args.log"; : > "$log"; export BS_LOG="$log"
  setterm() { :; }; chvt() { :; }; fgconsole() { printf '1\n'; }; gpm() { :; }
  openvt()  { printf 'ARGS=%s\n' "$*" >> "$BS_LOG"; return 0; }
  export -f setterm chvt fgconsole gpm openvt
  TARGET_VT=2; SCREEN_TIMEOUT=1800; BS_TMUX=true

  ( main ) || true

  run cat "$log"
  # openvt's own flags must lead with -f -c (force the specific VT).
  [[ "$output" == *"ARGS=-f -c 2 "* ]]
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
  # Reproduce the real container env: TERM=dumb (a bad, NON-EMPTY value that
  # ${TERM:-linux} would wrongly keep). main must override it to linux.
  export TERM=dumb

  ( main ) || true

  run cat "$log"
  [[ "$output" == *"TERM=linux"* ]]
  [[ "$output" != *"TERM=dumb"* ]]
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
  # Restore must have run: chvt back to the original VT.
  [[ "$output" == *"chvt 1"* ]]
}
