// Adapted from goose-io/scripts/bench_lines.py (MIT, Seth Stadick, 2026).
import std;
import os;
import io from "GOOSE_IO";
import bstr from "BSTR_DEP";
import simd_bytes from "SIMD_DEP";

fn main() {
    let argv = args();
    let passes, ok = parse_int(argv[3]);
    assert(ok && passes > 0);
    let capacity, cap_ok = parse_int(argv[4]);
    assert(cap_ok && capacity > 0);
    var count: i64 = 0;
    var checksum: i64 = 0;
    if argv[1] == "read" {
        let start = clock_ns();
        for _ in passes {
            let file, opened = io::open_read(argv[2]);
            assert(opened);
            let reader = io::buffered_reader(file, capacity);
            loop {
                let line, status = io::read_line(reader);
                if status == io::LineStatus.Eof { break; }
                assert(status == io::LineStatus.Line);
                count++;
                checksum += line.len;
                if line.len > 0 { checksum += line[0]; checksum += line[line.len - 1]; }
            }
            assert(io::close(reader));
        }
        print(clock_ns() - start, " ", count, " ", checksum);
    } else {
        var data: u8[>..] = [];
        assert(read_file(argv[2], data));
        let chunk, chunk_ok = parse_int(argv[6]);
        assert(chunk_ok && chunk > 0);
        let start = clock_ns();
        for _ in passes {
            let file, opened = io::open_write(argv[5]);
            assert(opened);
            let writer = io::buffered_writer(file, capacity);
            var offset: i64 = 0;
            while offset < data.len {
                let end = min(data.len, offset + chunk);
                let written = io::write(writer, data[offset..end]);
                assert(written == end - offset);
                count += written;
                offset = end;
            }
            assert(io::close(writer));
        }
        print(clock_ns() - start, " ", count, " 0");
    }
}
