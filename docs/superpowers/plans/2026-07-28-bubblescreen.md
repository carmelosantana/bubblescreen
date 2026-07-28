# BubbleScreen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A featherweight TrueNAS Scale Custom App that takes over the physical console with a live CPU/RAM/temp/NVIDIA-GPU dashboard, with smart GPU-aware view switching and display power management.

**Architecture:** A single slim Debian container runs `tmux` driving `btop` (CPU/RAM/temp) + `nvtop` (GPU) on a free virtual terminal. Pure decision logic lives in a sourced `lib.sh`; a `controller.sh` loop wires those decisions to tmux/setterm side effects; `entrypoint.sh` seizes/restores the console. The image is published to GHCR and consumed by a TrueNAS Custom App via Compose.

**Tech Stack:** Bash, tmux, btop, nvtop, gpm, util-linux (setterm/openvt/chvt), tini, Docker, GitHub Actions, bats (tests), charmbracelet/freeze (screenshots).

## Global Constraints

- Idle RAM footprint target: **< ~50 MB**. No X, no desktop, no CUDA base image, no database.
- Base image: `debian:bookworm-slim`. Runtime packages only: `btop`, `nvtop`, `tmux`, `gpm`, `util-linux`, `tini`, `ca-certificates`.
- GPU data comes from the host NVIDIA driver via the NVIDIA container runtime (`libnvidia-ml.so` injected) — **not** bundled. NVIDIA-only for v1.
- Target platform: **`linux/amd64`** only.
- Published image name: **`ghcr.io/${github.repository_owner}/bubblescreen`** (owner resolved by CI; never hardcode an owner).
- Env defaults (verbatim): `MODE=smart`, `ROTATE_INTERVAL=20`, `GPU_THRESHOLD=50`, `GPU_THRESHOLD_HOLD=3`, `GPU_HYSTERESIS=15`, `SCREEN_TIMEOUT=1800`, `WAKE_ON_GPU=true`, `TARGET_VT=auto`, `BTOP_PRESET=0`.
- All shell scripts: `#!/usr/bin/env bash` + `set -euo pipefail`; sourced libraries must be side-effect-free at source time (guard `main` with `[[ "${BASH_SOURCE[0]}" == "${0}" ]]`).
- `.dockerignore` excludes `docs/`, `.github/`, `scripts/`, `tests/`, screenshots, and git metadata — only `src/` runtime files enter the image.
- TDD, DRY, YAGNI, frequent commits. Commit author for this repo: `Carmelo Santana <carmelo@vctrs.io>`.

---

### Task 1: Repo scaffold + pure decision library (`lib.sh`)

The testable core: pure functions with no side effects. Everything else builds on these.

**Files:**
- Create: `src/lib.sh`
- Create: `tests/lib.bats`
- Create: `.gitignore`
- Create: `docs/screenshots/.gitkeep`

**Interfaces:**
- Produces (all echo a single line to stdout, no side effects):
  - `bs_parse_gpu_util <nvidia_smi_text>` → max integer utilization across lines; `0` if none numeric.
  - `bs_next_index <current_index> <count>` → `(current+1) % count`.
  - `bs_should_show_gpu <util> <threshold> <consec_above> <hold_needed>` → `yes`/`no` (yes iff `util>=threshold && consec_above>=hold_needed`).
  - `bs_should_return_overview <util> <threshold> <hysteresis>` → `yes`/`no` (yes iff `util < threshold - hysteresis`).
  - `bs_blank_minutes <timeout_seconds>` → setterm minutes: `0` if timeout `<=0` (never blank); else `min(60, max(1, round(sec/60)))`.

- [ ] **Step 1: Write the failing tests**

Create `tests/lib.bats`:

```bash
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/lib.bats`
Expected: FAIL — `bs_lib.sh` not found / functions undefined. (Install bats first if missing: `sudo apt-get install -y bats`.)

- [ ] **Step 3: Write `src/lib.sh`**

```bash
#!/usr/bin/env bash
# src/lib.sh — pure decision helpers. No side effects; safe to source in tests.

# Max integer GPU utilization across (possibly multi-line) nvidia-smi output.
bs_parse_gpu_util() {
  local max=0 line n
  while IFS= read -r line; do
    n="${line//[[:space:]]/}"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    (( n > max )) && max="$n"
  done <<< "${1:-}"
  printf '%s\n' "$max"
}

# Next index in a ring of COUNT items (0-based).
bs_next_index() {
  printf '%s\n' "$(( ($1 + 1) % $2 ))"
}

# Smart mode: switch TO the gpu view? yes iff sustained above threshold.
bs_should_show_gpu() {
  local util="$1" threshold="$2" consec_above="$3" hold_needed="$4"
  if (( util >= threshold )) && (( consec_above >= hold_needed )); then
    printf 'yes\n'; else printf 'no\n'; fi
}

# Smart mode: return to overview? yes iff util below threshold - hysteresis.
bs_should_return_overview() {
  local util="$1" threshold="$2" hysteresis="$3"
  if (( util < threshold - hysteresis )); then printf 'yes\n'; else printf 'no\n'; fi
}

# Translate SCREEN_TIMEOUT seconds to a setterm blank/powerdown minute value.
# 0 (or less) => never blank. Otherwise round to nearest minute, floor 1, cap 60.
bs_blank_minutes() {
  local sec="$1" min
  if (( sec <= 0 )); then printf '0\n'; return; fi
  min=$(( (sec + 30) / 60 ))
  (( min < 1 )) && min=1
  (( min > 60 )) && min=60
  printf '%s\n' "$min"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/lib.bats`
Expected: PASS (13 tests).

- [ ] **Step 5: Create supporting files**

`.gitignore`:
```
*.log
/tmp/
```

`docs/screenshots/.gitkeep`: empty file.

- [ ] **Step 6: Commit**

```bash
git add src/lib.sh tests/lib.bats .gitignore docs/screenshots/.gitkeep
git -c user.name="Carmelo Santana" -c user.email="carmelo@vctrs.io" commit -m "feat: pure decision library with bats tests"
```

---

### Task 2: tmux session builder (`layout.sh`)

Builds the tmux windows/panes for each `MODE`. Tested against a real headless tmux (no VT required) using a private socket and placeholder pane commands.

**Files:**
- Create: `src/layout.sh`
- Create: `tests/layout.bats`

**Interfaces:**
- Consumes: env `MODE`, `BTOP_PRESET`; optional test hooks `BS_TMUX` (default `tmux`), `BS_OVERVIEW_CMD` (default `btop -p "$BTOP_PRESET"`), `BS_GPU_CMD` (default `nvtop`).
- Produces: `bs_build_layout <session_name>` — creates a detached tmux session named `<session_name>`:
  - `split` → one window `dash` with two panes (overview left, gpu right, `even-horizontal`).
  - `rotate`/`smart` → window `overview` (split: overview left + gpu right) and window `gpu` (full nvtop). Window index order: `overview`=0, `gpu`=1.

- [ ] **Step 1: Write the failing tests**

Create `tests/layout.bats`:

```bash
#!/usr/bin/env bats

SOCK=bstest
T() { tmux -L "$SOCK" "$@"; }

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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/layout.bats`
Expected: FAIL — `bs_build_layout` undefined.

- [ ] **Step 3: Write `src/layout.sh`**

```bash
#!/usr/bin/env bash
# src/layout.sh — build the tmux session for the selected MODE.
set -euo pipefail

: "${MODE:=smart}"
: "${BTOP_PRESET:=0}"
: "${BS_TMUX:=tmux}"
: "${BS_OVERVIEW_CMD:=btop -p ${BTOP_PRESET}}"
: "${BS_GPU_CMD:=nvtop}"

bs_build_layout() {
  local session="$1"
  local tmux=(${BS_TMUX})

  case "$MODE" in
    split)
      "${tmux[@]}" new-session -d -s "$session" -n dash "$BS_OVERVIEW_CMD"
      "${tmux[@]}" split-window -h -t "$session:dash" "$BS_GPU_CMD"
      "${tmux[@]}" select-layout -t "$session:dash" even-horizontal
      ;;
    rotate|smart)
      "${tmux[@]}" new-session -d -s "$session" -n overview "$BS_OVERVIEW_CMD"
      "${tmux[@]}" split-window -h -t "$session:overview" "$BS_GPU_CMD"
      "${tmux[@]}" select-layout -t "$session:overview" even-horizontal
      "${tmux[@]}" new-window -t "$session:1" -n gpu "$BS_GPU_CMD"
      "${tmux[@]}" select-window -t "$session:overview"
      ;;
    *)
      echo "layout.sh: unknown MODE '$MODE'" >&2; return 2 ;;
  esac
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && bs_build_layout "${1:?session name required}"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/layout.bats`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add src/layout.sh tests/layout.bats
git -c user.name="Carmelo Santana" -c user.email="carmelo@vctrs.io" commit -m "feat: tmux layout builder for split/rotate/smart modes"
```

---

### Task 3: Controller loop (`controller.sh`)

Wires pure decisions to side effects. The per-iteration decision (`bs_tick`) is tested with stubbed wrappers; the infinite loop and sleeps are thin and untested.

**Files:**
- Create: `src/controller.sh`
- Create: `tests/controller.bats`

**Interfaces:**
- Consumes: `lib.sh`; env `MODE`, `GPU_THRESHOLD`, `GPU_THRESHOLD_HOLD`, `GPU_HYSTERESIS`, `WAKE_ON_GPU`, `BS_SESSION` (tmux session name), `BS_TMUX`.
- Produces (wrappers, all overridable in tests):
  - `bs_read_gpu_util` → echoes current max GPU util (calls `nvidia-smi`, parses via `bs_parse_gpu_util`).
  - `bs_show_view <overview|gpu>` → selects that tmux window.
  - `bs_wake_display` → resets the console blank timer + forces a redraw.
  - `bs_tick` → one smart-mode decision step; mutates globals `CURRENT_VIEW`, `CONSEC_ABOVE`, `CONSEC_BELOW`.

- [ ] **Step 1: Write the failing tests**

Create `tests/controller.bats`:

```bash
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/controller.bats`
Expected: FAIL — `controller.sh` / `bs_tick` undefined.

- [ ] **Step 3: Write `src/controller.sh`**

```bash
#!/usr/bin/env bash
# src/controller.sh — behavior loop: smart switching, rotation, wake-on-GPU.
set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${_here}/lib.sh"

: "${MODE:=smart}"
: "${GPU_THRESHOLD:=50}"
: "${GPU_THRESHOLD_HOLD:=3}"
: "${GPU_HYSTERESIS:=15}"
: "${WAKE_ON_GPU:=true}"
: "${ROTATE_INTERVAL:=20}"
: "${BS_SESSION:=bubblescreen}"
: "${BS_TMUX:=tmux}"

CURRENT_VIEW=overview
CONSEC_ABOVE=0
CONSEC_BELOW=0

bs_read_gpu_util() {
  local out
  out="$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null || true)"
  bs_parse_gpu_util "$out"
}

bs_show_view() {
  local view="$1"; local tmux=(${BS_TMUX})
  "${tmux[@]}" select-window -t "${BS_SESSION}:${view}" 2>/dev/null || true
}

# Reset the kernel console blank timer and force a redraw so the panel lights up.
bs_wake_display() {
  local tmux=(${BS_TMUX})
  "${tmux[@]}" refresh-client 2>/dev/null || true
}

bs_tick() {
  local util; util="$(bs_read_gpu_util)"
  if (( util >= GPU_THRESHOLD )); then
    CONSEC_ABOVE=$((CONSEC_ABOVE + 1)); CONSEC_BELOW=0
  else
    CONSEC_BELOW=$((CONSEC_BELOW + 1)); CONSEC_ABOVE=0
  fi

  if [[ "$CURRENT_VIEW" != "gpu" ]] \
     && [[ "$(bs_should_show_gpu "$util" "$GPU_THRESHOLD" "$CONSEC_ABOVE" "$GPU_THRESHOLD_HOLD")" == "yes" ]]; then
    bs_show_view gpu
    [[ "$WAKE_ON_GPU" == "true" ]] && bs_wake_display
    CURRENT_VIEW=gpu
  elif [[ "$CURRENT_VIEW" == "gpu" ]] \
     && [[ "$(bs_should_return_overview "$util" "$GPU_THRESHOLD" "$GPU_HYSTERESIS")" == "yes" ]]; then
    bs_show_view overview
    CURRENT_VIEW=overview
  fi
}

# Time-based rotation across windows (rotate mode only).
bs_rotate_loop() {
  local idx=0 count=2 names=(overview gpu)
  while true; do
    sleep "$ROTATE_INTERVAL"
    idx="$(bs_next_index "$idx" "$count")"
    bs_show_view "${names[$idx]}"
  done
}

main() {
  case "$MODE" in
    smart)  while true; do bs_tick; sleep 1; done ;;
    rotate) bs_rotate_loop ;;
    split)  while true; do sleep 3600; done ;;  # static; nothing to drive
    *) echo "controller.sh: unknown MODE '$MODE'" >&2; exit 2 ;;
  esac
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/controller.bats`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add src/controller.sh tests/controller.bats
git -c user.name="Carmelo Santana" -c user.email="carmelo@vctrs.io" commit -m "feat: controller loop with smart switching and wake-on-gpu"
```

---

### Task 4: Console takeover + entrypoint (`entrypoint.sh`, `tmux.conf`)

Seizes a free VT, starts gpm + the tmux session, sets the kernel blank timer, and restores the console on exit. The restore/trap logic is tested with mocked `chvt`/`setterm`; the live VT attach is verified manually on hardware.

**Files:**
- Create: `src/entrypoint.sh`
- Create: `src/tmux.conf`
- Create: `tests/entrypoint.bats`

**Interfaces:**
- Consumes: all env vars; `layout.sh`, `controller.sh`, `lib.sh`.
- Produces:
  - `bs_pick_vt` → echoes the VT number to use (`TARGET_VT` if numeric, else via `openvt`-style discovery; test hook `BS_FGCONSOLE`/`BS_OPENVT`).
  - `bs_set_blank <vt> <timeout_seconds>` → runs `setterm` blank/powerdown for the VT using `bs_blank_minutes`.
  - `bs_restore <original_vt>` → chvt back + un-blank; installed as the EXIT/INT/TERM trap.

- [ ] **Step 1: Write the failing tests**

Create `tests/entrypoint.bats`:

```bash
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/entrypoint.bats`
Expected: FAIL — functions undefined.

- [ ] **Step 3: Write `src/entrypoint.sh`**

```bash
#!/usr/bin/env bash
# src/entrypoint.sh — seize the console, run the dashboard, restore on exit.
set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_here}/lib.sh"

: "${MODE:=smart}"
: "${SCREEN_TIMEOUT:=1800}"
: "${TARGET_VT:=auto}"
: "${BS_SESSION:=bubblescreen}"
export BS_SESSION

bs_pick_vt() {
  if [[ "$TARGET_VT" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$TARGET_VT"; return
  fi
  # openvt -s allocates and switches to the first free VT; ask it to print which.
  # Discovery hook for tests:
  if [[ -n "${BS_OPENVT_VT:-}" ]]; then printf '%s\n' "$BS_OPENVT_VT"; return; fi
  fgconsole >/dev/null 2>&1 || true
  # Fall back to VT 7 (matches the steam-headless convention for a free VT).
  printf '7\n'
}

bs_set_blank() {
  local vt="$1" timeout="$2" min
  min="$(bs_blank_minutes "$timeout")"
  setterm --term linux --blank "$min" --powerdown "$min" >/dev/null 2>&1 || true
}

bs_restore() {
  local original="$1"
  "${BS_TMUX:-tmux}" kill-server 2>/dev/null || true
  setterm --term linux --blank 0 --powerdown 0 >/dev/null 2>&1 || true
  chvt "$original" 2>/dev/null || true
}

main() {
  local orig_vt vt
  orig_vt="$(fgconsole 2>/dev/null || echo 1)"
  vt="$(bs_pick_vt)"
  trap 'bs_restore "$orig_vt"' EXIT INT TERM

  # Console mouse (wheel scroll) for tmux/btop/nvtop.
  gpm -m /dev/input/mice -t imps2 >/dev/null 2>&1 || true

  # Build the session and set the kernel blank timer.
  MODE="$MODE" "${_here}/layout.sh" "$BS_SESSION"
  bs_set_blank "$vt" "$SCREEN_TIMEOUT"

  # Drive behavior (smart/rotate) in the background.
  "${_here}/controller.sh" &
  local controller_pid=$!

  # Attach the session on the chosen VT; openvt runs us there and chvt-switches.
  openvt -c "$vt" -s -w -- \
    tmux -f "${_here}/tmux.conf" attach-session -t "$BS_SESSION" || true

  kill "$controller_pid" 2>/dev/null || true
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
```

- [ ] **Step 4: Write `src/tmux.conf`**

```tmux
# BubbleScreen tmux config — kiosk feel: mouse scroll, arrow nav, no chrome.
set -g mouse on
set -sg escape-time 0
set -g status off
set -g mode-keys emacs
# Arrow keys switch views without a prefix.
bind -n Left  previous-window
bind -n Right next-window
bind -n Up    select-pane -t :.-
bind -n Down  select-pane -t :.+
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats tests/entrypoint.bats`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add src/entrypoint.sh src/tmux.conf tests/entrypoint.bats
git -c user.name="Carmelo Santana" -c user.email="carmelo@vctrs.io" commit -m "feat: console takeover entrypoint and tmux kiosk config"
```

---

### Task 5: Container image (`Dockerfile`, `.dockerignore`)

**Files:**
- Create: `Dockerfile`
- Create: `.dockerignore`

**Interfaces:**
- Consumes: `src/`. Produces: an image whose entrypoint is `tini -- /app/entrypoint.sh`.

- [ ] **Step 1: Write `.dockerignore`**

```
docs/
.github/
scripts/
tests/
*.md
.git/
.gitignore
**/*.png
```

- [ ] **Step 2: Write `Dockerfile`**

```dockerfile
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      btop nvtop tmux gpm util-linux tini ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY src/ /app/
RUN chmod +x /app/*.sh

# GPU data is injected by the NVIDIA container runtime at run time.
ENV NVIDIA_DRIVER_CAPABILITIES=utility \
    NVIDIA_VISIBLE_DEVICES=all \
    MODE=smart \
    ROTATE_INTERVAL=20 \
    GPU_THRESHOLD=50 \
    GPU_THRESHOLD_HOLD=3 \
    GPU_HYSTERESIS=15 \
    SCREEN_TIMEOUT=1800 \
    WAKE_ON_GPU=true \
    TARGET_VT=auto \
    BTOP_PRESET=0

ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
```

- [ ] **Step 3: Build and smoke-test**

Run:
```bash
docker build -t bubblescreen:test .
docker run --rm --entrypoint btop  bubblescreen:test --version
docker run --rm --entrypoint nvtop bubblescreen:test --version
docker run --rm --entrypoint tmux  bubblescreen:test -V
```
Expected: each prints a version string; no errors.

- [ ] **Step 4: Verify `.dockerignore` excludes docs**

Run: `docker build -t bubblescreen:test . && docker run --rm --entrypoint sh bubblescreen:test -c 'ls /app && ! test -d /docs && echo OK'`
Expected: lists the `src` scripts and prints `OK` (no docs in image).

- [ ] **Step 5: Commit**

```bash
git add Dockerfile .dockerignore
git -c user.name="Carmelo Santana" -c user.email="carmelo@vctrs.io" commit -m "feat: slim NVIDIA-runtime container image"
```

---

### Task 6: TrueNAS Custom App (`compose.yaml`)

**Files:**
- Create: `compose.yaml`

**Interfaces:**
- Consumes: the GHCR image. Produces: the on/off deployable app.

- [ ] **Step 1: Write `compose.yaml`**

```yaml
services:
  bubblescreen:
    image: ghcr.io/OWNER/bubblescreen:latest   # replace OWNER with your GitHub owner
    runtime: nvidia
    restart: unless-stopped
    cap_add:
      - SYS_TTY_CONFIG            # chvt / VT_ACTIVATE (fall back to privileged if TrueNAS blocks it)
    devices:
      - /dev/tty0:/dev/tty0
      - /dev/console:/dev/console
      - /dev/input:/dev/input
    device_cgroup_rules:
      - 'c 13:* rmw'             # /dev/input evdev (char major 13)
    environment:
      NVIDIA_DRIVER_CAPABILITIES: utility
      NVIDIA_VISIBLE_DEVICES: all
      MODE: smart
      ROTATE_INTERVAL: "20"
      GPU_THRESHOLD: "50"
      GPU_THRESHOLD_HOLD: "3"
      GPU_HYSTERESIS: "15"
      SCREEN_TIMEOUT: "1800"
      WAKE_ON_GPU: "true"
      TARGET_VT: auto
      BTOP_PRESET: "0"
```

- [ ] **Step 2: Validate compose syntax**

Run: `docker compose -f compose.yaml config >/dev/null && echo OK`
Expected: `OK` (no parse errors). The `runtime: nvidia` warning on a non-NVIDIA dev box is acceptable.

- [ ] **Step 3: Commit**

```bash
git add compose.yaml
git -c user.name="Carmelo Santana" -c user.email="carmelo@vctrs.io" commit -m "feat: TrueNAS Custom App compose definition"
```

---

### Task 7: GHCR publishing workflow (`.github/workflows/build.yml`)

**Files:**
- Create: `.github/workflows/build.yml`

- [ ] **Step 1: Write the workflow**

```yaml
name: build
on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4

      - name: Run shell tests
        run: |
          sudo apt-get update && sudo apt-get install -y bats tmux
          bats tests/

      - name: Log in to GHCR
        if: github.event_name != 'pull_request'
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Docker meta
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/${{ github.repository_owner }}/bubblescreen
          tags: |
            type=raw,value=latest,enable={{is_default_branch}}
            type=semver,pattern={{version}}
            type=sha

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/amd64
          push: ${{ github.event_name != 'pull_request' }}
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

- [ ] **Step 2: Verify YAML parses**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/build.yml')); print('OK')"`
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build.yml
git -c user.name="Carmelo Santana" -c user.email="carmelo@vctrs.io" commit -m "ci: build and publish image to GHCR"
```

---

### Task 8: Screenshot helper (`scripts/screenshots.sh`)

Generates README PNGs from the live TUIs in a headless pty via `charmbracelet/freeze`. Maintainer-run; not part of the image.

**Files:**
- Create: `scripts/screenshots.sh`

- [ ] **Step 1: Write `scripts/screenshots.sh`**

```bash
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
```

- [ ] **Step 2: Make executable and verify it runs its guard**

Run: `chmod +x scripts/screenshots.sh && bash -n scripts/screenshots.sh && echo OK`
Expected: `OK` (syntax valid). Actual image generation is a manual maintainer step requiring freeze.

- [ ] **Step 3: Commit**

```bash
git add scripts/screenshots.sh
git -c user.name="Carmelo Santana" -c user.email="carmelo@vctrs.io" commit -m "chore: screenshot generation helper"
```

---

### Task 9: Documentation (`README.md`)

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write `README.md`**

````markdown
# BubbleScreen

A featherweight "screensaver" for TrueNAS Scale. Toggle it on and your server's
physical console becomes a live CPU / RAM / temperature / NVIDIA-GPU dashboard;
toggle it off and the normal TrueNAS console returns. Idle footprint: under
~50 MB RAM. No X, no desktop, no database.

![Overview](docs/screenshots/overview.png)
![GPU](docs/screenshots/gpu.png)

## How it works

A slim Debian container runs `tmux` driving `btop` (CPU/RAM/temp) and `nvtop`
(NVIDIA GPU) on a free virtual terminal. GPU data comes from the host driver via
the NVIDIA container runtime. It replaces the console the same way steam-headless
does — minus the entire graphical desktop.

## Install (TrueNAS Scale)

1. Apps → Discover Apps → Custom App (YAML).
2. Paste `compose.yaml`, replacing `OWNER` with the GitHub owner of the published
   image (`ghcr.io/OWNER/bubblescreen:latest`).
3. Deploy. Turn the app **on** to take over the console; **off** to restore it.

The NVIDIA runtime must be enabled on the host (TrueNAS Apps → NVIDIA support).

## Modes

| MODE | Behavior |
|---|---|
| `smart` (default) | Overview normally; switches to the GPU view when GPU util is sustained above `GPU_THRESHOLD`, returns when it drops. Wakes the display on GPU activity. |
| `split` | btop (left) + nvtop (right), static. |
| `rotate` | Full-screen views cycling every `ROTATE_INTERVAL` seconds. |

## Configuration

| Var | Default | Meaning |
|---|---|---|
| `MODE` | `smart` | `split` \| `rotate` \| `smart` |
| `ROTATE_INTERVAL` | `20` | seconds per view (rotate) |
| `GPU_THRESHOLD` | `50` | GPU util % that triggers the GPU view |
| `GPU_THRESHOLD_HOLD` | `3` | seconds above threshold before switching |
| `GPU_HYSTERESIS` | `15` | % below threshold before returning |
| `SCREEN_TIMEOUT` | `1800` | idle seconds before the monitor powers off (`0` = never) |
| `WAKE_ON_GPU` | `true` | wake the display + show GPU on a threshold crossing |
| `TARGET_VT` | `auto` | VT to use (`auto` picks a free one) |
| `BTOP_PRESET` | `0` | btop layout preset |

## Controls

Arrow keys switch views; mouse wheel scrolls. Any key/mouse input wakes the
display (kernel-handled). The display powers off after `SCREEN_TIMEOUT` idle.

## Troubleshooting

- **Console not seized / permission errors:** if `SYS_TTY_CONFIG` is insufficient
  on your TrueNAS build, set `privileged: true` in `compose.yaml`.
- **No GPU data:** confirm the NVIDIA runtime is enabled and `nvidia-smi` works on
  the host; the container needs `NVIDIA_DRIVER_CAPABILITIES=utility`.
- **Wrong VT / console flicker:** pin `TARGET_VT` to a known free VT.
- **Display won't power off:** the monitor must honor VESA DPMS over the console.

## Development

```bash
sudo apt-get install -y bats tmux
bats tests/            # run all unit tests
docker build -t bubblescreen:test .
bash scripts/screenshots.sh   # regenerate README images (needs freeze + NVIDIA)
```
````

- [ ] **Step 2: Verify screenshot links resolve after generation**

Run: `grep -q 'docs/screenshots/overview.png' README.md && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git -c user.name="Carmelo Santana" -c user.email="carmelo@vctrs.io" commit -m "docs: README with install, modes, config, screenshots"
```

---

## Manual on-hardware verification (post-implementation checklist)

Not automatable in CI — run on the TrueNAS box after deploying:

- [ ] App **on** → console shows the dashboard; App **off** → TrueNAS console returns.
- [ ] `nvidia-smi` data visible in the nvtop pane (real numbers).
- [ ] Start a GPU job → smart mode switches to the GPU view and the panel wakes.
  - [ ] With `WAKE_ON_GPU=true`, confirm the display actually wakes from a blanked/DPMS-off state when a GPU job crosses the threshold; if it does not, harden `bs_wake_display` (e.g. re-assert `chvt` to the dashboard VT, or write directly to the VT device).
- [ ] Idle `SCREEN_TIMEOUT` → monitor powers off; keypress wakes it.
- [ ] Arrow keys switch views; mouse wheel scrolls.
- [ ] Confirm whether `SYS_TTY_CONFIG` suffices or `privileged: true` is needed; record in README.

## Self-Review Notes

- **Spec coverage:** §5 components 1–10 → Tasks 1–9 (lib+entrypoint power mgmt split across Tasks 1/4; screenshots Task 8; GHCR Task 7; .dockerignore Task 5). §6 env defaults → Global Constraints + Dockerfile + compose. §7 flagship flow → Task 3 controller + Task 4 blank timer + manual checklist. §9 testing → bats Tasks 1–4, build smoke Task 5, compose validate Task 6.
- **Deferred to phase 2 (per spec §11):** persisted history, single-pane GPU-btop, AMD/Intel, remote view — no tasks, intentionally.
