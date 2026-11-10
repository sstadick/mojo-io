"""Run every Mojo test, fail fast, and reject empty discovery."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
tests = sorted((root / "tests").glob("test_*.mojo"))
if not tests:
    raise SystemExit("No tests/test_*.mojo files found")
for test in tests:
    subprocess.run(["mojo", "run", "-I", str(root), "-D", "ASSERT=all", str(test)], cwd=root, check=True)
