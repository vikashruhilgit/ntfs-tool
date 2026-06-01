#!/usr/bin/env bash
# ntfs-oracle.sh — validate ntfsctl's writes against the REAL ntfs-3g driver.
#
# This is the cross-validation oracle the project long lacked: our own reader
# accepting a volume proves nothing (it shares any bug the writer has). A real
# NTFS implementation (ntfs-3g / ntfsprogs, the same lineage Linux ships) is the
# authority. It runs in Docker, entirely on a disk image — no physical drive,
# no Windows, fully reproducible.
#
# What it does:
#   1. Builds a Docker image with ntfs-3g (cached after first run).
#   2. Formats a fresh NTFS image with the REAL mkntfs.
#   3. Copies a source tree into it with ntfsctl (the binary under test).
#   4. Runs `ntfsfix -n` (must mount + pass) and reads files back via
#      `ntfscat`, checksumming against the source (must match byte-exact).
#
# Usage:
#   scripts/ntfs-oracle.sh [SRC_DIR] [SIZE_MIB]
#     SRC_DIR   tree to copy (default: a generated nested fixture)
#     SIZE_MIB  image size (default: 512)
#
# Exit non-zero if the real driver rejects the volume or any checksum mismatches.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
IMG="$WORK/oracle.img"
SRC="${1:-}"
SIZE_MIB="${2:-512}"
BIN="$ROOT/Tools/ntfsctl/.build/release/ntfsctl"

command -v docker >/dev/null || { echo "FAIL: docker not found"; exit 2; }
[ -x "$BIN" ] || { echo "Building ntfsctl (release)…"; swift build -c release --package-path "$ROOT/Tools/ntfsctl"; }

echo "==> building ntfs-3g oracle image (cached)…"
docker build -q -t ntfsora - >/dev/null <<'DOCKER'
FROM debian:bookworm-slim
RUN apt-get update -qq && apt-get install -y -qq ntfs-3g && rm -rf /var/lib/apt/lists/*
DOCKER

if [ -z "$SRC" ]; then
  SRC="$WORK/src"; mkdir -p "$SRC/a" "$SRC/b/c"
  for i in $(seq 1 200); do echo "file $i payload" > "$SRC/a/f$i.txt"; done
  for i in $(seq 1 200); do head -c 3000 /dev/urandom > "$SRC/b/c/g$i.bin"; done
  echo "==> generated fixture: $(find "$SRC" -type f | wc -l | tr -d ' ') files"
fi

dd if=/dev/zero of="$IMG" bs=1m count="$SIZE_MIB" 2>/dev/null
echo "==> formatting with REAL mkntfs (ntfs-3g)…"
docker run --rm -v "$WORK:/io" ntfsora mkntfs -Q -F -L ORACLE /io/oracle.img >/dev/null 2>&1

echo "==> ntfsctl cp (the code under test)…"
"$BIN" cp -rT "$SRC" "$IMG" /data >/dev/null

echo "==> ORACLE: ntfsfix -n"
if ! docker run --rm -v "$WORK:/io" ntfsora ntfsfix -n /io/oracle.img; then
  echo "FAIL: real ntfs-3g rejected the volume"; exit 1
fi

echo "==> ORACLE: read-back checksums via ntfscat"
fail=0
while IFS= read -r f; do
  rel="${f#"$SRC"/}"
  want="$(sha1sum "$f" | cut -d' ' -f1)"
  got="$(docker run --rm -v "$WORK:/io" ntfsora ntfscat "/io/oracle.img" "/data/$rel" 2>/dev/null | sha1sum | cut -d' ' -f1)"
  if [ "$want" != "$got" ]; then echo "  MISMATCH: /data/$rel ($want != $got)"; fail=1; fi
done < <(find "$SRC" -type f | head -25)
[ "$fail" = 0 ] || { echo "FAIL: read-back mismatch"; exit 1; }

echo "PASS: real ntfs-3g mounts the ntfsctl-written volume and reads it back byte-exact."
