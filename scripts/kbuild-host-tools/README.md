# kbuild host tools (native)

The Raspberry Pi kernel headers rsync'd into `rpi-sysroot/` carry *aarch64*
kbuild host tools (`fixdep`, `modpost`, ...) that the x86-64 build host cannot
execute, and Debian strips their sources from the headers packages.

`scripts/build-driver.sh` replaces the foreign-arch binaries in the sysroot
with the native ones kept here.

- `x86_64/fixdep`, `x86_64/modpost`: extracted from Debian bookworm's
  `linux-kbuild-6.1_6.1.176-1_amd64.deb` (kernel 6.1 series, matching the
  `6.1.0-rpi7` target kernel; host tools are stable within a series).
- Refresh after a target kernel major/minor bump:
  `curl -O https://deb.debian.org/debian/pool/main/l/linux/linux-kbuild-<series>_<ver>_amd64.deb && dpkg-deb -x <deb> /tmp/x`
  then copy `usr/lib/linux-kbuild-<series>/scripts/basic/fixdep` and
  `usr/lib/linux-kbuild-<series>/scripts/mod/modpost.real-lsb-64`.

On an arm64 host no replacement is needed: the binaries coming from the target
are already native there.
