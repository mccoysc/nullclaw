#!/usr/bin/env bash
# Download Zig 0.15.2 compiler binary package to the tools directory.
# Run from the repository root or from within the tools/ directory.
#
# Usage:
#   bash tools/get-zig.sh
#
# After completion the zig compiler will be available at:
#   tools/zig-<os>-<arch>-0.15.2/zig

set -euo pipefail

ZIG_VERSION="0.15.2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZIG_DOWNLOAD_INDEX="https://ziglang.org/download/index.json"

# Detect OS and architecture
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "$OS" in
  linux)  ZIG_OS="linux" ;;
  darwin) ZIG_OS="macos" ;;
  *)
    echo "Unsupported OS: $OS" >&2
    exit 1
    ;;
esac

case "$ARCH" in
  x86_64)  ZIG_ARCH="x86_64" ;;
  aarch64 | arm64) ZIG_ARCH="aarch64" ;;
  riscv64) ZIG_ARCH="riscv64" ;;
  armv7l)  ZIG_ARCH="armv7a" ;;
  *)
    echo "Unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

PACKAGE_NAME="zig-${ZIG_OS}-${ZIG_ARCH}-${ZIG_VERSION}"
TARBALL="${PACKAGE_NAME}.tar.xz"
DEST_DIR="${SCRIPT_DIR}/${PACKAGE_NAME}"
DOWNLOAD_URL="https://ziglang.org/download/${ZIG_VERSION}/${TARBALL}"

if [ -d "$DEST_DIR" ]; then
  echo "Zig ${ZIG_VERSION} already present at ${DEST_DIR}"
  echo "Delete the directory to re-download."
  exit 0
fi

echo "Downloading Zig ${ZIG_VERSION} for ${ZIG_OS}-${ZIG_ARCH}..."
echo "  URL: ${DOWNLOAD_URL}"
echo "  Destination: ${DEST_DIR}"

cd "$SCRIPT_DIR"

# Fetch expected SHA256 from the official download index.
EXPECTED_SHA256=""
if command -v python3 &>/dev/null; then
  FETCH_CMD=""
  if command -v curl &>/dev/null; then
    FETCH_CMD="curl -sL --fail"
  elif command -v wget &>/dev/null; then
    FETCH_CMD="wget -qO-"
  fi
  if [ -n "$FETCH_CMD" ]; then
    EXPECTED_SHA256="$($FETCH_CMD "$ZIG_DOWNLOAD_INDEX" 2>/dev/null \
      | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    pkg = '${ZIG_OS}-${ZIG_ARCH}'
    info = d.get('${ZIG_VERSION}', {}).get(pkg, {})
    print(info.get('shasum', ''))
except Exception:
    pass
" 2>/dev/null || true)"
  fi
fi

# Download the tarball.
if command -v curl &>/dev/null; then
  curl -L --fail --progress-bar -o "${TARBALL}" "${DOWNLOAD_URL}"
elif command -v wget &>/dev/null; then
  wget -O "${TARBALL}" "${DOWNLOAD_URL}"
else
  echo "Neither curl nor wget found. Please install one and retry." >&2
  exit 1
fi

# Verify SHA256 checksum if we were able to retrieve one.
if [ -n "$EXPECTED_SHA256" ]; then
  echo "Verifying checksum..."
  if command -v sha256sum &>/dev/null; then
    ACTUAL_SHA256="$(sha256sum "${TARBALL}" | awk '{print $1}')"
  elif command -v shasum &>/dev/null; then
    ACTUAL_SHA256="$(shasum -a 256 "${TARBALL}" | awk '{print $1}')"
  else
    echo "Warning: neither sha256sum nor shasum found; skipping checksum verification." >&2
    ACTUAL_SHA256=""
  fi
  if [ -n "$ACTUAL_SHA256" ]; then
    if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
      echo "Checksum mismatch for ${TARBALL}:" >&2
      echo "  expected: ${EXPECTED_SHA256}" >&2
      echo "  actual:   ${ACTUAL_SHA256}" >&2
      rm -f "${TARBALL}"
      exit 1
    fi
    echo "  Checksum OK (${ACTUAL_SHA256:0:16}...)"
  fi
else
  echo "Warning: could not fetch checksum from ${ZIG_DOWNLOAD_INDEX}; skipping verification." >&2
fi

echo "Extracting ${TARBALL}..."
# Extract to a temporary directory first, then verify the top-level directory
# matches the expected package name to guard against unexpected layout.
TMPDIR_EXTRACT="$(mktemp -d "${SCRIPT_DIR}/.zig-extract-XXXXXX")"
trap 'rm -rf "${TMPDIR_EXTRACT}"' EXIT

tar -xJf "${TARBALL}" -C "${TMPDIR_EXTRACT}"

EXTRACTED_DIRS=("${TMPDIR_EXTRACT}"/*)
if [ "${#EXTRACTED_DIRS[@]}" -ne 1 ] || [ "$(basename "${EXTRACTED_DIRS[0]}")" != "${PACKAGE_NAME}" ]; then
  echo "Unexpected extraction layout in ${TARBALL}:" >&2
  ls "${TMPDIR_EXTRACT}" >&2
  exit 1
fi

mv "${EXTRACTED_DIRS[0]}" "${DEST_DIR}"
rm -f "${TARBALL}"

echo ""
echo "Done. Zig ${ZIG_VERSION} installed at:"
echo "  ${DEST_DIR}/zig"
echo ""
echo "Add to PATH:"
echo "  export PATH=\"${DEST_DIR}:\$PATH\""
