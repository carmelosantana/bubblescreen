FROM debian:bookworm-slim

# nvtop ships in Debian's "contrib" component; the base image enables only "main".
# kbd provides openvt/chvt/fgconsole (VT takeover); util-linux only has setterm.
# htop is the CPU/RAM/temp monitor: it renders with console-native ACS line
# drawing (no UTF-8 locale needed) and adapts to narrow panes.
RUN sed -i 's/^Components: main$/Components: main contrib/' /etc/apt/sources.list.d/debian.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      htop nvtop tmux gpm util-linux kbd tini ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY src/ /app/
RUN chmod +x /app/*.sh

# No locale is set on purpose: htop and nvtop use ACS line-drawing in the C
# locale, which the Linux VT console renders natively. Forcing a UTF-8 locale
# makes them emit UTF-8 box-drawing that a raw console garbles.

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
    TARGET_VT=auto

ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
