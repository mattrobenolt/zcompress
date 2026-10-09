# Third-party notices

zcompress is MIT (`LICENSE`). This file lists every port, vendored artifact,
and dependency with a license that is not ours.

## Ports

- `src/snappy/encode.zig`: a port of the algorithm in klauspost/compress
  (BSD-3-Clause) `encodeBlockSnappyGo64K`, itself descended from the
  Snappy-Go reference encoder. The algorithm is ported, not the code.
  Attribution: Copyright klauspost/compress contributors,
  https://github.com/klauspost/compress (s2/encode_all.go).
- `src/snappy/golden.zig` golden fixtures: ported from golang/snappy
  (BSD-3-Clause) `TestDecode`, `TestDecodeCopy4`, and `TestDecodeLengthOffset`
  tables. Attribution: Copyright the Go Authors,
  https://github.com/golang/snappy (decode_test.go).
- `src/flate/golden.zig` golden fixtures: ported from golang/go
  (BSD-3-Clause) `src/compress/flate/flate_test.go` (`TestStreams`,
  `TestTruncatedStreams`), `inflate_test.go` (`TestReaderTruncated`), and
  `deflate_test.go` (`deflateTests`, as decode goldens). Attribution:
  Copyright the Go Authors, https://github.com/golang/go.
- `src/flate/testdata/huffman-*`: the nine `.in`/`.golden` pairs vendored
  verbatim from golang/go (BSD-3-Clause)
  `src/compress/flate/testdata/`. Attribution: Copyright the Go Authors,
  https://github.com/golang/go.
- `src/flate/decode.zig` lineage: the two-level Huffman decode table (a
  9-bit primary table plus a chained chase for longer codes) follows the
  algorithm in zlib's `doc/algorithm.txt` (zlib license, studied), as used by
  Zig std's `std.compress.flate.Decompress.zig` (MIT, in-tree, studied).
  Reimplemented in this package's shape — wire-bit orientation, table
  packing, chain layout, and the completeness rules are ours; no code copied.

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
