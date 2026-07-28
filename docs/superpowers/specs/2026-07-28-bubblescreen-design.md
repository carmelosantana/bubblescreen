# BubbleScreen — Design Spec

**Date:** 2026-07-28
**Status:** Approved (brainstorming complete)
**Codename:** BubbleScreen (name open — "bubbles" is conceptual, not literal graphics)

## 1. Summary

BubbleScreen is a featherweight TrueNAS Scale "screensaver" that takes over the
server's physical console with a live system-monitoring dashboard (CPU, RAM,
temperature, and NVIDIA GPU). When toggled **on** it seizes the console; when
toggled **off** the normal TrueNAS console returns. It ships as a TrueNAS Custom
App (Docker Compose) so the on/off toggle is native to the TrueNAS Apps UI.

Idle footprint target: **under ~50 MB RAM.** Low RAM usage is a hard
requirement — the host runs VMs and NVIDIA AI/GPU workloads (e.g. ComfyUI) that
own the memory budget.

## 2. Goals / Non-Goals

### Goals
- Fullscreen, always-legible monitoring of **CPU, RAM, temp, and NVIDIA GPU**
  (utilization, VRAM, temperature, power) on the physical TrueNAS console.
- Extremely low RAM and dependency footprint.
- On/off toggle that behaves like a TrueNAS app: on = takes over the display,
  off = console restored.
- Three display behaviors, selectable by env var:
  - **split** — two tools side by side.
  - **rotate** — full-screen views cycling on a timer.
  - **smart** (default) — overview normally; auto-switch to the GPU view when
    the GPU is working.
- **Display power management** the TrueNAS console can't do: power the monitor
  off after an idle timeout, wake on input, and wake on GPU activity.
- Keyboard navigation (arrow keys switch views) and mouse-wheel scroll in the
  console.

### Non-Goals (v1)
- Literal animated "bubble" graphics. ("Bubbles" is a vibe, delivered as a clean
  TUI.)
- Persisted long-term history / time-series database. Only live rolling graphs
  (seconds–minutes) that the tools draw natively.
- Remote streaming / VNC / web view. (steam-headless does this; we deliberately
  do not.)
- AMD/Intel GPU support as a shipped feature. The tool choice (nvtop) keeps the
  door open, but v1 targets NVIDIA only.

## 3. Background / Research findings

- **Console takeover is cheap for text.** steam-headless needs Xorg + DRM-master
  handling only because it pushes a *graphical* desktop. On TrueNAS the physical
  console is just a text getty over the kernel framebuffer (fbcon); nothing holds
  DRM master. A TUI renders directly in a virtual terminal (VT). We run our
  dashboard on a free VT and `chvt` to it; on exit we `chvt` back and the
  TrueNAS console returns. No X, no compositor, no DRM-master fight.
- **Tooling (NVIDIA):** the robust, build-free combination is **btop**
  (CPU/RAM/temp, ~10–25 MB, native TTY mode, historical braille/block graphs) +
  **nvtop** (NVIDIA GPU util/VRAM/temp/power, ~20 MB, per-GPU history). Both are
  `apt`-installable and work in a bare console. GPU data reaches the container
  via the host driver injected by the NVIDIA container runtime
  (`libnvidia-ml.so`); no CUDA base image needed.
  - btop's own GPU support exists only in a binary compiled with
    `GPU_SUPPORT=true` (official/apt binaries ship without it). We therefore use
    **nvtop for GPU** and keep btop stock — no fragile custom build. A future
    "single-pane GPU-btop" mode is an optional bonus, not the foundation.
- **Orchestration:** **tmux** (lightest scriptable multiplexer, works on a bare
  framebuffer TTY) drives split/rotate/smart layouts and provides key/mouse
  bindings. **gpm** provides console mouse (wheel scroll). A small polling loop
  against `nvidia-smi --query-gpu=utilization.gpu` implements rotate/smart
  switching.
- **Display power:** `setterm --blank/--powerdown` on our VT triggers the
  kernel's VESA DPMS to actually power the monitor down; the kernel auto-wakes
  the display on keyboard/mouse input. Part of util-linux — no extra daemon.

## 4. Architecture

BubbleScreen is a single container. Inside it, a chain of small, single-purpose
scripts sets up the console session and runs a controller loop.

```
TrueNAS Apps toggle  ──►  container up
                              │
                    entrypoint.sh (tini as PID 1)
                              │
        ┌─────────────────────┼──────────────────────┐
        ▼                     ▼                        ▼
   start gpm          layout.sh builds          openvt + chvt onto a
  (console mouse)     tmux session per MODE      free VT; exit trap
                      (btop + nvtop panes)       restores console
                              │
                              ▼
                        controller.sh
              (rotate timer / smart GPU polling /
               display power: blank/powerdown, wake-on-GPU)
```

The physical keyboard is routed by the kernel to whichever VT is foreground, so
input reaches the tmux session automatically. gpm adds mouse-wheel scroll. On
container stop, tini forwards the signal, the exit trap `chvt`s back to the
TrueNAS console VT and un-blanks the display.

## 5. Components

Each has one job, a clear interface (env vars in, tmux/VT side effects out), and
is independently testable.

1. **`Dockerfile`** — `debian:bookworm-slim` + `btop`, `nvtop`, `tmux`, `gpm`,
   `util-linux` (setterm/openvt/chvt), `tini`. No CUDA image. GPU libs come from
   the NVIDIA runtime at run time.
   - *Interface:* produces the image. *Depends on:* base packages only.

2. **`entrypoint.sh`** — orchestrates startup: start gpm; call `layout.sh` to
   build the detached tmux session; pick a free VT with `openvt`, `chvt` to it,
   and `tmux attach` there; install a trap (EXIT/TERM/INT) that kills tmux,
   restores the console VT, and un-blanks the display; then exec `controller.sh`.
   - *Interface:* reads all env vars. *Depends on:* layout.sh, controller.sh, VT
     devices, gpm.

3. **`layout.sh`** — builds the tmux windows/panes for the selected `MODE`:
   - split → one window, `btop` left + `nvtop` right (`even-horizontal`).
   - rotate/smart → separate full-screen windows (`overview`=btop, `gpu`=nvtop),
     plus a split overview window as needed.
   - *Interface:* `MODE`, `BTOP_PRESET`. *Depends on:* tmux, btop, nvtop.

4. **`controller.sh`** — the behavior + power loop (runs for the container
   lifetime):
   - **rotate:** every `ROTATE_INTERVAL`, advance to the next tmux window.
   - **smart:** poll `nvidia-smi` GPU utilization; when it holds ≥
     `GPU_THRESHOLD` for `GPU_THRESHOLD_HOLD` seconds, switch/zoom to the GPU
     view; when it falls below `GPU_THRESHOLD − GPU_HYSTERESIS`, return to
     overview.
   - **display power:** track idle time; after `SCREEN_TIMEOUT`, `setterm
     --powerdown` on the VT. `WAKE_ON_GPU=on` force-wakes the display + shows GPU
     on a threshold crossing. (Wake-on-input is handled by the kernel.)
   - *Interface:* all timing/threshold env vars. *Depends on:* tmux, nvidia-smi,
     setterm.

5. **`tmux.conf`** — mouse mode on (wheel scroll), arrow keys bound to
   prev/next view, minimal/no status bar, no escape-time lag.
   - *Interface:* consumed by tmux at session start.

6. **`compose.yaml`** — the TrueNAS Custom App definition and the on/off toggle:
   - `runtime: nvidia`, `environment: NVIDIA_DRIVER_CAPABILITIES=utility`,
     `NVIDIA_VISIBLE_DEVICES=all`.
   - Console/VT + input passthrough: the VT/console devices, `/dev/input`,
     `/dev/tty0`; `cap_add: [SYS_TTY_CONFIG]` for chvt/VT_ACTIVATE (fall back to
     `privileged: true` if a minimal cap set proves insufficient on TrueNAS).
   - `restart: unless-stopped`.
   - All BubbleScreen env vars surfaced with defaults.

7. **`README.md`** — TrueNAS Scale install (Custom App via compose), env
   reference, and troubleshooting (VT selection, cap vs privileged, verifying
   the NVIDIA runtime).

## 6. Configuration (environment variables)

| Var | Default | Meaning |
|---|---|---|
| `MODE` | `smart` | `split` \| `rotate` \| `smart` |
| `ROTATE_INTERVAL` | `20` | seconds per view in rotate mode |
| `GPU_THRESHOLD` | `50` | GPU util % that triggers the GPU view (smart) |
| `GPU_THRESHOLD_HOLD` | `3` | seconds util must stay above threshold before switching |
| `GPU_HYSTERESIS` | `15` | % below threshold before returning to overview |
| `SCREEN_TIMEOUT` | `1800` | idle seconds before powering the monitor off (`0` = never) |
| `WAKE_ON_GPU` | `true` | wake the display + show GPU on a threshold crossing |
| `TARGET_VT` | `auto` | VT to use (`auto` = first free via openvt `-s`) |
| `BTOP_PRESET` | `0` | btop layout preset |

## 7. Behavior detail: smart mode + display power (the flagship experience)

Default out-of-the-box flow:
1. Dashboard starts on a free VT showing the overview (btop). 
2. Idle for `SCREEN_TIMEOUT` (30 min) → monitor powers down (dark, silent).
3. A GPU job starts → utilization crosses `GPU_THRESHOLD` → controller wakes the
   display and switches to the nvtop GPU pane. You see the job working.
4. Job finishes → utilization drops below threshold − hysteresis → back to
   overview; idle timer resumes → eventually sleeps again.
5. Any keypress/mouse wheel wakes the display at any time (kernel-handled) and
   the user can arrow between views / scroll.

## 8. Resource budget

tmux (~3–5 MB) + btop (~10–25 MB) + nvtop (~20 MB) + gpm (~2 MB) ≈ **< 50 MB**
idle. Base image slim; no X, no desktop, no CUDA image, no database.

## 9. Testing strategy

- **layout.sh** — assert the expected tmux windows/panes exist per MODE
  (`tmux list-windows` / `list-panes`) in a headless tmux (no VT needed).
- **controller.sh** — unit-test the decision logic with a mockable GPU-reading
  function (feed synthetic utilization series; assert switch/return/wake
  decisions and idle→powerdown timing). Isolate `nvidia-smi` and `setterm`
  behind small wrapper functions so tests stub them.
- **entrypoint.sh** — verify the exit trap restores the VT and un-blanks
  (mock chvt/setterm; assert calls on TERM/INT/EXIT).
- **Container build** — CI builds the image and checks the tools launch
  (`btop --version`, `nvtop --version`, `tmux -V`).
- **Manual on-hardware** — verify console takeover, NVIDIA data visibility
  (requires the NVIDIA runtime), threshold switching, and DPMS power-off/wake on
  the real TrueNAS box. Documented as a manual checklist in the README.

## 10. Risks / open questions

- **Cap vs privileged on TrueNAS:** `SYS_TTY_CONFIG` + explicit device
  passthrough is the least-privilege target; if TrueNAS's container `/dev`
  restrictions block VT control, fall back to `privileged: true` (as
  steam-headless does). Resolve during implementation on hardware.
- **VT selection:** `openvt -s` should find a genuinely free VT; if gettys
  occupy the low VTs, confirm the chosen VT and the chvt-back target. `TARGET_VT`
  override exists for this.
- **DPMS reliability:** `setterm --powerdown` depends on the display honoring
  VESA DPMS over the console. Verify on the actual monitor; document fallback
  (blank-only) if powerdown is not honored.
- **btop GPU (future):** optional single-pane GPU-btop mode would need a
  `GPU_SUPPORT=true` build; deferred, not in v1.

## 11. Future / phase 2 (out of scope now)
- Optional persisted history (lightweight recorder) for hours/days of trend
  graphs.
- Optional single-pane GPU-enabled btop mode.
- AMD/Intel GPU support (swap/add nvtop-compatible panes).
- Optional remote/web view.
