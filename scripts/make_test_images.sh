#!/usr/bin/env bash
# scripts/make_test_images.sh
#
# Generates NTFS .img fixtures used by NTFSCoreTests by running `mkntfs` and
# `ntfs-3g` inside a Debian Docker container. Requires Docker Desktop (or any
# Linux container runtime exposing the standard `docker` CLI) to be running.
#
# Usage:
#   ./scripts/make_test_images.sh         # regenerate Packages/NTFSCore/Tests/NTFSCoreTests/Fixtures/small.img
#   ./scripts/make_test_images.sh --check # verify Docker is reachable, exit without generating
#
# The output fixture is committed to the repo so CI does not need Docker. Run
# this script only when the fixture's contents need to change (e.g. new test
# files inside the image). Commit the resulting small.img alongside any test
# code that depends on its new contents.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="${REPO_ROOT}/Packages/NTFSCore/Tests/NTFSCoreTests/Fixtures"
FIXTURE_PATH="${FIXTURE_DIR}/small.img"
DEBIAN_IMAGE="debian:bookworm-slim"

# Image size: 4 MiB. mkntfs's minimum is around 1.4 MiB; 4 MiB leaves room for
# several small test files inside without ballooning the committed binary.
IMG_SIZE_BYTES=$((4 * 1024 * 1024))

require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "error: docker CLI not found on PATH" >&2
        echo "       install Docker Desktop (https://www.docker.com/products/docker-desktop/) and retry" >&2
        exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
        echo "error: docker daemon not reachable" >&2
        echo "       start Docker Desktop and retry (or 'open -a Docker' on macOS)" >&2
        exit 1
    fi
}

if [ "${1:-}" = "--check" ]; then
    require_docker
    echo "Docker is reachable: $(docker version --format '{{.Client.Version}}' 2>/dev/null)"
    exit 0
fi

require_docker
mkdir -p "${FIXTURE_DIR}"

echo "==> Generating ${FIXTURE_PATH} (${IMG_SIZE_BYTES} bytes via mkntfs in ${DEBIAN_IMAGE})"

# All work happens inside the container so the host doesn't need ntfsprogs.
# We pass the image size as an env var, generate the file in /work, then `cp`
# it out via a mounted volume.
docker run --rm \
    --privileged \
    -e IMG_SIZE_BYTES="${IMG_SIZE_BYTES}" \
    -v "${FIXTURE_DIR}:/out" \
    "${DEBIAN_IMAGE}" \
    bash -euo pipefail -c '
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null
        apt-get install -y -qq ntfs-3g >/dev/null

        WORK=/tmp/fixture
        IMG="${WORK}/small.img"
        mkdir -p "${WORK}"

        # Sparse 4 MiB file (block-count 8192 at 512-byte blocks).
        dd if=/dev/zero of="${IMG}" bs=512 count=$((IMG_SIZE_BYTES / 512)) status=none

        # --fast skips zero-init of unused space; --label gives a known volume name
        # for later tests. --quiet and -F suppress interactive prompts.
        mkntfs --fast --quiet -F --label NTFSCORETEST --cluster-size 4096 "${IMG}"

        # Mount the image via ntfs-3g and drop a couple of small known-content
        # files in. These will be exercised by later iterations (MFT, $I30,
        # file read). Phase 1 only validates the boot sector.
        MOUNT=/tmp/mount
        mkdir -p "${MOUNT}"
        ntfs-3g -o force "${IMG}" "${MOUNT}"

        printf "Hello, NTFS.\n" > "${MOUNT}/hello.txt"
        printf "%s" "$(printf "abcdefghij%.0s" {1..256})" > "${MOUNT}/medium.txt"
        mkdir "${MOUNT}/sub"
        printf "nested\n" > "${MOUNT}/sub/nested.txt"

        umount "${MOUNT}"

        # Run ntfsfix to confirm the image is clean before we copy it out.
        ntfsfix --no-action "${IMG}" >/dev/null

        cp "${IMG}" /out/small.img
        chmod 0644 /out/small.img
        echo "fixture size: $(stat -c %s /out/small.img) bytes"
    '

echo "==> Fixture ready at ${FIXTURE_PATH}"
ls -la "${FIXTURE_PATH}"
