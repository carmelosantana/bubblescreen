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
2. Paste `compose.yaml`. It pulls the published image
   `ghcr.io/carmelosantana/bubblescreen:latest`.
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
