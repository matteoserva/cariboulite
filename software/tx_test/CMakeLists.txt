cmake_minimum_required(VERSION 3.15)
project(tx_test
        VERSION 1.0.0
        LANGUAGES C
        DESCRIPTION "CaribouLite TX stream test utility (standalone)")

set(CMAKE_BUILD_TYPE Release)

# The tool needs the full radio data path, so it compiles the C part of
# libcariboulite directly from the library tree (everything except the
# C++/SoapySDR layer). This keeps the project standalone and
# cross-compilable with nothing but a C toolchain: no prebuilt
# libcariboulite, no SoapySDR, no C++ runtime.
set(LIBCARIBOU_SRC ${PROJECT_SOURCE_DIR}/../libcariboulite/src)

if (NOT EXISTS ${LIBCARIBOU_SRC})
    message(FATAL_ERROR "libcariboulite sources not found at ${LIBCARIBOU_SRC}")
endif()

include_directories(${LIBCARIBOU_SRC})
add_compile_options(-Wall -Wextra -Wno-unused-variable -Wno-missing-braces -Wno-unused-parameter)

set(SOURCES
    tx_test.c

    # library API / setup layer
    ${LIBCARIBOU_SRC}/cariboulite.c
    ${LIBCARIBOU_SRC}/cariboulite_setup.c
    ${LIBCARIBOU_SRC}/cariboulite_events.c
    ${LIBCARIBOU_SRC}/cariboulite_radio.c

    # submodules
    ${LIBCARIBOU_SRC}/caribou_fpga/caribou_fpga.c
    ${LIBCARIBOU_SRC}/caribou_programming/caribou_prog.c
    ${LIBCARIBOU_SRC}/caribou_smi/caribou_smi.c
    ${LIBCARIBOU_SRC}/caribou_smi/smi_utils.c
    ${LIBCARIBOU_SRC}/caribou_smi/caribou_smi_modules.c
    ${LIBCARIBOU_SRC}/at86rf215/at86rf215.c
    ${LIBCARIBOU_SRC}/at86rf215/at86rf215_events.c
    ${LIBCARIBOU_SRC}/at86rf215/at86rf215_radio.c
    ${LIBCARIBOU_SRC}/at86rf215/at86rf215_baseband.c
    ${LIBCARIBOU_SRC}/rffc507x/rffc507x.c
    ${LIBCARIBOU_SRC}/hat/hat.c
    ${LIBCARIBOU_SRC}/hat/eeprom_utils.c

    # production/calibration helpers - only what the TX path links against.
    # production_testing.c/lcd.c are deliberately excluded: they pull in
    # libzmq and are only used by the production self-test app.
    ${LIBCARIBOU_SRC}/production_utils/production_utils.c
    ${LIBCARIBOU_SRC}/production_utils/hat_powermon.c

    # datatype helpers (C subset - the TX path needs no circular_buffer.cpp)
    ${LIBCARIBOU_SRC}/datatypes/tsqueue.c
    ${LIBCARIBOU_SRC}/datatypes/tiny_list.c
    ${LIBCARIBOU_SRC}/datatypes/entropy.c

    # I/O and logging
    ${LIBCARIBOU_SRC}/io_utils/io_utils.c
    ${LIBCARIBOU_SRC}/io_utils/io_utils_spi.c
    ${LIBCARIBOU_SRC}/io_utils/io_utils_sys_info.c
    ${LIBCARIBOU_SRC}/io_utils/io_utils_fs.c
    ${LIBCARIBOU_SRC}/io_utils/io_utils_i2c.c
    ${LIBCARIBOU_SRC}/io_utils/rpi/rpi.c
    ${LIBCARIBOU_SRC}/io_utils/spidev/spi.c
    ${LIBCARIBOU_SRC}/zf_log/zf_log.c
)

add_executable(tx_test ${SOURCES})
target_link_libraries(tx_test PRIVATE rt m pthread)

install(TARGETS tx_test RUNTIME DESTINATION bin)
