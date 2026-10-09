# zcompress

Fast, self-contained compression codecs in pure Zig. Performance in the class
of [klauspost/compress](https://github.com/klauspost/compress), usability in
the class of `std.compress`.

Status: scaffold. snappy (raw block) is the first codec, lifted from
[kafka-zig](https://github.com/mattrobenolt/kafka-zig) with fastmem wired into
its copy paths. flate, gzip/zlib, zstd, and lzw follow — one at a time, each
shippable alone. [`docs/zcompress-plan.md`](docs/zcompress-plan.md) is the
plan.

Design rules:

- One module per codec, importing only `std` and
  [fastmem](https://github.com/mattrobenolt/fastmem-zig). Lift a codec out
  and it still builds.
- Block functions first, then Sans-I/O streaming cores, then `std.Io`
  adapters. The caller owns every buffer; codec hot paths allocate nothing.
- SIMD is `@Vector`/`@shuffle`/`@select` and `std.simd`, comptime-sized per
  target. Assembly only where Zig cannot express the instruction,
  feature-gated, with a generic fallback, and only after a vector route is
  proven slower.
- Every format test cites its spec section (`// RFC 1951 §3.2.5 — ...`).
  Specs are vendored in
  [`docs/research/specs/`](docs/research/specs/README.md).
- Performance claims cite fleet runs under `docs/results/` — measured, never
  local-only.

```sh
nix develop   # Zig 0.16.0, zls, ziglint, zigdoc
just test     # unit tests for every codec
just lint     # ziglint + zig fmt --check
just bench    # local benchmarks (zig-benchmark; not claims evidence)
```

License: MIT. Ports and vendored artifacts are attributed in
[`THIRD_PARTY.md`](THIRD_PARTY.md).
