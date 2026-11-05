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
sudo tx_test [options] filename
```

Samples always come from the given input: passing `filename` (or `-` for
stdin) implicitly forces `-e 1` - the generated test-pattern mode is gone.
`-e` is still accepted so old command lines keep working untouched.
A missing filename prints the usage and aborts.

Options (drop-in compatible with the historic command lines):

| option | meaning | default |
|--------|---------|---------|
| `-c`   | TX channel (0: low, 1: high) | 0 |
| `-f`   | frequency [Hz] | 915e6 |
| `-r`   | sample rate [SPS] | 4000000 |
| `-w`   | CW output enable | 0 |
| `-g`   | gain 0..69, -1 = agc | 0 |
| `-p`   | ppm error | 0 |
| `-n`   | number of samples to write | 0 (stream until end of input) |
| `-e`   | accepted for compatibility, has no effect (input streaming is forced) | - |

Examples:

```
# the input file alone is enough now (implicit -e 1):
sudo tx_test -c 1 -f 433125000 -r 400000 -w 0 -g 0 ~/starwars_400k.bin

# your historic invocation, still works exactly as before:
sudo tx_test -c 1 -f 433125000 -r 400000 -w 0 -g 0 -e 1 ~/starwars_400k.bin

# streaming from a pipe (stops when the pipe closes):
some_iq_source | sudo tx_test -c 1 -f 433125000 -r 400000 -
```

Without `-n` the tool streams until the file/pipe is exhausted (or
Ctrl-C); `-n` additionally caps the sample count. Samples are int16
complex interleaved I/Q.

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
