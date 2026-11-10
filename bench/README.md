# Matched buffered-I/O comparison

Run on Linux with Mojo from this project's locked environment, Goose, Clang,
and a sibling goose-io checkout (locally named `goosio`):

```sh
pixi run bench --goose-io ../goosio --output results/io.json
```

The harness builds both runners before timing, pins subprocesses to one CPU,
warms each fixture, and alternates engine order over five samples. Each sample
reads or writes 8 MiB three times using an 8 KiB buffer. Clang uses `-O2`, as in
goose-io's existing harness; Mojo uses `-O3`. Compilation, fixture generation,
input loading for writes, process startup, and output verification are excluded.
File open/close and buffer allocation are included. Reads are warm-cache;
writes close without `fsync`, so this does not measure durable-storage speed.

Reads independently verify line count plus length/first/last-byte checksums.
Writes verify every output byte outside timing. Binary fixtures include NUL,
0xFF, CRLF, and an unterminated bare-CR tail. Unit tests separately check full
returned line contents. JSON retains every sample, fixture/source hashes,
compiler versions, options, and the Goose checkout's revision/dirty state.

## Common host, 2026-11-10

AMD Ryzen 9 3950X, Linux x86-64, CPU 0, Mojo 1.2.0. Ratio is Mojo time divided
by Goose time; lower is better. No simultaneous builds/tests were run.

| Workload | Mojo / Goose |
| --- | ---: |
| Empty lines | 3.396× |
| 2-byte lines | 1.650× |
| 16-byte lines | 1.499× |
| 80-byte CRLF lines | 1.140× |
| 1 KiB lines | 1.172× |
| 20 KiB lines | 0.468× |
| 1 MiB lines | 1.999× |
| Mixed binary lines | 1.169× |
| Writes in 32-byte chunks | 1.125× |
| Writes in 1 KiB chunks | 0.976× |
| Writes in 32 KiB chunks | 0.961× |

The explicit empty-line fast path and inlining reduced the empty-line gap from
5.4× to 3.4×. Writes are near Goose in this run; reads are mixed, with slower
tiny and very long lines. The spill-buffer design copies boundary-spanning
lines, unlike Goose's growing contiguous buffer. No performance parity is claimed.
