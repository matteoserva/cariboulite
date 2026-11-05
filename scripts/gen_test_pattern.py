#!/usr/bin/env python3
#
# gen_test_pattern.py
#
# Generate the same test pattern that tx_test produces internally with
# -t 2 (fm_fill() in software/tx_test/tx_test.c): NBFM, deviation
# +/-3 kHz, modulated by a square tone stepping through
# {400, 800, 1000, 1200} Hz once per second, sample amplitude 10000.
#
# This is a faithful sequential port of the C generator, including its
# double-precision accumulation order, so the output tracks what
# tx_test -t 2 streams sample-for-sample (modulo the C 2*pi phase
# wrapping, which does not affect cos/sin). No numpy, no C toolchain
# involved - stdlib only.
#
# Output: interleaved complex int16 I/Q (little endian), the native
# cariboulite_sample_complex_int16 file format - feed it straight back:
#
#   tx_test -c 1 -f 433125000 -r 4000000 test_pattern_4000000.bin
#
# Output file name: test_pattern_{rate}.bin (in the output directory).
#
# Usage: scripts/gen_test_pattern.py [-r rate] [-n seconds] [-o outdir]
#   -r sample rate in Hz    (default: 4000000)
#   -n duration in seconds  (default: 4 = one full tone cycle)
#   -o output directory     (default: current directory)
#
# Runtime ballpark: ~7 s for the 4 s @ 4 MHz default (16M samples).

import argparse
import math
import os
import sys
from array import array

TONE_LIST = (400, 800, 1000, 1200)   # Hz, one per second, cycling
DEVI_HZ = 3000.0                     # FM deviation
AMPLITUDE = 10000.0                  # sample amplitude, as in fm_fill()


def fm_fill(rate: int, seconds: int) -> array:
    """Port of fm_fill() from tx_test.c. Returns array('h') of interleaved
    I/Q int16 samples. The sequence of floating-point operations matches
    the C loop exactly, including the phase wrapping and the single
    conditional subtraction on the tone phase."""
    two_pi = 2.0 * math.pi
    inc_phase = two_pi * DEVI_HZ / rate  # C: 2*pi*devi*tone/rate per step
    inc_tone_step = 1.0 / rate

    phase = 0.0       # accumulated RF phase [rad]
    tone_phase = 0.0  # audio square wave phase [0..1)
    sec = 0.0
    tone_idx = 0
    n_tones = len(TONE_LIST)
    inc_tone = TONE_LIST[tone_idx] / rate

    buf = array('h')
    buf_extend = buf.extend
    cos = math.cos
    sin = math.sin
    amp = AMPLITUDE

    chunk = []  # reused I/Q pair staging, flushed every 4096 samples
    for _ in range(rate * seconds):
        tone = -1.0 if tone_phase < 0.5 else 1.0

        phase += inc_phase * tone
        if phase > two_pi:
            phase -= two_pi
        elif phase < 0:
            phase += two_pi

        tone_phase += inc_tone
        if tone_phase >= 1.0:
            tone_phase -= 1.0

        sec += inc_tone_step
        if sec >= 1.0:
            sec = 0.0
            tone_idx = (tone_idx + 1) % n_tones
            inc_tone = TONE_LIST[tone_idx] / rate

        # C truncates toward zero on the double->int16 cast; int() does too
        chunk.append(int(amp * cos(phase)))
        chunk.append(int(amp * sin(phase)))
        if len(chunk) == 8192:
            buf_extend(chunk)
            chunk.clear()

    if chunk:
        buf_extend(chunk)
    return buf


def main():
    ap = argparse.ArgumentParser(
        description="Build a test_pattern_{rate}.bin matching tx_test -t 2")
    ap.add_argument("-r", type=int, default=4000000, metavar="HZ",
                    help="sample rate in Hz (default: 4000000)")
    ap.add_argument("-n", type=int, default=4, metavar="SEC",
                    help="duration in seconds (default: 4, one full tone cycle)")
    ap.add_argument("-o", type=str, default=".", metavar="DIR",
                    help="output directory (default: .)")
    args = ap.parse_args()

    if args.r <= 0 or args.n <= 0:
        ap.error("-r and -n must be positive")

    buf = fm_fill(args.r, args.n)

    os.makedirs(args.o, exist_ok=True)
    path = os.path.join(args.o, f"test_pattern_{args.r}.bin")
    if sys.byteorder != "little":
        buf.byteswap()
    with open(path, "wb") as fh:
        buf.tofile(fh)

    size = 4 * args.r * args.n
    print(f"wrote {path}: {size} bytes "
          f"({args.r * args.n} complex int16 samples, {args.n} s @ {args.r} Hz)")


if __name__ == "__main__":
    main()
