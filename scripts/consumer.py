"""Build both packages, then run all I/O tests from installed artifacts without -I."""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile
import tomllib

root = Path(__file__).resolve().parents[1]
config = tomllib.loads((root / "pixi.toml").read_text())
channels = json.dumps(config["workspace"]["channels"])
dependency = config["dependencies"]["mojo-bstr"]
target = {("Linux", "x86_64"): "linux-64", ("Linux", "aarch64"): "linux-aarch64",
          ("Darwin", "arm64"): "osx-arm64"}[(platform.system(), platform.machine())]
with tempfile.TemporaryDirectory(prefix="mojo-io-consumer-") as directory:
    work = Path(directory)
    output = work / "packages"
    # Pixi requires source runtime dependencies inside one publish workspace.
    # Stage independent repositories under a disposable workspace; never upload.
    build = work / "build"
    build.mkdir()
    subprocess.run(["git", "clone", "--quiet", dependency["git"], str(build / "mojo-bstr")], check=True)
    subprocess.run(["git", "-C", str(build / "mojo-bstr"), "checkout", "--quiet", dependency["rev"]], check=True)
    shutil.copytree(root, build / "mojo-io",
                    ignore=shutil.ignore_patterns(".git", ".pixi", ".amp", "target", "__pycache__"))
    for name in ("mojo-bstr", "mojo-io"):
        # Nested [workspace] tables opt out of the parent's publish discovery.
        manifest = build / name / "pixi.toml"
        package_config = "\n".join(re.findall(
            r"(?ms)^\[package(?:\.[^\]]+)?\]\n.*?(?=^\[|\Z)", manifest.read_text()
        ))
        manifest.write_text(re.sub(r'^mojo-bstr = .*$', 'mojo-bstr = { path = "../mojo-bstr" }',
                                   package_config, flags=re.M))
    (build / "pixi.toml").write_text(
        '[workspace]\nname = "io-package-build"\npreview = ["pixi-build"]\n'
        f'channels = {channels}\n'
        f'platforms = ["{target}"]\n[dependencies]\n'
        'mojo-io = { path = "mojo-io" }\nmojo-bstr = { path = "mojo-bstr" }\n'
    )
    subprocess.run(["pixi", "publish", "--target-dir", str(output)], cwd=build, check=True)
    dependencies = []
    for name in ("mojo-bstr", "mojo-io"):
        package, = output.glob(f"{name}-*.conda")
        digest = hashlib.sha256(package.read_bytes()).hexdigest()
        dependencies.append(
            f"{name} = {{ url = {json.dumps(package.as_uri())}, sha256 = \"{digest}\" }}"
        )
    consumer = work / "consumer"
    consumer.mkdir()
    (consumer / "pixi.toml").write_text(
        '[workspace]\nname = "io-consumer"\n'
        f'channels = {channels}\n'
        f'platforms = ["{target}"]\n[dependencies]\n' + "\n".join(dependencies) + "\n"
    )
    shutil.copyfile(root / "tests/test_buffered.mojo", consumer / "test.mojo")
    env = os.environ.copy()
    for key in ("MOJO_PATH", "MOJO_INCLUDE_PATH", "MODULAR_MOJO_IMPORT_PATH",
                "PIXI_WORKSPACE_MANIFEST", "PIXI_PROJECT_MANIFEST", "CONDA_PREFIX"):
        env.pop(key, None)
    env["PIXI_CACHE_DIR"] = str(work / "consumer-cache")
    subprocess.run(["pixi", "run", "--manifest-path", str(consumer / "pixi.toml"),
                    "mojo", "run", "-D", "ASSERT=all", "test.mojo"], cwd=consumer, env=env, check=True)
    for module in ("mojo_bstr", "mojo_io"):
        assert (consumer / f".pixi/envs/default/lib/mojo/{module}.mojoc").is_file()
    print("Clean artifact-only consumer passed all I/O tests with installed bstr and I/O modules")
