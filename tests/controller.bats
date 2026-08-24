#!/usr/bin/env bats

setup() {
  export MODE=smart GPU_THRESHOLD=50 GPU_THRESHOLD_HOLD=3 GPU_HYSTERESIS=15 WAKE_ON_GPU=true
  source "${BATS_TEST_DIRNAME}/../src/controller.sh"
  # Stub side effects.
  SHOWN=""; WOKE=0
  bs_show_view()    { SHOWN="$SHOWN$1,"; }
  bs_wake_display() { WOKE=$((WOKE+1)); }
  CURRENT_VIEW=overview; CONSEC_ABOVE=0; CONSEC_BELOW=0; WAKE_LATCH=0
}

@test "update_consec counts above/below streaks" {
  bs_update_consec 70; [ "$CONSEC_ABOVE" -eq 1 ]; [ "$CONSEC_BELOW" -eq 0 ]
  bs_update_consec 70; [ "$CONSEC_ABOVE" -eq 2 ]
  bs_update_consec 10; [ "$CONSEC_ABOVE" -eq 0 ]; [ "$CONSEC_BELOW" -eq 1 ]
}

@test "smart view switches to gpu only after the hold is met" {
  CONSEC_ABOVE=1; bs_view_step 70; [ "$SHOWN" = "" ]
  CONSEC_ABOVE=3; bs_view_step 70; [ "$SHOWN" = "gpu," ]; [ "$CURRENT_VIEW" = "gpu" ]
}

@test "smart view returns to overview below threshold minus hysteresis" {
  CURRENT_VIEW=gpu
  bs_view_step 30
  [ "$SHOWN" = "overview," ]; [ "$CURRENT_VIEW" = "overview" ]
}

@test "gpu spike wakes once per spike and re-arms after it subsides" {
  CONSEC_ABOVE=3
  bs_wake_step 70; [ "$WOKE" -eq 1 ]; [ "$WAKE_LATCH" -eq 1 ]
  bs_wake_step 70; [ "$WOKE" -eq 1 ]                 # still latched — no repeat
  bs_wake_step 30; [ "$WAKE_LATCH" -eq 0 ]           # subsided — re-armed
  bs_wake_step 70; [ "$WOKE" -eq 2 ]                 # next spike wakes again
}

@test "no GPU wake when WAKE_ON_GPU=false" {
  WAKE_ON_GPU=false; CONSEC_ABOVE=9
  bs_wake_step 99
  [ "$WOKE" -eq 0 ]
}
