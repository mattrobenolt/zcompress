/* The zlib-ng fleet arm (bench/README.md): the streaming zlib API (the
 * pinned competitor shape) at level 1, over the three containers as
 * windowBits -15/15/31 (raw/zlib/gzip). Streams reset per iteration
 * (deflateReset/inflateReset), so the timed loop is the codec alone.
 *
 * Built against zlib-ng in ZLIB_COMPAT mode (the zlib.h API). Build defines:
 * CBENCH_TARGET (triple string), CBENCH_CPU, ZIG_VERSION, COMPETITOR_VERSION.
 */
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define ARM "zlibng"
#define IMPL "zlibng"
#define TOOL "zlib-ng"

static z_stream deflator;
static z_stream inflator;
static int current_wbits;

static int wbits_for(const char *codec)
{
    if (!strcmp(codec, "gzip")) return 31;
    if (!strcmp(codec, "zlib")) return 15;
    return -15;
}

static void impl_setup(void)
{
    memset(&deflator, 0, sizeof deflator);
    memset(&inflator, 0, sizeof inflator);
    current_wbits = 0;
}

static void impl_teardown(void)
{
    if (current_wbits) {
        deflateEnd(&deflator);
        inflateEnd(&inflator);
    }
}

static void setup_wbits(int wbits)
{
    if (current_wbits == wbits) return;
    if (current_wbits) {
        deflateEnd(&deflator);
        inflateEnd(&inflator);
    }
    if (deflateInit2(&deflator, 1, Z_DEFLATED, wbits, 8, Z_DEFAULT_STRATEGY) != Z_OK)
        exit(1);
    if (inflateInit2(&inflator, wbits) != Z_OK)
        exit(1);
    current_wbits = wbits;
}

static size_t impl_compress(const char *codec, const unsigned char *in, size_t in_len,
                            unsigned char *out, size_t out_cap)
{
    setup_wbits(wbits_for(codec));
    if (deflateReset(&deflator) != Z_OK) return 0;
    deflator.next_in = (unsigned char *)in;
    deflator.avail_in = (unsigned)in_len;
    deflator.next_out = out;
    deflator.avail_out = (unsigned)out_cap;
    if (deflate(&deflator, Z_FINISH) != Z_STREAM_END) return 0;
    return out_cap - deflator.avail_out;
}

static size_t impl_decompress(const char *codec, const unsigned char *in, size_t in_len,
                              unsigned char *out, size_t out_cap)
{
    setup_wbits(wbits_for(codec));
    if (inflateReset(&inflator) != Z_OK) return 0;
    inflator.next_in = (unsigned char *)in;
    inflator.avail_in = (unsigned)in_len;
    inflator.next_out = out;
    inflator.avail_out = (unsigned)out_cap;
    if (inflate(&inflator, Z_FINISH) != Z_STREAM_END) return 0;
    return out_cap - inflator.avail_out;
}

#include "cbench.h"
