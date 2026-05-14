#!/usr/bin/env bash
# scripts/make_test_images.sh
#
# Phase 1.5 stub. Will call `mkntfs` inside a Linux container (Docker/Podman)
# or VM (UTM/lima) to generate NTFS .img fixtures used by NTFSCoreTests.
# Until that wiring is in place, fixtures are not required — Phase 1 boot-sector
# tests use hand-crafted byte literals in BootSectorTests.swift.
#
# Intended usage (once implemented):
#   ./scripts/make_test_images.sh        # generates all fixtures
#   ./scripts/make_test_images.sh small  # generates only the small fixture

set -euo pipefail

echo "make_test_images.sh: not yet implemented (Phase 1.5)." >&2
echo "See scripts/make_test_images.sh header comment for the plan." >&2
exit 1
