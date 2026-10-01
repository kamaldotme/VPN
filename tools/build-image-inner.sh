#!/usr/bin/env bash
# Runs inside a privileged arm64 Debian container (started by build-image.sh).
# /cache = base image, /src = repo (read-only), /work = scratch volume, /out = results.
set -euo pipefail
GROW_MB=2200          # working room for the install; trimmed again at the end
MARGIN_MB=300         # free space left in the shipped image
IMG=/work/work.img
MNT=/mnt/root

say() { echo "--> $*"; }
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq xz-utils fdisk e2fsprogs dosfstools util-linux rsync zerofree >/dev/null 2>&1

# Loop device nodes may be missing in a container's /dev
for i in $(seq 0 15); do [[ -e /dev/loop$i ]] || mknod -m 660 /dev/loop$i b 7 "$i" 2>/dev/null || true; done

cleanup() {
  set +e
  for m in dev/pts dev proc sys run boot/firmware ""; do mountpoint -q "$MNT/$m" && umount -l "$MNT/$m"; done
  [[ -n "${LOOP_R:-}" ]] && losetup -d "$LOOP_R" 2>/dev/null
  [[ -n "${LOOP_B:-}" ]] && losetup -d "$LOOP_B" 2>/dev/null
}
trap cleanup EXIT

say "unpacking base image"
rm -f "$IMG"
xz -dc "/cache/$BASE_NAME" > "$IMG"

say "growing root partition by ${GROW_MB} MB"
truncate -s "+${GROW_MB}M" "$IMG"
echo ", +" | sfdisk --no-reread -q -N 2 "$IMG"
pstart() { sfdisk -d "$IMG" | sed -n "s/^.*img$1 : start= *\([0-9]*\), size= *\([0-9]*\).*/\1/p"; }
psize()  { sfdisk -d "$IMG" | sed -n "s/^.*img$1 : start= *\([0-9]*\), size= *\([0-9]*\).*/\2/p"; }
B_START=$(pstart 1); B_SIZE=$(psize 1); R_START=$(pstart 2)
[[ -n "$B_START" && -n "$B_SIZE" && -n "$R_START" ]] || { echo "could not read the partition table"; exit 1; }
LOOP_R=$(losetup --find --show --offset $((R_START*512)) "$IMG")
e2fsck -fy "$LOOP_R" >/dev/null 2>&1 || true
resize2fs "$LOOP_R" >/dev/null 2>&1

say "mounting"
LOOP_B=$(losetup --find --show --offset $((B_START*512)) --sizelimit $((B_SIZE*512)) "$IMG")
mkdir -p "$MNT"
mount "$LOOP_R" "$MNT"
mount "$LOOP_B" "$MNT/boot/firmware"
mount -t proc proc "$MNT/proc"
mount -t sysfs sys "$MNT/sys"
mount --bind /dev "$MNT/dev"
mount -t devpts devpts "$MNT/dev/pts"
mount -t tmpfs tmpfs "$MNT/run"

MACHINE_ID_BEFORE=$(cat "$MNT/etc/machine-id")
cp "$MNT/etc/resolv.conf" /tmp/resolv.conf.orig 2>/dev/null || true
rm -f "$MNT/etc/resolv.conf"; cat /etc/resolv.conf > "$MNT/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' > "$MNT/usr/sbin/policy-rc.d"; chmod 755 "$MNT/usr/sbin/policy-rc.d"

say "installing PrivacyPi $VERSION into the image"
mkdir -p "$MNT/tmp/privacypi-src"
rsync -a --exclude build --exclude .git --exclude .playwright-mcp --exclude '*.png' \
      --exclude __pycache__ --exclude .claude --exclude 'CREDENTIALS.local.md' /src/ "$MNT/tmp/privacypi-src/"
chroot "$MNT" /usr/bin/env PRIVACYPI_IMAGE_BUILD=1 bash /tmp/privacypi-src/install.sh \
  || { echo "INSTALL FAILED — last log lines:"; tail -40 "$MNT/var/log/privacypi-install.log"; exit 1; }

say "cleaning up"
chroot "$MNT" apt-get clean
rm -rf "$MNT/tmp/privacypi-src" "$MNT"/var/lib/apt/lists/* "$MNT"/var/cache/apt/*.bin "$MNT/root/.cache"
rm -f "$MNT/usr/sbin/policy-rc.d" "$MNT/var/log/privacypi-install.log"
rm -f "$MNT"/etc/ssh/ssh_host_*            # regenerated per device on first boot
rm -f "$MNT/var/lib/systemd/random-seed"
find "$MNT/var/log" -type f -exec truncate -s 0 {} \; 2>/dev/null || true
# install.sh pointed resolv.conf at the Pi's own DNS — keep that.
# The image must still look never-booted (root resize + per-device IDs depend on it).
echo "$MACHINE_ID_BEFORE" > "$MNT/etc/machine-id"

say "verifying nothing device-specific was baked in"
bad=0
for f in etc/privacypi/master.key etc/privacypi/secret.key etc/privacypi/secret.env etc/privacypi/alert.secret \
         etc/privacypi/adguard.creds etc/privacypi/wifi-psk.txt etc/privacypi/setup-complete etc/privacypi/.provisioned \
         opt/AdGuardHome/AdGuardHome.yaml var/lib/privacypi/privacypi.db etc/hostapd/hostapd.conf; do
  [[ -e "$MNT/$f" ]] && { echo "   LEFTOVER: /$f"; bad=1; }
done
ls "$MNT"/etc/ssh/ssh_host_* >/dev/null 2>&1 && { echo "   LEFTOVER: ssh host keys"; bad=1; }
[[ "$(cat "$MNT/etc/machine-id")" == "uninitialized" ]] || { echo "   machine-id is initialised"; bad=1; }
[[ -x "$MNT/opt/privacypi/venv/bin/gunicorn" && -x "$MNT/opt/AdGuardHome/AdGuardHome" && -f "$MNT/boot/firmware/privacypi-config.txt" ]] \
  || { echo "   install incomplete"; bad=1; }
(( bad == 0 )) || { echo "IMAGE VERIFICATION FAILED"; exit 1; }
echo "   enabled: $(ls "$MNT/etc/systemd/system/multi-user.target.wants" | tr '\n' ' ')"
echo "   root fs used: $(df -h "$MNT" | awk 'NR==2{print $3" of "$2}')"

say "unmounting + shrinking"
for m in dev/pts dev proc sys run boot/firmware ""; do umount "$MNT/$m"; done
e2fsck -fy "$LOOP_R" >/dev/null 2>&1 || true
resize2fs -M "$LOOP_R" >/dev/null 2>&1
BLOCKS=$(dumpe2fs -h "$LOOP_R" 2>/dev/null | awk -F: '/^Block count/{gsub(/ /,"",$2); print $2}')
BSIZE=$(dumpe2fs -h "$LOOP_R" 2>/dev/null | awk -F: '/^Block size/{gsub(/ /,"",$2); print $2}')
NEW_BLOCKS=$(( BLOCKS + MARGIN_MB*1024*1024/BSIZE ))
resize2fs "$LOOP_R" "$NEW_BLOCKS" >/dev/null 2>&1
e2fsck -fy "$LOOP_R" >/dev/null 2>&1 || true
zerofree "$LOOP_R" 2>/dev/null || true
losetup -d "$LOOP_R"; LOOP_R=""
losetup -d "$LOOP_B"; LOOP_B=""
NEW_SECTORS=$(( NEW_BLOCKS * BSIZE / 512 ))
echo ", $NEW_SECTORS" | sfdisk --no-reread -q -N 2 "$IMG"
truncate -s $(( (R_START + NEW_SECTORS) * 512 )) "$IMG"
sfdisk -d "$IMG" | grep -E 'label-id|img[12]'

say "compressing (xz)"
OUTF="/out/privacypi-$VERSION.img.xz"
xz -T0 -6 -c "$IMG" > "$OUTF.tmp" && mv "$OUTF.tmp" "$OUTF"
( cd /out && sha256sum "privacypi-$VERSION.img.xz" > "privacypi-$VERSION.img.xz.sha256" )
rm -f "$IMG"
say "image: $(ls -lh "$OUTF" | awk '{print $5}') compressed, $(( (R_START + NEW_SECTORS) / 2048 )) MB flashed"
