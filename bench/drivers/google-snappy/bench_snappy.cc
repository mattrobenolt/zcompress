/* The google/snappy fleet arm (bench/README.md): the pinned canonical snappy
 * implementation (docs/zcompress-plan.md, "Benchmark methodology"), raw
 * blocks only — the format description's block encoding, no framing — both
 * directions over the committed corpus. The rows compare against the zc
 * arm's `snappy/...` rows (bench/zig/bench_zcompress.zig).
 *
 * The timed loop is the codec alone: a `snappy::CompressionContext` is
 * created once in setup and reused, so no WorkingMemory is allocated per
 * iteration, and compress writes straight into the harness's target buffer.
 * The string wrappers (`snappy::Compress`/`snappy::Uncompress`) would
 * re-allocate the ~170 KiB of per-call scratch and resize the output string
 * on every call — a per-iteration artifact the other arms do not pay.
 * Decompression reads the reference blob with
 * `snappy::GetUncompressedLength` + `snappy::RawUncompress` into the
 * caller's buffer (the same pair the string wrapper calls internally).
 *
 * Format: docs/research/specs/snappy-format-description.txt (the same spec
 * zcompress implements). Built against the pinned release tarball; build
 * defines: CBENCH_TARGET (triple string), CBENCH_CPU, ZIG_VERSION,
 * COMPETITOR_VERSION.
 */
#include <stdlib.h>

#include "snappy.h"

#define ARM "googlesnappy"
#define IMPL "googlesnappy"
#define TOOL "google/snappy"
#define CBENCH_CODECS {"snappy"}
#define CBENCH_CODEC_COUNT 1
#define CBENCH_TOOLCHAIN "zig c++"

/* Owned by impl_setup/impl_teardown; reused across every compression. */
static snappy::CompressionContext *compressor = NULL;

static void impl_setup(void)
{
    compressor = new snappy::CompressionContext();
}

static void impl_teardown(void)
{
    delete compressor;
    compressor = NULL;
}

static size_t impl_compress(const char *codec, const unsigned char *in, size_t in_len,
                            unsigned char *out, size_t out_cap)
{
    (void)codec; /* one codec: the raw snappy block */
    if (out_cap < snappy::MaxCompressedLength(in_len)) return 0;
    size_t out_len = 0;
    /* Level 1 explicitly: the fast class the other arms measure (level 2 is
     * the denser, slower mode the library keeps experimental). */
    snappy::RawCompress(reinterpret_cast<const char *>(in), in_len,
                        reinterpret_cast<char *>(out), &out_len,
                        snappy::CompressionOptions{1}, compressor);
    return out_len;
}

static size_t impl_decompress(const char *codec, const unsigned char *in, size_t in_len,
                              unsigned char *out, size_t out_cap)
{
    (void)codec;
    size_t out_len = 0;
    if (!snappy::GetUncompressedLength(reinterpret_cast<const char *>(in), in_len, &out_len))
        return 0;
    if (out_len > out_cap) return 0;
    if (!snappy::RawUncompress(reinterpret_cast<const char *>(in), in_len,
                               reinterpret_cast<char *>(out)))
        return 0;
    return out_len;
}

#include "../c/cbench.h"
