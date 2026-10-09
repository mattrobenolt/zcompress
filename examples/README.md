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
`decode`, one optional path, `-` or no path for stdin), the input as an
`Io.File.Reader`, and stdout as an `Io.File.Writer`. A codec's example file
names the codec and provides streaming `encode`/`decode` pumps over that
scaffolding — stack-buffered, allocation-free end to end.

The framing is the codec package's, not the example's (snappy's:
`src/snappy/README.md`, "Streaming"). The examples exist to feel the codec
APIs in real usage: wrap, pump, finish.
