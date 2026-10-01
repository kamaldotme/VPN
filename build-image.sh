#!/usr/bin/env bash
# build-image.sh — build the flashable PrivacyPi SD-card image.
#
#   ./build-image.sh            → build/privacypi-<version>.img.xz (+ .sha256)
#
# Needs only Docker (macOS or Linux). It downloads the official Raspberry Pi OS
# Lite (64-bit) image, verifies its checksum, installs PrivacyPi into it inside
# a container (image-build mode: no secrets, nothing device-specific), shrinks
# and compresses it. The user flashes the result with Raspberry Pi Imager
# ("Use custom") or balenaEtcher; the card grows to full size on first boot.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(cat "$ROOT/VERSION")"

# Pinned base image (bump deliberately, then re-test on hardware).
BASE_NAME="2026-09-15-raspios-trixie-arm64-lite.img.xz"
BASE_URL="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-09-15/$BASE_NAME"

CACHE="$ROOT/build/cache"
OUT="$ROOT/build"
mkdir -p "$CACHE" "$OUT"

command -v docker >/dev/null || { echo "Docker is required"; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker is not running"; exit 1; }

if [[ ! -f "$CACHE/$BASE_NAME" ]]; then
  echo "==> Downloading $BASE_NAME"
  curl -fL --retry 3 -o "$CACHE/$BASE_NAME.part" "$BASE_URL"
  mv "$CACHE/$BASE_NAME.part" "$CACHE/$BASE_NAME"
fi
[[ -f "$CACHE/$BASE_NAME.sha256" ]] || curl -fsSL -o "$CACHE/$BASE_NAME.sha256" "$BASE_URL.sha256"
echo "==> Verifying base image checksum"
( cd "$CACHE" && shasum -a 256 -c "$BASE_NAME.sha256" >/dev/null ) || { echo "Base image checksum mismatch — delete $CACHE/$BASE_NAME and retry"; exit 1; }

# The build works on a Docker volume (loop devices on a macOS bind mount are slow/unreliable).
docker volume create privacypi-build >/dev/null
echo "==> Building PrivacyPi $VERSION image (10–15 minutes)"
docker run --rm --privileged --platform linux/arm64 \
  -v privacypi-build:/work \
  -v "$CACHE":/cache:ro \
  -v "$ROOT":/src:ro \
  -v "$OUT":/out \
  -e BASE_NAME="$BASE_NAME" -e VERSION="$VERSION" \
  debian:trixie bash /src/tools/build-image-inner.sh

echo
echo "==> Done:"
ls -lh "$OUT/privacypi-$VERSION.img.xz"
cat "$OUT/privacypi-$VERSION.img.xz.sha256"
