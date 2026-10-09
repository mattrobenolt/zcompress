# Examples

One CLI per codec, over a file argument or stdin, writing to stdout:

```sh
zig build example-snappy -- encode README.md > /tmp/out.snappy
zig build example-snappy -- decode /tmp/out.snappy > /tmp/out
cmp README.md /tmp/out
cat README.md | zig build example-snappy -- encode - > /tmp/out.snappy
```

Or via just: `just example snappy encode README.md > /tmp/out.snappy`.

Shared scaffolding lives in `examples/cli.zig`: argument parsing (`encode` /
`decode`, one optional path, `-` or no path for stdin), input reading with a
1 GiB cap, stdout, error reporting, and exit codes (0 ok, 1 usage, 2 codec
error). A codec's example file names the codec and provides whole-input
`encode`/`decode` over that scaffolding.

Each CLI owns its codec's framing decision — that is the point of the
exercise: feeling where the codec API ends and consumer framing begins.
Snappy is a raw-block codec, so `examples/snappy.zig` defines the block-split
framing (`u32-le compressed length + raw block`, 64 KiB blocks).

These CLIs read the whole input before encoding. Streaming CLIs arrive with
the streaming cores (docs/zcompress-plan.md, API layers).
