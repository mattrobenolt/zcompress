# Vendored specs

Verbatim spec text, fetched once, never edited. Tests cite these files by
name and section (`// RFC 1951 §3.2.5 — fixed Huffman`). When in doubt, read
the spec. When still in doubt, read the spec again.

| File | Source | Fetched |
|---|---|---|
| rfc1950-zlib.txt | https://www.rfc-editor.org/rfc/rfc1950.txt | 2026-10-08 |
| rfc1951-deflate.txt | https://www.rfc-editor.org/rfc/rfc1951.txt | 2026-10-08 |
| rfc1952-gzip.txt | https://www.rfc-editor.org/rfc/rfc1952.txt | 2026-10-08 |
| rfc8878-zstd.txt | https://www.rfc-editor.org/rfc/rfc8878.txt | 2026-10-08 |
| snappy-format-description.txt | https://github.com/google/snappy/blob/main/format_description.txt | 2026-10-08 |

LZW has no RFC. The reference formats are TIFF 6.0 (PackBits-adjacent LZW
compression, section 13) and PDF 32000 (LZWDecode, section 7.4.2.2). Those
spec sections vendor at M6 with the codec.

The zstd reference implementation (BSD-3, https://github.com/facebook/zstd)
supplements RFC 8878 where the frame/block layer leaves behavior unstated;
klauspost/compress's zstd (BSD-3) is the Go reference for the same gaps. The
same pattern holds per codec: the RFC is the contract, the reference suites
are the oracle.
