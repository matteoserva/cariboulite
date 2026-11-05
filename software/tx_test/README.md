# tx_test

Standalone CaribouLite TX stream test utility. Same job as
`libcariboulite`'s `src/tx_test.c`, but built as a self-contained
project (the needed C part of the library is compiled from the source
tree - no prebuilt libcariboulite, no SoapySDR).

Key difference from the library version: **this tool never programs the
FPGA**. Before touching anything it checks the ICE40 CDONE pin and
refuses to run if the FPGA is not configured (use the `flash_fpga` tool
for that).

## Usage

```
sudo tx_test [options] [filename]
```

By default samples are streamed from `filename` (or `-` for stdin), which
is then required. With `-t` a test pattern is generated internally and no
input is needed at all.

| option | meaning | default |
|--------|---------|---------|
| `-c`   | TX channel (0: low, 1: high) | 0 |
| `-f`   | frequency [Hz] | 915e6 |
| `-r`   | sample rate [SPS] | 4000000 |
| `-g`   | gain 0..69, -1 = agc | 0 |
| `-p`   | ppm error | 0 |
| `-n`   | number of samples to write | 0 (stream until end of input) |
| `-t`   | test pattern: 0 = from input, 1 = CW, 2 = NBFM | 0 |

Test patterns (`-t`):

- `1` - continuous wave, via the hardware CW output
  (`cariboulite_radio_set_cw_outputs()`): the modem DAC input is forced to
  constant I/Q, the streamed buffer content is ignored.
- `2` - narrow-band FM: square-wave tone modulating the carrier with
  ±3 kHz deviation, tone frequency stepping through
  400 → 800 → 1000 → 1200 Hz, one step per second, looping. Generated
  with a plain phase accumulator (`fm_fill()`) - it is a test signal, not
  a compliant transmitter.

Examples:

```
# stream a file (int16 complex interleaved I/Q):
sudo tx_test -c 1 -f 433125000 -r 400000 -g 0 ~/starwars_400k.bin

# streaming from a pipe (stops when the pipe closes):
some_iq_source | sudo tx_test -c 1 -f 433125000 -r 400000 -

# continuous wave, no input required:
sudo tx_test -c 1 -f 433125000 -t 1

# NBFM test signal, no input required:
sudo tx_test -c 1 -f 433125000 -t 2
```

Without `-n` the tool streams forever (test patterns) or until the
file/pipe is exhausted (default mode); Ctrl-C always stops it and `-n`
caps the sample count.

## Building

Recommended: `scripts/build-standalone.sh tx_test` from the repo root -
auto-detects native (target) vs cross (x86_64 host) build, supports
`--clean`, `--deploy` (scp to `pi@sdrpy`) and `-h`.
On-target builds are capped at `-j2` (`MAKE_JOBS=N` to override): the Pi
has little RAM and too much compiler parallelism OOM-crashes it.

Manually:

```
# on the target
cmake -S software/tx_test -B software/tx_test/build
cmake --build software/tx_test/build -j2

# on an x86_64 host (needs: apt install cmake gcc-aarch64-linux-gnu)
cmake -S software/tx_test -B software/tx_test/build-aarch64 \
      -DCMAKE_TOOLCHAIN_FILE=software/tx_test/aarch64-toolchain.cmake
cmake --build software/tx_test/build-aarch64 -j
```
