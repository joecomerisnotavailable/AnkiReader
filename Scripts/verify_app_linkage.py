#!/usr/bin/env python3
"""Check a built .app for accidental host-only dynamic library dependencies.

Usage: python3 Scripts/verify_app_linkage.py path/to/ReadingCompanion.app
Run against Debug and Release device products after changing native dependencies.
This checks packaging, not on-device launch or code signing.
"""
import argparse
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    app = parser.parse_args().app
    if not app.is_dir() or app.suffix != ".app":
        parser.error("Expected an existing .app directory")

    failures = []
    checked = 0
    for path in sorted(app.rglob("*")):
        if not path.is_file():
            continue
        # Mach-O, including universal binaries. Avoid running otool on media.
        with path.open("rb") as stream:
            magic = stream.read(4)
        if magic not in (bytes.fromhex(value) for value in (
            "feedface", "cefaedfe", "feedfacf", "cffaedfe",
            "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
        )):
            continue
        checked += 1
        output = subprocess.check_output(["otool", "-l", str(path)], text=True)
        # LC_ID_DYLIB names the library itself; only audit actual load commands.
        for command in re.split(r"Load command \d+\n", output):
            if not re.search(r"cmd LC_(?:LOAD|LOAD_WEAK|REEXPORT|LOAD_UPWARD|LAZY_LOAD)_DYLIB\b", command):
                continue
            dependency = re.search(r"name (.+) \(offset \d+\)", command).group(1)
            host_absolute = dependency.startswith("/") and not dependency.startswith(
                ("/System/Library/", "/usr/lib/")
            )
            if host_absolute or "libsudachi_bridge.dylib" in dependency:
                failures.append(f"{path.relative_to(app)}: {dependency}")
    if not checked:
        failures.append("No Mach-O binaries found")
    if failures:
        raise SystemExit("Invalid app linkage:\n" + "\n".join(failures))
    print(f"PASS: {checked} Mach-O binaries; no host-only or dynamic Sudachi dependencies")


if __name__ == "__main__":
    main()
