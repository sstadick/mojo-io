from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite
from std.tempfile import TemporaryDirectory
from std.pathlib import Path
from mojo_io import BufferedReader, BufferedWriter, read_lines


def test_lines_bytes_and_delimiters() raises:
    var temp = TemporaryDirectory()
    var path = String(Path(temp.name) / "bytes")
    var data: List[UInt8] = [10, 97, 13, 10, 0, 255, 10, 13, 120, 10, 116, 97, 105, 108, 13]
    var expected: List[List[UInt8]] = [[], [97], [0, 255], [13, 120], [116, 97, 105, 108, 13]]
    var capacities = [1, 2, 3, 8, 128]
    for cap in capacities:
        var writer = BufferedWriter(open(path, "w"), cap)
        writer.write_bytes(Span(data)[:2])
        writer.write_bytes(Span(data)[2:7])
        writer.write_bytes(Span(data)[7:])
        writer.close()
        writer.close()
        assert_equal(read_lines(path, cap), expected)
        var reader = BufferedReader(open(path, "r"), cap)
        var destination = List[UInt8](length=4, fill=0)
        var empty = List[UInt8]()
        assert_equal(reader.read_bytes(empty), 0)
        var found = List[UInt8]()
        while True:
            var count = reader.read_bytes(destination)
            if count == 0:
                break
            found.extend(Span(destination)[:count])
        assert_equal(found, data)
        assert_equal(reader.read_bytes(destination), 0)
        reader.close()
        var until = BufferedReader(open(path, "r"), cap)
        var record: List[UInt8] = [42]
        assert_equal(until.read_until(record), 1)
        assert_equal(record, [42])
        assert_equal(until.read_until(record), 3)
        assert_equal(record, [42, 97, 13])
        record.clear()
        assert_equal(until.read_until(record, 255), 2)
        assert_equal(record, [0])


def test_empty_tail_and_long_lines() raises:
    var temp = TemporaryDirectory()
    var path = String(Path(temp.name) / "lines")
    var writer = BufferedWriter(open(path, "w"), 3)
    writer.close()
    assert_equal(len(read_lines(path, 1)), 0)
    var long_line = String("x" * 10000)
    var output = BufferedWriter(open(path, "w"), 3)
    output.write_string(long_line)
    output.write_string("\r\n\nlast\n")
    output.close()
    var lines = read_lines(path, 7)
    assert_equal(len(lines), 3)
    assert_equal(lines[0], List(long_line.as_bytes()))
    assert_equal(len(lines[1]), 0)
    assert_equal(lines[2], List("last".as_bytes()))


def test_errors_and_closed_writer() raises:
    var temp = TemporaryDirectory()
    var path = String(Path(temp.name) / "errors")
    with assert_raises():
        var _ = BufferedWriter(open(path, "w"), 0)
    with assert_raises():
        var _ = BufferedReader(open(path, "r"), -1)
    var writer = BufferedWriter(open(path, "w"), 8)
    writer.close()
    with assert_raises():
        writer.write_string("lost")
    with assert_raises():
        writer.flush()
    var pending = BufferedWriter(open(path, "w"), 8)
    pending.write_string("a\nb")
    var moved = pending^
    moved.close()
    moved.close()
    assert_equal(read_lines(path), [List("a".as_bytes()), List("b".as_bytes())])
    var reader = BufferedReader(open(path, "r"), 8)
    assert_equal(List(reader.read_line().value()), List("a".as_bytes()))
    reader.close()
    reader.close()
    assert_false(Bool(reader.read_line()))
    var destination: List[UInt8] = [99]
    assert_equal(reader.read_bytes(destination), 0)
    assert_equal(reader.read_until(destination), 0)
    assert_equal(destination, [99])
    if Path("/dev/full").exists():
        var full = BufferedWriter(open("/dev/full", "w"), 8)
        full.write_string("short")
        with assert_raises():
            full.flush()
        with assert_raises():
            full.write_string("no retry")
        with assert_raises():
            full.close()
        full.close()
        with assert_raises():
            full.flush()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
