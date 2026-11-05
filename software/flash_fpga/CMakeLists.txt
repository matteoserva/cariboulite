cmake_minimum_required(VERSION 3.15)
project(flash_fpga
        VERSION 1.0.0
        LANGUAGES C
        DESCRIPTION "CaribouLite FPGA .bin flash utility (standalone)")

set(CMAKE_BUILD_TYPE Release)

# The tool links only the FPGA-programming part of libcariboulite:
# caribou_fpga + caribou_prog + io_utils + zf_log. The sources are
# compiled directly from the library tree, so this project builds
# standalone (no prebuilt libcariboulite required) and is
# cross-compilable with nothing but a C toolchain.
set(LIBCARIBOU_SRC ${PROJECT_SOURCE_DIR}/../libcariboulite/src)

if (NOT EXISTS ${LIBCARIBOU_SRC})
    message(FATAL_ERROR "libcariboulite sources not found at ${LIBCARIBOU_SRC}")
endif()

include_directories(${LIBCARIBOU_SRC})
add_compile_options(-Wall -Wextra -Wno-unused-variable -Wno-missing-braces)

set(SOURCES
    flash_fpga.c
    ${LIBCARIBOU_SRC}/zf_log/zf_log.c
    ${LIBCARIBOU_SRC}/io_utils/io_utils.c
    ${LIBCARIBOU_SRC}/io_utils/io_utils_spi.c
    ${LIBCARIBOU_SRC}/io_utils/io_utils_sys_info.c
    ${LIBCARIBOU_SRC}/io_utils/io_utils_fs.c
    ${LIBCARIBOU_SRC}/io_utils/io_utils_i2c.c
    ${LIBCARIBOU_SRC}/io_utils/rpi/rpi.c
    ${LIBCARIBOU_SRC}/io_utils/spidev/spi.c
    ${LIBCARIBOU_SRC}/caribou_programming/caribou_prog.c
    ${LIBCARIBOU_SRC}/caribou_fpga/caribou_fpga.c
)

add_executable(flash_fpga ${SOURCES})
target_link_libraries(flash_fpga PRIVATE pthread)

install(TARGETS flash_fpga RUNTIME DESTINATION bin)
