# CMake toolchain file for cross-compiling flash_fpga to aarch64
# (the Raspberry Pi OS 64-bit userland on the cariboulite target).
#
# Used by scripts/build-flash-fpga.sh, or manually:
#   cmake -B build-aarch64 -DCMAKE_TOOLCHAIN_FILE=aarch64-toolchain.cmake
#
# Host requirement (Debian/Ubuntu): gcc-aarch64-linux-gnu
# (pulls in libc6-dev-arm64-cross, which is all this tool needs -
# flash_fpga links only libc + pthread).

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

if (NOT DEFINED CROSS_COMPILE)
    set(CROSS_COMPILE "aarch64-linux-gnu-")
endif()

set(CMAKE_C_COMPILER   ${CROSS_COMPILE}gcc)
set(CMAKE_CXX_COMPILER ${CROSS_COMPILE}g++)

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
