FROM debian:bookworm-slim

# nvtop ships in Debian's "contrib" component; the base image enables only "main".
# kbd provides openvt/chvt/fgconsole (VT takeover); util-linux only has setterm.
RUN sed -i 's/^Components: main$/Components: main contrib/' /etc/apt/sources.list.d/debian.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      btop nvtop tmux gpm util-linux kbd tini ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY src/ /app/
RUN chmod +x /app/*.sh

# btop refuses to start without a UTF-8 locale ("No UTF-8 locale detected"), and
# the slim base sets none. C.UTF-8 is built into glibc — no locale-gen needed.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

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
