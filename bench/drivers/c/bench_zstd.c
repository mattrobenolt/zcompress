/* The zstd-c fleet arm (bench/README.md): the pinned facebook/zstd v1.5.7
 * (docs/research/zstd-notes.md §6.1, the native ceiling), whole-buffer
 * ZSTD_decompressDCtx on a reused context — the simple one-shot API shape
 * that matches the zc arm's `zstd/decompress/...` rows
 * (bench/zig/bench_zcompress.zig). Decode-only: M4 is the zstd decode
 * milestone and the zc arm has no encoder, so there is no compress row to
 * compare against.
 *
 * Window posture (src/zstd/README.md, "Benchmarks": the driver's rows must
 * share the one-shot's acceptance policy): ZSTD_d_windowLogMax pinned to
 * ZSTD_WINDOWLOG_LIMIT_DEFAULT (27, the reference default). The corpus
 * frames are single-segment with Window_Size = FCS <= 64 KiB, so every
 * arm's cap accepts them; the pin keeps the posture explicit and recorded.
 *
 * Build defines: CBENCH_TARGET (triple string), CBENCH_CPU, ZIG_VERSION,
 * COMPETITOR_VERSION.
 */
#include <stdlib.h>

#include <zstd.h>

#define ARM "zstd-c"
#define IMPL "zstd-c"
#define TOOL "zstd"
#define CBENCH_CODECS {"zstd"}
#define CBENCH_CODEC_COUNT 1
#define CBENCH_DIRECTIONS {"decompress"}
#define CBENCH_DIRECTION_COUNT 1

/* Owned by impl_setup/impl_teardown; the documented reuse pattern, so the
 * timed loop is the decode alone. */
static ZSTD_DCtx *dctx;

static void impl_setup(void)
{
    dctx = ZSTD_createDCtx();
    if (!dctx) exit(1);
    /* 27 = ZSTD_WINDOWLOG_LIMIT_DEFAULT (zstd_internal.h — the public
     * zstd.h hides it behind the static-linking-only section). */
    if (ZSTD_isError(ZSTD_DCtx_setParameter(dctx, ZSTD_d_windowLogMax, 27)))
        exit(1);
}

static void impl_teardown(void)
{
    ZSTD_freeDCtx(dctx);
    dctx = NULL;
}

static size_t impl_compress(const char *codec, const unsigned char *in, size_t in_len,
                            unsigned char *out, size_t out_cap)
{
    /* Decode-only arm (CBENCH_DIRECTIONS): cbench.h never calls this.
     * (Return 0 = the harness's failure sentinel.) */
    (void)codec;
    (void)in;
    (void)in_len;
    (void)out;
    (void)out_cap;
    return 0;
}

static size_t impl_decompress(const char *codec, const unsigned char *in, size_t in_len,
                              unsigned char *out, size_t out_cap)
{
    (void)codec; /* one codec: the zstd frame */
    size_t n = ZSTD_decompressDCtx(dctx, out, out_cap, in, in_len);
    if (ZSTD_isError(n)) return 0;
    return n;
}

#include "cbench.h"
