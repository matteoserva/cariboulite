#
# Top-level build Makefile -- HOST-side build of the shippable artifacts.
#
# Builds (all cross-compiled / produced on the host):
#   release/top.bin            FPGA bitstream   (firmware/, via yosys+nextpnr+icepack)
#   release/flash_fpga         FPGA uploader    (software/flash_fpga, standalone cross build)
#   release/tx_test            TX stream tester (software/tx_test, standalone cross build)
#   release/smi_stream_dev.ko  kernel module    (driver/, cross kbuild vs rpi-sysroot headers)
#
# Targets:
#   make [all]        build everything and populate release/
#   make firmware     build top.bin only
#   make flash_fpga   build the flash_fpga binary only
#   make tx_test      build the tx_test binary only
#   make driver       build smi_stream_dev.ko only
#   make release      re-collect artifacts into release/ (no rebuild)
#   make clean        clean sub-project outputs + release/
#
# Notes:
#   - top.bin needs yosys, nextpnr-ice40, icepack on the host.
#   - the driver needs gcc-aarch64-linux-gnu and the target kernel headers;
#     scripts/build-driver.sh auto-fetches them from the target (pi@sdrpy)
#     into rpi-sysroot/ on first use. Pass F=1 / FETCH=1 to force a re-fetch.
#   - the standalone tools need cmake + gcc-aarch64-linux-gnu (see
#     scripts/build-standalone.sh; on an aarch64 host they build natively).
#   - on-target builds of the full software/ stack are NOT part of this
#     Makefile (they must run on the Pi; see README / AGENTS.md).
#

REPO_ROOT  := $(shell pwd)
RELEASE_DIR:= $(REPO_ROOT)/release
SCRIPTS    := $(REPO_ROOT)/scripts
TARGET     ?= pi@sdrpy
FETCH      ?= 0
JOBS       ?= $(shell nproc)

# driver/build-host copies are re-stamped from these:
KO_SRC     := driver/build-host/smi_stream_dev.ko
BIN_SRC    := software/flash_fpga/build-aarch64/flash_fpga
TX_SRC     := software/tx_test/build-aarch64/tx_test
# on a native (aarch64) host, build-standalone.sh uses build/ instead:
BIN_NATIVE := software/flash_fpga/build/flash_fpga
TX_NATIVE  := software/tx_test/build/tx_test

.PHONY: all release clean firmware flash_fpga tx_test driver help

all: release

release: firmware flash_fpga tx_test driver
	@mkdir -p $(RELEASE_DIR)
	@cp -f firmware/top.bin $(RELEASE_DIR)/top.bin
	@u=$$(for f in $(BIN_SRC) $(BIN_NATIVE); do [ -x "$$f" ] && { echo "$$f"; break; }; done); \
		 [ -n "$$u" ] || { echo "flash_fpga binary missing"; exit 1; }; cp -f "$$u" $(RELEASE_DIR)/flash_fpga
	@u=$$(for f in $(TX_SRC) $(TX_NATIVE); do [ -x "$$f" ] && { echo "$$f"; break; }; done); \
		 [ -n "$$u" ] || { echo "tx_test binary missing"; exit 1; }; cp -f "$$u" $(RELEASE_DIR)/tx_test
	@[ -f $(KO_SRC) ] || { echo "driver module missing"; exit 1; }; cp -f $(KO_SRC) $(RELEASE_DIR)/
	@cp -f driver/build-host/Module.symvers driver/build-host/modules.order $(RELEASE_DIR)/ 2>/dev/null || true
	@echo "==> release/ contents:"
	@ls -l $(RELEASE_DIR)

firmware:
	@command -v yosys >/dev/null || { echo "yosys not found -- apt install yosys nextpnr-ice40 icestudio  (or: iverilog)"; exit 1; }
	$(MAKE) -C firmware top.bin

flash_fpga:
	$(SCRIPTS)/build-standalone.sh flash_fpga

tx_test:
	$(SCRIPTS)/build-standalone.sh tx_test

driver:
	$(SCRIPTS)/build-driver.sh $(if $(filter 1 y yes on,$(FETCH) $(F)),--fetch)

clean:
	@echo "==> cleaning firmware"
	-$(MAKE) -C firmware clean
	@echo "==> cleaning standalone tools (flash_fpga, tx_test)"
	-$(SCRIPTS)/build-standalone.sh all --clean
	@echo "==> cleaning driver"
	-$(SCRIPTS)/build-driver.sh --clean
	@echo "==> removing $(RELEASE_DIR)"
	@rm -rf $(RELEASE_DIR)

help:
	@grep -E '^#(   |  )' Makefile | sed 's/^#//'
