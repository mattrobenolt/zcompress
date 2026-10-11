/* Shared harness for the native competitor arms (bench/README.md): the C
 * drivers (libdeflate, zlib-ng) and the C++ driver (google/snappy). The
 * driver defines impl_compress/impl_decompress, the ARM/IMPL/TOOL strings,
 * and the codec set (CBENCH_CODECS, CBENCH_CODEC_COUNT), then includes
 * this header. Same CLI, corpus, and schema-v1 JSONL as the zcompress
 * driver: one process is one round of this arm.
 *
 * Decompression rows decode the committed reference blobs; the warmup pass
 * of each cell verifies the round trip; --check runs the whole matrix as
 * the correctness gate and prints one JSON summary line.
 *
 * The header compiles as C and as C++ (the google/snappy driver is a C++
 * translation unit); the driver's definitions precede the include, so no
 * prototypes are needed.
 */
#ifndef CBENCH_H
#define CBENCH_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

/* The driver's codec set and the compiler line in the meta record. The
 * flate-family default covers the C arms; the google/snappy driver
 * overrides both before including this header. A decode-only driver (the
 * zstd-c arm) overrides CBENCH_DIRECTIONS; its impl_compress is then never
 * called. */
#ifndef CBENCH_CODECS
#define CBENCH_CODECS {"flate", "gzip", "zlib"}
#define CBENCH_CODEC_COUNT 3
#endif
#ifndef CBENCH_TOOLCHAIN
#define CBENCH_TOOLCHAIN "zig cc"
#endif
#ifndef CBENCH_DIRECTIONS
#define CBENCH_DIRECTIONS {"compress", "decompress"}
#define CBENCH_DIRECTION_COUNT 2
#endif

static const char *const shapes[] = {"text", "random", "html", "rle", "mixed"};
static const size_t shape_sizes[] = {32 * 1024, 64 * 1024};
static const char *const codecs[] = CBENCH_CODECS;
static const char *const directions[] = CBENCH_DIRECTIONS;
static const int direction_count = CBENCH_DIRECTION_COUNT;

struct cbench_options {
    const char *corpus;
    const char *suite; /* "standard" | "quick" */
    unsigned long long seed;
    int samples;
    long sample_ms;
    const char *filter;
    int check;
};

struct cbench_case {
    const char *shape;
    size_t size;
    unsigned char *raw;
    unsigned char *blobs[CBENCH_CODEC_COUNT]; /* one per codec, in codecs[] order */
    size_t blob_lens[CBENCH_CODEC_COUNT];
};

static const char *blob_ext(const char *codec)
{
    if (!strcmp(codec, "gzip")) return "gz";
    if (!strcmp(codec, "zlib")) return "zz";
    if (!strcmp(codec, "zstd")) return "zst";
    return codec;
}

/* True when the driver carries this direction (CBENCH_DIRECTIONS). */
static int has_direction(const char *direction)
{
    for (int d = 0; d < direction_count; d++)
        if (!strcmp(directions[d], direction)) return 1;
    return 0;
}

static unsigned char *read_file(const char *dir, const char *name, size_t *len)
{
    char path[1024];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "open %s failed\n", path); exit(1); }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *buf = (unsigned char *)malloc((size_t)n ? (size_t)n : 1);
    if (!buf || fread(buf, 1, (size_t)n, f) != (size_t)n) {
        fprintf(stderr, "read %s failed\n", path);
        exit(1);
    }
    fclose(f);
    *len = (size_t)n;
    return buf;
}

static void load_case(struct cbench_options *o, const char *shape, size_t size,
                      struct cbench_case *c)
{
    char base[128], name[160];
    size_t n;
    snprintf(base, sizeof base, "%s-%zu", shape, size);
    c->shape = shape;
    c->size = size;
    c->raw = read_file(o->corpus, base, &n);
    if (n != size) { fprintf(stderr, "corpus size mismatch: %s\n", base); exit(1); }
    for (int k = 0; k < CBENCH_CODEC_COUNT; k++) {
        snprintf(name, sizeof name, "%s.%s", base, blob_ext(codecs[k]));
        c->blobs[k] = read_file(o->corpus, name, &c->blob_lens[k]);
    }
}

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* Minimal SHA-256 (FIPS 180-4) for the corpus hashes in the meta record. */
struct sha256 {
    uint32_t h[8];
    uint64_t len;
    unsigned char buf[64];
    size_t buf_len;
};

static const uint32_t sha256_k[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu, 0x59f111f1u,
    0x923f82a4u, 0xab1c5ed5u, 0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
    0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u, 0xe49b69c1u, 0xefbe4786u,
    0x0fc19dc6u, 0x240ca1ccu, 0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u,
    0x06ca6351u, 0x14292967u, 0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
    0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u, 0xa2bfe8a1u, 0xa81a664bu,
    0xc24b8b70u, 0xc76c51a3u, 0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au,
    0x5b9cca4fu, 0x682e6ff3u, 0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u,
};

static uint32_t rotr32(uint32_t x, unsigned n) { return x >> n | x << (32 - n); }

static void sha256_block(struct sha256 *s, const unsigned char *p)
{
    uint32_t w[64];
    for (int i = 0; i < 16; i++)
        w[i] = (uint32_t)p[i * 4] << 24 | (uint32_t)p[i * 4 + 1] << 16 |
               (uint32_t)p[i * 4 + 2] << 8 | (uint32_t)p[i * 4 + 3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ w[i - 15] >> 3;
        uint32_t s1 = rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ w[i - 2] >> 10;
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = s->h[0], b = s->h[1], c = s->h[2], d = s->h[3];
    uint32_t e = s->h[4], f = s->h[5], g = s->h[6], h = s->h[7];
    for (int i = 0; i < 64; i++) {
        uint32_t s1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25);
        uint32_t ch = (e & f) ^ (~e & g);
        uint32_t t1 = h + s1 + ch + sha256_k[i] + w[i];
        uint32_t s0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22);
        uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2 = s0 + maj;
        h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    s->h[0] += a; s->h[1] += b; s->h[2] += c; s->h[3] += d;
    s->h[4] += e; s->h[5] += f; s->h[6] += g; s->h[7] += h;
}

static void sha256_init(struct sha256 *s)
{
    static const uint32_t h0[8] = {
        0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
        0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u,
    };
    memcpy(s->h, h0, sizeof h0);
    s->len = 0;
    s->buf_len = 0;
}

static void sha256_update(struct sha256 *s, const unsigned char *p, size_t n)
{
    s->len += n;
    while (n) {
        size_t take = 64 - s->buf_len;
        if (take > n) take = n;
        memcpy(s->buf + s->buf_len, p, take);
        s->buf_len += take;
        p += take;
        n -= take;
        if (s->buf_len == 64) {
            sha256_block(s, s->buf);
            s->buf_len = 0;
        }
    }
}

static void sha256_final(struct sha256 *s, unsigned char out[32])
{
    uint64_t bits = s->len * 8;
    unsigned char pad = 0x80;
    sha256_update(s, &pad, 1);
    unsigned char zero = 0;
    while (s->buf_len != 56) sha256_update(s, &zero, 1);
    unsigned char lenbuf[8];
    for (int i = 0; i < 8; i++) lenbuf[i] = (unsigned char)(bits >> (56 - i * 8));
    sha256_update(s, lenbuf, 8);
    for (int i = 0; i < 8; i++) {
        out[i * 4] = (unsigned char)(s->h[i] >> 24);
        out[i * 4 + 1] = (unsigned char)(s->h[i] >> 16);
        out[i * 4 + 2] = (unsigned char)(s->h[i] >> 8);
        out[i * 4 + 3] = (unsigned char)s->h[i];
    }
}

static void sha256_hex(const unsigned char *data, size_t n, char out[65])
{
    struct sha256 s;
    unsigned char digest[32];
    sha256_init(&s);
    sha256_update(&s, data, n);
    sha256_final(&s, digest);
    for (int i = 0; i < 32; i++) sprintf(out + i * 2, "%02x", digest[i]);
    out[64] = 0;
}

#define CBENCH_TARGET_CAP (64 * 1024 + 64 * 1024 / 6 + 4096)

static void case_id(const struct cbench_case *c, const char *codec,
                    const char *direction, char *buf, size_t cap)
{
    snprintf(buf, cap, "%s/%s/%s/%zu", codec, direction, c->shape, c->size);
}

static int row_selected(struct cbench_options *o, const char *codec,
                        const char *direction, const char *shape, size_t size)
{
    char id[128];
    if (!o->filter) return 1;
    snprintf(id, sizeof id, "%s/%s/%s/%zu", codec, direction, shape, size);
    return strstr(id, o->filter) != NULL;
}

/* True when any row of this codec (any direction it carries) is selected. */
static int any_row(struct cbench_options *o, const char *codec, const char *shape, size_t size)
{
    for (int d = 0; d < direction_count; d++)
        if (row_selected(o, codec, directions[d], shape, size)) return 1;
    return 0;
}

static int check_cell(struct cbench_case *c, int k, unsigned char *target,
                      unsigned char *decoded, const char **detail)
{
    /* Decode-only drivers have no round trip: the reference decode is the
     * whole check. */
    if (has_direction("compress")) {
        size_t n = impl_compress(codecs[k], c->raw, c->size, target, CBENCH_TARGET_CAP);
        if (n == 0) { *detail = "compress failed"; return -1; }
        size_t back = impl_decompress(codecs[k], target, n, decoded, c->size);
        if (back != c->size || memcmp(decoded, c->raw, c->size)) {
            *detail = "round trip mismatch";
            return -1;
        }
    }
    size_t got = impl_decompress(codecs[k], c->blobs[k], c->blob_lens[k], decoded, c->size);
    if (got != c->size || memcmp(decoded, c->raw, c->size)) {
        *detail = "reference blob mismatch";
        return -1;
    }
    return 0;
}

static void run_check(struct cbench_options *o)
{
    unsigned char *target = (unsigned char *)malloc(CBENCH_TARGET_CAP);
    unsigned char *decoded = (unsigned char *)malloc(64 * 1024);
    const char *detail = "";
    int checked = 0;
    size_t count = !strcmp(o->suite, "quick") ? 1 : 2;
    impl_setup();
    for (size_t s = 0; s < 5 && !*detail; s++) {
        for (size_t z = 0; z < count && !*detail; z++) {
            struct cbench_case c;
            load_case(o, shapes[s], shape_sizes[z], &c);
            for (int k = 0; k < CBENCH_CODEC_COUNT; k++) {
                if (!any_row(o, codecs[k], c.shape, c.size)) continue;
                checked++;
                if (check_cell(&c, k, target, decoded, &detail)) break;
            }
            for (int k = 0; k < CBENCH_CODEC_COUNT; k++) free(c.blobs[k]);
            free(c.raw);
        }
    }
    impl_teardown();
    printf("{\"type\":\"check\",\"schema\":1,\"arm\":\"%s\",\"status\":\"%s\","
           "\"cases\":%d,\"cpu\":\"%s\",\"optimize\":\"release\",\"detail\":\"%s\"}\n",
           ARM, *detail ? "fail" : "pass", checked, CBENCH_CPU, detail);
    free(target);
    free(decoded);
    if (*detail) exit(1);
}

static void write_meta(struct cbench_options *o)
{
    printf("{\"type\":\"meta\",\"schema\":1,\"arm\":\"%s\",\"tool\":\"%s\","
           "\"rev\":\"%s\",\"toolchain\":\"" CBENCH_TOOLCHAIN
           " %s\",\"target\":\"%s\",\"cpu\":\"%s\","
           "\"optimize\":\"release\",\"suite\":\"%s\",\"seed\":%llu,\"samples\":%d,"
           "\"sample_ms\":%ld,\"impls\":[\"%s\"],\"corpus\":{",
           ARM, TOOL, COMPETITOR_VERSION, ZIG_VERSION, CBENCH_TARGET, CBENCH_CPU,
           o->suite, o->seed, o->samples, o->sample_ms, IMPL);
    for (size_t s = 0; s < 5; s++) {
        for (size_t z = 0; z < 2; z++) {
            char base[128], hex[65];
            size_t n;
            snprintf(base, sizeof base, "%s-%zu", shapes[s], shape_sizes[z]);
            unsigned char *raw = read_file(o->corpus, base, &n);
            sha256_hex(raw, n, hex);
            free(raw);
            printf("%s\"%s\":\"%s\"", (s || z) ? "," : "", base, hex);
        }
    }
    printf("}}\n");
}

static void measure(struct cbench_options *o, struct cbench_case *c, int k,
                    const char *direction, int sample, unsigned char *target)
{
    int compressing = !strcmp(direction, "compress");
    uint64_t deadline = (uint64_t)o->sample_ms * 1000000ull;
    uint64_t iters = 0;
    size_t out_len = 0;
    uint64_t start = now_ns();
    for (;;) {
        if (compressing)
            out_len = impl_compress(codecs[k], c->raw, c->size, target, CBENCH_TARGET_CAP);
        else
            out_len = impl_decompress(codecs[k], c->blobs[k], c->blob_lens[k], target, c->size);
        if (out_len == 0) { fprintf(stderr, "measurement failed\n"); exit(1); }
        iters++;
        if (iters % 8 == 0 && now_ns() - start >= deadline) break;
    }
    uint64_t elapsed = now_ns() - start;
    char id[128];
    case_id(c, codecs[k], direction, id, sizeof id);
    printf("{\"type\":\"sample\",\"case\":\"%s\",\"codec\":\"%s\",\"direction\":\"%s\","
           "\"shape\":\"%s\",\"size\":%zu,\"impl\":\"%s\",\"sample\":%d,\"iters\":%llu,"
           "\"ns\":%llu,\"out_len\":%zu}\n",
           id, codecs[k], direction, c->shape, c->size, IMPL, sample,
           (unsigned long long)iters, (unsigned long long)elapsed, out_len);
}

static void run_measure(struct cbench_options *o)
{
    unsigned char *target = (unsigned char *)malloc(CBENCH_TARGET_CAP);
    unsigned char *decoded = (unsigned char *)malloc(64 * 1024);
    size_t count = !strcmp(o->suite, "quick") ? 1 : 2;
    int cases = 0;
    write_meta(o);
    impl_setup();
    uint64_t start = now_ns();
    for (size_t s = 0; s < 5; s++) {
        for (size_t z = 0; z < count; z++) {
            struct cbench_case c;
            load_case(o, shapes[s], shape_sizes[z], &c);
            int counted = 0;
            const char *detail = "";
            /* Warmup: one pass per cell; verifies the round trip once per
             * process. A failure stops the run. */
            for (int k = 0; k < CBENCH_CODEC_COUNT; k++) {
                if (!any_row(o, codecs[k], c.shape, c.size)) continue;
                counted++;
                if (check_cell(&c, k, target, decoded, &detail)) {
                    fprintf(stderr, "warmup: %s\n", detail);
                    exit(1);
                }
            }
            if (!counted) {
                for (int k = 0; k < CBENCH_CODEC_COUNT; k++) free(c.blobs[k]);
                free(c.raw);
                continue;
            }
            cases += counted;
            for (int sample = 0; sample < o->samples; sample++)
                for (int k = 0; k < CBENCH_CODEC_COUNT; k++)
                    for (int d = 0; d < direction_count; d++)
                        if (row_selected(o, codecs[k], directions[d], c.shape, c.size))
                            measure(o, &c, k, directions[d], sample, target);
            for (int k = 0; k < CBENCH_CODEC_COUNT; k++) free(c.blobs[k]);
            free(c.raw);
        }
    }
    impl_teardown();
    printf("{\"type\":\"end\",\"cases\":%d,\"elapsed_ns\":%llu}\n",
           cases, (unsigned long long)(now_ns() - start));
    free(target);
    free(decoded);
}

int main(int argc, char **argv)
{
    /* Field assignments, not a designated initializer: valid C++ too. */
    struct cbench_options o;
    o.corpus = NULL;
    o.suite = "standard";
    o.seed = 0;
    o.samples = 5;
    o.sample_ms = 100;
    o.filter = NULL;
    o.check = 0;
    for (int i = 1; i < argc; i++) {
        const char *value = i + 1 < argc ? argv[i + 1] : "";
        if (!strcmp(argv[i], "--corpus")) { o.corpus = value; i++; }
        else if (!strcmp(argv[i], "--suite")) { o.suite = value; i++; }
        else if (!strcmp(argv[i], "--seed")) { o.seed = strtoull(value, NULL, 10); i++; }
        else if (!strcmp(argv[i], "--samples")) { o.samples = atoi(value); i++; }
        else if (!strcmp(argv[i], "--sample-ms")) { o.sample_ms = atol(value); i++; }
        else if (!strcmp(argv[i], "--filter")) { o.filter = value; i++; }
        else if (!strcmp(argv[i], "--check")) { o.check = 1; }
        else {
            fprintf(stderr, "unknown argument: %s\n", argv[i]);
            return 2;
        }
    }
    if (!o.corpus || o.samples < 1 || o.sample_ms < 1) {
        fprintf(stderr, "usage: --corpus DIR [--suite standard|quick] [--seed N] "
                "[--samples N] [--sample-ms MS] [--filter SUB] [--check]\n");
        return 2;
    }
    if (o.check) run_check(&o);
    else run_measure(&o);
    return 0;
}

#endif /* CBENCH_H */
