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
