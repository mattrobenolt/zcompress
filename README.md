# zcompress has moved

This repo is archived. The compression codecs now live at [baskingspot/compress](https://github.com/baskingspot/compress), and development continues there. This repo's history ends at `e91bb86`, and the new repo continues from it.

The package is named `compress` in its new home, so two things change in a project that depends on it:

```sh
zig fetch --save git+https://github.com/baskingspot/compress
```

```zig
const compress = b.dependency("compress", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("compress", compress.module("compress"));
```

An `@import("zcompress")` becomes `@import("compress")`.
