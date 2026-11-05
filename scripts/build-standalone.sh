#!/usr/bin/env bash
#
# build-standalone.sh
#
# Build the standalone software/<tool> utilities that compile the needed
# parts of libcariboulite straight from the source tree (no prebuilt
# library, no SoapySDR, kernel headers not involved):
#
#   flash_fpga  - FPGA .bin uploader            (software/flash_fpga)
#   tx_test     - TX stream tester, no flashing (software/tx_test)
#
# Modes (auto-detected from the host architecture):
#   - on the target / any aarch64 machine: native cmake build
#   - on an x86_64 host: cross build with gcc-aarch64-linux-gnu
#
# Result:
#   software/<tool>/build/flash_fpga            (native)
#   software/<tool>/build-aarch64/tx_test       (cross)
#
# Usage: scripts/build-standalone.sh [tool...] [options]
#        scripts/build-standalone.sh all
#        scripts/build-standalone.sh flash_fpga --deploy

set -euo pipefail

PROGRAM_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

CROSS_COMPILE_PREFIX="${CROSS_COMPILE:-aarch64-linux-gnu-}"
DEPLOY_HOST="${DEPLOY_HOST:-pi@sdrpy}"
# native (on-target) builds must stay light: the Pi has little RAM and
# several concurrent CMake compiles can OOM-crash it. Override with
# MAKE_JOBS=N if you know what you are doing.
MAKE_JOBS="${MAKE_JOBS:-2}"

TOOLS_KNOWN="flash_fpga tx_test"

usage() {
    cat <<EOF
Usage: $PROGRAM_NAME [tool...] [options]

Build standalone utilities from software/<tool> (flash_fpga, tx_test).
Tools: $TOOLS_KNOWN (or 'all'; default: all)

Options:
  --native        force a native build (default on aarch64 hosts)
  --cross         force an aarch64 cross build (default on x86_64 hosts)
  --clean         remove the build directories of the given tools and exit
  --deploy        scp the resulting binaries to the target
                  (DEPLOY_HOST=pi@sdrpy overridable; lands in
                  ~/cariboulite/software/<tool>/)
  -h, --help      this help

Host cross deps (x86_64 build host): apt install cmake gcc-aarch64-linux-gnu
EOF
}

die() { printf '%s: error: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }
say() { printf '%s\n' "$*" >&2; }

TOOLS=()
MODE=""
CLEAN=0
DEPLOY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --native)  MODE="native" ;;
        --cross)   MODE="cross" ;;
        --clean)   CLEAN=1 ;;
        --deploy)  DEPLOY=1 ;;
        -h|--help) usage; exit 0 ;;
        all)       TOOLS=($TOOLS_KNOWN) ;;
        -*)        usage >&2; die "unexpected option: $1" ;;
        *)
            found=0
            for t in $TOOLS_KNOWN; do [ "$1" = "$t" ] && { found=1; break; }; done
            [ "$found" -eq 1 ] || { usage >&2; die "unknown tool: $1 (known: $TOOLS_KNOWN)"; }
            TOOLS+=("$1")
            ;;
    esac
    shift
done
[ ${#TOOLS[@]} -gt 0 ] || TOOLS=($TOOLS_KNOWN)

if [ "$CLEAN" -eq 1 ]; then
    for t in "${TOOLS[@]}"; do
        rm -rf "$REPO_ROOT/software/$t/build" "$REPO_ROOT/software/$t/build-aarch64"
    done
    say "==> cleaned ${TOOLS[*]} build directories"
    exit 0
fi

command -v cmake >/dev/null || die "cmake not found -- install it (apt install cmake)"

# one build at a time - concurrent runs can exhaust the target's RAM
LOCK="$REPO_ROOT/.build-standalone.lock"
exec 9>"$LOCK"
flock -n 9 || die "another $PROGRAM_NAME is already running (lock: $LOCK)"

if [ -z "$MODE" ]; then
    case "$(uname -m)" in
        aarch64|armv8l) MODE="native" ;;
        *)              MODE="cross" ;;
    esac
fi

if [ "$MODE" = "cross" ]; then
    CC="${CROSS_COMPILE_PREFIX}gcc"
    command -v "$CC" >/dev/null || die \
        "cross compiler $CC not found -- install gcc-aarch64-linux-gnu (apt install), or build natively on the target"
fi

for t in "${TOOLS[@]}"; do
    TOOL_DIR="$REPO_ROOT/software/$t"
    [ -f "$TOOL_DIR/CMakeLists.txt" ] || die "tool project not found: $TOOL_DIR"

    if [ "$MODE" = "cross" ]; then
        BUILD_DIR="$TOOL_DIR/build-aarch64"
        say "==> cross-building $t for aarch64 with $CC"
        cmake -S "$TOOL_DIR" -B "$BUILD_DIR" \
              -DCMAKE_TOOLCHAIN_FILE="$TOOL_DIR/aarch64-toolchain.cmake" \
              -DCROSS_COMPILE="$CROSS_COMPILE_PREFIX"
        JOBS="$(nproc)"
    else
        BUILD_DIR="$TOOL_DIR/build"
        say "==> natively building $t on $(uname -m) (-j$MAKE_JOBS)"
        cmake -S "$TOOL_DIR" -B "$BUILD_DIR"
        JOBS="$MAKE_JOBS"
    fi
    cmake --build "$BUILD_DIR" -j"$JOBS"

    BIN="$BUILD_DIR/$t"
    [ -x "$BIN" ] || die "build finished but $BIN is missing"
    say "==> built: $BIN"
    file "$BIN" >&2

    if [ "$DEPLOY" -eq 1 ]; then
        say "==> deploying $t to $DEPLOY_HOST"
        # shellcheck disable=SC2086
        scp "$BIN" "$DEPLOY_HOST:cariboulite/software/$t/$t"
    fi
done
