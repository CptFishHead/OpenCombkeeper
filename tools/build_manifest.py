"""Build a release manifest from committed Git blobs."""
import argparse
from pathlib import Path
import subprocess
import zlib

FILES = ("opencombkeeper.lua", "install.lua", "src/topology.lua", "src/executor.lua",
         "src/plan.lua", "src/hardware.lua", "src/hardware.example.lua", "VERSION")
ROOT = Path(__file__).resolve().parents[1]


def build(revision: str) -> str:
    revision = subprocess.check_output(
        ["git", "rev-parse", revision + "^{commit}"], cwd=ROOT, text=True).strip()
    blobs = {name: subprocess.check_output(["git", "show", f"{revision}:{name}"], cwd=ROOT)
             for name in FILES}
    version = blobs["VERSION"].decode("ascii").strip()
    lines = ["OpenCombkeeper-package-1", f"revision {revision}", f"version {version}"]
    lines += [f"file {name} {len(content)} {zlib.adler32(content):08x}"
              for name, content in blobs.items()]
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("revision")
    parser.add_argument("--output", default=str(ROOT / "package.manifest"))
    options = parser.parse_args()
    Path(options.output).write_text(build(options.revision), encoding="ascii", newline="\n")
