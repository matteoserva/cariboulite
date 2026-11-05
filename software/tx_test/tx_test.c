/*
 * tx_test - standalone CaribouLite TX streaming utility
 *
 * Built as a self-contained tool (the needed C part of libcariboulite is
 * compiled from the source tree). Note:
 *   - NO FPGA programming: the tool assumes the FPGA is already
 *     configured and verifies it through the ICE40 CDONE pin before
 *     doing anything (use the flash_fpga tool to program it).
 *
 * Streamed samples come either from a binary complex int16 I/Q file
 * given as argument (default) or from an internally generated test
 * pattern (-t 1: continuous wave, -t 2: NBFM with a stepping tone).
 * Test patterns need no input file at all.
 */

#ifndef ZF_LOG_LEVEL
    #define ZF_LOG_LEVEL ZF_LOG_INFO
#endif

#define ZF_LOG_DEF_SRCLOC ZF_LOG_SRCLOC_LONG
#define ZF_LOG_TAG "TX_TEST"
#include "zf_log/zf_log.h"

#include <sys/types.h>
#include <unistd.h>

#include "cariboulite_setup.h"
#include "cariboulite_events.h"
#include "cariboulite.h"
#include "cariboulite_config_default.h"
#include "hat/hat.h"
#include "io_utils/io_utils.h"

#include <stdio.h>
#include <signal.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>

//=======================================================================
// INTERNAL VARIABLES AND DEFINITIONS

static int signal_shown = 0;
CARIBOULITE_CONFIG_STATIC_DEFAULT(cariboulite_sys);

/* defined in cariboulite_radio.c but not exposed in the public headers */
void cariboulite_radio_debug(cariboulite_radio_state_st* radio);

// Program state structure
typedef struct
{
    // Arguments
    char *filename;
    int tx_channel;
    int test_pattern;
    double frequency;
    float rate;
    float gain;
    float ppm_error;
    size_t samples_to_write;

    // State
    int sample_infinite;
    int program_running;
    int sys_type;
    size_t native_write_len;
    cariboulite_sample_complex_int16* buffer;
    cariboulite_radio_state_st *radio;
    FILE *file;
} prog_state_st;

static prog_state_st state = {0};

//=================================================
static int stop_program (void)
{
    if (state.program_running) ZF_LOGD("program termination requested");
    state.program_running = 0;
    return 0;
}

//=================================================
static void sighandler(void* context,
                       int signal_number,
                       siginfo_t *si)
{
    (void) context;

    if (signal_shown != signal_number)
    {
        ZF_LOGI("Received signal %d", signal_number);
        signal_shown = signal_number;
    }

    switch (signal_number)
    {
        case SIGINT:
        case SIGTERM:
        case SIGABRT:
        case SIGILL:
        case SIGSEGV:
        case SIGFPE: stop_program(); break;
        default: return; break;
    }
}

//=================================================
static void init_program_state(void)
{
    state.filename = NULL;
    state.tx_channel = 0;       // low freq channel
    state.frequency = 915e6;
    state.gain = 0;
    state.ppm_error = 0;
    state.samples_to_write = 0; // infinite
    state.rate = 4000000;
    state.test_pattern = 0;

    // state
    state.sample_infinite = 1;
    state.program_running = 1;
    state.sys_type = system_type_cariboulite_ism;
    state.native_write_len = 1024 * 1024 / 8;
    state.buffer = NULL;
    state.radio = NULL;
    state.file = NULL;
}

//=======================================================================
static void usage(void)
{
	fprintf(stderr,
		"CaribouLite TX test streamer (no FPGA programming)\n\n"
		"Usage:\t-c the TX channel to use (0: low, 1: high)\n"
		"\t-f frequency [Hz]\n"
		"\t[-r sample rate (default: 4000000)]\n"
		"\t[-g gain 0..69, -1 for agc (default: 0)]\n"
		"\t[-p ppm_error (default: 0)]\n"
		"\t[-n number of samples to write (default: 0, stop at end of input)]\n"
		"\t[-t test pattern to transmit (default: 0 = from input file)]:\n"
		"\t   1: continuous wave (hardware CW output)\n"
		"\t   2: NBFM, square tone stepping 400/800/1000/1200 Hz every second\n"
		"\tfilename ('-' for stdin) - REQUIRED only with -t 0\n\n"
		"Example:\n"
		"\t1. Stream samples from file starwars_400k.bin\n"
		"\t\ttx_test -c 1 -f 433125000 -r 400000 -g 0 ~/starwars_400k.bin\n"
		"\t2. Stream from a pipe\n"
		"\t\tsome_iq_source | tx_test -c 1 -f 433125000 -r 400000 -\n"
		"\t3. Continuous wave at 433.125MHz, no input needed\n"
		"\t\ttx_test -c 1 -f 433125000 -t 1\n"
		"\t4. NBFM test signal\n"
		"\t\ttx_test -c 1 -f 433125000 -t 2\n\n"
		"The FPGA must already be programmed - use flash_fpga if needed.\n");
	exit(1);
}

//=======================================================================
/*
 * Non-invasive "is the FPGA up" check: the ICE40 CDONE pin is high only
 * when configuration is complete and the core is running. Checked before
 * cariboulite_init() on purpose - the library init would otherwise
 * program a built-in blob into an unconfigured FPGA, and this tool
 * must never flash.
 */
static int fpga_check_programmed(void)
{
	int cdone = 0;

	if (io_utils_setup() < 0)
	{
		ZF_LOGE("io_utils setup failed - is the CaribouLite HAT present?");
		return -1;
	}
	io_utils_setup_gpio(CARIBOULITE_FPGA_CDONE, io_utils_dir_input, io_utils_pull_up);
	cdone = io_utils_read_gpio(CARIBOULITE_FPGA_CDONE);
	io_utils_cleanup();

	return cdone;
}

//=================================================
/*
 * NBFM (-t 2) generator. Deliberately dumb, it is only a test signal:
 * narrowband FM, deviation +/-3 kHz, modulated by a square tone whose
 * frequency steps through {400, 800, 1000, 1200} Hz once per second.
 */
static void fm_fill(cariboulite_sample_complex_int16 *buf, size_t samples)
{
    static const int tone_list[] = {400, 800, 1000, 1200};
    const double devi_hz = 3000.0;
    static double phase = 0;       /* accumulated RF phase [rad] */
    static double tone_phase = 0;  /* audio square wave phase [0..1) */
    static double sec = 0;
    static int tone_idx = 0;

    for (size_t i = 0; i < samples; i++)
    {
        double tone = tone_phase < 0.5 ? -1.0 : 1.0;

        phase += 2.0 * M_PI * devi_hz * tone / state.rate;
        if (phase > 2.0 * M_PI) phase -= 2.0 * M_PI;
        else if (phase < 0) phase += 2.0 * M_PI;

        tone_phase += (double) tone_list[tone_idx] / state.rate;
        if (tone_phase >= 1.0) tone_phase -= 1.0;

        sec += 1.0 / state.rate;
        if (sec >= 1.0)
        {
            sec = 0;
            tone_idx = (tone_idx + 1) % (int) (sizeof(tone_list) / sizeof(tone_list[0]));
        }

        buf[i].i = (int16_t) (10000.0 * cos(phase));
        buf[i].q = (int16_t) (10000.0 * sin(phase));
    }
}

//=======================================================================
static int check_inputs(void)
{
    state.sys_type = cariboulite_sys.board_info.numeric_product_id;

    if (state.tx_channel != 0 && state.tx_channel != 1)
    {
        ZF_LOGE("Radio selection incompatible [%d] (should be either '0' or '1')", state.tx_channel);
        return -1;
    }

    if (state.tx_channel == 0 &&
        (state.frequency < CARIBOULITE_S1G_MIN1 || state.frequency > CARIBOULITE_S1G_MAX2 ||
         (state.frequency > CARIBOULITE_S1G_MAX1 && state.frequency < CARIBOULITE_S1G_MIN2)) )
    {
        ZF_LOGE("S1G radio frequency (%.2f) is out of the [%.0f .. %.0f, %.0f .. %.0f] MHz range", state.frequency,
            CARIBOULITE_S1G_MIN1/1e6, CARIBOULITE_S1G_MAX1/1e6, CARIBOULITE_S1G_MIN2/1e6, CARIBOULITE_S1G_MAX2/1e6);
        return -1;
    }

    if (state.tx_channel == 1 && state.sys_type == system_type_cariboulite_full &&
        (state.frequency < CARIBOULITE_6G_MIN && state.frequency > CARIBOULITE_6G_MAX))
    {
        ZF_LOGE("HiF (full) radio frequency (%.2f) is out of the [%.0f .. %.0f] MHz range", state.frequency,
            CARIBOULITE_6G_MIN/1e6, CARIBOULITE_6G_MAX/1e6);
        return -1;
    }

    if (state.tx_channel == 1 && state.sys_type == system_type_cariboulite_ism &&
        (state.frequency < CARIBOULITE_2G4_MIN && state.frequency > CARIBOULITE_2G4_MAX))
    {
        ZF_LOGE("HiF (ISM) radio frequency (%.2f) is out of the [%.0f .. %.0f] MHz range", state.frequency,
            CARIBOULITE_2G4_MIN/1e6, CARIBOULITE_2G4_MAX/1e6);
        return -1;
    }

    if ((state.gain < 0 || state.gain > 23.0*3.0) && state.gain != -1)
    {
        ZF_LOGE("Tx channel gain %.0f is incompatible (legal range: [%.0f .. %.0f] dB, or -1 for agc)", state.gain,
            0.0, 23.0*3.0);
        return -1;
    }

    return 0;
}

//=================================================
int analyze_arguments(int argc, char *argv[])
{
    int opt;
    while ((opt = getopt(argc, argv, "c:f:t:p:g:n:r:")) != -1) {
		switch (opt) {
		case 'c':
			state.tx_channel = (int)atoi(optarg);
			break;
		case 't':
			state.test_pattern = (int)atoi(optarg);
			break;
		case 'f':
			state.frequency = atof(optarg);
			break;
		case 'r':
			state.rate = atof(optarg);
			break;
		case 'g':
			state.gain = (int)(atof(optarg));
			break;
		case 'p':
			state.ppm_error = atof(optarg);
			break;
		case 'n':
			state.samples_to_write = atoi(optarg);
			state.sample_infinite = state.samples_to_write > 0 ? 0 : 1;
			break;
		default:
			usage();
			return -1;
			break;
		}
	}

    if (state.test_pattern < 0 || state.test_pattern > 2)
    {
        ZF_LOGE("Invalid test pattern %d (valid: 0 = input file, 1 = CW, 2 = NBFM)", state.test_pattern);
        return -1;
    }

    /* the input file is mandatory only in the default mode (-t 0): the
     * generated patterns produce samples on their own */
    if (state.test_pattern == 0 && argc <= optind)
    {
        usage();
        return -1;
    }
    if (argc > optind) state.filename = argv[optind];

    printf("TX channel: %d, frequency: %.1f Hz, rate: %.0f, gain: %.0f, samples: %s, source: %s\n",
            state.tx_channel, state.frequency, state.rate, state.gain,
            state.sample_infinite ? "unlimited" : "limited",
            state.test_pattern == 0 ? state.filename :
                            (state.test_pattern == 1 ? "generated: CW" : "generated: NBFM"));
    return 0;
}

//=================================================
void release_system(void)
{
    cariboulite_radio_activate_channel(state.radio, cariboulite_channel_dir_tx, false);
    if (state.buffer) free (state.buffer);
    if (state.file && state.file != stdin) fclose(state.file);
    cariboulite_close();
}

//=================================================
int main(int argc, char *argv[])
{
    // pre-init the program state
    //-------------------------------------
    init_program_state();

    // Analyze program opts
    //-------------------------------------
    if (analyze_arguments(argc, argv) != 0)
    {
        return 0;
    }

    // Make sure the FPGA is up BEFORE any driver init - this tool
    // never programs the FPGA, it only refuses to run without one.
    //-------------------------------------
    if (fpga_check_programmed() != 1)
    {
        ZF_LOGE("FPGA is not programmed (CDONE low) - run the flash_fpga tool first");
        return -1;
    }

    // Init the program
    //-------------------------------------
    if (cariboulite_init(false, cariboulite_log_level_verbose) != 0)
    {
        ZF_LOGE("driver init failed, terminating...");
        return -1;
    }

    // setup the signal handler
    cariboulite_register_signal_handler ( sighandler, &cariboulite_sys);

    // check the input arguments (done after init to identify system type)
    if (check_inputs() != 0)
    {
        cariboulite_close();
        return -1;
    }

    // get the correct radio from the possible two
    state.radio = cariboulite_get_radio((cariboulite_channel_en)(state.tx_channel));

    // Allocate tx buffer
    state.native_write_len = cariboulite_radio_get_native_mtu_size_samples(state.radio);
    state.buffer = malloc(sizeof(cariboulite_sample_complex_int16) * state.native_write_len);
    if (state.buffer == NULL)
    {
        ZF_LOGE("TX Buffer allocation failed");
        release_system();
        return -1;
    }

    // Align the length (only if it is >0)
    if (!state.sample_infinite)
    {
        state.samples_to_write = ((state.samples_to_write % state.native_write_len) == 0) ?
                                 (state.samples_to_write) :
                                 (state.samples_to_write / state.native_write_len + 1) * state.native_write_len;
    }

    // A generated pattern never reads from input: with -t 1 the modem is
    // fed constant I/Q by the hardware itself, so the buffer content is
    // irrelevant - zero it once and stream it for the DMA clock.
    if (state.test_pattern == 1)
        memset(state.buffer, 0, sizeof(cariboulite_sample_complex_int16) * state.native_write_len);

    // Init the radio
    //-------------------------------------
    // Set radio parameters
    cariboulite_radio_activate_channel(state.radio, cariboulite_channel_dir_tx, false);
    cariboulite_radio_set_frequency(state.radio, true, &state.frequency);
    if (state.test_pattern == 1)
        cariboulite_radio_set_cw_outputs(state.radio, false, true);
    cariboulite_radio_set_tx_power(state.radio, 0);
    cariboulite_radio_sync_information(state.radio);
    if (state.rate < 3900000)
    {
        cariboulite_radio_set_tx_samp_cutoff_flt(state.radio, state.rate/1000);
    }
    else
    {
        cariboulite_radio_set_tx_samp_cutoff(state.radio, cariboulite_radio_rx_sample_rate_4000khz, cariboulite_radio_rx_f_cut_0_75_half_fs);
    }
    cariboulite_radio_activate_channel(state.radio, cariboulite_channel_dir_tx, true);

    // Open the input file for reading (only the default mode streams input)
    if (state.test_pattern == 0)
    {
        if (strcmp(state.filename, "-") == 0)
        {
            state.file = stdin;
        }
        else
        {
            state.file = fopen(state.filename, "rb");
            if (!state.file)
            {
                ZF_LOGE("Failed to open %s", state.filename);
                release_system();
                return -1;
            }
        }
    }

    usleep(100000);
    unsigned int it = 0;
	while (state.program_running)
	{
        int ret = 0;
        size_t nsamples = state.native_write_len;

        if (state.test_pattern == 0)
        {
            size_t rret = fread(state.buffer, 1,
                                sizeof(cariboulite_sample_complex_int16) * nsamples, state.file);
            if (rret == 0)
            {
                ZF_LOGI("Sample input (%s) exhausted - stopping TX",
                        state.file == stdin ? "stdin" : state.filename);
                break;
            }
            nsamples = rret / sizeof(cariboulite_sample_complex_int16);
        }
        else if (state.test_pattern == 2)
        {
            fm_fill(state.buffer, nsamples);
        }

        ret = cariboulite_radio_write_samples(state.radio, state.buffer, nsamples);

        if (ret < 0)
        {
            ZF_LOGE("Samples write operation failed. Quiting...");
            break;
        }

        if (!(it % 67))
            cariboulite_radio_debug(state.radio);

        if (!state.sample_infinite)
        {
            state.samples_to_write -= ret;
            if (state.samples_to_write <= 0)
                break;
        }
        if (ret > 0)
        {
            it++;
        }
    }

    // close the driver and release resources
    release_system();
    ZF_LOGI("samples written: %u blocks", it);
    return 0;
}
