#!/usr/bin/env bash
# scripts/package.sh
#
# Reproducible local packaging for the NTFSMountManager menu-bar app + its
# embedded NTFSFileSystem FSKit system extension. Produces a runnable `.app`
# bundle (with the extension embedded inside it) under `dist/`.
#
# This is a LOCAL packaging step. It produces a runnable, ad-hoc-signed
# `.app` — NOT a notarized, off-machine-distributable artifact. For real
# personal-use signing and the notarization path, see docs/PACKAGING.md.
#
# Usage:
#   ./scripts/package.sh                 # Release build (default), ad-hoc signed
#   ./scripts/package.sh --release       # explicit Release
#   ./scripts/package.sh --debug         # Debug build (faster, for iteration)
#   ./scripts/package.sh --zip           # also produce dist/NTFSMountManager.zip
#   ./scripts/package.sh --release --zip
#
# Signing:
#   By default the build is AD-HOC signed (CODE_SIGN_IDENTITY="-",
#   CODE_SIGNING_ALLOWED=NO) so it builds with no Apple Developer account.
#   To sign with your free personal Apple ID team for on-machine activation,
#   export DEVELOPMENT_TEAM (and optionally CODE_SIGN_IDENTITY) before running:
#
#     DEVELOPMENT_TEAM=ABCDE12345 ./scripts/package.sh --release
#
#   See docs/PACKAGING.md for the full free-personal-signing walkthrough and
#   the `systemextensionsctl developer on` activation step.
#
# Privileged helper (SMAppService root daemon):
#   The app also embeds NTFSPrivilegedHelper (Contents/MacOS/) + its LaunchDaemon
#   plist (Contents/Library/LaunchDaemons/). The DEFAULT ad-hoc build embeds them
#   correctly and BUILDS fine, but the daemon will NOT register ad-hoc:
#   SMAppService + the XPC code-signature gate require REAL, team-consistent
#   signing (app and daemon under the SAME team; OU pinned to JT8YU25ABP). To
#   exercise the helper at runtime, build signed — see docs/PACKAGING.md §5:
#
#     DEVELOPMENT_TEAM=JT8YU25ABP CODE_SIGN_STYLE=Automatic \
#       CODE_SIGN_IDENTITY="Apple Development" ./scripts/package.sh --release

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate repo root regardless of where the script is invoked from.
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

PROJECT="NTFSMountManager.xcodeproj"
SCHEME="NTFSMountManager"
APP_NAME="NTFSMountManager.app"
BUILD_DIR="${REPO_ROOT}/.build/Package"   # derivedDataPath for this packaging build
DIST_DIR="${REPO_ROOT}/dist"              # final output (gitignored)

# ---------------------------------------------------------------------------
# Parse args.
# ---------------------------------------------------------------------------
CONFIGURATION="Release"
MAKE_ZIP="no"
for arg in "$@"; do
  case "${arg}" in
    --release) CONFIGURATION="Release" ;;
    --debug)   CONFIGURATION="Debug" ;;
    --zip)     MAKE_ZIP="yes" ;;
    -h|--help)
      sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "error: unknown argument '${arg}' (try --help)" >&2
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Signing: ad-hoc by default; honor DEVELOPMENT_TEAM / CODE_SIGN_IDENTITY for
# real personal signing if the caller exported them.
# ---------------------------------------------------------------------------
SIGN_ARGS=()
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  # Real (personal or paid) signing path: let Xcode's automatic signing run.
  echo "==> Signing with DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}"
  SIGN_ARGS+=("DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}")
  if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
    SIGN_ARGS+=("CODE_SIGN_IDENTITY=${CODE_SIGN_IDENTITY}")
  fi
else
  # Ad-hoc signing path: no Apple Developer account required. The resulting
  # .app runs locally but the system extension will only activate after
  # `systemextensionsctl developer on` (see docs/PACKAGING.md).
  echo "==> Ad-hoc signing (no DEVELOPMENT_TEAM set). For on-machine extension"
  echo "    activation with your free Apple ID, see docs/PACKAGING.md."
  SIGN_ARGS+=(
    "CODE_SIGN_IDENTITY=-"
    "CODE_SIGNING_REQUIRED=NO"
    "CODE_SIGNING_ALLOWED=NO"
  )
fi

# ---------------------------------------------------------------------------
# 1. Regenerate the Xcode project from project.yml (the source of truth).
# ---------------------------------------------------------------------------
echo "==> Regenerating Xcode project from project.yml"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found. Install with: brew install xcodegen" >&2
  exit 1
fi
xcodegen generate

# ---------------------------------------------------------------------------
# 2. Build the containing app. Building the app scheme also builds and embeds
#    the NTFSFileSystem extension (project.yml declares `embed: true`).
# ---------------------------------------------------------------------------
echo "==> Building ${SCHEME} (${CONFIGURATION}) into ${BUILD_DIR}"
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination 'platform=macOS' \
  -derivedDataPath "${BUILD_DIR}" \
  "${SIGN_ARGS[@]}" \
  build

BUILT_APP="${BUILD_DIR}/Build/Products/${CONFIGURATION}/${APP_NAME}"
if [[ ! -d "${BUILT_APP}" ]]; then
  echo "error: expected built app not found at ${BUILT_APP}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Copy the freshly built .app into dist/ (clean each run for reproducibility).
# ---------------------------------------------------------------------------
echo "==> Staging app into ${DIST_DIR}"
mkdir -p "${DIST_DIR}"
rm -rf "${DIST_DIR:?}/${APP_NAME}"
# ditto preserves bundle structure, symlinks, and code signatures.
ditto "${BUILT_APP}" "${DIST_DIR}/${APP_NAME}"

DIST_APP="${DIST_DIR}/${APP_NAME}"

# ---------------------------------------------------------------------------
# 4. Verify the FSKit extension is actually embedded inside the bundle.
#    FSKit/SystemExtensions land in Contents/Library/SystemExtensions/; some
#    app-extension layouts use Contents/PlugIns/. Accept either, fail loudly
#    if neither contains an embedded extension.
# ---------------------------------------------------------------------------
echo "==> Verifying embedded extension"
EMBEDDED=""
for candidate in \
  "${DIST_APP}/Contents/Library/SystemExtensions"/*.systemextension \
  "${DIST_APP}/Contents/Library/SystemExtensions"/*.appex \
  "${DIST_APP}/Contents/PlugIns"/*.appex \
  "${DIST_APP}/Contents/PlugIns"/*.systemextension; do
  if [[ -d "${candidate}" ]]; then
    EMBEDDED="${candidate}"
    break
  fi
done

if [[ -z "${EMBEDDED}" ]]; then
  echo "error: no embedded FSKit extension found inside ${DIST_APP}" >&2
  echo "       expected a *.systemextension or *.appex under" >&2
  echo "       Contents/Library/SystemExtensions/ or Contents/PlugIns/" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 5. (Optional) zip the bundle for easy transfer to another machine.
# ---------------------------------------------------------------------------
ZIP_PATH=""
if [[ "${MAKE_ZIP}" == "yes" ]]; then
  ZIP_PATH="${DIST_DIR}/NTFSMountManager.zip"
  echo "==> Creating ${ZIP_PATH}"
  rm -f "${ZIP_PATH}"
  # ditto -c -k makes a Finder-compatible zip preserving bundle metadata.
  ditto -c -k --sequesterRsrc --keepParent "${DIST_APP}" "${ZIP_PATH}"
fi

# ---------------------------------------------------------------------------
# Report.
# ---------------------------------------------------------------------------
EMBEDDED_REL="${EMBEDDED#${DIST_APP}/}"
echo ""
echo "============================================================"
echo "  Packaging complete (${CONFIGURATION}, ad-hoc=$([[ -n "${DEVELOPMENT_TEAM:-}" ]] && echo no || echo yes))"
echo "  App:               ${DIST_APP}"
echo "  Embedded extension: ${EMBEDDED_REL}"
[[ -n "${ZIP_PATH}" ]] && echo "  Zip:               ${ZIP_PATH}"
echo "============================================================"
echo ""
echo "This is a LOCAL runnable .app (ad-hoc signed by default). It is NOT"
echo "notarized and NOT distributable off-machine as-is. To activate the"
echo "system extension on YOUR machine, see docs/PACKAGING.md"
echo "(free Apple ID signing + 'systemextensionsctl developer on')."
