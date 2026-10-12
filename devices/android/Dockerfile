# Android test slot: the PR's APK on an x86_64 emulator (KVM), streamed to a browser through noVNC.
# One reviewer session at a time (see devices/README.md). Built by device-images.yml.
FROM public.ecr.aws/docker/library/ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      tini python3 ca-certificates curl unzip openjdk-17-jre-headless \
      tigervnc-standalone-server novnc websockify openbox \
      libgl1 libglu1-mesa libpulse0 libnss3 libasound2t64 libfontconfig1 libbsd0 libdbus-1-3 \
      libx11-6 libx11-xcb1 libxext6 libxrender1 libxfixes3 libxi6 libxtst6 libxdamage1 libxcomposite1 \
      libxkbfile1 libxkbcommon0 libxkbcommon-x11-0 \
      libxcb1 libxcb-xinerama0 libxcb-icccm4 libxcb-image0 libxcb-keysyms1 libxcb-render0 \
      libxcb-render-util0 libxcb-shape0 libxcb-shm0 libxcb-sync1 libxcb-xfixes0 libxcb-xkb1 \
      libxcb-randr0 libxcb-util1 libxcb-cursor0 \
      fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*

# Android SDK command-line tools, pinned by checksum (Google's repository manifest lists the SHA-1
# e025545c62a8e64c7559119566a569fb1dec5f60 for this file).
ENV ANDROID_SDK_ROOT=/opt/android-sdk ANDROID_HOME=/opt/android-sdk ANDROID_AVD_HOME=/opt/android-avd
ARG CMDLINE_TOOLS_ZIP=commandlinetools-linux-16111833_latest.zip
ARG CMDLINE_TOOLS_SHA256=0877a1d048fe4a24efe2eff536ca4223f7adeb58648bb81909d33c446918cfa8
RUN curl -fsSL -o /tmp/cmdtools.zip "https://dl.google.com/android/repository/${CMDLINE_TOOLS_ZIP}" \
 && echo "${CMDLINE_TOOLS_SHA256}  /tmp/cmdtools.zip" | sha256sum -c - \
 && mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools" \
 && unzip -q /tmp/cmdtools.zip -d "${ANDROID_SDK_ROOT}/cmdline-tools" \
 && mv "${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools" "${ANDROID_SDK_ROOT}/cmdline-tools/latest" \
 && rm /tmp/cmdtools.zip
ENV PATH="${PATH}:${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${ANDROID_SDK_ROOT}/emulator"

# The emulator and an Android 14 system image, and one baked AVD. The data partition is 2 GB, which also bounds
# what an app can write. Each session copies the AVD into its
# tmpfs and runs that copy, so every session starts from the same clean device.
ARG SYSTEM_IMAGE="system-images;android-34;google_apis;x86_64"
RUN yes | sdkmanager --licenses > /dev/null \
 && sdkmanager --install "platform-tools" "emulator" "${SYSTEM_IMAGE}" > /dev/null \
 && mkdir -p "${ANDROID_AVD_HOME}" \
 && echo no | avdmanager create avd -n slot -k "${SYSTEM_IMAGE}" -d pixel_6 --force \
 && python3 - <<'PY'
import os
p = os.path.join(os.environ["ANDROID_AVD_HOME"], "slot.avd", "config.ini")
want = {
    "hw.ramSize": "3072", "hw.lcd.width": "720", "hw.lcd.height": "1280", "hw.lcd.density": "320",
    "hw.gpu.enabled": "yes", "hw.gpu.mode": "swiftshader_indirect", "hw.keyboard": "yes",
    "hw.audioInput": "no", "hw.audioOutput": "no", "showDeviceFrame": "no", "disk.dataPartition.size": "2G",
    "fastboot.forceColdBoot": "yes",
}
lines = [l for l in open(p).read().splitlines() if l.split("=")[0].strip() not in want]
lines += [f"{k}={v}" for k, v in want.items()]
open(p, "w").write("\n".join(lines) + "\n")
PY

RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin device
COPY devices/agent/agent.py /opt/agent/agent.py
COPY devices/android/session.sh /opt/agent/session.sh
RUN chmod 755 /opt/agent/agent.py /opt/agent/session.sh \
 && chmod -R a+rX "${ANDROID_SDK_ROOT}" "${ANDROID_AVD_HOME}"

# The agent runs as root with only the capabilities in docker-compose.yml (CHOWN, SETUID, SETGID, KILL)
# and starts each session as the unprivileged `device` user. APP_GROUPS adds the group that owns
# /dev/kvm to that user, so the emulator can use it.
ENV WORK_DIR=/session/run APP_BIN=app.apk
WORKDIR /home/device
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8080/healthz >/dev/null || exit 1
ENTRYPOINT ["/usr/bin/tini", "--", "python3", "/opt/agent/agent.py"]
