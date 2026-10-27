# harness-smoke (DIVE-7115) — a FRESH Ubuntu server, as a customer rents one.
#
# docker/Dockerfile is the demo image: it pre-installs jq/tmux/git and stubs the
# agent binary, so it proves 5dive lays down and nothing about the AI tools a
# hire installs. This image starts from ubuntu:<UBUNTU> and adds exactly the
# packages Canonical's server cloud image ships (its published .manifest), so a
# harness that needs a package the cloud image lacks fails here the way it
# fails on a customer's box. DIVE-7103 is the case: hermes' Node needs
# libatomic1, which is in no Ubuntu cloud image, and no CI job could see that.
#
# Left out, and only these: boot, kernel, firmware, disk and VM-agent packages
# that cannot run in a container, and systemd-resolved, whose postinst rewrites
# /etc/resolv.conf mid-build and takes DNS away from the rest of this layer
# (docker supplies resolv.conf at run time anyway). Nothing is ADDED.
#
# Run (systemd is PID 1, the CLI makes agents as systemd units):
#   docker build -f docker/harness-smoke.Dockerfile --build-arg UBUNTU=24.04 -t hs .
#   docker run -d --privileged --name hs hs
ARG UBUNTU=24.04
FROM ubuntu:${UBUNTU}
ARG UBUNTU

ENV DEBIAN_FRONTEND=noninteractive \
    container=docker

# The docker image is minimized (man pages and docs stripped by dpkg excludes).
# A cloud image is not, but that changes no binary, so it is left as it is.
RUN set -eu; \
    codename=$(. /etc/os-release && echo "$VERSION_CODENAME"); \
    apt-get update -qq; \
    apt-get install -y -qq --no-install-recommends ca-certificates curl >/dev/null; \
    curl -fsSL --retry 3 \
      "https://cloud-images.ubuntu.com/${codename}/current/${codename}-server-cloudimg-amd64.manifest" \
      -o /tmp/cloud.manifest; \
    test "$(wc -l < /tmp/cloud.manifest)" -gt 300; \
    cut -f1 /tmp/cloud.manifest | sed 's/:.*//' | sort -u \
      | grep -vE '^(linux-|grub|shim|efibootmgr|os-prober|mokutil|sbsigntool|secureboot-db|amd64-microcode|intel-microcode|thermald|irqbalance|snapd|lxd|cloud-init|cloud-guest-utils|cloud-initramfs|open-vm-tools|open-iscsi|multipath-tools|lvm2|mdadm|cryptsetup|dmeventd|btrfs-progs|xfsprogs|thin-provisioning-tools|initramfs-tools|finalrd|overlayroot|bcache-tools|plymouth|fwupd|udisks2|modemmanager|tpm-udev|systemd-resolved|resolvconf|ubuntu-minimal|ubuntu-server|ubuntu-standard|ubuntu-cloud-minimal|ubuntu-server-minimal|ubuntu-kernel|kmod|systemd-hwe|wireless|wpasupplicant|apport|ubuntu-advantage|ubuntu-pro|landscape|pollinate|motd-news|update-notifier|ubuntu-release-upgrader|update-manager|sosreport|ec2-|walinuxagent|hibagent)' \
      > /tmp/wanted; \
    apt-cache pkgnames | sort -u > /tmp/available; \
    comm -12 /tmp/wanted /tmp/available > /tmp/install; \
    echo "cloud image ${codename}: $(wc -l < /tmp/cloud.manifest) packages, installing $(wc -l < /tmp/install)"; \
    xargs -a /tmp/install apt-get install -y -qq --no-install-recommends >/dev/null; \
    if dpkg -s libatomic1 >/dev/null 2>&1; then echo "libatomic1: present"; else echo "libatomic1: absent (as on a fresh cloud server)"; fi; \
    rm -rf /var/lib/apt/lists/* /tmp/cloud.manifest /tmp/wanted /tmp/available /tmp/install

# Same masks as docker/Dockerfile: units that fail or mean nothing in a container.
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
      getty@tty1.service \
      serial-getty@ttyS0.service

STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/sbin/init"]
