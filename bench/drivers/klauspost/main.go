// The klauspost/compress fleet arm (bench/README.md). Same CLI, corpus, and
// schema-v1 JSONL as the zcompress driver: one process is one round of this
// arm. Rows: flate/gzip/zlib at level 1 (the fast class, matching the
// zcompress .fast rows) and snappy raw blocks, both directions.
//
// One-shot shape: writers and readers are constructed per iteration, the Go
// equivalent of the zcompress one-shots' per-call table setup. Decompression
// rows decode the committed reference blobs, identical bytes for every arm.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strings"
	"time"

	"github.com/klauspost/compress/flate"
	"github.com/klauspost/compress/gzip"
	"github.com/klauspost/compress/snappy"
	"github.com/klauspost/compress/zlib"
)

var shapes = []string{"text", "random", "html", "rle", "mixed"}
var sizes = []int{32 * 1024, 64 * 1024}
var codecs = []string{"flate", "gzip", "zlib", "snappy"}
var directions = []string{"compress", "decompress"}

type options struct {
	corpus   string
	suite    string
	seed     uint64
	samples  int
	sampleMs int64
	filter   string
	check    bool
}

type kase struct {
	shape string
	size  int
	raw   []byte
	blobs map[string][]byte
}

func blobExt(codec string) string {
	switch codec {
	case "gzip":
		return "gz"
	case "zlib":
		return "zz"
	default:
		return codec
	}
}

func loadCase(o *options, shape string, size int) (*kase, error) {
	base := fmt.Sprintf("%s-%d", shape, size)
	raw, err := os.ReadFile(filepath.Join(o.corpus, base))
	if err != nil {
		return nil, err
	}
	if len(raw) != size {
		return nil, fmt.Errorf("corpus size mismatch for %s", base)
	}
	c := &kase{shape: shape, size: size, raw: raw, blobs: map[string][]byte{}}
	for _, codec := range codecs {
		blob, err := os.ReadFile(filepath.Join(o.corpus, base+"."+blobExt(codec)))
		if err != nil {
			return nil, err
		}
		c.blobs[codec] = blob
	}
	return c, nil
}

// compressOne compresses raw with the codec's level-1 writer and returns the
// produced length.
func compressOne(codec string, raw, target []byte) (int, error) {
	buf := bytes.NewBuffer(target[:0])
	switch codec {
	case "flate":
		w, err := flate.NewWriter(buf, 1)
		if err != nil {
			return 0, err
		}
		if _, err := w.Write(raw); err != nil {
			return 0, err
		}
		if err := w.Close(); err != nil {
			return 0, err
		}
	case "gzip":
		w, err := gzip.NewWriterLevel(buf, 1)
		if err != nil {
			return 0, err
		}
		if _, err := w.Write(raw); err != nil {
			return 0, err
		}
		if err := w.Close(); err != nil {
			return 0, err
		}
	case "zlib":
		w, err := zlib.NewWriterLevel(buf, 1)
		if err != nil {
			return 0, err
		}
		if _, err := w.Write(raw); err != nil {
			return 0, err
		}
		if err := w.Close(); err != nil {
			return 0, err
		}
	case "snappy":
		return len(snappy.Encode(target, raw)), nil
	}
	return buf.Len(), nil
}

// decompressOne decodes blob into target and returns the decoded length.
func decompressOne(codec string, blob, target []byte) (int, error) {
	if codec == "snappy" {
		out, err := snappy.Decode(target[:0], blob)
		if err != nil {
			return 0, err
		}
		return len(out), nil
	}
	var r io.ReadCloser
	var err error
	switch codec {
	case "flate":
		r = flate.NewReader(bytes.NewReader(blob))
	case "gzip":
		r, err = gzip.NewReader(bytes.NewReader(blob))
	case "zlib":
		r, err = zlib.NewReader(bytes.NewReader(blob))
	}
	if err != nil {
		return 0, err
	}
	defer r.Close()
	out := bytes.NewBuffer(target[:0])
	if _, err := io.Copy(out, r); err != nil {
		return 0, err
	}
	return out.Len(), nil
}

// checkCell round-trips the raw corpus and decodes the reference blob.
func checkCell(c *kase, codec string, target, decoded []byte) error {
	n, err := compressOne(codec, c.raw, target)
	if err != nil {
		return fmt.Errorf("compress %s/%s: %w", codec, c.shape, err)
	}
	back, err := decompressOne(codec, target[:n], decoded)
	if err != nil {
		return fmt.Errorf("round trip %s/%s: %w", codec, c.shape, err)
	}
	if back != c.size || !bytes.Equal(decoded[:back], c.raw) {
		return fmt.Errorf("round trip mismatch %s/%s", codec, c.shape)
	}
	got, err := decompressOne(codec, c.blobs[codec], decoded)
	if err != nil {
		return fmt.Errorf("reference decode %s/%s: %w", codec, c.shape, err)
	}
	if got != c.size || !bytes.Equal(decoded[:got], c.raw) {
		return fmt.Errorf("reference blob mismatch %s/%s", codec, c.shape)
	}
	return nil
}

func caseID(codec, direction, shape string, size int) string {
	return fmt.Sprintf("%s/%s/%s/%d", codec, direction, shape, size)
}

func selected(o *options, codec, direction, shape string, size int) bool {
	return o.filter == "" || strings.Contains(caseID(codec, direction, shape, size), o.filter)
}

// anyRow reports whether any row of this codec (either direction) is selected.
func anyRow(o *options, codec, shape string, size int) bool {
	for _, direction := range directions {
		if selected(o, codec, direction, shape, size) {
			return true
		}
	}
	return false
}

func maxTarget() int {
	// flate's worst case is the largest of the four; snappy's bound is close.
	return 64*1024 + 64*1024/6 + 1024
}

func main() {
	var o options
	flag.StringVar(&o.corpus, "corpus", "", "corpus directory")
	flag.StringVar(&o.suite, "suite", "standard", "standard|quick")
	flag.Uint64Var(&o.seed, "seed", 0, "run seed")
	flag.IntVar(&o.samples, "samples", 5, "samples per cell")
	flag.Int64Var(&o.sampleMs, "sample-ms", 100, "milliseconds per sample")
	flag.StringVar(&o.filter, "filter", "", "case substring")
	flag.BoolVar(&o.check, "check", false, "run the correctness matrix")
	flag.Parse()
	if o.corpus == "" || o.samples < 1 || o.sampleMs < 1 {
		fmt.Fprintln(os.Stderr, "usage: --corpus DIR [--suite standard|quick] [--seed N] "+
			"[--samples N] [--sample-ms MS] [--filter SUB] [--check]")
		os.Exit(2)
	}
	if o.check {
		runCheck(&o)
		return
	}
	runMeasure(&o)
}

func suiteSizes(o *options) []int {
	if o.suite == "quick" {
		return sizes[:1]
	}
	return sizes
}

func runCheck(o *options) {
	target := make([]byte, maxTarget())
	decoded := make([]byte, 64*1024)
	checked := 0
	detail := ""
loop:
	for _, shape := range shapes {
		for _, size := range suiteSizes(o) {
			c, err := loadCase(o, shape, size)
			if err != nil {
				detail = err.Error()
				break loop
			}
			for _, codec := range codecs {
				if !anyRow(o, codec, shape, size) {
					continue
				}
				checked++
				if err := checkCell(c, codec, target, decoded); err != nil {
					detail = err.Error()
					break loop
				}
			}
		}
	}
	status := "pass"
	if detail != "" {
		status = "fail"
	}
	fmt.Printf("{\"type\":\"check\",\"schema\":1,\"arm\":\"klauspost\",\"status\":%q,"+
		"\"cases\":%d,\"cpu\":%q,\"optimize\":\"release\",\"detail\":%q}\n",
		status, checked, runtime.GOARCH, detail)
	if detail != "" {
		os.Exit(1)
	}
}

func runMeasure(o *options) {
	writeMeta(o)
	target := make([]byte, maxTarget())
	decoded := make([]byte, 64*1024)
	start := time.Now()
	cases := 0
	for _, shape := range shapes {
		for _, size := range suiteSizes(o) {
			c, err := loadCase(o, shape, size)
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			counted := 0
			// Warmup: one pass per cell; verifies the round trip once per
			// process. A failure stops the run.
			for _, codec := range codecs {
				if !anyRow(o, codec, shape, size) {
					continue
				}
				counted++
				if err := checkCell(c, codec, target, decoded); err != nil {
					fmt.Fprintln(os.Stderr, err)
					os.Exit(1)
				}
			}
			if counted == 0 {
				continue
			}
			cases += counted
			for sample := 0; sample < o.samples; sample++ {
				for _, codec := range codecs {
					for _, direction := range directions {
						if !selected(o, codec, direction, shape, size) {
							continue
						}
						measure(o, c, codec, direction, sample, target)
					}
				}
			}
		}
	}
	fmt.Printf("{\"type\":\"end\",\"cases\":%d,\"elapsed_ns\":%d}\n", cases, time.Since(start))
}

func measure(o *options, c *kase, codec, direction string, sample int, target []byte) {
	compressing := direction == "compress"
	deadline := time.Duration(o.sampleMs) * time.Millisecond
	var iters uint64
	outLen := 0
	start := time.Now()
	for {
		var err error
		if compressing {
			outLen, err = compressOne(codec, c.raw, target)
		} else {
			outLen, err = decompressOne(codec, c.blobs[codec], target)
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		iters++
		if iters%8 == 0 && time.Since(start) >= deadline {
			break
		}
	}
	elapsed := time.Since(start)
	fmt.Printf("{\"type\":\"sample\",\"case\":%q,\"codec\":%q,\"direction\":%q,"+
		"\"shape\":%q,\"size\":%d,\"impl\":\"klauspost\",\"sample\":%d,\"iters\":%d,"+
		"\"ns\":%d,\"out_len\":%d}\n",
		caseID(codec, direction, c.shape, c.size), codec, direction, c.shape, c.size,
		sample, iters, elapsed, outLen)
}

// moduleVersion reports the pinned klauspost/compress version from the
// build info, so the meta record carries the exact competitor revision.
func moduleVersion() string {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return "unknown"
	}
	for _, dep := range info.Deps {
		if dep.Path == "github.com/klauspost/compress" {
			return dep.Version
		}
	}
	return "unknown"
}

func writeMeta(o *options) {
	var b strings.Builder
	fmt.Fprintf(&b, "{\"type\":\"meta\",\"schema\":1,\"arm\":\"klauspost\","+
		"\"tool\":\"klauspost/compress\",\"rev\":%q,\"toolchain\":%q,"+
		"\"target\":%q,\"cpu\":%q,\"optimize\":\"release\",\"suite\":%q,\"seed\":%d,"+
		"\"samples\":%d,\"sample_ms\":%d,\"impls\":[\"klauspost\"],\"corpus\":{",
		moduleVersion(), "go "+runtime.Version(),
		"linux-"+runtime.GOARCH, runtime.GOARCH, o.suite, o.seed, o.samples, o.sampleMs)
	first := true
	for _, shape := range shapes {
		for _, size := range sizes {
			raw, err := os.ReadFile(filepath.Join(o.corpus, fmt.Sprintf("%s-%d", shape, size)))
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			sum := sha256.Sum256(raw)
			if !first {
				b.WriteByte(',')
			}
			first = false
			fmt.Fprintf(&b, "%q:%q", fmt.Sprintf("%s-%d", shape, size), hex.EncodeToString(sum[:]))
		}
	}
	b.WriteString("}}\n")
	fmt.Print(b.String())
}
