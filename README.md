# mojo-io

Binary-safe buffered file I/O for Mojo 1.2.0.
Package: `mojo-io`; import: `mojo_io`. Requires **mojo-bstr**.

## Read and write arbitrary bytes

```mojo {doctest="roundtrip" global=true}
from std.pathlib import Path
from std.tempfile import TemporaryDirectory
from std.testing import assert_equal
from mojo_io import BufferedReader, BufferedWriter

def main() raises:
    var directory = TemporaryDirectory()
    var path = String(Path(directory.name) / "records.bin")
    var bytes: List[UInt8] = [97, 0, 255, 13, 10, 116, 97, 105, 108]
    var writer = BufferedWriter(open(path, "w"), buffer_capacity=3)
    writer.write_bytes(Span(bytes))
    writer.close()

    var reader = BufferedReader(open(path, "r"), buffer_capacity=2)
    var first = reader.read_line()
    assert_equal(List(first.value()), [97, 0, 255])
    # Consume each borrowed line before the next read.
    var second = reader.read_line()
    assert_equal(List(second.value()), List("tail".as_bytes()))
    assert_equal(Bool(reader.read_line()), False)
    reader.close()
```

## Contracts

- `BufferedReader` and `BufferedWriter` take ownership of a `FileHandle`.
  Buffer capacities must be positive; the default is 128 KiB.
- `read_line()` returns `Optional[Span[UInt8, ...]]`: `None` means EOF, while
  an empty span is a real empty line. LF and CRLF terminate lines; bare CR is
  data. There is no extra line after a final terminator. An unterminated tail,
  including a trailing CR, is returned.
- **A borrowed line is valid only until the next reader read, close, move,
  or destruction.** Copy with `List(line.value())` to retain it. Mojo 1.2's
  origin checker does not reject every invalidating mutation: this is a
  caller-enforced contract, not a static-safety guarantee.
- `read_until(destination, char=10)` appends bytes before the delimiter,
  consumes but excludes it, and returns bytes consumed **including** it.
  Existing destination bytes are neither cleared nor counted. Zero means EOF,
  so an empty terminated record returns one. Unlike `read_line`, it does not
  strip CR.
- `read_bytes(destination)` fills up to `len(destination)` and returns the
  number read. A zero-length destination consumes nothing. Short underlying
  reads are not mistaken for EOF; the implementation does not seek.
- `read_lines(path, buf_size=...)` returns owned byte lists for all lines.
- `write_bytes` accepts arbitrary bytes; `write_string` accepts UTF-8 text.
  Both can raise I/O errors. `BufferedWriter` does not implement Mojo's
  non-raising `Writer` interface.
- **Call `close()` explicitly to observe write/flush errors.** Destruction
  attempts a flush but cannot report failures. A failed write poisons the
  writer to prevent duplicated output after partial writes. Closing releases
  the descriptor even after failure; repeated close is harmless. A flush
  writes to the OS; it is not an `fsync` durability guarantee.

## Develop

```sh
pixi run t
pixi run format
pixi run consumer
pixi run docs
```

Documentation uses a sibling Mojoverse checkout, or the path in `MOJOVERSE`.
It runs the examples with the package's own locked compiler before producing
the site under `target/docs`. Documentation CI saves a site artifact; it does
not deploy or replace stable documentation from nightly.

Tests cover binary data, buffer capacities down to one byte, LF/CRLF crossing
refills, empty/unterminated/long lines, destination reuse, empty reads, closed
writers, and write failures. Performance comparisons use goose-io's existing
line benchmark approach with matching data and buffer sizes; read and write
measurements must verify output before timing.
See the [benchmark protocol and results](bench/README.md) for measured gaps.

The manifest pins a compatible `mojo-bstr` Git revision; no sibling checkout is
needed. The consumer check builds both packages and runs the full I/O tests from
installed modules without source include paths.

`main` targets stable Mojo; `nightly` tracks nightly compiler compatibility.
Stable promotion is manual.

MIT licensed; see [LICENSE](LICENSE) for ExtraMojo attribution.
