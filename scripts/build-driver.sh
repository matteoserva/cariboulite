#!/usr/bin/env bash
#
# build-driver.sh
#
# Cross-build the cariboulite kernel module (smi_stream_dev.ko) on the host,
# against the Raspberry Pi kernel headers rsync'd into rpi-sysroot/ by
# scripts/fetch-kernel-headers.sh.
#
# Flow:
#   1. make sure the sysroot headers exist (auto-fetch when missing)
#   2. swap the target-arch kbuild host tools (fixdep, modpost) copied from
#      the target for native ones vendored in scripts/kbuild-host-tools/
#   3. mirror the driver sources into driver/build-host/ and drop a plain
#      kbuild Makefile there (same as the on-target CMake flow produces)
#   4. make -C <sysroot build dir> ARCH=.. CROSS_COMPILE=.. CC=.. M=.. modules
#
# Result: driver/build-host/smi_stream_dev.ko
#
# Usage: scripts/build-driver.sh [-f|--fetch] [-c|--clean] [-v|--verbose]

set -euo pipefail

PROGRAM_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

DRIVER_DIR="$REPO_ROOT/driver"
OUT_DIR="$DRIVER_DIR/build-host"
ENVFILE="$REPO_ROOT/rpi-sysroot/kernel-headers.env"
FETCH=0
CLEAN=0
VERBOSE=0

usage() {
    cat <<EOF
Usage: $PROGRAM_NAME [options]

Cross-compile driver/smi_stream_dev.ko on the host (no ssh needed after the
headers were fetched once).

Options:
  -f, --fetch      re-run scripts/fetch-kernel-headers.sh first (target kernel
                   changed); otherwise headers are fetched only if missing
  -c, --clean      make clean in the module build dir and exit
  -v, --verbose    show the full kbuild command line
  -h, --help       this help

Environment: SYSROOT (must match what was fetched; default <repo>/rpi-sysroot)
EOF
}

die() { printf '%s: error: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }
say() { printf '%s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
    case "$1" in
        -f|--fetch)  FETCH=1; shift ;;
        -c|--clean)  CLEAN=1; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) usage >&2; die "unexpected argument: $1" ;;
    esac
done

[ -d "$DRIVER_DIR" ] || die "driver directory not found: $DRIVER_DIR"

if [ -n "${SYSROOT:-}" ]; then
    ENVFILE="$SYSROOT/kernel-headers.env"
fi

# --- 1. kernel headers -------------------------------------------------------------------------
if [ "$FETCH" -eq 1 ] || [ ! -f "$ENVFILE" ]; then
    say "==> fetching kernel headers from the target"
    "$SCRIPT_DIR/fetch-kernel-headers.sh"   # incremental; retransfers only changes
    [ -f "$ENVFILE" ] || die "env file $ENVFILE still missing after fetch"
fi
[ -f "$ENVFILE" ] || die "no $ENVFILE -- run scripts/fetch-kernel-headers.sh first (or pass --fetch)"

# shellcheck source=/dev/null
. "$ENVFILE"

for v in KERNEL_RELEASE KERNEL_ARCH CROSS_COMPILE KERNEL_BUILD_DIR; do
    [ -n "${!v:-}" ] || die "$v missing in $ENVFILE -- re-run fetch-kernel-headers.sh"
done
[ -d "$KERNEL_BUILD_DIR" ] || die "kernel build dir missing: $KERNEL_BUILD_DIR (run fetch-kernel-headers.sh)"

command -v "${CROSS_COMPILE}gcc" >/dev/null || die \
    "cross compiler ${CROSS_COMPILE}gcc not found -- install gcc-aarch64-linux-gnu (arm) / gcc-arm-linux-gnueabihf (armhf)"

KBUILD_SCRIPTS="${KBUILD_DIR:-$KERNEL_BUILD_DIR}/scripts"

# --- clean ------------------------------------------------------------------------------------
if [ "$CLEAN" -eq 1 ]; then
    if [ -d "$OUT_DIR" ]; then
        make -C "$KERNEL_BUILD_DIR" "ARCH=$KERNEL_ARCH" "CROSS_COMPILE=$CROSS_COMPILE" \
             "M=$OUT_DIR" clean >&2 || true
        say "==> cleaned $OUT_DIR"
    fi
    exit 0
fi

# --- 2. kbuild host tools must be native ---------------------------------------------------------
# The sysroot scripts/ dirs were copied from the target, so fixdep/modpost are
# target-arch ELF the host cannot execute, and the headers packages carry no
# sources to rebuild them. Swap in the vendored native binaries instead.
# (On an arm64 host the target binaries are already native and nothing happens.)
HOST_TOOLS="$SCRIPT_DIR/kbuild-host-tools/$(uname -m)"
if [ -d "$KBUILD_SCRIPTS" ] && [ -n "${CROSS_COMPILE:-}" ]; then
    swap_foreign() { # $1 = binary name, $2 = vendored source file
        local f host_tag foreign=
        host_tag=$(uname -m | sed 's/^x86_64$/x86-64/')
        for f in $(find "$KBUILD_SCRIPTS" "$(dirname "$KERNEL_SRC_DIR")/scripts" -type f -name "$1" 2>/dev/null); do
            file "$f" | grep -q "$host_tag" || foreign="$foreign $f"
        done
        [ -n "$foreign" ] || return 0
        say "==> installing native $1: $foreign"
        # shellcheck disable=SC2086
        for f in $foreign; do
            rm -f "$f"
            cp -f "$2" "$f"
        done
    }
    [ -d "$HOST_TOOLS" ] || die "no vendored kbuild host tools for $(uname -m) (see scripts/kbuild-host-tools/README.md)"
    swap_foreign fixdep  "$HOST_TOOLS/fixdep"
    swap_foreign modpost "$HOST_TOOLS/modpost"
fi

# --- 3. module build dir ------------------------------------------------------------------------
say "==> preparing $OUT_DIR"
mkdir -p "$OUT_DIR"
cp -f "$DRIVER_DIR"/*.c "$DRIVER_DIR"/*.h "$OUT_DIR/"
cat > "$OUT_DIR/Makefile" <<'KBUILD'
obj-m += smi_stream_dev.o
ccflags-y += -O2 -DMODULE -D__KERNEL__
KBUILD

# --- 4. build -----------------------------------------------------------------------------------
say "==> building smi_stream_dev.ko for $KERNEL_RELEASE ($KERNEL_ARCH)"
# CC= override: Debian's .kernelvariables pins CC to the target's gcc flavour
# (e.g. gcc-12) which the host does not have; the host cross-gcc is compatible.
MAKE_ARGS=(-C "$KERNEL_BUILD_DIR" "ARCH=$KERNEL_ARCH" "CROSS_COMPILE=$CROSS_COMPILE"
           "CC=${CROSS_COMPILE}gcc" "M=$OUT_DIR" modules)
[ "$VERBOSE" -eq 1 ] && MAKE_ARGS+=(V=1)
make "${MAKE_ARGS[@]}"

# --- 5. result ----------------------------------------------------------------------------------
KO="$OUT_DIR/smi_stream_dev.ko"
[ -f "$KO" ] || die "build finished but $KO is missing"
say "==> done"
say "    module : $KO"
say "           $(file "$KO")"
ver=$(modinfo -F vermagic "$KO" 2>/dev/null || true)
[ -n "$ver" ] && say "    vermagic: $ver"
say ""
say "Deploy to the target with:"
say "    scp $KO ${TARGET:-pi@sdrpy}:~/ && ssh ${TARGET:-pi@sdrpy} 'sudo insmod ~/smi_stream_dev.ko'"
