This software has parts that must be compiled on target.
- firmware: host
- software: target
  (exceptions: software/flash_fpga and software/tx_test cross-compile on the
   host too: scripts/build-standalone.sh -- libc+pthread only, no sysroot;
   on-target builds must stay at -j2, more parallelism OOM-crashes the Pi)
- driver: target, or cross-compiled on host (see below)


The target address: pi@sdrpy
the cariboulite folder is mapped in the target at ~/cariboulite/

Host build entry point: top-level Makefile
- `make` builds top.bin, flash_fpga, tx_test, smi_stream_dev.ko and collects
  them into release/; `make clean` cleans sub-projects + release/

Driver cross-compile on host (produces driver/build-host/smi_stream_dev.ko):
- one-time host deps: rsync, gcc-aarch64-linux-gnu (apt install)
- scripts/fetch-kernel-headers.sh  # rsyncs the target's kernel headers into rpi-sysroot/
- scripts/build-driver.sh          # builds the .ko; --fetch to re-sync headers, --clean
- the sysroot carries aarch64 kbuild host tools; build-driver.sh swaps them
  for the native ones vendored in scripts/kbuild-host-tools/

