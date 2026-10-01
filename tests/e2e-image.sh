#!/usr/bin/env bash
# Run the end-to-end test against the REAL image: takes the root filesystem out
# of build/privacypi-<version>.img.xz (Raspberry Pi OS + PrivacyPi exactly as it
# will be flashed) and boots that userland in a container. Catches anything
# that differs between plain Debian (tests/e2e.sh) and Raspberry Pi OS.
# Not covered: the Pi's kernel, firmware and radios.
#
#   ./build-image.sh && tests/e2e-image.sh [--keep]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
IMG="build/privacypi-$VERSION.img.xz"
[[ -f "$IMG" ]] || { echo "build the image first: ./build-image.sh"; exit 1; }

echo "== extracting the root filesystem from $IMG"
docker volume create privacypi-build >/dev/null
docker run --rm --privileged --platform linux/arm64 -v privacypi-build:/work -v "$PWD/build":/b:ro debian:trixie bash -c '
  set -e
  apt-get update -qq >/dev/null && apt-get install -y -qq xz-utils fdisk >/dev/null 2>&1
  for i in $(seq 0 15); do [[ -e /dev/loop$i ]] || mknod -m 660 /dev/loop$i b 7 $i 2>/dev/null || true; done
  cd /work; xz -dc /b/privacypi-'"$VERSION"'.img.xz > t.img
  s() { sfdisk -d t.img | sed -n "s/^.*img$1 : start= *\([0-9]*\), size= *\([0-9]*\).*/\\$2/p"; }
  mkdir -p /m
  mount -o loop,ro,offset=$(( $(s 2 1) * 512 )) t.img /m
  mount -o loop,ro,offset=$(( $(s 1 1) * 512 )),sizelimit=$(( $(s 1 2) * 512 )) t.img /m/boot/firmware
  tar -C /m --numeric-owner -cf /work/rootfs.tar .
  umount /m/boot/firmware /m; rm -f t.img'
docker run --rm -v privacypi-build:/work busybox cat /work/rootfs.tar | docker import --platform linux/arm64 - privacypi-rootfs >/dev/null
docker run --rm -v privacypi-build:/work busybox rm -f /work/rootfs.tar

echo "== adding the test harness bits (client tools, eth0 left to Docker)"
docker build -q --platform linux/arm64 -t privacypi-e2e-pios - >/dev/null <<'DOCKERFILE'
FROM privacypi-rootfs
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends busybox-static >/dev/null 2>&1; \
    printf '[Match]\nName=eth0\n\n[Link]\nUnmanaged=yes\n' > /etc/systemd/network/10-test-eth0.network; \
    mkdir -p /etc/systemd/system/privacypi-init.service.d; \
    printf '[Service]\nEnvironment=NET_ROLES_WAIT=1\n' > /etc/systemd/system/privacypi-init.service.d/test.conf; \
    sed -i '/PARTUUID/d' /etc/fstab; \
    echo uninitialized > /etc/machine-id; \
    systemctl mask systemd-udev-settle.service getty@tty1.service console-getty.service serial-getty@.service >/dev/null 2>&1; true
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
DOCKERFILE

IMAGE=privacypi-e2e-pios SKIP_BUILD=1 tests/e2e.sh "$@"
