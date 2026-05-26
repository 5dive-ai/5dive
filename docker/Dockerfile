# 5dive CLI — demo container for tire-kickers who don't want a root install
# on their host. The image runs systemd as PID 1 (the CLI provisions agents as
# systemd units), so `docker run` needs --privileged.
#
# Build (from the repo root, not from docker/):
#   docker build -f docker/Dockerfile -t 5dive .
#
# Run:
#   docker run -d --name 5dive-demo --privileged 5dive
#   docker exec -it 5dive-demo bash
#
# Teardown:
#   docker rm -f 5dive-demo
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    container=docker

# systemd + the apt deps install.sh installs on a host. ca-certificates and
# sudo are pulled in explicitly because the base image is minimal.
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      systemd systemd-sysv \
      sudo ca-certificates curl \
      jq tmux git python3-yaml \
 && rm -rf /var/lib/apt/lists/*

# Mask units that fail noisily or are pointless in a container. The container
# boots faster and the journal stays readable.
RUN systemctl mask \
      systemd-udevd.service \
      systemd-udevd-kernel.socket \
      systemd-udevd-control.socket \
      systemd-firstboot.service \
      systemd-modules-load.service \
      sys-kernel-config.mount \
      sys-kernel-debug.mount \
      sys-kernel-tracing.mount \
      dev-hugepages.mount \
 && rm -f /lib/systemd/system/multi-user.target.wants/* \
          /etc/systemd/system/*.wants/* \
          /lib/systemd/system/local-fs.target.wants/* \
          /lib/systemd/system/sockets.target.wants/*udev* \
          /lib/systemd/system/sockets.target.wants/*initctl* \
          /lib/systemd/system/basic.target.wants/* \
          /lib/systemd/system/anaconda.target.wants/*

# Stage the working-tree as a file:// repo so install.sh's curl fetches
# resolve to local files. Keeps install.sh as the single source of truth for
# laying down binaries / units / hooks / skills — the Dockerfile doesn't
# duplicate that logic.
COPY 5dive 5dive-agent-start 5dive-refresh-plugins.sh install.sh projects-CLAUDE.md telegram-agent-CLAUDE.md /opt/5dive-bundle/
COPY hooks /opt/5dive-bundle/hooks/
COPY skills /opt/5dive-bundle/skills/
COPY systemd /opt/5dive-bundle/systemd/
# install.sh's curl fetches the unit at $REPO/systemd/5dive-agent%40.service
# (URL-encoded '@'). curl with file:// decodes %40 → @, so a symlink is enough
# to make both names resolve.
RUN ln -s 5dive-agent@.service /opt/5dive-bundle/systemd/'5dive-agent%40.service'

# install.sh's only systemctl call is `daemon-reload`, which can't succeed
# during a build (systemd isn't running as PID 1 yet). Stub it for the build,
# then drop the stub so the real /bin/systemctl takes over at boot.
RUN ln -sf /bin/true /usr/local/bin/systemctl \
 && REPO=file:///opt/5dive-bundle bash /opt/5dive-bundle/install.sh \
 && rm -f /usr/local/bin/systemctl

# systemd discovers /etc/systemd/system/5dive-agent@.service automatically
# on first boot, so no extra `daemon-reload` is needed.
STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/sbin/init"]
