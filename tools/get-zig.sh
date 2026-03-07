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

if command -v curl &>/dev/null; then
  curl -L --fail --progress-bar -o "${TARBALL}" "${DOWNLOAD_URL}"
elif command -v wget &>/dev/null; then
  wget -O "${TARBALL}" "${DOWNLOAD_URL}"
else
  echo "Neither curl nor wget found. Please install one and retry." >&2
  exit 1
fi

echo "Extracting ${TARBALL}..."
tar -xJf "${TARBALL}"
rm -f "${TARBALL}"

echo ""
echo "Done. Zig ${ZIG_VERSION} installed at:"
echo "  ${DEST_DIR}/zig"
echo ""
echo "Add to PATH:"
echo "  export PATH=\"${DEST_DIR}:\$PATH\""
