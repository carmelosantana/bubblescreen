#!/usr/bin/env bats
# DDC/CI display power management: sleep on input-idle, wake on input/GPU.

setup() {
  export SCREEN_TIMEOUT=300 BS_TMUX=true
  source "${BATS_TEST_DIRNAME}/../src/controller.sh"
  # Record DDC power writes and repaints instead of touching hardware.
  DDC=""; bs_ddc_power() { DDC="$DDC$1,"; }
  REFRESH=0; bs_refresh_client() { REFRESH=$((REFRESH+1)); }
  modprobe() { :; }   # never touch real kernel modules in tests
  BS_INPUT_STAMP="$BATS_TEST_TMPDIR/stamp"; : > "$BS_INPUT_STAMP"
  BS_DDC_AVAILABLE=1; BS_DDC_BUS=2; MONITOR_STATE=on
}

@test "display_off puts the monitor to standby once; a repeat is a no-op" {
  bs_display_off; [ "$DDC" = "04," ]; [ "$MONITOR_STATE" = "off" ]
  bs_display_off; [ "$DDC" = "04," ]
}

@test "display_on wakes and repaints only when the monitor was off" {
  MONITOR_STATE=off
  bs_display_on; [ "$DDC" = "01," ]; [ "$REFRESH" -eq 1 ]; [ "$MONITOR_STATE" = "on" ]
  bs_display_on; [ "$DDC" = "01," ]; [ "$REFRESH" -eq 1 ]
}

@test "no DDC display suppresses every power write" {
  BS_DDC_AVAILABLE=0
  bs_display_off; [ "$DDC" = "" ]
  MONITOR_STATE=off; bs_display_on; [ "$DDC" = "" ]
}

@test "power_step sleeps once idle reaches the timeout and wakes below it" {
  bs_idle_secs() { echo 300; }; bs_power_step
  [ "$MONITOR_STATE" = "off" ]; [ "$DDC" = "04," ]
  bs_idle_secs() { echo 5; };   bs_power_step
  [ "$MONITOR_STATE" = "on" ];  [ "$DDC" = "04,01," ]
}

@test "power_step with SCREEN_TIMEOUT=0 never sleeps" {
  SCREEN_TIMEOUT=0; bs_idle_secs() { echo 99999; }
  bs_power_step
  [ "$MONITOR_STATE" = "on" ]; [ "$DDC" = "" ]
}

@test "wake_display stamps activity and turns the monitor on" {
  MONITOR_STATE=off; touch -d '2001-01-01' "$BS_INPUT_STAMP"
  bs_wake_display
  [ "$DDC" = "01," ]; [ "$MONITOR_STATE" = "on" ]
  run bs_idle_secs; [ "$output" -lt 5 ]
}

@test "sync_i2c_nodes mknods the char devices from sysfs major:minor" {
  local sys="$BATS_TEST_TMPDIR/i2c"; mkdir -p "$sys/i2c-2" "$sys/i2c-5"
  echo "89:2" > "$sys/i2c-2/dev"; echo "89:5" > "$sys/i2c-5/dev"
  BS_I2C_CLASS_GLOB="$sys/i2c-*"
  BS_I2C_DEV_PREFIX="$BATS_TEST_TMPDIR/dev-i2c-"   # so [ -e ] never hits real /dev
  MK=""; mknod() { MK="$MK mknod:$*"; }
  bs_sync_i2c_nodes
  [[ "$MK" == *"mknod:${BS_I2C_DEV_PREFIX}2 c 89 2"* ]]
  [[ "$MK" == *"mknod:${BS_I2C_DEV_PREFIX}5 c 89 5"* ]]
}

@test "ddc_init records the detected bus and marks DDC available" {
  ddcutil() { printf 'Display 1\n   I2C bus:  /dev/i2c-3\n'; }
  BS_DDC_AVAILABLE=0; BS_DDC_BUS=""
  bs_ddc_init
  [ "$BS_DDC_AVAILABLE" -eq 1 ]; [ "$BS_DDC_BUS" = "3" ]
}

@test "ddc_init degrades gracefully when no display answers" {
  ddcutil() { printf 'Display detection failed.\n'; return 0; }
  BS_DDC_AVAILABLE=1
  bs_ddc_init
  [ "$BS_DDC_AVAILABLE" -eq 0 ]
}
