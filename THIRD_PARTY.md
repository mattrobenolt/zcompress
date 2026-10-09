# Third-party notices

zcompress is MIT (`LICENSE`). This file lists every port, vendored artifact,
and dependency with a license that is not ours.

## Ports

- `src/snappy/encode.zig`: a port of the algorithm in klauspost/compress
  (BSD-3-Clause) `encodeBlockSnappyGo64K`, itself descended from the
  Snappy-Go reference encoder. The algorithm is ported, not the code.
  Attribution: Copyright klauspost/compress contributors,
  https://github.com/klauspost/compress (s2/encode_all.go).
- `src/snappy/decode.zig` golden vectors: ported from golang/snappy
  (BSD-3-Clause) `TestDecode`, `TestDecodeCopy4`, and `TestDecodeLengthOffset`
  tables. Attribution: Copyright the Go Authors,
  https://github.com/golang/snappy (decode_test.go).
- `src/snappy/`: lifted from kafka-zig (Apache-2.0, same author and copyright
  holder as zcompress; the author relicensed the lift here). Upstream:
  https://github.com/mattrobenolt/kafka-zig, `src/snappy/`.

## Vendored specs (`docs/research/specs/`)

Verbatim spec text, fetched once with provenance recorded in the directory
`README.md`. IETF RFCs are freely distributed. The Snappy format description
comes from google/snappy (BSD-3-Clause).

## Dependencies

- fastmem (`https://github.com/mattrobenolt/fastmem-zig`, MIT): the blessed
  memory-copy primitive for codec hot paths. Pinned in `build.zig.zon`.
- zig-benchmark (`https://github.com/mattrobenolt/zig-benchmark`, MIT): the
  local benchmark harness behind `zig build bench`. Pinned in
  `build.zig.zon`. Used by bench executables only, never by codecs.
- ztest (`https://github.com/mattrobenolt/ztest`, MIT): the plain-text test
  runner for the test step. Pinned in `build.zig.zon`, lazy. The fuzz path
  (`-Dfuzz`) uses the default runner.
