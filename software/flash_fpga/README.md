# flash_fpga

Minimal standalone utility that does exactly one thing: upload a
CaribouLite FPGA firmware `.bin` file to the on-board Lattice ICE40.
It is the command-line equivalent of pushing `[3]` (Program FPGA),
`[2]` (program from file), `[99]` (quit) in `cariboulite_test_app`.

It links only the programming part of libcariboulite sources
(`caribou_fpga` + `caribou_programming` + `io_utils` + `zf_log`) compiled
directly from `../libcariboulite/src` - no prebuilt library, no SoapySDR,
no SMI driver involvement.

## Usage

```
sudo flash_fpga [options] [path/to/top.bin]
```

* The `.bin` path is optional - when omitted, `firmware/top.bin` is
  searched relative to the current directory (same layout as the repo),
  then `/usr/share/cariboulite/top.bin`.
* `-v` enables debug logging, `-h` prints usage.
* Run from the repo root to pick up `firmware/top.bin` with no arguments.

The tool performs a hard reset (discarding the running firmware),
programs the bitstream, soft-resets, prints the firmware versions and
puts the RF frontend back to low power - the same sequence as the test
application.

## Building

Recommended: `scripts/build-standalone.sh flash_fpga` from the repo root - it
auto-detects the mode (native on the target / any aarch64 machine,
cross from an x86_64 host), supports `--clean` and `--deploy`
(scp to `pi@sdrpy`). `scripts/build-flash-fpga.sh` is a shortcut wrapper.
On-target builds run with `-j2` at most (the Pi OOMs with more compiler
parallelism).

Manually:

```
# on the target (Raspberry Pi)
cmake -S software/flash_fpga -B software/flash_fpga/build
cmake --build software/flash_fpga/build -j

# on an x86_64 host (needs: apt install cmake gcc-aarch64-linux-gnu)
cmake -S software/flash_fpga -B software/flash_fpga/build-aarch64 \
      -DCMAKE_TOOLCHAIN_FILE=software/flash_fpga/aarch64-toolchain.cmake
cmake --build software/flash_fpga/build-aarch64 -j
```

Only libc + pthread are linked, so the cross build needs no target
sysroot - the Debian `gcc-aarch64-linux-gnu` package is enough.
