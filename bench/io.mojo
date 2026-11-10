from std.sys import argv
from std.time import monotonic
from mojo_io import BufferedReader, BufferedWriter


def main() raises:
    var args = argv()
    var path = String(args[2])
    var passes = Int(args[3])
    var capacity = Int(args[4])
    var count = 0
    var checksum = 0
    if args[1] == "read":
        var start = monotonic()
        for _ in range(passes):
            var reader = BufferedReader(open(path, "r"), capacity)
            while True:
                var item = reader.read_line()
                if not item:
                    break
                var line = item.value()
                count += 1
                checksum += len(line)
                if len(line):
                    checksum += Int(line[0]) + Int(line[len(line) - 1])
            reader.close()
        print(monotonic() - start, count, checksum)
    else:
        var data = open(path, "r").read_bytes()
        var destination = String(args[5])
        var chunk = Int(args[6])
        var start = monotonic()
        for _ in range(passes):
            var writer = BufferedWriter(open(destination, "w"), capacity)
            for offset in range(0, len(data), chunk):
                var end = min(len(data), offset + chunk)
                writer.write_bytes(Span(data)[offset:end])
                count += end - offset
            writer.close()
        print(monotonic() - start, count, 0)
