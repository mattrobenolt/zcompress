/* The libdeflate fleet arm (bench/README.md): whole-buffer
 * libdeflate_{deflate,gzip,zlib}_{compress,decompress} at level 1, the fast
 * class matching the zcompress .fast rows. Compressor and decompressor are
 * allocated once per process (the documented reuse pattern), so the timed
 * loop is the codec alone.
 *
 * Build defines: CBENCH_TARGET (triple string), CBENCH_CPU, ZIG_VERSION,
 * COMPETITOR_VERSION.
 */
#include <string.h>

#include <libdeflate.h>

#define ARM "libdeflate"
#define IMPL "libdeflate"
#define TOOL "libdeflate"

static struct libdeflate_compressor *compressor;
static struct libdeflate_decompressor *decompressor;

static void impl_setup(void)
{
    compressor = libdeflate_alloc_compressor(1);
    decompressor = libdeflate_alloc_decompressor();
}

static void impl_teardown(void)
{
    libdeflate_free_compressor(compressor);
    libdeflate_free_decompressor(decompressor);
}

static size_t impl_compress(const char *codec, const unsigned char *in, size_t in_len,
                            unsigned char *out, size_t out_cap)
{
    if (!strcmp(codec, "gzip"))
        return libdeflate_gzip_compress(compressor, in, in_len, out, out_cap);
    if (!strcmp(codec, "zlib"))
        return libdeflate_zlib_compress(compressor, in, in_len, out, out_cap);
    return libdeflate_deflate_compress(compressor, in, in_len, out, out_cap);
}

static size_t impl_decompress(const char *codec, const unsigned char *in, size_t in_len,
                              unsigned char *out, size_t out_cap)
{
    size_t actual = 0;
    enum libdeflate_result result;
    if (!strcmp(codec, "gzip"))
        result = libdeflate_gzip_decompress(decompressor, in, in_len, out, out_cap, &actual);
    else if (!strcmp(codec, "zlib"))
        result = libdeflate_zlib_decompress(decompressor, in, in_len, out, out_cap, &actual);
    else
        result = libdeflate_deflate_decompress(decompressor, in, in_len, out, out_cap, &actual);
    return result == LIBDEFLATE_SUCCESS ? actual : 0;
}

#include "cbench.h"
