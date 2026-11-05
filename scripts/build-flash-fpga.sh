#!/usr/bin/env bash
#
# build-flash-fpga.sh - compatibility wrapper
# Kept as a shortcut for: scripts/build-standalone.sh flash_fpga
# See scripts/build-standalone.sh for all options.

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/build-standalone.sh" flash_fpga "$@"
