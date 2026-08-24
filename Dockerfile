FROM debian:bookworm-slim

# nvtop ships in Debian's "contrib" component; the base image enables only "main".
# kbd provides openvt/chvt/fgconsole (VT takeover); util-linux only has setterm.
# htop is the CPU/RAM/temp monitor: it renders with console-native ACS line
# drawing (no UTF-8 locale needed) and adapts to narrow panes.
# ddcutil drives DDC/CI monitor power (the console framebuffer is efifb, which
# can't DPMS — the only way to truly power the monitor off is over the display
# cable's i2c/DDC lines). kmod provides modprobe to load i2c-dev at startup.
RUN sed -i 's/^Components: main$/Components: main contrib/' /etc/apt/sources.list.d/debian.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      htop nvtop tmux gpm util-linux kbd tini ca-certificates ddcutil kmod \
 && rm -rf /var/lib/apt/lists/*

COPY src/ /app/
RUN chmod +x /app/*.sh

# No locale is set on purpose: htop and nvtop use ACS line-drawing in the C
# locale, which the Linux VT console renders natively. Forcing a UTF-8 locale
# makes them emit UTF-8 box-drawing that a raw console garbles.

# GPU data is injected by the NVIDIA container runtime at run time.
ENV NVIDIA_DRIVER_CAPABILITIES=utility \
    NVIDIA_VISIBLE_DEVICES=all \
    APPS=htop,nvtop \
    MODE=smart \
    ROTATE_INTERVAL=20 \
    GPU_THRESHOLD=50 \
    GPU_THRESHOLD_HOLD=3 \
    GPU_HYSTERESIS=15 \
    SCREEN_TIMEOUT=300 \
    WAKE_ON_GPU=true \
    TARGET_VT=auto

ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
