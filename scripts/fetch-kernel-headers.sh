#!/usr/bin/env bash
#
# fetch-kernel-headers.sh
#
# Ask the target which kernel is actually running, then rsync that kernel's
# build tree (headers) into the local cross-compile sysroot (rpi-sysroot/).
#
# The remote layout is mirrored 1:1 under rpi-sysroot/, because the Raspberry Pi
# OS header packages are split over three trees that reference each other:
#
#   /usr/src/linux-headers-<ver>            flavour (arch bits, generated/autoconf.h)
#     |-- Makefile: "include /usr/src/linux-headers-<common>/Makefile"  (absolute)
#     `-- scripts -> ../../lib/linux-kbuild-<series>/scripts            (relative)
#   /usr/src/linux-headers-<common>         all headers + scripts sources
#   /usr/lib/linux-kbuild-<series>          kbuild infrastructure (scripts/tools)
#
# All of them are copied, and only the absolute include in the copied flavour
# Makefile is rewritten to the sysroot path; the relative links keep resolving
# on their own. /lib/modules/<ver>/{build,source} are re-created as relative
# symlinks inside the sysroot, so
#   make -C <sysroot>/lib/modules/<ver>/build M=<dir> modules
# works as it does on the target.
#
# See AGENTS.md: the driver is normally built *on the target*; this sysroot is
# for host-side tooling (IDE/indexer, static analysis, optional cross builds).

set -euo pipefail

PROGRAM_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

TARGET="${TARGET:-pi@sdrpy}"
SYSROOT="${SYSROOT:-$REPO_ROOT/rpi-sysroot}"
KERNEL_OVERRIDE=""
DRY_RUN=0
VERBOSE=0
DELETE=1

usage() {
    cat <<EOF
Usage: $PROGRAM_NAME [options]

Retrieve the kernel version running on the target, then rsync the matching
kernel headers into the local sysroot (default: <repo>/rpi-sysroot).

Options:
  -t, --target USER@HOST   target ssh address   (default: $TARGET, env TARGET)
  -o, --sysroot DIR        sysroot to populate  (default: <repo>/rpi-sysroot, env SYSROOT)
  -k, --kernel VER         use VER instead of the target's "uname -r"
      --no-delete          do not pass --delete to rsync (keep stale local files)
  -n, --dry-run            show what would be copied; write nothing
  -v, --verbose            verbose rsync (per-file list + stats)
  -h, --help               this help

Environment: TARGET, SYSROOT, SSH_OPTS (extra ssh options)
Exit codes: 0 ok, 1 local failure, 2 usage, 3 target-side failure (no headers)
EOF
}

die() { printf '%s: error: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }
say() { printf '%s\n' "$*" >&2; }
regex_escape() { printf '%s' "$1" | sed 's/[][(){}*+?^.$/\\|]/\\&/g'; }

while [ $# -gt 0 ]; do
    case "$1" in
        -t|--target)  TARGET="${2:?missing value for $1}"; shift 2 ;;
        -o|--sysroot) SYSROOT="${2:?missing value for $1}"; shift 2 ;;
        -k|--kernel)  KERNEL_OVERRIDE="${2:?missing value for $1}"; shift 2 ;;
        --no-delete)  DELETE=0; shift ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        -*)           usage >&2; exit 2 ;;
        *)            usage >&2; printf '%s: error: unexpected argument: %s\n' "$PROGRAM_NAME" "$1" >&2; exit 2 ;;
    esac
done

for tool in ssh rsync realpath sed; do
    command -v "$tool" >/dev/null || die "$tool not found on host"
done

SSH=(ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=20)
if [ -n "${SSH_OPTS:-}" ]; then
    read -r -a _extra_ssh <<<"$SSH_OPTS"
    SSH+=("${_extra_ssh[@]}")
fi
RSYNC_SSH="${SSH[*]}"

# --- 1. ask the target which kernel runs and which trees it needs -----------------------------------
say "==> querying $TARGET for the running kernel and its build tree"

probe() {
    "${SSH[@]}" "$TARGET" sh -s <<'REMOTE'
set -e
V=$(uname -r)
M=$(uname -m)
H=$(uname -n)

obj="/lib/modules/$V/build"
[ -e "$obj" ] || obj="/usr/src/linux-headers-$V"
if [ ! -d "$obj" ]; then
    echo "$H: no kernel build tree for the running kernel $V" >&2
    echo "  install the headers on the target first, e.g.:" >&2
    echo "    sudo apt-get update && sudo apt-get install -y linux-headers-$V" >&2
    echo "  (meta-packages: linux-headers-rpi-v8 / raspberrypi-kernel-headers)" >&2
    exit 3
fi
obj=$(readlink -f "$obj")

# "common" headers tree, referenced by an absolute include from the flavour Makefile
src=$(sed -n 's|^include[[:space:]]*\(/usr/src/[^[:space:]]*/Makefile\)$|\1|p' "$obj/Makefile" | head -n1)
if [ -n "$src" ]; then
    src=$(readlink -f "${src%/Makefile}")
fi
if [ -z "$src" ] || [ ! -d "$src" ]; then
    echo "$H: could not resolve the common headers tree from $obj/Makefile" >&2
    exit 3
fi

# kbuild tree(s), referenced by the relative scripts/tools symlinks in the flavour tree
for l in scripts tools; do
    if [ -L "$obj/$l" ]; then
        t=$(readlink -f "$obj/$l") || continue
        [ -d "$t" ] || continue
        printf 'KBUILDTREE=%s\n' "$(dirname "$t")"
    fi
done

printf 'KERNEL_RELEASE=%s\n' "$V"
printf 'KERNEL_MACHINE=%s\n' "$M"
printf 'OBJTREE=%s\n' "$obj"
printf 'SRCTREE=%s\n' "$src"
REMOTE
}

probe_err=$(mktemp)
if ! probe_out=$(probe 2>"$probe_err"); then
    cat "$probe_err" >&2
    rm -f "$probe_err"
    die "could not retrieve kernel information from $TARGET"
fi
rm -f "$probe_err"

KERNEL_RELEASE="" KERNEL_MACHINE="" OBJTREE="" SRCTREE="" KBUILDTREES=()
while IFS='=' read -r k v; do
    case "$k" in
        KERNEL_RELEASE) KERNEL_RELEASE="$v" ;;
        KERNEL_MACHINE) KERNEL_MACHINE="$v" ;;
        OBJTREE)        OBJTREE="$v" ;;
        SRCTREE)        SRCTREE="$v" ;;
        KBUILDTREE)     KBUILDTREES+=("$v") ;;
    esac
done <<<"$probe_out"

if [ -z "$KERNEL_RELEASE" ] || [ -z "$OBJTREE" ] || [ -z "$SRCTREE" ]; then
    die "malformed reply from target: [$probe_out]"
fi

if [ -n "$KERNEL_OVERRIDE" ] && [ "$KERNEL_OVERRIDE" != "$KERNEL_RELEASE" ]; then
    say "    NOTE: --kernel '$KERNEL_OVERRIDE' requested, but $TARGET runs '$KERNEL_RELEASE'"
    KERNEL_RELEASE="$KERNEL_OVERRIDE"
fi

case "$KERNEL_MACHINE" in
    aarch64|arm64)  KERNEL_ARCH=arm64; CROSS_COMPILE=aarch64-linux-gnu- ;;
    armv6l|armv7l)  KERNEL_ARCH=arm;   CROSS_COMPILE=arm-linux-gnueabihf- ;;
    x86_64)         KERNEL_ARCH=x86;   CROSS_COMPILE= ;;
    *)              KERNEL_ARCH="$KERNEL_MACHINE"; CROSS_COMPILE= ;;
esac

# --- 2. map the remote trees onto the sysroot -------------------------------------------------------
mkdir -p "$SYSROOT"
SYSROOT="$(cd -- "$SYSROOT" && pwd)"

# Mirror the remote absolute path under the sysroot, keeping the tree relocatable
# and the relative symlinks valid.
sysroot_of() {
    case "$1" in
        /*) printf '%s%s\n' "$SYSROOT" "$1" ;;
        *)  die "unexpected non-absolute path on target: $1" ;;
    esac
}

TREES=("$OBJTREE" "$SRCTREE")
seen_kb=()
for kb in ${KBUILDTREES[@]+"${KBUILDTREES[@]}"}; do
    skip=0
    for s in ${seen_kb[@]+"${seen_kb[@]}"}; do [ "$s" = "$kb" ] && skip=1; done
    [ "$skip" -eq 1 ] && continue
    seen_kb+=("$kb"); TREES+=("$kb")
done

say "==> target $TARGET runs kernel $KERNEL_RELEASE ($KERNEL_MACHINE -> ARCH=$KERNEL_ARCH)"
for t in "${TREES[@]}"; do
    say "    $t"
    say "        -> $(sysroot_of "$t")"
done
[ "$DRY_RUN" -eq 1 ] && say "    (dry run: nothing is written)"

# --- 3. rsync the trees into the sysroot -------------------------------------------------------------
RSYNC=(-a --human-readable --no-motd --insecure-links)
# --insecure-links: rsync >=3.5 refuses to materialise symlinked files under
# directories owned by a different uid; the sysroot is our own generated tree.
[ "$DELETE" -eq 1 ] && RSYNC+=(--delete)
if [ "$DRY_RUN" -eq 1 ]; then
    RSYNC+=(-n --itemize-changes)
elif [ "$VERBOSE" -eq 1 ]; then
    RSYNC+=(--progress --stats)
else
    RSYNC+=(--info=progress2)
fi

for t in "${TREES[@]}"; do
    dest="$(sysroot_of "$t")"
    say "==> rsync $TARGET:$t"
    [ "$DRY_RUN" -eq 0 ] && mkdir -p "$dest"
    rsync "${RSYNC[@]}" -e "$RSYNC_SSH" -- "$TARGET:$t/" "$dest/" \
        || die "rsync failed for $TARGET:$t"
done

# --- 4. point the copied flavour Makefile at the copied common tree ----------------------------------
OBJ_LOCAL="$(sysroot_of "$OBJTREE")"
SRC_LOCAL="$(sysroot_of "$SRCTREE")"
MODULES_LOCAL="$SYSROOT/lib/modules/$KERNEL_RELEASE"
KERNEL_BUILD_DIR="$MODULES_LOCAL/build"
ENVFILE="$SYSROOT/kernel-headers.env"

if [ "$DRY_RUN" -eq 1 ]; then
    say "==> would rewrite $OBJ_LOCAL/Makefile: $SRCTREE -> $SRC_LOCAL"
    say "==> would link $MODULES_LOCAL/{build,source}"
else
    say "==> rewriting the absolute include in $OBJ_LOCAL/Makefile"
    cp -f "$OBJ_LOCAL/Makefile" "$OBJ_LOCAL/Makefile.sysroot.orig"
    # sed -i chokes on read-only-ownership mounts; rewrite through the existing inode.
    sed "s|$SRCTREE|$SRC_LOCAL|g" "$OBJ_LOCAL/Makefile.sysroot.orig" > "$OBJ_LOCAL/Makefile.new"
    cat "$OBJ_LOCAL/Makefile.new" > "$OBJ_LOCAL/Makefile"
    rm -f "$OBJ_LOCAL/Makefile.new"
    say "    $(head -n1 "$OBJ_LOCAL/Makefile")"

    # Any remaining absolute reference to the target's tree would break the build;
    # path-segment anchored so our own sysroot paths do not look like hits.
    hits=$(grep -rnE "(^|[^[:alnum:]_./-])$(regex_escape "$SRCTREE")" \
               "${TREES[@]/#/$SYSROOT}" 2>/dev/null | grep -v 'Makefile\.sysroot\.orig' | head -n5 || true)
    if [ -n "$hits" ]; then
        say "    WARNING: copied files still reference the target path $SRCTREE:"
        printf '        %s\n' $hits >&2
    fi

    say "==> linking $MODULES_LOCAL/build and $MODULES_LOCAL/source"
    mkdir -p "$MODULES_LOCAL"
    ln -sfn "$(realpath --relative-to="$MODULES_LOCAL" "$OBJ_LOCAL")" "$MODULES_LOCAL/build"
    ln -sfn "$(realpath --relative-to="$MODULES_LOCAL" "$SRC_LOCAL")" "$MODULES_LOCAL/source"
fi

# --- 5. sanity check + metadata ----------------------------------------------------------------------
if [ "$DRY_RUN" -eq 0 ]; then
    say "==> verifying the copied tree"
    missing=0
    for f in \
        "$OBJ_LOCAL/Makefile" \
        "$OBJ_LOCAL/Module.symvers" \
        "$OBJ_LOCAL/include/generated/autoconf.h" \
        "$OBJ_LOCAL/include/generated/utsrelease.h" \
        "$SRC_LOCAL/include/linux/module.h" \
        "$SRC_LOCAL/scripts/Makefile.build"; do
        if [ ! -e "$f" ]; then
            printf '    MISSING: %s\n' "$f" >&2
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || die "the copied header tree is incomplete"
    say "    utsrelease: $(cat "$OBJ_LOCAL/include/generated/utsrelease.h")"

    {
        echo "# Generated by scripts/$PROGRAM_NAME -- do not edit, do not commit."
        echo "# Regenerate: scripts/$PROGRAM_NAME -t $TARGET"
        echo "TARGET=$TARGET"
        echo "KERNEL_RELEASE=$KERNEL_RELEASE"
        echo "KERNEL_MACHINE=$KERNEL_MACHINE"
        echo "KERNEL_ARCH=$KERNEL_ARCH"
        echo "CROSS_COMPILE=$CROSS_COMPILE"
        echo "SYSROOT=$SYSROOT"
        echo "KERNEL_BUILD_DIR=$KERNEL_BUILD_DIR"
        echo "KERNEL_OBJ_DIR=$OBJ_LOCAL"
        echo "KERNEL_SRC_DIR=$SRC_LOCAL"
        [ ${#KBUILDTREES[@]} -gt 0 ] && echo "KBUILD_DIR=$(sysroot_of "${KBUILDTREES[0]}")"
        echo "FETCHED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$ENVFILE"
fi

# --- 6. summary ---------------------------------------------------------------------------------------
say "==> done"
say "    sysroot      : $SYSROOT"
say "    kernel       : $KERNEL_RELEASE ($KERNEL_ARCH, CROSS_COMPILE=$CROSS_COMPILE)"
say "    build dir    : $KERNEL_BUILD_DIR"
say "    obj (flavour): $OBJ_LOCAL"
say "    src (common) : $SRC_LOCAL"
[ "$DRY_RUN" -eq 0 ] && say "    env file     : $ENVFILE"
say "    note         : the kbuild host tools in the sysroot (fixdep, kconfig/conf, ...)"
say "                   are $KERNEL_MACHINE binaries. A native build must rebuild them"
say "                   (make -C \"\$KERNEL_BUILD_DIR\" scripts), or build the module on the"
say "                   target, which is what this repo does (see AGENTS.md)."

if [ "$DRY_RUN" -eq 0 ]; then
    cat >&2 <<EOF

Host-side usage:
    . "$ENVFILE"
    make -C "\$KERNEL_BUILD_DIR" ARCH="\$KERNEL_ARCH" CROSS_COMPILE="\$CROSS_COMPILE" \\
         M="\$PWD/driver" modules
EOF
fi
