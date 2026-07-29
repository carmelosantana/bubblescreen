#!/usr/bin/env bats

setup() { source "${BATS_TEST_DIRNAME}/../src/lib.sh"; }

@test "bs_parse_gpu_util reads a single value" {
  run bs_parse_gpu_util "42"
  [ "$output" = "42" ]
}

@test "bs_parse_gpu_util returns max across multiple GPUs" {
  run bs_parse_gpu_util $'7\n88\n13'
  [ "$output" = "88" ]
}

@test "bs_parse_gpu_util ignores non-numeric and empty lines" {
  run bs_parse_gpu_util $'\nN/A\n5\n'
  [ "$output" = "5" ]
}

@test "bs_parse_gpu_util returns 0 when nothing numeric" {
  run bs_parse_gpu_util $'N/A\n[Not Supported]'
  [ "$output" = "0" ]
}

@test "bs_next_index wraps around" {
  run bs_next_index 2 3
  [ "$output" = "0" ]
  run bs_next_index 0 3
  [ "$output" = "1" ]
}

@test "bs_should_show_gpu yes when above and sustained" {
  run bs_should_show_gpu 60 50 3 3
  [ "$output" = "yes" ]
}

@test "bs_should_show_gpu no when above but not yet sustained" {
  run bs_should_show_gpu 60 50 1 3
  [ "$output" = "no" ]
}

@test "bs_should_show_gpu no when below threshold" {
  run bs_should_show_gpu 40 50 9 3
  [ "$output" = "no" ]
}

@test "bs_should_return_overview yes only below threshold minus hysteresis" {
  run bs_should_return_overview 34 50 15
  [ "$output" = "yes" ]
  run bs_should_return_overview 40 50 15
  [ "$output" = "no" ]
}

@test "bs_blank_minutes 0 disables" {
  run bs_blank_minutes 0
  [ "$output" = "0" ]
}

@test "bs_blank_minutes rounds seconds to minutes" {
  run bs_blank_minutes 1800
  [ "$output" = "30" ]
}

@test "bs_blank_minutes floors to at least 1 for small positive timeouts" {
  run bs_blank_minutes 20
  [ "$output" = "1" ]
}

@test "bs_blank_minutes clamps to 60" {
  run bs_blank_minutes 7200
  [ "$output" = "60" ]
}

@test "bs_app_cmd maps known apps to commands" {
  run bs_app_cmd htop
  [ "$output" = "htop" ]
  run bs_app_cmd nvtop
  [ "$output" = "nvtop" ]
}

@test "bs_app_cmd fails on an unknown app" {
  run bs_app_cmd bogus
  [ "$status" -ne 0 ]
}

@test "bs_parse_apps keeps a valid list in order, space-joined" {
  run bs_parse_apps "htop,nvtop"
  [ "$output" = "htop nvtop" ]
}

@test "bs_parse_apps accepts a single app" {
  run bs_parse_apps "nvtop"
  [ "$output" = "nvtop" ]
}

@test "bs_parse_apps trims whitespace" {
  run bs_parse_apps " htop , nvtop "
  [ "$output" = "htop nvtop" ]
}

@test "bs_parse_apps drops unknown apps but keeps valid ones" {
  run bs_parse_apps "htop,bogus"
  [ "$output" = "htop" ]
}

@test "bs_parse_apps falls back to the default when empty or all-invalid" {
  run bs_parse_apps ""
  [ "$output" = "htop nvtop" ]
  run bs_parse_apps "bogus,nope"
  [ "$output" = "htop nvtop" ]
}
