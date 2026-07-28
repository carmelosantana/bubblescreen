#!/usr/bin/env bats

setup() {
  export MODE=smart GPU_THRESHOLD=50 GPU_THRESHOLD_HOLD=3 GPU_HYSTERESIS=15 WAKE_ON_GPU=true
  source "${BATS_TEST_DIRNAME}/../src/controller.sh"
  # Stub side effects.
  SHOWN=""; WOKE=0
  bs_show_view() { SHOWN="$SHOWN$1,"; }
  bs_wake_display() { WOKE=$((WOKE+1)); }
  CURRENT_VIEW=overview; CONSEC_ABOVE=0; CONSEC_BELOW=0
}

@test "stays on overview until GPU sustained for hold" {
  bs_read_gpu_util() { echo 70; }
  bs_tick; [ "$SHOWN" = "" ]        # consec_above=1
  bs_tick; [ "$SHOWN" = "" ]        # consec_above=2
  bs_tick                            # consec_above=3 -> switch
  [ "$SHOWN" = "gpu," ]
  [ "$CURRENT_VIEW" = "gpu" ]
  [ "$WOKE" -eq 1 ]
}

@test "returns to overview once GPU drops below threshold minus hysteresis" {
  CURRENT_VIEW=gpu
  bs_read_gpu_util() { echo 30; }
  bs_tick
  [ "$SHOWN" = "overview," ]
  [ "$CURRENT_VIEW" = "overview" ]
}

@test "does not wake on switch when WAKE_ON_GPU=false" {
  WAKE_ON_GPU=false
  bs_read_gpu_util() { echo 99; }
  CONSEC_ABOVE=2
  bs_tick
  [ "$CURRENT_VIEW" = "gpu" ]
  [ "$WOKE" -eq 0 ]
}
