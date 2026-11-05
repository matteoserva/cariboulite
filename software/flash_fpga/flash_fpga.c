/*
 * flash_fpga - minimal CaribouLite FPGA programming utility
 *
 * This is the functional equivalent of the test application flow:
 *   [3] Program FPGA  ->  [2] program from .bin file  ->  [99] quit
 *
 * It only performs:
 *   - SPI / GPIO bring-up
 *   - FPGA hard reset (firmware discard)
 *   - ICE40 programming from a .bin file (forced)
 *   - soft reset, version printout, RFM low-power restore
 *
 * No SMI driver, no radio initialization - just the programming path
 * of libcariboulite (caribou_fpga + caribou_prog + io_utils + zf_log).
 */

#ifndef ZF_LOG_LEVEL
    #define ZF_LOG_LEVEL ZF_LOG_VERBOSE
#endif
#define ZF_LOG_DEF_SRCLOC ZF_LOG_SRCLOC_LONG
#define ZF_LOG_TAG "FLASH_FPGA"
#include "zf_log/zf_log.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <unistd.h>

#include "cariboulite_config_default.h"
#include "io_utils/io_utils.h"
#include "io_utils/io_utils_spi.h"
#include "caribou_fpga/caribou_fpga.h"

/* Same candidate locations the test app expects for firmware/top.bin,
 * tried relative to the current directory, plus a system location. */
static const char *default_bin_paths[] = {
	"firmware/top.bin",
	"../firmware/top.bin",
	"../../firmware/top.bin",
	"../../../firmware/top.bin",
	"/usr/share/cariboulite/top.bin",
};
#define NUM_DEFAULT_BIN_PATHS	(int)(sizeof(default_bin_paths)/sizeof(default_bin_paths[0]))

//=================================================
static void print_usage(const char *prog)
{
	printf("CaribouLite ICE40 FPGA flash utility\n");
	printf("------------------------------------\n");
	printf("Usage: %s [options] [path/to/top.bin]\n\n", prog);
	printf("  path/to/top.bin   FPGA firmware .bin file (compiled output).\n");
	printf("                    If omitted, firmware/top.bin is searched for\n");
	printf("                    relative to the current directory.\n");
	printf("Options:\n");
	printf("  -v, --verbose     debug logging\n");
	printf("  -h, --help        this help\n");
	printf("\nRequires the CaribouLite HAT on a Raspberry Pi (run as root).\n");
}

//=================================================
static const char *find_default_bin(void)
{
	for (int i = 0; i < NUM_DEFAULT_BIN_PATHS; i++)
	{
		if (access(default_bin_paths[i], R_OK) == 0)
			return default_bin_paths[i];
	}
	return NULL;
}

//=================================================
/* Mirror of cariboulite_setup_io() - only the GPIO/SPI part needed
 * to safely talk to the FPGA on the shared SPI bus. */
static int setup_board_io(io_utils_spi_st *spi)
{
	spi->miso = CARIBOULITE_MISO;
	spi->mosi = CARIBOULITE_MOSI;
	spi->sck = CARIBOULITE_SCK;

	if (io_utils_setup() < 0)
	{
		ZF_LOGE("Error setting up io_utils");
		return -1;
	}

	if (io_utils_spi_init(spi) < 0)
	{
		ZF_LOGE("Error setting up io_utils_spi");
		io_utils_cleanup();
		return -1;
	}

	/* Setup the initial states for components reset and SS */
	/* ICE40 */
	io_utils_set_gpio_mode(CARIBOULITE_FPGA_SS, io_utils_alt_gpio_out);
	io_utils_write_gpio(CARIBOULITE_FPGA_SS, 1);

	/* AT86RF215 - keep deselected while the programmer owns the SPI bus */
	io_utils_set_gpio_mode(CARIBOULITE_MODEM_SS, io_utils_alt_gpio_out);
	io_utils_write_gpio(CARIBOULITE_MODEM_SS, 1);
	io_utils_set_gpio_mode(CARIBOULITE_MODEM_RESET, io_utils_alt_gpio_out);
	io_utils_write_gpio(CARIBOULITE_MODEM_RESET, 0);

	/* RFFC5072 - keep deselected as well */
	io_utils_set_gpio_mode(CARIBOULITE_MIXER_SS, io_utils_alt_gpio_out);
	io_utils_write_gpio(CARIBOULITE_MIXER_SS, 1);
	io_utils_set_gpio_mode(CARIBOULITE_MIXER_RESET, io_utils_alt_gpio_out);
	io_utils_write_gpio(CARIBOULITE_MIXER_RESET, 0);

	return 0;
}

//=================================================
static void release_board_io(io_utils_spi_st *spi)
{
	io_utils_spi_close(spi);
	io_utils_cleanup();
}

//=================================================
int main(int argc, char *argv[])
{
	const char *bin_file = NULL;
	bool verbose = false;
	int res = -1;

	/* parse command line */
	for (int i = 1; i < argc; i++)
	{
		if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0)
		{
			print_usage(argv[0]);
			return 0;
		}
		else if (strcmp(argv[i], "-v") == 0 || strcmp(argv[i], "--verbose") == 0)
		{
			verbose = true;
		}
		else if (bin_file == NULL && argv[i][0] != '-')
		{
			bin_file = argv[i];
		}
		else
		{
			fprintf(stderr, "Unexpected argument: %s\n\n", argv[i]);
			print_usage(argv[0]);
			return -1;
		}
	}

	if (verbose)
		zf_log_set_output_level(ZF_LOG_VERBOSE);

	/* locate the .bin file if not given explicitly */
	if (bin_file == NULL)
	{
		bin_file = find_default_bin();
		if (bin_file == NULL)
		{
			ZF_LOGE("No firmware file given and firmware/top.bin was not found "
					"in the default locations - aborting");
			print_usage(argv[0]);
			return -1;
		}
		ZF_LOGI("Using default firmware file: %s", bin_file);
	}

	/* board I/O */
	io_utils_spi_st spi_dev;
	memset(&spi_dev, 0, sizeof(spi_dev));
	if (setup_board_io(&spi_dev) < 0)
		return -1;

	/* FPGA context - pinout from the default board configuration */
	caribou_fpga_st fpga;
	memset(&fpga, 0, sizeof(fpga));
	fpga.reset_pin = CARIBOULITE_FPGA_CRESET;
	fpga.soft_reset_pin = CARIBOULITE_FPGA_SOFT_RESET;
	fpga.cs_pin = CARIBOULITE_FPGA_SS;
	fpga.spi_dev = CARIBOULITE_SPI_DEV;
	fpga.spi_channel = CARIBOULITE_FPGA_SPI_CHANNEL;
	fpga.prog_dev.cs_pin = CARIBOULITE_FPGA_SS;
	fpga.prog_dev.cdone_pin = CARIBOULITE_FPGA_CDONE;
	fpga.prog_dev.reset_pin = CARIBOULITE_FPGA_CRESET;

	if (caribou_fpga_init(&fpga, &spi_dev) < 0)
	{
		ZF_LOGE("FPGA init failed");
		release_board_io(&spi_dev);
		return -1;
	}

	/* same sequence as the test app: hard reset first, discarding
	 * the current firmware, then force-reprogram from the .bin file */
	caribou_fpga_hard_reset(&fpga);

	printf("Programming FPGA from '%s' (this takes a few seconds)...\n", bin_file);
	res = caribou_fpga_program_to_fpga_from_file(&fpga, (char *)bin_file, true);
	if (res < 0)
	{
		ZF_LOGE("FPGA programming failed (%d)", res);
	}
	else
	{
		printf("FPGA programming successful, Versions:\n");
		caribou_fpga_get_versions(&fpga, NULL);
		caribou_fpga_print_versions(&fpga);

		/* put the RF frontend back to low power, as the test app does */
		caribou_fpga_set_io_ctrl_mode(&fpga, 0, caribou_fpga_io_ctrl_rfm_low_power);
	}

	caribou_fpga_close(&fpga);
	release_board_io(&spi_dev);

	return res < 0 ? -1 : 0;
}
