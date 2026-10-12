# Desktop test slot: the Linux build of zedu-desktop under a virtual display, streamed to a browser
# through noVNC. One reviewer session at a time (see devices/README.md). Built by device-images.yml.
FROM public.ecr.aws/docker/library/ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      tini python3 ca-certificates curl \
      tigervnc-standalone-server novnc websockify openbox dbus-x11 gnome-keyring \
      libgtk-3-0t64 libglib2.0-0t64 libatk1.0-0t64 libcairo2 libcairo-gobject2 libepoxy0 \
      libfontconfig1 libgdk-pixbuf-2.0-0 libharfbuzz0b libpango-1.0-0 libpangocairo-1.0-0 \
      libnotify4 libsecret-1-0 libayatana-appindicator3-1 libdbusmenu-glib4 libayatana-ido3-0.4-0 \
      libayatana-indicator3-7 libgstreamer1.0-0 libgstreamer-plugins-base1.0-0 \
      gstreamer1.0-plugins-base gstreamer1.0-plugins-good libstdc++6 zlib1g \
      libgl1-mesa-dri libegl1 libegl-mesa0 libglx-mesa0 libgles2 \
      fonts-noto-core fonts-noto-color-emoji fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin device
COPY devices/agent/agent.py /opt/agent/agent.py
COPY devices/desktop/session.sh /opt/agent/session.sh
COPY devices/desktop/needed-libs.txt /opt/agent/needed-libs.txt
RUN chmod 755 /opt/agent/agent.py /opt/agent/session.sh

# The agent runs as root with only the capabilities in docker-compose.yml (CHOWN, SETUID, SETGID,
# KILL) and starts each session's app as the unprivileged `device` user. The app cannot read the
# agent's environment (DEVICE_TOKEN) from /proc because it is a different user.
# The app is unpacked into /session, a tmpfs mounted with exec (Docker's --tmpfs is noexec by default).
ENV WORK_DIR=/session/run
WORKDIR /home/device
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8080/healthz >/dev/null || exit 1
ENTRYPOINT ["/usr/bin/tini", "--", "python3", "/opt/agent/agent.py"]
