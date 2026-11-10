#!/usr/bin/env python3
"""Matched warm-cache Mojo/Goose reads and writes; correctness before timing.

Line fixtures and length/edge-byte checksum follow goose-io/scripts/bench_lines.py
(MIT, Seth Stadick, 2026). Write outputs are checked byte-for-byte outside timing.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def capture(command, cwd=None):
    return subprocess.check_output(command, cwd=cwd, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--goose-io", type=Path, default=ROOT.parent / "goosio")
    parser.add_argument("--goose", default="goose")
    parser.add_argument("--cc", default="clang")
    parser.add_argument("--mib", type=int, default=8)
    parser.add_argument("--passes", type=int, default=3)
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--capacity", type=int, default=8192)
    parser.add_argument("--cpu", type=int, default=min(os.sched_getaffinity(0)))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if min(args.mib, args.passes, args.rounds, args.capacity) < 1:
        parser.error("sizes and counts must be positive")
    if args.output.exists():
        parser.error("output already exists; preserve previous measurements")
    goose_io = args.goose_io.resolve()
    # Keep the package's exact bstr dependency; Goose requires transitive imports.
    dep = re.search(r'import bstr from "([^"]+)";', (goose_io / "io.goose").read_text()).group(1)
    # The matching pinned SIMD dependency is the one used by goose-io's own harness.
    simd = re.search(r'import simd_bytes from "([^"]+)";', (goose_io / "scripts/bench_lines.py").read_text()).group(1)
    report = {
        "platform": platform.platform(), "cpu": args.cpu,
        "mojo": capture(["mojo", "--version"]),
        "goose": capture([args.goose, "--version"]),
        "cc": capture([args.cc, "--version"]),
        "goose_io_commit": capture(["git", "rev-parse", "HEAD"], goose_io),
        "goose_io_status": capture(["git", "status", "--porcelain"], goose_io),
        "bstr_dependency": dep, "simd_dependency": simd,
        "options": vars(args) | {"goose_io": str(goose_io), "output": str(args.output)},
        "source_sha256": {
            str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
            for directory in (ROOT / "mojo_io", ROOT / "bench")
            for path in sorted(directory.glob("*")) if path.is_file()
        },
        "results": [],
    }
    with tempfile.TemporaryDirectory(prefix="mojo-io-bench-") as directory:
        work = Path(directory)
        source = (ROOT / "bench/io.goose").read_text().replace("GOOSE_IO", str(goose_io)).replace("BSTR_DEP", dep).replace("SIMD_DEP", simd)
        (work / "io.goose").write_text(source)
        commands = {
            "mojo": ["mojo", "build", "-O3", "-I", str(ROOT), str(ROOT / "bench/io.mojo"), "-o", str(work / "mojo")],
            "goose": [args.goose, "build", str(work / "io.goose"), "--cc", args.cc, "--standalone", "-O2", "-o", str(work / "goose")],
        }
        report["build_commands"] = commands
        for command in commands.values():
            subprocess.run(command, check=True)
        patterns = {
            "empty-lines": b"\n", "2-byte-lines": b"a\n",
            "16-byte-lines": b"abcdefghijklmno\n", "80-byte-CRLF": b"a" * 78 + b"\r\n",
            "1-KiB-lines": b"b" * 1023 + b"\n", "20-KiB-lines": b"c" * 20002 + b"\n",
            "1-MiB-lines": b"d" * (1024 * 1024 - 1) + b"\n",
            "mixed-binary": b"\nalpha\r\nx\0\xff\n" + b"z" * 997 + b"\nlast\r\n",
        }
        fixtures = []
        tail = b"unterminated\0\xff\r"
        for name, pattern in patterns.items():
            repeats = max(1, args.mib * 1024**2 // len(pattern))
            data = pattern * repeats + tail
            path = work / name
            path.write_bytes(data)
            lines = [line.removesuffix(b"\r") for line in pattern.split(b"\n")[:-1]]
            checksum = sum(len(line) + (line[0] + line[-1] if line else 0) for line in lines)
            expected = ((len(lines) * repeats + 1) * args.passes,
                        (checksum * repeats + len(tail) + tail[0] + tail[-1]) * args.passes)
            fixtures.append(("read", name, path, data, expected, 0))
        write_data = bytes(range(256)) * (args.mib * 4096)
        write_path = work / "write-input"
        write_path.write_bytes(write_data)
        for chunk in (32, 1024, 32768):
            fixtures.append(("write", f"write-{chunk}", write_path, write_data, (len(write_data) * args.passes, 0), chunk))
        for mode, name, path, data, expected, chunk in fixtures:
            def sample(engine):
                destination = work / f"written-{engine}"
                command = ["taskset", "-c", str(args.cpu), str(work / engine), mode, str(path), str(args.passes), str(args.capacity)]
                if mode == "write":
                    command.extend([str(destination), str(chunk)])
                ns, count, checksum = map(int, capture(command).split())
                if (count, checksum) != expected:
                    raise AssertionError((engine, name, count, checksum, expected))
                if mode == "write" and destination.read_bytes() != data:
                    raise AssertionError(f"{engine} wrote incorrect bytes")
                return ns / 1e9
            for engine in commands:
                sample(engine)
            samples = {engine: [] for engine in commands}
            for number in range(args.rounds):
                order = list(commands)
                if number % 2:
                    order.reverse()
                for engine in order:
                    samples[engine].append(sample(engine))
            medians = {engine: statistics.median(values) for engine, values in samples.items()}
            ratio = medians["mojo"] / medians["goose"]
            report["results"].append({"case": name, "mode": mode, "bytes": len(data),
                                      "fixture_sha256": hashlib.sha256(data).hexdigest(),
                                      "expected": expected, "seconds": samples,
                                      "median_seconds": medians, "mojo_over_goose": ratio})
            print(f"{name:18} Mojo {medians['mojo']:.6f}s Goose {medians['goose']:.6f}s ratio {ratio:.3f}x", flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
