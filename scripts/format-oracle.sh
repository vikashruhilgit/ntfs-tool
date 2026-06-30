#!/usr/bin/env bash
# format-oracle.sh — validate the NTFSCore FORMATTER against the REAL ntfs-3g
# driver (and document the live FSKit round-trip for real hardware).
#
# Rubric-1 helper. The strongest fully-automatable local check of write
# correctness is: emit a freshly *formatted* NTFS image from NTFSCore, then ask
# an authoritative implementation (ntfs-3g / ntfsprogs, the same lineage Linux
# ships) to mount + fsck it. Our own reader accepting the volume proves nothing
# (it shares any bug the formatter has) — ntfs-3g is the independent authority.
#
# This validates the FORMAT path (rubric item 3's on-disk product). The
# write-through cp path has its own oracle in scripts/ntfs-oracle.sh.
#
# IMPORTANT — this needs Docker (for ntfs-3g) or a Linux box, so it CANNOT run
# in a headless CI / sandboxed environment with no Docker and no Linux. Run it
# on a developer machine that has Docker Desktop.
#
# Usage:
#   scripts/format-oracle.sh [SIZE_MIB]
#     SIZE_MIB  image size (default: 64)
#
# Exit non-zero if the real driver rejects the formatted volume.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
IMG="$WORK/fmt.img"
SIZE_MIB="${1:-64}"

command -v docker >/dev/null || { echo "FAIL: docker not found (needs ntfs-3g; cannot run headless)"; exit 2; }

echo "==> emitting a formatted NTFS image from NTFSCore (FormatEmitTests)…"
# FormatEmitTests is inert unless NTFS_EMIT_PATH is set, so this is the
# supported way to materialize the formatter's on-disk product for an oracle.
NTFS_EMIT_PATH="$IMG" NTFS_EMIT_MIB="$SIZE_MIB" \
  swift test --package-path "$ROOT/Packages/NTFSCore" --filter FormatEmitTests >/dev/null
[ -s "$IMG" ] || { echo "FAIL: NTFSCore did not emit an image at $IMG"; exit 1; }
echo "    emitted $(du -h "$IMG" | cut -f1) image"

echo "==> building ntfs-3g oracle image (cached)…"
docker build -q -t ntfsora - >/dev/null <<'DOCKER'
FROM debian:bookworm-slim
RUN apt-get update -qq && apt-get install -y -qq ntfs-3g && rm -rf /var/lib/apt/lists/*
DOCKER

echo "==> ORACLE: ntfsfix -n (must mount + pass cleanly)"
if ! docker run --rm -v "$WORK:/io" ntfsora ntfsfix -n /io/fmt.img; then
  echo "FAIL: real ntfs-3g rejected the NTFSCore-formatted volume"; exit 1
fi

echo "==> ORACLE: ntfsinfo -m (boot + \$MFT sanity)"
docker run --rm -v "$WORK:/io" ntfsora ntfsinfo -m /io/fmt.img | sed -n '1,20p' || true

echo "PASS: real ntfs-3g mounts + fsck-passes the NTFSCore-formatted volume."
echo
echo "------------------------------------------------------------------"
echo "LIVE FSKit round-trip (real hardware — NOT scriptable here):"
echo "  1. Activate the extension, plug in a spare NTFS USB stick."
echo "  2. In the app's Danger Zone, Format the volume as NTFS."
echo "  3. Mount it read-write; copy files in Finder; eject."
echo "  4. On Linux:   ntfsfix -n /dev/sdX1   (must pass)"
echo "     and read files back to confirm contents + metadata."
echo "  5. On Windows: chkdsk /f X:   (must report zero errors)."
echo "See docs/REPAIR.md for the full manual procedure."
